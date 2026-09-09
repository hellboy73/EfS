; =============================================================================
; radar.s — the HUD radar: what is near, on a fixed scale, in the corner
; =============================================================================
; Everything here is the honest v1 pipeline of open_questions.md G; the lying
; radar the story needs (E8) is a filter applied on top of it later, not a
; second renderer.
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
; Bottom-RIGHT of the PLAYER's screen, which is not the framebuffer's: TATE
; clockwise means fb_x = portrait_y and fb_y = 299 - portrait_x, so "bottom" is
; high fb_x and "right" is LOW fb_y. Half-res (174, 25) is full-res (348, 50),
; which is portrait x 199..299 and y 298..398.
;
; IT USED TO BE BOTTOM-LEFT (RADCY 124, portrait x 1..101) and moved when the
; HUD text arrived: the two lowest text rows run from the LEFT margin, so the
; instrument had to vacate that corner. Only RADCY changed - the vertical
; placement was already right, and the ring artwork moved with it by one
; constant (radar_bg.s RING_Y0, regenerated by tools/bggen.py --at 199,298).
RADCX       = 174
RADCY       = 25
RAD_SCR     = RAD_RH >> RAD_SH  ; ...and the radius that box holds, 25 cells

; Those two put the instrument HARD INTO THE CORNER: the outermost blip column
; is 174 + 25 = 199, which is the last half-res column there is, and the
; outermost row is 25 - 25 = 0, likewise the first. It cannot go further. What is left
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

; ...and its box, CLAMPED to the screen on ALL FOUR EDGES, exactly as add_disc
; clamps a rock's. Pushed into the corner the disc hangs one cell over two of
; them, and a box that ran past would index a band that does not exist. The
; round test is unaffected: it works off the true centre and r^2, so a star near
; the edge is still judged against the real circle.
;
; BOTH ENDS of each axis are clamped now, and the low end is not decoration. The
; move to the right-hand edge put RADCY at 25 against an RAD_OCR of 26, so
; RADCY - RAD_OCR is -1: a NEGATIVE box origin, which as an unsigned byte is 255
; and would walk the occluder band list off its end. The assert below caught it,
; which is what it was there for.
.if RADCX - RAD_OCR < 0
RAD_BX0     = 0
.else
RAD_BX0     = RADCX - RAD_OCR
.endif
.if RADCY - RAD_OCR < 0
RAD_BY0     = 0
.else
RAD_BY0     = RADCY - RAD_OCR
.endif
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

; WHAT THE INSTRUMENT OWES THE PLAYER is that they are not flying blind looking
; for rocks, and the honest answer to that is THE BIGGEST RAD_MAX ROCKS THERE
; ARE, filled gradually from the top down.
;
; It used to be a window of the RAD_CLASSES largest classes that still existed,
; which stepped down only when one of them was cleared out. That coupled two
; classes that have nothing to do with each other and left the display half empty
; for most of a level - a radar showing 30 contacts with 18 slots going spare.
;
; radar_alloc replaces it: the frame's RAD_MAX slots are handed out over the
; classes by size, biggest first, straight out of RKLIVE. See it for what the
; estimate costs.

; The slot cap, and the priority that spends it (G7). The GPU can only drop
; whole COMMANDS off the end of a list, so ordering points inside one
; DOT_PIXELS buys nothing - the command runs whole or not at all. Priority is
; therefore CPU1's own: one list per size class, emitted biggest first, and the
; class the cap lands in is truncated. Small debris is what stops appearing
; under load, and it comes back on its own when the field thins.
RAD_MAX     = 48                ; contacts drawn per frame, all classes together
                                ;   ...and the per-list ceiling is no longer a
                                ;   constant at all: RADWANT holds each class'
                                ;   share of exactly these slots, worked out
                                ;   once a frame by radar_alloc.

; THE OUTAGE IS A STORY BEAT, not a valve. It used to arm itself when the field
; got crowded, because do_radar's cost grew with the field and nothing else
; stopped it. Something does now: the allocation above never hands out more than
; RAD_MAX slots, radar_plot refuses a contact past its class' share for about ten
; cycles, and the scan STOPS the moment every allocated slot is filled - so a
; saturated field is bounded work rather than unbounded.
;
; Nothing arms it any more. Write RADDOWN and the instrument goes down for that
; many frames, blinking RADAR ERROR across the disc, which is what it is wanted
; for: something in the story breaking it, at a chosen moment.
RAD_DOWN_N  = 90                ; frames it stays down after that, ~1.5 s at
                                ;   60.317 Hz - long enough to read as a fault
                                ;   rather than as a flicker

