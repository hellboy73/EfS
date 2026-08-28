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
- **The ship.** A **solid vector triangle**, 28 px tall and 24 across the base at
  1:1, always nose-up, **40 px below centre at rest** and riding further down as
  the speed tier climbs. It shrinks with the zoom like everything else in the
  world. Three
  `LINE` ops.

  The 32 × 32 sprite it replaced is still here and still works — set
  `SHIP_SPRITE = 1` in `main.s` and the artwork, the `--tate` conversion and the
  five-page upload all come back. The triangle is in so the two can be compared
  once **zoom** exists: a vector ship scales for nothing, where a sprite needs a
  pre-scaled frame per zoom step, and the ship is the one object in the game that
  never rotates — so the usual argument for sprites does not apply to it.
- **120 asteroids** with real world positions, velocities and spins, scattered
  over the whole torus — two or three on camera at rest, seven or eight at top
  speed once the camera has pulled back. Each is a **closed
  dotted outline** at one of **five sizes: 192, 128, 64, 32 and 16** full-res
  pixels across, rotated by (its own spin — the heading) every frame. **Stars
  go out underneath one**, so a rock reads as a solid body and not as a wire
  hoop. Nothing collides with anything: you fly straight through them.
- **The zoom.** The camera pulls **back** as the ship speeds up, smoothly, to
  **2x out at the top tier**. Rocks and the ship scale with it, and so do their
  star-suppression discs. The starfield and the motes do **not** — the stars are
  conceptually infinitely far away and are there to show the *rotation*, and the
  motes are foreground grit for the sense of speed.
- **A HUD**: speed in px/s, turn rate in milliseconds per revolution, heading,
  `RZ` (the zoom reciprocal — 128 is 1:1, 64 is twice out), the number of stars
  that survived clipping, and `A` — how many rocks were drawn this frame.

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
| `ZOOM_RZ` | the **whole zoom curve**, one reciprocal per speed tier (128 = 1:1). Making the ramp start later, or making it a step, is an edit to this one line |
| `ZOOM_CULLR` / `ZOOM_CULLH` | what the cull has to admit at each zoom step. Regenerate both if `ZOOM_RZ` leaves the 64..128 range |
| `SHIP_OFF` | how far down the screen the ship sits per tier. **127 is a hard ceiling** — it is a signed byte |
| `AST_BUDGET` / `AST_CLIP` | the per-frame outline work budget, in vertex-units, and what a screen-straddling rock adds. **This is what stops the frame overrunning** — see finding 30 |
| `LOD_R` | on-screen radius below which a rock is drawn with every second vertex |
| `LOD_MIN_N` | ...and the vertex count below which it is **not**, because halving an octagon makes a rectangle — see finding 35 |
| `ZQ_LADDER` / `ZQ_SNAP` | the geometric zoom rungs the eased reciprocal snaps to, and the lookup that does it — finding 36 |
| `CAMX_GAIN` / `CAMX_LAG` | how far the camera leans into a turn, and how fast. **Flip the sign of the gain if it leans the wrong way** |
| `TP_OFF` | the `\|SHOFF\|` the teleport lands on. **72 is the floor** — below it the landing point stops fitting a signed byte |
| `CAMX_TIER` | how hard the camera leans into a turn, per tier — zero at a standstill |
| `BOOST_FRAMES` | how long a boost lasts; `TIER_SPD`'s last entry and `TIER_SHL`'s are how fast |

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
| **JOY2 DOWN** | **TELEPORT** — jump to a fixed point 80 px from the leading edge; 246 px at top speed, 160 at rest, backwards when reversing |
| **JOY2 UP** | **BOOST** — 700 px/s for 90 frames. Top tier only, cannot be stacked. The HUD speed field reads `BOST` while it runs |

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

Where it lands with the **zoom in and the bench driven to its top tier**:
**median 118,200 cycles (50% of budget), worst frame 209,200 (88%)**, with the
outline budget's low-water mark at 38 of 150 — so the valve is there but this
flight never needed it with the star occlusion of finding 22 in.

The worst frames are **heading-change frames**, and now we know why: `BUILD_ROT`
costs **20,081 cycles** for the pair of tables, measured on frame 30 mid-turn.
That is 8.5% of budget, paid only when the heading's integer part moves — and
it is the number that decides how zoom should work, because folding a scale into
those tables would mean paying it on every frame the zoom eases as well. PPRAM is a non-issue at 281 bytes of 2047, 14%.

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

