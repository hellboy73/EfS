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
      "REFI": 0xD1, "HEADF": 0xC5,
      "TURNVL": 0xDF, "TURNVH": 0xE0, "RAMPIX": 0xE1}


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

# The bench's own geometry, mirrored from main.s. If these drift apart the
# checks below stop meaning anything, so they are asserted where possible.
HCX, HCY = 100, 74              # half-res framebuffer centre
FBCX, FBCY = 200, 149           # full-res framebuffer centre
SPR_W2, SPR_H2 = 8, 7           # sprite 0 half-extent, half-res
STAR_N = 88
MOTE_N = 10
NOBJ = 250


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
JOY_UP, JOY_DOWN, JOY_RIGHT = 0x01, 0x02, 0x08
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
motepos = []                    # per-mote screen position by index, from RAM
bases = []                      # BASEX/BASEY straight out of RAM, so stars keep
                                #   their identity across a turn and the rebase
                                #   can be measured directly
for f in range(FRAMES):
    cpu_mem[JOY1] = JOY_RIGHT if f < TURN_UNTIL else 0
    # Climb the tiers at the start, then change speed again TWICE on the
    # straight leg: the ship's screen offset eases over ~40 frames after every
    # tier change, and that ease used to force a full star rebuild - which is
    # what made stars twitch sideways for a few frames each time.
    press = 0
    if f in (0, 1, 2, 3, 4, 5):
        press = JOY_UP
    elif f == 130:
        press = JOY_DOWN
    elif f == 160:
        press = JOY_UP
    cpu_mem[JOY1_PRESS] = press
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
    rot.append(([cpu_mem[0x0400 + i] for i in range(256)],
                [cpu_mem[0x0600 + i] for i in range(256)],
                cpu_mem[0xA2], cpu_mem[0xA3]))
    # Object screen positions BY INDEX, straight out of RAM. Matching sprites by
    # nearest neighbour worked with seven objects and stops working with 250:
    # one leaving the screen gets paired with another arriving, and the pairing
    # invents reversals that never happened.
    vis = {}
    for i in range(NOBJ):
        if cpu_mem[0x1E00 + i]:
            vis[i] = (s16(cpu_mem[0x1A00 + i], cpu_mem[0x1B00 + i]),
                      s16(cpu_mem[0x1C00 + i], cpu_mem[0x1D00 + i]))
    objs.append(vis)
    mvis = {}
    for i in range(MOTE_N):
        if cpu_mem[0x0DE0 + i]:
            mvis[i] = (cpu_mem[0x0DC0 + i], cpu_mem[0x0DD0 + i])
    motepos.append(mvis)
    # The occluder boxes exactly as the cart built them. Rebuilding them from
    # the emitted SPRITE commands nearly works and disagrees on about one star
    # in four thousand, which is enough to make a strict rigidity check useless.
    nb = cpu_mem[0xA1]
    occ.append([(cpu_mem[0x0A00 + k], cpu_mem[0x0A20 + k],
                 cpu_mem[0x0A40 + k], cpu_mem[0x0A60 + k]) for k in range(nb)])


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
mrev = msteps = 0
for deltas in _mtracks.values():
    for axis in (0, 1):
        seq = [d[axis] for d in deltas if d[axis]]
        msteps += len(seq)
        mrev += sum(1 for u, v in zip(seq, seq[1:]) if u * v < 0)
print(f"        mote motion: {msteps} pixel steps, {mrev} of them reversals")
check("the motes do not twitch", mrev <= msteps // 40,
      f"{mrev}/{msteps} steps reversed - the mote transform is truncating twice "
      f"or missing its sub-unit registration")

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


def covered(boxes, x, y):
    return any(x0 <= x <= x1 and y0 <= y <= y1 for x0, x1, y0, y1 in boxes)


print(f"        heading changes after the turn stopped: {drift}")
rigid_ok = rigid_bad = 0
steps = []
for n in range(STRAIGHT, FRAMES - 1):
    a, b = stars_of(frames[n]), stars_of(frames[n + 1])
    if a is None or b is None:
        continue
    d = sb((trace[n + 1]["TRAVI"] - trace[n]["TRAVI"]) & 0xFF)
    steps.append(d)
    bs = set(b)
    boxes = occ[n + 1]
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
    cx = ship_fbx(trace[n]["SHOFFH"]) >> 1      # the pivot is the SHIP, not the
    common = set(a) & set(b)                    #   screen centre
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
        rx, ry = a[i][0] - cx, a[i][1] - HCY
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
# with parking off this run reports 65, with it on, 3.
check("every star sweeps the way the turn does", wrong <= tested // 500,
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
# that true: it sits ahead of the ship by the ship's screen offset, so it swings
# around the ship as the heading changes. Run the star transform on the SHIP's
# own layer position and check it lands on the ship's sprite.
worst = 0
for n in range(2, TURN_UNTIL):
    ci, si, sx, sy = rot[n]
    t = trace[n]
    shipx = ((t["SHXH"] << 1) | (t["SHXL"] >> 7)) & 0xFF
    shipy = ((t["SHYH"] << 1) | (t["SHYL"] >> 7)) & 0xFF
    dx, dy = (shipx - sx) & 0xFF, (shipy - sy) & 0xFF
    view_y = sb8(ci[dy]) - sb8(si[dx])          # the same sum the cart makes
    star_at_ship = HCX + view_y
    drawn_ship = ship_fbx(t["SHOFFH"]) >> 1     # the sprite's own half-res centre
    worst = max(worst, abs(star_at_ship - drawn_ship))
print(f"        pivot: star transform of the ship's own position lands within "
      f"{worst} px of the ship")
check("the star field pivots on the ship", worst <= 3,
      f"{worst} px off - the field is turning about the wrong point, which is "
      f"what makes a turn feel like a strafe")

# --- objects must not swim ---------------------------------------------------
# On the straight leg both the ship and the objects move at constant velocity, so
# every object's true path across the screen is a straight line at constant
# speed. Any reversal in a screen coordinate is pure quantisation noise — which
# is exactly the "sprites float +/-2 px" complaint. Objects are tracked frame to
# frame by nearest match, which is unambiguous when they move a pixel or two.
tracks = {}
for n in range(STRAIGHT, FRAMES - 1):
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
