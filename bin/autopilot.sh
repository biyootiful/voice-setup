#!/bin/zsh
# Ticket autopilot — an "agent PM" for one Jira board.
#
#   autopilot.sh                     # full run: ship, groom, pick, dispatch
#   autopilot.sh ABC-12 ABC-34       # pilot: only these tickets, no grooming
#   autopilot.sh --dry-run           # decide and report, change nothing
#
# Board, repos, labels, reviewers and rules come from
# ~/.config/voice-setup/autopilot.conf (see config/autopilot.conf.example).
#
# One run, in order:
#   1. SHIP     autopilot-ship.sh pushes / PRs / merges whatever build agents finished.
#   2. LOOK     for each candidate ticket, report the Claude sessions,
#   (ticket-state.py) branches and PRs that already exist — so an open or closed session
#               is picked up where it left off instead of started over.
#   3. GROOM    (full run) tickets that are not ready get one Jira comment with
#               the questions and the needs-human label; ready ones get agent-ready.
#   4. DISPATCH up to MAX_IN_FLIGHT agents via jira-agent.sh --auto (new, resume,
#               or take over an idle window), and move merged work to Staging.
#   5. REPORT   ~/.local/state/autopilot/report-<date>.md
#
# Scope: AP_PROJECT tickets carrying an AP_SCOPE_LABELS label, minus AP_EXCLUDE.
# Humans review at the release PR (develop→main), not per ticket.

emulate -L zsh
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
source "$HOME/.config/voice-setup/reply-repos.conf" 2>/dev/null
source "$HOME/.config/voice-setup/autopilot.conf" 2>/dev/null \
  || { print -u2 "missing ~/.config/voice-setup/autopilot.conf (see config/autopilot.conf.example)"; exit 1; }
: "${AP_MAX_IN_FLIGHT:=2}"
JIRA_SITE="$AP_JIRA_SITE"
MAX_IN_FLIGHT="$AP_MAX_IN_FLIGHT"
BIN="$(cd "$(dirname "$0")" && pwd)"
STATE="$HOME/.local/state/autopilot"
KNOWLEDGE="$HOME/.config/voice-setup/org-knowledge.md"
mkdir -p "$STATE"
LOG="$STATE/autopilot.log"

dry=0; keys=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    *) keys+=("${a:u}") ;;
  esac
done

print -r -- "[$(date '+%F %T')] run start dry=$dry keys=${keys[*]:-all}" >> "$LOG"

# 1. SHIP — deterministic, before any decisions, so this run sees fresh PR state.
if (( dry )); then "$BIN/autopilot-ship.sh" --dry-run; else "$BIN/autopilot-ship.sh"; fi 2>>"$LOG"

REPORT="$STATE/report-$(date +%F-%H%M).md"
if (( ${#keys} )); then
  scope="ONLY these tickets: ${keys[*]}. Skip GROOM (they are already groomed) and
skip discovery — but still run LOOK and DISPATCH for each of them."
else
  scope="Discover candidates yourself:
  project = $AP_PROJECT AND statusCategory != Done AND labels in (${AP_SCOPE_LABELS// /, })
  AND issuetype != Epic ORDER BY rank ASC
Use fields [summary, status, labels, assignee, issuetype, priority] for the list
(the JQL tool is very verbose — never request description for a whole page)."
fi

if (( dry )); then
  act="DRY RUN: decide everything, report it, but run NO jira-agent.sh, write
nothing to Jira, and change no labels. Say what you WOULD do."
else
  act="LIVE RUN: carry out the actions."
fi

PROMPT="$(cat <<EOF
TICKET AUTOPILOT — you are the product manager agent for the $AP_PROJECT Jira
board (site $JIRA_SITE). Developers are the bottleneck; your job is
to keep agent builders busy on ready work so humans only review release PRs.
$act

Read $KNOWLEDGE first (roles, repos, environments, gotchas).

SCOPE. $scope
Never touch: $AP_EXCLUDE
Nor anything labeled needs-human unless a human has commented after that label
was added.

LOOK — for every candidate, run:
  python3 $BIN/ticket-state.py <KEY> [<KEY> ...] --fetch
(batch the keys in one call). Its verdict is authoritative about existing work:
  live-working / live-waiting / live-manual → leave alone, just report it
  takeover → an idle agent window: resume it with --takeover-pid <live_pid>
  resume   → resume that closed session
  pr-open  → read $STATE/<KEY>.json: CI failed, or a "migration version already
             on develop" reason → resume the session to fix / renumber it;
             awaiting review or a hard stop → report it, do nothing
  merged   → transition the ticket to Staging (if not already) and comment the PR links
  branch-only / new → candidate for a fresh build

GROOM (skip if told to) — a ticket is READY when all hold:
  • you can name the repo(s) it changes from the ticket or the code
  • it has acceptance criteria or a concrete done-condition you could test
  • no open decision is left to a human ("open question", "decide", "TBD", "?")
  • it is buildable in one session (not an epic-sized umbrella)
READY and not yet labeled → add label agent-ready.
NOT READY → one Jira comment listing exactly what is missing as numbered
questions (each with the default you'd assume), and add label needs-human. Once
per ticket — never re-comment if your previous comment has no reply.

DISPATCH — count in-flight first: tickets whose verdict is live-working or
live-waiting. Start at most $MAX_IN_FLIGHT minus that many builds this run,
taking agent-ready tickets in rank order. For each, decide the repos from the ticket + code, then run ONE of:
  new / branch-only:  $BIN/jira-agent.sh --auto --repos <r1,r2> https://$JIRA_SITE/browse/<KEY>
  resume:             $BIN/jira-agent.sh --auto --repos <r1,r2> --resume <sid> https://$JIRA_SITE/browse/<KEY>
  takeover:           $BIN/jira-agent.sh --auto --repos <r1,r2> --resume <sid> --takeover-pid <pid> https://$JIRA_SITE/browse/<KEY>
The first repo is the primary (where most of the change lands). After a fresh or
resumed dispatch, transition the ticket to In Progress if it is not already.
A launch prints "OK ..." — anything else is a failure: report it, don't retry.

REPORT — write $REPORT and print the same thing. Shape:
  # $AP_PROJECT autopilot — <date time>
  ## Dispatched      KEY · new|resume|takeover · repos · why this one
  ## Shipped         KEY · PR links · merged | open (reason)
  ## Left alone      KEY · verdict · reason
  ## Groomed         KEY · agent-ready | needs-human (the questions, one line)
  ## Needs Bi        anything only a human can unblock, one line each
Then stop.
EOF
)"

ALLOWED="Read,Grep,Glob,\
Bash(python3 $BIN/ticket-state.py:*),Bash($BIN/jira-agent.sh:*),\
Bash(cat:*),Bash(jq:*),Bash(ls:*),Bash(date:*),Bash(gh pr view:*),Bash(gh pr list:*),Bash(gh pr checks:*),\
Edit(/$STATE/**),\
mcp__claude_ai_Atlassian__getJiraIssue,mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql,\
mcp__claude_ai_Atlassian__getTransitionsForJiraIssue"
(( dry )) || ALLOWED+=",mcp__claude_ai_Atlassian__transitionJiraIssue,\
mcp__claude_ai_Atlassian__addCommentToJiraIssue,mcp__claude_ai_Atlassian__editJiraIssue"

cd "$STATE" || exit 1
claude -p "$PROMPT" --allowedTools "$ALLOWED" --output-format text 2>>"$LOG" | tee -a "$LOG"
print -r -- "[$(date '+%F %T')] run end; report $REPORT" >> "$LOG"
