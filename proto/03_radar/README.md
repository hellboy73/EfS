# proto 03 — radar bench

> **FROZEN — and this is the one the game grew out of.** [`src/`](../../src/)
> started as a byte-for-byte copy of this directory: the promotion commit
> proved it by building the root `cart.bin` and comparing it to `proto03.bin`
> here, which matched exactly. So this is a record, not living code. The game
> is built from the repo root with `make`; nothing in that build reads this
> directory. Do not fix things here and do not fork it into a `proto/04` —
> changes belong in `src/`. The findings below stay because `docs/` cites them.

Forked from [`proto/02_rocks`](../02_rocks/), which answered what a colliding
asteroid field costs. Everything that bench does, this one still does. What it
adds is the **HUD radar**: what is near, on a scale that does not move, in the
corner of the screen. That is this bench's one question, and
[`open_questions.md`](../../docs/open_questions.md) section G is the design it
is built from.

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

Enemies are placed the same way, and something reads them now — `load_foes`
in [`radar.s`](radar.s) pulls them into RAM and the radar puts blips on them.
That is *all* it does with them: E6 has not settled the roster, so the `kind`
byte is carried and never interpreted, and nothing moves, shoots or thinks.
Level 0 carries six, four of them inside the radar's reach and two outside, so
the admission test has something to reject.

---

## Starting point

