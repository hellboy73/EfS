; =============================================================================
; levels.s - the opening state of every level: how many rocks of each size the
; field is scattered with, the rocks and enemies placed by hand on top of that
; scatter, and where the ship starts. Split out of main.s for the same reason
; shapes.s was - so the level editor (tools/level_editor.py) has one file to
; read and write, and so the content of a level can be argued with without
; reading the flight code around it.
;
; design_technical.md 9 calls this a level's MISSION PLAN and lists what one
; eventually has to carry: world size, initial population, size-class mix, the
; enemy roster, physics overrides and the music. What is here is the population
; half of that - the part proto 02 can actually act on. The rest is added to
; these same per-level tables as the benches that need it are built.
; =============================================================================
; HOW A FIELD IS BUILT (load_level, main.s)
;
; Two passes, in this order, filling object slots from 0 upwards:
;
;   1. THE SCATTER. LVL_N192..LVL_N16 say how many rocks of each size class the
;      level wants; load_level drops exactly that many at random positions over
;      the whole torus. A 16-bit world coordinate is uniform by construction, so
;      "random position" is two random bytes per axis and nothing else - there
;      is no world boundary to keep away from and no rejection loop.
;
;      This replaced SHAPE_PICK, an eight-ticket table in main.s that gave the
;      size mix only IN EXPECTATION: ask for 120 rocks and you got roughly 15 of
;      the biggest, not 15. A count per class is what a level actually wants to
;      state, and it is also the number a designer can reason about ("four of
;      the 192s is a maze, twelve is a wall").
;
;   2. THE PLACED ROCKS. LVL_ROCKN records of six bytes each, appended after the
;      scatter, at exact world positions - the set-pieces: a cluster guarding a
;      route, a ring, a corridor of chips. These are the ones the editor lets
;      you drag.
;
; Lx_SEED is the LFSR state the scatter starts from, so the random half is
; random in SHAPE but not in OUTCOME: the same level lays out the same field on
; every run, and an unlucky arrangement can be reproduced, looked at, and then
; rerolled by changing this one word rather than by reseeding the whole program.
; The editor previews the exact field a seed produces - it runs main.s's own
; prng, in load_level's own order - so a reroll is judged before it is saved,
; not after it is flown.
;
; Velocity and spin are NOT per rock and are not here: they come from AST_VEL /
; AST_SPIN / AST_PHASE in main.s, indexed by size class and by the object slot,
; exactly as they did when the whole field was random. A level says WHAT and
; WHERE; how a 192 drifts is a property of 192s.
; =============================================================================
; HOW THIS FILE IS SHAPED, AND WHY
;
; The generated block is in two halves. The FIRST is a set of Lx_ CONSTANTS -
; one per level per number. The SECOND is the LVL_ tables load_level actually
; indexes, and not one cell in them is a literal: every one is a constant from
; the first half. So the two halves cannot drift apart, and a number edited by
; hand in the first half is the number the game gets.
;
; Two things are then DERIVED rather than stated, because a stated count is a
; count that can go stale:
;
;   Lx_ROCKN / Lx_FOEN  the length of that level's block divided by the record
;                       size. Add or delete a record by hand and the count
;                       follows; there is nothing to remember to update.
;   Lx_TOTAL            the five scatter counts plus Lx_ROCKN - the level's
;                       whole rock population, which the .assert at the bottom
;                       of the block checks against NOBJ. Asking for more rocks
;                       than there are object slots is an ASSEMBLY ERROR naming
;                       the level, not a run-time surprise.
; =============================================================================
; ENEMIES
;
; LVL_FOEN records of five bytes: a world position and a KIND byte. Nothing in
; proto 02 reads them - enemies are the next bench, and open_questions E6 has
; not yet settled how many alien types there are or how they behave - but the
; positions are authored here now so that bench inherits a level format instead
; of inventing one, and so the editor has somewhere to put them. The KIND byte
; is deliberately just a number until E6 says what the numbers are.
; =============================================================================
; Hand edits are fine anywhere in this file. Everything between the GENERATED
; markers below is also what tools/level_editor.py reads, and what it rewrites
; -- whole, not patched -- on every Save; the editor is the easy way to move a
; rock or reroll a seed, but the numbers are just numbers, so editing them by
; hand and running `make` works exactly as it always did.
; =============================================================================

; === GENERATED (tools/level_editor.py) - rewritten whole on Save =============
NLEVELS     = 1

; Level names. A comment, not a table - no level has anything to print them
; on yet, and a string per level is ROM the bench cannot spend. The editor
; reads and rewrites these lines, so keep the format.
;   NAME 0 "MINING ZONE"

; -----------------------------------------------------------------------------
; What each level asks for. THIS is the source: the tables further down are
; built out of these constants, and the .assert at the bottom of the block sums
; each level out of them and checks it against main.s's NOBJ - so a count
; changed here by hand is picked up everywhere, including by the assembler,
; which will refuse to build a level that cannot fit in the object slots.
;
;   Nx    how many rocks of that size class the scatter drops (see the header)
;   SEED  the LFSR word the scatter starts from - any nonzero value
;   SHX   where the ship starts, world 16-bit; SHHD its heading in brad, 0 = +Y
; -----------------------------------------------------------------------------
; level 0 - "MINING ZONE"
L0_N192     = 15
L0_N128     = 15
L0_N64      = 30
L0_N32      = 30
L0_N16      = 30
L0_SEED     = $3CA5
L0_SHX      = $8000
L0_SHY      = $8000
L0_SHHD     = 0

; The hand-placed blocks, and the counts DERIVED from their own length - so a
; record added or deleted by hand needs nothing else changed.
; level 0 - "MINING ZONE"
; rocks: XL, XH, YL, YH, class, type - 6 bytes each, class 0..4 = 192..16
LVL0_ROCKS:
LVL0_ROCKS_END:
; enemies: XL, XH, YL, YH, kind - 5 bytes each
LVL0_FOES:
              .byte   $B8, $8B, $D0, $87, 0
              .byte   $C0, $60, $A0, $8F, 0
              .byte   $F8, $AA, $90, $68, 1
              .byte   $3C, $76, $D8, $5C, 1
              .byte   $50, $C6, $00, $80, 0
              .byte   $00, $80, $E0, $31, 1
LVL0_FOES_END:
L0_ROCKN    = (LVL0_ROCKS_END - LVL0_ROCKS) / 6
L0_FOEN     = (LVL0_FOES_END - LVL0_FOES) / 5
L0_TOTAL    = L0_N192 + L0_N128 + L0_N64 + L0_N32 + L0_N16 + L0_ROCKN

; -----------------------------------------------------------------------------
; The tables load_level indexes by level. Nothing here is a number: every cell
; is one of the constants above, so this half of the file cannot drift from it.
; -----------------------------------------------------------------------------
LVL_N192:   .byte   L0_N192
LVL_N128:   .byte   L0_N128
LVL_N64:    .byte   L0_N64
LVL_N32:    .byte   L0_N32
LVL_N16:    .byte   L0_N16

LVL_SEEDL:  .byte   <L0_SEED
LVL_SEEDH:  .byte   >L0_SEED

LVL_SHXL:   .byte   <L0_SHX
LVL_SHXH:   .byte   >L0_SHX
LVL_SHYL:   .byte   <L0_SHY
LVL_SHYH:   .byte   >L0_SHY
LVL_SHHD:   .byte   L0_SHHD

LVL_ROCKN:  .byte   L0_ROCKN
LVL_ROCKLO: .byte   <LVL0_ROCKS
LVL_ROCKHI: .byte   >LVL0_ROCKS

LVL_FOEN:   .byte   L0_FOEN
LVL_FOELO:  .byte   <LVL0_FOES
LVL_FOEHI:  .byte   >LVL0_FOES

; The one thing a level cannot be allowed to get wrong, checked by the
; assembler rather than discovered in the simulator.
        .assert L0_TOTAL <= NOBJ, error, "level 0 (MINING ZONE) asks for more rocks than NOBJ slots"
; === END GENERATED ===
