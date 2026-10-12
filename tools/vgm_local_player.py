#!/usr/bin/env python3
"""vgm_local_player.py -- a local tracker-view player for the project's VGM
sketches, built around the real VGMPlay.exe (assets/vgm/tmp/VGMPlay.exe)
instead of trying to reimplement chip audio.

Why VGMPlay and not a from-scratch synth: getting OPLL FM synthesis right is
a project of its own, and VGMPlay already does it correctly. This tool's job
is only to show WHAT is playing WHERE, in sync with what VGMPlay is actually
producing -- not to make sound itself.

How the sync works: VGMPlay.exe, run with a filename argument, streams a
live "Playing  X.XX%  MM:SS.ss / MM:SS.ss seconds" progress line to its own
stdout (carriage-return-updated, ~15-20 times/second -- confirmed by timing
the raw pipe reads, 2026-09-28). This script launches it as a hidden child
process, reads that stream on a background thread, and drives the playhead
from VGMPlay's OWN reported position -- not a locally guessed timer. No
window-automation or process-injection trick is needed or used.

The channel/note decoding is the same algorithm as the Chip Tracker View
artifact (and, before that, the many tools/vgm_*.py scripts from this
session): parse the SN76489/YM2413 command stream directly, and draw a
solid block for a real key-off->key-on attack versus a connected line for a
pitch rewrite under an already-held key-on (the distinction that explained
why the rearranged theme sketch's arpeggio first came out silent).

Usage:
    python tools/vgm_local_player.py [path\\to\\file.vgm]
    (no path -- a file picker opens, defaulting to assets/vgm/tmp)
"""
import math
import os
import re
import struct
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox

SAMPLE_RATE = 44100
ROM_INS = ['User', 'Violin', 'Guitar', 'Piano', 'Flute', 'Clarinet', 'Oboe', 'Trumpet',
           'Organ', 'Horn', 'Synth', 'Harpsichord', 'Vibraphone', 'SynthBass', 'AcBass', 'ElecGtr']

HERE = Path(__file__).resolve().parent
VGM_TMP_DIR = HERE.parent / 'assets' / 'vgm' / 'tmp'
VGMPLAY_EXE = VGM_TMP_DIR / 'VGMPlay.exe'

PROGRESS_RE = re.compile(
    rb'Playing\s+[\d.]+%\s+(\d+):(\d+\.\d+)\s*/\s*(\d+):(\d+\.\d+)\s*seconds')


