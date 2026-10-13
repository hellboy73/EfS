; =============================================================================
; tunnel_pod.s - the LIFEPODS: a pilot's capsule, a barrel flown lid-first at the
; camera, spinning on its own axis, to be caught (included by tunnel.s)
; =============================================================================
; design_technical.md 11.45 and open_questions.md H6 say what a pod is for: one for
; each ship lost in the sector, and a catch gives the ship back. So the tunnel flies
; as many as LVSTART - LIVES (the ships in hand when the sector began, less those
; now: hud_game.s), 0 to TUN_PODS, spread evenly (PODT*), and a catch is a ship
; back and the score (tunnel_hud.s tun_hud_pod). TUNTEST (make run-tunnel) flies three.
; The speech PILOT RESCUED and PILOT LOST IN SPACE come later.
;
; THE SHAPE (the user, 2026-10-13). A cylinder whose radius is the 128 rock's (32
; half-res px at TUN_ZFULL, R = 8.5 world units) and whose length is four times its
; diameter (TUN_PODL = 68 z), its axis along z, the front lid towards the camera. On
; the lid a square hatch, on the wall a square window; both turn with the roll.
;
; THE PROJECTION, AND WHY IT HAS NO GAPS. Every point of the barrel is a point of the
; front lid's circle scaled about the window's centre V (the vanishing point of the
; axis) by k = z1 / z, its depth's ratio: P(phi, z) = V + k (d1 + r1 u(phi)), d1 the
; lid's centre relative to V, r1 its radius, u the direction phi. So the back lid is
; the front lid's polygon scaled towards V (its centre k d1, its radius k r1), and
; vertex i of the one and vertex i of the other lie on ONE line through V. The side
; lines are those lines: they lead to the centre, and they start and end ON the
; polygons' own vertices - nothing to meet in the middle, nothing to overshoot.
; Which vertices: edge i of the lid's polygon (outward normal n_i, the edge's middle
; angle) FACES V when n_i . d1 + r1 cos(pi/N) < 0. The edges that face V are one run
; s..e; the barrel's outline is the WHOLE front polygon, the side line at vertex s,
; the back polygon's vertices s..e+1 (the arc on the centre's side) and the side line
; at vertex e+1. The same run is the part of the wall that faces the camera, so the
; window shows only between the angles of vertices s and e+1, and is cut there - on
; the side line itself. The polygon is TUN_PODN = 24 (the user), 12 beyond TUN_ZLOD;
; beyond TUN_ZDOT everything is dotted and the hatch and the window are left out.
;
; OCCLUSION. Three discs, cross sections of the barrel: the front lid (the pod's own
; slot), the middle (z + L/2) and the back lid (z + L) - the last two in the two
; slots after the rocks (TUN_ROCKS, TUN_ROCKS + 1), which nothing spawns into. Stars
; and rocks behind them are hidden by tunnel.s's own tests, which loop TUN_NDISC. The
; pod is hidden by the nearer rocks' discs edge by edge, the rocks' rule (an edge
; whose ends or middle are in a disc is not drawn).
;
; DRAWING. Every part is a LIST of points with its edges (QE: present or not) handed
; to tun_qdraw: the edges that show and lie inside the window's x range go out as
; OPEN POLYGON16 runs (one GPU command a run, anchored on its first point, the others
; as byte offsets), the ones that cross the HUD's frame as LINE16s cut to it.
; =============================================================================

TUN_PODS    = 4                 ; the most pods a tunnel flies: the fifth ship lost is CONTINUE
TUN_PODR    = 36                ; a catch: |rel x| and |rel y| both under this, world units
                                ;   (a rock's hit is 15, a cloud's catch 36; the pod's was 18,
                                ;   doubled to make it easy - the user, 2026-10-13)
TUN_PODSP   = 2                 ; the roll, brad a frame
TUN_PODG    = 90                ; frames before a pod in which no rock is born in its lane
TUN_PODL    = 68                ; its length in z: 4 x its diameter (2 x 8.5)
TUN_PODWA   = 31                ; the window's near edge, z behind the front lid...
TUN_PODWB   = 37                ; ...and its far edge: 6.7 units, the arc of 2 x WH below
TUN_PODWH   = 16                ; half the window's width, brad (45 degrees in all)
TUN_PODHD   = 80                ; the hatch's half-diagonal / the lid's radius, Q0.7: a
                                ;   square of side 0.44 of the diameter (the user: 0.45 + 50%,
                                ;   then 25% less, then a little less again, 2026-10-13)
TUN_PODAZ   = 140               ; THE ARROWS (the user, 2026-10-13): two of the exit's pointer
                                ;   sprites either side of a pod, pointing at it and blinking,
                                ;   with the UFO alarm's beep in step, from its birth until it
                                ;   is this near (z)
TUN_PODAG   = 6                 ; their tips this far outside the lid's radius, full-res px
TUN_PODAP   = 14                ; the blink: on for 8 frames of every 14 - SE_ALARM's own
TUN_PODAON  = 8                 ;   beep and gap, so firing it every 3 x 14 frames (it is
                                ;   three beeps) keeps the beeps on the arrows
TUN_DECO    = 0                 ; OUTSIDE THE TUBE (the user, 2026-10-13): rocks that fly past
                                ;   out of reach, for the look - one every this many frames, plus
                                ;   0..31. 0 = none: tried and switched OFF (the user). 40 was ~3
                                ;   more rocks at once and a worst frame of 96% CPU; 80 with the
                                ;   budget below was 80% (174 k = 73% without them)...
TUN_DECOM   = 6                 ; ...and only while fewer than this many rocks fly and no pod
                                ;   does: a budget, so the worst frame stays the tube's own
TUN_DECOX   = 112               ; ...at least this far off the axis on one side (to 127): the lean
                                ;   is 81 and a lane's rock +-16, so none can be reached
TUN_PODQ    = 40                ; the point list's size

        .assert TUN_PODQ >= 24 + 1, error, "tunnel_pod.s: the front lid's 24 points must fit the list"

        .segment "TUNBSS"
DSPT:   .res    1                       ; frames to the next rock outside the tube
DTMP:   .res    1
PODI:   .res    1                       ; the next pod: an index into PODTL/PODTH...
PODE:   .res    1                       ; ...and where this tunnel's run of them ends
PODLX:  .res    1                       ; ...and its lane, 0..2 per axis
PODLY:  .res    1
TPOD:   .res    1                       ; pods caught this passage
TPLOST: .res    1                       ; ...and the ones that went past
LIX:    .res    1                       ; a new rock's lane (0..3, 3 is the centre too)
LIY:    .res    1
PR1:    .res    1                       ; the front lid's radius, full-res px (<= 63)
PRR:    .res    1                       ; the radius of the ring being worked on
PKB:    .res    1                       ; the ratios z1 / z (/256): the back lid...
PKM:    .res    1                       ; ...the middle...
PKA:    .res    1                       ; ...and the window's near and far edges
PKW:    .res    1
PDOT:   .res    1                       ; 1 = far: dotted, no hatch, no window
PSTP:   .res    1                       ; a vertex step in 48ths of a turn: 2 (24) or 4 (12)
PNV:    .res    1                       ; ...and the vertex count
PVIS:   .res    1
PDXL:   .res    1                       ; d1, the front lid's centre from V, full-res fb:
PDXH:   .res    1                       ;   x as a magnitude and a sign ($80 = negative)...
PDXS:   .res    1
PDYL:   .res    1                       ; ...and y
PDYH:   .res    1
PDYS:   .res    1
PCXL:   .res    1                       ; the ring being worked on: its centre from V,
PCXH:   .res    1                       ;   signed 16, full-res fb
PCYL:   .res    1
PCYH:   .res    1
PTXL:   .res    1                       ; a point, absolute full-res fb, signed 16
PTXH:   .res    1
PTYL:   .res    1
PTYH:   .res    1
WXL:    .res    1                       ; a point tested against the discs
WXH:    .res    1
WYL:    .res    1
WYH:    .res    1
CU:     .res    1                       ; a direction: cos and sin, Q0.7
SU:     .res    1
NTXL:   .res    1                       ; d1 shifted down to a byte, for the facing test
NTXH:   .res    1
NTYL:   .res    1
NTYH:   .res    1
NRC:    .res    1                       ; ...and r1 cos(pi/N) shifted with it
RT:     .res    26                      ; tun_rtab's products: a ring's r |cos| (13), or
                                        ;   the facing test's |d.x| |cos| and |d.y| |cos|
