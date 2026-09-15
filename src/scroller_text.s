; =============================================================================
; scroller_text.s - the title screen's marquee, EDITED BY HAND
; =============================================================================
; One loop of text along the bottom line (screens.s marquee). Edit the strings
; and run make; nothing generates this file.
;
;   * Only the MAD-65 font's characters, $20-$7E: capitals, digits, space and
;     ordinary punctuation. No lowercase is drawn as lowercase, no Polish letters,
;     no curly quotes - write ' and -.
;   * A " cannot go inside a "..." string; it would be .byte $22 on its own.
;   * The spaces are the timing: the first line is a screen's width (37) of them,
;     so the text enters from the right edge, and the gaps between sentences are
;     plain spaces too.
;   * $FF ends the loop and must stay last.
; =============================================================================

        .segment "UICODE"
SC_MSG:
        .byte   "                                     "     ; 37: enter from the right
        .byte   "           IN THE YEAR 2093, SATURN'S RINGS REVEAL A NEW MINERAL - SATURNIUM - A POSSIBLE KEY TO THE PROPULSION OF TOMORROW.   "
        .byte   "HUMANITY'S HOPES ARE HIGH. BUT THE RINGS HAVE STARTED LYING... GHOSTS ON RADAR... COLLISIONS WITH NOTHING AT ALL.   "
        .byte   "FIVE SHIPS LAUNCH FROM TITAN STATION. YOU FLY ONE OF THEM.   "
        .byte   "YOUR ORDERS: CLEAR THE RINGS, SECTOR BY SECTOR.   "
        .byte   "BUT SOMETHING OUT THERE IS NOT WHAT IT SEEMS...   "
        .byte   "GOOD LUCK, PILOT. YOU'LL NEED IT TO ESCAPE FROM SATURN.                      "
        .byte   "A MAD-65 ARCADE GAME BY MATEUSZ MATYSIAK V0.6                                                     "
        .byte   $FF                                         ; end of the loop
