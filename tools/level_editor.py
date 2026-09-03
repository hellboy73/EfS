#!/usr/bin/env python3
"""Level editor for EfS - reads and writes src/levels.s directly.

    python tools/level_editor.py [path/to/levels.s]

The companion to tools/shape_editor.py and deliberately the same tool in a
different space: only the GENERATED block in levels.s (between the sentinel
comments) is ever touched, and it is rewritten WHOLE on every Save - never
patched in place - so what comes back is always a clean, consistently formatted
file. Everything outside that block (the header prose) is left alone.

Where the shape editor works in one rock's local units, this works in WORLD
units: the whole 16-bit torus, 65536 units per axis, 16 units to a full-res
pixel, about 4096 x 4096 pixels or ~140 screens. The canvas is a window onto
that torus and the torus WRAPS, so panning off one edge simply keeps going -
there is no boundary to hit, because a 16-bit world coordinate has none (see
CLAUDE.md, "the wrap is free").

Two ways of showing how much of that world fits on a screen, both optional:

  * SCREEN FRAMES that follow the cursor - the framebuffer's own footprint in
    world units, drawn twice: solid for the resting zoom (RZ 128, 1:1) and
    dashed for the top-speed zoom-out, which is twice the ground. Hover
    anywhere and the frames say what would be on screen from there. They are
    turned to the level's start heading, because a screen that is 400 px one
    way and 300 the other is not a square and which way the long side points is
    the heading's business.
  * DASHED CIRCLES round the ship start - the same two rectangles' rotation
    sweep. The camera turns with the ship, so over a full turn the frame covers
    its own circumscribed circle; that circle is the honest answer to "what can
    reach the screen from here whatever way I am pointing".

A level's rocks come from two places and the editor shows both at once:

  * THE SCATTER - a count per size class, dropped at random positions by
    load_level (main.s) at start-up. These are drawn dim, and they cannot be
    selected or dragged, because they are not authored: they are a consequence
    of the five counts and the seed. What the editor CAN do is show you exactly
    which field a seed produces - it runs main.s's own LFSR, in main.s's own
    order - so a reroll is judged here rather than in the simulator.
  * THE PLACED ROCKS - drawn bright, dragged with the mouse, the set-pieces.

Enemies are placed the same way as rocks. Nothing reads them yet (the enemy
bench is the next one, and open_questions E6 has not settled the roster), so
the KIND byte is just a number for now; the positions are authored here so
that bench inherits a level format instead of inventing one.

Mouse: left-click selects, left-drag moves, double-click on empty space adds
one of whatever the Place panel is set to, Delete removes it. The wheel zooms
about the cursor and right-drag pans.
"""
import pathlib
import re
import string
import sys
import tkinter as tk
from tkinter import ttk, messagebox

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from shape_editor import parse_generated_block          # noqa: E402  same block shape

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The GAME's files, in src/ - see the note in shape_editor.py on why these
# stopped pointing at a bench.
DEFAULT_LEVELS = ROOT / "src" / "levels.s"
DEFAULT_SHAPES = ROOT / "src" / "shapes.s"
DEFAULT_MAIN = ROOT / "src" / "main.s"

SENTINEL_START = "; === GENERATED (tools/level_editor.py) - rewritten whole on Save ============="
SENTINEL_END = "; === END GENERATED ==="

CLASSES = [192, 128, 64, 32, 16]        # size-major, matches shapes.s and OBJSHP
CLASS_FIELD = ["LVL_N192", "LVL_N128", "LVL_N64", "LVL_N32", "LVL_N16"]

WORLD = 65536                           # units per axis. The whole point of 16
HALF = WORLD // 2                       #   bits: the wrap IS the overflow
UNITS_PER_PX = 16                       # world units to one full-res pixel
FOE_KINDS = 8                           # what fits in the editor's spinbox; the
                                        #   roster itself is open_questions E6

# The screen's footprint in world units, filled in from main.s at start-up by
# _read_screen so it cannot drift from the framebuffer the game actually has.
#
# The mapping (main.s, top of file) is fb_x = CX + vy and fb_y = CY - vx, so the
# half-extents are FBCY along the view's x axis and FBCX along its y axis - the
# frame is PORTRAIT in world space, which is what TATE means. The zoom-out
# factor is 128 / min(ZOOM_RZ): pulling the camera back shrinks everything on
# screen, so it grows the ground the screen covers by the same ratio.
SCREEN_HX = 149 * UNITS_PER_PX          # half-extent along the view x axis
SCREEN_HY = 200 * UNITS_PER_PX          # ...and the view y axis
ZOOM_OUT = 2.0                          # how much more ground at top speed

BG = "#101418"
GRID = "#1c242c"
AXIS = "#3a4552"
SCATTER_COLOR = "#3f6f8c"               # generated: dim, and not selectable
PLACED_COLOR = "#7fd0ff"                # authored: bright, and draggable
FOE_COLOR = "#ff8f5a"
SHIP_COLOR = "#8dff9a"
SEL_COLOR = "#ff5566"
VIEW_COLOR = "#2c3a46"                  # the ship's rotation-sweep circles
FRAME_COLOR = "#5c7f6b"                 # ...and the screen frames under the mouse
TEXT = "#c8d2dc"
DIM = "#7b8794"


# =============================================================================
# reading main.s and shapes.s - the numbers this editor has to agree with
# =============================================================================
def read_int(text, name, default):
    m = re.search(rf'^{name}\s*=\s*(\d+)', text, re.M)
    return int(m.group(1)) if m else default


def read_screen(path):
    """FBCX / FBCY and the widest zoom-out in ZOOM_RZ, straight out of main.s.
    Returns (half-extent along view x, along view y, zoom-out factor) in world
    units - see the note on SCREEN_HX above for which is which."""
    if not path.exists():
        return SCREEN_HX, SCREEN_HY, ZOOM_OUT
    text = path.read_text(encoding="utf-8")
    fbcx = read_int(text, "FBCX", 200)
    fbcy = read_int(text, "FBCY", 149)
    m = re.search(r'^ZOOM_RZ:\s*$(.*?)^\s*$', text, re.M | re.S)
    rz = [int(v) for v in re.findall(r'\d+', m.group(1).replace(';', '\n;').split(';')[0])] \
        if m else []
    lo = min(rz) if rz else 64
    return fbcy * UNITS_PER_PX, fbcx * UNITS_PER_PX, 128 / lo


