# Escape from Saturn — game physics

> **Status: COLLISION AND RESPONSE ARE BUILT.** Sections 3, 4 and 7 describe
> code that exists — [`src/physics.s`](../src/physics.s) —
> and every number in them is what that file actually uses. Sections 5 and 6
> (break-up, shot split) are still spec, and the tuning values are still
> placeholders: built is not the same as tuned. This file remains the single
> place parameters live, so tuning is a rebuild rather than a rewrite.
>
> **The UFO is built, and it is NOT a physics body** — section 9. It is
> kinematic: it steers, and it keeps out of everything instead of bouncing off
> it. The rocks never see it.
>
> **What is not built yet, and why:** spin transfer (4.3) needs a per-object
> spin, and spin is a property of the size class today — two RAM pages and two
> lines in the integrator, and it is its own bench. Break-up (5) needs the
> shot-split routine (6) to make the fragments with, and that does not exist.
> The ship is **detected** and nothing more (see 4.6).

Physics is the centre of this game's feel and will be revisited many times. The
guiding rule: **it must be simplified enough to run 60 times a second on a 65C02,
and consistent enough that the player can predict it.** Physical realism is not a
goal; predictability is.

---

## 1. Numeric conventions

| quantity | format | notes |
|---|---|---|
| position | 16.0 unsigned world units, per axis | wraps by 16-bit overflow |
| velocity | 8.8 signed world units / frame | integrated into position each frame |
| angle | 8-bit brad (0-255 = full turn) | matches the OS `sin`/`cos` tables |
| spin | 8-bit signed brad / frame | added to `angle` each frame, wraps for free |
| mass | a power-of-two EXPONENT per body class | never divided, never even multiplied — see section 4 |

All multiplies go through the **quarter-square table** (`a*b = f(a+b) - f(a-b)`,
`f(x) = x*x/4`), not `mul16`. Divides are avoided entirely: anything that would
divide uses a small reciprocal table instead.

There is one more unit, and it belongs to collision only. The **collision unit**
is **32 world units** — one half-res pixel, which is the unit `SHAPE_OCC` is
already authored in. In it every radius, every sum of two radii and every delta
that could possibly be a contact is a **signed byte**, and that single fact is
what lets the whole narrow phase be table lookups.

---

## 2. Integration (every frame, every live object)

```
pos_x += vel_x            ; 16-bit add, wrap is the overflow
pos_y += vel_y
angle += spin             ; 8-bit add, wraps for free
```

That is the whole cost for an object nothing has hit — roughly 30 cycles. This is
what makes tracking the entire world affordable (see `design_technical.md` 6.1).

---

## 3. Collision detection

**Broad phase** — the sector grid of `design_technical.md` 6.3, walked the way a
grid is meant to be walked. For each body the pass visits **the rest of its own
cell's list** and **four of the eight neighbours** (E, S, SE, SW). Four and not
eight, successors and not the whole list: that is what makes every pair come up
**exactly once** with no "already tested" flag anywhere. If j is east of i then i
is west of j, and west is in nobody's list.

It is complete only because the largest possible sum of two radii (78 collision
units) is smaller than a sector (128), which the assembler asserts. See
`design_technical.md` 6.3 for why that is the rule the sector size is chosen by.

It runs for exactly the bodies that pass the **coarse window** — the near-camera
set of `design_technical.md` 11.6. Everything outside is frozen, so it does not
collide either. A body at the edge of the window can still reach a frozen one and
kick it; momentum still balances, and the frozen body simply carries its new
velocity until the player flies close enough for it to start integrating again.

**Narrow phase** — circle vs circle, and **with no multiply in it at all**. The
quarter-square table is `f(x) = floor(x*x/4)`, so `f(2a) = a*a` exactly for any
`a <= 127`, and the whole test is

```
|d|^2 = QS[2*|dx|] + QS[2*|dy|]        vs        QS[2*rsum]
```

three 16-bit reads of a table that is in RAM for the rotation anyway, one add and
one compare — about 40 cycles. This matters more than the response does: the
narrow phase is what every candidate pair pays every frame forever, while the
response is paid only by the pairs that are touching.

