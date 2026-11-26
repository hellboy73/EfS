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
; half of that - the part load_level can actually act on. The rest is added to
; these same per-level tables as the code that reads it is built.
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
; LVL_FOEN records of SEVEN bytes, read once by foes.s load_foes:
;
;   XL, XH, YL, YH   the world position, 16-bit per axis
;   KIND             0 = the UFO, 1 = the spider, 2 = the pulsar, 3 = the EMP
;                    mine (empmine.s), 4 = a FREIGHTER (freight.s) - not an
;                    enemy and not in an enemy slot: HEADING 0 north / 128
;                    south, SPEED 0 docked. A kind nothing knows is not loaded.
;                    +128 = DORMANT, a GHOST (ghosts.s): kinds 0..3 only, at most
;                    GH_MAX a level, and only in the OUTER zone (ZONE 2) - it
;                    waits as a picture until woken, then flies HEADING /
;                    SPEED; anywhere else it loads awake
;   HEADING          the patrol course, brad, the ship's own convention - 0 flies
;                    toward -Y, "up" in the editor, and 64 toward +X. Unread by
;                    a mine, which never turns to a heading - HEADING and SPEED
;                    are 0 in its records, as a UFO holding its post writes them
;   SPEED            the patrol speed, in PIXELS A SECOND at 1:1, 0..175; 0 is a
;                    UFO that holds its post - and the ONLY value a mine
;                    understands, since it never patrols at all. load_foes turns
;                    it into 8.8 world units a frame (x68, which is
;                    16/60.317*256 to 0.2%)
;
; It was five bytes (position and kind) while nothing flew an enemy. The two
; new ones are what a patrol is: the UFO keeps this course and speed until it
; sees the ship, and it is put back on them the moment it loses it again - see
; foes.s. 175 px/s is the pursuit speed, half the ship's top tier, and no patrol
; is meant to be faster than a chase; the editor clamps to it.
; =============================================================================
; Hand edits are fine anywhere in this file. Everything between the GENERATED
; markers below is also what tools/level_editor.py reads, and what it rewrites
; -- whole, not patched -- on every Save; the editor is the easy way to move a
; rock or reroll a seed, but the numbers are just numbers, so editing them by
; hand and running `make` works exactly as it always did.
; =============================================================================
; WHERE IT LIVES, AND HOW IT IS READ
;
; Every table below is in LEVELS - ROM bank LVL_BANK (cart.cfg, ROM8) - and is
; read straight out of the $8000-$9FFF window, never copied to RAM: a sector
; loads once, so the cartridge's wait states are not felt, and the level count
; is bounded by the bank (8 KB) and not by the 391 bytes DEMO_RAM had left
; when the tables lived in CODE6. A LABEL HERE IS ITS WINDOW ADDRESS.
;
; The code that reads them is the LOADER (loader.s, segment LDCODE), and since
; 2026-11-22 it lives in THIS bank and runs in the window itself - so it reads
; these tables with no lv_open / lv_close (both gone, with LVSAVE). Its one rule
; is the one the old lv_open bracket had: while it runs the window shows ROM, so
; it may WRITE the RAM under the window but never READ it (`sta GTON`, never
; `inc GTON`); anything that reads that RAM is called through WCALL. A per-frame
; reader keeps its own RAM copy, taken once at load - gate.s GTMIS / GTMPR are
; the mission's.
;
; A pointer read from a table (LVL_ROCKLO/HI, LVL_FOELO/HI) is a window address
; and is followed the same way.
; =============================================================================
LVL_BANK    = LDR_BANK          ; cart.cfg: the LEVELS segment's bank - the
                                ;   loader's own, by design (loader.s)

        .segment "LEVELS"

; === GENERATED (tools/level_editor.py) - rewritten whole on Save =============
NLEVELS     = 4

