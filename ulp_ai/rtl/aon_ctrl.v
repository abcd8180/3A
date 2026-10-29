// ---------------------------------------------------------------------------
// aon_ctrl.v : Always-On 도메인 (32.768 kHz LFCLK, 상시 전원)
//  - 주기 웨이크업 타이머 (free-running, PERIOD 틱마다 tick_tgl 토글)
//  - 전원 시퀀서: RUN → ISO → OFF(파워게이팅, HF 발진기 OFF) → ON → UNISO → WAITACK → RUN
//  - 메인 도메인과는 토글 핸드셰이크(tick_tgl / ack_tgl) + 2FF 동기화로만 통신
//  period / deep_en 은 메인 도메인 레지스터(quasi-static: 타이머 정지 중에만 변경)
// ---------------------------------------------------------------------------
module aon_ctrl(
    input         lfclk,
    input         rst_n,
    input  [23:0] period,      // 0 = 타이머 정지
    input         deep_en,     // 1 = 슬립 시 메인 도메인 파워게이팅
    input         sleep_req,   // 메인 도메인: 코어 WFI & 가속기 유휴 (비동기)
    input         ack_tgl,     // 메인 도메인: 이벤트 수신 확인 토글 (비동기)
    output reg    tick_tgl,    // 웨이크 이벤트 토글
    output reg    hfosc_en,    // 메인 고속 RC 발진기 enable
    output reg    pwr_on,      // 메인 도메인 헤더 스위치 (1=전원 인가)
    output reg    iso_en,      // 출력 격리 셀 enable
    output reg    ret_hold     // 리텐션 플롭/SRAM 유지 모드
);
    reg [1:0] s_sync, a_sync;
    always @(posedge lfclk or negedge rst_n)
        if (!rst_n) begin s_sync <= 0; a_sync <= 0; end
        else begin s_sync <= {s_sync[0], sleep_req}; a_sync <= {a_sync[0], ack_tgl}; end
    wire sleep_s = s_sync[1];
    wire ack_s   = a_sync[1];
    wire pending = (ack_s != tick_tgl);

    // ---- 주기 타이머 ----
    reg [23:0] cnt;
    wire tick = (period != 0) && (cnt >= period - 1);
    always @(posedge lfclk or negedge rst_n)
        if (!rst_n) begin cnt <= 0; tick_tgl <= 1'b0; end
        else if (period == 0) cnt <= 0;
        else if (tick) begin cnt <= 0; tick_tgl <= ~tick_tgl; end
        else cnt <= cnt + 1;

    // ---- 전원 시퀀서 ----
    localparam P_RUN=3'd0, P_ISO=3'd1, P_OFF=3'd2, P_ON=3'd3, P_UNISO=3'd4, P_WACK=3'd5;
    reg [2:0] ps;
    always @(posedge lfclk or negedge rst_n) begin
        if (!rst_n) begin
            ps <= P_RUN; hfosc_en <= 1'b1; pwr_on <= 1'b1; iso_en <= 1'b0; ret_hold <= 1'b0;
        end else case (ps)
            P_RUN:   if (deep_en && sleep_s && !pending && !tick) begin
                         iso_en <= 1'b1; ret_hold <= 1'b1; ps <= P_ISO;
                     end
            P_ISO:   begin hfosc_en <= 1'b0; pwr_on <= 1'b0; ps <= P_OFF; end
            P_OFF:   if (tick) begin pwr_on <= 1'b1; ps <= P_ON; end
            P_ON:    begin hfosc_en <= 1'b1; ret_hold <= 1'b0; ps <= P_UNISO; end
            P_UNISO: begin iso_en <= 1'b0; ps <= P_WACK; end
            P_WACK:  if (!pending) ps <= P_RUN;   // 코어가 이벤트를 받을 때까지 대기
            default: ps <= P_RUN;
        endcase
    end
endmodule
