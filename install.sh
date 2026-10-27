#!/bin/bash
# Installs Vigil for the current user:
#   ~/Applications/Vigil.app, the `vigil` CLI link, the watchdog LaunchAgent, launch at login,
#   and (via sudo, asking for your password once) the narrow sudoers rule and boot-time reset
#   from scripts/install-privileged.sh. Claude Code hooks are separate: `vigil install-hooks`.
#
# Works from a release download (Vigil.app next to this script) or from a source checkout
# (builds build.noindex/Vigil.app first; needs Xcode or the Command Line Tools).
#
#   ./install.sh               first install, or reinstall (skips sudo if the privileged parts exist)
#   ./install.sh --update      update the app only; never runs sudo
#   ./install.sh --privileged  also reinstall the sudoers rule and boot-time reset
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(pwd)
PRIVILEGED=auto
for arg in "$@"; do
    case "$arg" in
        --update) PRIVILEGED=skip ;;
        --privileged) PRIVILEGED=force ;;
        *) echo "unknown option: $arg" >&2; exit 64 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    echo "Run ./install.sh as yourself, not with sudo. It asks for sudo once, for the privileged step." >&2
    exit 1
fi

if [ -x "$ROOT/Vigil.app/Contents/MacOS/vigil" ]; then
    APP_SRC="$ROOT/Vigil.app" # release download
else
    APP_SRC="$ROOT/build.noindex/Vigil.app" # source checkout
    if [ ! -x "$APP_SRC/Contents/MacOS/vigil" ]; then
        command -v swift >/dev/null || { echo "No prebuilt Vigil.app here and no Swift toolchain to build one (xcode-select --install)." >&2; exit 1; }
        ./scripts/build-app.sh
    fi
fi
DEST="$HOME/Applications/Vigil.app"
BIN="$DEST/Contents/MacOS/vigil"
GUI="gui/$(id -u)"

echo "→ Stopping any running Vigil"
if [ -x "$BIN" ]; then "$BIN" quit >/dev/null 2>&1 || true; fi
launchctl bootout "$GUI/local.vigil" 2>/dev/null || true
launchctl bootout "$GUI/local.vigil.watchdog" 2>/dev/null || true

echo "→ Installing $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP_SRC" "$DEST"
# A browser download is quarantined, and Gatekeeper would refuse the ad-hoc signed app.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

CLI=""
for dir in /opt/homebrew/bin /usr/local/bin; do
    if [ -d "$dir" ] && [ -w "$dir" ]; then
        ln -sfn "$BIN" "$dir/vigil"
        CLI="$dir/vigil"
        echo "→ Linked the CLI: $CLI"
        break
    fi
done

if [ "$PRIVILEGED" = auto ] && [ -f /etc/sudoers.d/vigil ] && [ -f /Library/LaunchDaemons/local.vigil.bootreset.plist ]; then
    PRIVILEGED=skip
fi
if [ "$PRIVILEGED" = skip ]; then
    echo "→ Privileged parts already installed; not touching them (./install.sh --privileged redoes them)"
else
    echo "→ Privileged step (sudo, once). It installs this sudoers rule and a boot-time 'pmset -a disablesleep 0':"
    echo "    $(id -un) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    echo "  (the whole script: $ROOT/scripts/install-privileged.sh)"
    sudo /bin/sh "$ROOT/scripts/install-privileged.sh" "$(id -un)"
fi

echo "→ LaunchAgents: watchdog, and the app at login"
"$BIN" setup-agents

echo
"$BIN" doctor || true
echo
echo "Vigil is in the menu bar (the moon; it turns into a sun while it keeps the Mac awake)."
echo "Uninstall any time: ~/Applications/Vigil.app/Contents/Resources/uninstall.sh"
if [ -n "$CLI" ]; then
    echo "Using Claude Code? Add its hooks (shows the diff and asks first): vigil install-hooks"
else
    echo "CLI: $BIN (no Homebrew bin folder to link it into)"
fi
