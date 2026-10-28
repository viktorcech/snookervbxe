#!/usr/bin/env python3
"""ai-snooker - VBXE asset exporter.

The Python sim is also our asset generator (assets are GENERATED, not sourced).
Outputs to build/assets/ for the MADS bring-up:
    palette.bin  256 * 3 bytes  (R,G,B 8-bit)  -- table colours + ball shades
    sprites.bin  ball sprites (indexed), anti-aliased + sphere-shaded
    discs.bin / rotpts.bin / zlut.bin  the table renderer's VRAM data (rot_export)
    geom.inc / persp.inc / rot.inc / rotdata.inc  the asm's tables

VBXE can draw round balls fine -- it just blits whatever bitmap we give it; the
roundness comes from rendering the sprites with supersampled AA + shading here.

Run:  python tools/vbxe_export.py
"""

import math
import os
import struct
import sys
sys.dont_write_bytecode = True  # no __pycache__ (the user's rule)
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import snooker_core as C                                    # noqa: E402

OUT = os.path.join(PROJ, 'build', 'assets')
VW, VH = 320, 240

# Fixed low palette indices for the table (the MADS side references these).
IDX = {
    'backdrop': 0, 'baize': 1, 'cushion': 2, 'cushtop': 3, 'rail': 4,
    'railside': 5, 'pocket': 6, 'line': 7, 'spot': 8,
    'red': 9, 'yellow': 10, 'green': 11, 'brown': 12, 'blue': 13,
    'pink': 14, 'black': 15, 'cue': 16, 'leather': 17, 'fall': 18, 'net': 19,
}

# Ball colour -> sprite VRAM bank high byte (sheet loaded into V:$00N000; the
# 6502 stores this in the ball record and project() adds it to the sprite addr).
# All 22 balls are dynamic now, so every colour needs its own depth-sprite sheet.
# Shared by export_persp (sheet files) and export_geom (per-ball bank byte).
# Every sheet is padded to SHEET_PAD bytes so a colour's base address is
# (bank byte)<<8 with the SAME low offsets -- project() adds one byte.
SHEET_PAD = 0xC00                       # every radius of rot_ref BALL_SIZES (2866 bytes)
SPRITES_VRAM = 0x001000
SND_VRAM = 0x008000                     # the sounds (tools/snd_prep.py): the sheets end before them
SHADOW_VRAM = 0x00B000                  # the ball shadows (bank 0, as the sprites), after the sounds
SHADOW_END = 0x00F000                   # the fps readout's font (src/fps.asm FPS_FONT)
BALL_BANK = {c: 0x10 + (SHEET_PAD >> 8) * i for i, c in enumerate(
    ('cue', 'red', 'yellow', 'green', 'brown', 'blue', 'pink', 'black'))}

# light direction for sphere shading (upper-left, slightly toward viewer)
_LD = (-0.40, -0.62, 0.67)
_LN = math.sqrt(sum(c * c for c in _LD))
_LD = tuple(c / _LN for c in _LD)


# ball shadows (src/objects.asm shad_all): a mask per zoom, OR-blitted (MODE 3)
# onto the erased table before the balls: 32 = penumbra, 64 = umbra
SHADOW_PEN, SHADOW_CORE = 32, 64
SHADOW_PEN_K, SHADOW_CORE_K = 0.66, 0.40
SHADOW_IN, SHADOW_OUT = 0.55, 1.20       # density 1 inside, 0 outside (ground radii, in R)


def _darken(rgb, k):
    """a colour in the shade: k of its light, a touch of blue from the room"""
    return (int(rgb[0] * k), int(rgb[1] * k), min(255, int(rgb[2] * k + 6)))


def shadow_mask(s, dyr, ryr):
    """the shadow under a sprite of radius s (d = 2s + 1 wide): the ball's
    ground point dyr x r below its centre, the ground circle seen ryr x r tall
    (r = s + 0.5) -> (mask bytes, rows), the mask d wide, its top = the
    sprite's, at least d rows.  Light from straight above (the canopy): a
    soft ellipse, full density to SHADOW_IN, none past SHADOW_OUT."""
    d, r = 2 * s + 1, s + 0.5
    cx, gy = r, r + dyr * r
    SS = 4
    rows = []
    for py in range(d + 16):
        row = []
        for px in range(d):
            acc = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    u = (px + (sx + 0.5) / SS - cx) / r
                    v = (py + (sy + 0.5) / SS - gy) / (ryr * r)
                    rho = math.sqrt(u * u + v * v)
                    acc += min(1.0, max(0.0, (SHADOW_OUT - rho) / (SHADOW_OUT - SHADOW_IN)))
            dn = acc / (SS * SS)
            row.append(SHADOW_CORE if dn >= 0.55 else SHADOW_PEN if dn >= 0.18 else 0)
        rows.append(row)
    h = d
    for y, row in enumerate(rows):
        if any(row):
            h = max(h, y + 1)
    return bytes(v for row in rows[:h] for v in row), h


