; =============================================================================
; radar.s — the HUD radar: what is near, on a fixed scale, in the corner
; =============================================================================
; The bench's one question. Everything here is the honest v1 pipeline of
; open_questions.md G; the lying radar of E8 is a filter applied on top of it
; later, not a second renderer.
;
; THE ONE IDEA. The radar's catchment is a CIRCLE in world space, and a circle
; is invariant under both of the transforms that follow it: the camera's
; rotation, and the radar's own (fixed) scale. So "is this contact on the
; radar" can be answered BEFORE any rotation, on the raw world delta - and once
; a contact passes, nothing downstream can push it out of the box, so there is
; no clipping pass at all. `gpu_dotpixels_clip` ($FF99) exists and is not
; needed here.
;
; THE SECOND IDEA, which is what makes it nearly free: at this scale the LOW
; BYTE of a world delta is noise. One radar pixel is 512 world units, so a
; delta's high byte alone is four times finer than anything that can be drawn.
; Every step below therefore runs on high bytes: the delta is one SBC per axis
; (and the wrap is free - see main.s), the admission test squares a value that
; can never leave 0..50, and the rotation is four byte-indexed table reads.
; There is not one multiply in the whole pass.
;
; THE NUMBERS, and why these three and not others (open_questions G1/G2/G4).
; Radius, scale and footprint are one choice made three ways, and 12,800 is the
; value that makes all three exact at once:
;
;   * 12,800 world units is 50 in position-high-byte units, so the admission
;     test is |dxh| <= 50 and then dxh^2 + dyh^2 <= 2500 - two reads of the
;     quarter-square table the multiply already builds (x*x = f(2x)) and one
;     16-bit compare. No new table, no 16-bit delta, no multiply.
;   * at a world scale of >> 9 that comes out as 25 half-res cells: a 50 x 50
;     cell circle, which is the 100 x 100 full-res box G4 settled on. And >> 9
;     on a value whose useful part is the high byte is >> 1 on THAT byte - so
;     the display scale is one signed halve, which is what RAD_SH = 1 means.
;   * 12,800 is just over three 4096-unit sectors, so the ring to walk is a
;     clean -4..+4 around the ship's own cell.
;
; The scale is a CONSTANT and does not track the camera's zoom (G1). It shares
; the camera's rotation - the same ROT tables do_camera builds - because a
; radar that did not turn with the view would be unreadable, but it must not
; share the zoom, or the reach would breathe with the throttle.
;
; WHAT IS NOT HERE. The ring and the ship icon are not drawn: there is no _BG
; variant of any line or pixel opcode (the VRAM-background window is
; write-only, so setting one bit would need a read-modify-write), which means
; the only way to put static furniture on the background is a bitmap through
; LOAD. That is coming as artwork, not as drawing code. See open_questions G5.
; =============================================================================

; --- tunables ----------------------------------------------------------------
RAD_RH      = 100               ; the catchment radius, in position-HIGH-BYTE
                                ;   units: 100 * 256 = 25,600 world units. It
                                ;   was 50 and the reach read as too short; the
                                ;   BOX did not change with it, because RAD_SH
                                ;   absorbed the difference - the two are one
                                ;   number seen twice and only their ratio is
                                ;   the footprint.
                                ;
                                ;   25,600 is 78% of the 32,768 at which a
                                ;   wrap-correct signed subtract stops being
                                ;   unambiguous, so there is one more doubling
                                ;   in this and no two.
RAD_R2      = RAD_RH * RAD_RH   ; ...and its square, which is what the round
                                ;   test actually compares against
RAD_SH      = 2                 ; the display scale, applied to the HIGH BYTE:
                                ;   this many shifts on top of the >> 8 that
                                ;   reading the high byte already is, so the
                                ;   world-space scale is >> 10
RAD_ROUND   = 1 << (RAD_SH - 1) ; ...and the half that makes that shift ROUND

; The box, as a HALF-RES centre - DOT_PIXELS coordinates are half-res (D8).
; Bottom-left of the PLAYER's screen, which is not the framebuffer's: TATE
; clockwise means fb_x = portrait_y and fb_y = 299 - portrait_x, so "bottom
; left" is high fb_x and high fb_y. Half-res (169, 119) is full-res (338, 238),
; which is portrait x 11..111 and y 288..388 - an 11 px margin on both edges of
; a 300 x 400 screen, clear of the ship (portrait x 150) and clear of the HUD
; text (which runs down the right-hand edge, portrait x 275+).
RADCX       = 174
RADCY       = 124
RAD_SCR     = RAD_RH >> RAD_SH  ; ...and the radius that box holds, 25 cells

