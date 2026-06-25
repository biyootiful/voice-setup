#!/usr/bin/env bash
# Installer for the local voice setup: dictation (whisper.cpp) + text-to-speech
# (Kokoro) + a code-aware reply drafter. Apple-Silicon macOS only.
#
#   ./install.sh
#
# Idempotent: safe to re-run. Downloads models, builds whisper.cpp, places
# scripts/config, and loads the background services. It CANNOT grant macOS
# permissions — see the checklist it prints at the end.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }

# ---- preflight -------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS only."; exit 1; }
[[ "$(uname -m)" == "arm64" || -n "${ALLOW_NON_ARM:-}" ]] || \
  warn "Not running as arm64 (Apple Silicon). If your terminal is under Rosetta, the whisper build still targets arm64 via flags, so this is usually fine."

BREW="/opt/homebrew/bin/brew"
[[ -x "$BREW" ]] || { echo "Homebrew (Apple Silicon) not found at /opt/homebrew. Install it from https://brew.sh first."; exit 1; }
BREW_PREFIX="$($BREW --prefix)"

VS_HOME="$HOME/.local/share/voice-setup"
WHISPER_DIR="$VS_HOME/whisper.cpp"
KOKORO_DIR="$HOME/.local/kokoro"
VENV="$HOME/.local/kokoro-venv"
BIN="$HOME/.local/bin"
mkdir -p "$VS_HOME" "$KOKORO_DIR" "$BIN" "$HOME/.hammerspoon" \
         "$HOME/Library/LaunchAgents" "$HOME/.config/voice-setup" "$HOME/.claude"

# ---- 1. Homebrew dependencies ---------------------------------------------
say "Installing Homebrew dependencies (sox, espeak-ng, python@3.12, jq, cmake)"
arch -arm64 "$BREW" install sox espeak-ng python@3.12 jq cmake || true
if [[ ! -d "/Applications/Hammerspoon.app" ]]; then
  say "Installing Hammerspoon"
  arch -arm64 "$BREW" install --cask hammerspoon || true
fi

# ---- 2. whisper.cpp (build arm64, download model) -------------------------
if [[ ! -x "$WHISPER_DIR/build/bin/whisper-server" ]]; then
  say "Cloning + building whisper.cpp (arm64, Metal)"
  [[ -d "$WHISPER_DIR/.git" ]] || git clone https://github.com/ggml-org/whisper.cpp "$WHISPER_DIR"
  "$BREW_PREFIX/bin/cmake" -B "$WHISPER_DIR/build" -S "$WHISPER_DIR" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF -DCMAKE_BUILD_TYPE=Release
  "$BREW_PREFIX/bin/cmake" --build "$WHISPER_DIR/build" -j --config Release
else
  say "whisper.cpp already built — skipping"
fi
if [[ ! -f "$WHISPER_DIR/models/ggml-large-v3-turbo.bin" ]]; then
  say "Downloading whisper model (large-v3-turbo, ~1.6GB)"
  (cd "$WHISPER_DIR" && sh ./models/download-ggml-model.sh large-v3-turbo)
fi

# ---- 3. Kokoro TTS (venv + models) ----------------------------------------
PY312="$BREW_PREFIX/opt/python@3.12/bin/python3.12"
if [[ ! -x "$VENV/bin/python" ]]; then
  say "Creating Kokoro Python 3.12 venv + installing kokoro-onnx"
  "$PY312" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet kokoro-onnx soundfile
fi
base="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
[[ -f "$KOKORO_DIR/kokoro-v1.0.onnx" ]] || { say "Downloading Kokoro model (~310MB)"; curl -sL -o "$KOKORO_DIR/kokoro-v1.0.onnx" "$base/kokoro-v1.0.onnx"; }
[[ -f "$KOKORO_DIR/voices-v1.0.bin"  ]] || { say "Downloading Kokoro voices (~27MB)";  curl -sL -o "$KOKORO_DIR/voices-v1.0.bin"  "$base/voices-v1.0.bin"; }

# ---- 4. Scripts ------------------------------------------------------------
say "Installing scripts to $BIN"
cp "$HERE"/bin/*.sh "$HERE"/bin/*.py "$BIN/"
chmod +x "$BIN"/*.sh

# ---- 5. Hammerspoon config -------------------------------------------------
say "Installing Hammerspoon config"
[[ -f "$HOME/.hammerspoon/init.lua" ]] && cp "$HOME/.hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua.bak.$(date +%s)"
cp "$HERE/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua"

# ---- 6. LaunchAgents (substitute __HOME__, load) --------------------------
say "Installing + loading background services"
for p in whisper-dictation kokoro-tts; do
  plist="$HOME/Library/LaunchAgents/com.user.$p.plist"
  sed "s|__HOME__|$HOME|g" "$HERE/launchagents/com.user.$p.plist" > "$plist"
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"
done

# ---- 7. Claude Code hooks (merge into settings.json) ----------------------
say "Wiring Claude Code hooks (auto-read + notifications)"
SETTINGS="$HOME/.claude/settings.json"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
tmp="$(mktemp)"
"$BREW_PREFIX/bin/jq" \
  --arg speak "$BIN/claude-speak-response.sh" \
  --arg notify "$BIN/claude-notify.sh" '
  .hooks = (.hooks // {})
  | .hooks.Stop = [{"hooks":[{"type":"command","command":$speak,"async":true}]}]
  | .hooks.Notification = [{"hooks":[{"type":"command","command":$notify,"async":true}]}]
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

# ---- 8. Reply-drafter config ----------------------------------------------
CONF="$HOME/.config/voice-setup/reply-repos.conf"
[[ -f "$CONF" ]] || { cp "$HERE/config/reply-repos.conf.example" "$CONF"; warn "Edit $CONF to point at YOUR repos (for Ctrl+Cmd+S)."; }

command -v claude >/dev/null 2>&1 || warn "Claude Code CLI ('claude') not found — install it and run 'claude' once to log in, for the reply drafter + voice hooks."

cat <<'DONE'

============================================================
 Install complete. A few MANUAL steps macOS requires:

 1. Open Hammerspoon (Applications). Grant it permission in:
      System Settings > Privacy & Security > Input Monitoring   -> Hammerspoon ON
      System Settings > Privacy & Security > Accessibility       -> Hammerspoon ON
      System Settings > Privacy & Security > Microphone          -> Hammerspoon ON
    Then Hammerspoon menu-bar icon > Reload Config.

 2. In Claude Code, open /hooks once (or restart it) so the
    auto-read + notification hooks activate.

 3. Edit ~/.config/voice-setup/reply-repos.conf to list your repos.

 4. (Keychron / external keyboards) set it to Mac mode.

 Hotkeys:
   Option+Space (hold) = dictate, release to type
   Option+Esc          = stop the voice reading
   Ctrl+Cmd+S          = draft a reply to highlighted text
   Ctrl+Cmd+R / .      = read highlighted text aloud / stop
============================================================
DONE
