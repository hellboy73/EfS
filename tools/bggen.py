#!/usr/bin/env python3
"""PNG -> MAD-65 VRAM-BACKGROUND strip, as an assembler source file.

    python tools/bggen.py --make-ring assets/png/radar100.png
    python tools/bggen.py assets/png/radar100.png proto/03_radar/radar_bg.s RING \
           --at 11,288

WHY THIS EXISTS AND NOT sprgen.py. A sprite is drawn by the blitter and can go
anywhere; this is furniture painted ONTO THE BACKGROUND, where the hardware
re-copies it under the image every frame for nothing. The background cannot be
drawn on - `MAD65_GPU_OS.md` is explicit that there is no `_BG` variant of any
line or pixel opcode, because setting one bit needs a read-modify-write and the
background window is write-only. Whole-byte writes are all there is, so a ring
is not a circle command, it is a bitmap: `LOAD` ($30), 256 bytes at a time, into
pages $C0-$FF.

WHAT IT EMITS, and why it is a strip and not pages. A `LOAD` writes a whole
256-byte page and a framebuffer row is 50 bytes, so a page is 5.12 rows of the
WHOLE SCREEN's width - 21 pages, 5,376 bytes, to cover a 100 x 100 corner. Most
of that is zeros. So this emits only the columns the art actually occupies, 13
bytes a row, and the cartridge expands them into a staging page. 1,300 bytes
instead of 5,376, and the arithmetic that costs is one counter.

THE PNG IS AUTHORED IN PLAYER ORIENTATION - upright, as you see it on the
turned monitor - and this rotates it, which is the TATE convention sprgen.py
already follows: nothing rotates at runtime, the asset is stored turned. The
mapping is main.s's own:

    fb_x = portrait_y            fb_y = 299 - portrait_x

so a PNG pixel (px, py) placed at portrait (X0, Y0) lands at framebuffer
(Y0 + py, 299 - X0 - px). The image's WIDTH therefore becomes framebuffer rows
and its HEIGHT becomes framebuffer columns.

The placement does NOT have to be byte-aligned. The strip is cut on byte
columns whatever the art's own edges are, and the ragged bits at either end
simply come out zero - which is what lets the instrument sit flush in the
corner rather than at the nearest multiple of eight.

PIXEL CONVENTION: anything not black and not transparent is a set bit. The
background is one bit deep - there is no overlay plane and no transparency, a
`LOAD` writes every bit of the page it covers.

--make-ring authors the artwork instead of reading it: a one-pixel ring at the
radius the radar's box wants, and a small ship at the centre pointing up. It is
here so the art has a provenance rather than appearing from nowhere - repaint
the PNG in any editor and re-run the conversion, the tool does not care which
made it.
"""

import sys

from PIL import Image


