; nanoport_asm.s - resident tag, interrupt server and copy routine of nanoport.device
; vasm (Motorola syntax), linked first so the device starts with "moveq #-1,d0 / rts"

	xref	_np_rom_init
	xdef	_np_irq_server
	xdef	_np_copy

RTC_MATCHWORD	equ	$4afc
NT_DEVICE	equ	3
VERSION		equ	1
LVO_Signal	equ	-324

; card registers, relative to the register block at $C000 (offsets >= $8000
; don't fit a 68000 16 bit displacement)
R_REGS		equ	$c000
R_STATUS	equ	$0002
R_INTENA	equ	$000a

; struct NPUnit (nanoport.h)
u_hw		equ	0
u_task		equ	4
u_irqmask	equ	8
u_intena	equ	12

	section	code,code

	moveq	#-1,d0			; not executable
	rts

romtag:	dc.w	RTC_MATCHWORD
	dc.l	romtag
	dc.l	endtag
	dc.b	0			; no RTF_AUTOINIT, np_rom_init builds the device
	dc.b	VERSION
	dc.b	NT_DEVICE
	dc.b	0			; priority
	dc.l	name
	dc.l	idstring
	dc.l	init

; d0 = 0, a0 = segment list, a6 = SysBase
init:	jmp	_np_rom_init

name:		dc.b	"nanoport.device",0
idstring:	dc.b	"nanoport 1.1 (23.11.2026) NanoMig network card",13,10,0
	even
endtag:

; ---------------------------------------------------------------------------
; PORTS (INT2) interrupt server, a1 = struct NPUnit
; The card keeps INT2 asserted while an enabled condition holds. The server
; masks the active sources and leaves the work to the unit task, which
; unmasks them again once everything has been processed.
; Servers get no valid a6 (any server before us in the chain may have
; changed it), so SysBase is loaded from 4. a0 is set back to the custom
; chips for servers after us that expect it. Uses d0/d1/a0/a1/a6, returns
; with Z set so the chain continues.
_np_irq_server:
	move.l	u_hw(a1),a0
	adda.l	#R_REGS,a0
	move.b	R_STATUS+1(a0),d0	; [7:4] free tx slots, [3:0] pending rx frames
	moveq	#$0f,d1
	and.b	d0,d1			; rx pending -> bit 0
	beq.s	.norx
	moveq	#1,d1
.norx:	and.b	#$f0,d0
	beq.s	.notx
	or.b	#2,d1			; tx free -> bit 1
.notx:	and.w	u_intena(a1),d1		; only the enabled sources
	beq.s	.none
	not.w	d1
	and.w	d1,u_intena(a1)
	move.w	u_intena(a1),R_INTENA(a0)
	move.l	u_irqmask(a1),d0
	move.l	u_task(a1),a1
	movea.l	4.w,a6
	jsr	LVO_Signal(a6)
.none:	lea	$dff000,a0
	moveq	#0,d0
	rts

; ---------------------------------------------------------------------------
; void np_copy(a0 = to, a1 = from, d0 = bytes), both addresses even
; 40 bytes per MOVEM pair, then long words, a word and a byte
_np_copy:
	movem.l	d2-d7/a2-a5,-(sp)
	move.l	d0,d1
	divu.w	#40,d1			; low word: blocks, high word: rest (frames are short)
	move.l	d1,d0
	swap	d0
	bra.s	.blk_e
.blk:	movem.l	(a1)+,d2-d7/a2-a5
	movem.l	d2-d7/a2-a5,(a0)
	lea	40(a0),a0
.blk_e:	dbra	d1,.blk
	move.w	d0,d1
	lsr.w	#2,d1
	bra.s	.lng_e
.lng:	move.l	(a1)+,(a0)+
.lng_e:	dbra	d1,.lng
	btst	#1,d0
	beq.s	.now
	move.w	(a1)+,(a0)+
.now:	btst	#0,d0
	beq.s	.done
	move.b	(a1),(a0)
.done:	movem.l	(sp)+,d2-d7/a2-a5
	rts

	end
