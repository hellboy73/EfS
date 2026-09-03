; =============================================================================
; shapes.s - every vertex table in the game: the asteroid outlines and the
; ship's triangle. Split out of main.s so the shape editor
; (tools/shape_editor.py) has one file to read and write, and so a shape can be
; looked at and changed without wading through the flight code around it.
; =============================================================================
; ASTEROIDS
;
; FIVE SIZE CLASSES (192, 128, 64, 32, 16 full-res px across) and, within each,
; AST_TYPES hand-authored VARIANTS - so a field of same-size rocks does not
; read as stamped from one mould. init_objects (main.s) picks a size class
; through SHAPE_PICK and a variant through TYPE_PICK, independently; one_asteroid
; combines them into one SHAPE ID, class * AST_TYPES + type, and that ID is
; what every table below is indexed by, size-major (all of class 192's variants,
; then all of 128's, ...).
;
; Vertices are SIGNED BYTES in HALF-RES pixels, origin-centred, wound in order
; and closed by the drawing code - so the 192 rock's radius is 48 here, not 96.
; The only hard rule is |x|, |y| <= 127: qmul indexes its table with |mx|+|cos|
; and that has to stay inside a byte. At 48 there is room to spare.
;
; Shapes are near-circular but irregular - a regular polygon reads as a
; machined part, and the eye picks the repetition out immediately even while it
; tumbles. Vertex counts fall with size (12, 10, 8, 6, 5): a rock 16 px across
; cannot show more corners than that anyway, and five is the floor - four reads
; as a diamond, a shape rather than a rock.
;
; Each variant ALSO carries an authored REDUCED outline - its own vertex list,
; not a derived one - used once a rock is small enough on screen to hit the LOD
; path (main.s LOD_R). Striding through the full outline (take every second
; vertex) used to do this job and it is why LOD only ever touched the two
; biggest classes: every second vertex of an octagon is a quadrilateral, and it
; does not read as a rock. An authored reduced shape does not have that limit;
; SHAPE_LODN is 0 where none has been authored yet - the shape just stays at
; full detail always.
;
; SHIP: SHIP_SHAPE, an authored outline like a rock's - up to 13 signed byte
; (dx,dy) pairs, FULL-res pixels from the ship's own centre, wound in order -
; scaled every frame by emit_ship (main.s) and drawn as closed LINE16 segments.
; dx is the fb_x axis (a NEGATIVE dx is toward the nose: "up" on the player's
; screen is decreasing fb_x, per the TATE note in main.s emit_ship), dy is
; fb_y. It never rotates, so nothing here ever multiplies two vertices
; together the way a rock's rotation does - the +/-127 ceiling is still worth
; keeping in mind (qmul's |x|+|y| rule) but nothing enforces it for the ship
; specifically. SHIP_VN is how many of the 13 slots are used.
;
; Hand edits are fine anywhere in this file. Everything between the GENERATED
; markers below is also what tools/shape_editor.py reads, and what it rewrites
; -- whole, not patched -- on every Save; the editor is the easy way to move a
; vertex or add a variant, but the numbers are just numbers, so editing them by
; hand and running `make` works exactly as it always did.
; =============================================================================

; === GENERATED (tools/shape_editor.py) - rewritten whole on Save ============
AST_TYPES  = 3                  ; authored variants per size class. TYPE_PICK
                                 ;   in main.s must have exactly this many values
CLASS_BASE: .byte 0*AST_TYPES, 1*AST_TYPES, 2*AST_TYPES, 3*AST_TYPES, 4*AST_TYPES
                                 ; class -> the first shape id in that class,
                                 ;   so one_asteroid never has to multiply

; per-shape-id tables, 5 classes x AST_TYPES, size-major
SHAPE_N:    .byte   12, 12, 13, 10, 10, 11, 9, 9, 9, 8, 7, 7, 5, 5, 5
SHAPE_R:    .byte   48, 48, 48, 32, 32, 32, 16, 16, 16, 8, 8, 8, 4, 4, 4
SHAPE_OCC:  .byte   39, 39, 39, 26, 26, 26, 13, 13, 13, 7, 7, 7, 3, 3, 3

SHAPE_LO:    .byte    <SHP192_A, <SHP192_B, <SHP192_C
             .byte    <SHP128_A, <SHP128_B, <SHP128_C
             .byte    <SHP64_A, <SHP64_B, <SHP64_C
             .byte    <SHP32_A, <SHP32_B, <SHP32_C
             .byte    <SHP16_A, <SHP16_B, <SHP16_C
SHAPE_HI:    .byte    >SHP192_A, >SHP192_B, >SHP192_C
             .byte    >SHP128_A, >SHP128_B, >SHP128_C
             .byte    >SHP64_A, >SHP64_B, >SHP64_C
             .byte    >SHP32_A, >SHP32_B, >SHP32_C
             .byte    >SHP16_A, >SHP16_B, >SHP16_C

SHAPE_LODN: .byte   6, 7, 8, 6, 7, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0
SHAPE_LODLO: .byte    <SHP192_A_LOD, <SHP192_B_LOD, <SHP192_C_LOD
             .byte    <SHP128_A_LOD, <SHP128_B_LOD, <SHP128_C_LOD
             .byte    0, 0, 0
             .byte    0, 0, 0
             .byte    0, 0, 0
SHAPE_LODHI: .byte    >SHP192_A_LOD, >SHP192_B_LOD, >SHP192_C_LOD
             .byte    >SHP128_A_LOD, >SHP128_B_LOD, >SHP128_C_LOD
             .byte    0, 0, 0
             .byte    0, 0, 0
             .byte    0, 0, 0

; 192 x 192 full-res -> radius 48 half-res
SHP192_A:     .byte    44,     2,    35,    20,    25,    41,     2,    34
              .byte   <-16,    32,   <-30,    20,   <-37,     4,   <-37,   <-18
              .byte   <-19,   <-27,   <-4,   <-40,    21,   <-38,    35,   <-16
SHP192_B:     .byte    45,    10,    24,    22,    19,    42,   <-7,    35
              .byte   <-22,    25,   <-33,    13,   <-41,   <-4,   <-29,   <-26
              .byte   <-17,   <-39,     6,   <-43,    30,   <-32,    34,   <-9
SHP192_C:     .byte    38,    16,    24,    30,     6,    35,   <-11,    31
              .byte   <-29,    23,   <-35,     6,   <-42,   <-14,   <-21,   <-28
              .byte   <-10,   <-22,   <-10,   <-44,    17,   <-42,    34,   <-26
              .byte    37,   <-9

; 128 x 128 full-res -> radius 32 half-res
SHP128_A:     .byte    29,   <-4,    19,    17,     6,    24,   <-13,    27
              .byte   <-27,    16,   <-27,     3,   <-23,   <-19,   <-8,   <-21
              .byte     8,   <-21,    18,   <-11
SHP128_B:     .byte    28,     5,    20,    20,     2,    23,   <-14,    28
              .byte   <-26,    11,   <-22,   <-5,   <-16,   <-17,   <-2,   <-23
              .byte    16,   <-24,    19,   <-8
SHP128_C:     .byte    22,     9,    13,    20,   <-6,    24,     1,     4
              .byte   <-12,    21,   <-27,     8,   <-26,   <-10,   <-14,   <-21
              .byte     2,   <-31,    20,   <-21,    26,   <-6

; 64 x 64 full-res -> radius 16 half-res
SHP64_A:      .byte    13,     0,    11,     8,     0,    13,   <-6,    12
              .byte   <-13,     8,   <-12,   <-2,   <-11,   <-7,   <-2,   <-14
              .byte     7,   <-9
SHP64_B:      .byte    13,     3,     5,    10,   <-4,    15,   <-8,    11
              .byte   <-8,     4,   <-15,   <-5,   <-5,   <-11,     3,   <-10
              .byte    12,   <-6
SHP64_C:      .byte    13,     7,     2,    13,   <-7,    10,   <-11,     2
              .byte   <-12,   <-5,   <-6,   <-8,   <-3,   <-13,     8,   <-12
              .byte    12,   <-2

; 32 x 32 full-res -> radius 8 half-res
SHP32_A:      .byte     6,   <-1,     2,     6,     0,     3,   <-3,     7
              .byte   <-6,     2,   <-6,   <-3,   <-3,   <-7,     2,   <-5
SHP32_B:      .byte     5,     5,     0,     7,   <-5,     3,   <-6,   <-1
              .byte   <-1,   <-6,     5,   <-5,     7,     0
SHP32_C:      .byte     5,     4,   <-1,     5,   <-6,     3,   <-7,     0
              .byte   <-6,   <-4,     1,   <-6,     5,   <-3

; 16 x 16 full-res -> radius 4 half-res
SHP16_A:      .byte     4,     0,     2,     3,   <-2,     2,   <-3,   <-1
              .byte     1,   <-3
SHP16_B:      .byte     3,     1,     0,     3,   <-4,     0,   <-2,   <-3
              .byte     3,   <-2
SHP16_C:      .byte     3,     2,   <-2,     3,   <-3,   <-1,   <-1,   <-3
              .byte     3,   <-1

; authored reduced (LOD) outlines
SHP192_A_LOD: .byte    44,     2,    25,    41,   <-32,    22,   <-38,   <-19
              .byte   <-7,   <-39,    21,   <-38
SHP192_B_LOD: .byte    42,    10,    19,    27,    16,    42,   <-28,    22
              .byte   <-39,   <-4,   <-20,   <-35,    26,   <-41
SHP192_C_LOD: .byte    21,    33,   <-23,    29,   <-41,   <-14,   <-10,   <-25
              .byte   <-10,   <-44,    23,   <-41,    37,   <-22,    41,     9
SHP128_A_LOD: .byte    28,   <-4,    22,    15,   <-14,    27,   <-27,    14
              .byte   <-24,   <-19,     8,   <-21
SHP128_B_LOD: .byte    27,     6,    18,    21,   <-14,    28,   <-27,     8
              .byte   <-14,   <-20,    16,   <-24,    19,   <-6
SHP128_C_LOD: .byte    14,    21,   <-12,    24,   <-27,     9,   <-20,   <-15
              .byte     2,   <-32,    26,   <-10

SHIP_VN     = 14
SHIP_SHAPE:   .byte     0,   <-8,   <-6,   <-8,   <-6,   <-13,     9,   <-13
              .byte     9,   <-8,     7,   <-8,    10,     0,     7,     8
              .byte     9,     8,     9,    13,   <-6,    13,   <-6,     8
              .byte     0,     8,   <-18,     0
; === END GENERATED ===
