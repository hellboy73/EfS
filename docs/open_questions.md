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

**A2. Exit mechanism — settled 2026-09-18, moved to `design_technical.md`
11.44.** A gate at a fixed world location, invisible until the mission is done,
then an X on the radar and the enemy arrow's sprite pointing at it. Still open
there: the primitive (`GATE_DOT`) and whether it animates or spins.

**A3. World size per level — settled 2026-09-18, moved to `design_technical.md`
11.45: there is none.** Every sector is the same 16-bit torus; "a larger area"
in levels 4-5 is a far gate, a harder population and lying instruments.

**A4. Does the wrap change across the campaign (TBD)?** The fiction frames the
looping region as a Saturnium space-folding anomaly that gets stranger as the game
goes on. Whether that ever becomes mechanical (asymmetric wrap, seams, a visible
fold) or stays pure flavour is a design call — mechanically it would cost the free
wrap, so the bar is high.

**A5. Levels split into sectors — settled 2026-09-18, moved to
`design_technical.md` 11.45.** Three sectors per level, fixed, numbered `1-1` ..
`5-3`; the briefing (picture + prose) only between levels, the tunnel between
sectors. Still open from the old entry, and now H1's: what the tunnel pays out,
and 1-1 as the sector that teaches one thing at a time.

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
  `BOOST_FRAMES = 90` (1.5 s). Not a button: the player has to already be holding
  the top tier, let go of forward, and choose it again (`do_boost`, input.s) -
  `BOOSTARM` carries the "let go while on top" half of the gesture across frames,
  and falling off the top tier cancels it. Gated on `BOOST_AVAIL`, which is always
  1 for now - the hook for a later collected, limited-charge boost (still open,
  see below). 482.5 px/s is the ceiling of a signed 8.8 velocity, so it is
  authored as the top tier *doubled* (`TIER_SHL`) rather than typed; typing 500
  into the speed table fires the ship backwards.
- **TELEPORT** (joystick 1 FIRE2, double-clicked): a jump along the heading whose
  length is not authored at all. The ship lands on a fixed screen point
  (`TP_OFF = 120`), so the distance falls out of the geometry as `SHOFF -
  landing`: 246 px at +350, 160 px at a standstill, and backwards in reverse.
  FIRE2 is shared with **weapon select** — a single click changes the weapon,
  gun and laser in turn (`laser.s wpn_toggle`, design_technical 11.24), and
  lands `TPCLICK_FRAMES` after the click, because until the window lapses it
  could still be the first half of a double. `TPCLICK_FRAMES`/`TPLOCK_FRAMES` (main.s, ~300 ms/~250 ms) are a
  first cut at the double-click window and the post-teleport lockout that stops
  a triple click's third edge from landing as the next single click - both TBM.

Open: the eleven values, the throttle's ramp rate, whether boost and teleport
belong in the game at all, and the double-click/lockout timings above.

---

## C. Camera and zoom

**C4. Zoom quantisation (ANSWERED in the bench — and the mix is deliberate).** The
bench runs exactly the mixed scheme this question was worried about, and it looks
right.

The **view scale is quantised**: the reciprocal snaps to `ZQ_LADDER`'s geometric
rungs, because the ZS table is rebuilt whenever its integer part moves (~10,000
cycles) and an un-quantised ease crosses all 64 values of the reciprocal instead
of 32 rungs (widened from 16 - see the ZQ_LADDER comment in main.s for the
position-stepping defect that motivated it).

The **object scale stays continuous**: rocks are sent the smooth ease (`ZEASH`),
never the rung (`ZOOMH`). Reading the rung there was a visible defect — a rock's
size has no per-frame motion of its own to hide a step in, the way its position
does, so the scale popped while everything else was smooth.

What is still open is the case the question was really about: **sprites**. When a
pre-scaled sprite set exists (D2) its steps are coarser than either of these, and
whether a snapped sprite beside a continuous outline reads wrong is a
look-at-the-screen decision.

---

## D. Rendering

**D9. Star layer size (SETTLED — park, do not fold).** A 256 × 256 layer rotates
to a view radius of up to 181, which does not fit the byte the view position is
stored in; folded stars are drawn at the wrong screen edge sweeping against the
turn. Stars that do not fit are now parked (all are off-screen anyway) and a
refresh un-parks them before the field scrolls past the 27-pixel margin. See
`design_technical.md` 5.3. Whether a denser layer is wanted is closed with D4 —
see `design_technical.md` 11.37.

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

**D11. Genuinely full-res authored rock shapes (TBD — narrowed).** The opcode
choice itself is closed (full-res solid, `$4E POLYGON16` — `design_technical.md`
11.40): looked at side by side, it reads clearly better than the dotted rim it
replaced. What is left is that the shapes are still the **half-res tables
doubled** (`SHAPE_16X`), an exact scale-up that lands every vertex on an even
full-res pixel. A genuinely full-res shape cannot be derived — it has to be
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

