#!/bin/zsh
# Launches whisper-server kept warm in memory for low-latency dictation.
# The model + Metal stay loaded so each transcription is near-instant.

WHISPER_DIR="$HOME/.local/share/voice-setup/whisper.cpp"
MODEL="$WHISPER_DIR/models/ggml-large-v3-turbo.bin"
PORT=8080

exec "$WHISPER_DIR/build/bin/whisper-server" \
  --model "$MODEL" \
  --host 127.0.0.1 \
  --port "$PORT" \
  --no-timestamps \
  --threads 6
