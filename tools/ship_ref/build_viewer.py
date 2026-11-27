#!/usr/bin/env python3
"""Builds ship_ref/viewer.html: ONE self-contained page (no server, no internet) that shows every reference
model (ship, base, spider, pulsar x2, UFO, mine, lifepod, transporter, alien tower) in an interactive WebGL view
with the same lighting and contour lines as the contact sheets, and a button that saves a PNG of the exact
frame you set up.  Models are taken straight from the build_*_ref.py generators - re-run this after changing one.

Run:  python tools/ship_ref/build_viewer.py   ->  ship_ref/viewer.html   (just open it in a browser)
"""
import base64
import json
import os
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_ship_ref as S                                         # noqa: E402
import build_base_ref as B                                         # noqa: E402
import build_spider_ref as SP                                      # noqa: E402
import build_pulsar_ref as PU                                      # noqa: E402
import build_ufo_ref as UF                                         # noqa: E402
import build_mine_ref as MI                                        # noqa: E402
import build_lifepod_ref as LP                                     # noqa: E402
import build_transporter_ref as TR                                 # noqa: E402
import build_alien_tower_ref as AT                                 # noqa: E402


def encode(mesh):
    """tris -> bytes: positions f32 (n*9), normals f32 (n*9), colour+flags u8 (n*4), group id u32 (n)."""
    emis = S.EMISSIVE
    tris = mesh.tris
    n = len(tris)
    pos = np.zeros((n, 9), np.float32)
    nrm = np.zeros((n, 9), np.float32)
    col = np.zeros((n, 4), np.uint8)
    gid = np.zeros(n, np.uint32)
    for i, (verts, ns, c, g) in enumerate(tris):
        pos[i] = np.asarray(verts, float).reshape(-1)
        fl = 0
        if tuple(c) in emis:
            fl |= 1
        if ns is not None:
            fl |= 2
            nrm[i] = np.asarray(ns, float).reshape(-1)
        col[i] = (c[0], c[1], c[2], fl)
        gid[i] = g
    blob = pos.tobytes() + nrm.tobytes() + col.tobytes() + gid.tobytes()
    return n, base64.b64encode(blob).decode("ascii")


def ship_views():
    out = []
    for key, title, az, el in S.VIEWS:
        scale = 10.2 if (el in (90, -90) or az in (0, 180, 90) and el == 0) else 8.8
        if key in ("front", "rear"):
            scale = 12.5
        out.append([key, title, az, el, scale, [0, -1.0, 3.0]])
    return out


def fix_views(views, default_ctr=(0, 0, 0)):
    return [[k, t, az, el, sc, list(ctr if ctr is not None else default_ctr)] for k, t, az, el, sc, ctr in views]


def main():
    models = []

    def add(mid, name, mesh, views, edge):
        n, data = encode(mesh)
        models.append({"id": mid, "name": name, "n": n, "edge": edge, "views": views, "data": data})
        print("%-14s %6d triangles" % (mid, n))

    add("srv_t01", "Statek SRV-T01", S.build(), ship_views(), 0.8)

    mbase, mods = B.build_base()
    c0 = mods[0][0]
    bviews = []
    for k, t, az, el, sc, ctr in B.VIEWS:
        if ctr is None:
            ctr = (c0[0], c0[1], B.H - 6)
        bviews.append([k, t, az, el, sc, list(ctr)])
    add("baza", "Baza ludzi (ze statkiem w doku)", mbase, bviews, 3.0)

    add("pajak", "Pająk", SP.build(), fix_views(SP.VIEWS), 1.6)
    add("pulsar_idle", "Pulsar (bez strzału)", PU.build(False), fix_views(PU.VIEWS), 1.2)
    add("pulsar_fire", "Pulsar (strzał)", PU.build(True), fix_views(PU.VIEWS), 1.2)
    add("ufo", "UFO", UF.build(), fix_views(UF.VIEWS), 0.6)
    add("mina", "Mina EMP", MI.build(), fix_views(MI.VIEWS), 0.5)
    add("lifepod", "Kapsuła ratunkowa (lifepod)", LP.build(), fix_views(LP.VIEWS), 0.7)
    add("transporter", "Transportowiec", TR.build(), fix_views(TR.VIEWS), 0.7)
    add("wieza", "Wieża obcych", AT.build(), fix_views(AT.VIEWS), 0.7)

    tpl = open(os.path.join(HERE, "viewer_template.html"), encoding="utf-8").read()
    html = tpl.replace("/*__MODELS__*/null", json.dumps(models, separators=(",", ":")))
    out = os.path.join(S.OUT, "viewer.html")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(html)
    print("wrote %s (%.1f MB)" % (out, os.path.getsize(out) / 1e6))


if __name__ == "__main__":
    main()
