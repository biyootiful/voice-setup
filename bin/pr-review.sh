#!/bin/zsh
# Review a GitHub PR with Claude Code and leave a PENDING review (inline comments
# + summary) that YOU submit. Takes the PR URL as $1 (or stdin). Posts under the
# configured work gh account. Nothing is submitted automatically.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/pr-review.log

CONFIG="$HOME/.config/voice-setup/reply-repos.conf"
[ -f "$CONFIG" ] && source "$CONFIG"
: "${GIT_BASE:=$HOME/Documents/git}"
: "${GH_ACCOUNT:=insticator-biY}"   # the work account reviews post under

url="${1:-$(cat)}"
url="${url//[[:space:]]/}"
[ -z "$url" ] && { echo "[$(date)] no url" >> "$LOG"; exit 0; }
case "$url" in
  https://github.com/*/*/pull/*) ;;
  *) echo "[$(date)] not a PR url: $url" >> "$LOG"; echo "NOT_A_PR_URL"; exit 1 ;;
esac

# make sure reviews post under the intended account
gh auth switch --hostname github.com --user "$GH_ACCOUNT" >/dev/null 2>&1 || true

rest="${url#https://github.com/}"
owner="${rest%%/*}"; rest="${rest#*/}"
repo="${rest%%/*}";  rest="${rest#*/}"
number="${rest#pull/}"; number="${number%%/*}"

# review from the local checkout if we have it (better context), else a temp dir
workdir="$GIT_BASE/$repo"
[ -d "$workdir" ] || workdir="$(mktemp -d)"
cd "$workdir" || exit 1
echo "[$(date)] reviewing $owner/$repo#$number as $GH_ACCOUNT (workdir=$workdir)" >> "$LOG"

PROMPT="Review GitHub pull request $url (owner=$owner, repo=$repo, number=$number) and leave a PENDING review that the human will submit. Do NOT submit or approve anything.

Steps:
1. Run 'gh pr view $url' and 'gh pr diff $url' to read the description and the full diff.
2. Read surrounding code for context (you may be inside the repo checkout). Focus on REAL issues: correctness bugs, security, broken logic, race conditions, API/contract breakage, and missing or wrong tests. Skip pure style nitpicks.
3. Create a PENDING review via the GitHub API. Write a JSON payload and run:
     gh api -X POST repos/$owner/$repo/pulls/$number/reviews --input <payload.json>
   payload.json must contain a 'body' (a short overall summary) and a 'comments' array of objects {path, line, side, body} anchored to changed lines. Do NOT include an 'event' field — omitting it leaves the review PENDING for the human to submit.
4. If there are genuinely no issues, still create a pending review whose body says it looks good, with an empty comments array.

Finally, print a 2-3 line plain-text summary of what you flagged (this goes to a notification). Do not leave a normal PR comment; only the pending review."

CLAUDE="$(command -v claude)"
[ -z "$CLAUDE" ] && { echo "[$(date)] claude CLI not found" >> "$LOG"; exit 1; }

out="$("$CLAUDE" -p "$PROMPT" \
  --allowedTools Bash Read Grep Glob Write \
  --strict-mcp-config 2>>"$LOG")"
echo "[$(date)] done exit=$? len=${#out}" >> "$LOG"
print -r -- "$out"
