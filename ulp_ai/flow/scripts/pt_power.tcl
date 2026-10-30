# pt_power.tcl — PrimeTime (PX/PrimePower) 시간기반 전력 분석 템플릿
# 사용: pt_shell -f flow/scripts/pt_power.tcl | tee logs/pt_<corner>.log
#   환경변수: CORNER(라이브러리 코너명), FSDB(게이트 시뮬 파형), WIN_ON/WIN_OFF(ns 구간)
source flow/scripts/lib_setup.tcl
set power_enable_analysis true
set power_analysis_mode time_based
read_verilog out/ulp_soc.syn.v
current_design ulp_soc
link_design
load_upf out/ulp_soc.syn.upf
read_sdc out/ulp_soc.syn.sdc
read_parasitics -quiet out/ulp_soc.spef        ;# 없으면 wireload/topo 추정으로 진행
update_timing -full
report_timing -max_paths 20 > reports/pt_timing_$::env(CORNER).rpt
report_constraint -all_violators > reports/pt_viol_$::env(CORNER).rpt

read_fsdb -strip_path tb/dut $::env(FSDB)
# 1) 전체 구간 평균
update_power
report_power -hierarchy -levels 2 > reports/pwr_total_$::env(CORNER).rpt
report_power -domains            > reports/pwr_domain_$::env(CORNER).rpt
# 2) 활성 구간(추론 1회)과 딥슬립 구간을 각각 분석
foreach {name t0 t1} [list active $::env(WIN_ON_START) $::env(WIN_ON_END) sleep $::env(WIN_OFF_START) $::env(WIN_OFF_END)] {
    set_power_analysis_options -waveform_interval 1000 -include all_with_leaf
    read_fsdb -strip_path tb/dut -time [list $t0 $t1] $::env(FSDB)
    update_power
    report_power -hierarchy -levels 2 > reports/pwr_${name}_$::env(CORNER).rpt
    report_power -domains            > reports/pwr_${name}_domain_$::env(CORNER).rpt
}
exit
