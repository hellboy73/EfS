#!/usr/bin/env python3
"""ALIEN TOWER reference model (companion of the other build_*_ref.py scripts).

Game data (src/enemies.s, EN_ALIEN_TOWER): a diamond with both diagonals, 75 px half-diagonal - an
"envelope" in 2D.  In 3D (the user): two very tall square PYRAMIDS (slightly blunted at the tip) standing upright, joined BASE TO BASE,
narrowing towards the top and towards the bottom - a long bipyramid with a bevelled waist at the middle.
Each pyramid's height = 5 x its base side.  Size from the source: the diamond's half-diagonal is 75 px, so the base
square has half-diagonal 75 (side 106 px); here 1 unit = 10.6 px -> side 10, each prism 50 high, 100 in all, and the
square is turned 45 degrees so the plan looks like the game's diamond.

Surface: every edge lightly bevelled; windows, vents and doors are shown ONLY as engraved outlines (flush panels, drawn
with contour lines by the renderer) so the surface stays closed and solid.

Run:  python tools/ship_ref/build_alien_tower_ref.py  -> ship_ref/alien_tower_*.png, alien_tower.obj
"""
import math
import os
import sys
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_ship_ref as S                                         # noqa: E402
from build_ship_ref import Mesh, render, label, export_obj, BG      # noqa: E402
from build_base_ref import block                                    # noqa: E402

OUT = S.OUT
C = {
    "body": (84, 92, 118),
    "panel": (98, 107, 136),
    "inset": (66, 73, 98),
    "slit": (52, 58, 80),
}

A = 10.0               # base side
H = 5 * A              # height of each prism
CH = 0.55              # bevel
YAW = 45.0             # plan turned to the game's diamond
LW = 0.07              # panel stand-off (flush)


TW = 0.7               # half-width of the blunted tip
BV = 0.5               # bevel at the waist
CB = 0.5               # ridge bevel (width at the base)
COL_BEV = (128, 138, 166)


def wid(h):
    """Half-width of the pyramid at height h above the junction."""
    return A / 2 * (1 - h / H) + TW * (h / H)


def face_frame(f):
    a = math.radians(YAW + 90 * f)
    n = np.array((math.cos(a), math.sin(a), 0.0))
    t = np.cross(np.array((0.0, 0.0, 1.0)), n)
    return n, t


def ring(h, shrink):
    w = wid(h) - shrink
    cb = CB * wid(h) / (A / 2)
    pts = []
    for f in range(4):
        n, t = face_frame(f)
        for u in (-(w - cb), (w - cb)):
            pts.append(n * w + t * u + np.array((0.0, 0.0, h)))
    return pts


def panel(m, f, u0, u1, h0, h1, col, off):
    """Flush trapezoid on the slanted face f, u in units of the face half-width at the BASE (scaled with the taper)."""
    n, t = face_frame(f)
    g = m.newgroup()

    def P(u, h):
        k = wid(h) / (A / 2)
        return n * (wid(h) + off) + t * (u * k) + np.array((0.0, 0.0, h))
    m.quad(P(u0, h0), P(u1, h0), P(u1, h1), P(u0, h1), col, g)