; Level names. A comment, not a table - no level has anything to print them
; on yet, and a string per level is ROM with nothing to spend it on. The editor
; reads and rewrites these lines, so keep the format.
;   NAME 0 "MINING ZONE"
;   NAME 1 "SECTOR ZERO"
;   NAME 2 "FORCE FIELD TEST"
;   NAME 3 "GHOST TEST"

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
;   MISN  what opens the exit gate (gate.s): 0 = the rocks of classes 0..MPAR
;         are all gone (MPAR 0 = the 192s), 1 = every enemy is dead, 2 = open
;         from the start
;   GTX   where the gate stands, world 16-bit - fixed, it never moves
;   BASE_ON  whether this sector has a human base (base.s): 0 = none, 1 =
;         built
;   BASE_X   where it stands, world 16-bit - fixed, it never moves; unread
;         while BASE_ON is 0
;   FF_ON    whether this sector has the force field (ffield.s): 0 = none,
;         1 = there - never with the base (the wall slots, slots.s)
;   FF_X     its centre, world 16-bit; the radius is ffield.s's FF_R, fixed
;   FF_VIS   1 = drawn, 0 = invisible (flashed where it is hit)
;   ZONE     where the sector is, and so which code the wall slots load
;         (slots.s): 1 = INNER, the near neighbourhood - the human base may
;         be there; 2 = OUTER, the farther reaches - the GHOSTS: a rock's
;         TYPE +128 is a ghost rock, a foe's KIND +128 a dormant one, and
;         anywhere else they load as ordinary ones; 3 = VOID, the aliens' own
;         sectors - the force field may be there
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
L0_MISN     = 0
L0_MPAR     = 0
L0_GTX      = $B046
L0_GTY      = $5130
L0_BASE_ON  = 1
L0_BASE_X   = $8000
L0_BASE_Y   = $5800
L0_FF_ON    = 0
L0_FF_X     = $8000
L0_FF_Y     = $8000
L0_FF_VIS   = 1
L0_ZONE     = 1

; level 1 - "SECTOR ZERO"
L1_N192     = 8
L1_N128     = 8
L1_N64      = 15
L1_N32      = 15
L1_N16      = 15
L1_SEED     = $3CA5
L1_SHX      = $8000
L1_SHY      = $8000
L1_SHHD     = 0
L1_MISN     = 3
L1_MPAR     = 0
L1_GTX      = $B046
L1_GTY      = $5130
L1_BASE_ON  = 0
L1_BASE_X   = $8000
L1_BASE_Y   = $5800
L1_FF_ON    = 0
L1_FF_X     = $8000
L1_FF_Y     = $8000
L1_FF_VIS   = 1
L1_ZONE     = 1

; level 2 - "FORCE FIELD TEST"
L2_N192     = 0
L2_N128     = 0
L2_N64      = 0
L2_N32      = 0
L2_N16      = 0
L2_SEED     = $5A17
L2_SHX      = $8000
L2_SHY      = $3000
L2_SHHD     = 128
L2_MISN     = 2
L2_MPAR     = 0
L2_GTX      = $8000
L2_GTY      = $1000
L2_BASE_ON  = 0
L2_BASE_X   = $8000
L2_BASE_Y   = $5800
L2_FF_ON    = 1
L2_FF_X     = $8000
L2_FF_Y     = $8000
L2_FF_VIS   = 1
L2_ZONE     = 3

; level 3 - "GHOST TEST"
L3_N192     = 0
L3_N128     = 2
L3_N64      = 6
L3_N32      = 8
L3_N16      = 8
L3_SEED     = $6B21
L3_SHX      = $8000
L3_SHY      = $8000
L3_SHHD     = 0
L3_MISN     = 2
L3_MPAR     = 0
L3_GTX      = $8000
L3_GTY      = $1800
L3_BASE_ON  = 0
L3_BASE_X   = $8000
L3_BASE_Y   = $5800
L3_FF_ON    = 0
L3_FF_X     = $8000
L3_FF_Y     = $8000
L3_FF_VIS   = 1
L3_ZONE     = 2