PT1:    .res    1
PT2:    .res    1
PT3:    .res    1
PKH:    .res    1                       ; tun_kone's magnitude's high byte and sign...
PKS:    .res    1
PQL:    .res    1                       ; ...and its product
PQH:    .res    1
PF:     .res    24                      ; per edge of the lid: it faces V
LFXL:    .res    24                      ; the front lid's vertices, absolute
LFXH:    .res    24
LFYL:    .res    24
LFYH:    .res    24
PS:     .res    1                       ; the facing run: its first vertex...
PE:     .res    1                       ; ...the vertex after its last edge...
PRN:    .res    1                       ; ...and its edge count (0 = none: V is inside)
PLO8:   .res    1                       ; the window's angles, from PS's
PHI8:   .res    1
PSPAN:  .res    1
PCLL:   .res    1                       ; 1 = cut on that side by the side line
PCLR:   .res    1
PARR:   .res    1                       ; 1 = a pod wants its arrows this frame...
PAXL:   .res    1                       ; ...at its middle's fb x (absolute full-res)...
PAXH:   .res    1
PALL:   .res    1                       ; ...the left one's tip (fb y, outside both lids)...
PALH:   .res    1
PARL:   .res    1                       ; ...and the right one's
PARH:   .res    1
FCYL:   .res    1                       ; the front lid's centre fb y (from V), for them
FCYH:   .res    1
PODBT:  .res    1                       ; the blink's clock, 0..3 x TUN_PODAP - 1
PANG:   .res    6                       ; the window's arc, brad
PANN:   .res    1
QXL:    .res    TUN_PODQ                ; THE POINT LIST: absolute full-res fb, signed 16
QXH:    .res    TUN_PODQ
QYL:    .res    TUN_PODQ
QYH:    .res    TUN_PODQ
QE:     .res    TUN_PODQ                ; edge i (point i to i + 1, wrapping) is part of it
QH:     .res    TUN_PODQ                ; point i is behind a nearer rock
QI:     .res    TUN_PODQ                ; point i is inside the window's x range
QV:     .res    TUN_PODQ                ; edge i is drawn
QO:     .res    TUN_PODQ                ; point i's outcode against the window
QN:     .res    1
QA:     .res    1                       ; the edge (or point) being worked on...
QB:     .res    1                       ; ...and the next
QS:     .res    1                       ; an invisible edge to start the walk from
QK:     .res    1
RUNN:   .res    1                       ; the run being collected: its points...
RAXL:   .res    1                       ; ...and its anchor (the first)
RAXH:   .res    1
RAYL:   .res    1
RAYH:   .res    1
PODBUF:   .res    7 + 2 * (TUN_PODQ + 1)  ; the POLYGON16 argument block
LAXL:   .res    1                       ; a cut line: its piece's start...
LAXH:   .res    1
LAYL:   .res    1
LAYH:   .res    1
LBXL:   .res    1                       ; ...its end...
LBXH:   .res    1
LBYL:   .res    1
LBYH:   .res    1
LSXL:   .res    1                       ; ...the step between pieces...
LSXH:   .res    1
LSYL:   .res    1
LSYH:   .res    1
LEXL:   .res    1                       ; ...and the line's own end
LEXH:   .res    1
LEYL:   .res    1
LEYH:   .res    1


        .segment "TUNCODE3"

; |cos| of j/48 of a turn, j = 0..12 (Q0.7), and for each k/48 of a turn which of
; them is its cos and its sin (bit 7: negative) - the API's sense. The 24-gon's vertices
; are the even k, its edges' normals the odd ones. A ring's 13 products r |cos| are made
; once (tun_rtab) and every point of it is read out of them.
MAG13:  .byte   127, 126, 123, 117, 110, 101, 90, 77, 64, 49, 33, 17, 0
CJ48:   .byte   $00, $01, $02, $03, $04, $05, $06, $07, $08, $09, $0A, $0B
        .byte   $0C, $8B, $8A, $89, $88, $87, $86, $85, $84, $83, $82, $81
        .byte   $80, $81, $82, $83, $84, $85, $86, $87, $88, $89, $8A, $8B
        .byte   $0C, $0B, $0A, $09, $08, $07, $06, $05, $04, $03, $02, $01
SJ48:   .byte   $0C, $0B, $0A, $09, $08, $07, $06, $05, $04, $03, $02, $01
        .byte   $00, $01, $02, $03, $04, $05, $06, $07, $08, $09, $0A, $0B
        .byte   $0C, $8B, $8A, $89, $88, $87, $86, $85, $84, $83, $82, $81
        .byte   $80, $81, $82, $83, $84, $85, $86, $87, $88, $89, $8A, $8B
; ...and the angle in brad
BR48:   .byte   0, 5, 11, 16, 21, 27, 32, 37, 43, 48, 53, 59
        .byte   64, 69, 75, 80, 85, 91, 96, 101, 107, 112, 117, 123
        .byte   128, 133, 139, 144, 149, 155, 160, 165, 171, 176, 181, 187
        .byte   192, 197, 203, 208, 213, 219, 224, 229, 235, 240, 245, 251

; The ratios z1 / (z1 + off), /256, by the pod's depth in the rocks' tiers (TZ, RTIER:
; 256 bytes for tier 0, then 128 each for tiers 1 and 2, read as K + 128,y and K + 256,y).
; z1 is held at TUN_ZFULL nearer than that, as the scale is: the pod stops growing
; there, whole.
        .macro  KTAB off
        .repeat 256, I
        .byte   .min(255, (256 * .max(I, TUN_ZFULL) + (.max(I, TUN_ZFULL) + off) / 2) / (.max(I, TUN_ZFULL) + off))
        .endrepeat
        .repeat 128, J
        .byte   .min(255, (512 * (J + 128) + (2 * (J + 128) + off) / 2) / (2 * (J + 128) + off))
        .endrepeat
        .repeat 128, J
        .byte   .min(255, (1024 * (J + 128) + (4 * (J + 128) + off) / 2) / (4 * (J + 128) + off))
        .endrepeat
        .endmacro
KTB:    KTAB    TUN_PODL
KTM:    KTAB    TUN_PODL / 2
KTA:    KTAB    TUN_PODWA
KTW:    KTAB    TUN_PODWB
LANE3:  .byte   <(-TUN_AMP), 0, TUN_AMP
; when each pod is born (frames flown), TBM: one run per count, spread evenly - 1: 1500;
; 2: 1000, 2000; 3: 900, 1800, 2700; 4: 600, 1200, 1800, 2400. PODS0 is where count N's
; run starts.
PODTL:  .byte   <1500, <1000, <2000, <900, <1800, <2700, <600, <1200, <1800, <2400
PODTH:  .byte   >1500, >1000, >2000, >900, >1800, >2700, >600, >1200, >1800, >2400
PODS0:  .byte   0, 0, 1, 3, 6
        .assert TUN_PODS = 4, error, "tunnel_pod.s: PODTL/PODTH hold runs for 1..4 pods"
        .assert 2700 < TUN_FRAMES - TUN_RUSHF - TUN_CLEAR, error, "tunnel_pod.s: the last pod must be born before the rocks stop"

; -----------------------------------------------------------------------------
; tun_pod_init - no pod flown yet, none caught; the first one's lane. The two ghost
; discs hide nothing.
; -----------------------------------------------------------------------------
tun_pod_init:
        lda     #20                     ; the first rock outside the tube a third of a second in
        sta     DSPT
.if TUNTEST
        lda     #3                      ; (no sector behind it: three)
.else
        lda     LVSTART                 ; the ships lost in the sector...
        sec
        sbc     LIVES
        bcs     :+
        lda     #0                      ;   (more now than then: none)
:       cmp     #TUN_PODS + 1
        bcc     :+
        lda     #TUN_PODS               ;   ...at most TUN_PODS
:
.endif
        tax                             ; ...and their run in PODTL/PODTH
        lda     PODS0,x
        sta     PODI
        clc
        txa
        adc     PODI
        sta     PODE
        stz     TPOD
        stz     TPLOST
        ldx     #TUN_ROCKS
        stz     ROC,x
        stz     RZL,x
        stz     RZH,x
        inx
        stz     ROC,x
        stz     RZL,x
        stz     RZH,x
        ; fall through

; tun_pod_lane - the next pod's lane, 0..2 on each axis.
tun_pod_lane:
@x:     jsr     prng
        and     #3
        cmp     #3
        beq     @x
        sta     PODLX
@y:     jsr     prng
        and     #3
        cmp     #3
        beq     @y
        sta     PODLY
        rts

