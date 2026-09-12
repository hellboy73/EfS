; =============================================================================
; enemies.s - composite enemy shapes, authored with tools/enemy_editor.py.
;
; A rock is one closed outline. An enemy is a small ordered list of PARTS
; sharing one anchor, and every part is a POLYGON16 call - there is no second
; primitive here, on purpose:
;
;   CX,CY,ANGLE,SCALE,N,dx0,dy0,...,dxK-1,dyK-1   (API_GPU_POLYGON16, $4E)
;
; `N`'s bit 7 is the polygon family's OPEN flag (MAD-65, 2026-09-06): bit 7 =
; 0, the default, CLOSES the outline (K vertices, K segments) - a hull, a
; turret dome, anything that reads as solid. Bit 7 = 1 leaves it OPEN (K
; vertices, K-1 segments) - a gun barrel, an antenna, anything that should
; not join back to itself. Both go through the SAME rotate+scale matrix on
; the GPU, at full res, anchored at the object's centre - which is the whole
; point: a barrel that has to swing with the hull does not cost CPU1 a single
; extra multiply to get there.
;
; That also settles what CIRCLE16 ($4F) and LINE16 ($43) are NOT used for
; here, even though both exist in MAD-65. CIRCLE16 has no SCALE - the team
; found nothing to fold a scale multiply into once rotation was gone off a
; circle - and LINE16 has neither ANGLE nor SCALE at all. This game's camera
; is always zooming, so anything without a free GPU-side SCALE would need its
; own hand-rolled rescale on CPU1 every frame: exactly the per-frame multiply
; this engine avoids (see "do not use mul16 in hot paths", CLAUDE.md). A
; "circle" part is therefore just a CLOSED polygon whose vertices the editor
; placed on a regular N-gon - enemies are ship-sized, not rock-sized, so 8-10
; sides already reads as round, the same reasoning that keeps a 12-vertex
; rock looking like a rock and not a machined part.
;
; UNITS: unlike shapes.s, nothing here is half-res-then-doubled - every part
; is authored directly in the signed-byte OFFSETS POLYGON16 wants, from the
; shared anchor (the same +/-127 ceiling as a rock's vertices; qmul is not
; involved, but the offset is still a signed byte on the wire, and `K` itself
; is 7 bits, 0-127, with bit 7 reserved for OPEN).
;
; AXES: FRAMEBUFFER axes, pre-rotated for TATE like SHIP_SHAPE - a negative dx
; is UP on the player's screen, a positive dy is LEFT. The editor turns them
; back on the way in, so it shows what the player sees; the numbers below are
; what the GPU is handed. An enemy drawn at ANGLE 0 (the UFO always is - it
; never turns, foes.s) therefore looks exactly as it does in the editor.
;
; PARTS ARE ALSO WHAT COMES APART. When an enemy is destroyed each part flies
; off as one piece (foes.s fw_spawn), so the split into parts is an art
; decision about the wreck as much as about the outline: the UFO is a closed
; hull and an open dome, and the dome is what pops off. EN_*_PW is how many of
; the LEADING parts do that - a count and not a flag per part, because
; fw_spawn only has to stop early. It exists because ANIMATION added parts
; that are pure decoration (a stripe scrolling across a hull), and a
; two-vertex line tumbling away from a wreck reads as a bug.
;
; FRAMES, AND WHY THEY ARE FREE. An enemy is animated like a sprite: a handful
; of authored FRAMES, switched, not tweened. The PART LIST is structural and
; the same in every frame - part 0 is the hull in all of them, and closed/open
; and the wreck flag belong to the part, not to the frame - so what a frame
; varies is only each part's VERTICES. The tables are FRAME-MAJOR: PLO/PHI
; hold FN*PN pointers, frame 0's parts first, and a frame is a row of PN of
; them. Drawing therefore costs one ADD over what it cost with no animation at
; all (the row offset, plus the part index), and never a multiply.
;
; Identical outlines are emitted ONCE and pointed at from every frame that
; uses them - the editor dedupes them - so a hull that does not move costs two
; pointer bytes a frame and not a second copy of itself.
;
; A PART CAN BE ABSENT FROM A FRAME - the UFO's extra line in the last frame
; only. The grid stays rectangular: the frames without it hold the part with
; ONE vertex, and an OPEN part's K vertices are K-1 segments, so one vertex is
; no segment and the GPU draws nothing (MAD-65 gpu_os.s op_polygon16: N-1 = 0
; goes straight to the closing edge, and OPEN skips it). Three data bytes,
; shared by every absent frame, and a command the GPU leaves after one vertex.
; A CLOSED part cannot do this - its v0 -> v0 closing edge is still drawn, as
; one lit pixel.
;
; K = 0 would be cheaper still - op_polygon16 returns before it transforms
; anything - but it MUST NOT be authored: foe_body's offset copy is a do-while
; on 2K (`asl / tax / ... dex / bne`) and fw_centre's vertex walk is a do-while
; on K, so both read zero as 256. Two `beq`s would fix that; until they are
; there, one vertex is the floor.
;
; THE PLAYLIST is separate from the frames, and that is the point. EN_*_ANIM
; is a list of frames - "0,1,2,1" plays three drawn frames as a four-step
; ping-pong - held as ROW OFFSETS so the runtime adds the part index straight
; to one of them. EN_*_AN is how many steps it has and EN_*_AHOLD how many
; game frames one step lasts, and BOTH ARE ANY NUMBER: each enemy counts its
; own step down (foes.s FOEACD/FOEAST), so nothing is divided and nothing is
; masked. A 6-frame hold and a 3-step playlist are as cheap as a power of two.
;
; It was a shift and a mask once (EN_*_ASH, EN_*_AMSK), read off the global
; frame counter. That bought a handful of cycles and cost the two things that
; turned out to matter: any hold that was not a power of two, and a
; STATE-DRIVEN enemy - one that has to restart its own loop when it changes
; what it is doing, which a shared clock cannot do.
;
; Repeats in the playlist are free, two pointer bytes each, so holding one
; frame longer than its neighbours is authored by writing it twice - which is
; what SPIDER's [0,0,0,0,0,1,2,1] is: sit still, then rock.
;
; THE COLLISION CIRCLE, EN_*_R, is here and not in foes.s because it is a
; property of the SHAPE - the editor draws it over the outline, which is the
; only place the two can honestly be compared. It is in COLLISION UNITS (32
; world units = one half-res px, foes.s), so over a shape authored in full-res
; px its radius is 2R. The editor's "from shape" button fills in the
; mean-vertex estimate the rocks and the ship use; FOE_R is deliberately 1.25x
; that, because the honest mean read too small to hit.
;
; It is NOT yet what the game reads. foes.s still has one FOE_R, because it
; still has one KIND - the assert at the bottom of this file is what stops the
; two drifting apart until the shape tables go per-KIND and FOE_R becomes a
; lookup like the pointers are.
;
; What is deliberately NOT here: how an enemy moves or fights. That is foes.s,
; and which kind number is which shape is FK_* there.
;
; Hand edits are fine anywhere in this file. Everything between the GENERATED
; markers is what tools/enemy_editor.py reads, and rewrites whole - not
; patched - on every Save.
; =============================================================================