; WHERE THE FAULT MESSAGE SITS. Cells 24-36 are the radar's (the HUD stops at 23)
; and the disc spans lines 37-49. One word per line, a blank line between them,
; centred on the disc's middle row: five glyphs from cell 29 run 29-33, portrait
; x 232-271 against a disc of 199-301, and lines 42 and 44 straddle line 43.
;
; Each string is the WORD AND ONE TRAILING SPACE, not a padded field. Nothing
; needs clearing - this goes on the IMAGE, which the hardware rebuilds from the
; background every frame, so the message disappears the moment it stops being
; issued - and a line of spaces would be glyphs the GPU draws for nothing.
RAD_ERR_X   = 29
RAD_ERR_Y1  = 42                ; "RADAR"
RAD_ERR_Y2  = 44                ; ...one blank line, then "ERROR"
RAD_ERR_N   = 6                 ; the longest word plus its trailing space

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
        .assert 1 + 2*RAD_MAX <= 255, error, "radar.s: a class list would run off its page"
        .assert RAD_BLINK_ON <= RAD_BLINK_N, error, "radar.s: the blink is lit for longer than its cycle"
        .assert RAD_ERR_X + RAD_ERR_N <= 37, error, "radar.s: the fault message runs off the cell grid"
        .assert RAD_ERR_Y2 <= 49, error, "radar.s: the fault message runs off the line grid"
        .assert RAD_ERR_Y2 > RAD_ERR_Y1 + 1, error, "radar.s: the two words need a blank line between them"
        .assert RAD_ERR_X >= 24, error, "radar.s: the fault message reaches into the HUD cells"

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
RADMIT      = $6E0A             ; ...and the ones that got inside the circle AND
                                ;   into a list - past the cap a contact is
                                ;   refused before the round test can judge it
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
RADDOWN     = $6E11             ; frames left on the outage; 0 = the instrument
                                ;   is working. Nothing sets it automatically -
                                ;   see RAD_DOWN_N.
RADWIN      = $6E13             ; how many classes in a row got slots this frame
RADWANT     = $6E1F             ; 6 bytes: each list's ceiling for the frame -
                                ;   classes 0..4 out of radar_alloc, and FOE_MAX
                                ;   at 5 for the enemies
RADLEFT     = $6E25             ; contacts still to be plotted before the whole
                                ;   budget is spent. The scan stops at zero.
        .assert RADLEFT = RADWANT + 6, error, "radar.s: RADWANT's six bytes ran into RADLEFT"

FOEXL       = $6F00             ; the enemies, FOE_MAX of each. Only the high
FOEXH       = $6F10             ;   bytes are read by anything here; the low
FOEYL       = $6F20             ;   bytes are carried because whatever finally
FOEYH       = $6F30             ;   MOVES an enemy will need them, and a radar
FOEKIND     = $6F40             ;   only stored what it draws would have to be
                                ;   unpicked to get them back

RGWAIT      = $6E1D             ; frames to sit out before the next background
                                ;   write is allowed - see 5.5
RGDONE      = $6E1E             ; 1 once the ring's one RECT_BG_RLE command has
                                ;   landed - see ring_frame

; The bootstrap's scratch at $F0-$F4 is dead by the first frame, and this is
; the only thing in the cartridge that wants a zero-page POINTER - every other
; buffer in the program has a fixed address.
RPTRL       = $F0
RPTRH       = $F1

