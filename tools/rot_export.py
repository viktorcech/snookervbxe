"""rot_export.py -- the table renderer's data for the asm (called by vbxe_export).

  rot.inc      constants, per-zoom planes, disc sprite tables (icl'd with the code)
  rotdata.inc  geometry indices + the draw list (org ROT_TAB), rcp7 (org ROT_RCP)
  discs.bin    the ellipse sprites (pocket openings, leather tops), every zoom -> VRAM
  rotpts.bin   the rotation points about the table centre per EVEN angle -> VRAM
  zlut.bin     the depth LUTs + disc class tables + ball LUT per zoom -> VRAM
               (zoom_set copies one zoom's 23 pages into ROT_LUT / ROT_BLUT / ROT_BLUT2)
"""
import os

import rot_ref as R

DISC_VRAM = 0x050000            # a free 64 KB bank (rdisc_y: the source's bank byte)
ROTPTS_VRAM = 0x010000          # 512 slots of 256 bytes ($010000-$02FFFF)
VTAB_VRAM = 0x400               # bank 0: rdisc's tables, then the draw list (to $FFF)
ZLUT_VRAM = 0x078000            # NZOOM blocks of 8 KB (two banks each: zoom_set), to the end of VRAM
ZLUT_PAGES = 23                 # 16 (ROT_LUT) + 5 (ROT_BLUT) + 2 (ROT_BLUT2)
ZLUT_STRIDE = 0x2000


def _arr(name, vals):
    out = name + '\n'
    for j in range(0, len(vals), 16):
        out += '    dta ' + ','.join(str(v & 255) for v in vals[j:j + 16]) + '\n'
    return out


def wind_left(sc, r):
    """wind every polygon so that its forward chain from the top vertex is the
    LEFT one on screen (the winding of a face never changes while the table
    turns): the asm's row loop then takes its swap path only at tips."""
    piv = (R.CXQ, R.CYQ)
    for n, it in enumerate(sc.items):
        if it['kind'] != 'poly':
            continue
        fwd = rev = 0
        for a in range(0, R.ANG, 16):
            rot, prj, (eu, ev) = r.frame(a, piv, R.ZOOM_DEFAULT)
            if n in r.cull:
                a_, b_, d_ = r.cull[n]
                if not a_ * eu + b_ * ev > d_:
                    continue
            if any(prj[p] is None for p in it['pp']):
                continue
            pts = [prj[p][:2] for p in it['pp']]
            k = len(pts)
            top = min(range(k), key=lambda i: (pts[i][1], i))
            nx, pv = pts[(top + 1) % k], pts[(top - 1) % k]
            # forward neighbour left of the backward one -> A is the left chain
            if (nx[0] - pts[top][0]) * (pv[1] - pts[top][1]) < (pv[0] - pts[top][0]) * (nx[1] - pts[top][1]):
                fwd += 1
            else:
                rev += 1
        if rev > fwd:
            it['pp'] = it['pp'][::-1]


def scene_asm():
    """the scene as the asm sees it: projection points sorted by z level (the
    asm tells the level by index), polygons wound left -- and its renderer."""
    R.ROUND_JAWS = True                 # the game's table: the pockets as the trick-shot PDF draws them
    sc = R.scene_real()                 #   (2026-10-27, rot_ref.py --cmp); False: the old square jaws
    sc.nd = sc.group_last('D')          # the D's own rotation points last (dtest)
    sc.nra = sc.mirror_first(sc.nd)     # the centre-symmetric pairs: their first halves made by rot_load
    perm = sorted(range(len(sc.pp)), key=lambda k: (sc.pp[k][1], k))
    newi = {old: new for new, old in enumerate(perm)}
    sc.pp = [sc.pp[k] for k in perm]
    for it in sc.items:
        it['pp'] = [newi[p] for p in it['pp']]
    r = R.Renderer(sc)
    wind_left(sc, r)
    return sc, r


