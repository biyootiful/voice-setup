#!/bin/zsh
# Launch the warm Kokoro TTS server using its dedicated Python 3.12 venv.
exec "$HOME/.local/kokoro-venv/bin/python" "$HOME/.local/bin/kokoro-tts-server.py"
