#!/bin/sh
# vreset after the return from an extended video mode, with (FIX=1) and without (FIX=0) the
# resync logic of top_020.sv; without it "vreset after the return to the native mode" fails
cd "$(dirname "$0")"
for f in 1 0; do
  iverilog -g2012 -P tb.FIX=$f -o tb_resync.vvp tb_resync.v ../../misc/video_analyzer.v && vvp -n tb_resync.vvp | grep -v finish
done
rm -f tb_resync.vvp