; =============================================================================
; THE FURNITURE — the ring and the ship icon, as a background bitmap
; =============================================================================
; The instrument's outline cannot be DRAWN. MAD65_GPU_OS.md is explicit: there
; is no _BG variant of any line or pixel opcode, because setting one bit needs a
; read-modify-write and the VRAM-background window is write-only (reads return
; ROM). Whole-byte writes are all there is, so the ring is a BITMAP, uploaded
; once, and after that the hardware re-copies it under the image every frame for
; nothing. Zero per-frame cost, which is what a thing that never changes should
; cost.
;
; THE ART is assets/png/radar100.png, authored upright and stored turned by
; tools/bggen.py - the TATE convention, the same one the ship sprite follows.
; 100 x 100, a one-pixel ring and a small ship at the centre, always pointing
; up, because the ship is definitionally at the radar's middle and it is the
; world that turns (4.3).
;
; ONE COMMAND, NOT TWENTY PAGES. This used to be a LOAD strip: a page is 256
; bytes of a 50-byte row pitch, so a 100 x 100 corner took 20 pages, one every
; other frame, ~40 frames (~0.7 s) to appear. MAD-65's V1.0 transport block adds
; RECT_BG_RLE ($32, API_GPU_RECT_BG_CART) - a byte-aligned rectangle of ANY
; height, RLE-compressed, streamed straight from the cartridge - which needs no
; page alignment at all. bggen.py now emits the ring as one RLE band covering
; the whole 100 rows (a one-pixel ring is sparse; it roughly halves), so the
; whole furniture is ONE command instead of twenty, and the two-frame replay
; rule (below) is paid once instead of twenty times: it lands in ~3 frames, not
; 40.
;
; STILL TWO FRAMES, THOUGH. Every VRAM-background write must be the only one on
; its frame with an idle frame after it (5.5): the background is double-buffered
; and the OS replays each write across two frames so it lands in both halves. A
; second write inside that window stomps the replay, and the result blinks every
; other displayed frame. ring_restart waits two frames clear of the boot
; CLEAR_BG for the same reason before ring_frame makes its one attempt.
;
; RGWAIT ALSO COVERS PPRAM PRESSURE. API_GPU_RECT_BG_CART returns carry SET and
; does nothing at all when the frame's PPRAM is already full - RGDONE simply
; stays clear and ring_frame tries again next frame, with no state to unwind.
;
; AND WHY IT CAN COME BACK. cart_frame re-issues CLEAR_BG after a frame the OS
; reported as overrun, which wipes the ring along with the damage. ring_restart
; is called there too, so the furniture repaints itself instead of vanishing for
; the rest of the session. Re-arming the job (gpu_rect_bg_begin) on that path is
; safe even if a replay were still pending, because the geometry it arms with is
; always the same RING_XB/WB/GAP/ROWS constants - unlike a job whose rectangle
; moves, there is no "new geometry" for a stale pending replay to pick up.
; -----------------------------------------------------------------------------
ring_restart:
        stz     RGDONE
        lda     #$02                    ; two frames clear of the CLEAR_BG that
        sta     RGWAIT                  ;   has just gone out
        lda     #RING_XB
        sta     OS_ARG+0
        lda     #RING_WB
        sta     OS_ARG+1
        lda     #RING_GAP
        sta     OS_ARG+2
        lda     #RING_ROWS
        sta     OS_ARG+3
        jmp     API_GPU_RECT_BG_BEGIN   ; arms the job; emits nothing, so doing
                                        ;   this immediately (ahead of RGWAIT's
                                        ;   settle) costs nothing - the actual
                                        ;   PPRAM write waits for ring_frame

; -----------------------------------------------------------------------------
; ring_frame — the one API_GPU_RECT_BG_CART call, retried until it lands.
; -----------------------------------------------------------------------------
; Called FIRST in the frame, for the same reason upload_step is: a command
; dropped for want of PPRAM would leave the instrument blank for a lot longer
; than one frame if this ran after everything else had already spent the
; frame's budget.
; -----------------------------------------------------------------------------
ring_frame:
        lda     RGDONE
        bne     @done                   ; the furniture is up
        lda     RGWAIT
        beq     @go
        dec     RGWAIT                  ; ...the settle after CLEAR_BG
        rts
@go:    lda     #RING_BANK
        sta     OS_ARG+0
        lda     #<RING_BLOB
        sta     OS_ARG+1
        lda     #>RING_BLOB
        sta     OS_ARG+2
        lda     #<RING_Y0
        sta     OS_ARG+3
        lda     #>RING_Y0
        sta     OS_ARG+4
        jsr     API_GPU_RECT_BG_CART
        bcs     @done                   ; PPRAM was full this frame - nothing
                                        ;   emitted or recorded; RGWAIT is
                                        ;   already zero, so next frame retries
        lda     #$01
        sta     RGDONE                  ; one command was the whole picture
