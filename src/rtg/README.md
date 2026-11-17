# RTG for the NanoMig 020 build (work in progress)

Picasso96 style graphics for the AGA build. The picture lives in fast RAM and is
scanned out through an additional read port of the SDRAM controller
(`../misc/sdram.sv`, `ENABLE_RTG`). While RTG is enabled the HDMI output runs
800x600@60, otherwise the native Amiga video is shown. No OSD over RTG yet.

Supported pictures: 8 bit palette, 16 bit RGB565 and RGB555, repeated up to 4x
horizontally and 3x vertically (400x300 is shown doubled), placed by a viewport
inside the 800x600 display. The register layout is the one of the MiSTle MiniMig
RTG core, so its P96 driver (adapted here, see below) works.

Build (from `src/`, Gowin IDE installed in `$HOME/gowin`):

    export PATH=$PATH:$HOME/gowin/IDE/bin
    export QT_QPA_PLATFORM=minimal
    gw_sh scripts/build_020_video.tcl rtg

Other variants: `vmodes` (video mode logic only, native video), `test800x600`,
`test720p` (test patterns), `rtgled` and `rtgdbg` (bring-up variants, see the
header of `scripts/build_020_video.tcl`).

1024x768 instead of 800x600 (build-time choice, define `VMODE_1024_RB` or
`VMODE_1024_VESA`, test patterns `test1024rb` and `test1024`):

| variant | timing | pixel clock | PLL |
|---|---|---|---|
| `VMODE_1024_RB` | 1184x802, CVT reduced blanking (+h/-v), 60.0 Hz | 57.00 MHz | x10, ODIV 2 |
| `VMODE_1024_VESA` | 1344x806, VESA DMT (-h/-v), 60.0 Hz | 64.98 MHz | x57 / IDIV 5, ODIV 2 |

RTG cores with 1024x768: `rtg1024rb` (recommended) and `rtg1024` (not recommended:
the core does not boot on the Tang Nano 20K, probably timing at 65 MHz on the full
device; the test pattern `test1024` works). Each needs its own driver:
`amiga/minimig_1024rb.card` or `amiga/minimig_1024.card`, copied to
`LIBS:Picasso96/minimig.card`. Picture modes up to 1024x768 (8 bit), 16 bit full
width only with little chipset load, 512x384 (2x2) in 16 bit is uncritical.

`sim/run_vmode.sh [VMODE_1024_RB|VMODE_1024_VESA]` checks the sync generator,
`sim/run_rtg.sh [VMODE_1024_RB|VMODE_1024_VESA]` the RTG chain on that raster.

## Registers (CPU window `$B80000`)

| offset      | function |
|-------------|----------|
| `$100/$102` | framebuffer byte address (long write, high word first, bits 3:0 ignored) |
| `$104`      | bit 15: 8 bit palette mode |
| `$106`      | 1: RGB565, 2: RGB555 |
| `$10c`      | status (read): bit 0 vblank, bit 2 row fetch overrun, bit 3 scanout active |
| `$10e`      | id `$8321` |
| `$110`      | bit 0: show RTG (switches HDMI to 800x600) instead of the native video |
| `$114`      | bits 1:0 horizontal repeat-1, bits 3:2 vertical repeat-1 |
| `$116`      | source stride in 16 byte units |
| `$118/$11a` | viewport horizontal start/stop in 16 pixel units (stop exclusive) |
| `$11c/$11e` | viewport vertical start/stop in 16 line units (stop exclusive) |
| `$120`      | visible source row length in 16 byte units |
| `$400-$7ff` | palette, 256 entries `$00RRGGBB`, written as two words (high first) |

Not implemented: the split screen / second framebuffer registers (`$08/$0A/$12`)
and the vblank interrupt (status bit 1 never gets set).

The framebuffer address is a CPU address in fast RAM (`$200000-$7FFFFF`), which is
the same byte address in the SDRAM. Stride and bytes per row must be multiples of
16. The configuration is taken over at the start of every vblank.

Bandwidth: one source row has to be fetched within one line time (two or three
with vertical repeat). In the simulation (`sim/tb_rtg.sv`, random chipset like load
on port 1) a row of 1024 bytes (1024 pixels 8 bit, 512 pixels 16 bit) per line holds
at 25 % load and overruns at 50 %; 800x600 16 bit with 3x vertical repeat holds at
50 %. The overrun bit in the status register shows lost rows.

## P96 driver

`amiga/minimig.card` is the MiSTle `minimig.card` (A. M. Robinson, LGPL 2.1)
with the NanoMig raster: 800x600, 1056x628 total, 39.9 MHz pixel clock, sync
40/128 and 1/4, and without the vblank interrupt flag. Source:
`amiga/minimig.card.asm`, build: `amiga/build_card.sh` (needs vasm, the NDK
includes and the P96 developer files from `mheyer32/p96drivers`, paths via
`NDK_INC` and `P96_INC`).

Installation (as for MiSTle):

1. Install Picasso96, in `DEVS:Monitors` rename the Picasso96 monitor to `Minimig`
   and set `BOARDTYPE=minimig` in the Picasso96 settings.
2. Copy `minimig.card` to `LIBS:Picasso96/`.
3. In Picasso96Mode create modes that fit into 800x600: 800x600 (the full
   viewport), 400x300 (2x2 repeat, up to 288 rows), 640x480 centered, ... in CLUT,
   RGB565 and RGB555.

The driver runs with Picasso96 2.x (rtg.library 40.x, Kickstart 3.0+) and 3.x. Screen
dragging (`SetSplitPosition`, `gbi_YSplit`) is only used by P96 3.x: the BoardInfo of
rtg.library 40.3993 is 1624 bytes, `gbi_YSplit` (offset 1636) lies behind it, so the
driver keeps the split row in its CardData and touches `gbi_YSplit` only when P96 3.x
calls `SetSplitPosition`. With the P96 2.0 installer choose any board and then change
`BOARDTYPE=uaegfx` to `BOARDTYPE=minimig` in the monitor icon.

`amiga/rtgdemo.asm` is a small test program that needs no Picasso96 (XOR pattern
400x300 in 8 bit, left mouse button ends).

## Simulation

`sim/run_sdram.sh` tests the SDRAM controller with the RTG port (pin level model),
`sim/run_rtg.sh` the whole chain register writes -> rtg_video -> SDRAM -> pixels
for four display configurations. Both need Verilator
(`VERILATOR=verilator-cli bash run_rtg.sh`).
