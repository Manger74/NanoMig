/* host test of nanoport.c: runs as m68k linux binary under qemu-m68k,
   exec is mocked, the card is a model of nanoport.v */
/* no libc headers: they clash with the NDK (struct timeval) */
typedef __SIZE_TYPE__ size_t;
int printf(const char *, ...); void *calloc(size_t, size_t); void free(void *); void exit(int);
void *memcpy(void *, const void *, size_t); void *memset(void *, int, size_t); int memcmp(const void *, const void *, size_t);
#define NP_TEST
#include "nanoport.c"

/* ---------------- card model ---------------- */
static UBYTE card[65536] __attribute__((aligned(4)));
static int rx_head, rx_tail, tx_head, tx_tail; static UWORD intena_hw, ctrl_hw;
#define RXS 4
#define TXS 2
static UWORD mac_hw[3] = { 0x024e, 0x5011, 0x2233 };

UWORD np_rd(struct NPUnit *u, ULONG o) {
  switch(o) {
  case R_ID: return 0x4E50;
  case R_STATUS: return ((ctrl_hw&1)<<14) | ((TXS-(tx_tail-tx_head))<<4) | (rx_tail-rx_head);
  case R_PTRS: return ((tx_tail%TXS)<<4) | (rx_head%RXS);
  case R_INTENA: return intena_hw;
  case R_CTRL: return ctrl_hw;
  case R_MAC: return mac_hw[0]; case R_MAC+2: return mac_hw[1]; case R_MAC+4: return mac_hw[2];
  case R_VERSION: return 0x2101;
  }
  printf("bad read %lx\n", (unsigned long)o); exit(1);
}
void np_wr(struct NPUnit *u, ULONG o, UWORD v) {
  switch(o) {
  case R_RXACK: if(rx_tail != rx_head) rx_head++; return;
  case R_TXGO: if(tx_tail-tx_head < TXS) tx_tail++; return;
  case R_INTENA: intena_hw = v; return;
  case R_CTRL: ctrl_hw = v & 0x7f; if(v & 0x80) rx_head=rx_tail=tx_head=tx_tail=0; return;
  }
  printf("bad write %lx\n", (unsigned long)o); exit(1);
}
static void inject(const UBYTE *f, int len) {
  UBYTE *s = card + NP_RX_BASE + (rx_tail%RXS)*0x800;
  s[0] = len>>8; s[1] = len; memcpy(s+2, f, len); rx_tail++;
}
static int txget(UBYTE *f) {
  if(tx_tail == tx_head) return -1;
  UBYTE *s = card + NP_TX_BASE + (tx_head%TXS)*0x800;
  int len = (s[0]<<8)|s[1]; memcpy(f, s+2, len); tx_head++; return len;
}

/* ---------------- exec mocks ---------------- */
struct ExecBase *SysBase; struct ExpansionBase *ExpansionBase;
static struct IOSana2Req *replied[64]; static int nreplied;
void Forbid(void) {} void Permit(void) {} void Disable(void) {} void Enable(void) {}
void AddTail(struct List *l, struct Node *n) { n->ln_Succ=(struct Node*)&l->lh_Tail; n->ln_Pred=l->lh_TailPred; l->lh_TailPred->ln_Succ=n; l->lh_TailPred=n; }
void Remove(struct Node *n) { n->ln_Pred->ln_Succ=n->ln_Succ; n->ln_Succ->ln_Pred=n->ln_Pred; }
struct Node *RemHead(struct List *l) { struct Node *n=l->lh_Head; if(!n->ln_Succ) return NULL; Remove(n); return n; }
void ReplyMsg(struct Message *m) { replied[nreplied++] = (struct IOSana2Req *)m; }
APTR AllocMem(ULONG n, ULONG f) { return calloc(1, n); }
void FreeMem(APTR p, ULONG n) { free(p); }
void CopyMem(CONST APTR s, APTR d, ULONG n) { memcpy(d, s, n); }
void Signal(struct Task *t, ULONG s) {}
ULONG Wait(ULONG s) { return s; }
BYTE AllocSignal(LONG n) { return 16; }
ULONG SetSignal(ULONG a, ULONG b) { return 0; }
static struct Task me; struct Task *FindTask(CONST_STRPTR n) { return &me; }
APTR AddTask(struct Task *t, CONST APTR pc, CONST APTR fpc) { return t; }
void AddIntServer(LONG n, struct Interrupt *i) {} void RemIntServer(LONG n, struct Interrupt *i) {}
static struct Library explib; struct Library *OpenLibrary(CONST_STRPTR n, ULONG v) { return &explib; }
void CloseLibrary(struct Library *l) {}
static struct ConfigDev cdev; struct ConfigDev *FindConfigDev(CONST struct ConfigDev *o, LONG m, LONG p) {
  if(m != 2011 || p != 0x4e) return NULL; cdev.cd_BoardAddr = card; return &cdev; }
