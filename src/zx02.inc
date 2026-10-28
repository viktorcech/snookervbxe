; zx02.inc -- the ZX02 decoder [2026-10-27, docs/mads-src/compression/zx2/zx02-optim.asm
; (DMSC, MIT), as doom-rapidus-vbxe boot.asm zx_dec takes it]: one stream from zx_gb (the
; next packed byte; it keeps X and C and leaves Y = 0) into (ZX_DST) on, its back
; references read from what it wrote -- RAM, or the MEMAC window at $3000 for a 4 KB
; bank.  tools/make_atr.py packs every stream with zx02.exe and unpacks it again in
; Python before it ships.  The includer defines ZX_OFF (2), ZX_DST (2), ZX_BIT, ZX_PTR (2)
; in the zero page and zx_gb.
.proc zx
    lda #$80
    sta ZX_BIT
    lda #0
    sta ZX_OFF              ; (the first match always sets its offset)
    sta ZX_OFF+1
    tay                     ; (Y = 0 all through: zx_gb leaves it so)
lit:
    ldx #1                  ; literals: Elias(n), then n bytes
    jsr gel
cp0:
    jsr zx_gb
    sta (ZX_DST),y
    inc ZX_DST
    bne c0
    inc ZX_DST+1
c0: dex
    bne cp0
    asl ZX_BIT
    bcs new
    inx                     ; a match at the last offset: Elias(n)
    jsr gel
cpy:
    lda ZX_DST              ; source = cursor - offset - 1 (C = 0 from gel / esk)
    sbc ZX_OFF
    sta ZX_PTR
    lda ZX_DST+1
    sbc ZX_OFF+1
    sta ZX_PTR+1
cp1:
    lda (ZX_PTR),y
    inc ZX_PTR
    bne c1
    inc ZX_PTR+1
c1: sta (ZX_DST),y
    inc ZX_DST
    bne c2
    inc ZX_DST+1
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
out:
    rts
.endp
