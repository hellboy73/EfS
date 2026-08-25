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

### 4.2 The ship points up; the world turns

The ship sprite is drawn essentially fixed, nose toward the top of the screen, with
a **small visual bank/tilt while turning** (a few degrees, art only, no effect on
physics). Everything else in the scene is rendered rotated by `-heading`.

Consequence: the rotation is a *camera* transform applied once per rendered object,
and the ship itself needs no transform at all.

### 4.3 Zoom is a function of speed

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
Exact zoom range **(TBM)**.

### 4.4 The transform, and why it is affordable

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
would cap the scene well under 100 vertices/frame. **The engine will therefore use
a quarter-square multiply table** — `f(x) = x*x/4`, `a*b = f(a+b) - f(a-b)` — which
turns a signed 8x8 -> 16 multiply into two table lookups and a subtract, on the
order of 50-70 cycles. Cost per vertex drops to roughly 250-300 cycles, so a scene
of ~160 transformed vertices (say 20 asteroids of 8 points) lands around 45k
cycles — roughly a fifth of the frame budget, leaving room for physics, input,
audio and list building. Table cost is 2 x 512 bytes of RAM, built once at boot.
**(TBM)**

### 4.5 Pre-rotated shapes — considered, rejected for now

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

`gpu_dotline_clip` (`$FF93`, signed-16, Cohen-Sutherland clipped) is the vector
workhorse — it clips off-screen geometry itself, which matters because at high
zoom-out a lot of the scene straddles the edge. `gpu_dotpixels_clip` (`$FF99`)
draws a whole cloud of clipped points in one call, which is exactly the starfield.
`gpu_line` (`$FF15`) is half-res and unclipped.

**Possible firmware addition:** a clipped *polyline* opcode (N points, one PPRAM
record) would cut the per-asteroid PPRAM cost by close to half versus emitting each
edge as a separate clipped dot-line. That is a MAD-65 firmware change, not a cart
change, and it is on the table. **(TBD)**

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

The mask is almost certainly the right structure, but the naive version is worth
measuring first so the mask has a number to beat. **(TBM)**

Two details that follow:

- The mask must be a **disc**, not a bounding box — a square hole punched in the
  starfield around a round rock reads as a rectangle and is worse than the
  see-through problem it fixes. Rasterise per cell-row with an x-span.

  A disc is still only an approximation: the drawn outline is deliberately
  irregular, so a star sitting in a concave notch survives when it should not,
  and one just outside a lobe dies when it should not. Both errors are a few
  pixels at the rim of a moving object and neither reads on screen. What matters
  more is that the occlusion disc uses the **same radius as the collision
  circle** (7.3), so what looks solid and what actually hits you are the same
  shape — a rock that visibly swallows a star but lets a bullet through would be
  a real complaint.
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

### 6.1 Every object is tracked exactly

The world is only 4096 x 4096 reference pixels and per-object integration is a
handful of 16-bit adds (~30 cycles), so a full population of 64-96 objects costs
about 3k cycles per frame — around 1% of the budget. **All asteroids and enemies
are therefore simulated persistently across the whole world**, not spawned on
approach. This keeps the physics honest: rocks that collided out of sight really
did collide, and the player can return to a place and find it changed.

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
into a **16 x 16 grid of sectors** (256 x 256 reference pixels each), objects are
bucketed by the high bits of their position, and only same-sector and
adjacent-sector pairs are tested. The sector index wraps by masking, which is again
free on a torus. Grid resolution **(TBD)** — a sector should be somewhat larger
than the biggest asteroid.

The same grid provides render culling: only sectors overlapping the visible window
are visited.

---

## 7. Physics

**This is the heart of the game and will get a lot of iteration.** It has its own
document, [`physics.md`](physics.md), so parameters can be tuned without touching
the architecture. The design commitments:

- **Simplified elastic collision.** On contact the relative velocity is split into
  normal and tangential components. The normal component is exchanged according to
  mass (mass tracks size class), with a restitution coefficient below 1 so energy
  bleeds out of the system and the field does not become a perpetual-motion pinball
  table.
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
6. All gameplay objects are **persistently tracked**; only cosmetics are generated.
7. Broad phase is a **sector grid** indexed by masked high bits of position.
8. Stars are a **sampled parallax layer**, not simulated objects.
9. Sprites are a **level-of-detail optimisation** for small on-screen objects, not
   the primary art form.
10. TATE, clockwise, per the MAD-65 house convention.
