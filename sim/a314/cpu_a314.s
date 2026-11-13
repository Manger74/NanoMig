; 68k test program for tb_cpu_a314.v: what a314.device does on the clockport
; (build: vasmm68k_mot -Fbin -m68020 -o cpu_a314.bin cpu_a314.s, see run.sh)
	org	0
	dc.l	$8000			; SSP
	dc.l	start			; PC

	org	$100
start:	lea	$d80001,a0		; SRAM, +4 IRQ, +8 A_LO, +12 A_HI
	move.b	#$23,8(a0)		; pointer = $0123
	move.b	#$01,12(a0)
	lea	src(pc),a1
	moveq	#63,d0
w:	move.b	(a1)+,(a0)		; 64 bytes to the A314 RAM (WriteMemA314)
	dbra	d0,w
	move.b	#$23,8(a0)
	move.b	#$01,12(a0)
	lea	dst,a1
	moveq	#63,d0
r:	move.b	(a0),(a1)+		; read them back (ReadMemA314)
	dbra	d0,r
	move.b	#$83,4(a0)		; set cp_irq and pi_irq
	move.b	4(a0),res		; IRQ register: bit 0 = cp_irq
	move.b	#$01,4(a0)		; clear cp_irq
	move.b	4(a0),res+1
	move.b	8(a0),res+2		; A_LO reads 0
	move.l	#$600df00d,done
stop:	bra.s	stop

	org	$200
src:	dc.b	$00,$11,$22,$33,$44,$55,$66,$77,$88,$99,$aa,$bb,$cc,$dd,$ee,$ff
	dc.b	$01,$12,$23,$34,$45,$56,$67,$78,$89,$9a,$ab,$bc,$cd,$de,$ef,$f0
	dc.b	$a5,$5a,$c3,$3c,$0f,$f0,$81,$18,$7e,$e7,$42,$24,$99,$66,$12,$21
	dc.b	$fe,$dc,$ba,$98,$76,$54,$32,$10,$13,$57,$9b,$df,$02,$46,$8a,$ce

	org	$1000
dst:	ds.b	64
res:	ds.b	4
done:	ds.l	1
