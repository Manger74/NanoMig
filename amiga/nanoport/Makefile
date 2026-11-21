# nanoport.device
#
# Amiga build (vbcc of the AmigaPorts m68k-amigaos-gcc package, bin/ in the PATH):  make
# host test (m68k-linux-gnu-gcc + qemu-m68k, exec and the card are mocked):  make test VBCC=...

VC      ?= vc
VCCFG   ?= $(dir $(shell which $(VC)))vc.config
NDK     ?= $(VBCC)/ndk/include_h
NETINC  ?= $(VBCC)/netinclude

# amiga.lib: library call stubs, the NDK 3.2 protos have no vbcc inlines
nanoport.device: nanoport_asm.s nanoport.c nanoport.h
	$(VC) +$(VCCFG) -cpu=68000 -O2 -nostdlib -o $@ nanoport_asm.s nanoport.c -lvc -lamiga

# diagnostic build: no INT2, the unit task polls the card every 2 ms
nanoport_poll.device: nanoport_asm.s nanoport.c nanoport.h
	$(VC) +$(VCCFG) -cpu=68000 -O2 -nostdlib -DNP_POLL=2000 -o $@ nanoport_asm.s nanoport.c -lvc -lamiga

nptest: nptest.c nanoport.h
	$(VC) +$(VCCFG) -cpu=68020 -O2 -o $@ nptest.c -lamiga

test: test/test_nanoport.c nanoport.c nanoport.h
	m68k-linux-gnu-gcc -m68000 -O1 -std=gnu99 -static '-D__reg(x)=' -Wno-pointer-sign \
	  -Itest/shim -I. -I$(NETINC) -I$(NDK) test/test_nanoport.c -o test/test_nanoport
	qemu-m68k test/test_nanoport

clean:
	rm -f nanoport.device nanoport_poll.device nptest test/test_nanoport

.PHONY: test clean