Ahead of it sits a **coarse reject on the position high bytes alone** — no 16-bit
delta, no radius lookup, no call. Most of what the cell walk hands over dies
there, at about forty cycles instead of a hundred and thirty.

The radius is `SHAPE_OCC`, the mean-vertex radius, and not a second opinion about
how big a rock is: `design_technical.md` 5.4 settles that the collision circle and
the star-occlusion disc must be the **same circle**, so what looks solid and what
hits you are one shape.

Deliberately **not** polygon-accurate: the drawn outline is irregular, the collider
is a circle, and the difference is not readable at these sizes.

---

## 4. Collision response

Billiard balls, with three cheats that all err on the safe side.

### 4.1 The normal is `d / rsum`, not `d / |d|`

A true unit normal wants a square root and a divide. But a collision is
**detected at the moment of contact**, and at contact `|d|` is within a percent
or two of `rsum`: a rock moves at most ~13 world units a frame, which is 0.4
collision units against radii of 3 to 39. `rsum` is a constant of the pair, so
dividing by it is one shift and one lookup in a 64-byte reciprocal table.

The error is not merely small, it is **safe**. Deeper overlap makes `|n|`
shorter, which makes the impulse **weaker**. The cheat cannot ring and it cannot
explode. What resolves a deep overlap is the separation in 4.4, not the impulse.

### 4.2 Every mass is a power of two

`m = 2^e`, so the mass factor

```
F_i = m_j / (m_i + m_j) = 1 / (2^k + 1),        k = e_i - e_j
```

depends on **nothing but the difference of the exponents**. Nine values, one
table, read forwards for `F_i` and backwards for `F_j`, because `F_j(k) = F_i(-k)`.
Every mirrored pair sums to exactly 128 — 120+8, 114+14, 102+26, 85+43, 64+64 — so
the impulse is equal and opposite **by construction**.

This is the one thing the response asks of anything new that wants to collide:
give it a power-of-two mass and a radius, and every line of it works unchanged.
That is what makes enemies, debris and the ship the same code as rocks.

### 4.3 The impulse itself

```
vn = (v_j - v_i) . n                        two 16-bit multiplies
if vn >= 0: no impulse, separate only       already parting
p  = (1 + e) * vn                           SHIFTS, not a multiply
P  = p * n                                  two multiplies
A  = F_i * P                                two multiplies
v_i += A ;  v_j += A - P                    because F_j = 1 - F_i
```

Six 16-bit multiplies, not eight: `-F_j * P = (F_i - 1) * P = A - P`, which turns
the partner's half into a subtract.

`(1 + e)` is spent as **shifts** — 1.75 is `vn + vn>>1 + vn>>2` — so restitution
costs nothing and is retuned by adding or deleting a term. That is the whole
reason it is done this way.

**The `vn >= 0` gate is not an optimisation.** Without it a pair that has just
bounced is hit again on the next frame while it is still overlapping, and the two
weld together. It is the single line standing between this model and sticky rocks.

Spin transfer (the tangential half, a glancing hit setting a rock tumbling) is
specified and **not built** — see the status banner.

### 4.4 Separation, and why it is positional

Every overlapping frame, impulse or no impulse, the pair is pushed apart along
`n`. Displacement goes as `1/m` and every mass is a power of two, so the
weighting is a **shift**: the lightest body of the pair moves the full step and
every heavier one halves it per exponent. A chip shoves a 192 sixteen times less
than the 192 shoves it. **No multiply anywhere in it.**

It is a small constant rather than the true overlap on purpose. It cannot
overshoot; it cannot jitter, because there is no gravity holding anything in
contact and a separated pair simply stops being found; and it is the only thing
that can resolve a pair **spawned inside another**, where there is no approach for
an impulse to answer. A field scattered on top of itself untangles in a second or
so, off camera, before the player sees it. Deeply-sunk pairs get four times the
push, which is one compare.

### 4.5 The budget

At most `COL_MAX` collisions are **resolved** per frame. Past that a pair is still
detected and still counted, it just waits: the overlap does not go away, so
nothing is lost by deferring, and one pathological frame cannot eat the budget.
The same bargain as `PEND_MAX` in the grid.

### 4.6 The ship

**Built.** The delta it needs is already computed by the object loop for the view
transform, so detection costs two shifts and the circle. `ship_respond` then
mirrors `col_respond`'s own maths with the ship standing in for one side of it,
and the answer is split three ways.

