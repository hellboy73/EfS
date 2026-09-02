#!/usr/bin/env python3
"""Vertex editor for EfS's asteroids and ship - reads and writes
proto/02_rocks/shapes.s directly.

    python tools/shape_editor.py [path/to/shapes.s]

Only the GENERATED block in shapes.s (between the sentinel comments) is ever
touched, and it is rewritten WHOLE on every Save - never patched in place - so
what you get back is always a clean, consistently formatted file. Everything
outside that block (the header prose) is left untouched.

Two preview panes show every shape at the game's own scale: 1:1 (RZ 128, the
resting zoom) and the top-speed zoom-out (RZ 64, half size) - half-res
authored units map directly to full-res screen pixels through main.s's own
ZOOM_RZ table, so "how big is this on screen" is just the shape's own units at
those two known scales. The big canvas on the left is a separate, zoomed-IN
space to actually work in; drag a point to move it, double-click an edge to
insert a vertex there, select a point and press Delete to remove it (3-vertex
floor). A shape's REDUCED (LOD) outline - what a rock switches to once it is
small enough on screen, see main.s LOD_R - is a separate outline, edited on
its own tab per shape, not derived from the full one.
"""
import colorsys
import math
import pathlib
import re
import string
import sys
import tkinter as tk
from tkinter import ttk, messagebox

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_SHAPES = ROOT / "proto" / "02_rocks" / "shapes.s"
DEFAULT_MAIN = ROOT / "proto" / "02_rocks" / "main.s"

SENTINEL_START = "; === GENERATED (tools/shape_editor.py) - rewritten whole on Save ============"
SENTINEL_END = "; === END GENERATED ==="

CLASSES = [192, 128, 64, 32, 16]          # size-major order, matches shapes.s
DEFAULT_R = {192: 48, 128: 32, 64: 16, 32: 8, 16: 4}
DEFAULT_N = {192: 12, 128: 10, 64: 8, 32: 6, 16: 5}
DEFAULT_OCC = {192: 39, 128: 26, 64: 13, 32: 7, 16: 3}
VERTEX_MAX = 127                          # qmul's |x|+|cos| has to stay in a byte


# =============================================================================
# parsing
# =============================================================================
def parse_value(tok):
    """'<-16' -> -16, '44' -> 44, '$3C' -> 60, anything else (a label ref, an
    expression) -> None, meaning "not a plain number, ignore it"."""
    tok = tok.strip()
    if not tok:
        return None
    m = re.match(r'^<?\$([0-9A-Fa-f]+)$', tok)
    if m:
        return int(m.group(1), 16)
    m = re.match(r'^<?-?\s*(\d+)$', tok)
    if not m:
        return None
    return -int(m.group(1)) if tok.replace('<', '').strip().startswith('-') else int(m.group(1))


def parse_generated_block(text, start_marker=SENTINEL_START, end_marker=SENTINEL_END):
    """Returns (scalars: {name: int}, blocks: {label: [values]}) for
    everything between the sentinels. A value list drops non-numeric tokens
    (label refs in the pointer tables) - callers that need those just don't
    ask for that block.

    The markers are arguments because levels.s has the same GENERATED-block
    shape and tools/level_editor.py reads it with this same function; only the
    sentinel text differs.
    """
    start = text.index(start_marker) + len(start_marker)
    end = text.index(end_marker)
    body = text[start:end]

    scalars, blocks = {}, {}
    cur_label, cur_vals = None, []

    def flush():
        if cur_label is not None:
            blocks[cur_label] = cur_vals

    for raw in body.split('\n'):
        code = raw.split(';', 1)[0]
        if not code.strip():
            continue
        indented = raw[:1] in (' ', '\t')
        if not indented:
            m = re.match(r'^(\w+):\s*(.*)$', code)
            if m:
                flush()
                cur_label, cur_vals = m.group(1), []
                rest = m.group(2).strip()
                if rest.startswith('.byte'):
                    cur_vals += [v for v in (parse_value(t) for t in
                                              rest[len('.byte'):].split(',')) if v is not None]
                continue
            m = re.match(r'^(\w+)\s*=\s*(-?\d+)', code)
            if m:
                flush()
                cur_label, cur_vals = None, []
                scalars[m.group(1)] = int(m.group(2))
                continue
        stripped = code.strip()
        if stripped.startswith('.byte') and cur_label is not None:
            cur_vals += [v for v in (parse_value(t) for t in
                                      stripped[len('.byte'):].split(',')) if v is not None]
    flush()
    return scalars, blocks


