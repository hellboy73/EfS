# Escape from Saturn — technical design

> **Status: DESIGN, nothing implemented.** This document records the technical
> assumptions agreed at project start (2026-08-25) plus the engineering analysis
> that follows from them. Numbers marked **(TBM)** are *to be measured* in
> madsim before they are fixed; items marked **(TBD)** are open decisions.
> Open items are collected in [`open_questions.md`](open_questions.md).
> The narrative lives in [`story.md`](story.md), the physics parameter set in
> [`physics.md`](physics.md).

---

## 1. What the game is

A loose, heavily expanded clone of *Asteroids* for the **MAD-65** console, with a
story campaign. The player flies a ship through a large wrapping world, clears the
mission stated by the level plan, then leaves the world boundary to reach the next
level.

Two things separate it from the 1979 original:

1. **The world is many screens across**, not one screen. The screen is a *camera*
   onto a torus, not the world itself.
2. **The camera rotates and zooms.** The ship is drawn effectively pointing "up"
   at all times; steering rotates the *world* around it, smoothly and at subpixel
   speeds. Flying faster pulls the camera back so the player sees further ahead.

---

## 2. Platform envelope

| | |
|---|---|
| Console | MAD-65 (2x W65C02S @ 14.318 MHz) |
| Cartridge | **256 KB = 32 banks x 8 KB**, window `$8000-$9FFF` |
| Cartridge model | **Model B** — code copied to RAM at boot, run from RAM |
| Screen | **TATE (portrait)** — monitor rotated **clockwise**, logical **300 x 400** |
| Colour | 1 bit (black / white) |
| Frame rate | 60.317 Hz |
| CPU budget | ~237,000 cycles per frame, **per CPU** |
| CPU1 RAM | `$0000-$77FF` (~30.75 KB) + `$A000-$BEFF` (~7.75 KB) |
| Audio | 2x SN76489 + YM2413 |

Rotation direction follows the MAD-65 house convention (`ROT_DIR` clockwise): the
top edge of the monitor faces the player's right, framebuffer-x+ = screen down,
framebuffer-y+ = screen left. **There is no "vertical mode" in the hardware** —
assets are pre-rotated and the existing blitters run unchanged. `madsim` shows the
rotated view with `F12`.

The screen coordinate system used throughout this document is the **player's**
300 x 400 portrait view; the framebuffer transform is a rendering detail.

---

## 3. The world

### 3.1 A torus with free wrapping

World position is a **16-bit unsigned value per axis**, and the axes wrap by
**16-bit arithmetic overflow**. There is no wrap test, no compare, no branch —
`clc / adc` *is* the wrap. Relative position between two objects is likewise a
plain 16-bit subtract, and the result read as signed 16-bit is automatically the
shortest distance across the seam. This is the single most important structural
decision in the engine and much of what follows depends on it.

### 3.2 Units

**1 world unit = 1/16 of a screen pixel at reference zoom.** Therefore:

- World size = 65536 units = **4096 x 4096 reference pixels**
- = **13.6 screens wide x 10.2 screens tall** at reference zoom
- Subpixel resolution = 1/16 px, i.e. 1 unit/frame = 3.75 px/s — fine enough that
  the slowest drift reads as smooth motion rather than stepping.

If playtesting wants a bigger world the knob is the **unit**, not the coordinate
width: 1/8 px per unit gives an 8192 px world (27 x 20 screens) at half the
subpixel resolution. The coordinate type never changes. **(TBD)**

### 3.3 Leaving the level

The world does not stop wrapping when the mission completes — instead an **exit
corridor** opens (a marked direction or gate). Flying into it ends the level. The
wrap therefore never has to be disabled, which keeps the free-wrap property intact
for the whole game. **(TBD)**

---

## 4. Camera

### 4.1 Heading — 32 directions

The ship flies in one of **32 headings** (11.25 degrees apart). The OS `sin`/`cos`
services take an angle in **brad** (0-255 = full circle), so a heading is stored as
a brad value and 32 directions are simply `heading & $F8` — steps of 8 brad.
Storing the heading in brad rather than 0-31 means it can be handed to the OS
tables directly, and leaves the door open to 64 or 256 headings later without a
data change.

### 4.2 The world turns about the SHIP, not about the screen centre

The ship is drawn off-centre — down the screen at speed, up in reverse (4.3) —
and it is the *ship* that rotates, so the world has to pivot on the ship. Pivot
on the screen centre instead and the world slides sideways past the ship on every
turn: it reads as a strafe, not a turn.

For anything drawn from its own world position (objects, asteroids) that is one
addition: `screen = ship_screen_position + R·(p − ship)`.

For the **star layer** it is not, and the naive version is expensive. The layer
only reaches 128 units from wherever it is centred, and the layer is centred
wherever the transform's origin lands — which, for a pivot on the ship, is the
ship. With the ship 60 units below centre the top of the screen is 160 units
away, past the end of the layer, and covering that would need roughly **four
times the stars** for the same density.

Both at once, for nothing: **sample the layer at the point the screen centre
looks at** — the ship plus its screen offset along the heading. The layer then
sits centred on the screen, where it is needed, and the pivot still lands on the
ship, because that sample point swings around the ship as the heading changes.
The offset cancels out of the drawing entirely; it only moves the sample.

One trap inside that: the sample is parallax-scaled, so feeding the offset
through it shrinks the swing by the parallax factor and the field pivots a
quarter of the way from the screen centre to the ship — still a strafe, just a
weaker one. **Rotation has no parallax** (5.3), and the camera's swing around the
ship is part of turning, not of travelling, so the offset has to be pre-multiplied
to cancel the parallax out.

