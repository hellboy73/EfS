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
      "REFI": 0xD1}


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
        elif op == 0x47:                        # DOT_PIXELS: N, then N pairs
            n = stream[i + 1]
            out.append((op, stream[i + 1:i + 2 + 2 * n]))
            i += 2 + 2 * n
        elif op == 0x50:                        # SPRITE: id, X16, Y16
            out.append((op, stream[i + 1:i + 6]))
            i += 6
        elif op in (0x62, 0x63):                # VTEXT: cell, line, scroll, str
            j = stream.index(0, i + 4)
            out.append((op, stream[i + 1:j + 1]))
            i = j + 1
        else:
            raise RuntimeError(f"unhandled opcode ${op:02X} at {i}")
    return out


def stars_of(stream):
    for op, payload in decode(stream):
        if op == 0x47:
            n = payload[0]
            return [(payload[1 + 2 * k], payload[2 + 2 * k]) for k in range(n)]
    return None

# The bench's own geometry, mirrored from main.s. If these drift apart the
# checks below stop meaning anything, so they are asserted where possible.
HCX, HCY = 100, 74              # half-res framebuffer centre
FBCX, FBCY = 200, 149           # full-res framebuffer centre
SPR_W2, SPR_H2 = 8, 7           # sprite 0 half-extent, half-res
STAR_N = 110


def ship_fbx(shoffh):
    """Full-res framebuffer x of the ship's centre for a signed offset byte."""
    return FBCX + (shoffh - 256 if shoffh > 127 else shoffh)

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
CART = open("proto01.bin", "rb").read()
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
JOY_UP, JOY_RIGHT = 0x01, 0x08
TURN_UNTIL = 140                # a full revolution: every heading, so the
                                #   fold band below is swept from end to end

frames = []
cycles = []
trace = []
bases = []                      # BASEX/BASEY straight out of RAM, so stars keep
                                #   their identity across a turn and the rebase
                                #   can be measured directly
for f in range(FRAMES):
    cpu_mem[JOY1] = JOY_RIGHT if f < TURN_UNTIL else 0
    cpu_mem[JOY1_PRESS] = JOY_UP if f in (0, 1, 2, 3, 4, 5) else 0
    call(cpu, API_GPU_BEGIN)
    cart_reads[0] = 0
    c = call(cpu, CART_FRAME)
    cycles.append((c, cart_reads[0]))
    call(cpu, API_GPU_END)
    end = cpu_mem[0x04] | (cpu_mem[0x05] << 8)  # PPWP points AT the WAI
    frames.append(bytes(cpu_mem[PPRAM + i] for i in range(end - PPRAM + 1)))
    trace.append({k: cpu_mem[a] for k, a in ZP.items()})
    bases.append([(cpu_mem[0x0B00 + i], cpu_mem[0x0B80 + i],
                   cpu_mem[0x0D00 + i]) for i in range(STAR_N)])


def s16(lo, hi):
    v = lo | (hi << 8)
    return v - 65536 if v & 0x8000 else v


print("\nframe  head tier  ship X     ship Y     vel (8.8)        stars occl")
for f in (0, 1, 10, 30, 60, FRAMES - 1):
    t = trace[f]
    print(f"{f:5d}   ${t['HEAD']:02X}   {t['TIER']}   "
          f"${t['SHXH']:02X}{t['SHXL']:02X}      ${t['SHYH']:02X}{t['SHYL']:02X}      "
          f"{s16(t['VELXL'], t['VELXH']):+6d},{s16(t['VELYL'], t['VELYH']):+6d}   "
          f"{t['STARN']:4d}  {t['OCCN']:3d}")

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
# does: type $14 (32 px wide, no overlay), data at $F400, 26 rows.
gpu_mem[0x0300] = 0x14
gpu_mem[0x0400] = 0x00
gpu_mem[0x0500] = 0xF4
gpu_mem[0x0600] = 26

regs_hit = False
gpu = MPU(memory=gpu_mem)
for f, stream in enumerate(frames):
    img[:] = bg                                 # the hardware background copy
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

