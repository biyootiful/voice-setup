# voice-setup

A local, private voice + AI workflow for Apple-Silicon macOS:

- **Dictation** — hold **Option+Space**, talk, release → it types into any app (whisper.cpp, on-device). Hold **Option+Shift+Space** instead for *clean dictation*: it transcribes, then auto-revises into tight prose before typing.
- **Auto-read** — Claude Code's replies are read aloud in a natural neural voice (Kokoro); **Option+Esc** stops it.
- **Approval alerts** — a chime + banner + spoken alert when Claude is waiting on you, even in another app.
- **Reply drafter** — highlight any message (Slack, email, ticket, doc) and press **Ctrl+Cmd+S**; Claude Code reads your repos and drops a paste-ready reply on your clipboard.
- **PR reviewer** — copy one or more GitHub PR links (even a whole Slack message — it extracts every PR link and ignores the rest) and press **Ctrl+Cmd+P**; Claude reviews each diff and leaves a **pending** review (inline comments) you submit. Needs the `gh` CLI logged in.
- **Resume screener** — download the resume PDFs (Slack "Download all" → `~/Downloads`), press **Ctrl+Cmd+H**, pick the role, pick the PDFs (multi-select). Each resume is screened *on its own* against that role's rubric, and you get a paste-ready summary on the clipboard plus a full report per candidate. PII is sent to Claude — you review before sharing. [How the bar works ↓](#the-resume-screen-bar)
- **Text reviser** — highlight any text and press **Ctrl+Cmd+E**; Claude rewrites it into direct, concise Slack-style communication (your voice preserved, no AI tone), paste-ready on the clipboard.
- **Jira agent** — copy a Jira ticket URL and press **Ctrl+Cmd+J**; pick the product group, and it spins up a new kitty Claude Code session scoped to just that group's repos, reads the ticket (via the Atlassian connector), and hands you a read-only implementation plan you then drive. Needs the Atlassian MCP connected and the `kitty` terminal.
- **Jira triage** — press **Ctrl+Cmd+K** and pick a board / product group; it cross-checks every open ticket against git and tells you what is *actually* deployed. Buckets each ticket as shipped-to-prod / on-stage / in-flight / no-code-found, flags **drift** where Jira and git disagree (marked Done but not in prod, sitting in "Staging" but already live, shipped but the board never moved), and lists orphan branches with no ticket. Writes a markdown report to `~/Documents/jira-triage/` and prints a summary. Read-only — JQL reads plus `git fetch`, nothing is written to Jira.

Everything runs locally except the reply drafter and the read-aloud, which use your existing **Claude Code subscription** (no extra API cost).

## Requirements

