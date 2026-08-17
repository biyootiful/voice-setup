#!/bin/zsh
# Shared repo picker for the Jira agents (Ctrl+Cmd+J plan, Ctrl+Cmd+K triage).
# Not executable on its own — source it.
#
#   pick_repo_group "prompt shown in the picker"
#     returns 0 and sets:
#       PICK_LABEL   short name, used for window titles + report filenames
#       PICK_REPOS   array of dir names under GIT_BASE, PRIMARY FIRST,
#                    filtered to the ones actually cloned
#       PICK_CUSTOM  1 if hand-picked, 0 if it came from repo-groups.conf
#     returns 1 if the user cancelled, 2 if nothing usable was left
#
# The list shows every group in GROUP_ORDER plus a "Custom…" entry, which pops
# a multi-select of every git repo under GIT_BASE and then asks which of them is
# the primary.
#
# PICK_REPOS[1] is the primary and it matters beyond being the cwd: Claude keys
# sessions by cwd alone, so the primary is the ONLY directory `claude --resume`
# can find that session from later. The other repos go in as --add-dir, and
# those are NOT persisted — a resumed session sees the primary only until you
# re-pass them (see README).
#
# Expects GIT_BASE / GROUP_ORDER / REPO_GROUPS in scope: source reply-repos.conf
# and repo-groups.conf first. Honours $LOG if the caller set one.

PICK_CUSTOM_LABEL="Custom… (pick repos)"

_pick_log() { [[ -n "${LOG:-}" ]] && print -r -- "[$(date)] picker: $*" >> "$LOG"; }

# Quote a shell string as an AppleScript string literal.
_pick_as_str() {
  local s="${1//\\/\\\\}"
  print -rn -- "\"${s//\"/\\\"}\""
}

# Join names into an AppleScript list literal: {"a", "b"}
_pick_as_list() {
  local -a out; local x
  for x in "$@"; do out+=("$(_pick_as_str "$x")"); done
  print -rn -- "{${(j:, :)out}}"
}

