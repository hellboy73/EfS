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
AST_TYPES  = 4                  ; authored variants per size class. TYPE_PICK
                                 ;   in main.s must have exactly this many values
CLASS_BASE: .byte 0*AST_TYPES, 1*AST_TYPES, 2*AST_TYPES, 3*AST_TYPES, 4*AST_TYPES
                                 ; class -> the first shape id in that class,
                                 ;   so one_asteroid never has to multiply

; per-shape-id tables, 5 classes x AST_TYPES, size-major
SHAPE_N:    .byte   13, 12, 13, 13, 10, 10, 13, 12, 9, 9, 10, 11, 9, 7, 9
            .byte   10, 5, 5, 5, 6
SHAPE_R:    .byte   48, 48, 48, 48, 32, 32, 32, 32, 16, 16, 16, 16, 8, 8, 8
            .byte   8, 4, 4, 4, 4
SHAPE_OCC:  .byte   39, 39, 39, 39, 26, 26, 26, 26, 13, 13, 13, 13, 7, 7, 7
            .byte   7, 3, 3, 3, 3

SHAPE_LO:    .byte    <SHP192_A, <SHP192_B, <SHP192_C, <SHP192_D
             .byte    <SHP128_A, <SHP128_B, <SHP128_C, <SHP128_D
             .byte    <SHP64_A, <SHP64_B, <SHP64_C, <SHP64_D
             .byte    <SHP32_A, <SHP32_B, <SHP32_C, <SHP32_D
             .byte    <SHP16_A, <SHP16_B, <SHP16_C, <SHP16_D
SHAPE_HI:    .byte    >SHP192_A, >SHP192_B, >SHP192_C, >SHP192_D
             .byte    >SHP128_A, >SHP128_B, >SHP128_C, >SHP128_D
             .byte    >SHP64_A, >SHP64_B, >SHP64_C, >SHP64_D
             .byte    >SHP32_A, >SHP32_B, >SHP32_C, >SHP32_D
             .byte    >SHP16_A, >SHP16_B, >SHP16_C, >SHP16_D

SHAPE_LODN: .byte   6, 7, 8, 6, 6, 7, 6, 6, 0, 0, 0, 0, 0, 0, 0
            .byte   0, 0, 0, 0, 0
SHAPE_LODLO: .byte    <SHP192_A_LOD, <SHP192_B_LOD, <SHP192_C_LOD, <SHP192_D_LOD
             .byte    <SHP128_A_LOD, <SHP128_B_LOD, <SHP128_C_LOD, <SHP128_D_LOD
             .byte    0, 0, 0, 0
             .byte    0, 0, 0, 0
             .byte    0, 0, 0, 0
SHAPE_LODHI: .byte    >SHP192_A_LOD, >SHP192_B_LOD, >SHP192_C_LOD, >SHP192_D_LOD
             .byte    >SHP128_A_LOD, >SHP128_B_LOD, >SHP128_C_LOD, >SHP128_D_LOD
             .byte    0, 0, 0, 0
             .byte    0, 0, 0, 0
             .byte    0, 0, 0, 0

; 192 x 192 full-res -> radius 48 half-res
SHP192_A:     .byte   <-19,   <-27,   <-4,   <-40,    21,   <-38,    30,   <-28
              .byte    35,   <-16,    40,     1,    30,    19,    23,    37
              .byte     2,    34,   <-16,    32,   <-30,    20,   <-37,     4
              .byte   <-37,   <-18
SHP192_B:     .byte    24,    22,    19,    42,   <-7,    35,   <-22,    25
              .byte   <-33,    13,   <-41,   <-4,   <-29,   <-26,   <-17,   <-39
              .byte     6,   <-43,    30,   <-32,    34,   <-9,    45,    10
SHP192_C:     .byte   <-10,   <-22,   <-10,   <-44,    17,   <-42,    34,   <-26
              .byte    37,   <-9,    38,    16,    24,    30,     6,    35
              .byte   <-11,    31,   <-29,    23,   <-35,     6,   <-42,   <-14
              .byte   <-21,   <-28
SHP192_D:     .byte   <-14,   <-30,     3,   <-40,    27,   <-34,    37,   <-14
              .byte    43,    10,    26,    21,    25,    33,     7,    40
              .byte   <-4,    34,   <-23,    30,   <-35,    16,   <-40,   <-1
              .byte   <-33,   <-24

; 128 x 128 full-res -> radius 32 half-res
SHP128_A:     .byte    18,   <-11,    29,   <-4,    19,    17,     6,    24
              .byte   <-13,    27,   <-27,    16,   <-27,     3,   <-23,   <-19
              .byte   <-8,   <-21,     8,   <-21
SHP128_B:     .byte    19,   <-8,    28,     5,    20,    20,     2,    23
              .byte   <-14,    28,   <-24,    10,   <-24,   <-7,   <-18,   <-19
              .byte   <-2,   <-25,    16,   <-24
