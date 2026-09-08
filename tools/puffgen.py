#!/usr/bin/env python3
"""EXPL_OFF -> one PNG per puff frame, ready for tools/sprgen.py --tate.

    python tools/puffgen.py                     # 2 sizes x 24 frames, cloud 0
    python tools/puffgen.py --cloud 2           # a different authored cloud
    python tools/puffgen.py --lag 2             # how far back the ghost ring is
    python tools/puffgen.py --out assets/png    # where they land

WHY THIS EXISTS. The mini explosion used to be a 3,072-byte table of eight
(dx, dy) offsets per cloud, per size, per age (src/shots.s, EXPL_OFF), replayed
by CPU1 into a DOT_PIXELS payload every frame: eight table reads, eight
sign-extended 16-bit adds and two range tests PER DOT, six puffs at a time.
Drawn as SPRITES instead it is ONE command per puff and the CPU does nothing at
all - which is the whole point, and it also gets the 3 KB out of the $2000-$5FFF
run window.

THE SOURCE IS STILL EXPL_OFF. Nothing is redrawn here: the clouds are the ones
that were authored, jitter and all, read straight out of src/shots.s so the two
cannot drift. This script only RESAMPLES them into pixels.

THE BLUR. Each frame carries TWO rings - its own age and an earlier one - so a
single sprite shows where the pixels are and where they just were. On a 1-bit
screen that is the only motion cue available (there is no dimming), and it costs
nothing: the dots go in the same sprite. The first --lag frames have no
predecessor and show one ring.

--lag IS NOT COSMETIC. The radii EASE OUT, so late in the animation two
CONSECUTIVE ages differ by less than a pixel and, at the 1:1 scale below, round
to the same pixels - the trailing ring lands exactly on the leading one and the
blur disappears over the last third. Measured distinct-dot counts per frame,
size 1, cloud 0:

    lag 1   8 14 16 16 14 15 13 15 14 15 12 12 15 11 12 10 12 7 7 7 7 4 4 4
    lag 2   8  8 16 16 16 16 16 16 16 16 16 15 16 15 14 14 13 13 8 8 8 7 4 4

Two rings of eight is 16, so lag 2 keeps them fully apart through frame 12 where
lag 1 has already started merging. The cost is that the ghost trails one frame
further back.

SCALE, AND THE ONE THING THAT CHANGED. A half-res DOT_PIXEL lands on full-res
pixel 2*x, so the old puff was drawn at TWICE the offsets stored in EXPL_OFF:
53 px across at size 0 and 81 at size 1. A sprite's width comes from a type
nibble and the widest it encodes is 64 px (MAD65_GPU_OS.md), so 81 does not fit
and never will. Written at 1:1 instead - one sprite pixel per stored unit - the
same authored dot pattern lands in 27 px and 41 px, which fit the 32 and 64
buckets exactly. The puff is therefore HALF the size it used to be. That is a
deliberate trade and the only visual change: everything else is the art that was
already there.

TATE. The offsets in EXPL_OFF are FRAMEBUFFER deltas (expl_one adds them to a
zoom_fb result). The PNG is authored UPRIGHT in the player's 300x400 portrait
view, like every other asset in this repo, and sprgen.py --tate turns it. For a
delta the framebuffer->portrait map (design_technical 2: fb-x+ = screen down,
fb-y+ = screen left) is:

    portrait_dx = -fb_dy        portrait_dy = +fb_dx

CANVAS. Square, side = the width bucket, cloud centred on (side/2, side/2). Not
a tight bounding box: a fixed square means the emitter places every frame of a
size with ONE constant (X = cx - side/2) instead of a per-age offset table, and
sprgen never has to pad, so its centring rule cannot bite.
"""

import os
import re
import sys

from PIL import Image

SRC = os.path.join("src", "shots.s")

# Mirrors shots.s. Asserted against what is actually parsed.
EXPL_SETS = 4
EXPL_SIZES = 2
EXPL_AGES = 24
EXPL_DOTS_N = 8
# EXPL_DOTS - how many of the eight are drawn at each age. The cloud THINS
# rather than fades, so a frame's ring is a PREFIX of its block.
EXPL_DOTS = [8] * 16 + [6] * 4 + [4] * 4

# One square canvas per size, from the measured reach of each (13 and 20 units).
# Both are the smallest encodable bucket that holds 2*max+2, so the outermost
# dot still has a pixel of margin.
SIDE = (32, 64)

WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)


