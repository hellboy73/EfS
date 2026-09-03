# Escape from Saturn — open questions

Everything here is deliberately **not** decided yet. Each entry says what the
decision is, what it depends on, and how it will be settled. Settled items move
into [`design_technical.md`](design_technical.md) section 11 and are deleted here.

`(TBM)` = to be measured in madsim. `(TBD)` = a design call to make.

---

## A. World

**A1. World size (TBD).** Baseline is 1 world unit = 1/16 screen pixel, giving a
4096 x 4096 px torus = 13.6 x 10.2 screens. Alternatives: 1/8 px per unit gives
8192 px (27 x 20 screens) with half the subpixel resolution; 1/32 gives 2048 px
(6.8 x 5.1 screens) with double. *Decide after* the speed tiers exist, because
what matters is **how long it takes to cross the world at cruise speed** — the
target is a number of seconds that feels like a place, not a corridor. First guess
to test: ~15-20 s corner to corner.

**A2. Exit mechanism (TBD).** How the player leaves once the mission is done.
Options: a gate object that appears at a fixed world location; an exit corridor in
a signalled direction; simply "fly in direction D for N seconds". Affects HUD
(needs a pointer/compass) and level scripting.

**A3. World size per level (TBD).** The script wants levels 4 and 5 to be *much*
larger than the early ones, so the answer is already "it varies" — world size is
per-level data. What this changes is A1: the baseline must be chosen with room to
grow, not as a fixed constant.

**A4. Does the wrap change across the campaign (TBD)?** The fiction frames the
looping region as a Saturnium space-folding anomaly that gets stranger as the game
goes on. Whether that ever becomes mechanical (asymmetric wrap, seams, a visible
fold) or stays pure flavour is a design call — mechanically it would cost the free
wrap, so the bar is high.

---

## B. Ship handling — the benches are built, now it has to be flown

[`proto/01_flight`](../proto/01_flight/) put all of B1-B3 on a joystick with a
live readout and [`proto/02_rocks`](../proto/02_rocks/) added a continuous
throttle, a boost and a teleport on top; both benches are frozen now and the
knobs came forward into [`src/main.s`](../src/main.s), which is where they are
flown. **These stay open until someone flies it and says which values are
right** — and where `cart_init` calls a value "the settled-on default", someone
already has.

The *turning* half of the section has been flown and has left: how fast the ship
turns, how quickly it gets there, and how hard that follows speed are now
[`design_technical.md`](design_technical.md) 11.15-11.17. What stays here is the
throttle's range, the camera's lag behind it, and what the ship looks like doing
it.

**B1. Speed range, and how the throttle moves through it (TBM).** The eleven
values are still the ones flown by hand — `-150, -100, -50, 0, +50, +100, +150,
+200, +250, +300, +350` px/s — but they are no longer *tiers the player steps
between*. `THRTL` is a continuous position over that table (`THRTL_ACCEL`: full
range in ~1.3 s), and a "tier" is now just how finely the curve is authored —
speed, ship offset, zoom and camera lean are all read at the swept position.

Two mechanics ride on top, and neither has been judged yet:

- **BOOST** (`TIER_BOOST`): a twelfth row the throttle cannot reach — 700 px/s for
  `BOOST_FRAMES = 90` (1.5 s), on joystick 2 UP. 482.5 px/s is the ceiling of a
  signed 8.8 velocity, so it is authored as the top tier *doubled* (`TIER_SHL`)
  rather than typed; typing 500 into the speed table fires the ship backwards.
- **TELEPORT** (joystick 2 DOWN): a jump along the heading whose length is not
  authored at all. The ship lands on a fixed screen point (`TP_OFF = 120`), so the
  distance falls out of the geometry as `SHOFF - landing`: 246 px at +350, 160 px
  at a standstill, and backwards in reverse.

Open: the eleven values, the throttle's ramp rate, and whether boost and teleport
belong in the game at all.

**B3. Camera lag constant (TBM — narrowed to one number).** Half of this question
is answered: the ship's screen slide and the zoom **do** share a constant. Both
ease by `1/(2^SHOFF_LAG)` of the remaining gap each frame with `SHOFF_LAG = 4`,
i.e. 1/16, and the camera's lean into a turn (C5) eases the same way on its own
constant, `CAMX_LAG = 5`. What is left is flying it: too fast is nauseating, too
slow disconnects the throttle from the view.

