# nanoport network card tests
#
#   make unit   - iverilog: nanoport.v + mcu_spi.v, cpu bus and SPI (back to back
#                 and with gaps between the bytes, 19.2 and 48 MHz)
#   make rom    - test rom for the full verilator simulation, run it with
#                 DEFINES += -DENABLE_NANOPORT in ../Makefile and
#                 KICK=nanoport/nanoport_test.bin AGA=1 FASTRAM=1 ../nanomig
#                 expected output: "SABCIDEFGH" followed by the timings

all: unit

unit:
	iverilog -g2012 -o tb_nanoport tb_nanoport.v ../../src/misc/mcu_spi.v ../../src/misc/nanoport.v
	vvp -n tb_nanoport
	iverilog -g2012 -o tb_b2b tb_b2b.v ../../src/misc/nanoport.v
	vvp -n tb_b2b

rom: nanoport_test.bin

nanoport_test.bin: ../test_rom/nanoport_test.s
	m68k-linux-gnu-as -m68020 --register-prefix-optional -o nanoport_test.o $<
	m68k-linux-gnu-ld -e 0xf80000 -Ttext=0xf80000 -o nanoport_test.elf nanoport_test.o
	m68k-linux-gnu-objcopy -O binary nanoport_test.elf $@
	truncate -s 262144 $@
	rm -f nanoport_test.o nanoport_test.elf

clean:
	rm -f tb_nanoport tb_b2b nanoport_test.bin
