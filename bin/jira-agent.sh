#!/bin/zsh
# Jira agent (Ctrl+Cmd+J). Takes the ticket URL as $1 (or stdin), pops a repo
# picker (the product groups from repo-groups.conf, plus "Custom…" to assemble a
# one-off set by hand), and opens a kitty `claude` session scoped to those repos.
#
# Two modes:
#   default   BUILD — branch off develop, failing test first, implement until the
#             repo's own check passes, commit, write a PR body. Stops once, at the
#             end. Resolves ordinary ambiguity itself and logs the assumptions
#             rather than handing back a list of questions.
#   --plan    READ-ONLY — investigate and produce a plan, touch nothing. For
#             scoping or estimating a ticket you have not committed to yet.
#
#   --push    (build mode only) also push the branch and open the draft PR.
#             Off by default, per ~/.claude/CLAUDE.md: only push when asked.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/jira-agent.log

source "$HOME/.config/voice-setup/reply-repos.conf"  2>/dev/null
source "$HOME/.config/voice-setup/repo-groups.conf"  2>/dev/null
: "${GIT_BASE:=$HOME/Documents/git}"

PICKER="$HOME/.local/bin/pick-repo-group.sh"
[[ -r "$PICKER" ]] || PICKER="$(cd "$(dirname "$0")" && pwd)/pick-repo-group.sh"
source "$PICKER" || { echo "[$(date)] cannot source $PICKER" >> "$LOG"; echo "NO_PICKER"; exit 1; }

mode=build
push=0
args=()
for a in "$@"; do
  case "$a" in
    --plan) mode=plan ;;
    --push) push=1 ;;
    *) args+=("$a") ;;
  esac
done

url="${args[1]:-$(cat)}"
url="${url//[[:space:]]/}"
KEY="$(printf '%s' "$url" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)"
[[ -z "$KEY" ]] && { echo "[$(date)] no Jira key in: $url" >> "$LOG"; echo "NO_JIRA_KEY"; exit 1; }
echo "[$(date)] ticket $KEY ($url) mode=$mode push=$push" >> "$LOG"

[[ -z "${GROUP_ORDER:-}" ]] && { echo "[$(date)] no GROUP_ORDER (edit repo-groups.conf)" >> "$LOG"; echo "NO_GROUPS"; exit 1; }

# Which repos? Groups from repo-groups.conf, or "Custom…" to pick by hand.
if [[ $mode == plan ]]; then
  pick_repo_group "Jira $KEY — plan only: which repos?"
else
  pick_repo_group "Jira $KEY — build: which repos?"
fi
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

# --- How each repo proves its own work. This is what lets the build agent finish
# --- without you: a command it can run and read the exit code of.
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

if (( push )); then
  push_block="
