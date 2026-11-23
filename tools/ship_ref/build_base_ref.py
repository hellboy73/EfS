#!/usr/bin/env python3
"""Human mining base reference model (companion of build_ship_ref.py).

In the game the base is six equilateral triangles, 140 px a side, laid out as a
hexagon with their apexes towards the middle and 16 px between them (src/base.s,
design_technical 11.48): centroids 96 px from the middle, circumradius 80.8 px,
inradius 40.4 px.  Here every triangle becomes a MODULE - a chamfered triangular
prism as tall as one side of the triangle - and the modules are joined by
narrow tunnels across the 16 px gaps.  Landing pads for ships like SRV-T01 are on
the roofs; a few ships are parked on them for scale.

Scale: one model unit = one SRV-T01 unit (ship 48 long = its 52 px sprite), and
the whole base is enlarged BASE_SCALE x over the game (user: "probably 2x").

Run:  python tools/ship_ref/build_base_ref.py   -> ship_ref/srv_base_*.png, srv_base.obj
"""
import math
import os
import sys
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_ship_ref as S                      # noqa: E402
from build_ship_ref import Mesh, render, label, export_obj, BG   # noqa: E402

OUT = S.OUT
BASE_SCALE = 1.5
K = (48.0 / 52.0) * BASE_SCALE                  # model units per game pixel
SIDE_PX, GAP_PX, CENT_PX = 140.0, 16.0, 96.0    # game numbers (base.s)

# palette (extends the ship's)
C = {
    "wall": (214, 218, 224),
    "chamfer": (172, 178, 188),
    "bevel": (232, 235, 239),
    "top": (196, 201, 208),
    "bottom": (214, 218, 224),
    "glass": (20, 34, 50),
    "lit": (255, 206, 110),
    "vent": (44, 48, 56),
    "slat": (122, 128, 138),
    "accent": (232, 112, 36),
    "dark": (34, 38, 46),
    "pad": (88, 94, 104),
    "padring": (232, 112, 36),
    "padmark": (236, 238, 240),
    "tunnel": (190, 196, 204),
    "flange": (140, 146, 156),
    "beacon": (255, 70, 60),
}

H = 0.5 * SIDE_PX * K                           # module height = HALF a triangle side
CH = 6.0                                        # bevel size on every edge
CUT = 15.0                                      # vertical-edge chamfer (apex a bit more)
CUT_APEX = 20.0
RECESS_F = 0.66                                 # recess = the module's own triangle, this fraction
RECESS_D = 4.5                                  # recess depth


# ------------------------------------------------------------------ geometry helpers
def offset_convex(P, d):
    """Inward offset of a convex CCW polygon."""
    n = len(P)
    lines = []
    for k in range(n):
        a, b = P[k], P[(k + 1) % n]
        e = (b - a) / np.linalg.norm(b - a)
        inward = np.array((-e[1], e[0]))
        lines.append((a + inward * d, e))
    out = []
    for k in range(n):
        (p1, e1), (p2, e2) = lines[k - 1], lines[k]
        A = np.array([[e1[0], -e2[0]], [e1[1], -e2[1]]])
        t = np.linalg.solve(A, p2 - p1)
        out.append(p1 + e1 * t[0])
    return out


def p3(P, z):
    return np.array((P[0], P[1], z), float)


def basis(n):
    n = np.asarray(n, float)
    n = n / np.linalg.norm(n)
    ref = np.array((0, 0, 1.0)) if abs(n[2]) < 0.9 else np.array((1.0, 0, 0))
    u = np.cross(n, ref)
    u /= np.linalg.norm(u)
    return u, np.cross(n, u)


def cyl_axis(m, p0, p1, r0, r1, col, segs=28, caps=(False, False), grp=None):
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    a = p1 - p0
    a /= np.linalg.norm(a)
    u, v = basis(a)
    g = grp if grp is not None else m.newgroup()
    d = [math.cos(2 * math.pi * i / segs) * u + math.sin(2 * math.pi * i / segs) * v for i in range(segs + 1)]
    for i in range(segs):
        q00, q01 = p0 + d[i] * r0, p0 + d[i + 1] * r0
        q10, q11 = p1 + d[i] * r1, p1 + d[i + 1] * r1
        m.tri(q00, q01, q11, col, g, (d[i], d[i + 1], d[i + 1]))
        m.tri(q00, q11, q10, col, g, (d[i], d[i + 1], d[i]))
    for end, (p, r) in enumerate(((p0, r0), (p1, r1))):
        if caps[end] and r > 0:
            g2 = m.newgroup()
            for i in range(segs):
                m.tri(p, p + d[i] * r, p + d[i + 1] * r, col, g2)


