# proto 02 — rocks & collisions bench

> **FROZEN.** This bench is a record, not living code. The game is in
> [`src/`](../../src/) and is built from the repo root with `make`; nothing in
> the build reads this directory. Do not fix things here, do not fork it into a
> `proto/04`, and if a number here disagrees with the game, the game is right.
> What a bench is still good for is being *read* — it is the smallest complete
> thing that answered its question, and its findings below are cited from
> `docs/`.

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

```bash
python ../../tools/level_editor.py
```

opens the level editor on [`levels.s`](levels.s) - the companion to the shape
editor, in world space instead of shape space. See below.

---

## The two authoring tools

Nothing in this bench's data is edited by hand unless you want to be:

| tool | file | what it authors |
|---|---|---|
| `tools/shape_editor.py` | [`shapes.s`](shapes.s) | what a rock *looks like* - outlines, LOD outlines, radii, the ship |
| `tools/level_editor.py` | [`levels.s`](levels.s) | what a *level* is - the size-class mix, the seed, the set-pieces, the ship's start |

Both work the same way: only the GENERATED block between the sentinel comments
is touched, and it is rewritten *whole* on every Save, so the file that comes
back is always consistently formatted and the prose header is never disturbed.
Hand-editing either file still works exactly as it did.

The level editor's map is the whole 16-bit torus, and it **wraps** - pan
straight through the seam, because a 16-bit world coordinate has no boundary to
hit. A level's rocks arrive two ways and it shows both at once:

- the **scatter** - a count per size class, dropped at random positions by
  `load_level` at start-up. Drawn dim and not draggable, because it is a
  consequence of the counts and the seed rather than something authored. The
  editor runs `main.s`'s own LFSR in `load_level`'s own order, so what it draws
  is the field the cartridge will actually build - `Reroll` is judged here, not
  in the simulator.
- the **placed rocks** - drawn bright, dragged with the mouse: the set-pieces.

Two optional overlays answer "how much of this is actually on screen": **screen
frames that follow the cursor** - the framebuffer's own footprint in world
units, solid at the resting zoom and dashed at the top-speed zoom-out, turned to
the level's start heading because the frame is portrait and which way its long
side points is the heading's business - and the **dashed circles round the ship
start**, which are those same two rectangles' rotation sweep, the honest answer
when the heading is not known. Both are read out of `main.s` (`FBCX`, `FBCY`,
`ZOOM_RZ`) rather than typed here, so they cannot drift from the real screen.

Enemies are placed the same way. Nothing reads them yet (that is the next
bench, and `open_questions.md` E6 has not settled the roster), but the level
format carries them now so that bench inherits one instead of inventing one.

---

## Starting point

Everything in [proto 01's README](../01_flight/README.md) still applies here
unchanged — the starfield, the zoom, the speed tiers, the turn model, the rock
tables in [`shapes.s`](shapes.s) and the `main.s` tables listed there. This
file only documents what changes on top of that baseline.

## The collision pass

[`physics.s`](physics.s) is the bench's answer to its own question, split out
of `main.s` for the same reason `shapes.s` and `levels.s` were: it is the file
that will be re-tuned twenty times, and it should be possible to argue with it
without reading the flight code. It hooks into `do_objects` in two places — a
per-frame reset and one call per near rock — and [`docs/physics.md`](../../docs/physics.md)
sections 3 and 4 are now a description of what it does rather than a spec for
what it might.

Four things carry it, and three of them are about not multiplying:

- **The collision unit is 32 world units** — one half-res pixel, the unit
  `SHAPE_OCC` is already authored in. Every radius, every sum of two radii and
  every delta that could be a contact is a signed byte.
- **The narrow phase has no multiply in it at all.** The quarter-square table
  is `f(x) = floor(x*x/4)`, so `f(2a) = a*a` exactly, and the circle test is
  three 16-bit table reads and a compare — about 40 cycles, on a table that is
  in RAM for the rotation anyway.
- **The normal is `d / rsum`, not `d / |d|`.** At the moment of contact those
  differ by a percent or two, `rsum` is a constant of the pair, and the error
  is *safe*: deeper overlap makes the normal shorter, so the impulse gets
  weaker. It cannot ring and it cannot explode.
- **Every mass is a power of two**, so the mass ratio depends only on the
  difference of two exponents: nine bytes, read forwards for one body and
  backwards for the other, summing to exactly 128.

The ship is **detected and nothing more** — it flies straight through. What a
hit does to it is not decided, and `do_ship` recomputes the ship's velocity
from the throttle every frame anyway, so an impulse written into it would not
survive to the next one.

## Answers so far

- **Broad phase.** Built on the sector grid `design_technical.md` 11.7 fixes.
  The grid's resolution is settled with it: a sector must be at least the
  largest **sum of two** collision radii, which is what lets each body visit
  four neighbours instead of eight and see every pair exactly once.
- **Narrow phase.** As proto 01's finding 22 called it — the mean-vertex
  radius, the same circle that suppresses stars.
- **Response.** Billiard-ball: normal components exchanged by mass with
  restitution, plus a positional separation that runs on every overlapping
  frame and is the only thing that can untangle rocks scattered on top of each
  other. Splitting and break-up are **not** here; they need the shot-split
  routine, which belongs to the next bench.
- **Cost, measured.** `preview.py` reports it every build: **+7,100 cycles in
  the median frame, +16,600 in the worst**, taking that worst frame from 63.7%
  of budget to 70.7%. It also checks the field's **momentum**, which is the one
  number that says whether the response is physics or just motion.

## The landmark

[`landmark.s`](landmark.s) is a **temporary debug object** — one 256 x 256 px
square nailed to a fixed world position, one sector from the ship's start. It
exists because every rock looks like every other rock and they all drift, so
there is nothing on screen to measure travel against: you cannot tell forty
seconds of flying from having gone round the torus twice. The square does not
move, so any motion of it is yours, and it is not a rock, so its rotation reads
as the camera turning. It is not in the object pool and physics.s never sees
it. Delete the file and its two references when it has done its job.

## Two banks

The cartridge outgrew a single 8 KB bank when `physics.s` landed, so it is now
**two**: bank 0 is header + bootstrap + code, bank 1 is `RODATA`. This costs
the bench nothing at run time and that is the whole reason it is the right
answer rather than shrinking the code — Model B already copies both segments
into RAM before the first frame, and the window is never read again. The
hand-rolled copy loop in `bootstrap.s` is gone in favour of the OS `cart_load`,
which runs from ROM and so is the only code allowed to re-bank the window it
would otherwise be executing from.

## What is not in scope

Enemies (ships, projectiles, AI) are the next bench after this one. This one
is asteroid-field collision only: ship-vs-rock and rock-vs-rock, on the same
torus, at the same scale, as proto 01 already flies it. Spin transfer and
break-up are deferred with it: spin is a property of the size class today, not
of the rock, and break-up needs fragments that only the shot-split routine
knows how to make.