STEP 8 — Push the branch and open a DRAFT PR against develop with \`gh\`. Title:
\"$KEY: <what changed>\". Body = the PR body from STEP 7."
else
  push_block="
STEP 8 — Do NOT push and do NOT open the PR. Print the exact commands I would run
to do it myself (git push -u plus the gh pr create), and leave the PR body on disk."
fi

# --- Shared by both modes. Two jobs: stop the agent asking things it could look
# --- up, and make it batch the questions it genuinely needs instead of firing
# --- them at me one at a time. Serial interruptions are what make delegating
# --- slower than just doing the work.
KNOWLEDGE="$HOME/.config/voice-setup/org-knowledge.md"
AMBIGUITY="=== HOW YOU HANDLE WHAT YOU DO NOT KNOW ===

Before you ask me anything, try all three of these:
  1. Read $KNOWLEDGE — where credentials come from, who owns what, past decisions.
     The answer is often already in there.
  2. Look in the code, the repo's CLAUDE.md, and the ticket's own comments.
  3. Search Jira and Confluence (Atlassian tools) and my mail (Gmail tools).
     Someone has usually answered this before; find it rather than asking me.
Only when all three come up empty is it a real blocker.

BATCH YOUR BLOCKERS — this is the important part. Do NOT discover them one at a
time and stop each time. Serial interruptions are the single most expensive thing
you can do to me: each one costs me a context switch worth more than the code you
wrote in between.

So: do a recon pass FIRST — read the ticket, the code and the knowledge file before
writing anything — work out the COMPLETE list of things you genuinely need a human
for, and print it as one block, early:

  🚧 NEEDS YOU — all of it, up front
    1. <what you need> — why, and what you will assume if I don't answer
    2. ...

Then KEEP WORKING on everything not blocked by that list. Do not wait for me. I
will answer the whole list in one pass while you work.

For anything merely under-specified — ambiguous, not blocked — take the most
conventional reading consistent with the existing code, PROCEED, and record it in
ASSUMPTIONS. Never ask me something the ticket already answers. Never ask me to
confirm a restatement of what I wrote. If you are 80% sure, that is sure enough.

Something is a REAL blocker only if:
  • it needs a credential or access you could not find via the three steps above,
  • the action is irreversible or outward-facing (push, deploy, prod, costs money),
  • two readings produce genuinely different products — not merely different
    implementations of the same product,
  • the ticket contradicts the code and you cannot tell which is stale."

if [[ $mode == plan ]]; then
PROMPT="$(cat <<EOF
Read Jira ticket $KEY ($url) with the Atlassian tools (by key $KEY — description AND
comments). Repos in scope: $REPO_LIST. Read each repo's CLAUDE.md first.

This is READ-ONLY scoping. Do not modify code, branches, or the ticket.

$AMBIGUITY

Produce, concisely:
  1. What the ticket is asking for, in 2-3 lines.
  2. The implementation plan — the specific files/areas to change in each repo.
  3. How it would be verified: the test you would write, and the repo's check:
$verify_block  4. Risks and edge cases.
  5. ASSUMPTIONS — the judgment calls you made reading the ticket, one line each.
  6. Effort: rough size, and whether ⌃⌘J in build mode could take this all the way.

Then stop.
EOF
)"
TITLE="📋 $KEY · $group"
# Read-only: no Edit/Write at all, Jira read tools only.
ALLOWED_TOOLS="Read,Grep,Glob,TodoWrite,WebFetch,WebSearch,Task,\
Bash(cd:*),Bash(git:*),Bash(ls:*),Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(grep:*),\
Bash(rg:*),Bash(find:*),Bash(fd:*),Bash(sed:*),Bash(awk:*),Bash(wc:*),Bash(jq:*),\
Bash(sort:*),Bash(uniq:*),Bash(cut:*),Bash(date:*),Bash(echo:*),Bash(mkdir:*),\
Bash(python3:*),Bash(gh:*),\
mcp__claude_ai_Atlassian__getJiraIssue,mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql,\
mcp__claude_ai_Atlassian__search,mcp__claude_ai_Atlassian__fetch,\
mcp__claude_ai_Atlassian__getJiraIssueRemoteIssueLinks,mcp__claude_ai_Atlassian__getConfluencePage"

else
PROMPT="$(cat <<EOF
You are building Jira ticket $KEY ($url) to completion. Repos in scope: $REPO_LIST.
Working directory is $GIT_BASE/$primary; the others are added dirs.

Read each repo's CLAUDE.md first — it names that repo's layout and its check command.

$AMBIGUITY

STEP 1 — Read the ticket with the Atlassian tools (by key $KEY): description AND
comments. Read $KNOWLEDGE. Restate the ask in 2 lines.

STEP 2 — RECON, before you write anything. Read the code you will need to touch and
work out the complete blocker list per the rules above. Print the 🚧 NEEDS YOU block
now, while I can still start resolving it. Then carry on — do not wait.

STEP 3 — Get to a clean start. In each repo you will touch: if the working tree is
dirty or you are on an unrelated WIP branch, \`git stash push -m "pre-$KEY autostash"\`
(say so in your summary — never discard anything), then branch from an up-to-date
develop as feature/$KEY-<short-kebab-description>.

STEP 4 — Write the FAILING TEST FIRST, in that repo's existing test style and
location. Run it. Confirm it fails for the right reason. This is the definition of
done for this ticket — if you cannot express the ticket as a test, say so explicitly
in your summary and explain what you will use as the gate instead.

STEP 5 — Implement until the test passes. Smallest change that does it. Match the
surrounding code; do not reformat untouched lines; do not add a dependency if
something already in the repo covers it.

STEP 6 — Run the full check for each repo you touched and paste the real result:
$verify_block$runtime_note
If it does not pass, keep working. Do not hand me a red branch and ask what to do —
the one exception is a pre-existing failure you did not cause, which you should
identify as such and leave alone.

STEP 7 — Commit on the ticket branch. Message: "$KEY: <what changed and why>".
No Co-Authored-By, no "Generated with Claude Code". Then write the PR body to
/tmp/$KEY-pr.md, containing:
  • what changed and why, per repo
  • ASSUMPTIONS — every judgment call from above, one line each
  • "Test instructions for reviewer" — concrete, change-specific steps: setup, the
    exact actions, and what to expect. Happy path plus the edge cases this change
    touches. Not "run the tests".
$push_block

STEP 9 — Capture what you learned, so I never answer it twice. Append to
$KNOWLEDGE any durable fact this run produced: where a credential actually comes
from, who owns a system, why something is the way it is, which environment is
which. Repo-specific conventions go in that repo's CLAUDE.md instead. NEVER write
a secret value into either file — record where to get it and who owns it. If you
learned nothing durable, say so and skip it.

STEP 10 — Print a terminal summary in this shape:
  🔨 $KEY — <one line>
  Branch: <branch>  ·  Repos: <list>
  ✅ <repo>: <the actual check output, e.g. "64 tests, 0 failures">
  📝 Assumptions I made (overrule any of these):
    • <one line each>
  🚧 Still blocked on you: <the unanswered NEEDS YOU items, or "none">
  📚 Added to org-knowledge.md: <what, or "nothing new">
  ⚠️  Stashed WIP: <repo: stash name, or "none">
  📄 PR body: /tmp/$KEY-pr.md
Then stop. That is the ONLY stop — do not stop before this point for direction.
EOF
)"
TITLE="🔨 $KEY · $group"
# Build mode needs to write code and run each repo's checks unattended. Additive
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
fi

CLAUDE="$(command -v claude)"
KITTY="/Applications/kitty.app/Contents/MacOS/kitty"; [[ -x "$KITTY" ]] || KITTY="$(command -v kitty)"
[[ -z "$CLAUDE" || -z "$KITTY" ]] && { echo "[$(date)] missing claude or kitty" >> "$LOG"; echo "MISSING_TOOL"; exit 1; }

echo "[$(date)] launching: mode=$mode group=$group primary=$primary repos=$REPO_LIST title=$TITLE" >> "$LOG"
# Sessions are keyed by cwd, and --add-dir is not persisted across a resume, so
# log the exact command that brings this one back after a crash / accidental
# close. Recover it with:  grep 'RESUME .*<KEY>' /tmp/jira-agent.log | tail -1
echo "[$(date)] RESUME $KEY: cd $GIT_BASE/$primary && claude --resume $KEY ${add_args[*]}" >> "$LOG"
# All agent sessions run inside ONE kitty instance (--single-instance), so each is
# a window of the same process. That makes cmd-` cycle between them (like browser
# windows) and Mission Control group them. --title pins the window title to the
# ticket so you can tell sessions apart — claude's TUI would otherwise overwrite it.
# NOTE: prompt must come BEFORE --add-dir / --allowedTools (both variadic).
"$KITTY" --single-instance --directory "$GIT_BASE/$primary" --title "$TITLE" \
  "$CLAUDE" "$PROMPT" "${add_args[@]}" \
  --allowedTools "$ALLOWED_TOOLS" >>"$LOG" 2>&1 &
echo "OK $group"