; The hand-placed blocks, and the counts DERIVED from their own length - so a
; record added or deleted by hand needs nothing else changed.
; level 0 - "MINING ZONE"
; rocks: XL, XH, YL, YH, class, type - 6 bytes each, class 0..4 = 192..16
LVL0_ROCKS:
LVL0_ROCKS_END:
; enemies: XL, XH, YL, YH, kind, heading, speed - 7 bytes each
LVL0_FOES:
        .byte   $B8, $8B, $D0, $87, 0, 0, 0       ; UFO at 35768, 34768, holding its post
        .byte   $C0, $60, $A0, $8F, 0, 64, 80       ; UFO at 24768, 36768, course 64 at 80 px/s
        .byte   $F8, $AA, $90, $68, 0, 192, 120       ; UFO at 43768, 26768, course 192 at 120 px/s
        .byte   $3C, $76, $D8, $5C, 0, 0, 0       ; UFO at 30268, 23768, holding its post
        .byte   $50, $C6, $00, $80, 0, 128, 175       ; UFO at 50768, 32768, course 128 at 175 px/s
        .byte   $00, $80, $E0, $31, 0, 96, 60       ; UFO at 32768, 12768, course 96 at 60 px/s
        .byte   $0E, $0B, $F4, $28, 1, 0, 0       ; SPIDER at 2830, 10484, holding its post
        .byte   $E7, $B5, $8D, $03, 1, 0, 0       ; SPIDER at 46567, 909, holding its post
        .byte   $F2, $1D, $DF, $C1, 1, 0, 0       ; SPIDER at 7666, 49631, holding its post
        .byte   $59, $6D, $FF, $4E, 2, 64, 40       ; PULSAR at 27993, 20223, course 64 at 40 px/s
        .byte   $75, $50, $6C, $2A, 2, 0, 0       ; PULSAR at 20597, 10860, holding its post
        .byte   $00, $C0, $00, $C0, 3, 0, 0       ; EMP MINE at 49152, 49152, holding its post
        .byte   $00, $40, $00, $40, 3, 0, 0       ; EMP MINE at 16384, 16384, holding its post
        .byte   $00, $80, $50, $65, 4, 128, 0       ; FREIGHTER at 32768, 25936, docked: stern to the base
        .byte   $00, $94, $00, $90, 4, 0, 120       ; FREIGHTER at 37888, 36864, course 0 at 120 px/s
LVL0_FOES_END:
L0_ROCKN    = (LVL0_ROCKS_END - LVL0_ROCKS) / 6
L0_FOEN     = (LVL0_FOES_END - LVL0_FOES) / 7
L0_TOTAL    = L0_N192 + L0_N128 + L0_N64 + L0_N32 + L0_N16 + L0_ROCKN

; level 1 - "SECTOR ZERO"
; rocks: XL, XH, YL, YH, class, type - 6 bytes each, class 0..4 = 192..16
LVL1_ROCKS:
        .byte   $CD, $CC, $14, $6E, 0, 0       ; 192A at 52429, 28180
        .byte   $F1, $95, $0F, $EA, 0, 0       ; 192A at 38385, 59919
        .byte   $23, $18, $74, $DF, 0, 0       ; 192A at 6179, 57204
        .byte   $B1, $69, $CE, $3D, 3, 0       ; 32A at 27057, 15822
        .byte   $FD, $DD, $B1, $E9, 3, 0       ; 32A at 56829, 59825
        .byte   $56, $CB, $09, $E6, 3, 0       ; 32A at 52054, 58889
