#!/bin/zsh
# Review candidate resumes with Claude Code. Pops a file picker (multi-select,
# defaults to ~/Downloads), reads each PDF, and prints paste-ready hiring
# feedback to stdout. Output goes to your clipboard for review — nothing is sent
# anywhere automatically.
#
# NOTE: resumes contain PII; this sends them to Claude via your subscription.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/resume-review.log
: "${USER_NAME:=me}"

# ---- pick PDFs (multi-select, default ~/Downloads) ------------------------
files="$(osascript <<APPLESCRIPT 2>>"$LOG"
set dl to POSIX file "$HOME/Downloads"
set theFiles to choose file with prompt "Select resume PDFs to review" of type {"com.adobe.pdf"} default location dl with multiple selections allowed
set outText to ""
repeat with f in theFiles
  set outText to outText & POSIX path of f & linefeed
end repeat
return outText
APPLESCRIPT
)"

if [[ -z "$files" ]]; then
  echo "[$(date)] no files selected (cancelled)" >> "$LOG"
  echo "CANCELLED"; exit 0
fi

paths=("${(@f)files}")
paths=(${paths:#})   # drop empty lines

# allow Claude to read the folders the files live in
typeset -A seen
add_args=()
file_list=""
for p in "${paths[@]}"; do
  d="${p:h}"
  if [[ -z "${seen[$d]}" ]]; then seen[$d]=1; add_args+=(--add-dir "$d"); fi
  file_list+="- $p"$'\n'
done
echo "[$(date)] reviewing ${#paths[@]} resume(s)" >> "$LOG"

PROMPT="You are helping a hiring manager ($USER_NAME) review candidate resumes. Read each of these PDF files:
$file_list
For EACH candidate, give a tight assessment (3-5 lines):
- Name and a one-line snapshot (years, current role/stack).
- Strengths relevant to a software engineering role.
- Gaps, concerns, or red flags (job hopping, vague impact, missing fundamentals, etc.).
- A clear recommendation: ADVANCE or PASS, with a one-line reason. If PASS, give a concise, fair, specific rejection reason that could be shared internally.

Then end with a 1-line overall ranking of the candidates.

Write it casual and first-person, paste-ready for Slack. Do NOT sound like AI, no em-dashes, no preamble. Be honest and specific, not generic praise."

CLAUDE="$(command -v claude)"
[[ -z "$CLAUDE" ]] && { echo "[$(date)] claude CLI not found" >> "$LOG"; exit 1; }

out="$("$CLAUDE" -p "$PROMPT" "${add_args[@]}" \
  --allowedTools Read \
  --strict-mcp-config 2>>"$LOG")"
echo "[$(date)] done exit=$? len=${#out}" >> "$LOG"
print -r -- "$out"