; Those two put the instrument HARD INTO THE CORNER: the outermost blip column
; is 174 + 25 = 199, which is the last half-res column there is, and the
; outermost row is 124 + 25 = 149, likewise. It cannot go further. What is left
; over is the ARTWORK, which sits one pixel inside that on each axis - the ring
; is drawn at radius 49 where the blips reach 50 - and a 51-cell disc against an
; even-numbered screen edge; neither is a margin anyone chose.

; The star-suppression disc is ONE CELL WIDER than that, and the extra cell is
; not slack. The two axes round independently, so a contact sitting on the rim
; at 45 degrees lands up to sqrt(2)/2 of a cell outside the circle - inside the
; BOX, always, but outside a disc of exactly RAD_SCR. Suppressing at RAD_SCR
; would leave those few blips sitting on a lit star. It is also the right shape
; for what is coming: the ring artwork (G5) has thickness, and this is where it
; will sit.
RAD_OCR     = RAD_SCR + 1

; ...and its box, CLAMPED to the screen, exactly as add_disc clamps a rock's.
; Pushed into the corner the disc now hangs one cell over two edges, and a box
; that ran past them would index a band that does not exist. The round test is
; unaffected: it works off the true centre and r^2, so a star near the edge is
; still judged against the real circle.
RAD_BX0     = RADCX - RAD_OCR
RAD_BY0     = RADCY - RAD_OCR
.if RADCX + RAD_OCR > 199
RAD_BX1     = 199
.else
RAD_BX1     = RADCX + RAD_OCR
.endif
.if RADCY + RAD_OCR > 149
RAD_BY1     = 149
.else
RAD_BY1     = RADCY + RAD_OCR
.endif

; WHICH SIZE CLASSES THE RADAR IS LOOKING FOR - "sensitivity", and the reason
; this file is affordable at all now that the reach has doubled. The instrument
; shows the RAD_CLASSES largest classes that still exist, and nothing smaller:
; at the start of a level that is the 192s and the 128s, and as the player
; clears a class out the window steps down of its own accord until it is hunting
; the 16s. Enemies are never subject to it.
;
; It is a gameplay idea that happens to be a performance one. Two classes is
; 30 rocks of a 120-rock field, so five sixths of the scan ends at one compare -
; and the ones it drops are the ones that were least worth a pixel anyway.
RAD_CLASSES = 2

; The slot cap, and the priority that spends it (G7). The GPU can only drop
; whole COMMANDS off the end of a list, so ordering points inside one
; DOT_PIXELS buys nothing - the command runs whole or not at all. Priority is
; therefore CPU1's own: one list per size class, emitted biggest first, and the
; class the cap lands in is truncated. Small debris is what stops appearing
; under load, and it comes back on its own when the field thins.
RAD_MAX     = 48                ; contacts drawn per frame, all classes together
RAD_CLS_MAX = 100               ; ...and per list, which is only a bound on the
                                ;   page each list lives in (1 + 2*100 = 201)

RAD_BLINK_N = 20                ; the enemy blink: a 20-frame cycle at 60.317 Hz
RAD_BLINK_ON = 10               ; ...lit for the first half of it, ~3 Hz. The
                                ;   dark phase is skipped at LIST-BUILD time, so
                                ;   the blink costs less than nothing

FOE_MAX     = 16                ; enemy slots. levels.s authors more than this
                                ;   at your peril - load_foes truncates