**B4. Visual bank angle while turning (TBD).** How much the ship tilts, and whether
it is a sprite swap (cheap, a handful of frames) or a real small rotation.

**B5. 32 headings or 256 (TBD).** The design assumes 32. The bench deliberately
runs at 256 — *with a fraction*, since the turn ladder is quarter-brad
(`design_technical.md` 11.15), so the heading is 8.8 and the world is rotated by
its integer part. With the ship always drawn nose-up, the only place the choice
shows is the smoothness of the world's rotation. If 32 is not visibly steppy it
is free; if it is, the design should say 256.

The fractional heading is a separate matter and does not settle this: it exists to
make the *rate* selectable in quarter-brad steps, and would still be wanted at 32.

---

## C. Camera and zoom

**C1. Zoom range (TBM — 2x is in and flying, and 3x is no longer blocked).**
Reference zoom is 16 units/px at standstill. The camera ramps to **2x out at the
top tier**, eased, and the whole curve is one line (`ZOOM_RZ`), so 3x or a later
ramp is an edit and not a rewrite. What that costs is measured: the visible-object
count scales as the **square** of the zoom, so 2x out means ~4x the objects
through the cull.

The slot cap is now `NOBJ = 120`. It was 250 while rocks were dotted half-res
figures, and what took it down was the move to full-res solid outlines (D11) as
much as the zoom.

The blocker this entry used to name is gone: "3x would be ~9x and needs the
spatial bucketing of E1 first" — the bucketing is built (E2), so 3x is now a
measurement rather than a prerequisite. Constrained by C2.

**C2. Legibility floor (TBM).** At maximum zoom-out, is a small asteroid still
readable in 1-bit at 300 x 400? This sets the hard limit on C1 and is a
look-at-the-screen decision, not a calculation.

**C3. Ship screen-Y range (TBM).** Built in proto 01: **40 px below centre at
rest** (20% of the half-height — dead centre gives as much screen behind as
ahead, and ahead is where you are going), +126 at +350, -40 at full reverse,
eased. Needs flying to settle whether the range is right and whether it should be
linear in speed (it is now) or weighted toward the fast end.

Two things the proto pinned down. **127 is a hard ceiling**, not a taste
judgement: the offset is a signed byte and the first cut ran to 140, wrapped, and
threw the ship to the top of the screen. And the offset is not free — the star
and mote camera point rides `SHOFF` ahead of the ship, so lowering the ship pushes
that sample nearer the star layer's 128-unit reach and measurably increases the
churn at the park boundary (wrong-way star sweeps went from 8 to 13 in 1,900).
Small, but it is the reason a bigger rest offset is not simply better.

**C4. Zoom quantisation (ANSWERED in the bench — and the mix is deliberate).** The
bench runs exactly the mixed scheme this question was worried about, and it looks
right.

The **view scale is quantised**: the reciprocal snaps to `ZQ_LADDER`'s geometric
rungs, because the ZS table is rebuilt whenever its integer part moves (~10,000
cycles) and an un-quantised ease crosses all 64 values of the reciprocal instead
of 16 rungs.

The **object scale stays continuous**: rocks are sent the smooth ease (`ZEASH`),
never the rung (`ZOOMH`). Reading the rung there was a visible defect — a rock's
size has no per-frame motion of its own to hide a step in, the way its position
does, so the scale popped while everything else was smooth.

What is still open is the case the question was really about: **sprites**. When a
pre-scaled sprite set exists (D2) its steps are coarser than either of these, and
whether a snapped sprite beside a continuous outline reads wrong is a
look-at-the-screen decision.

**C5. How hard the camera leans into a turn (TBM).** The camera lags a turning
ship, which slides the ship sideways across the screen: target cross-offset =
turn velocity x `CAMX_TIER` (Q0.7, per tier), eased with `CAMX_LAG = 5`, with the
turn velocity clamped at `CAMX_CLAMP = 768` (3.0 brad/frame) so the speed coupling
cannot push it past what the arithmetic holds. That puts the target at **+/-80
full-res px** at full lean and top speed. The first cut was a quarter of that and
read as almost nothing, the second a half — and all three leaned just as hard
standing still, which is where it looked wrong, hence the per-tier gain that is
zero at rest. Reverse leans too: the camera lags whichever way you are going.