; WHERE THIS FILE SITS IN THE BUILD. It is included EARLY - before the code -
; and pushes its own segment, so the tables still land in RODATA while the
; scalars above are defined before foes.s reads them. They have to be:
; EN_*_ASH is a `.repeat` count and EN_*_AMSK an immediate operand in
; foe_anim, and ca65 needs both as constants at the point of use. Only the
; LABELS (ANIM, PLO/PHI, the blobs) can be forward references, and those the
; linker resolves wherever the file sits.

        .pushseg
        .segment "RODATA"

; === GENERATED (tools/enemy_editor.py) - rewritten whole on Save ============
; ---- UFO ----
EN_UFO_PN     = 5      ; parts, the same in every frame
EN_UFO_PW     = 2      ; ...of which the LEADING ones become wreck pieces
EN_UFO_FN     = 4      ; authored frames
EN_UFO_AN     = 4      ; playlist steps - any number
EN_UFO_AHOLD  = 4      ; game frames one step lasts
EN_UFO_R      = 9      ; collision circle, collision units: radius 18 full-res px
EN_UFO_RBASE  = 0      ; its first row in EN_PLO/EN_PHI...
EN_UFO_ABASE  = 0      ; ...and its first step in EN_ANIM
; f0p0, f1p0, f2p0, f3p0
EN_UFO_S0:     .byte     6,   <-5,    10,   <-5,   <-10,     0,   <-20,     7
               .byte   <-10,     7,    10,     0,    20
