#!/usr/bin/env python3
"""SRV-T01 reference model: a small hand-built 3D mesh + software renderer.

Purpose: consistent turnaround / pseudo-3D views of the player ship to feed an
image generator (ChatGPT etc.) as a character-sheet style reference.  Not used
by the game build.

Proportions come from the game's own top-down vector hull
(ship_png/ship_rest_150_x8.png: 55 x 61 px -> nose-to-stern 48, span 43) and
the hull seen on assets/png/bitmaps/efs_title_scr.png (arrowhead hull, two
cylindrical engine pods at the stern, tall swept dorsal fin, SRV-T01 on the hull).

Axes: +Y nose, +X starboard (right when seen from behind), +Z up.  Units ~ metres.
Run:  python tools/ship_ref/build_ship_ref.py   -> ship_ref/ (PNGs + ship.obj)
"""
import math
import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ship_ref")
OUT = os.path.normpath(OUT)

# ---------------------------------------------------------------- palette
COL = {
    "hull": (222, 226, 230),
    "hull_dark": (150, 156, 164),
    "pod": (200, 205, 211),
    "fin": (236, 238, 240),
    "accent": (232, 112, 36),      # survey-fleet orange
    "nozzle": (46, 50, 58),
    "glow": (120, 220, 255),
    "dome": (70, 78, 90),
    "glass": (8, 10, 14),
}
BG = (44, 48, 56)


class Mesh:
    def __init__(self):
        self.tris = []   # (3 verts, 3 vertex normals or None, colour, group)
        self.group = 0

    def newgroup(self):
        self.group += 1
        return self.group

    def tri(self, a, b, c, col, grp, n=None):
        self.tris.append((np.array([a, b, c], float), n, col, grp))

    def quad(self, a, b, c, d, col, grp):
        self.tri(a, b, c, col, grp)
        self.tri(a, c, d, col, grp)

    def poly_fan(self, pts, col, grp):
        for i in range(1, len(pts) - 1):
            self.tri(pts[0], pts[i], pts[i + 1], col, grp)


def cyl_y(m, cx, cz, r0, r1, y0, y1, col, segs=40, caps=(False, False), smooth=True):
    """Cone frustum along Y from y0 (radius r0) to y1 (radius r1)."""
    grp = m.newgroup()
    ang = [2 * math.pi * i / segs for i in range(segs + 1)]
    def pt(r, y, a):
        return (cx + r * math.cos(a), y, cz + r * math.sin(a))
    def nrm(a):
        return np.array([math.cos(a), 0.0, math.sin(a)])
    for i in range(segs):
        a, b = ang[i], ang[i + 1]
        p00, p01 = pt(r0, y0, a), pt(r0, y0, b)
        p10, p11 = pt(r1, y1, a), pt(r1, y1, b)
        ns = (nrm(a), nrm(b), nrm(b)) if smooth else None
        m.tri(p00, p01, p11, col, grp, ns)
        ns = (nrm(a), nrm(b), nrm(a)) if smooth else None
        m.tri(p00, p11, p10, col, grp, (nrm(a), nrm(b), nrm(a)) if smooth else None)
    for end, (r, y) in enumerate(((r0, y0), (r1, y1))):
        if caps[end] and r > 0:
            g2 = m.newgroup()
            c = (cx, y, cz)
            for i in range(segs):
                m.tri(c, pt(r, y, ang[i]), pt(r, y, ang[i + 1]), col, g2)


def ring_y(m, cx, cz, r_in, r_out, y, col, segs=40):
    g = m.newgroup()
    for i in range(segs):
        a = 2 * math.pi * i / segs
        b = 2 * math.pi * (i + 1) / segs
        p = lambda r, t: (cx + r * math.cos(t), y, cz + r * math.sin(t))
        m.quad(p(r_in, a), p(r_out, a), p(r_out, b), p(r_in, b), col, g)