; -----------------------------------------------------------------------------
; tun_deco - a rock OUTSIDE THE TUBE now and then (TUN_DECO): born far like the others, on
; a place at least TUN_DECOX off the axis on one side (x or y, either sign) and anywhere
; on the other, never tested against the ship (RHI = 1). Pods and Saturnium stay in the
; tube. It lives here, not beside tun_spawn, because bank 10 is full.
; -----------------------------------------------------------------------------
tun_deco:
.if TUN_DECO
        dec     DSPT
        bne     @r
        jsr     prng
        and     #31
        clc
        adc     #TUN_DECO
        sta     DSPT
        lda     SC_PTRL                 ; none in the run's end either
        cmp     #<(TUN_FRAMES - TUN_RUSHF - TUN_CLEAR)
        lda     SC_PTRH
        sbc     #>(TUN_FRAMES - TUN_RUSHF - TUN_CLEAR)
        bcs     @r
        stz     PT1                     ; the budget: how many fly, and is one a pod?
        ldx     #TUN_ROCKS - 1
:       lda     RZL,x
        ora     RZH,x
        beq     :+
        inc     PT1
        lda     RKIND,x
        cmp     #2
        beq     @r                      ; a pod in flight: it has the frame
:       dex
        bpl     :--
        lda     PT1
        cmp     #TUN_DECOM
        bcs     @r
        ldx     #TUN_ROCKS - 1
:       lda     RZL,x
        ora     RZH,x
        beq     @free
        dex
        bpl     :-
@r:     rts
@free:  stx     TRK
        lda     #<TUN_RZMAX
        sta     RZL,x
        lda     #>TUN_RZMAX
        sta     RZH,x
        lda     #1
        sta     RHI,x                   ; (out of reach: never tested)
        stz     RDF,x
        stz     ROC,x
        stz     RKIND,x
        jsr     prng
        and     #3
        ldx     TRK
        sta     RTY,x
        jsr     prng
        ldx     TRK
        sta     RAN,x
        jsr     prng
        and     #TUN_RSPIN
        sec
        sbc     #4
        ldx     TRK
        sta     RSP,x
        jsr     prng                    ; bit 0: which axis is off; bit 1: which side
        sta     DTMP
        .assert (127 - TUN_DECOX) & (128 - TUN_DECOX) = 0, error, "tunnel_pod.s: 127 - TUN_DECOX must be a mask (2^n - 1)"
        jsr     prng
        and     #127 - TUN_DECOX
        clc
        adc     #TUN_DECOX              ; TUN_DECOX..127...
        sta     PT1                     ; the off coordinate...
        lda     DTMP
        and     #2
        beq     :+
        lda     #0                      ; ...or its negative
        sec
        sbc     PT1
        sta     PT1
:
        jsr     prng
        sta     PT2                     ; ...and the other, anywhere
        ldx     TRK
        lda     DTMP
        lsr     a
        bcc     @ony
        lda     PT1
        sta     RXW,x
        lda     PT2
        sta     RYW,x
        rts
@ony:   lda     PT1
        sta     RYW,x
        lda     PT2
        sta     RXW,x
.endif
        rts

