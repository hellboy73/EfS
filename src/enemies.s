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
; hull and an open dome, and the dome is what pops off.
;
; What is deliberately NOT here: how an enemy moves or fights. That is foes.s,
; and which kind number is which shape is FK_* there.
;
; Hand edits are fine anywhere in this file. Everything between the GENERATED
; markers is what tools/enemy_editor.py reads, and rewrites whole - not
; patched - on every Save.
; =============================================================================

; === GENERATED (tools/enemy_editor.py) - rewritten whole on Save ============
; ---- UFO ----
EN_UFO_PN     = 2
EN_UFO_PLO:    .byte <EN_UFO_P0, <EN_UFO_P1
EN_UFO_PHI:    .byte >EN_UFO_P0, >EN_UFO_P1
EN_UFO_P0:     .byte     6,   <-5,    10,   <-5,   <-10,     0,   <-20,     7
               .byte   <-10,     7,    10,     0,    20
EN_UFO_P1:     .byte   132,   <-5,    10,   <-15,     5,   <-15,   <-5,   <-5
               .byte   <-10

; ---- WORM ----
EN_WORM_PN     = 1
EN_WORM_PLO:   .byte <EN_WORM_P0
EN_WORM_PHI:   .byte >EN_WORM_P0
EN_WORM_P0:    .byte    12,     0,   <-15,    14,   <-9,     7,   <-5,    16
               .byte     0,     7,     5,    14,     9,     0,    15,   <-14
               .byte     9,   <-7,     5,   <-16,     0,   <-7,   <-5,   <-14
               .byte   <-9
; === END GENERATED ===