; f0p1, f1p1, f2p1, f3p1
EN_UFO_S1:     .byte   132,   <-5,    10,   <-15,     5,   <-15,   <-5,   <-5
               .byte   <-10
; f0p2
EN_UFO_S2:     .byte   130,     0,    19,     0,    12
; f0p3
EN_UFO_S3:     .byte   130,     0,     0,     0,   <-12
; f0p4, f1p4, f2p4
EN_UFO_S4:     .byte   129,     0,    20
; f1p2
EN_UFO_S5:     .byte   130,     0,    16,     0,     6
; f1p3
EN_UFO_S6:     .byte   130,     0,   <-6,     0,   <-16
; f2p2
EN_UFO_S7:     .byte   130,     0,    12,     0,     0
; f2p3
EN_UFO_S8:     .byte   130,     0,   <-12,     0,   <-19
; f3p2
EN_UFO_S9:     .byte   130,     0,     6,     0,   <-6
; f3p3
EN_UFO_S10:    .byte   130,     0,   <-16,     0,   <-20
; f3p4
EN_UFO_S11:    .byte   130,     0,    20,     0,    16

; ---- WORM ----
EN_WORM_PN     = 1      ; parts, the same in every frame
EN_WORM_PW     = 1      ; ...of which the LEADING ones become wreck pieces
EN_WORM_FN     = 1      ; authored frames
EN_WORM_AN     = 1      ; playlist steps - any number
EN_WORM_AHOLD  = 8      ; game frames one step lasts
EN_WORM_R      = 7      ; collision circle, collision units: radius 14 full-res px
EN_WORM_RBASE  = 20      ; its first row in EN_PLO/EN_PHI...
EN_WORM_ABASE  = 4      ; ...and its first step in EN_ANIM
; f0p0
EN_WORM_S0:    .byte    12,     0,   <-15,    14,   <-9,     7,   <-5,    16
               .byte     0,     7,     5,    14,     9,     0,    15,   <-14
               .byte     9,   <-7,     5,   <-16,     0,   <-7,   <-5,   <-14
               .byte   <-9

; ---- SPIDER ----
EN_SPIDER_PN     = 5      ; parts, the same in every frame
EN_SPIDER_PW     = 5      ; ...of which the LEADING ones become wreck pieces
EN_SPIDER_FN     = 3      ; authored frames
EN_SPIDER_AN     = 5      ; playlist steps - any number
EN_SPIDER_AHOLD  = 6      ; game frames one step lasts
EN_SPIDER_R      = 8      ; collision circle, collision units: radius 16 full-res px
EN_SPIDER_RBASE  = 21      ; its first row in EN_PLO/EN_PHI...
EN_SPIDER_ABASE  = 5      ; ...and its first step in EN_ANIM
; f0p0
EN_SPIDER_S0:  .byte    12,    20,   <-8,    18,   <-2,    14,     2,     8
               .byte     4,     2,     2,   <-2,   <-2,   <-4,   <-8,   <-2
               .byte   <-14,     2,   <-18,     8,   <-20,    14,   <-18,    18
               .byte   <-14
