#!/bin/zsh
# Claude Code "Notification" hook: alerts you when Claude needs approval or is
# waiting for input — even when the terminal is in the background.
# Fires a macOS banner (with a chime) and speaks a short alert via Kokoro.

input="$(cat)"
msg="$(printf '%s' "$input" | jq -r '.message // empty' 2>/dev/null)"
[ -z "$msg" ] && msg="Claude needs your attention."

# sanitize for the osascript string (strip quotes/backslashes/newlines)
safe="${msg//\\/}"; safe="${safe//\"/}"; safe="${safe//$'\n'/ }"

# macOS banner + system chime (works regardless of which app is focused)
/usr/bin/osascript -e "display notification \"$safe\" with title \"Claude Code\" sound name \"Glass\"" >/dev/null 2>&1

# short spoken alert via the warm Kokoro server (interrupts any current reading)
curl -s --max-time 5 -X POST --data-binary "$safe" http://127.0.0.1:8123/speak >/dev/null 2>&1

exit 0
