"""The ghosts' bench (src/ghosts.s, open_questions.md F10 GHOSTS): py65, the real
routines out of cart.bin, called by name.

    python tools/ghosts_bench.py          (make first: it reads cart.bin)

It boots the cartridge the way tools/preview.py does, then loads level 3, GHOST
TEST, through the real loader (level_begin, ws_sync, the staged copies) and flies
real frames over it, reading the command list each one builds:

  the load      the ghost tenant in the wall slots, the dormant enemies on the
                ghosts' list and in no enemy slot, the ghost rocks marked
  rock ghosts   invisible far, strobed near (every other frame), revealed by a
                hit or a bump and then drawn wherever, irregularly; broken, two
                ordinary rocks
  enemy ghosts  strobed near, dying away once the ship has gone, one drawn a
                frame, no enemy slot and nothing on the radar; woken, enemies
  the others    levels 0 and 2 still put their own tenants in the slots

and what they cost, CPU1 and GPU. Exit status 1 if any check fails.
"""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
_src = (ROOT / "tools" / "preview.py").read_text(encoding="utf-8")
_src = _src[:_src.index("\nframes = []")]
sys.argv = [str(ROOT / "tools" / "preview.py"), "--quick"]
G = {"__file__": str(ROOT / "tools" / "preview.py"), "__name__": "ghosts_bench"}
exec(compile(_src, "preview.py", "exec"), G)

cpu, mem, LBL, call, cart_bank = G["cpu"], G["cpu_mem"], G["_LBL"], G["call"], G["cart_bank"]
C = G["asm_consts"]("main.s", "hud_game.s", "radar.s", "foes.s", "shots.s", "physics.s", "satn.s",
                    "emp.s", "shield.s", "gate.s", "base.s", "empmine.s", "freight.s",
                    "enemies.s", "ffield.s", "ghosts.s", "objects.s")
fails = []


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    if detail:
        print(f"        {detail}")
    if not ok:
        fails.append(name)


def rd(a):
    save = cart_bank[0]
    cart_bank[0] &= 0x7F
    v = mem[a]
    cart_bank[0] = save
    return v


def wr(a, v):
    mem[a] = v & 0xFF


def wcall(name, x=None, a=None):
    call(cpu, LBL["win_off"])
    if x is not None:
        cpu.x = x
    if a is not None:
        cpu.a = a
    n = call(cpu, LBL[name])
    call(cpu, LBL["win_on"])
    return n


def loads_idle():
    return not (rd(LBL["lj_qn"]) or rd(LBL["lj_act"]) or rd(LBL["lj_row"] + 5)
                or rd(LBL["lj_row"] + 6))


def pump():
    for _ in range(400):
        if loads_idle():
            return
        call(cpu, LBL["ld_pump"])
    raise RuntimeError("ld_pump never finished")


def ld_call(name):
    call(cpu, LBL["win_off"])
    cpu.a = 0x80 | 8
    call(cpu, G["API_CART_BANK"])
    call(cpu, LBL[name])
    call(cpu, LBL["win_on"])
    cpu.a = 0x80                                # ...and bank 0 back in the window,
    call(cpu, G["API_CART_BANK"])               #   as ld_enter leaves it


def load(level):
    wr(C["CURLEV"], level)
    wr(LBL["overlay_cur"], 1)                   # FIELD loaded afresh, as the
    ld_call("ovl_load_field")                   #   field's bench does
    pump()
    ld_call("ld_level_begin")
    ld_call("ws_sync")
    pump()


def run_frame():
    mem[G["JOY1_PREV"]] = mem[G["JOY1"]] = mem[G["JOY1_PRESS"]] = 0
    mem[G["JOY1_PREV"] + 1] = mem[G["JOY1"] + 1] = mem[G["JOY1_PRESS"] + 1] = 0
    call(cpu, G["API_GPU_BEGIN"])
    c0 = cpu.processorCycles
    call(cpu, G["CART_FRAME"])
    c = cpu.processorCycles - c0
    call(cpu, G["API_GPU_END"])
    end = mem[0x04] | (mem[0x05] << 8)
    return bytes(mem[G["PPRAM"] + i] for i in range(end - G["PPRAM"] + 1)), c