@done:  rts

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
; radar_census / radar_alloc - who gets this frame's RAD_MAX slots.
; -----------------------------------------------------------------------------
; RKLIVE is the population per class, counted once when the level loads; the
; moment anything destroys a rock it decrements that, so the allocation below
; retunes itself with no event and nothing to remember to call.
;
; radar_alloc hands RAD_MAX slots out BY SIZE, biggest class first: class 0 takes
; as many as it has rocks, class 1 takes what is left, and so on down until the
; budget runs out. RADWANT[c] is that class' ceiling for the frame, RADSENS the
; first class that got anything and RADWIN how many classes in a row did - so the
; scan's gate stays the two instructions it always was. The display fills
; gradually from the top instead of waiting for a whole class to be cleared.
;
; IT IS AN ESTIMATE, in one direction. RKLIVE counts the whole world while the
; radar's circle covers about 62% of it, so a class can be allocated slots it
; cannot fill, and a few smaller contacts go unshown that there was room for.
; That is the cheap way to be wrong: the alternative is plotting every small rock
; in the field to discover the big ones were going to take every slot anyway.
; -----------------------------------------------------------------------------
radar_census:
        stz     RADDOWN                 ; a restart must not inherit an outage,
        ldx     #$04                    ;   and nothing zeroes cartridge RAM
:       stz     RKLIVE,x
        dex
        bpl     :-
        ldx     NROCK
        beq     radar_alloc
@lp:    dex
        ldy     OBJSHP,x                ; read-add-write, because INC abs,y does
        cpy     #$05                    ;   not exist - the same trap occ_bands
        bcs     @skip                   ;   documents. SHP_DEAD is past the end
        lda     RKLIVE,y                ;   of the table too; this only matters
        inc     a                       ;   if a census is ever taken AFTER
        sta     RKLIVE,y                ;   something has been shot, which today
@skip:                                  ;   nothing does
        cpx     #$00
        bne     @lp
        ; fall through

radar_alloc:
        lda     #RAD_MAX
        sta     RADLEFT                 ; slots still to hand out
        stz     RADSENS
        stz     RADWIN
        ldx     #$00
        ldy     #$FF                    ; the last class given anything, or none
@lp:    stz     RADWANT,x
        lda     RADLEFT
        beq     @next                   ; the budget is spent - everything from
        cmp     RKLIVE,x                ;   here down gets nothing
        bcc     :+                      ; fewer slots left than rocks: take them
        lda     RKLIVE,x                ; ...otherwise take every rock there is
:       beq     @next                   ; ...and this class has none
        sta     RADWANT,x
        sec
        lda     RADLEFT
        sbc     RADWANT,x
        sta     RADLEFT
        cpy     #$FF
        bne     :+
        stx     RADSENS                 ; the FIRST class to be given anything
:       txa
        tay                             ; ...and the last one, so far
@next:  inx
        cpx     #$05
        bne     @lp

        lda     #FOE_MAX                ; the enemies' list is outside the size
        sta     RADWANT+5               ;   budget: emit_radar serves them ahead
                                        ;   of every rock class anyway
        cpy     #$FF
        beq     @none
        tya                             ; RADWIN = last - first + 1, so the gate
        sec                             ;   stays one subtract and one compare
        sbc     RADSENS
        inc     a
        sta     RADWIN
        sec                             ; ...and RADLEFT stops being "budget
        lda     #RAD_MAX                ;   remaining" and becomes "contacts still
        sbc     RADLEFT                 ;   to plot", which is what the scan
        sta     RADLEFT                 ;   watches
        rts
@none:  stz     RADWIN                  ; nothing alive: the gate admits nothing
        stz     RADLEFT
        rts

; -----------------------------------------------------------------------------
; radar_health - is the instrument up this frame?
; -----------------------------------------------------------------------------
; Carry SET when it is down. Nothing arms this automatically any more - see the
; note on RAD_DOWN_N - so all it is is the countdown a scripted failure starts by
; writing RADDOWN.
; -----------------------------------------------------------------------------
radar_health:
        lda     RADDOWN
        beq     @up
        dec     RADDOWN
        sec
        rts
