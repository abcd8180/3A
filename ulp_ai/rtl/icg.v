// 래치 기반 통합 클럭 게이팅 셀 (실제 구현에선 표준셀 ICG 로 교체)
module icg(input clk, input en, output gclk);
    reg en_l;
    always @(clk or en) if (!clk) en_l = en;
    assign gclk = clk & en_l;
endmodule
