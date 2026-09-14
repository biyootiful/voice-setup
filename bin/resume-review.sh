#!/bin/zsh
# Screen candidate resumes against a ROLE SPEC with Claude Code.
#
#   resume-review.sh                                  # pick role, then PDFs
#   resume-review.sh --role data-engineer a.pdf b.pdf # non-interactive
#   resume-review.sh --dry-run --role fullstack x.pdf # print the prompt, run nothing
#
# Pops a role picker (from ~/.config/voice-setup/roles/*.md), then a multi-select
# file picker defaulting to ~/Downloads. Each resume is screened in its OWN
# Claude call against the role's rubric, so candidates are graded against the bar
# rather than against each other. Writes a full report to $RESUME_REVIEW_OUT and
# prints a paste-ready summary to stdout (which the hotkey puts on the clipboard).
#
# Nothing is sent anywhere automatically. You review before sharing.
#
# NOTE: resumes contain PII; this sends them to Claude via your subscription.

emulate -L zsh
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/resume-review.log
: "${USER_NAME:=me}"
: "${RESUME_ROLES_DIR:=$HOME/.config/voice-setup/roles}"
: "${RESUME_REVIEW_OUT:=$HOME/Documents/resume-reviews}"
: "${RESUME_REVIEW_PAR:=4}"     # concurrent Claude calls
T=$'\t'                          # field separator for the summary rows

RUN=$$   # tags log lines so two batches running at once stay readable
log() { print -r -- "[$(date)] ($RUN) $*" >> "$LOG"; }
as_str() { local s="${1//\\/\\\\}"; print -rn -- "\"${s//\"/\\\"}\""; }
as_list() { local -a o; local x; for x in "$@"; do o+=("$(as_str "$x")"); done; print -rn -- "{${(j:, :)o}}"; }
# Setup problems get their own dialog, then exit quietly so the hotkey does not
# also flash a generic "failed" alert on top of it.
bail() { log "bail: $1"; osascript -e "display alert \"Resume review\" message $(as_str "$1") as critical" >/dev/null 2>&1; echo "CANCELLED"; exit 0; }

