#!/bin/zsh
# Engineering Weekly drafter (Ctrl+Cmd+W). Opens a Claude session that:
#   1. reads my last few "Engineering Weekly" emails from Sent (Gmail MCP) to
#      learn the format, section order, and voice I actually use,
#   2. works out the reporting window from the date of that last update, so
#      nothing falls in the gap between weeks,
#   3. pulls each product area's board from Jira (Atlassian MCP) for that window,
#   4. drafts the update — ticket + one plain-English line each — in my format,
#   5. saves it as a Gmail DRAFT (never sends) and a local markdown file.
#
# Areas, boards, and the recipient live in
# ~/.config/voice-setup/eng-weekly.conf — see config/eng-weekly.conf.example.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/eng-weekly.log

source "$HOME/.config/voice-setup/reply-repos.conf" 2>/dev/null
source "$HOME/.config/voice-setup/eng-weekly.conf"  2>/dev/null
: "${GIT_BASE:=$HOME/Documents/git}"
: "${JIRA_SITE:=}"
: "${ENG_WEEKLY_TO:=}"
: "${ENG_WEEKLY_DAYS:=7}"
: "${ENG_WEEKLY_SUBJECT_HINT:=}"
: "${ENG_WEEKLY_SCOPE:=}"
: "${ENG_WEEKLY_OUT:=$HOME/Documents/eng-weekly}"

# ---- args ------------------------------------------------------------------
#   --days N    override the fallback window (default $ENG_WEEKLY_DAYS)
#   --dry-run   print the resolved config + prompt instead of launching
days="$ENG_WEEKLY_DAYS"; dry=0
while (( $# )); do
  case "$1" in
    --days)    shift; days="$1"; shift ;;
    --dry-run) dry=1; shift ;;
    *)         shift ;;
  esac
done

[[ -z "$ENG_WEEKLY_TO" ]] && { echo "[$(date)] no ENG_WEEKLY_TO (edit eng-weekly.conf)" >> "$LOG"; echo "NO_CONFIG"; exit 1; }
[[ -z "${ENG_WEEKLY_AREA_ORDER:-}" ]] && { echo "[$(date)] no ENG_WEEKLY_AREA_ORDER (edit eng-weekly.conf)" >> "$LOG"; echo "NO_AREAS"; exit 1; }

# ---- build the per-area board block ---------------------------------------
# ENG_WEEKLY_PROJECTS / ENG_WEEKLY_BOARDS are declared `typeset -gA` by the conf.
areas_block=""
have_area=0
for area in ${(s: :)ENG_WEEKLY_AREA_ORDER}; do
  keys="${ENG_WEEKLY_PROJECTS[$area]:-}"
  [[ -z "$keys" ]] && { echo "[$(date)] area '$area' has no ENG_WEEKLY_PROJECTS entry — skipped" >> "$LOG"; continue; }
  label="${ENG_WEEKLY_LABELS[$area]:-$area}"
  board="${ENG_WEEKLY_BOARDS[$area]:-}"
  areas_block+="  • ${label} — Jira project(s): ${keys// /, }"
  [[ -n "$board" ]] && areas_block+="   (board: $board)"
  areas_block+=$'\n'
  have_area=1
done
(( have_area )) || { echo "[$(date)] no usable areas" >> "$LOG"; echo "NO_AREAS"; exit 1; }

mkdir -p "$ENG_WEEKLY_OUT"
OUT="$ENG_WEEKLY_OUT/eng-weekly-$(date +%Y-%m-%d).md"

site_line=""
[[ -n "$JIRA_SITE" ]] && site_line="My Jira site is ${JIRA_SITE} — pass that hostname as cloudId; if it is rejected, call getAccessibleAtlassianResources to get the real cloudId."
subject_line=""
[[ -n "$ENG_WEEKLY_SUBJECT_HINT" ]] && subject_line="If Sent gives you nothing to copy, the subject usually looks like: ${ENG_WEEKLY_SUBJECT_HINT}."
scope_line=""
[[ -n "$ENG_WEEKLY_SCOPE" ]] && scope_line="Scope note (what belongs in this update): ${ENG_WEEKLY_SCOPE}"

PROMPT="$(cat <<EOF
You are drafting my weekly Engineering Weekly email, the one I send to ${ENG_WEEKLY_TO}. I write it by hand every week by walking the Jira boards below and turning each ticket into one short plain-English line. Do that walk for me and leave a draft I can edit and send.

CRITICAL SAFETY RULE: never send anything. Use create_draft only — there is no send tool. Do not transition, comment on, or edit any Jira ticket either. This whole job is read + draft.

STEP 1 — Learn my format from my own past updates. FIRST, before touching Jira:
search_threads with query: in:sent to:${ENG_WEEKLY_TO}
Take the 3-4 most recent and get_thread each one (messageFormat PLAIN_TEXT). Read them closely and write down, for your own use: the subject line pattern (including how the date/week is written), the section headings and their ORDER, whether tickets are named by key, by title, or not at all, how long each bullet is, whether there is an intro or sign-off, and the voice. ${subject_line}
These emails are the spec. Where this prompt and my actual past emails disagree about format, MY EMAILS WIN.

STEP 2 — Set the reporting window. Note the date of my most recent update. The window is [that date] → today; that is what keeps work from falling into the gap between weeks. If Sent has nothing, use the last ${days} days. State the window you picked in your terminal summary so I can sanity-check it.

