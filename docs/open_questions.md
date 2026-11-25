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

**E12. CPU1 overload — a degraded mode driven by `FRAME_POS` (TBD; raised
by the user 2026-09-22, plan agreed 2026-11-24, nothing built).** Some scenes
cannot be prevented: the player multiplies rocks (E9's split cascade) or
otherwise makes a frame CPU1 cannot finish. The GPU side already degrades
gracefully (the list below). CPU1 does not: **a CPU1 frame overrun is not
something to recover from, it must not happen.** The goal is to see the
deadline coming, close the frame's list normally, and make the next frames
cheaper.

**The governing rule: smoothness above everything** (the user, 2026-11-24).
Every visible cost of degrading - a missing starfield, a closer camera, a
rock that pops to a simpler outline, rocks passing through each other, a
split with one child - is preferred to a single skipped frame, on either
CPU. Weigh every fuse and threshold below against that, not against how
the degradation looks.

*The signal.* `FRAME_POS`, `$BF80`, a proposed MAD-65 hardware register
(MAD-65 `docs/MAD65_future_features.md`, not built): PHI2 cycles since the
frame edge ÷ 1024, reads 0..231, one step ~0.43% of a frame, saturates at
`$FF`. It restarts at every edge, so after an overrun it reads LOW - always
read it FIRST and `VSYNC_FLAG` second (the doc's trap). madsim must model it
(`min(255, cycles >> 10)`) and preview.py/py65 need an I/O hook returning a
deterministic value before any cartridge reads it.

*The frame order: a cuttable tail.* `do_stars` and `do_motes` sit in the
middle today (after `WS_FRAME`, main.s) only because they need the occluder
list complete; their output goes out in `emit_stars`/`emit_motes` at the end.
Their compute moves to after `do_hud`, still inside the `win_off` bracket.
Then:

```
[fixed]           frame_services, ring, hud_tick, state, input, camera, ship
[simulation]      do_objects, emit_asteroids, shots, foes, explosions, WS_FRAME
[mandatory tail]  emit_ship .. do_shield, do_hud
-- CHECKPOINT: FRAME_POS (then VSYNC_FLAG) >= threshold -> skip below, set DEGR
[cuttable]        do_radar, do_stars, do_motes
[emit, always]    emit_radar, win_on, emit_stars, emit_motes
```

Cutting is nearly free: `DOTBUF`, `MOTEBUF` and the radar pages (`$68xx`,
`RADN`) survive the frame, so a skipped compute re-emits last frame's result
(stars still one frame, radar one frame late) - no hole, no extra code past
the skipped `jsr`s. The threshold is `231 - (cost of the emit block) -
margin`, measured. One checkpoint, inline (~11 B: `lda FRAME_POS / ldx
VSYNC_FLAG / bne / cmp # / bcs`), no shared routine - code space is short.

*The guarantee's condition.* The checkpoint only saves what stands after it.
Worst case of everything before it plus the mandatory tail must fit the
frame: the degraded mode below is what keeps the next frames there, and the
worst case is a measurement (a laser soak through a packed field, F2 dump,
per-phase profile - `efs_dump_profiling`), not a guess.

*`DEGR`: how long degraded lasts.* A counter, not a bit. Every cut sets it to
H; every frame without a cut decrements it. H starts ~60 frames (1 s); a cut
that comes back soon after leaving doubles H, up to ~4 s, so the mode does
not flap (stars blinking on and off each second would be worse than four
seconds without them). A degraded frame measures the DEGRADED load, so a low
reading is not proof a full frame would fit - hence time, not load, decides
the exit.

*What a degraded frame does (each test is a few bytes where it is used):*

| fuse | where | cost |
|---|---|---|
| checkpoint + `DEGR` with hysteresis | end of frame | ~20 B |
| no stars at all: skip `do_stars`, `STARN = 0`; on exit zero `BASEHEAD` so the first frame back does `star_rebase_full` | stars.s | ~5 B |
| zoom in: `bit DEGR` into `cam_rockbrake`'s brake branch | cam.s | ~4 B |
| **a split makes ONE smaller rock, not two** - population stops growing, the cascade is defused at its source | shots.s | ~12 B |
| no rock-rock collisions (ship-rock and bullet-rock stay) | physics.s `do_collide` | TBM |

- *Stars*: their occlusion pass is the part that grows with objects on
  screen; dropping the layer removes it entirely.
- *Zoom*: the cull window follows the zoom and rocks outside it are frozen,
  so zooming in cuts what CPU1 moves, collides and emits - not only what the
  GPU draws. It does not shrink a cascade at the ship, which is what the
  split fuse is for.
- *One-child split*: in `rock_destroy` skip `rock_alloc` (and so
  `rock_recycle`) and mark `SPL_S = $FF`; `rock_split` skips the second
  `spl_one`. The reward is unchanged (`rock_score` runs before the split).
  The lone child is the "+" one, so it keeps `SPLIT_OFF`/`SPLIT_V`'s sideways
  kick with nothing to balance it - judge in madsim whether that reads as
  recoil or needs zeroing. The smallest class already turns to dust (that
  IS the reward) and is untouched.
- *No rock-rock collisions*: rocks pass through each other briefly in a busy
  scene; on exit the separation push (`n >> PHYS_SEP_SH`) parts the pairs
  that overlap - check it does not pop. Price `do_collide` in the heavy-scene
  dump first.
- Rocks OFF screen do not matter here: the cost is in the ones on screen
  (emit, occlusion, collision).

*Rejected:* radar every other frame as a standing rule (only spreads the
average unless something else uses the freed frames; skipping it on a cut
frame is what helps); reduced rock shapes as a CPU fuse - a vertex costs
CPU1 ~30 cycles of copying, so ~200 a big rock, nothing for CPU1.

*GPU-initiated degradation draws simpler rocks (the user, 2026-11-24).*
The reduced shapes ARE a GPU lever, so they belong to the GPU's own
degradation, not `DEGR`: when the GPU side trips - the same signal as
`cam_rockbrake`, `ABUDGET` nearly spent last frame - `one_asteroid` draws a
rock's authored reduced outline (`SHAPE_LODLO`/`SHAPE_LODHI`) wherever
`SHAPE_LODN` is non-zero, instead of the full one. 5-6 vertices fewer is
~9-11 k GPU cycles a 192/128 rock, and every vertex saved is budget the
rocks after it in the visible list get, so fewer of them are dropped. The
data is already there (shapes.s; retired from the flight code by 11.9, still
used by the tunnel's far rocks); the switch is ~15-20 B. Only the 192 and 128
classes have reduced outlines - authoring them for 64 (9-11 vertices) is what
would extend it to a cascade's mid-size rocks. It runs **alongside the zoom
brake, on the same trip** (the user, 2026-11-24) - not first with zoom held
back for later. A rock changing outline as the mode switches is a visible
pop, and it is **accepted, not hidden** (the user, 2026-11-24): it is far
better than a skipped frame, and hiding it would cost code for nothing.

*A second GPU trip: the GPU's real overrun, `GPU_LAST` (the user,
2026-11-24). The OS side is BUILT: `GPU_LAST` = `$0279`, published,
read-only (MAD-65 `MAD65_CPU_OS.md`, "Frame budget & overrun"); `$00` until
the first `gpu_begin`. The zoom brake's trip is BUILT too (2026-11-24,
`cam.s cam_rockbrake`, +21 B of CODE5): each frame `GPU_LAST` reads
`GPU_WORKING` takes a rung in and sets `RBHOLD` ($73BF) to `RB_HOLD` = 60;
ZCAP does not relax until the hold has run out. The simpler rocks are not
built yet. TEMPORARY: `DBG_BRAKE` (main.s, = TRAINER) shows one letter on
the background, line 3 cell 36 - G holding after a GPU overrun, Z ZCAP above
0, blank off (cam.s `dbg_brake`, 59 B, out of the demo build).*

*The pipeline, and what was decided about it (the user, 2026-11-24).* List N
is built in N, drawn in N+1 and its verdict reaches CPU1 in N+2, so list N+1
is built blind: **at least two GPU overruns are unavoidable** before any
reaction, and the brake's eased zoom (`ZOOM_LAG`, 1/16 of the gap a frame)
takes many more frames to bite. Decided: **the zoom stays smooth** (no snap);
**the rocks degrade at once on detection** - the simpler outlines go on in
the frame `GPU_LAST` trips, since `one_asteroid` runs after `cam_foe` (not
built); and for the frames in between, the list order is enough - the GPU
drops the tail of the list (backdrop first), which is what the order is for.
Known and left alone for now: the `$B1` of list N+1 arrives after the
reaction and takes a rung of its own. `ABUDGET` is an estimate made
in advance - the rocks' vertices against a fixed `AST_NONROCK` for everything
else - so a GPU frame lost to enemies, the base, explosions or anything the
constant under-prices never trips it, and CPU1 cannot see the GPU's own
`OVERRUN_CNT` (GPU RAM). The fact itself is in PPRAM: the GPU writes
`GPU_WORKING` (`$B1`) into `PP_STATUS` when it starts a list and `GPU_READY`
(`$B2`) at its `WAI`, so a chip handed back to CPU1 still holding `$B1` is a
list the GPU did not finish (a frame with no `CPU_READY` leaves `$B2`, so the
two never mix). `gpu_begin` copies that byte to `GPU_LAST` before it writes
`CPU_WORKING` over it. Then the zoom brake and the simpler rocks trip on
EITHER `ABUDGET` nearly spent (ahead of time) OR `GPU_LAST = $B1` (measured,
two frames late: list N comes back to CPU1 in frame N+2) - ~6 B in
`cam_rockbrake`, and the measured trip holds the brake for a while, like
`DEGR`, instead of releasing it the next frame. It cannot save the first lost
GPU frame; it stops a run of them for as long as a heavy scene lasts.

*The GPU's existing protection, for reference:* the rock vertex budget
`AST_BUDGET`/`ABUDGET` with the `AST_MAX` count cap (objects.s
`emit_asteroids`); the zoom brake `cam_rockbrake`/`ZCAP` off `ABUDGET`; list
order as priority under "the new frame wins" (background commands first,
stars and motes last); the radar's own priority and `RAD_MAX` truncation; the
HUD's 6-frame stagger; `OVRCNT` counting overruns without repairing them; the
tunnel's budgets; the OS's `pp_room`/`gpu_end` never publishing a straddling
list. Enemy density (11.49) is decided but its mechanism, F9, is not built.

*Two signals, one per CPU (the user, 2026-11-24).* **CPU1's fuses are
steered by `FRAME_POS`** - it measures the load where a counter could only
guess it, and smoothness outranks everything. **The GPU's are steered by
`ABUDGET`**, the deterministic vertex budget, because the GPU has no such
register: CPU1 cannot read the GPU's position in its frame. Both run, each
guarding its own side. The cost, accepted: with `FRAME_POS` changing the
game (zoom changes which rocks are simulated; splits and collisions are
physics), recordings and the attract demo (`tools/recorder`) stay bit-exact
in madsim and are only as exact on hardware as madsim's cycle accuracy.
Open: every threshold and H (all TBM).

*Before the hardware exists:* move `do_stars`/`do_motes`, build every fuse
behind `DEGR`, and drive `DEGR` from the trainer pad to check each one in
madsim; the checkpoint is the only piece that waits for `FRAME_POS`.

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

*One variant proposed (2026-11-24, F10 "GHOSTS"):* an **inactive** craft under
camouflage - stationary, powered down, invisible, not collidable, not targetable and
off the radar - whose cloak only SHIMMERS (a dotted strobe) while the ship passes
close; it decloaks when the sector's scenario wakes it (`A_WAKE`), not by itself.
It is the cheap end of E7: it does not cover a cloaked enemy that MOVES and is
simulated while unseen (`story.md` 2), which stays open here.

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
  **Settled (the user, 2026-11-25): a destroyed segment does NOT disappear** - so
  the cost never grows. It is drawn SHRUNK, the animation's small triangle for that
  segment, held still (no animation), and about once a second, irregularly, it
  gives off sparks like a rock hit by the blaster (`expl_spawn`). So the star
  occlusion stays ONE disc round the hexagon always, and the per-segment discs
  (`base.s` `@segs`, about 60 B in the base's slot) can go. **The wall stays**
  (the user, 2026-11-25): a shrunk segment still stops rocks, the ship and shots
  exactly as a whole one - the collision code does not change.
* **CPU cost of the star discs once a triangle is gone:** moot - see above, the
  base keeps its one disc (11.48's cheap case, 19 k cycles a frame for `do_base`
  and `do_stars` with the base on the screen).
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

**E13. Force field - the missions (the engine is settled: `design_technical.md` 11.51).**
The user's idea of 2026-11-23: the aliens shield an area with a circle that nothing
crosses but the teleport (B1), the payoff for teaching the teleport early. How it
draws, collides and lives in RAM is decided (11.51, the slots 11.52). What is still open:

* **The missions.** Which sectors have it, and whether the player has to go in, out or
  both - the level's map decides (the user); a rescue from inside and back out is the
  first candidate. How the teleport's charge is kept for the way back.
* **Visible or invisible per level** - both are built; which level gets which.
* **The radar** - not shown for now; look again once a level is flown.
* **Enemies at the edge** - they slide along it (11.51); whether a hunter that keeps
  grinding there needs steering round it is the base's E11 again.

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
GATE OPEN, and whether a level ever needs two conditions at once. A time limit and
chained events are proposed as one rule list in **F10**, which would also replace
`MS_*`.

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
  byte-identical to the silent build.** So the player's `CART_BANK_MIR`
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
* **The scenario rules (F10)** propose the same condition vocabulary for the whole
  sector, and `A_WAKE` as the first, cheapest spawn; this pool would extend it.
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

---

**F10. Sector scenarios - time limits and a chain of events (TBD, a proposal, 2026-11-24).**
The user's idea: missions that must be done within a time, after which something
happens - the base is destroyed if it is not defended in time; enemies attack the
freighters and two of three must be saved; get out of the force field before many
enemies appear there. That needs a small **scenario engine**: a chain of events
conditioned on time or on a task done. Nothing is decided - the user is still writing
the level scenarios (`level_design.md`) and they will say what it has to cover. The
proposal, built for the smallest code:

* **One mechanism, not three.** `gate.s`'s `GTMIS`/`GTMPR` (a condition that opens the
  gate, F1) and F9's spawn conditions are the same idea. A sector carries a list of
  **rules, "condition -> action", each firing once**, and the `MS_*` missions become
  rules (today's levels get one: `C_ROCKS 0 -> A_OPEN`), so `gate_check` goes.
* **The record: 4 bytes** - condition, its parameter, action, its parameter - in
  `levels.s` (bank 8), copied to RAM by the loader at sector start as `GTMIS` is now.
  Up to 8 a sector (32 B). RAM besides: a "fired" mask (1 B, one bit a rule), the sector
  clock (seconds + a 60-frame divider) and a countdown (~36 B in all).
* **Chains without a state machine.** The condition byte's top bit is SEQ: the rule is
  checked only once the rule before it has fired - sequences, and a poor man's AND.
  Several actions on one event are several rules with the same condition. Rule order
  matters: an earlier rule that wins (`A_OPEN`) stops the clock a later one waits for.
* **Conditions, a first set:** `C_TIME s` (s seconds of the sector), `C_CLOCK0` (the
  countdown reached zero), `C_FOES n` (n or fewer enemies alive - `MS_FOES`),
  `C_ROCKS k` (classes 0..k cleared - `MS_ROCKS`), `C_FRLOST n` (n freighters lost),
  `C_BASE` (the base destroyed), `C_GATE` (the mission is done). Later perhaps the ship
  within R of a point (F9's *place*).
* **Actions:** `A_MSG id` (message bar + voice, `indicate_msg`), `A_CLOCK s` (start the
  countdown, shown on the HUD; 0 stops it), `A_OPEN` (mission done, `gate_open`),
  `A_FAIL` (mission lost), `A_KILLBASE` (the base falls - also 4-3's scripted fall),
  `A_WAKE g` (wake a group of enemies the level placed DORMANT - a bit in the record's
  KIND; loaded, but not alive until woken. The cheapest "spawn" before F9's pool, which
  then only extends it).
* **The user's examples, written out.** *Defend the base 90 s:* `C_TIME 0 -> A_CLOCK 90`,
  `C_TIME 0 -> A_MSG`, `C_BASE -> A_FAIL`, `C_CLOCK0 -> A_OPEN`; or the base falls when
  time runs out: `C_FOES 0 -> A_OPEN`, `C_CLOCK0 -> A_KILLBASE`. *Convoy, save 2 of 3:*
  `C_FRLOST 2 -> A_FAIL`, `C_FOES 0 -> A_OPEN`. *Out of the force field:*
  `C_TIME 0 -> A_CLOCK 60`, `C_CLOCK0 -> A_WAKE 1`.
* **Cost (an estimate, TBM).** The interpreter - a loop over 8 rules, jump tables of
  conditions and actions, each 5-20 B since nearly all call what exists - ~200-250 B
  resident (CODE6), less ~60 B of `gate_check`/`MS_*`; the HUD countdown, two digits,
  ~40-60 B. The rules cost no resident RAM beyond the 36 B. CPU: a few hundred cycles a
  frame. It cannot run out of the window (F5): it reads the enemy state under it.
* **GHOSTS - dormant enemies that strobe as the ship passes (the user, 2026-11-24).** A
  UFO or a pulsar that is there but inactive: it does not move and does not react, and
  is shown only as a STROBE, dotted, while the ship is within a short distance of it -
  as the invisible force field flashes where it is hit (`ffield.s`, `FF_FLASH`). **In
  the story they are inactive alien craft under camouflage**: powered down and
  cloaked, the strobe is the cloak shimmering as the ship passes close - not a
  hologram, not a wreck, but a real ship waiting. `A_WAKE` drops the camouflage and
  turns a ghost into the real enemy, which makes the ghosts F10's dormant groups
  rather than a mechanism of their own.
  - **Nothing but a picture (the user, 2026-11-24): no hits, no collision.** Shots pass
    through a ghost, the ship flies through it, and so do rocks and enemy bullets.
    It is a warning - "something is parked here" - and nothing can be done to it until
    it is woken. (An earlier version had shots and ramming hit it with the field's
    `SE_ZAP` and hull damage; dropped, as it cost ~110-140 B more and hooks in
    `shots.s` and the ship's collision.)
  - **Not a `FOEST` state.** `FOEST` is read in ~45 places in 8 files (radar, the
    enemy arrow, `MS_FOES`, hits, laser, EMP, pulsar). A ghost is a separate small list
    instead, which none of them sees: off the radar, out of every hit test, and it
    does not hold up a mission. The loader fills it from enemy records carrying a
    DORMANT bit in KIND (bank 8, not resident). `A_WAKE` copies a ghost into a free
    enemy slot.
  - **The draw is `gate.s gb_draw`**, which already draws the gate, the base and the
    freighter from any `enemies.s` appearance: `GBSH = 1` is a `$4C DOT_POLYGON` a
    part, half-res, so the ghost is the enemy's own WHOLE shape, frame 0 only - never
    animated. No starfield disc. Per ghost per frame: a 16-bit delta from the ship and
    the "within R" test on the high bytes (tens of cycles); when near and on a strobe
    frame, `view_xform` + `gb_draw`.
  - **The GPU cost**, from MAD-65's `carts/cost_bench` (2026-11-24, madsim's core).
    A `DOT_POLYGON` is ~600 a command + ~800 a vertex (transform 646 + the segment) +
    ~74 a half-res step - which reproduces the bench's 12-vertex figure (26,995) to 4 %.
    Small enemies are paid for by VERTICES, not pixels:

    | ghost, frame 0, dotted | commands / vertices | estimate | of a frame |
    |---|---|---|---|
    | UFO, the hull only (part 0) | 1 / 6 | ~7-8 k | ~3 % |
    | UFO, all five parts | 5 / 15 | ~17-20 k | ~8 % |
    | pulsar, all three parts | 3 / 8 | ~13-15 k | ~6 % |

    So dotting saves only about A FIFTH against the solid `POLYGON16` (the UFO's solid
    hull is ~9 k in the dump, F9). What bounds the cost is the rule **at most one ghost
    drawn a frame** (round-robin on `FRAME`): the peak is one ghost, and with a 1-in-4
    strobe the average is a quarter of it, ~1-2 %. A zoomed-out camera is cheaper
    still (`SCALE` 100 is -12 %).
  - **`$45 DOT_LINES` instead** would halve the GPU side of the hull (~4 k: ~240 a
    joint, ~74 a step, no transform) but moves the rotation by the camera and the zoom
    onto CPU1 (four products a vertex) and needs the figure wholly on the screen or
    a clip, i.e. a second draw path of ~100 B beside `gb_draw`, which is free. Worth
    it only if the GPU turns out to be the tight side where ghosts are used.
  - **Decided (the user, 2026-11-24):**
    * **R = 150 screen px, or whatever approximation is fastest to compute.** The
      fastest is a square on the delta's high bytes, in world units at 1:1 (16 units a
      full-res px): |dx_hi| and |dy_hi| <= 9 is +/-2304 units = 144 px at 1:1. A square,
      not a circle, and in WORLD units, so it shrinks on the screen as the camera
      zooms out - the proposed approximation unless a flight says otherwise.
    * **The strobe is the force field's** (`ffield.s @flash`: every other frame while
      fresh, one in four as it dies away, `FF_FLASH` frames) and is **ONE routine
      shared by both** - the pattern taken out of `ffield.s` into a subroutine both
      call, so that a change to it changes both. Within R the ghost's timer is held at
      its fresh value; out of R it dies away as the field's does (1 B a ghost; without
      it the strobe would simply stop).
    * **The whole shape, frame 0, not animated.**
    * **No hits, no collision** (above).
  - **Cost (estimate, TBM; free space measured on the build of 2026-11-24, a73a65e).**

    | | where | bytes |
    |---|---|---|
    | the frame loop: delta, square, timer, strobe, one ghost a frame, `gb_draw`'s setup | resident | ~110-130 |
    | the shared strobe, out of `ffield.s` | resident | ~+5 net |
    | the call in `frame_body` | resident | 3 |
    | **resident code** | | **~120-145** |
    | 4 ghosts x (position 4 + appearance + timer) + a count | under the window | 25 |
    | the DORMANT bit in `load_foes` | bank 8, LDCODE | ~25 |

    **Where it lives: shared, not a level slot.** The wall slots (`slots.s`) hold the
    base OR the force field, and ghosts are wanted WITH either (escape a field where
    camouflaged craft wait; an ambush at the base) - and slot A has 26 B left with the
    base in it. Of the shared areas, the run area has 618 B free (CODE8 ends `$5D95`)
    against FIELDRAM's 168 (CODE9 to `$DA60`) and UPPER's 23. Proposed: the run area,
    as flight code before the kernel (the tunnel lays over it; `overlay.s` brings it
    back). The 25 B of data fit the ~34 left under the window (`FF_END` to `$9800`) but
    take nearly all of it; the reserve is that the freighters and the field never
    share a sector, so their state could share bytes (~47 B).
  - **Still open:** whether 4 ghosts a sector are enough. The GPU estimates above are a
    model fitted to the bench - measure a ghost in a dump.
* **The editor.** At first `tools/level_editor.py` carries the `RULE` block through
  untouched; text macros are enough to write it by hand.
* **Open:** what `A_FAIL` does (replay the sector - `design_technical.md` already has
  the "fly the same sector again" countdown -, lose a ship, or only a branch in the
  story: no reward, no pilot); whether 8 rules a sector are enough; whether the HUD
  needs more than the countdown (freighters left, the base's hull). Settle by filling
  the script/triggers column of `level_design.md` for two or three sectors first.

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
  `load_uicode`): screen code in its own banks, copied to `DEMO_RAM` at a
  state change, split by when it runs (INTRO once; TITLE + ATTRACT + sign-up;
  STORY + ENDINGS). `api_decrunch` can take LZ-packed overlays at 73–95 cycles
  per byte, so one is a loading frame or two. **Open:** how an overlay shares
  `$C000` with `CODE5` (`cam.s`), which the demo needs as much as play does —
  sized beside it, or reloaded on entry to play. **TBM:** what a load costs.
* **Hiscores live in KEEP**, `$DF00-$DFFF`, the page `cart.cfg` holds back from
  `DEMO_RAM`: seeded once by `cart_init`, never by `game_start`, so the board
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
  at boot into `DEMO_RAM` behind `CODE5` — resident for now, not yet an
  overlay — and its state is in KEEP. The title-theme sketch plays from
  power-on as a stand-in (`MUSIC_ON` = 1, banks 7-8). Still open: game over
  goes straight back into a game rather than to the title, and a frame of the
  title picture shows under the first frame of flight.
* **Decided 2026-09-18: the tunnel comes after EVERY sector** (11.45), short, and it cannot kill — see H6 for what is in it. Superseded wording: a short in-between STAGE after some levels — a
  mini-game, flying a tunnel. If it comes it is its own state with its own
  code, so it is one more overlay, not resident code, and it has to be weighed
  against the same `DEMO_RAM` room as the screens.
* **Built 2026-09-18: `SC_SECTOR`, the tunnel's placeholder** (`src/gate.s
  sector_frame`). Flying into the exit gate is SECTOR COMPLETED on black, FIRE
  after 1.5 s, and FIRE is `level_begin` — the next sector with the score, the
  ships and the Saturnium carried. The tunnel replaces this state's frame and
  nothing else. **Proposed, not decided:** it is built in `src/` as its own
  state and file, not as a separate program (CLAUDE.md: no `proto/04`), with a
  build switch that boots straight into it for testing, and a `preview.py`
  bench; its code is a SWAP overlay — while it flies, nothing of the field's
  code in `DEMO_RAM` (CODE5/CODE6) is needed, so the tunnel is copied over it
  and the resident code copied back before the next sector loads, and the
  object pool under the window is free scratch for it, since `level_begin`
  rebuilds the field afterwards anyway.
* **RAM audit, 2026-09-22 (the user).** Measured (`map.txt`): every scarce area
  is now nearly full at once — run area 289 B free, `UPPER` 16 B, `DEMO_RAM`
  209 B (`CODE5` 3,281 B + `UICODE` 1,444 B + `CODE6` 3,002 B). But
  `main.s frame_body` already proves `UICODE` and the flight engine never share
  a frame: `SCR_STATE = 0` falls through to the field and never calls
  `scr_frame`; any other value hands the WHOLE frame to `scr_frame` (`UICODE`)
  and the field's per-frame code never runs. The one place that boundary
  cracks today: `scr_frame` dispatches `SC_SECTOR` to `sector_frame`, which
  lives in `gate.s` (`CODE6`, the field group) — so `UICODE` and `CODE6` are
  both resident and cross-calling for as long as SECTOR COMPLETED is on
  screen. Extending 11.45's flow, three groups are pairwise mutually exclusive
  in time, always: **SCREEN** (`UICODE` — intro/title/attract/hiscore sign-up,
  and the coming briefing/start-banner/endings, which are the SAME
  bitmap+text machinery with different data, not a fourth tenant), **FIELD**
  (`CODE5`+`CODE6`, and `CODE7`/base.s is a candidate to join it from `UPPER`),
  **TUNNEL** (not built). **Proposed:** generalise CETAS's `states.s`
  `load_hicode`/`load_uicode` (a two-way `$A000` overlay, `overlay_cur` +
  one `cart_load` per swap) into an N-way overlay over `DEMO_RAM`, table-driven
  (`OVL_id, LOAD, RUN, SIZE`) since this cartridge needs three tenants, not two.
  Swap points ride the existing/planned state transitions: boot loads SCREEN
  first (matches "intro/UI/hiscore/attract loaded first"); FIRE into a game
  loads FIELD (before any field per-frame code can run, like CETAS's
  `pr_update` -> `load_hicode` before `ST_BOSSLOAD`); the gate loads TUNNEL;
  the tunnel's end loads SCREEN (before the next BRIEFING) or FIELD (when it
  falls straight to START BANNER, which draws over the live field, so FIELD
  must already be resident). The one prerequisite fix, independent of the rest:
  move `sector_frame` out of `gate.s`/`CODE6` into the tunnel's own file when
  it is built, so `SC_SECTOR` stops requiring `CODE6` resident under `UICODE`.
  The dispatcher itself (`overlay_cur`, the swap table) must live OUTSIDE
  `DEMO_RAM` — a handful of bytes in the run area or `UPPER`, never in one of
  the segments it swaps, exactly as CETAS's `set_state`/`load_*` sit in the
  ambient segment rather than `HICODE`/`UICODE`. **Payoff:** each active group
  gets the full `DEMO_RAM` ceiling (~7,936 B) instead of permanently splitting
  it three ways — FIELD's headroom goes from 209 B free today to roughly
  1,650 B, TUNNEL starts at the same ceiling rather than scrounging leftovers,
  and SCREEN has room for briefing/ending display without touching field code
  at all. Not yet decided where `CODE7` ends up or whether cutscenes ever need
  their own tenant — settle both when the tunnel and the briefing screens are
  actually written.
* **Built 2026-09-22: the FIELD/SCREEN overlay (`src/overlay.s`), the
  `sector_frame` move, and the swap-point mechanism above** — `cart.cfg` now
  has `FIELDRAM`/`SCREENRAM`, two MEMORY areas at the same physical range,
  CETAS's `HIRAM`/`UIRAM` trick. Measured after: **FIELDRAM 1,824 B free,
  SCREENRAM 6,333 B free** (was 209 B shared three ways). One thing the plan
  above did not anticipate and had to be fixed by building it: content code
  that triggers a FIELD entry (`title_frame`'s FIRE, `sector_frame`'s FIRE)
  must **tail-`jmp`** into the resident swap routine, never `jsr` — a `jsr`'s
  return address sits inside the memory about to be overwritten. The harder
  lesson, found only by the user re-testing in real madsim twice: the
  transition's one-time work (the `cart_load` + `game_start`/`level_begin` +
  clearing `BGDONE`) has to happen **synchronously, on the same frame as the
  trigger** — deferring it one frame via a flag (this was tried first) broke
  the title screen's background clear on real hardware, even though
  `tools/preview.py` kept passing throughout, because `preview.py` explicitly
  does not model the double-buffered background / VSYNC replay timing (its
  own header says so) and its `boot_cart()` bypasses the title/FIRE path
  entirely (a direct `SCR_STATE` poke). See
  `efs-field-screen-overlay` (memory) for the full account and the py65
  debugging recipe that ruled out the CPU1-command-list level before the fix
  was found. `frame_body` keeps a defensive fallback (load FIELD + clear
  `BGDONE` unconditionally) for exactly that poke path.
* **Checked against the attract DEMO (the user, 2026-09-22): the SCREEN/FIELD
  split holds, no third case.** The worry was whether the attract DEMO panel
  (recorded play, replayed — the bullet above) needs `UICODE` and the field
  resident together, since the marquee scrolls under the rotating ATTRACT
  panels. **Settled: no.** The demo panel is the full game with no HUD and a
  scripted joystick, not a game-plus-chrome hybrid — it does not coexist with
  the scroller or anything else `UICODE` draws, so it is a plain FIELD state
  like PLAY, just fed canned input. The marquee stops for the duration of that
  panel. So `SC_STATE`'s existing rule (SCREEN and FIELD never share a frame)
  needs no exception for it — only one more swap point: entering/leaving the
  demo panel loads/unloads FIELD exactly like a game start/end does.
* **Scope, decided 2026-09-22 (the user): staged, not all at once.** The
  question raised was why stop at `DEMO_RAM` (8 KB) rather than making most
  of RAM swappable behind a small resident kernel + shared data — and that is
  the right eventual shape: only the hot tables (`$0400-$0FFF`), `HIDATA`
  (the IRQ reads it in any state), the object pool/foes-state/`SHAPES` scratch
  (already shared, per the tunnel bullet above), and the dispatcher itself
  are truly kernel; the run area (`CODE`-`CODE4`, 20 KB) is FIELD too, not
  kernel — it is idle exactly when `DEMO_RAM`'s `CODE5`/`CODE6` are, and TUNNEL
  could borrow it the same way. But extending the swap to the run area costs
  more than a `cart.cfg`/`bootstrap.s` change: `main.s` today mixes the
  per-frame dispatch trampoline (`frame_body`, the `FRAME` counter, `spr_pump`)
  with the field engine in one file, and that has to be pulled apart into
  kernel vs. FIELD before any of it can move, then reverified against
  `preview.py`'s 220-frame trace. Decided: do `DEMO_RAM` first — its swap is
  already free (every file already sits in its own segment, the frame
  boundary is already proven) — and revisit the run area once the tunnel is
  actually being built and its real code size is known, rather than
  refactoring `main.s` on a guess.
* **TUNNEL memory audit, step A, 2026-10-12 (measured, nothing built).** The
  tunnel will not fit `DEMO_RAM`'s ~7.9 KB, so it is a list of overlay rows
  (`ovl_walk` already takes several per tenant) laid over what the FIELD does
  not need while it flies. Bytes per file and segment come from the linker's
  `--dbgfile` (line -> span), not from the map. What it found:
  * **The run area `$1000-$5FFE` is full (`CODE8` ends at `$5FFE`) and is
    mostly field:** `CODE` 8,075 B, `CODE2` 8,163, `CODE3` 2,814, `CODE4` 1,171.
    Reloading it costs one `cart_load` per bank (~20 KB) - TBM.
  * **KERNEL in that area is small but INTERLEAVED with field code in `CODE`:**
    `main.s` (cart_init, cart_frame, frame_body: 239 B), `math.s` (328), `input.s`
    (318), `sprites.s` `spr_pump` (77) - ~1 KB scattered through the field's
    first 8 KB. They have to move into one kernel segment (beside `CODE8`:
    `overlay.s` 125 B + `rumble.s` 131 B) before anything around them can be
    overwritten. That move is THE refactor, and it is ~1 KB, not a rewrite.
  * **Already safe, not kernel:** `sfx.s` (HIDATA, the IRQ reads it), `window.s`,
    the hot tables `$0400-$0FFF`, `SHAPES` `$9800` (the tunnel draws rocks),
    `KEEP` `$DF00`, zero page.
  * **TRAP: the state that must survive a tunnel is NOT in one place.** `SCORE`
    `$708C`, `LIVES` `$7093`, `CURLEV` `$7094`, `LSRHAVE` `$73AF`, `EMPHAVE`
    `$73B4` live in `$6000-$77FF`; `SATN` `$9688` (and `SATARM`) under the
    window. So neither of those areas is free for tunnel scratch as it stands:
    either the carried set (score, lives, level, Saturnium + armour, laser/EMP
    taken - from `game_start` vs `level_begin`) moves into one block in KEEP/
    low RAM, or the tunnel steers clear of those islands. Preferred: one block.
  * **Under the window is DATA ONLY for the tunnel.** The tunnel may read the
    cartridge (messages in bank 9, level data in bank 8, bitmaps by
    `RECT_BG_CART`), so the window is switched on and off like the field's; code
    there would run only while it is off. Code goes in `DEMO_RAM` + the run area.
  * **Open to verify when building:** any self-modifying operand in the run area
    that carries state across a reload (a reload restores its assembled
    initial value); and the real `cart_load` time of the run area.
  Plan: move the kernel out of `CODE` -> gather the carried state -> add the
  TUNNEL rows (`DEMO_RAM` first, then the run area) -> reload the field on exit.
  **Step 1 built 2026-10-12:** the kernel (`cart_frame`, `frame_body`, all of
  `math.s`, `spr_pump`) is in `CODE8`, 809 B at `$5CD6-$5FFE`; `$1000-$5CD5`
  (19,158 B) is pure field code now. `preview.py` is identical to HEAD (the one
  failing check, "FIRE after it is the next sector", fails on HEAD too) and the
  game plays; cycles moved by ~200 a frame.
  **Step 2 result 2026-10-12 - the carried state is NOT relocated.** The audit
  said `SCORE`, `LIVES`, `CURLEV`, `SATN`/`SATARM`, `LSRHAVE`, `EMPHAVE` are
  scattered over `$6000-$77FF` and under the window. Moving them is not needed:
  the tunnel has `DEMO_RAM` (7.9 KB) + the run area (19 KB) for code and data,
  which is far more than it will use, so **the tunnel simply never writes
  `$6000-$97FF`**, and whatever the sector carries survives by itself. The rule
  is the map, not a refactor of seven equates:
  * **Tunnel may write:** `DEMO_RAM` (its own rows), the run area `$1000-$5CD5`
    (its own rows), KEEP `$DF8D-$DFFF` (115 B free after the screens' state),
    and the stack.
  * **Tunnel must not write:** `$6000-$77FF` (rumble `$73C2-$73C4`, `SCORE`,
    `LIVES`, `CURLEV`, `LSRHAVE`, `EMPHAVE`, `SHAKEX`, `OVRCNT`...), under the
    window `$8000-$97FF` (`SATN`, `SATARM`, the pool, `foes.s` - and while the
    window is on, all of `$8000-$9FFF` is ROM anyway), `SHAPES` `$9800-$9FFF`
    (read only), UPPER (`RODATA`/`HIDATA`/`CODE7`: the IRQ reads it), KEEP
    `$DF00-$DF8C` (hiscores and `SCR_*`), `CODE8` (the kernel), lower RAM
    `QSL`/`QSH` `$0E00-$0FFF` and `MAT` `$0CAE` (the multiply).
  * **Zero page is the one shared resource** (2 B free). The tunnel borrows the
    field's, and the exact way is **save on entry, restore on exit** (copy the
    bytes it uses into its own RAM; ~100 B, a few hundred cycles once) rather
    than auditing which of ~120 variables `level_begin` re-initialises. NEVER
    borrow: `FRAME` `$80-$81`, `BGDONE` `$82`, `SPRJOB` `$EC`, the PRNG `$BF`/
    `$D2`, the multiply's `MAL..MSGN` `$A4-$AA`, `T0`/`T1` `$B7-$B8`, `MQA-MQR`
    `$E8-$EB` and `MAT`, which `cart_frame` and `math.s` (kernel) use.
  * **Lower RAM `$0400-$0DFF` (3.5 KB) is also field's** (rotation tables, star
    layers, occluders, HUD strings) and is NOT used by the tunnel until it is
    verified which of it `level_begin` rebuilds; the same save/restore applies.

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

* **How the text shows in the tunnel.** Settled 2026-09-23: it types itself
  out like a telegraph (`design_technical.md` 11.45). Still open: how long a
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
instruments and the radio's debrief/brief under it, stacked 50/300/50 px top
to bottom, the radio typed out like a telegraph. The joystick leans the ship
in eight directions inside an invisible tube, and no button does anything.
There is one lifepod for each ship lost in this sector. A rock hit costs all
the Saturnium collected in this passage, never a pod. Open:

* The lean (it springs back to the centre, 11.45): its range, and how fast
  it leans and returns (TBM).
* **CHOSEN 2026-10-13 (the user; merged from the branch `tunnel-roll`): LEFT/RIGHT ROLL THE WORLD** round the
  tube's axis instead of leaning, eased (W += (T - W) >> 3, top rate 2 brad a frame);
  UP/DOWN still lean along the screen's up-down, so the eight places become a ring.
  Every point is seen at R(TH) (w - cam), cam = R(-TH) (0, LY); a rock's angle gets TH
  too, a Saturnium cloud's pattern does not (the user: it may set it apart from the
  stars); the far stars are a disc of radius 105 turned with the roll. A hit knocks the
  roll. UP/DOWN inverted (UP leans down). The reach is a ring, so a corner lane is pulled
  in to it at birth. Dust born in a disc of radius 190 (was 127), signed-16 places; dust
  and far stars 24 each (were 32). Cost, measured: a calm frame 66.5 k (main 59.6 k), the
  rush 77.5 k (main 72 k); two madsim dumps (8 rocks + a pod, rolling) that were at 91%
  and 100.6% replay at 75% and 83.5%. Open: whether players find it too hard (play-testing).
  **THE EIGHT-WAY LEAN IS KEPT ASIDE, NOT IN THE SOURCE** (the user: in case the roll proves
  too hard): git tag **`tunnel-lean-8way`** is the last commit with it (`235d66f`), and the
  whole roll is ONE commit on top, **`e510a3b`** ("Tunnel: LEFT/RIGHT roll the world").
  To go back: `git revert e510a3b`. Expect conflicts only where later work hooks into the
  same code - tunnel_hud.s's calls in `tun_catch`/`tun_hit`/`tunnel_frame` and the dust and
  far-star counts (24/24 since the roll; the lean had 32/32 and ran at 59.6 k a calm frame).
  What the revert takes away, so nothing has to be re-thought: `tun_lean_frame` back to two
  springs (LEFT/RIGHT on x, UP/DOWN on y, not inverted), the dust back on the signed-byte
  torus (born in a +-127 square, `tun_proj`/`tun_proj9`), the far stars back to a 150 x 150
  wrap slid by CAM >> 3, `tun_rot`/`tun_trig`/`tun_ring` and the roll's TH added to rock and
  pod angles gone, and the corner lanes back at (+-81, +-81). Keep, if going back: the
  inverted UP/DOWN if wanted (one swap in `tun_lean_frame`), and tunnel_hud.s, which does
  not depend on the controls.
* **CONCLUDED 2026-10-15 (the user): the tunnel is a game element, the numbers and rules are
  design_technical 11.45's "THE TUNNEL CONCLUDED"** - a minute, it heals and does not punish
  (a hit stops the repair 5 s and takes 25 Saturnium, never below what the ship came in with;
  no top-up at the end: the hull may leave short of full), a cloud +25 and 50 points, a pod 300, +500 CLEAN RUN BONUS,
  pods at random moments, no FIRE, the four orders on the bar at the start. Settled with it:
  the pod is always reachable as built (no seeded generator for that); "all the Saturnium"
  is gone. What stays open:
* The seeded generator (11.45) and the density per level - wanted with the per-level variety,
  not before.
* Per-level variety as foreshadowing (candidate, deferred - the user: "its time will come"):
  L1 clean ice, L2 a silhouette that flickers and is gone, L3 wrecks of SRVs, L4 shadows
  pacing the ship, L5 the tunnel folding back on itself.
* Its music (none now; the effects stay as they are).
* ~~The ship for points~~ - settled 2026-10-15: every 20,000 points, up to 9 ships (11.45).
* **Built 2026-10-13: the tunnel flies (`src/tunnel.s`, TUNCODE bank 10 -> TUNRAM, the third DEMO_RAM tenant).**
  Entered by flying into the exit gate (DEMO=0), `make run-tunnel` / `run_tunnel.bat` boots straight into it
  (TUNTEST=1, FIRE skips to the rush), `make tunnel-test` = `tools/tunnel_bench.py` is its own bench (minutes
  less than `preview.py`). What is in: the 300 x 300 cockpit (`tunnel_hud.png`, background layer, centred),
  32 DUST stars (the near field, a torus, born at 510 and projected rel*F/z) + 32 FAR stars (pixels at infinity,
  sliding CAM >> 3), the lean (critically damped spring, 9 places, +-81), up to 16 rocks (the sector's 192
  outlines; reduced outlines beyond z 220, dotted beyond 500; occluded by nearer rocks; cut to the HUD frame
  edge by CPU line clipping), the hit (kick, shake, rumble, SE_KLANG, the rock thrown aside at its depth), the
  noise rumble (mode 7 + a silent tone on voice 6 for a smooth rise), and the 6 s end rush (eased speed-up,
  streaks growing from a pixel). Parameters are the TUN_* constants at the top of `tunnel.s`. Measured: a
  flying frame 49 k CPU cycles (21%), the rush 69 k CPU / 67 k GPU. Also built the same day: the Saturnium
  CLOUDS (DOT_PIXELS the size of a rock, 8 to 32 pixels, caught with SE_SATN, paid into SATN at the end), the
  end-of-run whine with vibrato and tremolo, and the engine volume (3, swelling to 5). Parameters:
  `physics.md` 12.
* **THE TUNNEL: what is still to do (2026-10-13, from 11.45, H6 and the user's plans).**
  1. **Lifepods**: the barrel is BUILT (2026-10-13, `tunnel_pod.s`, design_technical 11.45); three fly at
     fixed times in the test tunnel and a catch is only counted (TPOD, TPLOST). Still to do: one per ship lost
     in THIS sector (needs a per-sector count the field does not keep), a catch returns a ship (LIVES), the
     speech PILOT RESCUED / PILOT LOST IN SPACE, and the cost (~73 k CPU near: the facing test and the point
     list could be cheaper).
  1b. **BUILT 2026-10-13 (`tunnel_hud.s`, design_technical 11.45):** the bottom band carries SHIPS + hull (line
     46, hud_game.s's code in HUDCODE) and SATURNIUM (line 48; no LEVEL + SCORE in the tunnel), the hull grows to full, the
     Saturnium is the sector's +50 a cloud -20 a hit, sparks at SATN_FULL, one pod per ship lost (LVSTART -
     LIVES), a catch = a ship + 300, a cloud + 100. **Still to do: the ANIMATED PICTURE OF THE SHIP BEING
     REPAIRED where the radar stands in the sector** (the user's art, not drawn yet): in the tunnel only the
     band's right side is free for it - cells 24+ of lines 44-49, ~100 x 50 px. Its look, its frames and
     their cost (sprites or background) are open; it should read as the hull growing.
  2. ~~The stat bar and the radio bar~~ - **settled 2026-10-15**: the bar above the window carries the
     ORDERS at the start (BUILT, 11.45) and the tunnel's own lines; the sector's summary (score / time /
     kills - the field would have to count time and kills) goes on a SUMMARY SCREEN after the tunnel and
     the debrief / brief telegraph (H5) on the information screen after that. Both screens are to do.
  3. **A per-level seeded generator** (the same stream every run, a density per level, the pod guarantee),
     replacing the free PRNG; plus the per-level variety (L1 clean ice, L2 a silhouette that flickers, L3 SRV
     wrecks, L4 shadows pacing the ship, L5 the tunnel folding back).
  4. **The Saturnium rule - settled 2026-10-15 (the user; was -20 / +50):** a rock hit takes 25 but never
     below the hold the ship came in with, a cloud adds 25 (tunnel_hud.s).
  5. **The states round it**: the picture / summary / story between the tunnel and the next sector (the
     tunnel now exits straight to `set_state_field`); the 0.1 s reload hitch hidden under a blind.
  6. **Entry**: only the exit gate (and `run-tunnel`); the original idea was a test tunnel at the start of the
     test level, straight ahead of the ship. DEMO=1 (the expo build) still skips the tunnel.
  7. **Sound**: the effects stay as they are for now (the user, 2026-10-15); the tunnel's own music comes
     later (the title theme is stopped on entry).
  8. **Budget**: 16 rocks at once have been measured only for CPU and for a typical frame; the GPU worst case
     (several near rocks, all drawn solid, clipped edge by edge) is TBM, and the difficulty (rock density, the
     lean's 1 s, the speed) is for play-testing.
* **Built 2026-10-13: the TUNNEL's memory plan - two areas, the run area overlaid.** TUNRAM was full, so the
  tunnel is now laid over TWO things the field does not need while it flies: DEMO_RAM (`TUNCODE`: the flight
  frame, dust, far stars, lean, hum, streaks, hit, the art) and the RUN AREA `$1000-$59FF` (`TUNCODE2`: the
  rocks and their tables, 3.3 KB; `TUNBSS`: all its variables, 1.2 KB). Both rows load from ROM bank 10
  (`ovl_tunnel_segs`); on the way out `ovl_load_field`, seeing the tenant it replaces is the tunnel, first
  reloads the engine (`ovl_engine_segs`: CODE, CODE2, CODE3, CODE4 - the same four rows as the boot) and then
  FIELD. The kernel (`CODE8`, `$5B2D+`) stays, and a `lderror` assert in `tunnel.s` stops TUNRUN running into
  it. The carried state is untouched (the tunnel never writes `$6000-$97FF`), and no run-area label is a
  variable (checked: none is written at run time), so a reload restores exactly the code. **Measured**
  (`tools/tunnel_bench.py`): the reload is byte for byte the boot's, and costs 1.43 M CPU cycles - about 6
  frames, ~0.1 s, once, at the tunnel's exit (TBM on hardware, where the window adds wait states). **Free now:**
  TUNRAM about 4.8 KB, TUNRUN about 15 KB (18,944 less 4.5 KB). Next tenants (pods, Saturnium, the bars, the
  radio text) go in either, whichever the data wants.
* **Rock outline scaling (11.45).** The field's rock shapes are reused, but
  the tunnel needs them credible across nearly the whole zoom range, from
  just short of a point near the vanishing point to full-screen at the
  closest pass — untested, and the failure mode (an outline that reads as
  wrong well before it fills the screen) is only visible once flown.
* **The lifepod's pseudo-3D look** is built (2026-10-13, `tunnel_pod.s`): a
  barrel drawn from its geometry, not frames; to be judged once flown.
* **Saturnium's look in the tunnel is undecided (the user, 2026-09-23).** A
  candidate is a dense, growing cloud of pixels as it nears the camera, but
  that risks the per-pixel GPU cost already measured tight elsewhere (`DOT_PIXELS`,
  38) and the enemy-density budget's lesson that GPU cycles are the tight
  side (11.49) — a cheaper stand-in shape (a solid or a small dot cluster
  capped well below "dense cloud") may be needed instead, and cost should be
  measured before the look is committed to.
* **The end-of-run speed-up (11.45):** stars stretching into radial streaks
  once obstacles run out, longer with distance from centre — how far out
  they start, how long the stretch lasts, and its cost against the
  steady-state star field (which itself stays single-pixel and non-streaking
  in flight, 37 — a different budget here).
* **Cost (TBM):** perspective is a 1/z table, rocks are the GPU's scaled
  shapes, the stars `DOT_PIXELS`; the code is a SWAP overlay (H1). A 300 x 300
  window also means only part of the screen is redrawn, so the clear or the
  background layer may be cheaper than in flight.