LVL1_ROCKS_END:
; enemies: XL, XH, YL, YH, kind, heading, speed - 7 bytes each
LVL1_FOES:
        .byte   $00, $30, $00, $60, 0, 0, 0       ; UFO at 12288, 24576, holding its post
        .byte   $0C, $88, $D4, $21, 0, 64, 60       ; UFO at 34828, 8660, course 64 at 60 px/s
        .byte   $82, $09, $75, $D0, 1, 0, 0       ; SPIDER at 2434, 53365, holding its post
        .byte   $04, $D3, $94, $D5, 2, 192, 40       ; PULSAR at 54020, 54676, course 192 at 40 px/s
        .byte   $2F, $20, $71, $1D, 3, 0, 0       ; EMP MINE at 8239, 7537, holding its post
        .byte   $A5, $E1, $45, $9F, 3, 0, 0       ; EMP MINE at 57765, 40773, holding its post
LVL1_FOES_END:
L1_ROCKN    = (LVL1_ROCKS_END - LVL1_ROCKS) / 6
L1_FOEN     = (LVL1_FOES_END - LVL1_FOES) / 7
L1_TOTAL    = L1_N192 + L1_N128 + L1_N64 + L1_N32 + L1_N16 + L1_ROCKN

; level 2 - "FORCE FIELD TEST"
; rocks: XL, XH, YL, YH, class, type - 6 bytes each, class 0..4 = 192..16
LVL2_ROCKS:
        .byte   $00, $80, $00, $60, 0, 0       ; 192A at 32768, 24576 - inside the field
        .byte   $00, $A0, $00, $80, 0, 0       ; 192A at 40960, 32768 - inside the field
        .byte   $00, $60, $00, $28, 1, 0       ; 128A at 24576, 10240
        .byte   $00, $A0, $00, $28, 1, 0       ; 128A at 40960, 10240
        .byte   $00, $50, $00, $40, 1, 0       ; 128A at 20480, 16384
LVL2_ROCKS_END:
; enemies: XL, XH, YL, YH, kind, heading, speed - 7 bytes each
LVL2_FOES:
        .byte   $00, $80, $00, $80, 0, 0, 0       ; UFO at 32768, 32768, holding its post
        .byte   $00, $98, $00, $80, 0, 0, 60       ; UFO at 38912, 32768, course 0 at 60 px/s
        .byte   $00, $20, $00, $20, 0, 64, 60       ; UFO at 8192, 8192, course 64 at 60 px/s
        .byte   $00, $98, $00, $2C, 0, 0, 0       ; UFO at 38912, 11264, holding its post
LVL2_FOES_END:
L2_ROCKN    = (LVL2_ROCKS_END - LVL2_ROCKS) / 6
L2_FOEN     = (LVL2_FOES_END - LVL2_FOES) / 7
L2_TOTAL    = L2_N192 + L2_N128 + L2_N64 + L2_N32 + L2_N16 + L2_ROCKN

; level 3 - "GHOST TEST"
; rocks: XL, XH, YL, YH, class, type - 6 bytes each, class 0..4 = 192..16
LVL3_ROCKS:
        .byte   $00, $80, $00, $70, 0, 128       ; 192A ghost at 32768, 28672
        .byte   $00, $74, $00, $78, 1, 129       ; 128B ghost at 29696, 30720
        .byte   $00, $8C, $00, $78, 2, 130       ; 64C ghost at 35840, 30720
        .byte   $00, $80, $00, $64, 3, 128       ; 32A ghost at 32768, 25600
        .byte   $00, $70, $00, $88, 0, 0       ; 192A at 28672, 34816
        .byte   $00, $90, $00, $88, 1, 0       ; 128A at 36864, 34816
LVL3_ROCKS_END:
; enemies: XL, XH, YL, YH, kind, heading, speed - 7 bytes each
LVL3_FOES:
        .byte   $00, $80, $00, $58, 128, 0, 0       ; GHOST UFO at 32768, 22528, holding its post
        .byte   $00, $68, $00, $68, 130, 64, 40       ; GHOST PULSAR at 26624, 26624, course 64 at 40 px/s
        .byte   $00, $98, $00, $68, 131, 0, 0       ; GHOST EMP MINE at 38912, 26624, holding its post
        .byte   $00, $80, $00, $70, 129, 0, 0       ; GHOST SPIDER at 32768, 28672, holding its post
