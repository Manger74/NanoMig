/*
 * nanoport.c - SANA-II driver for the NanoMig nanoport network card
 *
 * The card is a Zorro II board (manufacturer 2011, product $4E) with four
 * receive and two transmit slots in block ram of the FPGA, served on the
 * fast cpu path. The FPGA Companion bridges the frames into its WiFi or
 * USB ethernet network, the Amiga gets its own IP address there.
 *
 * Design for low cpu load:
 *  - writes are copied straight into a free TX slot in the caller's
 *    context, no task switch per packet
 *  - received frames are copied once, from the card into the stack's
 *    buffer (SANA-II R4 DMA hooks with a MOVEM copy if the stack offers
 *    them, CopyToBuff() otherwise)
 *  - the interrupt server only masks the card interrupt and signals the
 *    unit task, which then drains all pending frames before it unmasks
 *    the interrupt again
 *
 * Build with vbcc, see build.bat.
 */

#include <exec/types.h>
#include <exec/memory.h>
#include <exec/resident.h>
#include <exec/errors.h>
#include <exec/execbase.h>
#include <hardware/intbits.h>
#include <libraries/configvars.h>
#include <utility/tagitem.h>
#include <proto/exec.h>
#include <proto/expansion.h>

#include "nanoport.h"

struct ExecBase *SysBase;
struct ExpansionBase *ExpansionBase;

static struct NPBase *np_base;

static const char np_name[] = NP_NAME;
static const char np_idstring[] = NP_IDSTRING;
static const char np_taskname[] = "nanoport unit";

#ifndef NP_TEST
#define np_rd(u, o)    (*(volatile UWORD *)((u)->hw + (o)))
#define np_wr(u, o, v) (*(volatile UWORD *)((u)->hw + (o)) = (v))
#else
UWORD np_rd(struct NPUnit *u, ULONG o);           /* test harness: card model */
void np_wr(struct NPUnit *u, ULONG o, UWORD v);
#endif

/* ------------------------------------------------------------------ helpers */

static void np_reply(struct IOSana2Req *ios) {
  if(!(ios->ios2_Req.io_Flags & IOF_QUICK))
    ReplyMsg(&ios->ios2_Req.io_Message);
}

static void np_error(struct IOSana2Req *ios, BYTE err, ULONG wire) {
  ios->ios2_Req.io_Error = err;
  ios->ios2_WireError = wire;
}

static void np_newlist(struct MinList *l) {   /* NewList() lives in amiga.lib */
  l->mlh_Head = (struct MinNode *)&l->mlh_Tail;
  l->mlh_Tail = NULL;
  l->mlh_TailPred = (struct MinNode *)&l->mlh_Head;
}

static void np_queue(struct MinList *l, struct IOSana2Req *ios) {
  ios->ios2_Req.io_Flags &= ~IOF_QUICK;
  Forbid();
  AddTail((struct List *)l, (struct Node *)ios);
  Permit();
}

static void np_flush_list(struct MinList *l, BYTE err, ULONG wire) {
  struct IOSana2Req *ios;
  Forbid();
  while((ios = (struct IOSana2Req *)RemHead((struct List *)l))) {
    np_error(ios, err, wire);
    ReplyMsg(&ios->ios2_Req.io_Message);
  }
  Permit();
}

static void np_intena(struct NPUnit *u, UWORD set, UWORD clr) {
  Disable();
  u->intena = (u->intena | set) & ~clr;
  np_wr(u, R_INTENA, u->intena);
  Enable();
}

static void np_event(struct NPUnit *u, ULONG event) {
  struct IOSana2Req *ios, *next;
  Forbid();
  for(ios = (struct IOSana2Req *)u->eventq.mlh_Head;
      (next = (struct IOSana2Req *)ios->ios2_Req.io_Message.mn_Node.ln_Succ); ios = next) {
    if(ios->ios2_WireError & event) {
      Remove((struct Node *)ios);
      ios->ios2_WireError = event;
      ReplyMsg(&ios->ios2_Req.io_Message);
    }
  }
  Permit();
}

static int np_addr_eq(const UBYTE *a, const UBYTE *b) {
  return *(const UWORD *)a == *(const UWORD *)b &&
    *(const ULONG *)(a+2) == *(const ULONG *)(b+2);
}

