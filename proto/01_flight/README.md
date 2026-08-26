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

- **A starfield.** 88 stars in their own 256 × 256 wrapping layer, drawn as
  half-res `DOT_PIXELS` - single pixels, but only on even coordinates, so they
  sit on a 2-pixel lattice. They are *not* world objects: no world coordinates,
  no zoom, no collision. They drift at **1/4** of the ship's speed. Flying
  scrolls them along one axis; only *turning* rotates them - see finding 6.
- **Motes.** A second layer, 10 specks (about 5 on screen), running at **twice**
  the ship's speed and drawn **in front of everything**. They are there to sell
  speed when there is nothing else in view. Being in front is what makes them
  cheap: no occlusion pass, and being few they need none of the starfield's
  rebuild-and-scroll machinery — they are transformed from scratch every frame.
  They do still need its *arithmetic* — see finding 15.
- **The ship.** `assets/png/ship32.png`, 32 × 32 with an overlay plane, run
  through `tools/sprgen.py --tate` into `ship32.s` and installed into sprite
  slot 1 at boot. Always nose-up, riding up and down the screen with the speed
  tier. Slot 0 is deliberately left as the GPU's ROM test sprite, so an id typo
  draws something recognisable rather than nothing.
- **200 asteroids** with real world positions, velocities and spins, scattered
  over the whole torus — three to six on camera at a time. Each is a **closed
  dotted outline** at one of **five sizes: 192, 128, 64, 32 and 16** full-res
  pixels across, rotated by (its own spin — the heading) every frame. **Stars
  go out underneath one**, so a rock reads as a solid body and not as a wire
  hoop. Nothing collides with anything: you fly straight through them.
- **A HUD**: speed in px/s, turn rate in milliseconds per revolution, heading,
  the number of stars that survived clipping, and `A` — how many rocks were
  drawn this frame.

### The rocks, and how to change them

Everything about them is a hand-written table at the bottom of `main.s`, meant
to be edited and looked at:

| table | what it sets |
|---|---|
| `SHP192` … `SHP16` | the outlines themselves — signed byte `x,y` pairs in **half-res** pixels, origin-centred, wound in order. The 192 rock has radius 48 here, not 96. |
| `SHAPE_N` / `SHAPE_R` | vertices and bounding radius per size (12, 10, 8, 6, 5 / 48, 32, 16, 8, 4) |
| `SHAPE_OCC` | the radius the **stars go out under**, per size (39, 26, 13, 7, 3). Not the bounding radius — see finding 22 |
| `SHAPE_PICK` | the size mix — eight tickets over the five classes |
| `AST_VEL` | four drift vectors per size, **hardcoded**, picked by `index & 3`. 8 px/s for the 192s up to 50 px/s for the 16s |
| `AST_SPIN` | one spin rate per size, 8.8 brad/frame: 45 s a revolution for the 192, 2.8 s for the 16 |
| `AST_PHASE` | eight starting angles, so they do not all turn in step |

Nothing here is random except *where* a rock is and *which size* it is. The
velocities and spins are authored, so the field is identical every run and
anything odd in it can be reproduced by flying the same way twice.

The only hard rule on a vertex is `|x|, |y| ≤ 127`: the multiply indexes its
table with `|x| + |cos|` and that has to stay inside a byte.

## Controls (joystick 1)

| | |
|---|---|
| LEFT / RIGHT | turn (held) |
| UP / DOWN | one speed tier up / down (on press) |
| FIRE | cycle the turn rate |
| JOY2 FIRE | step the speed-coupling strength |
| JOY2 LEFT/RIGHT | step how sharply the turn winds up |

Speed tiers, in pixels per second: `-150, -100, -50, 0, +50, +100, +150, +200,
+250, +300, +350`. Those are exact, not approximate: a world unit is 1/16 of a
pixel and the frame is 60.317 Hz, so one unit per frame is 3.77 px/s and no whole
number of units lands on a round speed. The speed is therefore kept as **8.8**,
which also removed the separate byte-wide velocity multiply — the ordinary
16-bit one does the job.

**The ship rides the speed.** It sits centred at rest, slides down the screen as
it accelerates (up to 120 px below centre at +350) and lifts above centre in
reverse (up to 80 px), so the player is always looking at where they are going.
It **eases** toward each tier's target rather than snapping — a jump on every tier
change is unreadable — and that ease is the camera-lag constant the design still
has to settle (`SHOFF_LAG`, currently 1/16 of the gap per frame).

