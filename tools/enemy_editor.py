#!/usr/bin/env python3
"""Composite shape editor for EfS's enemies - reads and writes src/enemies.s
directly.

    python tools/enemy_editor.py [path/to/enemies.s]

An enemy is a small ordered list of PARTS sharing one anchor, not one closed
outline like a rock - but every part is still a POLYGON16 call, CLOSED or
OPEN (MAD-65's polygon-family OPEN flag, N's bit 7): closed for a hull or a
turret dome, open for a barrel or an antenna. Both ride the same GPU-side
rotate+scale matrix, so nothing here costs CPU1 a hand-rolled rescale the way
a literal CIRCLE16 or LINE16 part would once the camera starts zooming - see
enemies.s for the long version. There is no circle primitive either: press
"Make regular polygon" on a selected part to lay its vertices out on a circle
(radius + side count) and close it; it is still an ordinary polygon
afterwards, free to hand-edit.

FRAMES. An enemy is animated the way a sprite is - a handful of authored
FRAMES, switched, not tweened. The PART LIST is structural and identical in
every frame (part 0 is the hull in all of them, and closed/open and the wreck
flag belong to the part, not to the frame); what a frame holds is each part's
VERTICES. So a frame costs only the parts that actually moved: the writer
below dedupes identical part outlines across frames and points the table at
one blob, which is why a static hull drawn in four frames costs four POINTER
bytes and not four copies of itself.

A PART CAN BE ABSENT FROM A FRAME, which is how a line appears in the last
frame and not in the first three. The part list stays rectangular - the
absent frames hold the part with ONE vertex, and an OPEN part's K vertices are
K-1 segments, so one vertex is no segment and the GPU draws nothing for it
(MAD-65 gpu_os.s op_polygon16 takes N-1 = 0 straight to the closing edge and
OPEN skips that). It costs three data bytes, shared by every frame that is
absent, and one command the GPU leaves almost immediately. "Absent in this
frame" is the button; only OPEN parts can do it, because a closed one still
draws its v0 -> v0 closing edge as a single lit pixel. Do NOT hand-author
K = 0 - the GPU handles it, but foes.s's copy loop is a do-while on 2K and
reads zero as 256.

THE PLAYLIST is separate from the frames, and that is the point. It is a list
of frame numbers - "0,1,2,1" plays three drawn frames as a four-step
ping-pong - of ANY length, and EN_*_AHOLD is how many game frames one step
lasts, also any number. Neither has to be a power of two: each enemy counts
its own step down (foes.s FOEACD/FOEAST), so the runtime never divides and
never masks. Repeats in the playlist are still free - two pointer bytes - so
holding one frame longer than its neighbours is authored by writing it
twice.

Only the GENERATED block in enemies.s is ever touched, rewritten WHOLE on
every Save, same discipline as tools/shape_editor.py - which this borrows its
parsing and negative-byte formatting from.

Left canvas: drag a handle to move it, double-click an edge to insert a
vertex there, select + Delete to remove them (3-vertex floor when closed,
2-vertex floor when open). All of the current frame's parts are drawn for
context; only the selected part's handles are draggable.

SELECTION IS A SET OF (PART, VERTEX) PAIRS, so it spans parts. The part rows
carry a TICK BOX each: tick a part to grab all of its handles, "tick all" to
grab the whole enemy, then drag any handle and the lot moves together. The box
is a view of the selection as much as a command - it shows ticked exactly
while every one of that part's handles is selected - and the radio beside it
only says which part the vertex-level buttons act on, without disturbing what
is ticked.

The finer ways in are still there: drag on empty space for a rubber band
(ctrl+drag to sweep every part rather than the selected one), shift-click to
add or drop one handle, ctrl+A for the whole enemy, ctrl+shift+A for the
current part, arrow keys to nudge by 1 (by 8 with shift). A drag moves EVERY
selected handle by the same delta, and the |v| <= 127 ceiling is applied to
that DELTA rather than to each point - clamp the points one at a time and the
outermost one sticks while the rest keep going, which deforms a hull instead
of stopping it.

"Offset all frames..." is the one to reach for when a shape has to sit off its
anchor - the spider mounted on a rock's centre. POLYGON16 rotates the offsets
about the anchor, so a shape authored 60 px off centre rides the rim of
whatever it is anchored to, spinning with it, for no CPU1 work at all. That
dialog shifts every part in every frame at once; ticking and dragging only
moves the frame you are looking at.

"Duplicate" copies a whole enemy - frames, parts, playlist, hold and radius.
That is how a second APPEARANCE of one enemy starts: a single behaviour KIND
in foes.s can wear two of these, and they want their own playlists and their
own collision circles.

THE COLLISION CIRCLE is drawn over the shape, dashed and green, from EN_*_R -
an authored property of the enemy, in COLLISION UNITS (32 world units = one
half-res px), which is what foes.s measures hits in. The shape is in FULL-RES
px, so the circle's radius on the canvas is 2R. "from shape" fills in the
mean-vertex estimate the rocks and the ship use; it is a starting point and
not an answer (FOE_R is deliberately 1.25x it, because the honest mean read
too small to hit). Until the shape tables go per-KIND, foes.s's own FOE_R is
still the number the game uses - enemies.s asserts the two agree.

THE VIEW is yours: the wheel zooms about the cursor, the middle button pans,
"f" or Fit re-frames the whole enemy - and IT IS NOT RECOMPUTED FROM THE
CONTENT. It used to be: the scale was
fitted to the outermost point on every redraw, which made dragging a handle
outward a runaway (the point moves out, so the view zooms out, so the same
cursor position is further out still, so the point moves out...) and threw the
zoom away in a few pixels of travel. The view now only changes when you change
it - which is also what keeps the zoom steady while you step through frames.

Right column: pick/add/remove enemy shapes and parts, and the numeric fields
for whatever is selected. The preview below plays the playlist at the game's
rate.

THE CANVAS IS THE PLAYER'S SCREEN, NOT THE FILE. enemies.s stores FRAMEBUFFER
offsets, and the monitor is turned 90 degrees clockwise (TATE): a stored dx is
the player's VERTICAL (negative = up, exactly as the ship's nose is authored in
shapes.s) and a stored dy is the player's horizontal, mirrored. So the editor
turns every point on the way in and back on the way out -

    player (x right, y down) = (-dy, dx)        stored (dx, dy) = (y, -x)

- and what is drawn here is what the game draws with ANGLE 0. It used to draw
the stored numbers straight, which showed every enemy a quarter turn off from
how it appears in the game. The numeric fields are in the player's axes too.
"""
import math
import pathlib
import re
import sys
import tkinter as tk
from tkinter import ttk, messagebox, simpledialog

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from shape_editor import parse_generated_block, fmt_cell, VERTEX_MAX  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_ENEMIES = ROOT / "src" / "enemies.s"

SENTINEL_START = "; === GENERATED (tools/enemy_editor.py) - rewritten whole on Save ============"
SENTINEL_END = "; === END GENERATED ==="

OPEN_BIT = 0x80             # POLYGON16's N: bit 7 = open (polyline), bits 0-6 = K
DEFAULT_HOLD = 8            # game frames a playlist step lasts, when a file
                            #   does not say (or said it as the old shift)
FPS = 60.317                # madsim's real rate, so the preview runs at the game's


def to_view(pt):
    """A stored (framebuffer) offset -> the player's (x right, y down)."""
    return -pt[1], pt[0]


def from_view(x, y):
    """...and back: the player's (x, y) -> the stored (dx, dy)."""
    return y, -x


# =============================================================================
# data model
# =============================================================================
class Part:
    """One POLYGON16 call's worth of an enemy, in ONE frame. `closed` and
    `wreck` are structural - the editor keeps them equal across every frame of
    the same part index - and `pts` is the only thing a frame really varies."""
    __slots__ = ("pts", "closed", "wreck")

    def __init__(self, pts, closed, wreck=True):
        self.pts = pts            # K points; closed wraps last->first, open does not
        self.closed = closed
        self.wreck = wreck        # does this part fly off as a wreck piece?

    @classmethod
    def new_closed(cls):
        return cls([(-10, 0), (0, -10), (10, 0), (0, 10)], True)

    @classmethod
    def new_open(cls):
        return cls([(-10, 0), (10, 0)], False)

    def copy(self):
        return Part(list(self.pts), self.closed, self.wreck)

    def min_pts(self):
        """An OPEN part may fall to ONE vertex: K vertices are K-1 segments, so
        K = 1 is no segment at all and the GPU draws nothing (MAD-65 gpu_os.s,
        op_polygon16: N-1 = 0 jumps straight to the closing edge, and OPEN
        skips that). That is how a part is ABSENT FROM A FRAME. A CLOSED part
        cannot do it - its closing edge v0 -> v0 is still drawn, as one lit
        pixel - and K = 0 must not be authored at all: foes.s's copy loop is a
        do-while on 2K, so nothing is the one count it reads as 256."""
        return 3 if self.closed else 1

    def absent(self):
        return not self.closed and len(self.pts) < 2


