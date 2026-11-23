#!/usr/bin/env python3
"""Alien mining 'spider' reference model (companion of build_ship_ref.py / build_base_ref.py).

The spider is the aliens' digging machine: it rides a rock and mines saturnium
(docs/physics.md 9.1).  Four legs with the KNEES UP; the body is a bucket-like maw
that narrows downwards (an excavator scoop with teeth); on top a flat saucer dome;
lots of pipes and cables.  Greyscale only.  Axes: +Z up (feet down), model units
= SRV-T01 units (ship 48 long); in the game the spider is ~44 px across, i.e. about
the size of the ship, so the leg span here is ~62.

Run:  python tools/ship_ref/build_spider_ref.py  -> ship_ref/spider_*.png, spider.obj
"""
import math
import os
import sys
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_ship_ref as S                                      # noqa: E402
from build_ship_ref import Mesh, render, label, export_obj, BG   # noqa: E402
from build_base_ref import cyl_axis, annulus, basis, p3, block   # noqa: E402

OUT = S.OUT

G = {                       # greys
    "dome": (176, 180, 186),
    "dome_mid": (158, 162, 169),
    "rim": (126, 130, 138),
    "body": (146, 150, 157),
    "hopper": (118, 122, 130),
    "inner": (28, 30, 36),
    "tooth": (210, 213, 217),
    "joint": (204, 207, 212),
    "leg": (160, 164, 171),
    "leg_dark": (112, 116, 124),
    "foot": (84, 88, 96),
    "pipe": (96, 101, 109),
    "pipe_l": (150, 154, 161),
    "cable": (46, 50, 58),
    "bracket": (132, 136, 144),
    "vent": (40, 43, 50),
}


# ------------------------------------------------------------------ primitives
def lathe(m, profile, col, segs=44, sx=1.0, sy=1.0, caps_axis=False):
    """Surface of revolution about Z.  profile = [(r, z), ...] bottom->top or any order."""
    g = m.newgroup()
    for k in range(len(profile) - 1):
        (r0, z0), (r1, z1) = profile[k], profile[k + 1]
        dr, dz = r1 - r0, z1 - z0
        L = math.hypot(dr, dz)
        nr, nz = dz / L, -dr / L
        for i in range(segs):
            a, b = 2 * math.pi * i / segs, 2 * math.pi * (i + 1) / segs

            def P(r, z, t):
                return np.array((r * math.cos(t) * sx, r * math.sin(t) * sy, z))

            def N(t):
                n = np.array((nr * math.cos(t) / sx, nr * math.sin(t) / sy, nz))
                return n / np.linalg.norm(n)
            m.tri(P(r0, z0, a), P(r0, z0, b), P(r1, z1, b), col, g, (N(a), N(b), N(b)))
            m.tri(P(r0, z0, a), P(r1, z1, b), P(r1, z1, a), col, g, (N(a), N(b), N(a)))


def sphere(m, c, r, col, nlat=10, nlon=16):
    g = m.newgroup()
    c = np.asarray(c, float)
    for i in range(nlat):
        t0, t1 = math.pi * i / nlat, math.pi * (i + 1) / nlat
        for j in range(nlon):
            p0, p1 = 2 * math.pi * j / nlon, 2 * math.pi * (j + 1) / nlon

            def V(t, p):
                n = np.array((math.sin(t) * math.cos(p), math.sin(t) * math.sin(p), math.cos(t)))
                return c + n * r, n
            (a, na), (b, nb), (cc, nc), (d, nd) = V(t0, p0), V(t0, p1), V(t1, p1), V(t1, p0)
            m.tri(a, b, cc, col, g, (na, nb, nc))
            m.tri(a, cc, d, col, g, (na, nc, nd))