**E9. What the split does to the frame (TBM — and it is the number to watch).**
The split is built (`physics.md` 6, `shots.s rock_split`) and it costs almost
nothing *itself*: a few thousand cycles on the frame a rock comes apart. What
costs is what it leaves behind. Two halves are born in the same place, and their
halves after that, so a cascade builds a **local cluster** — and a cluster is the
worst case for everything that is proportional to what is *near* rather than to
how many rocks exist: `do_objects`' precise pass, `do_collide`'s pair walk, and
the visible list.

Measured, on a deliberately harsh bench — every hit made lethal, so cascades run
far faster than a 5/4/3/2/1 hit-point field allows: the worst frame went from
74.0% to **88.2%**, and the packed visible list from 31 entries to **48 of
`VIS_MAX` 64**. Making the smallest class sweepable debris (`design_technical.md`
11.6) took both back down — **83.6%** and **36** — because the 16s were most of
what was crowding the list. That is the fix, and it is in; what is left open is
that the same pressure comes back on a level with a bigger population, and the
levers are still:

- `VIS_MAX` — 5 bytes an entry, and an overflow is *silent*: a rock past the end
  is neither drawn nor hittable that frame.
- the collision window, which `E1` already names as the lever left if the object
  count grows past what the cull can absorb.

**E10. Overload fallback: play a THRUSTER MALFUNCTION off the AST_MAX/PPRAM
trip (TBD, safety net — proposed 2026-09-11, not built).** The engine already
detects "too many rocks": when `AST_MAX` binds before `AST_BUDGET` is spent, or
a per-frame list overflows (`VIS_MAX`, PPRAM's own drop-the-tail behaviour), the
rest of that frame's rocks are silently abandoned rather than drawn (see the
`AST_BUDGET`/`AST_MAX` note in `main.s` around line 294, and G7's radar
equivalent). Idea: treat that trip as an alarm and spend it on something the
player feels instead of a frame that just quietly loses rocks — a
"THRUSTER MALFUNCTION" state that clamps the throttle's reachable range to the
*middle* of B1's ladder (not the top tier, not a standstill). Because C1 ties
zoom to throttle tier, a forced-mid speed forces a forced-mid zoom — tighter
than top speed's 2x-out, though not the tightest possible — which shrinks the
visible-object count (C1: cost scales as the *square* of the zoom) and buys the
overload a few seconds to recover before it can retrigger.

**It has to read as a game event, not a glitch.** The whole point is that a
player who hits this should experience "my ship is damaged/failing," not "the
game stuttered" — so it needs the same billing as any other scripted systems
failure: HUD text naming it, its own sound cue, maybe a screen-shake or a
flicker on the throttle readout, not just a silent speed cap appearing out of
nowhere. That framing is also what makes it forgiving to design around: since
it is diegetic, it can be foreshadowed (story.md's Saturnium-anomaly flavour,
A4, is sitting right there) rather than sprung on the player as an invisible
performance clamp. This also argues for *not* triggering it purely off a raw
engine counter (E1/E9's overload signal is a GPU-budget trip, not a narrative
beat) — better to gate it so it can only fire where the fiction can carry it,
e.g. armed on levels that already justify strain on the ship.

Not attempted, and nothing here is measured: not the 3 s duration (pure
guess), not "half the ladder," not which counter arms it. Filed here so it is
not forgotten if a split cascade (E9) or a content-heavy level ever sustains
real overload in play — at which point this needs an actual flying pass, the
same way B1-B8 did, not just picked numbers.

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

**E6. Enemy roster (the first kind is SETTLED — the UFO; the rest is TBD).** The
story fixes the *shape* of what is needed (see `story.md`): a **cloak state**
(E7), and **patrol / detect / pursue / lose-track** behaviour with a detection
radius. The UFO (`src/foes.s`, `design_technical.md` 11.23) is the first kind and
settles the second half of that sentence for it: the level record, patrol, sight
and its hysteresis, the chase, the gun, avoidance in place of collision physics,
and what a kill does. Shape representation is 11.20 and simulation lifetime
11.21. Still open:

- **How many more kinds, and what they do.** `KIND` 0 is the UFO, and
  `load_foes` skips any kind nothing knows how to fly. Built so far: the UFO,
  the spider and the PULSAR (`src/pulsar.s`, physics.md 11: a patrol with no
  chase, a spin, a two-ended laser on its frame 0 when it points at the ship,
  a jump round the ship when hit). Whether the pulsar ever pursues is open.
- **Animating parts** — a turret tracking, a barrel recoiling. The UFO's parts
  never move relative to each other; only its wreck moves them.
- **The GPU side of an enemy (TBM).** Two POLYGON16 commands a UFO, one a bullet,
  one a wreck piece — and `AST_NONROCK` (main.s), which the rock outline budget
  is derived from, has not been raised to cover any of it: the same debt
  shots.s's header already owes for the gun. madsim's F3 meter is where it is
  measured, not `tools/preview.py`, which does not model the GPU's clock.
