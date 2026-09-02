# proto 02 — rocks & collisions bench

Forked from [`proto/01_flight`](../01_flight/), which answered what flying has to
feel like and, along the way, already draws a full field of asteroids — real
world positions, velocities, spins, LOD, budget-capped emission. What it does
not do is **collide**: "Nothing collides with anything: you fly straight
through them." That is this bench's one question.

```bash
make run
```

Or `run.bat`. `F12` toggles `--tate`, `F3` shows the CPU/GPU utilisation meter.

```bash
python preview.py
```

runs the whole thing headless and writes `preview.png`, same as proto 01.

---

## Starting point

Everything in [proto 01's README](../01_flight/README.md) still applies here
unchanged — the starfield, the zoom, the speed tiers, the turn model, the rock
tables in [`shapes.s`](shapes.s) and the `main.s` tables listed there. This
file only documents what changes on top of that baseline.

## What this bench has to answer

- **Broad phase.** Section 11.7 of `design_technical.md` already fixes it as a
  **sector grid** indexed by masked high bits of position — this bench builds
  and measures that, on the wrapping world, not just asserts it.
- **Narrow phase.** Finding 22 in proto 01 already picked the number: a rock's
  collision radius should be its **mean-vertex radius** (`SHAPE_OCC`), the same
  circle that suppresses stars underneath it — so what looks solid and what
  hits you are the same shape. Circle-circle against the ship, circle-circle
  or radius-sum against another rock.
- **Response.** What happens on a hit — ship damage/destruction, rock
  splitting into smaller sizes (`design_technical.md` mentions this is
  expected for the asteroids-descendant feel), bounce/momentum transfer. TBD
  as this bench is built.
- **Cost.** Broad + narrow phase is new work every frame, on top of the
  ~66,500-118,000 cycles/frame the flight bench already measured. Whatever
  budget is left has to absorb it — measure, don't guess (per `CLAUDE.md`).

## What is not in scope

Enemies (ships, projectiles, AI) are the next bench after this one. This one
is asteroid-field collision only: ship-vs-rock and rock-vs-rock, on the same
torus, at the same scale, as proto 01 already flies it.
