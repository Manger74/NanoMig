# Networking with the NanoMig 1200 (A314)

Please read [Networking](https://github.com/MiSTle-Dev/FPGA-Companion/tree/main/NETWORKING.md) first!

To use the Internet with the NanoMig a **Pi-Pico W** or **Pi-Pico2 W** is required as MCU.

The Amiga talks to the Companion over the A314 clockport interface at `$D80001` of the core  
(about 250 kB/s download). The Companion plays the Raspberry Pi of the A314, joins your WiFi,  
and your router does the NAT.

**Example addresses:**  
Router `192.168.0.254`  
Companion `192.168.0.33` (static or dhcp)  
Amiga `192.168.0.66`

The Amiga's address must be unused in your LAN.

### 1. Core and Companion

Both must be enabled for A314 networking.

### 2. Connect the Companion to your network by editing config.ini on the SD-Card

```
; network settings
[NETWORK]
MODE=manual          ; manual or dhcp
IP=192.168.0.33
MASK=255.255.255.0
GW=192.168.0.254
DNS=1.1.1.1          ; name server, only with MODE=manual

[WIFI]
SSID=MyWiFi
PASS=MyPassword
;POWERSAVE=0         ; WiFi power save off, shorter round trip times

[A314]
ENABLE=1
PEER=192.168.0.66    ; the Amiga's address, unused in your LAN
;TXQ=32              ; Pico2 W only: more frames queued for the Amiga (default 12)
;STATS=5             ; timing statistics every 5 s in the Companion log
```

`[PLIP]` stays off (`ENABLE=0` or no section).

### 3. Download and install Roadshow

The demo version is fully functional but has a time limit.

edit **DEVS:Internet/routes** in TextEdit

```
DEFAULT 192.168.0.254
```

edit **DEVS:Internet/name_resolution** in TextEdit

```
NAMESERVER 1.1.1.1
```

### 4. Amiga: A314 drivers

Download the A314 software release ([github.com/niklasekstrom/a314](https://github.com/niklasekstrom/a314/releases)).

copy **a314-cp.device** (the clockport variant) to **DEVS:** and rename it to **a314.device**  
copy **a314eth.device** to **DEVS:**

**DEVS:a314.config** is optional, these are the defaults of the clockport variant:

```
ClockportAddress=D80001
Interrupt=6
```

create **DEVS:NetInterfaces/A314Eth** in TextEdit

```
device=a314eth.device
address=192.168.0.66
netmask=255.255.255.0
#configure=dhcp
```

- **address** must equal **PEER** in **config.ini**.
- Do not use **configure=dhcp**, **#** comments it out

reboot the Amiga!

### 5. Ping

From the Amiga shell, in this order:

```
ping 192.168.0.33     ; the Companion
ping 192.168.0.254    ; your router
ping 1.1.1.1          ; the internet
```

If the first ping works and the others fail, check the gateway entry.  
From a PC, **ping 192.168.0.66** reaches the Amiga and **ping 192.168.0.33** the Companion

### 6. FTP and Telnet to the Companion

Use the Companion's LAN address **192.168.0.33**.  
Both work from the Amiga over A314 and from a PC on the LAN.  

**FTP** (port 21) gives access to the Companion's SD card.  
Any user name and password are accepted. Passive mode only:  
  ```
  ftp 192.168.0.33
  ```
**Telnet** (port 23) shows the Companion's log and debug output (with `STATS` also the A314 timing):
  ```
  telnet 192.168.0.33
  ```
