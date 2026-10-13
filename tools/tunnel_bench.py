#!/usr/bin/env python3
"""The tunnel's own bench: seconds, not the eleven minutes of preview.py.

It borrows preview.py's machinery (the py65 CPU1 running cpu_os.bin, the real GPU OS
drawing into VRAM) by executing the part of that file BEFORE its flight run, and
then drives the TUNNEL IMAGE (make tunnel.bin, TUNTEST = 1), which powers on
straight into the tunnel - no gate to fly into, no sector, no title.

    python tools/tunnel_bench.py            (or: make tunnel-test)

What it checks: the cockpit's 20 bands, the stars (one DOT_PIXELS a frame, inside the
window, streaming out, everywhere at full lean), the controls (UP/DOWN: a critically
damped spring along the screen's up-down; LEFT/RIGHT: the world rolled round the tube's
axis, eased), and the rocks (growth with the perspective, one hit,
dodging, the occlusion of stars, the occlusion of rocks by rocks, the HUD frame).
"""

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
subprocess.run(["make", "tunnel.bin"], check=True, cwd=ROOT)

src = (ROOT / "tools" / "preview.py").read_text(encoding="utf8")
src = src.replace('subprocess.run(["make"], check=True, cwd=ROOT)', "pass")
src = src.replace('"cart.bin"', '"tunnel.bin"').replace('"cart.lbl"', '"tunnel.lbl"')
cut = src.index("\nboot_cart()\n")                      # the first call, after its def
gpu_a = src.index("gpu_mem = ObservableMemory()")
gpu_b = src.index("for f, stream in enumerate(frames):")
g = {"__file__": str(ROOT / "tools" / "preview.py"), "__name__": "preview_prefix"}
exec(compile(src[:cut], "preview.py[prefix]", "exec"), g)
exec(compile(src[gpu_a:gpu_b], "preview.py[gpu]", "exec"), g)
globals().update(g)

import re                                                  # noqa: E402

LBL = {m.group(2): int(m.group(1), 16) for m in
       re.finditer(r"^al ([0-9A-Fa-f]+) \.(\w+)\s*$", (ROOT / "tunnel.lbl").read_text(), re.M)}
JOY1, JOY1_PREV, JOY1_PRESS = 0x0A, 0x0B, 0x0C
JOY_UP, JOY_DOWN, JOY_LEFT, JOY_RIGHT, JOY_FIRE = 0x01, 0x02, 0x04, 0x08, 0x10
failed = []


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    if not ok:
        failed.append(name)
        if detail:
            print(f"        {detail}")


def frame(fire=False, joy=0):
    port = cpu_mem[SCR["JOYPORT"]]
    cpu_mem[JOY1_PREV] = cpu_mem[JOY1] = cpu_mem[JOY1_PRESS] = 0
    cpu_mem[JOY1_PREV + 3] = cpu_mem[JOY1 + 3] = cpu_mem[JOY1_PRESS + 3] = 0
    if fire:
        cpu_mem[JOY1 + port] = cpu_mem[JOY1_PRESS + port] = JOY_FIRE
    cpu_mem[JOY1 + port] |= joy
    call(cpu, API_GPU_BEGIN)
    call(cpu, CART_FRAME)
    call(cpu, API_GPU_END)
    end = cpu_mem[0x04] | (cpu_mem[0x05] << 8)
    return decode(bytes(cpu_mem[PPRAM + i] for i in range(end - PPRAM + 1)))


def raw_frame():
    call(cpu, API_GPU_BEGIN)
    cyc = call(cpu, CART_FRAME)
    call(cpu, API_GPU_END)
    end = cpu_mem[0x04] | (cpu_mem[0x05] << 8)
    return bytes(cpu_mem[PPRAM + i] for i in range(end - PPRAM + 1)), cyc


# ---- power on: straight into the tunnel -------------------------------------
call(cpu, CART_INIT)
snap_run = bytes(cpu_mem[0x1000:0x5A00])                  # the flight engine, as the boot loaded it...
snap_demo = bytes(cpu_mem[0xC800:0xD800])                 # ...and the field's DEMO_RAM code (cart_init has the SCREEN's
                                                          #   UICODE over its first $657 bytes, so those are left out)
check("power-on is the tunnel (TUNTEST)", cpu_mem[SCR["SCR_STATE"]] == SCR["SC_TUNNEL"],
      f"SCR_STATE {cpu_mem[SCR['SCR_STATE']]}")
seen = [frame() for _ in range(40)]
cleared = any(op == 0x20 for op, _ in seen[0])
rects = sum(1 for c in seen for op, _ in c if op == 0x32)
game = any(op in (0x4C, 0x4E) for c in seen for op, _ in c)
check("a CLEAR_BG, then the cockpit's 20 bands, each sent and replayed, and nothing of the field",
      cleared and rects == 40 and not game, f"{rects} bands")

TK = asm_consts("tunnel.s")
RUMBLE_A = asm_consts("rumble.s")["RUMBLE"]
VLEN_A = asm_consts("main.s")["VLEN"]
AMP, NR, ZHIT = TK["TUN_AMP"], TK["TUN_ROCKS"], TK["TUN_ZHIT"]
A = {n: LBL[n] for n in ("CAMX", "CAMY", "RZL", "RZH", "RXW", "RYW", "RHI", "RAN", "RSP", "RTY", "SPT",
                         "HITS", "SZ", "ROC", "RBX", "RBY")}


def flying_frame(**kw):
    cpu_mem[SCR["SC_PTRL"]] = cpu_mem[SCR["SC_PTRH"]] = 0         # the tunnel's own clock
    return frame(**kw)


def dots(c):
    return [[(pl[1 + 2 * i], pl[2 + 2 * i]) for i in range(pl[0])] for op, pl in c if op == 0x47]


def camera():
    return sb8(cpu_mem[A["CAMX"]]), sb8(cpu_mem[A["CAMY"]])


# ---- stress: rocks anywhere, nothing drawn outside the window ---------------------
import random