def bezier(p0, p1, p2, p3_, n=14):
    p0, p1, p2, p3_ = (np.asarray(x, float) for x in (p0, p1, p2, p3_))
    out = []
    for i in range(n + 1):
        t = i / n
        out.append((1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t * t * p2 + t ** 3 * p3_)
    return out


def polyline_tube(m, pts, r, col, segs=8, end_balls=False):
    g = m.newgroup()
    for a, b in zip(pts[:-1], pts[1:]):
        if np.linalg.norm(np.asarray(b) - np.asarray(a)) > 1e-6:
            cyl_axis(m, a, b, r, r, col, segs=segs, grp=g)
    if end_balls:
        sphere(m, pts[0], r * 1.5, col, 6, 8)
        sphere(m, pts[-1], r * 1.5, col, 6, 8)


def rpt(phi, r, z):
    return np.array((r * math.cos(phi), r * math.sin(phi), z))


# ------------------------------------------------------------------ dimensions
Z_GROUND = -16.0
DOME = [(0.0, 10.4), (2.4, 10.2), (5.0, 9.3), (8.0, 7.7), (11.0, 5.4), (13.4, 3.2), (14.2, 2.0), (14.2, 0.5),
        (12.6, -0.5), (9.5, -0.9)]


def dome_z(r):
    for (r0, z0), (r1, z1) in zip(DOME[:-1], DOME[1:]):
        if r0 <= r <= r1:
            return z0 + (z1 - z0) * (r - r0) / (r1 - r0)
    return DOME[-1][1]


HOP_TOP = (9.6, 7.4, -3.2)        # rx, ry, z at the neck
HOP_BOT = (5.4, 3.7, -13.0)       # rx, ry, z at the lip


def hopper_pt(theta, f=0.0):
    t = f
    rx = HOP_TOP[0] + (HOP_BOT[0] - HOP_TOP[0]) * t
    ry = HOP_TOP[1] + (HOP_BOT[1] - HOP_TOP[1]) * t
    z = HOP_TOP[2] + (HOP_BOT[2] - HOP_TOP[2]) * t
    return np.array((rx * math.cos(theta), ry * math.sin(theta), z))


# ------------------------------------------------------------------ the spider
def build():
    m = Mesh()
    # --- saucer dome: bands for panel lines
    bands = [(0, 3, G["dome"]), (3, 6, G["dome_mid"]), (6, 8, G["dome"]), (8, 9, G["rim"]), (9, 10, G["dome_mid"])]
    lathe(m, DOME[0:4], G["dome"])
    lathe(m, DOME[3:6], G["dome_mid"])
    lathe(m, DOME[5:8], G["rim"])
    lathe(m, DOME[7:10], G["dome_mid"])
    lathe(m, [(9.5, -0.9), (0.0, -0.9)], G["leg_dark"])              # underside plate
    # central turret bump + ring
    lathe(m, [(0.0, 11.9), (1.2, 11.7), (2.0, 11.0), (2.4, 10.2)], G["joint"], segs=24)
    # vent ports around the saucer
    for k in range(10):
        a = 2 * math.pi * (k + 0.5) / 10
        c = rpt(a, 8.8, dome_z(8.8) - 0.3)
        cyl_axis(m, c, c + np.array((0, 0, 1.6)), 0.9, 0.9, G["vent"], segs=10, caps=(False, True))
    # antenna whiskers
    for k, (dx, dy, L) in enumerate(((0.5, 0.0, 9), (-0.35, 0.4, 7), (-0.2, -0.45, 8))):
        b = np.array((0.0, 0.0, 11.9))
        t = b + np.array((dx * 2.2, dy * 2.2, L))
        cyl_axis(m, b, t, 0.3, 0.18, G["pipe_l"], segs=8, caps=(False, True))
        sphere(m, t, 0.6, G["joint"], 6, 8)

    # --- neck drum + ring pipes
    cyl_axis(m, p3((0, 0), -0.9), p3((0, 0), HOP_TOP[2]), 8.4, 8.4, G["body"], segs=44, caps=(False, False))
    for k, z in enumerate((-1.6, -2.4)):
        pts = [rpt(2 * math.pi * i / 40, 9.0 + k * 0.1, z) for i in range(41)]
        polyline_tube(m, pts, 0.45, G["pipe"])

    # --- hopper / maw: elliptical frustum, narrowing downwards, with an open throat and teeth
    prof_out = [(1.0, 0.0), (1.0, 1.0)]       # parametrised below
    segs = 44
    g = m.newgroup()
    for i in range(segs):
        a, b = 2 * math.pi * i / segs, 2 * math.pi * (i + 1) / segs
        p00, p01 = hopper_pt(a, 0), hopper_pt(b, 0)
        p10, p11 = hopper_pt(a, 1), hopper_pt(b, 1)
        m.quad(p00, p01, p11, p10, G["hopper"], g)
    # lip ring + throat
    lip_out = [hopper_pt(2 * math.pi * i / segs, 1) for i in range(segs)]
    throat = []
    for i in range(segs):
        t = 2 * math.pi * i / segs
        pt = hopper_pt(t, 1)
        throat.append(np.array((pt[0] * 0.72, pt[1] * 0.62, pt[2])))
    g = m.newgroup()
    for i in range(segs):
        j = (i + 1) % segs
        m.quad(lip_out[i], lip_out[j], throat[j], throat[i], G["tooth"], g)
    g = m.newgroup()
    for i in range(segs):
        j = (i + 1) % segs
        top_i = np.array((throat[i][0] * 1.2, throat[i][1] * 1.2, -7.5))
        top_j = np.array((throat[j][0] * 1.2, throat[j][1] * 1.2, -7.5))
        m.quad(throat[i], throat[j], top_j, top_i, G["inner"], g)
    g = m.newgroup()
    m.poly_fan([np.array((t[0] * 1.2, t[1] * 1.2, -7.5)) for t in throat], G["inner"], g)
    # teeth around the lip
    nt = 14
    for k in range(nt):
        t = 2 * math.pi * (k + 0.5) / nt
        base = hopper_pt(t, 1)
        out = np.array((math.cos(t), math.sin(t), 0.0))
        L = 3.6 if k % 2 == 0 else 2.8
        tip = base + out * 0.5 + np.array((0, 0, -L))
        cyl_axis(m, base + out * 0.1, tip, 0.95, 0.12, G["tooth"], segs=8)
    # collar bands on the hopper
    for f in (0.30, 0.62):
        pts = [hopper_pt(2 * math.pi * i / 40, f) * np.array((1.04, 1.04, 1.0)) for i in range(41)]
        polyline_tube(m, pts, 0.55, G["leg_dark"])
    # vertical pipe bundle down the hopper
    for k in range(10):
        t = 2 * math.pi * (k + 0.25) / 10
        a = hopper_pt(t, 0.02) * np.array((1.07, 1.07, 1.0))
        b = hopper_pt(t, 0.80) * np.array((1.12, 1.12, 1.0))
        cyl_axis(m, a, b, 0.42 if k % 2 else 0.55, 0.42 if k % 2 else 0.55, G["pipe"] if k % 3 else G["pipe_l"], segs=8, caps=(True, True))

    # --- four legs, knees up
    M_R, M_Z = 11.4, -0.8
    K_R, K_Z = 21.5, 14.0
    F_R, F_Z = 31.0, Z_GROUND + 1.0
    for k in range(4):
        phi = math.radians(45 + 90 * k)
        er = np.array((math.cos(phi), math.sin(phi), 0.0))
        et = np.array((-math.sin(phi), math.cos(phi), 0.0))
        M, K, F = rpt(phi, M_R, M_Z), rpt(phi, K_R, K_Z), rpt(phi, F_R, F_Z)
        # shoulder bracket under the saucer rim
        block(m, M[:2] - er[:2] * 0.0, 5.0, 5.0, math.degrees(phi), 4.6, -5.6, G["bracket"], ch=0.7)
        sphere(m, M, 2.3, G["joint"])
        cyl_axis(m, M, K, 1.9, 1.55, G["leg"], segs=18)
        sphere(m, K, 2.4, G["joint"])
        cyl_axis(m, K, F, 1.5, 0.9, G["leg"], segs=16)
        sphere(m, F, 1.3, G["joint"], 8, 12)
        cyl_axis(m, np.array((F[0], F[1], Z_GROUND)), np.array((F[0], F[1], Z_GROUND + 1.1)), 3.0, 2.6, G["foot"], segs=24, caps=(False, True))
        cyl_axis(m, np.array((F[0], F[1], Z_GROUND + 1.1)), F, 1.5, 1.0, G["leg_dark"], segs=12)
        # shoulder + knee clamp rings
        for f in (0.30, 0.55, 0.80):
            c = M + (K - M) * f
            ax = (K - M) / np.linalg.norm(K - M)
            cyl_axis(m, c - ax * 0.5, c + ax * 0.5, 2.2, 2.2, G["leg_dark"], segs=18, caps=(False, False))
        for f in (0.30, 0.65):
            c = K + (F - K) * f
            ax = (F - K) / np.linalg.norm(F - K)
            cyl_axis(m, c - ax * 0.45, c + ax * 0.45, 1.85 - 0.5 * f, 1.85 - 0.5 * f, G["leg_dark"], segs=16)
        # hydraulic ram (cylinder + rod) from the shoulder bracket to the upper leg
        H0 = rpt(phi, M_R - 1.5, M_Z - 3.3) + et * 2.2
        H1 = M + (K - M) * 0.62 + et * 2.0
        mid = H0 + (H1 - H0) * 0.55
        cyl_axis(m, H0, mid, 1.05, 1.05, G["pipe_l"], segs=12, caps=(True, True))
        cyl_axis(m, mid, H1, 0.5, 0.5, G["joint"], segs=8, caps=(False, True))
        sphere(m, H0, 1.2, G["joint"], 6, 8)
        sphere(m, H1, 0.9, G["joint"], 6, 8)
        # pipe pair along the lower leg
        for s in (-1, 1):
            a = K + et * 1.4 * s + er * 0.2
            b = F + et * 1.0 * s
            cyl_axis(m, a, b, 0.4, 0.4, G["pipe"] if s > 0 else G["pipe_l"], segs=8, caps=(True, True))
        # pipe pair along the upper leg
        for s in (-1, 1):
            a = M + et * 1.7 * s + np.array((0, 0, 1.0))
            b = K + et * 1.6 * s + np.array((0, 0, 0.9))
            cyl_axis(m, a, b, 0.38, 0.38, G["pipe_l"] if s > 0 else G["pipe"], segs=8, caps=(True, True))
        # cables from the saucer rim over to the knee (sagging) and down to the foot
        for s, rr in ((-1, 0.38), (1, 0.30)):
            start = M + et * 1.0 * s + np.array((0, 0, 3.4))
            end = K + et * 1.2 * s + np.array((0, 0, 1.6))
            pts = bezier(start, start + er * 7 + np.array((0, 0, 8)), end - er * 5 + np.array((0, 0, 8)), end)
            polyline_tube(m, pts, rr, G["cable"], end_balls=True)
            s2 = K + et * 1.2 * s + np.array((0, 0, 1.2))
            e2 = F + et * 0.9 * s + np.array((0, 0, 3.0))
            pts = bezier(s2, s2 + er * 6 + np.array((0, 0, 4)), e2 - er * 2 + np.array((0, 0, 7)), e2)
            polyline_tube(m, pts, rr * 0.9, G["cable"])
        # manifold pipe from the neck ring to the shoulder, looping
        a = rpt(phi, 8.8, -2.0)
        b = rpt(phi, M_R - 0.5, M_Z - 2.6)
        pts = bezier(a, a + er * 2 + np.array((0, 0, -3)), b - er * 3 + np.array((0, 0, 3)), b)
        polyline_tube(m, pts, 0.6, G["pipe_l"], end_balls=True)

    # --- cables over the saucer: from the turret, down the surface, between the legs
    for k in range(8):
        phi = math.radians(22.5 + 45 * k)
        pts = [rpt(phi, 2.6, dome_z(2.6) + 0.35)]
        for r in (4.5, 6.5, 8.5, 10.5, 12.5, 14.0):
            pts.append(rpt(phi, r, dome_z(r) + 0.45))
        pts += [rpt(phi, 14.9, 1.2), rpt(phi, 14.4, -0.4)]
        polyline_tube(m, pts, 0.32 if k % 2 else 0.42, G["cable"], end_balls=True)
        # drop from the rim to the neck ring, hanging loose
        a = rpt(phi, 14.4, -0.4)
        b = rpt(phi, 9.2, -2.4)
        pts = bezier(a, a + np.array((0, 0, -5)), b + rpt(phi, 4, 0) + np.array((0, 0, 1)), b)
        polyline_tube(m, pts, 0.32, G["cable"])
    return m


VIEWS = [
    ("front", "FRONT", 0, 0, 9.5, (0, 0, 0)),
    ("side", "SIDE", 90, 0, 9.5, (0, 0, 0)),
    ("diagonal", "DIAGONAL (legs side-on)", 45, 0, 9.5, (0, 0, 0)),
    ("top", "TOP", 0, 90, 9.5, (0, 0, 0)),
    ("bottom", "BOTTOM (the maw)", 0, -90, 9.5, (0, 0, 0)),
    ("three_quarter_1", "3/4 HIGH", 30, 28, 9.0, (0, 0, 0)),
    ("three_quarter_2", "3/4 HIGH (other side)", 165, 28, 9.0, (0, 0, 0)),
    ("three_quarter_low", "3/4 LOW (maw & teeth)", -35, -30, 9.0, (0, 0, -2)),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    m = build()
    export_obj(m, os.path.join(OUT, "spider.obj"))
    ims = []
    for key, title, az, el, scale, ctr in VIEWS:
        im = render(m, az, el, size=1000, ss=2, scale=scale, center=ctr, edge_dz=1.6)
        im.save(os.path.join(OUT, "spider_%s.png" % key))
        ims.append(label(im.copy(), title))
        print("rendered", key, flush=True)
    th = 560
    sheet = Image.new("RGB", (th * 4, th * 2), BG)
    for k, im in enumerate(ims):
        sheet.paste(im.resize((th, th), Image.LANCZOS), ((k % 4) * th, (k // 4) * th))
    sheet.save(os.path.join(OUT, "spider_sheet.png"))
    print("done")


if __name__ == "__main__":
    main()