class Palette:
    """256-entry RGB palette.  Indices 0..16 are the fixed table colours;
    ball shades are appended on demand.  Falls back to nearest if it fills."""

    def __init__(self):
        self.list = [(0, 0, 0)] * 256
        self.map = {}
        for name, i in IDX.items():
            self.list[i] = C.PAL[name]
            self.map[C.PAL[name]] = i
        # the ball shadows OR SHADOW_PEN / SHADOW_CORE into a table colour (< 32):
        # c | 32 = the penumbra's shade of c, c | 64 and c | 96 = the umbra's
        self.reserved = set()
        for i in range(max(IDX.values()) + 1):
            for bit, k in ((SHADOW_PEN, SHADOW_PEN_K), (SHADOW_CORE, SHADOW_CORE_K),
                           (SHADOW_PEN | SHADOW_CORE, SHADOW_CORE_K)):
                self.list[i | bit] = _darken(self.list[i], k)
                self.reserved.add(i | bit)
        self.n = max(IDX.values()) + 1

    def index(self, rgb):
        i = self.map.get(rgb)
        if i is not None:
            return i
        while self.n in self.reserved:
            self.n += 1
        if self.n < 256:
            i = self.n
            self.list[i] = rgb
            self.map[rgb] = i
            self.n += 1
            return i
        best, bd = 1, 1 << 30
        for k in range(1, self.n):
            if k in self.reserved:
                continue
            c = self.list[k]
            d = (c[0]-rgb[0])**2 + (c[1]-rgb[1])**2 + (c[2]-rgb[2])**2
            if d < bd:
                bd, best = d, k
        return best


def _quant(rgb):                       # ~16 levels/channel to bound palette size
    return ((rgb[0] & ~15) | 8, (rgb[1] & ~15) | 8, (rgb[2] & ~15) | 8)


def _shade(base, nx, ny):
    nz = math.sqrt(max(0.0, 1.0 - nx*nx - ny*ny))
    diff = max(0.0, nx*_LD[0] + ny*_LD[1] + nz*_LD[2])
    b = 0.36 + 0.64 * diff
    spec = (diff - 0.88) * 7 * 130 if diff > 0.88 else 0.0
    return (min(255, base[0]*b + spec),
            min(255, base[1]*b + spec),
            min(255, base[2]*b + spec))


def ball_sprite_rgb(base, size):
    """d*d (d=2*size+1) RGB sprite, None = transparent: a hard-edged disc of
    radius size+0.5 (it fills the box) with sphere shading.  A pixel is in when
    at least half of it is inside; no blending with the baize (at 5 px a soft
    edge was most of the ball: it looked blurred)."""
    d = 2 * size + 1
    c = size + 0.5           # the centre of the middle pixel
    r = size + 0.5
    SS = 4
    out = [None] * (d * d)
    for py in range(d):
        for px in range(d):
            inside = 0
            rs = gs = bs = 0.0
            for sy in range(SS):
                for sx in range(SS):
                    fx = px + (sx + 0.5) / SS - c
                    fy = py + (sy + 0.5) / SS - c
                    if fx*fx + fy*fy <= r*r:
                        inside += 1
                        col = _shade(base, fx / r, fy / r)
                        rs += col[0]; gs += col[1]; bs += col[2]
            if inside * 2 < SS * SS:
                continue
            out[py*d + px] = (int(rs / inside), int(gs / inside), int(bs / inside))
    return out, d


MIN_PNG_W = 960                 # every PNG for the user is at least this wide


def write_png(path, w, h, rgb):
    """RGB -> PNG.  An image narrower than MIN_PNG_W is enlarged by an
    integer factor, nearest neighbour (sharp pixels): never a small PNG."""
    k = -(-MIN_PNG_W // w) if w < MIN_PNG_W else 1
    if k > 1:
        big = bytearray()
        for y in range(h):
            line = bytearray()
            for x in range(w):
                line += rgb[(y * w + x) * 3:(y * w + x) * 3 + 3] * k
            big += bytes(line) * k
        rgb, w, h = bytes(big), w * k, h * k

    def chunk(typ, data):
        c = typ + data
        return (struct.pack('>I', len(data)) + c
                + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF))
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        rows += rgb[y * w * 3:(y + 1) * w * 3]
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(bytes(rows), 6)))
        f.write(chunk(b'IEND', b''))


