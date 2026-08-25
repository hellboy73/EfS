# Escape from Saturn — story index and technical implications

The narrative is written by the author in Polish and lives in three documents in
this folder:

| file | what it is |
|---|---|
| `EFS Wstęp do gry.md` | the opening text — the hook the player reads first |
| `EFS Skrócony scenariusz – 5 poziomów.md` | the working script: per-level briefing text + what the gameplay of each level is |
| `EFS Pełna historia gry – Escape from Saturn.md` | the full back story, level by level, plus the reveal |

**Those three files are the source of truth for the fiction.** This file only
records what the fiction *commits us to* technically, so the engine work and the
story stay in step.

---

## Premise, in one paragraph

2093. Corporate probes find **SATURNium** in Saturn's rings — a mineral that bends
electromagnetic and gravitational propagation. Mining begins; sensors start lying;
ships collide with things that were not there a moment earlier. Eight crewed survey
ships are sent to investigate the anomaly. You fly one of them. The reveal, never
stated outright, is that Saturnium was an alien **cloak** — the aliens have been
hiding at Saturn for a very long time, and mining the mineral is tearing the veil.
Once they realise they are being found, they hunt.

---

## Five levels

| # | name | mission | new gameplay element |
|---|---|---|---|
| 1 | MINING ZONE | clear the field | asteroids only — no enemies at all |
| 2 | SENSOR ANOMALY | clear the field | alien ships flicker into view briefly, do not attack |
| 3 | CONTACT | survive first contact | aliens stay visible, and fight when approached |
| 4 | HUNT | get through the region | patrols that detect and pursue; fighting everything is not the intent |
| 5 | ESCAPE | reach the boundary alive | very large area, many hunters, degraded instruments |

This settles **open question F1** (level count = 5) and gives the mission-type
spread for the level plan in `design_technical.md` section 9. Three distinct
mission types are needed: **clear**, **survive/traverse**, **reach the exit**.

---

## What the fiction commits the engine to

These are the places the story turns into code. Each one is a real feature, not
flavour text.

**1. The wrapping world is diegetic.** The script explicitly says the region loops
— leave one edge, appear at the other — and hangs it on Saturnium folding space
locally. This is a gift: the engine's cheapest structural property (16-bit overflow
wrapping, `design_technical.md` 3.1) is also a plot point, and it is *supposed* to
feel increasingly wrong rather than being an unexamined arcade convention.

**2. Enemies that appear and vanish.** Level 2's whole content is aliens becoming
briefly visible and then gone. Mechanically this is a **cloak state** on an enemy
object — it exists in the world and is simulated continuously; only its visibility
(and later its collidability and targetability) is toggled. Because every object is
persistently tracked (`design_technical.md` 6.1), a decloaking enemy is not a spawn
— it really was there. That is the honest version of the trick, and it is the one
the engine already supports.

**3. Instruments that lie.** By level 5 "the radar no longer shows everything" and
"distances do not always match the instruments". If there is a HUD radar/compass,
it needs a **noise/deception model**: missing contacts, ghost contacts, wrong
bearings — increasing per level. This is a per-level parameter, and it should be
designed *with* the HUD (open question D5), not bolted on.

**4. Detection and pursuit.** Level 4 introduces enemies with a detection radius
and a chase behaviour, and explicitly permits avoidance instead of combat. So the
enemy AI needs at least: patrol, detect, pursue, lose-track. That is the shape of
the enemy roster for open question E6.

**5. Escalating area size.** Levels 4 and 5 are described as far larger than the
earlier ones. World size is per-level data (open question A3), so this is free —
but it means A1 must be settled as a *baseline* with room to grow, not a fixed
constant.

**6. Eight crewed ships.** Eight survey ships are sent and are lost across the
campaign. That is a natural fit for lives, or for a between-level "ships remaining"
count, and it gives the game-over screen its meaning. **(TBD)**

---

## Budget note

The story wants briefing text before every level and a reveal at the end. Text is
cheap (its own bank, read straight from the cartridge window). **Full-screen
bitmaps are not** — roughly 15 KB, i.e. two banks each, on a 32-bank cartridge. Ten
illustrated screens would be two-thirds of the cart. Decide the illustrated-screen
count early; see open question F2/F3.