- **The far field.** 11.21's whole-field simulation stands, with the thinking
  decimated (11.23). If the roster outgrows that, the next lever is to freeze a
  far PATROL outright, the rocks' rule, and keep only chases alive — a chase is
  near the ship by definition.

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

**E11. Mining stations — the open parts of `design_technical.md` 11.46 (TBD).**
The figure, its radar mark, its circles and its brake are built and settled:
**11.48** (the human base - six dotted triangles as a hexagon, a circle a triangle
for the stars and the wall, a wall of infinite mass for rocks, a slide for the
ship, enemies stopped and sliding). What is still open:

* **Segments (the user, 2026-09-19):** the base will take **bullets**, be
  **attacked by aliens** and lose its **segments one by one**. What exists is the
  structure - a live bit, a circle, and a drawing mask a triangle (`BSLIVE`); what
  does not is the **hit points** a triangle has, what a bullet or an alien's
  shot does to one (a spark on the circle? the triangle's own outline as the
  target?), **how it falls** (`debris.s`'s way, pieces, a sound), what the
  hexagon does with a hole in it (rocks and the ship can now pass through the gap
  a dead triangle leaves), and whether the alien attackers target a segment or the
  base.
* **CPU cost of the star discs once a triangle is gone:** the one disc round the
  hexagon (11.48) is the cheap case, 19 k cycles a frame for `do_base` and
  `do_stars` with the base on the screen; with a triangle gone the base falls back
  to a disc a triangle that stands, about 2.7 k each more. A base that loses its
  segments one by one is at its dearest with five or four standing (about 28 k).
* **Enemies and the station:** the circles stop them and they slide along them,
  but they do not GO ROUND them as `foe_avoid` takes them round a rock, so a UFO
  after the ship on the far side stays pressed to the base. Do they need to steer
  round? Do the UFOs' shots at a besieged station hit it visibly (sparks, no
  damage)?
* **The circle is not the triangle:** it stands about 40 px off the middle of an
  edge. Fine circles need more of them; is this close enough? (The pocket in the
  middle of the hexagon, where a rock born inside used to get stuck, is closed:
  `bs_eject`, 11.48.)
* **Shots:** the player's bullets and the enemies' end on a live triangle, in a puff
  (11.48), and do it no harm. What is open: the hit points and what a shot takes off
  (Segments, above); the **laser's beam** (`laser.s`) and the pulsar's, which still go
  through the base, and whether they end on the first triangle or burn it.
* **The siege (4-3, 11.46; the fall, the pod and the gate are settled):**
  - What counts as "in the player's presence": on screen, or within a
    distance? And how long after that does the station fall?
  - What becomes of the UFOs still there once it has fallen?
  - How far off do the UFOs "see" the ship?
  - What the pieces of the fall are, and how long they last.
  - Is the wreck left behind solid like the station, or only a picture?
* **Which sectors** have one. Level 0 has one now, only to fly against. Fixed:
  the siege station in 4-3. Candidates for the rest: 1-1 (the station the field
  is cleared for), a dark station in L3.
* **Placement in the level editor**, and rocks the scatter drops inside the base
  (they are put back on a circle the first frame they are awake).
* **The GPU cost in madsim** of six dotted triangles beside the rocks: measured in
  py65 at about 121 k GPU cycles, half a frame, when the hexagon fills the screen
  (11.48); the F3 meter is owed a look.

**F1. Mission types (TBD).** ~~Number of levels~~ — **settled: 5 levels**
(MINING ZONE / CONTACT / HUNT / RESCUE / ESCAPE, re-cut 2026-09-18, see `story.md`). What
remains open is the implementation of the three mission types the script needs:
**clear the field**, **survive / traverse**, **reach the exit alive** — and what
each shows on the HUD.

One piece of "clear the field" is settled and built: **what counts as a rock
left**. `shots.s rocks_left` is the sum of `RKLIVE` over classes 0 to 3 — the
smallest class is debris and is excluded (`design_technical.md` 11.6), because
counting it would make the remaining work jump *upwards* every time the player
destroyed something and the game itself removes it off camera. Nothing reads the
number yet; it is there so that all three mission types read the same one.

