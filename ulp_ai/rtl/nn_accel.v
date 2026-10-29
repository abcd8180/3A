// ---------------------------------------------------------------------------
// nn_accel.v : INT8 완전연결(FC) 레이어 가속기 (메모리맵 + 버스 마스터)
//   y[j] = sat8( relu?( (b[j] + Σ_k W[j][k]*x[k]) >>> SHIFT ) )
//  - 32bit 워드 = INT8 4개 → 사이클당 4 MAC (SIMD)
//  - 유휴 시 클럭게이팅 + 피연산자 격리(operand isolation)로 동적전력 0
//  레지스터 (base 0x1000_0000)
//   0x00 CTRL   [0]=START(W) [1]=RELU
//   0x04 STATUS [0]=BUSY [1]=DONE (DONE 은 1 써서 클리어, W1C)
//   0x08 W_ADDR 0x0C X_ADDR 0x10 Y_ADDR 0x14 LEN(4의 배수) 0x18 OUT
//   0x1C SHIFT  0x20 B_ADDR(int32 바이어스)  0x24 IE [0]=DONE 인터럽트
// ---------------------------------------------------------------------------
module nn_accel(
    input             clk,
    input             rst_n,
    // 슬레이브(레지스터) 포트
    input             s_sel,
    input             s_we,
    input      [5:0]  s_addr,
    input      [31:0] s_wdata,
    output reg [31:0] s_rdata,
    // 마스터(SRAM) 포트
    output reg        m_req,
    output reg        m_we,
    output reg [31:0] m_addr,
    output reg [31:0] m_wdata,
    output reg [3:0]  m_be,
    input             m_gnt,
    input      [31:0] m_rdata,
    output            busy,
    output            irq
);
    reg [31:0] w_base, x_base, y_base, b_base;
    reg [15:0] len, nout;
    reg [4:0]  shift;
    reg        relu, done, ie;

    localparam A_IDLE=4'd0, A_LB=4'd1, A_LBW=4'd2, A_LX=4'd3, A_LXW=4'd4,
               A_LW=4'd5, A_LWW=4'd6, A_ST=4'd7;
    reg [3:0]  st;
    reg [31:0] wp, xp, yp, bp, xw;
    reg [15:0] k, j;
    reg signed [31:0] acc;

    assign busy = (st != A_IDLE);
    assign irq  = done & ie;

    // ---- 4-way INT8 dot product (유휴 시 입력 0 고정 = operand isolation) ----
    wire        mac_en = (st == A_LWW);
    wire [31:0] wa = mac_en ? m_rdata : 32'd0;
    wire [31:0] xa = mac_en ? xw      : 32'd0;
    wire signed [15:0] p0 = $signed(wa[7:0])   * $signed(xa[7:0]);
    wire signed [15:0] p1 = $signed(wa[15:8])  * $signed(xa[15:8]);
    wire signed [15:0] p2 = $signed(wa[23:16]) * $signed(xa[23:16]);
    wire signed [15:0] p3 = $signed(wa[31:24]) * $signed(xa[31:24]);
    wire signed [31:0] dot4 = p0 + p1 + p2 + p3;

    // ---- 재양자화 ----
    wire signed [31:0] sh  = acc >>> shift;
    wire signed [31:0] rl  = (relu && sh < 0) ? 32'sd0 : sh;
    wire [7:0] q = (rl >  127) ? 8'h7F :
                   (rl < -128) ? 8'h80 : rl[7:0];

    // ---- 레지스터 읽기 ----
    always @* begin
        case (s_addr[5:2])
            4'h0: s_rdata = {30'd0, relu, 1'b0};
            4'h1: s_rdata = {30'd0, done, busy};
            4'h2: s_rdata = w_base;   4'h3: s_rdata = x_base;
            4'h4: s_rdata = y_base;   4'h5: s_rdata = {16'd0, len};
            4'h6: s_rdata = {16'd0, nout};
            4'h7: s_rdata = {27'd0, shift};
            4'h8: s_rdata = b_base;   4'h9: s_rdata = {31'd0, ie};
            default: s_rdata = 32'd0;
        endcase
    end

    // ---- 마스터 버스(조합) ----
    always @* begin
        m_req = 1'b0; m_we = 1'b0; m_addr = 32'd0; m_wdata = 32'd0; m_be = 4'hF;
        case (st)
            A_LB: begin m_req = 1'b1; m_addr = bp; end
            A_LX: begin m_req = 1'b1; m_addr = xp; end
            A_LW: begin m_req = 1'b1; m_addr = wp; end
            A_ST: begin m_req = 1'b1; m_we = 1'b1; m_addr = {yp[31:2], 2'b00};
                        m_wdata = {4{q}}; m_be = 4'b0001 << yp[1:0]; end
            default: ;
        endcase
    end

    wire start = s_sel & s_we & (s_addr[5:2] == 4'h0) & s_wdata[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= A_IDLE; done <= 1'b0; ie <= 1'b0; relu <= 1'b0;
            w_base <= 0; x_base <= 0; y_base <= 0; b_base <= 0;
            len <= 0; nout <= 0; shift <= 0;
            wp <= 0; xp <= 0; yp <= 0; bp <= 0; xw <= 0; k <= 0; j <= 0; acc <= 0;
        end else begin
            if (s_sel & s_we) begin
                case (s_addr[5:2])
                    4'h0: relu   <= s_wdata[1];
                    4'h1: if (s_wdata[1]) done <= 1'b0;
                    4'h2: w_base <= s_wdata;  4'h3: x_base <= s_wdata;
                    4'h4: y_base <= s_wdata;  4'h5: len    <= s_wdata[15:0];
                    4'h6: nout   <= s_wdata[15:0];
                    4'h7: shift  <= s_wdata[4:0];
                    4'h8: b_base <= s_wdata;  4'h9: ie     <= s_wdata[0];
                    default: ;
                endcase
            end
            case (st)
            A_IDLE: if (start && nout != 0 && len != 0) begin
                wp <= w_base; bp <= b_base; yp <= y_base; j <= 0; done <= 1'b0;
                st <= A_LB;
            end
            A_LB:  if (m_gnt) st <= A_LBW;
            A_LBW: begin acc <= m_rdata; xp <= x_base; k <= 0; st <= A_LX; end
            A_LX:  if (m_gnt) st <= A_LXW;
            A_LXW: begin xw <= m_rdata; st <= A_LW; end
            A_LW:  if (m_gnt) st <= A_LWW;
            A_LWW: begin
                acc <= acc + dot4;
                wp <= wp + 4; xp <= xp + 4; k <= k + 4;
                st <= (k + 16'd4 >= len) ? A_ST : A_LX;
            end
            A_ST: if (m_gnt) begin
                yp <= yp + 1; bp <= bp + 4; j <= j + 1;
                if (j + 16'd1 == nout) begin done <= 1'b1; st <= A_IDLE; end
                else st <= A_LB;
            end
            default: st <= A_IDLE;
            endcase
        end
    end
endmodule