The ship's velocity is **recomputed from the throttle every frame**, so an
impulse written into `VELX`/`VELY` is gone by the next one. So:

- **`KNBX`/`KNBY`** — a decaying knockback added on top of the throttle-built
  velocity each frame (`ship.s knb_tick`). It carries the part of the impulse
  that lies **across** the heading: the sideways deflection, which the throttle
  has no way to express.
- **`THRTL`** — the part **along** the heading, `A·H`, is taken off the throttle
  itself, scaled by `THRTL_HIT`. That is the only place a speed change can
  survive, and it is what makes a hit *cost* something the player has to fly back
  up. The step is clamped to the side of `THRTL_REST` the ship was already on: a
  hit can stop the ship dead, it cannot punch it into reverse. Same argument as
  open question B8 makes about the gun's recoil.
- **`SHIPHP`** — `RAM_DMG`, one ordinary hit (`HIT_HP` = 10) of its `HP_MAX` =
  50, and at zero the ship breaks apart. A hit bigger than what is left is the
  last one (design_technical 11.25).

Splitting the impulse rather than applying all of it twice is the point: without
the subtraction the along-heading half would be charged once as a jolt and again
as a throttle.

Because the ship is the one body in the world that moves fast, two clamps that
`col_respond` never needs live on this path. Its velocity is 16.8 and a boost can
put it past a signed 16-bit, so the relative velocity is built in **24 bits** and
saturated to `VEL_SAT`; and `(1+e)·vn` must itself stay inside 16 bits, so the
closing speed is pegged at `COL_VNMAX`. Without the second one, 1.75 × the top
tier's 92.8 units a frame wrapped to a **positive** number and the response drove
the ship deeper into the rock.

### Parameters

As built. Every one of them is a first cut.

The **ship** does not separate the way a rock does. A rock pair gets the small
mass-weighted nudge above; the ship is snapped outright to the point
`rsum + SHIP_SEP_MG` from the rock's centre, along the line of centres, on every
overlapping frame. It has to be: the ship can cross several collision units in a
single frame, so it is already well inside the circle the first time the pair is
detected, and a nudge that is correct for a body moving 0.4 units a frame cannot
undo that — and a player holding the stick into a rock re-creates the overlap
every frame anyway, because `do_ship` rebuilds `VELX/VELY` from scratch (4.6).
That snap needs a **unit** normal, `d/|d|`; the `d/rsum` a rock pair uses makes
it an identity, and a shallow-angle graze — where the impulse along the normal
is small because the approach is nearly tangential — then has nothing left to
stop the ship passing through. `|d|` is estimated as `max(M, 0.875M + 0.5m)`,
which is why the margin exists.

| name | meaning | value |
|---|---|---|
| `PHYS_RADIUS[class]` | collision radius, collision units | **39, 26, 13, 7, 3** — `SHAPE_OCC` |
| `PHYS_MASS_E[class]` | mass exponent, `m = 2^e` | **4, 3, 2, 1, 0** |
| `PHYS_RESTITUTION` | normal-component retention | **0.75**, as `1 + 1/2 + 1/4` **(TBM)** |
| `PHYS_SEP_SH` | separation push is `n >> this` | **2** = 32 world units a frame **(TBM)** |
| `PHYS_SEP_DP` | ...shifted this much less when deeply sunk | **2 (TBM)** |
| `COL_MAX` | collisions resolved per frame | **8 (TBM)** |
| `SHIP_RAD` | the ship's collision radius | **8 (TBM)** |
| `SHIP_ME` | the ship's mass exponent | **1** — "the ship behaves like a 32" |
| `SHIP_SEP_MG` | how far PAST `rsum` the ship is snapped | **3** collision units **(TBM)** |
| `THRTL_HIT` | share of the along-heading loss taken off `THRTL`, Q0.7 | **128** = all of it **(TBM)** — the knob to fly this on |
| `VEL_SAT` | ship velocity saturates here before a hit reads it | **23170** (8.8) = 90.5 units/frame; only a boost reaches it |
| `COL_VNMAX` | largest closing speed the impulse can answer | **18724** (8.8) = 73 units/frame = 275 px/s |
| `PHYS_SPIN_GAIN` | fraction of tangential difference to spin | **not built** |
| `PHYS_SPIN_MAX[class]` | spin cap per size class | **not built** |

