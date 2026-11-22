# nanoport - network card for the NanoMig

nanoport gives the NanoMig a SANA-II network interface. The Amiga gets
its own IP address in the local network (static or via DHCP); the
router does the NAT as for any other device. The frames are moved
between the core and the FPGA Companion via SPI. The Companion
bridges them into its own network, i.e. WiFi (Pico W / Pico 2 W) or a
USB ethernet adapter (ASIX).

```
 Roadshow/AmiTCP ── nanoport.device ── Zorro II card (BSRAM) ══SPI══ FPGA Companion ── WiFi / USB ethernet ── router
```

Currently enabled in the 68020 build (`tang/nano20k/top_020.sv`,
`ENABLE_NANOPORT`). The card needs the TG68K (it sits on the fast CPU
path, not on the chip bus); the CPU type in the OSD can still be
68000, 68010 or 68020.

## Installation

1. Flash the core built from `top_020.sv` and a FPGA Companion
   firmware with nanoport support (branch `NANO_PORT`).
2. Copy `nanoport.device` (built from `amiga/nanoport`, see below) to
   `DEVS:Networks/`.
3. Roadshow: create `DEVS:NetInterfaces/nanoport`:

   ```
   device=DEVS:Networks/nanoport.device
   unit=0
   configure=dhcp
   ```

   For a static address replace `configure=dhcp` with
   `address=192.168.0.50` and `netmask=255.255.255.0` and set the
   default route and the name server as described in the Roadshow
   documentation (`DEVS:Internet/routes`, `DEVS:Internet/name_resolution`).
4. `AddNetInterface nanoport` (or reboot if the interface is in
   `DEVS:NetInterfaces` and Roadshow starts it automatically).

The Companion prints `NET: attached to ...`, `NET: Amiga online` and
`NET: Amiga IP is ...` on its debug console (telnet) once the Amiga
talks to the network.

## How it works

### Core (`src/misc/nanoport.v`)

The card is a Zorro II I/O board (manufacturer 2011/$07DB, product
$4E, 64 KiB). It is configured before the Fast RAM board in
`cpu_wrapper.v`. Accesses are served on the fast TG68K path with two
clk28 cycles per word, the Amiga reads about 10 MB/s from the card
(chip RAM: about 3 MB/s, measured in the simulation).

| Offset | Access | Content |
|--------|--------|---------|
| `$0000-$7FFF` | R | RX slots, 2 KiB each (4) |
| `$8000-$BFFF` | W | TX slots, 2 KiB each (2), byte writes allowed |
| `$C000` | R | ID `$4E50` |
| `$C002` | R | STATUS: [15] link, [14] online, [7:4] free TX slots, [3:0] pending RX frames |
| `$C004` | R | PTRS: [7:4] TX tail slot, [3:0] RX head slot |
| `$C006` | W | RXACK: release the RX head slot |
| `$C008` | W | TXGO: hand the TX tail slot to the Companion |
| `$C00A` | RW | INTENA: [0] INT2 while RX frames are pending, [1] INT2 while TX slots are free |
| `$C00C` | RW | CTRL: [0] online, [1] promiscuous, writing [7]=1 empties both rings |
| `$C010-$C014` | R | default station address (set by the Companion) |
| `$C016` | R | VERSION: [15:12] log2 RX slots, [11:8] log2 TX slots, [7:0] 1 |

Slot format: word 0 is the frame length in bytes, the frame follows
from offset 2 on, so the ethernet payload is long word aligned at
offset 16.

The card uses 6 BSRAM blocks (4 RX + 2 TX slots). The slot counts are
parameters of the module (`RX_BITS`, `TX_BITS`); the driver reads them
from the VERSION register.

### SPI (target 5)

