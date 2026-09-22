#!/bin/zsh
# Jira BUILD agent (Ctrl+Cmd+B). The counterpart to jira-agent.sh (⌃⌘J):
# where that one produces a read-only plan and stops, this one goes all the way
# to code that verifies itself — failing test first, implement until the repo's
# own check passes, commit on a ticket branch, and write out a PR body.
#
# The point is that it does NOT hand back mid-flight. It resolves ordinary
# ambiguity by assuming the conventional reading and recording the assumption,
# and stops only for things that are genuinely yours to decide.
#
# By default it does NOT push and does NOT open the PR (per ~/.claude/CLAUDE.md:
# only push when explicitly asked). Pass --push to let it do both.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/jira-build.log

source "$HOME/.config/voice-setup/reply-repos.conf"  2>/dev/null
source "$HOME/.config/voice-setup/repo-groups.conf"  2>/dev/null
: "${GIT_BASE:=$HOME/Documents/git}"

PICKER="$HOME/.local/bin/pick-repo-group.sh"
[[ -r "$PICKER" ]] || PICKER="$(cd "$(dirname "$0")" && pwd)/pick-repo-group.sh"
source "$PICKER" || { echo "[$(date)] cannot source $PICKER" >> "$LOG"; echo "NO_PICKER"; exit 1; }

push=0
args=()
for a in "$@"; do
  case "$a" in
    --push) push=1 ;;
    *) args+=("$a") ;;
  esac
done

url="${args[1]:-$(cat)}"
url="${url//[[:space:]]/}"
KEY="$(printf '%s' "$url" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)"
[[ -z "$KEY" ]] && { echo "[$(date)] no Jira key in: $url" >> "$LOG"; echo "NO_JIRA_KEY"; exit 1; }
echo "[$(date)] ticket $KEY ($url) push=$push" >> "$LOG"

[[ -z "${GROUP_ORDER:-}" ]] && { echo "[$(date)] no GROUP_ORDER (edit repo-groups.conf)" >> "$LOG"; echo "NO_GROUPS"; exit 1; }

pick_repo_group "Jira $KEY — build: which repos?"
case $? in
  0) ;;
  1) echo "[$(date)] picker cancelled" >> "$LOG"; echo "CANCELLED"; exit 0 ;;
  *) echo "[$(date)] picker found no usable repos" >> "$LOG"; echo "NO_REPOS"; exit 1 ;;
esac

