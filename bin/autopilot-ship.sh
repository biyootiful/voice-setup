#!/bin/zsh
# Ship what an autopilot build agent finished: push, open the PR, wait for CI,
# merge to develop. Plain shell with fixed guards, on purpose — the build agent
# runs unattended and git push / gh pr merge sit behind permissions.ask, so the
# agent only leaves a READY marker (/tmp/<KEY>-ready.json) and this does the
# outward-facing part.
#
#   autopilot-ship.sh              # every marker in /tmp
#   autopilot-ship.sh ABC-123      # just that one
#   autopilot-ship.sh --dry-run    # say what would happen, touch nothing
#
# Merge rules (all must hold, for EVERY repo in the ticket — no half-merged features):
#   • the marker has no hard_stop and every repo's check_passed is true
#   • base is develop, and the repo is not in AP_NEVER_MERGE
#   • the PR's CI checks passed (or the repo has none)
#   • develop does not require an approving review — unless AP_ADMIN_MERGE=1,
#     which merges with --admin (branch protection allows admins to bypass)
# Anything that fails a rule is left as an open PR and recorded as such; the next
# autopilot run sees it and either resumes the agent (CI red) or reports it.
#
# Result per ticket: $STATE/<KEY>.json. Processed markers move to $STATE/shipped/.

emulate -L zsh
zmodload zsh/datetime
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
source "$HOME/.config/voice-setup/reply-repos.conf" 2>/dev/null
source "$HOME/.config/voice-setup/autopilot.conf" 2>/dev/null \
  || { print -u2 "missing ~/.config/voice-setup/autopilot.conf (see config/autopilot.conf.example)"; exit 1; }
: "${GIT_BASE:=$HOME/Documents/git}"
GH_ORG="$AP_GH_ORG"
: "${AP_ADMIN_MERGE:=0}"
: "${AP_CI_TIMEOUT_MIN:=45}"
STATE="$HOME/.local/state/autopilot"
LOG="$STATE/ship.log"
NEVER_MERGE=(${=AP_NEVER_MERGE})
mkdir -p "$STATE/shipped"

dry=0; keys=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    *) keys+=("${a:u}") ;;
  esac
done

log() { print -r -- "[$(date '+%F %T')] $*" | tee -a "$LOG" >&2; }
run() { if (( dry )); then log "DRY: $*"; else "$@"; fi }

