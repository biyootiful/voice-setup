#!/bin/zsh
# Launch the warm TTS server in the venv its engine needs (see kokoro-tts-server.py).
if [[ "${TTS_ENGINE:-soprano}" == kokoro ]]; then
  exec "$HOME/.local/kokoro-venv/bin/python" "$HOME/.local/bin/kokoro-tts-server.py"
fi
exec "$HOME/.local/mlx-audio-venv/bin/python" "$HOME/.local/bin/kokoro-tts-server.py"