### 4.3 The ship points up; the world turns

The ship sprite is drawn essentially fixed, nose toward the top of the screen, with
a **small visual bank/tilt while turning** (a few degrees, art only, no effect on
physics). Everything else in the scene is rendered rotated by `-heading`.

Consequence: the rotation is a *camera* transform applied once per rendered object,
and the ship itself needs no transform at all.

### 4.4 Zoom is a function of speed

Speed drives a **camera distance**, smoothly interpolated (the camera lags the
speed change so a throttle tap does not snap the view):

| speed | camera | ship on screen | what the player sees |
|---|---|---|---|
| 0 | closest | **centred**, largest | few, very large rocks |
| forward, rising | pulls back smoothly | slides **down** the screen | more space ahead |
| top forward | furthest | lowest | maximum look-ahead, smallest objects |
| reverse | close | slides **up** past centre | space behind |

The ship's screen Y is interpolated with the same curve, so at top speed the player
is looking mostly at where they are going. Reverse pushes the ship above centre for
the same reason.

Zoom is expressed as **world units per screen pixel**: reference zoom = 16. Zooming
out to 3x means 48 units/px and a visible window of 900 x 1200 reference pixels.
Exact zoom range **(TBM — 2x is built and flying, see open_questions C1)**.

**How it is carried, and why that shape.** As the **reciprocal**, Q0.7: 128 is
1:1, 64 is twice as far out. That turns every use of it into a multiply and never
a divide, and because the camera only ever pulls *back* (`s <= 1`) the scaled
trig stays inside the quarter-square table's 127 limit for free.

| where | what it costs |
|---|---|
| an object's **centre** | two products, through a `ZS[i] = signed(i)*RZ/128` table read exactly like the rotation tables (4.5a) |
| an object's **vertices** | nothing. The scale folds into the per-object `cos`/`sin`, so rotate-and-scale is one matrix and a vertex costs what it always cost |
| its **occlusion disc** | one product on the radius |
| the **ship** | three products, because it is three points — which is the whole argument for keeping it vector rather than pre-scaling a sprite per zoom step |
| the **cull radius** | a nine-entry lookup. It scales as `128/RZ`, and a cull that did not follow the zoom would pop the biggest rocks in and out at the screen edges |
| the **starfield and motes** | nothing. They do not zoom |

**The scale must NOT be folded into the rotation tables** (4.5a says why in
general): three things read those tables — the starfield, the object centres and
the radar — and only one of them zooms. A separate scale table is 512 bytes and
~10k cycles to rebuild, against ~20k for the rotation pair, and it is rebuilt only
on frames where the reciprocal's integer part actually moved.

**Gradual, not stepped.** A step at a speed threshold saves nothing: the per-object
product is paid whether or not the scale changed, so the only difference is the
table rebuild during the transition. Against that, a step is worse in three ways.
The starfield does not zoom, so a rock snapping to a third of its size while the
stars stand still reads as the *rock* teleporting rather than the camera moving.
Its occlusion disc snaps with it, so a ring of stars blinks on at once around
every rock. And because the visible-object count goes as the square of the zoom,
a step concentrates the entire ~4x cost increase into one frame — which is the
frame the budget is set by. Easing spreads it over forty.

### 4.5 The transform, and why it is affordable

Per rendered object:

```
delta   = obj.pos - ship.pos        ; 16-bit subtract, wrap-correct for free
                                    ; read as SIGNED 16 -> shortest path across the seam
cull    if delta is outside the visible window at the current zoom
screen  = M * delta + ship_screen_pos
```

where `M` is the 2 x 2 matrix that folds **camera rotation and zoom into one
operation**:

```
a = cos(-heading) * s        M = [ a  -b ]      s = 256 / zoom
b = sin(-heading) * s            [ b   a ]      (a reciprocal, so no divide per vertex)
```

`M` is computed **once per frame** for the camera, and per object only when the
object also spins — in which case the object's own spin angle is *added* to the
camera angle before the matrix is built, so a spinning asteroid still costs one
matrix, not two transforms.

Per vertex that is 4 multiplies. `mul16` at `$FF72` is a few hundred cycles, which
would cap the scene well under 100 vertices/frame. **The engine therefore uses a
quarter-square multiply table** — `f(x) = x*x/4`, `a*b = f(a+b) - f(a-b)`, exact
because `a+b` and `a-b` always have the same parity so the two floors cancel —
which turns the multiply into two table lookups and a subtract.

**MEASURED** in `proto/01_flight` (see its README, finding 16):

| | |
|---|---|
| the multiply | **~60 cycles**, magnitudes in and out |
| per transformed vertex | **~530 cycles** (4 multiplies = 240; the rest is 2 magnitude splits, 2 sums, and a 16-bit add per axis) |
| a 12-vertex rock, all in | **~8,000 cycles** including classification and emission |
| table cost | **2 × 256 bytes**, not 2 × 512 |

Two things the original estimate got wrong, both in the same direction:

- **One 256-entry table is enough.** Only *magnitudes* are indexed, and both are
  — 127, so `a+b` never leaves a byte. The second copy of the table holds
  `f(x) + 64` and does the `>>7`'s rounding for free by being the minuend — so
  the 512 bytes saved get spent again, on speed rather than on range.
- **Signs must be stripped OUTSIDE the multiply.** A version that took signed
  operands and normalised them internally cost ~130 cycles, more than twice the
  estimate. Split the trig once per object and the coordinate once per vertex,
  and put the sign back on the product with a compare of the two flags.

