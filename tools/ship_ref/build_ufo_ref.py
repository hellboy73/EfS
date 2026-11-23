#!/usr/bin/env python3
"""Alien UFO reference model (companion of the other build_*_ref.py scripts).

From the title screen: a classic flying saucer - a wide, thin disc with a small dome on
top and a bright emitter in the middle of the underside, light streaming down from it.
In the game its collision radius is 18 px (EN_UFO_R), so the saucer is ~34 units across
(the ship is 48 long).  Greyscale hull, near-white light.  Axes: +Z up.

Run:  python tools/ship_ref/build_ufo_ref.py  -> ship_ref/ufo_*.png, ufo.obj
"""
import math
import os
import sys
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_ship_ref as S                                         # noqa: E402
from build_ship_ref import Mesh, render, label, export_obj, BG      # noqa: E402
from build_base_ref import cyl_axis, annulus, p3                    # noqa: E402
from build_spider_ref import lathe, sphere, polyline_tube, rpt      # noqa: E402
from build_pulsar_ref import torus                                  # noqa: E402

OUT = S.OUT
LIGHT = (240, 248, 255)
LIGHT2 = (176, 192, 212)
S.EMISSIVE.update({LIGHT, LIGHT2, (214, 232, 250)})

G = {
    "dome": (192, 195, 200),
    "dome_ring": (112, 116, 124),
    "top_a": (168, 172, 179),
    "top_b": (146, 150, 157),
    "rim": (120, 124, 132),
    "rim_light": (206, 209, 214),
    "under_a": (104, 108, 116),
    "under_b": (126, 130, 138),
    "housing": (62, 66, 74),
    "seam": (60, 64, 72),
    "rib": (88, 92, 100),
}

DOME = [(0.0, 4.75), (1.8, 4.6), (3.6, 4.05), (5.2, 3.1), (6.4, 2.0), (6.9, 1.45)]
TOP = [(6.9, 1.45), (7.6, 1.3), (9.0, 1.15), (13.0, 0.8), (16.2, 0.35), (17.0, 0.05)]
RIM = [(17.0, 0.05), (17.15, -0.2), (16.4, -0.55)]
UNDER = [(16.4, -0.55), (15.2, -0.75), (14.2, -0.8), (13.8, -0.95), (10.0, -1.1), (9.6, -1.25),
         (6.0, -1.4), (5.6, -1.6), (4.9, -2.1)]


def z_on(prof, r):
    for (r0, z0), (r1, z1) in zip(prof[:-1], prof[1:]):
        lo, hi = min(r0, r1), max(r0, r1)
        if lo <= r <= hi and hi > lo:
            return z0 + (z1 - z0) * (r - r0) / (r1 - r0)
    return prof[-1][1]


def build():
    m = Mesh()
    # --- upper surface: a low smooth blister, a ring at its foot, a wide thin flange
    lathe(m, DOME, G["dome"], segs=64)
    lathe(m, TOP[0:3], G["top_a"], segs=64)
    lathe(m, TOP[2:4], G["top_b"], segs=64)
    lathe(m, TOP[3:6], G["top_a"], segs=64)
    torus(m, 1.5, 7.2, 0.4, G["dome_ring"], segs=56, rsegs=8)
    for r in (11.0, 14.5):                                                  # shallow grooves
        torus(m, z_on(TOP, r) + 0.02, r, 0.1, G["seam"], segs=64, rsegs=6)
    # --- the rim: thin bevelled lip with a ring of tiny port lights
    lathe(m, RIM, G["rim"], segs=64)
    for k in range(40):
        phi = 2 * math.pi * (k + 0.5) / 40
        cyl_axis(m, rpt(phi, 16.95, 0.0), rpt(phi, 17.2, 0.0), 0.2, 0.2, LIGHT2, segs=8, caps=(False, True))
    # --- underside: shallow concentric terraces
    lathe(m, UNDER[0:2], G["under_a"], segs=64)
    lathe(m, UNDER[1:4], G["under_b"], segs=64)
    lathe(m, UNDER[3:6], G["under_a"], segs=64)
    lathe(m, UNDER[5:9], G["under_b"], segs=64)
    for r in (14.0, 9.8, 6.0):
        torus(m, z_on(UNDER, r) - 0.04, r, 0.18, G["rib"], segs=56, rsegs=6)
    for k in range(6):                                                       # a few dark ports on the terrace
        phi = 2 * math.pi * (k + 0.5) / 6 + 0.3
        c = rpt(phi, 11.9, z_on(UNDER, 11.9) - 0.03)
        annulus(m, c, np.array((0, 0, -1.0)), 0.0, 0.55, G["housing"], 14)
    # --- the dark recess round the emitter, then the emitter: a glowing cone pointing down
    zf = -2.1
    gr = m.newgroup()
    for i in range(48):
        a, b = 2 * math.pi * i / 48, 2 * math.pi * (i + 1) / 48
        m.tri(np.array((0, 0, zf)), np.array((4.9 * math.cos(a), 4.9 * math.sin(a), zf)),
              np.array((4.9 * math.cos(b), 4.9 * math.sin(b), zf)), G["housing"], gr)
    ze = zf - 0.1
    bulb = [(3.5, ze), (3.3, ze - 1.1), (2.6, ze - 2.2), (1.5, ze - 3.1), (0.0, ze - 3.6)]
    lathe(m, bulb, LIGHT, segs=40)                                            # the white, glowing sphere-ish bulb
    return m


VIEWS = [
    ("side", "SIDE", 0, 0, 24.0, (0, 0, -8)),
    ("side_high", "SIDE, SLIGHTLY BELOW", 0, -10, 24.0, (0, 0, -8)),
    ("top", "TOP", 0, 90, 20.0, (0, 0, 0)),
    ("bottom", "FROM BELOW", 0, -90, 20.0, (0, 0, -3)),
    ("three_quarter_1", "3/4 HIGH", 30, 26, 24.0, (0, 0, -6)),
    ("three_quarter_2", "3/4 HIGH (other side)", 210, 26, 24.0, (0, 0, -6)),
    ("three_quarter_low", "3/4 LOW (emitter)", -35, -24, 24.0, (0, 0, -8)),
    ("closeup", "CLOSE-UP", 25, -14, 40.0, (0, 0, -5)),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    m = build()
    export_obj(m, os.path.join(OUT, "ufo.obj"))
    ims = []
    for key, title, az, el, scale, ctr in VIEWS:
        im = render(m, az, el, size=1000, ss=2, scale=scale, center=ctr, edge_dz=0.6)
        im.save(os.path.join(OUT, "ufo_%s.png" % key))
        ims.append(label(im.copy(), title))
        print("rendered", key, flush=True)
    th = 560
    sheet = Image.new("RGB", (th * 4, th * 2), BG)
    for k, im in enumerate(ims):
        sheet.paste(im.resize((th, th), Image.LANCZOS), ((k % 4) * th, (k // 4) * th))
    sheet.save(os.path.join(OUT, "ufo_sheet.png"))
    print("done")


if __name__ == "__main__":
    main()
