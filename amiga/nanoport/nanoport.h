/*
 * nanoport.h - SANA-II driver for the NanoMig nanoport network card
 */

#ifndef NANOPORT_H
#define NANOPORT_H

#include <exec/types.h>
#include <exec/devices.h>
#include <exec/interrupts.h>
#include <exec/semaphores.h>
#include <exec/lists.h>
#include <devices/sana2.h>

#define NP_NAME      "nanoport.device"
#define NP_VERSION   1
#define NP_REVISION  0
#define NP_IDSTRING  "nanoport 1.0 (20.11.2026) NanoMig network card"

/* autoconfig ids of the card */
#define NP_MANUFACTURER 2011    /* $07DB, reserved for hackers */
#define NP_PRODUCT      0x4E

/* card layout */
#define NP_RX_BASE   0x0000
#define NP_TX_BASE   0x8000
#define NP_SLOT_SIZE 0x0800   /* slot n at base + (n << 11) */
#define R_ID         0xC000
#define R_STATUS     0xC002
#define R_PTRS       0xC004
#define R_RXACK      0xC006
#define R_TXGO       0xC008
#define R_INTENA     0xC00A
#define R_CTRL       0xC00C
#define R_MAC        0xC010
#define R_VERSION    0xC016

#define ST_LINK      0x8000
#define ST_RXCNT(s)  ((s) & 0x0f)
#define ST_TXFREE(s) (((s) >> 4) & 0x0f)
#define INT_RX       0x0001
#define INT_TX       0x0002
#define CTRL_ONLINE  0x0001
#define CTRL_PROMISC 0x0002
#define CTRL_RESET   0x0080

#define NP_MTU       1500
#define NP_MAXFRAME  1514
#define NP_MINFRAME  60
#define NP_HDR       14
#define NP_MCAST_MAX 16
#define NP_STACK     8192

/* SANA-II R4 DMA hooks, not in older headers (+4..+7 are the 16/32 bit copy hooks) */
#ifndef S2_DMACopyToBuff32
#define S2_DMACopyToBuff32   (S2_Dummy + 8)
#define S2_DMACopyFromBuff32 (S2_Dummy + 9)
#endif

typedef BOOL (*np_copy_fn)(__reg("a0") APTR to, __reg("a1") APTR from, __reg("d0") ULONG n);
typedef APTR (*np_dma_fn)(__reg("a0") APTR data);

/* one per OpenDevice() */
struct NPOpener {
  np_copy_fn copy_to;          /* S2_CopyToBuff */
  np_copy_fn copy_from;        /* S2_CopyFromBuff */
  np_dma_fn  dma_to;           /* S2_DMACopyToBuff32 (optional) */
  np_dma_fn  dma_from;         /* S2_DMACopyFromBuff32 (optional) */
};

struct NPMcast {
  UBYTE addr[6];
  UWORD count;
};

struct NPUnit {
  /* the first fields are used by the interrupt server (nanoport_asm.s) */
  volatile UBYTE *hw;          /*  0: card base */
  struct Task *task;           /*  4: unit task */
  ULONG irqmask;               /*  8: signal for the unit task */
  UWORD intena;                /* 12: shadow of R_INTENA */
  UWORD pad;

  struct Interrupt irq;
  struct Task *caller;         /* task waiting for the unit task to start/stop */
  ULONG quitmask;
  struct SignalSemaphore txlock;
  struct MinList readq;        /* CMD_READ */
  struct MinList orphanq;      /* S2_READORPHAN */
  struct MinList writeq;       /* writes waiting for a free TX slot */
  struct MinList eventq;       /* S2_ONEVENT */
  UWORD rx_slots, tx_slots;
  BOOL online, configured, promisc;
  UBYTE curaddr[6];
  UBYTE defaddr[6];
  struct NPMcast mcast[NP_MCAST_MAX];
  struct Sana2DeviceStats stats;
};

struct NPBase {
  struct Device dev;
  BPTR seglist;
  struct NPUnit unit;
};

/* nanoport_asm.s */
extern void np_irq_server(void);
extern void np_copy(__reg("a0") APTR to, __reg("a1") APTR from, __reg("d0") ULONG n);

#endif /* NANOPORT_H */