So 250-300 cycles a vertex was optimistic by about 2×; ~160 transformed
vertices is ~85k cycles, over a third of the budget rather than a fifth. The
practical ceiling is nearer **10 rocks of 10 points** than 20 of 8.

### 4.5a The object CENTRE needs no multiply at all

The four multiplies above are the price of a **vertex**, whose coordinates are
signed bytes. An object's *centre* is a different problem: the delta is a 16-bit
world coordinate, so neither the quarter-square table (8-bit operands) nor the
starfield's `ROT` tables (a byte index) appear to fit it, and the proto paid
`smul_core` at ~300 cycles a product for it.

They do fit it. `ROT[i] = signed(i)*coef/128` is **linear**, so it splits:

```
delta = hi*256 + lo   ->   delta*coef/128 = 256*ROT[hi] + ROT[lo]
```

and because the entries are 8.8, `256 * ROT[hi]` is not a shift — the two table
bytes **are** the 16-bit result, fraction byte low. `lo` is unsigned where the
table index is signed, so `lo >= 128` borrows the missing 256 from `hi+1`.

| | |
|---|---|
| per product | **~65 cycles**, against ~300 for `smul_core` |
| accuracy | *better* — nothing truncates on the way through, and the low entry's fraction byte rounds the result |
| extra cost | none. The tables already exist for the starfield |

This is what makes the **camera transform of a whole object field affordable**,
and it applies to anything positioned in world coordinates: object centres, the
radar's blips, and any effect that lives out in the world rather than on a
sprite. Measured in `proto/01_flight`: `smul_core` fell from 16,800 cycles a
frame to 2,700, and the frame from 106,700 to 66,500.

**The tables belong to the camera, not to the starfield.** The proto built them
inside its star rebase, which runs after the object pass, so on a turning frame
the objects transformed against the previous frame's heading. They are built in
`do_camera` now, still only on frames where the heading moved — ~15k cycles for
the pair, which is not something to spend speculatively.

**Consequence for zoom (4.4):** the tables carry rotation only, at scale 1. Zoom
must therefore be applied *after* them, per object, and NOT folded into the
table coefficients: a smooth zoom moves the scale every frame, and rebuilding
four 256-byte tables every frame costs more than the multiplies it saves at any
plausible object count. For a rock's **outline** the scale folds into the
per-rock `cos`/`sin` instead — two multiplies per rock, none per vertex — and
that stays inside the quarter-square table's 127 limit only as long as zoom
never magnifies (`s <= 1`).

### 4.5b The real cost is the objects you cannot see

The larger lesson from the proto is that neither of the above was the dominant
term. A field of N objects pays a position integrate and a cull for **every**
one of them, every frame, and a world of ~140 screens means 99% are nowhere near
the camera. At 200 objects that was 32,000 cycles a frame against ~20,000 for
every visible outline put together.

The fix is an ordering, not an algorithm: **reject first, move second.** A
coarse high-byte reject against the ship, before the object has been integrated
at all, cuts a distant object to ~40 cycles and leaves it stationary. Nothing
can observe that — there are no off-camera collisions and no outline is drawn —
and it starts moving again when the camera comes near. Measured: 32,000 -> 12,300.

Beyond ~250 objects (a byte index) even 40 cycles each stops being free, and the
answer is spatial bucketing: with 16-bit wrapping coordinates the cell index is
the top nibble of each high byte, so a 16 × 16 grid of 256-pixel cells costs
nothing to compute and the wrap is free. **(TBM — not needed until asteroids
break into fragments.)**

### 4.6 Pre-rotated shapes — considered, rejected for now

Storing every asteroid outline pre-rotated in all 32 orientations would remove the
rotation multiplies, but it does not remove the **zoom** multiplies, and it
multiplies shape ROM by 32. Folding rotation and scale into one matrix (4.4) costs
the same 4 multiplies that scale alone would. Revisit only if measurement says the
transform is the bottleneck.

---

## 5. Rendering

### 5.1 Vector first, sprites for the small stuff

The look is **vector**: asteroid outlines, the ship, enemies and effects are drawn
as line / dot-line polygons transformed on CPU1 and emitted to the GPU. Bitmaps and
sprites appear where they buy something:

- **Sprites** for objects that have become small on screen. Below a threshold size
  a transformed polygon costs more CPU than it earns in fidelity, so the object
  switches to one of a small set of pre-scaled sprites. This is the main CPU/GPU
  optimisation and the reason sprites exist in a vector game at all.
- **Bitmaps** for title, story, mission-briefing and end screens, drawn to the VRAM
  background (free per frame — the hardware re-copies it).
- **HUD** as text or tiles on the background layer where it does not change every
  frame.

The vector/sprite crossover size is **(TBM)**.

### 5.2 GPU primitives available

The **polygon family** - `gpu_dotpolygon` (`$FFD2`), `gpu_polygon` (`$FFD5`),
`gpu_polygon16` (`$FFD8`) - is the workhorse for anything that is a closed
outline around a centre, which is every rock and most enemies. One command is a
whole figure:

```
CX.16, CY.16, ANGLE, SCALE, N, dx0,dy0, ... , dxN-1,dyN-1
```

The centre is signed-16 and **may be off screen**; the offsets are the raw
authored shape, unrotated and unscaled. The GPU rotates, scales and clips, and
it clips properly - it cuts, it does not clamp, so a figure half off the top edge
keeps its shape instead of collapsing into a fan. CPU1's per-vertex cost is a
two-byte copy and the builder does no arithmetic at all.