static void np_addr_cpy(UBYTE *d, const UBYTE *s) {
  *(UWORD *)d = *(const UWORD *)s;
  *(ULONG *)(d+2) = *(const ULONG *)(s+2);
}

static struct NPMcast *np_mcast_find(struct NPUnit *u, const UBYTE *a) {
  int i;
  for(i = 0; i < NP_MCAST_MAX; i++)
    if(u->mcast[i].count && np_addr_eq(u->mcast[i].addr, a))
      return &u->mcast[i];
  return NULL;
}

/* ------------------------------------------------------------------ receive */

/* copy one frame from the card into a read request */
static void np_deliver(struct NPUnit *u, struct IOSana2Req *ios, UBYTE *frame, ULONG len, UBYTE flags) {
  struct NPOpener *op = ios->ios2_BufferManagement;
  UBYTE *src = frame;
  ULONG n = len;
  APTR dst;

  np_addr_cpy(ios->ios2_DstAddr, frame);
  np_addr_cpy(ios->ios2_SrcAddr, frame + 6);
  ios->ios2_PacketType = *(UWORD *)(frame + 12);
  if(!(ios->ios2_Req.io_Flags & SANA2IOF_RAW)) {
    src += NP_HDR;
    n -= NP_HDR;
  }
  ios->ios2_DataLength = n;
  ios->ios2_Req.io_Flags = (ios->ios2_Req.io_Flags & ~(SANA2IOF_BCAST | SANA2IOF_MCAST)) | flags;
  ios->ios2_Req.io_Error = 0;

  if(op->dma_to && (dst = op->dma_to(ios->ios2_Data)))
    np_copy(dst, src, n);
  else if(!op->copy_to(ios->ios2_Data, src, n)) {
    np_error(ios, S2ERR_NO_RESOURCES, S2WERR_BUFF_ERROR);
    np_event(u, S2EVENT_BUFF);
  }
  ReplyMsg(&ios->ios2_Req.io_Message);
}

static void np_rx_frame(struct NPUnit *u, UBYTE *frame, ULONG len) {
  struct IOSana2Req *ios, *next, *hit = NULL;
  UWORD type;
  UBYTE flags = 0;

  if(len < NP_HDR || len > NP_MAXFRAME) {
    u->stats.BadData++;
    return;
  }

  if(frame[0] & 1) {
    if(*(ULONG *)frame == 0xffffffff && *(UWORD *)(frame+4) == 0xffff)
      flags = SANA2IOF_BCAST;
    else {
      if(!u->promisc && !np_mcast_find(u, frame)) return;
      flags = SANA2IOF_MCAST;
    }
  } else if(!u->promisc && !np_addr_eq(frame, u->curaddr))
    return;

  type = *(UWORD *)(frame + 12);

  Forbid();
  for(ios = (struct IOSana2Req *)u->readq.mlh_Head;
      (next = (struct IOSana2Req *)ios->ios2_Req.io_Message.mn_Node.ln_Succ); ios = next) {
    if(ios->ios2_PacketType == type) {
      hit = ios;
      break;
    }
  }
  if(!hit) hit = (struct IOSana2Req *)RemHead((struct List *)&u->orphanq);
  else Remove((struct Node *)hit);
  Permit();

  if(!hit) {
    u->stats.UnknownTypesReceived++;
    return;
  }
  u->stats.PacketsReceived++;
  np_deliver(u, hit, frame, len, flags);
}

/* the slot numbers always come from the card (PTRS), so the driver can't
   get out of step with it, e.g. after a ring reset */
static void np_service_rx(struct NPUnit *u) {
  while(ST_RXCNT(np_rd(u, R_STATUS))) {
    UBYTE *slot = (UBYTE *)u->hw + NP_RX_BASE + ((ULONG)(np_rd(u, R_PTRS) & 15) << 11);
    np_rx_frame(u, slot + 2, *(UWORD *)slot);
    np_wr(u, R_RXACK, 0);
  }
  if(u->online) np_intena(u, INT_RX, 0);
}

/* ------------------------------------------------------------------ transmit */

