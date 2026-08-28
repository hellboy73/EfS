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
unknown. The bench now ships eleven, chosen by hand while flying it: `-150, -100,
-50, 0, +50, +100, +150, +200, +250, +300, +350` px/s. Still being felt out.

**B2. Turn rate (TBM, narrowed).** Flying the bench settled the band: **1 to 3
brad per frame is usable**, and the original "1/32 of a turn per frame" (8
brad/frame, 531 ms per revolution) is far too fast. Whole-brad steps inside that
band turned out to be too coarse to choose between, so the heading now carries a
fraction and the ladder is `5659, 4244, 3396, 2830, 2425, 2122, 1698, 1415` ms per
revolution. Still open: which one, and whether the ladder wants finer steps still.

**B6. How strongly should the turn rate follow flight speed (TBM)?** Turn radius
is `v/omega`, so a constant omega makes the radius grow in proportion to speed -
at +350 the ship sweeps a circle seven times wider than at +50. Doubling the rate
at top speed (the first cut) **rose too fast to fly**, so proto 01 now has a
strength dial on joystick 2's button: OFF / x1.12 / x1.25 / x1.50 at the top
tier. Open: which, if any. Full proportionality (constant radius) is certainly
too much - it leaves the ship barely able to turn at low speed.

**B3. Camera lag constant (TBM).** Half of it is now in proto 01: the ship's
screen offset eases toward its tier's target by 1/16 of the gap per frame
(`SHOFF_LAG`). The zoom half is still missing because there is no zoom yet. Too
fast is nauseating; too slow disconnects the throttle from the view, and both
halves should probably share one constant.

**B4. Visual bank angle while turning (TBD).** How much the ship tilts, and whether
it is a sprite swap (cheap, a handful of frames) or a real small rotation.

**B5. 32 headings or 256 (TBD).** The design assumes 32. Proto 01 deliberately
runs at 256 so the difference can be seen: with the ship always drawn nose-up,
the only place the choice shows is the smoothness of the world's rotation. If 32
is not visibly steppy it is free; if it is, the design should say 256.

---

## C. Camera and zoom

**C1. Zoom range (TBM — 2x is in and flying).** Reference zoom is 16 units/px
at standstill. Proto 01 now ramps to **2x out at the top tier**, per speed tier
and eased, and the whole curve is one line (`ZOOM_RZ` in `main.s`), so 3x or a
step at +150 is an edit and not a rewrite. What that costs is measured: the
visible-object count scales as the **square** of the zoom, so 2x out means ~4x
the objects through the cull, and it took `NOBJ` from 200 down to 120 to keep the
worst frame under budget (218,200 cycles, 92%). 3x would be ~9x and needs the
spatial bucketing of E1 first. Constrained by C2.

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

**D3. Clipped polyline GPU opcode (TBD — now with numbers).** Whether to add an
`N`-point clipped polyline to the MAD-65 GPU firmware. This is a **firmware**
change in the MAD-65 repo (new opcode + builder + jump-table entry + py65 test),
so it needs to be worth it. Proto 01 measured the per-edge path:

- **PPRAM is not the argument.** A whole frame of the bench is 281 bytes of the
  2047-byte list, 14%. Halving the outline traffic buys nothing that is scarce.
- **CPU1 cycles are.** `gpu_dotline_clip` costs **~3,000 cycles a call** — it is
  a real Cohen-Sutherland with a divide per crossing. Sending every edge of
  every rock through it put a 7-rock frame ~15% over budget on its own.
- **Most of that is avoidable in the cartridge.** Proto 01 emits a rock wholly
  on screen as one unclipped `DOT_LINES` chain, and for a rock that straddles an
  edge computes per-vertex outcodes and sends only the segments that actually
  cross to the clip builder — both-ends-inside goes to plain `gpu_dotline`
  (~200 cycles), both-ends-past-the-same-edge is dropped for free.

So the question is no longer "would a clipped polyline save PPRAM" (it would,
and it does not matter) but **"can it clip a chain for less than ~3,000 cycles a
crossing edge"**. If the answer is no, the outcode pre-pass in the cartridge is
the cheaper fix and the firmware stays as it is.

**D8. Star size and lattice (TBD).** `DOT_PIXELS` draws single pixels but takes
half-res coordinates, so stars land only on even framebuffer pixels - a 2-pixel
lattice, which is also the finest step the field can scroll by. `PIXEL` ($40)
would give full-res placement at 5 PPRAM bytes per star and one dispatch each,
against 2 bytes in a single batched call. Only worth it if the lattice reads as
chunky on a real screen.

**D9. Star layer size (SETTLED — park, do not fold).** A 256 × 256 layer rotates
to a view radius of up to 181, which does not fit the byte the view position is
stored in; folded stars are drawn at the wrong screen edge sweeping against the
turn. Stars that do not fit are now parked (all are off-screen anyway) and a
refresh un-parks them before the field scrolls past the 27-pixel margin. See
`design_technical.md` 5.3. What stays open is whether a *denser* layer is wanted
(see D4) — that is a separate question from this one.

**D10. Mote count and look (TBD).** The near layer runs 16 specks (about 7 on
screen) at twice the ship's speed. They are single pixels, exactly like stars, and
are told apart only by how fast they move - a short streak would read as speed
more strongly but costs a line instead of a point. Open: how many, and whether
they should be streaks.

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

**D6. Star occlusion behind asteroids (SETTLED for now — naive disc test).**
Rocks are dot-line outlines and are therefore hollow; stars must be suppressed
where a rock covers them or the rock reads as a wire hoop. Proto 01 does the
naive per-star × per-rock test, with a clamped bounding box as the cheap reject
and the quarter-square table doing the squares, and it costs **~3,000 cycles on
a median frame, ~6,000 on the worst** — 1.3% and 2.5% of budget at 40 stars and
up to 13 occluders. Good enough; folded into `design_technical.md` 5.4 along
with the leak/halo measurement that sets the suppression radius at the shape's
**mean vertex radius**, not its bound.

What stays open: the **coarse occlusion mask** (rocks + stars instead of rocks
× stars, 60 bytes at 8 × 8 half-res pixels per cell). It only starts to pay
when the product grows — zoom-out puts more rocks on camera and fragments
multiply them — so it is a **(TBM at 20+ rocks)**, and its resolution is a
**(TBD)**. Also open: whether the suppression radius and the **collision radius**
are literally the same number (5.4 argues they should be).

---

## E. Objects and physics

**E1. Object pool size (TBM, now with a real number).** Proto 01 measures
**~290 cycles per object per frame** for integrate + cull alone — ten times this
document's first estimate, because a 16.8 position plus an 8.8 velocity makes one
axis a 24-bit add. So 250 objects cost about **70k cycles, 30% of one CPU**, and
the whole bench (110 stars, 250 objects, a five-line HUD, the occlusion pass) runs
at **70% in its worst frame** and uses 250 bytes of the 2047-byte PPRAM list.

That makes ~250 the working ceiling unless the per-object cost comes down. Levers,
cheapest first: reject on the high byte of the delta before the precise cull
(done, ~7%); drop the fraction byte from positions that do not need sub-unit
drift; amortise the cull across frames. The collision broad phase has not been
measured at all yet and will add to this.

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
