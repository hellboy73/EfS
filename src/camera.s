; =============================================================================
; camera.s - the world turns, the ship does not
; =============================================================================
; Fixed decision 3: the ship is drawn essentially fixed and pointing up, and
; steering rotates the WORLD about it. So there is no camera position to
; integrate - there is a heading, its cosine and sine, and one transform that
; every object on screen goes through.
;
; The transform is a pair of 256-entry tables rebuilt whenever the heading
; moves (BUILD_ROT, in main.s), so a rotation costs four table reads and some
; adds per object rather than four multiplies - view_xform. Rotation and zoom
; are ONE matrix (fixed decision 4): the zoom rides in the same tables, and an
; object's own spin is folded into the angle before the GPU sees it.
; =============================================================================
; -----------------------------------------------------------------------------
; do_camera — cos/sin of the heading, then the two rotation tables.
; -----------------------------------------------------------------------------
do_camera:
        lda     HEAD
        jsr     API_COS
        sta     COSV
        ldx     #$00
        bit     COSV
        bpl     :+
        ldx     #$FF
:       stx     SGNC

        lda     HEAD
        jsr     API_SIN
        sta     SINV
        ldx     #$00
        bit     SINV
        bpl     :+
        ldx     #$FF
:       stx     SGNS

        ; The rotation tables are built HERE, and only on a frame where the
        ; heading actually moved — they are ~15k cycles and nothing else can
        ; change them. They used to be built inside star_rebase, which runs
        ; after do_objects: on a turning frame the objects would then transform
        ; against last frame's heading and lag the camera by a frame. Three
        ; things read them now — the starfield, the object centres, and (soon)
        ; the radar — so they belong to the camera, not to the stars.
        lda     HEAD
        cmp     ROTHEAD
        bne     :+                      ; (branching the other way is out of
        rts                             ;  range - two BUILD_ROTs is 147 bytes)
:       sta     ROTHEAD
        BUILD_ROT ROTC_I, ROTC_F, COSV, SGNC
        BUILD_ROT ROTS_I, ROTS_F, SINV, SGNS
        rts

; -----------------------------------------------------------------------------
; view_xform — rotate a WORLD-unit offset (PX, PY) into view coords.
; -----------------------------------------------------------------------------
;   vx =  px*cos + py*sin        vy = -px*sin + py*cos
;
; Four products, and they used to be four smul_core multiplies at ~300 cycles
; each because a world delta is 16-bit and neither the quarter-square table
; (8-bit operands) nor the ROT tables (a byte index) appeared to fit it. The ROT
; tables DO fit it — see RPROD — so this is now four table pairs and some adds,
; at the full 1/16-pixel resolution of a world coordinate. The caller rounds to
; a whole pixel afterwards, never before: rounding first is what used to make
; objects swim, and RPROD's own rounding is monotone so it cannot bring that
; back.
;
; The stars have always taken this shortcut. The only reason the objects did not
; was that nobody had noticed a 16-bit operand splits into two byte lookups.
; -----------------------------------------------------------------------------
view_xform:
        RPROD   ROTC_I, ROTC_F, PXL, PXH        ; vx = px*cos ...
        lda     T0
        sta     VXL
        lda     T1
        sta     VXH
        RPROD   ROTS_I, ROTS_F, PYL, PYH        ;      ... + py*sin
        clc
        lda     VXL
        adc     T0
        sta     VXL
        lda     VXH
        adc     T1
        sta     VXH

        RPROD   ROTC_I, ROTC_F, PYL, PYH        ; vy = py*cos ...
        lda     T0
        sta     VYL
        lda     T1
        sta     VYH
        RPROD   ROTS_I, ROTS_F, PXL, PXH        ;      ... - px*sin
        sec
        lda     VYL
        sbc     T0
        sta     VYL
        lda     VYH
        sbc     T1
        sta     VYH
        rts
