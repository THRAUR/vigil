#!/bin/sh
# Undoes install-privileged.sh: clears the flag, removes the boot-time reset and the sudoers rule.
# Usage: sudo sh scripts/uninstall-privileged.sh
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
[ "$(id -u)" -eq 0 ] || { echo "run this with sudo" >&2; exit 1; }

pmset -a disablesleep 0
launchctl bootout system/local.vigil.bootreset 2>/dev/null || true
rm -f /Library/LaunchDaemons/local.vigil.bootreset.plist
rm -f /etc/sudoers.d/vigil
echo "  removed /etc/sudoers.d/vigil and the boot-time reset; SleepDisabled is 0"