Turn rates, in milliseconds per full revolution: `5659, 4244, 3396, 2830, 2425,
2122, 1698, 1415`. **The default is 2122 ms.** Flying the first version showed
that 1-3 brad per frame was the usable band and that whole-brad steps inside it
were far too coarse, so the heading now carries a **fraction** and the ladder
steps a quarter of a brad at a time. Only the integer part of the heading is ever
used for cos/sin - and only a change in *that* rebases the starfield, so a slow
turn also rebases less often.

**The turn has momentum.** The stick sets a *target* angular velocity and the
real one eases toward it, so a turn winds up and unwinds instead of switching on
and off. Ramp 0 is the old on/off behaviour, kept so the two can be flown back to
back; the HUD shows which. At ramp 2 the turn takes about 50 frames to stop after
the stick is released — worth knowing, because "flying straight" starts later
than it looks.

**Speed-coupled turning** (joystick 2's button) makes the rate rise with flight
speed. Turn radius is `v/omega`, so a constant omega lets the radius grow in
proportion to speed — at +350 the ship sweeps a circle seven times wider than at
+50. The first cut doubled the rate at top speed and rose far too fast to fly, so
it is now a **strength dial**: OFF, then ×1.12, ×1.25 or ×1.50 at the top tier,
scaling smoothly to ×1.00 at a standstill. The HUD shows which. Off by default —
the point is to flip between them and feel the difference.

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

**10. The world has to pivot on the ship, and doing it naively costs four times
the stars.** Turning felt like a strafe because the world rotated about the
screen centre while the ship sat below it. Objects were a one-line fix. The star
layer was not: it only reaches 128 units from wherever it is centred, and pivoting
on the ship centres it on the ship, putting the top of the screen 160 units away —
past the end of the layer.

The fix costs nothing: **sample the layer at the point the screen centre looks
at**, which is the ship plus its screen offset along the heading. The layer then
sits centred on the screen where it is needed, and the pivot still lands on the
ship, because that sample point swings around the ship as the heading changes.

The trap inside it is that the sample is parallax-scaled, so the offset arrives a
quarter-strength and the field pivots a quarter of the way to the ship — still a
strafe. Rotation has no parallax, and the camera's swing is part of turning, so
the offset is pre-multiplied to cancel it. `preview.py` runs the star transform on
the **ship's own layer position** and checks it lands on the ship's sprite: **2 px**.

**11. A field of objects, and what one costs whether or not you can see it.**
Seven reference objects meant flying away once and never finding them again, so
the bench went to 250 scattered over the whole torus. That measured something
worth knowing: **~290 cycles per object per frame** for integrate + cull, ten
times the design's original estimate, because the position is 16.8 and the
velocity 8.8 so one axis is a 24-bit add.

The number that matters is that this cost was paid by **every** object, on every
frame, and a 140-screen world means 99% of them are nowhere near the camera. It
was the single largest item in the frame — larger than the outlines, larger
than the starfield.

The fix is an ordering, not an algorithm: **reject first, move second**. The
high-byte reject against the ship now runs before the rock has been integrated
at all, so a distant rock costs ~40 cycles instead of ~160 and simply does not
move. Nothing in the machine can observe that: there are no off-camera
collisions on a torus, and its outline is not being drawn. It starts moving
again the moment you fly near it. `do_objects` went from **32,000 cycles to
12,300** on the same frame.

Reading the position one frame stale is what makes the order safe: a rock covers
at most ~13 world units a frame, and the gap between the coarse window
(`CULL_HI` × 256) and the precise cull (`CULL_R`) is 128 units, so nothing can
cross both tests inside one frame.

**12. Stars wandering sideways after a speed change were the camera moving.**
The camera point sits ahead of the ship by the ship's screen offset, and that
offset *eases* between speed tiers — so for a few frames after every tier change
the camera is travelling as well as the ship. That used to force a full star
rebuild each of those frames, and a rebuild rounds every star independently: the
scroll was smooth, the rebuilds were the twitch. The camera's motion is along the
heading, which in view space **is** the scroll axis, so it belongs in the travel
accumulator. Only the heading forces a rebuild now.

**13. An exponential ease never lands on its target in integers.** The new turn
ramp shifts the remaining delta right each frame — which gives 0 one way and −1
the other, so the angular velocity stuck at a tiny nonzero value and the heading
crept *forever*, firing a full star rebuild every few dozen frames. It snaps to
the target when the step underflows. The same trap applies to every ease in the
bench, including the ship's screen offset.

**15. Speed does not hide bad rounding.** The motes were first written with only
the integer rotation tables and no sub-unit registration, on the theory that at
six pixels a frame the rounding would be invisible under the motion. It was not:
the sample is quantised to a whole layer unit, so between steps a mote does not
move at all and then jumps, and summing two separately-floored lookups scatters
that jump by up to two pixels *per mote*. Specks twitching back and forth — the
starfield's defect at a different scale.

Register against the sub-unit part of the sample, and **floor once, at the end**.
The registration stops the freeze-then-jump; the single floor makes each point's
position a monotone function of the sample, so it cannot step backwards.
`preview.py` counts reversals on frames where the ship's screen offset is steady
(while it eases, the camera outruns the ship and the motes reverse for real):
**68 of 401 without it, 3 of 309 with it**.

**14. The backdrop is appended to the list last, on purpose.** Stars second to
last, motes last. The GPU walks the PPRAM list in order, so whatever sits at the
end is what gets dropped if a frame ever runs long — and the backdrop is the only
thing on screen whose loss costs nothing. It also removed a wart: drawn last, the
starfield cannot be painted over by the sprites or the HUD, so the "every star
reached the framebuffer" check no longer has to excuse the rows the HUD sits on.
`preview.py` asserts the last two commands in the list are the two `DOT_PIXELS`.

**9. The star layer is only just big enough, and the overflow was being folded
onto the screen.** A few stars streaked along the top and bottom edges during
turns, *against* the rotation, and it came and went with the heading. A star's
view position is `R·d` over the whole 256 × 256 layer, so it reaches
128·(|cos| + |sin|) — 128 at heading 0, but 181 at 45°. The base is one byte and
folds at 128, so a star whose true view_y was 156–181 folded to −100…−75 and was
drawn at the *top* of the screen while still carrying the motion belonging to a
radius of 170 near the bottom. Hence: wrong place, too fast, wrong direction, and
absent at axis-aligned headings.

Stars that do not fit in a byte are now **parked** rather than folded — all of
them are off-screen by construction — and because parking at ±127 leaves only 27
pixels of margin past the visible ±100, a **refresh** re-runs the transform for
the parked stars alone before the scroll uses that margin up. It touches nothing
on screen, so the rigid scroll is undisturbed.

`preview.py` turns the ship through a full revolution and uses the fact that a
rotation moves every star **tangentially**: the cross product of radius and
motion has one sign for the whole field, and a folded star's comes out backwards.
With parking off: **123 of 5985 star motions against the rotation**. With it on:
**0**.

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

**20. The rotation tables take a 16-bit operand, and nobody had noticed.**
This is the largest single win in the file and it needed no new data at all.

`BUILD_ROT` fills `ROT[i] = signed(i)*coef/128` in 8.8, exactly, for a **byte**
index — which is why the starfield gets its multiply-free transform and why the
object centres appeared not to qualify: a world delta is 16-bit. But the table
is *linear*, so it splits:

```
delta = hi*256 + lo   ->   delta*coef/128 = 256*ROT[hi] + ROT[lo]
```

and `256 * ROT[hi]` needs no shifting whatever — multiplying an 8.8 value by 256
moves its fraction byte into the integer, so **the two table bytes already are
the 16-bit result**, fraction byte low. The one care needed is that the table
reads its index as signed while `lo` is unsigned: for `lo >= 128` the missing
256 is borrowed from the high index (`hi+1`), which cannot overflow because the
delta has already passed `in_range`.

**~65 cycles against `smul_core`'s ~300**, and *more* accurate — nothing is
truncated on the way through, and the low entry's fraction byte rounds the
result. `view_xform` went from four shift-and-add multiplies to four table pairs
and some adds; `smul_core` fell from 16,800 cycles a frame to 2,700 (what is
left is the ship's velocity and the star rebase).

The tables moved to `do_camera` at the same time, and had to: they were built
inside `star_rebase`, which runs *after* `do_objects`, so on a turning frame the
objects would have transformed against last frame's heading and lagged the
camera by a frame. Three things read them now — the starfield, the object
centres, and the radar when it arrives — so they belong to the camera. They are
still built only on frames where the heading actually moved; at ~15k cycles for
the pair that is not something to do speculatively.

**16. The quarter-square multiply is worth 4×, and it is worth stripping the
signs out of it too.** Rotating an outline is 4 multiplies a vertex, and the
bench's general `smul_core` — shift-and-add over seven bits — costs ~270 cycles.
`design_technical.md` 4.5 called for a quarter-square table instead:
`f(x) = x*x/4`, `a*b = f(a+b) - f(a-b)`, exact because `a+b` and `a-b` always
have the same parity so the two floors cancel. Built at boot as a running sum
(`f(x+1) - f(x) = floor((x+1)/2)`), so the whole page costs one add an entry.

Two things the design note did not say, both measured here:

- **One 256-entry table is enough, not 511.** Only *magnitudes* go in, and both
  are — 127, so `a+b` never leaves a byte. Half the RAM the design budgeted.
- **The sign handling was half the cost.** The first version took signed
  operands and stripped them inside: ~130 cycles. Splitting the trig into
  magnitude + sign once per rock, and the vertex once per vertex, and putting
  the sign back with a `cpy` on the two flags, gets the multiply itself to
  **~60 cycles**. The second copy of the table, holding `f(x) + 64`, does the
  `>>7`'s rounding for free by being the minuend.

Per transformed vertex: **~530 cycles**, against the design's estimate of
250-300. Four multiplies is 240 of it; the rest is the two magnitude splits, the
two sums, and a 16-bit add per axis to place the point.

**17. Clipping an outline: never clamp, and rarely clip.** `DOT_LINES` takes
byte coordinates, and the GPU does **not** validate them — an out-of-range
vertex is an address computed from the formula and written to, and past fb row
326 that address is the video register block. Clamping is not an option either:
a clamped corner sticks to the screen edge and *bends* every segment touching
it, so a 192-px rock half off the top comes apart into a fan.

So: a rock wholly on screen is one `DOT_LINES` chain, byte coordinates, interior
vertices shared. A rock crossing an edge is classified per segment with
Cohen-Sutherland **outcodes**, and only the segments that actually cross an edge
go to `gpu_dotline_clip`. That matters because the OS's clip builder measures at
**~3,000 cycles a call** — it is a real clip with a divide per crossing — while
a plain `gpu_dotline` for a segment with both ends on screen is a couple of
hundred, and a segment with both ends beyond the *same* edge is free. On a rock
that is only half off screen most segments are in the first two categories.

**18. Where the frame actually goes.** Profiled per routine on the same frame
(two rocks on camera, 200 in the world), before and after findings 20, 11 and
21 (`prof` harness, cycles):

| | before | after |
|---|---:|---:|
| `do_objects` — every object, integrate + cull | 32,000 | **12,300** |
| `smul_core` — the object-centre rotations | 16,800 | **2,700** |
| the outlines: rotate, classify, emit | 20,000 | **12,900** |
| `do_stars` + its `DOT_PIXELS` | 15,100 | 15,100 |
| the HUD (`gpu_vtext` × 7) | 9,900 | 9,900 |
| motes | 3,300 | 3,300 |
| **frame total** | **106,700** | **66,500** |

The lesson is the one in finding 11: what cost was the **objects you cannot
see**, not the ones you can.

Where it lands: **median 80,800 cycles (34% of budget), worst frame 165,000
(70%)** with the star occlusion of finding 22 in. PPRAM is a non-issue at 281 bytes of 2047, 14%.

One number in that budget is set by the *biggest* rock, not the average one. The
coarse cull has to pass anything whose rotation could still reach the screen,
and for a 192-px rock that is screen-half-height 200 + the ship's 120 px of
speed offset + a 96 px radius = 416 px on one axis and 246 on the other — so the
world-space vector to admit is up to **488 px**, not the 400 the bench used
while everything was a dot. At 400 the big rocks popped in and out at the screen
edges, which is exactly the size this pass exists to look at.

The two remaining big items are both worth knowing about. `do_stars` at 15,100
is the price of a rigid, rebuild-free starfield and is not going down. The HUD
at 9,900 for seven `VTEXT` lines is a bench luxury — the real game puts it on
the background layer, where it is free (finding D5 in `open_questions.md`).

**21. The visible list wants to be packed, and the reason is the zoom.** The
per-object screen position and its visibility flag used to be five whole pages
indexed by object id — 1,280 bytes to carry a dozen live entries, and a scan of
two hundred flags to find them. Packed into a 64-entry list it is 320 bytes and
the draw loop walks the dozen.

The saving is real but small. The reason to do it now is that a **packed list
can be sorted and a sparse flag array cannot**. Pulling the camera back at speed
multiplies the number of rocks in view; `AST_MAX` stops being a theoretical
ceiling and starts to bite; and when it does, what must be dropped is the
furthest rock, not whichever one happens to have the highest object id.

**22. A hollow rock needs a solid shadow, and the shape of it matters.** A
dot-line outline has no interior, so the starfield shines straight through a
rock and it reads as a wire hoop. Stars are therefore suppressed where a rock
covers them — dropped before they reach the `DOT_PIXELS` buffer, so it costs
nothing downstream and saves PPRAM.

**A disc, not a box.** A quarter of a bounding box is corner, measured, and a
star blinking out in open space beside a rock is a more obvious error than one
shining through it. Each occluder therefore carries both: a clamped box, which
is four byte compares and rejects nearly every star, and a centre plus r² for
the round test on whatever is left. The square is free — `f(x) = x*x/4` is the
quarter-square table already built for the rotation, and `x*x = f(2x)`.

**And not the bounding radius either.** An irregular outline's vertices sit
between about 0.66 and 1.0 of the bound, so the radius trades two errors:
*leak* (a star inside the outline that survives) against *halo* (a star
suppressed in open space beside it). `preview.py` rasterises the actual emitted
polygon and measures both:

| radius | leak | halo |
|---|---:|---:|
| bounding (1.00 R) | 0% | ~35% |
| **mean vertex (0.82 R)** | **6%** | **10%** |

`SHAPE_OCC` holds the mean vertex radius per shape and is meant to be tuned by
eye; the harness re-measures both errors every run. It is also the number the
**collision radius** should be, so that what looks solid and what actually hits
you are the same circle (`design_technical.md` 5.4).

**Only the centre's low byte is stored**, which is what lets a rock hanging off
the screen edge suppress stars at all — its true centre does not fit in a byte.
It works because the round test only ever runs on a star already inside the
clamped box, so the offset is within ±R and R is at most 48; a difference that
small comes back correctly from a byte subtract wherever the centre really is.
The old box list gave up on off-screen centres entirely.

**Cost: ~3,000 cycles median, ~6,000 worst** (1.3% and 2.5% of budget), at ~40
emitted stars and up to 13 occluders. The starfield had to move after the rocks
in the frame for this — `do_stars` now runs after `emit_asteroids`, which is
where the discs are registered. The command list order is unchanged, because
`do_stars` only fills a buffer; `emit_stars` still goes last.

**19. Five LOAD pages on one frame is 98% of budget, and there is no reason for
it.** Installing the ship means a `LOAD` of the 256-byte bitmap plus the four
sprite-definition pages — and `LOAD` is the only way CPU1 can write GPU RAM, so
setting two table entries costs four whole pages. Together that is 1,290 bytes
of the command list and ~50,000 cycles of copying. Spread one page per frame it
is 5% a frame and the ship appears on frame 5 (83 ms). It still has to go
*first* in whichever frame it lands on: a definition page dropped for want of
PPRAM would leave the slot empty for the rest of the session.

The check that caught the bug in this is worth keeping in mind. The first
version of "the ship is on screen" counted lit pixels in the sprite box — and
passed happily while the bitmap `LOAD` was going to the **wrong page** and the
blitter was reading the object table, which is also lit. `preview.py` now
compares GPU RAM against `ship32.s` byte for byte, and the pixels on screen
against the asset's two planes.

---

## Two things it deliberately gets "wrong"

**Heading is 256 steps, not 32.** The design assumes the ship flies in one of 32
directions. Since the ship is always drawn nose-up, the only place that choice
can show is the smoothness of the world's rotation — so the bench runs at full
8-bit brad resolution, and the question to answer while flying it is whether 32
steps (11.25° a click) would have been visibly steppy. If it would not be, 32 is
free; if it would, the design should say 256 and stop pretending.

**Star occlusion is the naive test, on purpose.** Every emitted star is tested
against every occluder, which is the cost `design_technical.md` 5.4 wants a
number for before anyone builds the coarse mask that replaces it. The number is
~3,000 cycles on a median frame — see finding 22 — so the mask is not needed
at this scene size and the naive version stays until zoom-out and fragments
multiply the rocks on camera.

---

## Files

```
header.s      "MAD65" signature + the two vectors, pointing at the bootstrap
bootstrap.s   Model B: copies CODE+RODATA out of the window into RAM at $2000
main.s        the bench itself — camera, ship, rocks, starfield, HUD
ship32.s      GENERATED by tools/sprgen.py from assets/png/ship32.png (--tate)
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