def annulus(m, c, n, r_in, r_out, col, segs=36):
    u, v = basis(n)
    g = m.newgroup()
    for i in range(segs):
        a, b = 2 * math.pi * i / segs, 2 * math.pi * (i + 1) / segs
        da = math.cos(a) * u + math.sin(a) * v
        db = math.cos(b) * u + math.sin(b) * v
        m.quad(c + da * r_in, c + da * r_out, c + db * r_out, c + db * r_in, col, g)


def disc_decal(m, c, n, r, col, segs=36):
    annulus(m, c, n, 0.0, r, col, segs)


# ------------------------------------------------------------------ module prism
def prism(m, poly, h, ch=None, z0=0.0, cols=None, hole=None, depth=0.0):
    """Chamfered prism over a convex CCW polygon.  `hole`: a triangle (3 points, vertex j
    belonging to poly[2j], poly[2j+1]) sunk `depth` into the roof."""
    ch = CH if ch is None else ch
    cl = dict(wall=C["wall"], chamfer=C["chamfer"], bevel=C["bevel"], top=C["top"], bottom=C["bottom"])
    if cols:
        cl.update(cols)
    n = len(poly)
    inner = offset_convex(poly, ch)
    zt = z0 + h
    g = m.newgroup()
    m.poly_fan([p3(q, z0) for q in inner], cl["bottom"], g)
    if hole is None:
        g = m.newgroup()
        m.poly_fan([p3(q, zt) for q in inner], cl["top"], g)
    else:
        g = m.newgroup()
        for j in range(3):
            o0, o1 = inner[2 * j], inner[2 * j + 1]
            o2 = inner[(2 * j + 2) % 6]
            ij, ij1 = hole[j], hole[(j + 1) % 3]
            m.tri(p3(o0, zt), p3(o1, zt), p3(ij, zt), cl["top"], g)                     # corner
            m.quad(p3(o1, zt), p3(o2, zt), p3(ij1, zt), p3(ij, zt), cl["top"], g)       # edge strip
        for j in range(3):
            a_, b_ = hole[j], hole[(j + 1) % 3]
            gw = m.newgroup()
            m.quad(p3(a_, zt), p3(b_, zt), p3(b_, zt - depth), p3(a_, zt - depth), C["chamfer"], gw)
        gf = m.newgroup()
        m.tri(p3(hole[0], zt - depth), p3(hole[1], zt - depth), p3(hole[2], zt - depth), C["pad"], gf)
    for k in range(n):
        k2 = (k + 1) % n
        col = cl["chamfer"] if k % 2 == 0 else cl["wall"]
        g = m.newgroup()
        m.quad(p3(inner[k], z0), p3(inner[k2], z0), p3(poly[k2], z0 + ch), p3(poly[k], z0 + ch), cl["bevel"], g)
        g = m.newgroup()
        m.quad(p3(poly[k], zt - ch), p3(poly[k2], zt - ch), p3(inner[k2], zt), p3(inner[k], zt), cl["bevel"], g)
        g = m.newgroup()
        m.quad(p3(poly[k], z0 + ch), p3(poly[k2], z0 + ch), p3(poly[k2], zt - ch), p3(poly[k], zt - ch), col, g)
    return inner


