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
auto=0          # --auto: unattended run for autopilot.sh (implies --push)
repos_arg=""    # --repos a,b: skip the picker
resume_sid=""   # --resume <sid>: continue that session instead of starting fresh
takeover_pid=""
review_file=""  # --review <file>: (with --auto) resolve code-review threads on the open PR
args=()
while (( $# )); do
  case "$1" in
    --plan)   mode=plan ;;
    --push)   push=1 ;;
    --auto)   auto=1; push=1 ;;
    --repos)  shift; repos_arg="$1" ;;
    --resume) shift; resume_sid="$1" ;;
    --takeover-pid) shift; takeover_pid="$1" ;;   # with --resume: stop this idle window first
    --review) shift; review_file="$1" ;;
    *) args+=("$1") ;;
  esac
  shift
done

url="${args[1]:-$(cat)}"
url="${url//[[:space:]]/}"
KEY="$(printf '%s' "$url" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)"
[[ -z "$KEY" ]] && { echo "[$(date)] no Jira key in: $url" >> "$LOG"; echo "NO_JIRA_KEY"; exit 1; }
echo "[$(date)] ticket $KEY ($url) mode=$mode push=$push" >> "$LOG"

[[ -z "${GROUP_ORDER:-}" ]] && { echo "[$(date)] no GROUP_ORDER (edit repo-groups.conf)" >> "$LOG"; echo "NO_GROUPS"; exit 1; }