- Apple-Silicon Mac (M1/M2/M3…), macOS.
- [Homebrew](https://brew.sh) installed at `/opt/homebrew`.
- [Claude Code](https://claude.com/claude-code) CLI installed and logged in (`claude`), for the reply drafter + read-aloud hooks.

## Install

```bash
git clone <your-repo-url> voice-setup
cd voice-setup
./install.sh
```

The installer (idempotent — safe to re-run) will:
- `brew install` sox, espeak-ng, python@3.12, jq, cmake, and Hammerspoon
- clone + build whisper.cpp (arm64/Metal) and download the `large-v3-turbo` model
- create the Kokoro Python venv and download its model
- copy the scripts to `~/.local/bin`, the config to `~/.hammerspoon/init.lua`
- load the two background services (LaunchAgents) so they start at login
- merge the auto-read + notification hooks into `~/.claude/settings.json`

### Manual steps macOS requires (the installer can't do these)

1. Open **Hammerspoon**, then grant it in **System Settings → Privacy & Security**:
   - **Input Monitoring** → Hammerspoon ON
   - **Accessibility** → Hammerspoon ON
   - **Microphone** → Hammerspoon ON

   Then Hammerspoon menu-bar icon → **Reload Config**.
2. In Claude Code, open **`/hooks`** once (or restart it) to activate the auto-read + notification hooks.
3. Edit **`~/.config/voice-setup/reply-repos.conf`** to point at your repos.
4. External keyboard (e.g. Keychron): set it to **Mac mode**.

## Hotkeys

| Keys | Action |
|------|--------|
| **Option + Space** (hold) | Dictate; release to type (raw) |
| **Option + Shift + Space** (hold) | Clean dictation; transcribes, auto-revises, types the polished version |
| **Option + Esc** | Stop the voice reading |
| **Ctrl + Cmd + S** | Draft a reply to highlighted text → clipboard |
| **Ctrl + Cmd + P** | Review the copied GitHub PR link(s) → pending review you submit |
| **Ctrl + Cmd + H** | Pick a role + resume PDFs → screen against that rubric |
| **Ctrl + Cmd + J** | Copied Jira URL → scoped planning session (pick group, or *Custom…*) |
| **Ctrl + Cmd + K** | Jira board triage → what's deployed vs what Jira claims (pick group, or *Custom…*) |
| **Ctrl + Cmd + E** | Revise highlighted text → concise Slack style on clipboard |
| **Ctrl + Cmd + R** | Read highlighted text aloud (macOS `say`) |
| **Ctrl + Cmd + .** | Stop reading |

## Seeing the shortcuts

- Click the **🎙️ menu-bar icon** for the full command list, plus **Edit shortcuts config**, **Edit reply-repos config**, and **Reload config**.
- Or press **⌃⌘/** to toggle an on-screen cheat sheet (⌃⌘/ again to hide).

## Configuration

All the hotkeys and toggles live in one file: **`~/.hammerspoon/init.lua`** (open it from the 🎙️ menu → *Edit shortcuts config*). Other knobs:

- **Reply drafter repos** — `~/.config/voice-setup/reply-repos.conf` (see `config/reply-repos.conf.example`).
- **Jira agent product groups** — `~/.config/voice-setup/repo-groups.conf` (see `config/repo-groups.conf.example`). For the Jira agent, also connect Atlassian once via `/mcp` in Claude Code.

  Both Jira hotkeys end their picker with **`Custom… (pick repos)`**, for a ticket that straddles repos no group covers — it lists every git repo under `GIT_BASE`, takes a multi-selection (cmd-click), then asks which one is **primary** (the cwd, and the only place `claude --resume` can find the session later — see below). No config edit needed; if you reach for the same combination twice, that's the signal to add it to `repo-groups.conf`. A custom set is labelled `<primary>+<n>` in the window title and report filename. Triage also needs Jira project keys for an ad-hoc set, so it guesses them from those repos' branch names (top 8 by frequency, noise words dropped) and shows the guess in an editable dialog — the guess is only the first word off a branch name, so check it.
- **Jira triage** — same `repo-groups.conf`, plus a `GROUP_JIRA_PROJECTS[<group>]` entry giving that group's Jira project keys (used for the JQL query *and* to stop branch names like `backup-develop-2024-03-20` being misread as tickets). `JIRA_SITE` and `JIRA_TRIAGE_OUT` live in `reply-repos.conf`. The git half runs standalone too, if you want to check deploy state without Jira:
  ```sh
  jira-git-facts.sh <group>                        # every key found on a branch
  jira-git-facts.sh <group> --keys ABC-12 ...      # just these tickets
  jira-git-facts.sh <group> --titles keys.tsv ...  # also match ticket titles
  jira-git-facts.sh adhoc --repos "a b" --projects "ABC"   # no group needed
  ```
  Triage takes the same two flags (`jira-triage.sh --repos "a b c" --projects "ABC"`, primary first, `--dry-run` to print the prompt instead of launching), which is how a custom pick is passed through — handy for scripting it without the dialogs.
  It assumes the convention `develop` → dev+stage and `main`/`master` → prod. If your repos deploy off different branches, edit the branch names near the top of `bin/jira-git-facts.sh`.

  **Two join signals.** The primary one is the Jira key in the branch name, checked by ancestry (`--merged`) rather than commit messages, which are too inconsistent to trust. But a lot of branches carry no key at all (`dark-mode`, `invoice-flow`) and that work is invisible to key matching — so `--titles` (a `KEY<TAB>title` file) additionally matches ticket *titles* against branch names via `bin/jira-title-match.py`. Title matches are reported in their own section as **candidates, never as deploy verdicts**: precision is roughly 3-4 in 6, so each one prints the words it matched on and you judge it. Many distinctive words is convincing; two generic ones is coincidence.
- **TTS voice / speed** — env vars on the Kokoro service: `KOKORO_VOICE` (currently `bf_isabella`), `KOKORO_SPEED`, `KOKORO_CHUNK_CHARS`. Set them in the `EnvironmentVariables` dict of `launchagents/com.user.kokoro-tts.plist`, then re-run `./install.sh` (or copy to `~/Library/LaunchAgents/`, substituting `__HOME__`, and `launchctl unload && load`). Editing only the installed copy works until the next install overwrites it.

  All 54 voices ship inside `voices-v1.0.bin` — nothing extra to download. Prefix is language + gender (`af_`/`am_` American, `bf_`/`bm_` British, then `e`=es, `f`=fr, `h`=hi, `i`=it, `j`=ja, `p`=pt, `z`=zh). Best English options: `af_heart`, `af_bella`, `af_nicole`, `am_michael`, `am_puck`, `bf_emma`, `bf_isabella`, `bm_george`; the rest of the American set is noticeably more synthetic. Non-English voices also need `lang=` changed in `bin/kokoro-tts-server.py`, which hardcodes `en-us`. To audition them all, loop `Kokoro.get_voices()` through `kokoro.create()` using `~/.local/kokoro-venv/bin/python`.
- **Whisper model** — change the model name in `~/.local/bin/whisper-dictation-server.sh`.

## Resuming an agent session

Closed the window by accident, or lost it to a crash / power cut? Claude keys sessions by **cwd alone**, and both Jira agents `cd` into the group's *primary* repo — the first cloned entry in `REPO_GROUPS[<group>]`, or whatever you picked as primary in the custom picker. `claude --resume` only ever lists sessions started in the directory you run it from, and nothing on screen tells you which directory that was, so:

```sh
claude-resume.sh ABC-12        # every session mentioning it, and where each lives
claude-resume.sh ABC-12 --go   # …pick one and reopen it, --add-dir repos restored
claude-resume.sh               # the 20 most recent, everywhere
```

```
  #   WHEN          RESUME FROM                    -c   OPENED WITH
  1   Aug 12 16:16  my-api                         -    Read Jira ticket ABC-12 (https://…
  2   Aug 04 11:40  my-api                         -    Read Jira ticket ABC-12 (https://…
```

It reads the cwd out of the transcripts in `~/.claude/projects/` (`bin/claude-sessions.py` does the scan; `--deep` searches whole transcripts rather than just the opening prompt). The **-c** column answers *resume or continue*: `yes` means that session is the newest in its directory, so `claude -c` there lands on it; `-` means something newer has run in that directory since and only `--resume` will find it.

The equivalent by hand is `cd ~/Documents/git/<primary> && claude --resume <TICKET-KEY> --add-dir ~/Documents/git/<other-repo>`. Two things bite here:

- **Only the primary works.** Run `claude --resume` in a sibling repo of the same group and the session simply isn't in the list.
- **`--add-dir` is not persisted.** A resumed session has access to the primary repo only. Nothing warns you at startup; it surfaces later as a permission prompt when the agent reaches for a file in a sibling repo, so re-pass the extra repos every time.

`claude-resume.sh --go` handles both: it cds to the right place and rebuilds the `--add-dir` list, preferring the launch log (which records the real command, so hand-picked custom groups come back intact) and falling back to the group whose primary is that directory. If two groups share a primary it says so and takes neither — pass `--group <name>`. The raw log lines are there too:

```sh
grep RESUME /tmp/jira-agent.log | tail -5      # or /tmp/jira-triage.log
```

Doing it by hand, `--resume <KEY>` pre-filters the session picker, and the seeded prompt starts with `Read Jira ticket <KEY>`, so the key always matches.

## Logs / debugging

- whisper server: `/tmp/whisper-server.log`
- Kokoro server: `/tmp/kokoro-tts.log`
- reply drafter: `/tmp/draft-reply.log`
- PR reviewer: `/tmp/pr-review.log`
- resume screener: `/tmp/resume-review.log`
- Jira agent: `/tmp/jira-agent.log`
- Jira triage: `/tmp/jira-triage.log`

Restart a service: `launchctl unload ~/Library/LaunchAgents/com.user.kokoro-tts.plist && launchctl load ~/Library/LaunchAgents/com.user.kokoro-tts.plist`

## The resume screen bar

The screen is only as good as the **role spec**. Specs live in `~/.config/voice-setup/roles/*.md`, one file per role, seeded from `config/roles/` on install; the `# ` heading is what the picker shows, and the whole file is injected into the prompt verbatim. `_TEMPLATE.md` (and anything else starting with `_`) is hidden from the picker.

That file is the bar, so write it like one. The earlier version of this tool asked Claude to assess resumes for "a software engineering role" and handed back a lot of weak ADVANCEs. Five things caused that, and the current design targets each:

- **No bar to measure against.** With no spec, the model grades resume *polish*, which is exactly what the market optimises for. Fix: the role spec, and specifically its **must-haves**, which are a hard gate — any one unmet is a `PASS`, no offsetting against strengths elsewhere. If you wouldn't reject someone for missing it, it isn't a must-have.
- **Relative grading.** All candidates in one prompt, ending with "rank them", spreads verdicts across the batch, so a weak batch still produces an ADVANCE for whoever is least bad. Fix: one Claude call per resume (`$RESUME_REVIEW_PAR` at a time, default 4). The model never sees the others, and the summary is sorted afterwards in shell. Scores are fit-to-spec, not position in the batch.
- **Keyword lists read as experience.** Fix: a tool named only in a skills list is a *claim*; evidence is the tool applied to described work with scope or outcome.
- **Years taken at face value.** Fix: the model computes relevant years from the actual date ranges before forming an impression, discounting adjacent-but-not-the-job experience.
- **A friendly-summary tone brief.** Fix: explicit calibration, and a decision framed as *does this earn a 30-minute phone screen*, not *should we hire them*.

**What a gate may turn on.** The first cut of this rubric produced 0 advances out of 9, and grepping the reasons showed 7 of the 8 rejections were "no stated data volume" or "no SQL problem described" — resume-writing conventions, not capabilities. That filters for how someone writes a resume, which is a bad predictor and skews against reformatted agency exports and non-US conventions. So the gate turns only on **what a resume reliably reveals**: which job they did, how long, what they owned, whether they operated it. A missing number, latency figure, or war story is a **question**, not a rejection — it produces `BORDERLINE` and an `ASK:` line. Same nine resumes after the change: 1 advance, 5 borderline, 3 pass, and all three passes were "doing a different job" rather than "wrote it differently".

**Every candidate gets an `ASK:`** — the one question a 10-minute call should open with. That is where the screen pays off: a resume screen cannot tell you whether someone is good, only whether they are plausible and what to probe.

Two things the spec deliberately does **not** gate on:

- **Specific tools.** Specs name a stack to describe the shape of the work; the prompt overrides any literal reading of it. An equivalent framework, language, database, orchestrator, or cloud clears the same bar, and the report names the equivalence it credited. A candidate who did the job on another stack is qualified; one who lists your exact stack with no problem attached is not. An older stack is not a weakness in itself.
- **Anything about the person.** Name, gender, ethnicity, nationality, photo, age or graduation year, family status, disability, visa status, and school or employer prestige are all explicitly excluded, and career breaks are only worth noting where they leave a capability untested.

  Employer prestige is deliberately out, and the specs say so: a recognisable logo is not rigour. What *is* scored is the **environment** — real traffic, uptime pressure, on-call, money-grade data, a system lived with for years, versus short client rotations with no ownership tail. That is the signal a brand name is a noisy proxy for, so it is screened directly instead.

Verdicts are `STRONG_ADVANCE`, `ADVANCE`, `BORDERLINE` (plausible, but something specific is untested — the `ASK:` names it) and `PASS` (a different job, or clearly below level, with a fair internally shareable reason). Reports land in `$RESUME_REVIEW_OUT`, default `~/Documents/resume-reviews/<role>-<timestamp>.md`, lead with the at-a-glance summary, and open automatically (`RESUME_REVIEW_OPEN=0` to stop that). The summary also goes to the clipboard, but the report is the copy that survives a second batch.

Run it from the terminal to iterate on a spec without the pickers:

```
resume-review.sh --role data-engineer ~/Downloads/*.pdf
resume-review.sh --dry-run --role fullstack a.pdf     # print the prompt, call nothing
```

A useful sanity check when tuning: run the same resume against two roles. A data engineer screened against `fullstack` should come back `PASS` with "no application-layer work to screen on", not a mediocre score.

## Uninstall

```bash
./uninstall.sh
```

Removes the services, scripts, and hooks. Homebrew packages and downloaded models are left in place (delete `~/.local/share/voice-setup` and `~/.local/kokoro*` to reclaim disk).

## Notes

- Keep this repo **private** if your `reply-repos.conf` references private repo names.
- Model files are **not** committed; the installer downloads them (~2 GB total).