def block(m, c2, w, l, yaw_deg, h, z0, col=None, ch=0.9):
    """Small chamfered machinery block; w along its own x, l along its own y."""
    a = math.radians(yaw_deg)
    ex, ey = np.array((math.cos(a), math.sin(a))), np.array((-math.sin(a), math.cos(a)))
    c2 = np.asarray(c2, float)
    pts = [c2 - ex * w / 2 - ey * l / 2, c2 + ex * w / 2 - ey * l / 2,
           c2 + ex * w / 2 + ey * l / 2, c2 - ex * w / 2 + ey * l / 2]
    col = col or C["slat"]
    ch = min(ch, w / 3, l / 3, h / 2)
    inner = offset_convex(pts, ch)
    zt = z0 + h
    for k in range(4):
        k2 = (k + 1) % 4
        g = m.newgroup()
        m.quad(p3(pts[k], z0), p3(pts[k2], z0), p3(pts[k2], zt - ch), p3(pts[k], zt - ch), col, g)
        g = m.newgroup()
        m.quad(p3(pts[k], zt - ch), p3(pts[k2], zt - ch), p3(inner[k2], zt), p3(inner[k], zt), C["bevel"], g)
    g = m.newgroup()
    m.poly_fan([p3(q, zt) for q in inner], col, g)


class Wall:
    def __init__(self, a, b):
        self.a, self.b = np.array(a, float), np.array(b, float)
        self.L = float(np.linalg.norm(self.b - self.a))
        self.d = (self.b - self.a) / self.L
        self.n = np.array((self.d[1], -self.d[0], 0.0))      # outward for a CCW polygon

    def P(self, u, v, off=0.0):
        return np.array((self.a[0] + self.d[0] * u, self.a[1] + self.d[1] * u, v)) + self.n * off


# ------------------------------------------------------------------ wall decals
def rect(m, w, u0, u1, v0, v1, col, off=0.4):
    g = m.newgroup()
    m.quad(w.P(u0, v0, off), w.P(u1, v0, off), w.P(u1, v1, off), w.P(u0, v1, off), col, g)


def windows(m, w, fu0, fu1, fv0, fv1, nu, nv, rng, lit=0.35, gap=0.35):
    u0, u1, v0, v1 = fu0 * w.L, fu1 * w.L, fv0 * H, fv1 * H
    cu, cv = (u1 - u0) / nu, (v1 - v0) / nv
    for i in range(nu):
        for j in range(nv):
            a, b = u0 + i * cu + cu * gap / 2, u0 + (i + 1) * cu - cu * gap / 2
            c0, c1 = v0 + j * cv + cv * gap / 2, v0 + (j + 1) * cv - cv * gap / 2
            col = C["lit"] if rng.random() < lit else C["glass"]
            rect(m, w, a, b, c0, c1, col, 0.4)


def vents(m, w, fu0, fu1, fv0, fv1, slats):
    u0, u1, v0, v1 = fu0 * w.L, fu1 * w.L, fv0 * H, fv1 * H
    rect(m, w, u0, u1, v0, v1, C["vent"], 0.4)
    step = (v1 - v0) / slats
    for i in range(slats):
        rect(m, w, u0 + 2, u1 - 2, v0 + i * step + step * 0.55, v0 + i * step + step * 0.85, C["slat"], 0.7)


def door(m, w, fu0, fu1, fv0, fv1, hazard=True):
    u0, u1, v0, v1 = fu0 * w.L, fu1 * w.L, fv0 * H, fv1 * H
    rect(m, w, u0, u1, v0, v1, C["vent"], 0.4)
    rect(m, w, (u0 + u1) / 2 - 0.8, (u0 + u1) / 2 + 0.8, v0, v1, C["slat"], 0.7)
    if hazard:
        nseg = 14
        sw = (u1 - u0) / nseg
        for i in range(nseg):
            rect(m, w, u0 + i * sw, u0 + (i + 1) * sw, v1 - 11, v1, C["accent"] if i % 2 == 0 else C["dark"], 0.7)


def stripe(m, w, fv0, fv1, col=None):
    rect(m, w, 0.0, w.L, fv0 * H, fv1 * H, col or C["accent"], 0.4)


def seams(m, w, n):
    for i in range(1, n):
        u = w.L * i / n
        rect(m, w, u - 0.5, u + 0.5, 0, H, C["slat"], 0.3)


def port(m, w, fu, fv, r):
    c = w.P(fu * w.L, fv * H, 0.5)
    annulus(m, c, w.n, r * 0.62, r, C["flange"])
    annulus(m, c + w.n * 0.2, w.n, r * 0.55, r * 0.62, C["accent"])
    disc_decal(m, c + w.n * 0.3, w.n, r * 0.55, C["vent"])


