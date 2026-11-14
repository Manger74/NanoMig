#!/bin/bash
# Full chain test: cpu register writes -> rtg_video -> sdram rtg port -> sdram model.
# Takes a few minutes (several complete 800x600 frames are rendered per test).
# Optional argument: VMODE_1024_RB or VMODE_1024_VESA for the 1024x768 raster.
set -e
# Verilator front end: "verilator", or "verilator-cli" when installed with pip
cd "$(dirname "$0")"
out=obj_rtg${1:+_$1}; rm -rf $out
${VERILATOR:-verilator} --binary --timing -Wno-fatal -Wno-lint -Wno-style --Mdir $out \
  -MAKEFLAGS CFG_CXXFLAGS_PCH_I=-include --top-module tb_rtg -DENABLE_RTG -DROWS=1 ${1:+-D$1} \
  ../../misc/sdram.sv sdram_model.sv ../rtg_video.sv tb_rtg.sv > $out.log 2>&1 || { tail -30 $out.log; exit 1; }
$out/Vtb_rtg | grep -E "^TEST|status|^--|TOTAL|row y|mismatch|rror|switch|FAIL"