`$4E POLYGON16` is the **only** way to get a full-resolution outline. A vertex
CPU1 transforms cannot carry better than half-res precision, because the
quarter-square multiply indexes with `|x| + |cos|` and that has to stay inside a
byte; transforming on the GPU lets the same +/-127 offset simply be read on the
400x300 grid. The limit worth writing down: a figure wider than 254 full-res
pixels no longer fits.

Measured (proto 01 finding 48), `$4E` costs **+17%** on the GPU over `$4C` - and
the split is worth knowing, because most of it is not the resolution. Dotted to
solid is +12%; half-res to full-res is only the further **+7%** `LINE16` charges
for 16-bit endpoints. Two consequences for anything that adopts it:

- **The win is the centre, not the shape.** A half-res anchor is the full-res
  position `>> 1`, so an object moves in two-pixel steps and a slow drift
  stutters. `$4E` removes that. A *finer shape* is a separate matter and cannot
  be derived from half-res artwork - re-rounding a half-res vertex at twice the
  radius returns exactly twice that vertex, so full-res shapes are new artwork.
- **There is no dotted full-res figure.** `$4E` is solid. Going full-res is
  therefore also an art decision, not only a precision one.

`gpu_dotline_clip` (`$FF93`, signed-16, Cohen-Sutherland clipped) remains the
tool for an *open* path - the polygon family has no polyline form and the closing
edge is not optional. `gpu_dotpixels_clip` (`$FF99`) draws a whole cloud of
clipped points in one call, which is exactly the starfield. `gpu_line` (`$FF15`)
is half-res and unclipped.

**Budget honestly: this is a transfer, not a speed-up.** Both processors are the
same 65C02 at the same clock, so the same algorithm costs the same on either
side; what is bought is that the cycles land on the idle one. The GPU pays
roughly 620-690 cycles a vertex for transform and clip, on top of the raster it
was already paying. Level-of-detail - sending fewer vertices - is the lever, and
it is entirely CPU1's to pull: there is no shape table in GPU RAM and no
`SHAPE_ID`, so a caller sending every second vertex simply sends a shorter
command.

### 5.3 Starfield parallax

Background stars are single pixels that move at a **fraction of the ship's
velocity**, so they read as distant. Implementation: stars are *not* simulated
objects. Each star has a fixed position in a star layer, and the layer is sampled
at `ship.pos * k` for a parallax factor `k < 1` (e.g. 1/4 and 1/8 for two layers).
Because the sample position is *derived* from the ship position rather than
accumulated, there is no drift and no per-star update cost — a layer is one add and
one `gpu_dotpixels_clip` call.

The star layer also rotates with the camera; two layers at different `k` give depth
for two calls. Star count and layer count **(TBM)**.

Note the layer must **rotate** with the camera even though it is "distant".
Parallax applies to translation only — rotation has no parallax, so a star layer
that translated slowly but did not rotate would visibly tear away from the world
every time the player turns.

**But it must not rotate every frame.** A star's exact view position is

```
view_i = R(H) · (p_i − s)
```

Split the sample into where it was at the last rebuild plus the distance flown
since, `s = s_base + t·forward`. `R` maps `forward` onto view-up by construction —
that is what "the ship always points up" *means* — so `R·(t·forward) = (0, −t)`,
and **the entire effect of flying is one scalar added to view-y**. No rotation, no
per-star work, and `t` can be carried at any precision.

So the starfield keeps each star's view-space position as a plain byte pair (the
byte wrap *is* the view torus: a star leaving one edge re-enters at the other for
free), adds the integer part of `t` to view-y every frame, and **rebuilds the
positions from the layer only when the heading actually changes**. Straight flight
costs one add per star and no table build at all.

Three things this got right that the obvious implementation got wrong, all
measured in proto 01:

- **Rigid beats scattered.** The first version folded the travel into the sample
  and rotated every frame, which threw away the sub-unit part of `s` in the table
  lookup. At heading `$14` the field stood still for three frames and then ~100 of
  110 stars jumped at once *by different amounts*, because each star's rounding
  flipped at its own moment. Near an axis (`$FC`) one table is almost the identity
  and the other almost zero, so the same lurch came out uniform — which is exactly
  why it looked fine at some headings and shook at others. The fix makes every
  heading behave the way the good one did.
- **Do not rotate the stars incrementally.** Applying the frame's small heading
  delta to the stored positions would be cheaper than rebuilding from the layer,
  but the table's matrix has a determinant of about 0.987, so the field implodes —
  roughly 20% per quarter turn. Rebuilding from the layer accumulates nothing.
- **The rebuild is a turning-time cost, not a flying-time one.** Two 256-byte
  table builds plus one transform per star, only on frames where the heading moved.
  Straight frames got about 35% cheaper than the every-frame version.

The residual: a rebuild re-registers the field against the integer sample and can
shift a star by up to a pixel. That happens only while turning, when the whole
field is rotating anyway.

**The layer has to be bigger than it looks.** A star's view position is `R·d`
over the whole layer square, so it reaches `L·(|cos| + |sin|)` — up to 1.41 times
the layer's half-size, at 45°. If the stored view position is one byte it folds at
128, and a star whose true view coordinate is 156–181 folds back to −100…−75 and
is **drawn at the opposite edge of the screen carrying the sweep speed of a radius
it does not have**. Under rotation that reads as a handful of stars streaking
along the top and bottom edges *against* the turn. It vanishes at axis-aligned
headings (where the maximum is exactly 128 and nothing folds), which is what makes
it look like an intermittent glitch rather than a systematic one.

Two things follow, and they are the same requirement stated twice:

