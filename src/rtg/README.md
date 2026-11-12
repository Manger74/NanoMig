# RTG for the NanoMig 020 build (work in progress)

Lean first stage: 8 bit palette pictures of 400x300 pixels, shown doubled on the
800x600@60 HDMI mode. The picture lives in fast RAM and is scanned out through an
additional read port of the SDRAM controller (`../misc/sdram.sv`, `ENABLE_RTG`).
No OSD and no 16 bit modes yet, the register layout is the one of the MiSTle
MiniMig RTG driver so that it can be extended later.

Build (from `src/`):

    gw_sh scripts/build_020_video.tcl rtg

Other variants: `vmodes` (video mode logic only, native video), `test800x600`,
`test720p` (test patterns), `rtgled` and `rtgdbg` (bring-up variants, see the
header of `scripts/build_020_video.tcl`).

## Registers (CPU window `$B80000`)

| offset     | function |
|------------|----------|
| `$100/$102`| framebuffer byte address (long write, high word first, bits 3:0 ignored) |
| `$10c`     | status: bit 0 vblank, bit 2 row fetch overrun |
| `$10e`     | id `$8321` |
| `$110`     | bit 0: show RTG (switches HDMI to 800x600) instead of the native video |
| `$400-$7ff`| palette, 256 entries `$00RRGGBB`, written as two words (high first) |

Writes to the other registers of the MiSTle layout are ignored.

The framebuffer address is a CPU address in fast RAM (`$200000-$5FFFFF`), which is
the same byte address in the SDRAM. 400 bytes per row, rows follow each other
without gap.

`amiga/rtgdemo.asm` is a small test program (XOR pattern, left mouse button ends).

## Simulation

`sim/run_sdram.sh` tests the SDRAM controller with the RTG port (pin level model),
`sim/run_rtg.sh` the whole chain register writes -> rtg_video -> SDRAM -> pixels.
Both need Verilator (`VERILATOR=verilator-cli bash run_rtg.sh`).