# --------------------------------------------------------------------------- parsing
def hz_to_note(hz):
    if not hz or hz <= 0:
        return None
    n = round(12 * math.log2(hz / 440.0)) + 69
    names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
    return {'name': names[n % 12] + str(n // 12 - 1), 'midi': n}


def parse_vgm(path):
    data = Path(path).read_bytes()
    if data[:4] != b'Vgm ':
        raise ValueError('to nie jest plik VGM (zla sygnatura)')

    def u32(off):
        return struct.unpack_from('<I', data, off)[0]

    version = u32(0x08)
    sn_clock = u32(0x0C)
    opll_clock = u32(0x10) or 3579545
    gd3_rel = u32(0x14)
    total_samples_hdr = u32(0x18)
    loop_rel = u32(0x1C)
    loop_samples = u32(0x20)
    data_offset = 0x40
    if version >= 0x150:
        rel = u32(0x34)
        data_offset = 0x34 + rel if rel else 0x40
    end_abs = (0x14 + gd3_rel) if gd3_rel else (0x04 + u32(0x04))
    loop_abs = (0x1C + loop_rel) if loop_rel else None
    end = min(end_abs, len(data))

    opll_freq_lo = [0] * 9
    opll_key_on = [False] * 9
    opll_instrument = [{'id': 0, 'name': 'User'} for _ in range(9)]
    opll_open = [None] * 9
    opll_blocks = [[] for _ in range(9)]

    psg_divisor = [0, 0, 0]
    psg_atten = [15, 15, 15, 15]
    psg_open = [None, None, None, None]
    psg_blocks = [[], [], [], []]
    pending_reg = None
    pending_lo = 0

    def close_opll(ch, end_t):
        o = opll_open[ch]
        if not o:
            return
        opll_blocks[ch].append({'start': o['start'], 'end': max(end_t, o['start'] + 1),
                                 'points': o['points'], 'instrument': o['instrument']})
        opll_open[ch] = None

    def close_psg_tone(ch, end_t):
        o = psg_open[ch]
        if not o:
            return
        psg_blocks[ch].append({'start': o['start'], 'end': max(end_t, o['start'] + 1), 'points': o['points']})
        psg_open[ch] = None

    def close_psg_noise(end_t):
        o = psg_open[3]
        if not o:
            return
        psg_blocks[3].append({'start': o['start'], 'end': max(end_t, o['start'] + 1)})
        psg_open[3] = None

    i, t, loop_sample_time, warn = data_offset, 0, None, None

    while i < end:
        if loop_abs is not None and i == loop_abs and loop_sample_time is None:
            loop_sample_time = t
        op = data[i]
        if op == 0x50:
            val = data[i + 1]
            if val & 0x80:
                reg, lo = (val >> 4) & 7, val & 0xF
                if reg in (0, 2, 4):
                    pending_reg, pending_lo = reg, lo
                elif reg in (1, 3, 5, 7):
                    ch = 3 if reg == 7 else (reg - 1) // 2
                    now_open, was_open = lo < 15, psg_atten[ch] < 15
                    if ch == 3:
                        if not was_open and now_open:
                            psg_open[3] = {'start': t}
                        elif was_open and not now_open:
                            close_psg_noise(t)
                    else:
                        if not was_open and now_open:
                            hz = sn_clock / (32 * psg_divisor[ch]) if psg_divisor[ch] > 0 else 0
                            nn = hz_to_note(hz)
                            psg_open[ch] = {'start': t, 'points': [
                                {'t': t, 'midi': nn['midi'] if nn else 60, 'name': nn['name'] if nn else '?'}]}
                        elif was_open and not now_open:
                            close_psg_tone(ch, t)
                    psg_atten[ch] = lo
            elif pending_reg is not None:
                n = pending_lo | ((val & 0x3F) << 4)
                ch = pending_reg // 2
                psg_divisor[ch] = n
                pending_reg = None
                if psg_atten[ch] < 15 and psg_open[ch]:
                    hz = sn_clock / (32 * n) if n > 0 else 0
                    nn = hz_to_note(hz)
                    psg_open[ch]['points'].append(
                        {'t': t, 'midi': nn['midi'] if nn else 60, 'name': nn['name'] if nn else '?'})
            i += 2
        elif op == 0x51:
            reg, val = data[i + 1], data[i + 2]
            if 0x10 <= reg <= 0x18:
                opll_freq_lo[reg - 0x10] = val
            elif 0x20 <= reg <= 0x28:
                ch = reg - 0x20
                key_on, block = bool(val & 0x10), (val >> 1) & 7
                fnum = (opll_freq_lo[ch] or 0) | ((val & 1) << 8)
                hz = fnum * opll_clock / (2 ** (19 - block)) / 72 if fnum > 0 else 0
                nn = hz_to_note(hz)
                was_on = opll_key_on[ch]
                point = {'t': t, 'midi': nn['midi'] if nn else 60, 'name': nn['name'] if nn else '?'}
                if key_on and not was_on:
                    close_opll(ch, t)
                    opll_open[ch] = {'start': t, 'points': [point], 'instrument': opll_instrument[ch]}
                elif key_on and was_on:
                    if opll_open[ch]:
                        opll_open[ch]['points'].append(point)
                elif not key_on and was_on:
                    close_opll(ch, t)
                opll_key_on[ch] = key_on
            elif 0x30 <= reg <= 0x38:
                ch, ins_id = reg - 0x30, (val >> 4) & 0xF
                opll_instrument[ch] = {'id': ins_id, 'name': ROM_INS[ins_id]}
                if opll_open[ch]:
                    opll_open[ch]['instrument'] = opll_instrument[ch]
            i += 3
        elif op == 0x61:
            t += struct.unpack_from('<H', data, i + 1)[0]
            i += 3
        elif op == 0x62:
            t += 735
            i += 1
        elif op == 0x63:
            t += 882
            i += 1
        elif 0x70 <= op <= 0x7F:
            t += (op & 0xF) + 1
            i += 1
        elif op == 0x66:
            break
        elif op == 0x67:
            size = struct.unpack_from('<I', data, i + 3)[0]
            i += 7 + size
        else:
            warn = f'nieznany opcode 0x{op:02X} przy 0x{i:X} -- pokazuje to, co sie dalo odczytac'
            break

    for ch in range(9):
        close_opll(ch, t)
    for ch in range(3):
        close_psg_tone(ch, t)
    close_psg_noise(t)

    return {
        'version': version, 'sn_clock': sn_clock, 'opll_clock': opll_clock,
        'total_samples': total_samples_hdr or t, 'loop_samples': loop_samples,
        'loop_sample_time': loop_sample_time, 'opll_blocks': opll_blocks,
        'psg_blocks': psg_blocks, 'warn': warn,
    }


def build_rows(parsed):
    rows = []
    for ch in range(9):
        rows.append({'chip': 'FM', 'opll': True, 'label': f'ch{ch}', 'blocks': parsed['opll_blocks'][ch]})
    for ch, label in enumerate(['SQ 0', 'SQ 1', 'SQ 2', 'NOISE']):
        rows.append({'chip': 'PSG', 'opll': False, 'label': label, 'blocks': parsed['psg_blocks'][ch]})
    for r in rows:
        midis = [p['midi'] for b in r['blocks'] for p in (b.get('points') or [])]
        r['midi_lo'] = min(midis) if midis else 60
        r['midi_hi'] = max(midis, default=r['midi_lo'] + 1)
        if r['midi_hi'] <= r['midi_lo']:
            r['midi_hi'] = r['midi_lo'] + 1
    return rows


# ------------------------------------------------------------------------------- GUI
ROW_H, RULER_H, SIDEBAR_W = 30, 24, 74
OPLL_COLOR, OPLL_DIM = '#6fd7b5', '#1d332b'
PSG_COLOR, PSG_DIM = '#e0a15c', '#332a1a'
BG, PANEL, GRID, TEXT, TEXT_DIM = '#0a0e13', '#10161d', '#1f2a35', '#c9d4de', '#5c6b7a'
PLAYHEAD, LOOP_COLOR = '#ff5f6d', '#5a9bd8'


class PlayerApp:
    def __init__(self, root, initial_path=None):
        self.root = root
        root.title('VGM Local Player')
        root.configure(bg=BG)
        root.geometry('1180x620')

        self.parsed = None
        self.rows = []
        self.px_per_sec = 70
        self.proc = None
        self.reader_thread = None
        self.pos = {'sec': 0.0, 'total': 0.0, 'playing': False}
        self.playhead_line = None
        self.zoom_var = tk.IntVar(value=self.px_per_sec)

        self._build_toolbar()
        self._build_meta()
        self._build_stage()

        if initial_path:
            self.load(initial_path)
        else:
            default = VGM_TMP_DIR / 'title_intro.vgm'
            if default.exists():
                self.load(str(default))

        self.root.protocol('WM_DELETE_WINDOW', self._on_close)
        self._poll()

    # -- UI construction --------------------------------------------------
    def _build_toolbar(self):
        bar = tk.Frame(self.root, bg=PANEL)
        bar.pack(side=tk.TOP, fill=tk.X, padx=8, pady=(8, 4))

        def btn(parent, text, cmd, primary=False):
            b = tk.Button(parent, text=text, command=cmd, bg=(OPLL_DIM if primary else '#141b23'),
                           fg=TEXT, activebackground=OPLL_DIM, relief=tk.FLAT, bd=0,
                           padx=10, pady=5, font=('Consolas', 10))
            b.pack(side=tk.LEFT, padx=3, pady=4)
            return b

        btn(bar, 'Otworz plik...', self.on_open)
        tk.Frame(bar, width=1, bg=GRID).pack(side=tk.LEFT, fill=tk.Y, padx=6, pady=4)
        self.play_btn = btn(bar, '▶ Graj (VGMPlay)', self.on_play, primary=True)
        self.stop_btn = btn(bar, '■ Stop', self.on_stop)
        tk.Frame(bar, width=1, bg=GRID).pack(side=tk.LEFT, fill=tk.Y, padx=6, pady=4)
        tk.Label(bar, text='zoom', bg=PANEL, fg=TEXT_DIM, font=('Consolas', 9)).pack(side=tk.LEFT, padx=(6, 2))
        zoom = tk.Scale(bar, from_=15, to=240, orient=tk.HORIZONTAL, variable=self.zoom_var,
                         showvalue=False, length=120, bg=PANEL, fg=TEXT, troughcolor='#141b23',
                         highlightthickness=0, command=self.on_zoom)
        zoom.pack(side=tk.LEFT)
        tk.Frame(bar, width=1, bg=GRID).pack(side=tk.LEFT, fill=tk.Y, padx=6, pady=4)
        self.time_label = tk.Label(bar, text='0:00.0 / 0:00.0', bg=PANEL, fg=TEXT,
                                    font=('Consolas', 10, 'bold'))
        self.time_label.pack(side=tk.LEFT, padx=6)

    def _build_meta(self):
        self.meta_label = tk.Label(self.root, text='', bg=BG, fg=TEXT_DIM, font=('Consolas', 9),
                                    anchor='w', justify=tk.LEFT)
        self.meta_label.pack(side=tk.TOP, fill=tk.X, padx=12, pady=(0, 4))
        legend = ('▬ atak (key-off→key-on)     ┄┄ slizg wysokosci pod trzymanym '
                  'key-on (bez ataku)     ┊ petla     ┃ playhead')
        tk.Label(self.root, text=legend, bg=BG, fg=TEXT_DIM, font=('Consolas', 9),
                 anchor='w').pack(side=tk.TOP, fill=tk.X, padx=12, pady=(0, 6))

    def _build_stage(self):
        stage = tk.Frame(self.root, bg=PANEL)
        stage.pack(side=tk.TOP, fill=tk.BOTH, expand=True, padx=8, pady=(0, 8))

        self.sidebar = tk.Canvas(stage, width=SIDEBAR_W, bg='#141b23', highlightthickness=0)
        self.sidebar.pack(side=tk.LEFT, fill=tk.Y)

        right = tk.Frame(stage, bg=PANEL)
        right.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        hbar = tk.Scrollbar(right, orient=tk.HORIZONTAL)
        hbar.pack(side=tk.BOTTOM, fill=tk.X)
        self.canvas = tk.Canvas(right, bg=BG, highlightthickness=0, xscrollcommand=hbar.set)
        self.canvas.pack(side=tk.TOP, fill=tk.BOTH, expand=True)
        hbar.config(command=self.canvas.xview)
        self.canvas.bind('<Button-1>', self.on_canvas_click)

    # -- loading / parsing --------------------------------------------------
    def on_open(self):
        initdir = str(VGM_TMP_DIR) if VGM_TMP_DIR.exists() else str(HERE)
        path = filedialog.askopenfilename(title='Wybierz plik VGM', initialdir=initdir,
                                           filetypes=[('VGM files', '*.vgm'), ('All files', '*.*')])
        if path:
            self.on_stop()
            self.load(path)

    def load(self, path):
        try:
            self.parsed = parse_vgm(path)
        except Exception as e:
            messagebox.showerror('Blad parsowania', str(e))
            return
        self.path = path
        self.rows = build_rows(self.parsed)
        self.pos = {'sec': 0.0, 'total': self.parsed['total_samples'] / SAMPLE_RATE, 'playing': False}
        self._show_meta()
        self._draw_static()
        self._update_time_label()

    def _show_meta(self):
        p = self.parsed
        dur = p['total_samples'] / SAMPLE_RATE
        loop = f"{p['loop_sample_time']/SAMPLE_RATE:.2f}s" if p['loop_sample_time'] is not None else '—'
        txt = (f"{os.path.basename(self.path)}   |   czas: {dur:.2f}s   |   petla od: {loop}   |   "
               f"YM2413 @ {p['opll_clock']/1e6:.4f} MHz   |   SN76489 @ {p['sn_clock']/1e6:.4f} MHz")
        if p['warn']:
            txt += '   |   ' + p['warn']
        self.meta_label.config(text=txt)

    # -- drawing --------------------------------------------------------
    def on_zoom(self, _val):
        self.px_per_sec = self.zoom_var.get()
        self._draw_static()

    def _draw_static(self):
        self.canvas.delete('all')
        self.sidebar.delete('all')
        if not self.parsed:
            return
        dur = self.parsed['total_samples'] / SAMPLE_RATE
        width = max(300, int(dur * self.px_per_sec) + 60)
        height = RULER_H + len(self.rows) * ROW_H
        self.canvas.config(scrollregion=(0, 0, width, height), height=height)
        self.sidebar.config(height=height)

        # sidebar
        self.sidebar.create_rectangle(0, 0, SIDEBAR_W, RULER_H, fill='#141b23', outline=GRID)
        for ri, r in enumerate(self.rows):
            y = RULER_H + ri * ROW_H
            col = OPLL_COLOR if r['opll'] else PSG_COLOR
            self.sidebar.create_rectangle(0, y, SIDEBAR_W, y + ROW_H, fill='#141b23', outline=GRID)
            self.sidebar.create_text(8, y + 9, anchor='w', text=r['chip'], fill=col, font=('Consolas', 7, 'bold'))
            self.sidebar.create_text(8, y + 20, anchor='w', text=r['label'], fill=TEXT, font=('Consolas', 9))

        # ruler + rows
        self.canvas.create_rectangle(0, 0, width, RULER_H, fill='#10161d', outline=GRID)
        step = 1 if self.px_per_sec > 90 else 5 if self.px_per_sec > 40 else 10 if self.px_per_sec > 18 else 30
        s = 0
        while s <= dur + step:
            x = s * self.px_per_sec
            self.canvas.create_line(x, RULER_H, x, height, fill='#1a2229')
            self.canvas.create_text(x + 3, RULER_H / 2, anchor='w', text=self._fmt(s),
                                     fill=TEXT_DIM, font=('Consolas', 8))
            s += step
        for ri in range(len(self.rows)):
            y = RULER_H + ri * ROW_H
            self.canvas.create_rectangle(0, y, width, y + ROW_H,
                                          fill=('#10161d' if ri % 2 == 0 else '#141b23'), outline=GRID)

        if self.parsed['loop_sample_time'] is not None:
            x = (self.parsed['loop_sample_time'] / SAMPLE_RATE) * self.px_per_sec
            self.canvas.create_line(x, 0, x, height, fill=LOOP_COLOR, dash=(4, 3))
            self.canvas.create_text(x + 3, 8, anchor='w', text='LOOP', fill=LOOP_COLOR, font=('Consolas', 8))

        for ri, r in enumerate(self.rows):
            y0 = RULER_H + ri * ROW_H
            color = OPLL_COLOR if r['opll'] else PSG_COLOR
            color_dim = OPLL_DIM if r['opll'] else PSG_DIM
            rng = max(1, r['midi_hi'] - r['midi_lo'])

            def y_for(midi):
                return y0 + 4 + (1 - (midi - r['midi_lo']) / rng) * (ROW_H - 8)

            for b in r['blocks']:
                x0, x1 = (b['start'] / SAMPLE_RATE) * self.px_per_sec, (b['end'] / SAMPLE_RATE) * self.px_per_sec
                pts = b.get('points') or [{'t': b['start'], 'midi': (r['midi_lo'] + r['midi_hi']) / 2, 'name': ''}]
                if len(pts) > 1:
                    coords = []
                    for p in pts:
                        coords += [(p['t'] / SAMPLE_RATE) * self.px_per_sec, y_for(p['midi'])]
                    coords += [x1, y_for(pts[-1]['midi'])]
                    self.canvas.create_line(*coords, fill=color, width=2, dash=(3, 3))
                else:
                    midi = pts[0]['midi']
                    y = y_for(midi)
                    bw = max(2, x1 - x0 - 1)
                    self.canvas.create_rectangle(x0, y - 5, x0 + bw, y + 5, fill=color_dim, outline=color)
                    if bw > 22 and pts[0]['name']:
                        self.canvas.create_text(x0 + 3, y, anchor='w', text=pts[0]['name'],
                                                 fill=BG, font=('Consolas', 7))

        self.playhead_line = self.canvas.create_line(0, 0, 0, height, fill=PLAYHEAD, width=2)
        self._move_playhead()

    @staticmethod
    def _fmt(sec):
        m, s = int(sec // 60), sec - int(sec // 60) * 60
        return f'{m}:{s:04.1f}'

    def on_canvas_click(self, event):
        if not self.parsed:
            return
        x = self.canvas.canvasx(event.x)
        if event.y > RULER_H:
            return
        self.pos['sec'] = max(0.0, x / self.px_per_sec)
        self._move_playhead()
        self._update_time_label()

    def _move_playhead(self):
        if self.playhead_line is None:
            return
        x = self.pos['sec'] * self.px_per_sec
        height = RULER_H + len(self.rows) * ROW_H
        self.canvas.coords(self.playhead_line, x, 0, x, height)
        w = self.canvas.winfo_width()
        if w > 1:
            left = self.canvas.canvasx(0)
            if x < left + 40 or x > left + w - 60:
                total_w = max(1, int((self.parsed['total_samples'] / SAMPLE_RATE) * self.px_per_sec) + 60)
                frac = max(0.0, (x - w * 0.3) / total_w)
                self.canvas.xview_moveto(frac)

    def _update_time_label(self):
        self.time_label.config(text=f"{self._fmt(self.pos['sec'])} / {self._fmt(self.pos['total'])}")

    # -- VGMPlay control --------------------------------------------------
    def on_play(self):
        if not self.parsed:
            return
        self.on_stop()
        if not VGMPLAY_EXE.exists():
            messagebox.showerror('Brak VGMPlay.exe', f'Nie znaleziono {VGMPLAY_EXE}')
            return
        try:
            self.proc = subprocess.Popen(
                [str(VGMPLAY_EXE), str(Path(self.path).resolve())],
                cwd=str(VGM_TMP_DIR), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                bufsize=0, creationflags=subprocess.CREATE_NO_WINDOW,
            )
        except Exception as e:
            messagebox.showerror('Nie udalo sie uruchomic VGMPlay', str(e))
            return
        self.pos['playing'] = True
        self.reader_thread = threading.Thread(target=self._read_progress, args=(self.proc,), daemon=True)
        self.reader_thread.start()

    def on_stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
            except Exception:
                pass
        self.proc = None
        self.pos['playing'] = False

    def _read_progress(self, proc):
        buf = b''
        while True:
            try:
                chunk = proc.stdout.read(256)
            except Exception:
                break
            if not chunk:
                break
            buf += chunk
            matches = list(PROGRESS_RE.finditer(buf))
            if matches:
                m = matches[-1]
                mm, ss, tmm, tss = m.groups()
                self.pos['sec'] = int(mm) * 60 + float(ss)
                self.pos['total'] = int(tmm) * 60 + float(tss)
                buf = buf[m.end():]
            if len(buf) > 4096:
                buf = buf[-256:]
        self.pos['playing'] = False

    # -- main loop tick --------------------------------------------------
    def _poll(self):
        if self.parsed:
            self._move_playhead()
            self._update_time_label()
        self.root.after(40, self._poll)

    def _on_close(self):
        self.on_stop()
        self.root.destroy()


def main():
    initial = sys.argv[1] if len(sys.argv) > 1 else None
    root = tk.Tk()
    PlayerApp(root, initial)
    root.mainloop()


if __name__ == '__main__':
    main()
