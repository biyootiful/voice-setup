#!/bin/zsh
# Jira triage agent (Ctrl+Cmd+K). Pops the repo picker — the product groups from
# repo-groups.conf, plus "Custom…" to assemble a one-off set by hand — then opens
# a kitty Claude session that:
#   1. runs jira-git-facts.sh to get git ground truth (what's in prod vs stage),
#   2. pulls the group's open Jira tickets via the Atlassian MCP,
#   3. joins the two and buckets every ticket by real deploy state,
#   4. writes a markdown report and prints an at-a-glance summary.
#
# Read-only: JQL reads + `git fetch` only. No transitions, comments, pushes.
#
# Group -> repos -> Jira projects all come from
# ~/.config/voice-setup/repo-groups.conf (see config/repo-groups.conf.example).

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/jira-triage.log

source "$HOME/.config/voice-setup/reply-repos.conf" 2>/dev/null
source "$HOME/.config/voice-setup/repo-groups.conf" 2>/dev/null
: "${GIT_BASE:=$HOME/Documents/git}"
: "${JIRA_SITE:=}"
: "${JIRA_TRIAGE_OUT:=$HOME/Documents/jira-triage}"

PICKER="$HOME/.local/bin/pick-repo-group.sh"
[[ -r "$PICKER" ]] || PICKER="$(cd "$(dirname "$0")" && pwd)/pick-repo-group.sh"
source "$PICKER" || { echo "[$(date)] cannot source $PICKER" >> "$LOG"; echo "NO_PICKER"; exit 1; }

[[ -z "${GROUP_ORDER:-}" ]] && { echo "[$(date)] no GROUP_ORDER (edit repo-groups.conf)" >> "$LOG"; echo "NO_GROUPS"; exit 1; }

# ---- which repos -----------------------------------------------------------
#   (no args)                       -> picker (groups + "Custom…")
#   <group>                         -> a group from repo-groups.conf
#   --repos "a b c" [--projects X]  -> ad-hoc set, primary FIRST
group=""; dry=0; cli_repos=""; cli_projects=""
while (( $# )); do
  case "$1" in
    --dry-run)  dry=1; shift ;;
    --repos)    shift; cli_repos="$1"; shift ;;
    --projects) shift; cli_projects="$1"; shift ;;
    -*)         shift ;;
    *)          [[ -z "$group" ]] && group="$1"; shift ;;
  esac
done

# REPO_GROUPS / GROUP_JIRA_PROJECTS are declared `typeset -gA` by repo-groups.conf.
if [[ -n "$cli_repos" ]]; then
  resolve_repo_list ${(s: :)cli_repos} || { echo "[$(date)] none of --repos are cloned" >> "$LOG"; echo "NO_REPOS"; exit 1; }
elif [[ -n "$group" ]]; then
  resolve_repo_group "$group"
  case $? in
    0) ;;
    3) echo "[$(date)] unknown group '$group'" >> "$LOG"; echo "NO_SUCH_GROUP"; exit 1 ;;
    *) echo "[$(date)] no cloned repos for $group" >> "$LOG"; echo "NO_REPOS"; exit 1 ;;
  esac
else
  pick_repo_group "Jira triage — which board / repos?"
  case $? in
    0) ;;
    1) echo "[$(date)] picker cancelled" >> "$LOG"; echo "CANCELLED"; exit 0 ;;
    *) echo "[$(date)] picker found no usable repos" >> "$LOG"; echo "NO_REPOS"; exit 1 ;;
  esac
fi

group="$PICK_LABEL"
existing=("${PICK_REPOS[@]}")

# Jira project keys: from config for a real group; for a hand-picked set, guessed
# from the repos' branch names and confirmed in a dialog (or given via --projects).
projects="$cli_projects"
if [[ -z "$projects" ]]; then
  if (( PICK_CUSTOM )); then
    if (( dry )); then
      projects="$(derive_jira_projects "${existing[@]}")"
    else
      pick_jira_projects "${existing[@]}"
      case $? in
        0) projects="$PICK_PROJECTS" ;;
        1) echo "[$(date)] cancelled at project keys" >> "$LOG"; echo "CANCELLED"; exit 0 ;;
        *) echo "[$(date)] no project keys for custom group $group" >> "$LOG"; echo "NO_PROJECTS"; exit 1 ;;
      esac
    fi
  else
    projects="${GROUP_JIRA_PROJECTS[$group]:-}"
  fi
fi
[[ -z "$projects" ]] && { echo "[$(date)] no Jira project keys for '$group'" >> "$LOG"; echo "NO_PROJECTS"; exit 1; }
JQL_PROJECTS="${projects// /, }"