Everything in [proto 01's README](../01_flight/README.md) still applies here
unchanged — the starfield, the zoom, the speed tiers, the turn model, the rock
tables in [`shapes.s`](shapes.s) and the `main.s` tables listed there. This
file only documents what changes on top of that baseline.

## The radar

[`radar.s`](radar.s) is the bench's answer to its own question, and its header is
the argument. Two ideas carry it.

**The catchment is a circle in world space**, and a circle is invariant under
both of the transforms that follow it — the camera's rotation and the radar's
own fixed scale. So "is this on the radar" is answered *before* any rotation, on
the raw world delta, and once a contact passes, nothing downstream can push it
out of the box. There is no clipping pass at all: `gpu_dotpixels_clip` (`$FF99`)
exists and is not needed, and `preview.py` proves it by checking that no blip on
any frame of the flight leaves the 50 x 50 cell square.

**The low byte of a world delta is noise at this scale.** One radar pixel is
1,024 world units, so a delta's high byte alone is four times finer than
anything that can be drawn. Every step runs on high bytes: the delta is one
`SBC` per axis (and the wrap is free), the admission test squares a value that
cannot leave 0..100, and the rotation is four byte-indexed reads of the `ROT`
tables `do_camera` already builds. **There is not one multiply in the pass.**

| | | why |
|---|---|---|
| reach | **25,600** world units | = 100 in position-high-byte units, so the round test is `QS[2\|dx\|] + QS[2\|dy\|] <= 10000` — two reads of the quarter-square table the multiply already builds. It covers **48% of the world**, and 78% of the 32,768 at which a wrap-correct signed subtract stops being unambiguous, so there is one more doubling in this and not two |
| scale | **`>> 10`**, a constant | on a value whose useful part is the high byte, that is two RORs on that byte. It shares the camera's **rotation** and must never share its **zoom** (G1) — which is why the reach could double without the box moving |
| footprint | **100 x 100** full-res px | hard into the bottom-left corner: the outermost blip column is 174 + 25 = 199, the last half-res column there is. What is left over is the *artwork*, one pixel inside that — the ring is drawn at radius 49 where the blips reach 50 |
| classes | **the two largest alive** | see below |

**Sensitivity: it hunts the two largest size classes that still exist** and
ignores everything smaller. As the player clears a class out, the window steps
down on its own — 192/128, then 128/64, down to the 16s — because the per-class
population is counted when the level loads and the window is recomputed from it
every frame. Nothing has to raise an event when the last 192 dies. Enemies are
never subject to it.

That is a gameplay rule that happens to be the performance one. Two classes of a
120-rock field is 30 rocks, so five sixths of the scan ends at one subtract and
one compare, before a position is read — and it is what let the reach double.

**The sector grid is not used, and that is a reversal.** The first version
walked a ring of cells, which is what `open_questions.md` G2 assumed. That was
right at a reach of 12,800, where the ring is 9 x 9 of a 16 x 16 grid. It is
wrong at 25,600, where the ring is **15 x 15** — the index would walk 88% of the
world to avoid looking at 12% of it. A spatial index earns its keep when the
query is small against the world; this one is not.

**Priority is CPU1's, not the GPU's.** The GPU drops whole *commands* off the end
of a list that runs long, so ordering points inside one `DOT_PIXELS` buys
nothing. There is one list per class on its own page, emitted **enemies first
and then the biggest rocks down** against a global slot cap, and the class the
cap lands in is truncated.

**Enemies blink** on a 20-frame cycle, lit for ten. The dark half is skipped at
list-build time, so the blink costs less than nothing.

### The furniture

The ring and the ship icon are **a background bitmap**, because they cannot be
drawn: there is no `_BG` variant of any line or pixel opcode — the background
window is write-only, and setting one bit would need a read-modify-write. Whole
bytes are all there is.

So [`assets/png/radar100.png`](../../assets/png/radar100.png) is the artwork,
authored upright and stored turned by [`tools/bggen.py`](../../tools/bggen.py) —
the TATE convention the ship sprite already follows. Repaint the PNG in any
editor and re-run:

```bash
python tools/bggen.py assets/png/radar100.png proto/03_radar/radar_bg.s RING --at 1,298
```

Three things about the upload are worth knowing before touching it:

- **It is a strip, not pages.** A `LOAD` writes a whole 256-byte page and a
  framebuffer row is 50 bytes, so a page is 5.12 rows of the *whole screen's*
  width: the corner is 20 pages, 5,120 bytes, almost all zeros. `radar_bg.s`
  stores the 13 columns the art occupies — 1,300 bytes — and `ring_page` expands
  them into a staging page with one cursor and no division.
- **It takes 40 frames**, one page every other frame, because every VRAM
  background write must be the only one on its frame with an idle frame after it
  (5.5). ~0.7 s at start-up. It cannot be done in `cart_init`: that runs outside
  the `gpu_begin`/`gpu_end` pair, so anything issued there lands in no frame.
- **It repaints itself.** `cart_frame` re-issues `CLEAR_BG` after a frame the OS
  reported as overrun, which takes the ring with it, so `ring_restart` is called
  there too.

And the instrument **suppresses the starfield inside its own disc**, through the
same occluder list the rocks use. Without it the field shines through the ring
and a contact is one more speck among specks. The disc is one cell wider than
the blip radius: the two axes round independently, so a contact on the rim at 45
degrees lands just outside a disc of exactly that radius.

### Cost, measured

`preview.py` reports it every build. The radar's own cost is the middle column,
measured against proto 02 on the identical flight with the same 88-star field,
so that the difference is the radar and nothing else:

| | proto 02 | proto 03, 88 stars | proto 03 as it ships |
|---|---|---|---|
| CPU1, median frame | 108,531 | 121,586 (**+13,055**) | 115,677 |
| CPU1, worst frame | 176,040 | 186,612 (**+10,572**) | **175,487** |
| % of budget, worst | 74.2% | 78.6% | **73.9%** |
| PPRAM | 320 B | 360 B | 328 B |

The third column is the bench as it stands, with the field thinned to 66 stars —
a quarter fewer, because the radar now owns a corner that used to be sky. That
paid for the radar and about 550 cycles over: the worst frame is *below* proto
02's, with the instrument on it.

That column now measures a version with the ship still on `LINE16`. It has
since moved onto the same `$4E POLYGON16` a rock uses, CPU1 side, and rocks
stopped falling back to an authored reduced outline at small sizes (both
`design_technical.md` 11.9 and 11.14) - together worth another ~10,900 cycles
off the worst frame (164,619, 69.3%). Not re-run as a controlled A/B against
proto 02 the way the table above was, so it is not a fourth column, but it is
what `preview.py` reports today.

The **worst** frame is the one that matters, and the radar adds 4.4% of budget
to it — flat, because the reach does not move with the zoom, so unlike
everything else in the frame its cost does not get worse at speed. The median
pays more than the worst does, which is the same fact from the other side: the
radar costs what it costs on a quiet frame too.

Where it goes on a 120-rock field: ~2,500 cycles rejecting 90 rocks on their
size class, ~900 box-testing the 30 that survive, ~3,100 plotting the ~19 that
get inside the circle, and ~1,800 in the emit — three `DOT_PIXELS` dispatches,
which is what the per-class priority costs. The first number is the one to
argue with: it is the price of a flat scan, and it is still cheaper than the
cell ring it replaced.

The ring upload costs ~17,000 cycles on each of the 20 frames it uses, and none
of them is anywhere near the worst frame of the flight.

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

The cartridge outgrew a single 8 KB bank when `physics.s` landed, so it is
**two**: bank 0 is header + bootstrap + code, bank 1 was `RODATA` alone.

`radar.s` filled bank 0 as well — with the HUD switched on it went over by 161
bytes — so bank 1 now carries a **`CODE2`** segment ahead of `RODATA`, and that
is where `radar.s` assembles. Nothing about it is special: `CODE` and `CODE2`
run contiguously in RAM and every reference between them resolves after the
copy, so it is simply where the room is. And it is still **one** `cart_load`
for bank 1, not two, because the pair is contiguous in the window as well as in
RAM — see `bootstrap.s`, which says what would break that.

This costs
the bench nothing at run time and that is the whole reason it is the right
answer rather than shrinking the code — Model B already copies both segments
into RAM before the first frame, and the window is never read again. The
hand-rolled copy loop in `bootstrap.s` is gone in favour of the OS `cart_load`,
which runs from ROM and so is the only code allowed to re-bank the window it
would otherwise be executing from.

## What is not in scope

**A moving instrument.** The ring is uploaded once and never touched again. A
radar that swept, or that dimmed a contact by age, would have to go back to the
background at 5.5's rate — which G6 now knows is 0.7 s for a full redraw, so it
would not be that layer doing it.

**Enemy behaviour.** This bench reads enemy *positions* and draws them. It does
not move them, arm them, cloak them or decide how many kinds there are; E6 and
E7 are still open and the `kind` byte is carried untouched.

**The lying radar.** `open_questions.md` E8 wants the instrument to degrade
across the campaign — missing contacts, ghost contacts, wrong bearings. Nothing
here fights that: it is a filter over the honest pipeline, not a second one.

**The slot cap has never actually bound.** The worst frame of the bench flight
draws 15 contacts of 48, so the truncation logic is verified against the
arithmetic but has never been *exercised* by a field dense enough to trip it.
`preview.py` checks the invariant on every frame; a flight that makes it fire
is still owed.

Also still out, inherited from proto 02: spin transfer and break-up. Spin is a
property of the size class today, not of the rock, and break-up needs fragments
that only the shot-split routine knows how to make.
