; mktables.asm -- mk_tables, after rdisc (cold: once at start)
; mk_tables: the page-aligned lookup tables, built at start in $0800-$0BFF
; (never loaded there: a DOS may sit low while the XEX loads).
; [2026-10-09 6502-cycles-layout/SKILL.md: page-align hot tables -- one 256-row column per page]
; [2026-10-09 vbxe-blitter/SKILL.md: stamp the bank byte once -- the screen buffers start at
;  $xx0100: 256 + 204*320 = $10000, the 64K step falls between rows 203 and 204]
; ymlo/ymmid/ymhi by the STORED row: 8..247 -> (row - 8) * 320 + SCR_OFF; the
; junk rows 0..7 and 248..255 -> rows 240..255 of the same formula, past the
; buffer's end in its next bank (a clipped polygon's spans there are harmless).
.proc mk_tables
    ldx #0
r:
    txa                         ; r = the buffer row: X - 8, or 240 + X / X for the junk rows
    cmp #8
    bcc junk
    cmp #248
    bcs row
    sbc #7                      ; (C = 0: - 8)
    bcs row                     ; (always: X >= 8)
junk:
    adc #240                    ; (C = 0)
row:
    tay                         ; r * 320 + SCR_OFF = r * 256 + r * 64 + 256
    and #3
    lsr @
    ror @
    ror @                       ; (r & 3) << 6
    sta ymlo,x
    sty rq0
    tya
    lsr @
    lsr @                       ; r >> 2 + r + 1: the middle byte, its carry the bank step
    sec
    adc rq0
    sta ymmid,x
    tay
    lda #0
    adc #0
    sta ymhi,x
    dey                         ; ymmid - 1 (>= 1: SCR_OFF)
    tya
    sta ymmid1,x
    inx
    bne r
    ldx #0                      ; shr4[i] = i >> 4
s:
    txa
    lsr @
    lsr @
    lsr @
    lsr @
    sta shr4,x
    inx
    bne s
    rts
.endp
