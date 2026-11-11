#!/bin/sh
# denise_sprites: sprite buffers in RAM16 vs block ram must give the same video
# 1) sprite data written by DMA, CPU/copper write POS/CTL during the line -> identical
# 2) +midline_data: CPU/copper also write DATA/DATB during the line -> counts the
#    known one-clock read-during-write difference (information, not a failure)
cd "$(dirname "$0")"; S=../../src/minimig-aga
iverilog -g2012 -DDENISE_EBR -o tb_sprite_bram tb_sprite_bram.v \
  $S/denise_sprites.v $S/denise_sprites_shifter.v $S/sprite_ram.v || exit 1
echo "== DMA data, POS/CTL during the line"
vvp -n tb_sprite_bram | grep -v "VCD info\|finish"; r=$?
echo "== also DATA/DATB during the line (information)"
vvp -n tb_sprite_bram +midline_data | grep -v "VCD info\|finish\|MISMATCH"
rm -f tb_sprite_bram