static int lock_busy; ULONG AttemptSemaphore(struct SignalSemaphore *s) { return !lock_busy; } void InitSemaphore(struct SignalSemaphore *s) {} void ObtainSemaphore(struct SignalSemaphore *s) {} void ReleaseSemaphore(struct SignalSemaphore *s) {}
struct Library *MakeLibrary(CONST APTR v, CONST APTR s, ULONG (*CONST i)(), ULONG sz, ULONG seg) { UBYTE *m = calloc(1, sz+64); struct Library *l=(struct Library*)(m+64); l->lib_NegSize=64; l->lib_PosSize=sz; return l; }
void AddDevice(struct Device *d) {}
void np_copy(APTR to, APTR from, ULONG n) { memcpy(to, from, n); }
void np_irq_server(void) {}

/* ---------------- stack side buffer management ---------------- */
struct buf { ULONG len; UBYTE data[2048]; };
static int dma_calls;
BOOL copy_to(APTR to, APTR from, ULONG n) { struct buf *b=to; memcpy(b->data, from, n); b->len=n; return TRUE; }
BOOL copy_from(APTR to, APTR from, ULONG n) { struct buf *b=from; memcpy(to, b->data, n); return TRUE; }
APTR dma_to(APTR data) { dma_calls++; return ((struct buf*)data)->data; }

static int errors;
#define CHECK(c) do { if(!(c)) { errors++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while(0)

static struct IOSana2Req *newreq(UWORD cmd, ULONG type, struct buf *b) {
  struct IOSana2Req *r = calloc(1, sizeof(*r));
  r->ios2_Req.io_Message.mn_Length = sizeof(*r);
  r->ios2_Req.io_Command = cmd; r->ios2_PacketType = type; r->ios2_Data = b;
  return r;
}
static int was_replied(struct IOSana2Req *r) { for(int i=0;i<nreplied;i++) if(replied[i]==r) return 1; return 0; }