def dots(stream):
    """Every DOT_POLYGON in the list: (centre, N byte)."""
    return [((G["s16"](pl[0], pl[1]), G["s16"](pl[2], pl[3])), pl[6])
            for op, pl in G["decode"](stream) if op == 0x4C]


def put_ship(x, y, head=0):
    for a, v in (("SHX", x), ("SHY", y)):
        wr(C[a + "F"], 0)
        wr(C[a + "L"], v)
        wr(C[a + "H"], v >> 8)
    wr(C["HEAD"], head)
    for a in ("VELXL", "VELXH", "VELYL", "VELYH"):
        if a in C:
            wr(C[a], 0)


def irregular(v):
    """Not the old every-other-frame rhythm: some frames lit twice running, or
    dark twice running, and neither all nor none."""
    return 0 < sum(v) < len(v) and any(v[i] == v[i + 1] for i in range(len(v) - 1))


def longest_dark(v):
    """The longest run of dark frames, round the cycle: a fluorescent tube's
    flicker has a long one."""
    best = run = 0
    for x in v + v:
        run = 0 if x else run + 1
        best = max(best, run)
    return min(best, len(v))


def frames(n):
    out = []
    for _ in range(n):
        st, _c = run_frame()
        out.append(dots(st))
    return out


# --- the load ---------------------------------------------------------------------
pump()
load(3)
nrock = rd(C["NROCK"])
ghosts = [i for i in range(nrock) if rd(C["OBJTYPE"] + i) & 0x80]
GHN = LBL["GHN"]
gh = [(rd(C["GHXH"] + i), rd(C["GHYH"] + i), rd(C["GHK"] + i)) for i in range(rd(GHN))]
check("level 3 from level_begin: the ghosts in the wall slots",
      rd(LBL["WSCUR"]) == 2 and rd(LBL["ws_tab_bs"] + 21) == 0x4C,
      f"WSCUR {rd(LBL['WSCUR'])}, WS_GROCK opcode ${rd(LBL['ws_tab_bs'] + 21):02X}")
check("...four dormant enemies on the ghosts' list, none in an enemy slot",
      rd(GHN) == 4 and rd(C["NFOE"]) == 0
      and sorted(k for _, _, k in gh) == [0, 1, 2, 3],
      f"GHN {rd(GHN)}, NFOE {rd(C['NFOE'])}, list {gh}")
check("...and four ghost rocks, the rest ordinary", len(ghosts) == 4,
      f"{len(ghosts)} of {nrock} rocks with GH_ROCK")

# --- rock ghosts --------------------------------------------------------------------
wr(GHN, 0)                                      # the enemy ghosts out of the way
wr(C["SHIPINV"], 250)
big = [i for i in ghosts if rd(C["OBJSHP"] + i) == 0][0]   # the 192 at (32768, 28672)
bx, by = rd(C["OBJXH"] + big), rd(C["OBJYH"] + big)
put_ship(bx << 8 | 0x80, (by + 11) << 8)        # 11 pages off: on the screen, not near
far = frames(8)
put_ship(bx << 8 | 0x80, (by + 6) << 8)         # 6 pages: near
near = frames(32)
check("a rock ghost far from the ship is not drawn",
      sum(len(f) for f in far) == 0, f"{sum(len(f) for f in far)} DOT_POLYGONs in 8 frames")
nf = [len(f) > 0 for f in near]
check("...and near it, it strobes, irregularly",
      irregular(nf) and 7 <= sum(nf) <= 16 and longest_dark(nf) >= 5, f"{sum(nf)} of 32 frames: {''.join('#' if v else '.' for v in nf)}")
