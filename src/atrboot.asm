; atrboot.asm -- build/snookerVBXE.atr's boot loader [2026-10-27, after doom-rapidus-vbxe
; boot.asm]: the OS loads it to $0500 (RAM no XEX segment loads into) and enters it at
; +6.  One byte stream from ATR_TITLE_SEC through SIOV (atr.inc), every part ZX02
; (zx02.inc): the title's and the photos' banks into VRAM through the window, the XEX's
; records (a segment unpacked where it loads, its INIs called: the title shows), at its
; RUN the other VRAM banks, then the RUN.  The OS ROM in all through, 6502 code; the
; loader's state in its own RAM (the INIs run between records), $0480 the sector.
    opt h-
    icl 'atr.inc'
DCB    = $0300
SIOV   = $E459
PORTB  = $D301
BASICF = $03F8
GINTLK = $03FA
COLOR4 = $02C8
NMIEN  = $D40E
TRIG3  = $D013
SECBUF = $0480
RBUF   = $0400              ; a rotation slot (the cassette buffer: free at boot)
VB     = $80                ; the VBXE's registers (defs.inc VB: the game's own cell)
MA_CTL = $5E
MA_BSEL = $5F
MEMB   = $5D                ; (write-only: zx02v.inc's match reads)
WINDOW = $3000
ZX_OFF = $E0                ; zx02.inc's cells (game zero page, free at boot)
ZX_DST = $E2
ZX_BIT = $E4
ZX_PTR = $E5

    org $0500
    dta 0, ATR_BOOT_NSEC, a($0500), a(binit)
binit:                      ; (BOOTAD + 6: the OS enters here)
    cld
    lda PORTB               ; BASIC out for good (its ROM would take $A000-$BFFF)
    ora #$02
    sta PORTB
    lda #1
    sta BASICF
; [2026-10-28] $A000-$BFFF must be RAM (the game's code under BASIC): IDE Plus 2.0 boots
; the ATR with its SDX module on there (alt-src kmkjzide.cpp: $D1FE bit 7 = 1 SDX off, (bit 7,
; bit 0) = (1, 1) the external cart off too; written unselected) -- off, and the OS's
; cartridge check (VBI: TRIG3 = GINTLK, else it hangs) told; still no RAM: a red halt
    lda $A000
    eor #$FF
    sta $A000
    cmp $A000
    beq ram
    lda #0
    sta NMIEN               ; (no VBI between the switch and GINTLK)
    lda #$81
    sta $D1FE
    lda TRIG3
    sta GINTLK
    lda #$40
    sta NMIEN
    lda $A000
    eor #$FF
    sta $A000
    cmp $A000
    beq ram
    lda #$34                ; (a cartridge we cannot switch off: red)
    sta COLOR4
    jmp *
ram:
    lda #0                  ; the VBXE: an FX core at $D640 or $D740 (vbxe.asm probe)
    sta VB
    ldx #$D6
pr: stx VB+1
    ldy #$40
    lda (VB),y
    cmp #$10
    beq vf
    inx
    cpx #$D8
    bne pr
    jmp *                   ; (none: the game could not run)
vf: lda #$38                ; MEMAC-A: 4 KB at $3000 (the game's)
    ldy #MA_CTL
    sta (VB),y
    lda #$30                ; the title, then the photos: a stream each (zx02v.inc)
    jsr zxv
    lda #$60
    jsr zxv
rec:
    jsr zx_gb               ; a record: its address
    sta ZX_DST
    jsr zx_gb
    sta ZX_DST+1
    cmp #$02                ; INI ($02E2) or RUN ($02E0)
    bne dat
    lda ZX_DST
    cmp #$E2
    beq ini
    cmp #$E0
    beq run
dat:
    jsr zx                  ; a segment: unpacked where it loads
    jmp rec
ini:
    jsr zx_gb
    sta ji+1
    jsr zx_gb
    sta ji+2
    jsr ji
    jmp rec
run:
    jsr zx_gb
    sta jr+1
    jsr zx_gb
    sta jr+2
    jsr zx_gb               ; the VRAM: its runs of banks, each its first bank + a stream
    sta vn
vl: dec vn
    bmi rq
    jsr zx_gb
    jsr zxv
    jmp vl
; the table's rotation points (rot_ref.py rot_points): only the first quarter's banks
; ship; a slot (256 B: x lo, x hi, y lo, y hi, 64 each) a quarter turn on is (-y, x),
; so slot t + 128 is made from slot t, t = 0..383 (banks ATR_ROT_BANK+8 on)
rq: lda #$80|ATR_ROT_BANK
    sta vi                  ; the source bank (+8: the target's)
rqb lda #$30                ; the window's page
rqp sta rqc+2
    sta rw0+2
    sta rw1+2
    sta rw2+2
    sta rw3+2
    ldy #MA_BSEL
    lda vi
    sta (VB),y
    ldx #0
rqc lda $3000,x             ; the slot -> RBUF
    sta RBUF,x
    inx
    bne rqc
    lda vi
    clc
    adc #8
    sta (VB),y
    ldx #63
rqk sec                     ; x' = -y
    lda #0
    sbc RBUF+$80,x
rw0 sta $3000,x
    lda #0
    sbc RBUF+$C0,x
rw1 sta $3040,x
    lda RBUF,x              ; y' = x
rw2 sta $3080,x
    lda RBUF+$40,x
rw3 sta $30C0,x
    dex
    bpl rqk
    ldx rqc+2
    inx
    txa
    cpx #$40
    bne rqp
    inc vi
    lda vi
    cmp #$80|ATR_ROT_BANK+24
    bne rqb
jr: jmp $0000
ji: jmp $0000


; zx_gb: the stream's next byte -- keeps X and C, leaves Y = 0 (zx02.inc)
.proc zx_gb
    ldy bpos
    bne ok
    php
    stx gx
r:  ldx #11                 ; the next sector (the DCB copied each time: the INIs may
d:  lda tdcb,x              ;   use the OS's)
    sta DCB,x
    dex
    bpl d
    jsr SIOV
    bmi r                   ; an error: again
    lda SECBUF+125          ; the next sector: the MyDOS link (make_atr.py: SNOOKER.DAT,
    sta tdcb+11             ;   16-bit links, 125 bytes a sector)
    lda SECBUF+126
    sta tdcb+10
    ldx gx
    plp
    ldy #256-125            ; (Y counts up to 0: C kept)
ok: lda SECBUF-[256-125],y
    iny
    sty bpos
    ldy #0
    rts
.endp

    icl 'zx02.inc'
    icl 'zx02v.inc'

bpos dta 0                  ; the place in SECBUF, 131..255 (0: read the next sector)
gx   dta 0
vn   dta 0
vi   dta 0
; the DCB: disk 1, read a sector into SECBUF, 15 s, 128 B -- the title's first sector on
tdcb dta $31, 1, $52, $40, a(SECBUF), $0F, 0, a(128), a(ATR_TITLE_SEC)
    ert *>$0500+ATR_BOOT_NSEC*128
