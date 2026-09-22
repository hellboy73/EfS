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
;                    mine (empmine.s). A kind nothing knows how to fly is not
;                    loaded at all
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
; The window shows the level bank only between lv_open and lv_close, and
; level_begin runs INSIDE win_off (window.s) - the object pool and the enemies'
; state are the RAM under that window. So, in every reader:
;
;   1. READ a level table only between lv_open and lv_close. Outside them the
;      window shows the RAM under it and the read returns whatever the object
;      pool left there, silently.
;   2. Between them, WRITE the RAM under the window but never READ it: a write
;      reaches the RAM whatever CART_EN says, a read returns the ROM. `inc GTON`
;      is a read; `sta GTON` is not.
;   3. A per-frame reader keeps its own RAM copy, taken once at load - gate.s
;      GTMIS / GTMPR are the mission's.
;   4. No nesting: there is one save byte, LVSAVE.
;
; A pointer read from a table (LVL_ROCKLO/HI, LVL_FOELO/HI) is a window address
; and is followed under the same rule.
; =============================================================================
LVL_BANK    = 8                 ; cart.cfg: the LEVELS segment's bank
LVSAVE      = $73B6             ; the bank byte lv_open borrowed the window from.
                                ;   IT WAS $73B4, AND $73B4 IS EMPHAVE'S:
                                ;   pickup.s's block grew by one byte when the
                                ;   EMP pickup landed and this equate did not
                                ;   follow, so every lv_open wrote a bank byte
                                ;   over "the player has an EMP" and every
                                ;   pickup wrote a flag over the bank the window
                                ;   is owed. Hand-placed RAM does not collide
                                ;   loudly (design_technical 11.22); the assert
                                ;   below is what makes it loud from here on.
                                ;   $73B5 is left free on purpose - it is the
                                ;   next byte of pickup.s's block, should that
                                ;   one grow again. window.s's WINSAVE starts at
                                ;   $73C0.
        .assert EMPHAVE < LVSAVE && LVSAVE < WINSAVE, error, "levels.s: LVSAVE has landed inside pickup.s's block or past WINSAVE"

        .pushseg
        .segment "CODE6"

; -----------------------------------------------------------------------------
; lv_open / lv_close - show the level bank in the window, and hand it back.
; -----------------------------------------------------------------------------
; The same borrow as hud_game.s's msg_open / msg_close: save CART_BANK_MIR, select
; the bank with CART_EN set, restore the whole saved byte. Clobber A only.
; -----------------------------------------------------------------------------
lv_open:
        lda     CART_BANK_MIR
        sta     LVSAVE
        lda     #LVL_BANK | CART_EN
        jmp     API_CART_BANK

lv_close:
        lda     LVSAVE
        jmp     API_CART_BANK

; lv_rec6 - the rock record at (T0) into LVREC, six bytes. Y, A clobbered.
lv_rec6:
        jsr     lv_open
        ldy     #$05
:       lda     (T0),y
        sta     LVREC,y
        dey
        bpl     :-
        jmp     lv_close                ; tail
        .popseg

        .segment "LEVELS"

; === GENERATED (tools/level_editor.py) - rewritten whole on Save =============
NLEVELS     = 1

; Level names. A comment, not a table - no level has anything to print them
; on yet, and a string per level is ROM with nothing to spend it on. The editor
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
;   MISN  what opens the exit gate (gate.s): 0 = the rocks of classes 0..MPAR
;         are all gone (MPAR 0 = the 192s), 1 = every enemy is dead, 2 = open
;         from the start
;   GTX   where the gate stands, world 16-bit - fixed, it never moves
;   BASE_ON  whether this sector has a human base (base.s): 0 = none, 1 =
;         built
;   BASE_X   where it stands, world 16-bit - fixed, it never moves; unread
;         while BASE_ON is 0
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
LVL0_FOES_END:
L0_ROCKN    = (LVL0_ROCKS_END - LVL0_ROCKS) / 6
L0_FOEN     = (LVL0_FOES_END - LVL0_FOES) / 7
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

LVL_MISN:   .byte   L0_MISN
LVL_MPAR:   .byte   L0_MPAR
LVL_GTXL:   .byte   <L0_GTX
LVL_GTXH:   .byte   >L0_GTX
LVL_GTYL:   .byte   <L0_GTY
LVL_GTYH:   .byte   >L0_GTY

LVL_BASE_ON: .byte   L0_BASE_ON
LVL_BASE_XL: .byte   <L0_BASE_X
LVL_BASE_XH: .byte   >L0_BASE_X
LVL_BASE_YL: .byte   <L0_BASE_Y
LVL_BASE_YH: .byte   >L0_BASE_Y

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
