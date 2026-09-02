# Escape from Saturn — game physics

> **Status: COLLISION AND RESPONSE ARE BUILT.** Sections 3, 4 and 7 describe
> code that exists — [`proto/02_rocks/physics.s`](../proto/02_rocks/physics.s) —
> and every number in them is what that file actually uses. Sections 5 and 6
> (break-up, shot split) are still spec, and the tuning values are still
> placeholders: built is not the same as tuned. This file remains the single
> place parameters live, so tuning is a rebuild rather than a rewrite.
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

**Detected and nothing more.** It flies straight through. The delta it needs is
already computed by the object loop for the view transform, so the test costs two
shifts and the circle; the answer is a flag, a per-frame count and a frame
counter, and nothing reads them yet.

Two reasons it stops there. What a hit does to the ship is not decided — it may
simply be death. And the ship's velocity is **recomputed from the throttle every
frame**, so an impulse written into it would be gone by the next one; giving the
ship a real reaction means either a separate decaying knockback vector or
reopening the flight model, and neither belongs in a collision bench.

### Parameters

As built. Every one of them is a first cut.

| name | meaning | value |
|---|---|---|
| `PHYS_RADIUS[class]` | collision radius, collision units | **39, 26, 13, 7, 3** — `SHAPE_OCC` |
| `PHYS_MASS_E[class]` | mass exponent, `m = 2^e` | **4, 3, 2, 1, 0** |
| `PHYS_RESTITUTION` | normal-component retention | **0.75**, as `1 + 1/2 + 1/4` **(TBM)** |
| `PHYS_SEP_SH` | separation push is `n >> this` | **2** = 32 world units a frame **(TBM)** |
| `PHYS_SEP_DP` | ...shifted this much less when deeply sunk | **2 (TBM)** |
| `COL_MAX` | collisions resolved per frame | **8 (TBM)** |
| `SHIP_RAD` | the ship's collision radius | **8 (TBM)** — nothing rides on it yet |
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

`proto/02_rocks/preview.py` runs the real cartridge against the real CPU1 ROM in
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