LVL3_FOES_END:
L3_ROCKN    = (LVL3_ROCKS_END - LVL3_ROCKS) / 6
L3_FOEN     = (LVL3_FOES_END - LVL3_FOES) / 7
L3_TOTAL    = L3_N192 + L3_N128 + L3_N64 + L3_N32 + L3_N16 + L3_ROCKN

; -----------------------------------------------------------------------------
; The tables load_level indexes by level. Nothing here is a number: every cell
; is one of the constants above, so this half of the file cannot drift from it.
; -----------------------------------------------------------------------------
LVL_N192:   .byte   L0_N192, L1_N192, L2_N192, L3_N192
LVL_N128:   .byte   L0_N128, L1_N128, L2_N128, L3_N128
LVL_N64:    .byte   L0_N64, L1_N64, L2_N64, L3_N64
LVL_N32:    .byte   L0_N32, L1_N32, L2_N32, L3_N32
LVL_N16:    .byte   L0_N16, L1_N16, L2_N16, L3_N16

LVL_SEEDL:  .byte   <L0_SEED, <L1_SEED, <L2_SEED, <L3_SEED
LVL_SEEDH:  .byte   >L0_SEED, >L1_SEED, >L2_SEED, >L3_SEED

LVL_SHXL:   .byte   <L0_SHX, <L1_SHX, <L2_SHX, <L3_SHX
LVL_SHXH:   .byte   >L0_SHX, >L1_SHX, >L2_SHX, >L3_SHX
LVL_SHYL:   .byte   <L0_SHY, <L1_SHY, <L2_SHY, <L3_SHY
LVL_SHYH:   .byte   >L0_SHY, >L1_SHY, >L2_SHY, >L3_SHY
LVL_SHHD:   .byte   L0_SHHD, L1_SHHD, L2_SHHD, L3_SHHD

LVL_MISN:   .byte   L0_MISN, L1_MISN, L2_MISN, L3_MISN
LVL_MPAR:   .byte   L0_MPAR, L1_MPAR, L2_MPAR, L3_MPAR
LVL_GTXL:   .byte   <L0_GTX, <L1_GTX, <L2_GTX, <L3_GTX
LVL_GTXH:   .byte   >L0_GTX, >L1_GTX, >L2_GTX, >L3_GTX
LVL_GTYL:   .byte   <L0_GTY, <L1_GTY, <L2_GTY, <L3_GTY
LVL_GTYH:   .byte   >L0_GTY, >L1_GTY, >L2_GTY, >L3_GTY

LVL_BASE_ON: .byte   L0_BASE_ON, L1_BASE_ON, L2_BASE_ON, L3_BASE_ON
LVL_BASE_XL: .byte   <L0_BASE_X, <L1_BASE_X, <L2_BASE_X, <L3_BASE_X
LVL_BASE_XH: .byte   >L0_BASE_X, >L1_BASE_X, >L2_BASE_X, >L3_BASE_X
LVL_BASE_YL: .byte   <L0_BASE_Y, <L1_BASE_Y, <L2_BASE_Y, <L3_BASE_Y
LVL_BASE_YH: .byte   >L0_BASE_Y, >L1_BASE_Y, >L2_BASE_Y, >L3_BASE_Y

LVL_FF_ON:  .byte   L0_FF_ON, L1_FF_ON, L2_FF_ON, L3_FF_ON
LVL_FF_XL:  .byte   <L0_FF_X, <L1_FF_X, <L2_FF_X, <L3_FF_X
LVL_FF_XH:  .byte   >L0_FF_X, >L1_FF_X, >L2_FF_X, >L3_FF_X
LVL_FF_YL:  .byte   <L0_FF_Y, <L1_FF_Y, <L2_FF_Y, <L3_FF_Y
LVL_FF_YH:  .byte   >L0_FF_Y, >L1_FF_Y, >L2_FF_Y, >L3_FF_Y
LVL_FF_VIS: .byte   L0_FF_VIS, L1_FF_VIS, L2_FF_VIS, L3_FF_VIS
LVL_ZONE:   .byte   L0_ZONE, L1_ZONE, L2_ZONE, L3_ZONE

