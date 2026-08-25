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
  half-res `DOT_PIXELS` - single pixels, but only on even coordinates, so they
  sit on a 2-pixel lattice. They are *not* world objects: no world coordinates,
  no zoom, no collision. They drift at **1/4** of the ship's speed. Flying
  scrolls them along one axis; only *turning* rotates them - see finding 6.
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
| JOY2 FIRE | toggle speed-coupled turn rate |

Speed tiers, in pixels per second: `-60, -30, 0, +15, +30, +60, +121, +181,
+271, +392`. The top tier crosses the 400-pixel screen height in about a second.

Turn rates, in milliseconds per full revolution: `5659, 4244, 3396, 2830, 2425,
2122, 1698, 1415`. **The default is 2122 ms.** Flying the first version showed
that 1-3 brad per frame was the usable band and that whole-brad steps inside it
were far too coarse, so the heading now carries a **fraction** and the ladder
steps a quarter of a brad at a time. Only the integer part of the heading is ever
used for cos/sin - and only a change in *that* rebases the starfield, so a slow
turn also rebases less often.

**Speed-coupled turning** (joystick 2's button) makes the rate rise with flight
speed: `rate x (1 + xtra/128)`, unchanged at a standstill and doubled at top
speed. Turn radius is `v/omega`, so a constant omega makes the radius grow in
proportion to speed; this halves that growth without making the ship spin like a
top when it is crawling. The HUD shows the multiplier. It is off by default - the
point is to be able to flip it back and forth and feel the difference.

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

**2. The rotation tables work.** The bench builds two 256-byte tables,
`ROTC[i] = i·cos/128` and `ROTS[i] = i·sin/128`, as a running 16-bit sum. The
whole star transform is then **four table lookups and two adds per star** — no
multiply at all. Since finding 6 the tables are only built on frames where the
heading moved, so a straight frame is **22% of one CPU** and a turning frame
**39%**, everything included (110 stars, 7 transformed objects, six HUD strings,
the occlusion pass). madsim's own meter agrees: 23% CPU1, 22% GPU.

**3. PPRAM is not the constraint here.** A steady frame is **250 bytes of the
2047-byte list**, 12%. Stars cost 2 bytes each and the HUD costs about 128. That
leaves a great deal of room for asteroid outlines.

**4. Text opcodes are destructive.** `TEXT`/`VTEXT` write whole character cells,
background included — they do not OR a glyph over what is already there. An
image-layer HUD therefore punches black rectangles into the starfield. The bench
shows this (and `preview.py` excludes those rows from its "every star was
drawn" check rather than pretending otherwise). For the real game this argues
for putting the HUD on the **background** layer, where it is also free.

Note that this bench's HUD is on the **image** layer on purpose, six `VTEXT`
commands every frame. That is legal — image-layer commands are never replayed —
but it is *not* what the game will do, and it would be illegal on the background:
there, only one write per frame is allowed plus a cooldown frame, so a three-line
HUD refreshes on a 6-frame round-robin. See `design_technical.md` 5.5.

**5. About 40% of the star layer is on screen.** 35–48 of 110, against the ~46%
the geometry predicts; the occlusion pass eats the rest. If a denser field is
wanted, raising `STAR_N` is nearly free on PPRAM and linear on CPU.

**6. A rotating starfield must not be rotated every frame.** The first version
computed every star's position from the layer each frame. It shook at most
headings and looked fine at a few, and the dumps said why: the tables round to
whole pixels, so the sub-unit part of the sample was being thrown away. The field
stood still for three or four frames and then ~100 of 110 stars jumped at once by
*differing* amounts — each star's rounding flipping at its own moment. Near an
axis one table is almost the identity and the other almost zero, so the same
lurch came out uniform and read as smooth.

The fix drops the per-frame rotation entirely. Because the camera maps the ship's
heading onto view-up, flying translates the field along **one axis only**, exactly,
by a scalar that can be carried in 8.8. So each star keeps a view-space byte pair,
every frame adds the integer part of that scalar to view-y (the byte wrap *is* the
view torus), and the positions are rebuilt from the layer **only when the heading
changes**. The field now translates rigidly at every heading — `preview.py`
asserts it: 3130 star-moves in step with the field, 0 out of step.

Two traps found on the way: rotating the stored positions by the frame's small
heading delta instead of rebuilding is cheaper but the table matrix's determinant
is ~0.987, so the field implodes about 20% per quarter turn; and a rebuild
re-registers against the integer sample, which used to shift the whole field by
up to a pixel.

**7. Rebuilds have to be smooth too.** Turning still shimmered, for two reasons
that were both cheap to remove. The rotation tables floored each lookup and the
two were then added, so the error was twice as large as it needed to be and was
not a smooth function of the heading; they now carry the fraction (which the
running-sum build produces for free) and the sum is floored **once**. And a
rebuild registered the field against the *integer* sample, throwing away the
sub-unit part; it now subtracts `R * frac`, four multiplies on a frame that is
rebuilding 110 stars anyway. `preview.py` reads the star bases straight out of
RAM - so stars keep their identity through a turn - and counts direction
reversals: **2180 base steps, 32 reversals**.

**8. Objects were swimming because they were rounded before the rotation, not
after.** The transform used to truncate the world delta to whole pixels first,
throwing away four bits of position, and the rotation turned that into one to two
pixels of visible wander at low speed. The multiply that forced it was
shift-and-add LSB-first, which shifts the multiplicand left six times and so
capped it near 1024. Rewriting it MSB-first shifts the *accumulator* instead, the
multiplicand never moves, and objects can be rotated at full 1/16-pixel
resolution and rounded once at the end. On a straight leg with constant
velocities every object's path is a straight line, so any reversal is pure
quantisation noise: **463 pixel steps, 5 reversals**.

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
