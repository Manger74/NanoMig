#!/bin/bash
# Sync generator check of the vidmode 2'b10 raster (1024x768 reduced blanking):
#   bash run_vmode.sh
cd "$(dirname "$0")"
VERILATOR=${VERILATOR:-verilator}
H=../../hdmi
$VERILATOR --binary --timing -Wno-fatal -Wno-lint -Wno-style -DHDMI_VIDEO_MODES --top-module tb_vmode \
  -Mdir obj_vmode_1024 tb_vmode.sv $H/hdmi.sv $H/packet_picker.sv $H/packet_assembler.sv \
  $H/audio_clock_regeneration_packet.sv $H/audio_info_frame.sv $H/audio_sample_packet.sv \
  $H/auxiliary_video_information_info_frame.sv $H/source_product_description_info_frame.sv \
  $H/tmds_channel.sv $H/serializer.sv > obj_vmode_1024.log 2>&1 || { tail -20 obj_vmode_1024.log; exit 1; }
./obj_vmode_1024/Vtb_vmode