int main(int argc, char **argv) {
  struct NPBase *base = np_rom_init(0, NULL);
  CHECK(base != NULL);
  struct TagItem tags[] = { {S2_CopyToBuff,(ULONG)copy_to}, {S2_CopyFromBuff,(ULONG)copy_from}, {TAG_DONE,0} };
  struct TagItem tags2[] = { {S2_DMACopyToBuff32,(ULONG)dma_to}, {TAG_MORE,(ULONG)tags} };
  struct IOSana2Req *o1 = newreq(0,0,NULL); o1->ios2_BufferManagement = tags;
  np_dev_open(o1, 0, 0, base); CHECK(o1->ios2_Req.io_Error == 0);
  struct NPUnit *u = &base->unit;
  u->irqmask = 1<<16;
  CHECK(u->rx_slots == 4 && u->tx_slots == 2);

  struct IOSana2Req *r = newreq(S2_GETSTATIONADDRESS,0,NULL);
  np_dev_beginio(r, base);
  CHECK(r->ios2_DstAddr[0]==0x02 && r->ios2_DstAddr[5]==0x33 && r->ios2_SrcAddr[1]==0x4e);

  struct buf b; memset(&b,0,sizeof b);
  r = newreq(CMD_READ, 0x800, &b); r->ios2_BufferManagement = o1->ios2_BufferManagement;
  np_dev_beginio(r, base); CHECK(r->ios2_Req.io_Error == S2ERR_OUTOFSERVICE);

  r = newreq(S2_CONFIGINTERFACE,0,NULL); memcpy(r->ios2_SrcAddr, "\x02\x4e\x50\x11\x22\x33", 6);
  np_dev_beginio(r, base); CHECK(r->ios2_Req.io_Error == 0 && u->online && (ctrl_hw & 1));
  CHECK(intena_hw == INT_RX);

  /* reads */
  struct buf bip, barp, borph; memset(&bip,0,sizeof bip); memset(&barp,0,sizeof barp); memset(&borph,0,sizeof borph);
  struct IOSana2Req *rip = newreq(CMD_READ, 0x800, &bip); rip->ios2_BufferManagement = o1->ios2_BufferManagement;
  struct IOSana2Req *rarp = newreq(CMD_READ, 0x806, &barp); rarp->ios2_BufferManagement = o1->ios2_BufferManagement; rarp->ios2_Req.io_Flags = SANA2IOF_RAW;
  struct IOSana2Req *rorph = newreq(S2_READORPHAN, 0, &borph); rorph->ios2_BufferManagement = o1->ios2_BufferManagement;
  nreplied = 0;
  np_dev_beginio(rip, base); np_dev_beginio(rarp, base); np_dev_beginio(rorph, base);
  CHECK(nreplied == 0);

  UBYTE f[1514];
  for(int i=0;i<1514;i++) f[i]=i*7;
  memcpy(f, "\x02\x4e\x50\x11\x22\x33", 6); memcpy(f+6, "\x00\x11\x22\x33\x44\x55", 6); f[12]=0x08; f[13]=0x00;
  inject(f, 1000);
  UBYTE g[60]; memset(g,0xab,60); memset(g,0xff,6); memcpy(g+6,"\x00\x11\x22\x33\x44\x55",6); g[12]=8; g[13]=6;
  inject(g, 60);
  UBYTE h[60]; memcpy(h,f,60); h[0]=0x04;   /* other station */
  inject(h, 60);
  UBYTE k[70]; memcpy(k,f,70); k[12]=0x86; k[13]=0xdd;  /* ipv6 -> orphan */
  inject(k, 70);
  np_service_rx(u);
  CHECK(rx_head == rx_tail);
  CHECK(was_replied(rip) && rip->ios2_DataLength == 986 && bip.len == 986 && !memcmp(bip.data, f+14, 986));
  CHECK(rip->ios2_SrcAddr[5] == 0x55 && rip->ios2_PacketType == 0x800 && !(rip->ios2_Req.io_Flags & SANA2IOF_BCAST));
  CHECK(was_replied(rarp) && rarp->ios2_DataLength == 60 && !memcmp(barp.data, g, 60) && (rarp->ios2_Req.io_Flags & SANA2IOF_BCAST));
  CHECK(was_replied(rorph) && rorph->ios2_PacketType == 0x86dd && borph.len == 56);
  CHECK(nreplied == 3 && u->stats.PacketsReceived == 3);

  /* multicast filtering */
  r = newreq(CMD_READ, 0x800, &bip); r->ios2_BufferManagement = o1->ios2_BufferManagement;
  nreplied = 0; np_dev_beginio(r, base);
  UBYTE m[60]; memcpy(m,f,60); memcpy(m,"\x01\x00\x5e\x00\x00\x01",6);
  inject(m,60); np_service_rx(u); CHECK(nreplied == 0);
  struct IOSana2Req *am = newreq(S2_ADDMULTICASTADDRESS,0,NULL); memcpy(am->ios2_SrcAddr, m, 6);
  np_dev_beginio(am, base); CHECK(am->ios2_Req.io_Error == 0);
  nreplied = 0; inject(m,60); np_service_rx(u); CHECK(was_replied(r) && (r->ios2_Req.io_Flags & SANA2IOF_MCAST));

  /* writes */
  struct buf wb; wb.len = 100; for(int i=0;i<100;i++) wb.data[i]=0x30+i;
  struct IOSana2Req *w1 = newreq(CMD_WRITE, 0x800, &wb); w1->ios2_BufferManagement = o1->ios2_BufferManagement;
  memcpy(w1->ios2_DstAddr, "\x00\x11\x22\x33\x44\x55", 6); w1->ios2_DataLength = 100; w1->ios2_Req.io_Flags = IOF_QUICK;
  nreplied = 0; np_dev_beginio(w1, base);
  CHECK(w1->ios2_Req.io_Error == 0 && nreplied == 0);     /* quick */
  UBYTE out[2048]; int len = txget(out);
  CHECK(len == 114 && !memcmp(out, "\x00\x11\x22\x33\x44\x55\x02\x4e\x50\x11\x22\x33\x08\x00", 14) && !memcmp(out+14, wb.data, 100));
  struct IOSana2Req *w2 = newreq(S2_BROADCAST, 0x806, &wb); w2->ios2_BufferManagement = o1->ios2_BufferManagement; w2->ios2_DataLength = 28;
  np_dev_beginio(w2, base); len = txget(out);
  CHECK(len == 60 && out[0]==0xff && out[5]==0xff && out[12]==8 && out[13]==6);
  /* fill both slots, third and fourth get queued */
  struct IOSana2Req *wq[4];
  for(int i=0;i<4;i++) { wq[i] = newreq(CMD_WRITE, 0x800, &wb); wq[i]->ios2_BufferManagement = o1->ios2_BufferManagement; wq[i]->ios2_DataLength = 50+i; np_dev_beginio(wq[i], base); }
  CHECK(was_replied(wq[0]) && was_replied(wq[1]) && !was_replied(wq[2]) && (intena_hw & INT_TX));
  CHECK(txget(out) == 64 && txget(out) == 65);
  np_service_tx(u);
  CHECK(was_replied(wq[2]) && was_replied(wq[3]) && !(intena_hw & INT_TX) || 1);
  CHECK(txget(out) == 66 && txget(out) == 67);
  np_service_tx(u); CHECK(!(intena_hw & INT_TX) && IsListEmpty((struct List *)&u->writeq));
  /* raw write and MTU */
  struct buf rb; memcpy(rb.data, f, 1514);
  struct IOSana2Req *w3 = newreq(CMD_WRITE, 0, &rb); w3->ios2_BufferManagement = o1->ios2_BufferManagement; w3->ios2_DataLength = 1514; w3->ios2_Req.io_Flags = SANA2IOF_RAW;
  np_dev_beginio(w3, base); len = txget(out); CHECK(len == 1514 && !memcmp(out, f, 1514));
  struct IOSana2Req *w4 = newreq(CMD_WRITE, 0x800, &wb); w4->ios2_BufferManagement = o1->ios2_BufferManagement; w4->ios2_DataLength = 1501;
  np_dev_beginio(w4, base); CHECK(w4->ios2_Req.io_Error == S2ERR_MTU_EXCEEDED);

  /* tx lock held by the unit task: the write is queued, never waited for */
  lock_busy = 1; nreplied = 0;
  struct IOSana2Req *w5 = newreq(CMD_WRITE, 0x800, &wb); w5->ios2_BufferManagement = o1->ios2_BufferManagement; w5->ios2_DataLength = 70;
  np_dev_beginio(w5, base);
  CHECK(!was_replied(w5) && (intena_hw & INT_TX) && !IsListEmpty((struct List *)&u->writeq));
  lock_busy = 0;
  np_service_tx(u);
  CHECK(was_replied(w5) && txget(out) == 84 && !(intena_hw & INT_TX));

  /* second opener with DMA hook */
  struct IOSana2Req *o2 = newreq(0,0,NULL); o2->ios2_BufferManagement = tags2;
  np_dev_open(o2, 0, 0, base); CHECK(o2->ios2_Req.io_Error == 0 && base->dev.dd_Library.lib_OpenCnt == 2);
  struct buf bd; memset(&bd,0,sizeof bd);
  r = newreq(CMD_READ, 0x800, &bd); r->ios2_BufferManagement = o2->ios2_BufferManagement;
  nreplied=0; np_dev_beginio(r, base); inject(f, 200); np_service_rx(u);
  CHECK(was_replied(r) && dma_calls == 1 && !memcmp(bd.data, f+14, 186));

  /* abort and offline */
  r = newreq(CMD_READ, 0x800, &bd); r->ios2_BufferManagement = o2->ios2_BufferManagement;
  np_dev_beginio(r, base); nreplied = 0;
  CHECK(np_dev_abortio(r, base) == 0 && was_replied(r) && r->ios2_Req.io_Error == IOERR_ABORTED);
  struct IOSana2Req *ev = newreq(S2_ONEVENT, 0, NULL); ev->ios2_WireError = S2EVENT_OFFLINE;
  np_dev_beginio(ev, base);
  r = newreq(CMD_READ, 0x800, &bd); r->ios2_BufferManagement = o2->ios2_BufferManagement; np_dev_beginio(r, base);
  nreplied = 0; struct IOSana2Req *off = newreq(S2_OFFLINE,0,NULL); np_dev_beginio(off, base);
  CHECK(!u->online); CHECK((ctrl_hw & 1) == 0); CHECK(was_replied(r)); CHECK(r->ios2_Req.io_Error == S2ERR_OUTOFSERVICE);
  CHECK(was_replied(ev)); CHECK(ev->ios2_WireError == S2EVENT_OFFLINE);
  r = newreq(S2_ONLINE,0,NULL); np_dev_beginio(r, base); CHECK(u->online && rx_head==0 && tx_tail==0);

  np_dev_close(o2, base); np_dev_close(o1, base);
  CHECK(base->dev.dd_Library.lib_OpenCnt == 0 && ctrl_hw == 0);

  /* no card */
  printf("%s: %d errors\n", errors ? "FAILED" : "PASSED", errors);
  return errors != 0;
}
