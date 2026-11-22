#!/bin/sh
# usage: ./sys_run.sh [FF_EN] [CHIP_PCT] [BURST] [SYNC_DLY]
cd "$(dirname "$0")"
iverilog -g2012 -DENABLE_FLICKER_FIXER -P sys_tb.FF_EN=${1:-1} -P sys_tb.CHIP_PCT=${2:-45} \
  -P sys_tb.BURST=${3:-0} -P sys_tb.SYNC_DLY=${4:-4} -o sys_$$.vvp sys_tb.v ../sdr_chip_model.v \
  ../../src/minimig/Amber.v ../../src/minimig/flickerfix.v ../../src/misc/sdram.sv && \
  vvp -n sys_$$.vvp | grep -v finish; rm -f sys_$$.vvp
