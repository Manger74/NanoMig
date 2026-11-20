/*
 * nptest.c - stress test of the nanoport card without network traffic
 *
 * Hammers the card with the same kind of accesses as the driver (MOVEM
 * reads from the RX slots, writes to a TX slot, register reads) and checks
 * the registers that must not change. Stop the network first (no
 * nanoport.device in use). Ends with Ctrl-C.
 *
 *   nptest            card accesses only
 *   nptest ONLINE     also sets the card online and acknowledges received
 *                     frames, so the Companion moves (broadcast) frames
 *                     over SPI at the same time
 *   nptest PING <own ip> <target ip>
 *                     ping flood with 1400 byte payload to a host in the
 *                     LAN, every reply is checked byte by byte. Loads the
 *                     whole path (card, SPI, Companion, network) without
 *                     driver, interrupts and TCP/IP stack.
 */

#include <exec/types.h>
#include <dos/dos.h>
#include <libraries/configvars.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/expansion.h>
#include <string.h>

#include "nanoport.h"

struct ExpansionBase *ExpansionBase;

#define REG(o) (*(volatile UWORD *)(hw + (o)))

/* MOVEM block copies like the driver's np_copy */
static void rd_block(__reg("a0") volatile UBYTE *src, __reg("d0") ULONG n) =
  "\tmovem.l\td2-d7/a2-a5,-(a7)\n"
  "\tlsr.l\t#5,d0\n"
  "\tsubq.l\t#1,d0\n"
  ".rd:\tmovem.l\t(a0)+,d1-d7/a1\n"
  "\tdbra\td0,.rd\n"
  "\tmovem.l\t(a7)+,d2-d7/a2-a5";

static void wr_block(__reg("a0") volatile UBYTE *dst, __reg("d0") ULONG n) =
  "\tmovem.l\td2-d7/a2-a5,-(a7)\n"
  "\tmove.l\td0,d7\n"
  "\tlsr.l\t#5,d7\n"
  "\tsubq.l\t#1,d7\n"
  "\tmove.l\t#$11223344,d0\n"
  "\tmove.l\t#$55667788,d1\n"
  "\tmove.l\t#$99aabbcc,d2\n"
  "\tmove.l\t#$ddeeff00,d3\n"
  "\tmovem.l\td0-d3,-(a7)\n"
  "\tmovem.l\t(a7)+,d4-d6/a1\n"
  ".wr:\tmovem.l\td0-d6/a1,(a0)\n"
  "\tlea\t32(a0),a0\n"
  "\tdbra\td7,.wr\n"
  "\tmovem.l\t(a7)+,d2-d7/a2-a5";

/* ------------------------------------------------------------ ping flood */

#define PAYLOAD 1400

static volatile UBYTE *hw;
static UWORD framew[800];            /* word aligned for the copies */
#define frame ((UBYTE *)framew)
static UBYTE mymac[6], dstmac[6];
static ULONG myip, dstip;

static ULONG parse_ip(char *s) {
  ULONG ip = 0, v = 0; int n = 0;
  for(;; s++) {
    if(*s >= '0' && *s <= '9') v = v * 10 + *s - '0';
    else { ip = (ip << 8) | (v & 255); v = 0; n++; if(*s != '.') break; }
  }
  return n == 4 ? ip : 0;
}

static UWORD csum(UBYTE *p, int n) {
  ULONG s = 0;
  for(; n > 1; n -= 2, p += 2) s += (p[0] << 8) | p[1];
  if(n) s += p[0] << 8;
  while(s >> 16) s = (s & 0xffff) + (s >> 16);
  return ~s;
}

static void put16(UBYTE *p, UWORD v) { p[0] = v >> 8; p[1] = v; }
static void put32(UBYTE *p, ULONG v) { put16(p, v >> 16); put16(p + 2, v); }

