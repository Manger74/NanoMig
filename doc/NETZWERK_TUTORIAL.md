# Netzwerk am NanoMig einrichten (PPP über die serielle Schnittstelle + Roadshow)

Dieses Tutorial zeigt, wie ein Amiga im NanoMig-Core über die **serielle Schnittstelle** ins WLAN, Heimnetz und Internet kommt. Der Companion (Pico W / Pico 2 W) spielt dabei den PPP-Server, auf dem Amiga läuft der TCP/IP-Stack **Roadshow**.

Stand: 2026-10-30

## Inhalt

1. [Überblick](#1-überblick)
2. [Voraussetzungen](#2-voraussetzungen)
3. [Menü und Konfiguration am NanoMig](#3-menü-und-konfiguration-am-nanomig)
4. [Was ist Roadshow?](#4-was-ist-roadshow)
5. [Roadshow herunterladen](#5-roadshow-herunterladen)
6. [Roadshow installieren und konfigurieren](#6-roadshow-installieren-und-konfigurieren)
7. [Verbindung aufbauen](#7-verbindung-aufbauen)
8. [Verbindung testen](#8-verbindung-testen)
9. [Fehlersuche](#9-fehlersuche)
10. [Grenzen und Prüfstand](#10-grenzen-und-prüfstand)

---

## 1. Überblick

```mermaid
flowchart LR
    A["Amiga<br/>Roadshow + ppp-serial.device"] -- "serial.device<br/>(Paula-UART, 8N1)" --> B["NanoMig-Core<br/>uart_port.v"]
    B -- "SPI, Port 0" --> C["Companion<br/>Pico W / Pico 2 W<br/>PPP-Server + lwIP"]
    C -- "WLAN" --> D["Router / Heimnetz / Internet"]
```

- Die serielle Schnittstelle des Amiga wird im Core als reiner Byte-Strom zum Companion durchgereicht.
- Der Companion nimmt dort PPP an und leitet die Pakete ins WLAN weiter.
- Es gibt **kein NAT im Companion**. Der Amiga erscheint im Heimnetz als normaler Host mit einer freien LAN-Adresse (Proxy-ARP), das NAT ins Internet macht dein Router.
- Datenrate: bei 115200 Bd maximal etwa 10 KiB/s netto (siehe [Grenzen](#10-grenzen-und-prüfstand)).

## 2. Voraussetzungen

| Komponente | Anforderung |
|---|---|
| NanoMig-Core | Bitstream mit dem Menüeintrag `Serial:` (`nanomig-serial-ppp.patch`, ändert nur `amiga.xml`). Bitstream muss neu gebaut werden, weil die XML eingebettet ist. Core-Variante mit AT-Modem-Port (`ENABLE_AT_MODEM`: Nano 20K, auch die `_020`-Variante) |
| Companion-Firmware | Build mit PPP-Server (`companion-ppp-server.patch`, Flag `ENABLE_PPP_SERVER`). Nur für die Boards `PICO`, `PICO2`, `MSP20K`, `MSP2_20K` (Pico W / Pico 2 W). Auf anderen Boards (z. B. BL616) hat der Menüeintrag keine Wirkung |
| WLAN | Der Companion ist bereits mit deinem WLAN verbunden (eigene Adresse z. B. `192.168.1.33`) |
| Amiga | AmigaOS 2.0 oder neuer (Roadshow läuft ab AmigaOS 2), Roadshow 1.15 |
| Empfehlung | `_020`-Bitstream mit CPU `68020`: der 68000 stößt bei 115200 Bd an seine Grenze (ein Interrupt je Byte) |

> [!NOTE]
> Der PPP-Server ist ein Patch und kein Bestandteil der Standard-Firmware. Ohne ihn gibt es den Betriebsmodus `PPP` nicht.

## 3. Menü und Konfiguration am NanoMig

### 3.1 OSD-Menü

Im OSD-Menü unter **Settings** gibt es den Eintrag **`Serial:`** mit zwei Werten:

| Wert | Verhalten | Wann nehmen |
|---|---|---|
| `AT modem` (Standard) | Port 0 hängt am virtuellen Modem. Der Companion antwortet auf AT-Befehle. `ATD*99#`, `ATDT*99…`, `ATDPPP` oder `ATDTppp` liefert `CONNECT` und schaltet in PPP. Nach Sitzungsende kommt `NO CARRIER` und der AT-Modus ist wieder aktiv | Dialer mit Chat-Script (Init-String, Wählbefehl), außerdem Terminalprogramme mit AT-Modem |
| `PPP` | Kein AT-Dialog. Der Server lauscht sofort auf PPP und nach jeder Sitzung neu | **Einfachster Weg**, wenn der Treiber nicht wählen muss |

Danach im Menü **Save settings** wählen, damit der Wert in `amiga.ini` gespeichert wird.

> [!TIP]
> Das Umschalten ist im laufenden Betrieb möglich. Eine laufende PPP-Sitzung wird dabei sauber beendet. Nach einem Hangup braucht der AT-Modus rund 3,5 s, bis er wieder antwortet.

### 3.2 `config.ini` auf der SD-Karte

Optionaler Abschnitt für die Adressen:

```ini
[ppp]
ip=192.168.253.1      ; Adresse des Companion auf der PPP-Strecke (Standard)
peer=192.168.1.50     ; Adresse des Amiga (Standard 192.168.253.2)
```

Es gibt zwei Betriebsarten:

| `peer=` | Ergebnis |
|---|---|
| nicht gesetzt (Standard `192.168.253.2`) | Der Amiga erreicht **nur den Companion** (Telnet, FTP, Echo auf `192.168.253.1`). Gut für den ersten Test |
| freie Adresse **im LAN-Subnetz** | Heimnetz und Internet. Der Companion beantwortet ARP für diese Adresse (Proxy-ARP) und leitet Pakete zwischen LAN und PPP weiter |

Für `peer=` gilt:

- Die Adresse muss **frei** sein: außerhalb des DHCP-Bereichs deines Routers und von keinem anderen Gerät benutzt, sonst gibt es einen Adresskonflikt.
- Nach dem Start muss im Companion-Log `PPP: <peer> is reachable via …` erscheinen. Fehlt die Zeile, nimmt deine Firmware den Schlüssel nicht an (siehe [Fehlersuche](#9-fehlersuche)).
- Ein Access Point mit **Client-Isolation** blockiert Proxy-ARP.

DNS-Server und Adresse bekommt der Amiga per IPCP vom Companion. Eine PPP-Authentifizierung gibt es nicht, jeder Client wird akzeptiert.

## 4. Was ist Roadshow?

Roadshow ist ein **TCP/IP-Stack für den klassischen Amiga** (AmigaOS 2/3) von Olaf Barthel. Er stellt `bsdsocket.library` bereit und ist damit kompatibel zu Programmen, die die AmiTCP-Schnittstelle nutzen (z. B. IBrowse, AWeb, YAM).

- **Keine grafische Oberfläche.** Alles läuft über Shell-Befehle und Textdateien (Handbuch: `Roadshow.guide`).
- Enthält Treiber für PPP über serielle Leitungen (`ppp-serial.device`), das ist der Weg dieses Tutorials.
- Enthält DHCP, Firewall und Diagnosebefehle (`ping`, `ShowNetStatus`, `GetNetStatus`, `AddNetRoute` u. a.).
- Aktuelle Version: **1.15** (Februar 2024).

## 5. Roadshow herunterladen

Bezugsquelle ist die Herstellerseite von APC&TCP:

**<http://roadshow.apc-tcp.de/index-en.php>**

- Roadshow ist **kommerziell** (Download-Version, laut Drittquelle rund 25 EUR; aktuellen Preis auf der Herstellerseite prüfen). Zusätzlich gibt es CD-ROM und USB-Medium.
- Eine **Demoversion** ist auf der Herstellerseite erhältlich. Sie ist auf 15 Minuten Laufzeit je Start begrenzt und reicht, um dieses Tutorial durchzuspielen.
- Updates innerhalb der Version 1.x sind für Käufer kostenlos, den Zugang gibt es über das Kundenkonto des Shops, in dem gekauft wurde.

## 6. Roadshow installieren und konfigurieren

### 6.1 Installation

1. Archiv auf dem Amiga entpacken und Roadshow mit der Installationsanleitung im Archiv installieren (Handbuch `Roadshow.guide`).
2. Neu starten, damit der Stack mitstartet.

> [!NOTE]
> Die weiteren Schritte setzen die Verzeichnisstruktur des Roadshow-1.15-Archivs voraus (`Storage/NetInterfaces/PPP`, `S/PPP-Configurations/PPP-Example`).

### 6.2 Interface-Datei für PPP

`Storage/NetInterfaces/PPP` aus dem Archiv nach `DEVS:NetInterfaces/PPP` kopieren, **ohne Änderung** (`device=ppp-serial.device`):

```
Copy Storage/NetInterfaces/PPP DEVS:NetInterfaces/PPP
```

`DEVS:NetInterfaces/PPP` bekommt weder `LOCALADDRESS` noch `REMOTEADDRESS`. Adresse, Gegenstelle und DNS kommen per IPCP vom Companion.

### 6.3 PPP-Konfigurationsdatei

Die Verbindung wird mit dem Programm `ppp_dialer` und einer Datei aus `S:PPP-Configurations/` aufgebaut. Die Vorlage `PPP-Example` liegt im Archiv. Die Datei muss zur Einstellung `Serial:` im OSD passen.

#### Variante A: OSD `Serial: PPP` (ohne Dialog)

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

#### Variante B: OSD `Serial: AT modem` (Companion antwortet auf `ATD`)

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

Erläuterungen:

| Zeile | Bedeutung |
|---|---|
| `speed=` | Baudrate. Der Core übernimmt sie von der Amiga-Software, am Companion ist nichts einzustellen. **Starte mit 57600**, 115200 ist grenzwertig (siehe [Grenzen](#10-grenzen-und-prüfstand)) |
| `nullmodem=yes` | Kein Modem, kein Wählen (Variante A) |
| `rtscts=no` | Flusskontrolle macht der Core selbst, ohne RTS/CTS verlustfrei |
| `checkcarrier=yes` | unkritisch: der Core meldet den Träger fest als vorhanden |
| `dial=ATDPPP\r` | Der Companion akzeptiert auch `ATD*99#`, `ATDT*99…` und `ATDTppp`. Mit Stern müssen Roadshow-Dateien den Wert in Anführungszeichen setzen und den Stern verdoppeln (`dial="ATD**99#\r"`), `ATDPPP\r` vermeidet das |
| `mtu=576` | kleinere Pakete, kürzere Latenz auf der langsamen Leitung |
| `accm=0`, `pfc=on`, `aacfc=on` | Header-Einsparungen, in Roadshow Standard und vom Companion ebenso angefordert |
| `vjhc=off` | Der Companion hat keine Van-Jacobson-Kompression, Roadshow würde sonst vergeblich verhandeln |
| `login`/`password` | leer lassen, es gibt keine Authentifizierung |

### 6.4 Routen und DNS

In der Regel nichts zu tun: Laut Roadshow-Handbuch setzt der PPP-Treiber Route und DNS-Server selbst. Falls `ShowNetStatus` nach dem Verbinden **keine Default-Route** zeigt:

- Manuell nach `ppp_dialer`: `AddNetRoute DEFAULT 192.168.253.1` (Adresse des Companion auf der PPP-Strecke, entspricht `[ppp] ip=`).
- DNS fehlt: in `DEVS:Internet/name_resolution` eine Zeile `nameserver 192.168.1.254` (Router) eintragen, bei Bedarf `prefer static`.

## 7. Verbindung aufbauen

1. **Vorher klären:** Terminalprogramme (z. B. JRComm) schließen, der serielle Port ist exklusiv. Im NanoMig-OSD `Serial:` passend zur Konfigurationsdatei einstellen (Variante A: `PPP`, Variante B: `AT modem`).
2. Roadshow läuft (Neustart nach der Installation) und das Interface wird angemeldet:

   ```
   AddNetInterface PPP
   ```

3. Dialer starten:

   ```
   ppp_dialer S:PPP-Configurations/Companion
   ```

   (Variante B: `ppp_dialer S:PPP-Configurations/Companion-AT`)

4. Das Shell-Fenster bleibt belegt, die Verbindung steht, bis du **Strg-C** drückst. Für weitere Befehle ein zweites Shell-Fenster öffnen.
5. Auf dem Companion (Log) erscheint `PPP: up, our address …`, beim Ende `PPP: down, error N`.

Zum Beenden: **Strg-C** im Dialer-Fenster. Der Companion schaltet dann (Variante B) mit `NO CARRIER` zurück in den AT-Modus.

## 8. Verbindung testen

Schrittweise von innen nach außen:

| # | Befehl (Amiga-Shell) | Erwartung | Was es prüft |
|---|---|---|---|
| 1 | `GetNetStatus` / `ShowNetStatus` | Interface `PPP` online, Adresse `192.168.253.2` (oder dein `peer=`), Gegenstelle `192.168.253.1`, Default-Route, DNS | PPP-Aushandlung (IPCP) |
| 2 | `ping 192.168.253.1` | Antworten | Strecke Amiga ↔ Companion |
| 3 | `ftp 192.168.253.1` | Login-Prompt des Companion-FTP-Servers | TCP über PPP |
| 4 | `ping 192.168.1.254` (dein Router) | Antworten | Weiterleitung ins Heimnetz (nur mit `peer=` im LAN-Subnetz) |
| 5 | `ping 8.8.8.8` | Antworten | Internet (Router-NAT) |
| 6 | `ping <hostname>` | Antworten | DNS über IPCP |
| 7 | Aus dem LAN: `ping <peer-Adresse>` | Antworten | Proxy-ARP und Rückrichtung |

Beispielwerte: Companion im WLAN `192.168.1.33`, Router `192.168.1.254`, `peer=192.168.1.50`. Danach IBrowse, AWeb oder YAM wie an jedem anderen Amiga-Netz benutzen.

> [!TIP]
> Aus dem Internet erreichbar wird der Amiga nur mit einer Portfreigabe am Router auf die Peer-Adresse.

## 9. Fehlersuche

| Symptom | Mögliche Ursache und Abhilfe |
|---|---|
| Dialer gibt nach `dialtimeout` (60 s) auf | Variante B: kein `CONNECT` angekommen. OSD steht auf `PPP` statt `AT modem`, falscher `dial=`-String oder falsche Baudrate. In der Konfiguration `logfile=RAM:ppp.log` und `log=lcp,ipcp` setzen (`all` für Rohframes) |
| Variante A: keine Verbindung | OSD steht auf `AT modem`. Auf `PPP` umstellen |
| Port belegt | Terminalprogramm oder anderer Treiber hält `serial.device` |
| Nur der Companion ist pingbar | `peer=` nicht gesetzt oder nicht angenommen. Im Companion-Log muss `PPP: … is reachable via …` stehen. Fehlt es, kennt der Parser (`inifile.c`) den Schlüssel `PEER` nicht (Fehler `Ignoring unknown config entry`), Firmware aktualisieren |
| Router/Internet nicht erreichbar trotz `peer=` | Peer-Adresse nicht frei (Adresskonflikt), nicht im LAN-Subnetz, Access Point mit Client-Isolation, keine Default-Route im Roadshow (`AddNetRoute DEFAULT …`) |
| Hänger und Abbrüche bei 115200 Bd | Auf 57600 Bd gehen. Im Companion-Log `PPP: tx queue full, N frame(s) refused` im Dauerfeuer deutet auf zu schnelle Quelle hin, einzelne Zeilen beim Verbindungsstart sind normal |
| Nach Hangup antwortet AT zunächst nicht | Der AT-Modus braucht ca. 3,5 s, bis er wieder antwortet |
| Client verschwindet ohne Terminate | Die Sitzung bleibt bis ca. 30 s aktiv (LCP-Echo), weil der Core weder DTR noch Carrier-Ende signalisiert |

Auf dem Amiga zeigt `ShowNetStatus` die tatsächlich ausgehandelte MTU, sie sollte 576 sein.

## 10. Grenzen und Prüfstand

**Grenzen**

- **Durchsatz** bei 115200 Bd: etwa 10 KiB/s netto, Companion → Amiga eher weniger. Die Obergrenze ist der Amiga (ein Interrupt je Byte, Paula hat nur ein Datenregister), nicht Companion oder SPI. Die Fenstergröße für weitergeleitete Verbindungen ist auf 4 Segmente begrenzt (Gegendruck auf der langsamen Strecke).
- **Baudrate:** 57600 Bd war im Feldtest zuverlässig, 115200 Bd instabil. Ob die späteren Änderungen (größere FIFOs im Core, Fensterbegrenzung) das auf Hardware beheben, ist hier nicht bestätigt.
- Ein Amiga (eine Peer-Adresse), kein IPv6, kein NAT im Companion.
- Pakete mit DF-Bit, die größer als die PPP-MTU sind, werden ohne ICMP verworfen. Für TCP verhindert das die MSS-Begrenzung, für andere Protokolle wäre es ein Blackhole.
- Keine PPP-Authentifizierung: im eigenen Netz in Ordnung, nicht für unbekannte Clients gedacht.

**Prüfstand**

| Bereich | Stand |
|---|---|
| PPP-Server, AT-Modus, Proxy-ARP, Weiterleitung, MTU/MSS | Host-Test mit echtem lwIP 2.2.1, simuliertem Amiga (lwIP-PPP-Client) und simuliertem LAN: alle Szenarien ohne Fehler |
| Hardware | Der Amiga erreichte den Companion. Der Fehler beim Einlesen von `peer=` wurde auf der Hardware gefunden und danach behoben. FTP lief bei 57600 Bd zuverlässig |
| Roadshow-Konfigurationen in diesem Tutorial | aus Handbuch und Beispieldatei (Roadshow 1.15) abgeleitet, **nicht in jedem Detail auf Hardware geprüft**. Welche Chat-Strings dein Dialer sendet, kann abweichen, dann `init=`/`dial=` anpassen |
| Internetzugang | Funktion hängt von deinem Router (NAT), WLAN und der freien Peer-Adresse ab |

---

*Quellen: Roadshow-Handbuch (`Roadshow.guide`, `roadshow.texi`) und `PPP-Example` aus dem Roadshow-1.15-Archiv, Herstellerseite <http://roadshow.apc-tcp.de/index-en.php>, Projektnotizen zum PPP-Tunnel Companion ↔ NanoMig.*
