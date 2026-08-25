# Escape from Saturn — story

> **Placeholder.** The narrative is being written separately and will be dropped
> in here. Nothing below is canon yet.

## What this document should end up containing

- **Premise** — who the player is, why they are at Saturn, what "escape" means.
- **Act structure** — how the campaign is divided, and where the difficulty and
  tone turns land.
- **Per-level beats** — for each level: the situation, the mission objective (this
  feeds the level plan in `design_technical.md` section 9), and the text shown
  before and after.
- **Antagonists** — who or what the enemies are, which maps onto the enemy roster
  in `open_questions.md` E6.
- **Ending(s)**.

## What the story constrains technically

Worth flagging as the text arrives, because these are the places narrative turns
into bank space and code:

- **Number of levels** drives the level-script bank and the mission-type variety.
- **Text volume** lives in its own bank, read straight from the cartridge window
  (never copied to RAM).
- **Briefing / cutscene screens** are full-screen 1-bit bitmaps at roughly 15 KB
  each, i.e. **two banks per screen**. This is the fastest way to run out of a
  256 KB cartridge, so the count matters early.
- **Music**: each distinct track is a VGM stream, bank-aligned. In the sister
  project CETAS one gameplay song was 11 banks on its own.
- **Named enemies / bosses** need art, behaviour and possibly their own physics
  overrides.