/* copy one write request into the next TX slot, txlock is held */
static void np_tx_frame(struct NPUnit *u, struct IOSana2Req *ios) {
  struct NPOpener *op = ios->ios2_BufferManagement;
  UBYTE *slot = (UBYTE *)u->hw + NP_TX_BASE + ((ULONG)((np_rd(u, R_PTRS) >> 4) & 15) << 11);
  UBYTE *dst = slot + 2;
  ULONG n = ios->ios2_DataLength, len = n;
  APTR src;

  if(!(ios->ios2_Req.io_Flags & SANA2IOF_RAW)) {
    UWORD *h = (UWORD *)dst;
    UBYTE *d = ios->ios2_DstAddr, *s = u->curaddr;
    h[0] = *(UWORD *)d; h[1] = *(UWORD *)(d+2); h[2] = *(UWORD *)(d+4);
    h[3] = *(UWORD *)s; h[4] = *(UWORD *)(s+2); h[5] = *(UWORD *)(s+4);
    h[6] = ios->ios2_PacketType;
    dst += NP_HDR;
    len += NP_HDR;
  }

  ios->ios2_Req.io_Error = 0;
  if(op->dma_from && (src = op->dma_from(ios->ios2_Data)))
    np_copy(dst, src, n);
  else if(!op->copy_from(dst, ios->ios2_Data, n)) {
    np_error(ios, S2ERR_NO_RESOURCES, S2WERR_BUFF_ERROR);
    np_event(u, S2EVENT_BUFF);
    return;
  }

  *(UWORD *)slot = len < NP_MINFRAME ? NP_MINFRAME : len;
  np_wr(u, R_TXGO, 0);
  u->stats.PacketsSent++;
}

static void np_service_tx(struct NPUnit *u) {
  struct IOSana2Req *ios;

  ObtainSemaphore(&u->txlock);
  while(ST_TXFREE(np_rd(u, R_STATUS))) {
    Forbid();
    ios = (struct IOSana2Req *)RemHead((struct List *)&u->writeq);
    Permit();
    if(!ios) break;
    np_tx_frame(u, ios);
    ReplyMsg(&ios->ios2_Req.io_Message);
  }
  ReleaseSemaphore(&u->txlock);

  /* atomic with the queue check: np_write() may queue a frame any time */
  Disable();
  if(IsListEmpty((struct List *)&u->writeq)) u->intena &= ~INT_TX;
  else u->intena |= INT_TX;
  np_wr(u, R_INTENA, u->intena);
  Enable();
}

/* CMD_WRITE, S2_BROADCAST, S2_MULTICAST */
static BOOL np_write(struct NPUnit *u, struct IOSana2Req *ios) {
  ULONG max = (ios->ios2_Req.io_Flags & SANA2IOF_RAW) ? NP_MAXFRAME : NP_MTU;

  if(!u->online) {
    np_error(ios, S2ERR_OUTOFSERVICE, S2WERR_UNIT_OFFLINE);
    return TRUE;
  }
  if(ios->ios2_DataLength > max) {
    np_error(ios, S2ERR_MTU_EXCEEDED, S2WERR_GENERIC_ERROR);
    return TRUE;
  }

  /* Never wait for the lock here: the unit task holds it while it calls the
     stack's copy hooks, and the stack may well be the caller and hold its
     own locks. If the lock is busy, the frame is queued and sent by the unit
     task (INT_TX fires as soon as a slot is free). */
  if(AttemptSemaphore(&u->txlock)) {
    if(IsListEmpty((struct List *)&u->writeq) && ST_TXFREE(np_rd(u, R_STATUS))) {
      np_tx_frame(u, ios);
      ReleaseSemaphore(&u->txlock);
      return TRUE;
    }
    ReleaseSemaphore(&u->txlock);
  }
  np_queue(&u->writeq, ios);
  np_intena(u, INT_TX, 0);
  return FALSE;
}

/* ------------------------------------------------------------------ online state */

