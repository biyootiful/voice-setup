#!/bin/zsh
# Find a Claude Code session and reopen it in the right directory.
#
#   claude-resume.sh                  # 20 most recent sessions, everywhere
#   claude-resume.sh ABC-12          # just the ones mentioning ABC-12
#   claude-resume.sh ABC-12 --go     # …and reopen it (asks if several match)
#   claude-resume.sh checkout --deep     # search whole transcripts, not just the opener
#   claude-resume.sh --go --group frontend   # force which group's --add-dir set to restore
#
# Why this exists: `claude --resume` only lists sessions started in the directory
# you run it from, and nothing on screen tells you which directory that was. The
# agents cd into the group's PRIMARY repo, so that is the one to go back to — this
# reads it out of the transcripts (via claude-sessions.py) and hands you the exact
# command, including the --add-dir repos, which a resume does NOT restore on its own.

emulate -L zsh
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
zmodload zsh/datetime

source "$HOME/.config/voice-setup/reply-repos.conf" 2>/dev/null
source "$HOME/.config/voice-setup/repo-groups.conf" 2>/dev/null
: "${GIT_BASE:=$HOME/Documents/git}"

SCAN="$HOME/.local/bin/claude-sessions.py"
[[ -r "$SCAN" ]] || SCAN="$(cd "$(dirname "$0")" && pwd)/claude-sessions.py"
[[ -r "$SCAN" ]] || { print -u2 "claude-sessions.py not found next to $0 or in ~/.local/bin"; exit 1; }

term=""; go=0; force_group=""; scan_args=()
while (( $# )); do
  case "$1" in
    --go|-g)     go=1; shift ;;
    --group)     shift; force_group="$1"; shift ;;
    --deep)      scan_args+=(--deep); shift ;;
    --all)       scan_args+=(--all); shift ;;
    -n|--limit)  shift; scan_args+=(--limit "$1"); shift ;;
    -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
    *)           [[ -z "$term" ]] && term="$1"; shift ;;
  esac
done

rows=(${(f)"$(python3 "$SCAN" ${term:+"$term"} "${scan_args[@]}")"})
(( ${#rows} )) || { print -u2 "no sessions match${term:+ '$term'}${scan_args[(r)--deep]:+ (deep)}"; exit 1; }

# --- the --add-dir set a resumed session loses -------------------------------
# Best source is the launch log, which records the real command (and so covers
# hand-picked custom groups). Otherwise infer it: the groups whose primary repo is
# this directory. If several groups share that primary the answer is genuinely
# ambiguous, so say so rather than guessing a wider set of directories than asked.
add_dirs_for() {   # $1 = cwd -> prints one directory per line, may print nothing
  local cwd="$1" base="${1:t}" l
  local -a lines=() keep=()
  lines=(${(f)"$(grep -h "RESUME .*cd $cwd &&" /tmp/jira-agent.log /tmp/jira-triage.log 2>/dev/null)"})
  for l in "${lines[@]}"; do
    [[ -z "$term" || "${(L)l}" == *"${(L)term}"* ]] && keep+=("$l")
  done
  l="${keep[-1]}"
  if [[ -n "$l" && "$l" == *--add-dir* ]]; then
    print -l -- ${(s: --add-dir :)${l#*--add-dir }}
    return
  fi
  local -a candidates=() g r
  for g in ${(s: :)GROUP_ORDER}; do
    local -a repos=()
    for r in ${(s: :)REPO_GROUPS[$g]}; do [[ -e "$GIT_BASE/$r/.git" ]] && repos+=("$r"); done
    (( ${#repos} )) && [[ "${repos[1]}" == "$base" ]] && candidates+=("$g")
  done
  [[ -n "$force_group" ]] && candidates=("$force_group")
  if (( ${#candidates} > 1 )); then
    print -u2 "  note: $base is the primary of ${#candidates} groups (${candidates[*]}) — pass --group <name> to pick one; resuming with no extra repos"
    return
  fi
  (( ${#candidates} )) || return
  for r in ${(s: :)REPO_GROUPS[${candidates[1]}]}; do
    [[ "$r" == "$base" ]] && continue
    [[ -e "$GIT_BASE/$r/.git" ]] && print -r -- "$GIT_BASE/$r"
  done
}

# --- table -------------------------------------------------------------------
print -r -- ""
printf "  %-3s %-13s %-30s %-4s %s\n" "#" "WHEN" "RESUME FROM" "-c" "OPENED WITH"
printf "  %-3s %-13s %-30s %-4s %s\n" "---" "-------------" "------------------------------" "----" "------------------------------"
typeset -a cwds=() sids=()
typeset i=0 r ts rest sid cwd newest snippet mark
for r in "${rows[@]}"; do
  (( i++ ))
  ts="${r%%$'\t'*}"; rest="${r#*$'\t'}"
  sid="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  cwd="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  newest="${rest%%$'\t'*}"; snippet="${rest#*$'\t'}"
  cwds+=("$cwd"); sids+=("$sid")
  mark='-'; (( newest )) && mark='yes'
  printf "  %-3d %-13s %-30s %-4s %s\n" "$i" "$(strftime '%b %d %H:%M' $ts)" "${cwd:t}" \
    "$mark" "${snippet[1,58]}"
done
print -r -- ""

pick=1
if (( go )); then
  if (( ${#rows} > 1 )); then
    print -n "open which? [1-${#rows}, enter to cancel] "
    read -r pick
    [[ -z "$pick" ]] && { print "cancelled"; exit 0; }
    [[ "$pick" == <-> ]] && (( pick >= 1 && pick <= ${#rows} )) || { print -u2 "not a row number"; exit 1; }
  fi
else
  print -r -- "  -c column: 'yes' means that session is the newest in its directory, so"
  print -r -- "             'claude -c' there lands on it; '-' means you need --resume."
  print -r -- ""
fi

cwd="${cwds[$pick]}"; sid="${sids[$pick]}"
typeset -a add_args=()
for d in ${(f)"$(add_dirs_for "$cwd")"}; do
  [[ -n "$d" ]] && add_args+=(--add-dir "$d")
done
cmd="cd $cwd && claude --resume $sid${add_args:+ ${add_args[*]}}"

if (( go )); then
  print -r -- "→ $cmd"
  cd "$cwd" || exit 1
  exec claude --resume "$sid" "${add_args[@]}"
fi

print -r -- "  $cmd"
(( ${#rows} > 1 )) && print -r -- "  (row 1 shown; re-run with --go to pick and open one)"