# ------------------------------------------------------------------ one module
def module(m, i, rng):
    th = math.radians(90 + 60 * i)
    r_hat = np.array((math.cos(th), math.sin(th)))
    t_hat = np.array((-math.sin(th), math.cos(th)))
    cen = r_hat * CENT_PX * K
    circ = SIDE_PX / math.sqrt(3) * K
    inr = SIDE_PX / (2 * math.sqrt(3)) * K
    V = [cen - r_hat * circ, cen + r_hat * inr + t_hat * SIDE_PX / 2 * K,
         cen + r_hat * inr - t_hat * SIDE_PX / 2 * K]        # apex, then two outer corners
    area = sum(V[j][0] * V[(j + 1) % 3][1] - V[(j + 1) % 3][0] * V[j][1] for j in range(3))
    if area < 0:
        V = [V[0], V[2], V[1]]
    # chamfer the vertical edges
    poly = []
    for j in range(3):
        v, pr, nx = V[j], V[j - 1], V[(j + 1) % 3]
        cut = CUT_APEX if j == 0 else CUT
        poly.append(v + (pr - v) / np.linalg.norm(pr - v) * cut)
        poly.append(v + (nx - v) / np.linalg.norm(nx - v) * cut)
    hole = None
    if i % 2 == 0:
        cen3 = np.array(cen)
        hole = [cen3 + (np.array(v) - cen3) * RECESS_F for v in V]
    prism(m, poly, H, hole=hole, depth=RECESS_D)
    walls = [Wall(poly[2 * j + 1], poly[(2 * j + 2) % 6]) for j in range(3)]
    named = {}
    for w in walls:
        if w.n[:2] @ r_hat > 0.9:
            named["out"] = w
        elif w.n[:2] @ t_hat > 0:
            named["next"] = w
        else:
            named["prev"] = w
    return cen, r_hat, V, named


def details(m, i, W, rng):
    o, nx, pv = W["out"], W["next"], W["prev"]
    if i == 0:       # operations / bridge block
        windows(m, o, 0.08, 0.92, 0.66, 0.88, 14, 2, rng, 0.30)
        stripe(m, o, 0.52, 0.56)
        vents(m, o, 0.08, 0.34, 0.08, 0.38, 8)
        door(m, o, 0.58, 0.90, 0.06, 0.38, hazard=False)
        windows(m, nx, 0.15, 0.85, 0.80, 0.92, 8, 1, rng, 0.4)
        vents(m, nx, 0.08, 0.32, 0.10, 0.28, 6)
        seams(m, pv, 3)
        windows(m, pv, 0.15, 0.85, 0.58, 0.68, 8, 1, rng, 0.25)
    elif i == 1:     # hangar block
        door(m, o, 0.08, 0.92, 0.05, 0.50)
        windows(m, o, 0.08, 0.92, 0.62, 0.74, 10, 1, rng, 0.25)
        stripe(m, o, 0.80, 0.84)
        vents(m, nx, 0.10, 0.90, 0.62, 0.90, 14)
        windows(m, pv, 0.15, 0.85, 0.74, 0.86, 6, 1, rng, 0.3)
        seams(m, nx, 2)
    elif i == 2:     # habitat block
        windows(m, o, 0.06, 0.94, 0.14, 0.90, 12, 6, rng, 0.45)
        stripe(m, o, 0.02, 0.06)
        windows(m, nx, 0.12, 0.88, 0.58, 0.90, 6, 3, rng, 0.40)
        vents(m, pv, 0.10, 0.40, 0.70, 0.92, 7)
        windows(m, pv, 0.55, 0.90, 0.70, 0.92, 3, 2, rng, 0.4)
    elif i == 3:     # reactor / processing block
        vents(m, o, 0.08, 0.30, 0.55, 0.86, 10)
        vents(m, o, 0.38, 0.62, 0.55, 0.86, 10)
        vents(m, o, 0.70, 0.92, 0.55, 0.86, 10)
        seams(m, o, 6)
        port(m, o, 0.5, 0.25, 15)
        stripe(m, o, 0.52, 0.55, C["dark"])
        seams(m, nx, 3)
        windows(m, pv, 0.15, 0.85, 0.78, 0.90, 7, 1, rng, 0.3)
    elif i == 4:     # cargo / mining block
        door(m, o, 0.06, 0.45, 0.05, 0.40)
        door(m, o, 0.55, 0.94, 0.05, 0.40)
        windows(m, o, 0.06, 0.94, 0.55, 0.65, 12, 1, rng, 0.25)
        stripe(m, o, 0.72, 0.78)
        vents(m, nx, 0.10, 0.34, 0.70, 0.90, 6)
        vents(m, nx, 0.66, 0.90, 0.70, 0.90, 6)
        windows(m, pv, 0.15, 0.85, 0.15, 0.27, 7, 1, rng, 0.3)
    else:            # lab / comms block
        windows(m, o, 0.10, 0.90, 0.62, 0.84, 3, 1, rng, 0.8, gap=0.15)
        port(m, o, 0.5, 0.32, 13)
        stripe(m, o, 0.90, 0.94)
        windows(m, nx, 0.12, 0.88, 0.70, 0.92, 10, 2, rng, 0.35)
        vents(m, pv, 0.10, 0.34, 0.60, 0.90, 9)
        seams(m, pv, 3)
    # tunnel ports (the tunnel itself is built in main)
    port(m, nx, 0.5, 0.40, 11)
    port(m, pv, 0.5, 0.40, 11)


