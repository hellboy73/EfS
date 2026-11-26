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
                    "enemies.s", "ffield.s")
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
# The loads are STAGED (overlay.s ld_pump): ovl_load_field and ws_sync only queue
# their rows, and ld_pump copies them over the following frames. ws_sync is
# loader code (LDCODE), run with the window on the loader's bank as ld_enter does.
def loads_idle():
    return not (rd(LBL["lj_qn"]) or rd(LBL["lj_act"]) or rd(LBL["lj_row"] + 5)
                or rd(LBL["lj_row"] + 6))


def pump():
    for i in range(400):
        if loads_idle():
            return
        call(cpu, LBL["ld_pump"])
    raise RuntimeError("ld_pump never finished")


def ld_call(name):
    call(cpu, LBL["win_off"])
    cpu.a = 0x80 | 8                            # LDR_BANK | CART_EN
    call(cpu, G["API_CART_BANK"])
    call(cpu, LBL[name])
    call(cpu, LBL["win_on"])


pump()                                          # whatever the boot left queued
wr(LBL["WSKIND"], 1)
ld_call("ws_sync")                              # slot A, and slot B's row patched...
pump()
wr(LBL["overlay_cur"], 1)                       # ...and FIELD loaded afresh, slot B with it
ld_call("ovl_load_field")
pump()
assert rd(LBL["WSCUR"]) == 1 and rd(LBL["ws_tab_bs"] + 18) == 0x4C, "the field is not in the slots"
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
    x, y = on_edge(th, -2600)                   # inside: seen from outside it is invisible
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
x, y = on_edge(0.4, 2600)                       # the same, from OUTSIDE: nothing
for a, v in (("SHX", x << 8), ("SHY", y << 8)):
    wr(C[a + "F"], 0); wr(C[a + "L"], v >> 8); wr(C[a + "H"], v >> 16)
wr(C["HEAD"], 0)
for f in range(3):
    st = run_frame()
out_n = len(pieces(st))
wr(C["FFLT"], C["FF_FLASH"]); wr(C["FFLK"], round(0.4 / (2 * math.pi) * 256))
fl_n = 0
for f in range(2):                              # the strobe: every other frame
    st = run_frame()
    fl_n += sum(1 for op, pl in G["decode"](st) if op == 0x4C and pl[6] == 0x83)
wr(C["FFLT"], 0)
check("a visible field seen from OUTSIDE is not drawn, but still flashes where it is hit",
      out_n == 0 and fl_n == 1, f"{out_n} pieces from outside; {fl_n} flash piece")
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
x, y = on_edge(0.3, -1500)
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

# --- the tower: the circle in the middle ------------------------------------------
TW_R = C["TW_R"]


def at_c(th, r):
    """The world point at bearing th (radians), r units from the centre."""
    return (round(CX + r * math.sin(th)) & 0xFFFF, round(CY - r * math.cos(th)) & 0xFFFF)


def c_dist(x, y):
    return math.hypot(s16(x - CX), s16(y - CY))


def fly_tower(kind, n_trials, frames):
    """Movers flown at the tower from every side, some born inside it: the worst
    any centre came to the tower's circle + its own radius, after the first frame."""
    worst = 1e9
    for t in range(n_trials):
        th = random.uniform(0, 2 * math.pi)
        if kind == "rock":
            shp = random.randrange(5)
            r = BODY_R[shp] * 32
        else:
            r = C["FF_FOER"]
        born_in = t % 5 == 0
        u = random.uniform(0, TW_R + r - 40) if born_in else TW_R + r + random.uniform(10, 1500)
        x, y = at_c(th, u)
        sp = random.choice([0.3, 2, 8, 30, 70, 110])
        aim = th + math.pi + random.uniform(-1.0, 1.0)
        vx8 = int(round(sp * math.sin(aim) * 256)) & 0xFFFF
        vy8 = int(round(-sp * math.cos(aim) * 256)) & 0xFFFF
        if kind == "rock":
            A = dict(XL=C["OBJXL"], XH=C["OBJXH"], XF=C["OBJXF"], YL=C["OBJYL"],
                     YH=C["OBJYH"], YF=C["OBJYF"], VXL=C["OBJVXL"], VXH=C["OBJVXH"],
                     VYL=C["OBJVYL"], VYH=C["OBJVYH"])
            wr(C["OBJSHP"], shp)
        else:
            A = dict(XL=C["FOEXL"], XH=C["FOEXH"], XF=C["FOEXF"], YL=C["FOEYL"],
                     YH=C["FOEYH"], YF=C["FOEYF"], VXL=C["FOEVXL"], VXH=C["FOEVXH"],
                     VYL=C["FOEVYL"], VYH=C["FOEVYH"])
        wr(A["XL"], x); wr(A["XH"], x >> 8); wr(A["XF"], 0)
        wr(A["YL"], y); wr(A["YH"], y >> 8); wr(A["YF"], 0)
        wr(A["VXL"], vx8); wr(A["VXH"], vx8 >> 8); wr(A["VYL"], vy8); wr(A["VYH"], vy8 >> 8)
        for f in range(frames):
            for ax in ("X", "Y"):
                vl, vh = rd(A[f"V{ax}L"]), rd(A[f"V{ax}H"])
                p = rd(A[f"{ax}F"]) | rd(A[f"{ax}L"]) << 8 | rd(A[f"{ax}H"]) << 16
                v = (vl | vh << 8) - (0x10000 if vh & 0x80 else 0)
                p = (p + v) & 0xFFFFFF
                wr(A[f"{ax}F"], p); wr(A[f"{ax}L"], p >> 8); wr(A[f"{ax}H"], p >> 16)
            wcall("ff_rock" if kind == "rock" else "ff_foe", x=0)
            d = c_dist(rd(A["XL"]) | rd(A["XH"]) << 8, rd(A["YL"]) | rd(A["YH"]) << 8)
            if f > 0:
                worst = min(worst, d - TW_R - r)
    return worst