; f0p1
EN_SPIDER_S1:  .byte   131,     2,   <-18,   <-4,   <-24,     2,   <-30
; f0p2
EN_SPIDER_S2:  .byte   131,    14,   <-18,    19,   <-26,    27,   <-26
; f0p3
EN_SPIDER_S3:  .byte   131,     2,     2,   <-4,     8,     3,    14
; f0p4
EN_SPIDER_S4:  .byte   131,    14,     2,    19,    10,    27,    10
; f1p0
EN_SPIDER_S5:  .byte    12,    23,   <-8,    21,   <-2,    17,     2,    11
               .byte     4,     5,     2,     1,   <-2,   <-1,   <-8,     1
               .byte   <-14,     5,   <-18,    11,   <-20,    17,   <-18,    21
               .byte   <-14
; f1p1
EN_SPIDER_S6:  .byte   131,     5,   <-18,   <-2,   <-23,     2,   <-30
; f1p2
EN_SPIDER_S7:  .byte   131,    17,   <-18,    19,   <-27,    27,   <-26
; f1p3
EN_SPIDER_S8:  .byte   131,     5,     2,   <-1,     7,     3,    14
; f1p4
EN_SPIDER_S9:  .byte   131,    17,     2,    19,    11,    27,    10
; f2p0
EN_SPIDER_S10: .byte    12,    26,   <-8,    24,   <-2,    20,     2,    14
               .byte     4,     8,     2,     4,   <-2,     2,   <-8,     4
               .byte   <-14,     8,   <-18,    14,   <-20,    20,   <-18,    24
               .byte   <-14
; f2p1
EN_SPIDER_S11: .byte   131,     8,   <-18,     0,   <-22,     2,   <-30
; f2p2
EN_SPIDER_S12: .byte   131,    20,   <-18,    19,   <-27,    27,   <-26
; f2p3
EN_SPIDER_S13: .byte   131,     8,     2,     0,     6,     3,    14
; f2p4
EN_SPIDER_S14: .byte   131,    20,     2,    19,    11,    27,    10

; ---- SPIDER_FLOAT ----
EN_SPIDER_FLOAT_PN     = 5      ; parts, the same in every frame
EN_SPIDER_FLOAT_PW     = 5      ; ...of which the LEADING ones become wreck pieces
EN_SPIDER_FLOAT_FN     = 4      ; authored frames
EN_SPIDER_FLOAT_AN     = 4      ; playlist steps - any number
EN_SPIDER_FLOAT_AHOLD  = 8      ; game frames one step lasts
EN_SPIDER_FLOAT_R      = 8      ; collision circle, collision units: radius 16 full-res px
EN_SPIDER_FLOAT_RBASE  = 36      ; its first row in EN_PLO/EN_PHI...
EN_SPIDER_FLOAT_ABASE  = 10      ; ...and its first step in EN_ANIM
; f0p0, f1p0, f2p0, f3p0
EN_SPIDER_FLOAT_S0: .byte    12,    12,     0,    10,     6,     6,    10,     0
               .byte    12,   <-6,    10,   <-10,     6,   <-12,     0,   <-10
               .byte   <-6,   <-6,   <-10,     0,   <-12,     6,   <-10,    10
               .byte   <-6
