#!/usr/bin/env python3
"""Human LIFEPOD (escape capsule) reference model (companion of the other build_*_ref.py scripts).

Per the user: a cylinder with a rectangular window covering HALF the circumference, about twice the
size of the ship's engine pod (pod R 5 x 21 long -> lifepod R 10 x 42 long), bevelled edges, and on
top a SQUARE hatch with the word LIFEPOD.  The rest (nose docking boss, tail thruster, orange bands,
beacon) is filled in to make it read as a rescue capsule.

Axes: the capsule STANDS upright (axis Z, lid up); +Y is the window side.  Cross-section angle phi is measured
from the top (+Z) towards +Y.  Human kit: off-white / light grey with orange marks.

Run:  python tools/ship_ref/build_lifepod_ref.py  -> ship_ref/lifepod_*.png, lifepod.obj
"""
import math
import os
import sys
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_ship_ref as S                                         # noqa: E402
from build_ship_ref import Mesh, render, label, export_obj, BG      # noqa: E402
from build_base_ref import cyl_axis, annulus, block                 # noqa: E402

OUT = S.OUT
C = {
    "body": (214, 218, 224),
    "bevel": (234, 237, 241),
    "dark": (60, 64, 72),
    "glass": (18, 30, 46),
    "frame": (120, 125, 133),
    "accent": (232, 112, 36),
    "lamp": (255, 206, 110),
    "text": (34, 38, 46),
    "hatch": (196, 201, 208),
    "nozzle": (52, 56, 64),
}
S.EMISSIVE.add(C["lamp"])

R = 10.0               # radius (ship's engine pod: 5)
HL = 21.0              # half length (pod: 21 long -> 42 long here)
CHA = 1.4              # end chamfer
WIN_A, WIN_B = math.radians(35), math.radians(195)       # 160 degrees: a bit under half of the circumference
WIN_X0, WIN_X1 = 1.5, 16.0
FRAME = 1.1            # frame width (arc length / axial)
HATCH_X = -11.5        # hatch centre along the axis
HATCH = 12.0           # hatch side


def E(phi):
    """Unit radial direction at angle phi (from +Z towards +Y)."""
    return np.array((0.0, math.sin(phi), math.cos(phi)))


def pt(x, r, phi):
    return np.array((x, 0.0, 0.0)) + E(phi) * r


def band(m, xa, xb, ra, rb, p0, p1, col, grp=None, seg_deg=5.0):
    """Surface patch of a (conical) cylinder about X: x in [xa,xb], radius ra->rb, phi in [p0,p1]."""
    g = grp if grp is not None else m.newgroup()
    n = max(1, int(math.ceil(abs(p1 - p0) / math.radians(seg_deg))))
    for i in range(n):
        a = p0 + (p1 - p0) * i / n
        b = p0 + (p1 - p0) * (i + 1) / n
        q00, q01, q11, q10 = pt(xa, ra, a), pt(xa, ra, b), pt(xb, rb, b), pt(xb, rb, a)
        na, nb = E(a), E(b)
        m.tri(q00, q01, q11, col, g, (na, nb, nb))
        m.tri(q00, q11, q10, col, g, (na, nb, na))


def radial_wall(m, x, r0, r1, p0, p1, col):
    """Flat ring segment in the plane x = const."""
    g = m.newgroup()
    n = max(1, int(math.ceil(abs(p1 - p0) / math.radians(8.0))))
    for i in range(n):
        a = p0 + (p1 - p0) * i / n
        b = p0 + (p1 - p0) * (i + 1) / n
        m.quad(pt(x, r0, a), pt(x, r0, b), pt(x, r1, b), pt(x, r1, a), col, g)


def side_wall(m, xa, xb, r0, r1, phi, col):
    """Flat wall at constant phi between radii r0 and r1, x in [xa, xb]."""
    g = m.newgroup()
    m.quad(pt(xa, r0, phi), pt(xb, r0, phi), pt(xb, r1, phi), pt(xa, r1, phi), col, g)


def bar(m, xa, xb, pa, pb, r_in, r_out, col):
    band(m, xa, xb, r_out, r_out, pa, pb, col)
    radial_wall(m, xa, r_in, r_out, pa, pb, col)
    radial_wall(m, xb, r_in, r_out, pa, pb, col)
    side_wall(m, xa, xb, r_in, r_out, pa, col)
    side_wall(m, xa, xb, r_in, r_out, pb, col)