; The knobs above are not independent, and the assembler is where that gets
; enforced rather than the simulator. Every one of these is a thing that would
; otherwise fail quietly - a blip off the edge of the screen, or a table index
; that wrapped.
        .assert 2*RAD_RH + 1 <= 255, error, "radar.s: the box test must fit an unsigned byte"
        .assert 2*RAD_RH <= 255, error, "radar.s: d*d = f(2d) needs 2d to index QS"
        .assert 2*RAD_R2 <= 65535, error, "radar.s: dx^2 + dy^2 would overflow the round test"
        .assert RAD_RH < 128, error, "radar.s: past 128 a rotated sum leaves a signed byte"
        .assert RADCX + RAD_SCR <= 199, error, "radar.s: a blip would land off the half-res screen (x)"
        .assert RADCY + RAD_SCR <= 149, error, "radar.s: a blip would land off the half-res screen (y)"
        .assert RADCX - RAD_SCR >= 0, error, "radar.s: a blip would land off the half-res screen (-x)"
        .assert RADCY - RAD_SCR >= 0, error, "radar.s: a blip would land off the half-res screen (-y)"
        .assert RAD_BX0 >= 0 && RAD_BY0 >= 0, error, "radar.s: the occluder box starts off screen"
        .assert 2*RAD_OCR <= 255, error, "radar.s: r^2 = f(2R) needs 2R to index QS"
        .assert 1 + 2*RAD_CLS_MAX <= 255, error, "radar.s: a class list would run off its page"
        .assert RAD_BLINK_ON <= RAD_BLINK_N, error, "radar.s: the blink is lit for longer than its cycle"
        .assert RAD_CLASSES >= 1, error, "radar.s: a radar that shows no rock class at all"

; --- RAM ---------------------------------------------------------------------
; Six DOT_PIXELS payloads, one per priority class, each on its own page: byte 0
; is the count the command wants and the pairs follow it. A page apiece rather
; than a packed array with a stride, because then the write index is a byte and
; the emit is a pointer swap - no multiply and no 16-bit arithmetic anywhere in
; the store.
; ...and they live HIGH, above $6800. RAM from $2000 up is not free: cart.cfg
; RUNS the cartridge's CODE and RODATA out of RAM at $2000 (Model B copies both
; out of the banked window before the first frame, because a window read costs
; three wait states), and the program currently reaches $43EC. $6800-$77FF is
; the last clear stretch below PPRAM.
RADBUF_PG   = $68               ; class c lives at ($68 + c) << 8
RADN        = $6E00             ; 6 bytes: points in each list
RADRAWN     = $6E06             ; ...and how many were actually emitted
RBLINK      = $6E07             ; the blink counter, 0..RAD_BLINK_N-1
RVISIT      = $6E09             ; objects the class window let through
RADMIT      = $6E0A             ; ...and the ones that got inside the circle
RKLIVE      = $6E0B             ; 5 bytes: rocks still alive in each size class
RADSENS     = $6E10             ; ...and the largest class that still has any -
                                ;   the window's lower edge. See radar_sens.
RDXB        = $6E14             ; its world delta from the ship, HIGH BYTES,
RDYB        = $6E15             ;   signed - the wrap is the byte subtract
RPX         = $6E16             ; ...and the half-res blip that comes out
RPY         = $6E17
RCLS        = $6E18             ; which list it belongs in, 0..5
RSLOT       = $6E19             ; slots left in the frame's budget
RORD        = $6E1A             ; the emit's cursor over RAD_ORDER
RTMP        = $6E1B             ; emit / load_foes scratch
NFOE        = $6E1C             ; enemies the level actually placed

FOEXL       = $6F00             ; the enemies, FOE_MAX of each. Only the high
FOEXH       = $6F10             ;   bytes are read by anything here; the low
FOEYL       = $6F20             ;   bytes are carried because the bench after
FOEYH       = $6F30             ;   this one will move them, and a radar that
FOEKIND     = $6F40             ;   only stored what it draws would have to be
                                ;   unpicked to get them back

RINGBUF     = $7000             ; one staging page for the ring upload. Page
                                ;   aligned, so the fill's write index is a byte
RGRR        = $6E1D             ; the upload's cursor: framebuffer row, relative
RGCOL       = $6E1E             ;   to the first page's first row; the column
RGDST       = $6E1F             ;   within that row; and the byte within the page
RGPG        = $6E20             ; which VRAM-background page is next...
RGPGN       = $6E21             ; ...and how many are left, 0 = done
RGWAIT      = $6E22             ; frames to sit out before the next background
                                ;   write is allowed - see 5.5
RGIN        = $6E23             ; 1 while the cursor is on a row the art covers

