; rtgprobe - checks what the P96 driver minimig.card tests in FindCard
; Prints: ID ($B8010E), STATUS ($B8010C), AvailMem(24BITDMA|FAST), AvailMem(FAST)
; Needs: ID $832x, STATUS & $fff0 = 0, 24BITDMA|FAST > $1c0000.
; Assemble with vasm:  vasmm68k_mot -Fhunkexe -o rtgprobe rtgprobe.asm

        machine 68020

        section code,code

start:
        move.l  4.w,a6
        lea     dosname(pc),a1
        moveq   #0,d0
        jsr     -552(a6)                ; OpenLibrary
        move.l  d0,d6
        beq     .exit
        move.l  d0,a6
        jsr     -60(a6)                 ; Output
        move.l  d0,d7

        lea     buf,a2
        lea     t_id(pc),a0
        bsr     puts
        moveq   #0,d0
        move.w  $b8010e,d0
        moveq   #4,d1
        bsr     hex
        lea     t_st(pc),a0
        bsr     puts
        moveq   #0,d0
        move.w  $b8010c,d0
        moveq   #4,d1
        bsr     hex
        move.l  4.w,a6
        lea     t_a1(pc),a0
        bsr     puts
        move.l  #$204,d1
        jsr     -216(a6)                ; AvailMem
        moveq   #8,d1
        bsr     hex
        lea     t_a2(pc),a0
        bsr     puts
        move.l  #$4,d1
        jsr     -216(a6)
        moveq   #8,d1
        bsr     hex
        lea     t_nl(pc),a0
        bsr     puts

        lea     buf,a0
        move.l  a2,d3
        sub.l   a0,d3                   ; length
        move.l  d7,d1
        move.l  a0,d2
        move.l  d6,a6
        jsr     -48(a6)                 ; Write
        move.l  4.w,a6
        move.l  d6,a1
        jsr     -414(a6)                ; CloseLibrary
.exit:
        moveq   #0,d0
        rts

puts:   move.b  (a0)+,d2
        beq     .e
        move.b  d2,(a2)+
        bra     puts
.e:     rts

hex:    ; d0 value, d1 digits -> (a2)+
        subq.l  #1,d1
.l:     rol.l   #4,d0
        move.b  d0,d2
        and.b   #15,d2
        add.b   #'0',d2
        cmp.b   #'9',d2
        ble     .o
        addq.b  #7,d2
.o:     move.b  d2,(a2)+
        dbra    d1,.l
        rts

dosname: dc.b   "dos.library",0
t_id:   dc.b    "ID=",0
t_st:   dc.b    " STATUS=",0
t_a1:   dc.b    " AVAIL_24DMA_FAST=",0
t_a2:   dc.b    " AVAIL_FAST=",0
t_nl:   dc.b    10,0
        even
        section bss,bss
buf:    ds.b    128
