# voice-setup

A local, private voice + AI workflow for Apple-Silicon macOS:

- **Dictation** — hold **Option+Space**, talk, release → it types into any app (whisper.cpp, on-device).
- **Auto-read** — Claude Code's replies are read aloud in a natural neural voice (Kokoro); **Option+Esc** stops it.
- **Approval alerts** — a chime + banner + spoken alert when Claude is waiting on you, even in another app.
- **Reply drafter** — highlight any message (Slack, email, ticket, doc) and press **Ctrl+Cmd+S**; Claude Code reads your repos and drops a paste-ready reply on your clipboard.

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
| **Option + Space** (hold) | Dictate; release to type |
| **Option + Esc** | Stop the voice reading |
| **Ctrl + Cmd + S** | Draft a reply to highlighted text → clipboard |
| **Ctrl + Cmd + R** | Read highlighted text aloud (macOS `say`) |
| **Ctrl + Cmd + .** | Stop reading |

## Configuration

- **Reply drafter repos** — `~/.config/voice-setup/reply-repos.conf` (see `config/reply-repos.conf.example`).
- **TTS voice / speed** — env vars on the Kokoro service: `KOKORO_VOICE` (default `af_heart`; try `af_bella`, `am_michael`, `bm_george`), `KOKORO_SPEED`, `KOKORO_CHUNK_CHARS`. Set them in `~/Library/LaunchAgents/com.user.kokoro-tts.plist` (add an `EnvironmentVariables` dict) and reload.
- **Whisper model** — change the model name in `~/.local/bin/whisper-dictation-server.sh`.

## Logs / debugging

- whisper server: `/tmp/whisper-server.log`
- Kokoro server: `/tmp/kokoro-tts.log`
- reply drafter: `/tmp/draft-reply.log`

Restart a service: `launchctl unload ~/Library/LaunchAgents/com.user.kokoro-tts.plist && launchctl load ~/Library/LaunchAgents/com.user.kokoro-tts.plist`

## Uninstall

```bash
./uninstall.sh
```

Removes the services, scripts, and hooks. Homebrew packages and downloaded models are left in place (delete `~/.local/share/voice-setup` and `~/.local/kokoro*` to reclaim disk).

## Notes

- Keep this repo **private** if your `reply-repos.conf` references private repo names.
- Model files are **not** committed; the installer downloads them (~2 GB total).