The reason this is a question and not a taste judgement is the **cull**. The world
pivots on the ship (4.2), so sliding the ship across the screen moves the pivot
with it. The cross-axis reach goes from 150 + 96 to 150 + 80 + 96, the worst-case
vector from 483 to 534 px, and both cull tables are regenerated from that number —
a 4.7% bigger `CULL_R` is **9.6% more area through the precise cull**. Leaning
harder is not free.

Open: whether +/-80 is right, and the **sign** — which way it leans is the only
thing about it that was ever a guess.

---

## D. Rendering

**D2. Number of pre-scaled sprite steps (TBD).** Settled that sprites are not a
level-of-detail fallback for the ship or for rocks — both stay vector at every
on-screen size, closing D1 (see `design_technical.md` 11.9). Sprites are for art
that is not an outline: **thruster flames and shots**, player and enemy. Flames
will be authored at several sizes so the right one is picked for the current
zoom level; how many steps, and whether shots need more than one size, is still
open.

**D8. Star size and lattice (TBD).** `DOT_PIXELS` draws single pixels but takes
half-res coordinates, so stars land only on even framebuffer pixels - a 2-pixel
lattice, which is also the finest step the field can scroll by. `PIXEL` ($40)
would give full-res placement at 5 PPRAM bytes per star and one dispatch each,
against 2 bytes in a single batched call. Only worth it if the lattice reads as
chunky on a real screen.

This is no longer only about stars: the radar's blips ride the same primitive and
the same lattice (G3), so whatever is decided here decides how a contact reads
too — and the radar has less room to lose, since a blip is a single point where a
star is one of eighty-eight.

**D9. Star layer size (SETTLED — park, do not fold).** A 256 × 256 layer rotates
to a view radius of up to 181, which does not fit the byte the view position is
stored in; folded stars are drawn at the wrong screen edge sweeping against the
turn. Stars that do not fit are now parked (all are off-screen anyway) and a
refresh un-parks them before the field scrolls past the 27-pixel margin. See
`design_technical.md` 5.3. What stays open is whether a *denser* layer is wanted
(see D4) — that is a separate question from this one.

**D10. Mote count and look (TBD).** The near layer runs `MOTE_N = 10` specks
(about 5 on screen) at twice the ship's speed. They are single pixels, exactly
like stars, and are told apart only by how fast they move — a short streak would
read as speed more strongly but costs a line instead of a point. 4x was tried and
is too fast: at the top tier it moves them ~12 half-res pixels a frame, and specks
that quick stop reading as depth and start reading as noise. Open: how many, and
whether they should be streaks.

**D4. Star layers (TBM).** How many parallax layers, how many stars per layer, and
their parallax factors. Cost is one `DOT_PIXELS` call per layer plus the point-list
build. PPRAM cost is 2 bytes per *visible* star, so the star count is bounded by
the 2 KB list as well as by CPU.

**D5. HUD layer (SETTLED — background, one line per two frames).** Measured in
proto 01: `TEXT`/`VTEXT` write whole cells including the background, so an
image-layer HUD erases the starfield under it. The HUD goes on the VRAM
background, where it is free — and where the double-buffer replay allows **one
background write per frame plus a cooldown frame**. With two HUD lines and a
message line that is a **6-frame round-robin, ~10 Hz per line**. Folded into
`design_technical.md` 5.5.

Two things the bench has since put numbers on. The HUD costs **~48,700 GPU cycles
in seven `VTEXT` commands**, and that is now wired into the rock budget
(`AST_NONROCK`) rather than being an anecdote: turning the HUD on takes ~26
vertices a frame away from the asteroids. And the bench draws it on the **image
layer** with `HUD_ON = 0` by default — precisely because that is not where the
real game puts it. The bench HUD is there to be measured, not to be copied.

What is still open: **how many lines** (each one added slows every other line
down — a fourth makes it 8 frames), and **where** they go, since 300 x 400 is
tall and narrow and the HUD competes with look-ahead.

**D6. Star occlusion behind asteroids (SETTLED for now — disc test, inverted onto
row bands).** Rocks are **outlines**, so they are hollow whichever opcode draws
them, and stars must be suppressed where a rock covers them or the rock reads as
a wire hoop. (This entry used to say "dot-line outlines"; they are solid full-res
now — see D11 — which changes nothing about the hollowness.) The suppression
radius is the shape's **mean vertex radius**, not its bound; the leak/halo
measurement behind that is folded into `design_technical.md` 5.4.

