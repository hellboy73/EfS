#!/usr/bin/env python3
"""Human TRANSPORTER reference model (companion of the other build_*_ref.py scripts).

Proportions are the game's EN_TRANSPORTER shape (src/enemies.s), top view, 1 unit = 1 sprite unit:
  part 0 outline: 90 x 60 - two drive cylinders 90 long x 15 across (y = +-15..30), joined by a
                  spine 80 long (x = +-40) between them (y = -15..15)
  part 1 outline: the container, 40 long x 29 wide, centred between the cylinders.
The container is LOWER than the cylinders (user).  Heights are not in the game data (it is flat).

Axes: +X = front (long axis), +Y = left, +Z = up.  Front = domed ends, rear (-X) = engine bells.
Run:  python tools/ship_ref/build_transporter_ref.py  -> ship_ref/transporter_*.png, transporter.obj
"""
import math
import os
import sys
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_ship_ref as S                                         # noqa: E402
from build_ship_ref import Mesh, render, label, export_obj, BG      # noqa: E402
from build_base_ref import cyl_axis, annulus, block, prism                 # noqa: E402

OUT = S.OUT
C = {
    "tank": (206, 210, 216),
    "tank_dark": (120, 126, 136),
    "ring": (150, 156, 166),
    "accent": (232, 112, 36),
    "box": (176, 150, 112),
    "box_dark": (132, 110, 80),
    "spine": (96, 102, 112),
    "nozzle": (52, 56, 64),
    "glow": (110, 200, 255),
    "lamp": (255, 206, 110),
}
S.EMISSIVE.add(C["glow"])
S.EMISSIVE.add(C["lamp"])

HS = 7.5               # engine half-section: the engines are SQUARE 15 x 15 in section
CY = 22.5              # engine axis offset in y
XR, XF, TIP = -40.0, 35.0, 48.0   # engine rear face, beak start, beak front (game outline: -45 incl. nozzles)


def X(x, y, z):
    return np.array((x, y, z), float)


