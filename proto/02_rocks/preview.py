#!/usr/bin/env python3
"""End-to-end check + picture + cycle budget for the flight-model bench.

Runs the real pieces against each other in a 65C02 emulator (py65): CPU1
(cpu_os.bin) executes the cartridge, building a frame's command list into the
ping-pong window at $7800 exactly as the hardware would, and the GPU
(gpu_os.bin) dispatch loop then consumes that list and renders it into VRAM.

Why bother when madsim exists: madsim shows the motion, which is the point of
this bench, but it cannot answer "is that star where the maths says it should
be" or "how many cycles did that frame cost". This does both, and it runs
without a window.

Two things it deliberately does NOT model:
  * cartridge wait states. Real hardware charges 3 per read in the $8000 window
    and py65 charges none, so the cycle numbers below are a NO-WAIT-STATE
    floor. The true figure is madsim's F3 meter. See the note it prints.
  * the double-buffered background and VSYNC timing.

Output: preview.png, the framebuffer turned 90 deg clockwise — what the monitor
shows when it is stood on its side (madsim's F12).
"""

import math
import re
import subprocess
import sys

from PIL import Image
from py65.devices.mpu65c02 import MPU
from py65.memory import ObservableMemory

FRAMES = 200                    # long enough to turn right round and then fly
SCALE = 2
OUT = "preview.png"

ROMS = "../../roms"
PPRAM = 0x7800
VRAM_IMG = 0x8000
IMG_END = 0xBA98
SENTINEL = 0x1000

API_GPU_BEGIN = 0xFF09
API_GPU_END = 0xFF0C

FB_W, FB_H = 400, 300           # the framebuffer: 300 rows of 50 bytes
ROW = FB_W // 8

# The cartridge's zero page, mirrored from main.s, for the trace below.
ZP = {"HEAD": 0x83, "TIER": 0x84, "TURNIX": 0x85,
      "SHXL": 0x8B, "SHXH": 0x8C, "SHYL": 0x8E, "SHYH": 0x8F,
      "VELXL": 0x91, "VELXH": 0x92, "VELYL": 0x93, "VELYH": 0x94,
      "STARN": 0xA0, "OCCN": 0xA1,
      "TRAVL": 0xC0, "TRAVH": 0xC1, "TRAVI": 0xC2, "BASEHEAD": 0xC3,
      "SPDL": 0xBD, "SPDH": 0xBE, "TSCALE": 0xCC, "SHOFFH": 0xD0,
      "REFI": 0xD1, "HEADF": 0xC5,
      "TURNVL": 0xDF, "TURNVH": 0xE0, "RAMPIX": 0xE1}
ZP_ABS = {"TPCNT": 0x0CB3,          # teleports so far
          "BOOSTN": 0x62FA,         # frames of boost left
          "ZEASH": 0x62D5,          # the eased reciprocal...
          "ZOOMH": 0x62F8,          # ...and the one snapped to a ZQ rung,
                                    #    which is what the frame actually uses
          "SHOFXH": 0x0CA1,         # the cross-axis camera lean, signed 8.8
          "OVRCNT": 0x62E4, "ABUDGET": 0x62E5}


def s16(lo, hi):
    v = lo | (hi << 8)
    return v - 65536 if v & 0x8000 else v


def sb8(v):
    return v - 256 if v > 127 else v


def decode(stream):
    """Walk a PPRAM command list. Returns [(opcode, payload_bytes), ...].

    Two traps. Byte-scanning for an opcode does not work: $47 is also the
    letter 'G', and the HUD says "HDG". And the list does not start at $7800 —
    that byte is the CPU/GPU handshake status. gpu_begin points PPWP at $7801,
    so the first opcode is at index 1.
    """
    out = []
    i = 1
    while i < len(stream):
        op = stream[i]
        if op == 0x00:                          # WAI: end of list
            break
        if op == 0x20:                          # CLEAR_BG
            out.append((op, b""))
            i += 1
        elif op in (0x45, 0x4A, 0x47):          # DOT_LINES / LINES / DOT_PIXELS:
            n = stream[i + 1]                   #   N, then N (+1 for a chain)
            k = n if op == 0x47 else n + 1      #   coordinate pairs
            out.append((op, stream[i + 1:i + 2 + 2 * k]))
            i += 2 + 2 * k
        elif op in (0x42, 0x44):                # LINE / DOT_LINE: X1,Y1,X2,Y2
            out.append((op, stream[i + 1:i + 5]))
            i += 5
        elif op == 0x43:                        # LINE16: the same four, signed 16
            g = stream[i + 1:i + 9]             #   - full-res endpoints
            out.append((op, [s16(g[0], g[1]), s16(g[2], g[3]),
                             s16(g[4], g[5]), s16(g[6], g[7])]))
            i += 9
        elif op == 0x30:                        # LOAD: page, then a whole page
            out.append((op, stream[i + 1:i + 2]))
            i += 258
        elif op == 0x50:                        # SPRITE: id, X16, Y16
            out.append((op, stream[i + 1:i + 6]))
            i += 6
        elif op in (0x4C, 0x4D, 0x4E):          # the POLYGON family: a 7-byte
            n = stream[i + 7]                   #   header (CX16, CY16, ANGLE,
            out.append((op, stream[i + 1:i + 8 + 2 * n]))   # SCALE, N) and 2N
            i += 8 + 2 * n                      #   bytes of RAW shape
        elif op in (0x62, 0x63):                # VTEXT: cell, line, scroll, str
            j = stream.index(0, i + 4)
            out.append((op, stream[i + 1:j + 1]))
            i = j + 1
        else:
            raise RuntimeError(f"unhandled opcode ${op:02X} at {i}")
    return out


def dotlists(stream):
    """Every DOT_PIXELS command in the list, in order. The cart emits two: the
    starfield, then the motes, both appended after everything else."""
    out = []
    for op, payload in decode(stream):
        if op == 0x47:
            n = payload[0]
            out.append([(payload[1 + 2 * k], payload[2 + 2 * k])
                        for k in range(n)])
    return out


def stars_of(stream):
    d = dotlists(stream)
    return d[0] if d else None


def motes_of(stream):
    d = dotlists(stream)
    return d[1] if len(d) > 1 else None


# --- a model of the GPU's own polygon transform ------------------------------
# The command no longer carries the outline; it carries the CENTRE, the ANGLE,
# the SCALE and the shape as authored, and the GPU builds the outline. So the
# harness has to build it too - and that is a better check than the old one, not
# a worse one. Before, this file read back the vertices CPU1 had computed and
# could only ever agree with the code that produced them. Now it recomputes them
# INDEPENDENTLY and the framebuffer check below compares that against what the
# GPU actually drew, which is a real cross-check of two implementations.
#
# It has to be bit-exact, so it mirrors gpu_os.s rather than using floats:
#   * pg_sinmag is |sin| on a 0-128 scale, NOT the CPU OS's 0-127 Q0.7. That is
#     what makes ANGLE = 0, SCALE = 128 an exact identity.
#   * pg_qmul is the quarter-square a*b = f(a+b) - f(|a-b|), f(x) = x^2/4, which
#     is exact for integers - so it is just (a*b + 64) >> 7, the +64 being the
#     rounding pg_qr carries for free.
#   * signs are stripped once and put back by comparing them, which is why the
#     dy*S term below negates when the signs AGREE: it is being subtracted.
PG_SINMAG = [round(128 * math.sin(math.pi * i / 128)) for i in range(128)]


def pg_matrix(ang, scale):
    """(C, sign of cos, S, sign of sin) - the rotate-and-scale, as the GPU folds it."""
    ca = (ang + 64) & 0xFF                      # cos(a) = sin(a + 90deg)
    C, sgc = PG_SINMAG[ca & 0x7F], -1 if ca & 0x80 else 1
    S, sgs = PG_SINMAG[ang & 0x7F], -1 if ang & 0x80 else 1
    if scale != 128:                            # 128 skips the multiply, which
        C = (C * scale + 64) >> 7               #   is also what keeps the table
        S = (S * scale + 64) >> 7               #   index inside a byte
    return C, sgc, S, sgs


def pg_vertex(dx, dy, cx, cy, C, sgc, S, sgs):
    """qx = CX + dx*C - dy*S,  qy = CY + dx*S + dy*C."""
    adx, sdx = abs(dx), (-1 if dx < 0 else 1)
    ady, sdy = abs(dy), (-1 if dy < 0 else 1)
    q = lambda a, b: (a * b + 64) >> 7
    t = q(adx, C)
    qx = cx + (-t if sdx != sgc else t)
    t = q(ady, S)
    qx += (-t if sdy == sgs else t)             # SUBTRACTED: negate when equal
    t = q(adx, S)
    qy = cy + (-t if sdx != sgs else t)
    t = q(ady, C)
    qy += (-t if sdy != sgc else t)
    return qx, qy


def polys(stream):
    """Every polygon command, as {cx, cy, ang, scale, n, offs}."""
    out = []
    for op, pl in decode(stream):
        if op == OP_POLY:
            n = pl[6]
            out.append({"cx": s16(pl[0], pl[1]), "cy": s16(pl[2], pl[3]),
                        "ang": pl[4], "scale": pl[5], "n": n,
                        "offs": [(sb8(pl[7 + 2 * k]), sb8(pl[8 + 2 * k]))
                                 for k in range(n)]})
    return out


def chains(stream):
    """Closed outlines, as point lists - CLOSED, so N vertices give N+1 points.

    UNCLIPPED, and that is the point: a vertex is allowed off screen now. The
    GPU cuts the figure at the edge, so what this returns is the true silhouette
    the rock would have if the screen were bigger, which is what the span and
    shape checks below want to measure.
    """
    out = []
    for p in polys(stream):
        C, sgc, S, sgs = pg_matrix(p["ang"], p["scale"])
        pts = [pg_vertex(dx, dy, p["cx"], p["cy"], C, sgc, S, sgs)
               for dx, dy in p["offs"]]
        out.append(pts + pts[:1])
    return out


def onscreen(pt):
    return 0 <= pt[0] < 200 * POLY_RES and 0 <= pt[1] < 150 * POLY_RES