; The bootstrap's scratch at $F0-$F4 is dead by the first frame, and this is
; the only thing in the cartridge that wants a zero-page POINTER - every other
; buffer in the program has a fixed address. Two of the five bytes, used only
; inside a frame.
RPTRL       = $F0
RPTRH       = $F1
RGSRCL      = $F2               ; ...and the ring upload's read cursor over the
RGSRCH      = $F3               ;   strip, which wants one too

; =============================================================================
; THE FURNITURE — the ring and the ship icon, as a background bitmap
; =============================================================================
; The instrument's outline cannot be DRAWN. MAD65_GPU_OS.md is explicit: there
; is no _BG variant of any line or pixel opcode, because setting one bit needs a
; read-modify-write and the VRAM-background window is write-only (reads return
; ROM). Whole-byte writes are all there is - LOAD, TEXT_BG, TILE_BG, CLEAR_BG -
; so the ring is a BITMAP, uploaded once, and after that the hardware re-copies
; it under the image every frame for nothing. Zero per-frame cost, which is what
; a thing that never changes should cost.
;
; THE ART is assets/png/radar100.png, authored upright and stored turned by
; tools/bggen.py - the TATE convention, the same one the ship sprite follows.
; 100 x 100, a one-pixel ring and a small ship at the centre, always pointing
; up, because the ship is definitionally at the radar's middle and it is the
; world that turns (4.3).
;
; WHY IT IS A STRIP AND NOT PAGES. A LOAD writes a whole 256-byte page and a
; framebuffer row is 50 bytes, so a page is 5.12 rows of the WHOLE screen's
; width: covering a 100 x 100 corner takes 20 pages, 5,120 bytes, almost all of
; it zeros. radar_bg.s stores the 13 columns the art actually occupies - 1,300
; bytes - and ring_page expands them into RINGBUF. The saving is 3,820 bytes of
; a bank that had 6,254 left.
;
; WHY IT TAKES 40 FRAMES. Every VRAM-background write must be the only one on
; its frame with an idle frame after it (5.5): the background is double-buffered
; and the OS replays each write across two frames so it lands in both halves. A
; second write inside that window stomps the replay, and the result blinks every
; other displayed frame. So it is one page every OTHER frame, 20 pages, ~0.7 s -
; and it starts two frames after the boot CLEAR_BG for the same reason.
;
; AND WHY IT CAN COME BACK. cart_frame re-issues CLEAR_BG after a frame the OS
; reported as overrun, which wipes the ring along with the damage. ring_restart
; is called there too, so the furniture repaints itself instead of vanishing for
; the rest of the session.
; -----------------------------------------------------------------------------
ring_restart:
        stz     RGRR
        lda     #RING_C0                ; the first page does not begin at a row
        sta     RGCOL                   ;   boundary, and this is the column it
        stz     RGDST                   ;   does begin at - worked out by
        lda     #RING_PG0               ;   bggen.py, so there is no division
        sta     RGPG                    ;   anywhere in here
        lda     #RING_PGN
        sta     RGPGN
        lda     #$02                    ; two frames clear of the CLEAR_BG that
        sta     RGWAIT                  ;   has just gone out
        lda     #<RING_STRIP
        sta     RGSRCL
        lda     #>RING_STRIP
        sta     RGSRCH
        ; fall through

; RGIN — is the cursor's row one that the art covers?
ring_setin:
        lda     RGRR
        sec
        sbc     #RING_RR0
        cmp     #RING_ROWS
        lda     #$00
        bcs     :+
        lda     #$01
:       sta     RGIN
        rts

; -----------------------------------------------------------------------------
; ring_frame — one page every other frame, until there are none left.
; -----------------------------------------------------------------------------
; Called FIRST in the frame, for the same reason upload_step is: a background
; page dropped for want of PPRAM would leave a hole in the instrument for the
; rest of the session, where a dropped star is gone for one frame.
; -----------------------------------------------------------------------------
ring_frame:
        lda     RGPGN
        beq     @done                   ; the furniture is up
        lda     RGWAIT
        beq     @go
        dec     RGWAIT                  ; ...the cooldown frame
        rts
@go:    jsr     ring_page
        lda     RGPG
        sta     OS_ARG+0
        lda     #<RINGBUF
        sta     OS_ARG+1
        lda     #>RINGBUF
        sta     OS_ARG+2
        jsr     API_GPU_LOAD
        inc     RGPG
        dec     RGPGN
        lda     #$01
        sta     RGWAIT
@done:  rts

