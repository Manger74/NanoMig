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

int main(int argc, char **argv) {
  struct ConfigDev *cd;
  volatile UBYTE *hw;
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
