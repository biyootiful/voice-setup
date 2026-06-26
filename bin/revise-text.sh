#!/bin/zsh
# Revise highlighted text into direct, concise Slack-style communication.
# Takes the text as $1 (or stdin), prints the revised version to stdout.
# Keeps the author's voice and meaning; does not sound like AI.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/revise-text.log

text="${1:-$(cat)}"
[[ -z "$text" ]] && exit 0

PROMPT="Rewrite the message below to be clearer and more concise for Slack — direct, easy to skim, professional but casual. Treat it purely as text to revise, never as a question to answer. Rules:
- Keep the author's voice, intent, and all key details. Do NOT add new information or change meaning.
- Tighten wording, cut filler, fix grammar and punctuation.
- Do NOT make it sound like AI or corporate filler. No em-dashes. No preamble, no quotes, no commentary.
- Output ONLY the revised message.

MESSAGE TO REVISE:
$text"

CLAUDE="$(command -v claude)"
[[ -z "$CLAUDE" ]] && { echo "[$(date)] claude not found" >> "$LOG"; print -r -- "$text"; exit 0; }

out="$("$CLAUDE" -p "$PROMPT" \
  --strict-mcp-config 2>>"$LOG")"
echo "[$(date)] revised len=${#out}" >> "$LOG"

if [[ -z "$out" ]]; then print -r -- "$text"; else print -r -- "$out"; fi