STEP 3 — Pull each board for that window. ${site_line}
The areas, in the order they should appear in the email:
${areas_block}
For each area, use searchJiraIssuesUsingJql with fields ["key","summary","status","assignee","issuetype","priority","resolutiondate","updated"] and maxResults 50, paging with nextPageToken until you have everything. Run these, substituting N = the number of days in your window from STEP 2:
  a. Landed:     project in (KEYS) AND statusCategory = Done AND updated >= -Nd ORDER BY updated DESC
  b. In flight:  project in (KEYS) AND statusCategory = "In Progress" ORDER BY updated DESC
  c. Newly up:   project in (KEYS) AND statusCategory = "To Do" AND updated >= -Nd ORDER BY updated DESC
If any of those is rejected, fall back to  project in (KEYS) AND updated >= -Nd ORDER BY updated DESC  and bucket by the status field yourself.
These responses are VERBOSE — a 50-issue page can blow the token limit and get spilled to a file. If that happens do NOT read the raw file; jq it:
  jq -r '.issues.nodes[] | [.key,(.fields.status.name//"?"),(.fields.assignee.displayName//"unassigned"),(.fields.resolutiondate//""|split("T")[0]),.fields.summary] | @tsv' <file>
${scope_line}

STEP 4 — Turn tickets into update lines. One line per ticket, in MY format from STEP 1. Rules:
• Write what CHANGED and why it matters, in plain English a non-engineer on the list can follow. The Jira summary is raw material, not the line — rewrite it. Expand internal shorthand and acronyms on first use.
• Read the ticket description/comments (getJiraIssue) for anything whose summary is too cryptic to rewrite honestly. Do this for the handful that need it, not all of them.
• Do NOT invent outcomes, metrics, dates, percentages, or customer names. If a ticket implies an impact you cannot verify from the ticket itself, write it inline as ⚠️[confirm: ...] and leave it for me. I would rather fill in five blanks than catch one confident fabrication.
• Merge duplicates and sibling tickets of one effort into a single line.
• Drop pure noise — chores, dependency bumps, ticket hygiene — unless my past emails show I include them.
• Keep tickets grouped under the area they came from, in the configured order above.

STEP 5 — Assemble the email in my format and create_draft it to ${ENG_WEEKLY_TO} with the subject in my pattern for this week. Also write the same content to $OUT (create/overwrite) so I have it if the draft gets lost.

STEP 6 — Print a terminal summary in this shape:
  📮 ENGINEERING WEEKLY — <today's date>
  Window: <start> → <today>  (from my last update, sent <date>)
  <area>: <n> landed · <n> in flight · <n> newly up
  ...
  ⚠️  Needs you (<n>): 
    • <the ⚠️[confirm: ...] blanks, one per line, each with the ticket key>
  🤔 Judgment calls:
    • <anything you dropped, merged, or guessed at, so I can overrule you>
  ✉️  Draft saved to Gmail (NOT sent) · 📄 $OUT
Then stop and wait — I will tell you what to change. Do not send.
EOF
)"

CLAUDE="$(command -v claude)"
KITTY="/Applications/kitty.app/Contents/MacOS/kitty"; [[ -x "$KITTY" ]] || KITTY="$(command -v kitty)"

if (( dry )); then
  print -r -- "--- to: $ENG_WEEKLY_TO   fallback window: ${days}d   out: $OUT"
  print -r -- "--- areas:"; print -r -- "$areas_block"
  print -r -- "--- prompt ---"; print -r -- "$PROMPT"
  exit 0
fi

[[ -z "$CLAUDE" || -z "$KITTY" ]] && { echo "[$(date)] missing claude or kitty" >> "$LOG"; echo "MISSING_TOOL"; exit 1; }

TITLE="📮 Eng weekly"
echo "[$(date)] launching eng-weekly (to=$ENG_WEEKLY_TO areas=$ENG_WEEKLY_AREA_ORDER fallback=${days}d)" >> "$LOG"
# One kitty instance, titled window — cmd-` cycles it with the other agent sessions.
# Tools this agent may use without prompting — writes the summary file + a Gmail draft; sending stays on ask.
# Additive and session-scoped; permissions.ask rules (git push, rm, Gmail
# send) still take precedence, so the dangerous gates stay in place.
ALLOWED_TOOLS="Read,Grep,Glob,TodoWrite,WebFetch,WebSearch,Write,Edit,Task,Bash(cd:*),Bash(git:*),Bash(ls:*),Bash(cat:*),Bash(head:*),Bash(tail:*),Bash(grep:*),Bash(rg:*),Bash(find:*),Bash(fd:*),Bash(sed:*),Bash(awk:*),Bash(wc:*),Bash(jq:*),Bash(sort:*),Bash(uniq:*),Bash(cut:*),Bash(date:*),Bash(echo:*),Bash(mkdir:*),Bash(python3:*),Bash(gh:*),mcp__claude_ai_Atlassian__getJiraIssue,mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql,mcp__claude_ai_Atlassian__search,mcp__claude_ai_Atlassian__fetch,mcp__claude_ai_Atlassian__getJiraIssueRemoteIssueLinks,mcp__claude_ai_Atlassian__getConfluencePage,mcp__claude_ai_Gmail__search_threads,mcp__claude_ai_Gmail__get_thread,mcp__claude_ai_Gmail__get_message,mcp__claude_ai_Gmail__list_labels,mcp__claude_ai_Gmail__list_drafts,mcp__claude_ai_Gmail__get_draft,mcp__claude_ai_Gmail__create_draft,mcp__claude_ai_Gmail__update_draft,mcp__claude_ai_Gmail__label_thread,mcp__claude_ai_Gmail__unlabel_thread,mcp__claude_ai_Gmail__label_message,mcp__claude_ai_Gmail__unlabel_message,mcp__claude_ai_Gmail__update_message_labels"

"$KITTY" --single-instance --directory "$ENG_WEEKLY_OUT" --title "$TITLE" \
  "$CLAUDE" "$PROMPT" \
  --allowedTools "$ALLOWED_TOOLS" >>"$LOG" 2>&1 &
echo "OK"
