#!/bin/bash
# Simulations of the A314 clockport interface (a314_cp), iverilog >= 12
#   ./run.sh            run all
set -e
cd "$(dirname "$0")"
S=../../src
O=/tmp/a314_sim; mkdir -p $O

echo "== a314_cp alone (register sequences of a314.device, CPLD irq semantics)"
iverilog -g2012 -o $O/cp.vvp tb_a314_cp.v $S/minimig-aga/a314_cp.v && vvp -n $O/cp.vvp | tail -2

echo "== real mcu_spi.v at bit level (19.2 MHz) + a314_host + a314_cp, 100 ns between bytes"
iverilog -g2012 -DENABLE_A314 -o $O/spi.vvp tb_spi_a314.v $S/misc/mcu_spi.v $S/misc/a314_host.v $S/minimig-aga/a314_cp.v && vvp -n $O/spi.vvp | grep -v finish | tail -5

echo "== same with 2 us between bytes (software SPI of the Companion)"
sed 's/integer sp_gap = 100;/integer sp_gap = 2000;/' tb_spi_a314.v > $O/tb_spi_a314.v
iverilog -g2012 -DENABLE_A314 -o $O/spi2u.vvp $O/tb_spi_a314.v $S/misc/mcu_spi.v $S/misc/a314_host.v $S/minimig-aga/a314_cp.v && vvp -n $O/spi2u.vvp | grep -v finish | tail -5

echo "== real gary.v + minimig_m68k_bridge.v + a314_cp (glue taken verbatim from minimig.v), 68000 and TG68K bus cycles"
python3 mkglue.py $S/minimig-aga/minimig.v $O/minimig_a314_glue.vh
iverilog -g2012 -DENABLE_A314 -I$O -o $O/bus.vvp tb_bus_a314.v \
  $S/minimig-aga/{amiga_clk,minimig_m68k_bridge,gary,a314_cp}.v && vvp -n $O/bus.vvp | grep -v finish | tail -2