def decorate(m):
    uw = A / 2 - CB - 0.4
    for f in range(4):
        for j in range(4):                   # four bays; the tip bay stays plain
            hb = j * A
            panel(m, f, -uw, uw, hb + 0.9, hb + 1.5, C["panel"], LW)
            if j == 3:
                continue
            kind = (f * 2 + j) % 4
            h0, h1 = hb + 2.3, hb + 9.1
            if kind == 0:
                for (a_, b_) in ((-3.2, -0.9), (0.9, 3.2)):
                    panel(m, f, a_, b_, h0 + 0.6, h1 - 0.6, C["panel"], LW)
                    panel(m, f, a_ + 0.35, b_ - 0.35, h0 + 0.95, h1 - 0.95, C["inset"], LW * 2)
            elif kind == 1:
                panel(m, f, -3.4, 3.4, h0 + 1.2, h1 - 1.2, C["panel"], LW)
                for k in range(4):
                    hh = h0 + 1.7 + k * (h1 - h0 - 3.4 - 0.3) / 3
                    panel(m, f, -2.8, 2.8, hh, hh + 0.45, C["slit"], LW * 2)
            elif kind == 2:
                panel(m, f, -1.9, 1.9, h0, h1 - 0.2, C["panel"], LW)
                panel(m, f, -1.35, 1.35, h0 + 0.5, h1 - 0.8, C["inset"], LW * 2)
                panel(m, f, -0.6, 0.6, h0 + 1.5, h0 + 3.2, C["panel"], LW * 3)
            else:
                for k in range(3):
                    uc = (k - 1) * 2.7
                    panel(m, f, uc - 0.85, uc + 0.85, h0 + 2.0, h0 + 3.7, C["panel"], LW)
                    panel(m, f, uc - 0.45, uc + 0.45, h0 + 2.4, h0 + 3.3, C["inset"], LW * 2)
                panel(m, f, -3.6, 3.6, h0 + 4.6, h1 - 0.3, C["panel"], LW)


def pyramid(m):
    """One pyramid, base (with its bevel) at z=0, tip at z=H."""
    levels = [(0.0, BV), (BV, 0.0), (H, 0.0)]
    rs = [ring(h, sh) for h, sh in levels]
    for li in range(len(rs) - 1):
        for j in range(8):
            j2 = (j + 1) % 8
            g = m.newgroup()
            col = COL_BEV if (j % 2 == 1 or li == 0) else C["body"]
            m.quad(rs[li][j], rs[li][j2], rs[li + 1][j2], rs[li + 1][j], col, g)
    g = m.newgroup()
    m.poly_fan(rs[-1][::-1], COL_BEV, g)          # the blunted tip's flat cap, facing up
    decorate(m)


def build():
    up = Mesh()
    pyramid(up)
    m = Mesh()
    m.tris = list(up.tris)
    m.group = up.group
    off = up.group + 10
    for verts, ns, col, grp in up.tris:          # the lower pyramid: the same, mirrored in z
        v2 = (verts * np.array((1.0, 1.0, -1.0)))[::-1].copy()
        m.tris.append((v2, None, col, grp + off))
    m.group = up.group + off + 1
    return m


VIEWS = [
    ("front", "SIDE (FACE ON)", 45, 0, 8.0, (0, 0, 0)),
    ("diagonal", "SIDE (ON THE CORNER)", 0, 0, 8.0, (0, 0, 0)),
    ("top", "TOP", 0, 90, 38.0, (0, 0, 0)),
    ("three_quarter_1", "3/4 HIGH", 30, 22, 7.5, (0, 0, 0)),
    ("three_quarter_2", "3/4 HIGH, OTHER SIDE", 210, 22, 7.5, (0, 0, 0)),
    ("three_quarter_low", "3/4 LOW", -30, -22, 7.5, (0, 0, 0)),
    ("waist", "CLOSE-UP: THE WAIST", 30, 12, 34.0, (0, 0, 0)),
    ("tip", "CLOSE-UP: TOP END", 30, 25, 34.0, (0, 0, H - 14)),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    m = build()
    export_obj(m, os.path.join(OUT, "alien_tower.obj"))
    ims = []
    for key, title, az, el, scale, ctr in VIEWS:
        im = render(m, az, el, size=1000, ss=2, scale=scale, center=ctr, edge_dz=0.7)
        im.save(os.path.join(OUT, "alien_tower_%s.png" % key))
        ims.append(label(im.copy(), title))
        print("rendered", key, flush=True)
    th = 560
    sheet = Image.new("RGB", (th * 4, th * 2), BG)
    for k, im in enumerate(ims):
        sheet.paste(im.resize((th, th), Image.LANCZOS), ((k % 4) * th, (k // 4) * th))
    sheet.save(os.path.join(OUT, "alien_tower_sheet.png"))
    print("done")


if __name__ == "__main__":
    main()