---

## 5. Break-up on impact

If the **relative normal speed** at contact exceeds `PHYS_BREAK_SPEED[class]`, the
body fragments instead of (or as well as) bouncing. The fragments are produced by
the same routine as a shot split (section 6), with the impact normal standing in
for the shot direction.

Smallest size class never fragments — it is destroyed or it survives.

| name | meaning | placeholder |
|---|---|---|
| `PHYS_BREAK_SPEED[class]` | relative normal speed that fragments this class | **(TBM)** |
| `PHYS_BREAK_BOTH` | does a hard impact break one body or both | **(TBD)** |

---

## 6. Shot split

A hit asteroid becomes **two** of the next size class down:

```
child.vel = parent.vel  +/-  (separation impulse, perpendicular to the shot)
child.pos = parent.pos  +/-  (separation offset, same axis)
child.spin = parent.spin  +/-  (spin kick)
```

The two children take opposite signs, so **linear momentum is conserved by
construction** and the field does not acquire a net drift over a long game. Some
of the shot's momentum is added to both children along the shot direction so the
pair visibly recoils away from the player.

| name | meaning | placeholder |
|---|---|---|
| `SPLIT_IMPULSE[class]` | separation speed given to each child | **(TBM)** |
| `SPLIT_OFFSET[class]` | initial separation, must exceed the child radii | **(TBD)** |
| `SPLIT_SPIN_KICK` | spin added/subtracted per child | **(TBM)** |
| `SHOT_PUSH` | momentum transferred from the shot | **(TBM)** |

---

## 7. Global limits

Caps exist so a long game cannot drift into chaos:

- `PHYS_VEL_MAX[class]` — speed cap per size class, clamped after every response.
- `PHYS_SPIN_MAX[class]` — as above for spin.
- Restitution below 1 (section 4) means unforced collisions bleed energy; the
  caps are the backstop for the forced cases (shots, break-ups).

**Neither cap is built, and as long as collisions are the only thing moving the
field, neither is needed**: momentum is conserved by construction and `e < 1`
takes energy out, so speeds cannot grow. They become necessary the moment
something *adds* momentum — a shot, a break-up, a thrusting enemy — and that is
the change that should add them.

---

## 8. Tuning workflow

1. Build with a debug overlay showing live velocity/spin histograms and the
   collision count per frame.
2. Run a **headless soak**: populate the world, run several thousand frames with
   no player, and check the field is still moving plausibly — no clumping into a
   corner, no everything-stopped, no runaway speeds.
3. Only then tune for feel with a player in the loop.

Step 2 catches the failure modes that are invisible in a 30-second play session
and obvious after ten minutes.

### What is measured so far

`tools/preview.py` (`make preview`) runs the real cartridge against the real
CPU1 ROM in
py65 and reports these every build. From a 200-frame flight over the level-0
field (120 rocks):

| | |
|---|---|
| cost, median frame | **+7,100 cycles** over no collision pass at all |
| cost, worst frame | **+16,600 cycles** — 63.7% of budget becomes 70.7% |
| collisions | 45 in 200 frames, worst frame 2 against a budget of 8 |
| field momentum | drifts **83 units over 45 collisions**, 0.13% |

The momentum figure is the one worth keeping an eye on. The mass factors sum to
exactly 128, so the impulse is exactly equal and opposite and the only thing that
can move the total is rounding — but `smul16q7` truncates toward zero, so the
rounding is **biased**, not neutral: about 1.8 units of momentum lost per
collision, always in the same direction. It is invisible over a 200-frame flight
and it would not be over a very long one. The soak in step 2 is what should catch
it, and the fix, if it needs one, is a round-half in the multiply rather than
anything in this file.

The cost figure has one obvious lever left if it is ever needed: gate collisions
on a window narrower than the cull's, one compare per body. At full zoom-out the
coarse window already admits about 28% of the world's rocks, so halving it is
worth roughly four times fewer pairs.

---

## 9. The UFO — a steered body, not a colliding one

