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

A level is defined by a **mission plan**: what has to be true before the exit opens
(clear N rocks, survive T seconds, destroy a specific target, escort, reach a
location, ...). The level plan also sets the initial population, the size-class
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