**Built 2026-09-18, with the exit gate (`design_technical.md` 11.44):** what
OPENS a sector is per-level data, `levels.s`'s `Lx_MISN` / `Lx_MPAR`, set in
the level editor. Three kinds so far: `MS_ROCKS` — every rock of classes
0..MPAR gone (read straight off `RKLIVE`, level 0 asks for the 192s),
`MS_FOES` — every placed enemy dead, `MS_OPEN` — open from the start ("reach
the exit alive"). Still open: **survive / traverse** (a clock, or a distance),
what the HUD shows of the mission's progress beyond CLEAR THE SECTOR and EXIT
GATE OPEN, and whether a level ever needs two conditions at once.

**F2. Bank map (TBD — but the SIZE is settled: 256 KB).** The draft in
`design_technical.md` section 10 is a guess. Real allocation follows real asset
sizes — music is usually the surprise (in CETAS one song was 11 banks).

What is no longer open is how much room there is and what it is worth: **256 KB,
32 banks, and nothing executes out of any of them** (`design_technical.md`
11.18). So bank space is not the constraint a new table runs into — **RAM** is,
and `design_technical.md` 11.19 now says which RAM, and what may go in each of
the four areas. A table that is only ever read, and read rarely, is still the
one kind of thing that can stay in the window and cost no RAM at all.

**F5. Running gameplay code out of the window (TBD — the next lever, and it is
not needed yet).** `design_technical.md` 11.19 left the run area with 7,940
bytes, which is enough for the enemies, the mission flow and the static objects
that are still to be written. When it is not, the next lever is not another RAM
move: it is **executing cold gameplay code in place, out of the cartridge
window**, the way `BOOT` already does. That costs **2.5x** (measured, proto 01 —
`bootstrap.s`) and **zero RAM**, and there are 27 free banks.

It fits what is left to build, because all of it is low-frequency: a mission
script interpreter runs a handful of times a frame, spawn logic sporadically,
and sixteen enemies deciding at ~150 cycles each is 2,400 → 6,000 with the wait
states, 2.5% of a frame. What must stay at full speed is what already exists —
the per-object, per-frame loops.

Two things have to be settled before it is used, and neither has been measured:

* It is **mutually exclusive with the RAM under the window** (11.19): code
  executing there needs `CART_EN` set. So a routine that runs in the window
  cannot touch the object pool, and its own data has to be in the same bank or
  at `$A000`. Putting the interpreter and the level scripts in ONE bank makes
  that a feature — no bank switching at all inside the pass.
* ~~The rule that such code **may never re-bank the window it is executing
  from** has never been tested against the OS's `vgm_tick`, which re-banks from
  the IRQ.~~ **MEASURED, and it composes.** `src/music.s` puts a placeholder song
  in banks 5-8 and `tools/preview.py` now stands in for the VSYNC interrupt,
  firing `vgm_tick` at a different point in every frame so it lands where a real
  one would: **216 of 220 injections fell inside a `win_off` bracket, every one
  handed the window back the way it found it, and the 220-frame trace is
  byte-identical to the silent build.** So the player's `CART_SHADOW`
  save/restore covers `CART_EN` in practice and not only in `cpu_os.s`, and
  11.19's brackets are safe against the one thing that could break them
  asynchronously. Still untested is the REVERSE direction — an interrupt landing
  in code that is executing *from* the window — which is this question's own
  risk and cannot be measured until such code exists.

**F3. Music: how many tracks, how long (TBD).** The biggest single consumer of a
256 KB cartridge. If the campaign wants more music than fits, the options are a
512 KB part (the bank register reaches 1 MB, so it costs nothing in hardware) or
fewer/shorter tracks.

**F4. Save / continue / high score — settled 2026-09-18, moved to
`design_technical.md` 11.45** (no codes; unlimited continues on FIRE2, with
everything reset; the table keeps the game's best run, its sector and a
continued mark). Open: what the mark looks like, what
the ENDING LOST says when the continue is declined, and the score thresholds
for **a ship for points**.

**F6. Pickups — the open parts of `design_technical.md` 11.47 (TBD).**
Settled 2026-09-18: the laser drops from a killed pulsar only while the player
lacks it, its ammunition is Saturnium; the shield drops from every killed
spider; pickups home and are absorbed like Saturnium; two-frame sprites; the
laser and Saturnium survive a lost ship and a sector, a continue resets both;
a pickup stays until taken, 2 slots, a third replaces the older; rocks marked
in the level editor drop the shield too; Saturnium's pull at any distance, reusing `satn.s`. Open:

- **The two sprites' art** — ties to D2's sprite-step work.

**F7. Saturnium dust — a continuous energy resource from the smallest size
class only, separate from "clear the field" (TBD, from a design conversation
2026-09-16).** The idea: split "destroy the rocks" into two objectives that pay
out differently, instead of one shared counter.

- **Level completion stays exactly as F1 has it** — `rocks_left` over classes
  0-3, a percentage of the larger clusters, untouched by this. Nothing here
  changes what finishes a level.
- **Only the smallest class (4, already debris — design_technical.md 11.6,
  already excluded from `rocks_left` because the game removes it off-camera on
  its own, F1) pays a resource.** The larger classes pay nothing. That makes
  finishing off debris the one thing worth doing to it, and closes off farming
  by over-fragmenting a big rock for reward, since none of the intermediate
  classes it passes through on the way down pay anything. It also turns E9's
  performance worry (leftover debris crowding a cascade) into a player
  incentive to clean it up, alongside E10's engine-side safety net rather than
  instead of it.
- **Delivered physically, not as a menu pickup.** Not F6's collectible sprite —
  the existing hit-puff (`expl_at`) on a debris kill would live longer and home
  toward the ship, reusing the point-cloud pattern already shared by stars,
  motes and radar blips (`DOT_PIXELS`) rather than becoming a full physics
  object. A "thunk" (sound plus a visible pulse) fires on the frame it reaches
  the ship. Needs its own small capped pool, separate from the existing hit-puff
  slots (which stay one-frame effects for ordinary hits); overflow during a
  cascade is dropped silently, matching the project's existing overflow
  convention (`VIS_MAX`, PPRAM).
- **Spent on teleport and the laser.** Feeds the charge B1 already flags as an
  open hook ("a later collected, limited-charge boost/teleport" — `BOOST_AVAIL`
  is hardcoded to 1 today) and gives B9's open laser-cost question an answer
  that is not CETAS's separate ammo count: the beam draws from the same pool
  instead of, or alongside, it. Not decided whether teleport and laser share one
  pool or use two.
- **Read out as sparks on the hull, not a HUD number.** Charge shown as
  needle-like sparks/rays around the ship, denser at higher charge — the same
  diegetic-readout idiom already used for the shield (`dot_circle`, F6), so it
  costs no HUD text and no new HUD row (D5 is already tight).

Open: the exchange rate and every number in this (all TBM once something is
built), whether debris left alone truly self-clears at no cost to the player
(in which case ignoring it is a free choice, not a hazard), how the "clear the
big clusters" percentage for level completion is chosen, and whether the spark
readout needs its own GPU/VRAM budget check alongside the shield's.

**F8. New weapon ideas from a design conversation, 2026-09-16 (TBD).**

- **The laser's source — SETTLED, `design_technical.md` 11.47:** the
  pulsar (`src/pulsar.s`) drops it on death, while the player lacks it.
- **EMP — BUILT, `design_technical.md` 11.42** (`src/emp.s`, 2026-09-18):
  FIRE1 + FIRE2, 200 Saturnium, a `DOT_CIRCLE` off the hull growing 16 px a
  frame for 31 frames, and every enemy inside the radar's round test at `2n`
  high-byte units dies, whatever its hit points; rocks never. Still open, and
  only this: **the ring's GPU cost (TBM)** — madsim's F3 meter during an EMP.
  If it does not fit, the ring gives (every other frame, or stopped at the
  screen edge), not the kill.

- **A spread-shot upgrade for the blaster — flagged with a real constraint,
  not yet a number.** More pellets fired in a wider fan. B8 already notes the
  player's shot pool is 6 slots; a target of ~15 pellets in flight at once is
  2.5x that, and costs GPU vertex budget on top of it (C1's cull is already
  tight at 120 objects and 2x zoom). Needs measuring in madsim before any
  pellet count is promised — a fan of 4-5 pellets was suggested as a cheaper
  starting point to test the feel before spending the budget on more.

---

**F9. Enemy pool, cap and conditions - the mechanism for `design_technical.md` 11.49 (TBD).**
The rule is decided: an enemy budget in GPU cycles (proposed, a quarter of the frame),
kept by the LEVEL SCRIPT (the user, 2026-09-20): **a pool of enemies a level sends in
all, a cap on how many are alive at once, spawned one after another, each with a
condition** - "as soon as there is room" or something that has to happen first, such as
the level being cleared (then they are at the gate). What is open is how it is written
and run.

* **The level's records.** `levels.s` has, per level, an enemy list of seven-byte
  records read once by `load_foes` (position, kind, heading, speed). Proposed: a
  per-level **cap** (`LVL_FCAP`), and a record gets a **condition** byte with its
  parameter. Pool records wait as data, not as enemies; **the pool may be longer than
  the 16 enemy slots** (`FOE_MAX`), because only the living hold a slot. One record
  may stand for several enemies (a count), so that a pool of forty is not forty rows.
* **The conditions.** A first set, each a byte: *room* (the default); *after N seconds
  of the sector*; *the ship within R of a point* (a place); *the mission is done* (the
  gate has opened, `gate_open`); *the previous entry is dead* (a chain, for a scripted
  order). Which of these a level needs is what to decide first - the example the user
  gave, the ambush at the gate, needs only "the mission is done".
* **Where a spawned enemy appears.** At its record's position; for an entry that waits
  for the gate, at the gate (or on a ring round it, out of the ship's view, so that it
  arrives instead of popping up). A spawn **never happens on the screen**: a minimum
  distance from the ship, or the spawn waits. The radar and the enemy arrow (`cam.s`)
  show it from the moment it exists.
* **The cadence.** One after another with an interval (a second or two) so that two
  entries whose conditions come true together do not appear in one frame; the same
  interval keeps a kill from being answered by an instant replacement.
* **Missions.** `MS_FOES` (F1) is "every enemy dead": with a pool it must mean the pool
  empty **and** none alive. An ambush that waits for "the mission is done" cannot be
  part of the mission it waits for: which enemies are the mission's and which are the
  ambush's (a flag on the record)?
* **The editor.** `tools/level_editor.py` writes the cap and the conditions and flags a
  level whose cap times its dearest appearance is over the budget; that needs the
  cost table below.
* **What the player is told.** A message on the bar when the reinforcements come
  (`ENEMY DETECTED` already exists, `cam.s`), and a sound?
* **The camera.** `cam.s` frames the nearest enemy and pulls out for it, and every
  zoom-out puts more on the screen: with a cap, the zoom cannot be what brings the
  crowd, but does the budget still assume the widest zoom?
* **The cost table.** One number an appearance, measured by replaying a dump's
  command list on the GPU (as 11.49 did), stored beside `EN_R` in `enemies.s`, or
  worked out by the enemy editor from the vertex count. The clipping penalty is real
  (a UFO half off the edge cost 14.8 k for its hull against 9 k) and is not in a
  per-appearance number.
* **The CPU side.** The dump was at 80% CPU1 as well; `do_foes` was 10-19 k cycles for
  six UFOs. The same limiter that keeps the GPU inside its frame keeps the enemies'
  thinking bounded; is one budget enough, or two?
* **Cheaper enemies.** Not part of the mechanism but of the same budget: do not emit a
  part that is absent in its frame (one vertex, 1.4 k a command); fold the UFO's
  few-pixel detail parts into its hull. Together about a fifth of a UFO's cost.

## G. HUD & radar

**G1. Radar scale (SETTLED — fixed, independent of camera zoom).** The radar
does **not** zoom with the camera (4.4) — it always represents the same
world-unit radius, so its scale is a compile-time constant shift, not a value
that tracks the camera's zoom reciprocal. Rotation is still shared with the
main camera transform (the same per-frame `ROT[]` tables from
`design_technical.md` 4.5a); only the scale step differs, and it's simpler
than the camera's because it never changes.

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
bottom-RIGHT corner).** Simpler than the earlier rectangle proposal in every
way that matters here: the catchment test is rotation-invariant (G2), and
because the radar's scale never changes (G1), the on-screen result is
exactly a circle too — no ellipse correction, no separate per-axis bound.