group="$PICK_LABEL"
existing=("${PICK_REPOS[@]}")
primary="${existing[1]}"
add_args=()
(( ${#existing[@]} > 1 )) && for r in ${existing[2,-1]}; do add_args+=(--add-dir "$GIT_BASE/$r"); done
REPO_LIST="${existing[*]}"

# --- How each repo proves its own work. This is what makes the agent able to
# --- finish without you: a command it can run and read the exit code of.
typeset -A VERIFY
VERIFY[assistant-ui]='npm test && npm run typecheck && npm run lint'
VERIFY[platform-api]='./mvnw test'
VERIFY[platform-web]='npx tsc --noEmit && yarn lint'
VERIFY[platform-functions]='cd <the subproject you changed> && (python -m pytest tests/ -q || npm test)'
VERIFY[billing-service]='JAVA_HOME=$(/usr/libexec/java_home -v 1.8) ./sbt test'
VERIFY[portal-api]='JAVA_HOME=$(/usr/libexec/java_home -v 1.8) ./sbt test'

verify_block=""
for r in "${existing[@]}"; do
  v="${VERIFY[$r]:-<no known check — find one and say what you used>}"
  verify_block+="  • $r → $v"$'\n'
done

# platform-web has no unit tests, so its real gate is driving the running app.
runtime_note=""
if (( ${existing[(Ie)platform-web]} )); then
  runtime_note="
RUNTIME CHECK (platform-web only): it has zero unit tests, so for any visible
UI change the gate is the running app. \`npm start\` serves localhost:3000 against
the DEPLOYED dev backend — you do not need platform-api running. Drive it with
the Chrome tools, then read read_console_messages and read_network_requests and
confirm you added no errors or failed calls. Login is Cognito: if it sits on the
login screen, STOP and ask me to log in once — never script a Cognito login."
fi

push_block=""
if (( push )); then
  push_block="
STEP 7 — Push the branch and open a DRAFT PR against develop with \`gh\`. Title:
\"$KEY: <what changed>\". Body = the PR body from STEP 6."
else
  push_block="
STEP 7 — Do NOT push and do NOT open the PR. Print the exact commands I would run
to do it myself (git push -u plus the gh pr create), and leave the PR body on disk."
fi

PROMPT="$(cat <<EOF
You are building Jira ticket $KEY ($url) to completion. Repos in scope: $REPO_LIST.
Working directory is $GIT_BASE/$primary; the others are added dirs.

Read each repo's CLAUDE.md first — it names that repo's layout and its check command.

=== HOW YOU HANDLE AMBIGUITY (this is the important part) ===
Do NOT hand a list of questions back to me. For anything under-specified, take the
most conventional reading consistent with the existing code, PROCEED, and record it
as one line in an ASSUMPTIONS list. I will overrule the ones I disagree with when I
read the diff — that is far cheaper for me than answering questions up front.

STOP and ask me ONLY if one of these is true:
  • the action is irreversible or outward-facing (push, deploy, migration against a
    real DB, anything touching prod, anything that costs money, sending mail),
  • it needs a credential or access you do not have,
  • two readings of the ticket produce genuinely different products — not merely a
    different implementation of the same product,
  • the ticket contradicts what the code actually does, and you cannot tell which is
    stale.
Never ask me something the ticket already answers. Never ask me to confirm a
restatement of what I wrote. If you are 80% sure, that is sure enough — proceed and
log the assumption.

STEP 1 — Read the ticket with the Atlassian tools (by key $KEY): description AND
comments. Restate the ask in 2 lines. Then stop talking and start working.

STEP 2 — Get to a clean start. In each repo you will touch: if the working tree is
dirty or you are on an unrelated WIP branch, \`git stash push -m "pre-$KEY autostash"\`
(say so in your summary — never discard anything), then branch from an up-to-date
develop as feature/$KEY-<short-kebab-description>.

STEP 3 — Write the FAILING TEST FIRST, in that repo's existing test style and
location. Run it. Confirm it fails for the right reason. This is the definition of
done for this ticket — if you cannot express the ticket as a test, say so explicitly
in your summary and explain what you will use as the gate instead.

STEP 4 — Implement until the test passes. Smallest change that does it. Match the
surrounding code; do not reformat untouched lines; do not add a dependency if
something already in the repo covers it.

STEP 5 — Run the full check for each repo you touched and paste the real result:
$verify_block$runtime_note
If it does not pass, keep working. Do not hand me a red branch and ask what to do —
the one exception is a pre-existing failure you did not cause, which you should
identify as such and leave alone.

STEP 6 — Commit on the ticket branch. Message: "$KEY: <what changed and why>".
No Co-Authored-By, no "Generated with Claude Code". Then write the PR body to
/tmp/$KEY-pr.md, containing:
  • what changed and why, per repo
  • ASSUMPTIONS — every judgment call from above, one line each
  • "Test instructions for reviewer" — concrete, change-specific steps: setup, the
    exact actions, and what to expect. Happy path plus the edge cases this change
    touches. Not "run the tests".
$push_block

STEP 8 — Print a terminal summary in this shape:
  🔨 $KEY — <one line>
  Branch: <branch>  ·  Repos: <list>
  ✅ <repo>: <the actual check output, e.g. "64 tests, 0 failures">
  📝 Assumptions I made (overrule any of these):
    • <one line each>
  ⚠️  Stashed WIP: <repo: stash name, or "none">
  📄 PR body: /tmp/$KEY-pr.md
Then stop. That is the ONLY stop — do not stop before this point for direction.
EOF
)"

CLAUDE="$(command -v claude)"
KITTY="/Applications/kitty.app/Contents/MacOS/kitty"; [[ -x "$KITTY" ]] || KITTY="$(command -v kitty)"
[[ -z "$CLAUDE" || -z "$KITTY" ]] && { echo "[$(date)] missing claude or kitty" >> "$LOG"; echo "MISSING_TOOL"; exit 1; }

# Build agent needs to write code and run each repo's checks unattended. Additive
# and session-scoped; permissions.ask (git push, rm) still wins, so the
# irreversible gates stay even with --push.
ALLOWED_TOOLS="Read,Write,Edit,Grep,Glob,TodoWrite,Task,WebFetch,WebSearch,\
Bash(cd:*),Bash(git:*),Bash(ls:*),Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(grep:*),\
Bash(rg:*),Bash(find:*),Bash(fd:*),Bash(sed:*),Bash(awk:*),Bash(wc:*),Bash(jq:*),\
Bash(sort:*),Bash(uniq:*),Bash(cut:*),Bash(date:*),Bash(echo:*),Bash(mkdir:*),\
Bash(npm:*),Bash(yarn:*),Bash(npx:*),Bash(pytest:*),Bash(python3:*),Bash(python:*),\
Bash(pip:*),Bash(pip3:*),Bash(./mvnw:*),Bash(mvn:*),Bash(./sbt:*),Bash(./gradlew:*),\
Bash(gh:*),Bash(node:*),mcp__claude-in-chrome,\
mcp__claude_ai_Atlassian__getJiraIssue,mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql,\
mcp__claude_ai_Atlassian__search,mcp__claude_ai_Atlassian__fetch,\
mcp__claude_ai_Atlassian__getJiraIssueRemoteIssueLinks"

TITLE="🔨 $KEY · $group"
echo "[$(date)] launching build: group=$group primary=$primary repos=$REPO_LIST push=$push" >> "$LOG"
echo "[$(date)] RESUME $KEY: cd $GIT_BASE/$primary && claude --resume $KEY ${add_args[*]}" >> "$LOG"
# NOTE: prompt must come BEFORE --add-dir / --allowedTools (both variadic).
"$KITTY" --single-instance --directory "$GIT_BASE/$primary" --title "$TITLE" \
  "$CLAUDE" "$PROMPT" "${add_args[@]}" \
  --allowedTools "$ALLOWED_TOOLS" >>"$LOG" 2>&1 &
echo "OK $group"