# ---- args ------------------------------------------------------------------
role_arg=""; dry=0; typeset -a argv_files=()
while (( $# )); do
  case "$1" in
    --role)    role_arg="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *)         argv_files+=("$1"); shift ;;
  esac
done

# ---- 1. pick the role ------------------------------------------------------
# The role spec IS the bar. Injected verbatim, so the screen is only as sharp as
# the file: see config/roles/_TEMPLATE.md.
typeset -a role_files=("$RESUME_ROLES_DIR"/*.md(N))
role_files=(${role_files:#*/_*})
(( ${#role_files} )) || bail "No role specs in $RESUME_ROLES_DIR.
Copy the examples from voice-setup/config/roles/ and edit them — the rubric in there is what stops weak candidates advancing."

typeset -a role_titles=()
local f t
for f in "${role_files[@]}"; do
  t="$(grep -m1 '^# ' "$f" 2>/dev/null | sed 's/^# *//')"
  role_titles+=("${t:-${f:t:r}}")
done

ROLE_FILE=""
if [[ -n "$role_arg" ]]; then
  for f in "${role_files[@]}"; do [[ "${f:t:r}" == "$role_arg" ]] && ROLE_FILE="$f"; done
  [[ -n "$ROLE_FILE" ]] || bail "No role spec named '$role_arg' in $RESUME_ROLES_DIR."
elif (( ${#role_files} == 1 )); then
  ROLE_FILE="${role_files[1]}"
else
  sel="$(osascript -e "choose from list $(as_list "${role_titles[@]}") with prompt \"Screen these resumes for which role?\" with title \"Resume review\"" 2>>"$LOG")"
  [[ -z "$sel" || "$sel" == "false" ]] && { log "cancelled at role picker"; echo "CANCELLED"; exit 0; }
  local i
  for i in {1..${#role_titles}}; do [[ "${role_titles[$i]}" == "$sel" ]] && ROLE_FILE="${role_files[$i]}"; done
  [[ -n "$ROLE_FILE" ]] || bail "Could not match role '$sel'."
fi
ROLE_SLUG="${ROLE_FILE:t:r}"
ROLE_TITLE="$(grep -m1 '^# ' "$ROLE_FILE" | sed 's/^# *//')"; : "${ROLE_TITLE:=$ROLE_SLUG}"
ROLE_SPEC="$(<"$ROLE_FILE")"
log "role=$ROLE_SLUG ($ROLE_TITLE)"

# ---- 2. pick the PDFs ------------------------------------------------------
typeset -a paths=()
if (( ${#argv_files} )); then
  paths=("${argv_files[@]}")
else
  files="$(osascript <<APPLESCRIPT 2>>"$LOG"
set dl to POSIX file "$HOME/Downloads"
set theFiles to choose file with prompt "Resumes to screen for: $ROLE_TITLE" of type {"com.adobe.pdf"} default location dl with multiple selections allowed
set outText to ""
repeat with f in theFiles
  set outText to outText & POSIX path of f & linefeed
end repeat
return outText
APPLESCRIPT
)"
  if [[ -z "$files" ]]; then
    log "no files selected (cancelled)"; echo "CANCELLED"; exit 0
  fi
  paths=("${(@f)files}")
  paths=(${paths:#})
fi

typeset -a missing=()
for p in "${paths[@]}"; do [[ -f "$p" ]] || missing+=("$p"); done
(( ${#missing} )) && bail "Not readable: ${missing[*]}"
log "screening ${#paths} resume(s) for $ROLE_SLUG"

CLAUDE="${CLAUDE_BIN:-$(command -v claude)}"
[[ -n "$CLAUDE" ]] || bail "claude CLI not found on PATH."

# ---- 3. the rubric prompt --------------------------------------------------
# One candidate per call. The model never sees the other resumes, which is the
# point: batching them made it rank candidates against each other, so a weak
# batch still produced an ADVANCE for whoever was least bad.
build_prompt() {
  local pdf="$1"
  cat <<PROMPT
You are screening ONE candidate resume for a hiring manager ($USER_NAME), against a specific role spec. Read this PDF: $pdf

=== ROLE SPEC (this is the bar — nothing else is) ===
$ROLE_SPEC
=== END ROLE SPEC ===

HOW TO SCREEN. Follow this order; do not skip to the verdict.

1. EXTRACT. If you cannot read the PDF's text (scan, image-only, empty), stop and return VERDICT: ERROR with what went wrong. Never infer content from the filename.

2. COMPUTE RELEVANT YEARS from the actual date ranges, and show the arithmetic. Only count experience relevant to THIS role; count analyst/BI/support/unrelated years at most half, and say what you discounted. Overlapping or concurrent roles count once. Resumes routinely imply more experience than the dates support, so do this before forming an impression.

3. TEST EACH MUST-HAVE as a hard gate. For each one, quote the resume verbatim (short) as evidence and mark it MET, WEAK, or NOT MET.
   Evidence rules, applied strictly:
   - A tool named only in a skills list, summary, or header is NOT evidence. It is a claim. Evidence is the tool applied to a described piece of work with scope or outcome attached.
   - Absence of evidence is NOT MET, not "probably fine". You are not filling gaps for the candidate.
   - Prestige is not evidence: a well-known employer, a degree, or a certification tells you nothing about what they did there.
   - Team accomplishments in "we" voice with no stated individual contribution are WEAK at best.
   WHAT A GATE MAY AND MAY NOT TURN ON. Gate only on what a resume reliably reveals: which job they actually did, how long, what they owned, whether they operated it. Those are structural, and their absence is real information.
   Never gate on a detail that competent people routinely leave off a resume — a data volume, a latency or cost figure, a described SQL problem, quantified impact. Their absence is NOT evidence of absence: it is a resume-writing convention, and it varies by region, employer, and whether an agency reformatted the page. If a capability is plainly implied by the work described but the supporting number or war story is missing, that is BORDERLINE with the question named, never PASS. Scoring is where thin evidence costs them.
   ANY must-have at NOT MET means VERDICT: PASS — but only where the CAPABILITY is absent, per the paragraph above. There is no offsetting it with strengths elsewhere. A WEAK must-have caps the verdict at BORDERLINE.

4. PLAUSIBILITY. Before weighing anything, ask whether the claimed scope fits the person's tenure and level at the time. Resumes inflate scope far more often than they invent employers, and this is where a screen gets fooled:
   - Scope vs tenure: work that would be a staff or lead engineer's program (re-architecting a platform, owning a multi-source migration, setting technical direction) claimed by someone in their first two years is almost certainly team work written in the first person. Note it and discount the ownership claim to participation, unless the resume says what THEY specifically did.
   - Volume vs time: count the distinct major projects claimed inside a tenure. Four year-sized initiatives in twelve months does not happen.
   - Sole-ownership voice: a large program described entirely as "I" with no team, partner, or manager anywhere is a rewrite, not a record. (The mirror of pure "we" voice, and just as uninformative.)
   - Metric pattern: when EVERY bullet carries a round percentage and none carries a mechanism, the numbers were retrofitted. A real fix names the cause — a skewed join, a missing index, a driver collecting to one node. "Improved X by 40% using <category of technique>" names nothing. Credit the mechanism, not the number.
   - Trajectory: a career switch into this field is fine and common, but pair it with the timeline. Someone whose degree and early work are unrelated has fewer real years in the discipline than the dates suggest.
   Where the deciding evidence for an ADVANCE is implausible in this way, cap the verdict at BORDERLINE and make the ASK a scope question that would settle it ("who else was on that migration, and which part was yours?"). Do not PASS them for it — inflated writing is not proof of a weak engineer, it is proof you do not yet know. Say plainly in the detail which claims you discounted and why.

5. WEIGH the core signals, anti-signals, and score dimensions, but only after the gate. Score 0-10 using the spec's dimensions.

TRANSFERABLE SKILL — apply this throughout, it overrides a literal reading of the spec. The spec names tools to describe the SHAPE of the work, not to require a brand. Credit any equivalent: a different framework, language, database, orchestrator, or cloud clears the same bar when the underlying capability is demonstrated. Someone who solved the problem on another stack is qualified; someone who lists our exact stack with no problem attached is not. If you credit an equivalence, name it in one short clause ("same job on Snowflake/Dagster"). Never mark a must-have NOT MET because a specific product is absent — only because the CAPABILITY is absent. Do not treat an older or unfashionable stack as a weakness in itself.

DO NOT SCREEN ON any of these, and do not mention them: name, gender, ethnicity, nationality, photo, age or graduation year, marital or family status, disability, visa or work-authorization status, or the prestige of a school or employer. Career breaks are not a character flaw; a gap is only worth noting if it leaves a capability untested. Non-native English phrasing on a resume says nothing about engineering ability.

6. VERDICT — judge against the bar, not against other candidates. You are seeing exactly one resume and you do not know who else applied.
   WHAT YOU ARE DECIDING: whether this person earns a 30-minute phone screen. Not an offer, not an onsite. A phone screen is cheap and a missing detail is one question away from resolved, so the cost of a wrong PASS (a good engineer never called) is higher than the cost of a wrong BORDERLINE (30 minutes).
   STRONG_ADVANCE — every must-have met with real evidence, several core signals, clearly at or above level. Rare.
   ADVANCE — every must-have met with real evidence, and a specific reason to spend an hour interviewing them.
   BORDERLINE — they plausibly do this job, but the resume leaves a specific thing untested. This is the right home for a candidate whose work looks right but whose page carries no numbers or no war stories. Name the question. This is a real, common, useful verdict, not a way to avoid deciding.
   PASS — they are doing a DIFFERENT job (consuming data rather than building it, frontend-only for a fullstack role), or clearly below the level, or the anti-signals dominate. Reserve it for that.
   CALIBRATION: in a normal inbound pool, most resumes are PASS, ADVANCE is genuinely uncommon, and a healthy screen produces a real BORDERLINE pile. Two failure modes, both bad: advancing on polish, and passing everyone because no one wrote their resume the way you would. If your reason for passing someone is "no number on the page" rather than "this is not the job they do", you have made the second mistake — that is a BORDERLINE with a question.

OUTPUT FORMAT. Do the gate analysis above before you write anything, but do NOT show your working. These five lines first, exactly these labels, one line each, no markdown:
NAME: <candidate name, or "Unknown">
VERDICT: <STRONG_ADVANCE|ADVANCE|BORDERLINE|PASS|ERROR>
SCORE: <0-10 integer>
YOE: <relevant years as a number, e.g. 4.5>
ONELINE: <one sentence under 140 chars: what they are, and the deciding reason>
ASK: <the probe, under 160 chars. For a PASS, the question that would overturn it, or "-" if nothing would.>

THE PROBE. This is the most useful line you write, so aim it. Rules:
- Aim it at the ONE claim the verdict rests on — the load-bearing one, the thing that changes the answer if it turns out to be thinner than written. Not the biggest gap on the page, and never a generic "tell me about your experience with X".
- Make it hard to answer from a rehearsed script. The four shapes that work: MECHANISM ("what was actually slow?"), SEQUENCE ("how did you find out it broke?"), ATTRIBUTION ("who else was on that, which part was yours?"), CONSEQUENCE ("what broke, and who got paged?"). Someone who did the work answers these in specifics immediately; someone who inherited the bullet stalls or restates the resume.
- Where step 4 flagged inflated scope, the probe IS the attribution question, naming the specific claim.
- Never yes/no, never answerable by repeating the resume, never trivia or a quiz about a tool.
- One question. Two only when the verdict genuinely turns on two separate unknowns.
---
Then the detail. Aim for 4 to 6 short lines total, and stop when you have said the useful thing:
- One line on who they are and the relevant-years figure.
- The one or two things that decide it. Only mention must-haves that are NOT clearly met; met ones need no commentary at all.
- Anything genuinely notable: a real strength, a concern, dates that do not add up.
- If PASS, a fair specific reason shareable internally as-is: about fit against this spec, never about the person.

Concision is the priority. Do not restate the resume, do not list what they already say about themselves, and do not quote more than a handful of words at a time - quote only when the exact wording is the point (an inflated claim, a telling omission). Do not use bold or headers. No preamble, no summing-up line at the end.Write like a person, first person, plain and direct. No em-dashes, no hedging padding, no "overall a solid profile" filler, no complimenting the resume for being well written.
PROMPT
}

if (( dry )); then
  print -r -- "--- role: $ROLE_SLUG ($ROLE_TITLE)"
  print -r -- "--- files: ${paths[*]}"
  print -r -- "--- report: $RESUME_REVIEW_OUT/${ROLE_SLUG}-<stamp>.md"
  print -r -- "--- prompt for ${paths[1]} ---"
  build_prompt "${paths[1]}"
  exit 0
fi

# ---- 4. screen each candidate independently, a few at a time ---------------
TMP="$(mktemp -d /tmp/resume-review.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

screen_one() {
  local idx="$1" pdf="$2"
  local out="$TMP/$idx.md" row="$TMP/$idx.row"
  local body
  body="$("$CLAUDE" -p "$(build_prompt "$pdf")" \
    --add-dir "${pdf:h}" \
    --allowedTools Read \
    --strict-mcp-config 2>>"$LOG")"
  print -r -- "$body" > "$out"

  local name verdict score yoe oneline ask rank label
  name="$(grep -m1 '^NAME:' "$out" | sed 's/^NAME: *//')"
  verdict="$(grep -m1 '^VERDICT:' "$out" | sed 's/^VERDICT: *//' | tr -d ' ')"
  score="$(grep -m1 '^SCORE:' "$out" | sed 's/^SCORE: *//' | grep -oE '[0-9]+' | head -1)"
  yoe="$(grep -m1 '^YOE:' "$out" | sed 's/^YOE: *//')"
  oneline="$(grep -m1 '^ONELINE:' "$out" | sed 's/^ONELINE: *//')"
  ask="$(grep -m1 '^ASK:' "$out" | sed 's/^ASK: *//')"
  # A response that ignored the format still has to land somewhere visible.
  [[ -z "$verdict" ]] && { verdict="ERROR"; oneline="${oneline:-unparseable response, see the report}"; }
  # Agency/ATS exports are often name-redacted, and three rows reading "Unknown"
  # are indistinguishable — fall back to the filename so they can be told apart.
  [[ -z "$name" || "$name" == "Unknown" ]] && name="${pdf:t:r}"
  : "${score:=0}"
  # label is what a human reads; verdict stays a token so sorting and tallying work.
  case "$verdict" in
    STRONG_ADVANCE) rank=1; label="Strong advance" ;;
    ADVANCE)        rank=2; label="Advance" ;;
    BORDERLINE)     rank=3; label="Borderline" ;;
    PASS)           rank=4; label="Pass" ;;
    *)              rank=5; label="Could not read"; verdict="ERROR" ;;
  esac
  # -r is required (fields can contain backslashes), so the tabs must be literal.
  print -r -- "$rank$T$score$T$verdict$T$name$T$yoe$T$oneline$T$label$T${pdf:t}$T$idx$T$ask" > "$row"
  log "  [$idx] ${pdf:t} -> $verdict score=$score name=$name"
}

local n=0
for p in "${paths[@]}"; do
  (( n++ ))
  while (( $(jobs -p | grep -c .) >= RESUME_REVIEW_PAR )); do sleep 0.4; done
  screen_one "$n" "$p" &
done
wait

# ---- 5. assemble: report file + paste-ready summary ------------------------
typeset -a rows
rows=(${(f)"$(cat "$TMP"/*.row(N) 2>/dev/null | sort -t$'\t' -k1,1n -k2,2nr)"})
(( ${#rows} )) || bail "Every candidate failed to screen. See $LOG."

typeset -A count
for r in "${rows[@]}"; do
  local -a c=("${(@ps:\t:)r}")
  (( count[${c[3]:-ERROR}]++ ))
done
adv=$(( ${count[STRONG_ADVANCE]:-0} + ${count[ADVANCE]:-0} ))
SUMMARY="$TMP/summary.txt"
{
  print -r -- "Resume screen: $ROLE_TITLE — ${#paths} candidate(s)"
  print -r -- "$adv advance, ${count[BORDERLINE]:-0} borderline, ${count[PASS]:-0} pass${count[ERROR]:+, ${count[ERROR]} could not be read}"
  print -r -- ""
  local last=""; local r=""
  for r in "${rows[@]}"; do
    local -a c=("${(@ps:\t:)r}")
    if [[ "${c[3]}" != "$last" ]]; then print -r -- ""; print -r -- "${c[7]}"; last="${c[3]}"; fi
    print -r -- "• ${c[4]} (${c[5]}y, ${c[2]}/10) — ${c[6]}"
    [[ ${c[1]} -le 3 && -n "${c[10]}" && "${c[10]}" != "-" ]] && print -r -- "   ask: ${c[10]}"
  done
} | cat -s > "$SUMMARY"

mkdir -p "$RESUME_REVIEW_OUT"
# Seconds, not minutes: two batches of the same role finishing in the same
# minute used to write the same path and the second one won. The -N suffix
# covers the same-second case (scripted runs), so a report is never clobbered.
STAMP="$(date +%Y-%m-%d-%H%M%S)"
OUT="$RESUME_REVIEW_OUT/${ROLE_SLUG}-${STAMP}.md"
dup=1
while [[ -e "$OUT" ]]; do
  OUT="$RESUME_REVIEW_OUT/${ROLE_SLUG}-${STAMP}-${dup}.md"
  (( dup++ ))
done

{
  print -r -- "# Resume screen: $ROLE_TITLE"
  print -r -- ""
  print -r -- "$(date '+%Y-%m-%d %H:%M') | ${#paths} candidate(s) | rubric: \`$ROLE_FILE\`"
  print -r -- ""
  print -r -- "## At a glance"
  print -r -- ""
  print -r -- '```'
  cat "$SUMMARY"
  print -r -- '```'
  print -r -- ""
  print -r -- "## Candidates"
  print -r -- ""
  print -r -- "| # | Candidate | Verdict | Score | Rel. yrs | Why | File |"
  print -r -- "|---|---|---|---|---|---|---|"
  local i=0; local r=""
  for r in "${rows[@]}"; do
    (( i++ ))
    local -a c=("${(@ps:\t:)r}")
    print -r -- "| $i | ${c[4]} | ${c[7]} | ${c[2]}/10 | ${c[5]} | ${c[6]} | ${c[8]} |"
  done
  print -r -- ""
  print -r -- "Verdicts are absolute, not a ranking: each resume was screened on its own against the rubric, so the score is fit-to-spec, not position in this batch."
  print -r -- ""
  for r in "${rows[@]}"; do
    local -a c=("${(@ps:\t:)r}")
    print -r -- "---"
    print -r -- ""
    print -r -- "## ${c[4]} — ${c[7]}, ${c[2]}/10"
    print -r -- ""
    print -r -- "\`${c[8]}\`"
    print -r -- ""
    [[ -n "${c[10]}" && "${c[10]}" != "-" ]] && { print -r -- "**Ask:** ${c[10]}"; print -r -- ""; }
    # Strip the machine-readable header; the table above already carries it.
    # Not anchored on the --- separator: the model sometimes omits it, and that
    # is not worth failing over. Leading label lines and blanks go, everything
    # from the first real line stays.
    [[ "${c[3]}" == "ERROR" ]] && { print -r -- "_Unparseable response, raw output:_"; print -r -- ""; }
    awk 'h && (/^(NAME|VERDICT|SCORE|YOE|ONELINE|ASK|GATE):/ || /^[[:space:]]*$/ || /^-{3,}[[:space:]]*$/) { next } { h=0; print }' h=1 "$TMP/${c[9]}.md"
    print -r -- ""
  done
} > "$OUT"

# The report is the artifact you keep and share; the clipboard is a convenience
# the next batch overwrites.
[[ "${RESUME_REVIEW_OPEN:-1}" == 1 ]] && open "$OUT" 2>>"$LOG"

cat "$SUMMARY"
print -r -- ""
print -r -- "Full notes per candidate: $OUT"

log "done role=$ROLE_SLUG candidates=${#paths} advance=$adv out=$OUT"
