# Setting up networking on the NanoMig (PPP over the serial port + Roadshow)

This tutorial shows how to get an Amiga running in the NanoMig core onto your WLAN, home network and the Internet via the **serial port**. The Companion (Pico W / Pico 2 W) acts as the PPP server, and the TCP/IP stack **Roadshow** runs on the Amiga.

Status: 2026-10-30

## Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Menu and configuration on the NanoMig](#3-menu-and-configuration-on-the-nanomig)
4. [What is Roadshow?](#4-what-is-roadshow)
5. [Downloading Roadshow](#5-downloading-roadshow)
6. [Installing and configuring Roadshow](#6-installing-and-configuring-roadshow)
7. [Establishing the connection](#7-establishing-the-connection)
8. [Testing the connection](#8-testing-the-connection)
9. [Troubleshooting](#9-troubleshooting)
10. [Limits and test status](#10-limits-and-test-status)

---

## 1. Overview

```mermaid
flowchart LR
    A["Amiga<br/>Roadshow + ppp-serial.device"] -- "serial.device<br/>(Paula UART, 8N1)" --> B["NanoMig core<br/>uart_port.v"]
    B -- "SPI, port 0" --> C["Companion<br/>Pico W / Pico 2 W<br/>PPP server + lwIP"]
    C -- "WLAN" --> D["Router / home network / Internet"]
```

- The Amiga's serial port is passed through the core to the Companion as a plain byte stream.
- The Companion accepts PPP there and forwards the packets to the WLAN.
- There is **no NAT in the Companion**. The Amiga appears on the home network as an ordinary host with a free LAN address (proxy ARP); your router does the NAT to the Internet.
- Data rate: at 115200 baud, at most about 10 KiB/s net (see [Limits](#10-limits-and-test-status)).

## 2. Prerequisites

| Component | Requirement |
|---|---|
| NanoMig core | Bitstream with the `Serial:` menu entry (`nanomig-serial-ppp.patch`, which only changes `amiga.xml`). The bitstream has to be rebuilt because the XML is embedded. Core variant with the AT modem port (`ENABLE_AT_MODEM`: Nano 20K, including the `_020` variant) |
| Companion firmware | Build with the PPP server (`companion-ppp-server.patch`, flag `ENABLE_PPP_SERVER`). Only for the boards `PICO`, `PICO2`, `MSP20K`, `MSP2_20K` (Pico W / Pico 2 W). On other boards (e.g. BL616) the menu entry has no effect |
| WLAN | The Companion is already connected to your WLAN (own address e.g. `192.168.1.33`) |
| Amiga | AmigaOS 2.0 or newer (Roadshow runs on AmigaOS 2 and up), Roadshow 1.15 |
| Recommendation | `_020` bitstream with CPU `68020`: the 68000 reaches its limit at 115200 baud (one interrupt per byte) |

> [!NOTE]
> The PPP server is a patch and not part of the standard firmware. Without it, the `PPP` operating mode does not exist.

## 3. Menu and configuration on the NanoMig

### 3.1 OSD menu

In the OSD menu under **Settings** there is the entry **`Serial:`** with two values:

| Value | Behavior | When to use |
|---|---|---|
| `AT modem` (default) | Port 0 is attached to the virtual modem. The Companion answers AT commands. `ATD*99#`, `ATDT*99…`, `ATDPPP` or `ATDTppp` returns `CONNECT` and switches to PPP. After the session ends, `NO CARRIER` is returned and AT mode is active again | Dialers with a chat script (init string, dial command), and terminal programs using the AT modem |
| `PPP` | No AT dialog. The server listens for PPP immediately and again after every session | **Simplest option** if the driver does not need to dial |

Afterwards choose **Save settings** in the menu so the value is stored in `amiga.ini`.

> [!TIP]
> Switching is possible during operation. A running PPP session is ended cleanly. After a hangup, AT mode takes about 3.5 s before it answers again.

### 3.2 `config.ini` on the SD card

Optional section for the addresses:

```ini
[ppp]
ip=192.168.253.1      ; Companion's address on the PPP link (default)
peer=192.168.1.50     ; Amiga's address (default 192.168.253.2)
```

There are two modes of operation:

| `peer=` | Result |
|---|---|
| not set (default `192.168.253.2`) | The Amiga reaches **only the Companion** (Telnet, FTP, echo on `192.168.253.1`). Good for a first test |
| a free address **in the LAN subnet** | Home network and Internet. The Companion answers ARP for this address (proxy ARP) and forwards packets between LAN and PPP |

For `peer=`:

- The address must be **free**: outside your router's DHCP range and not used by any other device, otherwise you get an address conflict.
- After startup, the Companion log must show `PPP: <peer> is reachable via …`. If that line is missing, your firmware does not accept the key (see [Troubleshooting](#9-troubleshooting)).
- An access point with **client isolation** blocks proxy ARP.

The Amiga receives its address and DNS server from the Companion via IPCP. There is no PPP authentication; any client is accepted.

## 4. What is Roadshow?

Roadshow is a **TCP/IP stack for the classic Amiga** (AmigaOS 2/3) by Olaf Barthel. It provides `bsdsocket.library` and is therefore compatible with programs that use the AmiTCP interface (e.g. IBrowse, AWeb, YAM).

- **No graphical user interface.** Everything is done with shell commands and text files (manual: `Roadshow.guide`).
- Includes drivers for PPP over serial lines (`ppp-serial.device`), which is the route this tutorial takes.
- Includes DHCP, a firewall and diagnostic commands (`ping`, `ShowNetStatus`, `GetNetStatus`, `AddNetRoute`, among others).
- Current version: **1.15** (February 2024).

## 5. Downloading Roadshow

The source is the manufacturer's site at APC&TCP:

**<http://roadshow.apc-tcp.de/index-en.php>**

- Roadshow is **commercial** (download version, around EUR 25 according to a third-party source; check the current price on the manufacturer's site). A CD-ROM and a USB medium are also available.
- A **demo version** is available on the manufacturer's site. It is limited to 15 minutes per start, which is enough to work through this tutorial.
- Updates within version 1.x are free for buyers; access is through the customer account of the shop where you bought it.

## 6. Installing and configuring Roadshow

### 6.1 Installation

1. Unpack the archive on the Amiga and install Roadshow following the installation instructions in the archive (manual `Roadshow.guide`).
2. Reboot so the stack starts at boot.

> [!NOTE]
> The following steps assume the directory structure of the Roadshow 1.15 archive (`Storage/NetInterfaces/PPP`, `S/PPP-Configurations/PPP-Example`).

### 6.2 Interface file for PPP

Copy `Storage/NetInterfaces/PPP` from the archive to `DEVS:NetInterfaces/PPP` **without changes** (`device=ppp-serial.device`):

```
Copy Storage/NetInterfaces/PPP DEVS:NetInterfaces/PPP
```

`DEVS:NetInterfaces/PPP` gets neither `LOCALADDRESS` nor `REMOTEADDRESS`. Address, peer and DNS come from the Companion via IPCP.

### 6.3 PPP configuration file

The connection is established with the program `ppp_dialer` and a file from `S:PPP-Configurations/`. The template `PPP-Example` is in the archive. The file must match the `Serial:` setting in the OSD.

#### Variant A: OSD `Serial: PPP` (no dialog)

`S:PPP-Configurations/Companion`:

```
interface=PPP
device=serial.device
speed=57600
nullmodem=yes
mtu=576
accm=0
pfc=on
aacfc=on
vjhc=off
```

#### Variant B: OSD `Serial: AT modem` (Companion answers `ATD`)

`S:PPP-Configurations/Companion-AT`:

```
interface=PPP
device=serial.device
speed=57600
rtscts=no
checkcarrier=yes
init=ATZ\r
dial=ATDPPP\r
mtu=576
accm=0
pfc=on
aacfc=on
vjhc=off
```

Notes:

| Line | Meaning |
|---|---|
| `speed=` | Baud rate. The core takes it from the Amiga software, so nothing needs to be set on the Companion. **Start with 57600**; 115200 is borderline (see [Limits](#10-limits-and-test-status)) |
| `nullmodem=yes` | No modem, no dialing (variant A) |
| `rtscts=no` | The core handles flow control itself and is lossless without RTS/CTS |
| `checkcarrier=yes` | Uncritical: the core permanently reports the carrier as present |
| `dial=ATDPPP\r` | The Companion also accepts `ATD*99#`, `ATDT*99…` and `ATDTppp`. With an asterisk, Roadshow files require the value in quotation marks with the asterisk doubled (`dial="ATD**99#\r"`); `ATDPPP\r` avoids that |
| `mtu=576` | Smaller packets, lower latency on the slow link |
| `accm=0`, `pfc=on`, `aacfc=on` | Header savings; default in Roadshow and requested by the Companion as well |
| `vjhc=off` | The Companion has no Van Jacobson compression; Roadshow would otherwise negotiate in vain |
| `login`/`password` | Leave empty, there is no authentication |

### 6.4 Routes and DNS

Usually nothing to do: according to the Roadshow manual, the PPP driver sets the route and DNS servers itself. If `ShowNetStatus` shows **no default route** after connecting:

- Manually, after `ppp_dialer`: `AddNetRoute DEFAULT 192.168.253.1` (the Companion's address on the PPP link, corresponding to `[ppp] ip=`).
- If DNS is missing: add a line `nameserver 192.168.1.254` (your router) in `DEVS:Internet/name_resolution`, and `prefer static` if needed.

## 7. Establishing the connection

1. **Beforehand:** close terminal programs (e.g. JRComm); the serial port is exclusive. In the NanoMig OSD, set `Serial:` to match the configuration file (variant A: `PPP`, variant B: `AT modem`).
2. Roadshow is running (reboot after installation) and the interface is registered:

   ```
   AddNetInterface PPP
   ```

3. Start the dialer:

   ```
   ppp_dialer S:PPP-Configurations/Companion
   ```

   (Variant B: `ppp_dialer S:PPP-Configurations/Companion-AT`)

4. The shell window stays occupied, and the connection remains up until you press **Ctrl-C**. Open a second shell window for further commands.
5. On the Companion (log), `PPP: up, our address …` appears; at the end, `PPP: down, error N`.

To end the connection: **Ctrl-C** in the dialer window. The Companion then switches back to AT mode (variant B) with `NO CARRIER`.

## 8. Testing the connection

Step by step, from the inside out:

| # | Command (Amiga shell) | Expected | What it checks |
|---|---|---|---|
| 1 | `GetNetStatus` / `ShowNetStatus` | Interface `PPP` online, address `192.168.253.2` (or your `peer=`), peer `192.168.253.1`, default route, DNS | PPP negotiation (IPCP) |
| 2 | `ping 192.168.253.1` | Replies | Amiga ↔ Companion link |
| 3 | `ftp 192.168.253.1` | Login prompt of the Companion FTP server | TCP over PPP |
| 4 | `ping 192.168.1.254` (your router) | Replies | Forwarding into the home network (only with `peer=` in the LAN subnet) |
| 5 | `ping 8.8.8.8` | Replies | Internet (router NAT) |
| 6 | `ping <hostname>` | Replies | DNS via IPCP |
| 7 | From the LAN: `ping <peer address>` | Replies | Proxy ARP and return direction |

Example values: Companion on the WLAN `192.168.1.33`, router `192.168.1.254`, `peer=192.168.1.50`. After that, use IBrowse, AWeb or YAM as on any other Amiga network.

> [!TIP]
> The Amiga becomes reachable from the Internet only with a port forward on the router to the peer address.

## 9. Troubleshooting

| Symptom | Possible cause and remedy |
|---|---|
| Dialer gives up after `dialtimeout` (60 s) | Variant B: no `CONNECT` arrived. OSD is set to `PPP` instead of `AT modem`, wrong `dial=` string or wrong baud rate. In the configuration set `logfile=RAM:ppp.log` and `log=lcp,ipcp` (`all` for raw frames) |
| Variant A: no connection | OSD is set to `AT modem`. Switch to `PPP` |
| Port busy | A terminal program or another driver holds `serial.device` |
| Only the Companion answers ping | `peer=` not set or not accepted. The Companion log must show `PPP: … is reachable via …`. If it is missing, the parser (`inifile.c`) does not know the key `PEER` (error `Ignoring unknown config entry`); update the firmware |
| Router/Internet unreachable despite `peer=` | Peer address not free (address conflict), not in the LAN subnet, access point with client isolation, no default route in Roadshow (`AddNetRoute DEFAULT …`) |
| Stalls and dropouts at 115200 baud | Go down to 57600 baud. A steady stream of `PPP: tx queue full, N frame(s) refused` in the Companion log points to a source that is too fast; a few lines when a connection starts are normal |
| AT does not answer right after hangup | AT mode takes about 3.5 s before it answers again |
| Client disappears without terminate | The session stays active for up to about 30 s (LCP echo), because the core signals neither DTR nor the end of carrier |

On the Amiga, `ShowNetStatus` shows the MTU actually negotiated; it should be 576.

## 10. Limits and test status

**Limits**

- **Throughput** at 115200 baud: about 10 KiB/s net, Companion → Amiga rather less. The upper limit is the Amiga (one interrupt per byte, Paula has only one data register), not the Companion or SPI. The window size for forwarded connections is limited to 4 segments (back-pressure on the slow link).
- **Baud rate:** 57600 baud was reliable in the field test, 115200 baud unstable. Whether the later changes (larger FIFOs in the core, window limiting) fix this on hardware is not confirmed here.
- One Amiga (one peer address), no IPv6, no NAT in the Companion.
- Packets with the DF bit that are larger than the PPP MTU are dropped without ICMP. For TCP, the MSS clamping prevents this; for other protocols it would be a black hole.
- No PPP authentication: fine on your own network, not intended for unknown clients.

**Test status**

| Area | Status |
|---|---|
| PPP server, AT mode, proxy ARP, forwarding, MTU/MSS | Host test with real lwIP 2.2.1, a simulated Amiga (lwIP PPP client) and a simulated LAN: all scenarios without errors |
| Hardware | The Amiga reached the Companion. The bug in reading `peer=` was found on the hardware and then fixed. FTP ran reliably at 57600 baud |
| Roadshow configurations in this tutorial | Derived from the manual and the example file (Roadshow 1.15), **not verified in every detail on hardware**. The chat strings your dialer sends may differ; adjust `init=`/`dial=` if so |
| Internet access | Depends on your router (NAT), the WLAN and the free peer address |

---

*Sources: Roadshow manual (`Roadshow.guide`, `roadshow.texi`) and `PPP-Example` from the Roadshow 1.15 archive, manufacturer's site <http://roadshow.apc-tcp.de/index-en.php>, project notes on the PPP tunnel Companion ↔ NanoMig.*