It sat in the bottom-LEFT corner until the HUD arrived (D5). The two bottom text
rows run from the left margin, so the instrument had to vacate that side; it is
now portrait x 199..299, hard against the right edge, and the HUD's rows are
bounded at cell 23 by an assert in `hud_game.s` so the two cannot grow into each
other silently. Only `RADCY` moved (`radar.s`) and the ring bitmap followed it by
one constant, regenerated with `tools/bggen.py ... --at 199,298`. One thing the
move surfaced: pushed against the low edge, the occlusion disc's box origin goes
*negative*, and an unsigned byte reads that as 255 and walks the occluder band
list off its end — `radar.s` now clamps both ends of both axes, not just the high
ones.

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

## H. Death, screens and the flow between them

**H1. The screens the two-state machine is a placeholder for (TBD).**
`design_technical.md` 11.22 settles what happens when a life is lost and when
the last one is: the blink, the wreck, the banner, `game_start`. It settles
nothing about the **screens**. There is no title, no attract mode, no level
summary, no continue window, no hall of fame — and CETAS has all five, each
with its own bitmap, its own song and its own typewriter. Today's "GAME OVER /
PUSH FIRE TO RESTART" is two lines of background text over the still-running
field, and it restarts a whole new game from level 1 with a fresh score.

That is deliberate. What is fixed is the SHAPE — one `GSTATE` byte and one
`game_start` entry point — so the screens can be attached without unpicking the
frame loop first. **How to settle:** with F1, because a level summary and a
mission-complete screen are the same machinery, and it is worth building all of
them once rather than the game-over one alone.

