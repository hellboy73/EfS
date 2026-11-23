"""The force field's bench (src/ffield.s, design_technical.md 11.51): py65, the
real routines out of cart.bin, called by name.

    python tools/ffield_bench.py          (make first: it reads cart.bin)

It boots the cartridge the way tools/preview.py does (it runs preview.py's own
setup, up to the flight), swaps the field tenant into the wall slots (slots.s
ws_sync), places a field, and then asks the one question the field is for:
DOES ANYTHING EVER CROSS THE EDGE? Every mover is flown at the edge from both
sides, at every speed it can have, and its centre is checked against the TRUE
circle (Python's hypot, not the cartridge's 256-gon) after every step:

  ff_f        its f against the true signed distance, all round the circle
  rocks       bounced, every class, from outside and from inside
  enemies     slid along it
  the ship    pressed against it frame after frame, and hurt at most once a
              FF_HURTCD; and one landed ACROSS the line (a teleport) is put out
              on its centre's side
  bullets     a step that crosses is spent, one that does not flies on
  the frame   ff_frame's drawing near the edge, visible and flashed

and the cycles each costs. Exit status 1 if any check fails.
"""
import math
import os
import random
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
_src = (ROOT / "tools" / "preview.py").read_text(encoding="utf-8")
_src = _src[:_src.index("\nframes = []")]
sys.argv = [str(ROOT / "tools" / "preview.py"), "--quick"]
G = {"__file__": str(ROOT / "tools" / "preview.py"), "__name__": "ffield_bench"}
exec(compile(_src, "preview.py", "exec"), G)

cpu, mem, LBL, call, cart_bank = G["cpu"], G["cpu_mem"], G["_LBL"], G["call"], G["cart_bank"]
C = G["asm_consts"]("main.s", "hud_game.s", "radar.s", "foes.s", "shots.s", "physics.s", "satn.s",
                    "emp.s", "shield.s", "gate.s", "base.s", "empmine.s", "freight.s",
                    "ffield.s")
FF_R = C["FF_R"]
random.seed(1123)
fails = []


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    if detail:
        print(f"        {detail}")
    if not ok:
        fails.append(name)


def rd(a):
    """A read of the RAM itself, the window's ROM out of the way."""
    save = cart_bank[0]
    cart_bank[0] &= 0x7F
    v = mem[a]
    cart_bank[0] = save
    return v


def wr(a, v):
    mem[a] = v & 0xFF


def rd16(a, b=None):
    lo, hi = rd(a), rd(a + 1 if b is None else b)
    return lo | hi << 8


def wr16(a, v, b=None):
    wr(a, v)
    wr(a + 1 if b is None else b, v >> 8)


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def wcall(name, x=None):
    """win_off, the routine, win_on - cart_frame's bracket. Returns (cycles of
    the routine alone, carry)."""
    call(cpu, LBL["win_off"])
    if x is not None:
        cpu.x = x
    n = call(cpu, LBL[name])
    carry = cpu.p & 1
    call(cpu, LBL["win_on"])
    return n, carry


# --- the field in the slots ----------------------------------------------------
call(cpu, LBL["ovl_load_field"])
wr(LBL["WSKIND"], 1)
call(cpu, LBL["ws_sync"])
CX, CY = 0x8000, 0x8000
wr(C["FFON"], 1)
wr16(C["FFCXL"], CX)
wr16(C["FFCYL"], CY)
wr(C["FFVIS"], 1)
wr(C["FFLT"], 0)
wr(C["FFHC"], 0)
wr(C["BSON"], 0)
wr(C["FRTN"], 0)


def true_d(x, y):
    """The true signed distance of a world point from the edge, > 0 outside."""
    dx, dy = s16(x - CX), s16(y - CY)
    return math.hypot(dx, dy) - FF_R


def on_edge(theta, u):
    """The world point at bearing theta (radians, the ship's convention:
    forward (sin, -cos)) and u units outside the edge."""
    r = FF_R + u
    return (round(CX + r * math.sin(theta)) & 0xFFFF,
            round(CY - r * math.cos(theta)) & 0xFFFF)


print("FORCE FIELD (ffield.s)")

