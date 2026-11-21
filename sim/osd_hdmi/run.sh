#!/bin/sh
# osd_hdmi tests (iverilog, python3)
set -e
cd "$(dirname "$0")"
S=../../src
W=$(mktemp -d)
iverilog -g2012 -o $W/tb tb_osd_hdmi.v $S/misc/osd_u8g2.v $S/misc/osd_hdmi.v
(cd $W && vvp -n tb >/dev/null)
(cd $W && python3 -I "$OLDPWD/compare.py" 720 576)
for g in "1056 628 800 600" "1650 750 1280 720"; do
    set -- $g
    iverilog -g2012 -Ptb_osd_hdmi.FRAME_W=$1 -Ptb_osd_hdmi.FRAME_H=$2 -Ptb_osd_hdmi.SCREEN_W=$3 \
             -Ptb_osd_hdmi.SCREEN_H=$4 -Ptb_osd_hdmi.RUN_REF=0 -o $W/tb tb_osd_hdmi.v $S/misc/osd_u8g2.v $S/misc/osd_hdmi.v
    echo "${3}x${4}:"; (cd $W && vvp -n tb >/dev/null && python3 -I "$OLDPWD/compare.py" $3 $4 noref)
done
iverilog -g2012 -DHDMI_OSD -o $W/tbi tb_hdmi_osd.sv $S/hdmi/hdmi.sv $S/hdmi/serializer.sv $S/hdmi/tmds_channel.sv $S/misc/osd_hdmi.v oser10_stub.v 2>/dev/null
vvp -n $W/tbi | head -1
rm -rf $W
