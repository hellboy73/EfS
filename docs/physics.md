# Escape from Saturn — game physics

> **Status: SPEC SKELETON.** The model below is the agreed shape of the physics;
> every number is a placeholder until it is measured in madsim. This file is the
> single place parameters live, so tuning is a rebuild rather than a rewrite.

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
| mass | 8-bit, from size class | never divided at runtime — see section 4 |

All multiplies go through the **quarter-square table** (`a*b = f(a+b) - f(a-b)`,
`f(x) = x*x/4`), not `mul16`. Divides are avoided entirely: anything that would
divide uses a small reciprocal table instead.

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

**Broad phase** — sector grid, see `design_technical.md` 6.3. Only same-sector and
neighbouring-sector pairs reach the narrow phase.

**Narrow phase** — circle vs circle. Each size class has a fixed collision radius;
overlap is `dx*dx + dy*dy < (r1+r2)^2` with the deltas taken as wrap-correct signed
16-bit. Squares come from the same quarter-square table.

Deliberately **not** polygon-accurate: the drawn outline is irregular, the collider
is a circle, and the difference is not readable at these sizes.

---

## 4. Collision response

On overlap, with `n` = unit normal along the centre-to-centre line and `t` the
perpendicular:

1. Decompose both velocities into normal and tangential components.
2. **Exchange the normal components** weighted by mass, scaled by restitution
   `e` (< 1, so the system loses energy).
3. **Leave the tangential components** mostly alone, but bleed a fraction of the
   tangential difference into **spin** for both bodies — this is what makes a
   glancing hit set a rock tumbling while a head-on hit does not.
4. **Separate** the bodies along `n` by the overlap amount so they do not stick.

Mass ratios come from a **precomputed table indexed by the pair of size classes**,
so step 2 is two table lookups and two multiplies, never a divide.

### Parameters

| name | meaning | placeholder |
|---|---|---|
| `PHYS_RESTITUTION` | normal-component retention, per collision | 0.75 **(TBM)** |
| `PHYS_SPIN_GAIN` | fraction of tangential difference to spin | **(TBM)** |
| `PHYS_SPIN_MAX[class]` | spin cap per size class | **(TBM)** |
| `PHYS_SEP_BIAS` | extra separation to avoid re-collision next frame | **(TBM)** |
| `PHYS_MASS[class]` | mass per size class | **(TBD)** |
| `PHYS_RADIUS[class]` | collision radius per size class | **(TBD)** |

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