def put_rock_any(k, x, y, z, ang, typ):
    cpu_mem[A["RZL"] + k], cpu_mem[A["RZH"] + k] = z & 0xFF, z >> 8
    cpu_mem[A["RXW"] + k] = x & 0xFF
    cpu_mem[A["RYW"] + k] = y & 0xFF
    cpu_mem[A["RHI"] + k] = 1                                   # (no hit counting here)
    cpu_mem[LBL["RDF"] + k] = 0
    cpu_mem[LBL["RKIND"] + k] = 0
    cpu_mem[A["RAN"] + k], cpu_mem[A["RSP"] + k], cpu_mem[A["RTY"] + k] = ang, 0, typ


def geometry(cmds):
    """Every full-res fb point the commands put on the screen: (kind, x, y)."""
    out = []
    for op, pl in cmds:
        if op == 0x43:
            x1, y1, x2, y2 = pl
            out += [("line", x1, y1), ("line", x2, y2)]
        elif op in (0x4C, 0x4E):
            cx, cy = pl[0] | pl[1] << 8, pl[2] | pl[3] << 8
            if cx > 32767:
                cx -= 65536
            if cy > 32767:
                cy -= 65536
            ang, scale, n = pl[4], pl[5], pl[6] & 0x7F
            C, sgc, S_, sgs = pg_matrix(ang, scale)
            dbl = 1 if op == 0x4C else 0                        # DOT_POLYGON is half-res: x2 on the screen
            for i in range(n):
                dx, dy = sb8(pl[7 + 2 * i]), sb8(pl[8 + 2 * i])
                qx, qy = pg_vertex(dx, dy, cx, cy, C, sgc, S_, sgs)
                out.append(("dot" if dbl else "poly", qx * (2 if dbl else 1), qy * (2 if dbl else 1)))
    return out


if "--stress" in sys.argv:
    rng = random.Random(7)
    bad = []
    for trial in range(int(sys.argv[sys.argv.index("--stress") + 1]) if len(sys.argv) > sys.argv.index("--stress") + 1 else 300):
        for k in range(NR):
            cpu_mem[A["RZL"] + k] = cpu_mem[A["RZH"] + k] = 0
        cpu_mem[A["SPT"]] = 250
        bx0, by0, bz0 = rng.randint(-100, 100), rng.randint(-100, 100), rng.choice([rng.randint(30, 300), rng.randint(300, 1000)])
        for k in range(rng.randint(1, 8)):
            if trial % 2:                                        # half the trials: a cluster, so rocks hide each other
                put_rock_any(k, bx0 + rng.randint(-14, 14), by0 + rng.randint(-14, 14), max(20, bz0 + rng.randint(-60, 60)),
                             rng.randint(0, 255), rng.randint(0, 3))
            else:
                put_rock_any(k, rng.randint(-100, 100), rng.randint(-100, 100),
                             rng.choice([rng.randint(30, 300), rng.randint(300, 1000)]), rng.randint(0, 255), rng.randint(0, 3))
        for ax in (0, 1):                                       # the lean anywhere: its spring state poked
            v = rng.randint(-AMP, AMP)
            cpu_mem[LBL["PLO"] + ax], cpu_mem[LBL["PHI"] + ax] = 0, v & 0xFF
            cpu_mem[LBL["VLO"] + ax] = cpu_mem[LBL["VHI"] + ax] = 0
        cpu_mem[LBL["THH"]] = rng.randint(0, 255)              # ...and the roll
        cpu_mem[LBL["WLO"]] = cpu_mem[LBL["WHI"]] = 0
        cmds = flying_frame()
        info = [(cpu_mem[A["RXW"] + k], cpu_mem[A["RYW"] + k], cpu_mem[A["RZL"] + k] | cpu_mem[A["RZH"] + k] << 8) for k in range(3)]
        for kind, x, y in geometry(cmds):
            if not (48 <= x <= 351):
                bad.append((trial, kind, x, y, camera(), info))
                if len(bad) == 1:
                    for op, pl in cmds:
                        if op in (0x4C, 0x4E):
                            print("      cmd", hex(op), "cx", pl[0] | pl[1] << 8, "cy", pl[2] | pl[3] << 8, "ang", pl[4], "scale", pl[5], "N", pl[6])
                        elif op == 0x43:
                            print("      line", pl)
                    for k in range(NR):
                        print("      rock", k, "z", cpu_mem[A["RZL"] + k] | cpu_mem[A["RZH"] + k] << 8,
                              "x", sb8(cpu_mem[A["RXW"] + k]), "y", sb8(cpu_mem[A["RYW"] + k]),
                              "roc", cpu_mem[A["ROC"] + k], "vis", cpu_mem[LBL["RVIS"] + k], "wc", cpu_mem[LBL["RWC"] + k],
                              "sel", cpu_mem[LBL["RSEL"] + k])
                break
        for op, pl in cmds:                                      # (the OS CLAMPS a LINE16, so a rock-sized line
            if op == 0x43 and (abs(pl[1] - pl[3]) > 120 or abs(pl[0] - pl[2]) > 120):   # that is 120+ px long was
                bad.append((trial, "long line", pl, camera(), info))                    # clamped, not cut)
                break
    print(f"stress: {len(bad)} frames drew outside the window's x range (fb x 50..349)")
    for b in bad[:12]:
        print("   ", b)
    sys.exit(1 if bad else 0)

# ---- the stars ---------------------------------------------------------------
clear = None


def clear_rocks():
    for k in range(NR):
        cpu_mem[A["RZL"] + k] = cpu_mem[A["RZH"] + k] = 0
    cpu_mem[A["SPT"]] = 250                                    # no new ones for a while
    for n_ in ("THL", "THH", "WLO", "WHI"):                    # ...and the world upright, still (a knock
        cpu_mem[LBL[n_]] = 0                                   #   rolls it, and a case set up near an edge
                                                               #   of the octagon test is not rotation-proof)


clear_rocks()
lists = []
for f in range(30):
    d = dots(flying_frame())
    lists.append(d[0] if len(d) == 1 else None)
check("flying: ONE DOT_PIXELS a frame, 30 frames running", all(l is not None for l in lists),
      f"{sum(l is None for l in lists)} frames without exactly one")
allpts = [p for l in lists if l for p in l]
check("every star inside the window (half-res fb x 25..174, y 0..149)",
      all(25 <= x <= 174 and 0 <= y <= 149 for x, y in allpts),
      f"{sum(not (25 <= x <= 174 and 0 <= y <= 149) for x, y in allpts)} outside")
