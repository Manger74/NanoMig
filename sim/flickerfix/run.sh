#!/bin/sh
# usage: ./run.sh [FF_EN] [SLOT_PCT] [LACE]
cd "$(dirname "$0")"
iverilog -g2012 -DENABLE_FLICKER_FIXER -P ff_tb.FF_EN=${1:-1} -P ff_tb.SLOT_PCT=${2:-60} -P ff_tb.LACE=${3:-1} \
  -o ff_tb_$$.vvp ff_tb.v ../../src/minimig/Amber.v ../../src/minimig/flickerfix.v && vvp -n ff_tb_$$.vvp | grep -v "finish\|bad:"; rm -f ff_tb_$$.vvp