# --- ff_f against the true distance ------------------------------------------
errs, wrong_band = [], 0
PM = C["FF_PM"] * 256
for i in range(3000):
    th = random.uniform(0, 2 * math.pi)
    u = random.uniform(-PM - 1500, PM + 1500)
    x, y = on_edge(th, u)
    wr16(C["FFDXL"], s16(x - CX) & 0xFFFF, C["FFDXH"])
    wr16(C["FFDYL"], s16(y - CY) & 0xFFFF, C["FFDYH"])
    _, near = wcall("ff_f")
    t = true_d(x, y)
    if near:
        f = s16(rd16(C["FFFL"], C["FFFH"]))
        errs.append(abs(f - t))
        if abs(t) > PM + 600:
            wrong_band += 1
    elif abs(t) < PM - 600:
        wrong_band += 1
check("ff_f: f is the signed distance from the true circle, all round it",
      max(errs) < 48, f"{len(errs)} in the band: worst |f - true| {max(errs):.1f} units, "
                      f"mean {sum(errs) / len(errs):.1f} (a px is 16)")
check("ff_f: the band takes everything near the edge and nothing far", wrong_band == 0,
      f"{wrong_band} misplaced")

# --- movers: rocks and enemies ------------------------------------------------
BODY_R = [39, 26, 13, 7, 3, 8]


def fly(kind, n_trials, frames):
    """Fly movers at the edge; return (crossings, intrusions, contacts, worst)."""
    cross = intr = contacts = 0
    worst = 1e9
    for t in range(n_trials):
        inside = t % 2 == 1
        th = random.uniform(0, 2 * math.pi)
        if kind == "rock":
            shp = random.randrange(5)
            r = BODY_R[shp] * 32
        else:
            r = C["FF_FOER"]
        u = r + random.uniform(10, 2500)
        x, y = on_edge(th, -u if inside else u)
        sp = random.choice([0.3, 2, 8, 30, 70, 110])        # units a frame
        aim = th + (0 if inside else math.pi) + random.uniform(-1.3, 1.3)
        vx, vy = sp * math.sin(aim), -sp * math.cos(aim)
        vx8 = int(round(vx * 256)) & 0xFFFF
        vy8 = int(round(vy * 256)) & 0xFFFF
        if kind == "rock":
            S, A = 0, dict(XL=C["OBJXL"], XH=C["OBJXH"], XF=C["OBJXF"], YL=C["OBJYL"],
                           YH=C["OBJYH"], YF=C["OBJYF"], VXL=C["OBJVXL"], VXH=C["OBJVXH"],
                           VYL=C["OBJVYL"], VYH=C["OBJVYH"])
            wr(C["OBJSHP"] + S, shp)
        else:
            S, A = 0, dict(XL=C["FOEXL"], XH=C["FOEXH"], XF=C["FOEXF"], YL=C["FOEYL"],
                           YH=C["FOEYH"], YF=C["FOEYF"], VXL=C["FOEVXL"], VXH=C["FOEVXH"],
                           VYL=C["FOEVYL"], VYH=C["FOEVYH"])
        wr(A["XL"] + S, x); wr(A["XH"] + S, x >> 8); wr(A["XF"] + S, 0)
        wr(A["YL"] + S, y); wr(A["YH"] + S, y >> 8); wr(A["YF"] + S, 0)
        wr(A["VXL"] + S, vx8); wr(A["VXH"] + S, vx8 >> 8)
        wr(A["VYL"] + S, vy8); wr(A["VYH"] + S, vy8 >> 8)
        for f in range(frames):
            for ax in ("X", "Y"):                           # objects.s's step, 16.8 + 8.8
                vl, vh = rd(A[f"V{ax}L"] + S), rd(A[f"V{ax}H"] + S)
                p = rd(A[f"{ax}F"] + S) | rd(A[f"{ax}L"] + S) << 8 | rd(A[f"{ax}H"] + S) << 16
                v = (vl | vh << 8) - (0x10000 if vh & 0x80 else 0)
                p = (p + v) & 0xFFFFFF
                wr(A[f"{ax}F"] + S, p); wr(A[f"{ax}L"] + S, p >> 8); wr(A[f"{ax}H"] + S, p >> 16)
            wr(C["FFLT"], 0)
            wcall("ff_rock" if kind == "rock" else "ff_foe", x=S)
            if rd(C["FFLT"]):
                contacts += 1
            px = rd(A["XL"] + S) | rd(A["XH"] + S) << 8
            py = rd(A["YL"] + S) | rd(A["YH"] + S) << 8
            d = true_d(px, py)
            if (d < 0) != inside:
                cross += 1
                break
            g = -d if inside else d
            worst = min(worst, g - r)
            if g < r - 48:
                intr += 1
    return cross, intr, contacts, worst


