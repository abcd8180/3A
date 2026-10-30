# syn_dc.tcl — Design Compiler (Topographical 가능) 합성 템플릿
# 사용: dc_shell -f flow/scripts/syn_dc.tcl | tee logs/syn.log
source flow/scripts/lib_setup.tcl            ;# 라이브러리 경로 (서버에서 작성)
set_app_var hdlin_enable_upf_compatible_naming true
set RTL [list rtl/rv32e_core.v rtl/nn_accel.v rtl/aon_ctrl.v rtl/icg_lib.v rtl/sram_macro.v rtl/ulp_soc.v]
analyze -format verilog $RTL
elaborate ulp_soc
current_design ulp_soc
link
load_upf flow/upf/ulp_soc.upf
source flow/constraints/ulp_soc.sdc
set_operating_conditions $::env(CORNER_SYN)
set_leakage_optimization true
set_dynamic_optimization true
set_clock_gating_style -sequential_cell latch -positive_edge_logic {integrated} -control_point before
compile_ultra -gate_clock -no_autoungroup
check_mv_design -verbose > reports/check_mv.rpt
report_qor            > reports/qor.rpt
report_timing -max_paths 20 > reports/timing_syn.rpt
report_area -hier     > reports/area.rpt
report_power -hier    > reports/power_syn_est.rpt
report_clock_gating   > reports/clock_gating.rpt
change_names -rules verilog -hierarchy
write -format verilog -hierarchy -output out/ulp_soc.syn.v
write_sdc  out/ulp_soc.syn.sdc
write_sdf  out/ulp_soc.syn.sdf
save_upf   out/ulp_soc.syn.upf
exit