markers=()
if (( ${#keys} )); then
  for k in "${keys[@]}"; do [[ -r /tmp/$k-ready.json ]] && markers+=(/tmp/$k-ready.json); done
else
  markers=(/tmp/*-ready.json(N))
fi
(( ${#markers} )) || { log "no READY markers"; exit 0; }

# Does <repo>'s develop require an approving review? (1 = yes)
needs_review() {
  local n
  n="$(gh api "repos/$GH_ORG/$1/branches/develop/protection" \
        -q '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null)"
  [[ "$n" == <-> ]] && (( n > 0 ))
}

for m in "${markers[@]}"; do
  KEY="$(jq -r .key "$m")"
  [[ "$KEY" == $AP_PROJECT-<-> ]] || { log "$m: key '$KEY' is not a $AP_PROJECT ticket — skipped"; continue; }
  hard="$(jq -r '.hard_stop // empty' "$m")"
  title="$(jq -r .pr_title "$m")"
  body="$(jq -r .pr_body "$m")"
  [[ -r "$body" ]] || { log "$KEY: PR body $body missing — skipped"; continue; }
  log "$KEY: shipping (${hard:+hard stop: $hard})"

  typeset -a results=() prs=() repos_merge=()
  all_ok=1
  n_repos="$(jq '.repos | length' "$m")"
  for (( i = 0; i < n_repos; i++ )); do
    repo="$(jq -r ".repos[$i].repo" "$m")"
    branch="$(jq -r ".repos[$i].branch" "$m")"
    base="$(jq -r ".repos[$i].base" "$m")"
    passed="$(jq -r ".repos[$i].check_passed" "$m")"
    dir="$GIT_BASE/$repo"
    reason=""

    # --- guards before anything leaves the machine ---------------------------
    [[ -d "$dir/.git" ]]                         || reason="no repo $dir"
    [[ -z "$reason" && "$branch" == *"$KEY"* ]]  || reason="${reason:-branch $branch does not name $KEY}"
    [[ -z "$reason" && "$base" == (develop|main) ]] || reason="${reason:-base $base not develop/main}"
    [[ -z "$reason" && "$passed" == true ]]      || reason="${reason:-agent check did not pass}"
    if [[ -z "$reason" ]]; then
      git -C "$dir" rev-parse -q --verify "refs/heads/$branch" >/dev/null || reason="no local branch $branch"
    fi
    if [[ -z "$reason" ]]; then
      git -C "$dir" fetch -q origin "$base"
      ahead="$(git -C "$dir" rev-list --count "origin/$base..$branch")"
      (( ahead > 0 )) || reason="$branch has no commits ahead of origin/$base"
    fi
    if [[ -n "$reason" ]]; then
      log "$KEY/$repo: NOT shipped — $reason"
      results+=("$(jq -nc --arg r "$repo" --arg why "$reason" '{repo:$r,status:"blocked",reason:$why}')")
      all_ok=0; continue
    fi

    # --- push + PR ----------------------------------------------------------
    run git -C "$dir" push -q -u origin "$branch" || { log "$KEY/$repo: push failed"; all_ok=0; continue; }
    pr="$(gh pr list -R "$GH_ORG/$repo" --head "$branch" --state open --json number -q '.[0].number' 2>/dev/null)"
    if [[ -z "$pr" ]]; then
      if (( dry )); then
        log "DRY: gh pr create $repo $base<-$branch \"$title\""; pr=0
      else
        url="$(gh pr create -R "$GH_ORG/$repo" --base "$base" --head "$branch" \
                 --title "$title" --body-file "$body" --reviewer "$AP_REVIEWERS" 2>>"$LOG")"
        pr="${url##*/}"
        # Reviewer requests sometimes fail while the PR itself is created.
        if [[ "$pr" == <-> ]] && ! gh pr view "$pr" -R "$GH_ORG/$repo" --json reviewRequests \
             -q '.reviewRequests[].login' | grep -q .; then
          for r in ${(s:,:)AP_REVIEWERS}; do
            gh api -X POST "repos/$GH_ORG/$repo/pulls/$pr/requested_reviewers" -f "reviewers[]=$r" >/dev/null 2>&1
          done
        fi
      fi
    fi
    [[ "$pr" == <-> ]] || { log "$KEY/$repo: could not open PR"; all_ok=0; continue; }
    log "$KEY/$repo: PR #$pr"
    prs+=("$repo#$pr")

    # --- CI -----------------------------------------------------------------
    ci=none
    if (( ! dry )) && (( pr > 0 )); then
      sleep 15   # let checks register
      # macOS has no `timeout`, so poll the buckets (pass/fail/pending/skipping/cancel).
      deadline=$(( EPOCHSECONDS + AP_CI_TIMEOUT_MIN * 60 ))
      while :; do
        buckets="$(gh pr checks "$pr" -R "$GH_ORG/$repo" --json bucket -q '.[].bucket' 2>/dev/null)"
        [[ -z "$buckets" ]] && { ci=none; break; }
        if [[ "$buckets" == *fail* || "$buckets" == *cancel* ]]; then ci=failed; break; fi
        [[ "$buckets" != *pending* ]] && { ci=passed; break; }
        (( EPOCHSECONDS > deadline )) && { ci=timeout; break; }
        sleep 30
      done
    fi
    log "$KEY/$repo: CI $ci"

    # --- may this one merge? ------------------------------------------------
    why=""
    [[ -n "$hard" ]]                         && why="hard stop: $hard"
    [[ -z "$why" && "$base" != develop ]]    && why="base is $base (prod) — human merges"
    [[ -z "$why" && ${NEVER_MERGE[(Ie)$repo]} -gt 0 ]] && why="$repo is never auto-merged"
    [[ -z "$why" && "$ci" == (failed|timeout) ]] && why="CI $ci"
    admin=()
    if [[ -z "$why" ]] && needs_review "$repo"; then
      if (( AP_ADMIN_MERGE )); then admin=(--admin); else why="develop requires an approving review"; fi
    fi
    if [[ -n "$why" ]]; then
      all_ok=0
      results+=("$(jq -nc --arg r "$repo" --argjson pr "$pr" --arg ci "$ci" --arg why "$why" '{repo:$r,pr:$pr,ci:$ci,status:"open",reason:$why}')")
    else
      repos_merge+=("$repo $pr ${admin[*]}")
      results+=("$(jq -nc --arg r "$repo" --argjson pr "$pr" --arg ci "$ci" '{repo:$r,pr:$pr,ci:$ci,status:"mergeable"}')")
    fi
  done

  # --- merge only if every repo in the ticket can --------------------------
  merged=0
  if (( all_ok )) && (( ${#repos_merge} )); then
    for e in "${repos_merge[@]}"; do
      parts=(${=e})
      run gh pr merge "${parts[2]}" -R "$GH_ORG/${parts[1]}" --merge --delete-branch ${parts[3,-1]} \
        && log "$KEY/${parts[1]}: merged #${parts[2]} into develop" \
        || { log "$KEY/${parts[1]}: merge FAILED"; all_ok=0; }
    done
    (( all_ok )) && merged=1
  fi
  # Merged: the per-ticket worktrees jira-agent.sh --auto made are done with.
  if (( merged )) && (( ! dry )); then
    for e in "${repos_merge[@]}"; do
      wt="$GIT_BASE/.autopilot/$KEY/${${=e}[1]}"
      [[ -d "$wt" ]] && git -C "$GIT_BASE/${${=e}[1]}" worktree remove "$wt" 2>>"$LOG" \
        && log "$KEY: removed worktree $wt"
    done
  fi

  outcome=open; (( merged )) && outcome=merged
  (( dry )) && outcome="dry-run"
  print -r -- "{\"key\":\"$KEY\",\"status\":\"$outcome\",\"at\":\"$(date -u +%FT%TZ)\",\"repos\":[${(j:,:)results}]}" \
    | jq . > "$STATE/$KEY.json"
  (( dry )) || mv "$m" "$STATE/shipped/$KEY-ready.$(date +%s).json"
  log "$KEY: $outcome (${prs[*]})"
done