class Shape:
    __slots__ = ("cls", "type", "r", "occ", "full", "lod")

    def __init__(self, cls, type_, r, occ, full, lod):
        self.cls, self.type = cls, type_
        self.r, self.occ = r, occ
        self.full = full                  # [(x,y), ...]
        self.lod = lod                    # [(x,y), ...] or None


class Model:
    def __init__(self, ast_types, shapes, ship):
        self.ast_types = ast_types
        self.shapes = shapes              # {(cls, type_letter): Shape}
        self.ship = ship                  # [(dx, dy), ...] - emit_ship (main.s)
                                           #   walks this one vertex at a time,
                                           #   so there is no array size capping it

    @property
    def types(self):
        return string.ascii_uppercase[:self.ast_types]

    @classmethod
    def load(cls, text):
        scalars, blocks = parse_generated_block(text)
        ast_types = scalars.get('AST_TYPES', 3)
        types = string.ascii_uppercase[:ast_types]
        shapes = {}
        for ci, c in enumerate(CLASSES):
            for ti, t in enumerate(types):
                idx = ci * ast_types + ti
                label = f"SHP{c}_{t}"
                raw = blocks.get(label, [])
                full = list(zip(raw[0::2], raw[1::2]))
                r = blocks.get('SHAPE_R', [None] * (5 * ast_types))[idx] or DEFAULT_R[c]
                occ = blocks.get('SHAPE_OCC', [None] * (5 * ast_types))[idx] or DEFAULT_OCC[c]
                lodn = blocks.get('SHAPE_LODN', [0] * (5 * ast_types))[idx]
                lod_raw = blocks.get(f"{label}_LOD")
                lod = list(zip(lod_raw[0::2], lod_raw[1::2])) if (lodn and lod_raw) else None
                shapes[(c, t)] = Shape(c, t, r, occ, full, lod)
        ship_vn = scalars.get('SHIP_VN', 3)
        ship_raw = blocks.get('SHIP_SHAPE', [-14, 0, 14, -12, 14, 12])
        ship = list(zip(ship_raw[0::2], ship_raw[1::2]))[:ship_vn]
        return cls(ast_types, shapes, ship)


# =============================================================================
# formatting / writing
# =============================================================================
def fmt_cell(v):
    return f"{v:5d}" if v >= 0 else f"  <-{-v}"


def fmt_flat(vals, per_line=15, indent="            "):
    lines = [vals[i:i + per_line] for i in range(0, len(vals), per_line)] or [[]]
    out = [indent + ".byte   " + ", ".join(str(v) for v in lines[0])]
    for row in lines[1:]:
        out.append(indent + ".byte   " + ", ".join(str(v) for v in row))
    return "\n".join(out)


def fmt_points(label, pts, per_line=8):
    vals = []
    for x, y in pts:
        vals += [x, y]
    lines = [vals[i:i + per_line] for i in range(0, len(vals), per_line)] or [[]]
    lead = f"{label}:"
    pad = " " * max(1, 14 - len(lead))
    out = [lead + pad + ".byte " + ", ".join(fmt_cell(v) for v in lines[0])]
    for row in lines[1:]:
        out.append(" " * 14 + ".byte " + ", ".join(fmt_cell(v) for v in row))
    return "\n".join(out)


def _labeled_flat(label, vals, width=12):
    """'LABEL:  .byte  v0, v1, ...' - one or more lines, all through fmt_flat
    so a table that outgrows one line (more variants added) just wraps."""
    body = fmt_flat(vals, indent="")
    lead = f"{label}:"
    pad = " " * max(1, width - len(lead))
    first, *rest = body.split("\n")
    lines = [lead + pad + first] + ["            " + r for r in rest]
    return "\n".join(lines)