def read_shapes(path):
    """(AST_TYPES, SHAPE_R by shape id). SHAPE_R is in HALF-res pixels, which is
    what shapes.s authors in; a rock's world radius is R * 2 * UNITS_PER_PX."""
    if not path.exists():
        return 3, [48] * 15
    scalars, blocks = parse_generated_block(path.read_text(encoding="utf-8"))
    at = scalars.get("AST_TYPES", 3)
    r = blocks.get("SHAPE_R") or [48, 32, 16, 8, 4]
    return at, r


def read_type_pick(path):
    """The eight tickets load_level draws a rock's variant with. Read, not
    assumed, because the preview has to match what the game will actually do."""
    if not path.exists():
        return [0, 1, 2, 0, 1, 2, 0, 1]
    m = re.search(r'^TYPE_PICK:\s*\.byte\s+(.*)$', path.read_text(encoding="utf-8"), re.M)
    if not m:
        return [0, 1, 2, 0, 1, 2, 0, 1]
    vals = [int(v) for v in re.findall(r'\d+', m.group(1).split(';')[0])]
    return (vals + [0] * 8)[:8]


def read_ast_vel(path):
    """AST_VEL as 20 (vx, vy) pairs, signed 8.8 - four drift vectors per size
    class. rock_kin picks one by (slot & 3), so the editor can show which way a
    rock will actually go without the level data carrying a velocity."""
    if not path.exists():
        return [(0, 0)] * 20
    text = path.read_text(encoding="utf-8")
    m = re.search(r'^AST_VEL:\s*$(.*?)^\s*$', text, re.M | re.S)
    if not m:
        return [(0, 0)] * 20
    words = []
    for line in m.group(1).split("\n"):
        code = line.split(';', 1)[0]
        if '.word' not in code:
            continue
        for tok in code.split('.word', 1)[1].split(','):
            tok = tok.strip()
            if tok.startswith('$'):
                v = int(tok[1:], 16)
                words.append(v - 0x10000 if v >= 0x8000 else v)
    pairs = list(zip(words[0::2], words[1::2]))
    return (pairs + [(0, 0)] * 20)[:20]


# =============================================================================
# main.s's own LFSR, so a previewed field IS the field
# =============================================================================
def prng_next(state):
    """One `jsr prng`: eight shifts of the 16-bit state, taps $B400, and the
    caller reads the LOW byte. Transcribed from main.s - if that routine ever
    changes, this has to change with it or the preview quietly lies."""
    for _ in range(8):
        bit = state & 1
        state >>= 1
        if bit:
            state ^= 0xB400
    return state & 0xFFFF


# =============================================================================
# model
# =============================================================================
class Level:
    def __init__(self, name="LEVEL", counts=None, seed=0x3CA5,
                 shx=0x8000, shy=0x8000, shhd=0, rocks=None, foes=None):
        self.name = name
        self.counts = list(counts or [0, 0, 0, 0, 0])   # per size class
        self.seed = seed                                 # the scatter's LFSR word
        self.shx, self.shy, self.shhd = shx, shy, shhd   # where the ship starts
        self.rocks = list(rocks or [])                   # [{x, y, cls, type}]
        self.foes = list(foes or [])                     # [{x, y, kind}]

    @property
    def total(self):
        return sum(self.counts) + len(self.rocks)

    def clone(self, name):
        return Level(name, self.counts, self.seed, self.shx, self.shy, self.shhd,
                     [dict(r) for r in self.rocks], [dict(f) for f in self.foes])

    def scatter(self, type_pick):
        """Exactly what load_level's first pass produces, in its own order:
        class by class, and per rock XL, XH, YL, YH, then the variant ticket."""
        st = self.seed & 0xFFFF
        out = []
        for cls in range(5):
            for _ in range(self.counts[cls]):
                st = prng_next(st); xl = st & 0xFF
                st = prng_next(st); xh = st & 0xFF
                st = prng_next(st); yl = st & 0xFF
                st = prng_next(st); yh = st & 0xFF
                st = prng_next(st); t = type_pick[(st & 0xFF) & 7]
                out.append({"x": (xh << 8) | xl, "y": (yh << 8) | yl,
                            "cls": cls, "type": t})
        return out


class Model:
    def __init__(self, levels):
        self.levels = levels

    @property
    def maxrock(self):
        """For the editor's own warnings only. The FILE does not carry this any
        more - the assembler sums each level itself, so nothing here can go
        stale against a hand edit."""
        return max((lv.total for lv in self.levels), default=0)

    @classmethod
    def load(cls, text):
        """The per-level numbers are read from the Ln_* CONSTANTS, not from the
        LVL_* tables: the tables are built out of those constants, so the
        constants are the source and a hand edit to one is picked up here. The
        rock and enemy blocks are still read as plain bytes - their counts are
        the length of the block and nothing else."""
        _, blocks = parse_generated_block(text, SENTINEL_START, SENTINEL_END)
        body = text[text.index(SENTINEL_START):text.index(SENTINEL_END)]
        n = int(re.search(r'^NLEVELS\s*=\s*(\d+)', body, re.M).group(1))
        names = dict((int(i), s) for i, s in
                     re.findall(r'^;\s*NAME\s+(\d+)\s+"(.*)"\s*$', body, re.M))

        consts = {}
        for lvl, key, val in re.findall(r'^L(\d+)_(\w+)\s*=\s*(\$?[0-9A-Fa-f]+)',
                                         body, re.M):
            consts[(int(lvl), key)] = int(val[1:], 16) if val.startswith('$') else int(val)

        def k(i, key, default=0):
            return consts.get((i, key), default)

        levels = []
        for i in range(n):
            raw = blocks.get(f"LVL{i}_ROCKS", [])
            rocks = [{"x": raw[j] | (raw[j + 1] << 8), "y": raw[j + 2] | (raw[j + 3] << 8),
                      "cls": raw[j + 4], "type": raw[j + 5]}
                     for j in range(0, len(raw) - len(raw) % 6, 6)]
            raw = blocks.get(f"LVL{i}_FOES", [])
            foes = [{"x": raw[j] | (raw[j + 1] << 8), "y": raw[j + 2] | (raw[j + 3] << 8),
                     "kind": raw[j + 4]}
                    for j in range(0, len(raw) - len(raw) % 5, 5)]
            levels.append(Level(
                names.get(i, f"LEVEL {i}"),
                [k(i, f"N{c}") for c in CLASSES],
                k(i, "SEED", 0x3CA5),
                k(i, "SHX", 0x8000), k(i, "SHY", 0x8000), k(i, "SHHD"),
                rocks, foes))
        return cls(levels)