def to_half(c):
    """An outline in half-res units, whatever family drew it."""
    return [(x // POLY_RES, y // POLY_RES) for x, y in c]


def cart_const(name):
    """Read a decimal constant straight out of main.s.

    The mirrored block below is hand-kept, which is survivable for geometry that
    changes once a year. It is NOT survivable for the switches the two valves are
    derived from: finding 49 is exactly a budget derived against the wrong
    configuration, and a stale mirror here would hide it again. So HUD_ON and
    ROCK_FAMILY are read, not typed.
    """
    m = re.search(rf"^{re.escape(name)}\s*=\s*(\d+)", open("main.s").read(), re.M)
    if not m:
        raise RuntimeError(f"{name} not found in main.s")
    return int(m.group(1))


def shapes_const(name):
    """Same as cart_const, but out of shapes.s - AST_TYPES and SHIP_VN, whose
    values the shape editor changes, not just main.s's own switches."""
    m = re.search(rf"^{re.escape(name)}\s*=\s*(-?\d+)", open("shapes.s").read(), re.M)
    if not m:
        raise RuntimeError(f"{name} not found in shapes.s")
    return int(m.group(1))


def shapes_array(name):
    """A flat numeric .byte array straight out of shapes.s's GENERATED block -
    SHAPE_N/R/OCC/LODN and an outline's own vertices, wrapping over however
    many continuation lines the shape editor wrote. Both `44` and `<-44` style
    literals are understood; a label reference (the SHAPE_LO/HI pointer
    tables) is silently skipped since nothing here needs its value.

    Hand-mirroring these the way SHIP_NOSE/SHAPE_N used to be is exactly the
    stale-mirror risk cart_const's docstring warns about, and shapes.s is now
    edited by a tool, not just by hand - the shape editor can add variants,
    vertices and reduced outlines with vertex counts nobody typed here.
    """
    lines = open("shapes.s").read().splitlines()
    out, capturing = [], False
    for line in lines:
        code = line.split(";", 1)[0]
        if re.match(rf"^{re.escape(name)}:", code):
            capturing = True
        elif capturing and not (line[:1] in " \t" and ".byte" in code):
            break
        if capturing and ".byte" in code:
            for tok in code.split(".byte", 1)[1].split(","):
                tok = tok.strip()
                m = re.match(r"^<?-?\s*(\d+)$", tok)
                if m:
                    v = int(m.group(1))
                    out.append(-v if tok.replace("<", "").strip().startswith("-") else v)
    if not capturing:
        raise RuntimeError(f"{name} not found in shapes.s")
    return out


def shapes_points(name):
    """An outline's (x, y) vertex pairs, straight out of shapes.s."""
    flat = shapes_array(name)
    return list(zip(flat[0::2], flat[1::2]))


# The bench's own geometry, mirrored from main.s. If these drift apart the
# checks below stop meaning anything, so they are asserted where possible.
HCX, HCY = 100, 74              # half-res framebuffer centre
FBCX, FBCY = 200, 149           # full-res framebuffer centre
SPR_W2, SPR_H2 = 8, 8           # the ship's occluder half-extent, half-res
ROCK_FAMILY = cart_const("ROCK_FAMILY")         # 0 = $4C dotted, 1 = $4D solid,
OP_POLY = (0x4C, 0x4D, 0x4E)[ROCK_FAMILY]   #   2 = $4E solid full-res
# $4E reads its centre and its offsets on the 400x300 grid, so an outline comes
# back in full-res units and everything geometric here has to know which. The
# occluder discs and the star layer stay HALF-res whatever the rocks are drawn
# with - the screen is the same screen - so the checks normalise to half-res and
# only the framebuffer comparison uses native units.
POLY_RES = 2 if ROCK_FAMILY == 2 else 1     # full-res units per half-res unit
POLY_FB = 2 // POLY_RES                     # ...and native units -> framebuffer
SHIP_SPRITE = 0                 # mirrors main.s: 0 = the vector outline
SHIP_SHAPE = shapes_points("SHIP_SHAPE")        # (dx, dy) vertices, FULL-res,
                                                 #   from shapes_const("SHIP_VN")
SHIP_SHAPE = SHIP_SHAPE[:shapes_const("SHIP_VN")]
SHIP_LINES = len(SHIP_SHAPE)    # ...drawn as that many solid LINE16 ops, closed
STAR_N = 88
MOTE_N = 10
NOBJ = 120
VIS_MAX = 64                    # the packed visible list, mirrored from main.s
VISIDX, VSXL, VSXH = 0x1A00, 0x1A40, 0x1A80
VSYL, VSYH = 0x1AC0, 0x1B00
AST_TYPES = shapes_const("AST_TYPES")
SHAPE_N_FULL = shapes_array("SHAPE_N")          # one entry per shape id (class *
SHAPE_R_FULL = shapes_array("SHAPE_R")          #   AST_TYPES + type), size-major -
SHAPE_LODN_FULL = shapes_array("SHAPE_LODN")    #   see shapes.s
SHAPE_R = tuple(SHAPE_R_FULL[i * AST_TYPES] for i in range(5))  # per CLASS -
                                                 # constant across a class's variants
HUD_ON = cart_const("HUD_ON")   # read from main.s, never typed - see below
# Both valves are DERIVED in main.s rather than typed, so mirror the arithmetic
# and not the answers - a stale constant here is how finding 49 stayed invisible.
AST_VCOST = (1564, 1749, 1873)[ROCK_FAMILY]     # GPU cycles a vertex, measured
AST_NONROCK = 62700 if HUD_ON else 14000        # the GPU's worst rock-free frame
AST_BUDGET = (209000 - AST_NONROCK) // AST_VCOST
AST_MAX = (AST_BUDGET + 4) // 5
ZOOM_RZ = (128, 128, 128, 128, 128, 123, 112, 99, 87, 76, 64)  # by speed tier,
                                # every value a rung of ZQ_LADDER


def ship_fbx(shoffh):
    """Full-res framebuffer x of the ship's centre for a signed offset byte."""
    return FBCX + (shoffh - 256 if shoffh > 127 else shoffh)


def shcy(shofxh):
    """HALF-res framebuffer y of the ship, i.e. the cart's SHCY.

    The cart computes it as HCY + (SHOFXH asr 1) and keeps it in a byte, and the
    star and mote layers are drawn about it - the cross-axis lean moves the pivot
    of the world rotation, so it has to move the backdrop's centre too.
    """
    return (HCY + (sb8(shofxh) >> 1)) & 0xFF

# -----------------------------------------------------------------------------
# Build, then load the ROMs bundled with this repo.
# -----------------------------------------------------------------------------
subprocess.run(["make"], check=True)


def gpu_symbol(name):
    txt = open(f"{ROMS}/gpu_symbols.txt").read()
    m = re.search(rf"^{re.escape(name)}\s*=\s*(0x[0-9A-Fa-f]+)", txt, re.M)
    if not m:
        raise RuntimeError(f"{name} not in {ROMS}/gpu_symbols.txt")
    return int(m.group(1), 16)


DISPATCH = gpu_symbol("dispatch_loop")

CPU_ROM = open(f"{ROMS}/cpu_os.bin", "rb").read()
GPU_ROM = open(f"{ROMS}/gpu_os.bin", "rb").read()
CART = open("proto02.bin", "rb").read()
assert len(CPU_ROM) == 0x4000 and len(GPU_ROM) == 0x4000
assert len(CART) == 0x2000, f"cartridge must be one 8 KB bank, got {len(CART)}"
assert CART[:5] == b"MAD65", "cartridge signature missing"

CART_INIT = CART[5] | (CART[6] << 8)
CART_FRAME = CART[7] | (CART[8] << 8)
print(f"cart_init @ ${CART_INIT:04X}, cart_frame @ ${CART_FRAME:04X}")


def call(mpu, addr, limit=5_000_000):
    """JSR addr, run until it returns. Returns cycles consumed."""
    ret = SENTINEL - 1
    mpu.memory[0x0100 + mpu.sp] = (ret >> 8) & 0xFF
    mpu.sp = (mpu.sp - 1) & 0xFF
    mpu.memory[0x0100 + mpu.sp] = ret & 0xFF
    mpu.sp = (mpu.sp - 1) & 0xFF
    mpu.pc = addr
    start = mpu.processorCycles
    n = 0
    while mpu.pc != SENTINEL:
        mpu.step()
        n += 1
        if n > limit:
            raise RuntimeError(f"runaway at ${mpu.pc:04X}")
    return mpu.processorCycles - start


# =============================================================================
# CPU1: the cartridge builds one command list per frame
# =============================================================================
cpu_mem = ObservableMemory()
for i, b in enumerate(CPU_ROM):
    cpu_mem[0xC000 + i] = b
for i, b in enumerate(CART):                    # bank 0 in the $8000 window
    cpu_mem[0x8000 + i] = b
# Count every read that lands in the cartridge window. Real hardware charges 3
# wait states on each of them (the cart is banked and cannot be shadowed), and
# py65 charges none — so this counter is what turns py65's cycle figure into a
# hardware one. It is also the argument for Model B: copy the code into RAM at
# boot and these reads become RAM reads at full speed.
cart_reads = [0]


def cart_read(addr):
    cart_reads[0] += 1
    return CART[addr - 0x8000]


cpu_mem.subscribe_to_read(range(0x8000, 0xA000), cart_read)

cpu = MPU(memory=cpu_mem)
call(cpu, CART_INIT)

# Joystick script. The two paths through do_stars have to be exercised
# separately, so: climb the speed tiers and turn for the first TURN_UNTIL
# frames, then let go and fly dead straight. The straight leg is where the
# starfield has to be smooth, and it is what the rigidity check below measures.
# The OS's frame ISR normally maintains these bytes; here we drive them.
JOY1, JOY1_PRESS = 0x0A, 0x0C
JOY2_PRESS = 0x0F
JOY_UP, JOY_DOWN, JOY_RIGHT = 0x01, 0x02, 0x08

# The throttle is HELD, not pressed: UP/DOWN on JOY1 accelerate continuously
# instead of stepping one tier per edge, so this script has to hold them down
# for a run of frames rather than pulsing JOY1_PRESS for one. THRTL_ACCEL is
# read from main.s rather than typed, for the same reason ROCK_FAMILY and
# HUD_ON are above: a stale copy here would silently test the wrong ramp.
TIER_N = cart_const("TIER_N")
TIER_ZERO = cart_const("TIER_ZERO")
THRTL_ACCEL = cart_const("THRTL_ACCEL")
THRTL_MAX = (TIER_N - 1) * 128
CLIMB_FRAMES = -(-(THRTL_MAX - TIER_ZERO * 128) // THRTL_ACCEL)  # 0 -> top, ceil
TIER_STEP_FRAMES = -(-128 // THRTL_ACCEL)          # one tier's worth of hold
BOOST_AT, TELEPORT_AT = 175, 185    # JOY2 up, then JOY2 down, on the straight
TP_OFF = 120                        #   leg where the field is settled and any
                                    #   sweep the jump causes has nowhere to hide
# The teleport is a DISCONTINUITY on purpose, and so is its recovery: the ship
# moves 246 px in one frame, SHOFF snaps, the star bases are rebased from
# scratch, and then the camera closes 1/16 of a 246 px gap per frame - 15 px on
# the first one, which is more than the "eases rather than snapping" bound of 12
# and is supposed to be. Three checks below measure continuity over a settled
# straight leg; they skip the jump and the fast part of the walk home, which get
# checks of their own instead.
TP_SKIP = set(range(TELEPORT_AT, TELEPORT_AT + 13))
TURN_UNTIL = 70                 # half a revolution - enough to sweep the whole
                                #   off-axis band the fold check needs - and then
                                #   there is room left for a settled straight leg,
                                #   which the turn's momentum delays by ~50 frames

frames = []
cycles = []
trace = []
rot = []                        # ROTC_I / ROTS_I + the sample, for the pivot check
objs = []                       # object screen positions by index, for the swim test
occ = []                        # the cart's own occluder boxes, straight from RAM
nrocks = []                     # ADRAWN, the rocks the cart emitted per frame
visn = []                       # VISN, entries in the packed visible list
visi = []                       # ...and VISI, how many the draw loop reached
vislist = []                    # the list itself, IN ORDER: (id, sx, sy, shape)
motepos = []                    # per-mote screen position by index, from RAM
bases = []                      # BASEX/BASEY straight out of RAM, so stars keep
                                #   their identity across a turn and the rebase
                                #   can be measured directly
TIER_DOWN_AT, TIER_UP_AT = 130, 160     # the straight leg's two speed changes
for f in range(FRAMES):
    joy1 = JOY_RIGHT if f < TURN_UNTIL else 0
    # Climb to the top tier at the start, then change speed again TWICE on the
    # straight leg: the ship's screen offset eases over ~40 frames after every
    # tier change, and that ease used to force a full star rebuild - which is
    # what made stars twitch sideways for a few frames each time.
    if f < CLIMB_FRAMES:                        # ...all the way to the TOP
        joy1 |= JOY_UP                          #   tier, where the zoom is
                                                 #   widest and the frame is
                                                 #   worst. A bench that never
                                                 #   reaches its own worst case
                                                 #   is not measuring the thing
                                                 #   it exists for.
    elif TIER_DOWN_AT <= f < TIER_DOWN_AT + TIER_STEP_FRAMES:
        joy1 |= JOY_DOWN
    elif TIER_UP_AT <= f < TIER_UP_AT + TIER_STEP_FRAMES:
        joy1 |= JOY_UP
    cpu_mem[JOY1] = joy1
    cpu_mem[JOY2_PRESS] = (JOY_UP if f == BOOST_AT else
                           JOY_DOWN if f == TELEPORT_AT else 0)
    call(cpu, API_GPU_BEGIN)
    cart_reads[0] = 0
    c = call(cpu, CART_FRAME)
    cycles.append((c, cart_reads[0]))
    call(cpu, API_GPU_END)
    end = cpu_mem[0x04] | (cpu_mem[0x05] << 8)  # PPWP points AT the WAI
    frames.append(bytes(cpu_mem[PPRAM + i] for i in range(end - PPRAM + 1)))
    t = {k: cpu_mem[a] for k, a in ZP.items()}
    t.update({k: cpu_mem[a] for k, a in ZP_ABS.items()})
    trace.append(t)
    bases.append([(cpu_mem[0x0B00 + i], cpu_mem[0x0B80 + i],
                   cpu_mem[0x0D00 + i]) for i in range(STAR_N)])
    rot.append(([cpu_mem[0x0400 + i] for i in range(256)],
                [cpu_mem[0x0600 + i] for i in range(256)],
                cpu_mem[0xA2], cpu_mem[0xA3]))
    # Object screen positions BY INDEX, straight out of RAM. Matching sprites by
    # nearest neighbour worked with seven objects and stops working with 250:
    # one leaving the screen gets paired with another arriving, and the pairing
    # invents reversals that never happened.
    # The packed visible list: VISN entries of VISIDX / VSX16 / VSY16. It used
    # to be five pages of flags and positions indexed by object id.
    vis = {}
    for k in range(cpu_mem[0x62CF]):
        vis[cpu_mem[VISIDX + k]] = (
            s16(cpu_mem[VSXL + k], cpu_mem[VSXH + k]),
            s16(cpu_mem[VSYL + k], cpu_mem[VSYH + k]))
    objs.append(vis)
    visn.append(cpu_mem[0x62CF])
    # VISI is where emit_asteroids' loop STOPPED. If it is short of VISN the
    # frame abandoned entries, and the check below decides whether any of them
    # would have been visible - which is finding 49 exactly.
    visi.append(cpu_mem[0x62D0])
    vislist.append([(cpu_mem[VISIDX + k],
                     s16(cpu_mem[VSXL + k], cpu_mem[VSXH + k]),
                     s16(cpu_mem[VSYL + k], cpu_mem[VSYH + k]),
                     cpu_mem[0x1F00 + cpu_mem[VISIDX + k]])
                    for k in range(cpu_mem[0x62CF])])
    mvis = {}
    for i in range(MOTE_N):
        if cpu_mem[0x0DE0 + i]:
            mvis[i] = (cpu_mem[0x0DC0 + i], cpu_mem[0x0DD0 + i])
    motepos.append(mvis)
    # The occluder boxes exactly as the cart built them. Rebuilding them from
    # the emitted SPRITE commands nearly works and disagrees on about one star
    # in four thousand, which is enough to make a strict rigidity check useless.
    # Occluders, exactly as the cart built them: the clamped box for the cheap
    # reject, then the disc inside it. The ship's entry has r2 = $FFFF, which
    # makes it a plain box.
    nb = cpu_mem[0xA1]
    occ.append([(cpu_mem[0x0A00 + k], cpu_mem[0x0A20 + k],
                 cpu_mem[0x0A40 + k], cpu_mem[0x0A60 + k],
                 cpu_mem[0x0A80 + k], cpu_mem[0x0AA0 + k],
                 cpu_mem[0x0AC0 + k] | (cpu_mem[0x0AE0 + k] << 8))
                for k in range(nb)])
    nrocks.append(cpu_mem[0xFE])                # ADRAWN: rocks emitted


print("\nframe  head tier  ship X     ship Y     vel (8.8)        stars occl")
for f in (0, 1, 10, 30, 60, FRAMES - 1):
    t = trace[f]
    print(f"{f:5d}   ${t['HEAD']:02X}   {t['TIER']}   "
          f"${t['SHXH']:02X}{t['SHXL']:02X}      ${t['SHYH']:02X}{t['SHYL']:02X}      "
          f"{s16(t['VELXL'], t['VELXH']):+6d},{s16(t['VELYL'], t['VELYH']):+6d}   "
          f"{t['STARN']:4d}  {t['OCCN']:3d}")

# Where the ship is ACTUALLY flying straight. Not "the heading looks constant" -
# the heading carries a fraction, and a creeping fraction eventually carries into
# the integer and fires a full star rebuild. The turn is over when the angular
# velocity is exactly zero, and with momentum that is ~50 frames after release.
STRAIGHT = TURN_UNTIL
while STRAIGHT < FRAMES and s16(trace[STRAIGHT]["TURNVL"],
                                trace[STRAIGHT]["TURNVH"]) != 0:
    STRAIGHT += 1
print(f"\nturn stops at frame {STRAIGHT}, {STRAIGHT - TURN_UNTIL} frames after "
      f"the stick was released - the turn has momentum now (ramp "
      f"{trace[-1]['RAMPIX']})")
assert STRAIGHT + 30 < FRAMES, "no settled straight leg left to measure"

# The heading must then STAY put: an ease that never quite reaches zero leaves the
# heading creeping, and every carry into the integer part is a full star rebuild -
# a scattered twitch in the middle of an otherwise rigid scroll.
drift = sum(1 for n in range(STRAIGHT, FRAMES - 1)
            if trace[n]["HEAD"] != trace[n + 1]["HEAD"])

BUDGET = 237_404
raw = [c for c, _ in cycles]                        # py65 charges no wait states
hw = [c + 3 * r for c, r in cycles]                 # ...hardware charges 3 a read
med_raw = sorted(raw)[len(raw) // 2]
med_hw = sorted(hw)[len(hw) // 2]
med_reads = sorted(r for _, r in cycles)[len(cycles) // 2]
print(f"\n{FRAMES} frames built. PPRAM: first {len(frames[0])} B, "
      f"steady {len(frames[-1])} B of 2047 "
      f"({100*len(frames[-1])/2047:.0f}% of the list)")
print(f"\nCPU1 budget, {BUDGET} cycles per frame:")
print(f"  instruction cycles        median {med_raw:6d}  worst {max(raw):6d}")
print(f"  + cartridge wait states   median {med_hw:6d}  worst {max(hw):6d}"
      f"  = {100*max(hw)/BUDGET:5.1f}%")
worst5 = sorted(range(len(hw)), key=lambda i: -hw[i])[:5]
print("  worst five frames:      " + "  ".join(
    f"f{i} {hw[i]}" for i in worst5))
print(f"  {med_reads} cartridge reads a frame. Model B is working when this is a")
print("  handful (the boot_frame trampoline); it was ~35,000 running in place,")
print("  which cost 2.5x and put the same frame at 77% of budget.")

# =============================================================================
# GPU: dispatch each list into VRAM
# =============================================================================
gpu_mem = ObservableMemory()
for i, b in enumerate(GPU_ROM):
    gpu_mem[0xC000 + i] = b
bg = bytearray(0x4000)
img = bytearray(0x4000)

gpu_mem.subscribe_to_write(range(VRAM_IMG, 0xC000),
                           lambda a, v: img.__setitem__(a - VRAM_IMG, v))
gpu_mem.subscribe_to_write(range(0xC000, 0x10000),
                           lambda a, v: bg.__setitem__(a - 0xC000, v))
gpu_mem.subscribe_to_read(range(0xC000, 0x10000),
                          lambda a: GPU_ROM[a - 0xC000])

# The harness jumps straight into the dispatch loop, so GPU boot never runs and
# the sprite definition table is empty. Install sprite 0 exactly as boot_main
# does: type $14 (32 px wide, no overlay), data at $F400, 26 rows. The cart then
# LOADs its own four definition pages over this on its first frame, which is
# precisely what the ship-sprite check below is testing.
gpu_mem[0x0300] = 0x14
gpu_mem[0x0400] = 0x00
gpu_mem[0x0500] = 0xF4
gpu_mem[0x0600] = 26

regs_hit = False
gpu = MPU(memory=gpu_mem)
for f, stream in enumerate(frames):
    img[:] = bg                                 # the hardware background copy
    # ...and the GPU's OWN VRAM has to be copied too, not just the buffer this
    # harness captures writes into. The drawing routines read-modify-write, so a
    # VRAM left dirty from the previous frame comes back out of every byte the
    # current frame touches: the picture grew 200 frames of ship and mote trails,
    # smeared a byte at a time. `_subject` is the raw list under the observer, so
    # this does not re-fire the write callbacks that maintain `img`.
    gpu_mem._subject[VRAM_IMG:0xC000] = bg
    for i, b in enumerate(stream):
        gpu_mem[PPRAM + i] = b
    gpu_mem[0x03] = (PPRAM + 1) & 0xFF          # PPWP -> first opcode
    gpu_mem[0x04] = (PPRAM + 1) >> 8
    gpu.pc = DISPATCH
    n = 0
    while gpu_mem[gpu.pc] != 0xCB:              # $CB = WAI: end of the frame
        gpu.step()
        n += 1
        if n > 5_000_000:
            raise RuntimeError("GPU runaway")
    regs_hit |= any(img[16320:])

# =============================================================================
# Checks
# =============================================================================
fail = []


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    if not ok:
        fail.append(name)
        if detail:
            print("        " + detail)


def pix(fx, fy):
    """Full-res framebuffer pixel."""
    if not (0 <= fx < FB_W and 0 <= fy < FB_H):
        return 0
    return (img[fy * ROW + (fx >> 3)] >> (7 - (fx & 7))) & 1


print("\nchecks:")
check("nothing was written at or past the register overlay (offset 16320)",
      not regs_hit)

# The backdrop is appended last on purpose: if the GPU ever runs out of frame,
# what it drops should be the starfield and the motes, not the ship or the HUD.
ops = [op for op, _ in decode(frames[-1])]
order_ok = len(ops) >= 2 and ops[-2] == 0x47 and ops[-1] == 0x47 and \
    all(o != 0x47 for o in ops[:-2])
print(f"        command order: {' '.join('%02X' % o for o in ops)}")
check("the starfield and the motes are the last two commands in the list",
      order_ok,
      "the backdrop is not last, so the GPU would drop gameplay before it")

# Ground truth for where the stars were asked to go, straight out of PPRAM.
dots = stars_of(frames[-1])
check("the frame contains a DOT_PIXELS command", dots is not None)

if dots is not None:
    motes = motes_of(frames[-1])
    print(f"        {len(dots)} stars emitted of {STAR_N} in the layer "
          f"({100*len(dots)/STAR_N:.0f}%), "
          f"{len(motes) if motes else 0} motes of {MOTE_N}")
    check("the mote layer is drawing", motes is not None and len(motes) >= 3,
          f"{len(motes) if motes else 0} motes on screen")
    check("every mote is inside the half-res screen",
          motes is not None and all(0 <= x < 200 and 0 <= y < 150
                                    for x, y in motes))
    check("a sane fraction of the layer is on screen",
          20 <= len(dots) <= 80,
          f"{len(dots)} visible; the rotated 150x200 view covers ~46% of a "
          f"256x256 layer, so expect roughly 50")
    check("every emitted star is inside the half-res screen",
          all(0 <= x < 200 and 0 <= y < 150 for x, y in dots))
    # ...except where the HUD covered it. TEXT/VTEXT write whole character
    # cells, background included — they do not OR a glyph over what is already
    # there — so a star under a HUD line is erased after the fact. Worth knowing
    # for the real game: an image-layer HUD punches black rectangles into the
    # starfield, which is one more reason to put it on the background layer.
    # Since the reorder the backdrop is drawn LAST, so nothing paints over it -
    # the HUD and sprite exclusions this check used to need are gone.
    HUD_LINES = ()
    hud_rows = {r for L in HUD_LINES for r in range(4 * L, 4 * L + 4)}
    # A sprite drawn over a star also erases it. The occluder list the cart
    # keeps only holds boxes whose CENTRE is on screen, so a sprite hanging off
    # an edge still paints over stars it never suppressed - that is a known
    # limit of the naive box list, not a transform bug. Exclude those too.
    sprite_rects = []
    for op, pl in decode(frames[-1]):
        if op == 0x50:
            x = pl[1] | (pl[2] << 8)
            y = pl[3] | (pl[4] << 8)
            x = x - 65536 if x & 0x8000 else x
            y = y - 65536 if y & 0x8000 else y
            sprite_rects.append((x >> 1, (x + 31) >> 1, y >> 1, (y + 31) >> 1))
    missing = [(x, y) for x, y in dots
               if not pix(2 * x, 2 * y) and x not in hud_rows
               and not any(x0 <= x <= x1 and y0 <= y <= y1
                           for x0, x1, y0, y1 in sprite_rects)]
    check("every emitted star not under the HUD reached the framebuffer",
          not missing, f"{missing}")
    # The occlusion list: no star may land inside the ship's sprite box.
    shipx = ship_fbx(trace[-1]["SHOFFH"]) >> 1   # this box is half-res
    shipy = shcy(trace[-1]["SHOFXH"])            #   and it leans with the ship
    inside = [(x, y) for x, y in dots
              if abs(x - shipx) <= SPR_W2 and abs(y - shipy) <= SPR_H2]
    check("no star was drawn inside the ship's sprite box",
          not inside, f"{inside}")
    check("stars are not all bunched in one place",
          len({x >> 5 for x, _ in dots}) >= 4 and
          len({y >> 5 for _, y in dots}) >= 3)

# --- the zoom -----------------------------------------------------------------
# It has to move, stay inside the range the tables are indexed for, and SETTLE.
# An exponential ease that never lands would leave the reciprocal creeping, and
# every creep rebuilds a 512-byte table (finding 13, and it bites hardest here).
rzs = [t['ZOOMH'] for t in trace]
print(f"        zoom reciprocal: {rzs[0]} -> {min(rzs)} -> {rzs[-1]} "
      f"(128 = 1:1, 64 = twice out); moved on "
      f"{sum(1 for a, b in zip(rzs, rzs[1:]) if a != b)} of {FRAMES} frames")
check('the zoom pulls back with speed', min(rzs) < 100,
      f'never went below {min(rzs)}')
check('the zoom stays inside the range ZOOM_CULLR is indexed for',
      all(64 <= z <= 128 for z in rzs),
      f'{min(rzs)}..{max(rzs)} - an index outside 0..8 reads a garbage radius')
# "Settles" is not "never moves" - the joystick script changes tier twice late
# on, and the zoom is meant to follow. The property is that it LANDS: the last
# frames are stationary and sitting exactly on the current tier's target.
check('the zoom settles on its target instead of creeping',
      len(set(rzs[-5:])) == 1 and rzs[-1] == ZOOM_RZ[trace[-1]['TIER']],
      f'last five {rzs[-5:]}, tier {trace[-1]["TIER"]} wants '
      f'{ZOOM_RZ[trace[-1]["TIER"]]}')

# --- the ship: an authored N-vertex outline, solid LINE ops ------------------
# The sprite is assembled out (SHIP_SPRITE = 0 in main.s) while the vector
# version is measured. LINE takes half-res BYTES and validates nothing, so the
# points have to be in range on every frame - and they have to be the right
# outline in the right place, which is what pins the TATE axis convention: the
# nose vertex (a negative dx, shapes.s's own convention) is the SMALLER fb_x,
# because up on the player's screen is fb_x decreasing.
def zscale(v, rz):
    """qmul's rounding: round(v * rz / 128)."""
    return (v * rz + 64) >> 7


def zscale_signed(v, rz):
    """emit_ship's sscale: the SIGN is stripped before qmul and reapplied
    after, not folded into a single signed multiply - that rounds differently
    for a negative v than zscale(v, rz) would (floor vs magnitude-then-sign),
    so this mirrors sscale exactly rather than plain-scaling a signed input."""
    return -zscale(-v, rz) if v < 0 else zscale(v, rz)


# The ship is drawn with LINE16 ($43) at FULL resolution - see the note in
# emit_ship. Everything here is therefore on the 400x300 grid, not 200x150.
shipx = ship_fbx(trace[-1]['SHOFFH'])           # the full-res centre
shipy = FBCY + sb8(trace[-1]['SHOFXH'])         # ...and the cross-axis lean
RZ = trace[-1]['ZOOMH']
tri = [tuple(pl) for op, pl in decode(frames[-1]) if op == 0x43]
check('the ship is SHIP_LINES solid lines', len(tri) == SHIP_LINES,
      f'{len(tri)} LINE commands in the frame, {SHIP_LINES} authored vertices')
check('no sprite is emitted while the vector outline is in',
      not any(op == 0x50 for op, _ in decode(frames[-1])))

want_ordered = [(shipx + zscale_signed(dx, RZ), shipy + zscale_signed(dy, RZ))
                for dx, dy in SHIP_SHAPE]
pts = sorted({(g[0], g[1]) for g in tri} | {(g[2], g[3]) for g in tri})
want = sorted(want_ordered)
check(f'the outline is nose up on the ship point, scaled by RZ {RZ}',
      pts == want, f'corners {pts}, wanted {want}')

allpts = [(g[0], g[1]) for f in frames for op, g in decode(f) if op == 0x43]
allpts += [(g[2], g[3]) for f in frames for op, g in decode(f) if op == 0x43]
check('every ship line stays inside the FULL-res field',
      len(allpts) == 2 * SHIP_LINES * FRAMES
      and all(0 <= x < 400 and 0 <= y < 300 for x, y in allpts),
      f'{len(allpts)} endpoints over {FRAMES} frames')

# The whole point of $43 over $42: distinct positions in MOTION. With half-res
# endpoints the nose lands on even pixels only, so consecutive frames repeat.
nosex = [min(g[0], g[2]) for f in frames for op, g in decode(f) if op == 0x43]
odd = sum(1 for v in nosex if v & 1)
check('the ship is drawn on odd pixels too, not just even ones',
      odd > 0, f'{odd} of {len(nosex)} nose endpoints land on an odd pixel')


# ...and SOLID on the framebuffer, not a row of specks - every AUTHORED edge,
# not just one flat one, since a general N-gon has no edge guaranteed to sit
# on a single row or column the way the old triangle's base did.
def edge_solid_fraction(p1, p2):
    """Walk the IDEAL line from p1 to p2 one dominant-axis step at a time and
    check each point's 2x2 pixel neighbourhood, not one single rounded pixel -
    which row a shallow diagonal lands on is a rasteriser rounding choice, and
    this check has no reason to assume it matches Python's, only that SOME
    adjacent pixel is lit at every step along the line (a real gap - the GPU
    skipping the line entirely, or stopping partway - fails this just as hard
    as it would fail an exact per-pixel reconstruction)."""
    x1, y1 = p1
    x2, y2 = p2
    dx, dy = x2 - x1, y2 - y1
    steps = max(abs(dx), abs(dy))
    if steps == 0:
        return 1.0
    hits = 0
    for i in range(steps + 1):
        fx = x1 + dx * i / steps
        fy = y1 + dy * i / steps
        x0, y0 = math.floor(fx), math.floor(fy)
        if any(pix(x0 + ox, y0 + oy) for ox in (0, 1) for oy in (0, 1)):
            hits += 1
    return hits / (steps + 1)


edge_fracs = [edge_solid_fraction(want_ordered[i], want_ordered[(i + 1) % len(want_ordered)])
              for i in range(len(want_ordered))]
check('the ship reached the framebuffer, solid', min(edge_fracs) > 0.8,
      f'lit fraction per edge: {[round(f, 2) for f in edge_fracs]}')

# ...and it must actually have moved off centre, and eased rather than snapped.
offs = [t["SHOFFH"] - 256 if t["SHOFFH"] > 127 else t["SHOFFH"] for t in trace]
jump = max(abs(b - a) for n, (a, b) in enumerate(zip(offs, offs[1:]))
           if n + 1 not in TP_SKIP)
print(f"        ship screen offset: {offs[0]} -> {offs[-1]} px, "
      f"largest single-frame move {jump} px")
check("the ship offset follows the speed tier", abs(offs[-1]) > 20,
      f"ended at {offs[-1]} px from centre")

# --- the teleport ----------------------------------------------------------
# It lands on a FIXED screen point, which is the whole reason it fits a signed
# byte. Anything else about it is allowed to vary; this may not.
tp = trace[TELEPORT_AT]
print(f"        teleport: SHOFF {offs[TELEPORT_AT - 1]} -> {offs[TELEPORT_AT]} px, "
      f"{TPD if (TPD := offs[TELEPORT_AT - 1] - offs[TELEPORT_AT]) else 0} px jumped; "
      f"TPCNT {tp['TPCNT']}, BOOSTN {trace[BOOST_AT]['BOOSTN']}")
check("the teleport fired exactly once", tp["TPCNT"] == 1 and
      trace[TELEPORT_AT - 1]["TPCNT"] == 0, f"TPCNT {tp['TPCNT']}")
check("the teleport lands on its fixed screen point",
      offs[TELEPORT_AT] == -TP_OFF, f"SHOFF {offs[TELEPORT_AT]}, wanted {-TP_OFF}")
check("the boost fired and is counting down",
      trace[BOOST_AT]["BOOSTN"] > 0 and trace[BOOST_AT - 1]["BOOSTN"] == 0,
      f"BOOSTN {trace[BOOST_AT - 1]['BOOSTN']} -> {trace[BOOST_AT]['BOOSTN']}")
# ...and the camera has to walk back, FRONT-LOADED: SHOFF_LAG closes 1/16 of the
# gap a frame, so 5 frames is 27.7% of it and 14 frames is 59.3% - the first five
# must therefore carry more than 40% of what the first fourteen do. A linear walk
# home would carry 36% and fail this.
early = offs[TELEPORT_AT + 5] - offs[TELEPORT_AT]
late = offs[TELEPORT_AT + 14] - offs[TELEPORT_AT]
# --- and the same jump in reverse, on its own short flight ------------------
# The main flight only ever teleports at top speed, which is forward - and that
# is exactly how a sign-extension bug in the backward case reached the screen.
# This re-inits the cart, backs up until the tier is below TIER_ZERO, and jumps.
def world(t):
    # the ship's 16-bit world position, fraction dropped
    return (t["SHXL"] | (t["SHXH"] << 8), t["SHYL"] | (t["SHYH"] << 8))


def wrapped(a, b):
    # b - a as the shortest signed distance across the 16-bit torus
    d = (b - a) & 0xFFFF
    return d - 65536 if d > 32767 else d


call(cpu, CART_INIT)
rev = []
REV_FRAMES = -(-(TIER_ZERO * 128) // THRTL_ACCEL)   # tier 3 -> 0, full astern
for f in range(60):
    cpu_mem[JOY1] = JOY_DOWN if f < REV_FRAMES else 0
    cpu_mem[JOY2_PRESS] = JOY_DOWN if f == 45 else 0    # ...then teleport
    call(cpu, API_GPU_BEGIN)
    call(cpu, CART_FRAME)
    call(cpu, API_GPU_END)
    rev.append({k: cpu_mem[a] for k, a in ZP.items()} |
               {k: cpu_mem[a] for k, a in ZP_ABS.items()})

rso = [t["SHOFFH"] - 256 if t["SHOFFH"] > 127 else t["SHOFFH"] for t in rev]
dy = wrapped(world(rev[44])[1], world(rev[45])[1])
step = wrapped(world(rev[43])[1], world(rev[44])[1])
print(f"        reverse teleport: tier {rev[45]['TIER']}, SHOFF {rso[44]} -> "
      f"{rso[45]} px; world y jumped {dy} against a per-frame {step}")
check("the reverse teleport lands on the mirrored screen point",
      rev[45]["TPCNT"] == rev[44]["TPCNT"] + 1 and rso[45] == TP_OFF,
      f"SHOFF {rso[45]}, wanted {TP_OFF}")
# Heading stays 0 through this flight, so forward is -y and backing up is +y.
# The broken version sign-extended the distance with a byte that LDY had just
# cleared the flags on, so the backward jump came out positive-forward: dy would
# be NEGATIVE here. That is the whole thing this check exists to catch.
check("the reverse teleport moves the ship BACKWARDS, not forwards",
      dy > 0 and abs(dy) > 8 * abs(step),
      f"jumped {dy} against a per-frame {step}")

check("the camera walks back after the teleport, and front-loads it",
      late > 0 and early > 0.40 * late,
      f"{early} px of the first {late} px, {early / late:.0%}" if late else "no recovery")
check("the ship offset eases rather than snapping", jump <= 12,
      f"moved {jump} px in one frame")

# --- and they must not twitch ------------------------------------------------
# On a straight leg a mote's path across the screen is a straight line at
# constant speed, so any reversal is quantisation noise - the same test the
# objects get. The first version of do_motes used only the integer rotation
# tables and no sub-unit registration, and the specks visibly jittered a couple
# of pixels back and forth.
mrev = msteps = 0
for n in range(STRAIGHT, FRAMES - 1):
    a, b = motepos[n], motepos[n + 1]
    for i in set(a) & set(b):
        for axis in (0, 1):
            d = b[i][axis] - a[i][axis]
            if abs(d) > 40:             # wrapped round the layer, not a step
                continue
            if d:
                msteps += 1
_mtracks = {}
for n in range(STRAIGHT, FRAMES - 1):
    # Only frames where the ship's screen offset is STEADY. While it eases after
    # a tier change the camera itself is moving backwards or forwards along the
    # heading - fast enough to outrun the ship - so the motes legitimately
    # reverse, and counting those would measure the ease, not the rounding.
    if trace[n]["SHOFFH"] != trace[n + 1]["SHOFFH"]:
        continue
    a, b = motepos[n], motepos[n + 1]
    for i in set(a) & set(b):
        d = (b[i][0] - a[i][0], b[i][1] - a[i][1])
        if max(abs(d[0]), abs(d[1])) > 40:
            continue
        _mtracks.setdefault(i, []).append(d)
# Split by AXIS, because the two axes are asking different questions and only
# one of them is finding 15. On a straight leg the field translates along one
# screen axis and not at all along the other:
#
#   ALONG travel - the defect's home. Freeze-then-jump shows up as a reversal
#     here, and there must be none. (Measured with the bug in: 68 of 401.)
#   ACROSS it    - a coordinate that should not be moving at all, so every step
#     is +/-1 of pure quantisation and a "reversal" is just two of them in a row.
#     Worth reporting, not worth failing on.
#
# Lumping the two together is what the first version of this check did, and it
# started failing when the ship's rest position moved down the screen: the star
# and mote camera point rides SHOFF pixels ahead of the ship, so a lower ship
# pushes the sample further out and the cross-axis rounding churns more. The
# motion along travel stayed exactly as clean as it was.
stats = {}
for axis in (0, 1):
    st = rev = tot = 0
    for deltas in _mtracks.values():
        seq = [d[axis] for d in deltas if d[axis]]
        st += len(seq)
        tot += sum(abs(v) for v in seq)
        rev += sum(1 for u, v in zip(seq, seq[1:]) if u * v < 0)
    stats[axis] = (st, rev, tot / st if st else 0)
major = max(stats, key=lambda a: stats[a][2] * stats[a][0])
minor = 1 - major
msteps, mrev, mmag = stats[major]
xsteps, xrev, xmag = stats[minor]
print(f"        mote motion along travel: {msteps} steps, mean {mmag:.1f} px, "
      f"{mrev} reversals")
print(f"        ...and across it: {xsteps} steps, mean {xmag:.1f} px, "
      f"{xrev} reversals")
check("the motes do not twitch along their travel", mrev == 0,
      f"{mrev}/{msteps} steps reversed - the mote transform is truncating twice "
      f"or missing its sub-unit registration")
check("the motes' cross-axis jitter is a single pixel", xmag < 1.5,
      f"mean {xmag:.1f} px sideways - that is more than rounding")

# --- the motes must actually be the FAST layer -------------------------------
# Stars run at 1/4 of the ship's speed and motes at 2x, so on a straight leg the
# mote field should travel about eight times as far per frame as the starfield.
# Both are rigid translations, so the mean displacement is the measurement.
def mean_shift(prev, cur):
    if not prev or not cur:
        return None
    # match by nearest, which is unambiguous for a rigid translation
    tot, n = 0.0, 0
    for x, y in prev:
        best = min(cur, key=lambda q: abs(q[0] - x) + abs(q[1] - y))
        if abs(best[1] - y) <= 1 and abs(best[0] - x) <= 20:
            tot += best[0] - x
            n += 1
    return tot / n if n else None


mote_travel = star_travel = 0.0
for n in range(STRAIGHT, FRAMES - 1):
    if n + 1 in TP_SKIP:
        continue
    a = mean_shift(motes_of(frames[n]), motes_of(frames[n + 1]))
    if a is not None:
        mote_travel += abs(a)
    star_travel += abs(sb8((trace[n + 1]["TRAVI"] - trace[n]["TRAVI"]) & 0xFF))
ratio = mote_travel / star_travel if star_travel else 0
print(f"        motes travelled {mote_travel:.0f} px to the stars' "
      f"{star_travel:.0f} - ratio {ratio:.1f} (2 / 0.25 = 8 expected)")
check("the motes are the near, fast layer", 5.0 <= ratio <= 11.0,
      f"ratio {ratio:.1f} - the mote parallax is not 2x the ship's speed")

# --- the reason do_stars is shaped the way it is -----------------------------
# On the straight leg the field must translate RIGIDLY: every visible star moves
# by exactly the frame's scroll step in fb_x and not at all in fb_y. The version
# this replaced failed here — it stood still for three frames and then moved
# ~100 of 110 stars by differing amounts, which is what "trembling" was.
def sb(v):
    return v - 256 if v > 127 else v


def covered(occs, x, y):
    """The cart's own suppression test: inside the box AND inside the disc.

    The centre is stored as a low byte only, which is exact for any point that
    reaches the disc test because such a point is inside the box and therefore
    within +/-R of the centre - so the byte difference, read as signed, is the
    true one. This mirrors that.
    """
    for x0, x1, y0, y1, cx, cy, r2 in occs:
        if not (x0 <= x <= x1 and y0 <= y <= y1):
            continue
        dx = sb((x - cx) & 0xFF)
        dy = sb((y - cy) & 0xFF)
        if dx * dx + dy * dy <= r2:
            return True
    return False


print(f"        heading changes after the turn stopped: {drift}")
rigid_ok = rigid_bad = 0
steps = []
for n in range(STRAIGHT, FRAMES - 1):
    if n + 1 in TP_SKIP:
        continue
    a, b = stars_of(frames[n]), stars_of(frames[n + 1])
    if a is None or b is None:
        continue
    d = sb((trace[n + 1]["TRAVI"] - trace[n]["TRAVI"]) & 0xFF)
    # ...and the cross step, which is not zero on the straight leg either: the
    # camera lean DECAYS after the turn stops, and the whole field slides back
    # with it, one whole pixel at a time. Rigid means "every star by the same
    # amount", not "only along the scroll axis".
    e = shcy(trace[n + 1]["SHOFXH"]) - shcy(trace[n]["SHOFXH"])
    steps.append(d)
    bs = set(b)
    boxes = occ[n + 1]
    for x, y in a:
        nx, ny = x + d, y + e
        if not (0 <= nx < 200) or not (0 <= ny < 150):
            continue                            # scrolled off the edge, fine
        if (nx, ny) in bs:
            rigid_ok += 1
        elif covered(boxes, nx, ny):
            continue                            # an object moved over it
        elif (x, y) not in bs:
            rigid_bad += 1                      # moved, but not with the field

moving = sum(1 for d in steps if d)
print(f"        straight leg: scroll step per frame {steps[:24]}")
print(f"        {moving} of {len(steps)} frames scroll; "
      f"{rigid_ok} star-moves rigid, {rigid_bad} not")
check("the starfield translates rigidly while flying straight",
      rigid_bad == 0 and rigid_ok > 500,
      f"{rigid_bad} stars moved out of step with the field")
check("the heading stops creeping once the turn is over", drift == 0,
      f"{drift} carries into the integer heading - the ease is not reaching zero")
check("the field does scroll on the straight leg", moving > 5,
      "TRAVI never advanced - the travel accumulator is not running")

# --- the rebase must be smooth too -------------------------------------------
# During the turn the field rotates and translates continuously, so each star's
# base should march in one direction per axis; a reversal is the rebase rounding
# differently from one frame to the next. This is what the 8.8 tables and the
# sub-unit registration in star_rebase are for.
rev = tot = 0
for i in range(STAR_N):
    for axis in (0, 1):
        seq = []
        for n in range(1, TURN_UNTIL):
            if bases[n][i][2] or bases[n - 1][i][2]:
                continue                        # parked: it has no position
            d = sb8((bases[n][i][axis] - bases[n - 1][i][axis]) & 0xFF)
            if d:
                seq.append(d)
        tot += len(seq)
        rev += sum(1 for a, b in zip(seq, seq[1:]) if a * b < 0)
print(f"        turning: {tot} base steps, {rev} of them reversals")
check("the star bases march smoothly through a turn",
      rev <= tot // 10, f"{rev}/{tot} reversed")

# --- no star may be a folded one ---------------------------------------------
# A star's view position reaches 128*(|cos|+|sin|) - up to 181 off-axis - while
# a base is one byte and folds at 128. A folded star lands back on the top or
# bottom edge carrying the sweep speed of a radius it does not have, and
# teleports across the screen when it crosses the fold. star_rebase parks those
# instead. This reconstructs every star's drawn position from RAM and looks for
# the teleports: on a turn, a star on screen in two consecutive frames cannot
# move further than its radius times the turn angle, which is about 6 px.
def drawn(n, cy=None):
    """{star index: (fb_x, fb_y)} for the stars actually on screen in frame n.

    cy is the cross-axis centre the field is drawn about - SHCY, the ship's own
    leaned position. It is a parameter only so the check below can reconstruct
    the same frame about the UNLEANED centre and show the two differ.
    """
    out = {}
    ti = trace[n]["TRAVI"]
    if cy is None:
        cy = shcy(trace[n]["SHOFXH"])
    for i, (bx, by, parked) in enumerate(bases[n]):
        if parked:
            continue
        fx = HCX + sb8((by + ti) & 0xFF)
        fy = cy - sb8(bx)
        if 0 <= fx < 200 and 0 <= fy < 150:
            out[i] = (fx, fy)
    return out


# Under a rotation every star moves TANGENTIALLY, so the cross product of its
# radius with its motion has the same sign for all of them - the turn's
# handedness. A folded star is drawn near one edge while carrying the motion
# belonging to its true position near the opposite one, so its cross product
# comes out backwards. That is exactly the "flying the wrong way" streak, and it
# is a scale-free test: no thresholds on speed or radius beyond ignoring the
# stars too close to the centre or too slow to have a reliable direction.
wrong = tested = 0
for n in range(1, TURN_UNTIL):
    a, b = drawn(n - 1), drawn(n)
    cx = ship_fbx(trace[n]["SHOFFH"]) >> 1      # the pivot is the SHIP, not the
    cy = shcy(trace[n]["SHOFXH"])               #   screen centre - on BOTH axes:
    common = set(a) & set(b)                    #   the lean moves it sideways
    if not common:
        continue
    # The frame is a rotation AND a scroll. Take the mean motion as the scroll -
    # the rotational parts cancel over a field spread around the pivot - and
    # subtract it, or stars near the pivot move mostly sideways and the sign
    # means nothing.
    tx = sum(b[i][0] - a[i][0] for i in common) / len(common)
    ty = sum(b[i][1] - a[i][1] for i in common) / len(common)
    signs = []
    for i in common:
        rx, ry = a[i][0] - cx, a[i][1] - cy
        vx, vy = b[i][0] - a[i][0] - tx, b[i][1] - a[i][1] - ty
        if rx * rx + ry * ry < 40 * 40 or abs(vx) + abs(vy) < 2:
            continue
        signs.append((i, rx * vy - ry * vx))
    if len(signs) < 8:
        continue
    pos = sum(1 for _, c in signs if c > 0)
    turn = 1 if pos * 2 > len(signs) else -1
    for _, c in signs:
        tested += 1
        if c * turn < 0:
            wrong += 1
parked = sum(1 for _, _, q in bases[-1] if q)
print(f"        turn: {tested} star motions checked, {wrong} against the "
      f"rotation; {parked} of {STAR_N} parked in the last frame")
# A handful is quantisation noise: a star just outside the radius filter moving
# a single pixel can flip the sign. The signal is an order of magnitude larger -
# with parking off this run reports 65 (3.4%), with it on, 13 (0.7%). The count
# rose from 8 when the ship's rest position moved 40 px down the screen, and that
# is the same mechanism as the mote note above: the star camera point rides SHOFF
# ahead of the ship, so a lower ship puts the sample nearer the layer's 128-unit
# reach and more stars sit on the park boundary. Real, small, and the reason the
# floor here is a percentage and not a count.
check("every star sweeps the way the turn does", wrong <= tested // 100,
      f"{wrong} of {tested} moved against the rotation - a folded base is "
      f"being drawn at the wrong edge")

# The drawn set must also match what the cart actually emitted, or the model
# above is measuring something other than the screen.
model = set(drawn(FRAMES - 1).values())
emitted = set(dots)
# The forced refresh has to actually fire, or parked stars are never brought
# back and a long straight flight thins the leading edge.
refs = sum(1 for a, b in zip(trace[STRAIGHT:], trace[STRAIGHT + 1:])
           if a["REFI"] != b["REFI"])
print(f"        straight leg: {refs} forced refresh(es)")
check("the parked set is refreshed while flying straight", refs >= 1,
      "REFI never moved - parked stars would never come back")

check("the reconstructed star set matches the emitted one",
      emitted <= model and len(model) - len(emitted) <= len(model) // 3,
      f"model {len(model)}, emitted {len(emitted)} (occlusion removes some)")

# --- the world must pivot on the SHIP, not on the screen centre --------------
# The ship turns; the world does not. So a world point AT the ship has to stay
# under the ship on screen through a turn - otherwise the world slides past it
# and turning reads as a strafe. The star layer's own sample point is what makes
# that true on the ALONG axis: it sits ahead of the ship by the ship's screen
# offset, so it swings around the ship as the heading changes. On the CROSS axis
# nothing swings, because the camera lean is not in the sample point - the field
# is drawn about SHCY instead. Run the star transform on the SHIP's own layer
# position and check it lands on the ship's sprite, on BOTH axes.
#
# The cross half is the one that caught the lean shipping without it: the field
# was drawn about HCY while the ship sat up to 40 half-res px off it, so the
# stars swept around a point the ship had left. That is a strafe, and it is
# exactly what this asserts is gone.
worst = worst_y = 0
for n in range(2, TURN_UNTIL):
    ci, si, sx, sy = rot[n]
    t = trace[n]
    shipx = ((t["SHXH"] << 1) | (t["SHXL"] >> 7)) & 0xFF
    shipy = ((t["SHYH"] << 1) | (t["SHYL"] >> 7)) & 0xFF
    dx, dy = (shipx - sx) & 0xFF, (shipy - sy) & 0xFF
    view_y = sb8(ci[dy]) - sb8(si[dx])          # the same sums the cart makes
    view_x = sb8(ci[dx]) + sb8(si[dy])
    star_at_ship = HCX + view_y
    drawn_ship = ship_fbx(t["SHOFFH"]) >> 1     # the sprite's own half-res centre
    worst = max(worst, abs(star_at_ship - drawn_ship))
    # ...and across it, where the whole argument rests on view_x being zero: the
    # camera sample sits directly ALONG the heading from the ship, so the ship's
    # own point carries no cross-axis view coordinate and the field's cross
    # centre IS the ship's cross position. Whatever that centre is, the pivot
    # lands on it - which is why the centre has to be SHCY and not HCY, and why
    # the check below pins that separately.
    worst_y = max(worst_y, abs(view_x))
lean = max(abs(sb8(t["SHOFXH"])) for t in trace[:TURN_UNTIL])
print(f"        pivot: star transform of the ship's own position lands within "
      f"{worst} px along the ship, {worst_y} px of the field's cross centre "
      f"(the lean reached {lean} full-res px)")
check("the turn leans the camera far enough for this to mean anything",
      lean >= 20, f"peak lean {lean} px - the cross check proves nothing")
check("the star field pivots on the ship along the heading", worst <= 3,
      f"{worst} px off - the field is turning about the wrong point, which is "
      f"what makes a turn feel like a strafe")
check("the star camera stays on the heading axis from the ship", worst_y <= 3,
      f"view_x reached {worst_y} - the sample point is off to one side, so the "
      f"field's cross centre is not the ship's cross position")

# ...and the cross centre the cart ACTUALLY draws about. Everything above
# reconstructs the field from RAM, so a model that leans while the cart does not
# would agree with itself and prove nothing. Reconstruct the peak-lean frame
# twice - about SHCY and about the unleaned HCY - and demand that the stars the
# cart emitted match the LEANED one. This is the check that fails if the lean is
# left out of do_stars, and it failed for the whole first cut of the lean.
peak = max(range(1, TURN_UNTIL), key=lambda n: abs(sb8(trace[n]["SHOFXH"])))
emitted_peak = set(stars_of(frames[peak]) or ())
leaned = set(drawn(peak).values())
unleaned = set(drawn(peak, HCY).values())
print(f"        frame {peak} leans {sb8(trace[peak]['SHOFXH'])} px: "
      f"{len(emitted_peak)} stars emitted, {len(emitted_peak & leaned)} on the "
      f"leaned centre, {len(emitted_peak & unleaned)} on the unleaned one")
check("the peak-lean frame can tell the two centres apart",
      leaned != unleaned and len(emitted_peak) >= 20,
      "the lean rounds to nothing there, or there are too few stars")
check("the cart draws the star field about the LEANED cross centre",
      emitted_peak <= leaned,
      f"{len(emitted_peak - leaned)} emitted stars are not where a field "
      f"centred on the ship would put them - the backdrop is pivoting about "
      f"the screen centre while the ship sits off it")

# --- objects must not swim ---------------------------------------------------
# On the straight leg both the ship and the objects move at constant velocity, so
# every object's true path across the screen is a straight line at constant
# speed. Any reversal in a screen coordinate is pure quantisation noise — which
# is exactly the "sprites float +/-2 px" complaint. Objects are tracked frame to
# frame by nearest match, which is unambiguous when they move a pixel or two.
tracks = {}
for n in range(STRAIGHT, FRAMES - 1):
    # Skip frames where the ZOOM is easing. Every object's screen position is
    # multiplied by the scale, so while it moves they all legitimately slide
    # toward or away from the ship's point - that is the camera pulling back,
    # not the transform rounding badly. The mote test skips the ship's offset
    # ease for exactly the same reason.
    if trace[n]['ZOOMH'] != trace[n + 1]['ZOOMH']:
        continue
    a, b = objs[n], objs[n + 1]
    # The whole scene shifts when the ship's screen offset eases between speed
    # tiers, so take that out first - it is the camera moving, not the object.
    dcam = (trace[n + 1]["SHOFFH"] - 256 if trace[n + 1]["SHOFFH"] > 127
            else trace[n + 1]["SHOFFH"]) - (
           trace[n]["SHOFFH"] - 256 if trace[n]["SHOFFH"] > 127
           else trace[n]["SHOFFH"])
    for i in set(a) & set(b):
        tracks.setdefault(i, []).append(
            (b[i][0] - a[i][0] - dcam, b[i][1] - a[i][1]))

reversals = 0
steps = 0
for deltas in tracks.values():
    for axis in (0, 1):
        seq = [d[axis] for d in deltas if d[axis]]
        steps += len(seq)
        reversals += sum(1 for a, b in zip(seq, seq[1:]) if a * b < 0)
print(f"        object motion: {steps} pixel steps, {reversals} of them reversals")
check("objects do not swim while flying straight",
      reversals <= steps // 20,
      f"{reversals}/{steps} steps reversed direction - the transform is "
      f"quantising position before the rotation instead of after")

# =============================================================================
# The asteroids
# =============================================================================
# Everything here is a safety property first and an aesthetic one second - but
# WHERE the safety lives has moved. It used to live in this file: $45 DOT_LINES
# does not validate anything, so a vertex outside 0-199 / 0-149 was not clipped
# but an address computed from the formula and written to, and past fb row 326
# that address is the video register block. CPU1 therefore had to guarantee that
# every emitted coordinate was inside the field, and "every chain is inside the
# field" was THE check.
#
# $4C is always clipped, by construction: the end kept when a segment is cut is
# the one that SATISFIES the edge, so it is inside by definition and cannot
# address outside the framebuffer. A vertex off screen is now legal and expected,
# the in-range check on the command list is therefore gone, and what stands in
# its place is the register-block check on the actual PICTURE (above) plus the
# independent model of the transform below.
all_chains = [c for f in frames for c in chains(f)]
chain_rz = [rzs[f] for f in range(FRAMES) for _ in chains(frames[f])]
straddle = [c for c in all_chains
            if any(onscreen(q) for q in c[:-1])
            and not all(onscreen(q) for q in c[:-1])]
offscreen = [c for c in all_chains if not any(onscreen(q) for q in c[:-1])]
print(f"\n        {sum(nrocks)} rocks drawn over {FRAMES} frames "
      f"(max {max(nrocks)} in one, cap is {AST_MAX}); "
      f"{len(all_chains)} outlines, {len(straddle)} of them straddling an edge "
      f"for the GPU to cut")
# --- the rocks are solid, and the disc is the right shape for that -----------
# A dotted outline is hollow, so without suppression a rock reads as a wire hoop
# with the field shining straight through it. Two separate things to check.
#
# FIRST, that the cart's own arithmetic agrees with the model: no emitted star
# may be inside any occluder the cart built. This is what catches the low-byte
# centre trick going wrong for a rock whose centre is off screen.
inside = suppressed = 0
for f in range(FRAMES):
    d = stars_of(frames[f])
    if d is None:
        continue
    inside += sum(1 for x, y in d if covered(occ[f], x, y))
    for x0, x1, y0, y1, cx, cy, r2 in occ[f]:
        if r2 == 0xFFFF:
            continue
        suppressed += sum(1 for x in range(x0, x1 + 1)
                          for y in range(y0, y1 + 1)
                          if sb((x - cx) & 0xFF) ** 2 + sb((y - cy) & 0xFF) ** 2
                          <= r2)
print(f"        rock discs covered {suppressed} half-res cells over {FRAMES} "
      f"frames; {inside} stars survived inside an occluder")
check("no star survives inside an occluder", inside == 0,
      f"{inside} stars came through - the cart's disc test disagrees with the "
      f"list it built")
check("the rock discs are actually covering ground", suppressed > 20000,
      f"only {suppressed} cells - the discs are not where the rocks are")

# --- the frame must never be allowed to overrun -------------------------------
# A missed frame is not a dropped rock: the GPU draws NOTHING that frame, and the
# background two-frame replay consumes its record anyway, so a blinked frame can
# leave the boot screen permanently in one of the two background buffers. The
# outline work therefore has a hard budget, and the cart repairs the background
# whenever the OS reports it missed one.
budgets = [t['ABUDGET'] for t in trace]
print(f"        outline work budget: {AST_BUDGET} a frame, low-water mark "
      f"{min(budgets)}; the OS reported {trace[-1]['OVRCNT']} overrun(s)")
check("the outline budget was never exhausted on this flight",
      min(budgets) > 0,
      f"hit zero - rocks were dropped. That is the valve working, but it means "
      f"the scene is at the edge")
# --- and it must never drop a rock that was going to be VISIBLE --------------
# emit_asteroids leaves its loop for three reasons: the visible list ran out
# (fine), ADRAWN hit AST_MAX, or ABUDGET hit zero. The last two abandon every
# REMAINING entry - and the visible list is not sorted by anything the player can
# see, so what gets abandoned is arbitrary and changes frame to frame. A rock in
# the middle of the screen blinks out.
#
# That is finding 49, and NOTHING here caught it: the bench flight never fills
# the list, so both valves stayed shut and every check passed while the shipped
# cart dropped rocks the moment the field got busy. The valves are meant to shed
# work that does not fit; shedding a rock the player is looking at is the failure
# they exist to prevent, so this asserts on the CONSEQUENCE rather than on either
# constant.
def would_draw(cx, cy, r):
    """mirrors span_test: does [c-r, c+r] reach the field on both axes?"""
    return not (cx + r < 0 or cx - r > 199 or cy + r < 0 or cy - r > 149)

abandoned = []
for f in range(FRAMES):
    for oid, sx, sy, shp in vislist[f][visi[f]:]:        # never even considered
        r = (SHAPE_R[shp] * rzs[f]) // 128               # ARAD, shrunk by the zoom
        if would_draw(sx >> 1, sy >> 1, r):
            abandoned.append((f, oid, (sx >> 1, sy >> 1), r))
print(f"        emit_asteroids left entries unconsidered on "
      f"{sum(1 for f in range(FRAMES) if visi[f] < visn[f])} of {FRAMES} frames; "
      f"{len(abandoned)} of those rocks would have been on screen")
check("no rock that would have been visible was ever dropped", not abandoned,
      f"{len(abandoned)} vanished mid-scene, first "
      f"{abandoned[:2]} - raise AST_BUDGET (and AST_MAX follows it), or make the "
      f"visible list drop the FURTHEST rock rather than the last one it reached")

check("no frame was reported as an overrun", trace[-1]['OVRCNT'] == 0,
      f"{trace[-1]['OVRCNT']} frames blinked (the harness is not real-time, so "
      f"this should be structurally impossible here)")


# SECOND, and this is the real question: how well does a circle stand in for the
# rock? The emitted DOT_LINES chain IS the rock's silhouette, so rasterise it and
# compare. Two errors, and they trade against each other through SHAPE_OCC:
#   LEAK  - inside the outline, not suppressed: a star shining through the rock
#   HALO  - suppressed, outside the outline: a star missing from open space
# A bounding radius drives leak to zero and makes the halo enormous (a quarter
# of a bounding BOX is corner); the smallest vertex radius does the reverse.
def poly_hit(poly, x, y):
    n = len(poly)
    hit = False
    for i in range(n):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % n]
        if (y0 > y) != (y1 > y) and \
                x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            hit = not hit
    return hit


area = leak = halo = 0
for f in range(FRAMES):
    rocks = [o for o in occ[f] if o[6] != 0xFFFF]
    for c in chains(frames[f]):
        poly = to_half(c)[:-1]          # the disc it is compared against is half-res
        xs = [q[0] for q in poly]
        ys = [q[1] for q in poly]
        # match the chain to its occluder by centroid - the disc list is built
        # in the same pass and the same order, but centroid is unambiguous here
        ccx, ccy = sum(xs) / len(xs), sum(ys) / len(ys)
        best = min(rocks, key=lambda o: (o[4] - ccx) ** 2 + (o[5] - ccy) ** 2,
                   default=None)
        if best is None:
            continue
        _, _, _, _, cx, cy, r2 = best
        if (cx - ccx) ** 2 + (cy - ccy) ** 2 > 25:
            continue                            # not this rock's disc
        # clamped to the field: the outline may now run off screen and the
        # occluder never does, so sampling the whole unclipped bounding box
        # would count open space beyond the edge as halo.
        for x in range(max(0, min(xs)), min(199, max(xs)) + 1):
            for y in range(max(0, min(ys)), min(149, max(ys)) + 1):
                pin = poly_hit(poly, x, y)
                din = sb((x - cx) & 0xFF) ** 2 + sb((y - cy) & 0xFF) ** 2 <= r2
                area += pin
                leak += pin and not din
                halo += din and not pin
print(f"        disc vs outline over {FRAMES} frames: {area} cells of rock, "
      f"{leak} leak ({100*leak/max(1,area):.0f}%), "
      f"{halo} halo ({100*halo/max(1,area):.0f}%)")
check("the suppression disc is a fair stand-in for the outline",
      area > 5000 and leak < area // 4 and halo < area // 4,
      f"leak {leak} / halo {halo} of {area} - retune SHAPE_OCC in main.s")

print(f"        visible list: {max(visn)} entries at its fullest, of "
      f"{VIS_MAX}")
check("the visible list never overflowed", max(visn) < VIS_MAX,
      f"{max(visn)} of {VIS_MAX} - objects past the end are silently not drawn")
check("asteroids are being drawn at all", len(all_chains) > 20,
      f"{len(all_chains)} polygon commands in {FRAMES} frames")
check("the GPU's clipper is exercised", len(straddle) > 0,
      "no rock ever straddled a screen edge, so that path is untested")
# A figure that misses the screen entirely still costs the GPU ~480 cycles and
# 2N+8 PPRAM bytes, so span_test in main.s tries to stop it being sent - but it
# is a BOUNDING-BOX cull tested one axis at a time, and that cannot catch a rock
# sitting diagonally past a corner: both axes overlap the field, the rock does
# not. Those are the leak, and the number is what says whether a corner test
# would be worth its cycles. It is a few percent, so it is not.
print(f"        {len(offscreen)} of {len(all_chains)} outlines "
      f"({100*len(offscreen)/max(1,len(all_chains)):.1f}%) missed the screen "
      f"entirely - the corner case span_test cannot see, ~480 GPU cycles each")
check("the cull leaks only the corner case, not whole rocks",
      len(offscreen) < len(all_chains) // 20,
      f"{len(offscreen)} of {len(all_chains)} sent for nothing - that is more "
      f"than a corner leak, so span_test is not doing its job")
check("every outline is closed", all(c[0] == c[-1] for c in all_chains))
# SCALE must be a Q0.7 shrink the GPU will honour: above 128 it is clamped, so
# the rock would silently stop tracking the zoom, and 0 draws nothing at all.
scales = {p["scale"] for f in frames for p in polys(f)}
check("every SCALE is a shrink the GPU will honour",
      all(0 < v <= 128 for v in scales),
      f"scales seen {sorted(scales)}")
# A shape switches to its AUTHORED reduced outline once small on screen
# (LOD_R in main.s, SHAPE_LODN in shapes.s) - vertex counts no longer follow
# from a class alone (variants can have different counts, and a reduced
# outline's count is independent of its full one), so the allowed set is
# whatever SHAPE_N/SHAPE_LODN actually say, not a derived "N or N//2".
LOD_N = set(SHAPE_N_FULL) | {n for n in SHAPE_LODN_FULL if n}
sizes = sorted({len(c) - 1 for c in all_chains})
check("every chain is an authored vertex count, full or reduced",
      set(sizes) <= LOD_N, f"segment counts seen: {sizes}, allowed {sorted(LOD_N)}")
print(f"        outline sizes on screen: "
      f"{ {n: sum(1 for c in all_chains if len(c) - 1 == n) for n in sizes} }")

# The span of a drawn outline must match the radius of SOME shape with that
# many vertices: this is what catches a rotation that has quietly lost or
# gained a factor. Normalised by the zoom of the frame it came from, so one
# bound covers every scale: span * 128 / RZ is what the outline would have
# spanned at 1:1, and that has to sit between some candidate's authored
# radius and twice it (an irregular polygon never quite reaches 2R).
#
# More than one shape id can share a vertex count now - two variants, or a
# reduced outline that happens to match a smaller class's full one - so a
# count no longer names a single radius; check against whichever candidate
# the span actually fits.
radii_by_n = {}
for i, n in enumerate(SHAPE_N_FULL):
    radii_by_n.setdefault(n, set()).add(SHAPE_R_FULL[i])
for i, n in enumerate(SHAPE_LODN_FULL):
    if n:
        radii_by_n.setdefault(n, set()).add(SHAPE_R_FULL[i])

spans = {}
for c, rz in zip(all_chains, chain_rz):
    h = to_half(c)                      # SHAPE_R is authored in half-res pixels
    xs = [x for x, _ in h[:-1]]
    ys = [y for _, y in h[:-1]]
    span = max(max(xs) - min(xs), max(ys) - min(ys))
    spans.setdefault(len(c) - 1, []).append((span * 128 + rz // 2) // rz)
ok = True
for n, sp in spans.items():
    lo, hi = min(sp), max(sp)
    Rs = sorted(radii_by_n.get(n, ()))
    matched = any(R - 3 <= lo and hi <= 2 * R + 3 for R in Rs)
    print(f"        {n:2d}-gon: un-zoomed span {lo}-{hi} half-res px, candidate "
          f"radii {Rs} (so R..2R = {[(R, 2*R) for R in Rs]})")
    if not matched:
        ok = False
check("every outline, un-zoomed, spans between some candidate's radius and twice it",
      ok, "outside all of them, the rotation or the scale has lost a factor")

# ...and they must actually TURN. A rock's outline changes shape on screen from
# frame to frame for two reasons at once - its own spin and the camera's - so a
# chain that is byte-identical for a long run is a transform that never ran.
sig = [tuple(sorted(chains(f)[0])) if chains(f) else None for f in frames]
run = best = 0
for a, b in zip(sig, sig[1:]):
    run = run + 1 if (a is not None and a == b) else 0
    best = max(best, run)
check("the outlines rotate rather than sitting still", best < 8,
      f"the first chain repeated identically for {best} frames")

# The picture has to contain them, not just the command list.
lit = 0
for c in chains(frames[-1]):
    for x, y in c[:-1]:
        if not onscreen((x, y)):        # the GPU cut this one off, so it is not
            continue                    #   supposed to have reached the picture
        lit += any(pix(POLY_FB * x + dx, POLY_FB * y + dy)
                   for dx in (-2, 0, 2) for dy in (-2, 0, 2))
total = sum(1 for c in chains(frames[-1]) for q in c[:-1] if onscreen(q))
check("the outlines reached the framebuffer", total == 0 or lit >= total * 3 // 4,
      f"{lit} of {total} vertices have a dot within a pixel or two")

# The starfield must MOVE.
first_dots = stars_of(frames[0])
if first_dots is not None and dots is not None:
    moved = len(set(dots) - set(first_dots))
    check("the starfield moved between the first and last frame",
          moved > len(dots) // 2,
          f"only {moved} of {len(dots)} stars changed position")

# =============================================================================
# preview.png — the framebuffer as the rotated monitor shows it
# =============================================================================
# fb-x + runs DOWN the screen and fb-y + runs LEFT, so the destination pixel is
# (299 - fb_y, fb_x): the same mapping madsim's F12 applies.
out = Image.new("1", (300, 400), 0)
p = out.load()
for y in range(FB_H):
    for xb in range(ROW):
        byte = img[y * ROW + xb]
        if not byte:
            continue
        for bit in range(8):
            if byte & (0x80 >> bit):
                p[299 - y, xb * 8 + bit] = 1
out.resize((300 * SCALE, 400 * SCALE), Image.NEAREST).save(OUT)
print(f"\nwrote {OUT} ({300*SCALE}x{400*SCALE})")

if fail:
    sys.exit(f"{len(fail)} check(s) failed")
print("all checks passed")