for kind, n in (("rock", 300), ("foe", 200)):
    cross, intr, contacts, worst = fly(kind, n, 120)
    word = "bounced" if kind == "rock" else "slid"
    check(f"{kind}s: {n} flown at the edge, half from inside - none ever crosses it",
          cross == 0, f"{cross} crossed")
    check(f"{kind}s: ...and none is ever left closer to it than its radius (48 units' grace)",
          intr == 0, f"{intr} frames inside; the closest any centre came: radius {worst:+.0f} units"
                     + (f"; {contacts} contacts lit it" if kind == "rock" else ""))

# --- the ship -------------------------------------------------------------------
wr(C["SHIPINV"], 200)                       # the hits are counted, not paid
wr(C["SHIPGONE"], 0)
SR = C["FF_SHIPR"]
cross = intr = hurts = 0
worst = 1e9
for t in range(160):
    inside = t % 2 == 1
    th = random.uniform(0, 2 * math.pi)
    u = SR + random.uniform(10, 2000)
    x, y = on_edge(th, -u if inside else u)
    sp = random.choice([1, 6, 20, 60, 100, 200])
    aim = th + (0 if inside else math.pi) + random.uniform(-1.2, 1.2)
    vx = int(round(sp * math.sin(aim) * 256)) & 0xFFFFFF
    vy = int(round(-sp * math.cos(aim) * 256)) & 0xFFFFFF
    sx, sy = x << 8, y << 8                  # 16.8
    wr(C["FFHC"], 0)
    for f in range(90):
        for a, v in (("SHX", sx), ("SHY", sy)):
            wr(C[a + "F"], v); wr(C[a + "L"], v >> 8); wr(C[a + "H"], v >> 16)
        for a, v in (("VELX", vx), ("VELY", vy)):   # the throttle holds it there
            wr(C[a + "L"], v); wr(C[a + "H"], v >> 8); wr(C[a + "T"], v >> 16)
        hc0 = rd(C["FFHC"])
        wcall("ff_brake")
        if rd(C["FFHC"]) > hc0:
            hurts += 1
        if rd(C["FFHC"]):
            wr(C["FFHC"], rd(C["FFHC"]) - 1)        # ff_frame's clock
        sx = rd(C["SHXF"]) | rd(C["SHXL"]) << 8 | rd(C["SHXH"]) << 16
        sy = rd(C["SHYF"]) | rd(C["SHYL"]) << 8 | rd(C["SHYH"]) << 16
        sx, sy = (sx + vx) & 0xFFFFFF, (sy + vy) & 0xFFFFFF   # do_ship's step
        d = true_d(sx >> 8, sy >> 8)
        if (d < 0) != inside:
            cross += 1
            break
        g = -d if inside else d
        worst = min(worst, g - SR)
        if g < SR - 48:
            intr += 1
check("the ship: 160 pressed into it for 90 frames, half from inside - never across",
      cross == 0, f"{cross} crossed")
