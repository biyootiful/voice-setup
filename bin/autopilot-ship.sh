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
#   • no unresolved review thread (bot or human) is left on the PR
#   • develop does not require an approving review — unless AP_ADMIN_MERGE=1,
#     which merges with --admin (branch protection allows admins to bypass)
# Anything that fails a rule is left as an open PR and recorded as such; the next
# autopilot run sees it and either resumes the agent (CI red) or reports it.
#
# Review threads: an automated reviewer (AP_REVIEW_BOTS) often comments on the PR.
# Its unresolved threads go to $STATE/<KEY>-review.json, and the next autopilot run
# sends a build agent to probe them (jira-agent.sh --review). That agent's marker
# carries review_replies; this script posts each reply and resolves the thread,
# but only a bot's thread — a human reviewer's thread is never auto-resolved.
# Open PRs with no marker are re-checked too (the sweep at the end), so threads a
# bot posts after shipping still reach an agent.
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
: "${AP_REVIEW_BOTS:=claude}"
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

# Unresolved review threads on <repo>#<pr>, as JSON; .bot marks an AP_REVIEW_BOTS author.
review_threads() {
  gh api graphql -F n="$2" -f o="$GH_ORG" -f r="$1" -f query='
    query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){
      reviewThreads(first:100){nodes{id isResolved isOutdated
        comments(first:20){nodes{author{login} path line url body}}}}}}}' 2>/dev/null \
  | jq --arg bots "$AP_REVIEW_BOTS" '
      ($bots | split(" ")) as $b
      | [.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved | not)
         | .comments.nodes as $c
         | {id, outdated: .isOutdated, author: $c[0].author.login, path: $c[0].path,
            line: $c[0].line, url: $c[0].url,
            comments: [$c[] | {author: .author.login, body}],
            bot: (($b | index($c[0].author.login)) != null)}]'
}

# Post the agent's verdicts from marker $1 onto <repo>#<pr>, resolving bot threads
# judged fixed / false_positive. needs_human stays open for a person.
post_replies() {
  local m="$1" repo="$2" pr="$3" open_json tid verdict reply
  open_json="$(review_threads "$repo" "$pr")"
  jq -c --arg r "$repo" '.review_replies[]? | select(.repo == $r)' "$m" | while read -r e; do
    tid="$(jq -r .thread_id <<<"$e")"; verdict="$(jq -r .verdict <<<"$e")"; reply="$(jq -r .reply <<<"$e")"
    jq -e --arg t "$tid" 'any(.[]; .id == $t and .bot)' <<<"$open_json" >/dev/null \
      || { log "$KEY/$repo: thread $tid is not an open bot thread — left alone"; continue; }
    [[ -n "$reply" && "$reply" != null ]] || continue
    run gh api graphql -f t="$tid" -f b="$reply" -f query='
      mutation($t:ID!,$b:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$t,body:$b}){comment{id}}}' >/dev/null \
      || { log "$KEY/$repo: reply to $tid failed"; continue; }
    if [[ "$verdict" == (fixed|false_positive) ]]; then
      run gh api graphql -f t="$tid" -f query='
        mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' >/dev/null \
        && log "$KEY/$repo: thread $tid $verdict — replied and resolved" \
        || log "$KEY/$repo: resolve $tid failed"
    else
      log "$KEY/$repo: thread $tid $verdict — replied, left open"
    fi
  done
}