- **A star whose true position does not fit must be parked, not folded.** Every
  such star is off-screen by construction — the visible band is far inside ±127 —
  so parking costs nothing visible.
- **The kept band must clear the screen by enough to scroll.** Parking at ±127
  leaves 27 pixels of margin past the visible ±100, and the field scrolls along
  that axis, so a *refresh* has to run before the margin is used up. It rewrites
  only the parked stars, so nothing on screen moves — a full rebuild rounds every
  star independently and would drop a scattered one-pixel twitch into an otherwise
  rigid scroll.

The general lesson for anything else drawn from a wrapping layer: **the layer's
radius must cover the screen's half-diagonal plus the scroll between rebuilds**,
and a square layer only guarantees its inscribed circle.

### 5.3a Two backdrop layers, and both go last in the list

There are two decorative layers, on opposite sides of the action:

| layer | parallax | drawn | purpose |
|---|---|---|---|
| **stars** | 1/4 of the ship's speed | behind everything | depth, distance |
| **motes** | **2x** the ship's speed | **in front of everything** | speed, when nothing else is in view |

The motes exist because with no enemies on screen there is nothing to judge speed
against; a handful of specks streaking past the camera supplies it. Being in
front is what makes them cheap — nothing can occlude them, so they skip the
occlusion pass entirely — and being few, they are simply transformed from scratch
every frame: no stored bases, no travel accumulator, no parking, no refresh.

What they do **not** get to skip is the arithmetic quality. The first version used
only the integer rotation tables and no sub-unit registration, on the theory that
at six pixels a frame nobody would see the rounding. They did: the sample is
quantised to a whole layer unit, so between steps a mote does not move at all and
then jumps, and summing two separately-floored lookups scatters that jump by up to
two pixels **per mote**. It reads as specks twitching back and forth — the same
defect the starfield had, at a different scale.

The rule this makes concrete, and it applies to anything drawn from a rotated
sampled layer: **register against the sub-unit part of the sample, and floor
once, at the end.** Sub-unit registration is what stops the field freezing between
sample steps; the single floor is what makes each point's position a *monotone*
function of the sample, so it cannot step backwards. Measured on the motes: 68
direction reversals in 401 pixel steps without it, 3 in 309 with it.

**Both layers are appended to the PPRAM list LAST — stars second to last, motes
last.** The GPU walks the list in order, so whatever is at the end is what gets
dropped if a frame ever runs long. The backdrop is the only thing on screen whose
loss costs nothing: a missing star is invisible, a missing ship is not. Ordering
also happens to work out: drawn last, the backdrop cannot be painted over by the
sprites or the HUD, which is why the starfield no longer needs to dodge them.

The rule generalises: **list order is a priority order.** Anything that must
survive a long frame goes early — the ship, the HUD, gameplay objects — and
anything expendable goes late.

### 5.4 Star occlusion — asteroids are hollow

Asteroids are drawn as **dot-line outlines**, so they have no interior. Stars
behind one would shine straight through it and the rock would read as a wire
hoop rather than a solid body. Stars must therefore be **suppressed where a rock
covers them**.

The suppression happens where the star list is built, not on the GPU: a star that
is occluded is simply never written into the `DOT_PIXELS` buffer, so it costs
nothing downstream and even saves PPRAM. Two ways to decide it:

- **Per-star × per-rock test.** Straightforward, but the cost is the product: 50
  stars × 20 rocks = 1000 tests per frame even with an early reject on one axis.
- **A coarse occlusion mask.** Rasterise each rock's disc into a low-resolution
  screen bitmap (8 × 8 half-res pixels per cell ⇒ 19 × 25 = 475 cells = 60 bytes),
  then each star is **one bit test**. Cost becomes *rocks + stars* instead of
  *rocks × stars*, and it stays flat as the star count grows.

**MEASURED** in `proto/01_flight`: the naive version costs **~3,000 cycles on a
median frame and ~6,000 on the worst**, with ~40 emitted stars and up to 13
occluders (one ship + twelve rocks). That is 1.3% and 2.5% of the frame — so
the mask has a very low number to beat, and **the naive test is good enough for
a scene this size**. Two things make it cheap:

- Each occluder carries a **clamped bounding box as well as its disc**. The box
  is four byte compares and rejects nearly every star; the round test only runs
  on what is inside the box.
- The square comes out of the **quarter-square table** already built for the
  rotation: `f(x) = x*x/4`, so `x*x = f(2x)`, and `2 * 48` is well inside a byte
  of index. Two lookups, an add and a 16-bit compare.

The mask becomes the right structure when *rocks* × *stars* grows — zoom-out
puts more rocks on camera, and fragments multiply them. Revisit then. **(TBM at
20+ rocks.)**

**The suppression radius is not the bounding radius.** An irregular outline's
vertices sit between roughly 0.66 and 1.0 of the bound, so the choice trades two
errors against each other: *leak* (a star inside the outline that survives) and
*halo* (a star suppressed in open space beside it). Measured against the drawn
polygon, per rock area:

| radius used | leak | halo |
|---|---:|---:|
| bounding (1.00 R) | 0% | ~35% |
| **mean vertex (0.82 R)** | **6%** | **10%** |

A bounding **box** is worse than either: a quarter of it is corner. The mean
vertex radius is what the proto ships, authored per shape in a `SHAPE_OCC`
table — which is also where the **collision radius** should come from, so that
what looks solid and what actually hits you are the same circle.

Two details that follow:

