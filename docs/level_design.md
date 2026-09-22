# level_design.md — per-level, per-sector breakdown

15 boards, `1-1` .. `5-3` (`design_technical.md` 11.45: 5 levels x 3 sectors,
one fixed torus size for every sector). This file is where each board's
content gets decided: mission, population, station, and any scripted
event/trigger it needs. It does not replace the other docs — it is where their
per-sector consequences land:

- **Narrative** (what happens, why, what the briefing/radio says) is
  `story.md` / `story_levels.md` / `story_full.md`, the author's own — this
  file does not invent story beats, only records the gameplay shape a
  decided beat needs.
- **Engine facts** (what a mission type can check, what a trigger/condition
  can be, RAM/GPU budgets) belong in `design_technical.md` once fixed, and
  are tracked as open in `open_questions.md` (F1 mission types, F9 enemy
  pool/conditions, H5 sector-flags-for-the-tunnel, E11 stations) until then.
- When a board's row here is filled in, the level editor
  (`tools/level_editor.py`) and `levels.s` are what actually build it; this
  file is the plan, not the data.

Only L4 has a settled per-sector breakdown so far (`design_technical.md`
11.46). Everything else below is a skeleton to fill in.

## How to read a sector's row

- **Mission** — one of the built kinds (`gate.s` `MS_ROCKS` / `MS_FOES` /
  `MS_OPEN`) or a still-open one (F1: survive/traverse).
- **Station** — none, or a human base (`base.s`, `design_technical.md` 11.46
  §11.46/48), and its state (working / silent / under siege / wreck).
- **Population** — what's new or notable about the rocks/enemies, relative to
  the level's own gameplay element in `story.md`.
- **Script/triggers** — anything beyond "mission done opens the gate": a
  scripted arrival, a condition on an enemy's spawn (F9), a flag the tunnel's
  debrief reads afterward (H5). Blank until we decide EfS needs one here.

---

## LEVEL 1 — MINING ZONE (clear the field)

| sector | mission | station | population | script/triggers |
|---|---|---|---|---|
| 1-1 | | | | |
| 1-2 | | | | |
| 1-3 | | | | |

## LEVEL 2 — CONTACT (survive first contact)

| sector | mission | station | population | script/triggers |
|---|---|---|---|---|
| 2-1 | | | | |
| 2-2 | | | | |
| 2-3 | | | | |

## LEVEL 3 — HUNT (get through the region)

| sector | mission | station | population | script/triggers |
|---|---|---|---|---|
| 3-1 | | | | |
| 3-2 | | | | |
| 3-3 | | | | |

## LEVEL 4 — RESCUE (save the survivor)

Settled, `design_technical.md` 11.46:

| sector | mission | station | population | script/triggers |
|---|---|---|---|---|
| 4-1 | | none | | radio: fragments of a distress call, bearing unsure (instruments lie) |
| 4-2 | | none | | a wreck along the way |
| 4-3 | | the siege station — working, then falls | UFOs holding station round it, firing, until they see the ship | station falls scripted, only in the player's presence (how "presence" is measured is still open — `open_questions.md` under 11.46) |

Open under this level (`open_questions.md`, 11.46's TBD list): what counts as
"in the player's presence", how long after that the station falls, what
becomes of the UFOs once it has, how far off they "see" the ship, what the
fall's pieces are and how long they last, whether the wreck is solid or a
picture.

## LEVEL 5 — ESCAPE (reach the exit alive)

| sector | mission | station | population | script/triggers |
|---|---|---|---|---|
| 5-1 | | | | |
| 5-2 | | | | |
| 5-3 | | | | |

---

## Standing questions this file will keep bumping into

- **Which sectors get a station** (`open_questions.md` E11): only 4-3 is
  fixed. Candidates floated so far: 1-1 (the station the field is cleared
  for), a dark/silent station in L3.
- **The trigger/condition vocabulary** is not built yet — only sketched for
  enemy spawns (F9: room / after N seconds / ship within R of a point /
  mission done / previous entry dead). Whether story-level triggers (own a
  weapon, kill a specific foe, cross an invisible marker, a sector-wide
  timer regardless of position) reuse that same record-and-condition
  mechanism, or need their own, is still open — this is where a sector's row
  will surface what the vocabulary actually needs to cover.
- **A sector needing two mission conditions at once** (F1) — e.g. "keep the
  laser before the gate opens" — is unresolved; the mission field above is
  one value today (`GTMIS`/`GTMPR`, `gate.s`).