# =============================================================================
# writing
# =============================================================================
def _row(label, vals, width=12):
    """'LABEL:      v0, v1, ...' as one .byte line, wrapping if a campaign ever
    grows past a sensible line length."""
    lead = f"{label}:"
    pad = " " * max(1, width - len(lead))
    chunks = [vals[i:i + 12] for i in range(0, len(vals), 12)] or [[]]
    out = [lead + pad + ".byte   " + ", ".join(str(v) for v in chunks[0])]
    for c in chunks[1:]:
        out.append(" " * width + ".byte   " + ", ".join(str(v) for v in c))
    return "\n".join(out)


def render_generated(model):
    lv = model.levels
    n = len(lv)
    out = []
    out.append(f"NLEVELS     = {n}")
    out.append("")
    out.append("; Level names. A comment, not a table - no level has anything to print them")
    out.append("; on yet, and a string per level is ROM the bench cannot spend. The editor")
    out.append("; reads and rewrites these lines, so keep the format.")
    for i, l in enumerate(lv):
        out.append(f';   NAME {i} "{l.name}"')
    out.append("")
    out.append("; -----------------------------------------------------------------------------")
    out.append("; What each level asks for. THIS is the source: the tables further down are")
    out.append("; built out of these constants, and the .assert at the bottom of the block sums")
    out.append("; each level out of them and checks it against main.s's NOBJ - so a count")
    out.append("; changed here by hand is picked up everywhere, including by the assembler,")
    out.append("; which will refuse to build a level that cannot fit in the object slots.")
    out.append(";")
    out.append(";   Nx    how many rocks of that size class the scatter drops (see the header)")
    out.append(";   SEED  the LFSR word the scatter starts from - any nonzero value")
    out.append(";   SHX   where the ship starts, world 16-bit; SHHD its heading in brad, 0 = +Y")
    out.append("; -----------------------------------------------------------------------------")
    for i, l in enumerate(lv):
        out.append(f'; level {i} - "{l.name}"')
        def const(name, val):
            return f"{f'L{i}_{name}':<12}= {val}"
        for c, cls in enumerate(CLASSES):
            out.append(const(f"N{cls}", l.counts[c]))
        out.append(const("SEED", f"${l.seed:04X}"))
        out.append(const("SHX", f"${l.shx:04X}"))
        out.append(const("SHY", f"${l.shy:04X}"))
        out.append(const("SHHD", l.shhd))
        out.append("")

    out.append("; The hand-placed blocks, and the counts DERIVED from their own length - so a")
    out.append("; record added or deleted by hand needs nothing else changed.")
    for i, l in enumerate(lv):
        out.append(f'; level {i} - "{l.name}"')
        out.append("; rocks: XL, XH, YL, YH, class, type - 6 bytes each, class 0..4 = 192..16")
        out.append(f"LVL{i}_ROCKS:")
        for r in l.rocks:
            out.append("        .byte   " + ", ".join(
                f"${v:02X}" for v in (r["x"] & 0xFF, (r["x"] >> 8) & 0xFF,
                                       r["y"] & 0xFF, (r["y"] >> 8) & 0xFF)) +
                f", {r['cls']}, {r['type']}"
                f"       ; {CLASSES[r['cls']]}{string.ascii_uppercase[r['type']]}"
                f" at {r['x']}, {r['y']}")
        out.append(f"LVL{i}_ROCKS_END:")
        out.append("; enemies: XL, XH, YL, YH, kind - 5 bytes each")
        out.append(f"LVL{i}_FOES:")
        for f in l.foes:
            out.append("        .byte   " + ", ".join(
                f"${v:02X}" for v in (f["x"] & 0xFF, (f["x"] >> 8) & 0xFF,
                                       f["y"] & 0xFF, (f["y"] >> 8) & 0xFF)) +
                f", {f['kind']}       ; kind {f['kind']} at {f['x']}, {f['y']}")
        out.append(f"LVL{i}_FOES_END:")
        out.append(f"L{i}_ROCKN    = (LVL{i}_ROCKS_END - LVL{i}_ROCKS) / 6")
        out.append(f"L{i}_FOEN     = (LVL{i}_FOES_END - LVL{i}_FOES) / 5")
        out.append(f"L{i}_TOTAL    = L{i}_N192 + L{i}_N128 + L{i}_N64 + L{i}_N32 + "
                   f"L{i}_N16 + L{i}_ROCKN")
        out.append("")

    out.append("; -----------------------------------------------------------------------------")
    out.append("; The tables load_level indexes by level. Nothing here is a number: every cell")
    out.append("; is one of the constants above, so this half of the file cannot drift from it.")
    out.append("; -----------------------------------------------------------------------------")
    for c, cls in enumerate(CLASSES):
        out.append(_row(f"LVL_N{cls}", [f"L{i}_N{cls}" for i in range(n)]))
    out.append("")
    out.append(_row("LVL_SEEDL", [f"<L{i}_SEED" for i in range(n)]))
    out.append(_row("LVL_SEEDH", [f">L{i}_SEED" for i in range(n)]))
    out.append("")
    out.append(_row("LVL_SHXL", [f"<L{i}_SHX" for i in range(n)]))
    out.append(_row("LVL_SHXH", [f">L{i}_SHX" for i in range(n)]))
    out.append(_row("LVL_SHYL", [f"<L{i}_SHY" for i in range(n)]))
    out.append(_row("LVL_SHYH", [f">L{i}_SHY" for i in range(n)]))
    out.append(_row("LVL_SHHD", [f"L{i}_SHHD" for i in range(n)]))
    out.append("")
    out.append(_row("LVL_ROCKN", [f"L{i}_ROCKN" for i in range(n)]))
    out.append(_row("LVL_ROCKLO", [f"<LVL{i}_ROCKS" for i in range(n)]))
    out.append(_row("LVL_ROCKHI", [f">LVL{i}_ROCKS" for i in range(n)]))
    out.append("")
    out.append(_row("LVL_FOEN", [f"L{i}_FOEN" for i in range(n)]))
    out.append(_row("LVL_FOELO", [f"<LVL{i}_FOES" for i in range(n)]))
    out.append(_row("LVL_FOEHI", [f">LVL{i}_FOES" for i in range(n)]))
    out.append("")
    out.append("; The one thing a level cannot be allowed to get wrong, checked by the")
    out.append("; assembler rather than discovered in the simulator.")
    for i, l in enumerate(lv):
        out.append(f'        .assert L{i}_TOTAL <= NOBJ, error, '
                   f'"level {i} ({l.name}) asks for more rocks than NOBJ slots"')
    return "\n".join(out)