- The mask must be a **disc**, not a bounding box — a square hole punched in the
  starfield around a round rock reads as a rectangle and is worse than the
  see-through problem it fixes. Rasterise per cell-row with an x-span.

  A disc is still only an approximation, and the measured size of that
  approximation is in the table above: with the mean vertex radius, 6% of the
  rock leaks and 10% of its area is halo. Both errors are a few pixels at the rim
  of a moving object and neither reads on screen. What matters more is that the
  occlusion disc uses the **same radius as the collision circle** (7.3), so what
  looks solid and what actually hits you are the same shape — a rock that
  visibly swallows a star but lets a bullet through would be a real complaint.
- **Sprites do not need this.** A sprite can carry an overlay (black) plane that
  masks whatever is under it, so sprite-based objects occlude for free. Only the
  vector layer needs the mask — which is another quiet argument for the sprite LOD
  in 5.1.

### 5.5 The HUD lives on the background, and it is rate-limited

**Text erases what is under it.** `TEXT` / `VTEXT` write whole character cells,
background included; they do not OR a glyph over what is already on screen. An
image-layer HUD therefore punches black rectangles into the starfield — measured
in proto 01, which draws its HUD on the image layer and loses every star beneath
it.

So the HUD goes on the **VRAM background**, where the hardware re-copies it under
the image every frame for nothing. That brings a hard constraint with it.

**One background write per frame, plus a cooldown frame — never two in a row.**
This is the rule CETAS arrived at (`text-bg-one-line-per-frame`) and it carries
over unchanged. Every VRAM-background write — each `TEXT_BG` / `VTEXT_BG` line
*and* `CLEAR_BG` — must be the only one on its frame, with at least one idle frame
after it.

*Why:* the background is double-buffered and the OS replays each background
command across **two** frames so it lands in both buffers. A second background op
on the same or the next frame stomps the first one's replay, so that line reaches
only one buffer — and since the hardware ping-pongs the buffers, it **blinks every
other displayed frame**. The classic symptoms are "the banner still flickers" and
"the background only half cleared".

**What that costs EfS.** Two frames per line, round-robin over however many lines
exist:

| background text lines | frames per line | refresh rate |
|---|---|---|
| 1 | 2 | 30 Hz |
| 2 (HUD) | 4 | ~15 Hz |
| **3 (2 HUD + 1 message)** | **6** | **~10 Hz** |
| 4 | 8 | ~7.5 Hz |

So with the planned two HUD lines plus a message line, **no HUD line may be
rewritten more often than every 6 frames**, and adding a fourth line pushes that
to 8. Ten refreshes a second is plenty for score, lives, speed and mission state —
but it means the HUD must be driven by a **per-frame sequencer**, not by whoever
happens to change a value.

Two consequences worth planning for now:

- **Draw on change, not every frame.** Cache each line's inputs and re-emit only
  when one actually moved; then the sequencer usually has nothing to do and the
  budget is spare for the message line.
- **Anything that must update every frame cannot be background text.** If some
  readout genuinely needs 60 Hz, it has to be an image-layer element that owns its
  rectangle — and pays for erasing the starfield under it.

`CLEAR_BG` obeys the same rule, so a screen transition is a sequence
(clear, wait, line 0, wait, line 1, …), never a burst.

---

## 6. Objects

### 6.1 Parameters are tracked everywhere; physics runs only nearby

Every object's parameters (position, velocity, type, shape) are kept for the
whole population, all the time — nothing is spawned on approach or discarded
when the player looks away. But **the physics — integrate, cull, collide — only
runs for objects near the camera**, not for the whole population every frame.

The first attempt (proto 01) simulated everyone every frame, and the price was
**ten times what this section first estimated**: **~290 cycles per object per
frame** for integrate + cull, not the ~30 the first estimate assumed, because the
position is 16.8 and the velocity 8.8, so integrating one axis is a 24-bit add
with a sign extension, not a 16-bit add. 250 objects cost about **70k cycles, 30%
of one CPU**, before anything is drawn — and, per 4.5b, 99% of that was spent on
objects nowhere near the camera.

Proto 02 fixed this with the sector grid (6.3): the coarse reject walks only the
cells overlapping the cull window, and an object outside it is **frozen** — its
stored position stands as of the last frame it was near the camera. Nothing in
the machine can observe the difference, because a frozen object neither collides
nor is drawn, and it starts integrating again the moment the camera comes near.

So the population is **persistent in its parameters, not in its simulation**:
returning to a place shows the same objects, doing what they were doing when the
player left them near enough to matter, but two rocks that were both off-camera
did not secretly collide with each other in the meantime — nothing computed that.
The population ceiling this sets is no longer per-object integrate cost; it is
RAM (one record per object, all the time) and how many objects are near the
camera at once, which the sector grid, the visible-list cap and the render vertex
budget bound separately. See `open_questions.md` E1 for the current numbers.

Procedural generation is used only for **cosmetic** matter (debris sparks, the star
layer), which has no state worth keeping.

### 6.2 Object record (draft)

```
pos_x, pos_y      16.0  world units (wrapping)
vel_x, vel_y       8.8  world units per frame, signed
angle              brad (0-255), current orientation
spin               signed brad per frame
size_class         0..N — drives mass, radius, shape set, split behaviour
shape_id           index into the vector shape table
flags              alive / type / just-hit / ...
hp                 for enemies
```

Exact layout is settled when the pools are written. The pool is
**structure-of-arrays** (one array per field) so indexed access is a single
`lda field,x`.

### 6.3 Broad phase: sector grid

Testing every pair of 96 objects is 4560 tests — too many. The world is divided
into a **16 x 16 grid of sectors**, objects are bucketed by the high bits of their
position, and only same-sector and adjacent-sector pairs are tested. The sector
index wraps by masking, which is again free on a torus.