wr(C["TWST"], 0)
for kind, n in (("rock", 300), ("foe", 200)):
    worst = fly_tower(kind, n, 60)
    check(f"the tower: {n} {kind}s flown at it (a fifth born inside it) - none is ever left in it",
          worst > -48, f"the closest any centre came: its radius {worst:+.0f} units")

wr(C["SHIPINV"], 200)
SR = C["FF_SHIPR"]
worst, hurts, lit = 1e9, 0, 0
for t in range(120):
    th = random.uniform(0, 2 * math.pi)
    u = random.uniform(10, TW_R + SR - 40) if t % 4 == 0 else TW_R + SR + random.uniform(10, 1500)
    x, y = at_c(th, u)
    sp = random.choice([1, 6, 20, 60, 100])
    aim = th + math.pi + random.uniform(-1.0, 1.0)
    vx = int(round(sp * math.sin(aim) * 256)) & 0xFFFFFF
    vy = int(round(-sp * math.cos(aim) * 256)) & 0xFFFFFF
    sx, sy = x << 8, y << 8
    wr(C["FFHC"], 0); wr(C["FFLT"], 0)
    for f in range(60):
        for a, v in (("SHX", sx), ("SHY", sy)):
            wr(C[a + "F"], v); wr(C[a + "L"], v >> 8); wr(C[a + "H"], v >> 16)
        for a, v in (("VELX", vx), ("VELY", vy)):
            wr(C[a + "L"], v); wr(C[a + "H"], v >> 8); wr(C[a + "T"], v >> 16)
        wcall("ff_brake")
        hurts += rd(C["FFHC"]) != 0
        lit += rd(C["FFLT"]) != 0
        sx = rd(C["SHXF"]) | rd(C["SHXL"]) << 8 | rd(C["SHXH"]) << 16
        sy = rd(C["SHYF"]) | rd(C["SHYL"]) << 8 | rd(C["SHYH"]) << 16
        sx, sy = (sx + vx) & 0xFFFFFF, (sy + vy) & 0xFFFFFF
        worst = min(worst, c_dist(sx >> 8, sy >> 8) - TW_R - SR)
check("the tower: the ship pressed into it (a quarter landed inside) slides on it - never in,"
      " never hurt, no flash", worst > -48 and hurts == 0 and lit == 0,
      f"closest: its radius {worst:+.0f} units; {hurts} hurts, {lit} flashes")
wr(C["SHIPINV"], 0)

wrong = 0
for t in range(400):
    th = random.uniform(0, 2 * math.pi)
    x0, y0 = at_c(th, random.uniform(TW_R + 30, TW_R + 900))
    tin = t % 2 == 0                            # half end inside it, half stay out
    x1, y1 = at_c(th + random.uniform(-0.3, 0.3), random.uniform(0, TW_R - 30) if tin else
                  random.uniform(TW_R + 30, TW_R + 900))
    vx, vy = s16(x1 - x0), s16(y1 - y0)
    if abs(vx) > 900 or abs(vy) > 900:
        continue
    wr(C["SHTLIVE"], 1)
    wr(C["SHTXL"], x1); wr(C["SHTXH"], x1 >> 8); wr(C["SHTYL"], y1); wr(C["SHTYH"], y1 >> 8)
    wr(C["SHTVXH"], vx); wr(C["SHTVXT"], vx >> 8); wr(C["SHTVYH"], vy); wr(C["SHTVYT"], vy >> 8)
    _, got = wcall("ff_shot_p", x=0)
    wrong += bool(got) != tin
