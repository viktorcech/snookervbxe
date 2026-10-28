"""menu_gfx.py -- the menu windows' look (src/menu.asm): a proportional, anti-aliased
font with a drop shadow (Segoe UI Bold, the capitals' height 8 px), in gold and in
white, blended over the windows' dark blue; the windows' colours (a top-down
gradient, the gold frame, the chosen row's strip, the draw's lines) -- each the
nearest of the title picture's palette (title_pal.bin: palette 2).

  python tools/menu_gfx.py   -> build/assets/menufont.bin (V:$071000, streamed),
                                menufont_v.inc (its stream), menugfx.inc (the tables),
                                tools/out/menu_font.png (a proof)
"""
import os
import sys
sys.dont_write_bytecode = True
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
A = os.path.join(os.path.dirname(HERE), 'build', 'assets')
FONT = 'C:/Windows/Fonts/segoeuib.ttf'
S = 4                                   # rendered at 4x, box-filtered down
CAP = 8                                 # the capitals' height (px)
MF_H = 11                               # a glyph's cell: the caps, the comma's tail, the shadow
GOLD, WHITE = (250, 204, 72), (250, 250, 240)
SHADOW = (0, 0, 0)
GRAD_TOP, GRAD_BOT = (24, 84, 48), (4, 18, 10)
BG = (12, 46, 26)                       # what the glyphs' edges are blended over
FRAME, FRAME_IN = (238, 196, 92), (128, 92, 28)
SEL = (40, 128, 70)                     # the chosen trick's strip
LINE = (222, 180, 84)                   # the draw's lines
BASE = 0x71000
CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!',-.:"   # (the menu's texts' only)

tp = open(os.path.join(A, 'title_pal.bin'), 'rb').read()
PAL = [(tp[k], tp[256 + k], tp[512 + k]) for k in range(256)]