# --- index-buffer raster primitives (1 byte = palette index) ---------------
def _rect(buf, x0, y0, x1, y1, idx):
    x0 = max(0, int(x0)); y0 = max(0, int(y0))
    x1 = min(VW, int(x1)); y1 = min(VH, int(y1))
    for y in range(y0, y1):
        b = y * VW
        for x in range(x0, x1):
            buf[b + x] = idx


def _fill_poly(buf, pts, idx):
    ys = [p[1] for p in pts]
    y0 = max(0, int(min(ys))); y1 = min(VH - 1, int(max(ys)) + 1)
    n = len(pts)
    for y in range(y0, y1 + 1):
        xs = []
        for i in range(n):
            ax, ay = pts[i]; bx, by = pts[(i + 1) % n]
            if (ay <= y < by) or (by <= y < ay):
                xs.append(ax + (bx - ax) * (y - ay) / (by - ay))
        if len(xs) >= 2:
            _rect(buf, min(xs), y, max(xs) + 1, y + 1, idx)


def _disc(buf, cx, cy, r, idx):
    r2 = r * r
    for y in range(int(cy - r), int(cy + r) + 1):
        if 0 <= y < VH:
            dy = y - cy
            for x in range(int(cx - r), int(cx + r) + 1):
                if 0 <= x < VW and (x - cx) ** 2 + dy * dy <= r2:
                    buf[y * VW + x] = idx


def _line(buf, x0, y0, x1, y1, idx):
    x0, y0, x1, y1 = int(x0), int(y0), int(x1), int(y1)
    dx = abs(x1 - x0); dy = -abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx + dy
    while True:
        if 0 <= x0 < VW and 0 <= y0 < VH:
            buf[y0 * VW + x0] = idx
        if x0 == x1 and y0 == y1:
            break
        e2 = 2 * err
        if e2 >= dy:
            err += dy; x0 += sx
        if e2 <= dx:
            err += dx; y0 += sy












# The XEX streams big assets into VRAM instead of keeping them in main RAM:
# every 4 KB chunk is a segment staged at $2000 followed by an INI hook
# (vram_next: the bank + 1).  Collected here, written by write_loaders().
_LOADERS = []                 # (name, file, vram base, length, nchunks)