def parse_expl_off(path):
    """The EXPL_OFF block of src/shots.s -> [size][cloud][age] = 16 signed ints.

    Reads the .byte lines between the EXPL_OFF label and the next label. The
    assembler writes negatives as `<-2` (the lo-byte operator applied to a
    negative), so the `<` is stripped before the int().
    """
    text = open(path, encoding="utf-8", errors="replace").read()
    start = text.index("\nEXPL_OFF:")
    body = text[start + len("\nEXPL_OFF:"):]
    vals = []
    for line in body.splitlines():
        line = line.split(";", 1)[0].strip()
        if not line:
            continue
        if not line.startswith(".byte"):
            if re.match(r"^[A-Za-z_.][A-Za-z0-9_]*:", line):
                break          # the next label: EXPL_OFF is over
            continue
        for tok in line[len(".byte"):].split(","):
            tok = tok.strip().lstrip("<")
            if tok:
                vals.append(int(tok, 0))

    want = EXPL_SIZES * EXPL_SETS * EXPL_AGES * EXPL_DOTS_N * 2
    if len(vals) != want:
        sys.exit(f"{path}: parsed {len(vals)} bytes of EXPL_OFF, expected {want}")

    out = []
    i = 0
    for _ in range(EXPL_SIZES):
        clouds = []
        for _ in range(EXPL_SETS):
            ages = []
            for _ in range(EXPL_AGES):
                ages.append(vals[i:i + 16])
                i += 16
            clouds.append(ages)
        out.append(clouds)
    return out


def ring(block, age):
    """The (dx, dy) pairs actually DRAWN at this age - EXPL_DOTS of them."""
    return [(block[2 * k], block[2 * k + 1]) for k in range(EXPL_DOTS[age])]


def render(ages, age, side, lag):
    """One frame: this age's ring plus the one `lag` ages back, centred."""
    im = Image.new("RGBA", (side, side), CLEAR)
    px = im.load()
    c = side // 2
    dots = ring(ages[age], age)
    if age >= lag:
        dots += ring(ages[age - lag], age - lag)  # the blur: where they just were
    painted = 0
    for dx, dy in dots:
        x = c - dy                                # fb -> portrait, for a delta
        y = c + dx
        if 0 <= x < side and 0 <= y < side:
            px[x, y] = WHITE
            painted += 1
        else:
            sys.exit(f"dot ({dx},{dy}) falls outside the {side}x{side} canvas")
    return im, painted


def main(cloud, outdir, lag):
    table = parse_expl_off(SRC)
    if not 0 <= cloud < EXPL_SETS:
        sys.exit(f"--cloud must be 0..{EXPL_SETS - 1}")
    if not 1 <= lag < EXPL_AGES:
        sys.exit(f"--lag must be 1..{EXPL_AGES - 1}")
    os.makedirs(outdir, exist_ok=True)

    total_bytes = 0
    for size in range(EXPL_SIZES):
        side = SIDE[size]
        wb = side // 8
        reach = max(max(abs(v) for v in blk) for blk in table[size][cloud])
        per_frame = wb * side                     # no overlay plane: W bytes/row
        print(f"size {size}: cloud {cloud} reaches {reach} units -> "
              f"{side}x{side} sprite, {per_frame} B/frame "
              f"(type ${(wb if wb != 8 else 8) | 0x10:02X})")
        for age in range(EXPL_AGES):
            im, n = render(table[size][cloud], age, side, lag)
            name = f"puff_s{size}_f{age:02d}.png"
            im.save(os.path.join(outdir, name))
            total_bytes += per_frame
        print(f"           {EXPL_AGES} frames -> {EXPL_AGES * per_frame} B "
              f"of GPU RAM ({EXPL_AGES * per_frame / 256:.0f} LOAD pages)")

    print(f"\n{EXPL_SIZES * EXPL_AGES} PNGs in {outdir}")
    print(f"GPU RAM for the whole set: {total_bytes} B "
          f"({total_bytes / 256:.0f} pages of the ~100 free from $1200)")


if __name__ == "__main__":
    a = sys.argv[1:]
    cloud, outdir, lag = 0, os.path.join("assets", "png"), 1
    if "--cloud" in a:
        i = a.index("--cloud")
        cloud = int(a[i + 1])
        a = a[:i] + a[i + 2:]
    if "--lag" in a:
        i = a.index("--lag")
        lag = int(a[i + 1])
        a = a[:i] + a[i + 2:]
    if "--out" in a:
        i = a.index("--out")
        outdir = a[i + 1]
        a = a[:i] + a[i + 2:]
    if a:
        sys.exit(__doc__)
    main(cloud, outdir, lag)
