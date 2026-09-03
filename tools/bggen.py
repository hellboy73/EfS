#!/usr/bin/env python3
"""PNG -> MAD-65 VRAM-BACKGROUND rectangle, RLE-compressed, as an assembler file.

    python tools/bggen.py --make-ring assets/png/radar100.png
    python tools/bggen.py assets/png/radar100.png src/radar_bg.s RING \
           --at 1,298

WHY THIS EXISTS AND NOT sprgen.py. A sprite is drawn by the blitter and can go
anywhere; this is furniture painted ONTO THE BACKGROUND, where the hardware
re-copies it under the image every frame for nothing. The background cannot be
drawn on - `MAD65_GPU_OS.md` is explicit that there is no `_BG` variant of any
line or pixel opcode, because setting one bit needs a read-modify-write and the
background window is write-only. Whole-byte writes are all there is, and since
MAD-65's V1.0 transport block this means `RECT_BG_RLE` ($32): a byte-aligned
rectangle, arbitrary height, straight from the cartridge, RLE-compressed.

WHAT IT EMITS. `RECT_BG_RLE` takes a byte column and a row directly - no page
alignment to fight, unlike the old `LOAD`-based approach this replaced (a page
is 256 bytes of a 50-byte row pitch, so a 100 x 100 corner needed 21 pages,
5,376 bytes, almost all zeros). This tool packs only the columns the art
occupies, RLE-compresses the whole rectangle as ONE band - a one-pixel ring is
sparse enough that it compresses to roughly a third of its raw size, comfortably
inside a single PPRAM command - and emits it as one length-prefixed blob in the
format roms/rle.py defines (see MAD-65's docs/MAD65_CPU_OS.md, "the transport
block"): `[clen_lo][clen_hi][dlen_lo][dlen_hi]` then the compressed bytes. The
whole picture then loads in one `API_GPU_RECT_BG_CART` call instead of dozens of
`LOAD`s spread across many frames - see radar.s's ring_frame.

The blob is placed in its own segment (BGDATA, cart.cfg) that stays in the
cartridge window instead of being copied to RAM with the rest of the program:
nothing ever reads it through a RAM pointer, only API_GPU_RECT_BG_CART, which
reads cartridge bytes directly by bank and window address.

THE PNG IS AUTHORED IN PLAYER ORIENTATION - upright, as you see it on the
turned monitor - and this rotates it, which is the TATE convention sprgen.py
already follows: nothing rotates at runtime, the asset is stored turned. The
mapping is main.s's own:

    fb_x = portrait_y            fb_y = 299 - portrait_x

so a PNG pixel (px, py) placed at portrait (X0, Y0) lands at framebuffer
(Y0 + py, 299 - X0 - px). The image's WIDTH therefore becomes framebuffer rows
and its HEIGHT becomes framebuffer columns.

The placement does NOT have to be byte-aligned. The rectangle is cut on byte
columns whatever the art's own edges are, and the ragged bits at either end
simply come out zero - which is what lets the instrument sit flush in the
corner rather than at the nearest multiple of eight.

PIXEL CONVENTION: anything not black and not transparent is a set bit. The
background is one bit deep - there is no overlay plane and no transparency, and
RECT_BG_RLE writes every bit of the rectangle it covers (GAP=0, solid - the comb
argument is not used here, there being nothing under the ring to show through).

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


# --- the RLE codec -------------------------------------------------------------
# Vendored from MAD-65's roms/rle.py rather than imported from the sibling repo,
# so this tool - and the cartridge it feeds - stay self-contained (CLAUDE.md).
# The format is frozen ABI (gpu_os.s rle_next / cpu_os.s dc_next decode it) and
# must not drift from the reference copy:
#
#   ctrl $01-$7F   the next ctrl bytes are literals
#   ctrl $80-$FF   repeat the ONE byte that follows, (ctrl - $80) + 2 times
#   ctrl $00       never emitted
#
# There is no end marker: both decoders are driven by an output count the
# runtime already knows (here, WB * H), so an over-long final run is harmless
# and none of the banding complexity roms/rle.py carries for a MULTI-band
# picture applies - this tool always emits exactly one band, the whole picture.
MAX_LITERAL = 127
MAX_RUN = 129
MIN_RUN = 2


def rle_compress(data):
    out = bytearray()
    i, n = 0, len(data)
    pending = bytearray()

    def flush():
        k = 0
        while k < len(pending):
            chunk = pending[k:k + MAX_LITERAL]
            out.append(len(chunk))
            out.extend(chunk)
            k += len(chunk)
        pending.clear()

    while i < n:
        b = data[i]
        j = i
        while j < n and data[j] == b:
            j += 1
        runlen = j - i
        if runlen >= 3 or (runlen == MIN_RUN and not pending):
            flush()
            while runlen >= MIN_RUN:
                take = min(runlen, MAX_RUN)
                if runlen - take == 1:
                    take -= 1           # never strand a single byte
                out.append(0x80 + (take - MIN_RUN))
                out.append(b)
                runlen -= take
            pending.extend([b] * runlen)
        else:
            pending.extend(data[i:j])
        i = j
    flush()
    return bytes(out)


def rle_blob(data):
    """One length-prefixed blob: [clen_lo][clen_hi][dlen_lo][dlen_hi] + stream."""
    c = rle_compress(data)
    dlen = len(data)
    return bytes([len(c) & 0xFF, len(c) >> 8, dlen & 0xFF, dlen >> 8]) + c


# --- the conversion ----------------------------------------------------------
FB_W, FB_H, ROW_BYTES = 400, 300, 50
BGDATA_BANK = 1                             # must match cart.cfg's BGDATA segment


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
    if col0 + ncol > 50:
        sys.exit(f"XB={col0} + WB={ncol} = {col0 + ncol} > 50: the rectangle "
                 f"would run off the right edge and smear into the next row.")

    # The rectangle: one row of the FRAMEBUFFER at a time, ncol bytes each, top
    # row first. fb_y counts down the portrait's x, so the first output row is
    # the LAST column of the PNG.
    raw = bytearray()
    for r in range(nrow):
        ipx = w - 1 - r                     # 299 - x0 - ipx == fby0 + r
        for c in range(ncol):
            byte = 0
            for bit in range(8):
                ipy = (col0 + c) * 8 + bit - fbx0
                if 0 <= ipy < h and lit(ipx, ipy):
                    byte |= 0x80 >> bit
            raw.append(byte)

    blob = rle_blob(bytes(raw))

    out = []
    A = out.append
    A("; ===========================================================================")
    A(f"; {label} - GENERATED by tools/bggen.py from {src}. Do not edit.")
    A("; ===========================================================================")
    A(f"; {w} x {h} authored upright at portrait ({x0}, {y0}), stored TURNED:")
    A(f"; framebuffer rows {fby0}..{fby1}, byte columns {col0}..{col0 + ncol - 1}.")
    A(";")
    A(f"; {nrow} rows of {ncol} bytes = {len(raw)} bytes raw, RLE-compressed to")
    A(f"; {len(blob)} bytes as ONE band (roms/rle.py format, MAD-65 sibling repo) -")
    A(f"; {len(raw) / len(blob):.2f}x, loaded in a single API_GPU_RECT_BG_CART call")
    A("; instead of the per-page LOADs this file used to hold. See radar.s.")
    A("; ===========================================================================")
    A("")
    A(f"{label}_ROWS    = {nrow}                ; source rows (== H, the whole picture")
    A("                                ;   is one band)")
    A(f"{label}_WB      = {ncol}                ; ...and bytes of each one")
    A(f"{label}_XB      = {col0}                ; destination byte column")
    A(f"{label}_Y0      = {fby0}               ; destination row of source row 0")
    A(f"{label}_GAP     = 0                 ; solid - nothing under the ring to")
    A("                                ;   show through")
    A(f"{label}_BANK    = {BGDATA_BANK}                 ; cart.cfg: BGDATA lives in bank {BGDATA_BANK}")
    A("")
    A('        .segment "BGDATA"       ; stays in the cartridge window - never')
    A("                                ;   copied to RAM. See cart.cfg.")
    A(f"{label}_BLOB:")
    blob_bytes = list(blob)
    for i in range(0, len(blob_bytes), 13):
        chunk = blob_bytes[i:i + 13]
        A("        .byte   " + ", ".join(f"${b:02X}" for b in chunk))
    A("")
    A('        .segment "RODATA"')
    A("")

    open(dst, "w", newline="\n").write("\n".join(out))
    print(f"wrote {dst}: {nrow} x {ncol} = {len(raw)} B raw -> {len(blob)} B "
          f"blob ({len(raw) / len(blob):.2f}x), one API_GPU_RECT_BG_CART call")


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