def build():
    m = Mesh()

    # ---- main hull: pyramid, flat underside, triangular cross-section ------
    ZB, H = -1.0, 12.4          # base plane / ridge height
    HW = 11.2                   # base half-width (touches the pods)
    Y_MID, Y_END = -10.0, -20.0
    N = np.array((0, 24, ZB))
    ml, mr = np.array((-HW, Y_MID, ZB)), np.array((HW, Y_MID, ZB))
    am = np.array((0, Y_MID, H))
    bl, br = np.array((-HW, Y_END, ZB)), np.array((HW, Y_END, ZB))
    ae = np.array((0, Y_END, H))
    hc = np.array((0, 0, 4.0))  # interior point, for outward normals

    def outward(p, q, r):
        n = np.cross(q - p, r - p)
        n = n / np.linalg.norm(n)
        if n @ ((p + q + r) / 3 - hc) < 0:
            n = -n
        return n

    # thick flat floor under the pyramid (same plan outline, vertical sides)
    ZF = ZB - 3.6
    fN = np.array((0, 24, ZF))
    fml, fmr = np.array((-HW, Y_MID, ZF)), np.array((HW, Y_MID, ZF))
    fbl, fbr = np.array((-HW, Y_END, ZF)), np.array((HW, Y_END, ZF))
    gb = m.newgroup()
    m.poly_fan([fN, fmr, fbr, fbl, fml], COL["hull_dark"], gb)
    ring_pts = [(N, fN), (mr, fmr), (br, fbr), (bl, fbl), (ml, fml)]
    for i in range(5):
        (t0, b0), (t1, b1) = ring_pts[i], ring_pts[(i + 1) % 5]
        gw = m.newgroup()
        col = COL["hull_dark"] if i == 2 else COL["hull"]
        m.quad(t0, t1, b1, b0, col, gw)
    for s in (1, -1):
        mS = np.array((s * HW, Y_MID, ZB)); bS = np.array((s * HW, Y_END, ZB))
        g1 = m.newgroup()
        m.tri(N, mS, am, COL["hull"], g1)
        g2 = m.newgroup()
        m.quad(mS, bS, ae, am, COL["hull"], g2)
        # orange survey band across the aft slope
        off = 0.05 * outward(mS, bS, ae)
        def sp(y, t):
            return np.array((s * HW * (1 - t), y, ZB + (H - ZB) * t)) + off
        ga = m.newgroup()
        m.quad(sp(-14.0, 0.0), sp(-16.5, 0.0), sp(-16.5, 0.97), sp(-14.0, 0.97), COL["accent"], ga)
        # canopy glass: seen from above a triangle with the hull's own proportions
        def fp(x, y, lift=0.0):
            wN = (y + 10.0) / 34.0
            wM = abs(x) / HW
            wA = 1.0 - wN - wM
            pt = ZB * (wN + wM) + H * wA
            return np.array((x, y, pt)) + outward(N, mS, am) * lift
        GL_SHIFT = 5.0                                   # glass slid aft along the ridge
        Y_AP = 20.5 - GL_SHIFT
        Y_GL, W_GL = Y_AP - 22.5 * 0.75, 7.2 * 0.75   # glass triangle, 75% size
        gg = m.newgroup()
        m.tri(fp(0, Y_AP, 0.06), fp(0, Y_GL, 0.06), fp(s * W_GL, Y_GL, 0.06), COL["glass"], gg)
        # canopy seam (the lid lifts to let the pilot in): thin dark strip across the slope
        gz = m.newgroup()
        Yc = Y_GL - 2.4   # seam stays just behind the glass
        wc = HW * (24 - Yc) / 34.0   # hull half-width at that y
        m.quad(fp(0, Yc + 0.2, 0.05), fp(s * wc, Yc + 0.2, 0.05), fp(s * wc, Yc - 0.2, 0.05),
               fp(0, Yc - 0.2, 0.05), COL["nozzle"], gz)
    # stern face
    gs = m.newgroup()
    m.tri(bl, br, ae, COL["hull_dark"], gs)
    # centre engine: housing under/behind the hull, ring, bell, glow
    cx, cz, R = 0.0, 1.1, 4.4
    cyl_y(m, cx, cz, R, R, -24, -14, COL["pod"], segs=44, caps=(False, True))
    cyl_y(m, cx, cz, R + 0.06, R + 0.06, -17.5, -16.5, COL["accent"], segs=44)
    ring_y(m, cx, cz, 3.5, R, -24.0, COL["hull_dark"], segs=44)
    cyl_y(m, cx, cz, 3.5, 2.7, -24.0, -20.5, COL["nozzle"], segs=44)
    g = m.newgroup()
    for i in range(44):
        t0 = 2 * math.pi * i / 44
        t1 = 2 * math.pi * (i + 1) / 44
        m.tri((cx, -20.5, cz), (cx + 2.7 * math.cos(t0), -20.5, cz + 2.7 * math.sin(t0)),
              (cx + 2.7 * math.cos(t1), -20.5, cz + 2.7 * math.sin(t1)), COL["glow"], g)

    # ---- engine pods: plain cylinders, concave conical intake in front ---
    PX = HW + 2.5 + 5.0            # pod axis x: 2.5 units of wing between hull and pod
    PZ = -2.8                      # pod axis = mid-height of the base slab (ZB-1.8)
    for sgn in (-1, 1):
        px = sgn * PX
        R = 5.0
        # outrigger wing: thin swept slab from the base-slab wall out to the pod axis
        gw = m.newgroup()
        zt, zb_ = PZ + 1.2, PZ - 1.2
        xi, xo = sgn * (HW - 0.3), px - sgn * (R - 0.3)
        root = (-10.0, -20.0)      # leading, trailing y at the hull
        tip = (-8.0, -21.5)        # leading, trailing y at the pod
        P = {}
        for name, x, (yl, yt) in (("i", xi, root), ("o", xo, tip)):
            for k, y in (("l", yl), ("t", yt)):
                for z_, zn in ((zt, "u"), (zb_, "d")):
                    P[name + k + zn] = (x, y, z_)
        m.quad(P["ilu"], P["itu"], P["otu"], P["olu"], COL["hull"], gw)
        m.quad(P["ild"], P["old"], P["otd"], P["itd"], COL["hull_dark"], gw)
        m.quad(P["ilu"], P["olu"], P["old"], P["ild"], COL["hull"], gw)
        m.quad(P["itu"], P["itd"], P["otd"], P["otu"], COL["hull"], gw)
        R = 5.0
        cyl_y(m, px, PZ, R, R, -24, -3, COL["pod"], segs=44)
        # front: flat annulus + cone that narrows INTO the pod (towards the stern)
        ring_y(m, px, PZ, 3.4, R, -3.0, COL["hull_dark"], segs=44)
        cyl_y(m, px, PZ, 3.4, 0.0, -3.0, -8.5, COL["nozzle"], segs=44)
        # orange bands
        cyl_y(m, px, PZ, R + 0.06, R + 0.06, -19.5, -17.5, COL["accent"], segs=44)
        cyl_y(m, px, PZ, R + 0.06, R + 0.06, -14.5, -13.5, COL["accent"], segs=44)
        # rear: ring, nozzle bell, glow
        ring_y(m, px, PZ, 3.9, R, -24.0, COL["hull_dark"], segs=44)
        cyl_y(m, px, PZ, 3.9, 3.0, -24.0, -20.5, COL["nozzle"], segs=44)
        g = m.newgroup()
        c0 = (px, -20.5, PZ)
        for i in range(44):
            t0 = 2 * math.pi * i / 44
            t1 = 2 * math.pi * (i + 1) / 44
            m.tri(c0, (px + 3.0 * math.cos(t0), -20.5, PZ + 3.0 * math.sin(t0)),
                  (px + 3.0 * math.cos(t1), -20.5, PZ + 3.0 * math.sin(t1)), COL["glow"], g)
    return m