**23. The preview picture had been wrong the whole time, and the harness was
lying about it.** `preview.py` resets the buffer it captures GPU writes into to
the background at the top of every frame, exactly as the hardware re-copies
VRAM-image from VRAM-background. It never reset **the GPU's own VRAM**. The
drawing routines read-modify-write, so every byte the current frame touched came
back carrying whatever had been in it since frame zero: the ship, the motes and
the starfield accumulated two hundred frames of trails, a byte at a time.

It reads as fuzz — outlines a little too thick, a stray line here and there —
which is exactly the kind of wrongness that gets explained away. It nearly cost a
false firmware finding: a throwaway diagnostic with the same flaw made the solid
`LINE` opcode look as though it byte-smeared diagonals, and the fix was almost
written up as a firmware limitation. Cleared properly, `LINE (10,10)-(40,30)`
draws 101 pixels over exactly the right extent, and the ship triangle is 116
pixels inside `fb_x 286-314, fb_y 136-160`. The opcode was never at fault.

Two lessons worth keeping. A harness that models a hardware copy has to model it
**everywhere the hardware does it**, not just where the answer is read from. And
a measurement that indicts the platform should be repeated on a clean rig before
it is written down.

**24. The ship is a vector triangle, and solid.** The rocks are dot-lines because
a dotted rim is what reads as rock and there are a dozen of them; the ship is one
object and wants to be the solid thing in the frame, which is also what it looked
like as a sprite. Three `LINE` ops, 15 bytes of the command list.

TATE decides which way it points, and it is worth writing down because it is easy
to get backwards: **up on the player's screen is DECREASING `fb_x`**, so the nose
is the point with the smaller x and the base spreads along `fb_y`. That is the
same quarter turn `sprgen --tate` bakes into the artwork; here it is just how the
three points are written. `preview.py` asserts the exact corners every run, which
is what would catch it flipping.

**25. 4x motes are too fast; 2x is the number.** The layer's parallax is one
shift in the sample — `camera >> 3` for 4x, `>> 4` for 2x, with the camera offset
pre-multiplied to match — so it costs nothing to try either. 4x was tried and
flown: at the top tier it moves the specks ~12 half-res pixels a frame, and at
that speed they stop reading as depth and start reading as noise, pulling the eye
off the rocks. Back to **2x**, ~6 pixels a frame, which is the layer doing its
job: saying "fast" when there is nothing else in view. `preview.py` measures the
ratio against the starfield — 2 / 0.25 = 8 expected, 7.9 measured.

**26. The zoom is a reciprocal, and it never touches the rotation tables.**
Carried as `128/scale` in Q0.7 — 128 is 1:1, 64 is twice out — so every use of it
is a multiply and never a divide. Because the camera only ever pulls *back*, the
scaled trig stays inside `qmul`'s 127 limit for nothing.

| where it lands | cost |
|---|---|
| a rock's **centre** | two products, through a `ZS[i] = signed(i)*RZ/128` table read exactly like the rotation tables (finding 20) |
| a rock's **vertices** | **nothing**. The scale folds into the per-rock `cos`/`sin`, so rotate-and-scale is one matrix and a vertex costs what it always did |
| its **suppression disc** | one product on the radius |
| the **ship** | three products, because it is three points |
| the **cull radius** | a nine-entry lookup; it scales as `128/RZ` |
| **stars and motes** | nothing, by design |

