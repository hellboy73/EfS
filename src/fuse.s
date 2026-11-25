; =============================================================================
; fuse.s - the CPU load fuse: the checkpoint before the frame's cuttable tail
; =============================================================================
; open_questions E12. A CPU1 frame overrun must not happen (smoothness above
; everything), so the frame is ordered with the work that may be dropped LAST:
; the radar's contact lists, the starfield and the motes. Their buffers -
; RADN and the $68xx pages, DOTBUF/STARN, MOTEBUF - survive the frame, and
; their emits stay at the end of cart_frame, so a frame that skips the compute
; re-emits last frame's result: a still starfield, a radar one frame late, and
; no hole anywhere.
;
; frame_tail is that checkpoint. FRAME_POS says how far into the frame CPU1
; is; past TAIL_CUT - or past the edge already, which VSYNC_FLAG tells - the
; tail is skipped and DEGR is set, the "degraded" countdown the fuses will
; read on the next frames (stars off, one-child splits, no rock-rock
; collisions, the zoom brake - none of them built yet). The read order is the
; MAD-65 trap: FRAME_POS FIRST, VSYNC_FLAG second; FRAME_POS restarts at the
; edge, so after an overrun it reads LOW.
;
; TAIL_CUT is 232 for now, which FRAME_POS never reaches on time: only a frame
; already past its edge is cut, and that frame is not published anyway. So
; the game is unchanged until a measurement - dbg_load's marks - gives the
; real threshold: 232 - (the tail and the emits after it) - a margin.
;
; py65 (preview.py) reads $BF80 as plain RAM, 0, so the checkpoint never
; trips there.
; =============================================================================

TAIL_MAX    = 51                ; the most the tail AND the emits after it were
                                ;   ever measured to cost (dbg_load's HWT,
                                ;   tools/loadmarks.py): 51 in two heavy runs
                                ;   flown by the user, dumps 00003693 and
                                ;   00003331 (2026-11-25). 0 = the fuse OFF
TAIL_MARGIN = 16                ; the safety buffer on top (~7% of a frame,
                                ;   ~16 k cycles): a tail heavier than any
                                ;   flown - more contacts, more occluders -
                                ;   must still fit. TBM, the user's call
.if TAIL_MAX
TAIL_CUT    = 232 - TAIL_MAX - TAIL_MARGIN  ; FRAME_POS at the checkpoint
                                ;   from which the tail is cut
.else
TAIL_CUT    = 232               ; never on time: only a frame past its edge
.endif
DEGR_HOLD   = 60                ; frames a cut keeps the game degraded (TBM)

; --- state: $70C9-$70D3, hud_game.s's free tail, after cam.s's DBGBRK --------
DEGR        = $70C9             ; frames of degraded mode left, 0 = normal
SPLALT      = $70D3             ; shots.s rock_destroy: counts degraded
                                ;   splits; bit 0 clear = this one makes one
                                ;   rock. Past the debug marks, and needs no
                                ;   init - only its parity is read
.if DBG_LOAD
CKPREV      = $70CA             ; FRAME_POS at last frame's checkpoint
HWL         = $70CB             ; THE MARKS, read out of an F2 dump
HWC         = $70CC             ;   (dumps/<frame>_cpu1_ram.bin at these
HWT         = $70CD             ;   offsets) - see dbg_load. game_start
NLATE       = $70CE             ;   clears all six
HWF         = $70CF
NCKL        = $70D0
NCUT        = $70D1             ; 16-bit: frames whose tail was cut
.endif

        .pushseg
        .segment "CODE4"                ; the run area: FIELDRAM had no room
; -----------------------------------------------------------------------------
; frame_tail - the checkpoint, then the radar, the stars and the motes.
; -----------------------------------------------------------------------------
; Inside cart_frame's win_off bracket: do_radar reads the object pool.
; -----------------------------------------------------------------------------
frame_tail:
        lda     FRAME_POS               ; the hardware FIRST...
        ldx     VSYNC_FLAG              ; ...then the OS's flag
        beq     :+
        lda     #$FF                    ; the edge has passed: past any threshold
:
.if DBG_LOAD
        jsr     dbg_load                ; TEMPORARY - keeps A
.endif
        cmp     #TAIL_CUT
        bcs     @cut
        lda     DEGR                    ; a frame that made it: the countdown
        beq     :+                      ;   runs out
        dec     DEGR
:       jsr     do_radar
        jsr     do_stars
        jmp     do_motes                ; tail
@cut:
.if DBG_LOAD
        inc     NCUT                    ; TEMPORARY - how often the fuse blew
        bne     :+
        inc     NCUT+1
:
.endif
        lda     #DEGR_HOLD
        sta     DEGR
        rts

.if DBG_LOAD
; -----------------------------------------------------------------------------
; dbg_load - TEMPORARY: the load's high-water marks, kept in RAM for a dump.
; -----------------------------------------------------------------------------
; Nothing on screen - a readout would cost CPU1 and the GPU every frame and
; move what it measures. Fly, press F2, read the dump. Each frame takes the
; PREVIOUS frame's pair - FRAME_LOAD (the OS's FRAME_POS at gpu_end) and
; CKPREV (FRAME_POS at this checkpoint), which belong together - and keeps:
;
;   HWL   the highest on-time FRAME_LOAD
;   HWC   ...that frame's checkpoint (HWL - HWC: its tail)
;   HWT   the highest tail cost LL - CC of ANY frame - not necessarily the
;         heaviest one, and what TAIL_CUT is set from: 232 - HWT - a margin
;   NLATE frames whose list was late ($FF), saturating at 255
;   HWF   the highest checkpoint reached on time: the worst FRONT of a
;         frame, everything before frame_tail
;   NCKL  frames whose edge had passed BEFORE the checkpoint - the ones no
;         tail cut can save, only the fuses that lighten the front
;   NCUT  (16-bit, counted in frame_tail) frames whose tail was cut, NCKL's
;         included
;
; FRAME_POS units: 1024 cycles, 232 ($E8) a whole frame.
; In: A = this frame's checkpoint. Keeps A.
; -----------------------------------------------------------------------------
dbg_load:
        pha
        cmp     #$FF                    ; this frame's checkpoint first
        bne     @ontime
        inc     NCKL                    ; late already: saturating count
        bne     @last
        dec     NCKL
        bra     @last
@ontime:
        cmp     HWF
        bcc     @last
        sta     HWF
@last:  lda     FRAME_LOAD              ; ...then the previous frame's pair
        cmp     #232
        bcc     @time
        inc     a                       ; only $FF is a late list; 232..254
                                        ;   (an overdue edge) is not counted
        bne     @done
        inc     NLATE
        bne     @done
        dec     NLATE                   ; saturate
        bra     @done
@time:  sec
        sbc     CKPREV                  ; the tail's cost
        bcc     @done                   ;   (a late checkpoint, $FF: none)
        cmp     HWT
        bcc     :+
        sta     HWT
:       lda     FRAME_LOAD
        cmp     HWL
        bcc     @done
        sta     HWL
        lda     CKPREV
        sta     HWC
@done:  pla
        sta     CKPREV                  ; this frame's, for the next frame
        rts
.endif
        .popseg