[`src/foes.s`](../src/foes.s). The rocks bounce; the UFO **avoids**. It has no
mass and no impulse, the rocks do not know it exists, and it is the UFO's job
never to be where a rock is — on patrol as much as in a chase, because a UFO
caught sitting inside a rock reads as a bug.

**Behaviour.** A level record (`levels.s`, seven bytes) gives it a patrol course
and speed, or speed 0 to hold a post. It sees the ship within `FOE_SEE`, turns
toward it at `FOE_SPD` and holds `FOE_STAND` off; the first UFO to see it sounds
the alarm (three beeps, ENEMY DETECTED). It holds its fire until it has closed to
`FOE_SHOOT`, waits `FOE_FIRST` more, then fires once a second at where the ship
is (no lead) while it stays that close. Past `FOE_LOSE` it gives up and is put
straight back on its patrol course and speed. Velocity changes by at most
`FOE_ACC` per axis per frame, so it turns in arcs.

**Avoidance.** Every obstacle — rock, other UFO, the ship — has a ZONE: its own
collision radius, the UFO's, and `FOE_MARGIN`. Of the zones the UFO is inside,
the deepest decides, and three things happen, in this order:

1. **Touching?** It is put on the circle just outside, obstacle + n·(rsum + 1).
   The hard guarantee — the same snap `ship_separate` gives the ship (4.6).
2. **Moving in?** The velocity component into the obstacle is replaced by an
   outward push of 3 world units a frame per collision unit of depth, capped at
   `FOE_SPD`. Only that component changes; nothing is rescaled, so sliding along
   a rock cannot pump the speed up.
3. **Going round.** A UFO with somewhere to be slides round at `FOE_VTMIN` at
   least, the way it was already going — so one flying dead at a rock goes round
   it and resumes its course instead of stopping at the edge. One holding a post
   slides only off the path of something actually coming at it, against that
   obstacle's own drift; a rock it merely sits beside it leaves alone, or the
   spring back to its post would make it orbit.

