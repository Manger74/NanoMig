| nanoport_test.s - test rom for the nanoport network card in the verilator simulation
| GNU as syntax, see sim/nanoport/Makefile. Prints over the serial port:
| upper case letter = test passed, lower case = failed, then two timings
| (CIA ticks for 16 KiB read from the card and from chip ram)
	.text
	.long	0x400
	.long	0xf80010
	.org	0x10
start:	move.l	#60000,d0
1:	subq.l	#1,d0
	bne.s	1b
	lea	0x400,sp
	move.b	#3,0xbfe201
	move.b	#2,0xbfe001		| rom overlay off
	move.w	#0x7fff,0xdff09a
	move.w	#0x7fff,0xdff09c
	move.w	#368,0xdff032		| 9600 baud
	moveq	#'S',d0
	bsr	putc

	| A: er_Type upper nibble of the first board must be $C (Zorro II, no mem)
	move.b	0xe80000,d0
	and.b	#0xf0,d0
	cmp.b	#0xc0,d0
	seq	d7
	moveq	#'A',d0
	bsr	result

	| B: manufacturer $07DB (inverted nibbles at $10..$16)
	lea	0xe80010,a0
	moveq	#0,d1
	moveq	#3,d2
2:	move.b	(a0),d0
	addq.l	#2,a0
	not.b	d0
	lsr.b	#4,d0
	lsl.w	#4,d1
	or.b	d0,d1
	dbra	d2,2b
	cmp.w	#0x07db,d1
	seq	d7
	moveq	#'B',d0
	bsr	result

	| C: configure at $E90000, ID register
	move.b	#0x90,0xe8004a
	move.b	#0xe9,0xe80048
	move.w	0xe9c000,d1
	cmp.w	#0x4e50,d1
	seq	d7
	moveq	#'C',d0
	bsr	result

	| I: the fast ram board follows in the chain (run with FASTRAM=1)
	move.b	0xe80000,d0
	and.b	#0xf0,d0
	cmp.b	#0xe0,d0
	seq	d7
	moveq	#'I',d0
	bsr	result

	lea	0xe90000,a5		| card base
	| D: INTENA readback, status: 2 free tx slots, no rx
	move.w	#2,0xc00a(a5)
	move.w	0xc00a(a5),d1
	cmp.w	#2,d1
	bne.s	3f
	move.w	0xc002(a5),d1
	and.w	#0x00ff,d1
	cmp.w	#0x0020,d1
3:	seq	d7
	moveq	#'D',d0
	bsr	result

	| E: INT2 (PORTS) is requested while TX slots are free
	move.w	0xdff01e,d1
	btst	#3,d1
	seq	d1
	tst.b	d1
	seq	d7
	moveq	#'E',d0
	bsr	result

	| F: fill both TX slots with long word writes and movem, TXGO twice
	lea	0x8000(a5),a0
	move.w	#60,(a0)+
	move.l	#0x11223344,(a0)+
	movem.l	d0-d7/a1-a4,(a0)
	move.w	#0,0xc008(a5)
	lea	0x8800(a5),a0
	move.w	#61,(a0)
	move.b	#0x55,0x8802+60(a5)	| odd tail byte
	move.w	#0,0xc008(a5)
	move.w	#0,0xc008(a5)		| no free slot, ignored
	move.w	0xc002(a5),d1
	and.w	#0x00ff,d1
	tst.w	d1			| 0 free, 0 rx
	bne.s	4f
	move.w	0xc004(a5),d1
	cmp.w	#0x0000,d1		| tail wrapped to slot 0
4:	seq	d7
	moveq	#'F',d0
	bsr	result

	| G: no INT2 anymore after clearing the request
	move.w	#0x0008,0xdff09c
	move.w	0xdff01e,d1
	btst	#3,d1
	sne	d1
	tst.b	d1
	seq	d7
	moveq	#'G',d0
	bsr	result

	| H: CTRL ring reset brings the free slots back, online bit in STATUS
	move.w	#0x0081,0xc00c(a5)
	move.w	0xc002(a5),d1
	cmp.w	#0x4020,d1
	seq	d7
	moveq	#'H',d0
	bsr	result

	| speed: read 16 KiB from the card and from chip ram, CIA-A timer A ticks
	lea	0x0000(a5),a0
	bsr	timed_read
	move.w	d7,d0
	bsr	puthex
	moveq	#' ',d0
	bsr	putc
	lea	0x10000,a0
	bsr	timed_read
	move.w	d7,d0
	bsr	puthex

	moveq	#'Z',d0
	bsr	putc
5:	bra.s	5b

| a0 = source, returns elapsed timer ticks in d7
timed_read:
	move.b	#0xff,0xbfe401
	move.b	#0xff,0xbfe501
	move.b	#0x11,0xbfee01		| force load, start, continuous
	move.w	#16384/48-1,d6
6:	movem.l	(a0)+,d0-d5/a1-a6
	dbra	d6,6b
	move.b	#0x00,0xbfee01		| stop
	moveq	#0,d7
	move.b	0xbfe501,d7
	lsl.w	#8,d7
	move.b	0xbfe401,d7
	not.w	d7
	rts

| Z flag set = pass, d0 = test letter
result:	tst.b	d7
	bne.s	1f
	or.b	#0x20,d0
1:	bra	putc

puthex:	moveq	#3,d2
	move.w	d0,d3
1:	rol.w	#4,d3
	move.w	d3,d0
	and.w	#15,d0
	add.b	#'0',d0
	cmp.b	#'9',d0
	bls.s	2f
	addq.b	#7,d0
2:	bsr.s	putc
	dbra	d2,1b
	rts

putc:	move.w	0xdff018,d1
	btst	#13,d1
	beq.s	putc
	and.w	#0xff,d0
	or.w	#0x100,d0
	move.w	d0,0xdff030
	rts
