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

**A3. Does the world differ per level (TBD)?** Same size every level, or larger
worlds later? Larger worlds cost nothing structurally (the unit is per-level data)
but change pacing.

---

## B. Ship handling — the first prototype

**B1. Number of speed tiers and their values (TBM).** The single most important
unknown. Prototype in madsim with a debug overlay: try 4, 6 and 8 tiers, plus one
reverse tier. Measure in screen-heights per second at reference zoom, not in
internal units.

**B2. Turn rate (TBM).** How many frames to swing 32 headings (a full turn), and
whether the rate depends on speed (slower turning at cruise reads as mass). Must be
tested *together with* B1 — the pair is what "handling" means.

**B3. Camera lag constant (TBM).** How fast zoom and ship screen-Y follow a speed
change. Too fast is nauseating; too slow disconnects the throttle from the view.

**B4. Visual bank angle while turning (TBD).** How much the ship tilts, and whether
it is a sprite swap (cheap, a handful of frames) or a real small rotation.

---

## C. Camera and zoom

**C1. Zoom range (TBM).** Reference zoom is 16 units/px at standstill. Top-speed
zoom of 32 (2x out) vs 48 (3x out) vs 64 (4x out) changes how small objects get and
therefore where the sprite LOD crossover has to sit. Constrained by C2.

**C2. Legibility floor (TBM).** At maximum zoom-out, is a small asteroid still
readable in 1-bit at 300 x 400? This sets the hard limit on C1 and is a
look-at-the-screen decision, not a calculation.

**C3. Ship screen-Y range (TBD).** Baseline: centre (150, 200) at rest, down to
around y = 320 at top speed, up to around y = 120 in reverse. Needs the same
prototype as B1.

**C4. Zoom quantisation (TBD).** Zoom is conceptually smooth, but if the sprite LOD
set is small the *sprite* scale must snap to the available sizes while vector
geometry stays continuous. Decide whether mixed continuous/snapped scaling looks
wrong on screen.

---

## D. Rendering

**D1. Vector/sprite LOD crossover (TBM).** The on-screen size below which an object
stops being a transformed polygon and becomes a pre-scaled sprite. Depends on the
measured cost of both paths.

**D2. Number of pre-scaled sprite steps (TBD).** How many sizes per object type,
which multiplies sprite ROM.

**D3. Clipped polyline GPU opcode (TBD).** Whether to add an `N`-point clipped
polyline to the MAD-65 GPU firmware. Would roughly halve PPRAM traffic for asteroid
outlines versus per-edge `gpu_dotline_clip`. This is a **firmware** change in the
MAD-65 repo (new opcode + builder + jump-table entry + py65 test), so it needs to
be worth it — measure the per-edge path first.

**D4. Star layers (TBM).** How many parallax layers, how many stars per layer, and
their parallax factors. Cost is one `gpu_dotpixels_clip` per layer plus the point
list build.

**D5. HUD placement in portrait (TBD).** 300 x 400 is tall and narrow; the HUD
competes with look-ahead. Background layer (free) vs image layer (costs per frame).

---

## E. Objects and physics

**E1. Object pool size (TBM).** 64? 96? 128? Bounded by the collision broad phase,
not by integration. Needs a worst-case measurement with everything on screen.

**E2. Sector grid resolution (TBD).** 16 x 16 sectors of 256 px is the baseline; a
sector must be larger than the biggest asteroid or the adjacency test misses
contacts.

**E3. Size classes (TBD).** How many asteroid sizes, their radii, and the mass
curve across them. Drives both physics and the LOD table.

**E4. Restitution, spin gain, split impulse, break-up threshold (TBM).** The whole
tuning surface. These get their own iteration loop once the physics runs at all —
see [`physics.md`](physics.md).

**E5. Do asteroids collide with each other every frame, or on a budget (TBD)?**
If E1 grows, pair testing may have to be amortised across frames (test half the
sectors per frame). Acceptable only if it does not produce visible pass-through.

**E6. Enemy roster (TBD).** Types, behaviours, whether they obey the same physics
as rocks or fly under their own control.

---

## F. Content and structure

**F1. Number of levels and mission types (TBD).** Waiting on the story.

**F2. Bank map (TBD).** The draft in `design_technical.md` section 10 is a guess.
Real allocation follows real asset sizes — music is usually the surprise (in CETAS
one song was 11 banks).

**F3. Music: how many tracks, how long (TBD).** The biggest single consumer of a
256 KB cartridge. If the campaign wants more music than fits, the options are a
512 KB part (the bank register reaches 1 MB, so it costs nothing in hardware) or
fewer/shorter tracks.

**F4. Save / continue / high score (TBD).** The console has no persistent storage;
decide what a "campaign" means across a power cycle (level codes?).