What changed since is the *shape* of the pass, not the test. "For each star, for
every occluder" is O(stars x occluders) and grows with exactly the thing that
overloads the frame — 40 survivors times up to 16 boxes is 640 tests. It is
inverted now: an occluder registers itself in the screen **row bands** its box
spans (`OCCB_SH = 4`, so 16 half-res rows a band, `OCCB_N = 10` bands over FBY
0..149) and a star tests only the occluders in its own band. 16 slots a band is
the `OCCN` maximum, so a band can never overflow and the build needs no capacity
test. The old figure — ~3,000 cycles on a median frame, ~6,000 on the worst — was
taken before that inversion and before the object count moved, so it needs
retaking.

What stays open: the **coarse occlusion mask** (rocks + stars instead of rocks
x stars, 60 bytes at 8 x 8 half-res pixels per cell). It only starts to pay when
the product grows — zoom-out puts more rocks on camera and fragments multiply
them — so it is a **(TBM at 20+ rocks)**, and its resolution is a **(TBD)**.

Closed since: whether the suppression radius and the **collision radius** are
literally the same number. They are — `design_technical.md` 11.12 — and the bench
asserts it (`SHAPE_OCC` is read by both).

**D11. What opcode draws a rock (TBM — full-res solid is in, and it cost half the
field).** `ROCK_FAMILY` picks between `$4C DOT_POLYGON` (dotted, half-res), `$4D
POLYGON` (solid, half-res) and `$4E POLYGON16` (solid, full-res). The bench ships
**2**, and the trade is not the one it looks like.

What full-res buys is mostly the **centre**, not the raster: at half-res a rock's
screen position is the full-res one `>> 1`, so it steps two pixels at a time and a
slow drift stutters — the same defect that was found on the ship and fixed with
`LINE16`. What it takes away is the **dotted rim**, because there is no dotted
full-res figure — and a dotted rim was chosen deliberately once, as the thing that
reads as "rock" and as the reason a rock gets a suppression disc rather than an
occluder box. So this is an art decision riding on a resolution one, and it should
be looked at rather than assumed.

The price is in the budget and it is not small: `AST_VCOST` is 1,564 GPU cycles a
vertex dotted, 1,749 solid half-res, **1,873 solid full-res**. Both valves are
derived from it (`AST_BUDGET`, `AST_MAX`), so changing family re-derives them —
but `NOBJ` is hand-set, and 120 is where full-res solid put it (C1).

Also open, and cheaper than it sounds: the shapes are still the **half-res tables
doubled** (`SHAPE_16X`), which is an exact scale-up that lands every vertex on an
even full-res pixel. A genuinely full-res shape cannot be derived — it has to be
authored — and it matters most on `SHP16`, where one half-res pixel is a quarter
of the whole rock.

---

## E. Objects and physics

**E1. Object pool size (TBM — and the cost has moved to the other CPU).** The
first measurement was **~290 cycles per object per frame** for integrate + cull
alone, ten times this document's original estimate, because a 16.8 position plus
an 8.8 velocity makes one axis a 24-bit add. Two things have happened since, and
between them they change what the answer is bounded by.

**The sector grid landed** (E2). `do_objects` no longer walks all `NOBJ` every
frame — it walks only the cells overlapping the cull window, so the cost is
proportional to what is *near* rather than to how many rocks exist. A far rock now
costs one coarse high-byte reject, ~40 cycles instead of ~160, and is frozen
rather than integrated.

**The transform moved to the GPU** (`design_technical.md` 11.13). A vertex used to
be ~530 cycles of CPU1 work; it is now ~30 of copying, plus 1,500-1,900 GPU cycles
of transform, clip and raster. So the budget the object count runs into is the
**GPU's** frame, not CPU1's — and it is derived rather than typed:
`AST_BUDGET = (209,000 - AST_NONROCK) / AST_VCOST`, with `AST_MAX` a count cap
that must never bind before the budget does. Hand-picking that cap at 10 fired
with budget still unspent and abandoned every remaining rock in the visible list,
wherever they happened to be on screen (proto 01 finding 49).

