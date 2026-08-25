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

## B. Ship handling — proto 01 is built, now it has to be flown

[`proto/01_flight`](../proto/01_flight/) puts all of B1-B3 on a joystick with a
live readout. **These stay open until someone flies it and says which values are
right.**

**B1. Number of speed tiers and their values (TBM).** The single most important
unknown. The bench ships ten: `-60, -30, 0, +15, +30, +60, +121, +181, +271,
+392` px/s, with the top tier crossing the 400-pixel screen in about a second.
Judge in screen-heights per second, not internal units.

**B2. Turn rate (TBM, narrowed).** Flying the bench settled the band: **1 to 3
brad per frame is usable**, and the original "1/32 of a turn per frame" (8
brad/frame, 531 ms per revolution) is far too fast. Whole-brad steps inside that
band turned out to be too coarse to choose between, so the heading now carries a
fraction and the ladder is `5659, 4244, 3396, 2830, 2425, 2122, 1698, 1415` ms per
revolution. Still open: which one, and whether the ladder wants finer steps still.

**B6. Should the turn rate follow flight speed (TBM)?** Turn radius is `v/omega`,
so a constant omega makes the radius grow in proportion to speed - at top speed
the ship sweeps a circle seven times wider than at a crawl. Proto 01 has a toggle
(joystick 2's button): `rate x (1 + xtra/128)`, unchanged at a standstill and
doubled at top speed, which halves the growth. Open: whether coupling is wanted at
all, and if so how strong. Full proportionality (constant radius) is probably too
much - it makes the ship almost unable to turn at low speed.

**B3. Camera lag constant (TBM).** Not in proto 01 (there is no zoom yet). How
fast zoom and ship screen-Y follow a speed change. Too fast is nauseating; too
slow disconnects the throttle from the view.

**B4. Visual bank angle while turning (TBD).** How much the ship tilts, and whether
it is a sprite swap (cheap, a handful of frames) or a real small rotation.

**B5. 32 headings or 256 (TBD).** The design assumes 32. Proto 01 deliberately
runs at 256 so the difference can be seen: with the ship always drawn nose-up,
the only place the choice shows is the smoothness of the world's rotation. If 32
is not visibly steppy it is free; if it is, the design should say 256.

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

**D8. Star size and lattice (TBD).** `DOT_PIXELS` draws single pixels but takes
half-res coordinates, so stars land only on even framebuffer pixels - a 2-pixel
lattice, which is also the finest step the field can scroll by. `PIXEL` ($40)
would give full-res placement at 5 PPRAM bytes per star and one dispatch each,
against 2 bytes in a single batched call. Only worth it if the lattice reads as
chunky on a real screen.

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

What is still open: **how many lines** (each one added slows every other line
down — a fourth makes it 8 frames), and **where** they go, since 300 x 400 is
tall and narrow and the HUD competes with look-ahead.

**D6. Star occlusion behind asteroids (TBM).** Rocks are dot-line outlines and are
therefore hollow; stars must be suppressed where a rock covers them or the rock
reads as a wire hoop. Naive per-star × per-rock testing vs a coarse disc-rasterised
occlusion mask — see `design_technical.md` 5.4. Measure the naive version first so
the mask has a number to beat. The mask resolution (8 × 8 half-res pixels per cell
= 60 bytes) is itself a **(TBD)**.

---

## E. Objects and physics

**E1. Object pool size (TBM).** 64? 96? 128? Bounded by the collision broad phase,
not by integration. Needs a worst-case measurement with everything on screen.
Proto 01's baseline to build on: 110 stars + 7 transformed objects + a six-line
HUD + the occlusion pass = **30% of one CPU's frame**, and **250 bytes of the
2047-byte PPRAM list**. Whatever asteroids cost, that is what they are competing
with.

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

**E6. Enemy roster (TBD).** Types and behaviours. The story fixes the *shape* of
what is needed (see `story.md`): a **cloak state** (visible/invisible while still
simulated), and **patrol / detect / pursue / lose-track** behaviour with a detection
radius. Still open: how many distinct alien types, whether they obey the same
collision physics as rocks or fly under their own control, and how they are armed.

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
