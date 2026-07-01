#!/bin/zsh
# Email triage agent (Ctrl+Cmd+M). Opens a Claude session that:
#   1. reads recent inbox via the Gmail MCP,
#   2. marks KNOWN automated noise as read (removes UNREAD; stays in inbox),
#   3. summarizes everything into noise / FYI / needs-you buckets,
#   4. drafts replies (NEVER sends — there is no send tool) for the threads that
#      need you, grounded in your configured repos + your own past Sent replies.
#
# All personal/company specifics (your domain, colleagues, noise senders, repos)
# live in ~/.config/voice-setup/email-triage.conf — see config/email-triage.conf.example.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG=/tmp/email-agent.log

source "$HOME/.config/voice-setup/reply-repos.conf"   2>/dev/null
source "$HOME/.config/voice-setup/email-triage.conf"  2>/dev/null
: "${GIT_BASE:=$HOME/Documents/git}"

# Fallbacks so the script still runs before the config is filled in.
: "${EMAIL_PRIMARY_REPO:=${PRIMARY_REPO:-}}"
: "${EMAIL_ADD_REPOS:=${EXTRA_REPOS:-}}"
: "${MY_EMAILS:=}"
: "${MY_DOMAIN_DESC:=the topics people email you about}"
: "${SALES_COLLEAGUES:=}"
: "${NOISE_SENDERS:=}"

CLAUDE="$(command -v claude)"
KITTY="/Applications/kitty.app/Contents/MacOS/kitty"; [[ -x "$KITTY" ]] || KITTY="$(command -v kitty)"
[[ -z "$CLAUDE" || -z "$KITTY" ]] && { echo "[$(date)] missing claude or kitty" >> "$LOG"; echo "MISSING_TOOL"; exit 1; }

# Working dir = primary repo (ground truth for drafting); fall back to GIT_BASE.
primary_dir="$GIT_BASE/$EMAIL_PRIMARY_REPO"
[[ -n "$EMAIL_PRIMARY_REPO" && -d "$primary_dir" ]] || primary_dir="$GIT_BASE"
add_args=()
for r in ${(s: :)EMAIL_ADD_REPOS}; do [[ -d "$GIT_BASE/$r" ]] && add_args+=(--add-dir "$GIT_BASE/$r"); done

# Optional lines injected into the prompt only when configured.
domain_line="My technical domain (what people email me for): ${MY_DOMAIN_DESC}."
[[ -n "$MY_EMAILS" ]]        && emails_line="My email addresses (I'm a participant even when only CC'd): ${MY_EMAILS}." || emails_line=""
[[ -n "$SALES_COLLEAGUES" ]] && colleagues_line="Colleagues who routinely CC me to supply the technical answer (treat their threads as ACTION): ${SALES_COLLEAGUES}." || colleagues_line=""

PROMPT="$(cat <<EOF
You are my email triage assistant. Use the Gmail tools (search_threads, get_thread, create_draft, and the label tools). To mark a thread read, remove the UNREAD label with unlabel_thread (labelId "UNREAD"). CRITICAL SAFETY RULE: never send anything. There is no send tool — you only create DRAFTS and mark noise read. Both are reversible.

Work in this order:

STEP 1 — Pull recent inbox. search_threads for "in:inbox newer_than:3d" (page through if there are more; cover up to ~80 threads).

STEP 2 — Classify each thread as NOISE, FYI, or ACTION.
• NOISE = automated / no-reply mail that never needs me. Treat mail from these senders/domains as noise:
  ${NOISE_SENDERS}
  Also treat any calendar mail (subject begins Invitation:/Accepted:/Declined:/Canceled:/Updated:) as noise.
• ACTION = a real human at a real org, in an active thread, where a reply or MY input is pending — even if I'm only CC'd. ${emails_line} ${domain_line} ${colleagues_line}
• FYI = read, but a human might want to glance (recurring budget/spend alerts, team digests).
If you are UNSURE, treat it as ACTION — never auto-read something borderline.

STEP 3 — For every NOISE thread, mark it read (unlabel_thread, remove UNREAD). Tally counts by category. Do NOT touch ACTION or unsure threads.

STEP 4 — For each ACTION thread: get_thread (full content), then work out the SPECIFIC open question and who is waiting on whom. If it is technical, ground yourself in the repos available in this session (the working directory and any added dirs) — how the relevant logic actually works — and search my prior answers with search_threads "in:sent <topic keywords>" to match my tone and past explanations. Then create_draft a reply in that thread. Ground every technical claim in what you found; for any specific number, date, or config you cannot verify, write it inline as "⚠️[confirm: ...]" rather than inventing it. Keep my voice: concise and direct.

STEP 5 — Print a summary to the terminal, exactly this shape:
  📧 EMAIL TRIAGE — <today's date>
  Auto-read as noise: <N> total
    • <category>: <n>   (e.g. Scheduled reports · Jira · GitHub · budget alerts · newsletters …)
  FYI (read — glance if you want):
    • <short bullets for anything recurring/important>
  🔴 NEEDS YOU (ranked, most urgent first):
    1. <sender / org> — "<subject>". Open question: <one line>.  [✍️ draft ready  |  ❓needs your input on: <what>]
    2. …
  🤔 Unsure (left UNREAD for you): <any borderline threads>

Finish by stating how many drafts you created and confirm nothing was sent. Then stop and wait.
EOF
)"

TITLE="📧 Email triage"
echo "[$(date)] launching email triage (primary=$primary_dir add=${EMAIL_ADD_REPOS})" >> "$LOG"
# One kitty instance, titled window — cmd-` cycles it with the other agent sessions.
"$KITTY" --single-instance --directory "$primary_dir" --title "$TITLE" \
  "$CLAUDE" "$PROMPT" "${add_args[@]}" >>"$LOG" 2>&1 &
echo "OK"
