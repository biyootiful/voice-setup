#!/usr/bin/env python3
"""Warm Kokoro neural-TTS server.
Short text (< CHUNK_CHARS) is read in one piece — no choppiness.
Longer text is split at sentence boundaries into ~CHUNK_CHARS pieces, and the
NEXT piece is synthesized while the current one plays, so there's no gap.
POST /speak <text>  ; POST/GET /stop  cancels. Local-only, free."""
import os, re, time, queue, subprocess, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import soundfile as sf
from kokoro_onnx import Kokoro

KDIR   = os.path.expanduser("~/.local/kokoro")
MODEL  = os.path.join(KDIR, "kokoro-v1.0.onnx")
VOICES = os.path.join(KDIR, "voices-v1.0.bin")
VOICE  = os.environ.get("KOKORO_VOICE", "af_heart")
SPEED  = float(os.environ.get("KOKORO_SPEED", "1.0"))
CHUNK_CHARS = int(os.environ.get("KOKORO_CHUNK_CHARS", "300"))
PORT   = 8123

kokoro = Kokoro(MODEL, VOICES)
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
                samples, sr = kokoro.create(c, voice=VOICE, speed=SPEED, lang="en-us")
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

print(f"kokoro-tts ready on :{PORT} (voice={VOICE}, chunk={CHUNK_CHARS})", flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