check("the tower: a bullet that ends in it is spent, one that stays out flies on", wrong == 0,
      f"{wrong} wrong")

# the field is DOWN while the tower is: a rock sitting across the edge stays where it is
wr(C["TWST"], 5)
moved = 0
for t in range(40):
    x, y = on_edge(random.uniform(0, 6.28), 100)
    wr(C["OBJSHP"], 2)
    for ax, v in (("X", x), ("Y", y)):
        wr(C[f"OBJ{ax}L"], v); wr(C[f"OBJ{ax}H"], v >> 8); wr(C[f"OBJ{ax}F"], 0)
        wr(C[f"OBJV{ax}L"], 0); wr(C[f"OBJV{ax}H"], 0)
    wcall("ff_rock", x=0)
    moved += (rd16(C["OBJXL"], C["OBJXH"]), rd16(C["OBJYL"], C["OBJYH"])) != (x, y)
check("while the tower is down the edge stops nothing", moved == 0, f"{moved} put back")
wr(C["TWST"], 0)

# the EMP: the count, once, on the rocks inside
save = {k: [rd(C[k] + i) for i in range(255)] for k in ("OBJSHP", "OBJXH", "OBJYH")}


def emp_hit(rocks, k=20, ship=(CX + 0x1000, CY)):
    """rocks = [(slot, shp, x, y)]; the ship at `ship`, the reach K pages: TWST after."""
    for i in range(255):
        wr(C["OBJSHP"] + i, 0xFF)
    for sl, shp, x, y in rocks:
        wr(C["OBJSHP"] + sl, shp); wr(C["OBJXH"] + sl, x >> 8); wr(C["OBJYH"] + sl, y >> 8)
    wr16(C["SHXL"], ship[0], C["SHXH"]); wr16(C["SHYL"], ship[1], C["SHYH"])
    wr(C["EMK"], k)
    wr(C["TWST"], 0)
    n, _ = wcall("ff_emp")
    return rd(C["TWST"]), n


inside = at_c(1.0, FF_R - 900)
outside = at_c(1.0, FF_R + 900)
cases = [("no rock at all", [], 0xFF),
         ("a 192 inside", [(200, 0, *inside)], C["TW_DOWN"]),
         ("only 16s inside (slot 0) - they do not count", [(0, 4, *inside)], 0xFF),
         ("a 32 inside (slot 0)", [(0, 3, *inside)], C["TW_DOWN"]),
         ("rocks only outside", [(7, 0, *outside), (254, 3, *outside)], 0xFF)]
bad = []
for name, rk, want in cases:
    got = emp_hit(rk)[0]
    if got != want:
        bad.append(f"{name}: {got}")
st_out, _ = emp_hit([(3, 1, *inside)], k=8)                 # the ring not there yet
st_far, _ = emp_hit([(3, 1, *inside)], ship=(CX + 0x5000, CY))
_, ncyc = emp_hit([])
check("the EMP: rocks inside -> down for TW_DOWN, none (the 16s do not count) -> dead for good;"
      " out of its reach, nothing", not bad and st_out == 0 and st_far == 0,
      f"{bad or 'all four cases right'}; short ring TWST {st_out}, far ship TWST {st_far}")
print(f"        ff_emp: {ncyc} cycles for the count over all 255 slots")
for k, v in save.items():
    for i in range(255):
        wr(C[k] + i, v[i])

# the drawing and the sparks, from near the middle, HEAD 0
x, y = at_c(2.0, 3000)
for a, v in (("SHX", x << 8), ("SHY", y << 8)):
    wr(C[a + "F"], 0); wr(C[a + "L"], v >> 8); wr(C[a + "H"], v >> 16)
wr(C["HEAD"], 0)


def tower_cmds(st):
    return [(op, pl) for op, pl in G["decode"](st) if op in (0x4C, 0x4E) and pl[6] in (0x86, 0x82)]


draws = {}
for name, tws in (("up", 0), ("down", 50), ("dead", 0xFF)):
    wr(C["TWST"], tws); wr(C["TWSP"], 200)
    for f in range(2):
        st = run_frame()
    draws[name] = tower_cmds(st)
shape = {k: [(op, pl[6]) for op, pl in v] for k, v in draws.items()}
check("the tower drawn: up solid (POLYGON16, both parts), down dotted (both), dead dotted"
      " without its last part",
      shape["up"] == [(0x4E, 0x86), (0x4E, 0x82)] and shape["down"] == [(0x4C, 0x86), (0x4C, 0x82)]
      and shape["dead"] == [(0x4C, 0x86)], str(shape))

