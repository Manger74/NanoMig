; rtgdemo - NanoMig RTG bring-up test (needs the "rtg" core variant)
;
; Allocates a 400x300 8 bit framebuffer in fast ram, fills it with an xor
; pattern, programs a palette and switches the hdmi output to the 800x600 rtg
; mode with 2x2 pixel doubling. Press the left mouse button to switch back to
; the normal Amiga video and exit.
;
; Assemble with vasm:  vasmm68k_mot -Fhunkexe -o rtgdemo rtgdemo.asm
; The rtg core follows the registers of the MiSTle MiniMig RTG layout (see src/rtg/README.md).

        machine 68020

RTG     = $b80100               ; register base, see src/rtg/README.md
STRIDE  = 400                   ; bytes per source row (multiple of 16)
WIDTH   = 400
HEIGHT  = 300
FBSIZE  = STRIDE*HEIGHT

        section code,code

start:
        movem.l d2-d7/a2-a6,-(sp)
        move.l  4.w,a6

        ; framebuffer: must be below $600000 (sdram address = cpu address there)
        move.l  #FBSIZE+16,d0
        move.l  #$10004,d1              ; MEMF_FAST|MEMF_CLEAR
        jsr     -198(a6)                ; AllocMem
        move.l  d0,fbmem
        beq     .exit
        add.l   #15,d0
        and.l   #$fffffff0,d0           ; 16 byte aligned
        move.l  d0,a2
        cmp.l   #$600000,d0
        bhs     .free                   ; not in the fast ram area the scanout can see

        ; xor pattern
        moveq   #0,d2                   ; y
.ly:    move.l  d2,d4
        mulu.w  #STRIDE,d4              ; y*400
        lea     0(a2,d4.l),a3
        moveq   #0,d3                   ; x
.lx:    move.l  d3,d4
        eor.b   d2,d4
        move.b  d4,(a3)+
        addq.w  #1,d3
        cmp.w   #WIDTH,d3
        blt.s   .lx
        addq.w  #1,d2
        cmp.w   #HEIGHT,d2
        blt.s   .ly

        ; palette: $00RRGGBB, index i -> r=i, g=255-i, b=(i*5)&255
        lea     RTG+$300,a0             ; $b80400
        moveq   #0,d2
.lp:    move.l  d2,d0
        lsl.l   #8,d0                   ; r<<8 ...
        move.w  #255,d1
        sub.w   d2,d1
        or.w    d1,d0                   ; ... r g
        lsl.l   #8,d0
        move.w  d2,d1
        mulu.w  #5,d1
        and.w   #255,d1
        or.w    d1,d0                   ; r g b
        move.l  d0,(a0)+                ; hi word first, then lo word
        addq.w  #1,d2
        cmp.w   #256,d2
        blt.s   .lp

        ; configuration
        lea     RTG,a0
        move.l  a2,(a0)                 ; $100/$102 framebuffer address
        move.w  #$8000,4(a0)            ; $104 8 bit palette mode
        move.w  #1,6(a0)                ; $106 (rgb565, ignored in palette mode)
        move.w  #$0005,$14(a0)          ; $114 2x horizontal, 2x vertical
        move.w  #STRIDE/16,$16(a0)      ; $116 stride in 16 byte units
        move.w  #0,$18(a0)              ; $118 viewport h start (16 pixel units)
        move.w  #50,$1a(a0)             ; $11a viewport h stop  = 800 pixels
        move.w  #0,$1c(a0)              ; $11c viewport v start (16 line units)
        move.w  #37,$1e(a0)             ; $11e viewport v stop  = 592 lines (296 source rows)
        move.w  #WIDTH/16,$20(a0)       ; $120 visible source line in 16 byte units
        move.w  #1,$10(a0)              ; $110 show the rtg display

.wait:  btst    #6,$bfe001              ; left mouse button (active low)
        bne.s   .wait

        lea     RTG,a0
        move.w  #0,$10(a0)              ; back to the normal video

.rel:   btst    #6,$bfe001              ; wait for the button to be released
        beq.s   .rel
.free:  move.l  fbmem,a1
        move.l  #FBSIZE+16,d0
        jsr     -210(a6)                ; FreeMem
.exit:  moveq   #0,d0
        movem.l (sp)+,d2-d7/a2-a6
        rts

        section data,bss
fbmem:  ds.l    1