def _ptr_table(name, types, suffix, is_lod, present):
    """SHAPE_LO/HI or SHAPE_LODLO/LODHI: one <LABEL or >LABEL per shape id, a
    '0' placeholder where `present` says there is nothing to point at, one
    .byte line per size class (matches the hand-authored layout)."""
    op = "<" if suffix == "lo" else ">"
    lead = f"{name}:"
    lines = []
    for ci, c in enumerate(CLASSES):
        cells = []
        for t in types:
            k = (c, t)
            if present(k):
                cells.append(f"{op}SHP{c}_{t}" + ("_LOD" if is_lod else ""))
            else:
                cells.append("0")
        row = ", ".join(cells)
        if ci == 0:
            pad = " " * max(1, 13 - len(lead))
            lines.append(lead + pad + ".byte    " + row)
        else:
            lines.append(" " * 13 + ".byte    " + row)
    return "\n".join(lines)


def render_generated(model):
    at = model.ast_types
    types = model.types
    ids = [(c, t) for c in CLASSES for t in types]
    out = []
    out.append(f"AST_TYPES  = {at}                  ; authored variants per size class. TYPE_PICK")
    out.append("                                 ;   in main.s must have exactly this many values")
    out.append("CLASS_BASE: .byte " + ", ".join(f"{i}*AST_TYPES" for i in range(5)))
    out.append("                                 ; class -> the first shape id in that class,")
    out.append("                                 ;   so one_asteroid never has to multiply")
    out.append("")
    out.append("; per-shape-id tables, 5 classes x AST_TYPES, size-major")
    out.append(_labeled_flat("SHAPE_N", [len(model.shapes[k].full) for k in ids]))
    out.append(_labeled_flat("SHAPE_R", [model.shapes[k].r for k in ids]))
    out.append(_labeled_flat("SHAPE_OCC", [model.shapes[k].occ for k in ids]))
    out.append("")

    out.append(_ptr_table("SHAPE_LO", types, "lo", False, lambda k: True))
    out.append(_ptr_table("SHAPE_HI", types, "hi", False, lambda k: True))
    out.append("")
    out.append(_labeled_flat("SHAPE_LODN",
                              [len(model.shapes[k].lod) if model.shapes[k].lod else 0 for k in ids]))
    out.append(_ptr_table("SHAPE_LODLO", types, "lo", True, lambda k: model.shapes[k].lod is not None))
    out.append(_ptr_table("SHAPE_LODHI", types, "hi", True, lambda k: model.shapes[k].lod is not None))
    out.append("")

    for c in CLASSES:
        out.append(f"; {c} x {c} full-res -> radius {model.shapes[(c, types[0])].r} half-res")
        for t in types:
            s = model.shapes[(c, t)]
            out.append(fmt_points(f"SHP{c}_{t}", s.full))
        out.append("")

    lod_any = any(model.shapes[(c, t)].lod for c in CLASSES for t in types)
    if lod_any:
        out.append("; authored reduced (LOD) outlines")
        for c in CLASSES:
            for t in types:
                s = model.shapes[(c, t)]
                if s.lod:
                    out.append(fmt_points(f"SHP{c}_{t}_LOD", s.lod))
        out.append("")

    out.append(f"SHIP_VN     = {len(model.ship)}")
    out.append(fmt_points("SHIP_SHAPE", model.ship))
    return "\n".join(out)


def save_model(path, model):
    text = path.read_text(encoding="utf-8")
    start = text.index(SENTINEL_START) + len(SENTINEL_START)
    end = text.index(SENTINEL_END)
    body = render_generated(model)
    new_text = text[:start] + "\n" + body + "\n" + text[end:]
    path.write_text(new_text, encoding="utf-8")


def sync_type_pick(main_path, ast_types):
    """Best-effort: re-spread TYPE_PICK's 8 tickets evenly over AST_TYPES
    values so a newly added variant is not dead on arrival. Silently does
    nothing if main.s or the line cannot be found - this is a convenience,
    not a requirement, and the file is still correct without it (just biased
    toward the old type count until someone edits TYPE_PICK by hand)."""
    if not main_path.exists():
        return False
    text = main_path.read_text(encoding="utf-8")
    tickets = [i % ast_types for i in range(8)]
    new_line = "TYPE_PICK:  .byte  " + ", ".join(str(v) for v in tickets)
    new_text, n = re.subn(r'^TYPE_PICK:\s*\.byte.*$', new_line, text, count=1, flags=re.M)
    if n:
        main_path.write_text(new_text, encoding="utf-8")
    return bool(n)