| Sub command | Bytes | Meaning |
|---|---|---|
| 0 STATUS | reply one byte delayed: `$A0`\|flags, rx free\|rx tail<<4, tx pending\|tx head<<4, CTRL | flags: [0] online, [1] promisc, [2] tx pending, [3] rx full |
| 1 RX_PUT | len hi, len lo, frame | written into the next RX slot, committed with the last byte |
| 2 TX_GET | reply without delay: len hi, len lo, frame | TX head slot |
| 3 TX_DONE | - | release the TX head slot |
| 4 INFO | flags ([0] link), MAC[6] | default station address for the driver |

TX_GET is served entirely in the SPI clock domain (`mcu_spi.v`), so the
Companion can read a frame with back to back bytes. The usual reply
path of the other targets only works with gaps between the bytes.
At 19.2 MHz SPI a full frame takes about 0.65 ms. The Companion is
interrupted (sysctrl irq 5) when the Amiga queued a frame, changed
CTRL or freed a slot of a full RX ring.

### FPGA Companion (`src/nanoport.c`)

A WiFi client may only send frames with its own MAC address, so the
Amiga uses a virtual MAC (the Companion's MAC with the locally
administered bit) and the Companion translates:

- Amiga to network: source MAC and ARP sender MAC are replaced, DHCP
  requests get the broadcast flag (the lease stays bound to the
  Amiga's MAC in the DHCP payload).
- network to Amiga: broadcasts and multicasts go to both, unicast
  IPv4/ARP for the Amiga's IP (learned from its frames) and DHCP
  replies for its MAC only to the Amiga.
- Amiga and Companion talk to each other locally (e.g. FTP or telnet
  to the Companion from the Amiga).

The same translation is used with USB ethernet. Only IPv4 and ARP are
bridged.

### Driver (`amiga/nanoport`)

- Writes are copied into a free TX slot directly in the caller's
  context, there is no task switch per packet. Only when both slots are
  busy, writes are queued and sent from the unit task on the TX
  interrupt.
- Received frames are copied once, from the card into the stack's
  buffer: with the SANA-II R4 DMA hooks of the stack via a MOVEM loop,
  otherwise via CopyToBuff().
- The INT2 server only masks the card interrupt and signals the unit
  task. The task processes all pending frames before it unmasks the
  interrupt, so a burst of frames causes a single interrupt.
- BeginIO() may also be called from a software interrupt of the stack.
  Request lists and the TX slots are therefore guarded with Disable()
  (a busy flag for the slots), not with Forbid() or a semaphore.
- Diagnostic builds: `make nanoport_poll.device` (no INT2, the unit task
  polls the card every 2 ms via timer.device), `-DNP_NO_DMA` (without the
  DMA hooks of the stack). `nptest` checks the card without driver and
  stack (`nptest` register test, `nptest PING <own ip> <target ip>`
  ping flood with checked replies).

Build with vbcc: `build.bat` (Windows, kusma/amiga-dev) or `make` in
`amiga/nanoport` (Linux, vbcc of the AmigaPorts m68k-amigaos-gcc package
with its `bin/` in the PATH).
`make test` runs a host test of the driver logic (m68k-linux-gnu-gcc
and qemu-m68k, exec and the card are mocked).

## Tests

- `sim/nanoport`: `make unit` simulates the card and the SPI side with
  iverilog (back to back SPI at 19.2 and 48 MHz and with gaps, ring reset
  in the same cycle as an MCU pointer update).
- `sim/test_rom/nanoport_test.s`: test ROM for the verilator simulation
  of the whole core (autoconfig chain with Fast RAM, registers, TX
  rings, INT2 via PORTS, read speed), see `sim/nanoport/Makefile`.

## Limits

- Real hardware: `nptest PING` ran about 700 MB without a corrupted
  frame. Crashes under heavy load with Roadshow are being investigated.
- 68020 build only for now, the 68000 build (FX68K) has no fast path.
- IPv4/ARP only, no IPv6.
- Throughput is limited by WiFi and SPI (about 2 MB/s raw at 19.2 MHz,
  shared with the SD card and OSD traffic).