static void np_set_online(struct NPUnit *u, BOOL on) {
  if(on == u->online) return;
  u->online = on;
  if(on) {
    np_wr(u, R_CTRL, CTRL_RESET | CTRL_ONLINE | (u->promisc ? CTRL_PROMISC : 0));
    u->stats.Reconfigurations++;
    np_intena(u, INT_RX, 0);
    np_event(u, S2EVENT_ONLINE);
  } else {
    np_intena(u, 0, INT_RX | INT_TX);
    np_wr(u, R_CTRL, 0);
    np_flush_list(&u->readq, S2ERR_OUTOFSERVICE, S2WERR_UNIT_OFFLINE);
    np_flush_list(&u->orphanq, S2ERR_OUTOFSERVICE, S2WERR_UNIT_OFFLINE);
    np_flush_list(&u->writeq, S2ERR_OUTOFSERVICE, S2WERR_UNIT_OFFLINE);
    np_event(u, S2EVENT_OFFLINE);
  }
}

/* ------------------------------------------------------------------ unit task */

static void np_unit_task(void) {
  struct NPUnit *u = &np_base->unit;
  BYTE irqsig = AllocSignal(-1), quitsig = AllocSignal(-1);

  u->irqmask = 1UL << irqsig;
  u->quitmask = 1UL << quitsig;
  Signal(u->caller, SIGF_SINGLE);

  for(;;) {
    ULONG sigs = Wait(u->irqmask | u->quitmask);
    if(sigs & u->quitmask) break;
    np_service_rx(u);
    np_service_tx(u);
  }

  /* the closer frees our memory once we are gone: stay in Forbid() */
  Forbid();
  Signal(u->caller, SIGF_SINGLE);
}

static BOOL np_unit_start(struct NPUnit *u) {
  struct ConfigDev *cd;
  struct Task *t;
  UBYTE *stack;
  UWORD ver;
  int i;

  if(!(ExpansionBase = (struct ExpansionBase *)OpenLibrary("expansion.library", 36)))
    return FALSE;
  cd = FindConfigDev(NULL, NP_MANUFACTURER, NP_PRODUCT);
  if(cd) cd->cd_Flags &= ~CDF_CONFIGME;
  CloseLibrary((struct Library *)ExpansionBase);
  if(!cd) return FALSE;

  u->hw = cd->cd_BoardAddr;
  if(np_rd(u, R_ID) != 0x4E50) return FALSE;

  ver = np_rd(u, R_VERSION);
  u->rx_slots = 1 << (ver >> 12);
  u->tx_slots = 1 << ((ver >> 8) & 15);

  for(i = 0; i < 3; i++) ((UWORD *)u->defaddr)[i] = np_rd(u, R_MAC + 2*i);
  if(!(u->defaddr[0] | u->defaddr[1] | u->defaddr[2])) {
    /* the Companion has not reported its address yet */
    static const UBYTE fallback[6] = { 0x02, 0x4e, 0x50, 0x00, 0x00, 0x01 };
    np_addr_cpy(u->defaddr, fallback);
  }
  np_addr_cpy(u->curaddr, u->defaddr);

  np_newlist(&u->readq);
  np_newlist(&u->orphanq);
  np_newlist(&u->writeq);
  np_newlist(&u->eventq);
  InitSemaphore(&u->txlock);

  u->intena = 0;
  np_wr(u, R_INTENA, 0);
  np_wr(u, R_CTRL, CTRL_RESET);

  /* unit task */
  if(!(t = AllocMem(sizeof(struct Task) + NP_STACK, MEMF_PUBLIC | MEMF_CLEAR)))
    return FALSE;
  stack = (UBYTE *)(t + 1);
  t->tc_Node.ln_Type = NT_TASK;
  np_newlist((struct MinList *)&t->tc_MemEntry);       /* RemTask() walks it when the task ends */
  t->tc_Node.ln_Pri = 5;
  t->tc_Node.ln_Name = (char *)np_taskname;
  t->tc_SPLower = stack;
  t->tc_SPUpper = stack + NP_STACK;
  t->tc_SPReg = stack + NP_STACK;
  u->task = t;
  u->caller = FindTask(NULL);
  SetSignal(0, SIGF_SINGLE);
  AddTask(t, (APTR)np_unit_task, NULL);
  Wait(SIGF_SINGLE);

  u->irq.is_Node.ln_Type = NT_INTERRUPT;
  u->irq.is_Node.ln_Pri = 0;
  u->irq.is_Node.ln_Name = (char *)np_name;
  u->irq.is_Data = u;
  u->irq.is_Code = np_irq_server;
  AddIntServer(INTB_PORTS, &u->irq);
  return TRUE;
}