def export_asm(outdir, emit_vram_loader):
    sc, r = scene_asm()

    # disc sprites: (rx, ry, colour) over every class, zoom and depth index;
    # per zoom and class a sprite id per depth index (the class tables)
    sprites, sid = [], {}
    cls_tabs = []                   # [zoom][class] -> [NLUT ids]
    for Z in r.Z:
        tabs = []
        for (rad, col) in r.classes:
            t = []
            for i in range(Z.NLUT):
                rx, ry = R.disc_size(Z.L, 1, i, rad)
                k = (rx, ry, col)
                if k not in sid:
                    sid[k] = len(sprites)
                    sprites.append(k)
                t.append(sid[k])
            tabs.append(t)
        cls_tabs.append(tabs)
    # one 64 KB bank: no sprite crosses it (rdisc_y adds the cut offset in 16 bits)
    blob = bytearray()
    spr_adr = []
    for (rx, ry, col) in sprites:
        w, h = 2 * rx + 1, 2 * ry + 1
        img = bytearray(w * h)
        for (yy, ww) in R.disc_mask(rx, ry):
            for x in range(rx - ww, rx + ww + 1):
                img[(yy + ry) * w + x] = R.disc_color(col, rx, ry, x - rx, yy)
        spr_adr.append(DISC_VRAM + len(blob))
        blob += img
    assert len(sprites) < 256 and (DISC_VRAM & 0xFFFF) + len(blob) <= 0x10000, (len(sprites), len(blob))

    with open(os.path.join(outdir, 'discs.bin'), 'wb') as f:
        f.write(bytes(blob))
    emit_vram_loader('discs', blob, DISC_VRAM)

    # draw list: kind (0 poly, 1 disc, 2 line, 3 spot; +$40 = far plane of
    # level H; +$80 = culled face: a, b as cull_prep's entries, -d' (3 bytes) --
    # visible iff a*Eu' + b*Ev' > d' (a cushion's wedge: + KS, the eye's height)),
    # then; $FE n: the D's items (n - 2 bytes), skipped by dtest; then
    #   poly: colour, n, pp*n   disc: class, pp   line: colour, pp, pp   spot: colour, pp
    # the cull test's factors as entries of cull_prep's product tables: 0 = zero,
    # j = +m_j, M + j = -m_j (m_j the j-th magnitude); v's at NCU on; d' stored negated
    mags = sorted({abs(v) for (a_, b_, d_) in r.cull.values() for v in (a_, b_)} - {0})
    ncm, ncu = len(mags), 2 * len(mags) + 1

    def cix(v):
        return 0 if v == 0 else mags.index(abs(v)) + 1 + (ncm if v < 0 else 0)
    dl = []
    dgrp = None
    for n, it in enumerate(sc.items):
        if it.get('grp') == 'D' and dgrp is None:   # the D's header: $FE, 2 + its items' bytes
            dgrp = len(dl)
            dl += [0xFE, 2]
        if dgrp is not None and it.get('grp') != 'D' and dl[dgrp + 1] == 2:
            dl[dgrp + 1] = len(dl) - dgrp
        k = {'poly': 0, 'disc': 1, 'line': 2, 'spot': 3}[it['kind']]
        if r.farcls[n]:
            k |= 0x40
        if n in r.cull:
            a_, b_, d_ = r.cull[n]
            assert -128 <= a_ < 128 and -128 <= b_ < 128 and -(1 << 23) <= d_ < (1 << 23)
            nd = -d_ & 0xFFFFFF
            dl += [k | 0x80, cix(a_), (2 if it.get('slant') else 1) * ncu + cix(b_), nd, nd >> 8, nd >> 16]
        else:
            dl += [k]
        if it['kind'] == 'poly':
            dl += [it['col'], len(it['pp'])] + it['pp']
        elif it['kind'] == 'disc':
            dl += [r.classes.index((it['r'], it['col'])), it['pp'][0]]
        elif it['kind'] == 'line':
            dl += [it['col'], 2] + it['pp']
        else:
            dl += [it['col'], it['pp'][0]]
    dl += [0xFF]
    dn = [n for n, it in enumerate(sc.items) if it.get('grp') == 'D']
    assert dgrp is not None and 2 < dl[dgrp + 1] < 256 and dn == list(range(dn[0], dn[-1] + 1))
    dend = sorted({sc.pp[k][0] for it in sc.items if it.get('grp') == 'D' for k in it['pp']}
                  - set(range(len(sc.rp) - sc.nd, len(sc.rp))))     # its ends: shared points
    assert len(dend) == 2
    assert max(len(it['pp']) for it in sc.items) <= 4
    assert len(sc.rp) <= 128 and len(sc.pp) <= 128, (len(sc.rp), len(sc.pp))   # (defs.inc rt*, ry*, rp*: 128 a page half)
    assert 4 * (len(sc.rp) - sc.nra) <= 256, (len(sc.rp), sc.nra)              # (a slot: the stored points' 4 planes)

    with open(os.path.join(outdir, 'rot.inc'), 'w') as f:
        f.write('; generated by tools/rot_export.py -- do not hand-edit (the table renderer)\n')
        f.write('ROT_NRA = %d' % sc.nra + chr(10) + 'ROT_NRS = %d' % (len(sc.rp) - sc.nra) + chr(10))   # the mirrored pairs, the stored points
        f.write('ROT_SXC = %d\nROT_NRP = %d\nROT_NPP = %d\nROT_NPP0 = %d\nROT_NCLS = %d\n'
                'ROT_DL_LEN = %d\nNZOOM = %d\nZOOM_DEF = %d\nZOOM_LOW = %d\nZOOM_EYE = %d\nZOOM_TOP = %d\n'
                'ZLUT_BANK = $%02X\nROT_PTS_BANK = $%02X\n'
                % (R.SXC, len(sc.rp), len(sc.pp), sum(1 for k, zl in sc.pp if zl == 0),
                   len(r.classes), len(dl), len(r.Z), R.ZOOM_DEFAULT, R.ZOOM_LOW, R.ZOOM_EYE,
                   R.ZOOM_TOP, ZLUT_VRAM >> 12,
                   ROTPTS_VRAM >> 12))
        f.write('ROT_ND = %d\nROT_DE0 = %d\nROT_DE1 = %d\n' % (sc.nd, dend[0], dend[1]))   # the D (dtest)
        f.write('ROT_NCM = %d\nROT_NCU = %d\n' % (ncm, ncu))            # cull_prep's magnitudes
        f.write(_arr('cm_mag', [0] + mags + [0] * (ncm + 1) + mags))     # (by entry: u's, then v's)
        f.write(_arr('zoom_ks0', [Z.KS for Z in r.Z]))                   # a sloped face's eye-height term
        f.write(_arr('zoom_ks1', [Z.KS >> 8 for Z in r.Z]))
        f.write(_arr('zoom_ks2', [Z.KS >> 16 for Z in r.Z]))
        f.write('ROT_CXQ = $%06X\nROT_CYQ = $%06X\n' % (R.CXQ, R.CYQ))   # the table centre, Q12
        f.write('ROT_DISC_BANK = $%02X' % (DISC_VRAM >> 16) + chr(10))   # the disc sprites' bank (rdisc_y)

        f.write(_arr('zoom_exm_lo', [-Z.EX for Z in r.Z]))     # the eye's distance, Q3
        f.write(_arr('zoom_exm_hi', [-Z.EX >> 8 for Z in r.Z]))
        f.write(_arr('zoom_off_lo', [Z.OFF for Z in r.Z]))
        f.write(_arr('zoom_off_hi', [Z.OFF >> 8 for Z in r.Z]))
        f.write(_arr('zoom_tf0_lo', [Z.TF0 for Z in r.Z]))
        f.write(_arr('zoom_tf0_hi', [Z.TF0 >> 8 for Z in r.Z]))
        f.write(_arr('zoom_tfh_lo', [Z.TFH for Z in r.Z]))
        f.write(_arr('zoom_tfh_hi', [Z.TFH >> 8 for Z in r.Z]))
        f.write(_arr('zoom_nh', [Z.NH for Z in r.Z]))           # DK past 8 bits for i < NH
        # the disc tables and the draw list live in VRAM bank 0 (VTAB_VRAM on),
        # read through the window rot_draw holds on bank 0 (vbxe manual ch. 6:
        # a MEMAC read costs the CPU what any read does)
        for nm, off in (('rot_sprx', 0x000), ('rot_spry8', 0x080), ('rot_spa0', 0x100),
                        ('rot_spa1', 0x180), ('rot_dl', 0x200)):
            f.write('%s = WINDOW+$%03X' % (nm, VTAB_VRAM + off) + chr(10))

    # VTAB_VRAM: rdisc's tables (w = 2 rx + 1; ry + 8: the screen row in one
    # subtraction, h = 2 ry + 1; the sprite address lo / mid), 128 each, then
    # the draw list -- one blob from V:$000000 (its first pages zero: the XDL
    # and the BCB templates are written there after it, at start)
    assert len(sprites) <= 0x80 and len(dl) <= 0x1000 - VTAB_VRAM - 0x200, (len(sprites), len(dl))
    vt = bytearray(VTAB_VRAM + 0x200 + len(dl))
    for k, (rx, ry, col) in enumerate(sprites):
        vt[VTAB_VRAM + k] = rx
        vt[VTAB_VRAM + 0x80 + k] = ry + 8
        vt[VTAB_VRAM + 0x100 + k] = spr_adr[k] & 255
        vt[VTAB_VRAM + 0x180 + k] = (spr_adr[k] >> 8) & 255
    vt[VTAB_VRAM + 0x200:] = bytes(v & 255 for v in dl)
    with open(os.path.join(outdir, 'vtab.bin'), 'wb') as f:
        f.write(bytes(vt))
    emit_vram_loader('vtab', vt, 0)

    rcp = [0, 0, 0] + [R.rcp7(n) for n in range(3, 256)]      # by row count
    with open(os.path.join(outdir, 'rotdata.inc'), 'w') as f:
        f.write('; generated by tools/rot_export.py -- do not hand-edit (the renderer RAM data)\n')
        f.write('    org ROT_TAB          ; geometry indices + the draw list\n')
        f.write(_arr('rot_pprp', [k for k, zl in sc.pp]))
        # per rotation point its projection point at level 0 / 1 (255 = none):
        # rot_project does each rotation point's shared work once for both
        lv = [{}, {}]
        for n, (k, zl) in enumerate(sc.pp):
            lv[zl][k] = n
        assert all(lv[0].get(k, lv[1].get(k)) is not None for k in range(len(sc.rp)))
        f.write(_arr('rot_rpp0', [lv[0].get(k, 255) for k in range(len(sc.rp))]))
        f.write(_arr('rot_rpp1', [lv[1].get(k, 255) for k in range(len(sc.rp))]))
        f.write('rot_tab_end              ; (main.asm puts rdisc.asm here)\n')
        f.write('    ert *>$A000\n')
        f.write('    org ROT_RCP\n')
        f.write(_arr('rcp_lo', rcp))
        f.write(_arr('rcp_hi', [v >> 8 for v in rcp]))

    # the rotation points per even angle: x lo, x hi, y lo, y hi (Q3 about the
    # table centre, signed 16) -> rot_load
    pts = bytearray()
    nrs = len(sc.rp) - sc.nra               # stored: the pairs' partners, the unpaired, the D (the first
    for slot in range(R.ANG // 2):          #   ROT_NRA are their partners' negations: rot_load makes them)
        rot = r.rot_points(2 * slot)
        rec = bytearray(256)
        for k, (x, y) in enumerate(rot[sc.nra:]):
            assert -32768 <= x < 32768 and -32768 <= y < 32768
            rec[k], rec[nrs + k] = x & 255, (x >> 8) & 255
            rec[2 * nrs + k], rec[3 * nrs + k] = y & 255, (y >> 8) & 255
        pts += rec
    with open(os.path.join(outdir, 'rotpts.bin'), 'wb') as f:
        f.write(bytes(pts))
    emit_vram_loader('rotpts', pts, ROTPTS_VRAM)

    # the zoom blocks: 16 pages ROT_LUT (rl0_lo rl0_hi rd0 rk0_lo rk0_hi rdk0,
    # the same for level 1, cls0..3), 5 pages ROT_BLUT (rl2_lo rl2_hi rd2
    # rk2_lo rk2_hi), 2 pages ROT_BLUT2 (rdk2, bsize); 6 KB stride
    def page(vals):
        return bytes(v & 255 for v in vals) + bytes(256 - len(vals))

    def dk_page(dk):
        # DK lo for every entry, DK hi at $C0 + i for the first 64 (rot_ref NH)
        pg = bytearray(page(dk))
        pg[0xC0:0x100] = bytes(d >> 8 for d in (dk + [0] * 64)[:64])
        return bytes(pg)
    zl = bytearray()
    for zi, Z in enumerate(r.Z):
        blk = bytearray()
        for lev in (0, 1):
            row, dr, kk, dk = Z.L[lev]
            for vals in (row, [v >> 8 for v in row], dr, kk, [v >> 8 for v in kk]):
                blk += page(vals)
            blk += dk_page(dk)
        for c in range(len(r.classes)):
            blk += page(cls_tabs[zi][c])
        assert len(blk) == 16 * 256 and len(r.classes) == 4
        row, dr, kk, dk = Z.L[2]
        for vals in (row, [v >> 8 for v in row], dr, kk, [v >> 8 for v in kk]):
            blk += page(vals)
        blk += dk_page(dk)
        blk += page(Z.BS)                   # (+ $C0: the shadows by size, patch_shadows)
        assert len(blk) == ZLUT_PAGES * 256
        zl += blk + bytes(ZLUT_STRIDE - len(blk))
    with open(os.path.join(outdir, 'zlut.bin'), 'wb') as f:
        f.write(bytes(zl))
    emit_vram_loader('zlut', zl, ZLUT_VRAM)
    return len(sprites), len(blob), len(dl), len(r.Z), sorted(set(s for Z in r.Z for s in Z.BS))


def patch_shadows(outdir, tabs):
    """tabs[zoom] = {size: (VRAM address, rows)} -> the zoom block's bsize
    page: mask address lo at $C0 + s, hi at $D0 + s, rows at $E0 + s (gstore)"""
    path = os.path.join(outdir, 'zlut.bin')
    zl = bytearray(open(path, 'rb').read())
    for zi, t in enumerate(tabs):
        pg = zi * ZLUT_STRIDE + (ZLUT_PAGES - 1) * 256
        for s, (adr, rows) in t.items():
            assert s < 16 and adr < 0x10000 and rows < 256
            zl[pg + 0xC0 + s] = adr & 255
            zl[pg + 0xD0 + s] = adr >> 8
            zl[pg + 0xE0 + s] = rows
    open(path, 'wb').write(bytes(zl))