check("...never closer than its radius, and hurt at most once a FF_HURTCD",
      intr == 0 and hurts <= 160 * (90 // C["FF_HURTCD"] + 1),
      f"{intr} frames inside (closest: radius {worst:+.0f}); {hurts} hurts in 14,400 frames")

# a teleport that lands ACROSS the line: put out on the centre's side
bad = 0
for t in range(100):
    th = random.uniform(0, 2 * math.pi)
    u = random.uniform(-SR + 20, SR - 20)
    if abs(u) < 8:
        continue
    x, y = on_edge(th, u)
    for a, v in (("SHX", x << 8), ("SHY", y << 8)):
        wr(C[a + "F"], 0); wr(C[a + "L"], v >> 8); wr(C[a + "H"], v >> 16)
    for a in ("VELX", "VELY"):
        wr(C[a + "L"], 0); wr(C[a + "H"], 0); wr(C[a + "T"], 0)
    wcall("ff_brake")
    d = true_d(rd16(C["SHXL"], C["SHXH"]), rd16(C["SHYL"], C["SHYH"]))
    if (d < 0) != (u < 0) or abs(d) < SR - 48:
        bad += 1
check("the ship landed across the line is put out on its centre's side", bad == 0,
      f"{bad} of 100 wrong")
wr(C["SHIPINV"], 0)

# --- bullets ---------------------------------------------------------------------
for who, fn in (("player's", "ff_shot_p"), ("enemy's", "ff_shot_f")):
    wrong = amb = hits = 0
    for t in range(600):
        th = random.uniform(0, 2 * math.pi)
        u = random.uniform(-700, 700)
        x0, y0 = on_edge(th, u)
        sp = random.uniform(20, 400)
        aim = random.uniform(0, 2 * math.pi)
        vx, vy = int(round(sp * math.sin(aim))), int(round(-sp * math.cos(aim)))
        x1, y1 = (x0 + vx) & 0xFFFF, (y0 + vy) & 0xFFFF
        d0, d1 = true_d(x0, y0), true_d(x1, y1)
        if min(abs(d0), abs(d1)) < 24:
            amb += 1
            continue
        want = (d0 < 0) != (d1 < 0)
        if who == "player's":
            P = dict(XL=C["SHTXL"], XH=C["SHTXH"], YL=C["SHTYL"], YH=C["SHTYH"],
                     VXH=C["SHTVXH"], VXT=C["SHTVXT"], VYH=C["SHTVYH"], VYT=C["SHTVYT"])
            wr(C["SHTLIVE"], 1)
        else:
            P = dict(XL=C["FSXL"], XH=C["FSXH"], YL=C["FSYL"], YH=C["FSYH"],
                     VXH=C["FSVXH"], VXT=C["FSVXT"], VYH=C["FSVYH"], VYT=C["FSVYT"])
            wr(C["FSI"], 0)
        wr(P["XL"], x1); wr(P["XH"], x1 >> 8); wr(P["YL"], y1); wr(P["YH"], y1 >> 8)
        wr(P["VXH"], vx); wr(P["VXT"], vx >> 8); wr(P["VYH"], vy); wr(P["VYT"], vy >> 8)
        _, got = wcall(fn, x=0)
        hits += got
        if bool(got) != want:
            wrong += 1
    check(f"bullets, the {who}: a step that crosses the edge is spent, one that does not "
          f"flies on", wrong == 0,
          f"{wrong} wrong of {600 - amb} ({hits} spent; {amb} within 24 units of it skipped)")

# --- the drawing: a real frame, its DOT_POLYGONs turned as the GPU turns them ------
def run_frame():
    mem[G["JOY1_PREV"]] = mem[G["JOY1"]] = mem[G["JOY1_PRESS"]] = 0
    call(cpu, G["API_GPU_BEGIN"])
    call(cpu, G["CART_FRAME"])
    call(cpu, G["API_GPU_END"])
    end = mem[0x04] | (mem[0x05] << 8)
    return bytes(mem[G["PPRAM"] + i] for i in range(end - G["PPRAM"] + 1))


def pieces(stream):
    """The field's pieces: OPEN five-vertex DOT_POLYGONs, as half-res points."""
    out = []
    for op, pl in G["decode"](stream):
        if op == 0x4C and pl[6] == 0x85:
            cx, cy = G["s16"](pl[0], pl[1]), G["s16"](pl[2], pl[3])
            m = G["pg_matrix"](pl[4], pl[5])
            out.append([G["pg_vertex"](G["sb8"](pl[7 + 2 * j]), G["sb8"](pl[8 + 2 * j]),
                                       cx, cy, *m) for j in range(5)])
    return out


wr(C["FFVIS"], 1)
wr(C["SHIPINV"], 200)
seen = joins = bad_joins = 0
worst_join = 0.0
curv_bad = 0
for th, head in ((0.4, 0), (2.0, 77), (4.1, 160), (5.5, 230)):
    x, y = on_edge(th, 2600)
    for a, v in (("SHX", x << 8), ("SHY", y << 8)):
        wr(C[a + "F"], 0); wr(C[a + "L"], v >> 8); wr(C[a + "H"], v >> 16)
    wr(C["HEAD"], head)
    st = None
    for f in range(3):
        st = run_frame()
    ps = pieces(st)
    seen += len(ps)
    ends = [(p[0], p[-1]) for p in ps]
    for i, (a0, a1) in enumerate(ends):          # every piece's ends meet another's
        for j, (b0, b1) in enumerate(ends):
            if i != j:
                d = min(math.dist(a1, b0), math.dist(a0, b1))
                if d < 20:
                    joins += 1
                    worst_join = max(worst_join, d)
    for p in ps:                                  # ...and it is bent: its middle stands
        mid = p[2]                                #   off its chord (a template bent the
        c0, c1 = p[0], p[4]                       #   wrong way fails the joins above)
        side = (c1[0] - c0[0]) * (mid[1] - c0[1]) - (c1[1] - c0[1]) * (mid[0] - c0[0])
        if abs(side) < 1:
            curv_bad += 1
check("the drawing: visible near the edge, the pieces are on the frame", seen >= 4,
      f"{seen} pieces over four headings")
check("...and they meet end to end, as one curve", joins >= 2 and worst_join < 3,
      f"{joins} joins, the worst {worst_join:.1f} half-res px apart")
check("...and every one is bent, not straight", curv_bad == 0, f"{curv_bad} straight")
wr(C["SHIPINV"], 0)

# --- the costs --------------------------------------------------------------------
def cyc_rock(u, sp_in):
    x, y = on_edge(1.0, u)
    wr(C["OBJSHP"], 1)
    wr(C["OBJXL"], x); wr(C["OBJXH"], x >> 8); wr(C["OBJYL"], y); wr(C["OBJYH"], y >> 8)
    v = int(round(-sp_in * math.sin(1.0) * 256)) & 0xFFFF
    w = int(round(sp_in * math.cos(1.0) * 256)) & 0xFFFF
    wr(C["OBJVXL"], v); wr(C["OBJVXH"], v >> 8); wr(C["OBJVYL"], w); wr(C["OBJVYH"], w >> 8)
    return wcall("ff_rock", x=0)[0]


far = cyc_rock(9000, 2)
band = cyc_rock(1500, 2)
hit = cyc_rock(820, 40)
print(f"        ff_rock: {far} cycles far from the edge, {band} in the band, {hit} bouncing")

# the frame, near the edge: visible, then a flash on an invisible field
x, y = on_edge(0.3, 1500)
for a, v in (("SHX", x << 8), ("SHY", y << 8)):
    wr(C[a + "F"], 0); wr(C[a + "L"], v >> 8); wr(C[a + "H"], v >> 16)
call(cpu, LBL["do_camera"]) if "do_camera" in LBL else None
vis, _ = wcall("ff_frame")
wr(C["FFVIS"], 0)
wr(C["FFLT"], 10)
wr(C["FFLK"], 19)
fl, _ = wcall("ff_frame")
wr(C["FFLT"], 0)
inv, _ = wcall("ff_frame")
wr(C["FFVIS"], 1)
print(f"        ff_frame: {vis} cycles visible at the edge, {fl} flashing, {inv} invisible")
check("ff_frame runs visible, flashing and invisible", vis > inv and fl > inv)

# --- the level itself: FORCE FIELD TEST through the real loader -------------------
# Its ship starts on HEAD 128 - which was lb_state's own "not a heading" marker for
# the rotation tables, so they were never built and the first frames drew the
# whole field on the ship (the user's madsim dump at frame 190).
wr(C["CURLEV"], 2)
call(cpu, LBL["ovl_load_field"])
call(cpu, LBL["win_off"])
call(cpu, LBL["level_begin"])
call(cpu, LBL["win_on"])
ok_load = (rd(LBL["WSCUR"]) == 1 and rd(C["FFON"]) == 1 and rd(C["HEAD"]) == 128)
st = run_frame()
rot = any(rd(C["ROTC_I"] + i) for i in range(256))
ps = pieces(st)
cxs = set()
for op, pl in G["decode"](st):
    if op == 0x4C and pl[6] == 0x85:
        cxs.add((G["s16"](pl[0], pl[1]), G["s16"](pl[2], pl[3])))
check("level 2 from level_begin: the field in the slots, the ship on HEAD 128",
      ok_load, f"WSCUR {rd(LBL['WSCUR'])} FFON {rd(C['FFON'])} HEAD {rd(C['HEAD'])}")
check("...and its first frame has rotation tables and pieces at distinct anchors",
      rot and len(cxs) == len(ps) and len(ps) >= 2, f"{len(ps)} pieces at {sorted(cxs)}")

print()
if fails:
    print(f"{len(fails)} check(s) failed")
    sys.exit(1)
print("all force field checks passed")