static void np_unit_stop(struct NPUnit *u) {
  np_set_online(u, FALSE);
  RemIntServer(INTB_PORTS, &u->irq);
  np_flush_list(&u->eventq, IOERR_ABORTED, 0);

  u->caller = FindTask(NULL);
  SetSignal(0, SIGF_SINGLE);
  Signal(u->task, u->quitmask);
  Wait(SIGF_SINGLE);
  FreeMem(u->task, sizeof(struct Task) + NP_STACK);
  u->task = NULL;
}

/* ------------------------------------------------------------------ commands */

static BOOL np_command(struct NPUnit *u, struct IOSana2Req *ios) {
  struct NPMcast *m;
  int i;

  switch(ios->ios2_Req.io_Command) {
  case CMD_READ:
    if(!u->online) { np_error(ios, S2ERR_OUTOFSERVICE, S2WERR_UNIT_OFFLINE); break; }
    np_queue(&u->readq, ios);
    return FALSE;

  case S2_READORPHAN:
    if(!u->online) { np_error(ios, S2ERR_OUTOFSERVICE, S2WERR_UNIT_OFFLINE); break; }
    np_queue(&u->orphanq, ios);
    return FALSE;

  case CMD_WRITE:
    return np_write(u, ios);

  case S2_BROADCAST:
    for(i = 0; i < 6; i++) ios->ios2_DstAddr[i] = 0xff;
    return np_write(u, ios);

  case S2_MULTICAST:
    if(!(ios->ios2_DstAddr[0] & 1)) { np_error(ios, S2ERR_BAD_ADDRESS, S2WERR_BAD_MULTICAST); break; }
    return np_write(u, ios);

  case S2_DEVICEQUERY: {
    struct Sana2DeviceQuery *q = ios->ios2_StatData;
    if(!q || q->SizeAvailable < sizeof(*q)) { np_error(ios, S2ERR_BAD_ARGUMENT, S2WERR_NULL_POINTER); break; }
    q->SizeSupplied = sizeof(*q);
    q->DevQueryFormat = 0;
    q->DeviceLevel = 0;
    q->AddrFieldSize = 48;
    q->MTU = NP_MTU;
    q->BPS = 20000000;
    q->HardwareType = S2WireType_Ethernet;
    break;
  }

  case S2_GETSTATIONADDRESS:
    np_addr_cpy(ios->ios2_SrcAddr, u->curaddr);
    np_addr_cpy(ios->ios2_DstAddr, u->defaddr);
    break;

  case S2_CONFIGINTERFACE:
    if(u->configured) { np_error(ios, S2ERR_BAD_STATE, S2WERR_IS_CONFIGURED); break; }
    if(!(ios->ios2_SrcAddr[0] & 1)) np_addr_cpy(u->curaddr, ios->ios2_SrcAddr);
    u->configured = TRUE;
    np_set_online(u, TRUE);
    break;

  case S2_ONLINE:
    if(!u->configured) { np_error(ios, S2ERR_BAD_STATE, S2WERR_NOT_CONFIGURED); break; }
    np_set_online(u, TRUE);
    break;

  case S2_OFFLINE:
    np_set_online(u, FALSE);
    break;

  case S2_ADDMULTICASTADDRESS:
    if(!(ios->ios2_SrcAddr[0] & 1)) { np_error(ios, S2ERR_BAD_ADDRESS, S2WERR_BAD_MULTICAST); break; }
    if((m = np_mcast_find(u, ios->ios2_SrcAddr))) { m->count++; break; }
    for(i = 0; i < NP_MCAST_MAX && u->mcast[i].count; i++);
    if(i == NP_MCAST_MAX) { np_error(ios, S2ERR_NO_RESOURCES, S2WERR_MULTICAST_FULL); break; }
    np_addr_cpy(u->mcast[i].addr, ios->ios2_SrcAddr);
    u->mcast[i].count = 1;
    break;

  case S2_DELMULTICASTADDRESS:
    if(!(m = np_mcast_find(u, ios->ios2_SrcAddr))) { np_error(ios, S2ERR_BAD_STATE, S2WERR_BAD_MULTICAST); break; }
    m->count--;
    break;

  case S2_GETGLOBALSTATS:
    if(!ios->ios2_StatData) { np_error(ios, S2ERR_BAD_ARGUMENT, S2WERR_NULL_POINTER); break; }
    CopyMem(&u->stats, ios->ios2_StatData, sizeof(u->stats));
    break;

  case S2_GETSPECIALSTATS: {
    struct Sana2SpecialStatHeader *h = ios->ios2_StatData;
    if(!h) { np_error(ios, S2ERR_BAD_ARGUMENT, S2WERR_NULL_POINTER); break; }
    h->RecordCountSupplied = 0;
    break;
  }

  case S2_TRACKTYPE:
  case S2_UNTRACKTYPE:
    break;          /* accepted, no per type statistics */

  case S2_GETTYPESTATS:
    np_error(ios, S2ERR_BAD_STATE, S2WERR_NOT_TRACKED);
    break;

  case S2_ONEVENT:
    if(ios->ios2_WireError & ~(S2EVENT_ONLINE | S2EVENT_OFFLINE | S2EVENT_BUFF | S2EVENT_ERROR)) {
      np_error(ios, S2ERR_NOT_SUPPORTED, S2WERR_BAD_EVENT);
      break;
    }
    if((ios->ios2_WireError & S2EVENT_ONLINE) && u->online) { ios->ios2_WireError = S2EVENT_ONLINE; break; }
    if((ios->ios2_WireError & S2EVENT_OFFLINE) && !u->online) { ios->ios2_WireError = S2EVENT_OFFLINE; break; }
    np_queue(&u->eventq, ios);
    return FALSE;

  case CMD_FLUSH:
    np_flush_list(&u->readq, IOERR_ABORTED, 0);
    np_flush_list(&u->orphanq, IOERR_ABORTED, 0);
    np_flush_list(&u->eventq, IOERR_ABORTED, 0);
    np_flush_list(&u->writeq, IOERR_ABORTED, 0);
    break;

  default:
    np_error(ios, IOERR_NOCMD, S2WERR_GENERIC_ERROR);
    break;
  }
  return TRUE;
}