**Decided 2026-09-15 (the user), not yet built:**

* **The states:** an INTRO played once after power-on; a TITLE with a scroller
  along the bottom, cycling through ATTRACT panels (the enemies, the hiscores,
  a demo); the five LEVELS, no bosses; a STORY screen between levels; two
  dedicated ENDINGS, won and lost; HISCORE sign-up. Today's GAME OVER / PUSH
  FIRE banner is a placeholder for the lost ending and goes when it arrives.
* **Story screens are bitmaps, and may differ per level.** None exist yet. They
  go to the background COMPRESSED — `gpu_rect_bg_begin` / `gpu_rect_bg_cart`,
  RLE bands decoded by the GPU (MAD-65 CPU OS, *The transport block*) — so the
  art costs cartridge banks and no CPU1 RAM at all. The bank count (32) is what
  a picture per level spends.
* **The attract DEMO is recorded play, replayed without the HUD** — a stretch of
  a later level. Cheap in RAM if it is what it sounds like: the game engine is
  already resident, and the recording is a few joystick bytes a frame fed into
  `input.s`'s one reader (`JOYIN`/`JOYINP`/`JOYINV`) from a level loaded with its
  own seed. **The catch to plan for:** a replay is only a replay while the
  simulation is bit-identical, and physics is expected to be re-tuned many
  times, so a recording desyncs silently on the next tune. It wants a
  re-record tool, and a `preview.py` check that a replay still ends where it
  was recorded to.
