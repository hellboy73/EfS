# campaign.md — five chapters, fifteen sectors

The campaign's skeleton, from the user's outline (`draft_scenariusza.html`,
2026-11-27). It sits **between** `story.md` (the fiction and what it commits the
engine to) and `level_design.md` (the per-sector tables the level editor builds
from): it says what happens, where, and why, chapter by chapter. The per-sector
rows of `level_design.md` are filled from here.

**Words.** A **chapter** is one of the campaign's five (what `story.md` calls a
"level"); a **sector** is one board, `1-1` .. `5-3`, three to a chapter; a
**zone** is the third axis, set per sector (`levels.s` `ZONE`, design_technical 52):

| zone | where | what the zone has (the code) | what it means in the fiction |
|---|---|---|---|
| 1 INNER | the near neighbourhood | the human base, the freighters | ours: safe-ish ground, the thing to defend |
| 2 OUTER | the farther reaches | rock ghosts and dormant enemies (`ghosts.s`) | Saturnium-rich rock; the aliens use it as camouflage |
| 3 VOID | what the aliens hold | the force field and its tower (`ffield.s`) | their mining fields, shielded |

Zones are **not** the campaign's order: a sector picks its zone and a chapter
moves between them. That settles the question left open in design_technical 52.

---

## The five chapters (working names — the user decides)