/* ------------------------------------------------------------------ device vectors */

static void np_dev_open(__reg("a1") struct IOSana2Req *ios, __reg("d0") ULONG unit,
			__reg("d1") ULONG flags, __reg("a6") struct NPBase *base) {
  struct NPUnit *u = &base->unit;
  struct NPOpener *op;
  struct TagItem *ti;

  base->dev.dd_Library.lib_OpenCnt++;    /* no expunge while we are busy */
  ios->ios2_Req.io_Error = IOERR_OPENFAIL;

  if(unit != 0 || ios->ios2_Req.io_Message.mn_Length < sizeof(struct IOSana2Req))
    goto fail;
  if(!(op = AllocMem(sizeof(*op), MEMF_PUBLIC | MEMF_CLEAR)))
    goto fail;

  /* buffer management tags, without utility.library */
  for(ti = ios->ios2_BufferManagement; ti && ti->ti_Tag != TAG_DONE; ti++) {
    if(ti->ti_Tag == TAG_MORE) { ti = (struct TagItem *)ti->ti_Data - 1; continue; }
    if(ti->ti_Tag == TAG_SKIP) { ti += ti->ti_Data; continue; }
    switch(ti->ti_Tag) {
    case S2_CopyToBuff:        op->copy_to   = (np_copy_fn)ti->ti_Data; break;
    case S2_CopyFromBuff:      op->copy_from = (np_copy_fn)ti->ti_Data; break;
#ifndef NP_NO_DMA   /* diagnostic build without the DMA hooks: -DNP_NO_DMA */
    case S2_DMACopyToBuff32:   op->dma_to    = (np_dma_fn)ti->ti_Data;  break;
    case S2_DMACopyFromBuff32: op->dma_from  = (np_dma_fn)ti->ti_Data;  break;
#endif
    }
  }
  if(!op->copy_to || !op->copy_from) {
    FreeMem(op, sizeof(*op));
    goto fail;
  }

  if(base->dev.dd_Library.lib_OpenCnt == 1 && !np_unit_start(u)) {
    FreeMem(op, sizeof(*op));
    goto fail;
  }
  if(flags & SANA2OPF_PROM) u->promisc = TRUE;

  ios->ios2_BufferManagement = op;
  ios->ios2_Req.io_Device = &base->dev;
  ios->ios2_Req.io_Unit = (struct Unit *)u;
  ios->ios2_Req.io_Error = 0;
  base->dev.dd_Library.lib_Flags &= ~LIBF_DELEXP;
  return;

 fail:
  base->dev.dd_Library.lib_OpenCnt--;
}