out_n = tot_n = 0
for l0, l1 in zip(lists, lists[1:]):                         # each star against its nearest in the last frame
    for (x1, y1) in l1:
        x0, y0 = min(l0, key=lambda q: (q[0] - x1) ** 2 + (q[1] - y1) ** 2)
        if (x0 - x1) ** 2 + (y0 - y1) ** 2 <= 36:             # (a reborn star has no earlier self nearby)
            tot_n += 1
            out_n += (x1 - 100) ** 2 + (y1 - 75) ** 2 >= (x0 - 100) ** 2 + (y0 - 75) ** 2
check("and they stream OUTWARD from the centre", tot_n > 100 and out_n >= 0.9 * tot_n,
      f"{out_n} of {tot_n} moved out")

# ---- the controls: UP/DOWN lean, LEFT/RIGHT roll the world ---------------------
import math
ROLLW, ROLLK, RKICK = TK["TUN_ROLLW"], TK["TUN_ROLLK"], TK["TUN_RKICK"]
LEAN_P, LEAN_N = JOY_UP, JOY_DOWN                           # inverted, a pilot's stick: UP leans down (+y)


def s16(v):
    return v - 65536 if v > 32767 else v


def rate():
    return s16(cpu_mem[LBL["WLO"]] | cpu_mem[LBL["WHI"]] << 8)


def theta():
    return cpu_mem[LBL["THL"]] | cpu_mem[LBL["THH"]] << 8


def set_roll(thh):
    cpu_mem[LBL["THL"]], cpu_mem[LBL["THH"]] = 0, thh & 0xFF
    cpu_mem[LBL["WLO"]] = cpu_mem[LBL["WHI"]] = 0


def lean_run(joy, n):
    tr = []
    for _ in range(n):
        cpu_mem[A["SPT"]] = 250                              # (no rock spawned to knock it)
        flying_frame(joy=joy)
        tr.append(camera())
    return tr


def roll_run(joy, n):
    tr = []
    for _ in range(n):
        cpu_mem[A["SPT"]] = 250
        flying_frame(joy=joy)
        tr.append((rate(), theta()))
    return tr


def q07(f):
    return int(round(127 * f))


clear_rocks()
lean_run(0, 100)
set_roll(0)
LYC = (AMP * 127 + 64) >> 7                                   # the camera at TH = 0: AMP * cos 0 (127/128)
r = lean_run(LEAN_P, 100)
ys = [p[1] for p in r]
reach = next((i for i, v in enumerate(ys) if v >= 0.9 * AMP), None)
check("UP leans the camera DOWN, to +AMP (AMP cos 0 = 127/128 of it): reached, never past it, and without a step",
      ys[-1] == LYC and max(ys) == LYC and all(b >= a for a, b in zip(ys, ys[1:]))
      and max(b - a for a, b in zip(ys, ys[1:])) <= AMP // 15 + 1 and all(p[0] == 0 for p in r),
      f"end {ys[-1]}, max {max(ys)}, biggest step {max(b - a for a, b in zip(ys, ys[1:]))}")
check("90% of the way in 25-45 frames (K1 = 6: ~0.5 s; K1 = 7 is ~1 s)",
      reach is not None and 25 <= reach <= 45, f"90% at frame {reach}")
r = lean_run(0, 120)
ys = [p[1] for p in r]
check("LET GO springs it back to the centre, without overshooting",
      ys[-1] == 0 and min(ys) >= 0 and all(b <= a for a, b in zip(ys, ys[1:])), f"end {ys[-1]}, min {min(ys)}")
r = lean_run(LEAN_N, 110)
check("DOWN leans it up, to -AMP", r[-1] == (0, -LYC), f"{r[-1]}")
lean_run(0, 120)
th0 = theta()
r = roll_run(JOY_RIGHT, 60)
ws = [w for w, _ in r]
reach = next((i for i, w in enumerate(ws) if w <= -0.9 * ROLLW), None)
check("RIGHT rolls the world: the rate eases to -TUN_ROLLW (TH falling), smoothly, never past it",
      ws[-1] == -ROLLW and min(ws) == -ROLLW and all(b <= a for a, b in zip(ws, ws[1:]))
      and -ws[0] <= ROLLW // (1 << ROLLK) + 1 and s16((r[-1][1] - th0) & 0xFFFF) < 0,
      f"end {ws[-1]}, first {ws[0]}, TH moved {s16((r[-1][1] - th0) & 0xFFFF)}")
check("...a SHORT start: 90% of the rate in 12-25 frames", reach is not None and 12 <= reach <= 25, f"90% at frame {reach}")
r = roll_run(0, 60)
ws = [w for w, _ in r]
reach = next((i for i, w in enumerate(ws) if w >= -0.1 * ROLLW), None)
th1 = theta()
roll_run(0, 60)
check("LET GO eases it to a stop just as short (12-25 frames to 10%), and it stays put: no creep",
      ws[-1] == 0 and all(b >= a for a, b in zip(ws, ws[1:])) and reach is not None and 12 <= reach <= 25
      and theta() == th1, f"end {ws[-1]}, 10% at {reach}, TH {th1} -> {theta()}")
r = roll_run(JOY_LEFT, 60)
check("LEFT rolls it the other way (+TUN_ROLLW)", r[-1][0] == ROLLW, f"{r[-1][0]}")
roll_run(0, 60)
for thh in (40, 100, 200):                                    # the camera turns with the world
    set_roll(thh)
    lean_run(LEAN_P, 100)
    a = 2 * math.pi * thh / 256
    ex = (AMP * q07(math.sin(a)) / 128, AMP * q07(math.cos(a)) / 128)
    cam = camera()
    check(f"leaning (UP) with the world rolled {thh} brad puts the camera at R(-TH) (0, AMP) in it",
          abs(cam[0] - ex[0]) <= 1 and abs(cam[1] - ex[1]) <= 1, f"cam {cam}, expected {ex}")
    lean_run(0, 120)
set_roll(0)
quad = [0, 0, 0, 0]
for _ in range(40):
    for x, y in (dots(flying_frame(joy=LEAN_P | JOY_RIGHT)) or [[]])[-1]:            # (the last DOT_PIXELS: a cloud may come first)
        quad[(x >= 100) * 2 + (y >= 75)] += 1
