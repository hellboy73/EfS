"""Replay a recorder.html recording offline, bit-for-bit.

    python tools/recorder/replay.py efs_input.json out/      [--frames N]

Runs the same WebAssembly core the recorder ran (madsim-wasm.js, beside this
file) on this repo's cart + ROMs, feeding the recorded mask each frame, and
writes:
    out/frames.npy   uint8 (N, 300, 400), the framebuffer (0 / 255), unrotated
    out/audio.f32    float32 stereo interleaved, at the recording's sample rate
It refuses to run if cart.bin or the ROMs differ from the ones recorded
against: the recording would replay into a different game.

Needs: pip install wasmtime numpy
"""
import argparse, base64, gzip, hashlib, json, os, re, sys
import numpy as np, wasmtime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
W, H = 400, 300

ap = argparse.ArgumentParser()
ap.add_argument("recording"); ap.add_argument("out")
ap.add_argument("--frames", type=int, help="run this many frames (default: the recording's length)")
a = ap.parse_args()

rec = json.load(open(a.recording))
masks = [m for m, n in rec["rle"] for _ in range(n)]
nframes = a.frames or len(masks)

js = open(os.path.join(HERE, "madsim-wasm.js"), encoding="ascii").read()
wasm = gzip.decompress(base64.b64decode(re.search(r'="([^"]+)"', js).group(1)))
img = {k: open(os.path.join(ROOT, p), "rb").read()
       for k, p in (("cpu", "roms/cpu_os.bin"), ("gpu", "roms/gpu_os.bin"), ("cart", rec.get("cart", "cart.bin")))}
for k in ("cpu", "gpu", "cart"):
    want = rec.get(k + "_sha1")
    if want and hashlib.sha1(img[k]).hexdigest() != want:
        sys.exit(f"{k} image differs from the one this was recorded against - rebuild that version first")

store = wasmtime.Store()
ex = wasmtime.Instance(store, wasmtime.Module(store.engine, wasm), []).exports(store)
mem = ex["memory"]
def put(b):
    p = ex["mad_alloc"](store, len(b)); mem.write(store, b, p); return p
rate = int(rec.get("rate", 48000))
ex["mad_init"](store, put(img["cpu"]), len(img["cpu"]), put(img["gpu"]), len(img["gpu"]),
               put(img["cart"]), len(img["cart"]), rate)
ex["mad_set_mix"](store, float(rec.get("mix", 0)))

frames = np.zeros((nframes, H, W), np.uint8); audio = []
for i in range(nframes):
    ex["mad_joy"](store, 0, masks[i] if i < len(masks) else 0)
    ex["mad_frame"](store)
    p = ex["mad_screen"](store)
    frames[i] = np.frombuffer(mem.read(store, p, p + W * H * 4), np.uint8).reshape(H, W, 4)[:, :, 0]
    n = ex["mad_audio_len"](store)
    if n:
        q = ex["mad_audio_ptr"](store)
        audio.append(np.frombuffer(mem.read(store, q, q + n * 4), np.float32).copy())
        ex["mad_audio_clear"](store)

os.makedirs(a.out, exist_ok=True)
np.save(os.path.join(a.out, "frames.npy"), frames)
np.concatenate(audio).tofile(os.path.join(a.out, "audio.f32"))
p = ex["mad_screen"](store)
print(f"{nframes} frames ({nframes / 60.317:.2f} s) at {rate} Hz; last screen sha1",
      hashlib.sha1(mem.read(store, p, p + W * H * 4)).hexdigest())