LVL_ROCKN:  .byte   L0_ROCKN, L1_ROCKN, L2_ROCKN, L3_ROCKN
LVL_ROCKLO: .byte   <LVL0_ROCKS, <LVL1_ROCKS, <LVL2_ROCKS, <LVL3_ROCKS
LVL_ROCKHI: .byte   >LVL0_ROCKS, >LVL1_ROCKS, >LVL2_ROCKS, >LVL3_ROCKS

LVL_FOEN:   .byte   L0_FOEN, L1_FOEN, L2_FOEN, L3_FOEN
LVL_FOELO:  .byte   <LVL0_FOES, <LVL1_FOES, <LVL2_FOES, <LVL3_FOES
LVL_FOEHI:  .byte   >LVL0_FOES, >LVL1_FOES, >LVL2_FOES, >LVL3_FOES

; The one thing a level cannot be allowed to get wrong, checked by the
; assembler rather than discovered in the simulator.
        .assert L0_TOTAL <= NOBJ, error, "level 0 (MINING ZONE) asks for more rocks than NOBJ slots"
        .assert (L0_ZONE >= 1) && (L0_ZONE <= 3), error, "level 0 (MINING ZONE): ZONE is 1 inner, 2 outer or 3 void"
        .assert (!L0_BASE_ON) || (L0_ZONE = 1), error, "level 0 (MINING ZONE) has the base outside the inner zone (ZONE 1)"
        .assert (!L0_FF_ON) || (L0_ZONE = 3), error, "level 0 (MINING ZONE) has the force field outside the void (ZONE 3)"
        .assert L1_TOTAL <= NOBJ, error, "level 1 (SECTOR ZERO) asks for more rocks than NOBJ slots"
        .assert (L1_ZONE >= 1) && (L1_ZONE <= 3), error, "level 1 (SECTOR ZERO): ZONE is 1 inner, 2 outer or 3 void"
        .assert (!L1_BASE_ON) || (L1_ZONE = 1), error, "level 1 (SECTOR ZERO) has the base outside the inner zone (ZONE 1)"
        .assert (!L1_FF_ON) || (L1_ZONE = 3), error, "level 1 (SECTOR ZERO) has the force field outside the void (ZONE 3)"
        .assert L2_TOTAL <= NOBJ, error, "level 2 (FORCE FIELD TEST) asks for more rocks than NOBJ slots"
        .assert (L2_ZONE >= 1) && (L2_ZONE <= 3), error, "level 2 (FORCE FIELD TEST): ZONE is 1 inner, 2 outer or 3 void"
        .assert (!L2_BASE_ON) || (L2_ZONE = 1), error, "level 2 (FORCE FIELD TEST) has the base outside the inner zone (ZONE 1)"
        .assert (!L2_FF_ON) || (L2_ZONE = 3), error, "level 2 (FORCE FIELD TEST) has the force field outside the void (ZONE 3)"
        .assert L3_TOTAL <= NOBJ, error, "level 3 (GHOST TEST) asks for more rocks than NOBJ slots"
        .assert (L3_ZONE >= 1) && (L3_ZONE <= 3), error, "level 3 (GHOST TEST): ZONE is 1 inner, 2 outer or 3 void"
        .assert (!L3_BASE_ON) || (L3_ZONE = 1), error, "level 3 (GHOST TEST) has the base outside the inner zone (ZONE 1)"
        .assert (!L3_FF_ON) || (L3_ZONE = 3), error, "level 3 (GHOST TEST) has the force field outside the void (ZONE 3)"
; === END GENERATED ===
