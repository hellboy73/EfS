; =============================================================================
; screens.s - the power-on INTRO, the TITLE screen, and the line into the game
; =============================================================================
; SCR_STATE decides what a frame is. SC_PLAY is 0 and is the game exactly as it
; was: cart_frame tests the byte once and falls straight into the flight. Every
; other value hands the whole frame to scr_frame here, before any of the game's
; passes run, so while a screen is up the world is not simulated, not drawn and
; not paid for.
;
;   SC_INTRO   black; the MAD-65 logo; MISSION / ASTEROID / DESTRUCTION revealed
;              one at a time; then the blinder
;   SC_TLOAD   the title picture streamed onto the background under the blinder
;   SC_TITLE   the picture, the marquee one line above the bottom, and FIRE
;
; THE PICTURES ARE BACKGROUND, SENT COMPRESSED. Both go through the transport
; block (MAD-65 CPU OS): RECT_BG_BEGIN arms the rectangle, then RECT_BG_CART
; sends one RLE band at a time straight out of the cartridge, and the GPU
; expands it. tools/artgen.py cut them into bands and packed the bands into
; banks 5-6; the runtime only walks its table (art_step). No CPU1 RAM holds a
; pixel of either.
;
; THE BLINDER hides every stream-in. It goes on before a picture's first band
; and comes off two frames after its last, which is when the OS's replay of
; that band has landed in the second of the two background buffers - so a
; picture is only ever seen whole.
;
; WHERE IT LIVES. The code is UICODE, copied by the bootstrap into CART_HIRAM
; behind CODE5. Its state is in KEEP (hiscore.s), straight after the hiscore
; table: always mapped, no bracket, and a pointer into it may be handed to the
; OS. The state is set by scr_boot from cart_init, because KEEP holds the CPU
; OS demo's bytes on entry.
; =============================================================================

SC_PLAY     = 0
SC_INTRO    = 1
SC_TLOAD    = 2
SC_TITLE    = 3
SC_SECTOR   = 4                 ; SECTOR COMPLETED - gate.s sector_frame

VR_BLIND_OFF = 4                ; API_GPU_VREG sub-ops (MAD65_CPU_OS.md)
VR_BLIND_ON  = 5

; --- the intro, in the player's portrait view --------------------------------
; The logo is 128 x 80 and the Makefile places it at portrait (22,160): its right
; edge on the screen's centre line (x 150) and centred top to bottom (160..239).
; The words start one cell right of that line: VTEXT puts cell X at 2 + 8X px.
INTRO_COL   = 19                ; x 154
INTRO_LINE  = 23                ; lines 23 / 25 / 27 = y 184..223, the logo's middle
SETTLE      = 2                 ; frames for a background write's replay to land

; --- WHEN, set against the title song's opening, in FRAMES SINCE POWER-ON -----
; (FRAME, which cart_init zeroes; 60.317 Hz.) Nothing here reads the song - the
; numbers were read off it once: the sketch opens on a tick every 0.467 s, and
; its chords come in at 3.733 s. The logo goes up on the first tick, as soon as
; its band has landed; each word takes the next one; the title is shown on the
; chords. Change the song and these are the numbers to change.
INTRO_TICK  = 28                ; 0.467 s
INTRO_W1    = 1 * INTRO_TICK    ; MISSION
INTRO_W2    = 2 * INTRO_TICK    ; ASTEROID
INTRO_W3    = 3 * INTRO_TICK    ; DESTRUCTION
TITLE_SHOW  = 225               ; 3.733 s: the blinder comes off the title
TLOAD_LEAD  = 17                ; ...and goes on this much earlier. The load is
                                ;   ~13 frames - arm 1, five batches of four
                                ;   bands every other frame (art_step says why),
                                ;   replay 2 - and the reveal waits for
                                ;   TITLE_SHOW anyway
INTRO_END   = TITLE_SHOW - TLOAD_LEAD
        .assert TITLE_SHOW < 256, error, "screens.s: the intro's clock is FRAME's low byte"
        .assert INTRO_W3 < INTRO_END, error, "screens.s: the last word would come after the screen has gone dark"

; --- the marquee --------------------------------------------------------------
SC_LINE     = 48                ; one above the bottom line of the 37 x 50 VTEXT grid
SC_WIN      = 39                ; 37 visible cells + the two guard cells a
                                ;   character enters from the right through
