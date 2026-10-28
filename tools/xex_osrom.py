"""xex_osrom.py -- the XEX's segments for the RAM under the OS ROM ($C000-$CFFF,
$D800-$FFFF), assembled where they run (src/osrom.asm), turned into what a loader
can load: pieces of <= 3840 bytes staged at $2040, each with a copier at $2000
and an INI on it (the ROM out a moment, NMI and IRQ off: the loader needs the OS
between segments).  In place, after MADS (tools/make_atr.py build()).

  python tools/xex_osrom.py build/snooker.xex
"""
import sys

PIECE = 3840                        # 15 pages: the staged reads stay below $3000


def copier(dst, n):
    """6502 code at $2000: the pages staged at $2040 -> dst, the ROM out meanwhile"""
    pages = (n + 255) // 256
    return bytes([
        0x78,                           # sei
        0xA9, 0x00, 0x8D, 0x0E, 0xD4,   # lda #0 / sta NMIEN
        0xAD, 0x01, 0xD3, 0x29, 0xFE, 0x8D, 0x01, 0xD3,   # PORTB & $FE: the ROM out
        0xA2, pages,                    # ldx #pages
        0xA0, 0x00,                     # ldy #0
        0xB9, 0x40, 0x20,               # l: lda $2040,y
        0x99, dst & 255, dst >> 8,      #    sta dst,y
        0xC8,                           #    iny
        0xD0, 0xF7,                     #    bne l
        0xEE, 0x14, 0x20,               #    inc l+2
        0xEE, 0x17, 0x20,               #    inc l+5
        0xCA,                           #    dex
        0xD0, 0xEE,                     #    bne l
        0xAD, 0x01, 0xD3, 0x09, 0x01, 0x8D, 0x01, 0xD3,   # PORTB | 1: the ROM in
        0xA9, 0x40, 0x8D, 0x0E, 0xD4,   # lda #$40 / sta NMIEN (the VBI, as the OS keeps it)
        0x58,                           # cli
        0x60])                          # rts


def seg(a, data):
    return bytes([a & 255, a >> 8, (a + len(data) - 1) & 255, (a + len(data) - 1) >> 8]) + data


def under_rom(a):
    return 0xC000 <= a <= 0xCFFF or 0xD800 <= a <= 0xFFFF


def main(path):
    raw = open(path, 'rb').read()
    out = bytearray()
    i, n, moved = 0, len(raw), 0
    while i < n:
        if raw[i] == 0xFF and raw[i + 1] == 0xFF:
            out += b'\xff\xff'
            i += 2
            continue
        a = raw[i] | raw[i + 1] << 8
        e = raw[i + 2] | raw[i + 3] << 8
        data = raw[i + 4:i + 5 + e - a]
        i += 5 + e - a
        if not under_rom(a):
            out += seg(a, data)
            continue
        assert under_rom(e), 'a segment across the ROM border: $%04X-$%04X' % (a, e)
        for k in range(0, len(data), PIECE):
            piece = data[k:k + PIECE]
            out += seg(0x2000, copier(a + k, len(piece)))
            out += seg(0x2040, piece)
            out += seg(0x02E2, bytes([0x00, 0x20]))       # INI $2000
            moved += len(piece)
    open(path, 'wb').write(bytes(out))
    print('xex_osrom: %d bytes for the RAM under the OS ROM, staged and copied by INI' % moved)


if __name__ == '__main__':
    main(sys.argv[1])