; -----------------------------------------------------------------------------
; ring_page — expand the strip into one 256-byte page.
; -----------------------------------------------------------------------------
; One pass, one cursor, no division. The page is walked byte by byte; a running
; (row, column) pair follows it, wrapping the column at the 50-byte row pitch;
; and a byte comes from the strip only where that pair lands inside the art. The
; strip pointer advances only when a byte is CONSUMED, which is what keeps it in
; step across a page boundary falling in the middle of a row - the common case,
; since 256 is not a multiple of 50.
; -----------------------------------------------------------------------------
ring_page:
@byte:  lda     RGIN
        beq     @zero
        lda     RGCOL
        sec
        sbc     #RING_COL0
        cmp     #RING_W
        bcs     @zero
        lda     (RGSRCL)
        inc     RGSRCL
        bne     @put
        inc     RGSRCH
        bra     @put
@zero:  lda     #$00
@put:   ldy     RGDST
        sta     RINGBUF,y
        inc     RGDST
        inc     RGCOL
        lda     RGCOL
        cmp     #50                     ; the framebuffer's row pitch
        bcc     :+
        stz     RGCOL
        inc     RGRR
        jsr     ring_setin
:       lda     RGDST                   ; wrapped to 0: the page is full
        bne     @byte
        rts

; -----------------------------------------------------------------------------
; add_radar_occluder — put the radar's disc in the star-suppression list.
; -----------------------------------------------------------------------------
; Without this the starfield shines straight through the instrument and a blip
; is one more speck among the specks. The rocks have had the same treatment
; since proto 01 for the same reason - a hollow outline reads as a wire hoop -
; and this is that mechanism used verbatim: a clamped box for the cheap per-star
; reject, and a centre plus r^2 for the round test inside it.
;
; Three things make it cheaper than a rock's. It never moves, so every number
; here is a constant the assembler folds - the box's clamp against the screen
; edges included, which add_disc has to do at run time because a rock's centre
; is not known until it is; and r^2 is RAD_OCR * RAD_OCR worked out at assembly
; time rather than looked up in QS.
;
; It is registered right after the ship's, from do_objects, and that is not
; arbitrary: the list is capped at 16 and the discs the rocks add would
; otherwise be able to fill it first. The two things that are ALWAYS on screen
; take their slots before anything can compete for them.
; -----------------------------------------------------------------------------
add_radar_occluder:
        ldy     OCCN
        lda     #RAD_BX0
        sta     OCCX0,y
        lda     #RAD_BX1
        sta     OCCX1,y
        lda     #RAD_BY0
        sta     OCCY0,y
        lda     #RAD_BY1
        sta     OCCY1,y
        lda     #RADCX
        sta     OCCCX,y
        lda     #RADCY
        sta     OCCCY,y
        lda     #<(RAD_OCR * RAD_OCR)
        sta     OCCR2L,y
        lda     #>(RAD_OCR * RAD_OCR)
        sta     OCCR2H,y
        inc     OCCN
        rts

; -----------------------------------------------------------------------------
; radar_census / radar_sens — which size classes the instrument is hunting.
; -----------------------------------------------------------------------------
; The window is the RAD_CLASSES largest classes that still have a rock in them.
; RKLIVE is the population per class, counted once when the level loads; the
; moment anything starts destroying rocks it decrements that and the window
; steps down on its own, with no event and nothing to remember to call.
;
; It is a gameplay rule first - an instrument that quietly retunes itself to
; whatever is left says something about the situation the player is in - and a
; budget rule second, which is the only reason the reach could double.
; -----------------------------------------------------------------------------
radar_census:
        ldx     #$04
:       stz     RKLIVE,x
        dex
        bpl     :-
        ldx     NROCK
        beq     radar_sens
@lp:    dex
        ldy     OBJSHP,x                ; read-add-write, because INC abs,y does
        lda     RKLIVE,y                ;   not exist - the same trap occ_bands
        inc     a                       ;   documents
        sta     RKLIVE,y
        cpx     #$00
        bne     @lp
        ; fall through

radar_sens:
        ldx     #$00
@lp:    lda     RKLIVE,x
        bne     @got                    ; ...the largest class still out there
        cpx     #$04
        bcs     @got                    ; nothing left anywhere: sit on the
        inx                             ;   smallest class rather than run off
        bra     @lp                     ;   the end of the table