# the spark is where the missing part is: its middle on the screen, from the down drawing
sp_bad = []
for twan in (0, 37, 100, 190):
    wr(C["TWST"], 0xFF); wr(C["TWSP"], 1); wr(C["TWAN"], twan)
    wr(C["FRAME"], 1)                           # no spin this frame
    wcall("ff_frame")
    ex = s16(rd16(C["EXTXL"], C["EXTXH"]) - CX)
    ey = s16(rd16(C["EXTYL"], C["EXTYH"]) - CY)
    wr(C["TWST"], 50); wr(C["TWAN"], twan); wr(C["FRAME"], 1)
    st = run_frame()
    cm = [pl for op, pl in tower_cmds(st) if pl[6] == 0x82]
    if not cm:
        sp_bad.append(f"{twan}: no part")
        continue
    pl = cm[0]
    cx, cy = G["s16"](pl[0], pl[1]), G["s16"](pl[2], pl[3])
    m = G["pg_matrix"](pl[4], pl[5])
    v = [G["pg_vertex"](G["sb8"](pl[7 + 2 * j]), G["sb8"](pl[8 + 2 * j]), cx, cy, *m)
         for j in range(2)]
    mx, my = (v[0][0] + v[1][0]) / 2 - cx, (v[0][1] + v[1][1]) / 2 - cy   # half-res px
    a_draw = math.atan2(my, mx)
    a_spark = math.atan2(-ex, ey)                # fb = (world y, -world x) at HEAD 0
    da = abs((a_draw - a_spark + math.pi) % (2 * math.pi) - math.pi)
    if da > 0.15:
        sp_bad.append(f"{twan}: {math.degrees(da):.0f} deg off")
# the radar mark: four dots, blinking with the enemies while it stands, steady dead
def marks(st):
    """The 2x2 squares among the list's four-dot DOT_PIXELS (a puff can be four)."""
    out = []
    for op, pl in G["decode"](st):
        if op == 0x47 and pl[0] == 4:
            pts = sorted((pl[1 + 2 * j], pl[2 + 2 * j]) for j in range(4))
            x, y = pts[0]
            if pts == [(x, y), (x, y + 1), (x + 1, y), (x + 1, y + 1)]:
                out.append(pl)
    return out


mk = {}
for name, tws in (("up", 0), ("dead", 0xFF)):
    wr(C["TWST"], tws); wr(C["TWSP"], 200)
    mk[name] = sum(1 for f in range(20) if marks(run_frame()))   # one blink cycle
check("the tower on the radar: a 2x2 mark, blinking while it stands, steady once dead",
      mk["up"] == C["RAD_BLINK_ON"] and mk["dead"] == 20,
      f"frames of 20 with the mark: {mk['up']} up, {mk['dead']} dead")

check("the dead tower sparks where its last part was", not sp_bad and rd(C["TWSP"]) > 0,
      str(sp_bad) if sp_bad else "four spins, each within 9 degrees")
wr(C["TWST"], 0)

# the GPU's price of the tower, up, down and dead, through the real GPU OS
from py65.devices.mpu65c02 import MPU as _MPU
_gm = bytearray(0x10000)
_gm[0xC000:] = G["GPU_ROM"]
_gpu = _MPU(memory=_gm)


def gpu_cost(cmds):
    out = []
    for cmd in ([], cmds):
        s = [0] + cmd + [0]
        _gm[G["PPRAM"]:G["PPRAM"] + len(s)] = bytes(s)
        _gm[3] = (G["PPRAM"] + 1) & 0xFF
        _gm[4] = (G["PPRAM"] + 1) >> 8
        _gpu.pc = G["DISPATCH"]
        c0 = _gpu.processorCycles
        while _gm[_gpu.pc] != 0xCB:
            _gpu.step()
        out.append(_gpu.processorCycles - c0)
    return out[1] - out[0]


gc = {k: gpu_cost(sum(([op] + list(pl) for op, pl in v), [])) for k, v in draws.items()}
print(f"        the tower on the GPU: {gc['up']} cycles up (solid), {gc['down']} down, "
      f"{gc['dead']} dead")

# --- the level itself: FORCE FIELD TEST through the real loader -------------------
# Its ship starts on HEAD 128 - which was lb_state's own "not a heading" marker for
# the rotation tables, so they were never built and the first frames drew the
# whole field on the ship (the user's madsim dump at frame 190).
wr(C["CURLEV"], 2)
ld_call("ovl_load_field")
pump()
ld_call("ld_level_begin")                       # the whole sector, synchronously (as
ld_call("ws_sync")                              #   power-on's), then its tenant, as
pump()                                          #   ld_enter does, and the copies
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
check("...and its first frame has rotation tables, and no field: the ship starts outside it",
      rot and len(ps) == 0, f"rotation tables {'built' if rot else 'MISSING'}; {len(ps)} pieces")

print()
if fails:
    print(f"{len(fails)} check(s) failed")
    sys.exit(1)
print("all force field checks passed")