The slot cap is `NOBJ = 120`, and it is a budget number rather than a world one:
the world is about 140 screens, so 120 is a bit over one rock per screen by
centre, which at up to 192 px across comes out as 3 to 6 actually on camera.
**Every slot still costs the coarse reject whether or not it is anywhere near**,
and that remains the single largest item in the frame — which is exactly what
makes `NOBJ` the lever it is.

The collision pass is measured and rides cheaply on top of all this: **+7,100
cycles in the median frame and +16,600 in the worst**, taking that worst frame
from 63.7% of budget to 70.7% over a 120-rock field. It is cheaper than the
integrate-and-cull it rides on. The lever left, if the object count grows past
what that can absorb, is a collision window narrower than the cull's — one compare
per body.

**E2. ~~Sector grid resolution~~ — SETTLED: 4096 world units, 16 x 16.** The rule
turned out to be sharper than "larger than the biggest asteroid": a sector must be
at least the **largest sum of two collision radii**, since that is the distance at
which two bodies can still touch. That is what lets the pair walk visit four
neighbours instead of eight and see every pair exactly once. Moved to
`design_technical.md` 6.3; the assembly-time assertion that enforces it lives in
`physics.s` (`2*COL_RMAX <= CELL_CU`, beside the one that keeps `2*rsum` inside
the quarter-square table's index).

**E3. ~~Size classes~~ — SETTLED: five, and the mass curve is powers of two.**
192/128/64/32/16 px across, radii 39/26/13/7/3 collision units (`SHAPE_OCC`, the
mean-vertex radius, which is also the star-occlusion disc), each class **half the
mass of the one above**. The halving is not a feel decision — it is what collapses
the mass-ratio table to nine bytes and makes momentum conserve to the bit. See
`design_technical.md` 11.11 and `physics.md` 4.2.

**E4. Restitution, spin gain, split impulse, break-up threshold (TBM).** The whole
tuning surface, and still largely open — the physics *runs* now, which means the
iteration loop this question was waiting for can start.

What has code behind it: **restitution**, spent as shifts rather than a multiply
(the `(1+e)` block), so retuning it costs nothing; and the **separation push**,
`n >> PHYS_SEP_SH` with `PHYS_SEP_DP` less shift for the heavier body of a pair —
both at first-cut values, `physics.md` 4. Separation is never skipped even when
the per-frame response cap (E5) is hit, because it is the only thing that can
resolve a pair.

What still has none: **spin gain** and the **break-up threshold** (the relative
normal speed a hit has to exceed to split a rock, `physics.md` 5). Splitting
itself does not exist yet, so E3's size classes have no ladder to fall down.

**E5. ~~Every frame, or on a budget~~ — SETTLED: every frame, with a deferral
cap.** Pairs are tested every frame for every body inside the coarse window, and
the *response* is capped at `COL_MAX` per frame. Past the cap a pair is still
detected and simply waits — the overlap does not go away, so nothing is lost by
deferring it, and one pathological frame cannot eat the budget. That is deferral,
not the amortisation this question feared: there is no pass-through, because the
detection is never the thing that gets skipped.

**E6. Enemy roster (TBD).** Types and behaviours. The story fixes the *shape* of
what is needed (see `story.md`): a **cloak state** (visible/invisible while still
simulated), and **patrol / detect / pursue / lose-track** behaviour with a
detection radius. Still open: how many distinct alien types, whether they obey the
same collision physics as rocks or fly under their own control, and how they are
armed.

The *format* already exists even though the roster does not: `levels.s` carries
enemy placements as `XL, XH, YL, YH, kind` — five bytes each, placed by hand in
the level editor beside the rocks — and nothing reads them yet. So the bench that
takes E6 on inherits a level format instead of inventing one, and the radar (G3)
needs the smallest possible reader for it — positions and nothing else.

**E7. Cloak semantics (TBD).** When an enemy is cloaked, is it only invisible, or
also non-collidable and non-targetable? Different answers make level 2 either eerie
or lethal. Also: what triggers decloaking — a timer, proximity, or the player
shooting.

**E8. Instrument deception model (TBD).** The story requires the radar/HUD to
degrade across the campaign: missing contacts, ghost contacts, wrong bearings.
Needs a per-level parameter set, and it must be designed together with the HUD
(D5) rather than added afterwards.

---

## F. Content and structure

**F1. Mission types (TBD).** ~~Number of levels~~ — **settled: 5 levels**
(MINING ZONE / SENSOR ANOMALY / CONTACT / HUNT / ESCAPE, see `story.md`). What
remains open is the implementation of the three mission types the script needs:
**clear the field**, **survive / traverse**, **reach the exit alive** — and what
each shows on the HUD.

**F2. Bank map (TBD).** The draft in `design_technical.md` section 10 is a guess.
Real allocation follows real asset sizes — music is usually the surprise (in CETAS
one song was 11 banks).

**F3. Music: how many tracks, how long (TBD).** The biggest single consumer of a
256 KB cartridge. If the campaign wants more music than fits, the options are a
512 KB part (the bank register reaches 1 MB, so it costs nothing in hardware) or
fewer/shorter tracks.

**F4. Save / continue / high score (TBD).** The console has no persistent storage;
decide what a "campaign" means across a power cycle (level codes?).

---

## G. HUD & radar

**G1. Radar scale (SETTLED — fixed, independent of camera zoom).** The radar
does **not** zoom with the camera (4.4) — it always represents the same
world-unit radius, so its scale is a compile-time constant shift, not a value
that tracks the camera's zoom reciprocal. Rotation is still shared with the
main camera transform (the same per-frame `ROT[]` tables from
`design_technical.md` 4.5a); only the scale step differs, and it's simpler
than the camera's because it never changes.

**G2. Data admission — by radius, entirely in world space, before the
transform (TBD — shape decided, exact radius still TBM).** The radar's
catchment is now a **circle** (G4), and a circle is rotation- and
scale-invariant: whether a point ends up inside it does not depend on the
camera heading or on the radar's (fixed) scale, only on its raw world-space
distance from the ship. That means the admission test can run **before**
any `ROT[]` rotation, and once a point passes it, no separate post-transform
clip is needed at all — the earlier plan of a rotate-then-clip-to-a-box pass
is dropped along with the rectangle.

The test itself reuses the pattern already used for star occlusion (5.4): a
cheap **box pre-reject** (compare `|dx|` and `|dy|` independently against the
radius, no multiply — the same coarse reject as 4.5b) throws out nearly
everything, then a **precise round test** (`dx*dx + dy*dy` vs `R*R`, via the
quarter-square table already built for rotation — `x*x = f(2x)`, so this is
two lookups and a compare, not a real multiply) confirms what's left. Only
survivors get rotated and scaled for display.

**The candidates do NOT come from the sector grid, and that is a reversal.**
This entry used to say the grid (6.3/6.2) was the natural source, walking a ring
of cells around the ship's own. That was right at a reach of 12,800, where the
ring is 9 x 9 of a 16 x 16 grid. It is wrong at 25,600, where the ring is
**15 x 15** - the index would be walking 88% of the world to avoid looking at
12% of it, and paying per-cell overhead for the privilege. A spatial index earns
its keep when the query is small against the world; this query is not, any more.

What replaced it is a flat scan of the object array with the **class window
tested first** (G8) - one subtract and one compare, and five sixths of the field
ends there before its position has even been read. Measured, the flat scan with
the window costs less than the cell ring did at half the reach.

**The radius itself is a performance knob, not a fixed number yet.** It will
be tuned down until the frame budget is comfortable. It should **not**
literally reuse any of the engine's existing cull thresholds — the per-sector
cull window (6.3) and the per-object cull radius (4.4, a 9-entry table that
scales as `128/RZ`) are both deliberately zoom-dependent, which is exactly
what G1 opted the radar out of; reusing either would make the radar's reach
breathe with the camera again, and reusing anything close to a screen's
worth of world units is pointless anyway — that's already visible without a
radar.

**The reach is 25,600 world units, and the class window is what pays for it.**
12,800 was the first cut and it read as short: the instrument told you about a
neighbourhood when what you want from a radar is a region. Doubling it took the
covered area from 12% of the world to **48%** - a circle of 25,600 in a 65,536
torus is very nearly half of everywhere - and it cost nothing on screen,
because radius and footprint are only related through the scale: `RAD_SH` went
from 1 to 2 and the box stayed at the 100 x 100 G4 settled on.

What it did cost is objects, and that is answered by **G8**: the instrument
shows only the two largest size classes that still exist. Between them, the
reach doubled and the frame got *cheaper* per contact considered.

Two things bound any further doubling. 25,600 is 78% of the **32,768** at which
a wrap-correct signed subtract stops being unambiguous, so there is one more
step in this and not two. And `RAD_RH` is 100 in high-byte units, where the box
test needs `2*RAD_RH+1` to fit an unsigned byte and the round test needs
`2*RAD_RH` to index the quarter-square table - both assert at assembly time.

**(TBM - flown, but not judged.)**

*Correction carried from the previous round:* the physics-active set is
**not** larger than the camera's cull window (6.1 ties "frozen vs simulated"
to that same window, and 6.3 says the collision pass sees only what survives
inside the render-visible window, not a margin beyond it) — so the radar
cannot just piggyback on "whatever physics already caught" and needs this
independent radius-bounded query, sized on its own terms.

