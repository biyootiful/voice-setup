#!/bin/zsh
# Claude Code "Stop" hook: read Claude's final response aloud via macOS `say`.
# Receives hook JSON on stdin (has .transcript_path). Extracts the last
# assistant message's text, strips markdown/code (so it doesn't read symbols
# or code blocks), and speaks it in the background. Uses the System Voice.
# Press ⌃⌘. (the Hammerspoon stop key) to interrupt — it runs `killall say`.

input="$(cat)"
tpath="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -z "$tpath" ] && exit 0
[ ! -f "$tpath" ] && exit 0

sleep 0.5   # let Claude's final message finish flushing to the transcript

# Last assistant entry that actually CONTAINS text (skip thinking/tool_use blocks)
text="$(jq -rs '
  [ .[]
    | select(.type=="assistant")
    | .message.content
    | select(type=="array")
    | (map(select(.type=="text") | .text) | join(" "))
    | select(length > 0)
  ] | last // ""
' "$tpath" 2>/dev/null)"
[ -z "$text" ] && exit 0
[ "$text" = "null" ] && exit 0

# Strip fenced code blocks, then inline markdown, collapse to one line
clean="$(printf '%s\n' "$text" \
  | awk 'BEGIN{c=0} /^[[:space:]]*```/{c=!c; next} c==0{print}' \
  | sed -E -e 's/\[([^]]*)\]\([^)]*\)/\1/g' -e 's/`[^`]*`//g' -e 's/[*_#>~|]//g' \
  | tr '\n' ' ' \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
[ -z "$clean" ] && exit 0

# Dedup: never read the same text twice in a row
hashfile="/tmp/claude-last-spoken.hash"
newhash="$(printf '%s' "$clean" | md5)"
[ -f "$hashfile" ] && [ "$(cat "$hashfile")" = "$newhash" ] && exit 0
printf '%s' "$newhash" > "$hashfile"

# Kokoro-only — no `say` fallback, so there's never a double voice.
killall afplay 2>/dev/null   # interrupt any current reading immediately
curl -s --max-time 10 -X POST --data-binary "$clean" http://127.0.0.1:8123/speak >/dev/null 2>&1
exit 0