# Ground truth for where the stars were asked to go, straight out of PPRAM.
dots = stars_of(frames[-1])
check("the frame contains a DOT_PIXELS command", dots is not None)

if dots is not None:
    print(f"        {len(dots)} stars emitted of {STAR_N} in the layer "
          f"({100*len(dots)/STAR_N:.0f}%)")
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
    HUD_LINES = (2, 4, 6, 8, 10, 45, 47)
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
            sprite_rects.append((x >> 1, (x + 31) >> 1, y >> 1, (y + 25) >> 1))
    missing = [(x, y) for x, y in dots
               if not pix(2 * x, 2 * y) and x not in hud_rows
               and not any(x0 <= x <= x1 and y0 <= y <= y1
                           for x0, x1, y0, y1 in sprite_rects)]
    check("every emitted star not under the HUD reached the framebuffer",
          not missing, f"{missing}")
    # The occlusion list: no star may land inside the ship's sprite box.
    shipx = ship_fbx(trace[-1]["SHOFFH"]) >> 1
    inside = [(x, y) for x, y in dots
              if abs(x - shipx) <= SPR_W2 and abs(y - HCY) <= SPR_H2]
    check("no star was drawn inside the ship's sprite box",
          not inside, f"{inside}")
    check("stars are not all bunched in one place",
          len({x >> 5 for x, _ in dots}) >= 4 and
          len({y >> 5 for _, y in dots}) >= 3)

# The ship rides down the screen with the speed tier now, so "is it at the
# centre" is no longer the question - "is it where the offset says" is.
sx = ship_fbx(trace[-1]["SHOFFH"]) - 16
ship = sum(pix(sx + dx, FBCY - 13 + dy)
           for dx in range(32) for dy in range(26))
check("the ship sprite is drawn where the speed offset puts it", ship > 50,
      f"{ship} pixels lit in the 32x26 box at ({sx},{FBCY-13})")

# ...and it must actually have moved off centre, and eased rather than snapped.
offs = [t["SHOFFH"] - 256 if t["SHOFFH"] > 127 else t["SHOFFH"] for t in trace]
jump = max(abs(b - a) for a, b in zip(offs, offs[1:]))
print(f"        ship screen offset: {offs[0]} -> {offs[-1]} px, "
      f"largest single-frame move {jump} px")
check("the ship offset follows the speed tier", abs(offs[-1]) > 20,
      f"ended at {offs[-1]} px from centre")
check("the ship offset eases rather than snapping", jump <= 12,
      f"moved {jump} px in one frame")

# --- the reason do_stars is shaped the way it is -----------------------------
# On the straight leg the field must translate RIGIDLY: every visible star moves
# by exactly the frame's scroll step in fb_x and not at all in fb_y. The version
# this replaced failed here — it stood still for three frames and then moved
# ~100 of 110 stars by differing amounts, which is what "trembling" was.
def sb(v):
    return v - 256 if v > 127 else v


def occluders(stream, shoffh):
    """The half-res boxes the cart suppresses stars inside, rebuilt from the
    SPRITE commands it emitted. The objects move independently of the field, so
    a star can vanish behind one without the field having done anything wrong —
    those have to come out of the rigidity count or it measures occlusion."""
    hx = ship_fbx(shoffh) >> 1
    boxes = [(hx - SPR_W2, hx + SPR_W2, HCY - SPR_H2, HCY + SPR_H2)]
    for op, pl in decode(stream):
        if op != 0x50:
            continue
        cx = (pl[1] | (pl[2] << 8)) + 16        # top-left back to centre
        cy = (pl[3] | (pl[4] << 8)) + 13
        if cx & 0x8000 or cy & 0x8000:
            continue
        hx, hy = cx >> 1, cy >> 1
        boxes.append((hx - SPR_W2, hx + SPR_W2, hy - SPR_H2, hy + SPR_H2))
    return boxes


def covered(boxes, x, y):
    return any(x0 <= x <= x1 and y0 <= y <= y1 for x0, x1, y0, y1 in boxes)