The scale is deliberately **not** folded into the rotation tables, even though
that would make it free per object: three things read those tables — the
starfield, the object centres, and the radar when it arrives — and only one of
them zooms. A separate 512-byte scale table costs ~10k to rebuild against ~20k
for the rotation pair, and only on frames where the reciprocal's integer part
actually moved (57 of 200 on the bench's flight).

**27. Gradual beats stepped, and the budget is the reason — not the look.**
A step at a speed threshold saves nothing measurable: the per-object product is
paid whether or not the scale changed, so the only difference between the two is
the table rebuild during the transition. Against that, a step is worse three ways,
and the third is the one that decides it:

- The starfield does not zoom, so a rock snapping to half its size while the
  stars stand still reads as the **rock** teleporting, not the camera moving.
- Its suppression disc snaps with it, so a ring of stars blinks on at once around
  every rock.
- **The visible-object count goes as the square of the zoom.** 2x out is ~4x the
  objects through the cull. A step drops that entire increase onto one frame —
  and the budget is set by the worst frame. Easing spreads it over forty.

That square is the real bill for zoom, and it is what took `NOBJ` from 200 to
**120**: at 2x out, 120 rocks put as many on camera as 200 did at 1:1.

**28. The ship at rest belongs below centre, and it is not free.** Dead centre
gives as much screen behind the ship as ahead of it, and ahead is where you are
going. It now rests 40 px down, 20% of the half-height.

Two things that cost. **127 is a hard ceiling** on the offset — it is the high
byte of a *signed* 8.8 value — and the first cut of the table ran to 140, wrapped
to -127 and threw the ship to the top of the screen mid-flight. And the star and
mote camera point rides `SHOFF` ahead of the ship, so lowering the ship pushes
that sample nearer the star layer's 128-unit reach: wrong-way star sweeps went
from 8 to 13 in 1,900, and the motes' cross-axis jitter roughly quintupled. Both
are still an order of magnitude below the numbers that indicated the real defects,
but a lower ship is not simply better.

**29. A test that lumps two axes together is measuring neither.** The mote
"do not twitch" check counted reversals on both screen axes at once and started
failing when the ship moved down. Split apart, the two axes were saying opposite
things:

| | steps | mean step | reversals |
|---|---:|---:|---:|
| **along** travel | 365 | 5.5 px | **0** |
| **across** it | 30 | 1.0 px | 26 |

Finding 15's defect — freeze-then-jump — lives on the travel axis, and there it is
perfectly clean. The cross axis has no motion at all, so every step on it is
+/-1 of pure quantisation and a "reversal" is just two of those in a row. The
check now asserts **zero** reversals along travel — stricter than what it
replaced — and reports the sideways jitter with a bound on its size instead.

**30. A late frame does not blink — it hands the GPU a spliced list and the
GPU executes the HUD as code.** Flown at nine-plus rocks the bench started losing
the whole screen, sometimes permanently, and leaving debris on the *background*
layer, which this cartridge writes to exactly once in its life. Four F2 dumps and
a decoder settled it.

**What the dumps ruled out first.** PPRAM peaked at **550 bytes of 2047**, so the
list was never close to full. `video_reg` read `$08` in every dump, so nothing had
latched a register *at the moment of capture*. And one dump caught CPU1 at
**100.0% util, `state=Running`** — a frame that never reached `gpu_end`.

**What the decoder found.** One buffer, status `$A2` — **CPU_READY** — decodes
cleanly for forty commands of rock outlines and then does this:

```
   280: DOT_LINE   [197, 47, 192, 57]
   285: DOT_LINE   [77, 158, 74, 98]   <- Y=158, outside the 0..149 field
   290: !! $02 is not an opcode:  02 02 00 53 50 44 20 2B 33 35 30 ...
                                        s  c  \0  S  P  D  ' ' +  3  5  0
```

That tail is a `VTEXT` — `62 02 02 00 "SPD +350 PX/S"` — whose `$62` opcode sits
at index 289 and was swallowed as the fourth argument of the `DOT_LINE` at 285.
The buffer is a **seam**: one frame's rock outlines spliced mid-command into
another frame's HUD, and stamped ready.

**How a seam happens.** From `MAD65_architecture.md`: *"Each frame, one chip
belongs exclusively to CPU1 and the other to GPU. At every VSYNC the assignment
swaps."* Unconditionally, in hardware. If CPU1 is still building when VSYNC
fires, the rest of its list lands in the **other** chip, on top of the list from
two frames ago — and `gpu_end` then stamps `CPU_READY` on that splice. The GPU's
contract (*"does not process PPRAM content until the CPU has set CPU_READY"*) is
satisfied by a buffer that is two half-frames glued together.

**Why it is catastrophic rather than ugly.** Once the walker desyncs it executes
whatever comes next, and what comes next is text. One HUD string:

| byte | char | as an opcode |
|---|---|---|
| `$20` | space | **CLEAR_BG** — writes the background layer |
| `$30` | `0` | **LOAD** — 258 bytes into an arbitrary GPU page |
| `$44` | `D` | DOT_LINE, with letters for coordinates |
| `$50` | `P` | SPRITE |

A `DOT_LINE` with a letter for `Y` reaches `fb_y = 2*255 = 510`, and
`$8000 + 510*50` lands deep inside the background window. A little further and it
is `$BFE0`, `VIDEO_REG`, where one stray bit is `BLINDER` and the screen is off
until something writes it back — which nothing will. All three symptoms, one
mechanism.

**The cartridge's defence: a work BUDGET, not a rock count.** `AST_BUDGET` is 120
vertex-units a frame; a rock costs its vertices, and a rock that straddles a
screen edge costs `AST_CLIP` more because each crossing segment goes through
`gpu_dotline_clip` at ~3,000 cycles. When the budget runs out the frame stops
drawing rocks. 120 is calibrated, not picked: this flight peaked at 112 units on
a 209,000-cycle frame. The cart also reads `OVERRUN_FLAG` every frame, re-issues
`CLEAR_BG` to repair the background, and shows the count as `OVR` on the HUD —
**it must read 000**.

**The real fix is four bytes, and it is in the OS.** `os_run` already computes the
exact condition — one instruction too late:

```
    jsr (FRAME_VEC)
    jsr gpu_end                      <- stamps CPU_READY unconditionally
    if VSYNC_FLAG != 0: OVERRUN_FLAG <- 1
```

Testing `VSYNC_FLAG` *before* `gpu_end` and skipping the `CPU_READY` stamp turns
a spliced buffer into a buffer the GPU refuses — the documented benign blink
instead of arbitrary code execution. That belongs in the MAD-65 repo, not here.

(An earlier draft of this finding blamed the `rp_replay` open item in
`MAD65_CPU_OS.md` — a real bug, about background writes being *lost* on a late
frame. It is not this one. This is writes being *invented*.)

**31. Clipping is now the largest single item, and a rock that straddles an edge
costs about what two rocks cost.** Profiled at five rocks on a turning, zooming
frame: `gpu_dotline_clip` **26,400 cycles** against 27,000 for every rock
transform put together. The outcode pre-pass of finding 17 already sends only the
genuinely-crossing segments there — this is what is left, and it is the OS doing a
real Cohen-Sutherland with a divide per crossing. It is why `AST_CLIP` exists, and
it is the next thing worth attacking if the scene needs to grow: a purpose-built
clipper that knows both endpoints are within 48 px of a known centre should be
able to beat 3,000 cycles by a lot.

**32. A rock small on screen does not show its corners.** The zoom makes every
rock small at speed, which is exactly when the frame is tightest, so below an
on-screen radius of `LOD_R` a shape of eight points or more is drawn with **every
second vertex**. Shapes already at five or six points are left alone — halving
those makes a triangle. Worth ~10,000 cycles on the worst frame for no visible
change, because at that size the vertices that get dropped were a pixel apart.

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

**33. The star-occlusion pass is not a constant, and inverting it is a loss until
the scene gets big.** Finding 18 wrote `do_stars` down as 15,100 cycles and said
it was not going down. That number was measured at **two rocks on camera**, and
the pass is `for each star, for each occluder` — O(stars x rocks), with both
factors rising together when the camera pulls back. It is the one item in the
frame whose cost grows with exactly what overloads the frame, and `AST_BUDGET`
does not model it at all.

Inverting it — register each occluder in the screen row bands its box spans
(`occ_bands`), then have a star walk only its own band's list — was measured
both ways on the same 200-frame flight, forcing every occluder into one band to
reproduce the old shape:

| | flat (old) | banded | |
|---|---:|---:|---|
| `NOBJ` 120, median | **117,057** | 118,422 | +1,365 |
| `NOBJ` 120, worst | **205,071** | 205,745 | +674 |
| `NOBJ` 250, median | 195,033 | **188,998** | −6,035 |
| `NOBJ` 250, worst | 310,085 | **299,311** | −10,774 |

So the inversion **costs** 1,365 cycles on the flight this bench actually flies
and **saves** 10,774 on the worst frame of one twice as dense. The crossover sits
between the 7 rocks the standard flight peaks at and the 13 the dense one does.
Two reasons the win is smaller than the test count suggests: the band index only
filters when the occluders are *small*, and at `RZ` 128 a 192-class disc spans
five of the ten bands on its own; and the build has a fixed cost — clearing the
bands, then a shift-and-append per occluder per band — that is paid whether there
are two occluders or sixteen.

It is in unconditionally. 1,365 cycles is 0.6% of budget on a frame already
running at 49%, and the whole reason this discussion started is that the scene
has to get denser. A threshold on `OCCN` would buy the sparse case back at the
price of a second path through the hottest loop in the file; worth doing only if
the sparse case ever becomes the one that is tight.

The dense column is worth reading on its own: **310,085 cycles is 131% of
budget**. Doubling `NOBJ` puts the bench well past the deadline, which is what
the sprite LOD, the sector grid and the degraded mode all exist to prevent.

**34. The sector grid barely pays as a cull, because the window is a quarter of
the world.** The 16 x 16 grid of `design_technical` 6.3 is in: cell index is
`(YH & $F0) | (XH >> 4)`, the wrap is a mask, rocks are bucketed once at init
and relinked only when a moving one crosses a 4096-unit boundary — about once in
300 frames. `do_objects` visits only the cells overlapping the cull window, and
`preview.py` confirms the output is unchanged: the same 669 rocks, drawn the same
way.

The cycles do not follow:

| | flat scan | grid | |
|---|---:|---:|---|
| `NOBJ` 120, median | **118,422** | 119,547 | +1,125 |
| `NOBJ` 250, median | 188,998 | **186,144** | −2,854 |
| `NOBJ` 250, worst | 299,311 | **298,283** | −1,028 |

The arithmetic that explains it: at `RZ` 64 the cull radius is 976 px in a
4096 px world, so **the window is 22.7% of the torus by area**. No spatial index
can beat that — the best any of them can do is skip the other 77%. The grid
visits 81 of 256 cells (32%, the cost of rounding a circle up to whole cells),
and at `NOBJ` 120 that is 81 cells for 120 rocks: **more cells than the objects
they were meant to save testing.**

The first version was worse still, at +2,649, because it masked the column into
the cell index per cell. Splitting each row into the two contiguous runs either
side of the column-15 wrap makes the cursor a plain `INX` and takes an empty cell
from ~60 cycles to ~16. That is what the numbers above are.

**It stays in, and not for the cull.** Rock-rock collision over the ~27 rocks
inside the window is 351 pairs naively — about 21,000 cycles — against ~54 pairs
and ~4,000 with the grid. Bullets want the same structure. As a broad phase it is
required; as a cull it is a rounding error, and the honest reason to have written
it is the first of those.

If the cull saving is ever wanted, the lever is not a finer grid — it is a
**bigger world**. Section 11 fixes world size as a function of the unit, and at
1/8 px instead of 1/16 the torus is 8192 px, the window falls to 5.7% of it, and
the grid starts skipping 90% instead of 68%.

**35. Every second vertex is not a level of detail. It made 36% of the rocks
rectangles.** Finding 32 halved the vertex count below `LOD_R` and called it free
— "at that size the vertices that get dropped were a pixel apart". Flying it says
otherwise, and the shape census says why:

```
outline sizes on screen: {4: 174, 5: 126, 6: 30, 10: 153}
```

No 8-gon and no 12-gon ever reached the screen: every one of them was halved. And
every 4-gon is a halved octagon — **174 of the 483 outlines drawn**. A
quadrilateral does not read as a rock, it reads as a rectangle.

Raising the floor to `LOD_MIN_N = 10`, so only the 12- and 10-vertex shapes may
halve, removes them:

| | median | worst | 4-gons |
|---|---:|---:|---:|
| halving from 8 | **119,547** | **207,102** | 174 |
| halving from 10 | 126,769 | 217,910 | **0** |

**+7,222 median, +10,808 worst, and the outline budget's low-water mark goes to
zero** — the valve is now dropping rocks on this flight, which is what
`[FAIL] the outline budget was never exhausted` is reporting.

That price is not the price of "more detail". It is the price of *not having a
reduced shape to switch to*. Taking every second vertex is a coincidence that
survives a 12-gon and destroys an 8-gon; a hand-drawn 5-point reduction of the
octagon would cost the same as the 4-gon did and still look like a rock. **Level
of detail wants authoring, the same way the full shapes are authored** — which is
the argument for the shape editor, and the thing that editor most needs to do is
show the reduced shape next to the full one.

**36. The zoom is quantised, and the rungs are geometric so sprites can share
them.** The ease still runs continuously in `ZEASL/ZEASH`; everything downstream
reads `ZOOMH`, which is the eased value snapped to one of 17 rungs at
`128 * 2^(-k/16)` — one table read a frame (`ZQ_SNAP`). `ZOOM_RZ` was rewritten
onto those rungs, and reshaped: 1:1 held all the way to +50, then steps of 1, 2,
3, 3, 3, 4 rungs, so the view opens fastest at the top of the range instead of
almost linearly.

Two payoffs, and only the second one shows up in a cycle count here.

**The rebuilds.** A full ramp crosses 16 rungs instead of all 64 integer values
of the reciprocal, so it rebuilds the ZS table at most 16 times instead of ~64,
at ~10,000 cycles each. That saving lands on **acceleration** frames — of which
this scripted flight has about forty, and none of them are its worst. The
measured median moved 126,769 → 124,642 and the worst 217,910 → 215,773, but part
of that is the scene itself shifting: snapping changes `RZ` during the ease, so a
slightly different set of rocks is on camera. The number that matters is not in
that table — it is that "accelerating while turning" now costs one table rebuild
where it used to cost two.

**The sprite index**, which is the reason the rungs are geometric rather than
merely fewer. With rungs at `128 * 2^(-k/16)` and size classes an octave apart,
on-screen radius is `R0 * 2^(-(c*S + k)/S)` — it depends on a **single integer**.
The bottom rung of one class is pixel-identical to the top rung of the class
below, so a sprite atlas is indexed by an addition and one sprite serves every
`(class, zoom)` pair landing on its index. The S=4 sub-ladder the sprites will
use — 128, 108, 91, 76, 64 — is every fourth rung, so it is exact rather than
approximate.

**37. The boost is a tier the player cannot select, and 500 px/s is a negative
number.** `ETIER` is `TIER`, except while `BOOSTN` is running, when it is
`TIER_BOOST`. The four places that were table-driven off `TIER` — speed,
`SHIP_OFF`, `ZOOM_RZ`, the HUD — read `ETIER` instead, and rows 11 of `ZOOM_RZ`
and `SHIP_OFF` are **copies of row 10**. That is the whole of "changes the speed
without touching the zoom or the ship's place on screen". JOY2 UP, top tier only,
90 frames. Idle cost is inside the noise.

480 px/s and not 500. `SPD` is signed 8.8 world units a frame; a unit is 1/16 px
at 60.317 Hz, so `$7FFF` is **482.5 px/s** and 500 px/s is `$8499` — negative.
Typing 500 into `TIER_SPD` fires the ship backwards at ~490 px/s.

**The first version of this was a silent corruption, and it looked like a
speedup.** `ETIER`/`BOOSTN` went at `$9B`/`$9C`, which are `star_rebase`'s
`SDXI`/`SDXF`. `do_stars` runs after `do_ship`, so the rebase ate them every
frame: the ship boosted at random and the HUD indexed `TIER_TXT` with garbage.
The symptom was the median **falling** to 123,890 and the outline-budget `[FAIL]`
going away. A second, quieter collision was found in the same sweep — `PEND` at
`$1BC0` reached 48 bytes into `OCCBL` — which had polluted some of finding 34's
measurements without ever tripping an assertion.

**42. Landing the teleport on a FIXED screen point removed two thirds of the
work — and uncovered an overflow that had been there all along.** The plan was:
widen `SHOFF` to 16.8 across nine sites, then clip the ship because it would
leave the screen, then jump. Landing on a fixed point instead makes `SHOFF`
afterwards a **constant**, and since the ship sits at `FBCX + SHOFF`, a landing
point `L` only has to satisfy **`L >= 72`** for the whole thing to fit the signed
byte the cartridge already has. `TP_OFF = 120` lands it 80 px from the leading
edge: 8 units of margin in the byte and 66 px of clearance for the nose. The ship
never leaves the screen, so nothing needs clipping either.

The jump length is not authored — it is `SHOFF - landing`, so **+350 jumps 246 px
and a standstill jumps 160**. Faster means further, which is what an escape move
wants, and no code decides it. Reverse mirrors: the ship rides above centre
backing up, so it lands low and the jump runs backwards along the heading.

**The overflow.** The first flight showed `SHOFF` running the wrong way after the
jump. The ease computes `target - SHOFF` in 16 bits, and both are signed bytes of
pixels, so the gap reaches 255 px — **65,280 in 8.8, which is not a positive
signed 16**. Between adjacent tiers the gap never passed 127 px, so this sat
there unseen from the beginning; a 246 px jump wrapped it and the ease walked the
ship away from its target. Only the *gap* needed a third byte; `SHOFF` itself is
still 8.8.

Three things the jump does that are not obvious. `PSHOFF` is dragged with
`SHOFF`, because `do_stars` folds `(SHOFF - PSHOFF)` into the scroll and a 246 px
step there would sweep the entire field sideways. The star bases are **rebased
from scratch**, and that is not caution: the star camera point is `SHOFF` scaled
into *layer* units (`shl6`) and the motes' into their own (`shl3`), not world
units, so the ship's world displacement and the `SHOFF` drop do not cancel
analytically the way they do for world objects — a full rebase means the question
never has to be answered. And the distance is authored on the **screen**, so it
is divided by the zoom to reach world units; `TPQ` turns that divide into one
Q0.7 product because the zoom is quantised to known rungs (finding 36).

**44. The clipper was the largest item in the frame, and it did not need a
divide.** `gpu_dotline_clip` is a general Cohen-Sutherland with a divide per
crossing — ~3,000 cycles a call, **26,400 at five rocks**, more than every rock
transform put together. None of that generality applies here: an outline's
segment is short (a vertex sits within `ARAD` of a centre the cull has already
put near the screen, so nothing is more than ~96 px outside) and the outcode
pre-pass of finding 17 already establishes that one end is on screen.

So `clip_fast` **bisects**. Keep `P` inside and `Q` outside, halve the interval
eight times, and `P` is the crossing to within 0.75 px on a segment that cannot
exceed ~192 — finer than the half-res lattice the dots land on. No divide, no
table, no per-edge passes. And `P` is inside by construction on every iteration,
so the byte coordinates the cheap builder wants need no clamping and cannot
address outside the field.

| | median | worst |
|---|---:|---:|
| `gpu_dotline_clip` | 127,293 | 214,778 |
| bisection | **122,976** | **202,030** |

**−12,748 on the worst frame, 90.5% of budget down to 85.1%**, and the scene is
byte-for-byte the same: 654 rocks, 481 whole outlines, 777 clipped segments both
ways. The one case it does not take is both ends off screen with the segment
crossing anyway — a chord across a corner — which still goes to the OS.

**43. The backward teleport went forwards, and the harness could not have known.**
`LDY` sets the flags. The distance was computed as `sbc TPDST / ldy #$00 / bpl`,
so the branch that was meant to test the *subtraction's* sign tested the zero it
had just loaded instead, and the top byte came out `$00` every time. Going
forward that is right by accident — the difference is genuinely positive.
Reversing, `SHOFF −38` against a landing of `+120` is −158 px, which as `$60`
with a zero top byte reads as **+96**, and the ship jumped forwards.

The fix is to sign-extend **both** operands before subtracting: the difference
reaches 246 px and does not fit the byte either of them lives in.

The reason this reached the screen is the more useful half. The scripted flight
only ever teleports at top speed, which is forward, so **every assertion passed
on a code path that was wrong in the other direction**. `preview.py` now flies a
second, 60-frame leg: re-init, three `DOWN` presses to full astern, teleport, and
check that the world position moved **backwards** — the broken version jumps
−1,515 where the fixed one jumps +2,548, and the check was verified by putting
the bug back and watching it fail.

`preview.py` also scripts a boost and a forward teleport into the main flight and
asserts the landing point, the once-only fire, and that the walk home is
front-loaded — five frames must carry over 40% of what fourteen do, which a
linear recovery fails.
The three continuity checks skip the jump and the fast part of the recovery,
because 15 px in one frame is more than "eases rather than snapping" allows and
is supposed to be.

**41. The boost did not read as a boost, and the fix was a shift, not a wider
type.** 480 px/s against a normal top of 350 is 37% and flying it says that is
not enough. `TIER_SPD` is signed 8.8 world units a frame and stops at 482.5 px/s,
so the number could not simply go up.

Widening `SPD` would mean a 24-bit operand for `smul16q7` and a three-byte tier
table. The multiplier goes **after** the direction product instead: `vel_shl`
sign-extends the 16-bit result into 24 bits and doubles it `TIER_SHL[ETIER]`
times. An authored 350 with a shift of 1 flies at **700 px/s** and nothing in the
multiply ever left 16 bits. The ship's velocity is 16.8 now like its position,
which also deleted the two sign extensions the integrate used to build every
frame — the change pays for itself.

The ceiling is 964 px/s at shift 1. The cull allows 1157: after finding 38's
regeneration the gap at `RZ` 64 is 320 units and a rock adds 13.

One thing this caught: `do_stars` computes the scroll from `SPD`, but the ship
flies on `VEL`. A boosted tier would have left the whole starfield behind, so the
scroll takes the same shift.

**39. The ship was stepping 2 px at a time, and it was the opcode.** `LINE`
(`$42`) takes half-res endpoints and doubles them, so a line that drifts or turns
slowly lands on the same two even pixels for several frames and then jumps. The
GPU OS documents the size of it: a 140 px spoke swept through 10 degrees in 0.4
degree steps gives **13 distinct lines out of 25 with `$42` and 24 with `$43`**.
On rocks it is invisible; on the one object the player watches for the whole
game it reads as the ship stepping rather than moving.

`emit_ship` now builds `LINE16` (`$43`) with signed-16 full-res endpoints — same
renderer, same still picture, four times the distinct positions in motion. The
centre has to be 16-bit because `FBCX` plus a `SHOFF` of 126 plus the nose is
past 255 on its own, and `SHIP_NOSE/TAIL/HALFW` became full-res numbers (14, 14,
12) rather than half-res ones. 8 PPRAM bytes a line instead of 4, on a list at
16% capacity.

**40. A camera offset added after the rounding makes the whole world step.**
Doubling the turn lean to +/-40 px broke `objects do not swim while flying
straight` — **160 reversals in 2,928 steps**, where there had been none. The lean
was being added to `fb_y` as a whole pixel *after* `asr4r` had already rounded
the zoom product, so every time `SHOFXH` crossed an integer the entire scene
jumped a pixel sideways, and the decay after a turn does that forty times.

Folding it into `MA` **before** the rounding — the lean pre-divided into
`zoom_ma`'s pixels-times-16 scale, once per frame — takes it back to zero
reversals, and is slightly cheaper than the sign-extend-and-add it replaced.
This is finding 15's rule on a third axis: register against the sub-unit part,
floor once, at the end. Three separate defects in this bench have now had the
same cause.

**38. The camera leans into a turn, and that moves the pivot — so `CULL_R` had to
grow.** `SHOFXL/H` eases toward `turn velocity * CAMX_GAIN` and is added to the
world's `fb_y` exactly as `SHOFF` is added to `fb_x`, plus to the ship and its
occluder box. The world rotation pivots on the **ship** (4.2), so the ship
sliding across the screen slides the pivot with it, and the cross-axis reach goes
from `150 + 96 = 246` to `150 + 40 + 96 = 286`. The worst-case vector goes
483 → 510 px and both cull tables were regenerated.

| | median | worst |
|---|---:|---:|
| before | 125,057 | 217,745 |
| after the wider cull | 128,385 | 221,167 |

**+3,328 cycles, and almost none of it is overhead** — a 2.3% larger `CULL_R` is
4.6% more area, so it is mostly rocks that genuinely have to be drawn now and
were being missed. The alternative is rocks popping in at the cross edges, which
is the defect finding 18 describes at 400 px.

**And the gain is per tier, not a constant.** The lean is meant to say "the
camera is not keeping up with this ship", and that sentence has no meaning at a
standstill — a pivot the ship is sitting still on has nothing to lag behind. It
looked wrong there, and it looked wrong because it was. `CAMX_TIER` tracks
|speed|: zero at `TIER_ZERO`, 107 at either end. Reverse leans too. It costs
nothing — a constant became a table read.

The backdrop deliberately does **not** get the lean. At 1/4 parallax a 20 px
camera shift is 5 px of stars, it only exists while the field is already
rotating, and a heading change rebases the field anyway so it cannot accumulate.
That buys a way out of a second sub-unit-registered accumulator in the code
findings 6, 12 and 15 are all about.

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
ship32.s      GENERATED by tools/sprgen.py from assets/png/ship32.png (--tate).
              Assembled out while SHIP_SPRITE = 0; the ship is a triangle.
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