SC_SPEED    = 1                 ; px a frame
SC_TERM     = $FF

; --- PUSH FIRE ---------------------------------------------------------------
; On the image layer, drawn on the frames it is lit and simply not drawn on the
; others - so a blink costs nothing to switch off, and nothing to clean up when
; FIRE ends the title.
PF_DELAY    = 603               ; frames of title before it starts: 10 s
PF_ON       = 30                ; frames lit...
PF_OFF      = 30                ; ...and dark
PF_LINE     = 1                 ; one below the top line
PF_COL      = (37 - (pf_text_end - pf_text - 1)) / 2   ; centred: cell 14

; --- state, in KEEP straight after the hiscore table ---------------------------
SCR_STATE   = HOF_END           ; SC_*
SCR_PH      = HOF_END + 1       ; the step inside the state
SCR_T       = HOF_END + 2       ; frames counted inside a step
SCR_BI      = HOF_END + 3       ; art_step: the next band's offset in ART_TAB
SCR_BE      = HOF_END + 4       ; ...and the picture's end
SC_PTRL     = HOF_END + 5       ; the marquee's first character in SC_MSG
SC_PTRH     = HOF_END + 6
SC_SCRL     = HOF_END + 7       ; ...and how many px it has slid left, 0-7
PF_WAITL    = HOF_END + 8       ; frames of title left before PUSH FIRE, 16-bit
PF_WAITH    = HOF_END + 9
PF_PH       = HOF_END + 10      ; ...then the blink's place, 0..PF_ON+PF_OFF-1
JOYPORT     = HOF_END + 11      ; THE PLAYING PORT, as an offset from JOY1: 0 is
                                ;   port 1, JOY2-JOY1 is port 2. Set by the FIRE
                                ;   that starts a game, from either port, and
                                ;   read by everything that reads a stick
                                ;   (input.s, gameover.s, sfx.s) as JOY1,x -
                                ;   CETAS's joy_port. Port 1 from power-on
SCR_SKIP    = HOF_END + 12      ; nonzero: FIRE skipped the intro, so the title
                                ;   is shown as soon as it has loaded
SC_BUF      = HOF_END + 13      ; SC_WIN characters + NUL, handed to VTEXT
        .assert JOY2 - JOY1 = 3 && JOY2_PRESS - JOY1_PRESS = 3 && JOY2_PREV - JOY1_PREV = 3, error, "screens.s: JOYPORT indexes the two ports' triples by one stride"
SCR_END     = SC_BUF + SC_WIN + 1
        .assert SCR_END <= HIRAM_TOP, error, "screens.s: the screens' state runs out of KEEP"
        .assert SC_PLAY = 0, error, "screens.s: cart_frame tests SCR_STATE for zero"

        .pushseg

        .include "screens_art.s"        ; GENERATED - the pictures (artgen.py)
        .include "scroller_text.s"      ; SC_MSG - the marquee's text, by hand

        .segment "UICODE"

; -----------------------------------------------------------------------------
; scr_boot - from cart_init: the machine powers on into the intro.
; -----------------------------------------------------------------------------
scr_boot:
        lda     #SC_INTRO
        sta     SCR_STATE
        stz     SCR_PH
        stz     JOYPORT                 ; port 1 until a FIRE says otherwise
        stz     SCR_SKIP
        rts

; -----------------------------------------------------------------------------
; scr_frame - the whole frame while SCR_STATE is not SC_PLAY.
; -----------------------------------------------------------------------------
scr_frame:
        lda     SCR_STATE
        cmp     #SC_SECTOR
        bne     :+
        jmp     sector_frame
:       cmp     #SC_TITLE
        bne     :+
        jmp     title_frame
:       cmp     #SC_TLOAD
        bne     intro_frame
        jmp     tload_frame

; -----------------------------------------------------------------------------
; intro_frame
; -----------------------------------------------------------------------------
intro_frame:
        lda     SCR_PH
        bne     @p1
        lda     #VR_BLIND_ON            ; step 0: hide the OS's boot screen and
        jsr     API_GPU_VREG            ;   clear it off the background
        jsr     API_GPU_CLEARBG
        bra     @next

@p1:    cmp     #1                      ; step 1: the clear's replay lands, then
        bne     @p2                     ;   the logo's rectangle is armed
        jsr     @tick
        bcc     @ret
        ldx     #ART_LOGO
        jsr     art_arm
        bra     @next

