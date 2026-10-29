`timescale 1ns/1ps
// 테스트벤치: 1 MHz 메인 RC 발진기 + 32.768 kHz LFCLK
// 웨이크마다 분류 결과를 골든 모델과 비교하고, 도메인별 활성 사이클로 평균전력을 추정
module tb;
    reg lfclk = 0, osc = 0, rst_n = 0;
    wire hfosc_en, pwr_on, iso_en, ret_hold, result_we, halted, cce, ace;
    wire [31:0] result;
    always #15259 lfclk = ~lfclk;           // 32.768 kHz
    always #500   osc   = ~osc;             // 1 MHz
    wire hfclk = osc & hfosc_en;            // 발진기 enable 모델

    ulp_soc #(.INIT("firmware.hex")) dut(.hfclk_osc(hfclk), .lfclk(lfclk), .rst_n(rst_n),
        .hfosc_en(hfosc_en), .pwr_on(pwr_on), .iso_en(iso_en), .ret_hold(ret_hold),
        .result(result), .result_we(result_we), .halted(halted),
        .core_clk_en(cce), .acc_clk_en(ace));

    reg [3:0] exp [0:4];
    integer n = 0, err = 0;
    integer c_core = 0, c_acc = 0, c_osc = 0, c_lf = 0, c_off = 0, c_sleepon = 0;
    always @(posedge osc) if (hfosc_en) begin
        c_osc = c_osc + 1;
        if (cce) c_core = c_core + 1;
        if (ace) c_acc  = c_acc + 1;
    end
    always @(posedge lfclk) begin
        c_lf = c_lf + 1;
        if (!pwr_on) c_off = c_off + 1;
    end
    always @(posedge hfclk) if (result_we) begin
        if (dut.c_wdata[3:0] !== exp[n]) begin
            err = err + 1; $display("[%0t] wake %0d: class %0d  (expected %0d)  MISMATCH", $time, n, dut.c_wdata, exp[n]);
        end else $display("[%0t] wake %0d: class %0d  OK", $time, n, dut.c_wdata);
        n = n + 1;
    end

    // ---- 가정 에너지 파라미터 (README 참고; 22~40nm ULP, 0.6~0.9 V 근사치) ----
    real E_CORE = 8.0e-12, E_ACC = 12.0e-12, E_OSC = 1.0e-12;  // J/cycle
    real P_AON  = 0.3e-6;    // AON 도메인 + LF 발진기
    real P_RET  = 1.0e-6;    // 8 KB 리텐션 SRAM + 리텐션 플롭 누설
    real P_ONLK = 10.0e-6;   // 메인 도메인 전원 ON 상태 누설
    initial begin
        $readmemh("expected.hex", exp);
        #100000 rst_n = 1;          // LFCLK 여러 주기 동안 리셋 유지
        wait (halted);
        #2000;
        begin : rpt
            real T, E, Pavg, ton;
            T   = $realtime * 1e-9;
            ton = T - c_off * 30.5176e-6;
            E   = c_core*E_CORE + c_acc*E_ACC + c_osc*E_OSC + P_AON*T + P_RET*T + P_ONLK*ton;
            Pavg = E / T;
            $display("------------------------------------------------------------");
            $display("시뮬 시간 %0.3f ms, 웨이크 %0d 회, 오류 %0d", T*1e3, n, err);
            $display("HF 발진기 ON %0d cyc, 코어 클럭 %0d cyc, 가속기 클럭 %0d cyc", c_osc, c_core, c_acc);
            $display("메인 도메인 OFF 비율 %0.1f %%", 100.0*(c_off*30.5176e-6)/T);
            $display("추론 1회당 동적에너지 ~%0.1f nJ", (c_core*E_CORE + c_acc*E_ACC + c_osc*E_OSC)/n*1e9);
            $display("평균전력(이 시뮬, 1 ms 주기) ~%0.2f uW", Pavg*1e6);
            $display("평균전력(1 s 주기 환산)      ~%0.2f uW", (P_AON + P_RET + ((c_core*E_CORE + c_acc*E_ACC + c_osc*E_OSC)/n + P_ONLK*ton/n)) * 1e6);
            $display("%s", (err == 0 && n == 5) ? "PASS" : "FAIL");
        end
        $finish;
    end
    initial begin #50_000_000; $display("TIMEOUT"); $finish; end
endmodule
