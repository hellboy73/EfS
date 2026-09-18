# Escape from Saturn — story index and technical implications

The narrative lives in three documents in this folder. They were written in Polish
by the author and translated here; the Polish originals are in git history at
commit `390346c` if the wording ever needs checking.

| file | what it is |
|---|---|
| [`story_intro.md`](story_intro.md) | the opening text — the hook the player reads first |
| [`story_levels.md`](story_levels.md) | the working script: per-level briefing text + what the gameplay of each level is |
| [`story_full.md`](story_full.md) | the full back story, level by level, plus the reveal |

**Those three files are the source of truth for the fiction.** This file only
records what the fiction *commits us to* technically, so the engine work and the
story stay in step.

---

## Premise, in one paragraph

2093. Corporate probes find **SATURNium** in Saturn's rings — a mineral that bends
electromagnetic and gravitational propagation. Mining begins; sensors start lying;
ships collide with things that were not there a moment earlier. Five crewed survey
ships launch from the Titan base to investigate the anomaly. You fly one of them. The reveal, never
stated outright, is that Saturnium was an alien **cloak** — the aliens have been
hiding at Saturn for a very long time, and mining the mineral is tearing the veil.
Once they realise they are being found, they hunt.

---

## Five levels

| # | name | mission | new gameplay element |
|---|---|---|---|
| 1 | MINING ZONE | clear the field | asteroids only in 1-1; from 1-2 alien ships flicker into view and are gone, never attack, and Control calls them a sensor glitch (the old L2, SENSOR ANOMALY, folded in) |
| 2 | CONTACT | survive first contact | aliens stay visible, and fight when approached |
| 3 | HUNT | get through the region | patrols that detect and pursue; fighting everything is not the intent |
| 4 | *(name TBD)* | save the survivor | a distress call from a mining station under siege: the crew of a lost ship (SRV-T03) holding the station's data. They are caught as a lifepod, and the station is destroyed whatever the player does |
| 5 | ESCAPE | reach the exit alive | many hunters, degraded instruments, and the station's data is the way out |

**Re-cut 2026-09-18 (the user).** L1 alone was rocks only and would have been
dull, so the old L2 (SENSOR ANOMALY) was folded into it. CONTACT and HUNT moved
up one level, the siege became L4, and ESCAPE stays the finale.

**Why the siege, and what the game is about (2026-09-18, the user).** The
aliens do not want to win a war. They want to stay hidden. The mine, while it
was autonomous, could be fooled by them. A crewed ship and a station's records
cannot, so the aliens destroy both, to wipe out what is known about them. That
is why they attack our ships, and why they attack the station. It is also the
clue to the reveal that no line ever states. So **the goal of the game is not
to beat the aliens, it is to get out with what is known about them**.
In order:
* L4: the crew of SRV-T03, lost earlier, took shelter at a station. The
  station's data is the one record the lying instruments could not corrupt: a
  map of the anomaly, and so the way out. The player drags the UFOs off the
  station and catches the crew's lifepod. The station goes anyway, because
  destroying it was the aliens' aim.
* L5: ESCAPE with the crew and the data. Its briefing's "the last known way
  home" is that data. ENDING WON is getting it out.

**`story_levels.md` and `story_full.md` still follow the old five and are the
author's to rewrite.** L1's briefing absorbs SENSOR ANOMALY's or hands it to
the radio in 1-2. L4 needs a name and a briefing. The reveal section gains the
aliens' motive above.

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

**5. Escalating area size — read as difficulty, not map size.** Every sector
is the same torus (`design_technical.md` 11.45); "far larger" in levels 4 and 5
is a far gate, more hunters and lying instruments.

**7. Human mining stations.** The fiction's mining stations are in the
field: a landmark in a world that wraps and so has no other one, and the
story of the human side told by the radio (a station's crew talks). See
`design_technical.md` 11.46.

**6. Five crewed ships — they are the lives.** SRV-T01..T05; losing one hands
over to the next callsign, and the tunnel can bring back a crew lost in that
sector. Losing the fifth offers a CONTINUE, and declining it is the lost ending
(`design_technical.md` 11.45).

---

## Budget note

The story wants briefing text before every level and a reveal at the end. Text is
cheap (its own bank, read straight from the cartridge window). **Full-screen
bitmaps are not** — roughly 15 KB, i.e. two banks each, on a 32-bank cartridge. Ten
illustrated screens would be two-thirds of the cart. Decide the illustrated-screen
count early; see open question F2/F3.
