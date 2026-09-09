; =============================================================================
; hud_game.s - the instrument panel, on the background layer
; =============================================================================
; hud.s next door is a TUNING readout: VTEXT onto the IMAGE layer, ~48,700 GPU
; cycles a frame, and switched off (HUD_ON = 0). This is the shipping HUD, and it
; is a different thing in every respect that matters. It goes on the VRAM
; BACKGROUND (design_technical 5.5), which the hardware re-copies under the image
; for nothing - so once a line is drawn it costs the GPU ZERO per frame. The whole
; cost of this file is the handful of frames on which a number actually changes.
;
; THE LAYOUT, in the player's 300 x 400 portrait view. VTEXT's grid is TEXT's
; transpose - 37 CELLS across (OS_ARG+0, the column: portrait x = 9 + 8*cell) by
; 50 LINES down (OS_ARG+1, the row: portrait y = 8*line) - so "cell" is the column
; and "line" is the row, and both count the way a reader expects.
;
;   line  2   .......... a centred, transient message ..........
;   ...
;   line 47   LIVES: 3  |xxxxxxxxxxxx|          <-- radar
;   line 48   (blank)                            <-- radar
;   line 49   LEVEL: 1  SCORE: 0000120           <-- radar
;
; A CLEAR LINE BETWEEN THEM: the rows are 47 and 49, not 48 and 49. Eight pixels
; of leading is the difference between two readings and a block of text.
;
; THE TWO ROWS ARE THE SAME WIDTH AND THE COLUMNS LINE UP. Both are exactly 24
; cells, both end on cell 23 - the last one clear of the radar - and the score
; block is exactly as wide as the hull bar and sits directly under it, so the
; "S" of SCORE lands under the opening pipe and the last digit under the closing
; one. The bar is 14 cells (two pipes round twelve of fill) and "SCORE: " plus
; seven digits is fourteen too; that is not a coincidence, it is the constraint
; the two field widths were chosen against.
;
; THE BAR IS PROPORTIONAL, NOT SO-MANY-CHARACTERS-PER-POINT. HP_MAX (main.s) is
; expected to change - a hull upgrade, a harder level, a different ship - and a
; bar that read "two cells per hit point" would silently overrun its box the
; first time it did. hud_bar_fill scales instead: fill = hp * HP_CELLS / HP_MAX,
; rounded, clamped, and never zero while the ship is alive. Raising HP_MAX needs
; no edit here at all, and the assert below is what stops it overflowing the byte
; the arithmetic runs in.
;
; A LINE IS EMITTED ONLY AS LONG AS ITS CONTENT, AND THAT IS LOAD-BEARING.
; TEXT_BG writes whole bytes, so a SPACE is not "leave this alone" - it is an
; instruction to clear that cell. Emitting a padded 37-column row therefore wipes
; everything to the right of the text, and what is to the right of these three
; rows is the radar: the instrument moved to the bottom-right corner (radar.s
; RADCX/RADCY, portrait x 199..299 = cell 24 onwards) and it shares lines 37..49
; with all three of them. The first version of this file blanked to column 36 and
; quietly ate the ring.
;
; So each row has a FIXED WIDTH of its own - its buffer is exactly that long, so
; it cannot be got wrong by editing a loop bound - and the asserts below are the
; sentence "nothing reaches the radar" in a form the assembler can check.
;
; WHY THE PACING EXISTS. A background text command is REPLAYED by the OS into the
; other double-buffer on the following frame, and it replays the POINTER, not the
; bytes. Two consequences, both load-bearing:
;
;   * a line's buffer must not be touched until its replay has been and gone, so
;     each of the four lines gets its OWN buffer and they are never shared;
;   * a second bg-text command issued INSIDE that window stomps the replay, one
;     buffer keeps the old line, and the row BLINKS as the buffers flip.
;
; So one emitter policing itself is not enough - the four here have to be
; serialised against each other. bgtext_claim is that arbiter (and is what a
; fifth emitter must go through too), and hud_tick's phase counter staggers them
; so they never even ask on the same frame: one row per two frames, in an
; 8-frame cycle. The period is 8 and not 6 because there are four emitters now
; and "one line per two frames" is the binding rule; each row therefore repaints
; at ~7.5 Hz, which is far faster than a number needs to be read.
;
; NO CONVERSION ANYWHERE. The score is SIX ASCII DIGITS and score_add does decimal
; carry propagation directly on them (the CETAS pattern) - there is no binary
; score, and therefore no hex-to-decimal, anywhere in this program. Same for the
; level and the lives, which are single digits, and for the hull bar, which is a
; count of characters.
; =============================================================================