; f0p1
EN_SPIDER_FLOAT_S1: .byte   131,   <-6,   <-10,   <-12,   <-16,   <-5,   <-22
; f0p2
EN_SPIDER_FLOAT_S2: .byte   131,     6,   <-10,    11,   <-18,    19,   <-18
; f0p3
EN_SPIDER_FLOAT_S3: .byte   131,   <-6,    10,   <-14,    12,   <-7,    17
; f0p4
EN_SPIDER_FLOAT_S4: .byte   131,     6,    10,     9,    19,    16,    14
; f1p1
EN_SPIDER_FLOAT_S5: .byte   131,   <-6,   <-10,   <-14,   <-12,   <-7,   <-17
; f1p2
EN_SPIDER_FLOAT_S6: .byte   131,     6,   <-10,    13,   <-16,    17,   <-8
; f1p3
EN_SPIDER_FLOAT_S7: .byte   131,   <-6,    10,   <-14,    12,   <-21,    18
; f1p4
EN_SPIDER_FLOAT_S8: .byte   131,     6,    10,     6,    20,    12,    13
; f2p1
EN_SPIDER_FLOAT_S9: .byte   131,   <-6,   <-10,   <-14,   <-12,   <-21,   <-18
; f2p2
EN_SPIDER_FLOAT_S10: .byte   131,     6,   <-10,     6,   <-20,    12,   <-13
; f2p3
EN_SPIDER_FLOAT_S11: .byte   131,   <-6,    10,   <-12,    16,   <-11,    25
; f2p4
EN_SPIDER_FLOAT_S12: .byte   131,     6,    10,    13,    16,    17,     8
; f3p1
EN_SPIDER_FLOAT_S13: .byte   131,   <-6,   <-10,   <-12,   <-16,   <-11,   <-25
; f3p2
EN_SPIDER_FLOAT_S14: .byte   131,     6,   <-10,     9,   <-19,    16,   <-14
; f3p3
EN_SPIDER_FLOAT_S15: .byte   131,   <-6,    10,   <-12,    16,   <-5,    22
; f3p4
EN_SPIDER_FLOAT_S16: .byte   131,     6,    10,    11,    18,    19,    18

; ---- the appearance table ----
; Which shape a foe wears is one byte, EA_*, and every table below is
; indexed by it. A behaviour KIND picks an appearance; two appearances
; can belong to one kind.
EA_UFO            = 0
EA_WORM           = 1
EA_SPIDER         = 2
EA_SPIDER_FLOAT   = 3
EN_APPN = 4      ; how many appearances there are
; parts per frame
EN_PN:         .byte EN_UFO_PN, EN_WORM_PN, EN_SPIDER_PN, EN_SPIDER_FLOAT_PN
; ...of which become wreck pieces
EN_PW:         .byte EN_UFO_PW, EN_WORM_PW, EN_SPIDER_PW, EN_SPIDER_FLOAT_PW
; playlist steps
EN_AN:         .byte EN_UFO_AN, EN_WORM_AN, EN_SPIDER_AN, EN_SPIDER_FLOAT_AN
; game frames a step lasts
EN_AHOLD:      .byte EN_UFO_AHOLD, EN_WORM_AHOLD, EN_SPIDER_AHOLD, EN_SPIDER_FLOAT_AHOLD
; collision circle, collision units
EN_R:          .byte EN_UFO_R, EN_WORM_R, EN_SPIDER_R, EN_SPIDER_FLOAT_R
; first row in EN_PLO/EN_PHI
EN_RBASE:      .byte EN_UFO_RBASE, EN_WORM_RBASE, EN_SPIDER_RBASE, EN_SPIDER_FLOAT_RBASE
; first step in EN_ANIM
EN_ABASE:      .byte EN_UFO_ABASE, EN_WORM_ABASE, EN_SPIDER_ABASE, EN_SPIDER_FLOAT_ABASE
; every playlist, end to end: step -> the frame's ROW within its own
;   appearance, already multiplied by the part count
EN_ANIM:       .byte 0*EN_UFO_PN, 1*EN_UFO_PN, 2*EN_UFO_PN, 3*EN_UFO_PN, 0*EN_WORM_PN
               .byte 0*EN_SPIDER_PN, 0*EN_SPIDER_PN, 1*EN_SPIDER_PN, 2*EN_SPIDER_PN, 1*EN_SPIDER_PN
               .byte 0*EN_SPIDER_FLOAT_PN, 1*EN_SPIDER_FLOAT_PN, 2*EN_SPIDER_FLOAT_PN, 3*EN_SPIDER_FLOAT_PN
