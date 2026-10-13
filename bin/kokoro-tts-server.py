#!/usr/bin/env python3
"""Warm neural-TTS server (Soprano by default, Kokoro as the fallback).
Short text (< CHUNK_CHARS) is read in one piece — no choppiness.
Longer text is split at sentence boundaries into ~CHUNK_CHARS pieces, and the
NEXT piece is synthesized while the current one plays, so there's no gap.
POST /speak <text>  ; POST/GET /stop  cancels. Local-only, free.

TTS_ENGINE=soprano (default): Soprano-1.1-80M on MLX, via mlx-audio. Picked by ear
  against Kokoro and Qwen3-TTS (2026-10-13): the most natural of the small models,
  and ~13x faster than real time on an M1 Pro. Needs ~/.local/mlx-audio-venv.
TTS_ENGINE=kokoro: Kokoro-82M on ONNX (KOKORO_VOICE, ~/.local/kokoro-venv)."""
import os, re, time, queue, subprocess, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import soundfile as sf

KDIR   = os.path.expanduser("~/.local/kokoro")
MODEL  = os.path.join(KDIR, "kokoro-v1.0.onnx")
VOICES = os.path.join(KDIR, "voices-v1.0.bin")
VOICE  = os.environ.get("KOKORO_VOICE", "af_heart")
SPEED  = float(os.environ.get("KOKORO_SPEED", "1.0"))
# Soprano is best on 2-15 s sentences, so it gets shorter pieces than Kokoro.
CHUNK_CHARS = int(os.environ.get("KOKORO_CHUNK_CHARS",
                  "180" if os.environ.get("TTS_ENGINE", "soprano") == "soprano" else "300"))
PORT   = 8123

ENGINE = os.environ.get("TTS_ENGINE", "soprano")
SOPRANO_MODEL = os.environ.get("SOPRANO_MODEL", "mlx-community/Soprano-1.1-80M-bf16")

if ENGINE == "kokoro":
    from kokoro_onnx import Kokoro
    kokoro = Kokoro(MODEL, VOICES)
    def synth(text):
        return kokoro.create(text, voice=VOICE, speed=SPEED, lang="en-us")
else:
    import numpy as np
    from mlx_audio.tts.utils import load_model
    soprano = load_model(SOPRANO_MODEL)
    _mlx_lock = threading.Lock()          # one generation at a time on the GPU
    def synth(text):
        with _mlx_lock:
            parts = list(soprano.generate(text))
        sr = parts[0].sample_rate if parts else 32000
        audio = np.concatenate([np.array(p.audio, dtype=np.float32) for p in parts]) if parts else np.zeros(1, np.float32)
        return audio, sr
_job = 0
_lock = threading.Lock()

def chunk_text(text):
    text = text.strip()
    if len(text) <= CHUNK_CHARS:           # short -> one piece, no streaming
        return [text]
    parts = re.split(r'(?<=[.!?])\s+', text)   # long -> accumulate to ~threshold
    chunks, buf = [], ""
    for p in parts:
        cand = (buf + " " + p).strip() if buf else p
        if buf and len(cand) > CHUNK_CHARS:
            chunks.append(buf); buf = p
        else:
            buf = cand
    if buf:
        chunks.append(buf)
    return chunks

def speak_job(text, myjob):
    # "settings.json" -> "settings dot json" so the dot isn't heard as a sentence break
    text = re.sub(r'(?<=\w)\.(?=\w)', ' dot ', text)
    chunks = chunk_text(text)
    q = queue.Queue()
    def producer():                         # synthesize ahead of playback
        for c in chunks:
            with _lock:
                if myjob != _job: break
            try:
                samples, sr = synth(c)
                fd, path = tempfile.mkstemp(suffix=".wav"); os.close(fd)
                sf.write(path, samples, sr)
                q.put(path)
            except Exception as e:
                print("synth error:", e, flush=True)
        q.put(None)
    threading.Thread(target=producer, daemon=True).start()
    while True:
        path = q.get()
        if path is None: break
        with _lock:
            cancelled = myjob != _job
        if cancelled:
            try: os.remove(path)
            except OSError: pass
            break
        proc = subprocess.Popen(["afplay", path])
        while proc.poll() is None:
            with _lock:
                if myjob != _job:
                    proc.terminate(); break
            time.sleep(0.05)
        try: os.remove(path)
        except OSError: pass
    while not q.empty():                     # drain leftover temp files on cancel
        p = q.get()
        if p:
            try: os.remove(p)
            except OSError: pass

def new_job():
    global _job
    with _lock:
        _job += 1
        return _job

class H(BaseHTTPRequestHandler):
    def _body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n).decode("utf-8", "ignore").strip() if n else ""
    def do_POST(self):
        if self.path.startswith("/stop"):
            new_job(); subprocess.run(["killall", "afplay"], stderr=subprocess.DEVNULL)
            self.send_response(200); self.end_headers(); return
        text = self._body()
        myjob = new_job()
        subprocess.run(["killall", "afplay"], stderr=subprocess.DEVNULL)
        self.send_response(200); self.end_headers()
        if text:
            threading.Thread(target=speak_job, args=(text, myjob), daemon=True).start()
    def do_GET(self):
        if self.path.startswith("/stop"):
            new_job(); subprocess.run(["killall", "afplay"], stderr=subprocess.DEVNULL)
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass

print(f"tts ready on :{PORT} (engine={ENGINE}, chunk={CHUNK_CHARS})", flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
