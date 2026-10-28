; menufont2_v.inc -- tools/menu_gfx.py (do not edit): the small font -> V:$05E000
    org vbank
    dta $5D
    org $2000
    ins '../build/assets/menufont2.bin',0,4096
    ini vram_next
    org $2000
    ins '../build/assets/menufont2.bin',4096,4096
    ini vram_next