class Enemy:
    """frames[f][i] is part i's outline in frame f - every frame has the same
    parts. `order` is the playlist: a frame number per step. `radius` is the
    COLLISION circle, in collision units (32 world units = one half-res px),
    so the circle drawn over a shape authored in full-res px has radius 2R."""
    __slots__ = ("name", "frames", "order", "hold", "radius")

    def __init__(self, name, frames=None, order=None, hold=DEFAULT_HOLD, radius=None):
        self.name = name
        self.frames = frames if frames is not None else [[Part.new_closed()]]
        self.order = order if order else [0]
        self.hold = hold
        self.radius = radius if radius is not None else self.radius_from_shape()

    def radius_from_shape(self):
        """The mean-vertex compromise the rocks, the ship and the UFO all make
        (foes.s FOE_R): the average distance from the anchor, halved into
        collision units. A starting point, not an answer - FOE_R itself is
        1.25x this, because the honest mean read too small to hit."""
        pts = [p for f in self.frames for part in f for p in part.pts]
        if not pts:
            return 8
        mean = sum(math.hypot(x, y) for x, y in pts) / len(pts)
        return max(1, min(127, int(round(mean / 2))))

    @property
    def pn(self):
        return len(self.frames[0]) if self.frames else 0

    @property
    def fn(self):
        return len(self.frames)

    def parts_of(self, f):
        return self.frames[f] if 0 <= f < self.fn else []

    def wreck_n(self):
        """How many LEADING parts fly off as wreck pieces. The runtime wants
        one count, not a flag per part (fw_spawn just stops early), so a
        cosmetic part has to sit at the end; this reports the honest prefix."""
        n = 0
        for p in (self.frames[0] if self.frames else []):
            if not p.wreck:
                break
            n += 1
        return n

    def wreck_ok(self):
        """...and this is whether the flags actually form that prefix."""
        seen_false = False
        for p in (self.frames[0] if self.frames else []):
            if not p.wreck:
                seen_false = True
            elif seen_false:
                return False
        return True


class Model:
    def __init__(self, enemies):
        self.enemies = enemies    # [Enemy, ...], order is draw order

    @classmethod
    def load(cls, text):
        scalars, blocks = parse_generated_block(text, SENTINEL_START, SENTINEL_END)
        body = generated_body(text)
        names = [m.group(1) for k in scalars
                 for m in [re.match(r'^EN_(.+)_PN$', k)] if m]
        # The flat appearance tables. A file written before them has a row
        # table and a playlist PER ENEMY instead, so both shapes are read -
        # this is the only place that knows the difference.
        flat_rows = [t.lstrip('<').strip() for t in block_tokens(body, "EN_PLO")]
        flat_anim = block_tokens(body, "EN_ANIM")
        enemies = []
        for name in names:
            pn = max(1, scalars[f"EN_{name}_PN"])
            fn = max(1, scalars.get(f"EN_{name}_FN", 1))
            pw = scalars.get(f"EN_{name}_PW", pn)
            an = scalars.get(f"EN_{name}_AN", 1)
            # AHOLD is a plain frame count. A file written before that was a
            # SHIFT, EN_*_ASH - read either, write only the count.
            hold = scalars.get(f"EN_{name}_AHOLD")
            if hold is None:
                old_ash = scalars.get(f"EN_{name}_ASH")
                hold = DEFAULT_HOLD if old_ash is None else (1 << old_ash)
            hold = max(1, min(255, hold))

            rbase = scalars.get(f"EN_{name}_RBASE")
            if flat_rows and rbase is not None:
                labels = flat_rows[rbase:rbase + fn * pn]
                abase = scalars.get(f"EN_{name}_ABASE", 0)
                order = parse_anim(flat_anim[abase:abase + an], pn)
            else:
                labels = [t.lstrip('<').strip()
                          for t in block_tokens(body, f"EN_{name}_PLO")]
                order = parse_anim(block_tokens(body, f"EN_{name}_ANIM"), pn)
            if len(labels) != fn * pn:
                labels = [f"EN_{name}_P{i}" for i in range(pn)]   # a pre-frames file
                fn = 1

            frames = []
            for f in range(fn):
                frames.append([part_from_bytes(blocks.get(labels[f * pn + i], []),
                                               wreck=(i < pw))
                               for i in range(pn)])

            order = [f for f in order if 0 <= f < fn] or list(range(fn))
            enemies.append(Enemy(name, frames, order, hold,
                                 scalars.get(f"EN_{name}_R")))
        return cls(enemies)


def part_from_bytes(raw, wreck=True):
    if not raw:
        return Part.new_closed()
    header = raw[0]
    closed = not (header & OPEN_BIT)
    k = header & 0x7F
    coords = raw[1:1 + 2 * k]
    pts = list(zip(coords[0::2], coords[1::2]))
    # ONE point is legal for an open part - that is a part absent from this
    # frame (K-1 = 0 segments), and reading it back as two would silently
    # un-hide it on the next Save. ZERO is not modelled at all: the GPU is
    # fine with it but foes.s reads it as 256, so a K = 0 blob in a
    # hand-edited file comes back as an ordinary two-point line.
    floor = 3 if closed else 1
    if len(pts) < floor:
        pts = (Part.new_closed() if closed else Part.new_open()).pts
    return Part(pts, closed, wreck)


def generated_body(text):
    start = text.index(SENTINEL_START) + len(SENTINEL_START)
    return text[start:text.index(SENTINEL_END)]


def block_tokens(body, label):
    """The RAW comma tokens of a `LABEL: .byte ...` block, continuation lines
    included. parse_generated_block drops everything that is not a plain
    number, and the two tables this file has to read back - the pointers and
    the playlist - are nothing but label refs and `n*EN_X_PN` expressions."""
    out, cur = [], False
    for raw in body.split('\n'):
        code = raw.split(';', 1)[0]
        if not code.strip():
            continue
        m = re.match(r'^(\w+):\s*(.*)$', code)
        if m:
            cur = (m.group(1) == label)
            rest = m.group(2).strip()
            if cur and rest.startswith('.byte'):
                out += [t.strip() for t in rest[len('.byte'):].split(',')]
            continue
        stripped = code.strip()
        if stripped.startswith('.byte'):
            if cur:
                out += [t.strip() for t in stripped[len('.byte'):].split(',')]
        elif cur:
            cur = False
    return [t for t in out if t]


