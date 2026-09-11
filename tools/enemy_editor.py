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

Only the GENERATED block in enemies.s is ever touched, rewritten WHOLE on
every Save, same discipline as tools/shape_editor.py - which this borrows its
parsing and negative-byte formatting from.

Left canvas: drag a handle to move it, double-click an edge to insert a
vertex there, select + Delete to remove one (3-vertex floor when closed,
2-vertex floor when open). All of the current enemy's parts are drawn for
context; only the selected part's handles are draggable. Right column:
pick/add/remove enemy shapes and parts, and the numeric fields for whatever
is selected.

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
    __slots__ = ("pts", "closed")

    def __init__(self, pts, closed):
        self.pts = pts            # K points; closed wraps last->first, open does not
        self.closed = closed

    @classmethod
    def new_closed(cls):
        return cls([(-10, 0), (0, -10), (10, 0), (0, 10)], True)

    @classmethod
    def new_open(cls):
        return cls([(-10, 0), (10, 0)], False)

    def min_pts(self):
        return 3 if self.closed else 2


class Enemy:
    __slots__ = ("name", "parts")

    def __init__(self, name, parts=None):
        self.name = name
        self.parts = parts if parts is not None else [Part.new_closed()]


class Model:
    def __init__(self, enemies):
        self.enemies = enemies    # [Enemy, ...], order is draw order

    @classmethod
    def load(cls, text):
        scalars, blocks = parse_generated_block(text, SENTINEL_START, SENTINEL_END)
        names = [m.group(1) for k in scalars
                 for m in [re.match(r'^EN_(.+)_PN$', k)] if m]
        enemies = []
        for name in names:
            pn = scalars[f"EN_{name}_PN"]
            parts = []
            for i in range(pn):
                raw = blocks.get(f"EN_{name}_P{i}", [])
                if not raw:
                    parts.append(Part.new_closed())
                    continue
                header = raw[0]
                closed = not (header & OPEN_BIT)
                k = header & 0x7F
                coords = raw[1:1 + 2 * k]
                pts = list(zip(coords[0::2], coords[1::2]))
                floor = 3 if closed else 2
                if len(pts) < floor:
                    pts = (Part.new_closed() if closed else Part.new_open()).pts
                parts.append(Part(pts, closed))
            enemies.append(Enemy(name, parts))
        return cls(enemies)


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


def fmt_ptr_line(label, op, part_labels, width=15):
    lead = f"{label}:"
    pad = " " * max(1, width - len(lead))
    return lead + pad + ".byte " + ", ".join(f"{op}{p}" for p in part_labels)


def render_generated(model):
    if not model.enemies:
        return "; (no enemy shapes authored yet - open tools/enemy_editor.py to add the first)"
    out = []
    for e in model.enemies:
        n = e.name
        out.append(f"; ---- {n} ----")
        out.append(f"EN_{n}_PN     = {len(e.parts)}")
        labels = [f"EN_{n}_P{i}" for i in range(len(e.parts))]
        out.append(fmt_ptr_line(f"EN_{n}_PLO", "<", labels))
        out.append(fmt_ptr_line(f"EN_{n}_PHI", ">", labels))
        for i, p in enumerate(e.parts):
            header = len(p.pts) | (0 if p.closed else OPEN_BIT)
            vals = [header]
            for x, y in p.pts:
                vals += [x, y]
            out.append(fmt_byte_line(labels[i], vals))
        out.append("")
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
GRID = "#26303a"
CLOSED_COLOR = "#7fd0ff"
OPEN_COLOR = "#ffb347"
DIM_COLOR = "#3a4552"       # context-only color for parts that are not selected
POINT_COLOR = "#ffffff"
SEL_COLOR = "#ff5566"


