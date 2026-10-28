; atr.inc -- build/snookerVBXE.atr's layout (tools/make_atr.py reads it): 128-byte sectors.
; The boot loader (atrboot.asm), then from ATR_TITLE_SEC ONE byte stream, every part of it
; ZX02 (zx02.inc): the title picture's 4 KB banks (V:$030000 on), the players' photos'
; (V:$060000 on) -- hud.asm esc_quit reads these again for QUIT TO MENU -- the XEX as
; records (a segment: its address, its stream; INI / RUN: $02E2 / $02E0 and the
; address), then the other VRAM banks: their count, their numbers, a stream each
ATR_BOOT_NSEC   = 6                 ; atrboot.asm at $0500-$07FF
ATR_TITLE_SEC   = ATR_BOOT_NSEC+1
ATR_TITLE_BANKS = 15                ; title.bin: V:$030000-$03EFFF
ATR_PHOTO_BANKS = 16                ; photos.bin: V:$060000-$06FFFF
ATR_ROT_BANK    = $10               ; rotpts.bin (rot.inc ROT_PTS_BANK): banks +0..+7 ship, atrboot.asm makes +8..+31
