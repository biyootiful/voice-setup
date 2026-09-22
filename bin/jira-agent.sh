#!/bin/zsh
# Spin up a Claude Code session to investigate a Jira ticket (read-only plan).
# Takes the ticket URL as $1 (or stdin), pops a repo picker (the product groups
# from repo-groups.conf, plus "Custom…" to assemble a one-off set by hand), and
# opens a new kitty window running `claude` scoped to those repos, seeded to
# read the ticket (via the Atlassian MCP) and produce an implementation plan.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/jira-agent.log

source "$HOME/.config/voice-setup/reply-repos.conf"  2>/dev/null
source "$HOME/.config/voice-setup/repo-groups.conf"  2>/dev/null
: "${GIT_BASE:=$HOME/Documents/git}"

PICKER="$HOME/.local/bin/pick-repo-group.sh"
[[ -r "$PICKER" ]] || PICKER="$(cd "$(dirname "$0")" && pwd)/pick-repo-group.sh"
source "$PICKER" || { echo "[$(date)] cannot source $PICKER" >> "$LOG"; echo "NO_PICKER"; exit 1; }

url="${1:-$(cat)}"
url="${url//[[:space:]]/}"
KEY="$(printf '%s' "$url" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)"
[[ -z "$KEY" ]] && { echo "[$(date)] no Jira key in: $url" >> "$LOG"; echo "NO_JIRA_KEY"; exit 1; }
echo "[$(date)] ticket $KEY ($url)" >> "$LOG"

[[ -z "${GROUP_ORDER:-}" ]] && { echo "[$(date)] no GROUP_ORDER (edit repo-groups.conf)" >> "$LOG"; echo "NO_GROUPS"; exit 1; }

# Which repos? Groups from repo-groups.conf, or "Custom…" to pick by hand.
pick_repo_group "Jira $KEY — which repos is this ticket about?"
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

PROMPT="Read Jira ticket $KEY ($url) using the Atlassian Jira tools (look it up by key $KEY and read its description and comments). Summarize what it's asking for in 2-3 lines. Then investigate the repositories in this product group ($REPO_LIST) and produce: (1) a concise implementation plan, (2) the specific files/areas to change in each repo, (3) risks, edge cases, and open questions. This is READ-ONLY planning — do NOT modify any code, branches, or the ticket. After the plan, wait for my direction."

CLAUDE="$(command -v claude)"
KITTY="/Applications/kitty.app/Contents/MacOS/kitty"; [[ -x "$KITTY" ]] || KITTY="$(command -v kitty)"
[[ -z "$CLAUDE" || -z "$KITTY" ]] && { echo "[$(date)] missing claude or kitty" >> "$LOG"; echo "MISSING_TOOL"; exit 1; }

TITLE="$KEY · $group"
echo "[$(date)] launching: group=$group primary=$primary repos=$REPO_LIST title=$TITLE" >> "$LOG"
# Sessions are keyed by cwd, and --add-dir is not persisted across a resume, so
# log the exact command that brings this one back after a crash / accidental
# close. Recover it with:  grep 'RESUME .*<KEY>' /tmp/jira-agent.log | tail -1
echo "[$(date)] RESUME $KEY: cd $GIT_BASE/$primary && claude --resume $KEY ${add_args[*]}" >> "$LOG"
# All agent sessions run inside ONE kitty instance (--single-instance), so each is
# a window of the same process. That makes cmd-` cycle between them (like browser
# windows) and Mission Control group them. -T pins the window title to the ticket
# so you can tell sessions apart — claude's TUI would otherwise overwrite it.
# NOTE: prompt must come BEFORE --add-dir (it's variadic and would eat the prompt).
# Tools this agent may use without prompting — read-only planning: no Edit/Write, Jira read tools only.
# Additive and session-scoped; permissions.ask rules (git push, rm, Gmail
# send) still take precedence, so the dangerous gates stay in place.
ALLOWED_TOOLS="Read,Grep,Glob,TodoWrite,WebFetch,WebSearch,Task,Bash(cd:*),Bash(git:*),Bash(ls:*),Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(grep:*),Bash(rg:*),Bash(find:*),Bash(fd:*),Bash(sed:*),Bash(awk:*),Bash(wc:*),Bash(jq:*),Bash(sort:*),Bash(uniq:*),Bash(cut:*),Bash(date:*),Bash(echo:*),Bash(mkdir:*),Bash(python3:*),Bash(gh:*),mcp__claude_ai_Atlassian__getJiraIssue,mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql,mcp__claude_ai_Atlassian__search,mcp__claude_ai_Atlassian__fetch,mcp__claude_ai_Atlassian__getJiraIssueRemoteIssueLinks,mcp__claude_ai_Atlassian__getConfluencePage"

"$KITTY" --single-instance --directory "$GIT_BASE/$primary" --title "$TITLE" \
  "$CLAUDE" "$PROMPT" "${add_args[@]}" \
  --allowedTools "$ALLOWED_TOOLS" >>"$LOG" 2>&1 &
echo "OK $group"
