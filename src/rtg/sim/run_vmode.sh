#!/bin/bash
# Sync generator check of the vidmode 2'b10 raster:
#   bash run_vmode.sh [VMODE_1024_RB|VMODE_1024_VESA]   (no argument: 800x600)
cd "$(dirname "$0")"
VERILATOR=${VERILATOR:-verilator}
D=${1:+-D$1}
H=../../hdmi
$VERILATOR --binary --timing -Wno-fatal -Wno-lint -Wno-style -DHDMI_VIDEO_MODES $D --top-module tb_vmode \
  -Mdir obj_vmode_${1:-800} tb_vmode.sv $H/hdmi.sv $H/packet_picker.sv $H/packet_assembler.sv \
  $H/audio_clock_regeneration_packet.sv $H/audio_info_frame.sv $H/audio_sample_packet.sv \
  $H/auxiliary_video_information_info_frame.sv $H/source_product_description_info_frame.sv \
  $H/tmds_channel.sv $H/serializer.sv > obj_vmode_${1:-800}.log 2>&1 || { tail -20 obj_vmode_${1:-800}.log; exit 1; }
./obj_vmode_${1:-800}/Vtb_vmode
