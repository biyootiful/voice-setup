#!/bin/zsh
# Git ground truth for Jira triage: for each Jira key, where has its code landed?
#
#   jira-git-facts.sh <group>                    # keys discovered from branch names
#   jira-git-facts.sh <group> --keys K1 K2 ...   # check these specific keys
#   jira-git-facts.sh <group> ... --no-fetch     # skip `git fetch` (fast, may be stale)
#   jira-git-facts.sh <group> ... --days N       # branch-discovery window (default 180)
#   jira-git-facts.sh <group> ... --titles f.tsv # also match ticket TITLES (key<TAB>title)
#   jira-git-facts.sh <label> --repos "a b c" [--projects "X Y"]
#                                                # ad-hoc set, no config entry needed
#                                                # (<label> is then only a heading)
#
# Deploy model, read off the repos' own GitHub Actions workflows:
#   develop            -> dev + stage   (build_deploy_*_dev.yml, *_stage.yml)
#   main (or master)   -> prod          (build_deploy_*_prod.yml)
# So "is it deployed" is a pure git question: which branch contains the commits.
# No AWS/API access needed, and nothing here writes — fetch + read only.
#
# Per-repo verdict for a key:
#   PROD      a branch for it is fully contained in the prod branch, or the prod
#             branch's commit messages mention the key
#   STAGE     same, but only true of develop
#   UNMERGED  a branch exists and is ahead of both
#   NO_TRACE  no branch name and no commit message mentions it
#
# Why branch names and not just commit messages: commit subjects are inconsistent
# (`Release MR`, `feat: added the new field`), and squash/release merges lose the key.
# The branch name is the reliable join, so ancestry is the primary signal and the
# commit-message grep is only a supplement.
#
# Keys are not the whole story though: in some repos ~59% of branches carry NO key
# (`dark-mode`, `search-v2`, `invoice-flow`), and that work is
# invisible to key matching. Pass --titles to also match ticket titles against branch
# names — reported in a SEPARATE, lower-confidence section, never as a deploy verdict.
# See bin/jira-title-match.py for the rules and why each guard exists.
#
# Performance note: everything is precomputed per repo into set indexes (merged
# branch lists, key sets) with a fixed number of git calls, so cost does not grow
# with keys x repos. That matters — `embed` alone has 2100+ remote branches, and a
# grep-per-key version of this script took over five minutes on that group.

emulate -L zsh
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export GIT_TERMINAL_PROMPT=0   # fail fast instead of hanging on a credential prompt

source "$HOME/.config/voice-setup/reply-repos.conf" 2>/dev/null
source "$HOME/.config/voice-setup/repo-groups.conf" 2>/dev/null
: "${GIT_BASE:=$HOME/Documents/git}"
: "${JIRA_TRIAGE_BRANCH_DAYS:=180}"

# ---- args ------------------------------------------------------------------
group=""; keys=(); do_fetch=1; days="$JIRA_TRIAGE_BRANCH_DAYS"; titles=""
cli_repos=""; cli_projects=""
while (( $# )); do
  case "$1" in
    --keys)     shift; while (( $# )) && [[ "$1" != --* ]]; do keys+=("${(U)1}"); shift; done ;;
    --no-fetch) do_fetch=0; shift ;;
    --days)     shift; days="$1"; shift ;;
    --titles)   shift; titles="$1"; shift ;;
    --repos)    shift; cli_repos="$1"; shift ;;
    --projects) shift; cli_projects="$1"; shift ;;
    -h|--help)  sed -n '2,39p' "$0"; exit 0 ;;
    *)          [[ -z "$group" ]] && group="$1"; shift ;;
  esac
done
[[ -z "$group" ]] && { echo "usage: $0 <group> [--keys K1 K2 ...] [--no-fetch] [--days N] [--titles f.tsv] [--repos \"a b c\"] [--projects \"X Y\"]" >&2; exit 2; }
[[ -n "$titles" && ! -r "$titles" ]] && { echo "--titles file not readable: $titles" >&2; exit 2; }

# --repos wins over the config lookup, so a hand-picked group (which has no
# repo-groups.conf entry) works — <group> is then just a label for the heading.
if [[ -n "$cli_repos" ]]; then
  repos=(${(s: :)cli_repos})
else
  repos=(${(s: :)REPO_GROUPS[$group]})