| # | name | one line | the player learns / gets | old name |
|---|---|---|---|---|
| 1 | SENSOR ANOMALY | clear the ground; something is wrong with the rocks - it ends on the first glimpse of them | fly, shoot, teleport (costs Saturnium); ghosts seen, not fought | MINING ZONE + SENSOR ANOMALY |
| 2 | CONTACT | first look under their field; they wake; we bring a report | the force field, spiders, the pulsars (laser) | CONTACT |
| 3 | RESCUE | our people are in their hands; the EMP takes the tower | mines, the EMP, waves that replace the dead | (was L4) |
| 4 | SIEGE | they come for the base; we go for the source | defending the base; the tower as a target | (HUNT's pursuit folded in) |
| 5 | ESCAPE | nothing to return to; out of the rings, to Titan | nothing new — everything at once | ESCAPE |

Alternatives, if a name does not sit right: 4 = REPRISAL or SOURCE; 3 = THE
TOWER. HUNT is retired as a chapter name: its mechanic (they find you and give
chase) is what waves and sieges are in chapters 3-5.

### The zone rhythm (as outlined)

|  | x-1 | x-2 | x-3 |
|---|---|---|---|
| **1** | inner | inner | outer |
| **2** | void | outer | inner |
| **3** | outer | void | outer |
| **4** | inner | outer | void |
| **5** | outer | inner | outer |

Not "one of each zone per chapter": 1, 3 and 5 repeat a zone. What the pattern
does give: **the void is visited three times, each one a step up** — 2-1 *look*,
3-2 *rescue*, 4-3 *destroy*; the inner zone is home (1-1, 1-2, 2-3, 4-1) and then
a ruin (5-2); and **every chapter but the first ends on a sector that is not the
easy one**.

---

## Chapter 1 — SENSOR ANOMALY

*Routine. The player learns the ship; the first crack in "no threat".*

| sector | zone | what happens | mission | working title |
|---|---|---|---|---|
| 1-1 | inner | The basics: flying, shooting. Clear the largest rocks round the base. | rocks | PERIMETER |
| 1-2 | inner | Clear the field for the transports (freighters). Learn to teleport: **collect Saturnium to make the jump**. | rocks + Saturnium | FREIGHT LANE |
| 1-3 | outer | Scout the farther ground and the **source of the false readings**. UFO ghosts turn up but are hard to find and **cannot be woken**. The gate opens when **all the largest rocks are destroyed — some of them ghosts** (big, and on the radar), so the player has to find the hidden ones: the message **destroy the ghost rock, collect samples**, then the tunnel opens. | the largest rocks (`MS_ROCKS` 0), ghosts included | THE FALSE ROCK |

Needs: freighters (built, `freight.s`); teleport on Saturnium (built);
ghosts that sleep for good in this sector (built: `gh_wake` is never called);
the gate is the ordinary `MS_ROCKS` on the largest class - the only check is that a ghost rock counts in `rocks_left` while it is hidden (to verify in `ghosts.s`).

## Chapter 2 — CONTACT

*The first time under their field. Ends with a lie told to us by silence.*

| sector | zone | what happens | mission | working title |
|---|---|---|---|---|
| 2-1 | void | **First visit, by accident, to reconnoitre.** Fly under the force field and see what is inside: big rocks with spiders. Break the rocks in the field. A gate opens — outside the field, with UFOs round it. | break the field's rocks | UNDER THE FIELD |
| 2-2 | outer | The aliens on the board are asleep too (ghosts) and wake **gradually as the others are killed**. Destroy all of them; **get the laser** (the first pulsars), try it, break the ghost rocks. | foes (+ ghost rocks) | WAKING |
| 2-3 | inner | **Hand in the report and the samples at the base.** A lone UFO near the base, and pulsars. No abduction scene: the report, plus **fragments of the pilots' SOS signals** that, read together, place them in a tower in the void - so we must fly **back for the rescue capsules**. | foes, then the scripted turn | DEBRIEF |

Needs: the field and the spiders on rocks (built); progressive waking
(F10 `A_WAKE g` — a *chain* "wake the next when one dies" is the user's rule and
`C_FOES n` + `A_WAKE` covers it); the laser as a pickup (built, `pulsar.s`/`laser.s`);
the scripted turn at 2-3 (Open 4).

## Chapter 3 — RESCUE

*Our crews are missing. The tower is the way in, and the EMP is the key.*

| sector | zone | what happens | mission | working title |
|---|---|---|---|---|
| 3-1 | outer | Clear the in-between sector of enemies. **The first mines.** Win the **EMP** and be made to try it. | foes, EMP pickup | MINES |
| 3-2 | void | **Second visit: a rescue** (a kidnapped pilot, or pilots lost in space). Destroy or switch off the **tower with the EMP**; the tower gives up the capsules. Then go back. Inside there must be **rocks enough that the Saturnium pays for the EMP and the teleport out of the field**. | tower, capsules | THE TOWER |
| 3-3 | outer | **The fight on the way back.** Aliens come in waves; each one killed is replaced by a new one (perhaps another kind), waking from sleep and camouflage. **Every enemy type is here now.** | foes (waves) | THE WAY BACK |

Needs: mines (built, `empmine.s`); the EMP and the tower that only it takes
down (built, `emp.s`, `ffield.s`); capsules caught and returned (the tunnel's
lifepod and `capsule.s` exist — what is *new* is a capsule held by a tower);
replacement waves (F9 "the previous entry is dead" chain, not built);
Saturnium accounting inside the field so the player cannot be stuck (a level
design check, not code).

## Chapter 4 — SIEGE

*They attack the place we return to. Then there is nowhere left but their side.*

| sector | zone | what happens | mission | working title |
|---|---|---|---|---|
| 4-1 | inner | **The aliens attack our base and we defend it.** Some flee through the gate. UFOs and pulsars here. | defend / foes | SIEGE |
| 4-2 | outer | The way back, again: waves, each kill replaced, enemies waking from camouflage. | foes (waves) | OPEN GROUND |
| 4-3 | void | **Third visit: strike at the source.** Mines round the field and many enemies. **Destroy the tower with the EMP, but first remove the rocks from inside** — there are spiders on them. **An artefact falls from the tower** (the plans of the aliens' bases). | tower, artefact | GROUND ZERO |

Needs: the base's scripted fall (A_KILLBASE) or defended-for-N-seconds
(F10 `A_CLOCK`); enemies that flee through the visible gate (Open 5);
4-2 duplicates 3-3's shape — they must differ (Open 6); the order inside 4-3
(rocks first, then tower) is a mission chain, `C_ROCKS` then the tower.

## Chapter 5 — ESCAPE

*Nothing to go back to.*

| sector | zone | what happens | mission | working title |
|---|---|---|---|---|
| 5-1 | outer | Fighting on the way back. | foes (waves) | RETREAT |
| 5-2 | inner | **The bases and the transports are found destroyed, the area mined**, and the aliens appear once the wreckage is discovered. There is nothing to return to: **get out of Saturn's rings, to Titan.** | survive / reach the gate | THE RUINS |
| 5-3 | outer | **The hardest fight**: many waves of aliens one after another, waking from sleep. The last sector. | foes (waves) → ENDING | THE RINGS |

Needs: base as a wreck (built for 4-3's fall; one more state of the same
object); a mined zone-1 sector; the largest wave pool in 5-3 within the
enemy budget (11.49, F9).

---

## The spine — what the story is, put together

The outline and `story.md` agree more than they differ. One reading that
joins them, **offered, not decided**:

1. **The aliens hide in the Saturnium.** It is their cloak (story.md). In the
   outer zone the rocks are soaked in it and the aliens sleep inside the
   camouflage (ghosts). Mining it tears the veil — the cause of the lying
   instruments and the lost ships.
2. **The void is where they mine, and the tower is the heart of each field.**
   The field keeps us out; only the EMP (from 3-1) and a teleport (Saturnium)
   get through. Hence: each void visit is a bigger reason to be there.
3. **Lost pilots are capsules, and capsules are lives (decided, 2026-11-27).** The
   aliens picked up some of the capsules drifting in the wormhole - the tunnel -
   and hold two or three pilots in the tower. Destroying a tower is hard, so
   **each pilot rescued from it adds a life** - the reward. Capsules caught in
   the tunnel itself already bring a crew back (11.45); the tower is a second
   source of the same thing.
4. **The tower is not the end (decided).** We go home believing the aliens are
   beaten with their base. It is **one of hundreds** of such towers round
   Saturn. This has to be told in the pictures and texts between sectors: the
   debrief after 3-2 and 4-3 says "it is over", and the next brief (or the
   radar, or the radio) quietly shows it is not - the chapter 4 siege and the
   chapter 5 ruins are the answer to that.
5. **The motive** from story.md (they want to stay hidden, so they destroy what
   is known about them): the siege (4-1) and the ruins (5-2) *are* that
   motive acting — the base is a record, and they wipe records. The tower
   (4-3) is the last place the record could be undone.
6. **"Get out with what is known"** (story.md's goal) is the artefact from
   the 4-3 tower (plans of the aliens' bases), carried through 5-1..5-3.

---

## Open questions this raises

1. ~~The capsules and the lives~~ **Decided:** each pilot rescued from the
   tower adds a life; the tower holds two or three, **and rescuing them is the
   sector's goal** - they are what makes the escape possible, whatever the lives
   counter says. The game has a cap today, `LIVES_MAX = 9` (`hud_game.s`: LIVES is
   one digit; extra ships and tunnel pods stop there). Whether pilots beyond the
   cap still count as rescued (the mission needs them, the counter stays at 9) and
   whether the cap stays 9 is settled **at the end, in testing** (user, 2026-11-27).
2. ~~What is carried out in chapter 5?~~ **Decided (2026-11-27): an artefact falls
   from the 4-3 tower - perhaps the plans of the aliens' bases.** That fits
   "hundreds of towers": it is the proof, a map of where they are, and the
   thing story.md's "get out with what is known" needs. Still open: what the
   pickup is on the screen (a new pickup, as the capsule/Saturnium are), when it
   drops (tower destroyed), and whether losing it costs anything.
3. ~~1-3's rock~~ **Decided:** the gate opens on all the largest rocks, ghosts
   among them (`MS_ROCKS`, no new rule).
4. ~~2-3's turn~~ **Decided:** no abduction scene. The pilots are known to be in the tower from the remains of their SOS signals (radio/message, `A_MSG` + voice, built; the picture between sectors can show the signal's trace).
5. **Enemies fleeing through the gate (4-1) — feasible?** Yes in outline, not
   built. The F9 example in `open_questions.md` already has enemies *arrive
   at the gate* when the mission is done; the reverse needs (a) a flagged
   record that does not die and (b) a FLEE behaviour: steer for the gate's
   position and remove the foe on arrival (`gate.s` already knows when
   something is at the gate's X). Immortal is a flag on the foe, one byte.
   The risk is the budget, not the code: they must leave while the
   defence is still going on.
6. **Three "waves on the way back"** (3-3, 4-2, 5-1) read the same in the
   outline. Suggest the escalation be explicit in the table: the pool size, the
   cap, the kinds, mines or none, how fast the dead are replaced.
7. ~~Chapter 1 and chapter 5 never meet the void~~ **Intended (user, 2026-11-27):** the story ends in the rings, not at a tower.
8. **Briefing pictures** (`level_design.md`): which sectors have a
   distinctive picture. Candidates from here: 1-3 (the false rock), 2-1
   (under the field), 3-2 (the tower and the capsules), 4-1 (the siege),
   5-2 (the ruins), 5-3 (the exit). The rest are neutral.

---

## Where this goes next

1. The user fixes the chapter names and the answers above.
2. `level_design.md`'s rows are filled from the tables here (mission, station,
   population, script).
3. `story_levels.md` / `story_full.md` — the author's own — are rewritten to
   five chapters; this file is the outline they follow.
4. Each sector is built in `tools/level_editor.py`; what has no code yet
   (waves, flee, the named rock, the base ruin) is listed under "Needs" above
   and goes to `open_questions.md` F9/F10 when it is picked up.

---

## Between the sectors (decided 2026-11-27)

* **The tower is one of hundreds.** After 3-2 we come home believing we beat them
  by destroying their base; the picture before 4-1 shows we did not (P10 below).
  This is the main job of the pictures in `level_design.md`.
* **Any chapter can be started from its beginning.** A chapter select, not
  codes (codes may come later). What the chapter then starts with - score,
  ships, Saturnium, weapons the story had given by then (the laser from
  2-2, the EMP from 3-1) - is a fixed loadout per chapter, to be written in
  the table for each chapter. Chapter 1 starts bare; 3 starts with the laser.

---

## The story as it plays, and the pictures it needs

One picture **before** each sector (`level_design.md`): it is the debrief of the
sector just played and the brief of the next, about 300 x 300 px, short text.
Below, each picture is one row: what it shows, the beat the text carries, and
what it can be drawn from (`ship_ref/` already has renders of the tower, the
lifepod, the mine, the pulsar and others). **All text here is a sketch of the
beat, not the wording** - that is the author's. "Story" pictures are distinct;
"neutral" ones can be a reused space scene (their count is the saving).

| id | before | shows | the beat | kind |
|---|---|---|---|---|
| P1 | 1-1 | Titan base, the five SRV ships on the pad, Saturn's rings above | routine: clear the rocks round the base (the intro's hook, `story_intro.md`) | story |
| P2 | 1-2 | the base perimeter clear, freighters coming in along a lane | the field is ready for the transports; a jump needs Saturnium | story (reused for P1's art, new freighters) |
| P3 | 1-3 | a radar scope: a contact that is gone on the next sweep, a lost freighter | a transport lost with no collision; Control says "sensor fault"; scout the source | story |
| P4 | 2-1 | a sample canister and, behind it, the flicker of a hull that is not there | the sample proves it: the rock was a ghost, so something hides in the Saturnium. By accident the way out leads under a dome of shimmering light | story |
| P5 | 2-2 | the dome seen from inside: spider-rocks, a gate beyond the field ringed by UFOs | inside the field there are mining rocks with spiders; the gate opened *outside* | story |
| P6 | 2-3 | the pulsar laser on the ship's hardpoint / a lab bench with the samples | the UFOs wake as others die; we have a weapon; take the report and samples home | neutral possible |
| P7 | 3-1 | the base's command room; the SOS traces on a screen, the pieces fitted to one point | the report is in; the **remains of three pilots' SOS signals** place them in a tower in the void; the way in is the EMP; sweep the middle sector for it | story |
| P8 | 3-2 | the tower (`alien_tower`) in the field's centre, our ship small beside it | second visit: the rescue; rocks inside pay for the EMP and the jump out | story |
| P9 | 3-3 | a lifepod with a pilot, the tower dark behind | the tower is down, **two or three pilots aboard** (lives); we think it is over; home - through what is waking | story |
| **P10** | 4-1 | **Saturn from far away, the rings dotted with hundreds of faint towers** | **the turn:** the base celebrates, the pilots' logs / the scope show the tower was one of hundreds. They know we know | story - the key picture |
| P11 | 4-2 | the base burning, UFOs escaping through the gate | the siege held, some got out through the gate; they must be followed to the source | story |
| P12 | 4-3 | a second tower ringed with mines | third visit: strike the source - rocks out of the field first, spiders on them, then the EMP | story (tower art of P8, mines added) |
| P13 | 5-1 | the **artefact**: a hologram / plate of the aliens' bases | it fell from the tower: the plans of their bases, the proof; it must reach Titan | story |
| P14 | 5-2 | a silent beacon at the base, no answer | the way home is by the inner zone | neutral possible |
| P15 | 5-3 | the rings, the exit marked, the swarm | the last way out; everything they have | neutral possible |
| E1 | ending won | Titan, the ship landing with the artefact | out with what is known: the game is *not* beating them, it is getting this out | story |
| E2 | ending lost | **no picture (decided 2026-11-27):** a plain GAME OVER and back to the title. The player can die at any time, even before meeting the aliens, so no one picture fits. Per-chapter lost pictures are possible later, but the lean is no | none |

Note on 5-2: the player finds the bases and transports destroyed *in the
sector* (the discovery is the gameplay), so P14 must not show the ruin - it is
the one picture that hides what the sector then reveals.

**The aliens erase everything (user, 2026-11-27) - background only.** Their aim
is to wipe out every trace, so they do not stop at killing: in the fiction what
they destroy they also cloak, as they do their own units. This explains 5-2:
the base and the freighters were destroyed while we were away (in 4-3), and the
discovery is what brings the aliens out. **It is not in the game and will not
be:** the engine cannot cloak a destroyed base, so 5-2 simply shows the wrecks
and mines, and the cloaking stays in the story's text and pictures (the
aliens' work is seen as an absence: a silent beacon P14, a freighter that never
arrived). P11 (the burning base in 4-1) is the visible half of the same act.

**Count:** 15 + 1 new ending picture (the won ending only). Candidates to reuse/neutralise, if the
budget needs it (two banks each, `story.md`'s budget note): P2 (P1's art), P6,
P14, P15, P12 (P8's tower). That leaves about **11 distinct** drawn scenes, of
which the must-haves are P1, P3, P5, P8, **P10**, P11, P13, E1.

### Art subjects, as a list for the artist

Titan base and the five SRV ships · a freighter · a radar scope with a ghost
contact · the dome (force field) from outside and inside · spider-rocks · the
gate ringed by UFOs · the pulsar laser · the command room with SOS traces · the
tower · a lifepod with a pilot · Saturn with hundreds of towers · the base
burning · a tower ringed by mines · the artefact · a silent beacon · the rings
and the exit · the landing on Titan.

### What the pictures settle in the story

1. The tower is *not* the only one; P10 is where the player learns it, and
   chapter 4-5 are the response (they attack, we retaliate, we flee).
2. The pilots are found by their SOS remains (P7), not shown abducted.
3. The artefact (P13) is the thing the ending (E1) delivers.
4. The aliens' motive (stay hidden) is only ever *implied*: they burn the base
   (P11) and the ruins (5-2) - never said, as story.md requires.
