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
gate** opens, fixed in the world where the level puts it. Flying into it ends the
sector. The wrap therefore never has to be disabled, which keeps the free-wrap
property intact for the whole game. **Built — see 11.44** (`src/gate.s`).

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

### 5.1 Vector first, sprites for what isn't an outline

The look is **vector**: asteroid outlines, the ship, enemies and effects are drawn
as line / dot-line polygons transformed on CPU1 and emitted to the GPU, at every
on-screen size. There is no polygon-to-sprite LOD fallback for the ship or for
rocks — both stay vector however small they draw (11.9; retires the old
reduced-outline LOD and closes `open_questions.md` D1). Bitmaps and sprites
appear where they buy something else:

- **Sprites** for art that is not an outline to begin with: thruster flames and
  shots. A raster sprite cannot ride a polygon's continuous scale the way a
  vertex can, so these are authored at a few pre-scaled sizes and the right one
  is picked for the current zoom (`open_questions.md` D2 has the open count).
- **Bitmaps** for title, story, mission-briefing and end screens, drawn to the VRAM
  background (free per frame — the hardware re-copies it).
- **HUD** as text or tiles on the background layer where it does not change every
  frame.

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

- **The list holds 32**, not the 16 it held with a ship, a radar and a screenful of
  rocks: the human base (11.48) puts in one disc round the hexagon while all six of its
  triangles stand, and a disc through the corners of each that stands once one is gone. A
  band holds 16 ids and `occ_bands` tests for a full one.

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

**Built, in [`src/physics.s`](../src/physics.s):** detection,
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

The campaign is **5 levels** — MINING ZONE, CONTACT, HUNT, RESCUE,
ESCAPE (re-cut 2026-09-18, `story.md`) — needing mission types: **clear the field**, **survive / traverse**,
and **reach the exit alive**. See [`story.md`](story.md) for the per-level content
and for the engine features the fiction commits us to (cloaked-but-simulated
enemies, detection-and-pursuit AI, deliberately unreliable instruments). Each
level is **three sectors** of one fixed world size — see 11.45.

A level is defined by a **mission plan**: what has to be true before the exit opens.
The level plan also sets the initial population, the size-class
mix, the enemy roster, physics parameter overrides and the music.

Level scripts are data, read straight out of the cartridge window (the CETAS
pattern), not copied to RAM. **They are, since 2026-09-20:** `levels.s` and the
base's `BASE_*` rows live in the `LEVELS` segment, ROM bank 8 (`LVL_BANK`), and
the three readers of a level (`load_level`, `load_foes`, `gate_load`, plus
`base_load`) take their reads between `lv_open` and `lv_close`, the same borrow
`msg_open` makes for `MSGDATA`. `level_begin` runs inside `win_off`, so the rules
are the ones in `levels.s`'s header: read a level table only inside the pair,
write (never read) the RAM under the window while it is open, and keep a RAM copy
of anything a frame reads (`GTMIS`/`GTMPR`, gate.s). The bank is 8 KB, so the
level count is no longer bounded by what `DEMO_RAM` has spare.