/* wait for a free TX slot and send frame[0..len) */
static BOOL send_frame(int len) {
  ULONG t = 0;
  volatile UBYTE *slot;
  UWORD *src = (UWORD *)frame, *dst;
  int i;
  while(!ST_TXFREE(REG(R_STATUS))) if(++t > 2000000) return FALSE;
  slot = hw + NP_TX_BASE + ((ULONG)((REG(R_PTRS) >> 4) & 15) << 11);
  dst = (UWORD *)(slot + 2);
  for(i = 0; i < (len + 1) / 2; i++) dst[i] = src[i];
  *(volatile UWORD *)slot = len < 60 ? 60 : len;
  REG(R_TXGO) = 0;
  return TRUE;
}

/* next received frame copied to buf, returns its length or 0 */
static int recv_frame(UBYTE *buf) {
  volatile UBYTE *slot;
  int len, i;
  if(!ST_RXCNT(REG(R_STATUS))) return 0;
  slot = hw + NP_RX_BASE + ((ULONG)(REG(R_PTRS) & 15) << 11);
  len = *(volatile UWORD *)slot;
  if(len > 1518) len = 1518;
  for(i = 0; i < (len + 1) / 2; i++) ((UWORD *)buf)[i] = ((volatile UWORD *)(slot + 2))[i];
  REG(R_RXACK) = 0;
  return len;
}

static void eth_hdr(const UBYTE *dst, UWORD type) {
  memcpy(frame, dst, 6); memcpy(frame + 6, mymac, 6); put16(frame + 12, type);
}

static int ping_flood(void) {
  static UWORD rxw[800];
  UBYTE *rx = (UBYTE *)rxw;
  static const UBYTE bcast[6] = { 255,255,255,255,255,255 };
  ULONG sent = 0, ok = 0, lost = 0, bad = 0, other = 0, t;
  UWORD seq = 0;
  int len, i;

  REG(R_INTENA) = 0;
  REG(R_CTRL) = CTRL_RESET | CTRL_ONLINE;

  /* ARP for the target */
  for(t = 0; !dstmac[0] && !dstmac[1] && !dstmac[2] && t < 20; t++) {
    ULONG w;
    eth_hdr(bcast, 0x0806);
    put16(frame+14, 1); put16(frame+16, 0x0800); frame[18] = 6; frame[19] = 4; put16(frame+20, 1);
    memcpy(frame+22, mymac, 6); put32(frame+28, myip);
    memset(frame+32, 0, 6); put32(frame+38, dstip);
    send_frame(42);
    for(w = 0; w < 300000; w++) {
      if((len = recv_frame(rx)) >= 42 && rx[12] == 8 && rx[13] == 6 && rx[21] == 2 &&
	 ((rx[28]<<24)|(rx[29]<<16)|(rx[30]<<8)|rx[31]) == dstip) {
	memcpy(dstmac, rx + 22, 6);
	break;
      }
    }
  }
  if(!dstmac[0] && !dstmac[1] && !dstmac[2]) { PutStr("nptest: no ARP reply\n"); return 20; }
  Printf("nptest: target %02lx:%02lx:%02lx:%02lx:%02lx:%02lx, Ctrl-C to stop\n",
	 dstmac[0], dstmac[1], dstmac[2], dstmac[3], dstmac[4], dstmac[5]);

  while(!(SetSignal(0, 0) & SIGBREAKF_CTRL_C)) {
    /* echo request: IPv4 header 20, ICMP 8, payload */
    eth_hdr(dstmac, 0x0800);
    frame[14] = 0x45; frame[15] = 0; put16(frame+16, 20 + 8 + PAYLOAD);
    put16(frame+18, seq); put16(frame+20, 0); frame[22] = 64; frame[23] = 1;
    put16(frame+24, 0); put32(frame+26, myip); put32(frame+30, dstip);
    put16(frame+24, csum(frame+14, 20));
    frame[34] = 8; frame[35] = 0; put16(frame+36, 0); put16(frame+38, 0x4e50); put16(frame+40, seq);
    for(i = 0; i < PAYLOAD; i++) frame[42+i] = (UBYTE)(seq + i * 7);
    put16(frame+36, csum(frame+34, 8 + PAYLOAD));
    if(!send_frame(42 + PAYLOAD)) { PutStr("nptest: TX stuck\n"); break; }
    sent++;

    /* wait for the reply */
    for(t = 0; t < 400000; t++) {
      if(!(len = recv_frame(rx))) continue;
      if(len >= 42 && rx[12] == 8 && rx[13] == 0 && rx[23] == 1 && rx[34] == 0 &&
	 ((rx[38]<<8)|rx[39]) == 0x4e50 && ((rx[40]<<8)|rx[41]) == seq) {
	BOOL good = len >= 42 + PAYLOAD;
	for(i = 0; good && i < PAYLOAD; i++) good = rx[42+i] == (UBYTE)(seq + i * 7);
	if(good) ok++; else bad++;
	break;
      }
      other++;
    }
    if(t == 400000) lost++;
    seq++;
    if(!(sent & 255))
      Printf("sent %lu, ok %lu, lost %lu, corrupt %lu, other frames %lu\n", sent, ok, lost, bad, other);
  }
  REG(R_CTRL) = CTRL_RESET;
  Printf("nptest: sent %lu, ok %lu, lost %lu, corrupt %lu\n", sent, ok, lost, bad);
  return bad ? 10 : 0;
}