def save_model(path, model):
    text = path.read_text(encoding="utf-8")
    start = text.index(SENTINEL_START) + len(SENTINEL_START)
    end = text.index(SENTINEL_END)
    path.write_text(text[:start] + "\n" + render_generated(model) + "\n" + text[end:],
                    encoding="utf-8")


# =============================================================================
# GUI
# =============================================================================
class LevelEditor(tk.Tk):
    def __init__(self, path):
        super().__init__()
        self.path = path
        self.title(f"EfS level editor - {path}")
        self.geometry("1240x800")
        self.configure(bg=BG)

        self.scr_hx, self.scr_hy, self.zoom_out = read_screen(DEFAULT_MAIN)
        self.ast_types, self.shape_r = read_shapes(DEFAULT_SHAPES)
        self.type_pick = read_type_pick(DEFAULT_MAIN)
        self.ast_vel = read_ast_vel(DEFAULT_MAIN)
        main_text = DEFAULT_MAIN.read_text(encoding="utf-8") if DEFAULT_MAIN.exists() else ""
        self.nobj = read_int(main_text, "NOBJ", 120)

        self.model = Model.load(path.read_text(encoding="utf-8"))
        self.li = 0
        self.dirty = False
        self.sel = None                     # ("rock"|"foe"|"ship", index)
        self.drag = False

        self.view_cx, self.view_cy = HALF, HALF
        self.ppu = 700 / WORLD              # canvas pixels per world unit
        self.pan_from = None
        self.hover = None                   # last cursor position, canvas px
        self._scatter_cache = None

        self._build_ui()
        self._refresh_all()

    # ---- UI scaffolding -----------------------------------------------------
    def _build_ui(self):
        top = tk.Frame(self, bg=BG)
        top.pack(side="top", fill="x", padx=8, pady=6)

        tk.Label(top, text="Level:", bg=BG, fg=TEXT).pack(side="left")
        self.level_var = tk.StringVar()
        self.level_menu = ttk.Combobox(top, textvariable=self.level_var, state="readonly",
                                        width=28)
        self.level_menu.pack(side="left", padx=(4, 10))
        self.level_menu.bind("<<ComboboxSelected>>", self._on_level_change)
        tk.Button(top, text="+ New level", command=self._add_level).pack(side="left", padx=4)

        right_btns = tk.Frame(top, bg=BG)
        right_btns.pack(side="right")
        tk.Button(right_btns, text="Fit world", command=self._fit).pack(side="left", padx=4)
        tk.Button(right_btns, text="Reload", command=self._reload).pack(side="left", padx=4)
        tk.Button(right_btns, text="Save to levels.s", command=self._save,
                   bg="#2a6", fg="white").pack(side="left", padx=4)

        mid = tk.Frame(self, bg=BG)
        mid.pack(side="top", fill="both", expand=True, padx=8, pady=4)

        left = tk.Frame(mid, bg=BG)
        left.pack(side="left", fill="both", expand=True)
        tk.Label(left, text="The torus (it wraps - pan straight through the seam). "
                             "Click to select, drag to move, double-click empty space to add.",
                  bg=BG, fg=DIM).pack(anchor="w")
        self.map = tk.Canvas(left, bg=BG, highlightthickness=0)
        self.map.pack(fill="both", expand=True)
        self.map.bind("<Configure>", lambda e: self._draw())
        self.map.bind("<ButtonPress-1>", self._press)
        self.map.bind("<B1-Motion>", self._motion)
        self.map.bind("<ButtonRelease-1>", lambda e: setattr(self, "drag", False))
        self.map.bind("<Double-Button-1>", self._dblclick)
        self.map.bind("<Motion>", self._hover)
        self.map.bind("<Leave>", self._unhover)
        self.map.bind("<ButtonPress-3>", self._pan_start)
        self.map.bind("<B3-Motion>", self._pan_move)
        self.map.bind("<MouseWheel>", self._wheel)
        self.bind("<Delete>", self._delete_selected)
        self.bind("<BackSpace>", self._delete_selected)

        side = tk.Frame(mid, bg=BG, width=330)
        side.pack(side="left", fill="y", padx=(10, 0))
        side.pack_propagate(False)

        self._build_name_panel(side)
        self._build_scatter_panel(side)
        self._build_ship_panel(side)
        self._build_place_panel(side)
        self._build_sel_panel(side)

        self.warn = tk.Label(side, text="", bg=BG, fg="#ff6666", wraplength=310,
                              justify="left")
        self.warn.pack(fill="x", pady=6)

        self.status = tk.Label(self, text="", bg=BG, fg=DIM, anchor="w")
        self.status.pack(side="bottom", fill="x", padx=8, pady=4)

    def _section(self, parent, title):
        tk.Label(parent, text=title, bg=BG, fg=TEXT,
                  font=("Segoe UI", 9, "bold")).pack(anchor="w", pady=(10, 2))
        f = tk.Frame(parent, bg=BG)
        f.pack(fill="x")
        return f

    def _build_name_panel(self, side):
        f = self._section(side, "Level name")
        self.name_var = tk.StringVar()
        e = tk.Entry(f, textvariable=self.name_var, width=30)
        e.pack(anchor="w")
        e.bind("<Return>", lambda ev: self._commit_name())
        e.bind("<FocusOut>", lambda ev: self._commit_name())

    def _build_scatter_panel(self, side):
        f = self._section(side, "Scatter - rocks per size class")
        self.count_vars = []
        for i, c in enumerate(CLASSES):
            tk.Label(f, text=f"{c} px", bg=BG, fg=TEXT, width=7,
                      anchor="w").grid(row=i, column=0, sticky="w", pady=1)
            v = tk.StringVar()
            e = tk.Entry(f, textvariable=v, width=6)
            e.grid(row=i, column=1, padx=4)
            e.bind("<Return>", lambda ev, k=i: self._commit_count(k))
            e.bind("<FocusOut>", lambda ev, k=i: self._commit_count(k))
            self.count_vars.append(v)

        tk.Label(f, text="Seed", bg=BG, fg=TEXT, width=7,
                  anchor="w").grid(row=5, column=0, sticky="w", pady=(6, 1))
        self.seed_var = tk.StringVar()
        e = tk.Entry(f, textvariable=self.seed_var, width=6)
        e.grid(row=5, column=1, padx=4, pady=(6, 1))
        e.bind("<Return>", lambda ev: self._commit_seed())
        e.bind("<FocusOut>", lambda ev: self._commit_seed())
        tk.Button(f, text="Reroll", command=self._reroll).grid(row=5, column=2, padx=4,
                                                                pady=(6, 1))

        self.show_scatter = tk.IntVar(value=1)
        tk.Checkbutton(f, text="show scatter", variable=self.show_scatter,
                        command=self._draw, bg=BG, fg=TEXT, selectcolor="#333",
                        activebackground=BG).grid(row=6, column=0, columnspan=2, sticky="w")
        self.show_drift = tk.IntVar(value=0)
        tk.Checkbutton(f, text="show drift", variable=self.show_drift,
                        command=self._draw, bg=BG, fg=TEXT, selectcolor="#333",
                        activebackground=BG).grid(row=6, column=2, sticky="w")
        self.show_frames = tk.IntVar(value=1)
        tk.Checkbutton(f, text="screen frames follow the cursor",
                        variable=self.show_frames, command=self._draw, bg=BG,
                        fg=TEXT, selectcolor="#333", activebackground=BG
                        ).grid(row=7, column=0, columnspan=3, sticky="w")

        self.total_label = tk.Label(side, text="", bg=BG, fg=DIM, anchor="w")
        self.total_label.pack(fill="x", pady=(4, 0))

    def _build_ship_panel(self, side):
        f = self._section(side, "Ship start")
        self.ship_vars = {}
        for i, (k, lab) in enumerate([("shx", "World X"), ("shy", "World Y"),
                                       ("shhd", "Heading (brad)")]):
            tk.Label(f, text=lab, bg=BG, fg=TEXT, width=14,
                      anchor="w").grid(row=i, column=0, sticky="w", pady=1)
            v = tk.StringVar()
            e = tk.Entry(f, textvariable=v, width=8)
            e.grid(row=i, column=1, padx=4)
            e.bind("<Return>", lambda ev, k=k: self._commit_ship(k))
            e.bind("<FocusOut>", lambda ev, k=k: self._commit_ship(k))
            self.ship_vars[k] = v

    def _build_place_panel(self, side):
        f = self._section(side, "Place (double-click the map)")
        self.place_var = tk.StringVar(value="rock")
        tk.Radiobutton(f, text="Rock", variable=self.place_var, value="rock", bg=BG,
                        fg=TEXT, selectcolor="#333", activebackground=BG,
                        command=self._draw).grid(row=0, column=0, sticky="w")
        tk.Radiobutton(f, text="Enemy", variable=self.place_var, value="foe", bg=BG,
                        fg=TEXT, selectcolor="#333", activebackground=BG,
                        command=self._draw).grid(row=0, column=1, sticky="w")

        tk.Label(f, text="Class", bg=BG, fg=TEXT).grid(row=1, column=0, sticky="w", pady=1)
        self.new_cls = ttk.Combobox(f, state="readonly", width=6,
                                     values=[str(c) for c in CLASSES])
        self.new_cls.set(str(CLASSES[0]))
        self.new_cls.grid(row=1, column=1, sticky="w", padx=4)

        tk.Label(f, text="Variant", bg=BG, fg=TEXT).grid(row=2, column=0, sticky="w", pady=1)
        self.new_type = ttk.Combobox(f, state="readonly", width=6,
                                      values=list(string.ascii_uppercase[:self.ast_types]))
        self.new_type.set("A")
        self.new_type.grid(row=2, column=1, sticky="w", padx=4)

        tk.Label(f, text="Enemy kind", bg=BG, fg=TEXT).grid(row=3, column=0, sticky="w", pady=1)
        self.new_kind = tk.Spinbox(f, from_=0, to=FOE_KINDS - 1, width=5)
        self.new_kind.grid(row=3, column=1, sticky="w", padx=4)

    def _build_sel_panel(self, side):
        f = self._section(side, "Selection")
        self.sel_label = tk.Label(f, text="Nothing selected", bg=BG, fg=DIM, anchor="w")
        self.sel_label.grid(row=0, column=0, columnspan=3, sticky="w")
        tk.Label(f, text="X", bg=BG, fg=TEXT).grid(row=1, column=0, sticky="w")
        self.selx = tk.StringVar()
        e = tk.Entry(f, textvariable=self.selx, width=8)
        e.grid(row=1, column=1, padx=4)
        e.bind("<Return>", lambda ev: self._commit_sel())
        e.bind("<FocusOut>", lambda ev: self._commit_sel())
        tk.Label(f, text="Y", bg=BG, fg=TEXT).grid(row=2, column=0, sticky="w")
        self.sely = tk.StringVar()
        e = tk.Entry(f, textvariable=self.sely, width=8)
        e.grid(row=2, column=1, padx=4)
        e.bind("<Return>", lambda ev: self._commit_sel())
        e.bind("<FocusOut>", lambda ev: self._commit_sel())
        tk.Button(f, text="Delete", command=self._delete_selected).grid(row=1, column=2,
                                                                        rowspan=2, padx=6)

    # ---- model helpers ------------------------------------------------------
    def _lvl(self):
        return self.model.levels[self.li]

    def _touch(self):
        self.dirty = True
        self._scatter_cache = None
        self._update_totals()
        self._update_status()

    def _scatter(self):
        if self._scatter_cache is None:
            self._scatter_cache = self._lvl().scatter(self.type_pick)
        return self._scatter_cache

    def _rock_world_r(self, cls, type_):
        """SHAPE_R is half-res px; a world unit is 1/16 of a FULL-res px."""
        idx = cls * self.ast_types + min(type_, self.ast_types - 1)
        r = self.shape_r[idx] if idx < len(self.shape_r) else 48
        return r * 2 * UNITS_PER_PX

    # ---- world <-> canvas ---------------------------------------------------
    def _to_canvas(self, wx, wy):
        """The nearest representative of (wx, wy) to the view centre. On a torus
        every point has infinitely many, and this is the one that is on screen -
        which is also why panning past the seam simply keeps working."""
        w = self.map.winfo_width() or 700
        h = self.map.winfo_height() or 700
        dx = ((wx - self.view_cx + HALF) & 0xFFFF) - HALF
        dy = ((wy - self.view_cy + HALF) & 0xFFFF) - HALF
        return w / 2 + dx * self.ppu, h / 2 + dy * self.ppu

    def _from_canvas(self, cx, cy):
        w = self.map.winfo_width() or 700
        h = self.map.winfo_height() or 700
        wx = int(round(self.view_cx + (cx - w / 2) / self.ppu)) & 0xFFFF
        wy = int(round(self.view_cy + (cy - h / 2) / self.ppu)) & 0xFFFF
        return wx, wy

    def _fit(self):
        w = self.map.winfo_width() or 700
        h = self.map.winfo_height() or 700
        self.ppu = 0.92 * min(w, h) / WORLD
        self.view_cx, self.view_cy = HALF, HALF
        self._draw()

    # ---- drawing ------------------------------------------------------------
    def _refresh_all(self):
        self.level_menu.configure(values=[f"{i}: {l.name}"
                                           for i, l in enumerate(self.model.levels)])
        self.level_var.set(f"{self.li}: {self._lvl().name}")
        lv = self._lvl()
        self.name_var.set(lv.name)
        for i, v in enumerate(self.count_vars):
            v.set(str(lv.counts[i]))
        self.seed_var.set(f"${lv.seed:04X}")
        self.ship_vars["shx"].set(str(lv.shx))
        self.ship_vars["shy"].set(str(lv.shy))
        self.ship_vars["shhd"].set(str(lv.shhd))
        self._scatter_cache = None
        self._update_totals()
        self._refresh_sel()
        self._draw()
        self._update_status()

    def _update_totals(self):
        lv = self._lvl()
        t = lv.total
        self.total_label.configure(
            text=f"{sum(lv.counts)} scattered + {len(lv.rocks)} placed = {t} of "
                  f"{self.nobj} slots   |   {len(lv.foes)} enemies",
            fg="#ff6666" if t > self.nobj else DIM)
        self.warn.configure(
            text=(f"{t} rocks will not fit in NOBJ={self.nobj} slots. Raise NOBJ in main.s "
                   f"or take {t - self.nobj} out - main.s asserts this at assembly time.")
            if t > self.nobj else "")

    def _status_text(self):
        star = "* " if self.dirty else ""
        px = 1 / (self.ppu * UNITS_PER_PX) if self.ppu else 0
        return (f"{star}level {self.li} \"{self._lvl().name}\"  -  {self.path}"
                f"   [1 canvas px = {px:.0f} full-res px]")

    def _update_status(self):
        self.status.configure(text=self._status_text())

    def _draw(self):
        c = self.map
        c.delete("all")
        w = c.winfo_width() or 700
        h = c.winfo_height() or 700
        lv = self._lvl()

        # grid every 4096 world units (256 full-res px), heavier on the seam
        step = 4096
        x0 = (self.view_cx - (w / 2) / self.ppu)
        y0 = (self.view_cy - (h / 2) / self.ppu)
        gx = int(x0 // step) * step
        while gx * self.ppu < (x0 + w / self.ppu) * self.ppu + step * self.ppu:
            sx = w / 2 + (gx - self.view_cx) * self.ppu
            if -2 <= sx <= w + 2:
                c.create_line(sx, 0, sx, h, fill=AXIS if (gx & 0xFFFF) == 0 else GRID)
            gx += step
            if gx > x0 + w / self.ppu + step:
                break
        gy = int(y0 // step) * step
        while True:
            sy = h / 2 + (gy - self.view_cy) * self.ppu
            if -2 <= sy <= h + 2:
                c.create_line(0, sy, w, sy, fill=AXIS if (gy & 0xFFFF) == 0 else GRID)
            gy += step
            if gy > y0 + h / self.ppu + step:
                break

        # what the player can see from the start position
        sx, sy = self._to_canvas(lv.shx, lv.shy)
        sweep = (self.scr_hx ** 2 + self.scr_hy ** 2) ** 0.5   # the frame's own
        for r, lab in ((sweep, "1:1"),                          #   half-diagonal
                        (sweep * self.zoom_out, "max zoom-out")):
            rr = r * self.ppu
            c.create_oval(sx - rr, sy - rr, sx + rr, sy + rr, outline=VIEW_COLOR,
                           dash=(3, 3))
            c.create_text(sx, sy - rr - 7, text=lab, fill=VIEW_COLOR,
                           font=("Consolas", 8))

        if self.show_scatter.get():
            for i, r in enumerate(self._scatter()):
                self._draw_rock(r, SCATTER_COLOR, slot=i)

        base = sum(lv.counts)
        for i, r in enumerate(lv.rocks):
            sel = self.sel == ("rock", i)
            self._draw_rock(r, SEL_COLOR if sel else PLACED_COLOR, slot=base + i, width=2)

        for i, f in enumerate(lv.foes):
            self._draw_foe(f, SEL_COLOR if self.sel == ("foe", i) else FOE_COLOR)

        self._draw_ship(lv, SEL_COLOR if self.sel == ("ship", 0) else SHIP_COLOR)
        self._draw_frames()

    def _draw_frames(self):
        """The two screen footprints, under the cursor. Redrawn on their own tag
        rather than through _draw, so following the mouse costs two rectangles
        and not the whole field."""
        c = self.map
        c.delete("frames")
        if not self.show_frames.get() or self.hover is None:
            return
        import math
        cx, cy = self.hover
        # turned to the level's start heading: the frame is portrait, so which
        # way its long side points is a real question and the heading answers it
        a = self._lvl().shhd * 2 * math.pi / 256
        ca, sa = math.cos(a), math.sin(a)
        ax, ay = ca * self.ppu, sa * self.ppu            # the view's x axis...
        bx, by = -sa * self.ppu, ca * self.ppu           # ...and its y axis
        for k, dash, lab in ((1.0, None, "1:1"),
                              (self.zoom_out, (4, 3), f"{self.zoom_out:g}x out")):
            hx, hy = self.scr_hx * k, self.scr_hy * k
            pts = []
            for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                pts += [cx + sx * hx * ax + sy * hy * bx,
                        cy + sx * hx * ay + sy * hy * by]
            kw = {"outline": FRAME_COLOR, "fill": "", "tags": "frames"}
            if dash:
                kw["dash"] = dash
            c.create_polygon(*pts, **kw)
            # the label sits just INSIDE the first corner, stepped along the
            # frame's own two axes so it stays inside however the frame is
            # turned. Outside, it collided with the ship's sweep-circle labels.
            c.create_text(pts[0] + 5 * (ca - sa), pts[1] + 5 * (sa + ca),
                           text=lab, fill=FRAME_COLOR, anchor="nw",
                           font=("Consolas", 8), tags="frames")
        c.create_line(cx - 5, cy, cx + 5, cy, fill=FRAME_COLOR, tags="frames")
        c.create_line(cx, cy - 5, cx, cy + 5, fill=FRAME_COLOR, tags="frames")

    def _hover(self, ev):
        self.hover = (ev.x, ev.y)
        self._draw_frames()
        wx, wy = self._from_canvas(ev.x, ev.y)
        self.status.configure(text=self._status_text() + f"   cursor {wx}, {wy}")

    def _unhover(self, _ev=None):
        self.hover = None
        self.map.delete("frames")
        self._update_status()

    def _draw_rock(self, r, color, slot=0, width=1):
        x, y = self._to_canvas(r["x"], r["y"])
        w = self.map.winfo_width() or 700
        h = self.map.winfo_height() or 700
        rr = max(1.5, self._rock_world_r(r["cls"], r["type"]) * self.ppu)
        if x < -rr or y < -rr or x > w + rr or y > h + rr:
            return
        self.map.create_oval(x - rr, y - rr, x + rr, y + rr, outline=color, width=width)
        if self.show_drift.get():
            vx, vy = self.ast_vel[r["cls"] * 4 + (slot & 3)]
            n = max(1.0, (vx * vx + vy * vy) ** 0.5)
            k = max(10.0, rr * 1.6)
            self.map.create_line(x, y, x + vx / n * k, y + vy / n * k, fill=color)

    def _draw_foe(self, f, color):
        x, y = self._to_canvas(f["x"], f["y"])
        w = self.map.winfo_width() or 700
        h = self.map.winfo_height() or 700
        if x < -20 or y < -20 or x > w + 20 or y > h + 20:
            return
        s = 7
        self.map.create_polygon(x, y - s, x + s, y, x, y + s, x - s, y,
                                 outline=color, fill="", width=2)
        self.map.create_text(x + 11, y - 9, text=str(f["kind"]), fill=color,
                              font=("Consolas", 8))

    def _draw_ship(self, lv, color):
        import math
        x, y = self._to_canvas(lv.shx, lv.shy)
        # main.s: ship forward in world = (sin H, -cos H), and the map draws +Y
        # down, so heading 0 points up the canvas - which is what it looks like
        # on the player's screen too.
        a = lv.shhd * 2 * math.pi / 256
        fx, fy = math.sin(a), -math.cos(a)
        px, py = -fy, fx
        L, W = 14, 6
        self.map.create_polygon(x + fx * L, y + fy * L,
                                 x - fx * L * 0.4 + px * W, y - fy * L * 0.4 + py * W,
                                 x - fx * L * 0.4 - px * W, y - fy * L * 0.4 - py * W,
                                 outline=color, fill="", width=2)

    # ---- picking ------------------------------------------------------------
    def _hit(self, cx, cy):
        """Placed items first, then the ship. The scatter is never hit-tested -
        it is generated, and dragging one would be a lie the next Save undoes."""
        lv = self._lvl()
        best, best_d = None, 18 ** 2
        for i, f in enumerate(lv.foes):
            x, y = self._to_canvas(f["x"], f["y"])
            d = (x - cx) ** 2 + (y - cy) ** 2
            if d < best_d:
                best, best_d = ("foe", i), d
        for i, r in enumerate(lv.rocks):
            x, y = self._to_canvas(r["x"], r["y"])
            rr = max(8, self._rock_world_r(r["cls"], r["type"]) * self.ppu)
            d = (x - cx) ** 2 + (y - cy) ** 2
            if d < max(best_d, rr ** 2):
                best, best_d = ("rock", i), d
        if best is None:
            x, y = self._to_canvas(lv.shx, lv.shy)
            if (x - cx) ** 2 + (y - cy) ** 2 <= 18 ** 2:
                best = ("ship", 0)
        return best

    def _press(self, ev):
        self.sel = self._hit(ev.x, ev.y)
        self.drag = self.sel is not None
        self._refresh_sel()
        self._draw()

    def _motion(self, ev):
        if not self.drag or self.sel is None:
            return
        wx, wy = self._from_canvas(ev.x, ev.y)
        kind, i = self.sel
        lv = self._lvl()
        if kind == "ship":
            lv.shx, lv.shy = wx, wy
            self.ship_vars["shx"].set(str(wx))
            self.ship_vars["shy"].set(str(wy))
        else:
            item = lv.rocks[i] if kind == "rock" else lv.foes[i]
            item["x"], item["y"] = wx, wy
        self.hover = (ev.x, ev.y)
        self._touch()
        self._refresh_sel()
        self._draw()

    def _dblclick(self, ev):
        if self._hit(ev.x, ev.y) is not None:
            return
        wx, wy = self._from_canvas(ev.x, ev.y)
        lv = self._lvl()
        if self.place_var.get() == "rock":
            cls = CLASSES.index(int(self.new_cls.get()))
            t = string.ascii_uppercase.index(self.new_type.get())
            lv.rocks.append({"x": wx, "y": wy, "cls": cls, "type": t})
            self.sel = ("rock", len(lv.rocks) - 1)
        else:
            lv.foes.append({"x": wx, "y": wy, "kind": int(self.new_kind.get())})
            self.sel = ("foe", len(lv.foes) - 1)
        self._touch()
        self._refresh_sel()
        self._draw()

    def _delete_selected(self, _ev=None):
        if self.sel is None or self.sel[0] == "ship":
            return
        kind, i = self.sel
        lv = self._lvl()
        (lv.rocks if kind == "rock" else lv.foes).pop(i)
        self.sel = None
        self._touch()
        self._refresh_sel()
        self._draw()

    # ---- pan / zoom ---------------------------------------------------------
    def _pan_start(self, ev):
        self.pan_from = (ev.x, ev.y, self.view_cx, self.view_cy)

    def _pan_move(self, ev):
        if not self.pan_from:
            return
        x0, y0, cx0, cy0 = self.pan_from
        self.view_cx = int(cx0 - (ev.x - x0) / self.ppu) & 0xFFFF
        self.view_cy = int(cy0 - (ev.y - y0) / self.ppu) & 0xFFFF
        self._draw()

    def _wheel(self, ev):
        before = self._from_canvas(ev.x, ev.y)
        k = 1.25 if ev.delta > 0 else 1 / 1.25
        self.ppu = max(700 / WORLD / 4, min(0.5, self.ppu * k))
        after = self._from_canvas(ev.x, ev.y)
        self.view_cx = (self.view_cx + before[0] - after[0]) & 0xFFFF
        self.view_cy = (self.view_cy + before[1] - after[1]) & 0xFFFF
        self._draw()
        self._update_status()

    # ---- field commits ------------------------------------------------------
    def _on_level_change(self, _ev=None):
        self.li = int(self.level_var.get().split(":", 1)[0])
        self.sel = None
        self._refresh_all()

    def _add_level(self):
        src = self._lvl()
        self.model.levels.append(src.clone(f"LEVEL {len(self.model.levels)}"))
        self.li = len(self.model.levels) - 1
        self.sel = None
        self._touch()
        self._refresh_all()

    def _commit_name(self):
        name = self.name_var.get().strip().replace('"', "'")
        if name and name != self._lvl().name:
            self._lvl().name = name
            self._touch()
            self._refresh_all()

    def _commit_count(self, k):
        try:
            v = max(0, min(255, int(self.count_vars[k].get())))
        except ValueError:
            self.count_vars[k].set(str(self._lvl().counts[k]))
            return
        if v != self._lvl().counts[k]:
            self._lvl().counts[k] = v
            self.count_vars[k].set(str(v))
            self._touch()
            self._draw()

    def _commit_seed(self):
        s = self.seed_var.get().strip()
        try:
            v = int(s[1:], 16) if s.startswith("$") else int(s, 0)
        except ValueError:
            self.seed_var.set(f"${self._lvl().seed:04X}")
            return
        v &= 0xFFFF
        if v == 0:                          # prng's state must never be zero
            v = 0x3CA5
        self._lvl().seed = v
        self.seed_var.set(f"${v:04X}")
        self._touch()
        self._draw()

    def _reroll(self):
        self._lvl().seed = prng_next(self._lvl().seed or 0x3CA5) or 0x3CA5
        self.seed_var.set(f"${self._lvl().seed:04X}")
        self._touch()
        self._draw()

    def _commit_ship(self, k):
        lv = self._lvl()
        try:
            v = int(self.ship_vars[k].get(), 0)
        except ValueError:
            self.ship_vars[k].set(str(getattr(lv, k)))
            return
        v &= 0xFF if k == "shhd" else 0xFFFF
        setattr(lv, k, v)
        self.ship_vars[k].set(str(v))
        self._touch()
        self._draw()

    def _refresh_sel(self):
        if self.sel is None:
            self.sel_label.configure(text="Nothing selected")
            self.selx.set("")
            self.sely.set("")
            return
        kind, i = self.sel
        lv = self._lvl()
        if kind == "ship":
            self.sel_label.configure(text="Ship start")
            x, y = lv.shx, lv.shy
        elif kind == "rock":
            r = lv.rocks[i]
            self.sel_label.configure(
                text=f"Placed rock {i} - {CLASSES[r['cls']]}"
                      f"{string.ascii_uppercase[r['type']]}")
            x, y = r["x"], r["y"]
        else:
            f = lv.foes[i]
            self.sel_label.configure(text=f"Enemy {i} - kind {f['kind']}")
            x, y = f["x"], f["y"]
        self.selx.set(str(x))
        self.sely.set(str(y))

    def _commit_sel(self):
        if self.sel is None:
            return
        try:
            x = int(self.selx.get(), 0) & 0xFFFF
            y = int(self.sely.get(), 0) & 0xFFFF
        except ValueError:
            self._refresh_sel()
            return
        kind, i = self.sel
        lv = self._lvl()
        if kind == "ship":
            lv.shx, lv.shy = x, y
            self.ship_vars["shx"].set(str(x))
            self.ship_vars["shy"].set(str(y))
        else:
            item = lv.rocks[i] if kind == "rock" else lv.foes[i]
            item["x"], item["y"] = x, y
        self._touch()
        self._draw()

    # ---- file ops -----------------------------------------------------------
    def _save(self):
        over = [f"{i} ({l.total})" for i, l in enumerate(self.model.levels)
                if l.total > self.nobj]
        if over:
            messagebox.showerror(
                "Too many rocks",
                f"These levels ask for more rocks than NOBJ={self.nobj} slots, and "
                f"main.s asserts the fit at assembly time:\n" + ", ".join(over))
            return
        save_model(self.path, self.model)
        self.dirty = False
        self._update_status()
        self.status.configure(text=f"Saved {self.path}")

    def _reload(self):
        if self.dirty and not messagebox.askyesno("Reload", "Discard unsaved changes?"):
            return
        self.model = Model.load(self.path.read_text(encoding="utf-8"))
        self.li = min(self.li, len(self.model.levels) - 1)
        self.dirty = False
        self.sel = None
        self._refresh_all()


def main():
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_LEVELS
    if not path.exists():
        print(f"no such file: {path}", file=sys.stderr)
        sys.exit(1)
    LevelEditor(path).mainloop()


if __name__ == "__main__":
    main()