# ---------------------------------------------------------------- render
def camera(az, el):
    az, el = math.radians(az), math.radians(el)
    c = np.array([math.sin(az) * math.cos(el), math.cos(az) * math.cos(el), math.sin(el)])
    up = np.array([0.0, 0.0, 1.0])
    if abs(el) > math.radians(89.0):
        up = np.array([0.0, 1.0, 0.0])
    f = -c
    r = np.cross(f, up)
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    return c, r, u


EMISSIVE = {COL["glow"], (255, 206, 110)}   # drawn unshaded


def render(mesh, az, el, size=800, ss=2, scale=10.2, bg=BG, center=(0, -1.0, 3.0), edge_dz=0.8):
    W = size * ss
    S = scale * ss
    c, r, u = camera(az, el)
    L = (-0.45 * r + 0.55 * u + 0.70 * c)           # key light, camera-relative
    L /= np.linalg.norm(L)
    Lf = (0.5 * r - 0.1 * u + 0.8 * c)
    Lf /= np.linalg.norm(Lf)
    ctr = np.array(center, float)
    rgb = np.zeros((W, W, 3), float)
    rgb[:] = bg
    zbuf = np.full((W, W), -1e9)
    gid = np.full((W, W), -1, int)
    emis = np.zeros((W, W), bool)
    ys, xs = np.mgrid[0:W, 0:W]
    for verts, ns, col, grp in mesh.tris:
        P = verts - ctr
        sx = P @ r * S + W / 2
        sy = W / 2 - P @ u * S - 0.0
        dz = P @ c
        x0, x1 = int(max(0, math.floor(sx.min()))), int(min(W - 1, math.ceil(sx.max())))
        y0, y1 = int(max(0, math.floor(sy.min()))), int(min(W - 1, math.ceil(sy.max())))
        if x1 < x0 or y1 < y0:
            continue
        den = (sy[1] - sy[2]) * (sx[0] - sx[2]) + (sx[2] - sx[1]) * (sy[0] - sy[2])
        if abs(den) < 1e-9:
            continue
        gx = xs[y0:y1 + 1, x0:x1 + 1] + 0.5
        gy = ys[y0:y1 + 1, x0:x1 + 1] + 0.5
        w0 = ((sy[1] - sy[2]) * (gx - sx[2]) + (sx[2] - sx[1]) * (gy - sy[2])) / den
        w1 = ((sy[2] - sy[0]) * (gx - sx[2]) + (sx[0] - sx[2]) * (gy - sy[2])) / den
        w2 = 1 - w0 - w1
        inside = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
        if not inside.any():
            continue
        z = w0 * dz[0] + w1 * dz[1] + w2 * dz[2]
        sub = zbuf[y0:y1 + 1, x0:x1 + 1]
        upd = inside & (z > sub + 1e-6)
        if not upd.any():
            continue
        if ns is None:
            n = np.cross(verts[1] - verts[0], verts[2] - verts[0])
            nl = np.linalg.norm(n)
            if nl < 1e-12:
                continue
            nn = np.broadcast_to(n / nl, (3,))
            ndl = np.abs(nn @ L)
            ndf = np.abs(nn @ Lf)
            facing = abs(nn @ c)
            lam = np.full(upd.shape, 0.0)
            lam[:] = 0.30 + 0.62 * ndl + 0.25 * ndf
            sh = lam
        else:
            nv = np.array(ns)
            nx = w0[..., None] * nv[0] + w1[..., None] * nv[1] + w2[..., None] * nv[2]
            nx /= np.linalg.norm(nx, axis=-1, keepdims=True) + 1e-12
            # face the camera
            flip = np.sign(nx @ c)
            flip[flip == 0] = 1
            nx = nx * flip[..., None]
            sh = 0.30 + 0.62 * np.clip(nx @ L, 0, 1) + 0.25 * np.clip(nx @ Lf, 0, 1)
        sh = np.clip(sh, 0, 1.15)
        colr = np.array(col, float)
        if col in EMISSIVE:
            shaded = colr * 1.0
            pix = np.broadcast_to(shaded, upd.shape + (3,))
        else:
            pix = colr * sh[..., None]
        rr = rgb[y0:y1 + 1, x0:x1 + 1]
        rr[upd] = pix[upd] if pix.ndim == 3 else pix
        sub[upd] = z[upd]
        gid[y0:y1 + 1, x0:x1 + 1][upd] = grp
        emis[y0:y1 + 1, x0:x1 + 1][upd] = col in EMISSIVE
    # crease / silhouette lines where group id changes
    edge = np.zeros((W, W), bool)
    edge[:, 1:] |= gid[:, 1:] != gid[:, :-1]
    edge[1:, :] |= gid[1:, :] != gid[:-1, :]
    dzx = np.abs(np.diff(zbuf, axis=1, prepend=zbuf[:, :1]))
    dzy = np.abs(np.diff(zbuf, axis=0, prepend=zbuf[:1, :]))
    edge |= (dzx > edge_dz) & (zbuf > -1e8)
    edge |= (dzy > edge_dz) & (zbuf > -1e8)
    from PIL import ImageFilter
    edge &= ~emis
    rgb[edge] = rgb[edge] * 0.35
    im = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))
    return im.resize((size, size), Image.LANCZOS)