SHP128_C:     .byte     2,    11,   <-5,    19,   <-12,    22,   <-20,    17
              .byte   <-27,     8,   <-26,   <-10,   <-14,   <-21,     2,   <-31
              .byte    19,   <-19,    26,   <-6,    22,     9,    14,    23
              .byte   <-5,    25
SHP128_D:     .byte   <-2,   <-17,    14,   <-24,    14,   <-18,    21,   <-8
              .byte    29,     2,    15,    21,     1,    25,   <-16,    21
              .byte   <-25,     8,   <-27,   <-3,   <-19,   <-23,   <-7,   <-24

; 64 x 64 full-res -> radius 16 half-res
SHP64_A:      .byte     7,   <-9,    13,     0,    11,     8,     0,    13
              .byte   <-6,    12,   <-13,     8,   <-12,   <-2,   <-11,   <-7
              .byte   <-2,   <-14
SHP64_B:      .byte   <-8,     4,   <-15,   <-5,   <-5,   <-12,     4,   <-12
              .byte    12,   <-6,    13,     3,     5,    10,   <-4,    15
              .byte   <-8,    11
SHP64_C:      .byte   <-6,   <-8,   <-3,   <-13,     8,   <-12,    10,   <-4
              .byte    12,   <-6,    13,     7,     2,    13,   <-7,    10
              .byte   <-12,     2,   <-12,   <-5
SHP64_D:      .byte     9,   <-1,    13,     3,     9,    10,   <-3,    13
              .byte   <-9,    10,   <-14,     5,   <-11,   <-5,   <-9,   <-9
              .byte   <-3,   <-13,     7,   <-12,    12,   <-6

; 32 x 32 full-res -> radius 8 half-res
SHP32_A:      .byte     0,     3,   <-3,     7,   <-7,     2,   <-6,   <-3
              .byte   <-3,   <-7,     3,   <-6,     7,   <-1,     6,     3
              .byte     3,     7
SHP32_B:      .byte   <-5,     4,   <-7,   <-1,   <-2,   <-7,     5,   <-5
              .byte     7,     0,     5,     5,     0,     7
SHP32_C:      .byte     5,     0,     4,     5,   <-1,     7,   <-6,     3
              .byte   <-7,     0,   <-6,   <-4,     1,   <-7,     6,   <-3
              .byte     7,     1
SHP32_D:      .byte     3,     2,     3,     7,   <-2,     6,   <-5,     6
              .byte   <-7,     0,   <-3,   <-2,   <-5,   <-5,   <-1,   <-8
              .byte     5,   <-5,     7,     2

; 16 x 16 full-res -> radius 4 half-res
SHP16_A:      .byte   <-2,     2,   <-3,   <-1,     1,   <-3,     4,     0
              .byte     2,     3
SHP16_B:      .byte     0,     3,   <-4,     0,   <-2,   <-3,     3,   <-2
              .byte     3,     1
SHP16_C:      .byte   <-3,   <-1,   <-1,   <-3,     3,   <-1,     3,     2
              .byte   <-2,     3
SHP16_D:      .byte   <-1,   <-1,     0,   <-4,     3,     1,     1,     3
              .byte   <-2,     3,   <-4,     0

; authored reduced (LOD) outlines
SHP192_A_LOD: .byte   <-32,    22,   <-38,   <-19,   <-7,   <-39,    21,   <-38
              .byte    44,     2,    25,    41
SHP192_B_LOD: .byte    19,    27,    16,    42,   <-28,    22,   <-39,   <-4
              .byte   <-20,   <-35,    26,   <-41,    42,    10
SHP192_C_LOD: .byte   <-10,   <-25,   <-10,   <-44,    23,   <-41,    37,   <-22
              .byte    41,     9,    21,    33,   <-23,    29,   <-41,   <-14
SHP192_D_LOD: .byte   <-35,    16,   <-34,   <-25,     0,   <-40,    27,   <-34
              .byte    43,    10,    18,    45
SHP128_A_LOD: .byte     8,   <-21,    28,   <-4,    22,    15,   <-14,    27
              .byte   <-27,    14,   <-24,   <-19
SHP128_B_LOD: .byte    19,   <-6,    27,     6,    18,    21,   <-14,    28
              .byte   <-27,     8,   <-14,   <-20,    16,   <-24
SHP128_C_LOD: .byte   <-20,   <-15,     2,   <-32,    26,   <-10,    14,    21
              .byte   <-12,    24,   <-27,     9
SHP128_D_LOD: .byte   <-16,    20,   <-25,     7,   <-20,   <-24,    15,   <-22
              .byte    28,     2,    18,    19

SHIP_VN     = 14
SHIP_SHAPE:   .byte     0,   <-8,   <-4,   <-8,   <-4,   <-14,     9,   <-14
              .byte     9,   <-8,     7,   <-8,    10,     0,     7,     8
              .byte     9,     8,     9,    14,   <-4,    14,   <-4,     8
              .byte     0,     8,   <-22,     0
; === END GENERATED ===