@up:    clc
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

        jsr     radar_alloc             ; ...and who gets this frame's slots
        jsr     radar_health            ; ...and whether the instrument is up at
        bcc     :+                      ;   all. The six lists are already empty,
        rts                             ;   so a downed radar draws nothing, and
:                                       ;   emit_radar says so instead

        ldx     NROCK
        beq     radar_foes
@lp:    dex
        lda     OBJSHP,x                ; THE CLASS GATE, first and cheapest:
        sec                             ;   classes RADSENS .. RADSENS+RADWIN-1,
        sbc     RADSENS                 ;   which is exactly the run radar_alloc
        cmp     RADWIN                  ;   gave slots to. Below RADSENS the
        bcs     @next                   ;   subtract goes negative and the
        inc     RVISIT                  ;   unsigned compare catches that too
                                        ;   (RADWIN 0 = nothing alive, admits
                                        ;   nothing)

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
        lda     RADLEFT                 ; STOP: every slot the allocation handed
        beq     radar_foes              ;   out is filled, so nothing further in
                                        ;   the field can reach the display
                                        ;   however long the scan goes on. This
                                        ;   is the bound - past here the rest of
                                        ;   the field is not looked at at all.
                                        ;   Enemies are unaffected: this lands ON
                                        ;   radar_foes, and emit_radar gives them
                                        ;   their slots ahead of every rock.
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
        ; --- the share, FIRST ------------------------------------------------
        ; RADWANT is this class' ceiling for the frame, out of radar_alloc - not
        ; a constant, because a class only gets the slots the bigger ones left.
        ; The test used to sit after the round test AND the rotation, so a
        ; contact past the cap paid the whole ~290 cycles to be thrown away at
        ; the last instruction. Here it is about ten.
        ldx     RCLS
        lda     RADN,x
        cmp     RADWANT,x
        bcc     :+
        rts
:
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
        ldx     RCLS                    ; (the cap was spent at the top; the
        lda     RADN,x                  ;  rotation clobbered X, so re-read it)
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
        dec     RADLEFT                 ; ...and one slot of the frame's budget is
                                        ;   spent. do_radar stops the scan when
                                        ;   this reaches zero.
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
        lda     RADDOWN                 ; the instrument is down: do_radar built
        beq     :+                      ;   no lists at all, so say so rather than
        jmp     radar_fault             ;   emit six empty ones
:       lda     #RAD_MAX
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
; at the level. Nothing else in the cartridge reads an enemy yet: the radar
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
; -----------------------------------------------------------------------------
; radar_fault - what a downed instrument shows.
; -----------------------------------------------------------------------------
; One VTEXT on the IMAGE, and deliberately not on the background where the ring
; and the HUD live: there it would need the two-frame replay, it would fight
; ring_frame for the replay window, and taking it off again would mean clearing
; the ring with it. On the image it costs one command a frame and vanishes by
; itself the moment it stops being issued.
;
; It blinks on RBLINK - the counter the enemy contacts already share, and which
; do_radar still advances before it gives up - so the alarm and the enemies pulse
; together, and the dark half of the cycle costs nothing at all.
; -----------------------------------------------------------------------------
radar_fault:
        lda     RBLINK
        cmp     #RAD_BLINK_ON
        bcs     @done
        lda     #RAD_ERR_Y1             ; the first word, then fall through into
        ldx     #<RAD_ERR_S1            ;   the same setup for the second - the
        ldy     #>RAD_ERR_S1            ;   tail below returns for both
        jsr     @word
        lda     #RAD_ERR_Y2
        ldx     #<RAD_ERR_S2
        ldy     #>RAD_ERR_S2
@word:  sta     OS_ARG+1
        stx     OS_ARG+3
        sty     OS_ARG+4
        lda     #RAD_ERR_X
        sta     OS_ARG+0
        stz     OS_ARG+2                ; no sub-cell scroll
        jmp     API_GPU_VTEXT           ; tail
@done:  rts

RAD_ERR_S1: .byte "RADAR ", 0
RAD_ERR_S2: .byte "ERROR ", 0

RAD_ORDER:  .byte   5, 0, 1, 2, 3, 4