def emit_vram_loader(name, blob, base):
    assert base & 0xFFF == 0, 'VRAM loader base must be 4 KB aligned'
    _LOADERS.append((name, name + '.bin', base, len(blob), (len(blob) + 4095) // 4096))


def write_loaders():
    """vram_load.inc: per stream a one-byte segment seeding vbank (its first bank
    - 1, as title.inc does: no INI stub in RAM), then its chunks, each 4 KB staged
    at $2000 and copied by vram_next (the bank + 1).  vram_stubs.inc: empty."""
    nl = chr(10)
    with open(os.path.join(OUT, 'vram_stubs.inc'), 'w') as f:
        f.write('; generated by vbxe_export.py -- do not hand-edit (no INI stubs: vram_load.inc seeds vbank)' + nl)
    with open(os.path.join(OUT, 'vram_load.inc'), 'w') as f:
        f.write('; generated by vbxe_export.py -- do not hand-edit (VRAM segments)' + nl)
        for name, fn, base, ln, nch in _LOADERS:
            f.write('    org vbank%s    dta $%02X                ; %s: vram_next steps to V:$%05X%s'
                    % (nl, ((base >> 12) - 1) & 255, name, base, nl))
            for k in range(nch):
                off = k * 4096
                n = min(4096, ln - off)
                f.write("    org $2000%s    ins '../build/assets/%s',%d,%d%s    ini vram_next%s"
                        % (nl, fn, off, n, nl, nl))
    return sum(l[3] for l in _LOADERS)


def export_persp(pal, sizes):
    """Ball sprites at every depth size any view uses + persp.inc (sizeoff
    tables).
    The 6502 projects a (rotated) table point (x', y') per ball:
        i  = xrow[(x'>>16) + 32 >> 1]        ; depth row (32 mm buckets from -512 mm)
        sx = prow_cx[i] + (prow_slope[i]*(y'-889))>>8   ; signed 8x16 mul
        sy = prow_sy[i] ; size = prow_size[i]
    """

    def build_sheet(color):
        sh = bytearray()
        offs = [0] * (max(sizes) + 1)
        for s in sizes:
            rgb, d = ball_sprite_rgb(C.PAL[color], s)
            offs[s] = len(sh)
            for px in rgb:
                sh.append(0 if px is None else pal.index(_quant(px)))
        return sh, offs

    # one depth-sprite sheet per colour, identical layout (same sizes and
    # offsets), each padded to SHEET_PAD and concatenated -> sprites.bin, which
    # the loader streams into VRAM at SPRITES_VRAM.  The 6502 reuses sizeoff_*
    # and only switches the per-ball bank byte.
    sheet, sizeoff = None, None
    blob = bytearray()
    for color in sorted(BALL_BANK, key=lambda c: BALL_BANK[c]):
        sh, off = build_sheet(color)
        assert len(sh) <= SHEET_PAD, 'sprite sheet %d > SHEET_PAD' % len(sh)
        if sheet is None:
            sheet, sizeoff = sh, off          # layout identical across colours
        blob += bytes(sh) + bytes(SHEET_PAD - len(sh))
    assert SPRITES_VRAM + len(blob) <= SND_VRAM
    with open(os.path.join(OUT, 'sprites.bin'), 'wb') as f:
        f.write(bytes(blob))
    emit_vram_loader('sprites', blob, SPRITES_VRAM)
    # the shadow masks per zoom (the camera's pitch at the pivot: the ground
    # point's drop and the ground circle's height, in ball radii) and per
    # sprite radius the zoom uses -> SHADOW_VRAM; their addresses, rows into
    # the zoom blocks (rot_export.patch_shadows)
    import rot_ref as RR
    import rot_export as RE
    rr = RR.Renderer(RR.scene_real())
    shb, tabs = bytearray(), []
    for Z in rr.Z:
        p = Z.proj
        c, g = p(RR.CX, RR.CY, C.BALL_R), p(RR.CX, RR.CY, 0.0)
        a, b = p(RR.CX - C.BALL_R, RR.CY, 0.0), p(RR.CX + C.BALL_R, RR.CY, 0.0)
        rpx = p(RR.CX, RR.CY + C.BALL_R, C.BALL_R)[0] - c[0]
        t = {}
        for s in sorted(set(Z.BS)):
            mask, h = shadow_mask(s, max(0.0, (g[1] - c[1]) / rpx), max(0.2, (a[1] - b[1]) / 2 / rpx))
            t[s] = (SHADOW_VRAM + len(shb), h)
            shb += mask
        tabs.append(t)
    assert SHADOW_VRAM + len(shb) <= SHADOW_END, len(shb)
    with open(os.path.join(OUT, 'shadows.bin'), 'wb') as f:
        f.write(bytes(shb))
    emit_vram_loader('shadows', shb, SHADOW_VRAM)
    RE.patch_shadows(OUT, tabs)

    def block(name, arr):
        out = name + '\n'
        for j in range(0, len(arr), 16):
            out += '    dta ' + ','.join(str(v) for v in arr[j:j+16]) + '\n'
        return out

    with open(os.path.join(OUT, 'persp.inc'), 'w') as f:
        f.write('; generated by vbxe_export.py -- do not hand-edit\n')
        f.write(block('sizeoff_lo', [o & 255 for o in sizeoff]))
        f.write(block('sizeoff_hi', [(o >> 8) & 255 for o in sizeoff]))
    return len(sheet), len(sizes)


def export_geom():
    """Write geom.inc: the initial 22-ball table, the 6 pocket capture circles,
    and MIND2 -- all derived from snooker_core so the asm never drifts from the
    sim.  init_balls : 22 x (x Q12 LE 3B, y Q12 LE 3B, sprite bank 1B).
    pockets : 6 x (px Q12 3B, py Q12 3B, pr^2 Q12^2 6B) little-endian.
    MIND2 : (2R)^2 in Q12^2 (6B LE) -- the ball-ball contact threshold."""
    balls = C.build_rack()
    out = ['; generated by vbxe_export.py -- do not hand-edit',
           '; initial rack: 22 x (x Q12 LE 3B, y Q12 LE 3B, sprite bank 1B)',
           'init_balls']
    for b in balls:
        x = C.to_fx(b.x) & 0xFFFFFF
        y = C.to_fx(b.y) & 0xFFFFFF
        out.append('    dta $%02X,$%02X,$%02X, $%02X,$%02X,$%02X, $%02X'
                   % (x & 255, (x >> 8) & 255, (x >> 16) & 255,
                      y & 255, (y >> 8) & 255, (y >> 16) & 255,
                      BALL_BANK[b.color]))

    def le(v, n):
        return ','.join('$%02X' % ((v >> (8 * i)) & 255) for i in range(n))

    # capture radii (mm).  Tighter than the sim's POCKETS so a ball only drops
    # when it actually reaches the mouth, not while still out in the open near
    # the corner.  Corners harder (smaller) than middles, like real snooker.
    CAP_CORNER = 45.0
    CAP_MIDDLE = 52.0
    out += ['; pockets: 6 x (px 3B, py 3B, pr^2 6B), little-endian', 'pockets']
    for i, (px, py, pr) in enumerate(C.POCKETS):
        cap = CAP_CORNER if i < 4 else CAP_MIDDLE   # POCKETS: 0-3 corners, 4-5 mids
        out.append('    dta %s, %s, %s'
                   % (le(C.to_fx(px), 3), le(C.to_fx(py), 3),
                      le(C.to_fx(cap) ** 2, 6)))
    out += ['; MIND2 = (2R)^2 in Q12^2, little-endian (6 bytes)', 'MIND2',
            '    dta %s' % le((2 * C.to_fx(C.BALL_R)) ** 2, 6)]
    with open(os.path.join(OUT, 'geom.inc'), 'w') as f:
        f.write('\n'.join(out) + '\n')
    return len(balls)


TITLE_VRAM = 0x30000      # the visible buffer: the game draws over it at start

# The HUD: VBXE text mode, 80 columns (hud.asm), in the 16 KB bank of the menu's
# sound (snd_prep.py SND3_VRAM): POKEY's AUDC tables first (from sounds.bin, the
# same in every sound bank).  V:HUD_VRAM: its 3 text lines
# (160 bytes each: char, attribute), the bar's 14 lines from line 0's font row
# 8 - HUD_TOP; V:HUD_FONT (2 KB boundary): the OS ROM's charset (internal codes
# $00-$7F), the tip square's 12 chars at $40-$4B drawn by tip_draw from the clean
# ball at $50-$5B (4 columns x 3 lines).
HUD_BANK = 0x74000
HUD_VRAM = 0x74400
HUD_FONT = 0x74800
HUD_TOP = 3
TIP_TDH = (2, 4, 5, 6, 6, 6, 6, 6, 6, 6, 5, 4, 2)   # the ball's half widths (SR pixels), rows 1..13
TIP_CX = 7                                          # its centre: SR pixel 7 of the 16, row 7


def hud_row(r):
    """the bar's line r (1..14) -> its offset in a tip char block (line * 32 + font row)"""
    return r + 8 - HUD_TOP - 1 if r <= HUD_TOP else (32 + r - HUD_TOP - 1 if r <= HUD_TOP + 8 else 64 + r - HUD_TOP - 9)


def export_hud_font():
    font = bytearray(open(os.path.join(OUT, 'osfont.bin'), 'rb').read())   # the XL OS's charset (1 KB)
    assert len(font) == 1024
    font += bytes(1024)
    tip = bytearray(96)
    for r in range(1, 14):
        h = TIP_TDH[r - 1]
        for x in range(2 * (TIP_CX - h), 2 * (TIP_CX + h) + 2):      # SR pixel -> 2 HR pixels
            tip[hud_row(r) + x // 8 * 8] |= 0x80 >> (x & 7)
    font[0x40 * 8:0x4C * 8] = bytes(96)
    font[0x50 * 8:0x5C * 8] = tip
    tabs = open(os.path.join(OUT, 'sounds.bin'), 'rb').read()[:0x400]   # (snd_prep.py TABS)
    blob = tabs + bytes(HUD_FONT - HUD_VRAM) + bytes(font)
    assert len(tabs) == HUD_VRAM - HUD_BANK
    with open(os.path.join(OUT, 'hudfont.bin'), 'wb') as f:
        f.write(blob)
    emit_vram_loader('hudfont', blob, HUD_BANK)
    with open(os.path.join(OUT, 'hud.inc'), 'w') as f:
        nl = chr(10)
        f.write('; generated by vbxe_export.py -- do not hand-edit (the HUD text mode)' + nl)
        f.write('HUD_FONT = $%05X%sHUD_TOP = %d%s' % (HUD_FONT, nl, HUD_TOP, nl))
        f.write('.macro TIP_ROF' + nl + '    dta %s%s.endm%s'
                % (', '.join(str(hud_row(r)) for r in range(1, 15)), nl, nl))


def export_title():
    """title.jpg -> 320 wide, 256 colours (overlay palette 2): title.bin streamed
    to TITLE_VRAM by title.inc (vbank seeded so vram_next starts there),
    title_pal.bin = R[256] G[256] B[256] for src/title.asm (staged at $2000).
    No title.jpg: the picture and palette already built are kept (its XDL is
    rebuilt).  Then the players' photos (export_photos)."""
    from PIL import Image
    src = os.path.join(PROJ, 'title.jpg')
    if os.path.exists(src):
        im = Image.open(src).convert('RGB')
        box = im.convert('L').point(lambda v: 255 if v > 40 else 0).getbbox()  # drop the black frame
        im = im.crop(box)
        h = round(im.size[1] * 320 / im.size[0])
        im = im.resize((320, h), Image.LANCZOS)
        q = im.quantize(256, method=Image.Quantize.MEDIANCUT, kmeans=3, dither=Image.Dither.FLOYDSTEINBERG)
        px = q.tobytes()
        pl = (q.getpalette() + [0] * 768)[:768]
        with open(os.path.join(OUT, 'title_pal.bin'), 'wb') as f:
            f.write(bytes(pl[0::3] + pl[1::3] + pl[2::3]))
    else:
        b = open(os.path.join(OUT, 'title.bin'), 'rb').read()
        h = next(h for h in range(100, 230)          # the picture's height: where its XDL starts
                 if b[320 * h] == 0x24 and b[320 * h + 2] == (240 - h) // 2 - 1 and b[320 * h + 3] == 0x62)
        px = b[:320 * h]
    p = open(os.path.join(OUT, 'title_pal.bin'), 'rb').read()
    pal = [(p[i], p[256 + i], p[512 + i]) for i in range(256)]
    # the XDL right after the picture: black (overlay off) | the picture, overlay
    # palette 2 | its last PHOTO_S lines with the attribute map on (the photos'
    # cells palette 3; off while the XEX loads -- menu.asm turns it on) | black | the menu bar (the HUD's text
    # lines, palette 0; priority 0 = hidden behind COLBAK until menu.asm has drawn it and
    # sets $FE) | black.  Priority $FE: player 0 (the mouse pointer) over the
    # overlay (in the map: P0 = $FE, title.asm).
    t = (240 - h) // 2
    gap = (240 - t - h - 16) // 2
    va, hv = TITLE_VRAM, HUD_VRAM
    mp = PHOTO_VRAM + PHOTO_MAP
    xdl = bytes([0x24, 0x00, t - 1,                          # OVOFF | RPTL
                 0x62, 0x08, h - PHOTO_S - 1,                # GMON | RPTL | OVADR, OVATT
                 va & 255, (va >> 8) & 255, va >> 16, 0x40, 0x01,   # step 320
                 0x21, 0xFE,                                 # normal width, palette 2
                 0x20, 0x06, PHOTO_S - 1,                    # RPTL (MAP_ON: menu.asm), MAP_ADR | MAP_PAR
                 mp & 255, (mp >> 8) & 255, mp >> 16, 160, 0,       # 40 cells a row
                 0, 0, 7, 7,                                 # 8 x 8 cells
                 0x34, 0x00, gap,                            # OVOFF | MAP_OFF | RPTL (+ the bar's black top line)
                 0xE1, 0x09, 13,                             # TMON | RPTL | OVADR | OVSCRL, CHBASE | OVATT
                 hv & 255, (hv >> 8) & 255, hv >> 16, 160, 0,       # the HUD's 3 text lines (hud.asm)
                 0, 8 - HUD_TOP,                             # line 0 from its font row 8 - HUD_TOP
                 HUD_FONT >> 11,
                 0x01, 0x00,                                 # palette 0, hidden
                 0x24, 0x80, 240 - t - h - gap - 16])        # OVOFF | RPTL (+ its black bottom line), END
    barpri = len(xdl) - 4
    mapon = 13                  # the map record's XDLC byte: MAP_ON set by the menu, once
    assert xdl[mapon:mapon + 2] == bytes([0x20, 0x06])   # the map's data is in VRAM by then
    bary = t + h + gap
    with open(os.path.join(OUT, 'title.bin'), 'wb') as f:
        f.write(px + xdl)
    assert TITLE_VRAM + len(px) + 4096 <= 0x44000   # below the pocket sound
    nl = chr(10)
    with open(os.path.join(OUT, 'title.inc'), 'w') as f:
        f.write('; generated by vbxe_export.py -- do not hand-edit (the title picture)' + nl)
        f.write('TITLE_XDL = $%05X            ; (after the picture)%s' % (TITLE_VRAM + len(px), nl))
        f.write('TITLE_BARPRI = $%05X         ; the menu bar priority byte%s' % (TITLE_VRAM + len(px) + barpri, nl))
        f.write('TITLE_BARY = %d                ; the menu bar first line%s' % (bary, nl))
        f.write('TITLE_MAPON = $%05X          ; the photo map record XDLC byte: | $08 = MAP_ON%s'
                % (TITLE_VRAM + len(px) + mapon, nl))
        f.write('PHOTO_BCB = $%05X            ; menu.asm: 12 BCB pairs (side * 6 + player), 42 bytes each%s'
                % (PHOTO_VRAM + PHOTO_BCBS, nl))
        f.write('    org vbank%s    dta $%02X                ; vram_next steps to the first bank%s'
                % (nl, (TITLE_VRAM >> 12) - 1, nl))
        blob = px + xdl
        for k in range(0, len(blob), 4096):
            f.write("    org $2000%s    ins '../build/assets/title.bin',%d,%d%s    ini vram_next%s"
                    % (nl, k, min(4096, len(blob) - k), nl, nl))
    export_photos(px, pal, h - PHOTO_S)       # (picture rows: its last PHOTO_S)
    return h


# The players' photos above their names in the menu (docs/players/*.png, opp 1..5, --photos once):
# composed over the picture at each side, all ten quantized together into overlay
# palette 3, which the attribute map gives their 8 x 8 cells (the rest of the
# picture keeps palette 2).  At V:$60000, the clean buffer: free until set_angle,
# after the menu.  A photo is one BCB pair: the picture copied in, then the cells'
# rows of the map; a human: the picture's own pixels back, the cells palette 2.
PHOTO_VRAM = 0x60000
PHOTO_S = 72
PHOTO_X = (24, 168)                     # above the P1 (columns 0-13) and P2 (18-31) fields
PHOTO_FILES = ('selby', 'higgins', 'robertson', 'trump', 'sullivan')
PHOTO_ORIG = 10 * PHOTO_S * PHOTO_S     # after the ten composites
PHOTO_MAP = PHOTO_ORIG + 2 * PHOTO_S * PHOTO_S
PHOTO_ROWS = PHOTO_MAP + 40 * 4 * (PHOTO_S // 8)
PHOTO_BCBS = PHOTO_ROWS + 2 * 4 * (PHOTO_S // 8)


def export_photos(px, pal, y0):
    """photos.bin (V:PHOTO_VRAM, streamed) and photo_pal.bin (overlay palette 3,
    R[256] G[256] B[256], title.asm) -- built ONCE from docs/players/*.png by
    python tools/vbxe_export.py --photos; a build keeps them (only the loader)"""
    pf = os.path.join(OUT, 'photos.bin')
    if '--photos' not in sys.argv:
        emit_vram_loader('photos', open(pf, 'rb').read(), PHOTO_VRAM)
        return
    from PIL import Image
    S, n = PHOTO_S, PHOTO_S // 8
    under = []                                   # the picture under each side's photo
    for x in PHOTO_X:
        under.append(bytes(c for y in range(S) for c in px[(y0 + y) * 320 + x:(y0 + y) * 320 + x + S]))
    comp = Image.new('RGB', (S * 10, S))
    for side in range(2):
        bg = Image.new('RGB', (S, S))
        bg.putdata([pal[i] for i in under[side]])
        for k, name in enumerate(PHOTO_FILES):
            ph = Image.open(os.path.join(PROJ, 'docs', 'players', name + '.png')).convert('RGBA')
            ph = ph.resize((S, S), Image.LANCZOS)
            c = bg.copy()
            c.paste(ph, (0, 0), ph)
            comp.paste(c, ((side * 5 + k) * S, 0))
    q = comp.quantize(256, method=Image.Quantize.MEDIANCUT, kmeans=3, dither=Image.Dither.FLOYDSTEINBERG)
    qb = q.tobytes()
    pl = (q.getpalette() + [0] * 768)[:768]
    blob = bytearray()
    for j in range(10):
        blob += bytes(qb[y * S * 10 + j * S + x] for y in range(S) for x in range(S))
    blob += under[0] + under[1]
    blob += bytes([0, 0, 0, 0x20] * 40 * n)      # the map: every cell palette 2
    blob += bytes([0, 0, 0, 0x30] * n)           # a side's cell row: palette 3 (the photo)
    blob += bytes([0, 0, 0, 0x20] * n)           #   or palette 2 (the picture)
    assert len(blob) == PHOTO_BCBS

    def bcb(src, sstep, dst, dstep, w, h, nxt):
        return bytes([src & 255, (src >> 8) & 255, src >> 16, sstep & 255, (sstep >> 8) & 31, 1,
                      dst & 255, (dst >> 8) & 255, dst >> 16, dstep & 255, (dstep >> 8) & 31, 1,
                      (w - 1) & 255, (w - 1) >> 8, h - 1, 0xFF, 0, 0, 0, 0, 0x08 if nxt else 0])
    for side in range(2):
        dst = TITLE_VRAM + y0 * 320 + PHOTO_X[side]
        cells = PHOTO_VRAM + PHOTO_MAP + PHOTO_X[side] // 8 * 4
        for k in range(6):                       # 0 a human, 1..5 the computer players
            src = PHOTO_VRAM + (PHOTO_ORIG + side * S * S if k == 0 else (side * 5 + k - 1) * S * S)
            row = PHOTO_VRAM + PHOTO_ROWS + (4 * n if k == 0 else 0)
            blob += bcb(src, S, dst, 320, S, S, True) + bcb(row, 0, cells, 160, 4 * n, n, False)
    assert PHOTO_VRAM + len(blob) <= 0x70000
    with open(pf, 'wb') as f:
        f.write(bytes(blob))
    with open(os.path.join(OUT, 'photo_pal.bin'), 'wb') as f:
        f.write(bytes(pl[0::3] + pl[1::3] + pl[2::3]))
    emit_vram_loader('photos', bytes(blob), PHOTO_VRAM)


def main():
    os.makedirs(OUT, exist_ok=True)
    pal = Palette()

    # the rotating table (tools/rot_ref.py spec): ONE camera fitted to every
    # angle; the balls project through its LUTs (ball-centre level, rotdata.inc)
    import rot_export
    nspr, ndisc, ndl, nzoom, used_sizes = rot_export.export_asm(OUT, emit_vram_loader)
    print(f'table renderer: {nspr} disc sprites ({ndisc} bytes VRAM), draw list {ndl} bytes, '
          f'{nzoom} zoom levels; ball sprite sizes {used_sizes}')
    # the 8 depth-sprite colour sheets add the ball shades to the palette
    cue_sheet, n_sizes = export_persp(pal, used_sizes)   # 8 ball sheets + sizeoff
    n_balls = export_geom()                       # init_balls + pockets + MIND2


    # shot-direction LUT: cos(angle) in Q16 signed, 1024 steps, 3-byte LE.
    # sin(angle) = cos(angle - 256 steps), so the asm derives sin by index offset.
    cosb = bytearray()
    for a in range(C.ANG_STEPS + 1):        # + cos(0) again: the aim lerp reads a+1
        c = int(round(65536 * math.cos(a * 2 * math.pi / C.ANG_STEPS)))
        cosb += (c & 0xFFFFFF).to_bytes(3, 'little')
    with open(os.path.join(OUT, 'coslut.bin'), 'wb') as f:
        f.write(bytes(cosb))

    # palette now holds table colours + ball shades
    with open(os.path.join(OUT, 'palette.bin'), 'wb') as f:
        for (r, g, b) in pal.list:
            f.write(bytes((r, g, b)))

    export_hud_font()
    th = export_title()         # (no title.jpg: the built picture kept, its XDL rebuilt)
    print('title.bin   : 320x%d, 256 colours -> V:$%05X; photos.bin -> V:$%05X%s' % (
        th, TITLE_VRAM, PHOTO_VRAM,
        '' if os.path.exists(os.path.join(PROJ, 'title.jpg')) else ' (title.jpg missing: the built picture kept)'))
    vram_total = write_loaders()
    print('VRAM loaders: %d bytes streamed in %d chunks (%s)'
          % (vram_total, sum(l[4] for l in _LOADERS),
             ', '.join('%s @$%05X' % (l[0], l[2]) for l in _LOADERS)))


    print(f'palette.bin : {pal.n} colours used (table + ball shades)')
    print(f'sprites.bin : 8 colour sheets, {cue_sheet} bytes each ({n_sizes} depth sizes)')
    print(f'geom.inc    : {n_balls} balls + 6 pockets + MIND2 (palette {pal.n}/256)')


if __name__ == '__main__':
    main()