@p2:    cmp     #2                      ; step 2: the logo's band(s)
        bne     @p3
        jsr     art_step
        bcs     @ret
        bra     @next

@p3:    cmp     #3                      ; step 3: their replay lands - then the
        bne     @p4                     ;   blinder comes off on a finished logo
        jsr     @tick
        bcc     @ret
        lda     #VR_BLIND_OFF
        jsr     API_GPU_VREG
        bra     @next

@p4:    lda     JOY1_PRESS              ; FIRE on EITHER port skips the rest -
        ora     JOY2_PRESS              ;   from here, once the logo is up, and
        and     #JOY_FIRE               ;   not in the five frames before: those
        beq     @words                  ;   have the logo's band pending, and the
        lda     #1                      ;   title may not re-arm the rectangle
        sta     SCR_SKIP                ;   under a band awaiting its replay
        bra     @dark
@words: ldx     SCR_T                   ; step 4: SCR_T is the next word, and a
        cpx     #3                      ;   word goes out once FRAME has reached
        bcs     @end                    ;   its cue - reached, not equalled, so a
        lda     FRAME                   ;   logo that landed late cannot make a
        cmp     intro_cue,x             ;   word miss its frame and never appear
        bcc     @ret
        inc     SCR_T
        bra     @word                   ; (one a frame at most - the cues are a
                                        ;   tick apart)
@end:   lda     FRAME
        cmp     #INTRO_END
        bcc     @ret
@dark:  lda     #VR_BLIND_ON            ; 3 s: the screen goes dark, and the
        jsr     API_GPU_VREG            ;   title streams in behind it
        lda     #SC_TLOAD
        sta     SCR_STATE
        stz     SCR_PH
@ret:   rts

; One word on the background: static strings, so the OS's replay of the pointer
; on the next frame reads the same bytes (the replay contract), and the cues are
; INTRO_TICK apart, so no two background lines go out on adjacent frames.
@word:  lda     #INTRO_COL
        sta     OS_ARG+0
        lda     intro_line,x
        sta     OS_ARG+1
        stz     OS_ARG+2
        lda     intro_lo,x
        sta     OS_ARG+3
        lda     intro_hi,x
        sta     OS_ARG+4
        jmp     API_GPU_VTEXT_BG

@next:  inc     SCR_PH
        stz     SCR_T
        rts

; C SET once SETTLE frames have been counted in this step.
@tick:  inc     SCR_T
        lda     SCR_T
        cmp     #SETTLE
        rts

intro_cue:  .byte   INTRO_W1, INTRO_W2, INTRO_W3
intro_line: .byte   INTRO_LINE, INTRO_LINE + 2, INTRO_LINE + 4
intro_lo:   .byte   <intro_w1, <intro_w2, <intro_w3
intro_hi:   .byte   >intro_w1, >intro_w2, >intro_w3
intro_w1:   .byte   "MISSION", 0
intro_w2:   .byte   "ASTEROID", 0
intro_w3:   .byte   "DESTRUCTION", 0
        .assert INTRO_COL + (intro_w3 - intro_w2) <= 37, error, "screens.s: DESTRUCTION runs off the VTEXT grid"

; -----------------------------------------------------------------------------
; tload_frame - the title picture, under the blinder the intro left on.
; -----------------------------------------------------------------------------
tload_frame:
        lda     SCR_PH
        bne     @p1
        ldx     #ART_TITLE
        jsr     art_arm
        inc     SCR_PH
        stz     SCR_T                   ; art_step's replay flag starts clear
        rts

@p1:    cmp     #1
        bne     @p2
        jsr     art_step
        bcs     @ret
        inc     SCR_PH
        stz     SCR_T
@ret:   rts

@p2:    inc     SCR_T                   ; the last band's replay has landed...
        lda     SCR_T
        cmp     #SETTLE
        bcc     @ret
        lda     SCR_SKIP                ; ...and, unless FIRE skipped the intro,
        bne     @show                   ;   it is the chords' frame
        lda     FRAME+1
        bne     @show
        lda     FRAME
        cmp     #TITLE_SHOW
        bcc     @ret
