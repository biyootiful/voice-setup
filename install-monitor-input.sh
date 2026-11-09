#!/usr/bin/env bash
# Set up only the ⌃⌘I monitor input switch, on a Mac that doesn't run the rest
# of voice-setup (e.g. the second computer sharing the monitor). Idempotent.
#
#   ./install-monitor-input.sh [THIS_INPUT OTHER_INPUT]
#
# THIS_INPUT is the monitor input this Mac is plugged into, OTHER_INPUT the
# other computer's (DisplayPort 1 = 15, DP 2 = 16, HDMI 1 = 17, HDMI 2 = 18,
# USB-C = 27). E.g. this Mac on DisplayPort, the other on HDMI 1:
#   ./install-monitor-input.sh 15 17
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BREW="/opt/homebrew/bin/brew"
[[ -x "$BREW" ]] || { echo "Homebrew (Apple Silicon) not found at /opt/homebrew. Install it from https://brew.sh first."; exit 1; }
[[ $# -eq 0 || $# -eq 2 ]] || { sed -n '2,10p' "$0"; exit 1; }

echo "==> Installing m1ddc (+ Hammerspoon if missing)"
arch -arm64 "$BREW" install m1ddc
[[ -d /Applications/Hammerspoon.app ]] || arch -arm64 "$BREW" install --cask hammerspoon

echo "==> Installing ~/.hammerspoon/monitor-input.lua"
mkdir -p "$HOME/.hammerspoon" "$HOME/.config/voice-setup"
cp "$HERE/hammerspoon/monitor-input.lua" "$HOME/.hammerspoon/monitor-input.lua"
INIT="$HOME/.hammerspoon/init.lua"
LOAD='dofile(os.getenv("HOME") .. "/.hammerspoon/monitor-input.lua")'
if [[ ! -f "$INIT" ]]; then
  printf 'hs.autoLaunch(true)   -- start Hammerspoon at login\n%s\n' "$LOAD" > "$INIT"
elif ! grep -q 'monitor-input.lua' "$INIT"; then
  printf '\n%s\n' "$LOAD" >> "$INIT"
fi

CONF="$HOME/.config/voice-setup/monitor-input.conf"
if [[ $# -eq 2 ]]; then
  [[ -f "$CONF" ]] && cp "$CONF" "$CONF.bak.$(date +%s)"
  printf '# Monitor input switch (⌃⌘I). See config/monitor-input.conf.example.\nTHIS_INPUT=%s\nOTHER_INPUT=%s\n' "$1" "$2" > "$CONF"
elif [[ ! -f "$CONF" ]]; then
  cp "$HERE/config/monitor-input.conf.example" "$CONF"
  echo "    Set THIS_INPUT + OTHER_INPUT in $CONF"
fi

echo "==> Monitor currently reports input: $(/opt/homebrew/bin/m1ddc get input 2>&1 || true)"
open -a Hammerspoon
echo "Done. If Hammerspoon was already running, click its menu-bar icon → Reload Config."
echo "Then ⌃⌘I on this Mac's keyboard sends the monitor to the other computer."