hp = rd(C["OBJHP"] + big)
put_ship(bx << 8 | 0x80, (by + 11) << 8)
wcall("rock_take_hit", x=big, a=C["HIT_HP"])
rev = [len(f) > 0 for f in frames(48)]
check("...hit, it is drawn far as well, irregularly",
      10 <= sum(rev) <= 24 and rd(C["OBJHP"] + big) < hp
      and any(rev[i] == rev[i + 1] for i in range(47)),
      f"{sum(rev)} of 48 frames; HP {hp} -> {rd(C['OBJHP'] + big)}")
other = [i for i in ghosts if i != big and rd(C["OBJSHP"] + i) == 2][0]
wcall("gh_reveal", x=other)
check("a bump marks it found out (GH_SEEN), the variant kept",
      rd(C["OBJTYPE"] + other) == 0x80 | 0x40 | 2, f"OBJTYPE ${rd(C['OBJTYPE'] + other):02X}")
free0 = rd(C["NROCK"])
wcall("rock_take_hit", x=big, a=250)
kids = [i for i in range(max(free0, rd(C["NROCK"])))
        if rd(C["OBJSHP"] + i) == 1 and not rd(C["OBJTYPE"] + i) & 0xC0]
check("...broken, the 192 is two ordinary 128s, no ghost bit",
      rd(C["OBJSHP"] + big) == 1 and not rd(C["OBJTYPE"] + big) & 0xC0 and len(kids) >= 4,
      f"its slot: class {rd(C['OBJSHP'] + big)}, OBJTYPE ${rd(C['OBJTYPE'] + big):02X}; "
      f"ordinary 128s now {len(kids)} (2 were placed + the scatter's)")

# --- enemy ghosts -------------------------------------------------------------------
load(3)
wr(C["SHIPINV"], 250)
ufo = [i for i in range(4) if rd(C["GHK"] + i) == 0][0]
ux, uy = rd(C["GHXH"] + ufo), rd(C["GHYH"] + ufo)
put_ship(ux << 8 | 0x80, (uy - 6) << 8)         # 6 pages: near, ahead of a ship on HEAD 0? -
f_near = frames(32)                              #   it is behind; drawn either way if on screen
put_ship(ux << 8 | 0x80, (uy - 11) << 8, 128)   # 11 pages, facing it: on the screen, not near
t0 = rd(C["GHT"] + ufo)
fade = frames(40)
fn = [len(f) for f in f_near]
fd = [len(f) > 0 for f in fade]
fl = [n > 0 for n in fn]
check("an enemy ghost near the ship strobes irregularly, its whole shape (5 parts)",
      irregular(fl) and 7 <= sum(fl) <= 16 and longest_dark(fl) >= 5 and set(fn) <= {0, 5},
      f"{sum(fl)} of 32 frames: {''.join('#' if v else '.' for v in fl)}")
check("...and dies away once the ship has gone, as the field's flash does",
      t0 == C["GH_FLASH"] and 3 <= sum(fd) <= 18 and not any(fd[C["GH_FLASH"] + 1:]),
      f"timer {t0} on leaving; drawn on {sum(fd)} of 40 frames, the last at "
      f"{max([i for i, v in enumerate(fd) if v], default=-1)}")
check("...from no enemy slot", rd(C["NFOE"]) == 0, f"NFOE {rd(C['NFOE'])}")
for i in range(4):                              # all four piled round the ship
    wr(C["GHXH"] + i, 0x80 + (i & 1) * 2)
    wr(C["GHYH"] + i, 0x7C + (i >> 1) * 2)
put_ship(0x8100, 0x7D00)
many, turn = [], set()
for _ in range(48):
    many += frames(1)
    if many[-1]:
        turn.add(rd(C["GHI"]))                  # which one it was
drawn = [len({c for c, _ in f}) for f in many]
every = len(turn)
check("four near at once: at most one drawn a frame, each in its turn",
      max(drawn) == 1 and sum(drawn) >= 12 and every == 4,
      f"{sum(drawn)} of 48 frames drew one, never more; {every} different ghosts")
