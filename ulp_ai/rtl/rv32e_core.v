// ---------------------------------------------------------------------------
// rv32e_core.v : 초저전력용 최소 RV32E 멀티사이클 코어
//  - 레지스터 16개(RV32E) → 레지스터파일 면적/누설 절반
//  - 파이프라인 없음(FETCH→EXEC→MEM), 분기예측/캐시 없음 → 토글 최소화
//  - WFI : 슬립 상태로 들어가고 irq 가 오면 다음 명령부터 재개(트랩 없음)
//  - EBREAK/ECALL/불법명령 : HALT
//  - 버스: req 를 gnt 까지 유지, rdata 는 gnt 다음 사이클에 유효
// ---------------------------------------------------------------------------
module rv32e_core #(parameter [31:0] RESET_PC = 32'h0)(
    input             clk,
    input             rst_n,
    output reg        mem_req,
    output reg        mem_we,
    output reg [31:0] mem_addr,
    output reg [31:0] mem_wdata,
    output reg [3:0]  mem_be,
    input             mem_gnt,
    input      [31:0] mem_rdata,
    input             irq,        // 깨움 요청(레벨)
    output            sleeping,   // WFI 대기 중
    output            halted
);
    localparam S_FETCH=3'd0, S_FWAIT=3'd1, S_EXEC=3'd2, S_MEM=3'd3,
               S_MWAIT=3'd4, S_SLEEP=3'd5, S_HALT=3'd6;
    localparam OP_LUI=7'b0110111, OP_AUIPC=7'b0010111, OP_JAL=7'b1101111,
               OP_JALR=7'b1100111, OP_BR=7'b1100011, OP_LD=7'b0000011,
               OP_ST=7'b0100011, OP_IMM=7'b0010011, OP_OP=7'b0110011,
               OP_FENCE=7'b0001111, OP_SYS=7'b1110011;
    localparam [31:0] INSN_WFI = 32'h10500073;

    reg [2:0]  st;
    reg [31:0] pc, ir;
    reg [31:0] rf [1:15];

    wire [6:0] opc = ir[6:0];
    wire [2:0] f3  = ir[14:12];
    wire       f7b = ir[30];
    wire [3:0] rd  = ir[10:7];
    wire [3:0] rs1 = ir[18:15];
    wire [3:0] rs2 = ir[23:20];
    wire [31:0] x1 = (rs1 == 4'd0) ? 32'd0 : rf[rs1];
    wire [31:0] x2 = (rs2 == 4'd0) ? 32'd0 : rf[rs2];

    wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
    wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
    wire [31:0] imm_b = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
    wire [31:0] imm_u = {ir[31:12], 12'd0};
    wire [31:0] imm_j = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};

    // ---- ALU ----
    wire [31:0] alu_b = (opc == OP_OP) ? x2 : imm_i;
    reg  [31:0] alu_y;
    always @* begin
        case (f3)
            3'd0: alu_y = (opc == OP_OP && f7b) ? x1 - alu_b : x1 + alu_b;
            3'd1: alu_y = x1 << alu_b[4:0];
            3'd2: alu_y = {31'd0, $signed(x1) < $signed(alu_b)};
            3'd3: alu_y = {31'd0, x1 < alu_b};
            3'd4: alu_y = x1 ^ alu_b;
            3'd5: alu_y = f7b ? $signed($signed(x1) >>> alu_b[4:0]) : x1 >> alu_b[4:0];
            3'd6: alu_y = x1 | alu_b;
            default: alu_y = x1 & alu_b;
        endcase
    end

    reg take;
    always @* begin
        case (f3)
            3'd0: take = (x1 == x2);
            3'd1: take = (x1 != x2);
            3'd4: take = $signed(x1) <  $signed(x2);
            3'd5: take = $signed(x1) >= $signed(x2);
            3'd6: take = x1 <  x2;
            3'd7: take = x1 >= x2;
            default: take = 1'b0;
        endcase
    end

    // ---- Load/Store ----
    wire        is_st   = (opc == OP_ST);
    wire [31:0] ls_addr = x1 + (is_st ? imm_s : imm_i);
    wire [4:0]  ls_sh   = {ls_addr[1:0], 3'b000};
    wire [31:0] ld_raw  = mem_rdata >> ls_sh;
    reg  [31:0] ld_val;
    always @* begin
        case (f3)
            3'd0: ld_val = {{24{ld_raw[7]}},  ld_raw[7:0]};
            3'd1: ld_val = {{16{ld_raw[15]}}, ld_raw[15:0]};
            3'd4: ld_val = {24'd0, ld_raw[7:0]};
            3'd5: ld_val = {16'd0, ld_raw[15:0]};
            default: ld_val = ld_raw;
        endcase
    end

    // ---- 버스 출력(조합) ----
    always @* begin
        mem_req = 1'b0; mem_we = 1'b0; mem_addr = pc; mem_wdata = 32'd0; mem_be = 4'hF;
        case (st)
            S_FETCH: mem_req = 1'b1;
            S_MEM: begin
                mem_req   = 1'b1;
                mem_addr  = {ls_addr[31:2], 2'b00};
                mem_we    = is_st;
                mem_wdata = x2 << ls_sh;
                case (f3[1:0])
                    2'd0:    mem_be = 4'b0001 << ls_addr[1:0];
                    2'd1:    mem_be = 4'b0011 << ls_addr[1:0];
                    default: mem_be = 4'b1111;
                endcase
            end
            default: ;
        endcase
    end

    assign sleeping = (st == S_SLEEP);
    assign halted   = (st == S_HALT);

    task wr(input [3:0] r, input [31:0] v);
        if (r != 4'd0) rf[r] <= v;
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_FETCH; pc <= RESET_PC; ir <= 32'h13;
        end else begin
            case (st)
            S_FETCH: if (mem_gnt) st <= S_FWAIT;
            S_FWAIT: begin ir <= mem_rdata; st <= S_EXEC; end
            S_EXEC: begin
                st <= S_FETCH;
                pc <= pc + 32'd4;
                case (opc)
                    OP_LUI:   wr(rd, imm_u);
                    OP_AUIPC: wr(rd, pc + imm_u);
                    OP_JAL:   begin wr(rd, pc + 32'd4); pc <= pc + imm_j; end
                    OP_JALR:  begin wr(rd, pc + 32'd4); pc <= (x1 + imm_i) & ~32'd1; end
                    OP_BR:    if (take) pc <= pc + imm_b;
                    OP_IMM, OP_OP: wr(rd, alu_y);
                    OP_LD, OP_ST: begin pc <= pc; st <= S_MEM; end
                    OP_FENCE: ;
                    OP_SYS:   if (ir == INSN_WFI) st <= S_SLEEP;
                              else begin pc <= pc; st <= S_HALT; end
                    default:  begin pc <= pc; st <= S_HALT; end
                endcase
            end
            S_MEM: if (mem_gnt) begin
                if (is_st) begin pc <= pc + 32'd4; st <= S_FETCH; end
                else st <= S_MWAIT;
            end
            S_MWAIT: begin wr(rd, ld_val); pc <= pc + 32'd4; st <= S_FETCH; end
            S_SLEEP: if (irq) st <= S_FETCH;
            default: ; // HALT
            endcase
        end
    end
endmodule