class EnemyEditor(tk.Tk):
    def __init__(self, path):
        super().__init__()
        self.path = path
        self.title(f"EfS enemy editor - {path}")
        self.geometry("1180x760")
        self.configure(bg=BG)

        self.model = Model.load(path.read_text(encoding="utf-8"))
        self.dirty = False
        self.cur_enemy_i = 0 if self.model.enemies else None
        self.cur_part_i = 0 if self.model.enemies else None
        self.sel_idx = None            # selected handle index within the part

        self._build_ui()
        self._refresh_all()

    # ---- state helpers -------------------------------------------------
    def _enemy(self):
        if self.cur_enemy_i is None:
            return None
        return self.model.enemies[self.cur_enemy_i]

    def _part(self):
        e = self._enemy()
        if e is None or self.cur_part_i is None or self.cur_part_i >= len(e.parts):
            return None
        return e.parts[self.cur_part_i]

    # ---- UI scaffolding --------------------------------------------------
    def _build_ui(self):
        top = tk.Frame(self, bg=BG)
        top.pack(side="top", fill="x", padx=8, pady=6)

        tk.Label(top, text="Enemy:", bg=BG, fg="white").pack(side="left")
        self.enemy_var = tk.StringVar()
        self.enemy_menu = ttk.Combobox(top, textvariable=self.enemy_var, state="readonly", width=18)
        self.enemy_menu.pack(side="left", padx=(2, 6))
        self.enemy_menu.bind("<<ComboboxSelected>>", self._on_enemy_change)

        tk.Button(top, text="+ New enemy", command=self._new_enemy).pack(side="left", padx=2)
        tk.Button(top, text="Rename", command=self._rename_enemy).pack(side="left", padx=2)
        tk.Button(top, text="Delete enemy", command=self._delete_enemy).pack(side="left", padx=(2, 14))

        right_btns = tk.Frame(top, bg=BG)
        right_btns.pack(side="right")
        tk.Button(right_btns, text="Copy ASM snippet", command=self._copy_snippet).pack(side="left", padx=4)
        tk.Button(right_btns, text="Reload", command=self._reload).pack(side="left", padx=4)
        self.save_btn = tk.Button(right_btns, text="Save to enemies.s", command=self._save,
                                   bg="#2a6", fg="white")
        self.save_btn.pack(side="left", padx=4)

        mid = tk.Frame(self, bg=BG)
        mid.pack(side="top", fill="both", expand=True, padx=8, pady=4)

        left = tk.Frame(mid, bg=BG)
        left.pack(side="left", fill="both", expand=True)
        tk.Label(left, text="Edit (drag a handle; double-click an edge to add a vertex; "
                             "select + Delete to remove)", bg=BG, fg="#888").pack(anchor="w")
        self.edit_canvas = tk.Canvas(left, bg=BG, highlightthickness=0, takefocus=1)
        self.edit_canvas.pack(fill="both", expand=True)
        self.edit_canvas.bind("<Configure>", lambda e: self._draw_edit())
        self.edit_canvas.bind("<ButtonPress-1>", self._edit_press)
        self.edit_canvas.bind("<B1-Motion>", self._edit_drag)
        self.edit_canvas.bind("<ButtonRelease-1>", self._edit_release)
        self.edit_canvas.bind("<Double-Button-1>", self._edit_dblclick)
        self.edit_canvas.bind("<Delete>", self._delete_selected)
        self.edit_canvas.bind("<BackSpace>", self._delete_selected)

        right = tk.Frame(mid, bg=BG, width=300)
        right.pack(side="left", fill="y", padx=(10, 0))
        right.pack_propagate(False)

        tk.Label(right, text="Parts (draw order)", bg=BG, fg="#888").pack(anchor="w")
        self.part_list = tk.Listbox(right, height=8, bg="#181d24", fg="white",
                                     selectbackground="#345", highlightthickness=0, exportselection=False)
        self.part_list.pack(fill="x", pady=(0, 4))
        self.part_list.bind("<<ListboxSelect>>", self._on_part_select)

        part_btns = tk.Frame(right, bg=BG)
        part_btns.pack(fill="x", pady=(0, 2))
        tk.Button(part_btns, text="+ Closed part", command=self._add_closed).pack(side="left", padx=2)
        tk.Button(part_btns, text="+ Open part", command=self._add_open).pack(side="left", padx=2)
        part_btns2 = tk.Frame(right, bg=BG)
        part_btns2.pack(fill="x", pady=(0, 6))
        tk.Button(part_btns2, text="Toggle closed/open", command=self._toggle_closed).pack(side="left", padx=2)
        tk.Button(part_btns2, text="Delete part", command=self._delete_part).pack(side="left", padx=2)
        move_btns = tk.Frame(right, bg=BG)
        move_btns.pack(fill="x", pady=(0, 8))
        tk.Button(move_btns, text="Move up", command=lambda: self._move_part(-1)).pack(side="left", padx=2)
        tk.Button(move_btns, text="Move down", command=lambda: self._move_part(1)).pack(side="left", padx=2)

        circle_frame = tk.Frame(right, bg=BG)
        circle_frame.pack(fill="x", pady=(0, 8))
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

        tk.Label(right, text="Preview (1:1 full-res)", bg=BG, fg="#888").pack(anchor="w", pady=(10, 0))
        self.preview = tk.Canvas(right, bg=BG, height=180, highlightthickness=1, highlightbackground=GRID)
        self.preview.pack(fill="x", pady=(0, 8))
        self.preview.bind("<Configure>", lambda e: self._draw_preview())

        self.warn_label = tk.Label(right, text="", bg=BG, fg="#ff6666", wraplength=280, justify="left")
        self.warn_label.pack(fill="x", pady=6)

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
        self.cur_part_i = 0
        self.sel_idx = None
        self.dirty = True
        self._refresh_enemy_menu()
        self._refresh_all()

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
        self.cur_part_i = 0 if self.model.enemies else None
        self.sel_idx = None
        self.dirty = True
        self._refresh_enemy_menu()
        self._refresh_all()

    def _on_enemy_change(self, _evt=None):
        names = [e.name for e in self.model.enemies]
        self.cur_enemy_i = names.index(self.enemy_var.get())
        self.cur_part_i = 0 if self._enemy().parts else None
        self.sel_idx = None
        self._refresh_all()

    # ---- part management --------------------------------------------------
    def _refresh_part_list(self):
        self.part_list.delete(0, "end")
        e = self._enemy()
        if e is None:
            return
        for p in e.parts:
            tag = "closed" if p.closed else "open"
            self.part_list.insert("end", f"{tag} ({len(p.pts)} pts)")
        if self.cur_part_i is not None and 0 <= self.cur_part_i < len(e.parts):
            self.part_list.selection_set(self.cur_part_i)

    def _add_closed(self):
        e = self._enemy()
        if e is None:
            return
        e.parts.append(Part.new_closed())
        self.cur_part_i = len(e.parts) - 1
        self.sel_idx = None
        self.dirty = True
        self._refresh_all()

    def _add_open(self):
        e = self._enemy()
        if e is None:
            return
        e.parts.append(Part.new_open())
        self.cur_part_i = len(e.parts) - 1
        self.sel_idx = None
        self.dirty = True
        self._refresh_all()

    def _toggle_closed(self):
        p = self._part()
        if p is None:
            return
        if p.closed and len(p.pts) < 2:
            return
        if not p.closed and len(p.pts) < 3:
            messagebox.showinfo("Toggle closed/open", "Needs at least 3 points to close.")
            return
        p.closed = not p.closed
        self.dirty = True
        self._refresh_all()

    def _delete_part(self):
        e = self._enemy()
        p = self._part()
        if e is None or p is None:
            return
        del e.parts[self.cur_part_i]
        self.cur_part_i = min(self.cur_part_i, len(e.parts) - 1) if e.parts else None
        self.sel_idx = None
        self.dirty = True
        self._refresh_all()

    def _move_part(self, d):
        e = self._enemy()
        if e is None or self.cur_part_i is None:
            return
        i, j = self.cur_part_i, self.cur_part_i + d
        if j < 0 or j >= len(e.parts):
            return
        e.parts[i], e.parts[j] = e.parts[j], e.parts[i]
        self.cur_part_i = j
        self.dirty = True
        self._refresh_all()

    def _on_part_select(self, _evt=None):
        sel = self.part_list.curselection()
        if not sel:
            return
        self.cur_part_i = sel[0]
        self.sel_idx = None
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
        self.sel_idx = None
        self.dirty = True
        self._refresh_all()

    # ---- canvas geometry ----------------------------------------------------
    def _all_pts(self):
        e = self._enemy()
        pts = []
        if e:
            for p in e.parts:
                pts += p.pts
        return pts

    def _edit_transform(self):
        w = self.edit_canvas.winfo_width() or 400
        h = self.edit_canvas.winfo_height() or 400
        cx, cy = w / 2, h / 2
        pts = self._all_pts()
        span = max([abs(x) for x, y in pts] + [abs(y) for x, y in pts] + [4])
        scale = 0.85 * min(w, h) / 2 / span
        return cx, cy, scale

    def _to_canvas(self, cx, cy, scale, pt):
        vx, vy = to_view(pt)
        return cx + vx * scale, cy + vy * scale

    def _from_canvas(self, cx, cy, scale, x, y):
        return from_view((x - cx) / scale, (y - cy) / scale)

    # ---- drawing --------------------------------------------------------
    def _refresh_all(self):
        self._refresh_enemy_menu()
        self._refresh_part_list()
        self._draw_edit()
        self._draw_preview()
        self._update_status()

    def _update_status(self):
        e = self._enemy()
        star = "* " if self.dirty else ""
        which = e.name if e else "(no enemies)"
        self.status.configure(text=f"{star}{which}  -  {self.path}")

    def _draw_edit(self):
        c = self.edit_canvas
        c.delete("all")
        w = c.winfo_width() or 400
        h = c.winfo_height() or 400
        cx, cy, scale = self._edit_transform()
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
        c.create_oval(cx - 3, cy - 3, cx + 3, cy + 3, outline="#556", width=1)  # shared anchor

        e = self._enemy()
        if e is None:
            self._refresh_sel_fields()
            return
        for i, p in enumerate(e.parts):
            self._draw_part(c, cx, cy, scale, p, i == self.cur_part_i)

        self._refresh_sel_fields()
        bad = []
        if self._part():
            bad = [i for i, (x, y) in enumerate(self._part().pts) if abs(x) > VERTEX_MAX or abs(y) > VERTEX_MAX]
        if bad:
            self.warn_label.configure(text=f"Point {bad} exceeds |v|<=127 - the offset would not "
                                            f"fit a signed byte on the wire. Fix before saving.")
        else:
            self.warn_label.configure(text="")

    def _draw_part(self, c, cx, cy, scale, p, selected):
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
        if selected:
            for i, pt in enumerate(p.pts):
                x, y = self._to_canvas(cx, cy, scale, pt)
                r = 6 if i == self.sel_idx else 4
                fill = SEL_COLOR if i == self.sel_idx else POINT_COLOR
                c.create_oval(x - r, y - r, x + r, y + r, fill=fill, outline="")
                c.create_text(x + 10, y - 10, text=str(i), fill="#666", font=("Consolas", 8))

    def _draw_preview(self):
        c = self.preview
        c.delete("all")
        w = c.winfo_width() or 260
        h = c.winfo_height() or 180
        cx, cy = w / 2, h / 2
        e = self._enemy()
        if e is None:
            return
        for p in e.parts:
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

    # ---- edit-canvas interaction -------------------------------------------
    def _hit_test(self, x, y):
        p = self._part()
        if p is None:
            return None
        cx, cy, scale = self._edit_transform()
        for i, pt in enumerate(p.pts):
            px, py = self._to_canvas(cx, cy, scale, pt)
            if (px - x) ** 2 + (py - y) ** 2 <= 100:
                return i
        return None

    def _edit_press(self, ev):
        self.edit_canvas.focus_set()
        self.sel_idx = self._hit_test(ev.x, ev.y)
        self._draw_edit()

    def _edit_drag(self, ev):
        p = self._part()
        if p is None or self.sel_idx is None:
            return
        cx, cy, scale = self._edit_transform()
        wx, wy = self._from_canvas(cx, cy, scale, ev.x, ev.y)
        pts = list(p.pts)
        pts[self.sel_idx] = (round(wx), round(wy))
        p.pts = pts
        self.dirty = True
        self._draw_edit()
        self._draw_preview()

    def _edit_release(self, _ev):
        self._update_status()

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
        self.sel_idx = best_at
        self.dirty = True
        self._draw_edit()
        self._draw_preview()

    def _delete_selected(self, _ev=None):
        p = self._part()
        if p is None or self.sel_idx is None:
            return
        if len(p.pts) <= p.min_pts():
            floor = "3 points" if p.closed else "2 points"
            messagebox.showinfo("Minimum vertices", f"A {'closed' if p.closed else 'open'} "
                                                      f"part needs at least {floor}.")
            return
        pts = list(p.pts)
        del pts[self.sel_idx]
        p.pts = pts
        self.sel_idx = None
        self.dirty = True
        self._draw_edit()
        self._draw_preview()

    # ---- selected-handle fields ----------------------------------------------
    def _refresh_sel_fields(self):
        p = self._part()
        if p is None or self.sel_idx is None or self.sel_idx >= len(p.pts):
            self.sel_label.configure(text="No handle selected")
            self.selx_var.set("")
            self.sely_var.set("")
        else:
            x, y = to_view(p.pts[self.sel_idx])
            self.sel_label.configure(text=f"Point {self.sel_idx} (player's x/y from the anchor)")
            self.selx_var.set(str(x))
            self.sely_var.set(str(y))

    def _commit_sel_point(self):
        p = self._part()
        if p is None or self.sel_idx is None or self.sel_idx >= len(p.pts):
            return
        try:
            x = int(self.selx_var.get())
            y = int(self.sely_var.get())
        except ValueError:
            self._refresh_sel_fields()
            return
        pts = list(p.pts)
        pts[self.sel_idx] = from_view(x, y)
        p.pts = pts
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
            if not e.parts:
                bad.append(f"{e.name}: no parts")
                continue
            for p in e.parts:
                if len(p.pts) > 0x7F:
                    bad.append(f"{e.name}: a part has more than 127 vertices")
                for x, y in p.pts:
                    if abs(x) > VERTEX_MAX or abs(y) > VERTEX_MAX:
                        bad.append(f"{e.name}: point past |v|<=127")
        if bad:
            messagebox.showerror("Out of range", "Fix these before saving:\n" + "\n".join(sorted(set(bad))))
            return
        save_model(self.path, self.model)
        self.dirty = False
        self._update_status()
        self.status.configure(text=f"Saved {self.path}")

    def _reload(self):
        if self.dirty and not messagebox.askyesno("Reload", "Discard unsaved changes?"):
            return
        self.model = Model.load(self.path.read_text(encoding="utf-8"))
        self.cur_enemy_i = 0 if self.model.enemies else None
        self.cur_part_i = 0 if self.model.enemies else None
        self.sel_idx = None
        self.dirty = False
        self._refresh_all()


def main():
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_ENEMIES
    if not path.exists():
        print(f"no such file: {path}", file=sys.stderr)
        sys.exit(1)
    app = EnemyEditor(path)
    app.mainloop()


if __name__ == "__main__":
    main()
