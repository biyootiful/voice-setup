#!/bin/zsh
# Claude Code "Stop" hook: read Claude's final response aloud via macOS `say`.
# Receives hook JSON on stdin (has .transcript_path). Extracts the last
# assistant message's text, strips markdown/code (so it doesn't read symbols
# or code blocks), and speaks it in the background. Uses the System Voice.
# Press ⌃⌘. (the Hammerspoon stop key) to interrupt — it runs `killall say`.
#
# Replies are written for the screen (tables, bullets, paths, ticket lists), and
# read verbatim they sound robotic in any voice. So anything longer than a line or
# two is first rewritten by Haiku into what a colleague would SAY: two or three
# sentences, outcome first, then what needs you. Falls back to the stripped text
# if that call fails or takes too long.
#
# Several sessions are usually open at once, so every reading starts with which
# one is talking: a short plain-English name ("the autopilot session", "the
# ABC-442 build"), made once per session from how it started and cached.

# The rewrite is itself a `claude -p` run, which fires this Stop hook again.
[ -n "$VOICE_SETUP_NO_SPEAK" ] && exit 0

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

# Rewrite + playback run in the background: a Stop hook blocks Claude Code until
# it returns, and the rewrite takes a few seconds.
{
  haiku() {   # $1 = prompt; 20 s cap; the inner run must not re-trigger this hook
    (cd /tmp && VOICE_SETUP_NO_SPEAK=1 perl -e 'alarm shift; exec @ARGV' 20 \
      claude -p "$1" --model haiku --no-session-persistence --output-format text 2>/dev/null) \
      | tr '\n' ' ' | sed -E 's/[*_#`>|"]//g; s/^[[:space:]]+//; s/[[:space:]]+$//'
  }

  # --- which session is this? -------------------------------------------------
  sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
  [ -z "$sid" ] && sid="${${tpath:t}%.jsonl}"
  labels=/tmp/claude-speak-labels; mkdir -p "$labels"
  label="$(cat "$labels/$sid" 2>/dev/null)"
  if [ -z "$label" ]; then
    opener="$(jq -rs '[.[] | select(.type=="user" and (.message.content|type)=="string")
                        | .message.content | select(startswith("<")|not)] | .[0:3] | join(" / ")' \
                "$tpath" 2>/dev/null | head -c 700)"
    sdir="$(jq -rs '[.[] | .cwd // empty] | .[0] // ""' "$tpath" 2>/dev/null)"
    label="$(haiku "Name this Claude Code session in 2 to 5 plain words, the way you'd say it out loud so the listener knows which of several open windows is talking. Use a ticket key if it's about one ticket. Examples: the autopilot session, the ABC-442 build, the voice setup work, the Druid query fix. Output only the name, lowercase except ticket keys, no punctuation.

Folder: ${sdir:t}
How it started: $opener")"
    label="${label[1,60]}"
    [ -z "$label" ] && label="the ${sdir:t} session"
    print -r -- "$label" > "$labels/$sid"
  fi

  # --- spoken rewrite ---------------------------------------------------------
  SPOKEN_MAX_DIRECT=220   # short, plain replies are already speakable
  if [ "${#clean}" -gt "$SPOKEN_MAX_DIRECT" ] || printf '%s' "$text" | grep -qE '^\s*([-*]|[0-9]+\.|\|)'; then
    brief="Rewrite the message below as what you would SAY OUT LOUD to Bi, who is listening, not reading.
  - 1 to 3 short sentences, under 60 words. Natural spoken English, like a colleague giving a quick update.
  - Lead with the outcome. Then anything he has to do or decide.
  - No lists, tables, symbols, file paths, URLs, code, commit hashes or session ids. Say counts instead of enumerating (\"seven tickets\", not each key). Keep at most one or two ticket keys if they matter.
  - Write it the way it is SAID: ticket keys and numbers as spoken words (ABC-442 → \"A B C four forty-two\", 2026-10-13 → \"October thirteenth\"), no abbreviations or symbols. Use contractions.
  - Don't add anything that isn't in the message. No greeting, no \"here's a summary\".
  Output only the words to speak.

  MESSAGE:
  $text"
    spoken="$(haiku "$brief")"
    [ -n "$spoken" ] && clean="$spoken"
  fi

  clean="From ${label}. $clean"

  # Kokoro-only — no `say` fallback, so there's never a double voice.
  [ -z "$SPEAK_DRY" ] && killall afplay 2>/dev/null   # interrupt any current reading immediately
  if [ -n "$SPEAK_DRY" ]; then print -r -- "$clean"; else
    curl -s --max-time 10 -X POST --data-binary "$clean" http://127.0.0.1:8123/speak >/dev/null 2>&1
  fi
} &!
exit 0