def export_obj(mesh, path):
    verts, faces, mats = [], [], []
    with open(path, "w") as fh:
        fh.write("# SRV-T01 reference mesh (+Y nose, +X right, +Z up)\n")
        for verts_t, ns, col, grp in mesh.tris:
            idx = []
            for v in verts_t:
                verts.append(v)
                fh.write("v %.4f %.4f %.4f\n" % tuple(v))
                idx.append(len(verts))
            faces.append(idx)
        for f in faces:
            fh.write("f %d %d %d\n" % tuple(f))


def label(im, text):
    d = ImageDraw.Draw(im)
    try:
        font = ImageFont.truetype("arial.ttf", 26)
    except Exception:
        font = ImageFont.load_default()
    d.text((18, 14), text, fill=(235, 238, 242), font=font)
    return im


VIEWS = [
    ("front", "FRONT (nose)", 0, 0),
    ("rear", "REAR (engines)", 180, 0),
    ("side_right", "SIDE (starboard)", 90, 0),
    ("top", "TOP", 0, 90),
    ("bottom", "BOTTOM", 0, -90),
    ("three_quarter_front", "3/4 FRONT", 35, 22),
    ("three_quarter_rear", "3/4 REAR", 215, 20),
    ("three_quarter_low", "3/4 LOW", -40, -22),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    mesh = build()
    export_obj(mesh, os.path.join(OUT, "srv_t01.obj"))
    ims = []
    for key, title, az, el in VIEWS:
        scale = 10.2 if (el in (90, -90) or az in (0, 180, 90) and el == 0) else 8.8
        if key in ("front", "rear"):
            scale = 12.5
        im = render(mesh, az, el, scale=scale)
        im.save(os.path.join(OUT, "srv_t01_%s.png" % key))
        ims.append(label(im.copy(), title))
        print("rendered", key, flush=True)
    # contact sheet 4 x 2
    th = 560
    sheet = Image.new("RGB", (th * 4, th * 2), BG)
    for i, im in enumerate(ims):
        sheet.paste(im.resize((th, th), Image.LANCZOS), ((i % 4) * th, (i // 4) * th))
    sheet.save(os.path.join(OUT, "srv_t01_sheet.png"))
    print("done ->", OUT)


if __name__ == "__main__":
    main()