LIVES_START  = 9                ; ships in hand at the start of a game. NINE
                                ;   while the field is being flown for tuning;
                                ;   the shipping number is 3. It is a constant so
                                ;   that tools/preview.py reads it rather than
                                ;   hard-coding a digit and going red every time
                                ;   it is changed. LIVES is one digit, so 9 is as
                                ;   high as the readout goes.
HUD_ROW1     = 47               ; LIVES and the hull bar
HUD_ROW2     = 49               ; LEVEL and SCORE
IND_ROW      = 2                ; the message bar - third text row from the top,
                                ;   rows 0 and 1 left clear so it is not hard
                                ;   against the screen edge
HUD_COLS     = 37               ; cells in a row (VTEXT clamps the cell to 0-36)
HUD_IND_BUF  = HUD_COLS + 1     ; the message bar spans the row, and may: nothing
                                ;   of the radar's is on line 2

HUD_RADAR_C0 = 24               ; the first cell the radar reaches into. Blips
                                ;   start at portrait x 199, and cell 24 covers
                                ;   194..201 - so cell 23 is the last safe one

; --- the left field, common to both rows -------------------------------------
C_LABEL      = 0                ; "LIVES: " / "LEVEL: " then one digit
C_LABEL_NUM  = 7
C_RIGHT      = 10               ; ...and where the right-hand field starts, on
                                ;   both rows: the hull bar on one, the score on
                                ;   the other, two clear cells after the digit

; --- row 1: LIVES and the hull bar -------------------------------------------
HP_CELLS     = 12               ; cells of fill inside the box. HP_MAX (main.s)
                                ;   is what a full hull is; these two are
                                ;   independent on purpose - see hud_bar_fill
C_HPBAR      = C_RIGHT          ; the opening pipe
C_HPFILL     = C_HPBAR + 1      ; the fill sits between the two pipes
C_HPEND      = C_HPFILL + HP_CELLS  ; ...and the closing one
HUD_L1_LEN   = C_HPEND + 1

; --- row 2: LEVEL and SCORE --------------------------------------------------
SCORE_DIGITS = 7                ; ...and every one of them is shown, leading
                                ;   zeros included: a fixed-width odometer does
                                ;   not jump about as it fills
C_SCORE      = C_RIGHT          ; "SCORE: " then SCORE_DIGITS digits - exactly
C_SCORE_NUM  = C_SCORE + 7      ;   as wide as the bar above it
HUD_L2_LEN   = C_SCORE_NUM + SCORE_DIGITS

        .assert HUD_L1_LEN <= HUD_RADAR_C0, error, "hud_game.s: row 1 reaches the radar"
        .assert HUD_L2_LEN <= HUD_RADAR_C0, error, "hud_game.s: row 2 reaches the radar"
        .assert HUD_L1_LEN = HUD_L2_LEN, error, "hud_game.s: the two rows no longer line up"
        .assert C_LABEL_NUM < C_RIGHT, error, "hud_game.s: the label runs into the right-hand field"
        .assert HP_MAX * HP_CELLS + HP_MAX / 2 <= 255, error, "hud_game.s: hud_bar_fill's product no longer fits a byte - raise HP_MAX and it must go 16-bit"
        .assert HP_MAX >= 1, error, "hud_game.s: hud_bar_fill would divide by zero"
        .assert HUD_ROW2 - HUD_ROW1 >= 2, error, "hud_game.s: the two rows have no clear line between them"
        .assert HUD_ROW2 <= 49 && IND_ROW <= 49, error, "hud_game.s: a row is off the VTEXT grid"

; --- the pacing --------------------------------------------------------------
BGTEXT_HOLD  = 2                ; frames a bg text line owns the layer - the OS
                                ;   replays the command into the other buffer on
                                ;   the FOLLOWING frame
HUD_PERIOD   = 8                ; frames between repaints of any one line
HUD_PH_ROW1  = 0                ; ...and the phase each takes. Two apart, so no
HUD_PH_ROW2  = 2                ;   two ever land inside another's replay window
HUD_PH_IND   = 4
HUD_PH_OVER  = 6                ; ...and the game-over banner, which is an
                                ;   emitter like any other and goes through the
                                ;   same arbiter (gameover.s). It is what makes
                                ;   the period 8 rather than 6, and what makes
                                ;   the header's "four emitters" line above true
                                ;   at last; each row now repaints at ~7.5 Hz
                                ;   rather than 10, which is still far faster
                                ;   than a number needs to be read
        .assert HUD_PH_ROW2 - HUD_PH_ROW1 >= BGTEXT_HOLD, error, "hud_game.s: rows 1 and 2 collide"
        .assert HUD_PH_IND - HUD_PH_ROW2 >= BGTEXT_HOLD, error, "hud_game.s: row 2 and the bar collide"
        .assert HUD_PH_OVER - HUD_PH_IND >= BGTEXT_HOLD, error, "hud_game.s: the bar and the banner collide"
        .assert HUD_PERIOD - HUD_PH_OVER >= BGTEXT_HOLD, error, "hud_game.s: the banner wraps onto row 1"

