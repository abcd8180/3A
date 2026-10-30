# ulp_soc.sdc — 시작용 제약 (값은 INSTRUCTIONS 에 따라 조정)
set HF_PERIOD  [expr {1000.0 / $::env(HF_MHZ)}]   ;# ns
create_clock -name hfclk -period $HF_PERIOD [get_ports hfclk_osc]
create_clock -name lfclk -period 30517.578  [get_ports lfclk]
# ICG 로 생성되는 게이트 클럭은 합성툴이 자동 추론(ICG 셀 매핑 후). 두 도메인은 비동기.
set_clock_groups -asynchronous -group {hfclk} -group {lfclk}
set_clock_uncertainty 0.1 [all_clocks]
set_clock_transition  0.2 [all_clocks]
set_input_delay  [expr {0.3*$HF_PERIOD}] -clock hfclk [remove_from_collection [all_inputs] [get_ports {hfclk_osc lfclk rst_n}]]
set_output_delay [expr {0.3*$HF_PERIOD}] -clock hfclk [get_ports {result* halted core_clk_en acc_clk_en}]
set_false_path -from [get_ports rst_n]
# 2FF 동기화기 첫 단: 비동기 경로 (set_clock_groups 로 이미 제외되지만 명시)
# period/deep_en → AON period_l/deep_l : quasi-static, 비동기 그룹으로 제외됨
set_load 0.005 [all_outputs]