@got:   stx     RADSENS
        rts

; -----------------------------------------------------------------------------
; do_radar — build the frame's contact lists. Draws nothing.
; -----------------------------------------------------------------------------
; Runs AFTER do_objects, so the rocks it reads have already moved. It reads
; object state and never writes it: a contact inside the radar's circle but
; outside the camera's cull window is FROZEN (6.1) and its position is "last
; known while near the camera". That is accepted, not overlooked - rocks drift
; at ~13 units a frame against a radar pixel worth 1,024 - see G2.
;
; A FLAT SCAN, AND WHY THE SECTOR GRID IS NOT USED HERE. The first version of
; this walked a ring of cells, which is what open_questions G2 assumed. That was
; right at a reach of 12,800 and is wrong at 25,600: the ring needed to cover a
; radius that large is 15 x 15 of a 16 x 16 grid, so the index would be walking
; 88% of the world to avoid looking at 12% of it, and paying per-cell overhead
; for the privilege. A grid earns its keep when the query is small against the
; world. This one is not, any more.
;
; What replaced it is cheaper than either: the CLASS WINDOW is tested first, and
; it is one subtract and one compare. Five sixths of a 120-rock field ends
; there, before its position has even been read.
; -----------------------------------------------------------------------------
do_radar:
        stz     RVISIT
        stz     RADMIT
        ldx     #$05                    ; six empty lists
:       stz     RADN,x
        dex
        bpl     :-

        lda     RBLINK                  ; one counter for every enemy on screen:
        inc     a                       ;   the blink is global on purpose, so
        cmp     #RAD_BLINK_N            ;   contacts pulse together and read as
        bcc     :+                      ;   one instrument rather than as noise
        lda     #$00
:       sta     RBLINK

        jsr     radar_sens              ; ...and which classes are in play

        ldx     NROCK
        beq     radar_foes
@lp:    dex
        lda     OBJSHP,x                ; THE CLASS WINDOW, first and cheapest:
        sec                             ;   classes RADSENS .. RADSENS+RAD_CLASSES-1
        sbc     RADSENS                 ;   and nothing else. Below RADSENS the
        cmp     #RAD_CLASSES            ;   subtract goes negative and the
        bcs     @next                   ;   unsigned compare catches it too
        inc     RVISIT

        ; The box reject. A signed byte delta is inside [-RAD_RH, +RAD_RH]
        ; exactly when the delta plus RAD_RH is below 2*RAD_RH+1 read as
        ; UNSIGNED - one ADC and one CMP, no sign test and no branch on the
        ; common path.
        lda     OBJXH,x
        sec
        sbc     SHXH
        sta     RDXB
        clc
        adc     #RAD_RH
        cmp     #2*RAD_RH+1
        bcs     @next
        lda     OBJYH,x
        sec
        sbc     SHYH
        sta     RDYB
        clc
        adc     #RAD_RH
        cmp     #2*RAD_RH+1
        bcs     @next

        lda     OBJSHP,x                ; the size class IS the priority class
        sta     RCLS
        phx
        jsr     radar_plot
        plx
@next:  cpx     #$00
        bne     @lp
        ; fall through to the enemies

; -----------------------------------------------------------------------------
; radar_foes — the other source, and a linear scan on purpose.
; -----------------------------------------------------------------------------
; Enemies are not in the sector grid. There are at most FOE_MAX of them and the
; grid's whole value is that it stops a walk being proportional to a population
; - at sixteen there is no population to be proportional to, and the box reject
; is ~25 cycles, so the entire scan is cheaper than the bookkeeping a grid
; membership would cost when they start moving.
; -----------------------------------------------------------------------------
radar_foes:
        lda     RBLINK                  ; the dark half of the blink: build no
        cmp     #RAD_BLINK_ON           ;   enemy points at all. Nothing is
        bcs     @done                   ;   drawn and nothing is tested
        ldx     NFOE
        beq     @done
@lp:    dex
        inc     RVISIT
        lda     FOEXH,x
        sec
        sbc     SHXH
        sta     RDXB
        clc
        adc     #RAD_RH
        cmp     #2*RAD_RH+1
        bcs     @next
        lda     FOEYH,x
        sec
        sbc     SHYH
        sta     RDYB
        clc
        adc     #RAD_RH
        cmp     #2*RAD_RH+1
        bcs     @next
        lda     #$05                    ; the enemy list, whatever KIND says -
        sta     RCLS                    ;   E6 has not settled what kinds are
        phx
        jsr     radar_plot
        plx
