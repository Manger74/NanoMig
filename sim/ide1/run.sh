#!/bin/sh
# compare gayle with and without DISABLE_IDE1
cd "$(dirname "$0")"; S=../../src
for d in NONE DISABLE_IDE1; do
  iverilog -g2012 -DINFER_DPRAM -D$d -o tb_$d tb_ide1.v $S/minimig-aga/gayle.v $S/minimig-aga/ide.v || exit 1
  vvp -n tb_$d | grep -v VCD > trace_$d.txt
done
n=$(wc -l < trace_NONE.txt)
if cmp -s trace_NONE.txt trace_DISABLE_IDE1.txt; then echo "PASS ($n cycles identical)"; else diff trace_NONE.txt trace_DISABLE_IDE1.txt | head; echo FAIL; exit 1; fi