check("leaning and rolling the stars still fill all four quarters of the window",
      min(quad) >= 0.08 * sum(quad), f"quarters {quad}")
lean_run(0, 120)
roll_run(0, 60)

# ---- the far stars: pixels at infinity, turned by the roll, slid a little by the lean ----------
NFAR = TK["TUN_FAR"]
FR = [cpu_mem[LBL["FARR"] + i] for i in range(NFAR)]
FA = [cpu_mem[LBL["FARA"] + i] for i in range(NFAR)]


def still_points(n=3, joy=0):
    """The points drawn in the same place in n frames running: the far stars (the dust moves)."""
    sets = []
    for _ in range(n):
        d = dots(flying_frame(joy=joy))
        sets.append(set(d[0]) if d else set())
    return set.intersection(*sets)


def far_expected():
    """Where the far stars must be: o = r (cos, sin)(a + TH), oy less LY >> FSH; those in the window."""
    thh, ly = cpu_mem[LBL["THH"]], sb8(cpu_mem[LBL["LY"]])
    out = set()
    for r_, a_ in zip(FR, FA):
        a = 2 * math.pi * ((a_ + thh) & 255) / 256
        ox = round(r_ * q07(math.cos(a)) / 128)
        oy = round(r_ * q07(math.sin(a)) / 128) - (ly >> TK["TUN_FSH"])
        if abs(ox) < 75 and abs(oy) < 75:
            out.add((100 + oy, 75 - ox))
    return out


def near(exp, got):
    return sum(1 for (x, y) in exp if any(abs(x - u) <= 1 and abs(y - v) <= 1 for u, v in got))


clear_rocks()                                             # (a rock would hide some)
check("the far stars fill a disc round the window's centre that covers it (radius 105)",
      max(FR) <= 105 and max(FR) >= 90 and sum(r_ > 75 for r_ in FR) >= 4, f"radii {sorted(FR)}")
far0 = still_points()
exp0 = far_expected()
check("the far stars: pixels that do not move, where their places say (>= 90% of those in the window)",
      len(exp0) >= 0.4 * NFAR and near(exp0, far0) >= 0.9 * len(exp0), f"{near(exp0, far0)} of {len(exp0)}")
set_roll(77)
lean_run(LEAN_P, 100)
far1 = still_points(joy=LEAN_P)
exp1 = far_expected()
check("...and rolled and leaning they turn with the roll and slide against the lean",
      len(exp1) >= 0.4 * NFAR and near(exp1, far1) >= 0.9 * len(exp1) and exp1 != exp0,
      f"{near(exp1, far1)} of {len(exp1)}, cam {camera()}")
lean_run(0, 120)
set_roll(0)

# ---- a rock turns with the world ---------------------------------------------
clear_rocks()
for thh, side in ((64, 1), (192, -1)):
    set_roll(thh)
    for k in range(NR):
        cpu_mem[A["RZL"] + k] = cpu_mem[A["RZH"] + k] = 0
    cpu_mem[A["SPT"]] = 250
    cpu_mem[A["RZL"]], cpu_mem[A["RZH"]] = 250, 0
    cpu_mem[A["RXW"]], cpu_mem[A["RYW"]] = AMP, 0
    cpu_mem[A["RHI"]] = 1
    cpu_mem[LBL["RDF"]] = cpu_mem[LBL["RKIND"]] = 0
    cpu_mem[A["RAN"]], cpu_mem[A["RSP"]], cpu_mem[A["RTY"]] = 10, 0, 0
    cmds = flying_frame()
    pls = [pl for op, pl in cmds if op == 0x4E]
    cx = pls[0][0] | pls[0][1] << 8 if pls else None
    cy = pls[0][2] | pls[0][3] << 8 if pls else None
    check(f"a rock a lane to the right, the world rolled {thh} brad: drawn turned with it "
          f"({'below' if side > 0 else 'above'} the centre, its angle its own + TH)",
          len(pls) == 1 and abs(cy - 150) <= 2 and (cx - 200) * side > 40 and pls[0][4] == (10 + thh) & 255,
          f"{len(pls)} polygons, centre {(cx, cy)}, angle {pls[0][4] if pls else None}")
set_roll(0)
clear_rocks()

# ---- the rocks ---------------------------------------------------------------


def put_rock(k, x, y, z, ang=0, spin=0, typ=0):
    cpu_mem[A["RZL"] + k], cpu_mem[A["RZH"] + k] = z & 0xFF, z >> 8
    cpu_mem[A["RXW"] + k] = x & 0xFF
    cpu_mem[A["RYW"] + k] = y & 0xFF
    cpu_mem[A["RHI"] + k] = 0
    cpu_mem[LBL["RDF"] + k] = 0                                  # (not thrown)
    cpu_mem[LBL["RKIND"] + k] = 0                                # (a rock)
    cpu_mem[A["RAN"] + k], cpu_mem[A["RSP"] + k], cpu_mem[A["RTY"] + k] = ang, spin & 0xFF, typ


def polys(cmds):
    return [pl for op, pl in cmds if op == 0x4E]


EXTRA = {}                                                     # extra checks, filled in below
clear_rocks()
lean_run(0, 150)                                      # at rest: no velocity left, no shake
put_rock(0, 0, 0, 100)
pls = polys(flying_frame())
cen = (pls[0][0] | pls[0][1] << 8, pls[0][2] | pls[0][3] << 8) if pls else None
check("a rock dead ahead is ONE POLYGON16 round the window's centre (full-res 200,150)",
      len(pls) == 1 and cen == (200, 150), f"{len(pls)} polygons, centre {cen}")
