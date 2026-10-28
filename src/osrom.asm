; osrom.asm -- the RAM under the OS ROM ($C000-$CFFF, $D800-$FFFF): the ROM is out
; from the menu on (menu.asm os_off), so the game's own NMI / IRQ entries, the
; VBI's exit and code that only the game runs live here.  Each chunk is staged at
; $2040 by the XEX and copied by its INI with the ROM out a moment (NMI and IRQ off
; meanwhile; the loader needs the OS between segments).
; [2026-10-22 6502-idioms/SKILL.md: code size is RAM -- the OS's 14 KB taken back
;  (mads-src/A800-OS-XL-Rev2-main: at run time the game needed only its NMI / IRQ
;  entries, XITVBV, the keyboard IRQ); 6502-nmos-atari/SKILL.md: handlers short,
;  save only what they use]
NMIEN   = $D40E
NMIRES  = $D40F
NMIST   = $D40F
VVBLKI  = $0222
KBCODE  = $D209
CH1     = $02F2

; (tools/xex_osrom.py turns every segment here into staged pieces, each copied by
; its INI with the ROM out a moment)

; --- $C000: the rules (cold: once a shot)
    org $C000
    icl 'rules.asm'
    icl 'snooker.asm'
    ert *>$D000

; --- $D800: the physics, the maths, the balls' setup and draw list, render:
; only the game runs them (after os_off)
    org $D800
    icl 'objects.asm'
    icl 'physics.asm'
    icl 'math.asm'          ; (the AI's window never covers it here)
    icl 'render.asm'
    ert *>$FF00

; --- $FF00: the interrupt entries and the vectors
    org $FF00
; nmi_h: as the OS's: a DLI (none here) through VDSLST, else A, X, Y saved and the
; immediate VBI (vbi.asm) through VVBLKI
.proc nmi_h
    bit NMIST
    bpl v
    jmp ($0200)             ; (VDSLST)
v:
    pha
    txa
    pha
    tya
    pha
    sta NMIRES
    jmp (VVBLKI)
.endp
    icl 'vbi.asm'           ; (here: never inside $4000-$7FFF, where snd_irq opens MEMAC-B)
; xitvbv: the VBI's end (as the OS's XITVBV)
.proc xitvbv
    pla
    tay
    pla
    tax
    pla
    rti
.endp
; irq_h: as the OS's IRQ entry: through VIMIRQ (sound.asm's snd_irq, which passes
; any other IRQ on to kbirq)
.proc irq_h
    cld
    jmp (VIMIRQ)
.endp
; kbirq: a key: CH (and KEYDEL, the debounce the VBI counts down) as the OS sets
; them; any other source (BREAK) acknowledged.  A only.
.proc kbirq
    pha
    lda IRQST
    and #$40                ; (active low)
    bne ot
    lda POKMSK              ; the keyboard's acknowledge
    and #$BF
    sta IRQEN
    lda POKMSK
    sta IRQEN
    lda KBCODE
    cmp CH1                 ; the same key again within the debounce: nothing
    bne nw
    lda KEYDEL
    bne ex
    lda KBCODE
nw:
    sta CH
    sta CH1
    lda #3
    sta KEYDEL
ex:
    pla
    rti
ot:
    lda #0                  ; anything else: acknowledged, the enables back
    sta IRQEN
    lda POKMSK
    sta IRQEN
    pla
    rti
.endp
    ert thkblk>=$4000 && thkblk<$8000     ; (the VBI calls it: an NMI may come while
                                            ;   snd_irq has MEMAC-B on $4000-$7FFF)
    :[$FFFA-*] dta 0
    dta a(nmi_h), a(nmi_h), a(irq_h)     ; NMI, RESET (an XL's RESET brings the ROM back), IRQ
