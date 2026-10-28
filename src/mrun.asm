; mrun.asm -- rfill's merged rows, in free RAM below the loader's $2000 (as the
; palette at lbuf_lo).
; [2026-10-21 vbxe-blitter/SKILL.md: fewer, larger blits -- a row whose span equals the
;  one before joins its BCB (h rows, dst step y 320); fable-skill-atari/SKILL.md 5: the
;  same pixels in the same order; 6502-idioms/SKILL.md: code size is RAM -- the slopes'
;  integer steps read from rfill's own operands, only the hot ones copied]
; ==========================================================================
; mrun: a run of rfill's rows (8..211) whose two chains both move under one
; pixel a row (rfill.up checked: m1 = 0, or $FF with m0 <> 0).  A row's span
; depends only on the chains' integer x: while neither moves, the rows join
; one blit; a move sends the blit so far (FB+14 = its rows - 1) and starts
; the next.  X = the row, Y = the rows of the run; on to rfill.rowend with
; the chains stepped past the run, X the row after it, FB+14 = 0.
; ==========================================================================
.proc mrun
; [2026-10-28 6502-idioms/SKILL.md: a known flag is not set again -- row needs no clc (flush
;  leaves C = 0); Y known 0 at the end: sty.  Measured: X from the blit's rows at flush
;  instead of inx a row cost more (13243 vs 12901 a frame: few rows a blit)]
    lda rfill.ma0+1         ; the fraction steps and the branches on their carry
    sta ma0+1               ; (bcs: m >= 0 moves on a carry, bcc: m < 0 on none)
    lda rfill.ba
    sta ca
    lda rfill.mb0+1
    sta mb0+1
    lda rfill.bb
    sta cb
    sta cbb
    clc                     ; (row: C = 0, as flush leaves it)
row:                        ; this row's fields, as rfill.row; C = 0
    lda rxb+1               ; d = xb - xa - 1
    sbc rxa+1
    sta FB+12
    lda rxb+2
    sbc rxa+2
    bmi rare                ; empty or crossed: rfill's own loop takes the rest
    sta FB+13
    lda ymlo,x              ; C = 1: dst = row * 320 - 256 + (x + 255) + 1
    adc rxa+1
    sta FB+6
    lda ymmid1,x
    adc rxa+2
    sta FB+7
    sty myst                ; the blit's first row: Y here
step:                       ; the fractions; a carry (or none) moves an integer x
    clc
    lda rxa
ma0 adc #0
    sta rxa
ca  bcs xa
    clc
    lda rxb
mb0 adc #0
    sta rxb
cb  bcs xb
    inx                     ; the next row's span is this one's: the blit grows
    dey
    bne step
    dex                     ; the run is over: its blit, rows myst (flush's
    iny                     ;   inx / dey give X, Y back)
    bne flush               ; (always)
rare:
    pha
    lda #0                  ; (nothing pending: the plain blits are one row)
    sta FB+14
    pla
    jmp rfill.rare
xa:                         ; C: the move (bcs 1 / bcc 0) -- x += m1 + C, 16 bits
    lda rxa+1
    adc rfill.ma1+1
    sta rxa+1
    lda rxa+2
    adc rfill.ma1+1
    sta rxa+2
    clc                     ; chain B's step all the same
    lda rxb
    adc mb0+1
    sta rxb
cbb bcs xb
    jmp flush               ; B stays (C either way: bcs / bcc patched)
xb:
    lda rxb+1
    adc rfill.mb1+1
    sta rxb+1
    lda rxb+2
    adc rfill.mb1+1
    sta rxb+2
flush:                      ; the blit so far: rows myst - Y + 1
    tya
    clc
    sbc myst                ; (Y <= myst: a borrow, C = 0 -- row's own)
    eor #$FF                ; myst - Y = its rows - 1
    sta FB+14
wt  lda $D653               ; BUSY (page patched by set_angle)
    bne wt
    lda #1
st  sta $D653               ; START
    inx
    dey
    jne row
    sty FB+14               ; (Y = 0) the run is over, its last blit sent
    jmp rfill.rowend
.endp
    ert >mrun.step <> >[mrun.xa-1]  ; the hot loop in one page
    ert *>$0F00                 ; (ymmid1 from $0F00)
    org $1728                   ; ($1728-$174F free)

; mtest: rfill.up, a run of 4+ rows -> mrun when both chains move under 1 px a
; row (m1 = 0, or $FF with m0 <> 0), else rfill.row as ever.  X, Y kept.
.proc mtest
    lda rfill.ma1+1
    beq ea
    cmp #$FF
    bne no
    lda rfill.ma0+1
    beq no
ea:
    lda rfill.mb1+1
    beq eb
    cmp #$FF
    bne no
    lda rfill.mb0+1
    beq no
eb:
    jmp mrun
no:
    jmp rfill.row
.endp
    ert *>$1750