# ------------------------------------------------------------------ roof
def pipe(m, p0, p1, r, col=None):
    cyl_axis(m, p0, p1, r, r, col or C["slat"], segs=14, caps=(True, True))


def dish(m, base2, yaw_deg, z0):
    """Comm dish on a short mast, tilted up and out."""
    b = p3(base2, z0)
    top = b + np.array((0, 0, 9.0))
    pipe(m, b, top, 1.6, C["slat"])
    a = math.radians(yaw_deg)
    d = np.array((math.cos(a) * 0.55, math.sin(a) * 0.55, 0.83))
    d /= np.linalg.norm(d)
    cyl_axis(m, top, top + d * 5.0, 2.0, 11.0, C["bevel"], segs=28)          # the bowl (open)
    pipe(m, top + d * 0.5, top + d * 9.0, 0.6, C["slat"])                      # feed


def roof(m, i, cen, r_hat, V, walls):
    """Roof installations (no pads: the landing places are the triangular recesses)."""
    t_hat = np.array((-r_hat[1], r_hat[0]))
    c = np.array(cen)
    z0 = H
    ang_out = math.degrees(math.atan2(r_hat[1], r_hat[0]))
    if i % 2 == 0:
        # recess in the middle: small kit in the three corners + two pipe runs along the outer wall
        for v in V:
            d = (np.array(v) - c)
            dn = d / np.linalg.norm(d)
            q = c + d * 0.80
            ang = math.degrees(math.atan2(dn[1], dn[0]))
            if i == 0:
                block(m, q, 9, 9, ang, 5, z0, C["slat"])
            elif i == 2:
                pipe(m, p3(q, z0), p3(q, z0 + 9), 2.6, C["flange"])
                pipe(m, p3(q, z0 + 9), p3(q, z0 + 10.2), 3.2, C["accent"])
            else:
                block(m, q, 8, 12, ang + 90, 4, z0, C["flange"])
        o = walls["out"]
        for k in (-1, 1):
            a_ = o.P(o.L * (0.5 + k * 0.12), z0 + 2.2, -4.5)
            b_ = o.P(o.L * (0.5 + k * 0.40), z0 + 2.2, -4.5)
            pipe(m, a_, b_, 1.5, C["accent"] if k > 0 else C["slat"])
    elif i == 1:     # hangar roof: machinery hall, exhaust stacks, pipe runs
        block(m, c, 62, 34, ang_out + 90, 12, z0, C["slat"])
        block(m, c + t_hat * 8, 40, 20, ang_out + 90, 7, z0 + 12, C["flange"])
        for k in (-1, 0, 1):
            q = c - r_hat * 38 + t_hat * 26 * k
            pipe(m, p3(q, z0), p3(q, z0 + 20), 4.0, C["flange"])
            pipe(m, p3(q, z0 + 20), p3(q, z0 + 21.4), 4.6, C["vent"])
        pipe(m, p3(c + t_hat * 31 + r_hat * 4, z0 + 4), p3(c + t_hat * 31 + r_hat * 40, z0 + 4), 2.2, C["accent"])
        pipe(m, p3(c - t_hat * 31 + r_hat * 4, z0 + 4), p3(c - t_hat * 31 + r_hat * 40, z0 + 4), 2.2, C["slat"])
    elif i == 3:     # reactor roof: radiator fins, coolant tank, antenna dish
        for k in range(7):
            q = c + t_hat * (-30 + 10 * k) - r_hat * 8
            block(m, q, 2.0, 44, ang_out + 90, 15, z0, C["flange"], ch=0.5)
        block(m, c - r_hat * 8, 74, 4, ang_out + 90, 3, z0, C["slat"], ch=0.5)
        t0 = p3(c + r_hat * 36, z0)
        cyl_axis(m, t0, t0 + np.array((0, 0, 6.0)), 9, 9, C["flange"], segs=28, caps=(False, True))
        cyl_axis(m, t0 + np.array((0, 0, 6.0)), t0 + np.array((0, 0, 7.2)), 10, 10, C["accent"], segs=28, caps=(False, True))
        dish(m, c - r_hat * 44 + t_hat * 14, ang_out + 180, z0)
    else:            # cargo / lab roof: containers, sensor block, small dish
        cols = [C["wall"], C["accent"], C["flange"], C["wall"], C["slat"], C["accent"]]
        n = 0
        for row in range(2):
            for k in range(3):
                q = c + t_hat * (-26 + 26 * k) + r_hat * (10 - 15 * row)
                block(m, q, 22, 12, ang_out, 9, z0, cols[n % 6], ch=0.8)
                if (row + k) % 2 == 0:
                    block(m, q, 20, 10, ang_out, 8, z0 + 9, cols[(n + 2) % 6], ch=0.8)
                n += 1
        block(m, c - r_hat * 34, 30, 10, ang_out + 90, 6, z0, C["slat"])
        dish(m, c + r_hat * 38 + t_hat * 22, ang_out, z0)