static BPTR np_dev_expunge(__reg("a6") struct NPBase *base) {
  BPTR seg;
  if(base->dev.dd_Library.lib_OpenCnt) {
    base->dev.dd_Library.lib_Flags |= LIBF_DELEXP;
    return 0;
  }
  seg = base->seglist;
  Remove((struct Node *)base);
  FreeMem((UBYTE *)base - base->dev.dd_Library.lib_NegSize,
	  base->dev.dd_Library.lib_NegSize + base->dev.dd_Library.lib_PosSize);
  return seg;
}

static BPTR np_dev_close(__reg("a1") struct IOSana2Req *ios, __reg("a6") struct NPBase *base) {
  FreeMem(ios->ios2_BufferManagement, sizeof(struct NPOpener));
  ios->ios2_Req.io_Device = (struct Device *)-1;
  ios->ios2_Req.io_Unit = (struct Unit *)-1;

  if(--base->dev.dd_Library.lib_OpenCnt == 0) {
    np_unit_stop(&base->unit);
    base->unit.configured = FALSE;
    base->unit.promisc = FALSE;
    if(base->dev.dd_Library.lib_Flags & LIBF_DELEXP)
      return np_dev_expunge(base);
  }
  return 0;
}

static ULONG np_dev_null(void) {
  return 0;
}

static void np_dev_beginio(__reg("a1") struct IOSana2Req *ios, __reg("a6") struct NPBase *base) {
  ios->ios2_Req.io_Message.mn_Node.ln_Type = NT_MESSAGE;
  ios->ios2_Req.io_Error = 0;
  if(ios->ios2_Req.io_Command != S2_ONEVENT)   /* carries the event mask */
    ios->ios2_WireError = 0;
  if(np_command(&base->unit, ios))
    np_reply(ios);
}

static ULONG np_dev_abortio(__reg("a1") struct IOSana2Req *ios, __reg("a6") struct NPBase *base) {
  struct NPUnit *u = &base->unit;
  struct MinList *lists[4];
  struct Node *n;
  int i;

  lists[0] = &u->readq; lists[1] = &u->orphanq; lists[2] = &u->writeq; lists[3] = &u->eventq;

  Forbid();
  for(i = 0; i < 4; i++) {
    for(n = (struct Node *)lists[i]->mlh_Head; n->ln_Succ; n = n->ln_Succ) {
      if(n == (struct Node *)ios) {
	Remove(n);
	ios->ios2_Req.io_Error = IOERR_ABORTED;
	ReplyMsg(&ios->ios2_Req.io_Message);
	Permit();
	return 0;
      }
    }
  }
  Permit();
  return IOERR_NOCMD;    /* not queued (anymore) */
}

static const APTR np_vectors[] = {
  (APTR)np_dev_open,
  (APTR)np_dev_close,
  (APTR)np_dev_expunge,
  (APTR)np_dev_null,
  (APTR)np_dev_beginio,
  (APTR)np_dev_abortio,
  (APTR)-1
};

/* called by the resident tag (nanoport_asm.s) when the device is loaded */
struct NPBase *np_rom_init(__reg("a0") BPTR seglist, __reg("a6") struct ExecBase *sysbase) {
  struct NPBase *base;

  SysBase = sysbase;
  base = (struct NPBase *)MakeLibrary((APTR)np_vectors, NULL, NULL, sizeof(struct NPBase), seglist);
  if(!base) return NULL;

  base->dev.dd_Library.lib_Node.ln_Type = NT_DEVICE;
  base->dev.dd_Library.lib_Node.ln_Name = (char *)np_name;
  base->dev.dd_Library.lib_Flags = LIBF_SUMUSED | LIBF_CHANGED;
  base->dev.dd_Library.lib_Version = NP_VERSION;
  base->dev.dd_Library.lib_Revision = NP_REVISION;
  base->dev.dd_Library.lib_IdString = (APTR)np_idstring;
  base->seglist = seglist;
  np_base = base;

  AddDevice(&base->dev);
  return base;
}
