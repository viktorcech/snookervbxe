; zx02v.inc -- the ZX02 decoder into VRAM [2026-10-27]: zx02.inc's, but one stream runs
; on across 4 KB banks, so a match reaches back up to 32 KB (tools/make_atr.py packs the
; title, the photos, every run of VRAM banks whole).  Written through MEMAC-A ($3000,
; 4 KB: the bank in zvb, the next one when the cursor reaches $4000); a match read
; through MEMAC-B ($4000-$7FFF, 16 KB, write-only MEMB: the bank in zsb).  A = the first
; bank; MEMAC-B is left off.  The includer defines ZX_OFF (2), ZX_DST (2), ZX_BIT,
; ZX_PTR (2) in the zero page, zx_gb (zx02.inc) and MEMB.
.proc zxv
    sta zvb
    lda #0
    sta ZX_DST
    sta ZX_OFF              ; (the first match always sets its offset)
    sta ZX_OFF+1
    lda #>WINDOW
    sta ZX_DST+1
    lda #$80
    sta ZX_BIT
    jsr sel                 ; (Y = 0 from it, all through: zx_gb leaves it so)
lit:
    ldx #1                  ; literals: Elias(n), then n bytes
    jsr gel
cp0:
    jsr zx_gb
    sta (ZX_DST),y
    inc ZX_DST
    bne c0
    jsr nxa
c0: dex
    bne cp0
    asl ZX_BIT
    bcs new
    inx                     ; a match at the last offset: Elias(n)
    jsr gel
cpy:                        ; source = cursor - offset - 1 (C = 0 from gel / esk), as an
    lda zvb                 ;   offset in MEMAC-B's 16 KB bank zsb, + $80 (H: $80-$BF
    lsr @                   ;   before, never below 0 after: the offset < 32 KB)
    lsr @
    sta zsb
    lda zvb
    and #3
    asl @
    asl @
    asl @
    asl @                   ; (C = 0: a 2-bit value)
    adc ZX_DST+1            ; + $30..$3F
    adc #$80-[>WINDOW]      ; (C = 0: at most $BF)
    sta ZX_PTR+1
    lda ZX_DST
    sbc ZX_OFF
    sta ZX_PTR
    lda ZX_PTR+1
    sbc ZX_OFF+1
w:  bmi h                   ; H < $80: a 16 KB bank back
    clc
    dec zsb
    adc #$40                ; (N from it for w)
    bcc w                   ; (always: A < $C0)
h:  eor #$C0                ; $80-$BF -> $40-$7F
    sta ZX_PTR+1
    jsr bsel
cp1:
    lda (ZX_PTR),y
    inc ZX_PTR
    bne c1
    inc ZX_PTR+1
    bpl c1
    jsr nxb                 ; ($8000: MEMAC-B's next bank; A kept)
c1: sta (ZX_DST),y
    inc ZX_DST
    bne c2
    jsr nxa
c2: dex
    bne cp1
    asl ZX_BIT
    bcc lit
new:
    inx                     ; a match at a new offset: Elias(MSB + 1), LSB, Elias(n - 1);
    jsr gel                 ;   an MSB code of 0 ends the stream
    beq out
    dex
    txa
    lsr @
    sta ZX_OFF+1
    jsr zx_gb               ; (keeps the lsr's C for the ror)
    ror @
    sta ZX_OFF
    ldx #1
    jsr esk
    inx
    bcc cpy                 ; (always: C = 0 from esk)
gelg:
    asl ZX_BIT              ; an interlaced Elias-gamma code into X
    rol @
    tax
gel:
    asl ZX_BIT
    bne esk
    jsr zx_gb               ; (C = 1 kept: the old byte's stop bit)
    rol @
    sta ZX_BIT
esk:
    txa
    bcs gelg
    rts
out:
    lda #0                  ; MEMAC-B off
    beq bs
nxb:                        ; MEMAC-B's next 16 KB (A kept)
    pha
    lda #$40
    sta ZX_PTR+1
    inc zsb
    jsr bsel
    pla
    rts
bsel:
    lda zsb
    ora #$80
bs: ldy #MEMB
    sta (VB),y
    ldy #0
    rts
nxa:                        ; the cursor's next page; past $3FFF the next 4 KB bank
    inc ZX_DST+1
    lda ZX_DST+1
    cmp #>WINDOW+$10
    bne r
    lda #>WINDOW
    sta ZX_DST+1
    inc zvb
sel:
    lda zvb
    ora #$80
    ldy #MA_BSEL
    sta (VB),y
    ldy #0
r:  rts
zvb dta 0                   ; the cursor's 4 KB bank
zsb dta 0                   ; MEMAC-B's 16 KB bank
.endp