@show:  lda     #VR_BLIND_OFF
        jsr     API_GPU_VREG
        lda     #<SC_MSG                ; the marquee from the top of its text
        sta     SC_PTRL
        lda     #>SC_MSG
        sta     SC_PTRH
        stz     SC_SCRL
        lda     #<PF_DELAY              ; ...and PUSH FIRE's wait from the frame
        sta     PF_WAITL                ;   the picture is shown
        lda     #>PF_DELAY
        sta     PF_WAITH
        lda     #$FF                    ; the blink's first step lands on 0: lit
        sta     PF_PH
        lda     #SC_TITLE
        sta     SCR_STATE
        rts

; -----------------------------------------------------------------------------
; title_frame - the marquee, and FIRE starts a game.
; -----------------------------------------------------------------------------
title_frame:
        jsr     marquee
        jsr     push_fire
        ldx     #0                      ; FIRE on either port - and the port it
        lda     JOY1_PRESS              ;   came from is the one that plays
        and     #JOY_FIRE               ;   (JOYPORT). Port 1 wins a tie
        bne     @go
        ldx     #JOY2 - JOY1
        lda     JOY2_PRESS
        and     #JOY_FIRE
        beq     @ret
@go:    stx     JOYPORT
        lda     JOY1_PRESS,x            ; consume the edge, or the press that
        and     #<~JOY_FIRE             ;   starts the game also fires the gun
        sta     JOY1_PRESS,x            ;   on its first frame
        jsr     API_VGM_STOP            ; the title's song is the title's (and
                                        ;   with MUSIC_ON = 0 this only silences
                                        ;   chips that are already silent - it
                                        ;   is not tested, because music.s is
                                        ;   assembled after this file)
        jsr     win_off                 ; a fresh game - game_start walks the
        jsr     game_start              ;   object pool, which lives under the
        jsr     win_on                  ;   window (window.s)
        stz     BGDONE                  ; ...and the flight's first frame wipes
        stz     SCR_STATE               ;   the picture and puts the radar's ring
@ret:   rts                             ;   and the HUD back (cart_frame)

; -----------------------------------------------------------------------------
; push_fire - after PF_DELAY frames of title, PUSH FIRE: PF_ON lit, PF_OFF dark.
; -----------------------------------------------------------------------------
push_fire:
        lda     PF_WAITL                ; still waiting?
        ora     PF_WAITH
        beq     @blink
        lda     PF_WAITL
        bne     :+
        dec     PF_WAITH
:       dec     PF_WAITL
        rts
@blink: lda     PF_PH
        inc     a
        cmp     #PF_ON + PF_OFF
        bcc     :+
        lda     #0
:       sta     PF_PH
        cmp     #PF_ON
        bcs     @ret                    ; the dark half: draw nothing
        lda     #PF_COL
        sta     OS_ARG+0
        lda     #PF_LINE
        sta     OS_ARG+1
        stz     OS_ARG+2
        lda     #<pf_text
        sta     OS_ARG+3
        lda     #>pf_text
        sta     OS_ARG+4
        jmp     API_GPU_VTEXT
@ret:   rts

pf_text:    .byte   "PUSH FIRE", 0
pf_text_end:

; -----------------------------------------------------------------------------
; marquee - SC_WIN characters of SC_MSG on line SC_LINE, slid SC_SCRL px.
; -----------------------------------------------------------------------------
; On the IMAGE layer, rebuilt every frame, so it needs no replay and simply
; stops existing when the title does. T0/T1 are the game's scratch pair and are
; a zero-page pointer here: nothing of the game runs while a screen is up.
; -----------------------------------------------------------------------------
marquee:
        lda     SC_PTRL
        sta     T0
        lda     SC_PTRH
        sta     T1
        ldy     #0
@cp:    lda     (T0)
        cmp     #SC_TERM
        bne     @put
        lda     #<SC_MSG                ; the window runs over the end of the
        sta     T0                      ;   text and on round to its start
        lda     #>SC_MSG
        sta     T1
        lda     (T0)
@put:   sta     SC_BUF,y
        inc     T0
        bne     :+
        inc     T1