# Every cloned repo under GIT_BASE, case-insensitively sorted. `.git` is tested
# with -e, not -d, so linked worktrees (where it is a file) still count.
_pick_all_repos() {
  local -a hits; local h
  hits=("$GIT_BASE"/*/.git(N))
  reply=()
  for h in "${hits[@]}"; do reply+=("${${h:h}:t}"); done
  reply=(${(oi)reply})
}

# Hand-assembled group: which repos, then which one is primary.
_pick_custom() {
  local -a all; _pick_all_repos; all=("${reply[@]}")
  (( ${#all} )) || { _pick_log "no git repos under $GIT_BASE"; return 2; }

  local sel
  sel="$(osascript -e "choose from list $(_pick_as_list "${all[@]}") with prompt \"Custom group — every repo the agent may read (cmd-click to pick several):\" with multiple selections allowed" 2>>"${LOG:-/dev/null}")"
  [[ -z "$sel" || "$sel" == "false" ]] && { _pick_log "cancelled at repo list"; return 1; }
  local -a picked; picked=("${(@s:, :)sel}")

  local primary="${picked[1]}"
  if (( ${#picked} > 1 )); then
    local p
    p="$(osascript -e "choose from list $(_pick_as_list "${picked[@]}") with prompt \"Primary repo — the session opens here, and it is the only place 'claude --resume' can find it again:\" default items $(_pick_as_list "$primary")" 2>>"${LOG:-/dev/null}")"
    [[ -z "$p" || "$p" == "false" ]] && { _pick_log "cancelled at primary"; return 1; }
    primary="$p"
  fi

  PICK_REPOS=("$primary" ${picked:#$primary})
  # Label goes into window titles and report filenames, so keep it short and
  # path-safe: "my-api+2" = primary plus two more.
  PICK_LABEL="$primary"
  (( ${#PICK_REPOS} > 1 )) && PICK_LABEL="$primary+$(( ${#PICK_REPOS} - 1 ))"
  return 0
}

pick_repo_group() {
  emulate -L zsh
  local prompt="${1:-Which product group?}"
  PICK_LABEL=""; PICK_REPOS=(); PICK_CUSTOM=0

  local -a groups=(${(s: :)GROUP_ORDER})
  local sel
  sel="$(osascript -e "choose from list $(_pick_as_list "${groups[@]}" "$PICK_CUSTOM_LABEL") with prompt \"$prompt\"" 2>>"${LOG:-/dev/null}")"
  [[ -z "$sel" || "$sel" == "false" ]] && { _pick_log "cancelled at group list"; return 1; }

  if [[ "$sel" == "$PICK_CUSTOM_LABEL" ]]; then
    _pick_custom || return $?
    PICK_CUSTOM=1
  else
    resolve_repo_group "$sel" || return $?
  fi
  _pick_log "label=$PICK_LABEL custom=$PICK_CUSTOM primary=${PICK_REPOS[1]} repos=${PICK_REPOS[*]}"
  return 0
}

# Non-interactive path: a group name straight from argv.
resolve_repo_group() {
  emulate -L zsh
  local g="$1" r
  PICK_LABEL=""; PICK_REPOS=(); PICK_CUSTOM=0
  [[ -n "${REPO_GROUPS[$g]:-}" ]] || { _pick_log "unknown group '$g'"; return 3; }
  for r in ${(s: :)REPO_GROUPS[$g]}; do
    [[ -e "$GIT_BASE/$r/.git" ]] && PICK_REPOS+=("$r")
  done
  (( ${#PICK_REPOS} )) || { _pick_log "no cloned repos for '$g'"; return 2; }
  PICK_LABEL="$g"
  return 0
}

# Non-interactive path: an explicit repo list, primary first.
resolve_repo_list() {
  emulate -L zsh
  local r
  PICK_LABEL=""; PICK_REPOS=(); PICK_CUSTOM=1
  for r in "$@"; do
    if [[ -e "$GIT_BASE/$r/.git" ]]; then PICK_REPOS+=("$r")
    else _pick_log "skipping '$r' — not cloned at $GIT_BASE/$r"; fi
  done
  (( ${#PICK_REPOS} )) || return 2
  PICK_LABEL="${PICK_REPOS[1]}"
  (( ${#PICK_REPOS} > 1 )) && PICK_LABEL="${PICK_REPOS[1]}+$(( ${#PICK_REPOS} - 1 ))"
  return 0
}

# --- Jira project keys for a custom group -----------------------------------
# A hand-picked group has no GROUP_JIRA_PROJECTS entry, and triage needs keys for
# two things: the JQL query, and anchoring key-matching in git so branch names
# like backup-develop-2024-03-20 aren't read as a ticket. Guess them from the
# repos' own remote branch names (the same one-liner documented in
# repo-groups.conf.example), then let the dialog correct the guess.

# The first word of a branch name is only *sometimes* a project key, so this is a
# guess and is treated as one. Three filters keep it usable: the STOP list below
# (jira-git-facts.sh's, plus the English words that show up in branch names like
# fix-for-123), a 3-letter minimum, and a cap of the 8 most frequent — without the
# cap, a legacy repo with 2000 branches offers 29 "projects", most of them prose.
_PICK_STOP="DEVELOP MASTER MAIN BACKUP RELEASE HOTFIX BUGFIX FEATURE CHORE FIX WIP TODO TEST REVERT PATCH TASK MR V UTF ES NO SHA MD PR
AND FOR THE NEW OLD ADD ADDING UPDATE UPDATES CHANGE CHANGES REMOVE TEMP TMP MISC PAGE PART ITEM ITEMS ISSUE BUG DEV PROD STAGE QA"

derive_jira_projects() {
  emulate -L zsh
  local -a words; local r k
  for r in "$@"; do
    words+=(${(f)"$(git -C "$GIT_BASE/$r" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null \
      | grep -oE '[A-Za-z]{3,}-[0-9]+' | sed 's/-[0-9]*$//' | tr 'a-z' 'A-Z')"})
  done
  local -A n
  for k in "${words[@]}"; do
    [[ -z "$k" || " ${_PICK_STOP//$'\n'/ } " == *" $k "* ]] && continue
    (( n[$k]++ ))
  done
  local -a top
  top=(${(f)"$(for k in ${(k)n}; do print -r -- "${n[$k]} $k"; done | sort -rn | awk 'NR <= 8 && $1 >= 2 { print $2 }')"})
  print -r -- "${top[*]}"
}

# Sets PICK_PROJECTS. Returns 1 if cancelled, 2 if left empty.
pick_jira_projects() {
  emulate -L zsh
  local guess ans
  guess="$(derive_jira_projects "$@")"
  local msg="Jira project keys for this custom group, space separated. Guessed from the repos' branch names — fix it if the guess is wrong."
  ans="$(osascript \
    -e "set r to display dialog $(_pick_as_str "$msg") default answer $(_pick_as_str "$guess") with title \"Jira triage\"" \
    -e 'text returned of r' 2>>"${LOG:-/dev/null}")" || { _pick_log "cancelled at project keys"; return 1; }
  # Accept "ABC, def" as readily as "ABC DEF".
  local cleaned="${ans//,/ }"
  local -a ks=(${(U)${=cleaned}})
  ks=(${(u)ks})
  PICK_PROJECTS="${ks[*]}"
  (( ${#ks} )) || { _pick_log "no project keys given"; return 2; }
  _pick_log "projects=$PICK_PROJECTS (guess was: ${guess:-none})"
  return 0
}