**Frozen/stale rocks beyond the near-camera simulation window (SETTLED —
accept it).** Objects inside the radar's radius but outside the camera's
actual simulated window are frozen (6.1): their position is "last known
while near the camera," not current. Decision: fine as-is for v1 — rocks
drift slowly, a stationary one only starts moving once the camera nears it
(6.1), and at the radar's small scale that lag reads as minimal. No plan to
widen the simulated window just for this. Revisit only if playtesting says
otherwise; note it also happens to sit comfortably next to **E8**'s eventual
deliberate deception rather than fighting it.

**G3. Blip shape (SETTLED for v1 — single points through one batched call).**
Every rock is **one point**, regardless of size class; an enemy is one point too,
toggled by a **global blink counter at 10 frames dark / 10 frames lit** (a
20-frame, ~3 Hz cycle) — skipped at list-build time on the off phase, so the blink
costs nothing. Points go through `DOT_PIXELS` (`$FF24`), the batched point-cloud
primitive, at 2 bytes each — not the full-res `PIXEL` op (D8), which would cost 5
PPRAM bytes plus a dispatch *per point*. `DOT_PIXELS` places points on the
half-res, 2-pixel lattice (D8); that rules out any tight multi-point "stamp" for
size differentiation (offsets of 1 px do not land on distinct cells), which is why
size differentiation is dropped for v1 rather than attempted with stamps — size
survives as *priority* instead (G7).