def build():
    m = Mesh()
    for sgn in (-1, 1):
        y = sgn * CY
        # square-section engine body, bevelled edges
        block(m, ((XR + XF) / 2, y), XF - XR, 2 * HS, 0.0, 2 * HS, -HS, C["tank"], ch=1.3)
        # square collars (orange at the ends, grey between)
        for xr, col in ((-36.0, "accent"), (-33.0, "ring"), (-14.0, "ring"), (6.0, "ring"), (26.0, "ring"), (29.5, "accent")):
            wid = 2.4 if col == "accent" else 1.2
            block(m, (xr, y), wid, 2 * HS + 0.5, 0.0, 2 * HS + 0.5, -HS - 0.25, C[col], ch=0.4)
        # side vents on the outer wall
        for xr in (-24.0, -20.0, -16.0 + 12, 14.0, 18.0):
            block(m, (xr, sgn * (CY + HS + 0.1)), 2.0, 0.4, 0.0, 6.0, -3.0, C["tank_dark"], ch=0.1)
        # rear: the square body ends in a ROUND nozzle - collar ring, bell, glow
        cyl_axis(m, X(XR, y, 0.0), X(XR - 1.2, y, 0.0), 5.6, 5.6, C["tank_dark"], segs=40)
        cyl_axis(m, X(XR - 1.2, y, 0.0), X(XR - 5.0, y, 0.0), 4.6, 6.4, C["nozzle"], segs=40)
        annulus(m, X(XR - 5.0 + 0.05, y, 0.0), X(-1, 0, 0), 0.0, 5.7, C["glow"], 40)

    # beak: a flat-fronted wedge as tall as the engines, all edges bevelled, flows on from both engines
    poly = [np.array(q, float) for q in ((XF, -30.0), (TIP, -4.0), (TIP, 4.0), (XF, 30.0))]
    prism(m, poly, 2 * HS, ch=2.0, z0=-HS, cols=dict(wall=C["tank"], chamfer=C["ring"], bevel=C["ring"],
                                                      top=C["tank"], bottom=C["tank_dark"]))

    # belly plate: closes the bevel grooves where the engines meet the deck from below
    block(m, ((XR + XF) / 2 + 1.0, 0.0), XF - XR + 2.0, 2 * 28.8, 0.0, 1.5, -HS, C["tank_dark"], ch=0.3)

    # closed hull between the engines: deck plate with a rear bulkhead (stern closed) and a front bulkhead
    block(m, ((XR + XF) / 2, 0.0), XF - XR, 2 * CY - 2 * HS + 0.2, 0.0, 3.5, -HS, C["spine"], ch=0.4)
    block(m, (XR + 1.0, 0.0), 2.0, 2 * CY - 2 * HS + 0.2, 0.0, 9.5, -HS, C["spine"], ch=0.4)
    block(m, (XF - 1.0, 0.0), 2.0, 2 * CY - 2 * HS + 0.2, 0.0, 9.5, -HS, C["spine"], ch=0.4)

    # cargo container: same as before, but TALLER (still just below the engine tops)
    BX, BY, BH = 20.0, 14.5, 10.5
    zb = -4.0
    block(m, (0.0, 0.0), 2 * BX, 2 * BY, 0.0, BH, zb, C["box"], ch=0.8)
    for xr in np.linspace(-BX + 3, BX - 3, 9):
        for sgn in (-1, 1):
            block(m, (xr, sgn * (BY + 0.15)), 1.1, 0.5, 0.0, BH - 1.6, zb + 0.8, C["box_dark"], ch=0.1)
    block(m, (0.0, 0.0), 2 * BX + 0.4, 2 * BY + 0.4, 0.0, 1.8, zb + BH * 0.45, C["accent"], ch=0.1)
    for sx in (-1, 1):
        for sy in (-1, 1):
            block(m, (sx * (BX - 0.7), sy * (BY - 0.7)), 2.2, 2.2, 0.0, BH + 0.8, zb - 0.2, C["tank_dark"], ch=0.3)
    block(m, (BX - 5, 0.0), 2.0, 2.0, 0.0, 1.4, zb + BH, C["lamp"], ch=0.3)
    return m


VIEWS = [
    ("top", "TOP", 0, 90, 5.4, (0, 0, 0)),
    ("side", "SIDE", 0, 0, 5.4, (0, 0, 0)),
    ("front", "FRONT", 90, 0, 9.0, (0, 0, 0)),
    ("rear", "REAR", -90, 0, 9.0, (0, 0, 0)),
    ("three_quarter_1", "3/4 HIGH, FRONT LEFT", 35, 28, 5.4, (0, 0, 0)),
    ("three_quarter_2", "3/4 HIGH, REAR RIGHT", 215, 28, 5.4, (0, 0, 0)),
    ("three_quarter_low", "3/4 LOW", -35, -22, 5.4, (0, 0, 0)),
    ("bottom", "BOTTOM", 0, -90, 5.4, (0, 0, 0)),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    m = build()
    export_obj(m, os.path.join(OUT, "transporter.obj"))
    ims = []
    for key, title, az, el, scale, ctr in VIEWS:
        im = render(m, az, el, size=1000, ss=2, scale=scale, center=ctr, edge_dz=0.7)
        im.save(os.path.join(OUT, "transporter_%s.png" % key))
        ims.append(label(im.copy(), title))
        print("rendered", key, flush=True)
    th = 560
    sheet = Image.new("RGB", (th * 4, th * 2), BG)
    for k, im in enumerate(ims):
        sheet.paste(im.resize((th, th), Image.LANCZOS), ((k % 4) * th, (k // 4) * th))
    sheet.save(os.path.join(OUT, "transporter_sheet.png"))
    print("done")


if __name__ == "__main__":
    main()