int main(int argc, char **argv) {
  struct ConfigDev *cd;
  UWORD mac[3], ver, st, tx;
  ULONG loops = 0, bad = 0, frames = 0;
  BOOL online = argc > 1 && !strcmp(argv[1], "ONLINE");
  int i;

  if(!(ExpansionBase = (struct ExpansionBase *)OpenLibrary("expansion.library", 36))) return 20;
  cd = FindConfigDev(NULL, NP_MANUFACTURER, NP_PRODUCT);
  CloseLibrary((struct Library *)ExpansionBase);
  if(!cd) { PutStr("nptest: no nanoport card\n"); return 20; }
  hw = cd->cd_BoardAddr;

  if(REG(R_ID) != 0x4E50) { PutStr("nptest: bad ID\n"); return 20; }
  ver = REG(R_VERSION);
  for(i = 0; i < 3; i++) mac[i] = REG(R_MAC + 2*i);
  Printf("nptest: card at %08lx, version %04lx, %s, Ctrl-C to stop\n",
	 (ULONG)hw, (ULONG)ver, online ? "online" : "offline");

  if(argc == 4 && !strcmp(argv[1], "PING")) {
    myip = parse_ip(argv[2]);
    dstip = parse_ip(argv[3]);
    if(!myip || !dstip) { PutStr("nptest PING <own ip> <target ip>\n"); return 20; }
    for(i = 0; i < 3; i++) { mymac[2*i] = mac[i] >> 8; mymac[2*i+1] = mac[i]; }
    return ping_flood();
  }

  REG(R_INTENA) = 0;
  REG(R_CTRL) = CTRL_RESET | (online ? CTRL_ONLINE : 0);

  while(!(SetSignal(0, 0) & SIGBREAKF_CTRL_C)) {
    for(i = 0; i < 64; i++) {
      rd_block(hw + NP_RX_BASE + ((i & 3) << 11), 1536);
      st = REG(R_STATUS);
      tx = (REG(R_PTRS) >> 4) & 15;
      wr_block(hw + NP_TX_BASE + ((ULONG)tx << 11) + 16, 1504);  /* never TXGO */
      if(REG(R_ID) != 0x4E50 || REG(R_VERSION) != ver ||
	 REG(R_MAC) != mac[0] || REG(R_MAC+2) != mac[1] || REG(R_MAC+4) != mac[2])
	bad++;
      if(online && ST_RXCNT(st)) { REG(R_RXACK) = 0; frames++; }
    }
    if(!(++loops & 63))
      Printf("loops %lu, register errors %lu, frames %lu\n", loops, bad, frames);
  }

  REG(R_CTRL) = CTRL_RESET;
  Printf("nptest: %lu loops, %lu register errors, %lu frames\n", loops, bad, frames);
  return bad ? 10 : 0;
}
