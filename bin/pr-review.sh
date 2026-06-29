#!/bin/zsh
# Review GitHub PR(s) with Claude Code and leave a PENDING review on each
# (inline comments + summary) that YOU submit. Accepts raw pasted text as $1
# (or stdin) — e.g. a whole Slack message — and extracts every PR link from it.
# Posts under the configured work gh account. Nothing is submitted automatically.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/pr-review.log

CONFIG="$HOME/.config/voice-setup/reply-repos.conf"
[ -f "$CONFIG" ] && source "$CONFIG"
: "${GIT_BASE:=$HOME/Documents/git}"
: "${GH_ACCOUNT:=}"   # set in reply-repos.conf; empty = use gh's active account

input="${1:-$(cat)}"
[ -z "$input" ] && { echo "[$(date)] no input" >> "$LOG"; exit 0; }

# Extract every GitHub PR URL from the pasted text (ignores Jira links, @mentions,
# etc.). Strips any trailing /files, #discussion, ?query. Dedups.
urls=("${(@f)$(printf '%s' "$input" \
  | grep -oE 'https?://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+')}")
typeset -U urls
if [[ ${#urls[@]} -eq 0 ]]; then
  echo "[$(date)] no PR urls found in input" >> "$LOG"
  echo "NO_PR_URL"; exit 1
fi

[ -n "$GH_ACCOUNT" ] && gh auth switch --hostname github.com --user "$GH_ACCOUNT" >/dev/null 2>&1 || true
CLAUDE="$(command -v claude)"
[[ -z "$CLAUDE" ]] && { echo "[$(date)] claude CLI not found" >> "$LOG"; exit 1; }

review_one() {
  local url="$1"
  local rest="${url#http*://github.com/}"
  local owner="${rest%%/*}"; rest="${rest#*/}"
  local repo="${rest%%/*}";  rest="${rest#*/}"
  local number="${rest#pull/}"; number="${number%%[/?#]*}"

  local workdir="$GIT_BASE/$repo"
  [[ -d "$workdir" ]] || workdir="$(mktemp -d)"
  ( cd "$workdir" || exit 1
    echo "[$(date)] reviewing $owner/$repo#$number as $GH_ACCOUNT (workdir=$workdir)" >> "$LOG"
    local PROMPT="Review GitHub pull request $url (owner=$owner, repo=$repo, number=$number) and leave a PENDING review that the human will submit. Do NOT submit or approve anything.

Steps:
1. Run 'gh pr view $url' and 'gh pr diff $url' to read the description and full diff.
2. Read surrounding code for context (you may be inside the repo checkout). Focus on REAL issues: correctness bugs, security, broken logic, race conditions, API/contract breakage, missing or wrong tests. Skip pure style nitpicks.
3. Create a PENDING review via the GitHub API by writing a JSON payload and running:
     gh api -X POST repos/$owner/$repo/pulls/$number/reviews --input <payload.json>
   payload.json must have a 'body' (short overall summary) and a 'comments' array of {path, line, side, body} on changed lines. Do NOT include an 'event' field — omitting it leaves the review PENDING.
4. If there are genuinely no issues, still create a pending review whose body says it looks good with an empty comments array.

Finally print a 1-2 line plain-text summary of what you flagged. Only the pending review — no normal PR comment."
    "$CLAUDE" -p "$PROMPT" --allowedTools Bash Read Grep Glob Write --strict-mcp-config 2>>"$LOG" )
}

echo "[$(date)] found ${#urls[@]} PR(s)" >> "$LOG"
for u in "${urls[@]}"; do
  res="$(review_one "$u")"
  printf '• %s\n%s\n\n' "$u" "$res"
done
echo "[$(date)] all done (${#urls[@]} PRs)" >> "$LOG"