The **population** half of that plan now exists, in
[`src/levels.s`](../src/levels.s), authored with
`tools/level_editor.py` the way shapes are authored with `tools/shape_editor.py`.
Per level it carries a **count per size class** — which the loader scatters over
the torus from a per-level LFSR seed, so a field is random in shape but identical
on every run — plus **hand-placed rocks** for set-pieces, **enemy positions**
(carried but not yet read; see `open_questions.md` E6), and the ship's start.
Physics overrides and music are still to come, and go in the same
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

   **AMENDED: the smallest size class is DEBRIS, and debris is not permanent.**
   The split (`shots.s rock_split`) forced this. A destroyed rock becomes two of
   the next class down, so the field *multiplies*: one 192 taken all the way apart
   is sixteen 16s, and a level that starts with 120 rocks peaks at 570 against 255
   slots — which is the ceiling, because an object id is a byte and `$FF` is the
   sector grid's end-of-list marker. A fixed-size field was what made "nothing is
   forgotten" affordable, and the split is exactly what breaks that arithmetic.

   So the 16s stopped being part of the field and became an effect. They exist to
   give a 32 something to come apart into and a hit something to scatter; they can
   be shot like anything else; and **the moment one has drifted `RECYC_FAR` from
   the ship, `rock_sweep` drops it** — every frame, as routine, not as an
   emergency. `RECYC_FAR` is 1,536 reference pixels, six times the furthest a rock
   can be and still be on screen, so one is never seen going. The sweep walks
   `RECYC_STEP` slots a frame, so the whole array comes round in an eighth of a
   second.

   That is what makes the arithmetic close: the leaf of the cascade is exactly the
   class the sweep takes back, so the slots a split spends are the slots the sweep
   returns. Measured on a bench where every hit was made lethal, it holds the live
   count *below* where the level started, and it takes CPU1's worst frame from
   88.2% to 83.6% — the 16s were the thing crowding the visible list.

   `rock_recycle` is the same test used as a last resort: when a split has nowhere
   to put its second half it walks the whole field looking for one speck to take.
   If it finds none, **the killing blow does not land** and the rock keeps its last
   hit point. That is the backstop, and it is counted (`NBLOCK`) so that "it never
   fires" is a number rather than a hope.

   The consequence worth naming: **"how many rocks are left" excludes the smallest
   class** — `shots.s rocks_left` sums classes 0 to 3 and nothing else. Counting
   debris would make a level's remaining work jump *upwards* every time the player
   destroyed something. See `open_questions.md` F1.
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
18. **The cartridge is 256 KB, and NOTHING executes out of it.** Every code and
    data segment is copied into RAM before the first frame (Model B, the CETAS
    bootstrap pattern) and the window is never read again. This is not a size
    optimisation, it is the difference between a frame that fits and one that
    does not: **the cartridge window has no RAM shadow**, so a read there costs
    3 wait states, and an instruction fetch is a read. Running in place was
    measured at ~35,000 cartridge reads a frame and 2.5x the cycle cost, which
    put the same frame at 77% of budget instead of 69%.

    So a bank is free and RAM is not. 256 KB is 32 banks, and adding one costs a
    `cart_load` in the bootstrap; what it costs at run time is nothing at all.
    What is scarce is the **RAM the code runs in**, and that is the number a new
    routine has to fit in — not the bank map.

    **AMENDED: the run area is `$1000-$5FFF` and holds only `CODE` + `CODE2`.**
    It was `$2000-$5FFF` with `RODATA` in it too, and it had about 2,000 bytes
    left, which is what made "where does the next subsystem go" the question
    this section could not answer. Two moves fixed it and neither cost anything
    a measurement can see — see 11.19 for the map they produced and the rules
    that keep it:

    * `RODATA` is 1,666 bytes of pure tables and had no reason to be in the
      scarcest space in the machine. It runs at `$A000` now, in the same
      full-speed upper RAM `HIDATA` uses. `bootstrap.s` did not change one line
      — it takes every address from the linker.
    * The object pool was 4 KB at `$1000-$1FFF`, the one data block sitting
      **directly below the run area**, so vacating it is the only way spare data
      RAM can turn into code space. It moved into the RAM under the cartridge
      window (11.19), and `cart.cfg`'s `RAM` region starts at `$1000`.

    Together: **7,940 bytes free in the run area** where there were 2,331, with
    the 220-frame `tools/preview.py` trace identical before and after — every
    ship position, star, collision and command — and the frame budget unmoved at
    70.6%.

    The one deliberate exception is `BGDATA`, which stays in the window and is
    read straight out of it by `API_GPU_RECT_BG_CART` — it is never executed,
    never reached through a RAM pointer, and read once (radar.s's ring), so the
    wait states are paid twice a session rather than twice a cycle.

    **AMENDED AGAIN, with the UFO (23): `CODE3`.** `foes.s` took bank 1 (`CODE2`
    + `BGDATA`) past 8 KB and upper RAM to its last few hundred bytes, while the
    run area still had room and bank 3 had 2.3 KB of ROM behind `HIDATA`. So
    `CODE3` is stored there and copied into the run area straight after `CODE2`
    — one more `cart_load` in `bootstrap.s`, taking its addresses from the linker
    like the other four. It is ordinary run-area code; where one segment ends and
    the next begins is where a bank filled, not a difference in kind.

    **AMENDED A THIRD TIME, with the laser (24): `CODE4`, and the bootstrap
    became a table.** `laser.s` is 783 bytes and bank 3's ROM had 539 left
    behind `HIDATA` + `CODE3`, so `CODE4` is stored behind `COLD` in bank 4 —
    which has 5 KB spare, since `COLD` is only the puff table — and copied into
    the run area after `CODE3`. That needed one more `cart_load`, and bank 0,
    which holds the bootstrap as well as `CODE`, had **15 bytes** left against
    the 31 a written-out call costs. So `bootstrap.s` copies from a table now:
    seven bytes a segment (bank, `LOAD`, `RUN`, `SIZE` — `cart_load`'s own
    `OS_ARG` block) and one loop, 73 bytes for six segments where five cost
    161, and bank 0 has 103 free. A seventh segment is one row. Every address
    in it is still the linker's.

    **And a second place code can run: `DEMO_RAM`, `$C000-$DFFF`** (19), 8 KB
    the CPU OS gave the cartridge on 2026-09-11. It is the answer to "where does
    the next subsystem go" now that the run area is down to ~850 bytes, and the
    natural home for per-level overlays — enemy behaviour copied in by
    `cart_load` when a level starts, since the cartridge's banks are free and RAM
    is what is scarce.

    **Its first tenant, 2026-09-15: `CODE5`.** The camera's enemy framing
    (`cam.s`, open_questions C6) is 1,618 bytes against the run area's 850, so
    it is stored last in bank 4, behind `BGDATA` (which keeps its offsets and so
    `RING_BANK`), and runs at `$C000`: a `DEMO_RAM` memory area in `cart.cfg` and a
    seventh `boot_segs` row. Only code lives there — the state it keeps is in
    the `$6Fxx` page the OS clears, so nothing trusts the demo's bytes.

    **And its top page is KEEP, `$DF00-$DFFF` (2026-09-15).** `cart.cfg`'s
    `DEMO_RAM` area is `$1F00` long, not `$2000`, so no segment can be placed on
    the last page. It holds what must outlive a NEW GAME — the hiscore table
    first (`src/hiscore.s`, 8 × 11 B) — which is filled once by `cart_init`
    and never by `game_start`, and lasts one power-on (a RESET copies the demo
    back over it). It is also the page the screens' code overlays will leave
    alone when they are copied to `$C000` (`open_questions.md` H1).

19. **There are FIVE places a byte can live, and access pattern decides which.**
    CPU1 has more RAM than one contiguous window suggests, and the five areas
    are not interchangeable — each is ruled out for something. Measured, in both
    simulators, before any of it was relied on. (It was four until 2026-09-11,
    when the MAD-65 CPU OS handed `$C000-$DFFF` to the cartridge — see
    `DEMO_RAM` below.)

    | area | size | free | what belongs there |
    |---|---|---|---|
    | run area `$1000-$5FFF` | 20,480 | 612 | **code** — `CODE`, `CODE2`, `CODE3`, `CODE4` — and nothing else if it can be helped |
    | lower RAM `$0400-$0FFF` | 3,072 | ~0 | the hot tables — ROT, the quarter-square multiply, the star layer |
    | under the cart `$8000-$9FFF` | 8,192 | ~750 (231 state + 523 shapes) | bulk data walked in **bracketed passes** — the object pool, the enemies' state (`foes.s`, `$9100-$95FF`) and everything chained behind it up to `SHAPES_AT` (`$9800`); from there **`SHAPES`**, every vertex table in the game (1,525 B) |
    | upper RAM `$A000-$BEFF` | 7,936 | 1,796 | `RODATA`, `HIDATA`: tables and cold code, **and anything the IRQ reads** |
    | `DEMO_RAM` `$C000-$DFFF` | 8,192 | 475 + 168 | code or data, full speed, always mapped — `CODE5` (`cam.s` + `hof_seed`, 1,505 B) since 2026-09-15; the top page `$DF00-$DFFF` is KEEP (hiscores, 88 B) |

    (Measured 2026-09-18, after the three moves below. `DEMO_RAM` is where new
    code goes; `HIDATA` is for what the IRQ reads or runs once a level.)

    **Three things left CPU RAM's scarce areas on 2026-09-18**, none of them by
    shrinking anything:

    * **Every HUD label and indicator message** — `MSGDATA`, **bank 9, a bank to
      itself** since 2026-09-20, read straight out of the window by
      `msg_open`/`msg_close` (`hud_game.s`) on the rare frame a row rebuilds or a
      message queues. A new message is a `.byte` in that segment and one table
      byte; it costs no RAM. It rode behind `SPRART` in bank 7 until the message
      set was planned to grow: `IND_LO`/`IND_HI` are the halves of a plain 16-bit
      pointer and `msg_open` maps `MSG_BANK` as a constant, so **one bank is
      where that model stops working** — a second would cost a third index table,
      a bank byte at every reference and a `msg_open` that takes an argument, in
      five source files. The bank is dedicated to hold that limit on purpose:
      8 KB at the measured 13-byte average is ~600 messages, against 4.8 KB
      shared with a neighbour that grows with every sprite.
    * **Every sprite** — the flames', the arrows', the pickup's art and the four
      GPU definition pages, `SPRART`, bank 7, page aligned in the order they
      land in GPU RAM (`sprites.s`). Nothing is staged in CPU RAM: `cart_init`
      arms `gpu_load_cart_begin`, and `spr_pump` drains it (`gpu_load_cart_n`)
      last in every frame until `LOAD_REM` is 0 — eight pages, the first two or
      three frames of the intro. A new sprite is a page in that bank and a slot
      in the definition pages, in one file. (The ship's own sprite, and its
      upload path, were removed: the ship is an outline, 11.14.)
    * **Every vertex table** — `SHAPES` (`shapes.s`, `enemies.s`): rocks, ship
      and every enemy, copied at boot from bank 2 into the RAM under the window
      at `$9800` (`main.s SHAPES_AT`, `cart.cfg WINSHP`; the linker checks that
      they agree and that the tables fit). Every reader already runs inside
      `cart_frame`'s `win_off` bracket, where the window is RAM, and copies the
      vertices with the CPU — nothing hands the OS a pointer into it. A new
      enemy's outline costs no upper RAM; it costs the 523 bytes left in that
      2 KB, and the state chain behind `foes.s` has 231 before it meets it.

    **`DEMO_RAM`, `$C000-$DFFF`: 8 KB that became the game's on 2026-09-11,
    and from now on belong to every MAD-65 cartridge.** The CPU1 ROM is two 8 KB
    halves — the built-in demo at `$C000-$DFFF`, the OS at `$E000-$FFFF` — and
    boot copies both into the shadow RAM and runs from there. The demo only runs
    when no cartridge answers, so from `cart_init` on the demo's half is plain
    RAM that the OS never reads, writes or executes again. It is MAD-65 ABI
    (`DEMO_RAM` / `DEMO_RAM_END` in cpu_os.s; `docs/MAD65_CPU_OS.md`, Memory
    Map), and MAD-65 proves the "never touches" part instruction by instruction
    (`roms/test_cart_hiram.py`, `carts/hiram_test`, also run in madsim).

    What makes it different from the other four:

    * **Always mapped.** It is not under the cartridge window, so `CART_EN` does
      not matter: no bracket to read it, and it is **safe for the IRQ** and for
      anything a pointer handed to the OS is dereferenced from later — the two
      things the RAM under the cart can never hold. Full speed; no wait states.
    * **Code runs from it** as well as data, exactly as from the run area. A
      segment gets there the way `RODATA` got to `$A000`: a `MEMORY` area at
      `$C000`, size `$2000`, a segment with `run=` it, and one more `cart_load`
      in `bootstrap.s` (see 18).
    * **It is not empty on entry.** It holds the demo's image when `cart_init`
      runs — the OS does not clear it the way it clears `$0200-$77FF`, the
      window RAM and `$A000-$BEFF`. Initialise whatever is used; a table that
      trusts zeros here reads the demo.
    * **Two neighbours are off limits.** Never write `$E000-$FFFF` — that is the
      running OS, and a write lands in it — and never write `SHADOW_REG`
      (`$BF70`): run mode is what makes this RAM, and clearing it un-maps the OS
      the game is executing from. A RESET copies the EPROM back, demo and all.

    `tools/preview.py` already matches the hardware here: it loads the 16 KB CPU
    ROM at `$C000` as plain memory, so the demo's bytes are there at
    `cart_init` and a write simply lands, as it does on the machine.

    **`$8000-$9FFF` is RAM, and that is not a trick.** MAD-65's upper RAM chip
    has `/CE` = A15, so it covers `$8000-$FFFF` whole and the cartridge only
    *overlays* it on reads. A write reaches that RAM whatever `CART_EN` says; a
    read needs `CART_EN` clear, which is one `cart_bank` call. It is **full
    speed** — the three wait states are the cartridge's, not this chip's.
    Measured: an off/on bracket costs **73 cycles**, and the toggle is per
    REGION OF CODE, not per access, so a pass brackets itself once
    (`src/window.s`, `cart_frame`'s three pairs).

    Three rules make it usable, and none of them is negotiable:

    * **Nothing the IRQ reads.** `audio_tick` dereferences the SFX step program
      live in the interrupt, and at the normal `CART_EN=1` it would read
      cartridge ROM. That is why `sfx.s` is a `HIDATA` file end to end.
    * **Nothing read by code executing from the window.** That code needs
      `CART_EN` set and this RAM needs it clear; they cannot both be true. Data
      touched by a window-resident routine belongs at `$A000` instead. See
      `open_questions.md` F5, which is the only thing this rule constrains.
    * **The bracket always closes.** `boot_frame` is a trampoline that executes
      *from* the window, so no path may leave `cart_frame` or `cart_init` with
      `CART_EN` clear.

    What makes the brackets safe to nest inside is that **every routine that
    borrows the window restores the whole `CART_BANK_MIR` byte**, `CART_EN`
    included — `do_explosions` for `EXPL_OFF`, and the OS's own
    `gpu_rect_bg_cart` on every path out. Only those two read the cartridge in
    flight, which is why two brackets cover the whole frame.

    The one borrow that is not the game's to schedule is the **VGM player**:
    `vgm_tick` re-banks the window from the VSYNC interrupt, so it lands wherever
    the game happens to be, brackets included. It composes, and that is measured
    rather than read: `tools/preview.py` stands in for the interrupt and fires it
    at a different point in every frame — **216 of 220 landed inside a bracket,
    every one restored the cleared `CART_EN`, and the frame trace is identical to
    a silent build.** See `open_questions.md` F5.


20. **An enemy is a small ordered list of parts sharing one anchor, and every
    part is a `$4E` POLYGON16 call, closed or OPEN.** `src/enemies.s`,
    authored with `tools/enemy_editor.py`. This is the same OPEN bit 22's ship
    wreck already uses (`debris.s do_debris`, `ora #$80`) put to a second use:
    a hull or a turret dome is a closed part, a gun barrel or an antenna is an
    open one, and both ride the SAME GPU-side rotate+scale matrix at the
    shared centre - no per-part CPU1 transform either way.

    MAD-65 also ships `$4F CIRCLE16` and `$43 LINE16`, and enemies use
    neither. `CIRCLE16` has no `SCALE` - the MAD-65 team found nothing to fold
    a scale multiply into once a circle's rotation is gone - and `LINE16` has
    neither `ANGLE` nor `SCALE` at all. This game's camera is always zooming
    (4), so anything without a free GPU-side `SCALE` would need its own
    hand-rolled rescale on CPU1 every frame - exactly the multiply 5 rules
    out. A "circle" part is authored as a closed polygon on a regular N-gon
    instead (`tools/enemy_editor.py`'s "Make regular polygon"); enemies are
    ship-sized, not rock-sized, so 8-10 sides already reads as round, same as
    a 12-vertex rock does not read as machined.

    What this settles is shape REPRESENTATION. The offsets are FRAMEBUFFER
    axes, pre-rotated for TATE exactly like `SHIP_SHAPE` (a negative dx is up
    the player's screen), and `tools/enemy_editor.py` turns them back on the
    way in, so the editor shows what the player sees at ANGLE 0 — it used to
    draw the stored numbers straight, a quarter turn off. A part is also what
    comes apart: a destroyed enemy's wreck is its parts (23), so how an outline
    is split into parts is decided with the break-up in mind. How enemies move
    is 23 for the UFO and `open_questions.md` E6 for the rest.
21. **Enemies simulate on their own window, independent of the rocks' sector-
    grid cull — and for now that window is the WHOLE FIELD.** 6's rule ("physics
    runs only for objects near the camera") stays exactly as it is for rocks;
    it is not being reopened. Enemies opt out of it instead of inheriting it,
    because the two populations do not share the reason the rule exists.

    The rock cull was forced by scale: up to 120 slots at ~290 cycles each to
    integrate is 30%+ of a CPU uncalled (6.1), and it was recently TIGHTENED to
    almost exactly the on-screen rotated-rectangle bound (see `CULRL`/`CULRH`,
    `main.s`), so a rock freezes within about a screen-width of vanishing.
    Reusing that same window for enemies would mean a pursuer that fell one
    screen behind the ship simply stops - which is the opposite of the point of
    having pursuit AI, and it would apply just as much *ahead* of the ship, not
    only behind (the window is a heading-shaped box, symmetric on every side -
    there is no directional bias to fix, only the fact that it is tight).

    `FOE_MAX` is 16 (`radar.s`), not 120, and 16 objects always integrating and
    AI-ticking every frame - not just the ones near the camera - was already
    priced in `open_questions.md` F5 before this was settled: ~150 cycles/enemy
    to decide plus ~290 to integrate is on the order of 7,000 cycles worst
    case, about 3% of the frame. That is what "the whole field" is standing on;
    it is a deliberate choice made because it is currently cheap, not a claim
    that distance never matters.

    **NA RAZIE — for now, not forever.** If the roster grows past what 16
    always-on slots can carry, or a single enemy's per-frame cost grows (more
    parts, heavier AI, its own collision pass) past what rides free on this
    budget, the lever is an enemy-only window — sized on its own terms, not
    inherited from `CULRL`/`CULRH` — not silently falling back to the rocks'
    tight one. See `open_questions.md` E6.

    **The first enemy already made it cost more than the estimate, and the
    answer was to THINK less often, not to simulate less.** The UFO's AI with
    its obstacle search came to ~12,000 cycles a frame for six of them; every
    UFO now integrates every frame as this entry says, but decides every 2
    frames near the camera and every 8 far outside it (23). Still the whole
    field.
22. **A LIFE LOST AND A GAME OVER: two states, and the ship comes apart into
    four pieces of itself.** `src/gameover.s`, `src/debris.s`, `ship.s
    ship_die`.

    Lives were a number in the HUD's corner that nothing decremented. They now
    mean something, and the two endings are deliberately different in kind:

    * **A ship in hand.** The puff a rock's death throws off, on the ship's own
      position; `SE_DEATH`, CETAS's loss tune transplanted verbatim; and the
      ship comes straight back **where it stood**, full hull, blinking for
      `SHIP_INVULN` = 180 frames (3 s, CETAS's own number). In place, not
      teleported to a clear spot: the world wraps and the camera rides the ship,
      so there is no middle of the screen to come back to.

      The grace period is **NOT intangibility**. CETAS's whale swims through
      what hit it; this ship still rams, still bounces, still rings — only
      `SHIPHP` stops paying (`physics.s ship_hurt`). A ship gliding through the
      middle of a rock whose far side you can see reads as a broken collision
      test, not as mercy. The blink is `SHIPINV & 8`: eight frames shown, eight
      hidden, 3.75 Hz — measured, not copied; CETAS's own comment on that test
      says 4/4 and is wrong.

    * **The last ship.** `SHIPGONE`, and the hull comes apart. `SHIP_SHAPE` is a
      closed ring of fourteen vertices, and `debris.s` cuts that ring into
      **four runs** — the port nozzle pod (0..5), the nose (5,6,7), the
      starboard pod (7..12) and the tail spike (12,13,0) — each drawn as one
      `$4E` POLYGON16 with N's OPEN bit set. Consecutive runs share their end
      vertex, so the four together are exactly the fourteen segments the intact
      hull draws, and an `.assert` in the file says so. **A pod comes off as a
      pod:** a recognisable part of the ship you were flying, not an anonymous
      stick. An earlier cut spawned six generic radiating strokes and read as a
      starburst placed where a ship had been.

      Nothing is authored beyond the four cut points. Change the ship in
      `tools/shape_editor.py` and the wreck changes with it, in step.

    **THERE IS NO ANIMATION TABLE AND NO ANIMATION EDITOR, and that is the
    decision, not an omission.** A keyframed break-up would be kilobytes of data
    per ship, would need a tool to author it, and would still have to
    interpolate — which is the multiply this does not do. The whole motion is
    four constants (`DEBRIS_FRAMES` 120, `DEBRIS_K` 11, `DEBRIS_JIT` 32,
    `DEBRIS_SPIN` 2) and one add per piece per frame. A piece's launch velocity
    is its own pivot offset times `DEBRIS_K`, so the four leave together but not
    in step; the jitter is what stops them reading as one hull being inflated,
    because a pure radial scale-up of a shape is still that shape.

    **THE FOUR ARE ONE SETTING, NOT FOUR**, and the file says so at the top of
    them, because it cost three passes to learn:

        radius reached = |c| * (1 + DEBRIS_FRAMES * DEBRIS_K / 256)
        tumble         = DEBRIS_FRAMES * DEBRIS_SPIN, brad (256 = one turn)

    So *halving* `K` and `SPIN` while *doubling* `FRAMES` is the same break-up in
    slow motion — same distance, same amount of tumble, twice the time to read
    it — and that is exactly the move that took it 60 → 120. Changing the
    duration alone changes how far the wreck flies and how many times it turns,
    which is a different break-up, not a slower one. `JIT` scales with `K` for a
    third reason: left at 64 against `K` = 11 it exceeds the smallest launch
    component (the pods' 22) and throws a piece sideways faster than it was ever
    aimed. The wreck ran at 45/28/64/4, then 60/21/64/4, and is now 120/11/32/2.

    The spin is also **punctured**: a plain centred range includes zero, and at
    `SPIN` = 2 that leaves one piece in four not tumbling at all, which reads as
    a piece that got stuck rather than one that drew a low number. Folding
    `0..SPIN-1` up to `1..SPIN` makes the range symmetric and zero-free for two
    bytes.

    The wreck is drawn for **exactly** `DEBRIS_FRAMES` frames, and getting that
    right needed one non-obvious thing: `do_debris` tests `SHIPGONE` and
    `GSTATE`, **not** `DBN`. `state_tick` runs early in the frame and has
    already counted `DBN` down by the time the draw pass reaches it, so a draw
    gated on `DBN` silently loses the wreck's last frame — the first cut drew 59
    of 60. The banner is armed on the frame *after* the count reaches zero, for
    the same reason, and winds `HUD_PHASE` as it does so: the beat between the
    wreck vanishing and the words appearing should be chosen, not whatever the
    paint stagger happened to be on the frame the ship died.

    **The wreck is SCREEN-anchored, not world-anchored** — offsets are full-res
    screen pixels from where the ship's centre is drawn, so no piece goes
    through `view_xform` or `zoom_fb`. That is free, and it is also right: from
    the frame the ship dies the throttle walks itself back to the resting tier
    (`input.s throttle_rest`), one `THRTL_ACCEL` a frame, so the world coasts to
    a halt and the zoom eases out to 1:1 underneath a wreck that stays put.
    Snapping the throttle instead would stop the world dead in one frame, which
    reads as the game crashing rather than as the ship dying.

    **The state machine is TWO states and stops there.** `GS_PLAY` and
    `GS_OVER`, one `GSTATE` byte, one `game_start` entry point that `cart_init`
    also calls — so the boot path and the restart path cannot drift apart. CETAS
    has a title screen, a level summary, a continue countdown and a hall of
    fame; none of those exists here yet, and inventing them as a side effect of
    "the ship should explode" would be the wrong way round. What this fixes is
    the SHAPE, so they have somewhere to attach.

    **The banner is ONE line, and the two words trade places on it.** "GAME
    OVER" and "PUSH FIRE" are both nine characters — not a coincidence, the
    constraint the second was written against — so they occupy the same nine
    cells on the screen's middle row and swap every `GO_SWAP` = 64 frames
    (~1.06 s). Nothing moves: the line does not change width, there is no second
    row competing with it, and the alternation itself is what draws the eye. Two
    static rows said the same thing and sat there.

    It is background text on a paint phase of `hud_game.s`'s own arbiter — which
    is what finally makes that file's "four emitters" header true and its
    `HUD_PERIOD` 8 rather than 6 — so the whole price of the alternation is one
    command every 64 frames and nothing at all in between. `GO_SWAP` is asserted
    to be a whole number of paint periods: the swap then always lands the same
    distance before the row's phase, and the cadence is exactly 64 frames rather
    than 64 plus whatever the stagger felt like.

    FIRE is armed only once the wreck is gone, so the reflexive shot a player
    fires as the ship dies cannot skip it, and the edge is consumed so it does
    not also come out of the new game's first gun frame.

    **`JOYIN` / `JOYINP` / `JOYINV`.** While `SHIPGONE`, `do_input` republishes
    the three joystick bytes as zero and every reader in the program — the turn,
    the throttle, the boost gesture, the teleport, `thrust.s`'s five nozzles and
    their puffs, `shots.s`'s gun — reads the republished copy. One test in one
    place instead of six scattered guards. `state_tick` reads the raw
    `JOY1_PRESS`, because the one control that must work when there is no ship
    is the one that starts a new game.

    **THE SOUND OF IT IS THREE VOICES, AND THE ARBITER HAD TO BECOME GENERAL.**
    The first cut was CETAS's `se_death` taken across whole — five steps falling
    72 → 55 on one voice — and it read as what it literally is, a few square
    notes. One square wave playing five pitches is a *tune*, and losing the ship
    is not a tune. It is now three simultaneous layers, all authored to the same
    91 frames so they end together: a **warble that falls** on `VOICE_SHIP` (six
    one-frame alternations are heard as one unstable tone, not as six notes, and
    that instability is the sound of something tearing; the alternation then
    widens and slows into a plain fall onto the engine's lowest note), a
    **slower, lower second voice** on `VOICE_GUN` that beats against it — two
    square waves a fraction apart is the only chorus a PSG has — and a **noise
    blast** underneath, mode 6, peaking at 14 and decaying over the full 91.

    That exposed a real hole. The loss tune sits on `VOICE_SHIP` with the klang
    and the teleport, and the ship goes on ramming rocks while it plays —
    *especially* while it is invulnerable and blinking, when grinding along one
    is the normal case — so every ram shot the tune out from under itself after
    four notes. `sfx.s` already had an arbiter for exactly this failure, but
    only for the single noise voice (a thruster puff cutting the boost hiss).
    It is now **per voice**: `VPRI`/`VLEN` × 4, `sfx_fire` itself is the door
    everything goes through, `noise_fire` is gone, and one priority scale covers
    all four voices because priorities are only ever compared *within* one.
    `PRI_DEATH` outranks everything, so for its ~1.5 s the death owns the chip.

    The one deliberate exception is the body layer, which is `PRI_FEEDBACK` and
    therefore loses its voice to the player's gun. On a life that is *not* the
    last one the ship is back immediately, and a shot taken in the next second
    and a half has to be heard. Losing the bass of a chord to the player's own
    trigger is the right trade; losing the whole death to it is not.

    Cost: **+400 cycles median** on CPU1, 0.17% of the frame, and the 220-frame
    `tools/preview.py` trace is otherwise byte-identical to the build before it.

    **The trap this cost a debugging session to find, and it is a rule now:**
    RAM in this cartridge is hand-placed equates spread over four files, and
    they do not collide loudly. The first cut of the death state took
    `$6248-$624C`, which looks free from `main.s`'s own page — the names around
    `SHIPHP` stop at `$6247` — and is not: `physics.s`'s `COL_UX`/`COL_UY` and
    `main.s`'s own `CULRL`/`CULRH` both claim bytes in it. The collision normal
    and the cull window came out as the joystick, and the **only** symptom was a
    preview whose score came out different. Before placing a byte, grep the
    whole of `src/` for its address range, and assert both ends of the block
    against its neighbours the way `main.s` now does.
23. **The first enemy is the UFO: it patrols, sees, chases, shoots and keeps
    out of everything — and it is steered, not a physics body.** `src/foes.s`;
    the model and every tunable are `physics.md` 9.

    **It never turns.** The Asteroids saucer, drawn at ANGLE 0 so it always
    looks the way the editor shows it (20), scaled by the zoom like everything
    else. Two parts: a closed hull and an open dome.

    **The level says where, which way and how fast.** `levels.s` enemy records
    are SEVEN bytes now — position, `KIND`, patrol heading (brad, the ship's
    convention) and patrol speed in px/s (0..175; 0 holds a post). Only `KIND` 0,
    the UFO, is loaded; a kind nothing can fly is skipped, not faked.
    `tools/level_editor.py` edits the two new bytes, draws the course as an arrow
    and, on request, each UFO's sight circle.

    **Sight is a WORLD distance.** `FOE_SEE` is the resting screen's height,
    400 px = 6,400 world units, and the zoom does not change it: at rest it
    reaches past the screen's edges (the ship sits 70 px low, so 270 px ahead,
    130 behind, 150 aside), and fully zoomed out a UFO can be on screen before
    it sees you. Seeing starts the chase: toward the ship at `FOE_SPD`, half the
    ship's top tier, easing in to hold `FOE_STAND` = 160 px off rather than
    ramming. The first UFO to see the ship — the first, not every one, since a
    chase already under way is not news — sounds the ALARM: `SE_ALARM`, three
    flat beeps on `VOICE_ROCK` at `PRI_ALARM`, and ENEMY DETECTED on the message
    bar. It holds its fire until it has closed to `FOE_SHOOT` = 220 px (firing
    from the edge of sight read as being shot the instant it saw you), waits a
    second more, then fires once a second while the ship stays that close,
    aimed at where the ship IS — no lead — with a bullet that does NOT inherit
    the UFO's velocity, or it would not go where it was aimed. Past `FOE_LOSE`, twice the sight, it is put straight back on its
    patrol course and speed from wherever it is; the gap between the two radii
    is the hysteresis that stops a ship on the edge flipping it every frame.

    **Its bullet is the gun's bullet**, same command, same speed, same screen
    margin, and dies the moment it leaves the screen once it has been on it; one
    fired from off screen gets `FSH_MIN` = 60 frames to arrive first. It costs
    the ship one ordinary hit (`FSH_DMG`) through `ship_hurt`, as a ram does, and breaks
    rocks the way the gun does — for no score (`FOEKILL`), thrown across its own
    heading (`SPL_HD`, which the gun sets too now). It hits against the SECTOR
    GRID, not the visible list, so it hits what is in its way off screen as well.
    It is tested swept: against the ship, four points along the frame's step
    relative to the ship; against a rock, two. Bullets do not collide with
    bullets.

    **The player's bullets** hit a UFO on the screen with shots.s's own swept
    test. Three hits (`FOE_HP` = 30, 25); 50 a hit and 100 on top for the last, so the killing blow
    pays both, like a rock's. It dies with a rock's boom, flash and break shake
    — and, since 42, a shriek on top — and its PARTS fly apart and tumble for 1.5 s — debris.s's recipe, with parts
    where the ship has runs. A ship that RAMS a UFO pays a ram's worth, as for a
    rock, and the UFO is shoved aside undamaged — the rocks' rule (physics.md
    4.6).

    **It avoids; it never collides.** Every rock, other UFO and the ship has a
    zone round it, 32 px wider than contact; inside the deepest one the
    UFO is snapped out if touching, loses any velocity into it for an outward
    push, and slides round it — or, holding a post, steps off the path of what
    is coming at it. `tools/preview.py` checks the result over EVERY rock on
    every frame: no live UFO ends a frame more than a collision unit inside one.

    **It thinks every 2 frames near the camera and every 8 far from it** (21),
    integrates every frame, and skips its screen transform for a few frames when
    it is well off the screen. Measured on the 220-frame preview flight with the
    level's six: `do_foes` went from 19,300 cycles median / 26,900 worst as first
    built to 10,800 / 18,300; the median frame is +10,500 cycles over the build
    before the UFOs (92,300 -> 102,800), the worst in-flight frame 56% -> 64% of
    budget, and the startup frame, the worst of all, 70.1% -> 76.8%. The GPU side
    is NOT measured (`open_questions.md` E6): madsim's F3 meter is owed a look.

    **Where it lives.** Its state is under the cartridge window, `$9100-$95FF`,
    read only inside `cart_frame`'s bracket (19); its code is `CODE2`, the new
    `CODE3` (18) and `HIDATA`. Its shot is `SE_UFO_SHOT`: the gun's crack a fifth
    higher, on `VOICE_ROCK` so the two guns never cut each other off.
24. **The second weapon is the LASER: one beam from the nose to the top of the
    screen, twenty frames a press, through everything, `LSR_DMG` = 4 hit points
    a frame.**
    `src/laser.s`; the model and its numbers are `physics.md` 10, and its
    balance is `open_questions.md` B9.

    **FIRE2's single click chooses it** — the gun and the laser in turn. The
    double click is still the teleport (B1), so a change lands `TPCLICK_FRAMES`
    after its click: until then it could be the first half of a double. It is
    said on the message bar (FRONT BLASTER ARMED / LASER ARMED) — and it JUMPS
    THE QUEUE there, the only line that does (`hud_game.s indicate_urgent`):
    every other message reports something that happened, while this one is the
    state the player is now flying in, and queued behind a HULL BREACH's two
    seconds it would arrive after they had already fired the other weapon. It is
    heard as CETAS's click-clack
    (`SE_WSWITCH`). A new game starts on the gun. A beam already burning when
    the weapon changes burns out, the way a bullet in flight is not recalled.

    **It is CETAS's laser, drawn CETAS's way.** `gpu_hdotline`, the byte-aligned
    dotted rule every laser in CETAS is drawn with; CETAS's twenty frames
    (`HERO_LASER_DUR`); CETAS's falling tone (`SE_LASER`, at the gun's level).
    One rule where CETAS draws two. It fits here for a reason CETAS does not
    have: the ship always points up (3) and TATE puts up on the framebuffer's
    −X, so nose-to-top-edge is ALWAYS a horizontal framebuffer line, and the
    cheapest line opcode there is is always the right one. The rule is widened
    to whole VRAM bytes by the OS, so its near end can reach up to 3 half-res px
    into the nose — under the hull, which is drawn after it.

    **The ship is not locked while it burns**, as CETAS's whale is. The beam is
    laid from wherever the nose is on every frame, so turning SWEEPS it across
    the field — and the sweep is TESTED, not sampled: on a frame the heading
    moved, the hit test is widened on the side the beam came from by what the
    turn swept at each target's distance (physics.md 10), because at the top of
    a zoomed-out screen one brad carries a speck most of its own width. One
    press, one beam; a press while it burns does nothing.

    **It pierces, and it is paid like the gun.** Every rock and UFO whose circle
    it reaches loses `LSR_DMG` = 4 hit points a frame, two fifths of a bullet
    (25) — `rock_take_hit`, `foe_take_hit` — and pays pro rata for it, 4 a
    frame on a rock and 20 on a UFO, so a rock is worth the same to the beam as
    to bullets. Nothing stops it, and a rock broken in it drops both
    halves in it. The test is the gun's own, on the screen: the visible list and
    `FOEFX/FY`, which carry the screen shake, against a beam placed with the
    shake too. A rock something else broke earlier in the frame is still in the
    list stamped `SHP_DEAD`, and is skipped — its slot may already be free.

    **`tools/preview.py` flies it**, on a flight of its own after the main one
    (which never changes weapon, and is unchanged by this entry save for the
    cycle counts): the main flight's opening climb and turn, zoomed out, with
    one FIRE2 click and three beams into the turn - a press into the first -
    then a UFO parked ahead of a fourth on the straight, a double click and a
    click back. It checks the choice and its timing, that the
    teleport leaves the weapon alone and FIRE fires no bullet on the laser,
    exactly `LSR_FRAMES` lit frames a press, one rule a frame from byte 0 to the
    nose's byte on the ship's row, at most `LSR_DMG` off a rock a frame and only
    while lit, that every hit point lost is explained by the beam's geometry and
    nothing level with it and inside its width escapes, that no rock the beam
    swept across was stepped over, and that the UFO loses `LSR_DMG` a frame and
    dies on the frame its hit points run out.

    **What it costs, on CPU1** — inclusive, by stack depth, over preview.py's
    flights in py65: **35 cycles a frame dark** (`lsr_frame` 21, `lsr_foes`
    14). **Lit, on the zoomed-out turning flight, 1,824 median and 2,737 at the
    90th percentile** — 0.8% and 1.2% of the frame, against the gun's own hit
    pass at 2,027 median — and **13,911 at worst, 5.9%**, which is `rock_split`
    running inside it on the frame a big rock comes apart: the split a bullet
    would pay for too. (`lsr_foes` alone peaks at 7,572, the frame a UFO dies
    and its wreck is spawned.) The GPU side is one `HDOT_LINE` a frame and is
    not measured (B9).

    **Where it lives.** Its code is `CODE4` (18, amended a third time); its
    state is `$6FC9-$6FE1`, the free tail of the page `main.s`'s death block
    sits on, asserted against `thrust.s`'s `$7000`. It reaches the frame through
    three hooks: `do_shots` dispatches FIRE through `wpn_trigger` and calls
    `lsr_frame` after the gun's hit pass; `do_foes` calls `lsr_foes` after
    `foe_hits`; `input.s do_fire2` calls `wpn_toggle` when a single click is
    confirmed.
25. **Hit points are counted in tenths of a hit: `HIT_HP` = 10.** `main.s`.
    Every hit point in the game was multiplied by ten on 2026-09-11, and every
    ordinary hit with it, so that the laser can deal a fraction of one. A
    bullet, a ram and a UFO's bullet each cost `HIT_HP` (`SHOT_DMG`, `RAM_DMG`,
    `FSH_DMG`); the laser costs `LSR_DMG` = 4 a frame. The ship has `HP_MAX` =
    50, a UFO `FOE_HP` = 30, the rocks `ROCK_HP` = 50 / 40 / 30 / 20 / 10 — all
    written as so many `HIT_HP`, so they still read as "how many bullets".
    Nothing changed for the gun: five hits end the ship, three a UFO, and a rock
    takes the bullets it always took.

    **What had to change with it, beyond the numbers.** Every `dec` of a hit
    point became a subtraction that treats "more than was left" as the last
    hit, because two sizes of hit now mix — a 50 lasered down to 8 and then
    shot is at -2: `rock_take_hit`, `rock_take_hit_deferred`, `ship_hurt` and
    the new `foe_take_hit` all take the hit's size in A. The two thresholds that
    meant "one left" mean "one ordinary hit left" now (`CRACK_HP`, and HULL
    CRITICAL at `HIT_HP`): the crack is drawn, and its shake fires, when a hit
    takes a rock across `CRACK_HP`, whatever the hit's size. A split refused
    for want of a slot leaves the rock on 1 — a sliver — as it always did. The
    hull bar used to form `hp × HP_CELLS` in a byte, which 50 overflows; it
    carries a remainder round its add loop instead (Bresenham's trick), which
    stays under `HP_MAX + HP_CELLS`. And the laser is paid pro rata, `SCORE_HIT`
    per `SHOT_DMG`.

    **The one balance change it makes** is the laser's, and it is B9's to
    judge: a press is 80, so the largest rock (50) goes in thirteen frames with
    the beam still lit for the halves it just made, and a UFO (30) lasts eight.
26. **Camera lag stays at `SHOFF_LAG` = 4 (ship slide and zoom) and `CAMX_LAG` =
    5 (turn lean).** Flown and confirmed comfortable at the top tier — not
    nauseating, and not so slow it disconnects the throttle from the view.
    Closes `open_questions.md` B3.
27. **The ship never banks.** It stays drawn nose-up at every turn rate; the
    sense of turning is carried entirely by the world's own rotation and the
    camera's lean into a turn (34 below), not by tilting the ship's outline. No
    bank-angle mechanic exists or is planned. Closes `open_questions.md` B4.
28. **Heading stays at its natural 8.8 fractional resolution — no separate
    coarse table.** The turn ladder (15-17 above) already needs the fraction
    for its rate math, and with the ship always drawn nose-up the only place
    resolution would show is the smoothness of the world's own rotation, which
    reads fine at full resolution. Nothing coarser was ever built, so the
    32-vs-256 choice needs no answer. Closes `open_questions.md` B5.
29. **Firing does not slow the ship.** No recoil or impulse is taken off
    `THRTL` or `SPD` on a shot. Closes `open_questions.md` B8.
30. **The laser's numbers (24 above) are flown and judged, not just built.**
    `LSR_DMG` = 4/frame, `LSR_FRAMES` = 20, no ammunition and no cooldown past
    its own burn, `TPCLICK_FRAMES` = 18 switch latency — all confirmed in
    play. Closes `open_questions.md` B9.
31. **Zoom-out stops at 2x — 3x was judged and declined.** The visible-object
    count scales as the square of the zoom, and 2x already reads well against
    the legibility floor (32 below); going further was measured against what
    it costs and not worth it. `ZCAP`'s hook for a performance-driven cap
    stays, but nothing past 2x is a design target. Closes `open_questions.md`
    C1.
32. **A small asteroid stays legible in 1-bit at 300x400 at the 2x zoom-out
    ceiling.** Checked by eye and confirmed. Closes `open_questions.md` C2.
33. **Ship screen-Y range is 40 px below centre at rest, +126 px at +350, -40
    px at full reverse, eased and linear in speed.** Flown and measured; 127
    stays the hard ceiling (signed-byte offset). Closes `open_questions.md`
    C3.
34. **The camera's lean into a turn is +/-80 px at full lean and top speed
    (`CAMX_TIER`, `CAMX_LAG` = 5, `CAMX_CLAMP` = 768), and the sign is correct
    as flown.** Closes `open_questions.md` C5.
35. **The camera-frames-nearest-enemy servo is flown and good.** `CAM_M` = 24,
    `CAM_MHYS` = 16, `CAM_F` = 250, `CAM_SSTEP` = 4 and the servo's step rate
    stand as final. Closes `open_questions.md` C6.
36. **The flame sprite's step scheme is final.** `thrust.s`'s `FLAME_N` = 27
    slot table stays as authored; no further pre-scaled sizes are being added
    for flames or shots. Closes `open_questions.md` D2.
37. **The star field is two parallax layers: `STAR_N` = 50 far stars at 1/4
    parallax, `MOTE_N` = 10 near motes at twice ship speed, single pixels, no
    streaks.** No further layers and no denser field. Closes
    `open_questions.md` D4 and D10.
38. **Stars and radar blips stay on the half-res, 2-pixel `DOT_PIXELS`
    lattice.** The full-res `PIXEL` op does not earn its per-point cost;
    half-res reads fine on real hardware. Closes `open_questions.md` D8.
39. **Rocks stay full-res solid (`$4E POLYGON16`), not dotted.** Looked at
    side by side, full-res solid reads clearly better despite losing the
    dotted rim, and the extra GPU cost per vertex (1,873 cycles against 1,564
    dotted) is worth it. What remains open about the shapes themselves
    (authoring genuinely full-res outlines instead of the doubled half-res
    tables) stays at `open_questions.md` D11, narrowed to that.
40. **The radar's admission test and its 25,600-unit reach are flown and
    judged, not just measured.** The catchment is a circle tested entirely in
    world space before the `ROT[]` transform: a box pre-reject (`|dx|`/`|dy|`
    against the radius, no multiply) followed by the precise round test
    (`dx*dx + dy*dy` vs `R*R`, through the same quarter-square table star
    occlusion uses) — a circle is rotation- and scale-invariant, so nothing
    needs to clip a survivor afterward. Candidates come from a flat scan of
    the object array with the class window (G8) tested first, not the sector
    grid — right at 12,800 units (a 9x9 ring), wrong at 25,600 (a 15x15 ring
    walks 88% of the world to skip 12% of it). The reach itself is 25,600
    world units, covering 48% of the torus at no on-screen cost, bounded
    above by the 32,768 point past which a wrap-correct signed subtract stops
    being unambiguous. Closes `open_questions.md` G2.
41. **The background-bitmap radar fallback was considered and rejected.** Its
    mechanism turned out to be exactly what the radar's own furniture already
    uses (`LOAD`, one 256-byte page at a time, obeying the two-frame rule),
    which settled its real cost: a full redraw of the 100x100 corner is 20
    pages, ~0.7 s — a scene transition, not a refresh rate. If the live
    per-frame path ever needs relief, the lever is the class window (G8), not
    a second rendering mode. Closes `open_questions.md` G6.
42. **The third weapon is the EMP, and every enemy's death is one event.**
    `src/emp.s`; the design is `open_questions.md` F8's, which this closes but
    for the GPU cost below.

    **The trigger: FIRE1 + FIRE2 held together**, on the frame the second goes
    down (`emp_input`, from `do_input` before `do_fire2`). It costs
    `SATN_EMP_COST` = **200** Saturnium = `SATN_FULL`, the charge the hull's
    spark ring already flashes at, so the readout is built. Short of it the
    chord says **EMP NOT AVAILABLE** through `indicate_urgent` (the bar's
    second queue-jumper, after the weapon change: it answers a press) and
    spends nothing. The chord eats both edges: a pending FIRE2 click is
    cancelled and `TPLOCK` armed, so it is neither a weapon change nor half a
    teleport, and this frame's FIRE1 edge is cleared from `JOYINP` before the
    gun sees it. A FIRE1 that went down a frame EARLIER has already fired — so
    with the laser armed and 200-207 in the hold, the beam's 8 can leave the EMP
    short. One EMP at a time; a chord while one grows buys nothing.

    **The ring is a screen circle and nothing else**: one `DOT_CIRCLE` (`$FF27`,
    now in `mad65.inc` as `API_GPU_DOTCIRCLE`) about the hull's drawn centre
    (`FLCX/FLCY` halved), `R = n << 3` half-res px for `n` = 1..`EMP_FRAMES` =
    31 — 16 full-res px a frame, 0.51 s, 248 at the end. *Widened after a
    madsim dump*: the first cut grew 8 px a frame to 128, the half-diagonal
    from the screen's MIDDLE — but at speed the ship sits up to 126 px below
    it (33) and the camera leans 80 px (34), so the far corner is ~400 px away,
    and the dump showed a pulsar on the screen, near its top, 33 pages from a
    fast ship, outside the reach and alive.

    **The kill is the radar's round test at radius `K = n << 1`, in position
    high bytes**: every live enemy — a spider still MOUNTED on its rock
    included, asleep or awake, on the screen or not, hit points ignored — with
    `dx² + dy² <= K²` on the high-byte delta, out of the quarter-square table.
    No multiply, no zoom. One high-byte unit is 4 half-res px at the 2x
    zoom-out, so there the kill and the ring are one circle frame for frame,
    out to 62 pages = 15,872 world units = 496 full-res px, past every corner;
    at 1:1 the kill runs twice the ring's pace, off the screen. Far enemies die on later
    frames, so a crowd's wrecks spread over the half second. Rocks are never
    touched: the pass walks `FOEST` and nothing else.

    **Every enemy's death goes through `foe_kill`, whatever killed it, and is
    the same event.** The pay is unchanged — the gun's `SCORE_FOE_HIT` 50 a hit
    and the laser's pro rata share still pay as they land, and `SCORE_FOE_KILL`
    100 on the death (`FOEKILL`, a pulsar's beam, still pays nobody). The EMP
    lands no hit, so an EMP kill is `SCORE_FOE_KILL` alone: it pays for the
    death, not for an effortless hit. The death is a rock's — the boom, the
    one-frame flash, the break shake — with a creature's shriek on top:
    `SE_SCREECH`, a high warble that sags, 16 frames, on `VOICE_ROCK` at
    `PRI_BOOM`, so it and the boom's noise voice never cut each other.

    **Measured** (`tools/preview.py`'s EMP bench, py65): the refusal, the
    price, 31 rings with `R` 8..248 about the hull, each placed enemy dying on
    exactly the first `n` its distance fits (a UFO at 4 pages on n=2, a
    250-hit-point one at (4,4) on 3, a mounted spider at (7,9) on 6, an
    off-screen UFO at (24,12) on 14, and a PULSAR at the dump's (12,32) on 18),
    one at 70 pages untouched, +100 a kill
    and nothing more,
    no rock's hit point lost. **CPU1: 1,105 cycles a frame** over 16 live
    enemies with none in reach (0.47%); a kill adds `foe_kill`'s own cost, as
    from any weapon. **The GPU side is NOT measured (TBM)**: a dotted circle is
    roughly half of `CIRCLE16`'s ~54,000 cycles at R = 100, and this one is on
    the slower clipped path from the frame it crosses the nearest edge — ~75
    half-res px from the middle of the screen — to its last. madsim's F3 meter during an
    EMP is the measurement; if it does not fit, the ring gives — every other
    frame, or stopped at the screen edge — and the kill does not.

    **Where it lives**: CODE6 in DEMO_RAM, behind the pulsar; its state
    (`EMPN` and three bytes of scratch) under the window behind satn.s's. Both
    new sound programs and the message's text are in CODE6 too, because UPPER
    had 41 bytes left: sfx.s and hud_game.s keep only their table rows there.
    DEMO_RAM is otherwise kept for the next enemies' code — nothing else
    moves there.
43. **The shield: 30 s of a quarter of every hit, a dotted circle round the
    hull.** `src/shield.s`; `open_questions.md` F6, which still owns the pickup.

    **What it does**: `physics.s ship_hurt` calls `shield_armour` straight after
    `satn_armour`, so the hull pays `(cost + carried) / 4` of what the
    Saturnium armour left — the remainder carried in `SHARM`, the armour's own
    trick, so the pulsar's beam at 1 a frame costs 1 frame in 4, not 0. It
    changes what the hull PAYS only; a ram still bounces and klangs.
    `SHLD_FRAMES` = 1,810 (30 s), the last `SHLD_WARN` = 241 (4 s) blinking
    `SHLD_BLINK` = 8 frames on and off. **SHIELD ENABLED** is queued when it
    goes up and **SHIELD WEARS OFF** when the blink starts. A ship lost
    (`SHIPGONE` or the respawn blink `SHIPINV`) drops it.

    **What it looks like**: one `DOT_CIRCLE` about the hull's pivot
    (`FLCX/FLCY` halved). Centring it on the middle of `SHIP_SHAPE`'s -22..+10
    instead was tried and judged worse in flight. The half-res lattice leaves
    it a full-res pixel off on a frame the pivot lands on an odd one — a madsim
    dump showed exactly that, 1 px sideways at `FLCY` = 149. So the view's
    centre `FBCY` moved one px to the right on the screen, 149 -> 148 (main.s),
    set by eye so the circle sits round the hull at rest; in flight the turn
    lean moves the ship off it and the pixel comes and goes.
    `SHLD_R` = 15 half-res px at 1:1 (30 full-res; the nose is 22 out),
    **scaled by the zoom the way the hull is** — `qmul` by `ZOOMH`, the laser's
    way of putting a radius on the screen — so it shrinks smoothly, a half-res
    pixel at a time: 15, 13, 11, 9, 8 at ZOOMH 127/112/96/80/64. (A first cut
    borrowed the Saturnium ring's two-step 3/4 rule and looked wrong.)

    **No pickup yet**: `shield_on` (full 30 s again if already up) is the
    pickup's door; the TRAINER's DOWN on the second pad opens it for now.
    The pickup is decided (every killed spider drops it, 47), not built.

    **Measured** (`tools/preview.py`'s shield bench): raised by the trainer,
    one circle a frame about the hull, R per zoom as above, a hit of 10 paying
    2 and ten 1s paying 2, the warning queued on frame 241 exactly, the blink,
    down at 0, dropped by a lost ship.

    **Where it lives**: CODE2 (bank 1, run area — DEMO_RAM stays for enemy
    code); its three bytes of state under the window behind the EMP's; its two
    strings in CODE2, only their `IND_LO`/`IND_HI` rows in UPPER. `game_start`
    resets it through a tail call out of `laser.s lsr_reset`, so DEMO_RAM,
    where `game_start` lives, needed no byte.
44. **The exit gate: invisible until the mission is done, then an X in the
    world, an X on the radar and the enemy arrow pointing at it.**
    `src/gate.s`; settles `open_questions.md` A2 and the first half of F1.

    **Per level, in `levels.s`** (the level editor places the gate by drag and
    picks the mission): `Lx_GTX`/`Lx_GTY`, where it stands — fixed, it never
    moves — and `Lx_MISN`/`Lx_MPAR`, what opens it: `MS_ROCKS` (every rock of
    classes 0..MPAR gone, off `RKLIVE`; level 0 asks for the 192s), `MS_FOES`
    (every placed enemy dead), `MS_OPEN` (open from the first frame).
    `levels.s` moved from RODATA to CODE6 to make room (UPPER had 15 B), and
    on 2026-09-20 on to its own cartridge bank, `LEVELS` (section 9).

    **Closed** it costs one mission test a frame and draws nothing. **Open**
    it says EXIT GATE OPEN, and from then: its polygon at its world position
    when near the screen; an X of nine dots on the radar while it is in
    reach (`GATE_RX`, radar_plot's round test) and not on the radar at all when it
    is not, as a rock or an enemy; and, while its centre is
    off the screen, the enemy arrow's sprite on that edge (`cam.s arrow_fb`,
    the second half of `cam_arrow`), blinking in turn with an enemy arrow when
    there is one and steady when there is not.

    **Its shape is an enemy appearance, `EA_GATE`**, authored and animated in
    `tools/enemy_editor.py` like a UFO; `gate_body` is `foe_body`'s loop. It
    is a bottomless well: a fixed equilateral triangle of side 200 px and three
    concentric ones inside it, each shrinking by 0.4^(1/5) a frame over five
    frames, so the smallest vanishes as a new one appears at side 180 and the
    loop has no seam. Its
    ANGLE is `GATE_SPIN`'s own turn (0) minus `HEAD`, so it stays put in a
    turning world. `GATE_DOT` picks `$4C DOT_POLYGON` (1, now) or `$4E
    POLYGON16` (0) at the same size — **still open**, as is the animation.

    **A far gate** (a delta past ±$3FFF) is halved before `view_xform` and
    doubled back after it until one axis is past $3C00, so it lands off every
    edge even at the 2x zoom-out and the arrow still points the right way.

    **Flying in** — the ship's centre within `GATE_IN` (48 px) of the gate's
    on both axes — plays the teleport shimmer and is `SC_SECTOR`
    (`screens.s`): SECTOR COMPLETED on black, a blinking PUSH FIRE after
    `SEC_ARM` (90) frames, and FIRE is `level_begin` (`gameover.s`), which
    `game_start` now falls into: the next sector (round to the first while
    `NLEVELS` is 1) with the score, the ships and the Saturnium kept, the hull
    whole. **`SC_SECTOR` is the tunnel's placeholder**, and the tunnel will
    replace its frame and nothing else (`open_questions.md` H1).

    **Trainer**: RIGHT on the second pad opens the gate.

    **Measured** (`tools/preview.py`'s gate bench): `do_gate` is 50 cycles a
    frame closed, 3,819 open and far, 7,089 open and drawn (3.0% of a frame);
    the 220-frame trace is otherwise identical to the build before it, +53
    cycles median. The bench checks the mission opening it, one X and one
    arrow, UP for a gate ahead and DOWN for one 20,000 units behind, the
    polygon and no arrow on the screen, SC_SECTOR on flying in, FIRE refused
    before `SEC_ARM`, and the next sector keeping score, ships and Saturnium.

    **Where it lives**: code, `levels.s` and the strings in CODE6 (DEMO_RAM,
    **391 B left** there after it); 36 B of state under the window behind
    `shield.s`'s; `EA_GATE`'s tables in RODATA (UPPER, 73 B left).

45. **The campaign's shape: 5 levels x 3 sectors, 5 ships, one flow of
    states.** Decided 2026-09-18 (the user); settles `open_questions.md` A3,
    A5 and the structural half of H1. Nothing of it is built beyond what H1
    and 11.44 already list.

    **A level is a chapter, a sector is a board.** Five levels (`story.md`),
    **three sectors each, fixed** — 15 boards, numbered `1-1` .. `5-3`. The
    briefing belongs to the level; the gate (11.44) ends a sector. **Every
    sector is the same size** — the one 16-bit torus (3.1), because the wrap
    is free and a per-level world size would cost it. What the script calls
    "a far larger area" in levels 4 and 5 is made out of what a sector
    already has: a gate placed far from the start, a denser or more hostile
    population, and instruments that lie (E8) — not a bigger map.

    **The flow:**

    ```
    POWER-ON -> INTRO (once) -> TITLE <-> ATTRACT
      FIRE -> PROLOGUE (story_intro.md, typewriter, FIRE skips)
        per level:  BRIEFING (picture + prose)
          per sector: START BANNER -> PLAY -> gate -> TUNNEL
        (after x-3 the TUNNEL comes first, then the next level's BRIEFING)
      after 5-3            -> ENDING WON  -> HISCORE -> TITLE
      last ship lost       -> CONTINUE? --yes--> the same sector, reset
                                        --no---> ENDING LOST -> HISCORE -> TITLE
    ```

    **The BRIEFING is a picture over prose**, not a full-screen bitmap: the
    picture takes the top half to a third of the screen, the level's text
    (`story_levels.md`) runs under it. That halves-or-better the banks a
    picture costs (H1's RLE bands), five of them in all — one per level,
    none per sector.

    **The START BANNER** is one or two lines over the field for ~2 s:
    `SECTOR 1-2` and the mission (`CLEAR THE LARGE ROCKS`, `DESTROY ALL
    HOSTILES`, `REACH THE EXIT GATE`), read from the sector's `MISN`.

    **THE RADIO IS IN THE TUNNEL** (the user, 2026-09-20), and only there:
    Control and the other ships talk in the debrief and the brief under the
    tunnel's window (below), from the HUD-message bank. **There is no radio
    line during play** - the two HUD rows and the radar keep the screen, and
    what happens in a sector (a foe decloaks, the gate opens, a ship is lost)
    is the message bar's (`indicate_msg`, the `IM_*` strings) or the tunnel's
    debrief afterwards. This replaces the in-flight HUD line this paragraph
    first decided (2026-09-18); the open parts are `open_questions.md` H5.

    **Lives are the five survey ships**, SRV-T01..T05 (`story_levels.md`);
    `LIVES_START` is already 5. Losing one hands over to the next callsign
    (`SRV-T01 LOST - T02 TAKING OVER`, on the message bar; the tunnel's radio
    picks it up in the debrief). A ship lost in a
    sector can be won back in the tunnel that follows it, and only there.
    Ships lost in earlier sectors come back only as **a ship for points** (an
    extra life at score thresholds; the thresholds are TBD). The count never
    goes above five.

    **The TUNNEL follows every sector** and replaces `SC_SECTOR`'s frame. It
    is about a minute long and nobody dies in it. A 300 x 300 window at the
    top holds the flight: forward through space in 3D, rocks coming at the
    camera. Under it are the instruments and the radio, which gives the
    debrief of the sector just flown and the brief for the next: a summary
    and what to do. It is also where the ship gets ready for the next
    sector. It is pseudo-3D: the ship
    flies forward inside an invisible tube it cannot leave. The **joystick
    alone** leans it in eight directions within a limited range, to catch or
    dodge what comes at it, and **springs back to the centre** when the stick
    is let go. No button does anything. The minute's stream of rocks,
    Saturnium and pods is **generated from a per-level seed**, like a
    sector's scatter (`levels.s`), so it is the same on every run. The
    instruments under the window show the Saturnium, the ships, the sector's
    summary (score, time, kills) and the radio text. There are two things to
    catch:
    * **lifepods**, one for each ship lost in *this* sector (so at most four,
      since the fifth ship lost goes to CONTINUE instead). Catching one
      returns that ship. A rock hit never takes a caught pod back.
    * **Saturnium**, carried into the next sector (EMP, and later the laser
      and teleport).
    **Any rock hit costs all the Saturnium collected in this passage**,
    never the ship and never a pod. This is the first setting, to be re-tuned
    once it is flown. What is left open is `open_questions.md` H6.

    **No codes, and every game starts at 1-1.** The MAD-65 has no keyboard,
    so a code could not be entered. What replaces it is CETAS's continue
    (`CETAS/src/gameover.s`): when the fifth ship is lost, a CONTINUE screen
    with a countdown offers to **fly the same sector again with everything
    reset: score 0, five ships, the weapons and the Saturnium back to a new
    game's**. The story can be finished that way, and the hiscore table
    stays honest because a continued score starts from zero. Continues are
    **unlimited**, and **FIRE2** takes one (as in CETAS, so that a reflexive
    shot cannot). The hiscore table takes **the best score of any run in the
    game, not the last run's**. The continue window is **10 s** and starts
    once its text is fully shown (as in CETAS). It records the sector reached (`3-2`) beside
    the score, and marks an entry whose game was continued. The ENDINGS
    replacing the GAME OVER banner are agreed but deferred.

46. **Mining stations: one fixed, indestructible landmark in some sectors.**
    Decided 2026-09-18 (the user); **the figure and its wall are built as the
    human base, 48**; the rest is not, and the open parts are
    `open_questions.md` E11.

    **What one is.** A human mining base, the fiction's (`story_full.md`),
    at most **one per sector and not in every sector**, but somewhere in
    every level. It is a simple geometric figure that never moves and cannot
    be destroyed. It is scenery and an obstacle, and gives the player
    nothing. It is placed per sector in `levels.s`, like the gate.

    **Why.** The torus has no landmarks, and a station is one: the player
    knows they have been here. It also gives "clear the field" a reason (the
    rocks threaten the station), and it gives the radio a second voice, the
    station's crew. Its state across the campaign (working, then silent,
    then a wreck) is told by the radio, not by the figure, which stays the
    same.

    **What touches it.** Rocks bounce off it as off a wall of infinite mass.
    Shots end on it. The ship **does not collide**: the station's
    anti-collision field brakes it, so it can neither ram the station nor
    fly through it, and loses no hull.

    **The radar shows it**, whatever classes G8's window is showing, with its
    own mark, while it is in reach, and not at all when it is not, as it does
    the gate. (It once pinned both to the rim and blinked them there; on the
    edge of reach that read as flicker, and the mark jumped inward as the pin
    took hold.)

    **The station under siege is L4** (`story.md`), and the one station
    that is destroyed. It is spread over the level:
    * **4-1:** fragments of a distress call on the radio, with an unsure
      bearing, because the instruments lie;
    * **4-2:** on the way, a wreck;
    * **4-3:** the siege. UFOs are firing at the station, and they keep at it
      until they see the ship, then turn on it. That is a new state before
      the UFO's patrol, detect and pursue (`foes.s`): holding station round a
      point and firing at it. The station **falls in the player's
      presence**, and only then. Its fall is **scripted**: it happens
      whatever the player does, and the figure stays indestructible to the
      physics. It breaks into pieces that are defined later, and they are
      gone after a moment, the way the ship's wreck is (`debris.s`). It
      spits out the crew of SRV-T03's **lifepod**, which **homes on the ship
      by itself and cannot be missed** (F6's magnetism). Catching it is a
      bonus pickup, and it opens the gate: a new mission kind beside
      `MS_ROCKS`/`MS_FOES`/`MS_OPEN`. A **wreck** may stay behind, a
      second figure authored in the editor.
47. **Pickups: dropped by a kill, absorbed like Saturnium, two-frame sprites.**
    Decided 2026-09-18 (the user), not built; the open parts are
    `open_questions.md` F6.

    **Two pickups, each from its own enemy.**
    * **The laser drops from a killed PULSAR** (`src/pulsar.s`), the enemy
      that itself fights with lasers (F8) — **but only while the player does
      not have the laser yet.** A pulsar killed by a player who already has
      it drops nothing. Until it is picked up the laser (24) cannot be chosen:
      FIRE2's single click stays on the gun.
    * **The shield drops from EVERY killed spider** (`FK_SPIDER`, physics.md
      9.1). It is the door `shield_on` (43) was left open for, and it
      replaces the trainer's DOWN as the way in. **Chosen rocks drop it
      too**, marked one by one in the level editor.

    **"Has the laser" means TAKEN.** A laser dropped and still lying in the
    world does not count, so the next pulsar killed drops another: at most
    two in space at once, one per slot.

    **The laser's ammunition is Saturnium** — no separate round count, as
    CETAS has. That is the pool the laser already burns (`SATN_LSR_COST`,
    `satn.s`), so finding the laser only unlocks it.

    **What keeps it.** A **lost ship** keeps the laser and the Saturnium. A
    **sector passed** keeps everything, plus whatever the tunnel changes
    (45). A **continue** takes the Saturnium and every extra weapon back to a
    new game's (45), so the laser has to be found again.

    **A pickup stays until it is taken** — no timeout. At most **2 at once**
    (two slots); a third drop **replaces the older** of the two.

    **Not caught, absorbed.** A pickup is not flown over exactly: it homes on
    the ship by itself and is taken on arrival, the way Saturnium dust is
    (F7) and the lifepod is (46), **with Saturnium's own pull** (`satn.s`,
    `SATP_ACC`): at any distance, from the frame it drops, so it is home in
    under half a second and never really lies in the world. Chosen because
    code space is short and this reuses `satn.s`'s steering rather than
    adding a second. The 2 slots are a safety net for a burst — two pulsars
    killed together by one EMP (42) drop two lasers at once. A 2-button stick has no fine control to
    demand a precise pass over a small icon.

    **What it looks like.** **One sprite for every pickup**, laser and
    shield alike (`assets/png/bonusbox1.png` .. `bonusbox4.png`, 2026-09-20):
    16x16 with an overlay, one GPU page, never scaled, so it is the same size
    at every zoom, and **four frames in a loop, one every 6 game frames**
    (`PK_FRAMES`, `PK_HOLD`). It is drawn in the hardware's axes, like the
    enemy arrow, so it is not turned for TATE. The frame count and the size
    are the art's: `tools/pickupgen.py` takes as many `<set>N.png` as there
    are, and the Makefile's `PICKUP_SET` picks the set.

    **Built 2026-09-18, `src/pickup.s`** (CODE6), all but the rocks marked
    in the editor. A pickup is a slot of `satn.s`'s pool with another tag
    (`SPT_LASER`/`SPT_SHIELD`), held to slots 0 and 1. `foe_kill` drops it
    (`pk_drop`), `do_satn` steers it like a mote and draws it as a sprite
    (`pk_draw`), and its arrival sets `LSRHAVE` (LASER ACQUIRED) or calls
    `shield_on`. The art (`tools/pickupgen.py` → `src/pickups_art.s`) sits in
    `SPRART` and reaches the GPU with every other sprite's at power-on
    (`sprites.s`, 11.19), so it costs no CPU RAM. A kill by a pulsar's beam
    (`FOEKILL`) drops nothing, just as it pays nothing. The trainer's LEFT
    gives the laser.

48. **The human base: six triangles as an animated shape like the gate's, a
    circle a triangle for the stars and for the wall, and a radar mark.** Decided
    2026-09-19 (the user), built as `src/base.s` and `EA_BASE`. It is 46's station
    figure and its "does not collide", made concrete; the parts of 46 it does not
    touch (the siege, shots) are still 46's, and `open_questions.md` E11 has what
    is open.

    **What it is.** **Six equilateral triangles, the gate's largest at 0.7** (140 px
    a side), laid out as a **hexagon** with their apexes toward the middle and
    **16 px between them**: 304 x 272 px, about the size of the screen at 1:1. It
    began as fifteen 64 px squares, then eight of 96, then six triangles of 200 px
    (428 x 380), and the GPU could not draw any of them beside the enemies (a dump
    of a scene with four UFOs: the 200 px hexagon was 66.8 k of a 236 k frame); at
    140 px it is **52.5 k** on the same scene, a fifth less - a dotted line costs
    about 39 cycles a pixel, but three vertices and a command are a fixed part of
    a triangle, so the saving is not the third the length would give. It
    never moves, is not in the object pool and is placed per level in `base.s`'s
    `BASE_*` rows (**level 0 has one now**, 640 px dead ahead of the start, at
    `$8000,$5800`; a row's `BASE_ON` 0 takes it away). The rows move into
    `levels.s` when the level editor learns to place one - that file is rewritten
    whole on Save, so they cannot live in it yet.

    **It is an enemy appearance, `EA_BASE`, and the gate draws it.** Authored in
    `tools/enemy_editor.py` like `EA_GATE`: six parts, six frames (frame *f* has
    triangle *f* smaller, 0.6), a playlist of the six frames in turn, **60 game
    frames a step** (`EN_BASE_AHOLD`) - each triangle is shown smaller for 60
    frames, one after another round the hexagon. Its vertices are data in the RAM
    under the cartridge window (SHAPES, 386 B left after them) like every other
    outline, and **nothing in `base.s` draws a line**: `gate.s`'s `gb_draw` (the
    body of `gate_body`, now parameterised by a five-byte record `GBAP`..`GBMK`:
    appearance, step, spin, scale halving, and a mask of the parts to draw) is the
    drawing, one `DOT_POLYGON` a part at the object's centre, turned by `-HEAD`.
    `gate_body` sets the record for the gate and falls in; `do_base` sets it for
    the base and jumps in. **The numbers are authored in half-res units**, one
    unit = 2 px, and `GBSH` = 0 tells `gb_draw` not to halve the scale as the
    gate's full-res numbers want: a vertex offset is a signed byte, and the hexagon
    reaches 154 px from its centre, which is 77 units, and 154 px would not fit.
    The editor therefore draws the base at half size. `GATE_GR` (the cull margin)
    is the gate's own again, 192 px: the base reaches 154.

    **A circle a triangle, on its vertices, for the wall - and for the stars, once
    a triangle is gone.** Each triangle is a **segment**; its circle has the
    triangle's centroid for a centre and passes through its three corners: **41
    half-res px = 41 collision units**, `EA_BASE`'s circumradius (40.3 for all six,
    out of its vertices, rounded up to hold them; the centres are `BS_OFF`, 48
    units out and 60 degrees apart). It is the wall (below) always, and the star-occlusion disc
    (`add_disc`, a rock's way, decision 12) when a triangle is missing: a circle
    through the corners covers the whole triangle, so no star shows through one,
    and it reaches 20 units past the middle of each edge, a halo of about 40 px
    that the hexagon's own edges never fill.
    **While all six stand the stars get ONE disc**, on the anchor, round the whole
    hexagon: 77 half-res px at 1:1, the farthest corner (`BS_HR`). The hexagon is
    nearly a circle, and six discs are not cheap - each is a bounding box that
    covers most of the screen and a star tests the boxes in turn: **six discs
    cost `do_base` 15.7 k and `do_stars` 15.9 k cycles a frame, one disc 8.8 k and
    10.6 k** (a whole frame is 237 k; with no base at all `do_base` is 3 k and
    `do_stars` 6.6 k). The one disc hides a few pixels of stars past the flats,
    12 units at the worst. **Measured** (`base_bench`): over eight headings with
    the ship in the middle 63 stars are drawn and none is inside a triangle, where
    the same scenes without the base draw 63 more there.

    **A segment is live or not** - a bit of `BSLIVE`, all set by `base_load` - and
    a segment that is not live has **no disc, no wall and no drawing** (`gb_draw`'s
    mask). Nothing clears a bit yet: the base will be shot at and attacked by
    aliens and lose its triangles **one by one**, and that is all it will take,
    with the hit points and the fall itself (E11).

    **The radar mark is six dots, the hexagon's own shape** - two above, one to
    each side, two below - in the player's screen axes and never turned, on the
    radar while the base is in reach and absent when it is not.
    `gate.s`'s `gate_radar` was split for it: `gr_pos` (its position half, from a
    world position's high bytes to the radar cell, or "out of reach" as carry set)
    is what `do_base` calls too, and the dots are the only part that is the base's
    own. It is drawn before the near test, so the mark does not depend on the
    base being near the screen.

    **Nothing can enter a live segment.** One routine, `bs_keep`, puts a mover
    back outside every live circle - each grown by the mover's own radius, so its
    edge and not its centre stops at the line - and three movers differ only in
    what they do with their velocity:
    * **A rock** is put back and its velocity into the circle **reversed**: a wall
      of infinite mass, no energy lost (`base_rock`, in `do_objects` after the rock
      has moved and before its cell is looked up, so the grid sees the corrected
      place). A spider riding a rock goes with it; a drifting spider's carrier is
      a rock.
    * **An enemy** is put back and its velocity **into the circle taken away**
      (`base_foe`, the end of `foe_integrate`, so every UFO and pulsar). It keeps
      steering, so it **slides along the circle**; going round is what `foe_avoid`
      does for rocks and is not done for this (E11).
    * **The ship** is stopped **before** it moves (`base_brake`, in `do_ship`
      between the knockback and the position integration). `bs_keep` runs on where
      the true 24-bit step would put it, and the velocity is corrected by however
      far it was put back, so the ship ends on the circle and **slides along it**.
      It is done by velocity, not by pushing the position back, so that the ship
      is never drawn inside the wall for a frame. **The stars do not follow the
      velocity, though** - `do_stars` scrolls them off the throttle (`SPD`, times the
      tier's `vel_shl`), and the wall does not touch that - so the first version
      left the ship held at the base with the starfield flowing past it at full
      speed (the user's dump `00002080`: `SPD` 23.8 k, the ship's velocity -2 units
      a frame). `base_brake` therefore takes what it took off the velocity **along
      the heading** off the stars' travel as well: forward is (sin, -cos), so the
      correction's projection is `cx * SINV - cy * COSV` (two `smul16q7`), and a
      world unit of travel is two of `TRAVL`/`TRAVH`'s 256ths of a pixel (parallax
      1/4, 32 units a pixel), so twice the projection is added to `TRAV`. Head on
      the stars stop; along a wall they slow by the way forward that is lost. What
      the stars cannot show is a sideways slide - they scroll along the heading
      only, for the knockback's sideways part as well. The ship's radius is 12
      units (its own 16 px and eight more, so it stops short of the line); it loses
      no hull. **Answers E11's brake question**: the ship slides.
    **How a circle pushes, without a square root.** Distances are in collision
    units (32 world units = a half-res px) so that two lookups in the quarter-square
    table `physics.s` uses and an add are d^2, compared with (41 + the mover's
    radius)^2. A mover that is inside is moved **along the axis it is farther from
    the centre on**, to the first whole unit at which it is outside (a short search
    up the table: at most rsum steps, a few for a rock). Magnitudes are floored, so
    the test errs toward "inside", and a mover is never left in a circle: it stands
    off it by up to a unit and a half (3 px), and the velocity that is reversed or
    dropped is that axis's, not the true normal's. The six circles overlap, so a
    push out of one can land in the next; they are walked up to six times.
    **Three consequences.** **The middle of the hexagon is a trap for a circle wall,
    and is closed.** The six circles overlap and leave one small pocket free there
    (8 units across the middle): a mover pushed out of one circle lands in the next,
    and one that ends in the pocket has no way out of it. The scatter drops rocks
    at random over the whole torus, level 0's at a fixed seed, and **a dump
    (`dumps/00002856`) found a class-3 rock at 16 units from the anchor** with a
    velocity of 8 units a frame that it could not use, jittering in the pocket
    for good. A mover that is **still being pushed after six passes is now put out
    of the base** (`bs_eject`): a circle on the anchor as far out as any of the six
    reaches (89 units), and it is pushed out of that the way it is pushed out of a
    segment's, reversing or dropping its velocity as usual. It jumps, once, and it
    never happens to a mover that was outside: a rock that is born inside the base
    leaves at its first frame awake. **A ship that is already inside** (a teleport
    landed there, or the sector began there) is let out and not held, as braked it
    would be trapped. **And a triangle's circle is not the triangle**: it stands 20
    units (40 px) off the middle of an edge, so a rock bounces off empty space there;
    the corners are covered.
    **Measured** (`base_bench`, direct calls on random movers, the circles
    worked out again in Python): 3000 ships and velocities round the circles - 141
    braked, none ended inside, none braked that would not have gone in; 2000 rocks
    of every class and 1500 enemies, each put outside every circle with only the
    velocity it should lose changed; head on at a circle's middle the ship stops
    exactly on it; on a real frame a rock aimed at a circle never gets in and
    comes back out, and a UFO whose post is inside a circle is not inside one at
    the end of the frame. `base_brake` costs 316 cycles, `base_rock` 31 a rock
    that is far and 4.6 k one that is on a circle.

    **Bullets end on the triangle** (the user, 2026-09-20: they were flying through
    it). The player's, in `shot_move` right after the bullet has moved
    (`base_shot_p`), and the UFOs' and spiders', in `fsh_all` before the ship is
    tested (`base_shot_f`): a bullet that is in a live triangle is spent, with the
    same puff on its tip a hit on a rock gives, and pays nothing. **It is the
    triangle, not its circle** - the circle stands 20 units off the middle of an
    edge, and a bullet that dies in empty air reads as a shield - and it is cheap:
    the three edges of an equilateral triangle are 20 units (`BS_TI`) from its
    centroid and 120 degrees apart, and all six triangles point their apexes at the
    anchor, so in world axes the normals are one of two sets (the odd triangles are
    the even ones turned half a turn), and a point q from the centroid is inside when
    `qy < TI` and `|7/8 qx| - qy/2 < TI` - whole units, floored, `7/8` for 0.866, a
    shift and a subtract each. Only the segments whose centroid is within six
    pages are looked at, and a bullet a base's window away is rejected on its high
    bytes. The bullet is a point with a two-unit lip (`SHOT_HITR`), and it flies at
    most 14 units a frame against a triangle 40 across, so it is tested where it
    is and not swept; through the **gap** between two triangles it flies on, as it
    should. **Measured** (`base_bench`): 1500 random points, stopped exactly when
    inside a triangle to within 2.5 units either way; the player's and an enemy's
    bullet in flight at 192 units a frame stop on the edge of triangle 0 on the
    fourth frame; a dead segment (`BSLIVE`) stops nothing. **Not done**: the base
    takes no damage from a shot (no hit points yet, E11), **the laser's beam and the
    pulsar's** still go through, and a rock **frozen** outside `do_objects` window is
    not tested - a rock the scatter dropped inside the base is put back on a circle
    the first frame it is awake, which can be a visible jump.

    **Where it lives.** `EA_BASE`'s vertices in SHAPES; all of `base.s`'s wall and
    tables in **`CODE7`**, a segment stored in ROM **bank 7** (4.9 KB of it free,
    and 195 bytes more since `MSGDATA` moved out to its own bank on 2026-09-20)
    and **run in upper RAM** after `HIDATA` (`cart.cfg`, and one more row in
    `bootstrap.s`'s `boot_segs`): 937 bytes, of the 1,796 upper RAM had. The place,
    the discs and the mark are `CODE6` (`DEMO_RAM`). **Free now (before the bullets and the star correction added 430 B to
    `CODE7`, 1,367 B in all): `DEMO_RAM` 30 B, the RUN area 597 B, bank 0
    34 B, SHAPES 386 B; upper RAM 429 B**. 55 bytes
    of state under the window behind `gate.s`'s, three `jsr`s in the flight code
    (`do_ship`, `do_objects`, `foe_integrate`), and a dozen small edits to
    `gate.s`. CODE7 was first the RUN area's, then upper RAM's: both `DEMO_RAM` and
    upper RAM are full-speed and unbanked, and upper RAM is where the room is.

49. **Enemy density: a screen holds only as many enemies as the GPU can draw beside
    everything else, and enemies arrive gradually.** Decided 2026-09-20 (the user).
    **The rule is decided; the mechanism that keeps it is not built** - it is
    `open_questions.md` F9.

    **Why, measured.** A madsim dump of a real scene (`dumps/00002856`, frame 2856,
    the camera at its widest, scale 0.5) had **the GPU at 99.6%** (236,436 of
    237,404 cycles; replayed command by command on the real `gpu_os.bin` in py65 it
    comes to the same 99.6%) and CPU1 at 80.2%. **Four UFOs on the screen at once
    cost 91,100 GPU cycles, 38% of the frame** (21-27 k each: five parts, 15
    vertices), against 66,800 for the human base (200 px triangles, now 52,500),
    22,300 for two rocks, 17,300 for the ship, 14,100 for a pulsar and 19,400 for
    ten `DOT_PIXELS` lists. A solid polygon costs the GPU about **1.4 k cycles a
    command and 1.2 k a segment whatever its length** - a five-pixel UFO detail of
    two vertices is 2.7 k, and a part that is absent from its frame (one vertex) is
    still 1.4 k - so what an enemy costs is how many commands and vertices it has,
    and a screen of enemies is dear. A dotted line is 39 cycles a pixel.

    **The rule.**
    1. **A level never has more enemies on the screen at once than an enemy budget
       allows.** The budget is in **GPU cycles, not a head count**: an appearance
       has a cost (measured: the UFO is about 22 k) and the enemies on the screen
       may not add up to more than a set share of the frame. Proposed: **a quarter
       of the GPU frame, about 60 k cycles - two or three UFOs of today's shape.**
       The number is a first setting, to be flown and re-tuned like every other.
    2. **Enemies arrive gradually.** A group is not on the screen all together: its
       members come one after another, and the rest wait - not yet present, or
       held off the screen - until room is made by a kill or a departure.
    3. **The level keeps the rule: a pool, a cap, and conditions** (the user,
       2026-09-20 - not a runtime that holds enemies back at the edge of the
       screen). A level has a **pool** of the enemies it will send in all, and **a cap
       on how many of them may be alive at once**. Enemies are **spawned one after
       another**: a pool entry whose condition holds is spawned when fewer than the cap
       are alive, and a kill makes room for the next. So **no new enemy appears on the
       map while the cap is full**, and a crowd cannot chase the ship into view,
       because there is no crowd.
       **A pool entry has a condition** - by default "as soon as there is room", but
       it may be something that has to happen first: a time, the ship reaching a place,
       or **the level being cleared**. *"You cleared the level? Fly to the gate - and
       there are the enemies"*: an entry that waits for the mission to be done and then
       appears at the gate, counting against the cap like any other. The budget of rule 1
       is a property of how the level is authored (the cap times the dearest appearance
       in the pool may not pass it; the level editor can flag one that does), and the
       game only counts the living and releases the next.
    4. **It counts everything that is drawn beside the player**: the UFOs that
       besiege the station in 4-3 (46) count against it like any others, and so do
       the base and its segments' losses, which are drawn either way.
    5. **Every appearance has its cost written down**, measured on the GPU, next to
       its shape (the enemy editor), so that a new enemy is priced when it is drawn.
       An enemy that is dear for what it shows - parts that are a few pixels, parts
       that are absent in most frames - is redrawn, not budgeted around.