# --- the artwork -------------------------------------------------------------
def make_ring(path, size=100, ring_r=49):
    """A ring at `ring_r` and a ship at the centre, upright, on a 1-bit field."""
    im = Image.new("1", (size, size), 0)
    p = im.load()
    c = size // 2

    # The ring, by the midpoint circle the GPU would have drawn if it could -
    # eight-way symmetry off one octant, so it is exactly round and exactly one
    # pixel thick.
    x, y, d = ring_r, 0, 1 - ring_r
    while x >= y:
        for sx, sy in ((x, y), (y, x), (-x, y), (-y, x),
                       (x, -y), (y, -x), (-x, -y), (-y, -x)):
            px, py = c + sx, c + sy
            if 0 <= px < size and 0 <= py < size:
                p[px, py] = 1
        y += 1
        if d < 0:
            d += 2 * y + 1
        else:
            x -= 1
            d += 2 * (y - x) + 1

    # The ship: the same silhouette the game flies, at a size that survives one
    # bit per pixel - a nose, two swept wings and a notched tail. Solid, because
    # an outline this small closes up into a blob anyway. It points UP, and it
    # stays pointing up: the ship is definitionally at the radar's centre and
    # the world turns around it (4.3), so nothing here ever needs to rotate.
    ship = [
        "....X....",
        "....X....",
        "...XXX...",
        "...XXX...",
        "..XXXXX..",
        "..XXXXX..",
        ".XXXXXXX.",
        "XXX.X.XXX",
        "XX..X..XX",
        "....X....",
    ]
    sh, sw = len(ship), len(ship[0])
    for ry, row in enumerate(ship):
        for rx, ch in enumerate(row):
            if ch == "X":
                p[c - sw // 2 + rx, c - sh // 2 + ry] = 1

    im.save(path)
    print(f"wrote {path}: {size} x {size}, ring r={ring_r}, ship {sw} x {sh}")


# --- the conversion ----------------------------------------------------------
FB_W, FB_H, ROW_BYTES = 400, 300, 50
BG_BASE = 0xC000


def main(src, dst, label, at):
    x0, y0 = at
    im = Image.open(src).convert("RGBA")
    w, h = im.size
    px = im.load()

    def lit(ix, iy):
        r, g, b, a = px[ix, iy]
        return a > 127 and (r or g or b)

    # Where the art lands in the framebuffer. WIDTH becomes rows, HEIGHT becomes
    # columns - see the header.
    fbx0, fbx1 = y0, y0 + h - 1
    fby0, fby1 = 299 - x0 - (w - 1), 299 - x0
    if not (0 <= fbx0 and fbx1 < FB_W and 0 <= fby0 and fby1 < FB_H):
        sys.exit(f"art at portrait ({x0},{y0}) falls off the framebuffer: "
                 f"fb x {fbx0}..{fbx1}, y {fby0}..{fby1}")
    col0 = fbx0 // 8
    ncol = (fbx1 // 8) - col0 + 1
    nrow = fby1 - fby0 + 1

    # The strip: one row of the FRAMEBUFFER at a time, ncol bytes each, top row
    # first. fb_y counts down the portrait's x, so the first strip row is the
    # LAST column of the PNG.
    strip = []
    for r in range(nrow):
        ipx = w - 1 - r                         # 299 - x0 - ipx == fby0 + r
        row = []
        for c in range(ncol):
            byte = 0
            for bit in range(8):
                ipy = (col0 + c) * 8 + bit - fbx0
                if 0 <= ipy < h and lit(ipx, ipy):
                    byte |= 0x80 >> bit
            row.append(byte)
        strip.append(row)

    # The pages a LOAD has to write to cover it. A page is 256 bytes of a
    # 50-byte row pitch, so it starts mid-row and the cartridge's builder walks
    # rows and columns rather than dividing.
    off0 = fby0 * ROW_BYTES + col0
    off1 = fby1 * ROW_BYTES + col0 + ncol - 1
    pg0, pg1 = off0 >> 8, off1 >> 8
    base_off = pg0 << 8                         # where the first page starts
    r0, c0 = divmod(base_off, ROW_BYTES)        # ...as a row and a column

    out = []
    A = out.append
    A("; ===========================================================================")
    A(f"; {label} - GENERATED by tools/bggen.py from {src}. Do not edit.")
    A("; ===========================================================================")
    A(f"; {w} x {h} authored upright at portrait ({x0}, {y0}), stored TURNED:")
    A(f"; framebuffer rows {fby0}..{fby1}, byte columns {col0}..{col0 + ncol - 1}.")
    A(";")
    A(f"; {nrow} rows of {ncol} bytes = {nrow * ncol} bytes. The same picture as")
    A(f"; whole LOAD pages would be {pg1 - pg0 + 1} x 256 = {(pg1 - pg0 + 1) * 256}, almost")
    A("; all of it zeros, which is why the cartridge expands this instead.")
    A("; ===========================================================================")
    A("")
    A(f"{label}_ROWS    = {nrow}                ; framebuffer rows the art covers")
    A(f"{label}_W       = {ncol}                ; ...and bytes of each one")
    A(f"{label}_COL0    = {col0}                ; the first of those byte columns")
    A(f"{label}_PG0     = ${pg0 + (BG_BASE >> 8):02X}              ; first VRAM-background page to LOAD")
    A(f"{label}_PGN     = {pg1 - pg0 + 1}                ; ...and how many")
    A(f"{label}_R0      = {r0}               ; the row that first page STARTS in,")
    A(f"{label}_C0      = {c0}                ; at this column - so the builder needs")
    A("                                ;   no division")
    A(f"{label}_RR0     = {fby0 - r0}                 ; and the art's first row, relative")
    A("                                ;   to that one")
    A("")
    A(f"{label}_STRIP:")
    for r, row in enumerate(strip):
        for i in range(0, len(row), 13):
            chunk = row[i:i + 13]
            A("        .byte   " + ", ".join(f"${b:02X}" for b in chunk))
    A("")

    open(dst, "w", newline="\n").write("\n".join(out))
    print(f"wrote {dst}: {nrow} x {ncol} = {nrow * ncol} bytes, "
          f"pages ${pg0 + (BG_BASE >> 8):02X}..${pg1 + (BG_BASE >> 8):02X} "
          f"({pg1 - pg0 + 1} LOADs)")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--make-ring":
        make_ring(a[1], *(int(v) for v in a[2:]))
    elif len(a) >= 3:
        at = (11, 288)
        if "--at" in a:
            i = a.index("--at")
            at = tuple(int(v) for v in a[i + 1].split(","))
            a = a[:i] + a[i + 2:]
        main(a[0], a[1], a[2], at)
    else:
        sys.exit(__doc__)