; --- the message bar ---------------------------------------------------------
IND_TICKS    = 120              ; frames a message is held (~2 s at 60.317 Hz)
IND_TICKS_Q  = 70               ; ...shortened while others are waiting
IND_QMAX     = 4                ; queued messages; a fifth is dropped
IQ_NONE      = $FF              ; nothing on the bar (IND_CUR only)

IM_HULL      = 0                ; the ship took a hit
IM_CRITICAL  = 1                ; ...and it is down to its last hit point
IM_LEVEL     = 2                ; a level just started
IM_LIFE      = 3                ; ...and a ship was lost, but not the last one

; --- RAM ---------------------------------------------------------------------
; $7030-$70FF was the last clear stretch of the page thrust.s and shots.s share
; (the flames end at $701E, the shots' per-bullet trig at $702F). The four line
; buffers are SEPARATE and never shared - see the replay note in the header - and
; each of the three HUD rows is sized to its OWN content, so a row physically
; cannot emit into the radar's columns however the builders are edited.
HUD_L1      = $7030             ; HUD_L1_LEN + NUL
HUD_L2      = $704A             ; HUD_L2_LEN + NUL
IND_BUF     = $7064             ; HUD_IND_BUF - the bar does span the row
SCORE       = $708C             ; SCORE_DIGITS ASCII digits, MSD first. THE score
                                ;   - there is no binary copy of it anywhere
LIVES       = $7093             ; ships in hand, 0-9
CURLEV      = $7094             ; the level on the board, 0-based (shown +1)
HUD_PHASE   = $7095             ; 0..HUD_PERIOD-1, the stagger counter
BGTEXT_GAP  = $7096             ; frames left before another bg text may go out
HC_HP       = $7097             ; the cached inputs. A row is rebuilt only when
HC_LEV      = $7098             ;   one of these stops matching the live state,
HC_LIVES    = $7099             ;   so on a normal frame the HUD is a few byte
HC_SCORE    = $709A             ;   compares - SCORE_DIGITS bytes
IND_TIMER   = $70A1             ; frames the current message has left, 0 = idle
IND_CUR     = $70A2             ; what is on the bar (IQ_NONE = nothing)
IND_QN      = $70A3             ; how many are queued
IND_QD      = $70A4             ; ...and their ids, IND_QMAX of them
HUD_N       = $70A8             ; scratch: a length or a carry, over one call

; -----------------------------------------------------------------------------
; DBG_CLASSES - a TEMPORARY class census, top left, one line per size class
; -----------------------------------------------------------------------------
; Not part of the game, and one edit removes every byte of it. Five short VTEXT
; commands at cell 0 of lines DBG_ROW0..+4 - the largest class at the top, the
; smallest at the bottom - each showing that class' RKLIVE as two hex digits.
;
; On the IMAGE, not the background, and that is the whole reason it can exist at
; all: the background carries the shipping HUD's two-frame replay schedule, and
; the bench checks it (never two lines in one frame, none inside another's replay
; window). A debug tool must not have to join that. The image is rebuilt from the
; background every frame, so it is re-issued every frame; what happens every
; DBG_PERIOD frames is the RE-READ of the census, which is all that was wanted.
; Two glyphs a line is a few hundred GPU cycles, against ~7,000 for a full row.
;
; It starts below IND_ROW rather than at line 0: the message bar spans its whole
; row, and the image composites over the background, so overlapping it would put
; digits on top of "STAY ALIVE".
                                ; DBG_CLASSES itself lives in main.s beside
                                ;   HUD_ON, because cart_frame's .if reads it
                                ;   before this file is included
DBG_PERIOD  = 10                ; frames between re-reads of the census
DBG_ROW0    = 3                 ; the largest class' line; the rest follow down
DBG_CELL    = 0                 ; hard against the left margin
.if DBG_CLASSES
DBG_BUF     = $70B0             ; 5 x 4: two hex digits, a NUL, and a spare byte
                                ;   so the stride is a shift and not a multiply
DBG_WAIT    = $70C4             ; frames left before the next re-read
        .assert DBG_ROW0 > IND_ROW, error, "hud_game.s: the census would land on the message bar"
        .assert DBG_ROW0 + 4 <= 49, error, "hud_game.s: the census runs off the line grid"
.endif

; The one zero-page pointer this file needs, and it is BORROWED. $80-$FF is the
; cartridge's entire zero page and it has four free bytes left, no two of them
; adjacent - so ind_build reads its message text through DEC0/DEC1, the decimal
; scratch of the tuning readout in hud.s. That is not a collision: both are
; single-call scratch, neither survives its own routine, and do_hud and hud_tick
; can never nest - they are called one after another from the frame body, not
; from inside each other. It is written down because the next person who wants a
; zero-page pointer will find the same four bytes.
HUD_PTR     = DEC0

; -----------------------------------------------------------------------------
; hud_init - once, from cart_init, after the level is loaded.
; -----------------------------------------------------------------------------
; RAM is not cleared for us - the boot ROM does not zero the cartridge's pages -
; so every byte the HUD reads has to be written here.
.if DBG_CLASSES
; -----------------------------------------------------------------------------
; dbg_classes - re-read the census every DBG_PERIOD frames, draw it every frame.
; -----------------------------------------------------------------------------
dbg_classes:
        lda     DBG_WAIT
        beq     @read
        dec     DBG_WAIT
        bra     @draw
@read:  lda     #DBG_PERIOD
        sta     DBG_WAIT
        ldx     #$00                    ; class 0 first, so the biggest rocks are
        ldy     #$00                    ;   the top line. Y walks DBG_BUF.
@rl:    lda     RKLIVE,x
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        jsr     dbg_hex
        sta     DBG_BUF,y
        iny
        lda     RKLIVE,x
        and     #$0F
        jsr     dbg_hex
        sta     DBG_BUF,y
        iny
        lda     #$00
        sta     DBG_BUF,y
        iny
        iny                             ; the spare byte of the 4-wide stride
        inx
        cpx     #$05
        bne     @rl

@draw:  ldx     #$00
@dl:    lda     #DBG_CELL
        sta     OS_ARG+0
        txa
        clc
        adc     #DBG_ROW0
        sta     OS_ARG+1
        stz     OS_ARG+2                ; no sub-cell scroll
        txa                             ; the string: DBG_BUF + class * 4
        asl     a
        asl     a
        clc
        adc     #<DBG_BUF
        sta     OS_ARG+3
        lda     #>DBG_BUF
        adc     #$00
        sta     OS_ARG+4
        phx
        jsr     API_GPU_VTEXT
        plx
        inx
        cpx     #$05
        bne     @dl
        rts

; A = a nibble 0-15, out as its ASCII digit. The carry is doing real work here:
; the compare leaves it SET for 10-15, so the +6 arrives as +7, and CLEAR again
; before the +'0' on both paths.
dbg_hex:
        cmp     #$0A
        bcc     :+
        adc     #$06
:       adc     #'0'
        rts
.endif

; -----------------------------------------------------------------------------
hud_init:
        ldx     #SCORE_DIGITS-1         ; "000000": the score IS these digits
        lda     #'0'
@sc:    sta     SCORE,x
        dex
        bpl     @sc
        lda     #LIVES_START            ; ships in hand at the start of a game
        sta     LIVES
        stz     CURLEV
        stz     BGTEXT_GAP
        jsr     indicate_reset
        ; fall through to hud_reset

; -----------------------------------------------------------------------------
; hud_reset - make every cached input impossible, so every row repaints.
; -----------------------------------------------------------------------------
; Call after anything that wipes the background - cart_frame's one-shot CLEAR_BG
; and the overrun repair beside it - or the HUD would stay blank until a number
; happened to change on its own. $FF can never equal a real input: HP is 0..5,
; the level and the lives are small, and the score digits are ASCII.
; -----------------------------------------------------------------------------
hud_reset:
        lda     #HUD_PERIOD-1           ; next tick wraps to phase 0, so row 1
        sta     HUD_PHASE               ;   repaints at the first opportunity
        lda     #$FF
        sta     HC_HP
        sta     HC_LEV
        sta     HC_LIVES
        ldx     #SCORE_DIGITS-1
@l:     sta     HC_SCORE,x
        dex
        bpl     @l
        rts

; -----------------------------------------------------------------------------
; bgtext_tick - once per frame, BEFORE any emitter. Ages the shared window.
; -----------------------------------------------------------------------------
bgtext_tick:
        lda     BGTEXT_GAP
        beq     @ret
        dec     BGTEXT_GAP
@ret:   rts

; -----------------------------------------------------------------------------
; bgtext_claim - may I put a background text line out this frame?
;   out: C SET   = yes, and the layer is mine for BGTEXT_HOLD frames
;        C CLEAR = no, someone's replay is still in flight; come back later
; Every background-text emitter in this cartridge goes through here.
; -----------------------------------------------------------------------------
bgtext_claim:
        lda     BGTEXT_GAP
        bne     @busy
        lda     #BGTEXT_HOLD
        sta     BGTEXT_GAP
        sec
        rts
@busy:  clc
        rts

; -----------------------------------------------------------------------------
; hud_tick - once per frame, EARLY. The whole HUD's timeline.
; -----------------------------------------------------------------------------
; Cheap on a normal frame: an increment, one compare, and on four frames in eight
; a handful of byte compares that find nothing has changed. A row is built and
; emitted only when its own inputs have actually moved.
;
; A row that wanted to emit but could not claim the layer leaves its caches STALE
; on purpose - that is what makes it try again on its next phase instead of
; silently dropping the update.
; -----------------------------------------------------------------------------
hud_tick:
        jsr     ind_timer_tick          ; the bar's hold runs on EVERY frame, so a
                                        ;   message is held for the time it was
                                        ;   promised and not a multiple of eight
        inc     HUD_PHASE
        lda     HUD_PHASE
        cmp     #HUD_PERIOD
        bcc     @have
        stz     HUD_PHASE
        lda     #0
@have:
        cmp     #HUD_PH_ROW1
        beq     hud_row1
        cmp     #HUD_PH_ROW2
        beq     hud_row2
        cmp     #HUD_PH_IND
        beq     @bar
        cmp     #HUD_PH_OVER
        beq     @over
        rts
@bar:   jmp     indicate_tick           ; a jmp, not a branch: the builders and the
                                        ;   emitters sit between here and there
@over:  jmp     gameover_row            ; ...and the banner's, which lives in
                                        ;   gameover.s with the state it reads

; --- row 1: LIVES and the hull bar -------------------------------------------
hud_row1:
        lda     SHIPHP
        cmp     HC_HP
        bne     @do
        lda     LIVES
        cmp     HC_LIVES
        bne     @do
        rts                             ; nothing moved
@do:    jsr     bgtext_claim
        bcc     @skip
        jsr     hud_build_row1
        lda     SHIPHP                  ; the caches are taken only NOW: had the
        sta     HC_HP                   ;   claim failed they would still be stale
        lda     LIVES                   ;   and this row would retry next phase
        sta     HC_LIVES
        jmp     hud_emit_row1           ; tail
@skip:  rts

; --- row 2: LEVEL and SCORE --------------------------------------------------
hud_row2:
        lda     CURLEV
        cmp     HC_LEV
        bne     @do
        ldx     #SCORE_DIGITS-1
@cmp:   lda     SCORE,x
        cmp     HC_SCORE,x
        bne     @do
        dex
        bpl     @cmp
        rts
@do:    jsr     bgtext_claim
        bcc     @skip
        jsr     hud_build_row2
        lda     CURLEV
        sta     HC_LEV
        ldx     #SCORE_DIGITS-1
@cp:    lda     SCORE,x
        sta     HC_SCORE,x
        dex
        bpl     @cp
        jmp     hud_emit_row2           ; tail
@skip:  rts

; -----------------------------------------------------------------------------
; hud_build_row1 - "LIVES: n" and the hull bar, into HUD_L1.
; -----------------------------------------------------------------------------
; The bar is HP_PER_HP characters per hit point, left-aligned between two pipes,
; the rest left as the spaces hud_blank_l1 wrote - so a hull at 2 of 5 reads
; "|xxxx       |" and the box does not change width as it empties. A fixed-width
; box is also what gives this row a fixed emit length, which is what keeps it off
; the radar.
; -----------------------------------------------------------------------------
hud_build_row1:
        jsr     hud_blank_l1
        ldx     #0                      ; "LIVES: "
        ldy     #C_LABEL
@lab:   lda     STR_LIVES,x
        sta     HUD_L1,y
        iny
        inx
        cpx     #7
        bne     @lab
        lda     LIVES
        clc
        adc     #'0'
        sta     HUD_L1+C_LABEL_NUM
        lda     #'|'                    ; the box
        sta     HUD_L1+C_HPBAR
        sta     HUD_L1+C_HPEND
        jsr     hud_bar_fill            ; ...and X cells of fill inside it
        beq     @done
        ldy     #C_HPFILL
        lda     #'x'
@fill:  sta     HUD_L1,y
        iny
        dex
        bne     @fill
@done:  rts

; -----------------------------------------------------------------------------
; hud_bar_fill - how many cells of the hull bar are lit.
;   out: X = fill, 0..HP_CELLS, and Z set when it is 0
; -----------------------------------------------------------------------------
;   fill = (SHIPHP * HP_CELLS + HP_MAX/2) / HP_MAX
;
; PROPORTIONAL, and that is the whole point: HP_MAX is a game parameter that is
; expected to move (main.s), while HP_CELLS is a property of the box the bar has
; to fit in. Tying them together with "two characters per hit point" made the two
; one number, and the first hull upgrade would have written past the closing pipe.
;
; No multiply: HP_MAX is small, so the product is a short add loop and the divide
; a short subtract loop - a few hundred cycles, once every HUD_PERIOD frames at
; most, on a row that only rebuilds when the hull actually changed. The assert on
; HP_MAX * HP_CELLS above is what keeps all of it inside one byte.
;
; ROUNDED, not truncated (the + HP_MAX/2), so a hull just under half reads as
; half rather than as less. And NEVER ZERO WHILE ALIVE: a ship on its last point
; of a twenty-point hull rounds to nothing, and an empty box would say "dead"
; when it is not. Zero is reserved for actually zero.
; -----------------------------------------------------------------------------
hud_bar_fill:
        lda     SHIPHP
        beq     @empty                  ; genuinely gone: an empty box, and Z set
        cmp     #HP_MAX+1               ; clamp: a medkit past full must not
        bcc     :+                      ;   overrun the box
        lda     #HP_MAX
:       tax                             ; X = hp, the add loop's counter
        lda     #HP_MAX/2               ; the rounding term, added up front
@mul:   clc
        adc     #HP_CELLS
        dex
        bne     @mul                    ; A = hp * HP_CELLS + HP_MAX/2
        ldx     #0
@div:   cmp     #HP_MAX                 ; ...divided by HP_MAX
        bcc     @got
        sec
        sbc     #HP_MAX
        inx
        bra     @div
@got:   cpx     #HP_CELLS+1             ; clamp again: rounding at the top can
        bcc     :+                      ;   land one past a full box
        ldx     #HP_CELLS
:       cpx     #0
        bne     @ret
        inx                             ; alive, but rounded away - show one cell
@ret:   cpx     #0                      ; set Z for the caller
        rts
@empty: ldx     #0
        rts

; -----------------------------------------------------------------------------
; hud_build_row2 - "LEVEL: n" and "SCORE: dddddd", into HUD_L2.
; -----------------------------------------------------------------------------
; Every cell of this row is written on every build - the two labels, the two
; numbers and the three spaces between them - so it needs no blanker: there is
; never anything stale left to erase. Every score digit prints, LEADING ZEROS AND
; ALL: a fixed-width odometer, which does not shift its digits sideways as the
; score grows past a power of ten, and which lines up cell for cell with the hull
; bar on the row above.
; -----------------------------------------------------------------------------
hud_build_row2:
        ldx     #0                      ; "LEVEL: "
        ldy     #C_LABEL
@lab:   lda     STR_LEVEL,x
        sta     HUD_L2,y
        iny
        inx
        cpx     #7
        bne     @lab
        lda     CURLEV                  ; 0-based in the game, 1-based on screen
        clc
        adc     #'1'
        sta     HUD_L2+C_LABEL_NUM
        lda     #' '                    ; the gap, written rather than assumed
        ldy     #C_LABEL_NUM+1
:       sta     HUD_L2,y
        iny
        cpy     #C_RIGHT
        bne     :-
        ldx     #0                      ; "SCORE: ", starting under the bar's pipe
        ldy     #C_SCORE
@lab2:  lda     STR_SCORE,x
        sta     HUD_L2,y
        iny
        inx
        cpx     #7
        bne     @lab2
        ldx     #0                      ; ...and the digits, verbatim
        ldy     #C_SCORE_NUM
@dig:   lda     SCORE,x
        sta     HUD_L2,y
        iny
        inx
        cpx     #SCORE_DIGITS
        bne     @dig
        stz     HUD_L2+HUD_L2_LEN       ; the terminator, and the row stops there
        rts

; -----------------------------------------------------------------------------
; hud_blank_l1 / hud_blank_ind - spaces, then the NUL.
; -----------------------------------------------------------------------------
; Only two, and each hard-wired to its own buffer, because the cartridge's zero
; page has no spare PAIR of bytes for a pointer (see HUD_PTR above). Absolute,Y
; costs the same four cycles as (zp),y and needs no pointer at all.
;
; Row 2 needs no blanker: every one of its cells is written on every build. Row 1
; has one, because the hull bar's fill shrinks and the cells it gives up have to
; go back to spaces.
;
; Blanking only as far as the row's OWN length is the point of the whole design:
; a space is not "leave this cell alone", it is "clear this cell", and the cells
; past these lengths belong to the radar.
; -----------------------------------------------------------------------------
hud_blank_l1:
        ldy     #HUD_L1_LEN-1
        lda     #' '
:       sta     HUD_L1,y
        dey
        bpl     :-
        stz     HUD_L1+HUD_L1_LEN
        rts

hud_blank_ind:
        ldy     #HUD_COLS-1
        lda     #' '
:       sta     IND_BUF,y
        dey
        bpl     :-
        stz     IND_BUF+HUD_COLS
        rts

; -----------------------------------------------------------------------------
; hud_emit_row1 / hud_emit_row2 - one VTEXT_BG command apiece.
; -----------------------------------------------------------------------------
; OS_ARG+0 is the CELL (the column) and OS_ARG+1 the LINE (the row): the vertical
; grid is the horizontal one transposed, so both count the way the layout comment
; at the top of this file draws them. The buffer must stay put until the OS has
; replayed the command on the next frame - it does, because the arbiter will not
; let this row be rebuilt for another HUD_PERIOD frames.
; -----------------------------------------------------------------------------
hud_emit_row1:
        stz     OS_ARG+0                ; cell 0 - the left margin
        lda     #HUD_ROW1
        sta     OS_ARG+1
        stz     OS_ARG+2                ; no sub-cell scroll
        lda     #<HUD_L1
        sta     OS_ARG+3
        lda     #>HUD_L1
        sta     OS_ARG+4
        jmp     API_GPU_VTEXT_BG

hud_emit_row2:
        stz     OS_ARG+0
        lda     #HUD_ROW2
        sta     OS_ARG+1
        stz     OS_ARG+2
        lda     #<HUD_L2
        sta     OS_ARG+3
        lda     #>HUD_L2
        sta     OS_ARG+4
        jmp     API_GPU_VTEXT_BG

ind_emit:
        stz     OS_ARG+0
        lda     #IND_ROW
        sta     OS_ARG+1
        stz     OS_ARG+2
        lda     #<IND_BUF
        sta     OS_ARG+3
        lda     #>IND_BUF
        sta     OS_ARG+4
        jmp     API_GPU_VTEXT_BG

; =============================================================================
; The message bar
; =============================================================================
; MESSAGES ARE QUEUED, NOT OVERWRITTEN. indicate_msg never draws anything: it
; appends an id to a short FIFO, and indicate_tick shows the head once the bar is
; free. Two events in the same second therefore play one after the other instead
; of the second wiping the first off the screen after three frames. The rest of
; the behaviour follows from that:
;
;   * a repeat of what is already showing, or already waiting, is DROPPED - so a
;     ship grinding along a rock cannot back the queue up;
;   * a message that expires with another waiting is drawn STRAIGHT OVER it, one
;     emit and no blank frame between, because every emit rewrites the whole row;
;   * the hold shortens to IND_TICKS_Q while anything is waiting, so a burst
;     drains at a readable pace instead of taking eight seconds.
;
; The bar's TIMER runs every frame (ind_timer_tick, from hud_tick) but its EMIT
; happens only on phase HUD_PH_IND, and even then only if bgtext_claim agrees.
;
; This is the ONE row that spans the full width, and may: line 2 is at the top of
; the screen, where nothing of the radar's is.
; =============================================================================

indicate_reset:
        stz     IND_TIMER
        stz     IND_QN
        lda     #IQ_NONE
        sta     IND_CUR
        rts

; -----------------------------------------------------------------------------
; indicate_msg - A = IM_* id. Queue it. Clobbers A/X.
; -----------------------------------------------------------------------------
indicate_msg:
        cmp     IND_CUR                 ; already on the bar -> drop
        beq     @drop
        ldx     IND_QN                  ; already waiting -> drop
        beq     @add
@scan:  dex
        cmp     IND_QD,x
        beq     @drop
        cpx     #0
        bne     @scan
@add:   ldx     IND_QN
        cpx     #IND_QMAX
        bcs     @drop                   ; full -> the newcomer loses; it is a FIFO
        sta     IND_QD,x
        inc     IND_QN
@drop:  rts

; -----------------------------------------------------------------------------
; ind_timer_tick - age the message on the bar. Every frame, from hud_tick.
; -----------------------------------------------------------------------------
; Counts down to 1 and STOPS there: "expired, still on screen". The clearing emit
; is indicate_tick's job on its own phase, which is what keeps this file to one
; background command per phase however the timer happens to land.
; -----------------------------------------------------------------------------
ind_timer_tick:
        lda     IND_TIMER
        cmp     #2
        bcc     @ret                    ; 0 = idle, 1 = expired and waiting
        dec     IND_TIMER
@ret:   rts

; -----------------------------------------------------------------------------
; indicate_tick - the bar's emit. Reached from hud_tick on phase HUD_PH_IND.
; -----------------------------------------------------------------------------
indicate_tick:
        lda     IND_TIMER
        beq     @idle                   ; bar empty: is anything waiting?
        cmp     #1
        bne     @ret                    ; still showing
        lda     IND_QN                  ; expired. Next one straight over it...
        bne     @next
        jsr     bgtext_claim            ; ...or blank the row
        bcc     @ret                    ; can't yet - hold it one more phase
        stz     IND_TIMER
        lda     #IQ_NONE
        sta     IND_CUR
        jsr     hud_blank_ind
        jmp     ind_emit                ; tail
@idle:  lda     IND_QN
        beq     @ret
@next:  jsr     bgtext_claim
        bcc     @ret
        bra     ind_next
@ret:   rts

; -----------------------------------------------------------------------------
; ind_next - pop the head, render it centred, emit it, arm the hold.
; -----------------------------------------------------------------------------
ind_next:
        lda     IND_QD                  ; take the head...
        sta     IND_CUR
        dec     IND_QN                  ; ...and shift the rest down
        ldx     #0
@sh:    cpx     IND_QN
        bcs     @armed
        lda     IND_QD+1,x
        sta     IND_QD,x
        inx
        bra     @sh
@armed:
        lda     IND_QN                  ; a queue behind it shortens the hold
        beq     :+
        lda     #IND_TICKS_Q
        bra     @set
:       lda     #IND_TICKS
@set:   sta     IND_TIMER
        ldx     IND_CUR                 ; its text, out of the id tables
        lda     IND_LO,x
        sta     HUD_PTR
        lda     IND_HI,x
        sta     HUD_PTR+1
        jsr     ind_build               ; centred into IND_BUF
        jmp     ind_emit                ; tail

; -----------------------------------------------------------------------------
; ind_build - HUD_PTR -> a NUL-terminated string; centre it in IND_BUF.
; -----------------------------------------------------------------------------
; The only place in this file that needs a zero-page pointer, because a message's
; text is the one source whose address is not known at assembly time. See the
; note on HUD_PTR at the top.
; -----------------------------------------------------------------------------
ind_build:
        ldy     #0                      ; measure it (clamped to the row)
@len:   lda     (HUD_PTR),y
        beq     @got
        iny
        cpy     #HUD_COLS
        bne     @len
@got:   sty     HUD_N
        jsr     hud_blank_ind           ; clobbers A/Y, not HUD_N or HUD_PTR
        lda     #HUD_COLS               ; start column = (37 - length) / 2
        sec
        sbc     HUD_N
        lsr     a
        tax                             ; X walks the destination
        ldy     #0                      ; Y walks the source
@cp:    cpy     HUD_N
        beq     @done
        lda     (HUD_PTR),y
        sta     IND_BUF,x
        inx
        iny
        bra     @cp
@done:  rts

; =============================================================================
; score_add - A = points to add to the six ASCII digits. Preserves X and Y.
; =============================================================================
; The score IS the string. There is no binary total anywhere, so nothing ever
; converts anything: this adds the points into the ones place and carries leftward
; in DECIMAL, digit by digit, exactly as it would be done by hand. The carry out
; of a digit can be up to 25 (255 points landing in the ones place), so the
; division is a subtract loop rather than a compare - it runs at most 26 times on
; the first digit and at most once on any other.
;
; Preserving X and Y is not politeness: the callers are inside collision and kill
; loops that hold an object index in one of them.
;
; Past 999,999 the score wraps. Six digits is what row 3 has room for beside the
; radar, and at 10 a hit and 50 a break that is a very long game.
; =============================================================================
score_add:
        phx
        phy
        sta     HUD_N                   ; HUD_N = the carry into this digit
        ldx     #SCORE_DIGITS-1
@dig:   lda     SCORE,x
        sec
        sbc     #'0'                    ; ASCII -> 0..9
        clc
        adc     HUD_N                   ; + the carry in (up to 255 on the first)
        ldy     #0                      ; ...so Y:A is a 9-bit value
        bcc     :+
        ldy     #1
:       phx
        ldx     #0                      ; X = the quotient: the carry OUT
@d10:   cpy     #0
        bne     @sub
        cmp     #10
        bcc     @done10
@sub:   sec
        sbc     #10
        bcs     :+
        dey                             ; borrow into the high half
:       inx
        bra     @d10
@done10:
        stx     HUD_N                   ; the carry into the next digit up
        plx
        clc
        adc     #'0'                    ; the remainder, back to ASCII
        sta     SCORE,x
        dex
        bpl     @dig
        ply
        plx
        rts

; =============================================================================
; The strings
; =============================================================================
; Fixed-length labels (the builders copy an exact count, so no NUL is needed) and
; NUL-terminated messages (ind_build measures them).
; =============================================================================
        .segment "RODATA"

STR_LEVEL:  .byte   "LEVEL: "
STR_SCORE:  .byte   "SCORE: "
STR_LIVES:  .byte   "LIVES: "

IM_HULL_S:  .byte   "HULL BREACH", 0
IM_CRIT_S:  .byte   "HULL CRITICAL", 0
IM_LEVEL_S: .byte   "STAY ALIVE", 0
IM_LIFE_S:  .byte   "SHIP LOST", 0

IND_LO:     .byte   <IM_HULL_S, <IM_CRIT_S, <IM_LEVEL_S, <IM_LIFE_S
IND_HI:     .byte   >IM_HULL_S, >IM_CRIT_S, >IM_LEVEL_S, >IM_LIFE_S

        .segment "CODE2"
