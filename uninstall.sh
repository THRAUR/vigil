#!/bin/bash
# Removes Vigil: quits the app (it clears SleepDisabled on the way out), removes both
# LaunchAgents, the Claude Code hooks (shows the diff and asks), then, via sudo, the sudoers rule
# and the boot-time reset, and finally the app and the CLI link. Pass --purge to also delete state
# and logs. A copy of this script ships inside the app:
#   ~/Applications/Vigil.app/Contents/Resources/uninstall.sh
set -uo pipefail
cd "$(dirname "$0")"
ROOT=$(pwd)

if [ "$(id -u)" -eq 0 ]; then
    echo "Run uninstall.sh as yourself, not with sudo. It asks for sudo once." >&2
    exit 1
fi

DEST="$HOME/Applications/Vigil.app"
BIN="$DEST/Contents/MacOS/vigil"
GUI="gui/$(id -u)"

echo "→ Quitting Vigil"
if [ -x "$BIN" ]; then "$BIN" quit || true; fi
launchctl bootout "$GUI/local.vigil" 2>/dev/null || true
launchctl bootout "$GUI/local.vigil.watchdog" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.vigil.plist" "$HOME/Library/LaunchAgents/local.vigil.watchdog.plist"

if [ -x "$BIN" ] && [ -f "$HOME/.claude/settings.json" ]; then
    echo "→ Claude Code hooks"
    "$BIN" uninstall-hooks || true
fi

# Before the app goes: when this script runs from inside the app, so does the privileged one.
echo "→ Privileged step (sudo): remove the sudoers rule and the boot-time reset"
sudo /bin/sh "$ROOT/scripts/uninstall-privileged.sh"

for link in /opt/homebrew/bin/vigil /usr/local/bin/vigil; do
    if [ -L "$link" ]; then rm -f "$link"; fi
done
rm -rf "$DEST"
echo "→ Removed the app and the CLI link"

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$HOME/Library/Application Support/Vigil" "$HOME/Library/Logs/Vigil"
    echo "→ Removed state and logs"
fi
if pmset -g | grep -Eq '^ *SleepDisabled[[:space:]]+1'; then FLAG=1; else FLAG=0; fi
echo "Vigil is uninstalled. SleepDisabled=$FLAG"