rigid_ok = rigid_bad = 0
steps = []
for n in range(TURN_UNTIL + 1, FRAMES - 1):
    a, b = stars_of(frames[n]), stars_of(frames[n + 1])
    if a is None or b is None:
        continue
    d = sb((trace[n + 1]["TRAVI"] - trace[n]["TRAVI"]) & 0xFF)
    steps.append(d)
    bs = set(b)
    boxes = occluders(frames[n + 1], trace[n + 1]["SHOFFH"])
    for x, y in a:
        nx = x + d
        if not (0 <= nx < 200):
            continue                            # scrolled off the edge, fine
        if (nx, y) in bs:
            rigid_ok += 1
        elif covered(boxes, nx, y):
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
check("the field does scroll on the straight leg", moving > 5,
      "TRAVI never advanced - the travel accumulator is not running")

# --- the rebase must be smooth too -------------------------------------------
# During the turn the field rotates and translates continuously, so each star's
# base should march in one direction per axis; a reversal is the rebase rounding
# differently from one frame to the next. This is what the 8.8 tables and the
# sub-unit registration in star_rebase are for.
def sb8(v):
    return v - 256 if v > 127 else v


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
def drawn(n):
    """{star index: (fb_x, fb_y)} for the stars actually on screen in frame n."""
    out = {}
    ti = trace[n]["TRAVI"]
    for i, (bx, by, parked) in enumerate(bases[n]):
        if parked:
            continue
        fx = HCX + sb8((by + ti) & 0xFF)
        fy = HCY - sb8(bx)
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
    signs = []
    for i in set(a) & set(b):
        rx, ry = a[i][0] - HCX, a[i][1] - HCY
        vx, vy = b[i][0] - a[i][0], b[i][1] - a[i][1]
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
check("every star sweeps the way the turn does", wrong == 0,
      f"{wrong} of {tested} moved against the rotation - a folded base is "
      f"being drawn at the wrong edge")

# The drawn set must also match what the cart actually emitted, or the model
# above is measuring something other than the screen.
model = set(drawn(FRAMES - 1).values())
emitted = set(dots)
# The forced refresh has to actually fire, or parked stars are never brought
# back and a long straight flight thins the leading edge.
refs = sum(1 for a, b in zip(trace[TURN_UNTIL:], trace[TURN_UNTIL + 1:])
           if a["REFI"] != b["REFI"])
print(f"        straight leg: {refs} forced refresh(es)")
check("the parked set is refreshed while flying straight", refs >= 1,
      "REFI never moved - parked stars would never come back")

check("the reconstructed star set matches the emitted one",
      emitted <= model and len(model) - len(emitted) <= len(model) // 3,
      f"model {len(model)}, emitted {len(emitted)} (occlusion removes some)")

# --- objects must not swim ---------------------------------------------------
# On the straight leg both the ship and the objects move at constant velocity, so
# every object's true path across the screen is a straight line at constant
# speed. Any reversal in a screen coordinate is pure quantisation noise — which
# is exactly the "sprites float +/-2 px" complaint. Objects are tracked frame to
# frame by nearest match, which is unambiguous when they move a pixel or two.
def sprites_of(stream):
    out = []
    for op, pl in decode(stream):
        if op == 0x50:
            x = pl[1] | (pl[2] << 8)
            y = pl[3] | (pl[4] << 8)
            out.append((x - 65536 if x & 0x8000 else x,
                        y - 65536 if y & 0x8000 else y))
    return out


tracks = {}
prev = None
for n in range(TURN_UNTIL + 1, FRAMES):
    cur = sprites_of(frames[n])
    if prev is not None:
        for i, (x, y) in enumerate(prev):
            best = min(cur, key=lambda q: abs(q[0] - x) + abs(q[1] - y),
                       default=None)
            if best is None or abs(best[0] - x) + abs(best[1] - y) > 6:
                continue
            tracks.setdefault(i, []).append((best[0] - x, best[1] - y))
    prev = cur

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
