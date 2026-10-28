; title.asm -- the title picture, up while the XEX loads and until fire / START /
; a key (boot.asm title_wait); the game's first frame draws over it.
; [2026-10-21 6502-idioms/SKILL.md: code size is RAM -- the picture streams into the
;  visible buffer with its XDL (title.inc), this INI code and its palette are staged
;  at $2000 and the next chunk overwrites them: no game RAM.  vbxe-blitter/SKILL.md:
;  every field the frame needs in the XDL; overlay palette 2 (the game's is 1)]
    icl '../build/assets/title.inc'
COLOR4 = $02C8                      ; OS shadow of COLBK

    org $2000
.proc title_show
    lda VB+1
    jeq x                   ; no VBXE: `start` halts anyway
    ldy #PSEL
    lda #2
    sta (VB),y
    ldy #CSEL
    lda #0
    sta (VB),y
    tax
c:                          ; CSEL once, R/G/B per colour (CB steps CSEL)
    lda tpal,x
    ldy #CR
    sta (VB),y
    lda tpal+256,x
    iny
    sta (VB),y
    lda tpal+512,x
    iny
    sta (VB),y
    inx
    bne c
    ldy #PSEL               ; palette 3: the players' photos (the menu's map cells)
    lda #3
    sta (VB),y
    ldy #CSEL
    txa                     ; (X = 0)
    sta (VB),y
p3:
    lda ppal,x
    ldy #CR
    sta (VB),y
    lda ppal+256,x
    iny
    sta (VB),y
    lda ppal+512,x
    iny
    sta (VB),y
    inx
    bne p3
    ldy #PSEL               ; palette 0: the HUD's text (hud.asm HA_*): foregrounds
    txa                     ;   $20.., their backgrounds $A0.. (X = 0)
    sta (VB),y
    ldy #CSEL
    lda #$20
    sta (VB),y
h:
    ldy #CR
hc:
    lda hpal,x              ; (CB steps CSEL)
    sta (VB),y
    inx
    iny
    cpy #CB+1
    bne hc
    cpx #15
    bne h2
    ldy #CSEL
    lda #$A0
    sta (VB),y
h2:
    cpx #30
    bne h
    ldy #VB_P0              ; P0: the map's priority (as the XDL's $FE: the pointer over it)
    lda #$FE
    sta (VB),y
    ldy #XDL_ADR0
    lda #<TITLE_XDL
    sta (VB),y
    iny
    lda #>TITLE_XDL
    sta (VB),y
    iny
    lda #^TITLE_XDL
    sta (VB),y
    lda #0
    sta SDMCTL              ; ANTIC off: black around the picture
    sta COLOR4
    ldy #VIDEO_CONTROL      ; [2026-10-27] the display stays off: the menu turns it on
    lda #0                  ;   with its bar drawn (menu.asm shw) -- the picture and the
    sta (VB),y              ;   bar at once, not the picture first while the rest loads
x:
    rts
.endp
tpal
    ins '../build/assets/title_pal.bin'
ppal
    ins '../build/assets/photo_pal.bin'
hpal                        ; palette 1's black 15, yellow 10, blue 13, white 16 (vbxe_export IDX)
    ins '../build/assets/palette.bin',15*3,3    ; $20 black on $A0 yellow
    ins '../build/assets/palette.bin',15*3,3    ; $21 black on $A1 white
    ins '../build/assets/palette.bin',16*3,3    ; $22 white on $A2 blue
    ins '../build/assets/palette.bin',15*3,3    ; $23 THINKING (thkblk) on $A3 yellow
    ins '../build/assets/palette.bin',16*3,3    ; $24 white on $A4 black
    ins '../build/assets/palette.bin',10*3,3
    ins '../build/assets/palette.bin',16*3,3
    ins '../build/assets/palette.bin',13*3,3
    ins '../build/assets/palette.bin',10*3,3
    ins '../build/assets/palette.bin',15*3,3
VB_P0   = $55               ; P0 (VBXE 1.27 manual ch. 9: the map's priority register 0)
    ert *>WINDOW
    ini title_show