def underside(m, i, cen, r_hat, V):
    """Horizontal installations hanging under the flat floor of module i."""
    t_hat = np.array((-r_hat[1], r_hat[0]))
    c = np.array(cen)
    ao = math.degrees(math.atan2(r_hat[1], r_hat[0]))

    def run(a2, b2, z, r, col=None):
        pipe(m, p3(a2, z), p3(b2, z), r, col)

    def hang(q, w, l, yaw, h, col):
        block(m, q, w, l, yaw, h, -h, col, ch=0.8)

    if i == 0:       # two long collectors, a cross manifold, a tank
        run(c + r_hat * 30 - t_hat * 46, c + r_hat * 30 + t_hat * 46, -3.2, 3.0, C["flange"])
        run(c + r_hat * 38 - t_hat * 42, c + r_hat * 38 + t_hat * 42, -3.0, 2.2, C["accent"])
        for k in (-1, 1):
            run(c + r_hat * -12 + t_hat * 20 * k, c + r_hat * 38 + t_hat * 20 * k, -3.0, 2.0, C["slat"])
        cyl_axis(m, p3(c - r_hat * 4 - t_hat * 20, -8), p3(c - r_hat * 4 + t_hat * 20, -8), 7, 7, C["wall"], segs=24, caps=(True, True))
        hang(c - r_hat * 26 + t_hat * 34, 16, 12, ao, 6, C["slat"])
        hang(c - r_hat * 26 - t_hat * 34, 16, 12, ao, 6, C["flange"])
    elif i == 1:     # three horizontal tanks and a feed line
        for k in (-1, 0, 1):
            q = c + t_hat * 28 * k
            cyl_axis(m, p3(q - r_hat * 26, -7.5), p3(q + r_hat * 14, -7.5), 6.5, 6.5, C["wall"], segs=24, caps=(True, True))
            cyl_axis(m, p3(q - r_hat * 14, -7.5), p3(q - r_hat * 12, -7.5), 7.0, 7.0, C["accent"], segs=24)
        run(c + r_hat * 26 - t_hat * 44, c + r_hat * 26 + t_hat * 44, -3.0, 2.6, C["flange"])
        for k in (-1, 0, 1):
            q = c + t_hat * 28 * k
            run(q + r_hat * 14, q + r_hat * 26, -3.0, 1.6, C["slat"])
        hang(c - r_hat * 40, 34, 12, ao + 90, 7, C["slat"])
    elif i == 2:     # flat radiator plate, edge pipes
        hang(c, 64, 40, ao + 90, 3.2, C["flange"])
        for k in range(6):
            run(c + r_hat * (-16 + 6.5 * k) - t_hat * 34, c + r_hat * (-16 + 6.5 * k) + t_hat * 34, -5.0, 1.0, C["slat"])
        run(c + r_hat * 36 - t_hat * 48, c + r_hat * 36 + t_hat * 48, -3.2, 3.0, C["accent"])
        run(c - r_hat * 40 - t_hat * 24, c - r_hat * 40 + t_hat * 24, -3.2, 2.4, C["slat"])
        hang(c + r_hat * 22 + t_hat * 40, 12, 14, ao, 8, C["wall"])
        hang(c + r_hat * 22 - t_hat * 40, 12, 14, ao, 8, C["wall"])
    elif i == 3:     # reactor drum underneath with radial lines
        cyl_axis(m, p3(c, 0), p3(c, -10), 16, 16, C["wall"], segs=36, caps=(False, True))
        cyl_axis(m, p3(c, -6), p3(c, -7.4), 17, 17, C["accent"], segs=36)
        for v in V:
            d = np.array(v) - c
            dn = d / np.linalg.norm(d)
            run(c + dn * 14, c + dn * 58, -3.2, 2.4, C["flange"])
            cyl_axis(m, p3(c + dn * 58, -3.2), p3(c + dn * 61, -3.2), 3.6, 3.6, C["slat"], segs=14, caps=(False, True))
        run(c + r_hat * 30 - t_hat * 46, c + r_hat * 30 + t_hat * 46, -3.0, 2.0, C["slat"])
    elif i == 4:     # cargo gantry: two beams and hung containers
        hang(c + r_hat * 22, 84, 4, ao + 90, 5, C["slat"])
        hang(c - r_hat * 8, 70, 4, ao + 90, 5, C["slat"])
        cols = [C["wall"], C["accent"], C["flange"], C["wall"]]
        for k in range(4):
            hang(c + r_hat * 7 + t_hat * (-27 + 18 * k), 15, 22, ao, 8, cols[k])
        run(c - r_hat * 30 - t_hat * 36, c - r_hat * 30 + t_hat * 36, -3.0, 2.2, C["flange"])
    else:            # pipe manifold
        for k in range(4):
            run(c + r_hat * -22 + t_hat * (-24 + 16 * k), c + r_hat * 34 + t_hat * (-24 + 16 * k), -3.2, 2.2 + (k % 2) * 0.8,
                C["accent"] if k == 1 else C["flange"])
        hang(c + r_hat * 36, 70, 7, ao + 90, 6, C["slat"])
        hang(c - r_hat * 26, 40, 8, ao + 90, 5, C["wall"])
        cyl_axis(m, p3(c + r_hat * 10 + t_hat * 44, -5), p3(c + r_hat * 10 - t_hat * 44, -5), 4.5, 4.5, C["vent"], segs=20, caps=(True, True))