def parse_anim(tokens, pn):
    """ANIM holds ROW offsets - `2*EN_UFO_PN` - because that is what the
    runtime adds to a part index without a multiply. Back to frame numbers."""
    out = []
    for t in tokens:
        m = re.match(r'^(\d+)\s*\*', t)
        if m:
            out.append(int(m.group(1)))
            continue
        m = re.match(r'^(\d+)$', t)
        if m:
            out.append(int(m.group(1)) // max(1, pn))
    return out


def sanitize_name(raw, existing):
    s = re.sub(r'[^A-Za-z0-9]+', '_', raw.strip()).strip('_').upper()
    if not s:
        s = "ENEMY"
    if not s[0].isalpha():
        s = "E_" + s
    base, n = s, 2
    while s in existing:
        s = f"{base}{n}"
        n += 1
    return s


# =============================================================================
# formatting / writing - same signed-byte style as shape_editor.py
# =============================================================================
def fmt_byte_line(label, vals, per_line=8, width=15):
    lead = f"{label}:"
    pad = " " * max(1, width - len(lead))
    lines = [vals[i:i + per_line] for i in range(0, len(vals), per_line)] or [[]]
    out = [lead + pad + ".byte " + ", ".join(fmt_cell(v) for v in lines[0])]
    for row in lines[1:]:
        out.append(" " * width + ".byte " + ", ".join(fmt_cell(v) for v in row))
    return "\n".join(out)


def fmt_tok_line(label, toks, per_line=8, width=15):
    lead = f"{label}:"
    pad = " " * max(1, width - len(lead))
    lines = [toks[i:i + per_line] for i in range(0, len(toks), per_line)] or [[]]
    out = [lead + pad + ".byte " + ", ".join(lines[0])]
    for row in lines[1:]:
        out.append(" " * width + ".byte " + ", ".join(row))
    return "\n".join(out)


def part_bytes(p):
    vals = [len(p.pts) | (0 if p.closed else OPEN_BIT)]
    for x, y in p.pts:
        vals += [x, y]
    return vals


def render_enemy(e, rbase, abase):
    """One enemy's block: its scalars, and the blobs its rows point at.

    Identical part outlines are emitted ONCE and pointed at from every frame
    that uses them, so a part that does not animate costs two pointer bytes a
    frame and nothing else. The ROWS themselves are not here - they go into the
    one flat table below, because the runtime indexes by APPEARANCE and a table
    per enemy would mean a pointer to a pointer."""
    n = e.name
    pn, fn = e.pn, e.fn
    # The grid has to be rectangular or the rows come out the wrong length and
    # the loader cannot slice them back apart. The editor's own part operations
    # touch every frame, so this can only be reached by a hand-edited file -
    # and this file is the only copy, so it is checked rather than trusted.
    ragged = [f for f in range(fn) if len(e.parts_of(f)) != pn]
    if ragged:
        raise ValueError(f"{n}: frame(s) {ragged} do not have the same {pn} parts as frame 0")
    out = [f"; ---- {n} ----"]
    out.append(f"EN_{n}_PN     = {pn}      ; parts, the same in every frame")
    out.append(f"EN_{n}_PW     = {e.wreck_n()}      ; ...of which the LEADING ones become wreck pieces")
    out.append(f"EN_{n}_FN     = {fn}      ; authored frames")
    out.append(f"EN_{n}_AN     = {len(e.order)}      ; playlist steps - any number")
    out.append(f"EN_{n}_AHOLD  = {e.hold}      ; game frames one step lasts")
    out.append(f"EN_{n}_R      = {e.radius}      ; collision circle, collision units: radius {2 * e.radius} full-res px")
    out.append(f"EN_{n}_RBASE  = {rbase}      ; its first row in EN_PLO/EN_PHI...")
    out.append(f"EN_{n}_ABASE  = {abase}      ; ...and its first step in EN_ANIM")

    blobs, index, rows = [], {}, []
    for f in range(fn):
        for i, p in enumerate(e.parts_of(f)):
            key = tuple(part_bytes(p))
            if key not in index:
                users = []
                index[key] = (f"EN_{n}_S{len(blobs)}", users)
                blobs.append((index[key][0], list(key), users))
            index[key][1].append((f, i))
            rows.append(index[key][0])
    for label, vals, users in blobs:
        out.append("; " + ", ".join(f"f{f}p{i}" for f, i in users))
        out.append(fmt_byte_line(label, vals))
    return out, rows


def render_generated(model):
    """The whole block. Per enemy: scalars and blobs. Then THE APPEARANCE
    TABLES - one flat row table and one flat playlist, both sliced by the
    per-appearance base above.

    Why flat. foes.s looks a shape up by APPEARANCE (a per-foe byte), not by
    the assembler name, because one behaviour KIND can wear two shapes - the
    spider mounted on its rock and the spider adrift. A table per enemy would
    make that a pointer to a pointer and cost four zero-page bytes and an
    indirection per part; one flat table makes it a single ADD per foe:

        row  = EN_RBASE[app] + EN_ANIM[EN_ABASE[app] + step] + part
    """
    if not model.enemies:
        return "; (no enemy shapes authored yet - open tools/enemy_editor.py to add the first)"
    out, all_rows, all_anim = [], [], []
    for e in model.enemies:
        block, rows = render_enemy(e, len(all_rows), len(all_anim))
        out += block + [""]
        all_rows += rows
        all_anim += [f"{f}*EN_{e.name}_PN" for f in e.order]
    if len(all_rows) > 256 or len(all_anim) > 256:
        raise ValueError(f"the appearance tables are indexed by a byte: "
                         f"{len(all_rows)} rows and {len(all_anim)} playlist steps, "
                         f"256 each is the ceiling")

    names = [e.name for e in model.enemies]
    out.append("; ---- the appearance table ----")
    out.append("; Which shape a foe wears is one byte, EA_*, and every table below is")
    out.append("; indexed by it. A behaviour KIND picks an appearance; two appearances")
    out.append("; can belong to one kind.")
    for i, n in enumerate(names):
        out.append(f"EA_{n:<14} = {i}")
    out.append(f"EN_APPN = {len(names)}      ; how many appearances there are")
    for field, vals, note in (
        ("EN_PN", [f"EN_{n}_PN" for n in names], "parts per frame"),
        ("EN_PW", [f"EN_{n}_PW" for n in names], "...of which become wreck pieces"),
        ("EN_AN", [f"EN_{n}_AN" for n in names], "playlist steps"),
        ("EN_AHOLD", [f"EN_{n}_AHOLD" for n in names], "game frames a step lasts"),
        ("EN_R", [f"EN_{n}_R" for n in names], "collision circle, collision units"),
        ("EN_RBASE", [f"EN_{n}_RBASE" for n in names], "first row in EN_PLO/EN_PHI"),
        ("EN_ABASE", [f"EN_{n}_ABASE" for n in names], "first step in EN_ANIM"),
    ):
        out.append(f"; {note}")
        out.append(fmt_tok_line(field, vals, per_line=6))
    out.append("; every playlist, end to end: step -> the frame's ROW within its own")
    out.append(";   appearance, already multiplied by the part count")
    out.append(fmt_tok_line("EN_ANIM", all_anim, per_line=5))
    out.append("; every row, end to end, frame-major within each appearance")
    out.append(fmt_tok_line("EN_PLO", [f"<{r}" for r in all_rows], per_line=6))
    out.append(fmt_tok_line("EN_PHI", [f">{r}" for r in all_rows], per_line=6))
    return "\n".join(out).rstrip("\n") + "\n"


def save_model(path, model):
    text = path.read_text(encoding="utf-8")
    start = text.index(SENTINEL_START) + len(SENTINEL_START)
    end = text.index(SENTINEL_END)
    body = render_generated(model)
    new_text = text[:start] + "\n" + body + text[end:]
    path.write_text(new_text, encoding="utf-8")


# =============================================================================
# GUI
# =============================================================================
BG = "#101418"
BAR = "#161b21"
GRID = "#26303a"
CLOSED_COLOR = "#7fd0ff"
OPEN_COLOR = "#ffb347"
DIM_COLOR = "#3a4552"       # context-only color for parts that are not selected
ONION_COLOR = "#4a3a2e"     # the previous frame, drawn behind everything
POINT_COLOR = "#ffffff"
SEL_COLOR = "#ff5566"
LIMIT_COLOR = "#33404d"     # the |v| <= 127 ceiling
DISC_COLOR = "#3f8060"      # the collision circle (EN_*_R)

ZOOM_MIN, ZOOM_MAX = 0.25, 40.0


class EnemyEditor(tk.Tk):
    def __init__(self, path):
        super().__init__()
        self.path = path
        self.title(f"EfS enemy editor - {path}")
        self.geometry("1240x800")
        self.configure(bg=BG)

        self.model = Model.load(path.read_text(encoding="utf-8"))
        self.dirty = False
        self.cur_enemy_i = 0 if self.model.enemies else None
        self.cur_frame_i = 0
        self.cur_part_i = 0 if self.model.enemies else None
        # THE SELECTION is a SET of handle indices within the current part, and
        # sel_idx is the last one touched - what the X/Y fields edit. A drag
        # moves the whole set RIGIDLY (the clamp is applied to the delta, not to
        # each point), which is how a hull is moved without deforming it.
        self.sel = set()
        self.sel_idx = None
        self._band = None              # the rubber band, canvas px, while drawn
        self._drag = None              # (stored x0, y0, {i: (x, y)}) while moving

        # The view. NOT derived from the content - see the module docstring.
        self.view_scale = None         # None = fit once, on the first draw
        self.view_ox = 0.0
        self.view_oy = 0.0
        self._pan_from = None

        self.play_step = 0
        self.play_job = None

        self._build_ui()
        self._refresh_all()

    # ---- state helpers -------------------------------------------------
    def _enemy(self):
        if self.cur_enemy_i is None:
            return None
        return self.model.enemies[self.cur_enemy_i]

    def _frame_parts(self):
        e = self._enemy()
        if e is None:
            return []
        self.cur_frame_i = max(0, min(self.cur_frame_i, e.fn - 1))
        return e.parts_of(self.cur_frame_i)

    def _part(self):
        parts = self._frame_parts()
        if self.cur_part_i is None or self.cur_part_i >= len(parts):
            return None
        return parts[self.cur_part_i]

    # ---- UI scaffolding --------------------------------------------------
    def _build_ui(self):
        top = tk.Frame(self, bg=BG)
        top.pack(side="top", fill="x", padx=8, pady=(6, 2))

        tk.Label(top, text="Enemy:", bg=BG, fg="white").pack(side="left")
        self.enemy_var = tk.StringVar()
        self.enemy_menu = ttk.Combobox(top, textvariable=self.enemy_var, state="readonly", width=18)
        self.enemy_menu.pack(side="left", padx=(2, 6))
        self.enemy_menu.bind("<<ComboboxSelected>>", self._on_enemy_change)

        tk.Button(top, text="+ New enemy", command=self._new_enemy).pack(side="left", padx=2)
        tk.Button(top, text="Duplicate", command=self._dup_enemy).pack(side="left", padx=2)
        tk.Button(top, text="Rename", command=self._rename_enemy).pack(side="left", padx=2)
        tk.Button(top, text="Delete enemy", command=self._delete_enemy).pack(side="left", padx=(2, 14))

        right_btns = tk.Frame(top, bg=BG)
        right_btns.pack(side="right")
        tk.Button(right_btns, text="Copy ASM snippet", command=self._copy_snippet).pack(side="left", padx=4)
        tk.Button(right_btns, text="Reload", command=self._reload).pack(side="left", padx=4)
        self.save_btn = tk.Button(right_btns, text="Save to enemies.s", command=self._save,
                                   bg="#2a6", fg="white")
        self.save_btn.pack(side="left", padx=4)

        # ---- the frame strip --------------------------------------------
        fbar = tk.Frame(self, bg=BAR)
        fbar.pack(side="top", fill="x", padx=8, pady=2)

        tk.Label(fbar, text="Frame", bg=BAR, fg="white").pack(side="left", padx=(6, 2))
        tk.Button(fbar, text="<", width=2, command=lambda: self._step_frame(-1)).pack(side="left")
        self.frame_label = tk.Label(fbar, text="1/1", bg=BAR, fg=CLOSED_COLOR, width=6)
        self.frame_label.pack(side="left")
        tk.Button(fbar, text=">", width=2, command=lambda: self._step_frame(1)).pack(side="left", padx=(0, 8))
        tk.Button(fbar, text="+ Dup", command=self._dup_frame).pack(side="left", padx=2)
        tk.Button(fbar, text="Delete", command=self._delete_frame).pack(side="left", padx=2)
        tk.Button(fbar, text="Move <", command=lambda: self._move_frame(-1)).pack(side="left", padx=2)
        tk.Button(fbar, text="Move >", command=lambda: self._move_frame(1)).pack(side="left", padx=(2, 10))

        self.onion_var = tk.IntVar(value=1)
        tk.Checkbutton(fbar, text="Onion skin", variable=self.onion_var, bg=BAR, fg="white",
                       selectcolor=BG, activebackground=BAR, activeforeground="white",
                       command=self._draw_edit).pack(side="left", padx=(0, 12))

        tk.Label(fbar, text="Playlist", bg=BAR, fg="white").pack(side="left")
        self.order_var = tk.StringVar()
        oe = tk.Entry(fbar, textvariable=self.order_var, width=24)
        oe.pack(side="left", padx=2)
        oe.bind("<Return>", lambda ev: self._commit_order())
        oe.bind("<FocusOut>", lambda ev: self._commit_order())
        tk.Button(fbar, text="all", command=lambda: self._preset_order("loop")).pack(side="left", padx=2)
        tk.Button(fbar, text="ping-pong", command=lambda: self._preset_order("pingpong")).pack(side="left", padx=2)

        tk.Label(fbar, text="hold", bg=BAR, fg="white").pack(side="left", padx=(10, 2))
        self.hold_var = tk.StringVar()
        hb = tk.Entry(fbar, textvariable=self.hold_var, width=4)
        hb.pack(side="left")
        hb.bind("<Return>", lambda ev: self._commit_hold())
        hb.bind("<FocusOut>", lambda ev: self._commit_hold())
        tk.Label(fbar, text="frames/step", bg=BAR, fg="#888").pack(side="left", padx=(2, 0))

        self.play_btn = tk.Button(fbar, text="Play", width=6, command=self._toggle_play)
        self.play_btn.pack(side="left", padx=(12, 4))

        mid = tk.Frame(self, bg=BG)
        mid.pack(side="top", fill="both", expand=True, padx=8, pady=4)

        left = tk.Frame(mid, bg=BG)
        left.pack(side="left", fill="both", expand=True)
        tk.Label(left, text="Edit (drag a handle; double-click an edge to add a vertex; "
                             "select + Delete to remove)  -  wheel zooms, middle drag pans, f fits",
                 bg=BG, fg="#888").pack(anchor="w")
        self.edit_canvas = tk.Canvas(left, bg=BG, highlightthickness=0, takefocus=1)
        self.edit_canvas.pack(fill="both", expand=True)
        self.edit_canvas.bind("<Configure>", lambda e: self._draw_edit())
        self.edit_canvas.bind("<ButtonPress-1>", self._edit_press)
        self.edit_canvas.bind("<B1-Motion>", self._edit_drag)
        self.edit_canvas.bind("<ButtonRelease-1>", self._edit_release)
        self.edit_canvas.bind("<Double-Button-1>", self._edit_dblclick)
        self.edit_canvas.bind("<Delete>", self._delete_selected)
        self.edit_canvas.bind("<BackSpace>", self._delete_selected)
        self.edit_canvas.bind("<Control-a>", lambda ev: self._select_all(whole=True))
        self.edit_canvas.bind("<Control-A>", lambda ev: self._select_all(whole=False))
        for key, (dx, dy) in (("Left", (-1, 0)), ("Right", (1, 0)),
                              ("Up", (0, -1)), ("Down", (0, 1))):
            self.edit_canvas.bind(f"<{key}>",
                                  lambda ev, d=(dx, dy): self._nudge(*d))
            self.edit_canvas.bind(f"<Shift-{key}>",
                                  lambda ev, d=(dx, dy): self._nudge(8 * d[0], 8 * d[1]))
        self.edit_canvas.bind("<MouseWheel>", self._on_wheel)
        self.edit_canvas.bind("<Button-4>", lambda ev: self._zoom_at(ev.x, ev.y, 1.1))
        self.edit_canvas.bind("<Button-5>", lambda ev: self._zoom_at(ev.x, ev.y, 1 / 1.1))
        self.edit_canvas.bind("<ButtonPress-2>", self._pan_press)
        self.edit_canvas.bind("<B2-Motion>", self._pan_drag)
        self.edit_canvas.bind("<ButtonRelease-2>", lambda ev: self._pan_end())
        self.edit_canvas.bind("<KeyPress-f>", lambda ev: self._fit_view())

        right = tk.Frame(mid, bg=BG, width=320)
        right.pack(side="left", fill="y", padx=(10, 0))
        right.pack_propagate(False)

        whole_row = tk.Frame(right, bg=BG)
        whole_row.pack(fill="x", pady=(0, 4))
        tk.Button(whole_row, text="Select whole enemy (ctrl+A)",
                  command=lambda: self._select_all(whole=True)).pack(side="left", padx=2)
        tk.Button(whole_row, text="Offset all frames...",
                  command=self._offset_all_frames).pack(side="left", padx=2)

        zoom_row = tk.Frame(right, bg=BG)
        zoom_row.pack(fill="x", pady=(0, 4))
        tk.Label(zoom_row, text="View:", bg=BG, fg="#888").pack(side="left")
        tk.Button(zoom_row, text="-", width=2, command=lambda: self._zoom_centre(1 / 1.25)).pack(side="left", padx=2)
        tk.Button(zoom_row, text="+", width=2, command=lambda: self._zoom_centre(1.25)).pack(side="left", padx=2)
        tk.Button(zoom_row, text="Fit (f)", command=self._fit_view).pack(side="left", padx=6)
        self.zoom_label = tk.Label(zoom_row, text="", bg=BG, fg="#666")
        self.zoom_label.pack(side="left")

        disc_row = tk.Frame(right, bg=BG)
        disc_row.pack(fill="x", pady=(0, 6))
        tk.Label(disc_row, text="Collision R", bg=BG, fg=DISC_COLOR).pack(side="left")
        self.rad_var = tk.StringVar()
        re_ = tk.Entry(disc_row, textvariable=self.rad_var, width=5)
        re_.pack(side="left", padx=(4, 2))
        re_.bind("<Return>", lambda ev: self._commit_radius())
        re_.bind("<FocusOut>", lambda ev: self._commit_radius())
        self.rad_px = tk.Label(disc_row, text="", bg=BG, fg="#666")
        self.rad_px.pack(side="left", padx=(2, 6))
        tk.Button(disc_row, text="from shape", command=self._radius_from_shape).pack(side="left")

        tk.Label(right, text="Parts - TICK to grab a part's handles, radio picks "
                                "the one the buttons act on",
                 bg=BG, fg="#888", wraplength=310, justify="left").pack(anchor="w")
        self.cur_part_var = tk.IntVar(value=0)
        self.tick_vars, self.part_labels = [], []
        self.part_rows = tk.Frame(right, bg="#181d24")
        self.part_rows.pack(fill="x", pady=(0, 2))
        tick_row = tk.Frame(right, bg=BG)
        tick_row.pack(fill="x", pady=(0, 4))
        tk.Button(tick_row, text="tick all", command=lambda: self._tick_all(True)).pack(side="left", padx=2)
        tk.Button(tick_row, text="none", command=lambda: self._tick_all(False)).pack(side="left", padx=2)

        part_btns = tk.Frame(right, bg=BG)
        part_btns.pack(fill="x", pady=(0, 2))
        tk.Button(part_btns, text="+ Closed part", command=self._add_closed).pack(side="left", padx=2)
        tk.Button(part_btns, text="+ Open part", command=self._add_open).pack(side="left", padx=2)
        part_btns2 = tk.Frame(right, bg=BG)
        part_btns2.pack(fill="x", pady=(0, 2))
        tk.Button(part_btns2, text="Toggle closed/open", command=self._toggle_closed).pack(side="left", padx=2)
        tk.Button(part_btns2, text="Delete part", command=self._delete_part).pack(side="left", padx=2)
        move_btns = tk.Frame(right, bg=BG)
        move_btns.pack(fill="x", pady=(0, 2))
        tk.Button(move_btns, text="Move up", command=lambda: self._move_part(-1)).pack(side="left", padx=2)
        tk.Button(move_btns, text="Move down", command=lambda: self._move_part(1)).pack(side="left", padx=2)
        tk.Button(move_btns, text="Copy from frame...", command=self._copy_part_from).pack(side="left", padx=2)
        absent_row = tk.Frame(right, bg=BG)
        absent_row.pack(fill="x", pady=(0, 2))
        self.absent_btn = tk.Button(absent_row, text="Absent in this frame",
                                     command=self._toggle_absent)
        self.absent_btn.pack(side="left", padx=2)

        self.wreck_var = tk.IntVar(value=1)
        tk.Checkbutton(right, text="flies off as a wreck piece (EN_*_PW)", variable=self.wreck_var,
                       bg=BG, fg="white", selectcolor="#181d24", activebackground=BG,
                       activeforeground="white", command=self._commit_wreck).pack(anchor="w", pady=(2, 6))

        circle_frame = tk.Frame(right, bg=BG)
        circle_frame.pack(fill="x", pady=(0, 6))
        tk.Label(circle_frame, text="Make regular polygon (circle):", bg=BG, fg="white").pack(anchor="w")
        cr = tk.Frame(circle_frame, bg=BG)
        cr.pack(fill="x", pady=2)
        tk.Label(cr, text="R", bg=BG, fg="white").pack(side="left")
        self.circ_r_var = tk.StringVar(value="12")
        tk.Entry(cr, textvariable=self.circ_r_var, width=5).pack(side="left", padx=(2, 10))
        tk.Label(cr, text="sides", bg=BG, fg="white").pack(side="left")
        self.circ_n_var = tk.StringVar(value="8")
        tk.Entry(cr, textvariable=self.circ_n_var, width=5).pack(side="left", padx=2)
        tk.Button(circle_frame, text="Apply to selected part",
                  command=self._make_regular_polygon).pack(anchor="w", pady=(4, 0))

        sel_frame = tk.Frame(right, bg=BG)
        sel_frame.pack(fill="x", pady=6)
        self.sel_label = tk.Label(sel_frame, text="No handle selected", bg=BG, fg="#888")
        self.sel_label.grid(row=0, column=0, columnspan=4, sticky="w", pady=(0, 2))
        tk.Label(sel_frame, text="X", bg=BG, fg="white").grid(row=1, column=0, sticky="w")
        self.selx_var = tk.StringVar()
        ex = tk.Entry(sel_frame, textvariable=self.selx_var, width=6)
        ex.grid(row=1, column=1, padx=(4, 12))
        ex.bind("<Return>", lambda ev: self._commit_sel_point())
        ex.bind("<FocusOut>", lambda ev: self._commit_sel_point())
        tk.Label(sel_frame, text="Y", bg=BG, fg="white").grid(row=1, column=2, sticky="w")
        self.sely_var = tk.StringVar()
        ey = tk.Entry(sel_frame, textvariable=self.sely_var, width=6)
        ey.grid(row=1, column=3, padx=4)
        ey.bind("<Return>", lambda ev: self._commit_sel_point())
        ey.bind("<FocusOut>", lambda ev: self._commit_sel_point())

        self.preview_title = tk.Label(right, text="Preview (1:1 full-res)", bg=BG, fg="#888")
        self.preview_title.pack(anchor="w", pady=(8, 0))
        self.preview = tk.Canvas(right, bg=BG, height=170, highlightthickness=1, highlightbackground=GRID)
        self.preview.pack(fill="x", pady=(0, 6))
        self.preview.bind("<Configure>", lambda e: self._draw_preview())

        self.warn_label = tk.Label(right, text="", bg=BG, fg="#ff6666", wraplength=300, justify="left")
        self.warn_label.pack(fill="x", pady=4)

        self.status = tk.Label(self, text="", bg=BG, fg="#888", anchor="w")
        self.status.pack(side="bottom", fill="x", padx=8, pady=4)

    # ---- enemy management --------------------------------------------------
    def _refresh_enemy_menu(self):
        names = [e.name for e in self.model.enemies]
        self.enemy_menu.configure(values=names)
        if self.cur_enemy_i is not None and names:
            self.enemy_var.set(names[self.cur_enemy_i])
        else:
            self.enemy_var.set("")

    def _new_enemy(self):
        existing = {e.name for e in self.model.enemies}
        raw = simpledialog.askstring("New enemy", "Name:", parent=self)
        if raw is None:
            return
        name = sanitize_name(raw, existing)
        self.model.enemies.append(Enemy(name))
        self.cur_enemy_i = len(self.model.enemies) - 1
        self.cur_frame_i = 0
        self.cur_part_i = 0
        self._clear_sel()
        self.play_step = 0
        self.dirty = True
        self._refresh_enemy_menu()
        self._fit_view()

    def _dup_enemy(self):
        """A whole copy - frames, parts, playlist, hold and radius. How a
        second APPEARANCE of the same enemy starts: one behaviour KIND in
        foes.s can wear two of these (the spider on its rock and the spider
        adrift), and they need their own playlists and their own circles."""
        e = self._enemy()
        if e is None:
            return
        existing = {x.name for x in self.model.enemies}
        raw = simpledialog.askstring("Duplicate enemy", "Name for the copy:",
                                      initialvalue=f"{e.name}_COPY", parent=self)
        if raw is None:
            return
        clone = Enemy(sanitize_name(raw, existing),
                      [[q.copy() for q in f] for f in e.frames],
                      list(e.order), e.hold, e.radius)
        self.model.enemies.insert(self.cur_enemy_i + 1, clone)
        self.cur_enemy_i += 1
        self.cur_frame_i = 0
        self.cur_part_i = 0
        self.play_step = 0
        self._clear_sel()
        self.dirty = True
        self._refresh_enemy_menu()
        self._refresh_all()
        self.status.configure(text=f"Duplicated {e.name} as {clone.name} - "
                                   f"{clone.pn} parts x {clone.fn} frames.")

    def _rename_enemy(self):
        e = self._enemy()
        if e is None:
            return
        existing = {x.name for x in self.model.enemies if x is not e}
        raw = simpledialog.askstring("Rename enemy", "Name:", initialvalue=e.name, parent=self)
        if raw is None:
            return
        e.name = sanitize_name(raw, existing)
        self.dirty = True
        self._refresh_enemy_menu()
        self._update_status()

    def _delete_enemy(self):
        e = self._enemy()
        if e is None:
            return
        if not messagebox.askyesno("Delete enemy", f"Delete '{e.name}' and all its parts?"):
            return
        del self.model.enemies[self.cur_enemy_i]
        self.cur_enemy_i = 0 if self.model.enemies else None
        self.cur_frame_i = 0
        self.cur_part_i = 0 if self.model.enemies else None
        self._clear_sel()
        self.play_step = 0
        self.dirty = True
        self._refresh_enemy_menu()
        self._fit_view()

    def _on_enemy_change(self, _evt=None):
        names = [e.name for e in self.model.enemies]
        self.cur_enemy_i = names.index(self.enemy_var.get())
        self.cur_frame_i = 0
        self.cur_part_i = 0 if self._enemy().pn else None
        self._clear_sel()
        self.play_step = 0
        self._fit_view()                # a different enemy is a different size

    # ---- frames ------------------------------------------------------------
    def _step_frame(self, d):
        e = self._enemy()
        if e is None:
            return
        self.cur_frame_i = (self.cur_frame_i + d) % e.fn
        self._clear_sel()
        self._refresh_all()             # the VIEW is untouched: the zoom survives

    def _dup_frame(self):
        e = self._enemy()
        if e is None:
            return
        e.frames.insert(self.cur_frame_i + 1,
                        [p.copy() for p in e.parts_of(self.cur_frame_i)])
        self.cur_frame_i += 1
        self._clear_sel()
        self.dirty = True
        self._refresh_all()

    def _delete_frame(self):
        e = self._enemy()
        if e is None:
            return
        if e.fn <= 1:
            messagebox.showinfo("Delete frame", "An enemy needs at least one frame.")
            return
        gone = self.cur_frame_i
        del e.frames[gone]
        e.order = [f - 1 if f > gone else f for f in e.order if f != gone] or [0]
        self.cur_frame_i = min(gone, e.fn - 1)
        self._clear_sel()
        self.play_step = 0
        self.dirty = True
        self._refresh_all()

    def _move_frame(self, d):
        e = self._enemy()
        if e is None:
            return
        i, j = self.cur_frame_i, self.cur_frame_i + d
        if j < 0 or j >= e.fn:
            return
        e.frames[i], e.frames[j] = e.frames[j], e.frames[i]
        e.order = [j if f == i else i if f == j else f for f in e.order]
        self.cur_frame_i = j
        self.dirty = True
        self._refresh_all()

    def _commit_order(self):
        e = self._enemy()
        if e is None:
            return
        toks = [t for t in re.split(r'[^0-9]+', self.order_var.get()) if t]
        order = [int(t) for t in toks if int(t) < e.fn]
        if not order:
            self._refresh_order_field()
            return
        if order != e.order:
            e.order = order
            self.dirty = True
        self.play_step = 0
        self._refresh_all()

    def _preset_order(self, kind):
        e = self._enemy()
        if e is None:
            return
        if kind == "loop":
            order = list(range(e.fn))
        else:
            order = list(range(e.fn)) + list(range(e.fn - 2, 0, -1))
        e.order = order or [0]
        self.play_step = 0
        self.dirty = True
        self._refresh_all()

    def _commit_hold(self):
        e = self._enemy()
        if e is None:
            return
        try:
            held = int(self.hold_var.get())
        except ValueError:
            self._refresh_order_field()
            return
        held = max(1, min(255, held))
        if held != e.hold:
            e.hold = held
            self.dirty = True
        self._refresh_order_field()
        self._update_status()

    # ---- the collision circle ------------------------------------------------
    def _commit_radius(self):
        e = self._enemy()
        if e is None:
            return
        try:
            r = int(self.rad_var.get())
        except ValueError:
            self._refresh_radius_field()
            return
        r = max(1, min(127, r))
        if r != e.radius:
            e.radius = r
            self.dirty = True
        self._refresh_radius_field()
        self._draw_edit()
        self._draw_preview()
        self._update_status()

    def _radius_from_shape(self):
        e = self._enemy()
        if e is None:
            return
        e.radius = e.radius_from_shape()
        self.dirty = True
        self._refresh_radius_field()
        self._draw_edit()
        self._draw_preview()

    def _refresh_radius_field(self):
        e = self._enemy()
        if e is None:
            self.rad_var.set("")
            self.rad_px.configure(text="")
            return
        self.rad_var.set(str(e.radius))
        self.rad_px.configure(text=f"units = {2 * e.radius} px")

    def _refresh_order_field(self):
        e = self._enemy()
        if e is None:
            self.order_var.set("")
            self.hold_var.set("")
            self.frame_label.configure(text="-/-")
            return
        self.order_var.set(",".join(str(f) for f in e.order))
        self.hold_var.set(str(e.hold))
        self.frame_label.configure(text=f"{self.cur_frame_i + 1}/{e.fn}")

    # ---- playback ----------------------------------------------------------
    def _toggle_play(self):
        if self.play_job is not None:
            self.after_cancel(self.play_job)
            self.play_job = None
            self.play_btn.configure(text="Play")
            self._draw_preview()
            return
        self.play_btn.configure(text="Pause")
        self.play_job = self.after(1, self._tick)

    def _tick(self):
        e = self._enemy()
        if e is None:
            self.play_job = None
            self.play_btn.configure(text="Play")
            return
        self._draw_preview()
        self.play_step = (self.play_step + 1) % len(e.order)
        ms = max(16, int(round(e.hold * 1000.0 / FPS)))
        self.play_job = self.after(ms, self._tick)

    # ---- part management --------------------------------------------------
    def _refresh_part_list(self):
        """The part rows: a TICK BOX that selects the whole part's handles, and
        a radio that says which part the vertex-level buttons act on. Ticking
        is how a whole enemy gets dragged in one go - tick every part, then
        drag any handle - and the box is a view of the selection as much as a
        command, so it is ticked exactly while all of that part's handles are
        selected."""
        parts = self._frame_parts()
        if len(self.tick_vars) != len(parts):
            for w in self.part_rows.winfo_children():
                w.destroy()
            self.tick_vars = []
            self.part_labels = []
            for i in range(len(parts)):
                row = tk.Frame(self.part_rows, bg="#181d24")
                row.pack(fill="x")
                v = tk.IntVar(value=0)
                self.tick_vars.append(v)
                tk.Checkbutton(row, variable=v, bg="#181d24", activebackground="#181d24",
                               selectcolor="#101418", highlightthickness=0, bd=0,
                               command=lambda k=i: self._tick_part(k)).pack(side="left")
                lab = tk.Radiobutton(row, text="", variable=self.cur_part_var, value=i,
                                     bg="#181d24", fg="white", activebackground="#181d24",
                                     activeforeground="white", selectcolor="#101418",
                                     highlightthickness=0, bd=0, anchor="w",
                                     command=self._pick_part)
                lab.pack(side="left", fill="x", expand=True)
                self.part_labels.append(lab)

        for i, p in enumerate(parts):
            tag = "closed" if p.closed else "open"
            mark = "" if p.wreck else "   [cosmetic]"
            body = " - ABSENT here -" if p.absent() else f"({len(p.pts)} pts)"
            self.part_labels[i].configure(text=f"{i}: {tag} {body}{mark}")
            full = bool(p.pts) and all((i, vi) in self.sel for vi in range(len(p.pts)))
            self.tick_vars[i].set(1 if full else 0)

        if self.cur_part_i is not None and 0 <= self.cur_part_i < len(parts):
            self.cur_part_var.set(self.cur_part_i)
            self.wreck_var.set(1 if parts[self.cur_part_i].wreck else 0)
            self.absent_btn.configure(text="Draw it in this frame"
                                      if parts[self.cur_part_i].absent()
                                      else "Absent in this frame")

    def _tick_part(self, i):
        parts = self._frame_parts()
        if i >= len(parts):
            return
        want = bool(self.tick_vars[i].get())
        mine = {(i, vi) for vi in range(len(parts[i].pts))}
        self.sel = (self.sel | mine) if want else (self.sel - mine)
        if self.sel_idx not in self.sel:
            self.sel_idx = min(self.sel) if self.sel else None
        self._draw_edit()

    def _tick_all(self, want):
        parts = self._frame_parts()
        for i in range(len(parts)):
            self.tick_vars[i].set(1 if want else 0)
            self._tick_part(i)

    def _pick_part(self):
        """Which part the vertex-level buttons act on. It does NOT clear the
        selection - the ticks are the selection now, and losing them every
        time the current part changed was the tiresome part."""
        self.cur_part_i = self.cur_part_var.get()
        self._refresh_all()

    def _add_part(self, maker):
        e = self._enemy()
        if e is None:
            return
        for f in e.frames:              # a part exists in every frame or in none
            f.append(maker())
        self.cur_part_i = e.pn - 1
        self._clear_sel()
        self.dirty = True
        self._refresh_all()

    def _add_closed(self):
        self._add_part(Part.new_closed)

    def _add_open(self):
        self._add_part(Part.new_open)

    def _toggle_closed(self):
        e, p = self._enemy(), self._part()
        if e is None or p is None:
            return
        want = not p.closed
        if want and min(len(f[self.cur_part_i].pts) for f in e.frames) < 3:
            messagebox.showinfo("Toggle closed/open",
                                "Every frame needs at least 3 points to close this part.")
            return
        for f in e.frames:
            f[self.cur_part_i].closed = want
        self.dirty = True
        self._refresh_all()

    def _commit_wreck(self):
        e, p = self._enemy(), self._part()
        if e is None or p is None:
            return
        want = bool(self.wreck_var.get())
        for f in e.frames:
            f[self.cur_part_i].wreck = want
        self.dirty = True
        self._refresh_all()

    def _delete_part(self):
        e = self._enemy()
        if e is None or self.cur_part_i is None:
            return
        if e.pn <= 1:
            messagebox.showinfo("Delete part", "An enemy needs at least one part.")
            return
        for f in e.frames:
            del f[self.cur_part_i]
        self.cur_part_i = min(self.cur_part_i, e.pn - 1)
        self._clear_sel()
        self.dirty = True
        self._refresh_all()

    def _move_part(self, d):
        e = self._enemy()
        if e is None or self.cur_part_i is None:
            return
        i, j = self.cur_part_i, self.cur_part_i + d
        if j < 0 or j >= e.pn:
            return
        for f in e.frames:
            f[i], f[j] = f[j], f[i]
        self.cur_part_i = j
        self.dirty = True
        self._refresh_all()

    def _toggle_absent(self):
        """An OPEN part drops to ONE vertex in this frame and the GPU draws
        nothing for it - the cheapest way to have a line in the last frame and
        not in the first three. The geometry is not kept anywhere: coming back
        copies it from the first frame that still draws the part, which is the
        way it is authored anyway (draw it once, mark it absent elsewhere)."""
        e, p = self._enemy(), self._part()
        if e is None or p is None:
            return
        if p.closed:
            messagebox.showinfo("Absent in this frame",
                                "Only an OPEN part can be absent: a closed one with a single "
                                "vertex still draws its closing edge v0 -> v0, which is one lit "
                                "pixel. Toggle the part open first, or give it its own frames.")
            return
        i = self.cur_part_i
        if len(p.pts) >= 2:
            p.pts = [p.pts[0]]
        else:
            src = next((f for f in e.frames if len(f[i].pts) >= 2), None)
            if src is not None:
                p.pts = list(src[i].pts)
            else:
                x, y = p.pts[0]
                p.pts = [(x, y), (clamp_vertex(x + 8), y)]
        self._clear_sel()
        self.dirty = True
        self._refresh_all()

    def _copy_part_from(self):
        """Pull the selected part's outline out of another FRAME - how a frame
        that only moves one part is usually built."""
        e, p = self._enemy(), self._part()
        if e is None or p is None or e.fn < 2:
            return
        raw = simpledialog.askstring("Copy part from frame",
                                     f"Frame 0..{e.fn - 1} to copy part "
                                     f"{self.cur_part_i} from:", parent=self)
        if raw is None:
            return
        try:
            src = int(raw)
        except ValueError:
            return
        if not (0 <= src < e.fn) or src == self.cur_frame_i:
            return
        p.pts = list(e.frames[src][self.cur_part_i].pts)
        self._clear_sel()
        self.dirty = True
        self._refresh_all()

    def _make_regular_polygon(self):
        p = self._part()
        if p is None:
            return
        try:
            r = int(self.circ_r_var.get())
            n = int(self.circ_n_var.get())
        except ValueError:
            return
        r = max(1, min(VERTEX_MAX, r))
        n = max(3, min(32, n))
        pts = []
        for i in range(n):
            a = 2 * math.pi * i / n
            pts.append((round(r * math.cos(a)), round(r * math.sin(a))))
        p.pts = pts
        p.closed = True
        self._clear_sel()
        self.dirty = True
        self._refresh_all()

    # ---- the view -----------------------------------------------------------
    def _all_pts(self):
        """Every point of every FRAME - so Fit frames the whole animation and
        stepping through frames never wants a different view."""
        e = self._enemy()
        pts = []
        if e:
            for f in e.frames:
                for p in f:
                    pts += p.pts
        return pts

    def _fit_scale(self):
        w = self.edit_canvas.winfo_width() or 400
        h = self.edit_canvas.winfo_height() or 400
        pts = self._all_pts()
        span = max([abs(x) for x, y in pts] + [abs(y) for x, y in pts] + [4])
        return max(ZOOM_MIN, min(ZOOM_MAX, 0.85 * min(w, h) / 2 / span))

    def _fit_view(self):
        self.view_scale = self._fit_scale()
        self.view_ox = 0.0
        self.view_oy = 0.0
        self._refresh_all()

    def _edit_transform(self):
        w = self.edit_canvas.winfo_width() or 400
        h = self.edit_canvas.winfo_height() or 400
        if self.view_scale is None:
            if w < 50 or h < 50:        # no layout yet: fit, but do NOT cache -
                return w / 2, h / 2, self._fit_scale()   #   it would stick at
            self.view_scale = self._fit_scale()          #   the zoom floor
        return w / 2 + self.view_ox, h / 2 + self.view_oy, self.view_scale

    def _zoom_at(self, mx, my, factor):
        cx, cy, scale = self._edit_transform()
        new = max(ZOOM_MIN, min(ZOOM_MAX, scale * factor))
        if new == scale:
            return
        vx, vy = (mx - cx) / scale, (my - cy) / scale    # keep what is under
        self.view_ox += (mx - vx * new) - cx            #   the cursor there
        self.view_oy += (my - vy * new) - cy
        self.view_scale = new
        self._draw_edit()
        self._update_zoom_label()

    def _zoom_centre(self, factor):
        w = self.edit_canvas.winfo_width() or 400
        h = self.edit_canvas.winfo_height() or 400
        self._zoom_at(w / 2, h / 2, factor)

    def _on_wheel(self, ev):
        self._zoom_at(ev.x, ev.y, 1.1 if ev.delta > 0 else 1 / 1.1)

    def _pan_press(self, ev):
        self._pan_from = (ev.x, ev.y)

    def _pan_drag(self, ev):
        if self._pan_from is None:
            return
        self.view_ox += ev.x - self._pan_from[0]
        self.view_oy += ev.y - self._pan_from[1]
        self._pan_from = (ev.x, ev.y)
        self._draw_edit()

    def _pan_end(self):
        self._pan_from = None

    def _update_zoom_label(self):
        _, _, scale = self._edit_transform()
        self.zoom_label.configure(text=f"{scale:.2f}x")

    def _to_canvas(self, cx, cy, scale, pt):
        vx, vy = to_view(pt)
        return cx + vx * scale, cy + vy * scale

    def _from_canvas(self, cx, cy, scale, x, y):
        return from_view((x - cx) / scale, (y - cy) / scale)

    # ---- drawing --------------------------------------------------------
    def _refresh_all(self):
        self._refresh_enemy_menu()
        self._refresh_order_field()
        self._refresh_radius_field()
        self._refresh_part_list()
        self._draw_edit()
        self._draw_preview()
        self._update_zoom_label()
        self._update_status()

    def _update_status(self):
        e = self._enemy()
        star = "* " if self.dirty else ""
        which = e.name if e else "(no enemies)"
        extra = ""
        if e:
            extra = (f"  -  {e.pn} parts x {e.fn} frames, {len(e.order)} steps, "
                     f"{e.hold} frames a step, R{e.radius}")
        self.status.configure(text=f"{star}{which}{extra}  -  {self.path}")

    def _draw_edit(self):
        c = self.edit_canvas
        c.delete("all")
        w = c.winfo_width() or 400
        h = c.winfo_height() or 400
        cx, cy, scale = self._edit_transform()
        step = 16 if scale > 1.2 else 32
        for g in range(-256, 257, step):
            x = cx + g * scale
            if 0 <= x <= w:
                c.create_line(x, 0, x, h, fill=GRID)
            y = cy + g * scale
            if 0 <= y <= h:
                c.create_line(0, y, w, y, fill=GRID)
        lim = VERTEX_MAX * scale        # the signed-byte ceiling, drawn
        c.create_rectangle(cx - lim, cy - lim, cx + lim, cy + lim,
                           outline=LIMIT_COLOR, dash=(3, 3))
        c.create_line(cx, 0, cx, h, fill="#3a4552")
        c.create_line(0, cy, w, cy, fill="#3a4552")
        c.create_oval(cx - 3, cy - 3, cx + 3, cy + 3, outline="#556", width=1)  # shared anchor

        e = self._enemy()
        if e is None:
            self._refresh_sel_fields()
            return

        # the collision circle - full-res px, so twice the stored collision units
        cr = 2 * e.radius * scale
        c.create_oval(cx - cr, cy - cr, cx + cr, cy + cr, outline=DISC_COLOR, dash=(4, 3))

        if self.onion_var.get() and e.fn > 1:
            for p in e.parts_of((self.cur_frame_i - 1) % e.fn):
                self._draw_part(c, cx, cy, scale, p, False, color=ONION_COLOR)

        for i, p in enumerate(self._frame_parts()):
            self._draw_part(c, cx, cy, scale, p, i == self.cur_part_i, pi=i)

        if self._band is not None:
            c.create_rectangle(*self._band, outline=SEL_COLOR, dash=(2, 2))

        self._refresh_sel_fields()
        self._refresh_part_list()       # the ticks follow the selection
        self._refresh_warnings()

    def _refresh_warnings(self):
        e = self._enemy()
        msgs = []
        if e is not None:
            p = self._part()
            if p:
                bad = [i for i, (x, y) in enumerate(p.pts)
                       if abs(x) > VERTEX_MAX or abs(y) > VERTEX_MAX]
                if bad:
                    msgs.append(f"Point {bad} exceeds |v|<=127 - the offset would not fit a "
                                f"signed byte on the wire.")
            if not e.wreck_ok():
                msgs.append("The wreck parts have to be the LEADING ones - EN_*_PW is a count, "
                            "not a flag per part. Move the cosmetic parts to the end.")
            gone = [i for i in range(e.pn)
                    if all(f[i].absent() for f in e.frames)]
            if gone:
                msgs.append(f"Part {gone} is absent from EVERY frame - it draws nothing "
                            f"anywhere and still costs a command a frame. Delete it, or "
                            f"draw it in the frame it belongs to.")
        self.warn_label.configure(text="\n".join(msgs))

    def _draw_part(self, c, cx, cy, scale, p, selected, color=None, pi=None):
        if color is None:
            base_color = CLOSED_COLOR if p.closed else OPEN_COLOR
            color = base_color if selected else DIM_COLOR
        poly = []
        for pt in p.pts:
            poly += list(self._to_canvas(cx, cy, scale, pt))
        if len(p.pts) >= 2:
            if p.closed:
                c.create_polygon(*poly, outline=color, fill="", width=2 if selected else 1)
            else:
                c.create_line(*poly, fill=color, width=2 if selected else 1)
        # Handles: every vertex of the SELECTED part, and - because the
        # selection now spans parts - the picked vertices of any other part
        # too, so a whole-enemy drag shows what it has hold of.
        if pi is None or (not selected and pi not in {q for q, _ in self.sel}):
            return
        for i, pt in enumerate(p.pts):
            picked = (pi, i) in self.sel
            if not selected and not picked:
                continue
            x, y = self._to_canvas(cx, cy, scale, pt)
            r = 6 if (pi, i) == self.sel_idx else (5 if picked else 4)
            fill = SEL_COLOR if picked else POINT_COLOR
            c.create_oval(x - r, y - r, x + r, y + r, fill=fill, outline="")
            if selected:
                c.create_text(x + 10, y - 10, text=str(i), fill="#666", font=("Consolas", 8))

    def _draw_preview(self):
        c = self.preview
        c.delete("all")
        w = c.winfo_width() or 300
        h = c.winfo_height() or 170
        cx, cy = w / 2, h / 2
        e = self._enemy()
        if e is None:
            self.preview_title.configure(text="Preview (1:1 full-res)")
            return
        if self.play_job is not None:
            step = self.play_step % len(e.order)
            shown = e.order[step]
            self.preview_title.configure(
                text=f"Preview 1:1  -  step {step + 1}/{len(e.order)}, frame {shown}")
        else:
            shown = self.cur_frame_i
            self.preview_title.configure(text=f"Preview 1:1  -  frame {shown} (paused)")
        cr = 2 * e.radius
        c.create_oval(cx - cr, cy - cr, cx + cr, cy + cr, outline=DISC_COLOR, dash=(4, 3))
        for p in e.parts_of(shown):
            poly = []
            for pt in p.pts:
                vx, vy = to_view(pt)
                poly += [cx + vx, cy + vy]
            color = CLOSED_COLOR if p.closed else OPEN_COLOR
            if len(p.pts) >= 2:
                if p.closed:
                    c.create_polygon(*poly, outline=color, fill="", width=1)
                else:
                    c.create_line(*poly, fill=color, width=1)

    # ---- the selection -------------------------------------------------------
    # A selected handle is a (PART, VERTEX) pair, not a bare index: moving a
    # whole enemy off its anchor - which is how a shape is mounted on something
    # else's centre, the spider on its rock - means dragging every part at
    # once, and doing that part by part is the one thing this editor was
    # genuinely tiresome at.
    def _clear_sel(self):
        self.sel = set()
        self.sel_idx = None                # (part, vertex): what X/Y edits
        self._band = None
        self._drag = None

    def _sel_by_part(self):
        out = {}
        for pi, vi in self.sel:
            out.setdefault(pi, set()).add(vi)
        return out

    def _select_all(self, whole=True):
        """ctrl+A takes the WHOLE enemy - every vertex of every part in this
        frame. ctrl+shift+A stays inside the selected part."""
        if self._enemy() is None:
            return "break"
        parts = self._frame_parts()
        if whole:
            self.sel = {(pi, vi) for pi, pp in enumerate(parts)
                        for vi in range(len(pp.pts))}
        elif self.cur_part_i is not None and self.cur_part_i < len(parts):
            self.sel = {(self.cur_part_i, vi)
                        for vi in range(len(parts[self.cur_part_i].pts))}
        self.sel_idx = min(self.sel) if self.sel else None
        self._draw_edit()
        return "break"

    def _move_sel(self, dx, dy):
        """Translate every selected handle RIGIDLY, across parts. The |v| <= 127
        ceiling is applied to the DELTA, not to each point - clamping the points
        one by one would let the outermost one stick while the rest kept going,
        which deforms the shape instead of stopping it."""
        if not self.sel or self._drag is None:
            return
        parts = self._frame_parts()
        _, _, orig = self._drag
        live = [k for k in self.sel if k in orig]
        if not live:
            return
        xs = [orig[k][0] for k in live]
        ys = [orig[k][1] for k in live]
        dx = max(-VERTEX_MAX - min(xs), min(VERTEX_MAX - max(xs), dx))
        dy = max(-VERTEX_MAX - min(ys), min(VERTEX_MAX - max(ys), dy))
        for pi, vis in self._sel_by_part().items():
            if pi >= len(parts):
                continue
            pts = list(parts[pi].pts)
            for vi in vis:
                if (pi, vi) in orig:
                    pts[vi] = (orig[(pi, vi)][0] + dx, orig[(pi, vi)][1] + dy)
            parts[pi].pts = pts
        self.dirty = True

    def _grab(self, wx=0.0, wy=0.0):
        """Snapshot the selected points, so a drag's delta always measures from
        where the press was and never accumulates rounding."""
        parts = self._frame_parts()
        self._drag = (wx, wy, {(pi, vi): parts[pi].pts[vi] for pi, vi in self.sel
                               if pi < len(parts) and vi < len(parts[pi].pts)})

    def _nudge(self, px, py):
        """Arrow keys, in the PLAYER's axes: +x is right on screen, +y is down.
        The stored axes are the quarter turn of that (see the module docstring),
        so a step right is a step DOWN the stored dy."""
        if not self.sel:
            return "break"
        self._grab()
        self._move_sel(py, -px)
        self._drag = None
        self._draw_edit()
        self._draw_preview()
        return "break"

    def _offset_all_frames(self):
        """Shift the WHOLE enemy - every part, in EVERY frame - by a typed
        amount. This is the one that mounts a shape on someone else's anchor:
        POLYGON16 rotates the offsets about the anchor, so an enemy authored
        60 px off centre rides the rim of whatever it is anchored to, spinning
        with it, for no CPU1 work at all. Doing that by hand, frame by frame
        and part by part, is how it used to have to be done."""
        e = self._enemy()
        if e is None:
            return
        raw = simpledialog.askstring(
            "Offset every frame",
            "Shift the whole enemy by dx,dy in the PLAYER's axes\n"
            "(+x right, +y down), every part in every frame:",
            initialvalue="60,0", parent=self)
        if not raw:
            return
        try:
            sx, sy = (int(v) for v in re.split(r'[,\s]+', raw.strip())[:2])
        except ValueError:
            return
        dx, dy = from_view(sx, sy)
        pts = [q for f in e.frames for pp in f for q in pp.pts]
        if not pts:
            return
        lo_x, hi_x = min(x for x, _ in pts), max(x for x, _ in pts)
        lo_y, hi_y = min(y for _, y in pts), max(y for _, y in pts)
        dx = max(-VERTEX_MAX - lo_x, min(VERTEX_MAX - hi_x, dx))
        dy = max(-VERTEX_MAX - lo_y, min(VERTEX_MAX - hi_y, dy))
        if not dx and not dy:
            messagebox.showinfo("Offset every frame",
                                "That would push a vertex past |v| <= 127, so nothing moved.")
            return
        for f in e.frames:
            for pp in f:
                pp.pts = [(x + dx, y + dy) for x, y in pp.pts]
        self._clear_sel()
        self.dirty = True
        self._refresh_all()
        self.status.configure(text=f"Offset {e.name} by {to_view((dx, dy))} "
                                   f"in the player's axes, in all {e.fn} frames.")

    # ---- edit-canvas interaction -------------------------------------------
    def _handle_parts(self):
        """Which parts show draggable handles: the selected one, plus any part
        that already has a handle in the selection."""
        got = {pi for pi, _ in self.sel}
        if self.cur_part_i is not None:
            got.add(self.cur_part_i)
        return got

    def _hit_test(self, x, y):
        parts = self._frame_parts()
        cx, cy, scale = self._edit_transform()
        order = ([self.cur_part_i] if self.cur_part_i is not None else [])
        order += sorted(self._handle_parts() - set(order))
        for pi in order:
            if pi is None or pi >= len(parts):
                continue
            for vi, pt in enumerate(parts[pi].pts):
                px, py = self._to_canvas(cx, cy, scale, pt)
                if (px - x) ** 2 + (py - y) ** 2 <= 100:
                    return (pi, vi)
        return None

    def _edit_press(self, ev):
        self.edit_canvas.focus_set()
        hit = self._hit_test(ev.x, ev.y)
        shift = bool(ev.state & 0x0001)
        self._band = None
        self._drag = None
        if hit is None:
            if not shift:
                self.sel = set()
                self.sel_idx = None
            self._band = (ev.x, ev.y, ev.x, ev.y)    # rubber band from here
        else:
            if shift:
                self.sel.symmetric_difference_update({hit})
            elif hit not in self.sel:
                self.sel = {hit}
            self.sel_idx = hit if hit in self.sel else None
            if self.sel:
                cx, cy, scale = self._edit_transform()
                self._grab(*self._from_canvas(cx, cy, scale, ev.x, ev.y))
        self._draw_edit()

    def _edit_drag(self, ev):
        if self._band is not None:
            self._band = (self._band[0], self._band[1], ev.x, ev.y)
            self._draw_edit()
            return
        if self._drag is None:
            return
        cx, cy, scale = self._edit_transform()
        wx, wy = self._from_canvas(cx, cy, scale, ev.x, ev.y)
        wx0, wy0, _ = self._drag
        self._move_sel(int(round(wx - wx0)), int(round(wy - wy0)))
        self._draw_edit()
        self._draw_preview()

    def _edit_release(self, ev):
        if self._band is not None:
            x0, y0, x1, y1 = self._band
            self._band = None
            if abs(x1 - x0) > 3 or abs(y1 - y0) > 3:
                self._select_in_band(x0, y0, x1, y1,
                                     add=bool(ev.state & 0x0001),
                                     every=bool(ev.state & 0x0004))
            self._draw_edit()
        self._drag = None
        self._update_status()

    def _select_in_band(self, x0, y0, x1, y1, add=False, every=False):
        """A plain band stays in the selected part; ctrl+band sweeps every part,
        which is the quick way to grab a whole enemy whose parts sit off to one
        side of the anchor."""
        parts = self._frame_parts()
        lo_x, hi_x = min(x0, x1), max(x0, x1)
        lo_y, hi_y = min(y0, y1), max(y0, y1)
        cx, cy, scale = self._edit_transform()
        which = list(range(len(parts))) if every else \
            ([self.cur_part_i] if self.cur_part_i is not None else [])
        got = set()
        for pi in which:
            if pi is None or pi >= len(parts):
                continue
            for vi, pt in enumerate(parts[pi].pts):
                px, py = self._to_canvas(cx, cy, scale, pt)
                if lo_x <= px <= hi_x and lo_y <= py <= hi_y:
                    got.add((pi, vi))
        self.sel = (self.sel | got) if add else got
        self.sel_idx = min(self.sel) if self.sel else None

    def _edit_dblclick(self, ev):
        p = self._part()
        if p is None or len(p.pts) < 2:
            return
        cx, cy, scale = self._edit_transform()
        wx, wy = self._from_canvas(cx, cy, scale, ev.x, ev.y)
        pts = list(p.pts)
        n_edges = len(pts) if p.closed else len(pts) - 1
        best, best_d, best_at = None, None, None
        for i in range(n_edges):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
            d = (mx - wx) ** 2 + (my - wy) ** 2
            if best_d is None or d < best_d:
                best, best_d, best_at = (round(mx), round(my)), d, i + 1
        pts.insert(best_at, best)
        p.pts = pts
        self.sel = {(self.cur_part_i, best_at)}
        self.sel_idx = (self.cur_part_i, best_at)
        self.dirty = True
        self._draw_edit()
        self._draw_preview()

    def _delete_selected(self, _ev=None):
        """Delete across parts, and check EVERY part's own floor first - a
        selection that would take one part below three closed vertices must not
        half-apply and leave the others thinned."""
        parts = self._frame_parts()
        if not parts or not self.sel:
            return
        per = self._sel_by_part()
        under = []
        for pi, vis in per.items():
            if pi >= len(parts):
                continue
            pp = parts[pi]
            if len(pp.pts) - len(vis) < pp.min_pts():
                under.append(f"part {pi} ({'closed' if pp.closed else 'open'}) would drop "
                             f"to {len(pp.pts) - len(vis)}, floor is {pp.min_pts()}")
        if under:
            messagebox.showinfo("Minimum vertices", "Nothing deleted:\n" + "\n".join(under))
            return
        for pi, vis in per.items():
            if pi < len(parts):
                parts[pi].pts = [pt for vi, pt in enumerate(parts[pi].pts) if vi not in vis]
        self._clear_sel()
        self.dirty = True
        self._refresh_all()

    # ---- selected-handle fields ----------------------------------------------
    def _sel_point(self):
        """The one handle the X/Y fields edit, as (part, vertex), or None."""
        parts = self._frame_parts()
        if self.sel_idx is None:
            return None
        pi, vi = self.sel_idx
        if pi is None or pi >= len(parts) or vi >= len(parts[pi].pts):
            return None
        return pi, vi

    def _refresh_sel_fields(self):
        at = self._sel_point()
        if at is None:
            self.sel_label.configure(text="No handle selected")
            self.selx_var.set("")
            self.sely_var.set("")
            return
        pi, vi = at
        x, y = to_view(self._frame_parts()[pi].pts[vi])
        if len(self.sel) > 1:
            span = len(self._sel_by_part())
            self.sel_label.configure(
                text=f"{len(self.sel)} handles in {span} part(s) - a drag moves them "
                     f"together; X/Y edits part {pi} point {vi}")
        else:
            self.sel_label.configure(text=f"Part {pi}, point {vi} "
                                          f"(player's x/y from the anchor)")
        self.selx_var.set(str(x))
        self.sely_var.set(str(y))

    def _commit_sel_point(self):
        at = self._sel_point()
        if at is None:
            return
        try:
            x = int(self.selx_var.get())
            y = int(self.sely_var.get())
        except ValueError:
            self._refresh_sel_fields()
            return
        pi, vi = at
        pp = self._frame_parts()[pi]
        pts = list(pp.pts)
        pts[vi] = from_view(x, y)
        pp.pts = pts
        self.dirty = True
        self._draw_edit()
        self._draw_preview()

    # ---- file ops -----------------------------------------------------------
    def _copy_snippet(self):
        e = self._enemy()
        if e is None:
            return
        saved = render_generated(Model([e]))
        self.clipboard_clear()
        self.clipboard_append(saved)
        self.status.configure(text=f"Copied {e.name} to clipboard.")

    def _save(self):
        bad = []
        for e in self.model.enemies:
            if not e.frames or not e.pn:
                bad.append(f"{e.name}: no parts")
                continue
            if not e.wreck_ok():
                bad.append(f"{e.name}: the wreck parts are not the leading ones")
            for f in e.frames:
                for p in f:
                    if len(p.pts) > 0x7F:
                        bad.append(f"{e.name}: a part has more than 127 vertices")
                    if len(p.pts) < p.min_pts():
                        bad.append(f"{e.name}: a {'closed' if p.closed else 'open'} part is "
                                   f"below its {p.min_pts()}-vertex floor")
                    for x, y in p.pts:
                        if abs(x) > VERTEX_MAX or abs(y) > VERTEX_MAX:
                            bad.append(f"{e.name}: a point is past |v|<=127")
        if bad:
            messagebox.showerror("Cannot save", "Fix these before saving:\n" + "\n".join(sorted(set(bad))))
            return
        try:
            save_model(self.path, self.model)
        except ValueError as exc:          # a ragged frame grid - render_enemy
            messagebox.showerror("Cannot save", str(exc))
            return
        self.dirty = False
        self._update_status()
        self.status.configure(text=f"Saved {self.path}")

    def _reload(self):
        if self.dirty and not messagebox.askyesno("Reload", "Discard unsaved changes?"):
            return
        self.model = Model.load(self.path.read_text(encoding="utf-8"))
        self.cur_enemy_i = 0 if self.model.enemies else None
        self.cur_frame_i = 0
        self.cur_part_i = 0 if self.model.enemies else None
        self._clear_sel()
        self.play_step = 0
        self.dirty = False
        self._refresh_all()             # the view survives a reload too


def clamp_vertex(v):
    return max(-VERTEX_MAX, min(VERTEX_MAX, int(round(v))))


def main():
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_ENEMIES
    if not path.exists():
        print(f"no such file: {path}", file=sys.stderr)
        sys.exit(1)
    app = EnemyEditor(path)
    app.mainloop()


if __name__ == "__main__":
    main()