def near(c):
    """the nearest palette index, never 0 (the blitter's mode 1: 0 is transparent)"""
    return min(range(1, 256), key=lambda i: sum((a - b) ** 2 for a, b in zip(PAL[i], c)))


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def glyphs():
    """internal codes 0..63 (ATASCII 32..95) -> (width, advance, rows of RGBA-ish
    (colour weight, shadow weight))"""
    f = ImageFont.truetype(FONT, 100)
    top, bot = f.getbbox('H')[1], f.getbbox('H')[3]
    size = round(100 * CAP * S / (bot - top))
    f = ImageFont.truetype(FONT, size)
    top = f.getbbox('H')[1]
    out = {}
    for code in range(64):
        ch = chr(code + 32)
        if ch == ' ':
            out[code] = (0, 3, None)
            continue
        if ch not in CHARS:
            continue
        x0, _, x1, _ = f.getbbox(ch)
        wpx = -(-(x1 - x0) // S) + 1
        im = Image.new('L', (wpx * S + S, MF_H * S), 0)
        ImageDraw.Draw(im).text((-x0, -top), ch, font=f, fill=255)
        im = im.resize((wpx + 1, MF_H), Image.BOX)
        cov = [[im.getpixel((x, y)) / 255 for x in range(wpx + 1)] for y in range(MF_H)]
        w = wpx + 1                                  # (+1: the shadow's column)
        rows = []
        for y in range(MF_H):
            r = []
            for x in range(w):
                c = cov[y][x] if x < wpx + 1 else 0
                sh = cov[y - 1][x - 1] if y and x else 0
                r.append((c, sh))
            rows.append(r)
        out[code] = (w, w - 1, rows)
    return out


def plane(gl, colour):
    """one colour's glyphs, each w x MF_H bytes in a row: 0 transparent"""
    blob, offs = bytearray(), {}
    for code in range(64):
        if code not in gl or gl[code][2] is None:
            continue
        w, adv, rows = gl[code]
        offs[code] = len(blob)
        for r in rows:
            for c, sh in r:
                if c < 0.08 and sh < 0.12:
                    blob.append(0)
                    continue
                px = mix(BG, SHADOW, min(1, sh * 0.85))
                blob.append(near(mix(px, colour, c)))
    return blob, offs


BASE2 = 0x5E000                         # [2026-10-27] the small font: V:$05E000-$05FFFF
CAP2, MF2_H = 6, 8                      # the tournament's draw (modes.asm tdrawb)
CHARS2 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'()?:!-"
DIM = (150, 120, 50)                    # a loser's name


def small():
    """the small font: gold, white and dim planes (the draw's headers, winners,
    losers) -> menufont2.bin (8 KB, streamed to V:$05E000), menufont2_v.inc, and
    menugfx2.inc (MF2_H, the planes' offsets, mf2_w / mf2_a / mf2_ol / mf2_oh)"""
    global CAP, MF_H, CHARS
    keep = CAP, MF_H, CHARS
    CAP, MF_H, CHARS = CAP2, MF2_H, CHARS2
    try:
        gl = glyphs()
    finally:
        CAP, MF_H, CHARS = keep
    gold, offs = plane(gl, GOLD)
    white, _ = plane(gl, WHITE)
    dim, _ = plane(gl, DIM)
    data = gold + white + dim
    assert len(data) <= 0x2000, len(data)
    open(os.path.join(A, 'menufont2.bin'), 'wb').write(bytes(data) + bytes(0x2000 - len(data)))
    V = ['; menufont2_v.inc -- tools/menu_gfx.py (do not edit): the small font -> V:$05E000',
         '    org vbank', '    dta $5D']
    for k in range(2):
        V += ['    org $2000', "    ins '../build/assets/menufont2.bin',%d,4096" % (k * 4096), '    ini vram_next']
    open(os.path.join(A, 'menufont2_v.inc'), 'w').write(chr(10).join(V) + chr(10))
    w = [gl[c][0] if c in gl else 0 for c in range(64)]
    adv = [max(1, gl[c][1] - 1) if c in gl else 2 for c in range(64)]   # (1 px tighter: the
    o = [offs.get(c, 0) + (BASE2 & 0xFFFF) for c in range(64)]          #   shadow overlaps)
    I = ['; menugfx2.inc -- tools/menu_gfx.py (do not edit): the small font (modes.asm)',
         'MF2_H = %d' % MF2_H,
         'MF2_C1 = $%04X              ; the white glyphs' % len(gold),
         'MF2_C2 = $%04X              ; the dim ones' % (len(gold) + len(white)),
         'mf2_w  dta ' + ', '.join(str(x) for x in w),
         'mf2_a  dta ' + ', '.join(str(x) for x in adv),
         'mf2_ol dta ' + ', '.join('<$%04X' % x for x in o),
         'mf2_oh dta ' + ', '.join('>$%04X' % x for x in o)]
    open(os.path.join(A, 'menugfx2.inc'), 'w').write(chr(10).join(I) + chr(10))


def main():
    gl = glyphs()
    gold, offs = plane(gl, GOLD)
    white, _ = plane(gl, WHITE)
    data = gold + white
    assert BASE + len(data) <= 0x74000, len(data)
    open(os.path.join(A, 'menufont.bin'), 'wb').write(bytes(data) + bytes(-len(data) % 4096))
    n = (len(data) + 4095) // 4096
    V = ['; menufont_v.inc -- tools/menu_gfx.py (do not edit): the menu font -> V:$071000',
         '    org vbank', '    dta $70']
    for k in range(n):
        V += ['    org $2000', "    ins '../build/assets/menufont.bin',%d,4096" % (k * 4096), '    ini vram_next']
    open(os.path.join(A, 'menufont_v.inc'), 'w').write(chr(10).join(V) + chr(10))
    w = [gl[c][0] if c in gl else 0 for c in range(64)]
    adv = [gl[c][1] if c in gl else 3 for c in range(64)]
    o = [offs.get(c, 0) + (BASE & 0xFFFF) for c in range(64)]
    grad = [near(mix(GRAD_TOP, GRAD_BOT, k / 15)) for k in range(16)]
    I = ['; menugfx.inc -- tools/menu_gfx.py (do not edit): the menu windows (menu.asm)',
         'MF_H = %d                   ; a glyph cell\'s height' % MF_H,
         'MF_C1 = $%04X              ; the white glyphs: after the gold ones' % len(gold),
         'MG_FRAME = %d' % near(FRAME), 'MG_FRIN = %d' % near(FRAME_IN), 'MG_SEL = %d' % near(SEL),
         'MG_LINE = %d' % near(LINE),
         'mf_w  dta ' + ', '.join(str(x) for x in w),
         'mf_a  dta ' + ', '.join(str(x) for x in adv),
         'mf_ol dta ' + ', '.join('<$%04X' % x for x in o),
         'mf_oh dta ' + ', '.join('>$%04X' % x for x in o),
         'mg_g  dta ' + ', '.join(str(x) for x in grad)]
    open(os.path.join(A, 'menugfx.inc'), 'w').write(chr(10).join(I) + chr(10))
    small()
    if '--png' not in sys.argv:                # (the proof picture only on demand, not every build)
        print('menu_gfx: %d bytes of glyphs (%d 4K)' % (len(data), n))
        return
    # a proof: the texts over the gradient, as the blitter puts them (python tools/menu_gfx.py --png)
    im = Image.new('RGB', (320, 60))
    for y in range(60):
        for x in range(320):
            im.putpixel((x, y), PAL[grad[min(15, y * 16 // 60)]])
    for k, (txt, pl) in enumerate((("1 THREE-BALL PLANT  O'SULLIVAN", gold), ('5 OFF THE JAW  LAST 8: 3  FINAL!', white))):
        x = 6
        for ch in txt:
            c = ord(ch) - 32
            if c in offs:
                ww = gl[c][0]
                for yy in range(MF_H):
                    for xx in range(ww):
                        v = pl[offs[c] + yy * ww + xx]
                        if v:
                            im.putpixel((x + xx, 8 + k * 20 + yy), PAL[v])
            x += adv[c]
    im.resize((960, 180), Image.NEAREST).save(os.path.join(HERE, 'out', 'menu_font.png'))
    print('menu_gfx: %d bytes of glyphs (%d 4K), gradient %s' % (len(data), n, [PAL[g] for g in grad]))
    print('frame', PAL[near(FRAME)], PAL[near(FRAME_IN)], 'sel', PAL[near(SEL)], 'line', PAL[near(LINE)])


if __name__ == '__main__':
    main()