:       iny
        cpy     #SC_WIN
        bne     @cp
        lda     #0
        sta     SC_BUF,y

        stz     OS_ARG+0                ; cell 0 ...
        lda     #SC_LINE
        sta     OS_ARG+1
        lda     SC_SCRL                 ; ...slid left by the sub-cell offset
        sta     OS_ARG+2
        lda     #<SC_BUF
        sta     OS_ARG+3
        lda     #>SC_BUF
        sta     OS_ARG+4
        jsr     API_GPU_VTEXT

        lda     SC_SCRL                 ; a whole cell slid: the window steps on
        clc                             ;   one character
        adc     #SC_SPEED
        cmp     #8
        bcc     @st
        sbc     #8                      ; (C is set - no borrow)
        pha
        inc     SC_PTRL
        bne     :+
        inc     SC_PTRH
:       lda     SC_PTRL
        sta     T0
        lda     SC_PTRH
        sta     T1
        lda     (T0)
        cmp     #SC_TERM
        bne     @nw
        lda     #<SC_MSG
        sta     SC_PTRL
        lda     #>SC_MSG
        sta     SC_PTRH
@nw:    pla
@st:    sta     SC_SCRL
        rts

; -----------------------------------------------------------------------------
; art_arm - X = ART_<picture>: arm its rectangle, point art_step at its bands.
; -----------------------------------------------------------------------------
; RECT_BG_BEGIN emits nothing. Never re-arm while a band of the previous
; picture still waits for its replay - the replay would take the new geometry
; (MAD65_CPU_OS.md, the job contract); every caller has SETTLE frames behind it.
; -----------------------------------------------------------------------------
art_arm:
        lda     ART_GEO,x
        sta     OS_ARG+0                ; XB
        lda     ART_GEO+1,x
        sta     OS_ARG+1                ; WB
        lda     ART_GEO+2,x
        sta     OS_ARG+2                ; GAP
        lda     ART_GEO+3,x
        sta     OS_ARG+3                ; H
        lda     ART_GEO+4,x
        sta     SCR_BI
        lda     ART_GEO+5,x
        sta     SCR_BE
        jmp     API_GPU_RECT_BG_BEGIN

; -----------------------------------------------------------------------------
; art_step - send the picture's next ART_BATCH bands, every OTHER frame.
; C CLEAR = all of them are out; C SET = more next frame.
; -----------------------------------------------------------------------------
; THE GPU'S TIME IS THE BOUND, NOT PPRAM. The first cut sent as many bands as
; the 2 KB of PPRAM took - up to five - and a frame of five cost the GPU
; 252,717 cycles, 106% of its frame (measured: the real GPU OS in py65). It
; never finished that list, so the fifth band reached neither background buffer
; and the title had a black vertical bar down its left side, where that band
; lands. A 15-row band decodes 750 bytes for ~49,000 cycles, so four are ~90%.
;
; EVERY OTHER FRAME, because the OS replays each band into the second buffer on
; the NEXT frame: sending a batch on that frame too would stack a new batch on
; top of the replay. So a batch goes out, the next frame is its replay alone,
; and SCR_T - which no caller counts while this runs - is the flag between them.
;
; RECT_BG_CART can still refuse with C set when PPRAM is full, emitting and
; recording nothing; what is left of the batch then goes on the next free frame.
; -----------------------------------------------------------------------------
ART_BATCH   = 4                 ; bands a batch: ~90% of the GPU's frame

art_step:
        lda     SCR_T                   ; last frame sent a batch: this one is
        beq     @go                     ;   its replay, and nothing else
        stz     SCR_T
        sec
        rts
@go:    ldy     #ART_BATCH
@lp:    ldx     SCR_BI
        cpx     SCR_BE
        bcs     @done
        lda     ART_TAB,x
        sta     OS_ARG+0                ; bank
        lda     ART_TAB+1,x
        sta     OS_ARG+1                ; the band's blob, in the window
        lda     ART_TAB+2,x
        sta     OS_ARG+2
        lda     ART_TAB+3,x
        sta     OS_ARG+3                ; its destination row
        lda     ART_TAB+4,x
        sta     OS_ARG+4
        phy                             ; (the builder's registers are its own)
        jsr     API_GPU_RECT_BG_CART
        ply
        bcs     @more                   ; PPRAM full - the rest next time
        lda     #1                      ; a band is out: next frame is replay
        sta     SCR_T
        lda     SCR_BI
        clc
        adc     #5
        sta     SCR_BI
        dey
        bne     @lp
        cmp     SCR_BE
        bcs     @done                   ; the batch ended on the last band
@more:  sec
        rts
@done:  clc
        rts

        .popseg