* **The screens' code is not resident** — the run area and upper RAM have a few
  hundred bytes between them. The plan is CETAS's overlay (`states.s`
  `load_uicode`): screen code in its own banks, copied to `CART_HIRAM` at a
  state change, split by when it runs (INTRO once; TITLE + ATTRACT + sign-up;
  STORY + ENDINGS). `api_decrunch` can take LZ-packed overlays at 73–95 cycles
  per byte, so one is a loading frame or two. **Open:** how an overlay shares
  `$C000` with `CODE5` (`cam.s`), which the demo needs as much as play does —
  sized beside it, or reloaded on entry to play. **TBM:** what a load costs.
* **Hiscores live in KEEP**, `$DF00-$DFFF`, the page `cart.cfg` holds back from
  `CART_HIRAM`: seeded once by `cart_init`, never by `game_start`, so the board
  outlives a game and lasts one power-on. Built — `src/hiscore.s`.
* **Built 2026-09-15: the INTRO and the TITLE** (`src/screens.s`). Power-on is
  `SC_INTRO`: black, the MAD-65 logo, MISSION / ASTEROID / DESTRUCTION one on
  each of the song's opening ticks (every 28 frames); then the blinder, the
  title picture streamed in under it and shown on frame 225, where the song's
  chords come in (3.733 s) - constants read off the song once, not synced to
  it; and a marquee (`src/scroller_text.s`, plain ASCII) on the bottom line; FIRE starts a
  game. Both pictures go out as RLE bands through
  `RECT_BG_BEGIN` / `RECT_BG_CART` (`tools/artgen.py`, banks 5-6, 15-row bands,
  batches of four every OTHER frame, `ART_BATCH`). The GPU's TIME binds, not
  PPRAM: a 15-row band costs it ~49,000 cycles to decode, so five in a frame
  (the first cut, which PPRAM allowed) measured 252,717 cycles, 106% of the
  GPU's frame - the last band never landed and left a black bar down the
  title's left side. Four is ~90%, and the frame after a batch carries only its
  replay. Every future story screen obeys the same arithmetic. The screens' code is `UICODE`, loaded
  at boot into `CART_HIRAM` behind `CODE5` — resident for now, not yet an
  overlay — and its state is in KEEP. The title-theme sketch plays from
  power-on as a stand-in (`MUSIC_ON` = 1, banks 7-8). Still open: game over
  goes straight back into a game rather than to the title, and a frame of the
  title picture shows under the first frame of flight.
* **Decided 2026-09-18: the tunnel comes after EVERY sector** (11.45), short, and it cannot kill — see H6 for what is in it. Superseded wording: a short in-between STAGE after some levels — a
  mini-game, flying a tunnel. If it comes it is its own state with its own
  code, so it is one more overlay, not resident code, and it has to be weighed
  against the same `CART_HIRAM` room as the screens.
