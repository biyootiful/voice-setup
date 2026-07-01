#!/bin/zsh
# Spin up a Claude Code session to investigate a Jira ticket (read-only plan).
# Takes the ticket URL as $1 (or stdin), pops a product-group picker, and opens
# a new kitty window running `claude` scoped to that group's repos, seeded to
# read the ticket (via the Atlassian MCP) and produce an implementation plan.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/jira-agent.log

source "$HOME/.config/voice-setup/reply-repos.conf"  2>/dev/null
source "$HOME/.config/voice-setup/repo-groups.conf"  2>/dev/null
: "${GIT_BASE:=$HOME/Documents/git}"

url="${1:-$(cat)}"
url="${url//[[:space:]]/}"
KEY="$(printf '%s' "$url" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)"
[[ -z "$KEY" ]] && { echo "[$(date)] no Jira key in: $url" >> "$LOG"; echo "NO_JIRA_KEY"; exit 1; }
echo "[$(date)] ticket $KEY ($url)" >> "$LOG"

[[ -z "${GROUP_ORDER:-}" ]] && { echo "[$(date)] no GROUP_ORDER (edit repo-groups.conf)" >> "$LOG"; echo "NO_GROUPS"; exit 1; }

# product-group picker
items=""
for g in ${(s: :)GROUP_ORDER}; do items+="\"$g\","; done
items="${items%,}"
group="$(osascript -e "choose from list {$items} with prompt \"Jira $KEY — which product group is this ticket about?\"" 2>>"$LOG")"
[[ -z "$group" || "$group" == "false" ]] && { echo "[$(date)] picker cancelled" >> "$LOG"; echo "CANCELLED"; exit 0; }

# resolve to existing repo dirs
repos=(${(s: :)REPO_GROUPS[$group]})
existing=()
for r in "${repos[@]}"; do [[ -d "$GIT_BASE/$r" ]] && existing+=("$r"); done
[[ ${#existing[@]} -eq 0 ]] && { echo "[$(date)] no existing repos for $group" >> "$LOG"; echo "NO_REPOS"; exit 1; }

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
# All agent sessions run inside ONE kitty instance (--single-instance), so each is
# a window of the same process. That makes cmd-` cycle between them (like browser
# windows) and Mission Control group them. -T pins the window title to the ticket
# so you can tell sessions apart — claude's TUI would otherwise overwrite it.
# NOTE: prompt must come BEFORE --add-dir (it's variadic and would eat the prompt).
"$KITTY" --single-instance --directory "$GIT_BASE/$primary" --title "$TITLE" \
  "$CLAUDE" "$PROMPT" "${add_args[@]}" >>"$LOG" 2>&1 &
echo "OK $group"
