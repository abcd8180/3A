#!/bin/sh
# 사용법: ./run_sim.sh   (Icarus Verilog 12+ 필요)
set -e
cd "$(dirname "$0")"
python3 sw/gen_firmware.py .
iverilog -g2012 -o sim.vvp tb/tb_ulp_soc.v rtl/*.v
vvp -n sim.vvp