cyc = wcall("gh_frame")
print(f"        gh_frame, four ghosts near: {cyc} cycles")
wcall("gh_wake")
kinds = sorted(rd(C["FOEKIND"] + i) for i in range(rd(C["NFOE"])))
check("woken: four enemies in slots, the list empty",
      rd(C["NFOE"]) == 4 and kinds == [0, 1, 2, 3] and rd(GHN) == 0
      and all(rd(C["FOEST"] + i) for i in range(4)),
      f"NFOE {rd(C['NFOE'])}, kinds {kinds}, GHN {rd(GHN)}")

# --- the shake: the picture jumps, the position does not -------------------------
if "gh_jit" in LBL:
    zp = C["CX2L"]
    deltas = []
    for f in range(8):
        wr(C["FRAME"], f)
        for i, v in enumerate((0x34, 0x01, 0x78, 0x00)):
            wr(zp + i, v)
        wcall("gh_jit", x=zp, a=5)
        dx = (rd(zp) | rd(zp + 1) << 8) - 0x134
        dy = (rd(zp + 2) | rd(zp + 3) << 8) - 0x78
        deltas.append((dx, dy))
    pos0 = [(rd(C["GHXH"] + i), rd(C["GHYH"] + i)) for i in range(4)]
    check("the shake: one px a frame (half-res), never none, a different way each frame",
          all(max(abs(dx), abs(dy)) <= 1 and (dx, dy) != (0, 0) for dx, dy in deltas)
          and len(set(deltas)) == 8, f"half-res px over 8 frames {deltas}")
else:
    print("        (GH_SHAKE is 0: no shake to check)")

# --- the other tenants ----------------------------------------------------------------
load(0)
w0 = rd(LBL["WSCUR"])
load(2)
w2 = rd(LBL["WSCUR"])
check("levels 0 and 2 still take the base and the field", w0 == 0 and w2 == 1,
      f"WSCUR {w0}, {w2}")

# --- the GPU's price ----------------------------------------------------------------
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


load(3)
wr(GHN, 0)
wr(C["SHIPINV"], 250)
big = [i for i in range(rd(C["NROCK"])) if rd(C["OBJTYPE"] + i) & 0x80 and rd(C["OBJSHP"] + i) == 0][0]
bx, by = rd(C["OBJXH"] + big), rd(C["OBJYH"] + big)
put_ship(bx << 8 | 0x80, (by + 6) << 8)
dot = solid = None
for _ in range(32):
    st, _c = run_frame()
    for op, pl in G["decode"](st):
        if op == 0x4C and dot is None:
            dot = [op] + list(pl)
wr(C["OBJTYPE"] + big, rd(C["OBJTYPE"] + big) & 0x03)   # the same rock, ordinary
st, _c = run_frame()
cands = [(op, pl) for op, pl in G["decode"](st) if op == 0x4E and pl[6] & 0x7F > 9]
if cands:
    solid = [cands[0][0]] + list(cands[0][1])
if dot and solid:
    print(f"        the 192 on the GPU: {gpu_cost(dot)} cycles dotted (a ghost), "
          f"{gpu_cost(solid)} solid")

load(3)                                         # an enemy ghost of each kind, drawn
wr(C["SHIPINV"], 250)
for i in range(rd(C["NROCK"])):                 # (the rock ghosts out of it: the
    wr(C["OBJTYPE"] + i, rd(C["OBJTYPE"] + i) & 0x3F)   #   spider's sits on one)
for i in range(rd(GHN)):
    k = rd(C["GHK"] + i)
    put_ship(rd(C["GHXH"] + i) << 8 | 0x80, (rd(C["GHYH"] + i) - 4) << 8)
    for j in range(rd(GHN)):                    # only this one near
        wr(C["GHT"] + j, 0)
    cmds = None
    for _ in range(32):
        st, _c = run_frame()
        got = [[op] + list(pl) for op, pl in G["decode"](st) if op == 0x4C]
        if got and rd(C["GHI"]) == i:
            cmds = sum(got, [])
    if cmds:
        print(f"        enemy ghost, kind {k}: {gpu_cost(cmds)} GPU cycles a drawn frame")

print()
if fails:
    print(f"{len(fails)} check(s) failed")
    sys.exit(1)
print("all ghost checks passed")