; every row, end to end, frame-major within each appearance
EN_PLO:        .byte <EN_UFO_S0, <EN_UFO_S1, <EN_UFO_S2, <EN_UFO_S3, <EN_UFO_S4, <EN_UFO_S0
               .byte <EN_UFO_S1, <EN_UFO_S5, <EN_UFO_S6, <EN_UFO_S4, <EN_UFO_S0, <EN_UFO_S1
               .byte <EN_UFO_S7, <EN_UFO_S8, <EN_UFO_S4, <EN_UFO_S0, <EN_UFO_S1, <EN_UFO_S9
               .byte <EN_UFO_S10, <EN_UFO_S11, <EN_WORM_S0, <EN_SPIDER_S0, <EN_SPIDER_S1, <EN_SPIDER_S2
               .byte <EN_SPIDER_S3, <EN_SPIDER_S4, <EN_SPIDER_S5, <EN_SPIDER_S6, <EN_SPIDER_S7, <EN_SPIDER_S8
               .byte <EN_SPIDER_S9, <EN_SPIDER_S10, <EN_SPIDER_S11, <EN_SPIDER_S12, <EN_SPIDER_S13, <EN_SPIDER_S14
               .byte <EN_SPIDER_FLOAT_S0, <EN_SPIDER_FLOAT_S1, <EN_SPIDER_FLOAT_S2, <EN_SPIDER_FLOAT_S3, <EN_SPIDER_FLOAT_S4, <EN_SPIDER_FLOAT_S0
               .byte <EN_SPIDER_FLOAT_S5, <EN_SPIDER_FLOAT_S6, <EN_SPIDER_FLOAT_S7, <EN_SPIDER_FLOAT_S8, <EN_SPIDER_FLOAT_S0, <EN_SPIDER_FLOAT_S9
               .byte <EN_SPIDER_FLOAT_S10, <EN_SPIDER_FLOAT_S11, <EN_SPIDER_FLOAT_S12, <EN_SPIDER_FLOAT_S0, <EN_SPIDER_FLOAT_S13, <EN_SPIDER_FLOAT_S14
               .byte <EN_SPIDER_FLOAT_S15, <EN_SPIDER_FLOAT_S16
EN_PHI:        .byte >EN_UFO_S0, >EN_UFO_S1, >EN_UFO_S2, >EN_UFO_S3, >EN_UFO_S4, >EN_UFO_S0
               .byte >EN_UFO_S1, >EN_UFO_S5, >EN_UFO_S6, >EN_UFO_S4, >EN_UFO_S0, >EN_UFO_S1
               .byte >EN_UFO_S7, >EN_UFO_S8, >EN_UFO_S4, >EN_UFO_S0, >EN_UFO_S1, >EN_UFO_S9
               .byte >EN_UFO_S10, >EN_UFO_S11, >EN_WORM_S0, >EN_SPIDER_S0, >EN_SPIDER_S1, >EN_SPIDER_S2
               .byte >EN_SPIDER_S3, >EN_SPIDER_S4, >EN_SPIDER_S5, >EN_SPIDER_S6, >EN_SPIDER_S7, >EN_SPIDER_S8
               .byte >EN_SPIDER_S9, >EN_SPIDER_S10, >EN_SPIDER_S11, >EN_SPIDER_S12, >EN_SPIDER_S13, >EN_SPIDER_S14
               .byte >EN_SPIDER_FLOAT_S0, >EN_SPIDER_FLOAT_S1, >EN_SPIDER_FLOAT_S2, >EN_SPIDER_FLOAT_S3, >EN_SPIDER_FLOAT_S4, >EN_SPIDER_FLOAT_S0
               .byte >EN_SPIDER_FLOAT_S5, >EN_SPIDER_FLOAT_S6, >EN_SPIDER_FLOAT_S7, >EN_SPIDER_FLOAT_S8, >EN_SPIDER_FLOAT_S0, >EN_SPIDER_FLOAT_S9
               .byte >EN_SPIDER_FLOAT_S10, >EN_SPIDER_FLOAT_S11, >EN_SPIDER_FLOAT_S12, >EN_SPIDER_FLOAT_S0, >EN_SPIDER_FLOAT_S13, >EN_SPIDER_FLOAT_S14
               .byte >EN_SPIDER_FLOAT_S15, >EN_SPIDER_FLOAT_S16
; === END GENERATED ===

        .popseg