Two notes for whoever builds it. There is a **clipping** twin,
`gpu_dotpixels_clip` (`$FF99`), which drops off-screen points from a signed-16
cloud; the radar does not need it, because a circular admission test (G2)
guarantees every surviving blip lands inside the box. `proto/02_rocks`'s
`mad65.inc` has `$FF24` already (the starfield uses it) but not `$FF99` or
`$FF27` — that file lists only what the cartridge actually calls, so the bench
that takes this on adds the equates it needs.

The blink needs enemies to exist. `levels.s` carries them and nothing reads them
(E6), so the radar bench is where the smallest possible reader gets written:
positions and a kind byte, no behaviour.

**G4. Radar shape & footprint (SETTLED — a circle in a 100x100 px box,
bottom-left corner).** Simpler than the earlier rectangle proposal in every
way that matters here: the catchment test is rotation-invariant (G2), and
because the radar's scale never changes (G1), the on-screen result is
exactly a circle too — no ellipse correction, no separate per-axis bound.

**G5. Ship icon & frame (SETTLED — a background bitmap, and it is built).** The
plan was to *draw* a static ring and ship icon onto the VRAM background. **The
background cannot be drawn on.** The GPU OS is explicit: there is no `_BG`
variant of any line or pixel opcode, because setting an individual bit needs a
read-modify-write and the background window is write-only. Background layers are
built from whole-byte writes only — `LOAD`, `TEXT_BG`, `TILE_BG`, `CLEAR_BG`.

So the furniture is a **bitmap**, and it is now built: `assets/png/radar100.png`
is a 100 x 100 ring with a small ship at its centre, authored upright and stored
turned by `tools/bggen.py` (the TATE convention the ship sprite already follows).
It is uploaded with `LOAD` at start-up and after that costs **nothing at all** —
the hardware re-copies the background under the image every frame.

Three things fell out of building it that the entry did not anticipate:

- **It is a strip, not pages.** A `LOAD` writes a whole 256-byte page and a
  framebuffer row is 50 bytes, so a page is 5.12 rows of the *whole screen's*
  width: the corner takes 20 pages, 5,120 bytes, almost all zeros. The cartridge
  stores the 13 columns the art occupies — 1,300 bytes — and expands them into a
  staging page. The expansion is one cursor and no division.