The normal is `d/|d|`, `|d|` from `max(M, 0.875M + 0.5m)` carried at 2×
(ship_respond's estimate at 4×, which a 74-unit zone would overflow).

**Ramming.** A ship that flies into a UFO pays `RAM_DMG` exactly as for a rock,
and the UFO is shoved out of the way; `FOE_RAMCD` frames pass before that UFO can
charge it again. The UFO itself takes no damage — the rocks' rule (4.6, the
rock's own hit point is off by request).

**Thinking less than every frame.** Seeing and avoiding is the expensive half, so
a UFO near the camera thinks every 2^`FOE_SNEAR` frames and one far outside the
coarse window every 2^`FOE_SFAR`, both staggered by slot, with the acceleration
scaled by the frames skipped. Two frames need no wider zone: `FOE_MARGIN` is
already more than a split chip and a UFO can close in two. Eight frames get
`FOE_LOOK` added — sound only because every rock that far out is frozen (6.1).
Integration is every frame for every UFO.

| name | meaning | value |
|---|---|---|
| `FOE_R` | the UFO's collision radius, collision units | **9** (18 full-res px) **(TBM)**; the shape is 1.25x the first one — at 1x (radius 7) it was too small next to the ship to hit, at 1.5x (11) too big |
| `FOE_HP` | hit points | **30** = 3 × `HIT_HP`: three bullets, or 15 frames of laser |
| `FSH_DMG` | what its bullet takes off the ship or a rock | **10** = `HIT_HP`, one ordinary hit |
| `FOE_SEE` | sight | **6400** world units — the resting screen's height |
| `FOE_LOSE` | it gives up the chase past this | **12800** — twice the sight |
| `FOE_SHOOT` | it only fires within this | **3520** — 220 px **(TBM)**; it was `FOE_SEE`, and read as being shot the instant it saw you |
| `FOE_STAND` | the chase holds this far off | **2560** — 160 px **(TBM)** |
| `FOE_SPD` | the chase speed, 8.8 units a frame | **$2E6C** = 175 px/s, half the ship's top tier |
| `FOE_BACK` | the most it backs off at, inside the stand-off | **FOE_SPD/2** |
| `FOE_ACC` | velocity change per axis per frame, 8.8 | **$00C0** — rest to `FOE_SPD` in ~1 s **(TBM)** |
| `FOE_MARGIN` | clear space round every obstacle, collision units | **16** — 32 px **(TBM)**; `FOE_R` + this ≤ 25 keeps a near UFO's cell walk 2x2 (`FOE_HIWN` ≤ 8, asserted) |
| `FOE_VTMIN` | the least it slides round an obstacle at, 8.8 | **$1000** = 60 px/s **(TBM)** |
| `FOE_FIRE` / `FOE_FIRST` | frames between shots / before the first, counted from reaching `FOE_SHOOT` | **60 / 60** + a stagger by slot |
| `FOE_RAMCD` | frames before the same UFO can hurt a ramming ship again | **30** |
| `FSH_MIN` | frames a bullet fired from off screen lives before the screen may take it | **60** |
| `FOE_SNEAR` / `FOE_SFAR` | think every 2^this frames, near / far | **1 / 3** |
| `FOE_FARPG` | pages past the coarse window before a UFO is far | **16** |
| `SCORE_FOE_HIT` / `SCORE_FOE_KILL` | the player's pay for a hit / the last one | **50 / 100** |

## 10. The laser — a screen segment, not a body

`src/laser.s`; the decision is `design_technical.md` 11.24. The laser moves no
mass and is moved by none: it is a test, made once a frame, of which circles
reach one segment on the screen.

**The segment** runs from the ship's nose to the top of the screen. The ship
always points up and TATE puts up on the framebuffer's −X, so it is horizontal
in the framebuffer: `x ∈ [0, nose]` on the ship's row. The nose is `LSR_NOSE`
ahead of the ship's centre, scaled by `ZEASH` as the hull is; the centre and the
row are where `emit_ship` puts them, screen shake included — and the targets'
points (the visible list, `FOEFX/FY`) carry the same shake, so it cancels.

**A target is crossed** when its circle — its collision radius at this zoom, as
the gun uses it (`BODY_R` or `FOE_R`, `qmul` by `ZOOMH`, doubled into full-res),
plus `LSR_HW` — reaches the segment: level with it and `|v| ≤ R` across, or past
an end by `over` and `over² + v² ≤ R²` (the quarter-square table). Everything it
crosses loses **`LSR_DMG` = 4 hit points a frame** — two fifths of a bullet;
`rock_take_hit` for a rock, `foe_take_hit` for a UFO — and nothing stops the
beam.

**The sweep.** The world turns about the ship by whole brads, so a target `u` px
up the screen from the ship moves `u·d·2π/256` px across the beam on a frame the
heading changed by `d`. At the top of a zoomed-out screen `d = 1` is ~8 px and
the smallest rock's whole circle is 12, so a beam tested once a frame could be
stepped over. The test is therefore widened on the side the beam came from — +Y
after a right turn (HEAD rising), −Y after a left — to `R + u·|d|·LSR_SWK/512`,
which is the wedge between last frame's beam and this one, near enough. The ends
are not widened; the far one is off the screen and the near one barely moves.
`tools/preview.py` checks the guarantee directly: a rock level with the beam on
both sides of a crossing has been hit on one of the two frames.

| name | meaning | value |
|---|---|---|
| `LSR_FRAMES` | frames one press keeps the beam lit; no re-fire while lit | **20** — CETAS's `HERO_LASER_DUR` **(TBM, open_questions B9)** |
| `LSR_HW` | the beam's half-width for the hit test, full-res px, added to every target's radius | **2** — CETAS's `HERO_LASER_HH`, the gun's `SHOT_HITR` |
| `LSR_NOSE` | full-res px from the ship's centre to the nose at 1:1 | **22** — `SHIP_SHAPE` vertex 13, the gun's muzzle |
| `LSR_SWK` | the sweep, 128·4·2π/256 per brad | **13** — 12.57 rounded up, 3% generous |
| `LSR_DMAX` | brads a frame the sweep believes at most | **7** — bounds `qmul`; real turns are under 2 |
| `LSR_DMG` | hit points a frame to everything crossed | **4** — two fifths of a bullet's `SHOT_DMG` (10); 80 a press. Paid pro rata: `LSR_SCORE` 4, `LSR_FOE_SCORE` 20 a frame **(TBM, B9)** |
