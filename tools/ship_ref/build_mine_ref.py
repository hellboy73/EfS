#!/usr/bin/env python3
"""Human EMP MINE reference model (companion of the other build_*_ref.py scripts).

Proportions from the game (src/enemies.s EN_EMP_MINE_S*, src/empmine.s), seen from above: THREE
triangles 120 degrees apart, each 10 px across its base and 13 px tall (apex 16 px from the middle),
their bases touching corner to corner round a small triangular gap 3 px from the middle.
Here each triangle is a SQUARE-BASED PYRAMID (base 10 x 10, height 13): the three square bases face
the middle and touch along their vertical edges, which leaves a triangular shaft open at the top and
the bottom, and in it a small white glowing ball (like the bulb under the UFO).

Grey pyramids with orange tips.  Axes: +Z up; arm 0 is +Y.
1 game px = 0.923 model units (SRV-T01 units, ship 48 long): base 9.2, height 12.0, ~30 across.

Run:  python tools/ship_ref/build_mine_ref.py  -> ship_ref/mine_*.png, mine.obj
"""
import math
import os
import sys
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_ship_ref as S                                         # noqa: E402
from build_ship_ref import Mesh, render, label, export_obj, BG      # noqa: E402
from build_base_ref import cyl_axis                                 # noqa: E402
from build_spider_ref import sphere                                 # noqa: E402

OUT = S.OUT
PX = 0.923
GLOW = (240, 248, 255)
S.EMISSIVE.add(GLOW)

C = {
    "pyr": (150, 154, 161),
    "pyr_dark": (108, 112, 120),
    "back": (62, 66, 74),
    "accent": (232, 112, 36),
}

B = 5.0 * PX                      # half the base side (game: base 10 px)
D = B / math.sqrt(3.0)            # base plane distance from the middle: bases touch at their vertical edges
H = 13.0 * PX                     # pyramid height (game: 13 px)
APEX = D + H                      # ~ 16 px from the middle, as in the game
BALL = D * 0.96


def arm(m, angle):
    er = np.array((math.cos(angle), math.sin(angle), 0.0))
    et = np.array((-math.sin(angle), math.cos(angle), 0.0))
    ez = np.array((0.0, 0.0, 1.0))

    def P(r, t, z):
        return er * r + et * t + ez * z

    base = [P(D, -B, -B), P(D, B, -B), P(D, B, B), P(D, -B, B)]
    apex = P(APEX, 0, 0)
    gb = m.newgroup()
    m.quad(*base, C["back"], gb)                                       # the square base, facing the middle
    for k in range(4):
        gk = m.newgroup()
        m.tri(base[k], base[(k + 1) % 4], apex, C["pyr"] if k % 2 == 0 else C["pyr_dark"], gk)
    # orange tip: the pyramid's last 22%, floated a hair outside the faces
    s_ = 0.22
    tip = [apex + (p_ - apex) * s_ for p_ in base]
    ctr = (base[0] + base[1] + base[2] + base[3]) / 4
    for k in range(4):
        t0, t1 = tip[k], tip[(k + 1) % 4]
        n = np.cross(t0 - apex, t1 - apex)
        n = n / np.linalg.norm(n)
        if n @ ((t0 + t1 + apex) / 3 - ctr) < 0:
            n = -n
        gk = m.newgroup()
        m.tri(t0 + n * 0.05, t1 + n * 0.05, apex + n * 0.05, C["accent"], gk)


def build():
    m = Mesh()
    for k in range(3):
        arm(m, math.radians(90 + 120 * k))
    sphere(m, (0, 0, 0), BALL, GLOW, 14, 24)                           # the glowing ball in the shaft
    return m


VIEWS = [
    ("top", "TOP (looking down the shaft)", 0, 90, 24.0, (0, 0, 0)),
    ("bottom", "BOTTOM", 0, -90, 24.0, (0, 0, 0)),
    ("side", "SIDE", 0, 0, 24.0, (0, 0, 0)),
    ("side_b", "SIDE (turned 60 deg)", 60, 0, 24.0, (0, 0, 0)),
    ("three_quarter_1", "3/4 HIGH", 25, 32, 24.0, (0, 0, 0)),
    ("three_quarter_2", "3/4 HIGH (other side)", 205, 32, 24.0, (0, 0, 0)),
    ("three_quarter_low", "3/4 LOW", -35, -30, 24.0, (0, 0, 0)),
    ("closeup", "CLOSE-UP: BALL IN THE SHAFT", 20, 55, 70.0, (0, 0, 0)),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    m = build()
    export_obj(m, os.path.join(OUT, "mine.obj"))
    ims = []
    for key, title, az, el, scale, ctr in VIEWS:
        im = render(m, az, el, size=1000, ss=2, scale=scale, center=ctr, edge_dz=0.5)
        im.save(os.path.join(OUT, "mine_%s.png" % key))
        ims.append(label(im.copy(), title))
        print("rendered", key, flush=True)
    th = 560
    sheet = Image.new("RGB", (th * 4, th * 2), BG)
    for k, im in enumerate(ims):
        sheet.paste(im.resize((th, th), Image.LANCZOS), ((k % 4) * th, (k // 4) * th))
    sheet.save(os.path.join(OUT, "mine_sheet.png"))
    print("done")


if __name__ == "__main__":
    main()