def place_ship(m, pos_xy, floor_z, yaw_deg):
    sm = S.build()
    zmin = min(v[2] for verts, _, _, _ in sm.tris for v in verts)
    a = math.radians(yaw_deg)
    R = np.array(((math.cos(a), -math.sin(a), 0), (math.sin(a), math.cos(a), 0), (0, 0, 1.0)))
    off = np.array((pos_xy[0], pos_xy[1], floor_z - zmin))
    gofs = m.group
    for verts, ns, col, grp in sm.tris:
        nv = None if ns is None else tuple(R @ np.asarray(x) for x in ns)
        m.tris.append(((R @ verts.T).T + off, nv, col, grp + gofs))
    m.group += sm.group + 1


# ------------------------------------------------------------------ whole base
def build_base(with_ships=True):
    m = Mesh()
    rng = np.random.default_rng(65)
    mods = []
    for i in range(6):
        cen, r_hat, V, W = module(m, i, rng)
        details(m, i, W, rng)
        roof(m, i, cen, r_hat, V, W)
        underside(m, i, cen, r_hat, V)
        mods.append((cen, W, r_hat, V))
        if i % 2 == 0:                      # markings on the recess floor
            cen3 = np.array(cen)
            tri = [cen3 + (np.array(v) - cen3) * RECESS_F for v in V]
            fz = H - RECESS_D + 0.08
            a1, a2 = offset_convex(tri, 3.0), offset_convex(tri, 6.0)
            g = m.newgroup()
            for j in range(3):
                m.quad(p3(a1[j], fz), p3(a1[(j + 1) % 3], fz), p3(a2[(j + 1) % 3], fz), p3(a2[j], fz), C["padring"], g)
            for q in offset_convex(tri, 10.0):
                g = m.newgroup()
                x, y = q
                m.quad(np.array((x - 1.6, y - 1.6, fz)), np.array((x + 1.6, y - 1.6, fz)),
                       np.array((x + 1.6, y + 1.6, fz)), np.array((x - 1.6, y + 1.6, fz)), C["lit"], g)
    # tunnels between neighbours, across the 16 px gap
    for i in range(6):
        wa = mods[i][1]["next"]
        wb = mods[(i + 1) % 6][1]["prev"]
        z = 0.40 * H
        pa = wa.P(wa.L / 2, z, -3.0)
        pb = wb.P(wb.L / 2, z, -3.0)
        cyl_axis(m, pa, pb, 8.0, 8.0, C["tunnel"], segs=28)
        for p, w in ((pa, wa), (pb, wb)):
            q = p + w.n * 5.0
            cyl_axis(m, p + w.n * 3.0, q, 10.5, 10.5, C["flange"], segs=28, caps=(False, True))
        mid = (pa + pb) / 2
        ax = (pb - pa) / np.linalg.norm(pb - pa)
        annulus(m, mid, ax, 8.0, 9.5, C["accent"], 28)
        # report the gap actually modelled
        if i == 0:
            print("tunnel length / gap: %.1f units, %.1f px" % (np.linalg.norm(pb - pa) - 6.0,
                                                               (np.linalg.norm(pb - pa) - 6.0) / K))
    if with_ships:
        cen0, _, r0, _ = mods[0]
        yaw = math.degrees(math.atan2(-r0[1], -r0[0])) - 90.0   # nose pointing at the middle of the base
        place_ship(m, cen0, H - RECESS_D, yaw)
    return m, mods


