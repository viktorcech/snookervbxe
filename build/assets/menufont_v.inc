; menufont_v.inc -- tools/menu_gfx.py (do not edit): the menu font -> V:$071000
    org vbank
    dta $70
    org $2000
    ins '../build/assets/menufont.bin',0,4096
    ini vram_next
    org $2000
    ins '../build/assets/menufont.bin',4096,4096
    ini vram_next
    org $2000
    ins '../build/assets/menufont.bin',8192,4096
    ini vram_next
