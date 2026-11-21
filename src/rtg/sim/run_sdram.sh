#!/bin/bash
# Random traffic regression of the sdram controller (needs Verilator >= 5, e.g. pip install verilator)
# Checks all ports against a reference memory, the sdram model also flags protocol violations.
set -e
# Verilator front end: "verilator", or "verilator-cli" when installed with pip
cd "$(dirname "$0")"
run() {  # name, rtg rate (percent of idle cycles in which the rtg client requests a burst)
  out=obj_sdram_$1; rm -rf $out
  ${VERILATOR:-verilator} --binary --timing -Wno-fatal -Wno-lint -Wno-style --Mdir $out \
    -MAKEFLAGS CFG_CXXFLAGS_PCH_I=-include --top-module tb_sdram \
    -DENABLE_RTG -DRTG -DP1_RATE=60 -DP2_RATE=50 -DRTG_RATE=$2 -DRUN_SLOTS=20000 \
    ../../misc/sdram.sv sdram_model.sv tb_sdram.sv > $out.log 2>&1 || { tail -30 $out.log; exit 1; }
  echo "--- rtg client rate $2%"; $out/Vtb_sdram | grep -E "RESULT|RTG|rror"
}
run idle 0
run low 5
run mid 30
run max 100
