#!/bin/zsh
# Draft a reply to any highlighted message/question by reading the relevant
# codebase(s) with Claude Code headless. Works with text from any app (Slack,
# email, tickets, docs). Takes the message as $1 (or stdin), prints the draft
# to stdout. Read-only (no edits), uses the Claude subscription.
#
# Repos to search are configured in ~/.config/voice-setup/reply-repos.conf

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/draft-reply.log

# ---- config (edit ~/.config/voice-setup/reply-repos.conf) ----
CONFIG="$HOME/.config/voice-setup/reply-repos.conf"
[ -f "$CONFIG" ] && source "$CONFIG"
: "${GIT_BASE:=$HOME/Documents/git}"
: "${PRIMARY_REPO:=}"
: "${EXTRA_REPOS:=}"          # space-separated dir names under GIT_BASE
: "${USER_NAME:=me}"
# --------------------------------------------------------------

question="${1:-$(cat)}"
[ -z "$question" ] && { echo "[$(date)] empty question, abort" >> "$LOG"; exit 0; }

if [ -z "$PRIMARY_REPO" ] || [ ! -d "$GIT_BASE/$PRIMARY_REPO" ]; then
  echo "[$(date)] PRIMARY_REPO not set or missing ($GIT_BASE/$PRIMARY_REPO). Edit $CONFIG" >> "$LOG"
  exit 1
fi
cd "$GIT_BASE/$PRIMARY_REPO" || exit 1
echo "[$(date)] drafting for: ${question:0:80}" >> "$LOG"

# build --add-dir args for the extra repos
add_args=()
for r in ${(s: :)EXTRA_REPOS}; do
  [ -d "$GIT_BASE/$r" ] && add_args+=(--add-dir "$GIT_BASE/$r")
done

REPO_LIST="$PRIMARY_REPO $EXTRA_REPOS"
PROMPT="You are helping $USER_NAME quickly answer a question from a coworker (it could come from Slack, email, a ticket, a doc, anywhere). You have read access to these repos: $REPO_LIST (the primary one, $PRIMARY_REPO, is the current directory). Search the code as needed to find the accurate answer.

Then write a short reply that $USER_NAME can paste as-is. Rules:
- Natural, casual, first-person voice. Friendly and direct.
- Do NOT sound like AI. No em-dashes. No preamble, no sign-off, no 'Sure!' or 'Great question'.
- Be concise but specific; reference file paths or function names when helpful.
- If you genuinely can't determine the answer from the code, say what you'd check next instead of guessing.
- Output ONLY the reply text, nothing else.

The incoming message:
$question"

CLAUDE="$(command -v claude)"
[ -z "$CLAUDE" ] && { echo "[$(date)] claude CLI not found on PATH" >> "$LOG"; exit 1; }

out="$("$CLAUDE" -p "$PROMPT" \
  "${add_args[@]}" \
  --allowedTools Read Grep Glob \
  --strict-mcp-config 2>>"$LOG")"
echo "[$(date)] done exit=$? len=${#out}" >> "$LOG"
print -r -- "$out"