**Resolution: settled at 4096 world units a sector** — the top nibble of each
position byte, so `cell = (YH & $F0) | (XH >> 4)` and there is no arithmetic in
it. The rule that picks it is sharper than "larger than the biggest asteroid":
a sector must be at least the **largest sum of two collision radii**, because
that is the distance at which two bodies can still touch. At 4096 units (128
collision units) against a largest sum of 78, it holds with room to spare, and
proto 02 asserts it at assembly time.

That rule is what makes the pair walk cheap. With it, each body needs its own
cell and **four** of the eight neighbours (E, S, SE, SW) — the other four are
covered from the far side — and every pair comes up exactly once with no
"already tested" bookkeeping. See [`physics.md`](physics.md) 3.

The same grid provides render culling: only sectors overlapping the visible window
are visited. Note the two uses want different resolutions and the render side is
the loose one: at full zoom-out the cell window is 11x11 of the 16x16 grid, and
that coarseness is paid by the cull, not by the collision pass, which sees only
what survives the precise coarse window inside it.

---

## 7. Physics

**This is the heart of the game and will get a lot of iteration.** It has its own
document, [`physics.md`](physics.md), so parameters can be tuned without touching
the architecture. The design commitments:

**Built, in [`proto/02_rocks/physics.s`](../proto/02_rocks/physics.s):** detection,
the elastic response, separation and the ship test. Not built: spin transfer,
break-up, shot split. `physics.md` says which is which and why.

- **Simplified elastic collision.** On contact the relative velocity is split into
  normal and tangential components. The normal component is exchanged according to
  mass (mass tracks size class), with a restitution coefficient below 1 so energy
  bleeds out of the system and the field does not become a perpetual-motion pinball
  table.
- **Every mass is a power of two**, halving with each size class down. That is not
  a tuning choice, it is what collapses the mass-ratio table to nine bytes indexed
  by the *difference* of two exponents, makes the ratios sum to exactly 128 (so
  momentum is conserved to the bit), and turns the positional separation into a
  shift. Anything that wants to collide — enemy, debris, the ship — buys into the
  whole response by having a power-of-two mass and a radius, and nothing else.
- **Spin transfer.** The tangential component feeds the spin of both bodies — a
  glancing blow sets rocks tumbling, a head-on one does not.
- **Break-up on impact.** Above a relative-normal-speed threshold one or both
  bodies fragment, using the same split rules as being shot.
- **Shot split.** A hit asteroid splits into **two** smaller ones. The children
  inherit the parent's momentum plus a separation impulse perpendicular to the
  shot, and receive new spins derived from the parent's spin plus the impact.
  Momentum is approximately conserved by construction, so the field does not drift.
- **Everything is parameterised** — restitution, mass curve, split impulse, spin
  gain, break-up threshold, per-size-class caps — as tables in one file, so tuning
  is a rebuild and not a rewrite.

Velocities are **8.8 fixed point**; positions stay 16.0 world units with the
fractional part of velocity accumulating in a parallel subpixel accumulator. Speeds
are quantised to a small set of magnitudes for the *ship* (section 8) but are
continuous for everything else.

---

## 8. The ship

- **32 headings** (4.1); turning is smooth in *world rotation*, i.e. the camera
  angle interpolates toward the target heading rather than snapping.
- **A small set of predefined speeds** rather than continuous thrust — the speed
  tier drives zoom, ship screen position and look-ahead, so discrete tiers make the
  camera behaviour readable. Number of tiers and their values **(TBM)**. This is
  the first thing to prototype in madsim, because it decides whether the game feels
  like *Asteroids* or like a shooter.
- Acceleration between tiers is smooth and takes time proportional to the gap; the
  camera follows with its own lag (4.3).
- Firing: shots are objects in the same pool with a lifetime, so they wrap and
  collide like everything else.

---

## 9. Levels

The campaign is **5 levels** — MINING ZONE, SENSOR ANOMALY, CONTACT, HUNT,
ESCAPE — needing three mission types: **clear the field**, **survive / traverse**,
and **reach the exit alive**. See [`story.md`](story.md) for the per-level content
and for the engine features the fiction commits us to (cloaked-but-simulated
enemies, detection-and-pursuit AI, deliberately unreliable instruments, per-level
world size).

A level is defined by a **mission plan**: what has to be true before the exit opens.
The level plan also sets the world size, the initial population, the size-class
mix, the enemy roster, physics parameter overrides and the music.

Level scripts are data, read straight out of the cartridge window (the CETAS
pattern), not copied to RAM.

The **population** half of that plan now exists, in
[`proto/02_rocks/levels.s`](../proto/02_rocks/levels.s), authored with
`tools/level_editor.py` the way shapes are authored with `tools/shape_editor.py`.
Per level it carries a **count per size class** — which the loader scatters over
the torus from a per-level LFSR seed, so a field is random in shape but identical
on every run — plus **hand-placed rocks** for set-pieces, **enemy positions**
(carried but not yet read; see `open_questions.md` E6), and the ship's start.
World size, physics overrides and music are still to come, and go in the same
per-level tables. Nothing about a level is a literal in that file: the tables are
built out of named constants and the per-level totals are summed from them, so
the assembler refuses to build a level asking for more rocks than there are
object slots.

---

## 10. Cartridge bank map (draft)

256 KB = 32 banks of 8 KB. Bank order is the `MEMORY` declaration order in
`cart.cfg`. **Draft only** — it will be redone once real sizes exist.

