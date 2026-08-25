# proto 01 — flight model bench

The first thing built for Escape from Saturn, and deliberately not a game. It
exists to answer one question — **what does flying this ship have to feel like**
— and to put real numbers under the assumptions in
[`docs/design_technical.md`](../../docs/design_technical.md).

```bash
make run
```

Or `run.bat`. The monitor starts on its side (`--tate`); `F12` toggles it,
`F3` shows the CPU/GPU utilisation meter.

```bash
python preview.py
```

runs the whole thing headless — cart → CPU OS → PPRAM → GPU OS in py65 — checks
the geometry, reports the cycle budget, and writes `preview.png`.

---

## What is on screen

- **A starfield.** 110 stars in their own 256 × 256 wrapping layer, drawn as
  half-res `DOT_PIXELS`. They are *not* world objects: no world coordinates, no
  zoom, no collision. They drift at **1/8** of the ship's speed and they rotate
  with the camera.
- **The ship.** Sprite 0 (the GPU's built-in test sprite — placeholder art),
  fixed dead centre, always nose-up.
- **Seven drifting objects.** Also sprite 0, but with real world positions and
  velocities, so they show what the transform does to something that is actually
  out there.
- **A HUD**: speed in px/s, turn rate in milliseconds per revolution, heading,
  and the number of stars that survived clipping.

## Controls (joystick 1)

| | |
|---|---|
| LEFT / RIGHT | turn (held) |
| UP / DOWN | one speed tier up / down (on press) |
| FIRE | cycle the turn rate |

Speed tiers, in pixels per second: `-60, -30, 0, +15, +30, +60, +121, +181,
+271, +392`. The top tier crosses the 400-pixel screen height in about a second.

Turn rates, in milliseconds per full revolution: `4244, 2122, 1415, 1061, 707,
531`. **The default is 2122 ms.** The last one, 531 ms, is the "1/32 of a turn
per frame" idea from the original brief — it is in the list so it can be felt,
but half a second for a full revolution is roughly four times faster than
*Asteroids* and it is very hard to fly.

---

## What it measured

**1. Model B is not optional — it is worth 2.5×.**
Running the game code in place in the `$8000` window costs 3 wait states on
every read, instruction fetches included. Same frame, same work:

| | cycles/frame | of the 237,404 budget |
|---|---|---|
| code running in the cartridge window | ~182,000 | **77%** |
| code copied to RAM first (Model B) | ~72,000 | **30%** |

35,000 cartridge reads a frame × 3 wait states is the entire difference.
`bootstrap.s` does the copy; `preview.py` prints the read count every run, so a
regression shows up immediately.

**2. The rotation tables work.** Per frame the bench builds two 256-byte tables,
`ROTC[i] = i·cos/128` and `ROTS[i] = i·sin/128`, as a running 16-bit sum. After
that the whole star transform is **four table lookups and two adds per star** —
no multiply in the inner loop at all. 110 stars, 7 transformed objects, six HUD
strings and the occlusion pass together come to **30% of one CPU's frame**.

**3. PPRAM is not the constraint here.** A steady frame is **250 bytes of the
2047-byte list**, 12%. Stars cost 2 bytes each and the HUD costs about 128. That
leaves a great deal of room for asteroid outlines.

**4. Text opcodes are destructive.** `TEXT`/`VTEXT` write whole character cells,
background included — they do not OR a glyph over what is already there. An
image-layer HUD therefore punches black rectangles into the starfield. The bench
shows this (and `preview.py` excludes those rows from its "every star was
drawn" check rather than pretending otherwise). For the real game this argues
for putting the HUD on the **background** layer, where it is also free.

**5. About a third of the star layer is on screen.** 35–48 of 110, against the
~46% the geometry predicts; the occlusion pass eats the rest. If a denser field
is wanted, raising `STAR_N` is nearly free on PPRAM and linear on CPU.

---

## Two things it deliberately gets "wrong"

**Heading is 256 steps, not 32.** The design assumes the ship flies in one of 32
directions. Since the ship is always drawn nose-up, the only place that choice
can show is the smoothness of the world's rotation — so the bench runs at full
8-bit brad resolution, and the question to answer while flying it is whether 32
steps (11.25° a click) would have been visibly steppy. If it would not be, 32 is
free; if it would, the design should say 256 and stop pretending.

**Star occlusion is done the naive way.** Every star is tested against every
sprite box, because sprite 0 has no overlay plane and stars otherwise shine
straight through the ship. Real asteroids will need this for a better reason —
a dot-line outline is *hollow* — and at 20 rocks the naive cost becomes stars ×
rocks. The coarse disc mask in `design_technical.md` 5.4 is the intended
replacement; this version exists to give it a number to beat.

---

## Files

```
header.s      "MAD65" signature + the two vectors, pointing at the bootstrap
bootstrap.s   Model B: copies CODE+RODATA out of the window into RAM at $2000
main.s        the bench itself — camera, ship, objects, starfield, HUD
mad65.inc     the OS entry points and RAM locations this cart uses
cart.cfg      ld65 config: one 8 KB bank, load in ROM / run in RAM
preview.py    headless end-to-end check, cycle budget, and preview.png
```

## Notes for whoever edits this next

- **The wrap is free.** World positions are 16-bit and wrap by overflow; a
  16-bit subtract read as signed is the shortest distance across the seam. Any
  code that tests for a world boundary is a bug.
- **Do not use the OS `rng` here.** It clobbers X, and its seed is set up by
  CPU1 boot — which the py65 harness does not run, so an unseeded LFSR makes
  every star land on the same pixel. The cart carries its own `prng`, which also
  makes the bench reproducible.
- The coordinate mapping (TATE clockwise, `fb_x = portrait_y`,
  `fb_y = 299 - portrait_x`) is written out at the top of `main.s`. Read it
  before touching anything that positions something on screen.