# ------------------------------------------------------------------ 5x7 stencil letters
GLYPH = {
    "L": ["X....", "X....", "X....", "X....", "X....", "X....", "XXXXX"],
    "I": ["XXXXX", "..X..", "..X..", "..X..", "..X..", "..X..", "XXXXX"],
    "F": ["XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "X...."],
    "E": ["XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "XXXXX"],
    "P": ["XXXX.", "X...X", "X...X", "XXXX.", "X....", "X....", "X...."],
    "O": [".XXX.", "X...X", "X...X", "X...X", "X...X", "X...X", ".XXX."],
    "D": ["XXXX.", "X...X", "X...X", "X...X", "X...X", "X...X", "XXXX."],
}


def text_on_plane(m, word, cx, cy, z, cell, col):
    """Stencil text lying flat at height z, reading along +X (viewed from above, +Y up)."""
    g = m.newgroup()
    width = (len(word) * 6 - 1) * cell
    x0 = cx - width / 2
    y0 = cy + 3.5 * cell
    for li, ch in enumerate(word):
        for row, line in enumerate(GLYPH[ch]):
            for colm, v in enumerate(line):
                if v == "X":
                    x = x0 + (li * 6 + colm) * cell
                    y = y0 - row * cell
                    m.quad(np.array((x, y - cell, z)), np.array((x + cell, y - cell, z)),
                           np.array((x + cell, y, z)), np.array((x, y, z)), col, g)


def build():
    m = Mesh()
    xs, xe = -HL + CHA, HL - CHA
    # --- end chamfers and end caps
    for sgn in (-1, 1):
        xa = sgn * (HL - CHA)
        xb = sgn * HL
        band(m, xa, xb, R, R - CHA, 0, 2 * math.pi, C["bevel"], seg_deg=6)
        g = m.newgroup()
        for i in range(48):
            a, b = 2 * math.pi * i / 48, 2 * math.pi * (i + 1) / 48
            m.tri(np.array((xb, 0, 0)), pt(xb, R - CHA, a), pt(xb, R - CHA, b), C["body"], g)
    # --- the body: whole circle outside the window, the other half inside the window's span
    band(m, xs, WIN_X0, R, R, 0, 2 * math.pi, C["body"])
    band(m, WIN_X1, xe, R, R, 0, 2 * math.pi, C["body"])
    band(m, WIN_X0, WIN_X1, R, R, WIN_B, WIN_A + 2 * math.pi, C["body"])
    # --- the window: frame, mullions, dark glass
    fa = FRAME / R
    r_out = R + 0.35
    bar(m, WIN_X0, WIN_X1, WIN_A, WIN_A + fa, R - 0.1, r_out, C["frame"])
    bar(m, WIN_X0, WIN_X1, WIN_B - fa, WIN_B, R - 0.1, r_out, C["frame"])
    bar(m, WIN_X0, WIN_X0 + FRAME, WIN_A, WIN_B, R - 0.1, r_out, C["frame"])
    bar(m, WIN_X1 - FRAME, WIN_X1, WIN_A, WIN_B, R - 0.1, r_out, C["frame"])
    ga, gb = WIN_A + fa, WIN_B - fa
    gx0, gx1 = WIN_X0 + FRAME, WIN_X1 - FRAME
    band(m, gx0, gx1, R - 0.5, R - 0.5, ga, gb, C["glass"])
    # inner reveal round the glass
    for xx in (gx0, gx1):
        radial_wall(m, xx, R - 0.5, R - 0.1, ga, gb, C["dark"])
    for ph in (ga, gb):
        side_wall(m, gx0, gx1, R - 0.5, R - 0.1, ph, C["dark"])
    # --- orange bands, front and rear
    for (xa, xb) in ((-19.4, -18.0), (19.0, 20.2)):
        band(m, xa, xb, R + 0.12, R + 0.12, 0, 2 * math.pi, C["accent"])
        radial_wall(m, xa, R, R + 0.12, 0, 2 * math.pi, C["accent"])
        radial_wall(m, xb, R, R + 0.12, 0, 2 * math.pi, C["accent"])

    # --- tail (bottom once the capsule stands): a small thruster; the top is the LID with the hatch
    cyl_axis(m, np.array((-HL, 0, 0)), np.array((-HL - 2.8, 0, 0)), 4.3, 3.0, C["nozzle"], segs=32)
    annulus(m, np.array((-HL - 2.82, 0, 0)), np.array((-1.0, 0, 0)), 0.0, 2.9, C["dark"], 32)
    cyl_axis(m, np.array((-HL - 2.2, 0, 0)), np.array((-HL - 2.8, 0, 0)), 3.3, 3.3, C["frame"], segs=32)

    # --- stand it upright: the axis X becomes Z (nose/lid up), Y stays
    out = Mesh()
    out.group = m.group
    for verts, ns, col, grp in m.tris:
        v2 = np.stack((-verts[:, 2], verts[:, 1], verts[:, 0]), axis=1)
        n2 = None if ns is None else tuple(np.array((-n[2], n[1], n[0])) for n in ns)
        out.tris.append((v2, n2, col, grp))
    m = out

    # --- the square hatch, flush in the LID (the top end cap), with the lettering
    top = HL
    side = 11.0
    block(m, (0.0, 0.0), side, side, 0.0, 0.7, top - 0.2, C["hatch"], ch=0.25)
    ztop = top + 0.5
    inset, w = 0.5, 0.4
    s = side / 2 - inset
    g = m.newgroup()
    for (x0_, y0_, x1_, y1_) in ((-s, -s, s, -s + w), (-s, s - w, s, s), (-s, -s, -s + w, s), (s - w, -s, s, s)):
        m.quad(np.array((x0_, y0_, ztop + 0.03)), np.array((x1_, y0_, ztop + 0.03)),
               np.array((x1_, y1_, ztop + 0.03)), np.array((x0_, y1_, ztop + 0.03)), C["accent"], g)
    text_on_plane(m, "LIFEPOD", 0.0, 0.0, ztop + 0.05, 0.2, C["text"])
    # hinges on the -Y edge of the hatch, an orange latch on the +Y edge
    for dx in (-3.0, 3.0):
        block(m, (dx, -side / 2 - 0.45), 2.2, 0.9, 0.0, 0.9, top - 0.2, C["frame"], ch=0.25)
    block(m, (0.0, side / 2 + 0.5), 2.8, 1.0, 0.0, 1.0, top - 0.2, C["accent"], ch=0.25)
    return m


VIEWS = [
    ("top", "TOP: THE LID WITH THE HATCH", 0, 90, 17.0, (0, 0, 0)),
    ("window_side", "WINDOW SIDE", 0, 0, 17.0, (0, 0, 0)),
    ("other_side", "OTHER SIDE", 180, 0, 17.0, (0, 0, 0)),
    ("bottom", "BOTTOM (THRUSTER)", 0, -90, 17.0, (0, 0, 0)),
    ("three_quarter_1", "3/4 HIGH, WINDOW SIDE", 25, 30, 17.0, (0, 0, 0)),
    ("three_quarter_2", "3/4 HIGH, OTHER SIDE", 205, 30, 17.0, (0, 0, 0)),
    ("three_quarter_low", "3/4 LOW", -35, -25, 17.0, (0, 0, 0)),
    ("closeup", "CLOSE-UP: LID AND HATCH", 20, 55, 46.0, (0, 0, HL)),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    m = build()
    export_obj(m, os.path.join(OUT, "lifepod.obj"))
    ims = []
    for key, title, az, el, scale, ctr in VIEWS:
        im = render(m, az, el, size=1000, ss=2, scale=scale, center=ctr, edge_dz=0.7)
        im.save(os.path.join(OUT, "lifepod_%s.png" % key))
        ims.append(label(im.copy(), title))
        print("rendered", key, flush=True)
    th = 560
    sheet = Image.new("RGB", (th * 4, th * 2), BG)
    for k, im in enumerate(ims):
        sheet.paste(im.resize((th, th), Image.LANCZOS), ((k % 4) * th, (k // 4) * th))
    sheet.save(os.path.join(OUT, "lifepod_sheet.png"))
    print("done")


if __name__ == "__main__":
    main()