| banks | contents |
|---|---|
| 0-3 | `MAINCODE` — game code, copied to RAM at boot (Model B) |
| 4 | `RODATA` — generated tables, sprite definitions |
| 5-7 | vector shape tables (asteroid outlines, ship, enemies) |
| 8-11 | sprite blobs (small-object LOD sprites, HUD, effects) |
| 12-14 | full-screen bitmaps (title, briefing, ending) |
| 15 | level / mission scripts |
| 16 | story text |
| 17-31 | music (VGM streams, one per phase, each bank-aligned) |

---

## 11. Decisions already fixed

These are settled and should not be re-opened without a reason:

1. World coordinates are 16-bit per axis and **wrap by overflow**. No wrap logic.
2. The world unit is a fraction of a reference pixel; **world size is tuned by
   changing the unit**, never the coordinate width.
3. The camera rotates the world; the ship is drawn essentially fixed, pointing up.
4. Rotation and zoom are **one matrix**, and object spin is folded into the camera
   angle before the matrix is built.
5. Multiplies go through a **quarter-square table**, not `mul16`.
6. All gameplay objects keep **persistent parameters across the whole world**;
   only cosmetics are procedurally generated. Physics (integrate, cull, collide)
   runs only for objects near the camera — an object outside the sector grid's
   cull window is frozen, not simulated. See 6.1.
7. Broad phase is a **sector grid** indexed by masked high bits of position.
8. Stars are a **sampled parallax layer**, not simulated objects.
9. Sprites are for art that is not an outline — **thruster flames and shots**
   (player and enemy) — not a level-of-detail fallback for the ship or for
   rocks. Both stay vector at every on-screen size: the vertex cost that would
   justify a fallback lives on the GPU (13), and every proto bench so far finds
   GPU headroom while CPU1 is the tighter side. This retires the authored
   reduced-outline LOD proto 02/03 had (`SHAPE_LODN`/`LOD_R`) along with the
   sprite fallback it stood in for — settles the old D1; see `open_questions.md`
   D2 for what is still open about the flame sprites themselves.
10. TATE, clockwise, per the MAD-65 house convention.
11. Every **collidable body has a power-of-two mass** and a radius, and those two
    numbers are its entire physical identity. See 7 and `physics.md` 4.2 for what
    that buys; the cost is that a size class cannot be given an arbitrary mass.
12. The **collision circle is the star-occlusion disc** — one radius, `SHAPE_OCC`,
    the mean-vertex one. Restated here because it is now load-bearing in two
    subsystems rather than an aesthetic preference in one. See 5.4.
13. **Closed outlines are drawn by the GPU, not transformed by CPU1.** The
    `$4C` / `$4D` / `$4E` polygon family takes a centre, an angle, a scale and
    the shape *as authored*; CPU1 copies two bytes a vertex and does nothing
    else. This settles the old D3 ("would a clipped polyline opcode be worth
    it?") in a stronger form than the question asked - the opcode transforms as
    well as clips - and it moves the frame-budget question with it: the outline
    budget still counts vertices, but the frame it protects is now the **GPU's**.
    See proto 01 findings 46 and 48.
14. **The ship's outline is drawn through that same GPU polygon path, not a
    CPU1-transformed one.** 4.4's "keep it vector rather than pre-scale a
    sprite" argument costed the ship at three points; proto 03 authors it as a
    14-vertex shape (`shapes.s SHIP_SHAPE`), so the per-vertex CPU1 loop
    (`sscale` then `API_GPU_LINE16`) it used to run was no longer the cheap
    case. `emit_ship` now builds the same centre/angle(0)/scale/shape argument
    block a rock does and calls `API_GPU_POLYGON16` — measured at ~10,900
    fewer CPU1 cycles on the worst frame, folded together with 11.9's rock
    change. See proto 03's README "Cost, measured".
15. **Turn rate is a quarter-brad ladder, and the ship flies at rung 3 — 2830 ms
    per revolution.** Flying proto 01 settled the band before it settled the
    value: **1 to 3 brad per frame is usable**, and this document's original
    "1/32 of a turn per frame" (8 brad/frame, 531 ms per revolution) is far too
    fast. Whole-brad steps inside that band were too coarse to choose between,
    so the heading carries a fraction — it is 8.8, and the world is rotated by
    its integer part — and the ladder is quarter-brad: `5659, 4244, 3396, 2830,
    2425, 2122, 1698, 1415` ms per revolution. The ladder stays a bench control;
    the game gets rung 3. Settles the old B2. The fractional heading is not
    itself a ruling on 32 headings vs 256 — that is still open, see
    `open_questions.md` B5.
16. **The stick sets a TARGET angular velocity, and the real one eases toward it
    by 1/4 of the gap each frame** (`RAMP_SHIFT = 2`), so a turn winds up and
    unwinds instead of switching on and off. This is not a restatement of 15 or
    17: those decide *how fast* the ship turns, this decides *how quickly it
    gets there*. An instant ease (ramp 0 — the old on/off behaviour) stays in
    the benches so the two can be flown back to back. Settles the old B7.
17. **The turn rate rises with flight speed, by x1.25 at the top tier.** Turn
    radius is `v/omega`, so a constant omega makes the radius grow in proportion
    to speed — at +350 the ship would sweep a circle seven times wider than at
    +50. Doubling the rate at the top — the first cut — rose too fast to fly,
    and full proportionality (a constant turn radius) is rejected at the other
    end, because it leaves the ship barely able to turn at low speed. The
    coupling is one `TURN_XTRA` table read at the swept throttle position, and
    x1.25 is the settled shift of it. Settles the old B6.
