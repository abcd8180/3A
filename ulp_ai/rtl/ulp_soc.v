// ---------------------------------------------------------------------------
// ulp_soc.v : 초저전력 RISC-V AI SoC 톱
//  메모리맵: 0x0000_0000 SRAM 8KB | 0x1000_0000 NN 가속기 | 0x2000_0000 AON/시스템
//  AON/시스템 레지스터: 0x00 PERIOD  0x04 CTRL[0]=DEEP_EN  0x08 STAT  0x0C RESULT
// ---------------------------------------------------------------------------
module ulp_soc #(parameter INIT = "firmware.hex")(
    input         hfclk_osc,  // 메인 RC 발진기 출력 (hfosc_en 으로 켜고 끔)
    input         lfclk,      // 32.768 kHz 상시 클럭
    input         rst_n,
    output        hfosc_en,
    output        pwr_on, iso_en, ret_hold,
    output [31:0] result,
    output        result_we,
    output        halted,
    output        core_clk_en, acc_clk_en
);
    // ---------------- 클럭 ----------------
    wire clk_main = hfclk_osc;              // 발진기가 꺼지면 자동으로 정지
    wire core_clk, acc_clk;

    // ---------------- 코어 ----------------
    wire        c_req, c_we, c_gnt, c_sleep, c_irq;
    wire [31:0] c_addr, c_wdata, c_rdata;
    wire [3:0]  c_be;
    rv32e_core u_core(.clk(core_clk), .rst_n(rst_n),
        .mem_req(c_req), .mem_we(c_we), .mem_addr(c_addr), .mem_wdata(c_wdata),
        .mem_be(c_be), .mem_gnt(c_gnt), .mem_rdata(c_rdata),
        .irq(c_irq), .sleeping(c_sleep), .halted(halted));

    // ---------------- 가속기 ----------------
    wire        a_sel = c_req & (c_addr[31:28] == 4'h1);
    wire [31:0] a_srd;
    wire        m_req, m_we, a_busy, a_irq;
    wire [31:0] m_addr, m_wdata;
    wire [3:0]  m_be;
    wire        m_gnt = m_req;                       // 가속기 버스 우선
    wire [31:0] ram_rd;
    nn_accel u_acc(.clk(acc_clk), .rst_n(rst_n),
        .s_sel(a_sel & c_gnt), .s_we(c_we), .s_addr(c_addr[5:0]), .s_wdata(c_wdata), .s_rdata(a_srd),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_be(m_be),
        .m_gnt(m_gnt), .m_rdata(ram_rd), .busy(a_busy), .irq(a_irq));

    // ---------------- 버스 / SRAM ----------------
    assign c_gnt = c_req & ~m_req;
    wire r_sel_c = c_gnt & (c_addr[31:28] == 4'h0);
    wire ram_req = m_req | r_sel_c;
    sram #(.WORDS(2048), .INIT(INIT)) u_ram(.clk(clk_main), .req(ram_req),
        .we(m_req ? m_we : c_we), .be(m_req ? m_be : c_be),
        .addr(m_req ? m_addr[12:2] : c_addr[12:2]),
        .wdata(m_req ? m_wdata : c_wdata), .rdata(ram_rd));

    // ---------------- AON/시스템 레지스터 (메인 도메인) ----------------
    reg  [23:0] period;
    reg         deep_en;
    reg  [31:0] result_r;
    wire        s_sel = c_gnt & (c_addr[31:28] == 4'h2);
    reg  [31:0] s_rd;
    wire        tick_tgl;
    reg  [1:0]  t_sync;
    reg         ack_tgl;
    always @(posedge clk_main or negedge rst_n)
        if (!rst_n) begin period <= 0; deep_en <= 0; result_r <= 0; end
        else if (s_sel & c_we) case (c_addr[3:2])
            2'd0: period   <= c_wdata[23:0];
            2'd1: deep_en  <= c_wdata[0];
            2'd3: result_r <= c_wdata;
            default: ;
        endcase
    assign result    = result_r;
    assign result_we = s_sel & c_we & (c_addr[3:2] == 2'd3);
    always @* case (c_addr[3:2])
        2'd0: s_rd = {8'd0, period};  2'd1: s_rd = {31'd0, deep_en};
        2'd2: s_rd = {30'd0, a_busy, ack_tgl};  default: s_rd = result_r;
    endcase

    // 읽기 데이터 mux (1사이클 지연 선택)
    reg [1:0]  rsel;
    reg [31:0] p_rd;
    always @(posedge clk_main) if (c_gnt) begin
        rsel <= c_addr[29:28];
        p_rd <= (c_addr[31:28] == 4'h1) ? a_srd : s_rd;
    end
    assign c_rdata = (rsel == 2'd0) ? ram_rd : p_rd;

    // ---------------- 웨이크 이벤트 (토글 핸드셰이크) ----------------
    always @(posedge clk_main or negedge rst_n)
        if (!rst_n) t_sync <= 0; else t_sync <= {t_sync[0], tick_tgl};
    wire tmr_evt = (t_sync[1] != ack_tgl);
    always @(posedge clk_main or negedge rst_n)
        if (!rst_n) ack_tgl <= 1'b0;
        else if (c_sleep & tmr_evt) ack_tgl <= t_sync[1];   // 코어가 깨면서 소비
    assign c_irq = tmr_evt | a_irq;

    // ---------------- 클럭 게이팅 ----------------
    assign core_clk_en = ~(c_sleep | halted) | c_irq;
    assign acc_clk_en  = a_busy | a_sel;
    icg u_icg_c(.clk(clk_main), .en(core_clk_en), .gclk(core_clk));
    icg u_icg_a(.clk(clk_main), .en(acc_clk_en),  .gclk(acc_clk));

    // ---------------- AON ----------------
    wire sleep_req = c_sleep & ~a_busy & ~a_irq;
    aon_ctrl u_aon(.lfclk(lfclk), .rst_n(rst_n), .period(period), .deep_en(deep_en),
        .sleep_req(sleep_req), .ack_tgl(ack_tgl), .tick_tgl(tick_tgl),
        .hfosc_en(hfosc_en), .pwr_on(pwr_on), .iso_en(iso_en), .ret_hold(ret_hold));
endmodule