sc = []
clear_rocks()
put_rock(0, 0, 0, TK["TUN_RZMAX"])
for _ in range(TK["TUN_RZMAX"] // 2):
    cpu_mem[A["SPT"]] = 250
    p = [pl for op, pl in flying_frame() if op in (0x4C, 0x4E)]      # dotted when far
    if p:
        sc.append(p[0][5])
check("it GROWS with the perspective (scale rising, 1:1 = 128 at TUN_ZFULL and no more)",
      len(sc) > 200 and all(b >= a for a, b in zip(sc, sc[1:])) and max(sc) == 128 and sc[0] < 8,
      f"{len(sc)} frames, scale {sc[:2]}..{sc[-2:]}")
clear_rocks()
put_rock(0, 0, 0, 60)
for i in range(TK["TUN_STARS"]):
    cpu_mem[A["SZ"] + i] = 200
d = dots(flying_frame())
r_occ, bx, by = cpu_mem[A["ROC"]], cpu_mem[A["RBX"]] - 128, cpu_mem[A["RBY"]] - 128
inside = [(x, y) for x, y in (d[0] if d else []) if (75 - y - bx) ** 2 + (x - 100 - by) ** 2 < (0.85 * r_occ) ** 2]
check("it hides the stars behind its disc: none drawn inside it",
      r_occ > 8 and not inside, f"disc radius {r_occ}, {len(inside)} stars inside")
clear_rocks()
put_rock(0, 0, 0, 60)
put_rock(1, AMP, 0, 60)
h0 = cpu_mem[A["HITS"]]
for _ in range(30):
    flying_frame()
check("a rock on the ship at TUN_ZHIT is ONE hit, one a lane away is none, and both are gone after",
      cpu_mem[A["HITS"]] == h0 + 1 and cpu_mem[A["RZL"]] == 0 and cpu_mem[A["RZL"] + 1] == 0,
      f"hits {cpu_mem[A['HITS']] - h0}")
# the knock: the ship is kicked away, the view shakes, the pad rumbles, the sound is the ram's,
# and the rock - frozen in depth - is thrown off sideways and goes
clear_rocks()
lean_run(LEAN_P, 150)                               # the ship below the axis...
set_roll(0)
th0 = theta()
put_rock(0, 6, AMP, 45)                               # ...and a rock a little to its right
h0 = cpu_mem[A["HITS"]]
minw, shk_seen, rz_after, rx_seq, vl_ship, vl_noise = 0, 0, [], [], 0, 0
for _ in range(14):
    flying_frame(joy=LEAN_P)
    minw = min(minw, rate())
    shk_seen = max(shk_seen, cpu_mem[LBL["SHK"]])
    vl_ship, vl_noise = max(vl_ship, cpu_mem[VLEN_A + 2]), max(vl_noise, cpu_mem[VLEN_A + 3])
    if cpu_mem[LBL["RDF"]]:
        rz_after.append(cpu_mem[A["RZL"]] | cpu_mem[A["RZH"]] << 8)
        rx_seq.append(sb8(cpu_mem[A["RXW"]]))
check("a hit KNOCKS the ship away from the rock: across, by the roll (on the right, the ship below: TH falls)",
      cpu_mem[A["HITS"]] == h0 + 1 and minw <= -RKICK // 2 and s16((theta() - th0) & 0xFFFF) < -256,
      f"hits {cpu_mem[A['HITS']] - h0}, min rate {minw}, TH moved {s16((theta() - th0) & 0xFFFF)}")
check("...the view SHAKES (SHK set) and the pad RUMBLES",
      shk_seen >= TK["TUN_SHAKE"] - 2 and cpu_mem[RUMBLE_A] > 0, f"SHK max {shk_seen}, RUMBLE {cpu_mem[RUMBLE_A]}")
check("...the sound is the ram: both halves of SE_KLANG hold their voices (the ship's tone voice and the noise one)",
      vl_ship >= 15 and vl_noise >= 7, f"VLEN ship {vl_ship}, noise {vl_noise}")
check("...and the rock stops approaching (its depth frozen) and is thrown AWAY, to the right, 3 units a frame",
      len(rz_after) >= 3 and len(set(rz_after)) == 1 and all(b - a == TK["TUN_DEFL"] for a, b in zip(rx_seq, rx_seq[1:])),
      f"depths {sorted(set(rz_after))}, x {rx_seq[:6]}")
for _ in range(30):
    flying_frame(joy=LEAN_P)
check("...until it has left the window, and then it is gone", cpu_mem[A["RZL"]] == 0 and cpu_mem[A["RZH"]] == 0)
clear_rocks()
lean_run(0, 120)
roll_run(0, 60)
set_roll(0)
# the engine: an audible noise rumble (mode 6), its rate stepping up and swelling in the rush
cpu_mem[SCR["SC_PTRL"]] = cpu_mem[SCR["SC_PTRH"]] = 0
for _ in range(20):
    frame()
HP = LBL["HUMP"]
noise = [cpu_mem[HP + i] for i in range(14)]
check("the engine: a NOISE program (type 1), four 4-frame steps in mode 6 at volume TUN_HUMV (3)",
      noise[0] == 1 and noise[1::3][:4] == [4] * 4 and noise[2::3][:4] == [TK["TUN_HUMM"]] * 4
      and noise[3::3][:4] == [TK["TUN_HUMV"]] * 4 and noise[13] == 0xFF, f"{noise}")
F1 = TK["TUN_FRAMES"] - TK["TUN_RUSHF"]
modes, vols, wn, wv, lastq = [], [], [], [], None
HQ = LBL["HUMQ"]
cpu_mem[SCR["SC_PTRL"]], cpu_mem[SCR["SC_PTRH"]] = (F1 - 20) & 0xFF, (F1 - 20) >> 8
prev = None
for _ in range(TK["TUN_RUSHF"] + 20):
    frame()
    cur = tuple(cpu_mem[HP + i] for i in range(14))
    both = (cur, tuple(cpu_mem[HQ + i] for i in range(14)))
    if both != prev:
        modes.append(cur[2])
        vols.append(cur[3])
        wn.append(cpu_mem[HQ + 2])
        wv.append(cpu_mem[HQ + 3])
        if cpu_mem[HQ + 3] > 0:
            lastq = [cpu_mem[HQ + i] for i in range(14)]
        prev = both
modes, vols, wn, wv = modes[:-2], vols[:-2], wn[:-2], wv[:-2]   # (the last ones are the scene's end: the hum is cut and restarted)
live = [(n, v) for n, v in zip(wn, wv) if v > 0]
check("...and from the start of the rush a WHINE joins it on tone voice 0: it fades in and climbs to the top of the note table",
      live and live[0][0] >= 60 and live[-1][0] >= 100 and live[-1][0] <= 108 and live[-1][1] >= 4
      and all(b[0] >= a[0] for a, b in zip(live, live[1:])) and wv[0] == 0,
      f"{len(live)} notes {live[0] if live else None}..{live[-1] if live else None}")
check("...in the rush its noise gets FASTER (mode 6, 5, 4, never back) and LOUDER (a step or two, up to 5)",
      all(b <= a for a, b in zip(modes, modes[1:])) and modes[0] == 6 and modes[-1] == 4
      and all(b >= a for a, b in zip(vols, vols[1:])) and vols[-1] == TK["TUN_HUMV"] + 2, f"modes {modes[0]}..{modes[-1]}, volumes {vols[0]}..{vols[-1]}")
n0, n1, n2, n3 = lastq[2], lastq[5], lastq[8], lastq[11]
v0, v1 = lastq[3], lastq[6]
check("...with a VIBRATO (steps 1 and 3 a few semitones above and below the note: up to +-3 at the end) and a TREMOLO (every other step quieter)",
      n1 - n0 >= 2 and n2 - n3 >= 2 and n2 >= n0 and v1 == v0 - 1 and lastq[1::3][:4] == [2, 2, 2, 3],
      f"notes {n0},{n1},{n2},{n3} volumes {v0},{v1}, frames {lastq[1::3][:4]}")
for _ in range(80):
    frame()                                           # (the scene ended and began again: back to flying)
clear_rocks()

# the end of the run: no more rocks, then the rush - the dust becomes streaks, the ship accelerates
clear_rocks()
cut = TK["TUN_FRAMES"] - TK["TUN_RUSHF"] - TK["TUN_CLEAR"]
cpu_mem[SCR["SC_PTRL"]], cpu_mem[SCR["SC_PTRH"]] = (cut + 5) & 0xFF, (cut + 5) >> 8
cpu_mem[A["SPT"]] = 1
for _ in range(90):
    cpu_mem[A["SPT"]] = 1
    frame()
check("no new rock is born in the last TUN_RUSHF + TUN_CLEAR frames",
      all(cpu_mem[A["RZL"] + k] == 0 and cpu_mem[A["RZH"] + k] == 0 for k in range(NR)))
cpu_mem[SCR["SC_PTRL"]], cpu_mem[SCR["SC_PTRH"]] = (F1 - 3) & 0xFF, (F1 - 3) >> 8
for _ in range(2):
    frame()
extra, lens0, meanlen = [], [], []
dist = lambda p: ((p[0] - 100) ** 2 + (p[1] - 75) ** 2) ** 0.5
for i in range(TK["TUN_RUSHF"] - 20):
    cmds = frame()
    f = cpu_mem[SCR["SC_PTRL"]] | cpu_mem[SCR["SC_PTRH"]] << 8
    extra.append(cpu_mem[LBL["SPD"]] - (TK["TUN_SPEED"] + ((f - 1) & 1)))
    ls = [pl for op, pl in cmds if op == 0x42]
    L = [(dist((l[2], l[3])) - dist((l[0], l[1]))) / dist((l[2], l[3])) for l in ls if dist((l[2], l[3])) > 12]
    meanlen.append(sum(L) / len(L) if L else 0)           # the tail as a fraction of the head's distance
    if i < 6:
        lens0 += [max(abs(l[0] - l[2]), abs(l[1] - l[3])) for l in ls]
lines = ls
pix = dots(cmds)
heads = [(l[2], l[3]) for l in lines]
tails = [(l[0], l[1]) for l in lines]
ok_dir = all(dist(t) <= dist(h) for t, h in zip(tails, heads))
ratios = [(dist(h) - dist(t)) / dist(h) for t, h in zip(tails, heads) if dist(h) > 12]
check("in the rush the dust is STREAKS (LINEs, tail toward the centre) and only the far stars are pixels",
      len(lines) >= 6 and ok_dir and (not pix or len(pix[0]) <= TK["TUN_FAR"]),
      f"{len(lines)} lines, {len(pix[0]) if pix else 0} pixels, inward {ok_dir}")
check("...they START from a single pixel (no streak longer than 1 px in the first frames of the rush)",
      lens0 and max(lens0) <= 1, f"longest {max(lens0 or [0])}")
smooth = [sum(meanlen[i:i + 8]) / 8 for i in range(len(meanlen) - 8)]
check("...and GROW smoothly: the mean tail fraction never jumps (<= 0.02 a frame, over 8 frames) and ends near a half",
      all(-0.01 <= b - a <= 0.02 for a, b in zip(smooth, smooth[1:])) and 0.4 <= smooth[-1] <= 0.55,
      f"biggest step {max(b - a for a, b in zip(smooth, smooth[1:])):.3f}, end {smooth[-1]:.2f}")
check("...longer the farther from the centre (the tail is the head less a fraction, 0.1..0.55 at the end)",
      ratios and 0.1 <= min(ratios) and max(ratios) <= 0.55, f"fractions {min(ratios or [0]):.2f}..{max(ratios or [0]):.2f}")
avg = [sum(extra[i:i + 32]) / 32 for i in range(len(extra) - 32)]
check("...and the ship accelerates SMOOTHLY: the extra speed (32-frame mean) does not fall (dither aside) and never jumps (<= 0.2 a frame: the speed-up was doubled), to 12 or more",
      all(-0.08 <= b - a <= 0.2 for a, b in zip(avg, avg[1:])) and avg[-1] >= 12 and max(abs(b - a) for a, b in zip(extra, extra[1:])) <= 1,
      f"mean {avg[0]:.2f} .. {avg[-1]:.2f}, biggest step {max(b - a for a, b in zip(avg, avg[1:])):.3f}")
raw, cyc = raw_frame()
g0 = gpu.processorCycles
gpu_draw(raw)
print(f"        a frame of the rush: {cyc} CPU cycles ({100 * cyc / 237000:.1f}%), GPU {gpu.processorCycles - g0} cycles "
      f"({100 * (gpu.processorCycles - g0) / 237000:.1f}%), {len(lines)} streaks")
cpu_mem[SCR["SC_PTRL"]], cpu_mem[SCR["SC_PTRH"]] = (TK["TUN_FRAMES"] - 1) & 0xFF, (TK["TUN_FRAMES"] - 1) >> 8
frame()
frame()
check("at TUN_FRAMES the scene ends (here, in the tunnel image: it starts again from the dark)",
      cpu_mem[SCR["SCR_PH"]] <= 1, f"SCR_PH {cpu_mem[SCR['SCR_PH']]}")
for _ in range(60):
    frame()                                           # back to flying for the tests below
clear_rocks()
# ---- the Saturnium clouds: DOT_PIXELS the size of a rock, 8 pixels far to 32 near, caught like a pickup
def put_cloud(k, x, y, z):
    put_rock(k, x, y, z)
    cpu_mem[LBL["RKIND"] + k] = 1
    cpu_mem[A["RSP"] + k] = 1


def cloud_list(cmds):
    d = dots(cmds)
    return d[0] if len(d) >= 2 else None                  # the clouds go out BEFORE the stars' list


clear_rocks()
lean_run(0, 150)
counts, spread = [], []
put_cloud(0, 0, 0, TK["TUN_RZMAX"])
for _ in range(TK["TUN_RZMAX"] // 2):
    cpu_mem[A["SPT"]] = 250
    cl = cloud_list(flying_frame())
    if cl:
        counts.append(len(cl))
        r_half = (cpu_mem[LBL["RSCR"]])
        spread.append(max(((x - 100) ** 2 + (y - 75) ** 2) ** 0.5 for x, y in cl) - r_half)
caught0 = cpu_mem[LBL["TSAT"]]
check("a Saturnium cloud is a DOT_PIXELS: 8 pixels far, growing to 32 at the camera (never fewer coming in)",
      len(counts) > 100 and counts[0] <= 10 and counts[-1] >= 28 and max(counts) <= TK["TUN_CLOUDMAX"]
      and all(b >= a - 3 for a, b in zip(counts, counts[1:])), f"{len(counts)} frames, {counts[:3]}..{counts[-3:]}")
check("...scattered through a disc of a rock's radius (no pixel farther from its centre than that)",
      max(spread) <= 1.5, f"{max(spread):.1f} px past the radius")
check("...and dead ahead it is CAUGHT: the tally rises, the cloud is gone, and there is no knock or shake",
      caught0 == 1 and cpu_mem[A["RZL"]] == 0 and cpu_mem[LBL["SHK"]] == 0, f"TSAT {caught0}, SHK {cpu_mem[LBL['SHK']]}")
cpu_mem[LBL["TSAT"]] = 0
clear_rocks()
h0 = cpu_mem[A["HITS"]]
put_cloud(0, 0, 0, 60)
vl = 0
for _ in range(20):
    flying_frame()
    vl = max(vl, cpu_mem[VLEN_A + 3])
check("...with the sector's Saturnium sound (SE_SATN: the noise voice held for its 16 frames), and not a rock's hit",
      vl >= 14 and cpu_mem[A["HITS"]] == h0 and cpu_mem[LBL["TSAT"]] == 1, f"noise claim {vl}, TSAT {cpu_mem[LBL['TSAT']]}")
cpu_mem[LBL["TSAT"]] = 0
clear_rocks()
put_cloud(0, AMP, 0, 60)
for _ in range(20):
    flying_frame()
check("a cloud a lane away is not caught", cpu_mem[LBL["TSAT"]] == 0)
clear_rocks()
# the reach: a ring of radius AMP, so the spawner pulls a corner lane in to it, and every lane is caught
rmax, ncorner, rcorner = 0, 0, 0
for _ in range(400):
    clear_rocks()
    call(cpu, LBL["tun_spawn"])
    k = next(k for k in range(NR) if cpu_mem[A["RZL"] + k] | cpu_mem[A["RZH"] + k])
    x, y = sb8(cpu_mem[A["RXW"] + k]), sb8(cpu_mem[A["RYW"] + k])
    rr = (x * x + y * y) ** 0.5
    rmax = max(rmax, rr)
    if abs(x) > 30 and abs(y) > 30:
        ncorner += 1
        rcorner = max(rcorner, rr)
check("the spawner keeps everything within the ring's reach (AMP + 16 of jitter), corner lanes pulled in",
      rmax <= AMP + 16 * 1.42 + 1 and ncorner > 40 and rcorner <= AMP + 16 * 1.42 + 1,
      f"farthest {rmax:.0f}, {ncorner} in corners, farthest of those {rcorner:.0f}")
for thh in (32, 96, 160, 224):                              # a corner cloud, the world rolled to face it
    clear_rocks()
    cpu_mem[LBL["TSAT"]] = 0
    lean_run(0, 120)
    set_roll(thh)
    lean_run(LEAN_P, 100)
    cx, cy = camera()
    sx, sy = (1 if cx > 0 else -1), (1 if cy > 0 else -1)
    put_cloud(0, sx * 57, sy * 57, 60)                      # (AMP, AMP) on the ring: times 181/256
    for _ in range(20):
        cpu_mem[A["SPT"]] = 250
        flying_frame(joy=LEAN_P)
    check(f"a cloud in a corner lane ({sx * 57}, {sy * 57}) is caught with the world rolled to it ({thh} brad)",
          cpu_mem[LBL["TSAT"]] == 1, f"cam {(cx, cy)}, TSAT {cpu_mem[LBL['TSAT']]}")
cpu_mem[LBL["TSAT"]] = 0
lean_run(0, 120)
clear_rocks()
put_cloud(0, 0, 0, 200)
put_rock(1, 0, 0, 90)
cl_pts = cloud_list(flying_frame())
r_occ, bx, by = cpu_mem[A["ROC"] + 1], cpu_mem[A["RBX"] + 1] - 128, cpu_mem[A["RBY"] + 1] - 128
hid_in = [(x, y) for x, y in (cl_pts or []) if (75 - y - bx) ** 2 + (x - 100 - by) ** 2 < (0.85 * r_occ) ** 2]
check("a rock in front of a cloud hides the pixels behind its disc", r_occ > 8 and not hid_in, f"disc {r_occ}, {len(hid_in)} pixels inside")
clear_rocks()
kinds = 0
cpu_mem[A["SPT"]] = 5
for _ in range(900):
    flying_frame()
    kinds |= 1 + max(cpu_mem[LBL["RKIND"] + k] for k in range(NR))
check("left alone, the spawner makes clouds as well as rocks", kinds == 3 or kinds >= 2)
clear_rocks()
cpu_mem[LBL["TSAT"]] = 0

clear_rocks()
put_rock(0, 0, 0, 60)
put_rock(1, 0, 0, 130)
pls = polys(flying_frame())
check("a rock wholly behind another is not drawn at all (one polygon, the near one, closed)",
      len(pls) == 1 and not pls[0][6] & 0x80, f"{len(pls)} polygons")
clear_rocks()
put_rock(0, 0, 0, 60)
put_rock(1, 30, 0, 130)
pls = polys(flying_frame())
closed = [pl for pl in pls if not pl[6] & 0x80]
opened = [pl for pl in pls if pl[6] & 0x80]
check("one partly behind another is cut: the near one closed, the far one only as open runs",
      len(closed) == 1 and len(opened) >= 1, f"{len(closed)} closed, {len(opened)} open")
clear_rocks()
put_rock(0, 0, 0, 60)
put_rock(1, 50, 50, 130)
pls = polys(flying_frame())
check("two apart are both drawn whole", len(pls) == 2 and all(not pl[6] & 0x80 for pl in pls), f"{len(pls)} polygons")
clear_rocks()
lean_run(LEAN_P, 100)
put_rock(0, 0, 0, 60)
h0 = cpu_mem[A["HITS"]]
for _ in range(30):
    flying_frame(joy=LEAN_P)
check("leaning a lane clear of a rock dodges it", cpu_mem[A["HITS"]] == h0, f"{cpu_mem[A['HITS']] - h0} hits")
lean_run(0, 120)
cpu_mem[A["SPT"]] = 5
nrock = 0
for _ in range(600):
    nrock = max(nrock, len(polys(flying_frame())))
check("left alone it spawns its own, never more than TUN_ROCKS at once", 0 < nrock <= NR, f"most at once {nrock}")

# far rocks are drawn from their REDUCED outlines (6-8 vertices), near ones whole (12-13)
clear_rocks()
put_rock(0, 0, 0, 600)
put_rock(1, 20, 20, 100)
cmds = flying_frame()
nv_far = [pl[6] & 0x7F for op, pl in cmds if op == 0x4C]          # DOT_POLYGON: half-res
nv_near = [pl[6] & 0x7F for op, pl in cmds if op == 0x4E]         # POLYGON16: solid
check("a far rock is a DOTTED polygon of its reduced outline (<= 8 vertices), a near one solid and whole (>= 12)",
      nv_far and nv_near and max(nv_far) <= 8 and min(nv_near) >= 12, f"far {nv_far}, near {nv_near}")
# the HUD's frame: nothing of a rock may be drawn past the window (full-res fb x 50..349)
bad = []
nlines = 0
for (wx, wy, wz) in [(0, 60, 120), (0, -60, 120), (0, 70, 70), (0, -70, 70), (30, 60, 100), (-30, -60, 100)]:
    clear_rocks()
    put_rock(0, wx, wy, wz, ang=17, typ=1)
    cmds = flying_frame()
    lines = [pl for op, pl in cmds if op == 0x43]
    nlines += len(lines)
    for x1, y1, x2, y2 in lines:
        if not (50 <= x1 <= 349 and 50 <= x2 <= 349):
            bad.append((wx, wy, wz, x1, x2))
    for pl in polys(cmds):                                  # a closed one must be wholly inside
        cx = pl[0] | pl[1] << 8
        rad = 96 * pl[5] // 128
        if not pl[6] & 0x80 and not (50 <= cx - rad and cx + rad <= 349):
            bad.append((wx, wy, wz, "closed polygon past the frame", cx, rad))
check("a rock at the window's edge is cut to it: every line inside fb x 50..349, no whole polygon past it",
      nlines > 0 and not bad, f"{nlines} lines, outside: {bad[:4]}")
clear_rocks()

# ---- what it costs -----------------------------------------------------------
raw, cyc = raw_frame()
g0 = gpu.processorCycles
gpu_draw(raw)
print(f"        a frame of the tunnel: {cyc} CPU cycles ({100 * cyc / 237000:.1f}% of 237,000), "
      f"GPU {gpu.processorCycles - g0} cycles ({100 * (gpu.processorCycles - g0) / 237000:.1f}%), "
      f"{len(polys(decode(raw)))} polygons")

# ---- the memory plan: the tunnel overwrites the run area, and the field comes back from ROM
over = bytes(cpu_mem[0x1000:0x5A00]) != snap_run and bytes(cpu_mem[0xC800:0xD800]) != snap_demo
check("while the tunnel flies the run area and DEMO_RAM hold the tunnel, not the field", over)
check("the tunnel's variables and rocks live in the run area ($1000+), not in DEMO_RAM",
      0x1000 <= LBL["RZL"] < 0x5A00 and 0x1000 <= LBL["tun_rocks_frame"] < 0x5A00 and 0xC000 <= LBL["tunnel_frame"] < 0xDF00)
cpu_mem[SCR["SCR_STATE"]] = SCR["SC_PLAY"]                 # what set_state_field does before it loads FIELD
cyc = call(cpu, LBL["ovl_load_field"])
back = bytes(cpu_mem[0x1000:0x5A00]) == snap_run and bytes(cpu_mem[0xC800:0xD800]) == snap_demo
dr = [i for i in range(len(snap_run)) if cpu_mem[0x1000 + i] != snap_run[i]]
dd = [i for i in range(len(snap_demo)) if cpu_mem[0xC800 + i] != snap_demo[i]]
check("ovl_load_field restores the flight engine (run area) and FIELD (DEMO_RAM) byte for byte from ROM", back,
      f"run area differs at {len(dr)} bytes{(' from $%04X' % (0x1000 + dr[0])) if dr else ''}; "
      f"DEMO_RAM at {len(dd)} bytes{(' from $%04X to $%04X' % (0xC800 + dd[0], 0xC800 + dd[-1])) if dd else ''}")
print(f"        the reload: {cyc} CPU cycles ({100 * cyc / 237000:.0f}% of a frame)")

print(f"{len(failed)} check(s) failed" if failed else "all tunnel checks passed")
sys.exit(1 if failed else 0)