@next:  cpx     #$00
        bne     @lp
@done:  rts

; -----------------------------------------------------------------------------
; radar_plot — RDXB/RDYB passed the box; finish the job or drop it.
; -----------------------------------------------------------------------------
; in:  RDXB, RDYB = the world delta's high bytes, signed; RCLS = which list
; out: a point appended to that list, or nothing
; Clobbers A, X, Y - callers keep their loop state in RAM, as everything in
; this cartridge does across a JSR.
; -----------------------------------------------------------------------------
radar_plot:
        ; --- the round test --------------------------------------------------
        ; f(x) = floor(x*x/4) and f(2a) = a*a EXACTLY for a <= 127, so a square
        ; is one indexed read of the table the multiply already built - the
        ; same identity physics.s tests its collision circles with. |d| <= 50
        ; here, so the index is at most 100 and the sum at most 5,000: both
        ; inside what the table and a 16-bit add hold.
        lda     RDXB
        bpl     :+
        eor     #$FF
        inc     a
:       asl     a
        tax
        lda     QSL,x
        sta     T0
        lda     QSH,x
        sta     T1
        lda     RDYB
        bpl     :+
        eor     #$FF
        inc     a
:       asl     a
        tax
        clc
        lda     QSL,x
        adc     T0
        sta     T0
        lda     QSH,x
        adc     T1
        cmp     #>RAD_R2
        bcc     @in
        bne     @out
        lda     T0
        cmp     #<RAD_R2
        bcc     @in
        beq     @in                     ; the rim is inside
@out:   rts
@in:
        ; --- the rotation ----------------------------------------------------
        ;   vx = dx*cos + dy*sin        vy = dy*cos - dx*sin
        ;
        ; out of do_camera's ROT tables, which hold signed(i)*coef/128 as an
        ; 8.8 pair and are EXACT (see BUILD_ROT). The star field and the object
        ; centres read the same tables through RPROD, which splits a 16-bit
        ; delta into two lookups; this needs only the high half, so it is four
        ; reads and two adds instead of RPROD's four passes.
        ;
        ; The fraction bytes are added anyway, for their CARRY alone, and then
        ; RAD_ROUND adds the half that turns the shift below into a round
        ; instead of a floor. Dropping either would bias every contact inward
        ; and let a stationary rock's blip step a whole pixel as the camera
        ; turns - the same defect that made objects swim before their transform
        ; stopped rounding early. Two instructions to not have it.
        ldx     RDXB
        ldy     RDYB
        clc
        lda     ROTC_F,x
        adc     ROTS_F,y                ; (for the carry only)
        lda     ROTC_I,x
        adc     ROTS_I,y
        clc
        adc     #RAD_ROUND              ; the half that makes the shift below a
        .repeat RAD_SH                  ;   round instead of a floor
        cmp     #$80                    ; sign into carry, then ROR: an
        ror     a                       ;   arithmetic >> RAD_SH
        .endrepeat
        sta     RPY                     ; ...parked: fb_y is CY minus this
        sec
        lda     ROTC_F,y
        sbc     ROTS_F,x
        lda     ROTC_I,y
        sbc     ROTS_I,x
        clc
        adc     #RAD_ROUND
        .repeat RAD_SH
        cmp     #$80
        ror     a
        .endrepeat

        ; --- the blip --------------------------------------------------------
        ; Same mapping as an object's: fb_x = CX + vy, fb_y = CY - vx, about
        ; the radar's centre instead of the screen's. No clip and no clamp: the
        ; round test above bounds |vx| and |vy| at RAD_RH, so the blip cannot
        ; leave the box. That is the whole reason the catchment is a circle.
        clc
        adc     #RADCX
        sta     RPX
        sec
        lda     #RADCY
        sbc     RPY
        sta     RPY

        inc     RADMIT
        ldx     RCLS
        lda     RADN,x
        cmp     #RAD_CLS_MAX
        bcs     @full
        asl     a                       ; the write index: 1 + 2N, because byte
        inc     a                       ;   0 of the page is the count
        tay
        stz     RPTRL
        lda     RCLS
        clc
        adc     #RADBUF_PG
        sta     RPTRH
        lda     RPX
        sta     (RPTRL),y
        iny
        lda     RPY
        sta     (RPTRL),y
        inc     RADN,x