fi
(( ${#repos} )) || { echo "unknown group '$group' (check ~/.config/voice-setup/repo-groups.conf, or pass --repos)" >&2; exit 2; }

warnings=()
existing=()
for r in "${repos[@]}"; do
  if [[ -d "$GIT_BASE/$r/.git" ]]; then existing+=("$r")
  else warnings+=("repo '$r' is in group '$group' but is NOT cloned at $GIT_BASE/$r — its share of any ticket is invisible here")
  fi
done
(( ${#existing} )) || { echo "no cloned repos for group '$group'" >&2; exit 2; }

projects="${cli_projects:-${GROUP_JIRA_PROJECTS[$group]:-}}"

# ---- fetch (parallel; staleness silently corrupts every verdict) ------------
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
if (( do_fetch )); then
  for r in "${existing[@]}"; do
    ( git -C "$GIT_BASE/$r" fetch --prune --quiet origin >/dev/null 2>&1 \
        && print ok > "$tmpd/f.$r" || print fail > "$tmpd/f.$r" ) &
  done
  wait
  for r in "${existing[@]}"; do
    [[ "$(<"$tmpd/f.$r" 2>/dev/null)" == ok ]] || \
      warnings+=("git fetch FAILED for '$r' — its verdicts come from a possibly stale clone (last fetch $(stat -f '%Sm' -t '%Y-%m-%d' "$GIT_BASE/$r/.git/FETCH_HEAD" 2>/dev/null || echo never))")
  done
else
  warnings+=("--no-fetch: verdicts come from whatever each clone last fetched, which may be weeks old")
fi

# ---- key regex -------------------------------------------------------------
# Configured project keys anchor the match, which removes everything a generic
# regex picks up (backup-develop-2024-03-20 -> "DEVELOP-2024", bugfix/x -> "BUGFIX-1").
if [[ -n "$projects" ]]; then
  KEY_RE="(${projects// /|})-[0-9]+"
else
  KEY_RE="[A-Z][A-Z0-9]+-[0-9]+"
  warnings+=("no GROUP_JIRA_PROJECTS entry for '$group' — using a generic key regex, so some non-ticket strings may appear below")
fi
STOP="DEVELOP MASTER MAIN BACKUP RELEASE HOTFIX BUGFIX FEATURE CHORE FIX WIP TODO TEST REVERT PATCH TASK MR V UTF ES NO SHA MD PR"

cutoff="$(date -v-${days}d +%Y-%m-%d 2>/dev/null)" || cutoff="0000-00-00"

# ---- per-repo indexes (fixed number of git calls each) ---------------------
typeset -A PROD STAGE BR_OF IN_PROD IN_STAGE MERGED_PROD MERGED_STAGE OPENPR
discovered=()
for r in "${existing[@]}"; do
  d="$GIT_BASE/$r"
  p=""
  for b in main master; do
    git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$b" && { p="$b"; break }
  done
  [[ -z "$p" ]] && p="$(git -C "$d" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  PROD[$r]="$p"
  s=""
  for b in develop staging; do
    git -C "$d" show-ref --verify --quiet "refs/remotes/origin/$b" && { s="$b"; break }
  done
  STAGE[$r]="$s"
  [[ -z "$p" ]] && warnings+=("'$r' has no main/master/origin-HEAD — cannot tell what is in prod")
  [[ -z "$s" ]] && warnings+=("'$r' has no develop/staging branch — no stage signal there, only prod vs unmerged")

  # branches (name + last-commit date), excluding origin/HEAD
  git -C "$d" for-each-ref --format='%(refname:short)|%(committerdate:short)' refs/remotes/origin \
    | grep -v '^origin/HEAD' > "$tmpd/br.$r"

  # branches fully contained in prod / stage — ONE git call each, replaces a
  # per-branch `rev-list` (this is what made the legacy groups usable)
  if [[ -n "$p" ]]; then
    git -C "$d" for-each-ref --format='%(refname:short)' --merged "origin/$p" refs/remotes/origin 2>/dev/null > "$tmpd/mgp.$r"
    while read -r b; do MERGED_PROD[$r::$b]=1; done < "$tmpd/mgp.$r"
  fi
  if [[ -n "$s" ]]; then
    git -C "$d" for-each-ref --format='%(refname:short)' --merged "origin/$s" refs/remotes/origin 2>/dev/null > "$tmpd/mgs.$r"
    while read -r b; do MERGED_STAGE[$r::$b]=1; done < "$tmpd/mgs.$r"
  fi

  # branch -> key(s), one awk pass over the branch list. Uppercase a copy for
  # case-insensitive matching (toupper preserves length, so offsets still line up).
  while IFS=$'\t' read -r br k bdate; do
    [[ -z "$k" ]] && continue
    BR_OF[$r::$k]+="$br "
    [[ "$bdate" > "$cutoff" ]] && discovered+=("$k")
  done < <(awk -F'|' -v re="$KEY_RE" '{ br=$1; dt=$2; s=toupper(br);
      while (match(s, re)) { print br "\t" substr(s, RSTART, RLENGTH) "\t" dt; s=substr(s, RSTART+RLENGTH) } }' "$tmpd/br.$r")

  # keys named anywhere in the prod / stage commit-message history — one grep each
  if [[ -n "$p" ]]; then
    while read -r k; do IN_PROD[$r::$k]=1; done < <(
      git -C "$d" log --format='%h %s %b' "origin/$p" 2>/dev/null | grep -ohiE "$KEY_RE" | tr 'a-z' 'A-Z' | sort -u)
  fi
  if [[ -n "$s" ]]; then
    while read -r k; do IN_STAGE[$r::$k]=1; done < <(
      git -C "$d" log --format='%h %s %b' "origin/$s" 2>/dev/null | grep -ohiE "$KEY_RE" | tr 'a-z' 'A-Z' | sort -u)
  fi

  # open PRs: `gh pr list` (a listing) works. `gh pr list --search` and
  # `gh search prs` silently return [] for these keys — never rely on GitHub search.
  if command -v gh >/dev/null 2>&1; then
    while IFS=$'\t' read -r hr pr; do [[ -n "$hr" ]] && OPENPR[$r::$hr]="$pr"; done < <(
      gh pr list --repo "$(git -C "$d" remote get-url origin 2>/dev/null)" --state open --limit 200 \
         --json number,headRefName,baseRefName 2>/dev/null \
      | jq -r '.[] | "\(.headRefName)\t#\(.number)->\(.baseRefName)"' 2>/dev/null)
  fi
done

# ---- key set ---------------------------------------------------------------
if (( ${#keys} == 0 )); then
  filtered=()
  for k in ${(u)discovered}; do
    [[ -z "$projects" && " $STOP " == *" ${k%%-*} "* ]] && continue
    filtered+=("$k")
  done
  keys=(${(u)filtered})
  mode="branch-derived, branches active since $cutoff"
  (( ${#keys} == 0 )) && warnings+=("no branch in ${existing[*]} has been touched since $cutoff, so nothing was discovered from git alone — these repos look dormant. Ticket verdicts still work: pass the keys explicitly with --keys, or widen the window with --days N.")
else
  mode="explicit --keys"
fi
keys=(${(on)keys})

# ---- report ----------------------------------------------------------------
print "# GIT FACTS — group '$group'"
print "generated by jira-git-facts.sh; key set: $mode (${#keys} keys); repos: ${existing[*]}"
[[ -n "$projects" ]] && print "jira projects for this group: $projects"
print ""
print "## DEPLOY MODEL PER REPO"
for r in "${existing[@]}"; do
  d="$GIT_BASE/$r"; p="${PROD[$r]}"; s="${STAGE[$r]}"
  print "  $r: prod=${p:-NONE} stage=${s:-NONE}  ($(git -C "$d" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||'))"
  if [[ -n "$p" && -n "$s" ]]; then
    sa="$(git -C "$d" rev-list --count "origin/$p..origin/$s" 2>/dev/null)"   # on stage, not yet released
    pa="$(git -C "$d" rev-list --count "origin/$s..origin/$p" 2>/dev/null)"   # on prod, never back-merged
    print "    unreleased on $s: ${sa:-?} commit(s); $p ahead of $s by ${pa:-?} (hotfixes/cherry-picks)"
    [[ "$sa" == "0" ]] && warnings+=("'$r': $s holds nothing $p doesn't — nothing is stage-only right now, so an empty STAGE bucket for this repo is expected, not a bug")
  fi
done
print ""
print "## KEY STATES"
print "# VERDICT = strongest state across repos. PROD>STAGE>UNMERGED>NO_TRACE."
print "# SPLIT means repos disagree — part of the ticket is live, part is not."
print "KEY | VERDICT | PER-REPO DETAIL"

notrace=()
for k in "${keys[@]}"; do
  rank_best=0; details=(); states=()
  for r in "${existing[@]}"; do
    d="$GIT_BASE/$r"; p="${PROD[$r]}"; s="${STAGE[$r]}"
    state="NO_TRACE"; rank=0; note=""
    brs=(${=BR_OF[$r::$k]})

    for br in "${brs[@]}"; do
      short="${br#origin/}"
      pr="${OPENPR[$r::$short]}"
      if [[ -n "${MERGED_PROD[$r::$br]}" ]]; then
        (( rank < 3 )) && { rank=3; state="PROD"; note="branch $short merged into $p" }
      elif [[ -n "${MERGED_STAGE[$r::$br]}" ]]; then
        (( rank < 2 )) && { rank=2; state="STAGE"; note="branch $short merged into $s, awaiting release to $p" }
      elif (( rank < 1 )); then
        # Count only vs prod. A count vs develop would mostly measure how far
        # develop trails prod (hotfixes land on prod directly), not this ticket's work.
        ap="$(git -C "$d" rev-list --count "origin/$p..$br" 2>/dev/null)"
        rank=1; state="UNMERGED"; note="branch $short, ${ap:-?} commit(s) not in $p${pr:+, open PR $pr}"
      fi
    done

    # commit-message supplement: catches keys that never made it into a branch name
    if (( rank < 3 )) && [[ -n "${IN_PROD[$r::$k]}" ]]; then
      rank=3; state="PROD"; note="commit message in $p mentions it${note:+ (also: $note)}"
    fi
    if (( rank < 2 )) && [[ -n "${IN_STAGE[$r::$k]}" ]]; then
      rank=2; state="STAGE"; note="commit message in $s mentions it${note:+ (also: $note)}"
    fi

    (( rank == 0 )) && continue
    states+=("$state"); details+=("$r:$state($note)")
    (( rank > rank_best )) && rank_best=$rank
  done

  if (( rank_best == 0 )); then
    print "$k | NO_TRACE | no branch or commit in ${existing[*]} references this key"
    notrace+=("$k")
    continue
  fi
  case $rank_best in
    3) verdict="PROD" ;;
    2) verdict="STAGE" ;;
    1) verdict="UNMERGED" ;;
  esac
  uniq_states=(${(u)states})              # must be a real array — ${#${(u)states}}
  (( ${#uniq_states} > 1 )) && verdict="SPLIT:$verdict"   # would measure string length
  print "$k | $verdict | ${(j: ; :)details}"
done

# ---- title matching for keys with no key-based trace ------------------------
# Separate section on purpose: this is a weaker signal than the key match and must
# not be read as a deploy verdict. See bin/jira-title-match.py.
if [[ -n "$titles" ]] && (( ${#notrace} )); then
  MATCHER="$HOME/.local/bin/jira-title-match.py"
  [[ -r "$MATCHER" ]] || MATCHER="${0:A:h}/jira-title-match.py"
  if [[ -r "$MATCHER" ]] && command -v python3 >/dev/null 2>&1; then
    : > "$tmpd/branchstate.tsv"
    for r in "${existing[@]}"; do
      p="${PROD[$r]}"; s="${STAGE[$r]}"
      while IFS='|' read -r br bdate; do
        [[ -z "$br" ]] && continue
        if [[ -n "${MERGED_PROD[$r::$br]}" ]]; then st="PROD"
        elif [[ -n "${MERGED_STAGE[$r::$br]}" ]]; then st="STAGE"
        else st="UNMERGED"; fi
        # printf, not `print -r` — with -r the \t stays a literal backslash-t
        printf '%s\t%s\t%s\n' "$r" "${br#origin/}" "$st" >> "$tmpd/branchstate.tsv"
      done < "$tmpd/br.$r"
    done
    tm="$(python3 "$MATCHER" --titles "$titles" --branches "$tmpd/branchstate.tsv" --keys "${notrace[@]}" 2>/dev/null)"
    print ""
    print "## TITLE MATCHES — LOWER CONFIDENCE, VERIFY BEFORE ACTING"
    print "# For keys above that came back NO_TRACE, a branch whose NAME looks like the"
    print "# ticket's TITLE. Needed because many branches carry no Jira key at all. These"
    print "# are CANDIDATES, not verdicts: measured precision was roughly 3-4 in 6. Two"
    print "# real patterns it catches: work shipped under a sibling ticket's branch, and"
    print "# keyless feature branches. Judge each by the shared words shown."
    if [[ -n "$tm" ]]; then print -r -- "$tm"; else print "  (no title matches)"; fi
  else
    warnings+=("--titles was given but the matcher or python3 is missing — title matching was skipped, so keyless branches stayed invisible")
  fi
fi

if (( ${#warnings} )); then
  print ""
  print "## WARNINGS (these limit how much the verdicts above can be trusted)"
  for w in "${warnings[@]}"; do print "  - $w"; done
fi