markers=()
if (( ${#keys} )); then
  for k in "${keys[@]}"; do [[ -r /tmp/$k-ready.json ]] && markers+=(/tmp/$k-ready.json); done
else
  markers=(/tmp/*-ready.json(N))
fi
(( ${#markers} )) || log "no READY markers"

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

  typeset -a results=() prs=() repos_merge=() review_entries=()
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
    # Verdicts from a --review agent go on the threads now that its fix is pushed.
    (( pr > 0 )) && post_replies "$m" "$repo" "$pr"

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

    # --- review threads (read after CI: the review bot runs as a check) -----
    threads='[]'; n_open=0; n_bot=0
    if (( pr > 0 )); then
      threads="$(review_threads "$repo" "$pr")"; [[ -n "$threads" ]] || threads='[]'
      n_open="$(jq length <<<"$threads")"; n_bot="$(jq '[.[] | select(.bot)] | length' <<<"$threads")"
      (( n_bot )) && review_entries+=("$(jq -c --arg r "$repo" --argjson pr "$pr" --arg b "$branch" \
                       '{repo:$r, pr:$pr, branch:$b, threads:[.[] | select(.bot)]}' <<<"$threads")")
    fi

    # --- may this one merge? ------------------------------------------------
    why=""
    # Parallel builds on one repo each pick "the next" Flyway version, so two can
    # claim the same V<n>. Refuse to merge a migration whose version develop
    # already has; the next autopilot run resumes the agent to renumber it.
    clash=""
    for f in ${(f)"$(git -C "$dir" diff --name-only --diff-filter=A "origin/$base...$branch" | grep -E '/V[0-9][0-9._]*__[^/]*$')"}; do
      v="${${f:t}%%__*}"
      git -C "$dir" ls-tree -r --name-only "origin/$base" | grep -qE "/${v}__" && clash+="${f:t} "
    done
    [[ -n "$clash" ]] && why="migration version already on $base: $clash— renumber"
    [[ -n "$hard" ]]                         && why="hard stop: $hard"
    [[ -z "$why" && "$base" != develop ]]    && why="base is $base (prod) — human merges"
    [[ -z "$why" && ${NEVER_MERGE[(Ie)$repo]} -gt 0 ]] && why="$repo is never auto-merged"
    [[ -z "$why" && "$ci" == (failed|timeout) ]] && why="CI $ci"
    if [[ -z "$why" ]] && (( n_open )); then
      why="unresolved review threads: $n_open ($n_bot from the review bot)"
      (( n_open > n_bot )) && why+=" — $(( n_open - n_bot )) from a human reviewer"
    fi
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

  if (( ${#review_entries} )); then
    print -r -- "[${(j:,:)review_entries}]" | jq --arg k "$KEY" '{key:$k, repos:.}' > "$STATE/$KEY-review.json"
    log "$KEY: bot review threads → $STATE/$KEY-review.json"
  else
    rm -f "$STATE/$KEY-review.json"
  fi

  outcome=open; (( merged )) && outcome=merged
  (( dry )) && outcome="dry-run"
  print -r -- "{\"key\":\"$KEY\",\"status\":\"$outcome\",\"at\":\"$(date -u +%FT%TZ)\",\"repos\":[${(j:,:)results}]}" \
    | jq . > "$STATE/$KEY.json"
  (( dry )) || mv "$m" "$STATE/shipped/$KEY-ready.$(date +%s).json"
  log "$KEY: $outcome (${prs[*]})"
done

# --- sweep: open PRs from earlier runs (no marker now) -----------------------
# A bot can post threads after the ship that opened the PR, and a human may have
# merged it by hand since. Refresh both, so the next autopilot run acts on facts.
for f in $STATE/$AP_PROJECT-<->.json(N); do
  KEY="${${f:t}%.json}"
  (( ${#keys} )) && (( ! ${keys[(Ie)$KEY]} )) && continue
  [[ -r /tmp/$KEY-ready.json ]] && continue
  [[ "$(jq -r .status "$f")" == open ]] || continue
  typeset -a review_entries=()
  states=()
  for e in ${(f)"$(jq -c '.repos[] | select(.pr != null and .pr > 0)' "$f")"}; do
    repo="$(jq -r .repo <<<"$e")"; pr="$(jq -r .pr <<<"$e")"
    st="$(gh pr view "$pr" -R "$GH_ORG/$repo" --json state -q .state 2>/dev/null)"
    states+=("$st")
    [[ "$st" == OPEN ]] || continue
    threads="$(review_threads "$repo" "$pr")"; [[ -n "$threads" ]] || threads='[]'
    br="$(gh pr view "$pr" -R "$GH_ORG/$repo" --json headRefName -q .headRefName 2>/dev/null)"
    jq -e 'any(.[]; .bot)' <<<"$threads" >/dev/null && review_entries+=("$(jq -c --arg r "$repo" \
        --argjson pr "$pr" --arg b "$br" '{repo:$r, pr:$pr, branch:$b, threads:[.[] | select(.bot)]}' <<<"$threads")")
  done
  if (( ${#states} )) && [[ -z "${states:#MERGED}" ]]; then
    if (( ! dry )); then
      jq '.status = "merged" | .note = "merged outside the autopilot"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    log "$KEY: sweep — every PR merged (by hand)"
  elif (( ${#states} )) && (( ! ${states[(Ie)OPEN]} )); then
    if (( ! dry )); then
      jq '.status = "closed" | .note = "PR closed without merging, outside the autopilot"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    rm -f "$STATE/$KEY-review.json"
    log "$KEY: sweep — PR closed unmerged (${states[*]})"
  elif (( ${#review_entries} )); then
    print -r -- "[${(j:,:)review_entries}]" | jq --arg k "$KEY" '{key:$k, repos:.}' > "$STATE/$KEY-review.json"
    log "$KEY: sweep — bot review threads open → $STATE/$KEY-review.json"
  else
    rm -f "$STATE/$KEY-review.json"
  fi
done