; (tun_ring and tun_rmul are the roll's - tunnel.s - and live here because bank 10 is full)
; tun_ring - thing X (TRK) in a CORNER lane (|x| and |y| both over 40: the lanes are
; 0 or +-AMP, give or take 16) is pulled in to the roll's ring: x and y times 181/256
; (1/sqrt 2), so (AMP, AMP) is AMP from the axis, like the side lanes.
tun_ring:
        lda     RXW,x
        jsr     tun_abs
        cmp     #41
        bcc     @r
        lda     RYW,x
        jsr     tun_abs
        cmp     #41
        bcc     @r
        lda     RXW,x
        jsr     @s
        sta     RXW,x
        lda     RYW,x
        jsr     @s
        sta     RYW,x
@r:     rts
@s:     sta     TMV                     ; A * 181 >> 8, rounded, signed
        jsr     tun_abs
        tax
        lda     #181
        jsr     tun_rmul
        lda     PL
        asl     a
        lda     PH
        adc     #0
        ldx     TMV
        bpl     :+
        eor     #$FF
        clc
        adc     #$01
:       ldx     TRK
        rts

; tun_rmul - A (0..255) * X (0..127) -> PH:PL, exact: umul, or when A + X is past the
; table, 2 * (A >> 1) * X (+ X if A was odd).
tun_rmul:
        sta     TA
        stx     TB
        clc
        adc     TB
        bcs     @big
        jmp     umul                    ; tail
@big:   lda     TA
        sta     RMT
        lsr     a
        sta     TA
        jsr     umul
        asl     PL
        rol     PH
        lda     RMT
        lsr     a
        bcc     @r
        clc
        lda     PL
        adc     TB
        sta     PL
        bcc     @r
        inc     PH
@r:     rts

; -----------------------------------------------------------------------------
; tun_pod_sched - once a frame, before the rocks: the ghost discs are cleared (the
; pod sets them again if it is in view) and the next pod is born when its time has
; come and a slot is free (else it waits a frame).
; -----------------------------------------------------------------------------
tun_pod_sched:
        stz     PARR
        stz     ROC + TUN_ROCKS
        stz     ROC + TUN_ROCKS + 1
        lda     SC_PTRL                 ; past the point where rocks stop (a clock moved on:
        cmp     #<(TUN_FRAMES - TUN_RUSHF - TUN_CLEAR)  ;   FIRE in run-tunnel, a bench):
        lda     SC_PTRH                 ;   no pod is born late, in the run's end
        sbc     #>(TUN_FRAMES - TUN_RUSHF - TUN_CLEAR)
        bcc     :+
        lda     PODE
        sta     PODI
:       ldx     PODI
        cpx     PODE
        bcs     @r
        lda     SC_PTRL
        cmp     PODTL,x
        lda     SC_PTRH
        sbc     PODTH,x
        bcc     @r                      ; not yet
        ldx     #TUN_ROCKS - 1
:       lda     RZL,x
        ora     RZH,x
        beq     @free
        dex
        bpl     :-
@r:     rts
@free:  stx     TRK
        lda     #<TUN_RZMAX
        sta     RZL,x
        lda     #>TUN_RZMAX
        sta     RZH,x
        stz     RHI,x
        stz     RDF,x
        stz     ROC,x
        stz     RTY,x
        lda     #2
        sta     RKIND,x
        lda     #TUN_PODSP
        sta     RSP,x
        jsr     prng
        ldx     TRK
        sta     RAN,x
        ldy     PODLX                   ; its lane, give or take 8
        jsr     @jit
        sta     RXW,x
        ldy     PODLY
        jsr     @jit
        sta     RYW,x
        jsr     tun_ring                ; a corner lane pulled in to the roll's ring
        inc     PODI
        jmp     tun_pod_lane            ; (tail) the next one's
@jit:   jsr     prng
        and     #15
        sec
        sbc     #8
        clc
        adc     LANE3,y
        ldx     TRK
        rts

; -----------------------------------------------------------------------------
; tun_pod_guard - rock TRK has just been born in lane LIX, LIY. If the next pod is
; due within TUN_PODG frames in the same lane, the rock is moved one lane over on x:
; a pod is always reachable (the generator's guarantee, H6).
; -----------------------------------------------------------------------------
tun_pod_guard:
        ldx     PODI
        cpx     PODE
        bcs     @r
        lda     PODTL,x
        sec
        sbc     SC_PTRL
        sta     PT1
        lda     PODTH,x
        sbc     SC_PTRH
        bne     @r                      ; far off (or past)
        lda     PT1
        cmp     #TUN_PODG
        bcs     @r
        lda     LIY
        cmp     #3
        bne     :+
        lda     #1
:       cmp     PODLY
        bne     @r
        lda     LIX
        cmp     #3
        bne     :+
        lda     #1
:       cmp     PODLX
        bne     @r
        ldx     TRK
        cmp     #2
        beq     @back
        lda     RXW,x
        clc
        adc     #TUN_AMP
        sta     RXW,x
        rts
@back:  lda     RXW,x
        sec
        sbc     #2 * TUN_AMP
        sta     RXW,x
@r:     rts

; -----------------------------------------------------------------------------
; tun_pod_catch - pod TRK has been caught: a sound (a stand-in: the speech PILOT
; RESCUED comes later), the tally, the pod gone.
; -----------------------------------------------------------------------------
tun_pod_catch:
        lda     #SE_TELEPORT
        jsr     sfx_fire
        inc     TPOD
        jsr     tun_hud_pod             ; a ship back, and the score (tunnel_hud.s)
        ldx     TRK
        stz     RZL,x
        stz     RZH,x
        rts

; -----------------------------------------------------------------------------
; tun_pod_p1 - pass 1 for pod TRK, from tun_rocks_frame once it is projected (TZ,
; RTIER, SCL, XM/YM and their signs SXS/SYS): its radius, d1, its detail, the ratios
; of its rings, its three discs, and whether any of it is in the window (RVIS).
; -----------------------------------------------------------------------------
tun_pod_p1:
        lda     SCL                     ; the radius: 64 at 1:1 is the 128 rock's,
        lsr     a                       ;   held at 63 so a lid's chord is a byte
        cmp     #64
        bcc     :+
        lda     #63
:       sta     PR1
        lda     YML                     ; fb x = 2 oy...
        asl     a
        sta     PDXL
        lda     YMH
        rol     a
        sta     PDXH
        lda     SYS
        sta     PDXS
        lda     XML                     ; ...fb y = -2 ox
        asl     a
        sta     PDYL
        lda     XMH
        rol     a
        sta     PDYH
        lda     SXS
        eor     #$80
        sta     PDYS
        ldy     TZ                      ; the four ratios, by depth
        lda     RTIER
        beq     @t0
        cmp     #1
        beq     @t1
        lda     KTB + 256,y
        sta     PKB
        lda     KTM + 256,y
        sta     PKM
        lda     KTA + 256,y
        sta     PKA
        lda     KTW + 256,y
        sta     PKW
        bra     @td
@t1:    lda     KTB + 128,y
        sta     PKB
        lda     KTM + 128,y
        sta     PKM
        lda     KTA + 128,y
        sta     PKA
        lda     KTW + 128,y
        sta     PKW
        bra     @td
@t0:    lda     KTB,y
        sta     PKB
        lda     KTM,y
        sta     PKM
        lda     KTA,y
        sta     PKA
        lda     KTW,y
        sta     PKW
@td:    ldx     TRK
        stz     PDOT                    ; dotted beyond TUN_ZDOT
        lda     RZL,x
        cmp     #<(TUN_ZDOT + 1)
        lda     RZH,x
        sbc     #>(TUN_ZDOT + 1)
        rol     PDOT
        lda     #2                      ; 24 vertices...
        sta     PSTP
        lda     #24
        sta     PNV
        lda     RZH,x
        bne     @lod
        lda     RZL,x
        cmp     #TUN_ZLOD + 1
        bcc     @full
@lod:   lda     #4                      ; ...or 12 beyond TUN_ZLOD
        sta     PSTP
        lda     #12
        sta     PNV
@full:  stz     PVIS
        jsr     tun_pfront              ; the front lid: its disc in its own slot
        lda     PCYL
        sta     FCYL
        lda     PCYH
        sta     FCYH
        jsr     tun_pin
        bcs     :+
        inc     PVIS
:       ldx     TRK
        jsr     tun_pdisc
        lda     PKM                     ; the middle
        jsr     tun_kmul
        lda     PCXL                    ; (its arrows' fb x)
        clc
        adc     #200
        sta     PAXL
        lda     PCXH
        adc     #0
        sta     PAXH
        ldx     #TUN_ROCKS
        jsr     tun_pdisc
        ldy     TRK
        lda     RZL,y
        clc
        adc     #<(TUN_PODL / 2)
        sta     RZL,x
        lda     RZH,y
        adc     #>(TUN_PODL / 2)
        sta     RZH,x
        lda     PKB                     ; the back lid
        jsr     tun_kmul
        jsr     tun_parw                ; (where its arrows go)
        jsr     tun_pin
        bcs     :+
        inc     PVIS
:       ldx     #TUN_ROCKS + 1
        jsr     tun_pdisc
        ldy     TRK
        lda     RZL,y
        clc
        adc     #<TUN_PODL
        sta     RZL,x
        lda     RZH,y
        adc     #>TUN_PODL
        sta     RZH,x
        ldx     TRK
        lda     PVIS
        beq     @out
        lda     #1
        sta     RVIS,x
        rts
@out:   stz     PARR                    ; out of the window: no arrows...
        stz     ROC,x                   ; ...and it hides nothing either
        stz     ROC + TUN_ROCKS
        stz     ROC + TUN_ROCKS + 1
        rts

; tun_povl - C SET when disc Y (a nearer rock's) overlaps the pod's disc X, which is
; taken half as big again (the hull between the three discs is a little wider than
; they are). The octagon distance of the stars' test. Keeps X and Y.
tun_povl:
        lda     ROC,x
        beq     @no
        lsr     a
        clc
        adc     ROC,x
        adc     ROC,y
        sta     PT3                     ; (at most 48 + 39: a byte)
        lda     RBX,y
        sec
        sbc     RBX,x
        bcs     :+
        eor     #$FF
        adc     #$01
:       cmp     PT3
        bcs     @no
        sta     DXM
        lda     RBY,y
        sec
        sbc     RBY,x
        bcs     :+
        eor     #$FF
        adc     #$01
:       cmp     PT3
        bcs     @no
        sta     DYM
        cmp     DXM
        bcs     @ym
        lsr     a
        clc
        adc     DXM
        bra     @c
@ym:    lda     DXM
        lsr     a
        clc
        adc     DYM
@c:     cmp     PT3                     ; C clear when nearer than the two radii
        bcs     @no
        sec
        rts
@no:    clc
        rts

; tun_parw - pod TRK's arrows, if it is still far (z >= TUN_PODAZ): either side of the
; whole of it - the left tip TUN_PODAG past the larger of the two lids' fb y + r, the
; right one past the smaller of their fb y - r (the ring PC, PRR is the back lid here;
; FCY and PR1 the front's). Whether any of it is in the window is pass 1's to say:
; PARR is cleared again if it is not. Keeps PC and PRR.
tun_parw:
        ldx     TRK
        lda     RZL,x
        cmp     #<TUN_PODAZ
        lda     RZH,x
        sbc     #>TUN_PODAZ
        bcs     :+
        rts                             ; near: it needs no pointing out
:       lda     FCYL                    ; the front: y + r...
        clc
        adc     PR1
        sta     PALL
        lda     FCYH
        adc     #0
        sta     PALH
        lda     PCYL                    ; ...against the back's
        clc
        adc     PRR
        tax
        lda     PCYH
        adc     #0
        tay
        cpx     PALL                    ; the larger
        sbc     PALH
        bvc     :+
        eor     #$80
:       bmi     :+
        stx     PALL
        sty     PALH
:       lda     FCYL                    ; ...and y - r, the smaller
        sec
        sbc     PR1
        sta     PARL
        lda     FCYH
        sbc     #0
        sta     PARH
        lda     PCYL
        sec
        sbc     PRR
        tax
        lda     PCYH
        sbc     #0
        tay
        cpx     PARL
        sbc     PARH
        bvc     :+
        eor     #$80
:       bpl     :+
        stx     PARL
        sty     PARH
:       lda     PALL                    ; absolute, and the gap outside them
        clc
        adc     #150 + TUN_PODAG
        sta     PALL
        lda     PALH
        adc     #0
        sta     PALH
        lda     PARL
        clc
        adc     #<(150 - TUN_PODAG)
        sta     PARL
        lda     PARH
        adc     #>(150 - TUN_PODAG)
        sta     PARH
        lda     #1
        sta     PARR
        rts

; tun_pod_arrows - last in the frame, over everything (the sprites are OVERLAY): the
; two arrows of a pod that wants them, blinking, and the alarm's beep in step. With
; no pod to point at the clock starts again, so the next one begins on a beep.
tun_pod_arrows:
        lda     PARR
        bne     :+
        stz     PODBT
        rts
:       lda     PODBT
        bne     :+
        lda     #SE_ALARM               ; three beeps, on the first three blinks
        jsr     sfx_fire
:       lda     PODBT                   ; the blink's phase: PODBT mod TUN_PODAP
:       cmp     #TUN_PODAP
        bcc     :+
        sbc     #TUN_PODAP
        bra     :-
:       sta     PT1
        inc     PODBT
        lda     PODBT
        cmp     #3 * TUN_PODAP
        bcc     :+
        stz     PODBT
:       lda     PT1
        cmp     #TUN_PODAON
        bcc     :+
        rts                             ; (off)
:       lda     PALL                    ; the LEFT one (portrait), pointing right
        sta     PTYL
        lda     PALH
        sta     PTYH
        ldx     #0
        jsr     @one
        lda     PARL                    ; the RIGHT one, pointing left
        sta     PTYL
        lda     PARH
        sta     PTYH
        ldx     #1
@one:   lda     PAXL                    ; X = 0 (ARW_RIGHT) or 1 (ARW_LEFT): top-left =
        sec                             ;   the tip - its place in the sprite
        sbc     @tx,x
        sta     OS_ARG+1
        lda     PAXH
        sbc     #0
        sta     OS_ARG+2                ; wholly inside the window's fb x 50..333
        beq     @x0
        cmp     #1
        bne     @no
        lda     OS_ARG+1                ; 256..333
        cmp     #<(349 - 16 + 1)
        bcs     @no
        bra     @xok
@x0:    lda     OS_ARG+1                ; 50..255
        cmp     #50
        bcc     @no
@xok:
        lda     PTYL
        sec
        sbc     @ty,x
        sta     OS_ARG+3
        lda     PTYH
        sbc     #0
        sta     OS_ARG+4                ; ...and on the screen's fb y 0..299: a top row
        beq     @yok                    ;   of 0..255, or 256..288
        cmp     #1
        bne     @no
        lda     OS_ARG+3
        cmp     #<(300 - ARW_RIGHT_HEIGHT)
        bcs     @no
@yok:
        txa
        clc
        adc     #ARW_SLOT0
        sta     OS_ARG+0
        jmp     API_GPU_SPRITE          ; tail
@no:    rts
@tx:    .byte   ARW_RIGHT_TX, ARW_LEFT_TX
@ty:    .byte   ARW_RIGHT_TY, ARW_LEFT_TY

; tun_pfront - the ring is the front lid: PC = d1, PRR = PR1.
tun_pfront:
        lda     PDXL
        sta     PCXL
        lda     PDXH
        sta     PCXH
        bit     PDXS
        bpl     :+
        lda     #0
        sec
        sbc     PCXL
        sta     PCXL
        lda     #0
        sbc     PCXH
        sta     PCXH
:       lda     PDYL
        sta     PCYL
        lda     PDYH
        sta     PCYH
        bit     PDYS
        bpl     :+
        lda     #0
        sec
        sbc     PCYL
        sta     PCYL
        lda     #0
        sbc     PCYH
        sta     PCYH
:       lda     PR1
        sta     PRR
        rts

; tun_kmul - A = a ratio k (/256): the ring at that depth. PC = k d1, PRR = k PR1 / 256.
tun_kmul:
        sta     MB8
        lda     PDXL
        sta     MA8
        lda     PDXH
        sta     PKH
        lda     PDXS
        sta     PKS
        jsr     tun_kone
        lda     PQL
        sta     PCXL
        lda     PQH
        sta     PCXH
        lda     PDYL
        sta     MA8
        lda     PDYH
        sta     PKH
        lda     PDYS
        sta     PKS
        jsr     tun_kone
        lda     PQL
        sta     PCYL
        lda     PQH
        sta     PCYH
        lda     PR1
        sta     MA8
        jsr     tun_mul8
        lda     MPL
        asl     a                       ; (rounded)
        lda     MPH
        adc     #0
        sta     PRR
        rts

; tun_kone - (PKH:MA8) * MB8 / 256, rounded, signed by PKS -> PQH:PQL.
tun_kone:
        jsr     tun_mul8                ; lo * k
        lda     MPL
        asl     a
        lda     MPH
        adc     #0
        sta     PQL
        stz     PQH
        lda     PKH
        sta     MA8
        jsr     tun_mul8                ; hi * k
        lda     MPL
        clc
        adc     PQL
        sta     PQL
        lda     MPH
        adc     #0
        sta     PQH
        bit     PKS
        bpl     @p
        lda     #0
        sec
        sbc     PQL
        sta     PQL
        lda     #0
        sbc     PQH
        sta     PQH
@p:     rts

; tun_abs16 - X:A (hi:lo) signed -> its magnitude in X:A.
tun_abs16:
        cpx     #$80
        bcc     @r
        eor     #$FF
        clc
        adc     #1
        pha
        txa
        eor     #$FF
        adc     #0
        tax
        pla
@r:     rts

; tun_pin - C SET when the disc PC, PRR is wholly outside the window (|x| or |y| from
; its centre at least 150 + r, full-res).
tun_pin:
        lda     PRR
        clc
        adc     #150
        sta     PT3
        lda     PCXL
        ldx     PCXH
        jsr     tun_abs16
        cpx     #0
        bne     @out
        cmp     PT3
        bcs     @out
        lda     PCYL
        ldx     PCYH
        jsr     tun_abs16
        cpx     #0
        bne     @out
        cmp     PT3
        bcs     @out
        clc
        rts
@out:   sec
        rts

; tun_fit - PT1:A (hi:lo), a signed 16: C CLEAR when it is a byte in -127..127 (in
; A), else C SET. Clobbers Y, keeps X.
tun_fit:
        ldy     PT1
        beq     @pos
        cpy     #$FF
        bne     @no
        cmp     #$81
        bcc     @no
        clc
        rts
@pos:   cmp     #$80                    ; (C clear when it fits)
        bcs     @no
        rts
@no:    sec
        rts

; tun_clamp - PT1:A (hi:lo), a signed 16 -> A, held to -127..127. Clobbers Y.
tun_clamp:
        ldy     PT1
        bmi     @neg
        bne     @max
        cmp     #$80
        bcc     @r
@max:   lda     #127
        rts
@neg:   cpy     #$FF
        bne     @min
        cmp     #$81
        bcs     @r
@min:   lda     #$81
@r:     rts

; tun_pdisc - the ring PC, PRR as slot X's occlusion disc (tunnel.s's RBX/RBY: window
; offsets, half-res, biased 128): none (ROC = 0) if its centre is past a byte, which
; is past the window for a radius this size.
tun_pdisc:
        stz     ROC,x
        lda     PCXH                    ; fb x / 2 is the portrait y offset
        cmp     #$80
        ror     a
        sta     PT1
        lda     PCXL
        ror     a
        jsr     tun_fit
        bcs     @r
        eor     #$80
        sta     RBY,x
        lda     PCYH                    ; fb y / 2 is minus the portrait x offset
        cmp     #$80
        ror     a
        sta     PT1
        lda     PCYL
        ror     a
        jsr     tun_fit
        bcs     @r
        sta     PT2
        lda     #128
        sec
        sbc     PT2
        sta     RBX,x
        lda     PRR
        lsr     a
        sta     ROC,x
@r:     rts

; tun_rtab - the ring's 13 products PRR |cos j| (RT), for tun_ppk.
tun_rtab:
        ldx     #12
:       lda     PRR
        sta     MQA
        lda     MAG13,x
        sta     MQB
        phx
        jsr     qmul
        plx
        sta     RT,x
        dex
        bpl     :-
        rts

; tun_rv - A = an index into RT (+ X) with bit 7 the sign -> A = that product, signed.
tun_rv:
        stx     PT3
        cmp     #$80                    ; (the sign from the byte itself: the caller's
        bcs     @n                      ;   LDX has just set N)
        adc     PT3
        tax
        lda     RT,x
        rts
@n:     and     #$7F
        clc
        adc     PT3
        tax
        lda     RT,x
        eor     #$FF
        inc     a
        rts

; tun_ppk - Y = k (48ths of a turn): the point of the ring PC (its products in RT) in
; that direction -> PT, absolute.
tun_ppk:
        lda     CJ48,y
        sta     CU
        lda     SJ48,y
        sta     SU
        lda     CU
        ldx     #0
        jsr     tun_rv
        ldx     #0
        cmp     #$80
        bcc     :+
        dex
:       clc
        adc     PCXL
        sta     PTXL
        txa
        adc     PCXH
        sta     PTXH
        lda     PTXL
        clc
        adc     #200
        sta     PTXL
        bcc     :+
        inc     PTXH
:       lda     SU
        ldx     #0
        jsr     tun_rv
        ldx     #0
        cmp     #$80
        bcc     :+
        dex
:       clc
        adc     PCYL
        sta     PTYL
        txa
        adc     PCYH
        sta     PTYH
        lda     PTYL
        clc
        adc     #150
        sta     PTYL
        bcc     :+
        inc     PTYH
:       rts

; tun_ppt - the point of the ring PC, PRR in the direction CU, SU -> PT, absolute.
tun_ppt:
        lda     PRR
        sta     SMB
        lda     CU
        jsr     tun_sm
        ldx     #0
        cmp     #$80
        bcc     :+
        dex
:       clc
        adc     PCXL
        sta     PTXL
        txa
        adc     PCXH
        sta     PTXH
        lda     PTXL
        clc
        adc     #200
        sta     PTXL
        bcc     :+
        inc     PTXH
:       lda     PRR
        sta     SMB
        lda     SU
        jsr     tun_sm
        ldx     #0
        cmp     #$80
        bcc     :+
        dex
:       clc
        adc     PCYL
        sta     PTYL
        txa
        adc     PCYH
        sta     PTYH
        lda     PTYL
        clc
        adc     #150
        sta     PTYL
        bcc     :+
        inc     PTYH
:       rts

; tun_vang - QB = a vertex of the lid -> Y = its place in the 48ths.
tun_vang:
        lda     QB
        asl     a
        ldx     PSTP
        cpx     #4
        bne     :+
        asl     a
:       tay
        rts

; tun_qput - Q[X] = PT, its edge part of the list.
tun_qput:
        lda     PTXL
        sta     QXL,x
        lda     PTXH
        sta     QXH,x
        lda     PTYL
        sta     QYL,x
        lda     PTYH
        sta     QYH,x
        lda     #1
        sta     QE,x
        rts

; tun_fput - Q[Y] = the front lid's vertex X.
tun_fput:
        lda     LFXL,x
        sta     QXL,y
        lda     LFXH,x
        sta     QXH,y
        lda     LFYL,x
        sta     QYL,y
        lda     LFYH,x
        sta     QYH,y
        lda     #1
        sta     QE,y
        rts

; tun_qmid - Q[X] = the midpoint of Q[X - 1] and Q[X + 1].
tun_qmid:
        lda     QXL - 1,x
        clc
        adc     QXL + 1,x
        sta     QXL,x
        lda     QXH - 1,x
        adc     QXH + 1,x
        cmp     #$80
        ror     a
        sta     QXH,x
        ror     QXL,x
        lda     QYL - 1,x
        clc
        adc     QYL + 1,x
        sta     QYL,x
        lda     QYH - 1,x
        adc     QYH + 1,x
        cmp     #$80
        ror     a
        sta     QYH,x
        ror     QYL,x
        lda     #1
        sta     QE,x
        rts

; -----------------------------------------------------------------------------
; tun_draw_pod - pass 2 for pod TRK: the nearer discs, then the front lid, the
; outline's far side (side line, back arc, side line), the hatch and the window.
; -----------------------------------------------------------------------------
tun_draw_pod:
        stz     NCNT                    ; the nearer discs, as offsets from the window's
        ldy     #TUN_NDISC - 1          ;   centre (fb half-res, biased): every disc
@n:     cpy     TRK                     ;   nearer than the front lid
        beq     @nn
        lda     ROC,y
        beq     @nn
        ldx     TRK
        lda     RZL,y
        cmp     RZL,x
        lda     RZH,y
        sbc     RZH,x
        bcs     @nn
        ldx     TRK                     ; ...and only one that overlaps one of the pod's
        jsr     tun_povl                ;   own three discs: the rest cannot hide any of
        bcs     @tk                     ;   it, and every one kept is a test for every
        ldx     #TUN_ROCKS              ;   point and edge of the pod
        jsr     tun_povl
        bcs     @tk
        ldx     #TUN_ROCKS + 1
        jsr     tun_povl
        bcc     @nn
@tk:    lda     RBY,y
        sta     NBX,y
        lda     #0
        sec
        sbc     RBX,y
        sta     NBY,y
        ldx     NCNT
        tya
        sta     NLIST,x
        inc     NCNT
@nn:    dey
        bpl     @n
        ; --- the front lid: the whole polygon -------------------------------
        jsr     tun_pfront
        stz     QB
        jsr     tun_rtab
@fv:    jsr     tun_vang
        jsr     tun_ppk
        ldx     QB
        jsr     tun_qput
        lda     PTXL
        sta     LFXL,x
        lda     PTXH
        sta     LFXH,x
        lda     PTYL
        sta     LFYL,x
        lda     PTYH
        sta     LFYH,x
        inc     QB
        lda     QB
        cmp     PNV
        bne     @fv
        sta     QN
        jsr     tun_qdraw
        jsr     tun_pface
        ; --- the far side: side line, the back arc, side line ----------------
        lda     PRN
        beq     @hatch                  ; V inside the lid: the lid hides the rest
        lda     PKB
        jsr     tun_kmul
        ldx     PS
        ldy     #0
        jsr     tun_fput                ; Q0: the front lid's vertex s
        lda     #1
        ldx     NCNT                    ; (with rocks in front, each side line is two
        beq     :+                      ;   edges, so a disc over one end does not
        inc     a                       ;   take the whole of it)
:       sta     QA
        lda     PS
        sta     QB
        jsr     tun_rtab
@bv:    jsr     tun_vang
        jsr     tun_ppk
        ldx     QA
        jsr     tun_qput
        inc     QA
        lda     QB
        cmp     PE
        beq     @bd
        inc     a
        cmp     PNV
        bcc     :+
        lda     #0
:       sta     QB
        bra     @bv
@bd:    lda     NCNT
        beq     :+
        inc     QA                      ; (the second side line's middle)
:       ldx     PE
        ldy     QA
        jsr     tun_fput                ; ...and the front lid's vertex e + 1
        iny
        sty     QN
        lda     #0
        sta     QE - 1,y                ; OPEN: no edge back to the start
        lda     NCNT
        beq     :+
        ldx     #1
        jsr     tun_qmid
        ldx     QN
        dex
        dex
        jsr     tun_qmid
:       jsr     tun_qdraw
        ; --- the hatch, turning with the roll -------------------------------
@hatch: lda     PDOT
        beq     :+
        rts                             ; far: the lid's outline is all there is
:       jsr     tun_pfront
        lda     PR1
        sta     MQA
        lda     #TUN_PODHD
        sta     MQB
        jsr     qmul
        sta     PRR
        ldx     TRK
        lda     RAN,x                   ; (its roll and the world's)
        clc
        adc     THH
        clc
        adc     #32
        sta     PT2
        stz     QA
@h:     lda     PT2
        jsr     API_COS
        sta     CU
        lda     PT2
        jsr     API_SIN
        sta     SU
        jsr     tun_ppt
        ldx     QA
        jsr     tun_qput
        lda     PT2
        clc
        adc     #64
        sta     PT2
        inc     QA
        lda     QA
        cmp     #4
        bne     @h
        sta     QN
        jsr     tun_qdraw
        lda     PRN
        bne     tun_pod_window
        rts

; -----------------------------------------------------------------------------
; tun_pod_window - the window on the wall: its middle at the roll's angle, 2 WH brad
; wide, from TUN_PODWA to TUN_PODWB behind the lid. Its two straight edges run along
; the barrel (towards V), its other two are ARCS - pieces of the rings at those two
; depths - and all of it is cut to the facing part of the wall, between the angles of
; vertices PS and PE. An edge on the cut is the side line, already drawn: left out.
; -----------------------------------------------------------------------------
tun_pod_window:
        lda     PS
        sta     QB
        jsr     tun_vang
        lda     BR48,y
        sta     PT1                     ; the facing wall's first angle...
        lda     PE
        sta     QB
        jsr     tun_vang
        lda     BR48,y
        sec
        sbc     PT1
        sta     PSPAN                   ; ...and how far it goes
        stz     PCLL
        stz     PCLR
        ldx     TRK
        lda     RAN,x                   ; (its roll and the world's)
        clc
        adc     THH
        sec
        sbc     #TUN_PODWH
        sec
        sbc     PT1                     ; the window's first angle, from PT1
        cmp     PSPAN
        bcc     @in
        beq     @in
        clc                             ; past the facing wall: does it come round
        adc     #2 * TUN_PODWH          ;   into its start?
        bcs     :+
        rts
:       sta     PHI8
        stz     PLO8
        inc     PCLL
        bra     @hi
@in:    sta     PLO8
        clc
        adc     #2 * TUN_PODWH
        bcs     @cr
        sta     PHI8
@hi:    lda     PSPAN
        cmp     PHI8
        bcs     @ok
@cr:    lda     PSPAN
        sta     PHI8
        inc     PCLR
@ok:    lda     PHI8
        sec
        sbc     PLO8
        cmp     #2
        bcs     :+
        rts                             ; (a sliver: nothing)
:       stz     PANN                    ; its arc's angles: every 8 brad, and its end
        lda     PLO8
        sta     PT2
@ag:    lda     PT2
        clc
        adc     PT1
        ldx     PANN
        sta     PANG,x
        inc     PANN
        lda     PT2
        cmp     PHI8
        beq     @agd
        clc
        adc     #8
        bcs     @last
        cmp     PHI8
        bcc     :+
@last:  lda     PHI8
:       sta     PT2
        bra     @ag
@agd:   lda     PKA                     ; the near arc, forward...
        jsr     tun_kmul
        stz     QA
@ra:    ldx     QA
        lda     PANG,x
        jsr     API_COS
        sta     CU
        ldx     QA
        lda     PANG,x
        jsr     API_SIN
        sta     SU
        jsr     tun_ppt
        ldx     QA
        jsr     tun_qput
        inc     QA
        lda     QA
        cmp     PANN
        bne     @ra
        lda     PKW                     ; ...and the far arc, back
        jsr     tun_kmul
        lda     PANN
        sta     PT3
@rb:    dec     PT3
        ldx     PT3
        lda     PANG,x
        jsr     API_COS
        sta     CU
        ldx     PT3
        lda     PANG,x
        jsr     API_SIN
        sta     SU
        jsr     tun_ppt
        ldx     QA
        jsr     tun_qput
        inc     QA
        lda     PT3
        bne     @rb
        lda     QA
        sta     QN
        ldx     PANN                    ; the edge along the barrel at the far end...
        lda     PCLR
        eor     #1
        sta     QE - 1,x
        ldx     QN                      ; ...and at the near one (the closing edge)
        lda     PCLL
        eor     #1
        sta     QE - 1,x
        jmp     tun_qdraw               ; tail

; -----------------------------------------------------------------------------
; tun_pface - which of the lid's edges face V (PF), and their run: PS, PE, PRN. The
; test is n . d1 + r1 cos(pi/N) < 0 with d1 and r1 shifted down together until d1
; is a byte each way (it is a sign: the scale does not matter).
; -----------------------------------------------------------------------------
tun_pface:
        lda     PDXL
        sta     NTXL
        lda     PDXH
        sta     NTXH
        lda     PDYL
        sta     NTYL
        lda     PDYH
        sta     NTYH
        lda     PR1
        sta     NRC
@sh:    lda     NTXH
        ora     NTYH
        bne     @dv
        lda     NTXL
        ora     NTYL
        bpl     @ok
@dv:    lsr     NTXH
        ror     NTXL
        lsr     NTYH
        ror     NTYL
        lsr     NRC
        bra     @sh
@ok:    ldx     #12                     ; |d.x| |cos j| and |d.y| |cos j|, j = 0..12
:       lda     MAG13,x
        sta     MQB
        lda     NTXL
        sta     MQA
        phx
        jsr     qmul
        plx
        sta     RT,x
        lda     NTYL
        sta     MQA
        phx
        jsr     qmul
        plx
        sta     RT + 13,x
        dex
        bpl     :-
        lda     NRC                     ; r cos(pi/N): 127 (24) or 124 (12) of 128
        sta     MQA
        lda     #127
        ldx     PSTP
        cpx     #4
        bne     :+
        lda     #124
:       sta     MQB
        jsr     qmul
        sta     NRC
        stz     QA                      ; edge QA: its normal half a step on
        lda     PSTP
        lsr     a
        sta     QB
@e:     ldy     QB
        lda     CJ48,y                  ; d.x cos: the sign is cos's xor d.x's
        eor     PDXS
        ldx     #0
        jsr     tun_rv
        sta     PT1
        ldy     QB
        lda     SJ48,y
        eor     PDYS
        ldx     #13
        jsr     tun_rv
        sta     PT2
        stz     PT3                     ; PT1 + PT2 + NRC, 16 bit: PT3 the high byte
        lda     PT1
        bpl     :+
        dec     PT3
:       lda     PT2
        bpl     :+
        dec     PT3
:       lda     PT1
        clc
        adc     PT2
        bcc     :+
        inc     PT3
:       clc
        adc     NRC
        bcc     :+
        inc     PT3
:       lda     PT3
        asl     a                       ; negative: it faces V
        lda     #0
        rol     a
        ldx     QA
        sta     PF,x
        lda     QB
        clc
        adc     PSTP
        sta     QB
        inc     QA
        lda     QA
        cmp     PNV
        bne     @e
        stz     PRN                     ; the run: an edge that faces, after one that does not
        ldx     #0
@f:     lda     PF,x
        beq     @fn
        txa
        bne     :+
        lda     PNV
:       dec     a
        tay
        lda     PF,y
        beq     @fd
@fn:    inx
        cpx     PNV
        bne     @f
        rts                             ; none
@fd:    stx     PS
@w:     lda     PF,x
        beq     @we
        inc     PRN
        inx
        cpx     PNV
        bcc     @w
        ldx     #0
        bra     @w
@we:    stx     PE
        rts

; -----------------------------------------------------------------------------
; tun_qhid - C SET when the point W (absolute full-res fb) is behind a nearer rock's
; disc (NLIST, NCNT > 0). A point too far out for a byte is not.
; -----------------------------------------------------------------------------
tun_qhid:
        lda     WXL
        sec
        sbc     #200
        pha
        lda     WXH
        sbc     #0
        cmp     #$80
        ror     a
        sta     PT1
        pla
        ror     a
        jsr     tun_fit
        bcs     @no
        eor     #$80
        sta     PXB
        lda     WYL
        sec
        sbc     #150
        pha
        lda     WYH
        sbc     #0
        cmp     #$80
        ror     a
        sta     PT1
        pla
        ror     a
        jsr     tun_fit
        bcs     @no
        eor     #$80
        sta     PYB
        jmp     tun_hid                 ; tail
@no:    clc
        rts

; -----------------------------------------------------------------------------
; tun_qdraw - the point list Q (QN points, QE its edges) on the window. Each edge
; shows unless an end or its middle is behind a nearer rock; the ones that show and
; lie inside the window's x range are collected into runs - OPEN POLYGON16s (dotted
; when far) - and the ones that cross the frame are cut to it, as LINE16s.
; -----------------------------------------------------------------------------
tun_qdraw:
        ldx     #0
@p:     stx     QA                      ; each point's OUTCODE against the window: 1 left
        stz     QO,x                    ;   of fb x 50, 2 right of 349, 4 above y 0, 8
        stz     QH,x                    ;   below 299
        lda     QXL,x
        cmp     #50
        lda     QXH,x
        sbc     #0
        bpl     :+
        lda     #1
        sta     QO,x
:       lda     #<349
        cmp     QXL,x
        lda     #>349
        sbc     QXH,x
        bpl     :+
        lda     #2
        sta     QO,x
:       lda     QYH,x
        bpl     :+
        lda     QO,x
        ora     #4
        sta     QO,x
:       lda     #<299
        cmp     QYL,x
        lda     #>299
        sbc     QYH,x
        bpl     :+
        lda     QO,x
        ora     #8
        sta     QO,x
:       lda     QO,x                    ; in the x range: an edge to here may join a run
        and     #3
        cmp     #1                      ; (C clear when 0)
        lda     #0
        rol     a
        eor     #1
        sta     QI,x
        lda     NCNT                    ; behind a rock? Only a point in the window is
        beq     @nh                     ;   asked (one outside is not drawn, and an
        lda     QO,x                    ;   edge that leaves the window is cut anyway)
        bne     @nh
        lda     QXL,x
        sta     WXL
        lda     QXH,x
        sta     WXH
        lda     QYL,x
        sta     WYL
        lda     QYH,x
        sta     WYH
        jsr     tun_qhid
        ldx     QA
        bcc     @nh
        inc     QH,x
@nh:    ldx     QA
        inx
        cpx     QN
        beq     :+
        jmp     @p
:
        lda     QN                      ; the edges
        dec     a
        sta     QS
        ldx     #0
@e:     stx     QA
        stz     QV,x
        lda     QE,x
        beq     @iv
        txa
        inc     a
        cmp     QN
        bcc     :+
        lda     #0
:       tay
        lda     QO,x                    ; both ends past the same edge of the window:
        and     QO,y                    ;   nothing of it shows
        bne     @iv
        lda     QH,x
        ora     QH,y
        bne     @iv
        lda     NCNT
        beq     @vs
        lda     QO,x                    ; (its middle is asked only if an end is in)
        and     QO,y
        bne     @vs
        lda     QXL,x                   ; its middle, against the discs
        clc
        adc     QXL,y
        sta     WXL
        lda     QXH,x
        adc     QXH,y
        cmp     #$80
        ror     a
        sta     WXH
        ror     WXL
        lda     QYL,x
        clc
        adc     QYL,y
        sta     WYL
        lda     QYH,x
        adc     QYH,y
        cmp     #$80
        ror     a
        sta     WYH
        ror     WYL
        jsr     tun_qhid
        bcs     @iv
@vs:    ldx     QA
        inc     QV,x
        bra     @en
@iv:    lda     QA
        sta     QS                      ; (the last one that does not show will do)
@en:    ldx     QA
        inx
        cpx     QN
        bne     @e
        stz     RUNN                    ; the walk, from the edge after QS, all the way round
        lda     QN
        sta     QK
        ldx     QS
@r:     inx
        cpx     QN
        bcc     :+
        ldx     #0
:       stx     QA
        txa
        inc     a
        cmp     QN
        bcc     :+
        lda     #0
:       sta     QB
        lda     QV,x
        beq     @rf
        ldy     QB
        lda     QI,x
        and     QI,y
        beq     @cut                    ; it crosses the frame
        lda     RUNN
        bne     @ad
        jsr     tun_rbeg
@ad:    ldx     QB
        jsr     tun_radd
        bcc     @rn
        jsr     tun_rflush              ; too far from the anchor: a new run from here
        ldx     QA
        jsr     tun_rbeg
        ldx     QB
        jsr     tun_radd
        bcc     @rn
        stz     RUNN                    ; an edge too long for a byte: cut it as a line
@cut:   jsr     tun_rflush
        lda     PDOT
        bne     @rn
        jsr     tun_qline
        bra     @rn
@rf:    jsr     tun_rflush
@rn:    ldx     QA
        dec     QK
        bne     @r
        ; fall through: the last run

; tun_rflush - the run collected so far, if it has an edge, to the GPU.
tun_rflush:
        lda     RUNN
        cmp     #2
        bcc     @z
        ora     #$80                    ; OPEN
        sta     PODBUF + 6
        stz     PODBUF + 4                ; no angle...
        lda     #128
        sta     PODBUF + 5                ; ...1:1
        lda     PDOT
        bne     @dot
        lda     RAXL
        sta     PODBUF + 0
        lda     RAXH
        sta     PODBUF + 1
        lda     RAYL
        sta     PODBUF + 2
        lda     RAYH
        sta     PODBUF + 3
        jsr     @arg
        jsr     API_GPU_POLYGON16
        bra     @z
@dot:   lda     RAXH                    ; far: DOTPOLYGON is half-res, centre and offsets
        cmp     #$80
        ror     a
        sta     PODBUF + 1
        lda     RAXL
        ror     a
        sta     PODBUF + 0
        lda     RAYH
        cmp     #$80
        ror     a
        sta     PODBUF + 3
        lda     RAYL
        ror     a
        sta     PODBUF + 2
        lda     RUNN
        asl     a
        tax
:       lda     PODBUF + 6,x
        cmp     #$80
        ror     a
        sta     PODBUF + 6,x
        dex
        bne     :-
        jsr     @arg
        jsr     API_GPU_DOTPOLYGON
@z:     stz     RUNN
        rts
@arg:   lda     #<PODBUF
        sta     OS_ARG + 0
        lda     #>PODBUF
        sta     OS_ARG + 1
        rts

; tun_rbeg - a run begins at point X: the anchor, offset (0, 0).
tun_rbeg:
        lda     QXL,x
        sta     RAXL
        lda     QXH,x
        sta     RAXH
        lda     QYL,x
        sta     RAYL
        lda     QYH,x
        sta     RAYH
        stz     PODBUF + 7
        stz     PODBUF + 8
        lda     #1
        sta     RUNN
        rts

; tun_radd - point X joins the run: C SET (and nothing added) if it is more than a
; byte from the anchor either way.
tun_radd:
        lda     QXL,x
        sec
        sbc     RAXL
        pha
        lda     QXH,x
        sbc     RAXH
        sta     PT1
        pla
        jsr     tun_fit
        bcs     @no
        sta     PT2
        lda     QYL,x
        sec
        sbc     RAYL
        pha
        lda     QYH,x
        sbc     RAYH
        sta     PT1
        pla
        jsr     tun_fit
        bcs     @no
        pha
        lda     RUNN
        asl     a
        tay
        lda     PT2
        sta     PODBUF + 7,y
        pla
        sta     PODBUF + 8,y
        inc     RUNN
        clc
@no:    rts

; -----------------------------------------------------------------------------
; tun_qline - the edge QA -> QB cut to the window: walked in steps of the edge halved
; until a step is within 120 each way (the last piece is what is left, once that fits
; a byte), and each piece cut by tunnel.s's own byte clipper round a local centre (the
; pod's slot's RCX/RCY and limits, free in pass 2).
; -----------------------------------------------------------------------------
tun_qline:
        ldx     QA
        ldy     QB
        lda     QXL,x
        sta     LAXL
        lda     QXH,x
        sta     LAXH
        lda     QYL,x
        sta     LAYL
        lda     QYH,x
        sta     LAYH
        lda     QXL,y
        sta     LEXL
        sec
        sbc     LAXL
        sta     LSXL
        lda     QXH,y
        sta     LEXH
        sbc     LAXH
        sta     LSXH
        lda     QYL,y
        sta     LEYL
        sec
        sbc     LAYL
        sta     LSYL
        lda     QYH,y
        sta     LEYH
        sbc     LAYH
        sta     LSYH
@h:     lda     LSXH                    ; a step within -120..120 each way?
        sta     PT1
        lda     LSXL
        jsr     @in
        bcs     @half
        lda     LSYH
        sta     PT1
        lda     LSYL
        jsr     @in
        bcc     @go
@half:  lda     LSXH
        cmp     #$80
        ror     LSXH
        ror     LSXL
        lda     LSYH
        cmp     #$80
        ror     LSYH
        ror     LSYL
        bra     @h
@go:    lda     LEXL                    ; what is left: a byte each way? Then it is the
        sec                             ;   last piece, to the line's own end
        sbc     LAXL
        pha
        lda     LEXH
        sbc     LAXH
        sta     PT1
        pla
        jsr     tun_fit
        bcs     @mid
        lda     LEYL
        sec
        sbc     LAYL
        pha
        lda     LEYH
        sbc     LAYH
        sta     PT1
        pla
        jsr     tun_fit
        bcs     @mid
        lda     LEXL
        sta     LBXL
        lda     LEXH
        sta     LBXH
        lda     LEYL
        sta     LBYL
        lda     LEYH
        sta     LBYH
        jmp     tun_qpiece              ; (tail)
@mid:   lda     LAXL
        clc
        adc     LSXL
        sta     LBXL
        lda     LAXH
        adc     LSXH
        sta     LBXH
        lda     LAYL
        clc
        adc     LSYL
        sta     LBYL
        lda     LAYH
        adc     LSYH
        sta     LBYH
        jsr     tun_qpiece
        lda     LBXL
        sta     LAXL
        lda     LBXH
        sta     LAXH
        lda     LBYL
        sta     LAYL
        lda     LBYH
        sta     LAYH
        jmp     @go
@in:    jsr     tun_fit                 ; C SET unless PT1:A is in -120..120
        bcs     @r
        ora     #0                      ; (tun_abs reads N: tun_fit's flags are a compare's)
        jsr     tun_abs
        cmp     #121
@r:     rts

; tun_qpiece - the piece LA -> LB: nothing if both ends are past the same edge, else
; round LA as the slot's centre, cut to the window's x limits and the screen's y ones.
tun_qpiece:
        lda     LAXL                    ; both left of fb x 50?
        cmp     #50
        lda     LAXH
        sbc     #0
        bpl     :+
        lda     LBXL
        cmp     #50
        lda     LBXH
        sbc     #0
        bpl     :+
        rts
:       lda     #<349                   ; both right of 349?
        cmp     LAXL
        lda     #>349
        sbc     LAXH
        bpl     :+
        lda     #<349
        cmp     LBXL
        lda     #>349
        sbc     LBXH
        bpl     :+
        rts
:       lda     LAYH                    ; both above 0?
        and     LBYH
        bpl     :+
        rts
:       lda     #<299                   ; both below 299?
        cmp     LAYL
        lda     #>299
        sbc     LAYH
        bpl     :+
        lda     #<299
        cmp     LBYL
        lda     #>299
        sbc     LBYH
        bpl     :+
        rts
:       ldx     TRK
        lda     LAXL
        sta     RCXL,x
        lda     LAXH
        sta     RCXH,x
        lda     LAYL
        sta     RCYL,x
        lda     LAYH
        sta     RCYH,x
        lda     #50                     ; the limits round it, held to a byte
        sec
        sbc     LAXL
        pha
        lda     #0
        sbc     LAXH
        sta     PT1
        pla
        jsr     tun_clamp
        ldx     TRK
        sta     RBL,x
        sta     BLL
        lda     #<349
        sec
        sbc     LAXL
        pha
        lda     #>349
        sbc     LAXH
        sta     PT1
        pla
        jsr     tun_clamp
        ldx     TRK
        sta     RBH,x
        sta     BHH
        lda     #0
        sec
        sbc     LAYL
        pha
        lda     #0
        sbc     LAYH
        sta     PT1
        pla
        jsr     tun_clamp
        ldx     TRK
        sta     RBT,x
        lda     #<299
        sec
        sbc     LAYL
        pha
        lda     #>299
        sbc     LAYH
        sta     PT1
        pla
        jsr     tun_clamp
        ldx     TRK
        sta     RBB,x
        stz     EX0
        stz     EY0
        lda     LBXL
        sec
        sbc     LAXL
        sta     EX1
        lda     LBYL
        sec
        sbc     LAYL
        sta     EY1
        jsr     tun_xclip
        bcs     @r
        jsr     tun_yclip
        bcs     @r
        jmp     tun_line                ; tail
@r:     rts