primary="${existing[1]}"
add_args=()
(( ${#existing[@]} > 1 )) && for r in ${existing[2,-1]}; do add_args+=(--add-dir "$GIT_BASE/$r"); done

FACTS="$HOME/.local/bin/jira-git-facts.sh"
[[ -x "$FACTS" ]] || FACTS="$(cd "$(dirname "$0")" && pwd)/jira-git-facts.sh"
# A hand-picked group isn't in repo-groups.conf, so the facts script can't look it
# up — hand it the repos and keys explicitly. These must precede --keys, which is
# variadic and would swallow them.
FACTS_CMD="$FACTS $group"
(( PICK_CUSTOM )) && FACTS_CMD="$FACTS $group --repos \"${existing[*]}\" --projects \"$projects\""

mkdir -p "$JIRA_TRIAGE_OUT"
OUT="$JIRA_TRIAGE_OUT/${group}-$(date +%Y-%m-%d).md"
TITLES="$JIRA_TRIAGE_OUT/.${group}-titles.tsv"   # key<TAB>title, written by the agent

site_line=""
[[ -n "$JIRA_SITE" ]] && site_line="My Jira site is ${JIRA_SITE} — pass that hostname as cloudId; if it is rejected, call getAccessibleAtlassianResources to get the real cloudId."

PROMPT="$(cat <<EOF
You are my Jira triage assistant for the "$group" product group. Goal: tell me, at a glance, the true state of this board — specifically which tickets' code is actually DEPLOYED and which are out of sync with what Jira claims.

STRICTLY READ-ONLY. Do NOT transition tickets, comment, edit issues, create branches, commit, or push. You may only read Jira and run the git commands below (which fetch but never write).

STEP 1 — Git ground truth. Run this and read the whole output:
  $FACTS_CMD
It fetches every repo in the group and prints, for each Jira key it found on a branch, whether that work is in prod (main), stage (develop only), unmerged, or absent. The deploy model is: develop -> dev+stage, main -> prod. READ ITS "WARNINGS" SECTION and carry anything in it into your final report — a failed fetch or an uncloned repo means some verdicts are unreliable, and I need to know that.

STEP 2 — Pull the board. ${site_line}
Use searchJiraIssuesUsingJql with:
  jql: project in ($JQL_PROJECTS) AND (statusCategory != Done OR resolutiondate >= -21d) ORDER BY updated DESC
  fields: ["key","summary","status","assignee","issuetype","priority","updated"]
  maxResults: 50
Page with nextPageToken until you have them all. This response is VERBOSE — a 50-issue page can exceed the token limit and get spilled to a file. If that happens, do NOT try to read the raw file; jq it, e.g.
  jq -r '.issues.nodes[] | [.key,(.fields.status.name//"?"),(.fields.assignee.displayName//"unassigned"),(.fields.issuetype.name//"?"),(.fields.updated|split("T")[0]),.fields.summary] | @tsv' <file>

STEP 3 — Fill the gaps, and match on ticket TITLES as well as keys. Many branches carry no Jira key at all (in some repos most of them: \`dark-mode\`, \`search-v2\`, \`invoice-flow\`), so a key-only join misses real shipped work. Do this:
  a. Write a tab-separated file of every ticket from STEP 2 as \`KEY<TAB>title\`, one per line, to $TITLES. Use the full summary text, and make sure it is a real tab.
  b. Re-run the facts script over ALL the keys from STEP 2, passing that file:
     $FACTS_CMD --no-fetch --titles $TITLES --keys KEY-1 KEY-2 ...
(--no-fetch is correct here: STEP 1 already fetched.)
This gives you two things: verdicts for keys STEP 1 didn't cover, and a "TITLE MATCHES" section proposing branches for keys that came back NO_TRACE.

TITLE MATCHES ARE CANDIDATES, NOT VERDICTS. Do not move a ticket into the shipped/stage/in-flight buckets on a title match alone, and never report one as "deployed". Judge each by the "shared words" the script prints: many distinctive words that together describe one specific change is convincing; two generic words (e.g. "ui update", "fix image") is probably coincidence. Report the convincing ones under the ticket's ⚪ entry as "possible match: <branch> [<state>] — verify", and ignore the weak ones apart from a one-line count of how many you discarded.

STEP 4 — Join and bucket every ticket. Buckets:
  GREEN  Shipped to prod   — git says PROD
  YELLOW On stage          — git says STAGE (in develop, not main)
  BLUE   In flight         — git says UNMERGED (branch exists; note the open PR number if there is one)
  WHITE  No code found     — git says NO_TRACE
  RED    Drift             — Jira status and git disagree. Call this out for each of:
           - status is Done/Closed/Released but git is not PROD  (claimed done, not shipped)
           - status is Staging/QA/In Review but git says PROD    (already live, board is behind)
           - status is To Do/Intake/Backlog but git says PROD or STAGE (work shipped, board never moved)
           - status is In Progress but git says PROD — list these LAST and label them
             "soft" drift: a multi-part ticket can legitimately have some code in prod
             while work continues, so this is a prompt to check, not a mistake
           - git verdict starts with SPLIT — part of the ticket is live and part is not; name which repo is which
  GHOST  Orphan branches   — a key on a git branch that does NOT EXIST in Jira at all.
           Do NOT infer this from absence in STEP 2 — that query is filtered, so most
           branch keys missing from it are simply tickets closed more than 21 days ago,
           which are NOT orphans. Verify first: take the branch keys not seen in STEP 2
           and run one searchJiraIssuesUsingJql with searchResultMode "count" and
           jql: key in (KEY-1, KEY-2, ...). Only keys Jira rejects or does not return
           are real orphans. If they all exist, say "no orphan branches" and move on.
A ticket appears in exactly one of GREEN/YELLOW/BLUE/WHITE by its git state, and ALSO in RED if it drifts. Sort RED first, most consequential first.

STEP 5 — Write the report to $OUT (create/overwrite it). Markdown, with: a one-paragraph "state of the board" opener, a summary count table, then a section per bucket. Tables should carry key, summary (trimmed), Jira status, git verdict, assignee. Link keys as ${JIRA_SITE:+https://$JIRA_SITE/browse/}<KEY>. End with the WARNINGS from step 1 verbatim under "Caveats".

IMPORTANT for the WHITE bucket: list EVERY ticket in it in full (key, summary, status, assignee) in both the report and the terminal summary — do not collapse or truncate it to a count. I want to see how big it really is and judge the false-positive rate myself. It will be the biggest bucket by far, so split it into three sub-groups (still listing every ticket) so the list is readable:
  (a) Not started — status To Do / Intake / Backlog. Expected; no code should exist yet.
  (b) No code by nature — the ticket isn't a code change (security policy, SOC2, access
      review, DNS/email/deliverability config, spike or exploration, docs). Judge this
      from the summary. Expected; NO_TRACE is the correct answer for these.
  (c) ⚠️ Suspicious — status says code should exist (In Progress / QA / Staging / Done)
      and it isn't a (b). These are the only ones worth investigating. Attach any
      convincing TITLE MATCH from STEP 3 to the ticket here as "possible match:
      <branch> [<state>] — verify", because the two real causes of a false NO_TRACE
      are exactly what title matching finds: work shipped under a sibling ticket's
      branch, and keyless feature branches.

STEP 6 — Print a terminal summary in this shape:
  📋 JIRA TRIAGE — $group — <today's date>
  <one line: total tickets, and the headline finding>
  🔴 DRIFT (<n>) — needs a decision:
    • <KEY> — "<summary>". Jira says <status>, git says <verdict>. → <what to do in one clause>
  🟢 Shipped to prod: <n>    🟡 On stage: <n>    🔵 In flight: <n>
  🟡 On stage (waiting to be released):
    • <KEY> — <summary>  [<assignee>]
  🔵 In flight:
    • <KEY> — <summary>  [<assignee>, PR #<n>]
  ⚪ No code found (<n>) — FULL LIST, sub-grouped:
     (a) not started (<n>): • <KEY> — <summary>  [<status>, <assignee>]
     (b) no code by nature (<n>): • <KEY> — <summary>  [<status>, <assignee>]
     (c) ⚠️ suspicious (<n>): • <KEY> — <summary>  [<status>, <assignee>] <why it's odd>
         <if a convincing title match: "possible match: <branch> [<state>] — verify">
  🔗 Title matches discarded as coincidence: <n>
  👻 Orphan branches: <key/branch> — <state>, no ticket
  ⚠️  <any caveats>
  📄 Report: $OUT
Then stop and wait. Do not offer to change anything in Jira.
EOF
)"

CLAUDE="$(command -v claude)"
KITTY="/Applications/kitty.app/Contents/MacOS/kitty"; [[ -x "$KITTY" ]] || KITTY="$(command -v kitty)"
[[ -z "$CLAUDE" || -z "$KITTY" ]] && { echo "[$(date)] missing claude or kitty" >> "$LOG"; echo "MISSING_TOOL"; exit 1; }

if (( dry )); then
  print -r -- "--- group '$group' (custom=$PICK_CUSTOM) repos: ${existing[*]}"
  print -r -- "--- jira projects: $projects"
  print -r -- "--- would run in $GIT_BASE/$primary with add-dirs: ${add_args[*]}"
  print -r -- "--- report path: $OUT"
  print -r -- "--- prompt ---"
  print -r -- "$PROMPT"
  exit 0
fi

TITLE="📋 Jira triage · $group"
echo "[$(date)] launching triage group=$group projects=$projects repos=${existing[*]} out=$OUT" >> "$LOG"
# Sessions are keyed by cwd and --add-dir is not restored on resume, so log the
# command that brings this one back:  grep RESUME /tmp/jira-triage.log | tail -1
echo "[$(date)] RESUME $group: cd $GIT_BASE/$primary && claude --resume ${add_args[*]}" >> "$LOG"
# One kitty instance, titled window — cmd-` cycles it with the other agent sessions.
# NOTE: prompt must come BEFORE --add-dir (variadic, it would eat the prompt).
"$KITTY" --single-instance --directory "$GIT_BASE/$primary" --title "$TITLE" \
  "$CLAUDE" "$PROMPT" "${add_args[@]}" >>"$LOG" 2>&1 &
echo "OK $group"