VIEWS = [
    ("top", "TOP", 0, 90, 2.0, (0, 0, 0)),
    ("bottom", "BOTTOM", 0, -90, 2.0, (0, 0, 0)),
    ("side_a", "SIDE A", 0, 0, 1.8, (0, 0, 0.5 * H)),
    ("side_b", "SIDE B (30 deg)", 30, 0, 1.8, (0, 0, 0.5 * H)),
    ("three_quarter_1", "3/4 HIGH", 20, 38, 1.6, (0, 0, 0.35 * H)),
    ("three_quarter_2", "3/4 REAR HIGH", 200, 32, 1.6, (0, 0, 0.35 * H)),
    ("three_quarter_low", "3/4 LOW", -35, -38, 1.6, (0, 0, 0.0)),
    ("pad_closeup", "ROOF / RECESS + SHIP", 25, 40, 4.6, None),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    m, mods = build_base()
    export_obj(m, os.path.join(OUT, "srv_base.obj"))
    ims = []
    for key, title, az, el, scale, ctr in VIEWS:
        if ctr is None:
            c0 = mods[0][0]
            ctr = (c0[0], c0[1], H - 6)
        im = render(m, az, el, size=1000, ss=2, scale=scale, center=ctr, edge_dz=3.0)
        im.save(os.path.join(OUT, "srv_base_%s.png" % key))
        ims.append(label(im.copy(), title))
        print("rendered", key, flush=True)
    th = 560
    sheet = Image.new("RGB", (th * 4, th * 2), BG)
    for k, im in enumerate(ims):
        sheet.paste(im.resize((th, th), Image.LANCZOS), ((k % 4) * th, (k // 4) * th))
    sheet.save(os.path.join(OUT, "srv_base_sheet.png"))
    print("done")


if __name__ == "__main__":
    main()