# Which repos? --repos (the autopilot, unattended), else groups from
# repo-groups.conf or "Custom…" to pick by hand.
if [[ -n "$repos_arg" ]]; then
  PICK_LABEL="autopilot"
  PICK_REPOS=()
  for r in ${(s:,:)repos_arg}; do
    [[ -e "$GIT_BASE/$r/.git" ]] && PICK_REPOS+=("$r") || echo "[$(date)] --repos: no repo $r" >> "$LOG"
  done
  (( ${#PICK_REPOS} )) || { echo "NO_REPOS"; exit 1; }
else
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
fi

group="$PICK_LABEL"
existing=("${PICK_REPOS[@]}")
primary="${existing[1]}"

# Unattended builds run in their own git worktree per ticket, so two agents on the
# same repo (or my own checkout) never share a working tree. Branch refs are
# shared, so autopilot-ship.sh pushes from the main checkout as usual.
ROOT="$GIT_BASE"
if (( auto )) && [[ -z "$resume_sid" ]]; then
  ROOT="$GIT_BASE/.autopilot/$KEY"
  for r in "${existing[@]}"; do
    wt="$ROOT/$r"
    [[ -e "$wt/.git" ]] && continue
    base=develop
    git -C "$GIT_BASE/$r" fetch -q origin 2>>"$LOG"
    git -C "$GIT_BASE/$r" rev-parse -q --verify origin/develop >/dev/null \
      || base="$(git -C "$GIT_BASE/$r" symbolic-ref -q --short refs/remotes/origin/HEAD | sed 's|^origin/||')"
    mkdir -p "$ROOT"
    git -C "$GIT_BASE/$r" worktree add -q --detach "$wt" "origin/${base:-main}" >>"$LOG" 2>&1 \
      || { echo "[$(date)] worktree add failed for $r" >> "$LOG"; echo "WORKTREE_FAILED $r"; exit 1; }
    echo "[$(date)] worktree $wt at origin/${base:-main}" >> "$LOG"
  done
fi

add_args=()
(( ${#existing[@]} > 1 )) && for r in ${existing[2,-1]}; do add_args+=(--add-dir "$ROOT/$r"); done
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

if (( auto )); then
  # Unattended (autopilot.sh). Nobody is watching this window, and git push /
  # gh pr merge sit behind permissions.ask, so the agent never pushes: it leaves a
  # READY marker and autopilot-ship.sh (plain shell, fixed guards) pushes, opens
  # the PR, waits for CI and merges to develop.
  source "$HOME/.config/voice-setup/autopilot.conf" 2>/dev/null
  push_block="
STEP 8 — UNATTENDED RUN. No human is watching this window.
  • You are in a fresh per-ticket git worktree (detached at origin/<base>), not my
    checkout: skip STEP 3's stash and just create the branch here. Install
    dependencies first if the repo's check needs them (e.g. npm ci).
  • Do NOT git push, open a PR, or merge — autopilot-ship.sh does that from your marker.
  • NEEDS YOU items: do not wait for an answer. Post the whole block as ONE Jira
    comment on $KEY, add the label needs-human, finish everything not blocked, and
    say so in the marker.
  • HARD STOPS — do the code, but set \"hard_stop\" in the marker and never run:
    ${AP_HARD_STOPS:-infra applies, prod data writes, secret changes, or anything needing another team.}
    A repo with no develop branch targets main, which is prod: always a hard stop.
  • Before the marker, review your own diff with a fresh subagent (Task): ask it
    for correctness bugs and for anything that contradicts the ticket. Fix what
    it finds, re-run the checks, and note what it found.
  • Then write /tmp/$KEY-ready.json — exactly this shape, valid JSON:
      {\"key\": \"$KEY\",
       \"repos\": [{\"repo\": \"<name>\", \"branch\": \"<branch>\", \"base\": \"develop|main\",
                   \"check\": \"<command you ran>\", \"check_passed\": true}],
       \"pr_title\": \"$KEY: <what changed>\",
       \"pr_body\": \"/tmp/$KEY-pr.md\",
       \"review\": \"<what the review subagent found and what you fixed>\",
       \"hard_stop\": null | \"<why a human must merge or act>\",
       \"needs_human\": [\"<open NEEDS YOU items, if any>\"]}
    Write it only when every touched repo's check passes on a committed tree.
    If you cannot get there, write no marker and say why in STEP 10."
elif (( push )); then
  push_block="
STEP 8 — Push the branch and open a DRAFT PR against develop with \`gh\`. Title:
\"$KEY: <what changed>\". Body = the PR body from STEP 7."
else
  push_block="
STEP 8 — Default: don't push, don't open the PR. Leave the PR body on disk and
print the exact git push -u / gh pr create commands.
This is a DEFAULT, not a prohibition. If I ask for the push or the PR at any point
in the session — \"push it\", \"pr link\", \"can I merge\" — that overrides this
immediately and you just do it. Never tell me you are blocked from doing something
I have just asked you to do; if a tool call is denied, say what was denied and
retry it once now that I have asked."
fi

# --- Shared by both modes. Two jobs: stop the agent asking things it could look
# --- up, and make it batch the questions it genuinely needs instead of firing
# --- them at me one at a time. Serial interruptions are what make delegating
# --- slower than just doing the work.
KNOWLEDGE="$HOME/.config/voice-setup/org-knowledge.md"
AMBIGUITY="=== HOW YOU HANDLE WHAT YOU DO NOT KNOW ===

Before you ask me anything, try all four of these:
  1. Read $KNOWLEDGE — where credentials come from, who owns what, past decisions.
     The answer is often already in there.
  2. Look in the code, the repo's CLAUDE.md, and the ticket's own comments.
  3. Search Jira and Confluence (Atlassian tools) and my mail (Gmail tools).
     Someone has usually answered this before; find it rather than asking me.
  4. CREDENTIALS — never ask me for a token, key or password without doing this
     first. Run \`agent-secret.sh list\`. If what you need is there and present,
     read it with \`agent-secret.sh get <name>\` and use it inline —
     \`KEY=\"\$(agent-secret.sh get <name>)\"\` — NEVER echo it, print it, write it
     to a file, or paste it into a commit, PR or Jira comment.
     If it is absent, run:
       agent-secret.sh need <name> \"<how to get it, in one sentence>\" \"<owner>\"
     That registers it and prints the command I run to add it. Put it in your
     NEEDS YOU block and CARRY ON with other work — do not wait.
     You cannot add secrets yourself, by design. Never ask me to paste a secret
     into this session.
Only when all four come up empty is it a real blocker.

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
Working directory is $ROOT/$primary; the others are added dirs.

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
a secret value into either file — record where to get it and who owns it.
If I told you during this run how to obtain ANY credential, you must also run
\`agent-secret.sh need <name> \"<how to get it>\" \"<owner>\"\` so the next agent
finds it without asking me. That is not optional — it is the whole point.
If you learned nothing durable, say so and skip it.

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
(( auto )) && ALLOWED_TOOLS+=",mcp__claude_ai_Atlassian__addCommentToJiraIssue,\
mcp__claude_ai_Atlassian__editJiraIssue,mcp__claude_ai_Atlassian__transitionJiraIssue,\
mcp__claude_ai_Atlassian__getTransitionsForJiraIssue"
(( auto )) && TITLE="🤖 $KEY · autopilot"
fi

# --review: the PR is open and an automated reviewer left threads. That reviewer
# sees only the diff (no ticket, no surrounding code), so each comment is a claim
# to test, not an instruction. The agent decides per thread; autopilot-ship.sh
# posts the replies and resolves, so nothing outward-facing happens from here.
if [[ -n "$review_file" ]]; then
  (( auto )) || { echo "[$(date)] --review needs --auto" >> "$LOG"; echo "REVIEW_NEEDS_AUTO"; exit 1; }
  [[ -r "$review_file" ]] || { echo "[$(date)] no review file $review_file" >> "$LOG"; echo "NO_REVIEW_FILE"; exit 1; }
  PROMPT="$(cat <<REVIEW
You are resolving automated code-review comments on the open PR(s) for Jira
ticket $KEY ($url). Repos in scope: $REPO_LIST. Worktrees are under $ROOT.

The unresolved threads are in $review_file: per repo the PR number, branch, and
each thread's id, path, line, url and comments.

The reviewer is a bot that sees only the diff: no ticket, no product context,
often not the code around the change. Treat every comment as a HYPOTHESIS to
test, not an instruction, and expect false positives. Its severity markers are
its guess, not a fact.

STEP 1 — Context before judging. Read the ticket (description and comments) with
the Atlassian tools, $HOME/.config/voice-setup/org-knowledge.md, each repo's
CLAUDE.md, the PR description (gh pr view), and the whole diff
(git diff origin/<base>...<branch>).

STEP 2 — Get onto the branch in each worktree: git switch <branch> if you are not
on it, then git pull --ff-only origin <branch>.

STEP 3 — Probe each thread before touching code:
  • Read what it points at AND what that depends on: callers, transaction /
    async / thread boundaries, config, existing tests, how the repo does the
    same thing elsewhere.
  • Write the claim in one line, and what would have to be true for it to be a
    real bug.
  • Try to prove it: a test that fails if the claim is right, or the exact path
    traced with file:line. A claim you cannot demonstrate is not established.
  • Check whether the ticket or existing code made it a deliberate choice.
  • Verdict:
      fixed          real. Minimal fix, with a test that fails before and passes after.
      false_positive wrong for this codebase. The reply must carry the evidence:
                     file:line of the guarding code, the passing test, the ticket
                     line. "Looks fine" is not evidence.
      needs_human    real but a product/scope call, or you genuinely cannot tell.
  Never change code just to make a comment go away: a plausible fix for a
  non-bug is a regression.

STEP 4 — Run the full check for each repo you touched and read the result:
$verify_block
Commit on the same branch: "$KEY: address review — <what>". No Co-Authored-By.

STEP 5 — Write /tmp/$KEY-ready.json as the unattended rules below describe, PLUS
  "review_replies": [{"repo": "<repo>", "thread_id": "<id from the file>",
                      "verdict": "fixed|false_positive|needs_human",
                      "reply": "<1-4 sentences for the thread: fixed → what changed
                                 and the commit sha; false_positive → the evidence>"}]
with one entry per thread in the file. autopilot-ship.sh posts each reply and
resolves the fixed / false_positive threads after it pushes; needs_human threads
stay open (list them in needs_human too). Do NOT reply, resolve or push yourself.
Write the marker even if every thread is a false positive and you committed nothing.
pr_body: keep /tmp/$KEY-pr.md (recreate it from gh pr view --json body if missing).
$push_block

Then print one line per thread (verdict · why) and stop.
REVIEW
)"
  TITLE="🔍 $KEY · review"
fi

CLAUDE="$(command -v claude)"
KITTY="/Applications/kitty.app/Contents/MacOS/kitty"; [[ -x "$KITTY" ]] || KITTY="$(command -v kitty)"
[[ -z "$CLAUDE" || -z "$KITTY" ]] && { echo "[$(date)] missing claude or kitty" >> "$LOG"; echo "MISSING_TOOL"; exit 1; }

echo "[$(date)] launching: mode=$mode group=$group primary=$primary repos=$REPO_LIST title=$TITLE" >> "$LOG"
# Sessions are keyed by cwd, and --add-dir is not persisted across a resume, so
# log the exact command that brings this one back after a crash / accidental
# close. Recover it with:  grep 'RESUME .*<KEY>' /tmp/jira-agent.log | tail -1
echo "[$(date)] RESUME $KEY: cd $ROOT/$primary && claude --resume $KEY ${add_args[*]}" >> "$LOG"
# All agent sessions run inside ONE kitty instance (--single-instance), so each is
# a window of the same process. That makes cmd-` cycle between them (like browser
# windows) and Mission Control group them. --title pins the window title to the
# ticket so you can tell sessions apart — claude's TUI would otherwise overwrite it.
# NOTE: prompt must come BEFORE --add-dir / --allowedTools (both variadic).
if [[ -n "$resume_sid" ]]; then
  # Pick up an existing session where it left off. Its transcript already holds
  # the original instructions; this restates the finish line (and, under --auto,
  # the unattended rules, which an older session never saw).
  [[ -n "$review_file" ]] || PROMPT="Resuming $KEY where you left off. First re-establish state without
redoing finished work: git status, current branch, git log against the base, and
any open PR for $KEY. Then continue from the first unfinished step through to the
final summary.
$( (( auto )) && print -r -- "$push_block" )"
  # Two processes writing one transcript corrupt it, so an open-but-idle window
  # is stopped before the resume. Only a claude process that is provably this
  # session (its argv names the sid, or the ticket key in an agent prompt) — never
  # a session someone started by hand; ticket-state.py already excludes those.
  if [[ -n "${takeover_pid:-}" ]]; then
    pcmd="$(ps -o command= -p "$takeover_pid" 2>/dev/null)"
    if [[ "$pcmd" == *claude* && ( "$pcmd" == *"$resume_sid"* || "$pcmd" == *"Jira ticket $KEY "* ) ]]; then
      echo "[$(date)] takeover: stopping idle pid $takeover_pid for $KEY" >> "$LOG"
      kill -TERM "$takeover_pid"
      for _ in {1..20}; do kill -0 "$takeover_pid" 2>/dev/null || break; sleep 0.5; done
      kill -0 "$takeover_pid" 2>/dev/null && { echo "TAKEOVER_FAILED $takeover_pid still running"; exit 1; }
    else
      echo "[$(date)] takeover refused: pid $takeover_pid is not $KEY/$resume_sid ($pcmd)" >> "$LOG"
      echo "TAKEOVER_REFUSED"; exit 1
    fi
  fi
  # The resumed session's directory is the one it was started in, not $primary.
  rcwd="$(python3 "$(dirname "$0")/claude-sessions.py" "$resume_sid" --all | head -1 | cut -f3)"
  [[ -d "$rcwd" ]] || rcwd="$ROOT/$primary"
  echo "[$(date)] resuming $KEY session $resume_sid in $rcwd" >> "$LOG"
  "$KITTY" --single-instance --directory "$rcwd" --title "$TITLE ↻" \
    "$CLAUDE" --resume "$resume_sid" "$PROMPT" "${add_args[@]}" \
    --allowedTools "$ALLOWED_TOOLS" >>"$LOG" 2>&1 &
  echo "OK resumed $resume_sid"
  exit 0
fi
"$KITTY" --single-instance --directory "$ROOT/$primary" --title "$TITLE" \
  "$CLAUDE" "$PROMPT" "${add_args[@]}" \
  --allowedTools "$ALLOWED_TOOLS" >>"$LOG" 2>&1 &
echo "OK $group"