* **Built 2026-09-18: `SC_SECTOR`, the tunnel's placeholder** (`src/gate.s
  sector_frame`). Flying into the exit gate is SECTOR COMPLETED on black, FIRE
  after 1.5 s, and FIRE is `level_begin` — the next sector with the score, the
  ships and the Saturnium carried. The tunnel replaces this state's frame and
  nothing else. **Proposed, not decided:** it is built in `src/` as its own
  state and file, not as a separate program (CLAUDE.md: no `proto/04`), with a
  build switch that boots straight into it for testing, and a `preview.py`
  bench; its code is a SWAP overlay — while it flies, nothing of the field's
  code in `CART_HIRAM` (CODE5/CODE6) is needed, so the tunnel is copied over it
  and the resident code copied back before the next sector loads, and the
  object pool under the window is free scratch for it, since `level_begin`
  rebuilds the field afterwards anyway.

**H2. The wreck's numbers (TBM, and being flown).** `DEBRIS_FRAMES` 120,
`DEBRIS_K` 11, `DEBRIS_JIT` 32, `DEBRIS_SPIN` 2 (`src/debris.s`). It has already
moved twice — 45/28/64/4, then 60/21/64/4, now this — and the lesson each time
was that the four are **one setting**: `design_technical.md` 11.22 gives the two
formulas that tie them, and halving `K`/`SPIN` while doubling `FRAMES` is what
"slower and longer" actually means. **How to settle:** keep flying it in madsim;
the shape of the break-up comes from `SHIP_SHAPE` itself, so these four numbers
are the whole of what there is to tune.

Two known simplifications, both deliberate and both documented in the file:

* **The spread is not scaled by the zoom**, only each piece's own shape is (the
  GPU's `SCALE`). `smul16q7` cannot take 128 — its magnitude is seven bits — so
  correcting it needs the reciprocal-table treatment, for an error that is
  shrinking to nothing anyway while `ZEASH` eases back to 1:1 over exactly those
  frames. Revisit only if a death ever has to happen at a held zoom.
* **The explosion is still the rock's puff.** A sprite explosion at the ship's
  centre was asked for and is not built; the wreck currently opens with the same
  `expl_at` cloud a rock hit throws off. That is a sprite-authoring job, not an
  engine one. The SOUND of it is no longer a placeholder — three layers, see
  `design_technical.md` 11.22 — so the picture is now the half that is behind.

**H4. What else wants the voice arbiter (TBD).** Making the claim per voice
(`sfx.s` `VPRI`/`VLEN`, `design_technical.md` 11.22) settled the loss tune being
cut, and it is the mechanism anything long will need: an enemy's warning sound,
a level's opening sting, a boss. **Open:** whether `PRI_DEATH` should stay the
only thing above `PRI_BOOM`, or whether the scale needs a band for "narrative"
sounds that outrank gameplay feedback but yield to a death. Decide when the
first one exists, not before.

**H3. The death path is not in the headless bench (TBD, and it should be).**
`tools/preview.py` flies 220 frames and never rams anything hard enough to die,
so every check it makes is a check on a living ship. The break-up, the blink,
the banner and the restart were verified by a throwaway probe built on the same
harness — it poked `LIVES` and called `ship_die` through the real code, then
watched the command list — and that probe is gone. It confirmed: four OPEN
polygons of 6/3/6/3 vertices for exactly `DEBRIS_FRAMES` frames with no ship
outline and no flame sprite, no piece left with a zero tumble, `GS_OVER` on the
frame after them, the banner appearing at cell 14 of row 24 one frame later and
alternating its two words at exactly 64-frame gaps, and FIRE restoring the ship and blanking the banner on the same frame. It
also found the off-by-one that made the wreck 59 frames long, which is the kind
of thing only a bench finds.

**How to settle:** a second short run appended to `preview.py` after the main
one. The thing in the way is that the probe hardcoded `ship_die`'s address,
which moves on every build, and `preview.py`'s whole discipline is to parse
addresses out of the source instead. Either export the handful of labels a bench
needs, or have the Makefile emit a label file beside `map.txt`.

**H5. Radio messages (decided 2026-09-18, moved 2026-09-20 — not built,
`design_technical.md` 11.45).** The radio is in the TUNNEL between sectors
(H6), not a HUD line during play: Control and the other ships talk in the
debrief of the sector just flown and the brief for the next, in the text area
under the tunnel's window, strings in the HUD-message bank. In flight the
message bar keeps what it has. Open:

* How the text shows in the tunnel: whether it types itself out, how long a
  line stays, whether the minute holds two or three lines, and whether the
  radio's text is fixed per sector or assembled from what happened in it.
* **The triggers, now a record and not an event.** A debrief has to know what
  the sector held: a ship lost, a foe seen, the station reached. So the sector
  keeps a few flag bits during play (RAM to spend) and the tunnel reads them;
  the brief for the next sector is per-sector script data in `levels.s`'s bank
  (`LEVELS`), beside the level's other tables.
* **What the fiction lost by it.** Two beats were written as radio in flight and
  no longer have a place there: 4-1's fragments of a distress call with an
  unsure bearing, and the station's crew talking (11.46), which in 4-3 would be
  heard only after the siege, in the tunnel that follows it. They move to the
  briefing of L4 and to the tunnel after 4-1 and 4-2 (the approach), or are
  told some other way; the author's call.

**H6. The tunnel — what it is is settled (`design_technical.md` 11.45), its
numbers are not (TBD/TBM).** After every sector (after x-3, before the level
briefing): about a minute, no death, a 300 x 300 pseudo-3D window with the
instruments and the radio's debrief/brief under it. The joystick leans the ship
in eight directions inside an invisible tube, and no button does anything.
There is one lifepod for each ship lost in this sector. A rock hit costs all
the Saturnium collected in this passage, never a pod. Open:

* The lean (it springs back to the centre, 11.45): its range, and how fast
  it leans and returns (TBM).
* The seeded generator (11.45): how it makes sure a pod is always reachable,
  and the density per level.
* Whether "all the Saturnium" is too harsh once flown (first setting, 11.45).
* Per-level variety as foreshadowing (candidate): L1 clean ice, L2 a
  silhouette that flickers and is gone, L3 wrecks of SRVs, L4 shadows pacing
  the ship, L5 the tunnel folding back on itself.
* Its music.
* **Cost (TBM):** perspective is a 1/z table, rocks are the GPU's scaled
  shapes, the stars `DOT_PIXELS`; the code is a SWAP overlay (H1). A 300 x 300
  window also means only part of the screen is redrawn, so the clear or the
  background layer may be cheaper than in flight.
