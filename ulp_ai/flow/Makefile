# ulp_ai Synopsys 흐름. 저장소의 ulp_ai/ 에서: make -f flow/Makefile <타깃>
HF_MHZ ?= 1
CORNER ?= tt
export HF_MHZ CORNER
RTL := rtl/rv32e_core.v rtl/nn_accel.v rtl/aon_ctrl.v rtl/icg.v rtl/sram.v rtl/ulp_soc.v
dirs:  ; mkdir -p logs reports out
fw:    ; python3 sw/gen_firmware.py .
rtl_sim: dirs fw
	vcs -full64 -sverilog -kdb -lca -debug_access+all -timescale=1ns/1ps \
	    +define+DUMP_FSDB tb/tb_ulp_soc.v $(RTL) -o out/simv_rtl -l logs/vcs_rtl.log
	./out/simv_rtl -l logs/sim_rtl.log
syn: dirs
	dc_shell -f flow/scripts/syn_dc.tcl | tee logs/syn.log
gls: dirs fw
	vcs -full64 -sverilog -kdb -lca -debug_access+all -timescale=1ns/1ps \
	    +define+DUMP_FSDB +neg_tchk -sdf max:tb.dut:out/ulp_soc.syn.sdf \
	    -upf out/ulp_soc.syn.upf \
	    tb/tb_ulp_soc.v out/ulp_soc.syn.v $(STDCELL_VERILOG) -o out/simv_gls -l logs/vcs_gls.log
	./out/simv_gls -l logs/sim_gls.log
pt: dirs
	pt_shell -f flow/scripts/pt_power.tcl | tee logs/pt_$(CORNER).log
