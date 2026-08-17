# voice-setup

A local, private voice + AI workflow for Apple-Silicon macOS:

- **Dictation** — hold **Option+Space**, talk, release → it types into any app (whisper.cpp, on-device). Hold **Option+Shift+Space** instead for *clean dictation*: it transcribes, then auto-revises into tight prose before typing.
- **Auto-read** — Claude Code's replies are read aloud in a natural neural voice (Kokoro); **Option+Esc** stops it.
- **Approval alerts** — a chime + banner + spoken alert when Claude is waiting on you, even in another app.
- **Reply drafter** — highlight any message (Slack, email, ticket, doc) and press **Ctrl+Cmd+S**; Claude Code reads your repos and drops a paste-ready reply on your clipboard.
- **PR reviewer** — copy one or more GitHub PR links (even a whole Slack message — it extracts every PR link and ignores the rest) and press **Ctrl+Cmd+P**; Claude reviews each diff and leaves a **pending** review (inline comments) you submit. Needs the `gh` CLI logged in.
- **Resume reviewer** — download the resume PDFs (Slack "Download all" → `~/Downloads`), press **Ctrl+Cmd+H**, pick the PDFs in the file dialog (multi-select), and Claude drops hiring feedback per candidate on your clipboard. PII is sent to Claude — you review before sharing.
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
| **Ctrl + Cmd + H** | Pick resume PDFs → hiring feedback on clipboard |
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

## Logs / debugging

- whisper server: `/tmp/whisper-server.log`
- Kokoro server: `/tmp/kokoro-tts.log`
- reply drafter: `/tmp/draft-reply.log`
- PR reviewer: `/tmp/pr-review.log`
- resume reviewer: `/tmp/resume-review.log`
- Jira agent: `/tmp/jira-agent.log`
- Jira triage: `/tmp/jira-triage.log`

Restart a service: `launchctl unload ~/Library/LaunchAgents/com.user.kokoro-tts.plist && launchctl load ~/Library/LaunchAgents/com.user.kokoro-tts.plist`

## Uninstall

```bash
./uninstall.sh
```

Removes the services, scripts, and hooks. Homebrew packages and downloaded models are left in place (delete `~/.local/share/voice-setup` and `~/.local/kokoro*` to reclaim disk).

## Notes

- Keep this repo **private** if your `reply-repos.conf` references private repo names.
- Model files are **not** committed; the installer downloads them (~2 GB total).
