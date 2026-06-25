#!/usr/bin/env bash
# Remove the voice setup. Leaves Homebrew packages and the downloaded models
# in place (delete ~/.local/share/voice-setup and ~/.local/kokoro* by hand if
# you want the disk space back).
set -uo pipefail
BIN="$HOME/.local/bin"

echo "Stopping + removing background services…"
for p in whisper-dictation kokoro-tts; do
  plist="$HOME/Library/LaunchAgents/com.user.$p.plist"
  launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist"
done

echo "Removing scripts…"
rm -f "$BIN"/whisper-dictation-server.sh "$BIN"/kokoro-tts-server.sh \
      "$BIN"/kokoro-tts-server.py "$BIN"/claude-speak-response.sh \
      "$BIN"/claude-notify.sh "$BIN"/draft-reply.sh

echo "Removing Claude hooks (Stop + Notification)…"
SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq 'if .hooks then .hooks |= (del(.Stop, .Notification)) else . end' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
fi

echo "Done. Your Hammerspoon init.lua was left in place — restore a .bak if you want the old one."
echo "killall the running servers now? run:  killall afplay; pkill -f whisper-server; pkill -f kokoro-tts-server"