# =============================================================================
# GUI
# =============================================================================
BG = "#101418"
GRID = "#26303a"
FULL_COLOR = "#7fd0ff"
LOD_COLOR = "#ffb347"
POINT_COLOR = "#ffffff"
SEL_COLOR = "#ff5566"
OCC_COLOR = "#232b35"                     # the hit-radius disc: a step up from
                                           #   BG, not a hard fill - see SHAPE_OCC
                                           #   in shapes.s, "also the number the
                                           #   collision radius should be"
                                           #   (design_technical.md 5.4)


class ShapeEditor(tk.Tk):
    def __init__(self, path):
        super().__init__()
        self.path = path
        self.title(f"EfS shape editor - {path}")
        self.geometry("1180x760")
        self.configure(bg=BG)

        self.model = Model.load(path.read_text(encoding="utf-8"))
        self.dirty = False
        self.cur_class = CLASSES[0]
        self.cur_type = self.model.types[0]
        self.edit_lod = False              # editing the reduced outline?
        self.sel_idx = None                # selected vertex index

        self._build_ui()
        self._refresh_all()

    # ---- UI scaffolding -----------------------------------------------------
    def _build_ui(self):
        top = tk.Frame(self, bg=BG)
        top.pack(side="top", fill="x", padx=8, pady=6)

        tk.Label(top, text="Shape:", bg=BG, fg="white").pack(side="left")
        self.class_var = tk.StringVar(value=str(self.cur_class))
        cls_menu = ttk.Combobox(top, textvariable=self.class_var, state="readonly", width=6,
                                 values=[str(c) for c in CLASSES] + ["SHIP"])
        cls_menu.pack(side="left", padx=(2, 10))
        cls_menu.bind("<<ComboboxSelected>>", self._on_class_change)

        self.type_frame = tk.Frame(top, bg=BG)
        self.type_frame.pack(side="left", padx=(0, 10))
        self.type_var = tk.StringVar(value=self.cur_type)

        self.lod_var = tk.StringVar(value="full")
        self.lod_full_rb = tk.Radiobutton(top, text="Full outline", variable=self.lod_var,
                                           value="full", command=self._on_lod_toggle,
                                           bg=BG, fg="white", selectcolor="#333")
        self.lod_lod_rb = tk.Radiobutton(top, text="Reduced (LOD)", variable=self.lod_var,
                                          value="lod", command=self._on_lod_toggle,
                                          bg=BG, fg="white", selectcolor="#333")
        self.lod_full_rb.pack(side="left")
        self.lod_lod_rb.pack(side="left", padx=(0, 10))

        tk.Button(top, text="Author reduced from full", command=self._author_lod).pack(side="left", padx=4)
        tk.Button(top, text="Remove reduced", command=self._remove_lod).pack(side="left", padx=4)
        tk.Button(top, text="+ New variant", command=self._add_variant).pack(side="left", padx=(14, 4))

        right_btns = tk.Frame(top, bg=BG)
        right_btns.pack(side="right")
        tk.Button(right_btns, text="Copy ASM snippet", command=self._copy_snippet).pack(side="left", padx=4)
        tk.Button(right_btns, text="Reload", command=self._reload).pack(side="left", padx=4)
        self.save_btn = tk.Button(right_btns, text="Save to shapes.s", command=self._save,
                                   bg="#2a6", fg="white")
        self.save_btn.pack(side="left", padx=4)

        mid = tk.Frame(self, bg=BG)
        mid.pack(side="top", fill="both", expand=True, padx=8, pady=4)

        # big edit canvas
        left = tk.Frame(mid, bg=BG)
        left.pack(side="left", fill="both", expand=True)
        tk.Label(left, text="Edit (drag a point; double-click an edge to add one; "
                             "select + Delete to remove)", bg=BG, fg="#888").pack(anchor="w")
        self.edit_canvas = tk.Canvas(left, bg=BG, highlightthickness=0)
        self.edit_canvas.pack(fill="both", expand=True)
        self.edit_canvas.bind("<Configure>", lambda e: self._draw_edit())
        self.edit_canvas.bind("<ButtonPress-1>", self._edit_press)
        self.edit_canvas.bind("<B1-Motion>", self._edit_drag)
        self.edit_canvas.bind("<ButtonRelease-1>", self._edit_release)
        self.edit_canvas.bind("<Double-Button-1>", self._edit_dblclick)
        self.bind("<Delete>", self._delete_selected)
        self.bind("<BackSpace>", self._delete_selected)

        # right column: two true-scale previews + numeric fields
        right = tk.Frame(mid, bg=BG, width=300)
        right.pack(side="left", fill="y", padx=(10, 0))
        right.pack_propagate(False)

        tk.Label(right, text="Normal (1:1, resting zoom)", bg=BG, fg="#888").pack(anchor="w")
        self.prev_normal = tk.Canvas(right, bg=BG, height=180, highlightthickness=1,
                                      highlightbackground=GRID)
        self.prev_normal.pack(fill="x", pady=(0, 8))

        tk.Label(right, text="Max zoom-out (top speed, RZ 64)", bg=BG, fg="#888").pack(anchor="w")
        self.prev_far = tk.Canvas(right, bg=BG, height=180, highlightthickness=1,
                                   highlightbackground=GRID)
        self.prev_far.pack(fill="x", pady=(0, 8))

        for c in (self.prev_normal, self.prev_far):
            c.bind("<Configure>", lambda e: self._draw_previews())

        form = tk.Frame(right, bg=BG)
        form.pack(fill="x", pady=6)
        self.field_vars = {}
        for i, (key, label) in enumerate([("n", "Vertices (N)"), ("r", "Bounding radius (R)"),
                                           ("occ", "Star-occlusion radius")]):
            tk.Label(form, text=label, bg=BG, fg="white").grid(row=i, column=0, sticky="w", pady=2)
            var = tk.StringVar()
            state = "readonly" if key == "n" else "normal"
            e = tk.Entry(form, textvariable=var, width=6, state=state)
            e.grid(row=i, column=1, padx=6)
            if key != "n":
                e.bind("<Return>", lambda ev, k=key: self._commit_field(k))
                e.bind("<FocusOut>", lambda ev, k=key: self._commit_field(k))
            self.field_vars[key] = var

        sel_frame = tk.Frame(right, bg=BG)
        sel_frame.pack(fill="x", pady=6)
        self.sel_label = tk.Label(sel_frame, text="No point selected", bg=BG, fg="#888")
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

        self.warn_label = tk.Label(right, text="", bg=BG, fg="#ff6666", wraplength=280,
                                    justify="left")
        self.warn_label.pack(fill="x", pady=6)

        self.status = tk.Label(self, text="", bg=BG, fg="#888", anchor="w")
        self.status.pack(side="bottom", fill="x", padx=8, pady=4)

    # ---- state -> data helpers ----------------------------------------------
    def _shape(self):
        if self.cur_class == "SHIP":
            return None
        return self.model.shapes[(self.cur_class, self.cur_type)]

    def _points(self):
        """The point list currently being edited: the ship's own outline, or
        a rock's full or reduced one - all the same shape, an editable closed
        polygon, so the rest of the editor does not need to special-case it."""
        if self.cur_class == "SHIP":
            return self.model.ship
        s = self._shape()
        pts = s.lod if self.edit_lod else s.full
        return pts or []

    def _set_points(self, pts):
        if self.cur_class == "SHIP":
            self.model.ship = pts
            self.dirty = True
            self._update_status()
            return
        s = self._shape()
        if self.edit_lod:
            s.lod = pts
        else:
            s.full = pts
        self.dirty = True
        self._update_status()

    # ---- top controls ---------------------------------------------------
    def _rebuild_type_row(self):
        for w in self.type_frame.winfo_children():
            w.destroy()
        if self.cur_class == "SHIP":
            return
        for t in self.model.types:
            tk.Radiobutton(self.type_frame, text=t, variable=self.type_var, value=t,
                            command=self._on_type_change, bg=BG, fg="white",
                            selectcolor="#333").pack(side="left")

    def _on_class_change(self, _evt=None):
        v = self.class_var.get()
        self.cur_class = int(v) if v != "SHIP" else "SHIP"
        if self.cur_class != "SHIP" and self.cur_type not in self.model.types:
            self.cur_type = self.model.types[0]
        self.type_var.set(self.cur_type)
        self._rebuild_type_row()
        self.sel_idx = None
        self._refresh_all()

    def _on_type_change(self):
        self.cur_type = self.type_var.get()
        self.sel_idx = None
        self._refresh_all()

    def _on_lod_toggle(self):
        self.edit_lod = (self.lod_var.get() == "lod")
        self.sel_idx = None
        self._refresh_all()

    # ---- LOD management ---------------------------------------------------
    def _author_lod(self):
        s = self._shape()
        if s is None:
            return
        if s.lod:
            if not messagebox.askyesno("Replace reduced outline",
                                        "This shape already has a reduced outline. "
                                        "Regenerate it from the full one?"):
                return
        n = max(3, len(s.full) // 2)
        step = len(s.full) / n
        s.lod = [s.full[int(i * step) % len(s.full)] for i in range(n)]
        self.dirty = True
        self.lod_var.set("lod")
        self.edit_lod = True
        self._refresh_all()

    def _remove_lod(self):
        s = self._shape()
        if s is None or not s.lod:
            return
        if messagebox.askyesno("Remove reduced outline",
                                "This shape will always draw at full detail. Continue?"):
            s.lod = None
            self.dirty = True
            self.lod_var.set("full")
            self.edit_lod = False
            self._refresh_all()

    def _add_variant(self):
        if self.cur_class == "SHIP":
            return
        letters = string.ascii_uppercase
        new_letter = letters[self.model.ast_types]
        if self.model.ast_types >= 8:
            messagebox.showinfo("Limit", "TYPE_PICK has 8 tickets; 8 variants is the "
                                          "practical ceiling without also editing that "
                                          "table's spread by hand.")
            return
        # seed the new type in every class from type A, nudged so it doesn't
        # sit exactly on top of it
        base_type = self.model.types[0]
        for c in CLASSES:
            src = self.model.shapes[(c, base_type)]
            ang_off = 2 * math.pi / (3 * max(1, len(src.full)))
            pts = _rotate(src.full, ang_off)
            lod = _rotate(src.lod, ang_off) if src.lod else None
            self.model.shapes[(c, new_letter)] = Shape(c, new_letter, src.r, src.occ, pts, lod)
        self.model.ast_types += 1
        self.dirty = True
        synced = sync_type_pick(DEFAULT_MAIN, self.model.ast_types)
        self._rebuild_type_row()
        self.type_var.set(new_letter)
        self.cur_type = new_letter
        msg = f"Added variant {new_letter} to every size class."
        msg += " Updated TYPE_PICK in main.s." if synced else (
            " Could not update TYPE_PICK in main.s automatically - "
            "add a value there by hand or the new variant will never be picked.")
        messagebox.showinfo("New variant", msg)
        self._refresh_all()

    # ---- canvas geometry ----------------------------------------------------
    def _edit_transform(self):
        w = self.edit_canvas.winfo_width() or 400
        h = self.edit_canvas.winfo_height() or 400
        cx, cy = w / 2, h / 2
        pts = self._points()
        span = max([abs(x) for x, y in pts] + [abs(y) for x, y in pts] + [4])
        scale = 0.85 * min(w, h) / 2 / span
        return cx, cy, scale

    def _to_canvas(self, cx, cy, scale, p):
        return cx + p[0] * scale, cy + p[1] * scale

    def _from_canvas(self, cx, cy, scale, x, y):
        return (x - cx) / scale, (y - cy) / scale

    # ---- drawing --------------------------------------------------------
    def _refresh_all(self):
        s = self._shape()
        if s is not None:
            self.field_vars["n"].set(str(len(s.full) if not self.edit_lod else len(s.lod or [])))
            self.field_vars["r"].set(str(s.r))
            self.field_vars["occ"].set(str(s.occ))
            self.lod_lod_rb.configure(state="normal" if s.lod else "disabled")
            if not s.lod and self.edit_lod:
                self.edit_lod = False
                self.lod_var.set("full")
        else:
            self.field_vars["n"].set(str(len(self.model.ship)))
            self.field_vars["r"].set("-")
            self.field_vars["occ"].set("-")
            self.lod_lod_rb.configure(state="disabled")
        self._draw_edit()
        self._draw_previews()
        self._update_status()

    def _update_status(self):
        which = "SHIP" if self.cur_class == "SHIP" else f"{self.cur_class}-class, variant {self.cur_type}"
        target = " (reduced/LOD)" if self.edit_lod else ""
        star = "* " if self.dirty else ""
        self.status.configure(text=f"{star}{which}{target}  -  {self.path}")

    def _draw_edit(self):
        c = self.edit_canvas
        c.delete("all")
        w = c.winfo_width() or 400
        h = c.winfo_height() or 400
        cx, cy, scale = self._edit_transform()
        # grid + axes
        for gx in range(-200, 201, 16):
            x = cx + gx * scale
            if 0 <= x <= w:
                c.create_line(x, 0, x, h, fill=GRID)
        for gy in range(-200, 201, 16):
            y = cy + gy * scale
            if 0 <= y <= h:
                c.create_line(0, y, w, y, fill=GRID)
        c.create_line(cx, 0, cx, h, fill="#3a4552")
        c.create_line(0, cy, w, cy, fill="#3a4552")

        if self.cur_class != "SHIP":
            occ = self._shape().occ
            r = occ * scale
            c.create_oval(cx - r, cy - r, cx + r, cy + r, fill=OCC_COLOR, outline="")

        pts = self._points()
        self._refresh_sel_fields()
        if not pts:
            return
        poly = []
        for p in pts:
            poly += list(self._to_canvas(cx, cy, scale, p))
        if len(pts) >= 2:
            color = LOD_COLOR if self.edit_lod else FULL_COLOR
            c.create_polygon(*poly, outline=color, fill="", width=2)
        for i, p in enumerate(pts):
            x, y = self._to_canvas(cx, cy, scale, p)
            r = 6 if i == self.sel_idx else 4
            fill = SEL_COLOR if i == self.sel_idx else POINT_COLOR
            c.create_oval(x - r, y - r, x + r, y + r, fill=fill, outline="")
            c.create_text(x + 10, y - 10, text=str(i), fill="#666", font=("Consolas", 8))

        bad = [i for i, (x, y) in enumerate(pts) if abs(x) > VERTEX_MAX or abs(y) > VERTEX_MAX]
        if bad:
            self.warn_label.configure(text=f"Vertex {bad} exceeds |v|<=127 - qmul's table "
                                            f"index would overflow a byte. Fix before saving.")
        else:
            self.warn_label.configure(text="")

    def _draw_previews(self):
        pts = self._points()
        if self.cur_class == "SHIP":
            full_pts, lod_pts, occ = pts, None, None
        else:
            s = self._shape()
            full_pts, lod_pts, occ = s.full, s.lod, s.occ
        for canvas, rz, label in ((self.prev_normal, 128, "1:1"), (self.prev_far, 64, "2x out")):
            canvas.delete("all")
            w = canvas.winfo_width() or 260
            h = canvas.winfo_height() or 180
            cx, cy = w / 2, h / 2
            # half-res unit -> 2 full-res screen px at RZ128 (1:1); RZ64 halves that
            px_per_unit = 2 * (rz / 128) if self.cur_class != "SHIP" else (rz / 128)
            if occ is not None:
                r = occ * px_per_unit
                canvas.create_oval(cx - r, cy - r, cx + r, cy + r, fill=OCC_COLOR, outline="")
            for src, color, dash in ((full_pts, FULL_COLOR, None), (lod_pts, LOD_COLOR, (3, 2))):
                if not src:
                    continue
                poly = []
                for x, y in src:
                    poly += [cx + x * px_per_unit, cy + y * px_per_unit]
                kwargs = {"outline": color, "fill": "", "width": 1}
                if dash:
                    kwargs["dash"] = dash
                if len(src) >= 2:
                    canvas.create_polygon(*poly, **kwargs)
            canvas.create_text(6, 6, text=label, fill="#666", anchor="nw", font=("Consolas", 8))

    # ---- edit-canvas interaction -------------------------------------------
    def _hit_test(self, x, y):
        cx, cy, scale = self._edit_transform()
        for i, p in enumerate(self._points()):
            px, py = self._to_canvas(cx, cy, scale, p)
            if (px - x) ** 2 + (py - y) ** 2 <= 100:
                return i
        return None

    def _edit_press(self, ev):
        i = self._hit_test(ev.x, ev.y)
        self.sel_idx = i
        self._drag_active = i is not None
        self._draw_edit()

    def _edit_drag(self, ev):
        if self.sel_idx is None:
            return
        cx, cy, scale = self._edit_transform()
        wx, wy = self._from_canvas(cx, cy, scale, ev.x, ev.y)
        pt = (round(wx), round(wy))
        pts = list(self._points())
        pts[self.sel_idx] = pt
        self._set_points(pts)
        self._draw_edit()
        self._draw_previews()

    def _edit_release(self, _ev):
        self._update_status()

    def _edit_dblclick(self, ev):
        pts = list(self._points())
        if len(pts) < 2:
            return
        cx, cy, scale = self._edit_transform()
        wx, wy = self._from_canvas(cx, cy, scale, ev.x, ev.y)
        best, best_d, best_at = None, None, None
        for i in range(len(pts)):
            a, b = pts[i], pts[(i + 1) % len(pts)]
            mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
            d = (mx - wx) ** 2 + (my - wy) ** 2
            if best_d is None or d < best_d:
                best, best_d, best_at = (round(mx), round(my)), d, i + 1
        pts.insert(best_at, best)
        self.sel_idx = best_at
        self._set_points(pts)
        self._draw_edit()
        self._draw_previews()

    def _delete_selected(self, _ev=None):
        if self.sel_idx is None:
            return
        pts = list(self._points())
        if len(pts) <= 3:
            messagebox.showinfo("Minimum vertices", "A closed outline needs at least 3 points.")
            return
        del pts[self.sel_idx]
        self.sel_idx = None
        self._set_points(pts)
        self._draw_edit()
        self._draw_previews()

    # ---- selected-point fields ----------------------------------------------
    def _refresh_sel_fields(self):
        pts = self._points()
        if self.sel_idx is None or self.sel_idx >= len(pts):
            self.sel_label.configure(text="No point selected")
            self.selx_var.set("")
            self.sely_var.set("")
        else:
            x, y = pts[self.sel_idx]
            self.sel_label.configure(text=f"Point {self.sel_idx} (relative to centre)")
            self.selx_var.set(str(x))
            self.sely_var.set(str(y))

    def _commit_sel_point(self):
        if self.sel_idx is None:
            return
        pts = list(self._points())
        if self.sel_idx >= len(pts):
            return
        try:
            x = int(self.selx_var.get())
            y = int(self.sely_var.get())
        except ValueError:
            self._refresh_sel_fields()
            return
        pts[self.sel_idx] = (x, y)
        self._set_points(pts)
        self._draw_edit()
        self._draw_previews()

    # ---- numeric fields ---------------------------------------------------
    def _commit_field(self, key):
        if self.cur_class == "SHIP":
            return
        s = self._shape()
        if s is None:
            return
        try:
            v = int(self.field_vars[key].get())
        except ValueError:
            self._refresh_all()
            return
        setattr(s, key, max(1, v))
        self.dirty = True
        self._draw_previews()
        self._update_status()

    # ---- file ops -----------------------------------------------------------
    def _copy_snippet(self):
        if self.cur_class == "SHIP":
            label = "ship"
            text = f"SHIP_VN     = {len(self.model.ship)}\n" + fmt_points("SHIP_SHAPE", self.model.ship) + "\n"
        else:
            s = self._shape()
            label = f"SHP{s.cls}_{s.type}" + ("_LOD" if self.edit_lod else "")
            pts = s.lod if self.edit_lod else s.full
            text = fmt_points(label, pts) + "\n"
        self.clipboard_clear()
        self.clipboard_append(text)
        self.status.configure(text=f"Copied {label} to clipboard.")

    def _save(self):
        bad = []
        for s in self.model.shapes.values():
            for pts, tag in ((s.full, "full"), (s.lod or [], "lod")):
                for x, y in pts:
                    if abs(x) > VERTEX_MAX or abs(y) > VERTEX_MAX:
                        bad.append(f"{s.cls}{s.type} {tag}")
        if bad:
            messagebox.showerror("Out of range", "These outlines have a vertex past |v|<=127 "
                                                   "and would break qmul's table index:\n" +
                                                   ", ".join(sorted(set(bad))))
            return
        save_model(self.path, self.model)
        self.dirty = False
        self._update_status()
        self.status.configure(text=f"Saved {self.path}")

    def _reload(self):
        if self.dirty and not messagebox.askyesno("Reload", "Discard unsaved changes?"):
            return
        self.model = Model.load(self.path.read_text(encoding="utf-8"))
        self.dirty = False
        self.sel_idx = None
        self._rebuild_type_row()
        self._refresh_all()


def _rotate(pts, ang):
    ca, sa = math.cos(ang), math.sin(ang)
    return [(round(x * ca - y * sa), round(x * sa + y * ca)) for x, y in pts]


def main():
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SHAPES
    if not path.exists():
        print(f"no such file: {path}", file=sys.stderr)
        sys.exit(1)
    app = ShapeEditor(path)
    app.mainloop()


if __name__ == "__main__":
    main()