@full:  rts

; -----------------------------------------------------------------------------
; emit_radar — spend RAD_MAX slots, biggest first.
; -----------------------------------------------------------------------------
; One DOT_PIXELS per non-empty list. That is five extra dispatches in the worst
; case against one, and it is what buys the priority: a list that does not fit
; is truncated to the slots left, and the ones after it are not sent at all.
;
; Enemies go FIRST. They are the thing the instrument exists for, and losing a
; contact because a rock field was busy is exactly the failure the priority is
; there to prevent. Then the rock classes, 0 (192 px) down to 4 (16 px).
; -----------------------------------------------------------------------------
emit_radar:
        stz     RADRAWN                 ; cleared HERE and not in do_radar, so
                                        ;   that do_hud - which runs between the
                                        ;   two - reads LAST frame's count rather
                                        ;   than a zero. One frame stale on a
                                        ;   readout the real game rate-limits to
                                        ;   ~10 Hz anyway (5.5); the alternative
                                        ;   was to emit before the HUD, which
                                        ;   would rank the radar below it in the
                                        ;   list, and it is not below it
        lda     #RAD_MAX
        sta     RSLOT
        stz     RORD
@lp:    ldx     RORD
        lda     RAD_ORDER,x
        tax
        lda     RADN,x
        beq     @next
        cmp     RSLOT                   ; ...truncated to what is left
        bcc     :+
        lda     RSLOT
:       beq     @done                   ; nothing left: stop, do not skip on
        sta     RTMP

        stz     RPTRL                   ; the count goes into byte 0 of the page
        txa
        clc
        adc     #RADBUF_PG
        sta     RPTRH
        sta     OS_ARG+1
        stz     OS_ARG+0
        lda     RTMP
        ldy     #$00
        sta     (RPTRL),y
        jsr     API_GPU_DOTPIXELS

        sec
        lda     RSLOT
        sbc     RTMP
        sta     RSLOT
        clc
        lda     RADRAWN
        adc     RTMP
        sta     RADRAWN
@next:  inc     RORD
        lda     RORD
        cmp     #$06
        bne     @lp
@done:  rts

; -----------------------------------------------------------------------------
; load_foes — the enemies out of levels.s, once.
; -----------------------------------------------------------------------------
; Called by cart_init after load_level, which has already left LVLIX pointing
; at the level. Nothing else in the cartridge reads an enemy yet: this bench
; needs positions to put blips on and nothing more, and E6 has not settled what
; a KIND is - so the byte is carried and not interpreted.
; -----------------------------------------------------------------------------
load_foes:
        stz     NFOE
        ldx     LVLIX
        lda     LVL_FOEN,x
        beq     @done
        cmp     #FOE_MAX                ; a level that authors more than there
        bcc     :+                      ;   are slots loses the tail, quietly -
        lda     #FOE_MAX                ;   the assembler cannot check this one
:       sta     RTMP                    ;   the way it checks the rock count
        lda     LVL_FOELO,x
        sta     T0
        lda     LVL_FOEHI,x
        sta     T1

@lp:    ldy     #$04                    ; stage the record: Y has to be the
:       lda     (T0),y                  ;   record cursor here and the slot
        sta     LVREC,y                 ;   below, and it cannot be both
        dey
        bpl     :-
        ldx     NFOE
        lda     LVREC+0
        sta     FOEXL,x
        lda     LVREC+1
        sta     FOEXH,x
        lda     LVREC+2
        sta     FOEYL,x
        lda     LVREC+3
        sta     FOEYH,x
        lda     LVREC+4
        sta     FOEKIND,x
        inc     NFOE
        clc                             ; ...and on to the next five bytes
        lda     T0
        adc     #$05
        sta     T0
        bcc     :+
        inc     T1
:       dec     RTMP
        bne     @lp
@done:  rts

; The priority order the emit spends its slots in: enemies first, then the rock
; classes from 0 (192 px across) down to 4 (16 px). A table rather than a loop
; bound, so "what matters most" is one line to re-argue.
RAD_ORDER:  .byte   5, 0, 1, 2, 3, 4
