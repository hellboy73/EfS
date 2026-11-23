#!/usr/bin/env python3
"""Alien PULSAR reference model (companion of the other build_*_ref.py scripts).

From the game (src/enemies.s EN_PULSAR_S*, src/pulsar.s), seen from the side: two low,
very obtuse cones, bases facing each other, apexes outward - 37 px across the base, 9 px
tall - with a gap between the bases that opens (18 px) and closes (4 px); a bar (the laser)
runs horizontally through the gap and the beam leaves BOTH ends of it at once, only when
the cones are closest.  Here that becomes a solid of revolution about Z (so a camera at
elevation 0 gives the game's side view), with a big winding (a coil) between the cones.

  idle : cones apart, coil wound out between them, no beam
  fire : cones close, coil squeezed, the gap glows, two beams along +X and -X

Units = SRV-T01 units (1 game px = 0.923): cone base R 17.2, cone height 8.3.
Greyscale (like the spider); the beam is near-white.

Run:  python tools/ship_ref/build_pulsar_ref.py  -> ship_ref/pulsar_*.png, pulsar_idle.obj, pulsar_fire.obj
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
from build_spider_ref import lathe, sphere, bezier, polyline_tube, rpt   # noqa: E402

OUT = S.OUT

BEAM = (240, 248, 255)
HUB_GLOW = (214, 232, 250)
S.EMISSIVE.update({BEAM, HUB_GLOW, (176, 192, 212)})

G = {
    "cone": (160, 164, 171),
    "cone_dark": (118, 122, 130),
    "rim": (104, 108, 116),
    "plate": (70, 74, 82),
    "wire": (132, 136, 144),
    "wire_dark": (84, 88, 96),
    "hub": (40, 44, 52),
    "strap": (176, 180, 186),
    "axle": (190, 193, 198),
    "cable": (46, 50, 58),
    "nozzle": (60, 64, 72),
    "ring_pulse": (176, 192, 212),
}

R_BASE = 17.2
CONE_H = 8.3
GAP_IDLE = 16.6          # between the two bases (game: 18 px)
GAP_FIRE = 7.5           # (game: 4 px; opened a little here so the coil fits)
COIL_HALF = 10.0         # the winding hangs in the gap, wound round the beam axis (X)
COIL_RAD = 3.0
COIL_WIRE = 0.5
COIL_TURNS = 9
BEAM_LEN = 110.0         # shown; in the game it is ~254 px (234 units) a side


def torus(m, cz, R, r, col, segs=56, rsegs=10):
    g = m.newgroup()
    for i in range(segs):
        u0, u1 = 2 * math.pi * i / segs, 2 * math.pi * (i + 1) / segs
        for j in range(rsegs):
            v0, v1 = 2 * math.pi * j / rsegs, 2 * math.pi * (j + 1) / rsegs

            def P(u, v):
                n = np.array((math.cos(v) * math.cos(u), math.cos(v) * math.sin(u), math.sin(v)))
                return np.array(((R + r * math.cos(v)) * math.cos(u), (R + r * math.cos(v)) * math.sin(u), cz + r * math.sin(v))), n
            (a, na), (b, nb), (c, nc), (d, nd) = P(u0, v0), P(u1, v0), P(u1, v1), P(u0, v1)
            m.tri(a, b, c, col, g, (na, nb, nc))
            m.tri(a, c, d, col, g, (na, nc, nd))


def cone_profile(g):
    """Profile of the upper cone, base at z=g: stepped terraces, very obtuse overall."""
    pts = [(R_BASE, 0.0), (R_BASE, 1.3), (16.0, 1.7), (12.6, 3.6), (12.6, 4.0), (9.2, 5.5), (9.2, 5.9),
           (5.2, 7.3), (5.2, 7.7), (1.8, 8.3), (0.0, 8.6)]
    return [(r, g + z) for r, z in pts]


def helix_coil(m, half_len, R, wire_r, turns, col, col2):
    """Winding round the X axis (the beam's axis): a helix of wire, floating, nothing holds it."""
    steps = 28
    pts = []
    total = turns * steps
    for i in range(total + 1):
        t = i / steps
        x = -half_len + 2 * half_len * i / total
        th = 2 * math.pi * t
        pts.append(np.array((x, R * math.cos(th), R * math.sin(th))))
    polyline_tube(m, pts, wire_r, col, segs=8)
    # a second, thinner counter-wound strand for a woven look
    pts2 = []
    for i in range(total + 1):
        t = i / steps
        x = -half_len + 2 * half_len * i / total
        th = 2 * math.pi * t + math.pi
        pts2.append(np.array((x, (R + wire_r * 0.2) * math.cos(th), (R + wire_r * 0.2) * math.sin(th))))
    polyline_tube(m, pts2, wire_r * 0.7, col2, segs=8)
    # end rings: the coil's two ends are closed with a thin ring
    for sgn in (-1, 1):
        c = np.array((sgn * half_len, 0.0, 0.0))
        annulus(m, c, np.array((1.0, 0, 0)), R - wire_r, R + wire_r * 1.1, col2, 24)


def build(fire):
    m = Mesh()
    gap = GAP_FIRE if fire else GAP_IDLE
    g = gap / 2.0
    for sgn in (1, -1):
        prof = cone_profile(g)
        if sgn < 0:
            prof = [(r, -z) for r, z in prof]
        lathe(m, prof[0:3], G["rim"], segs=56)
        lathe(m, prof[2:5], G["cone"], segs=56)
        lathe(m, prof[4:8], G["cone_dark"], segs=56)
        lathe(m, prof[7:11], G["cone"], segs=56)
        # flat face looking at the gap
        gp = m.newgroup()
        zf = sgn * g
        for i in range(56):
            a, b = 2 * math.pi * i / 56, 2 * math.pi * (i + 1) / 56
            m.tri(np.array((0, 0, zf)), np.array((R_BASE * math.cos(a), R_BASE * math.sin(a), zf)),
                  np.array((R_BASE * math.cos(b), R_BASE * math.sin(b), zf)), G["plate"], gp)
        torus(m, sgn * (g + 0.65), R_BASE - 0.1, 0.65, G["rim"], segs=56, rsegs=8)
        for k in range(12):                               # small round vents on the second terrace
            phi = 2 * math.pi * (k + 0.5) / 12
            c = rpt(phi, 10.9, sgn * (g + 4.6))
            cyl_axis(m, c, c + np.array((0, 0, sgn * 0.8)), 0.6, 0.6, G["hub"], segs=8, caps=(False, True))
        sphere(m, (0, 0, sgn * (g + CONE_H + 0.35)), 1.1, G["axle"], 8, 12)

    # --- the winding: hangs in the gap, wound round the beam's axis (X)
    helix_coil(m, COIL_HALF, COIL_RAD, COIL_WIRE, COIL_TURNS, G["wire"], G["wire_dark"])

    if fire:
        # the laser leaves the coil along +X and -X: a hot core inside it, then the beams
        sphere(m, (0, 0, 0), 1.7, HUB_GLOW, 10, 16)
        cyl_axis(m, np.array((-COIL_HALF, 0, 0)), np.array((COIL_HALF, 0, 0)), 0.9, 0.9, BEAM, segs=12)
        for sgn in (1, -1):
            x0 = sgn * COIL_HALF
            x1 = sgn * (COIL_HALF + BEAM_LEN)
            cyl_axis(m, np.array((x0, 0, 0)), np.array((x1, 0, 0)), 0.95, 0.45, BEAM, segs=12, caps=(False, True))
            cyl_axis(m, np.array((x0, 0, 0)), np.array((x0 + sgn * 3.5, 0, 0)), 1.7, 0.95, HUB_GLOW, segs=12)
            for t in (0.12, 0.30, 0.52, 0.80):
                c = np.array((x0 + sgn * BEAM_LEN * t, 0, 0))
                annulus(m, c, np.array((1.0, 0, 0)), 0.95, 3.0 * (1.1 - 0.6 * t), (176, 192, 212), 24)
    return m


VIEWS = [
    ("side", "SIDE (the game's view)", 0, 0, 8.0, (0, 0, 0)),
    ("end", "ALONG THE BEAM", 90, 0, 8.0, (0, 0, 0)),
    ("top", "TOP (along the axis)", 0, 90, 8.0, (0, 0, 0)),
    ("three_quarter_1", "3/4 HIGH", 30, 26, 7.5, (0, 0, 0)),
    ("three_quarter_2", "3/4 HIGH (other side)", 205, 26, 7.5, (0, 0, 0)),
    ("three_quarter_low", "3/4 LOW", -40, -24, 7.5, (0, 0, 0)),
    ("full", "FULL BEAM LENGTH SHOWN", 25, 20, 3.7, (0, 0, 0)),
    ("closeup", "CLOSE-UP OF THE GAP", 22, 10, 15.0, (0, 0, 0)),
]


def run(fire):
    tag = "fire" if fire else "idle"
    m = build(fire)
    export_obj(m, os.path.join(OUT, "pulsar_%s.obj" % tag))
    ims = []
    for key, title, az, el, scale, ctr in VIEWS:
        im = render(m, az, el, size=1000, ss=2, scale=scale, center=ctr, edge_dz=1.2)
        im.save(os.path.join(OUT, "pulsar_%s_%s.png" % (tag, key)))
        ims.append(label(im.copy(), title + (" - FIRING" if fire else " - idle")))
        print("rendered", tag, key, flush=True)
    th = 560
    sheet = Image.new("RGB", (th * 4, th * 2), BG)
    for k, im in enumerate(ims):
        sheet.paste(im.resize((th, th), Image.LANCZOS), ((k % 4) * th, (k // 4) * th))
    sheet.save(os.path.join(OUT, "pulsar_%s_sheet.png" % tag))


def main():
    os.makedirs(OUT, exist_ok=True)
    run(False)
    run(True)
    # the two states side by side in the game's view
    a = Image.open(os.path.join(OUT, "pulsar_idle_side.png"))
    b = Image.open(os.path.join(OUT, "pulsar_fire_side.png"))
    cmp_ = Image.new("RGB", (2000, 480), BG)
    cmp_.paste(a.crop((0, 260, 1000, 740)), (0, 0))
    cmp_.paste(b.crop((0, 260, 1000, 740)), (1000, 0))
    label(cmp_, "IDLE (cones apart, no beam)")
    d = __import__("PIL.ImageDraw", fromlist=["ImageDraw"]).Draw(cmp_)
    d.text((1018, 14), "FIRING (cones together, beam both ways)", fill=(235, 238, 242),
           font=__import__("PIL.ImageFont", fromlist=["ImageFont"]).truetype("arial.ttf", 26))
    cmp_.save(os.path.join(OUT, "pulsar_compare.png"))
    # two separate pictures at the SAME zoom and camera: idle, firing
    for tag, fire in (("idle", False), ("fire", True)):
        mm = build(fire)
        for key, az, el in (("hero", 28, 16), ("side", 0, 0)):
            im = render(mm, az, el, size=1200, ss=2, scale=17.0, center=(0, 0, 0), edge_dz=1.0)
            im.save(os.path.join(OUT, "pulsar_%s_%s.png" % (key, tag)))
    print("done")


if __name__ == "__main__":
    main()