- **It takes 40 frames.** One page every other frame, because of 5.5's two-frame
  rule. ~0.7 s at start-up, and it repaints itself after an overrun `CLEAR_BG`
  rather than leaving a hole for the session.
- **The instrument suppresses the starfield inside its own disc**, through the
  occluder list the rocks already use (5.4). Without that the field shines
  through the ring and a contact is one more speck among the specks. The disc is
  one cell wider than the blip radius, because the two axes round independently
  and a contact on the rim at 45 degrees lands just outside a disc of exactly
  that radius.

**G6. Fallback: background-bitmap radar at a lower refresh (TBD, backup idea —
and its mechanism is now proven).** The radar does not need 60 Hz. If the live
per-frame `DOT_PIXELS` path ever busts the budget, the alternative is CPU1
rasterising the *contacts* into a RAM bitmap and uploading that, refreshed less
often than every frame.

Both of the things this entry said needed checking are now answered, because
G5's furniture uses exactly that path. **The primitive is `LOAD`** (`$30`), one
256-byte page at a time into pages `$C0-$FF`. **And it does obey the two-frame
rule**, so the achievable refresh is one page every other frame — and a 100 x
100 corner is 20 pages, not one. That settles the fallback's real cost: a full
redraw of the contact layer would be ~0.7 s, which is not a refresh rate, it is
a scene transition.

So the fallback is weaker than it looked. If the live path ever needs relief,
the lever to reach for first is the class window (G8), not this.

**G7. Graceful degradation under load — biggest first, decided on CPU1 (TBD).**
If the radius (G2) admits more contacts than there are slots for, the **largest
size classes go on the radar and the smaller ones only if slots are left**, so
small debris is what silently stops appearing under load and starts reappearing
on its own when the field thins.

The earlier version of this entry proposed getting that for free from
`design_technical.md` 5.3a — the GPU drops the tail of a PPRAM list that runs long
— and **that does not work here**. The drop is per *command*, and every blip in a
frame is one batched `DOT_PIXELS`: ordering points inside a single command buys
nothing, because the command either runs whole or not at all.

So the priority is CPU1's own. One point buffer per size class plus one for
enemies, filled during the sector walk and emitted **largest first** against a
global slot cap; the class the cap lands in is truncated and the rest are not
emitted. That costs one dispatch per non-empty class instead of one for the frame,
and no copying at all — the priority *is* the order of the emit calls.

Still open: where the radar's block sits in the **whole** frame's PPRAM list
relative to gameplay objects, stars and motes (5.3a again). It is information, not
decoration, so it likely wants to rank above the backdrop layers — but that is a
placement decision for when the full per-frame list is actually being assembled.

**G8. Radar sensitivity — which size classes it hunts (SETTLED for v1 — the two
largest that still exist).** The instrument does not show every rock. It shows
the **`RAD_CLASSES` largest size classes that still have a member**, and ignores
everything smaller: at the start of a level that is the 192s and the 128s, and
as the player clears a class out the window steps down of its own accord —
192/128, then 128/64, and so on down to the 16s. **Enemies are never subject to
it**; a contact is a contact whatever else is on the screen.

It is a gameplay rule first. An instrument that quietly retunes itself to
whatever is left tells the player something about the state of the field without
a line of HUD text, and it sits naturally beside **E8**'s eventual deception —
one is the radar being honest about a changing world, the other is it lying
about an unchanged one.

It is also what pays for G2's reach. Two classes of a 120-rock field is 30
rocks, so five sixths of the scan ends at one subtract and one compare, before a
position is read. Doubling the radius and adding this together left the frame
cheaper per contact than the narrow radar was.

The mechanism is a per-class population count taken when the level loads
(`RKLIVE`), and a window that is recomputed from it every frame. Nothing has to
raise an event when the last 192 dies: whatever destroys it decrements the count
and the instrument follows on the next frame. **Open:** whether the window is
two classes or one, and whether the step down should be announced — a silent
retune is elegant but a player who does not notice it may read the emptier
screen as a broken radar.

Ties to **E8** (instrument deception): everything above is the honest v1
pipeline. The lying radar from level 5 on is a filter/parameter set applied
on top of it — missing contacts, ghost contacts, wrong bearings — not a
separate rendering path.
