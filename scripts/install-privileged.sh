#!/bin/sh
# Vigil's only privileged step. Run with sudo (install.sh does that for you).
# It installs exactly two root-owned files and nothing else:
#
#   /etc/sudoers.d/vigil
#       lets USER run "/usr/bin/pmset -a disablesleep 0" and "/usr/bin/pmset -a disablesleep 1"
#       without a password. sudo matches the arguments exactly, so no other pmset call is allowed.
#   /Library/LaunchDaemons/local.vigil.bootreset.plist
#       runs "/usr/bin/pmset -a disablesleep 0" once at every boot, so a reboot always clears the flag.
#
# Usage: sudo sh scripts/install-privileged.sh <your-user-name>
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin

[ "$(id -u)" -eq 0 ] || { echo "run this with sudo" >&2; exit 1; }
USER_NAME="${1:-${SUDO_USER:-}}"
case "$USER_NAME" in ""|root) echo "usage: sudo sh $0 <your-user-name>" >&2; exit 1 ;; esac
case "$USER_NAME" in *[!A-Za-z0-9._-]*) echo "unexpected characters in user name: $USER_NAME" >&2; exit 1 ;; esac
id -u "$USER_NAME" >/dev/null 2>&1 || { echo "no such user: $USER_NAME" >&2; exit 1; }

# 1. sudoers rule. Validate it on its own, install it, then validate the whole configuration.
#    The file name has no dot: sudo skips files in sudoers.d whose names contain one.
SUDOERS=/etc/sudoers.d/vigil
TMP=$(mktemp /tmp/vigil-sudoers.XXXXXX)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
# Installed by Vigil. Lets $USER_NAME switch the kernel SleepDisabled flag, and nothing else.
# Remove with: sudo rm $SUDOERS
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
EOF
visudo -cf "$TMP" >/dev/null || { echo "the generated rule didn't validate; nothing installed" >&2; exit 1; }
install -m 0440 -o root -g wheel "$TMP" "$SUDOERS"
if ! visudo -c >/dev/null 2>&1; then
    rm -f "$SUDOERS"
    echo "sudo's configuration didn't validate with the rule, so it was removed again" >&2
    exit 1
fi
echo "  installed $SUDOERS"

# 2. Boot-time reset.
PLIST=/Library/LaunchDaemons/local.vigil.bootreset.plist
cat > "$PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>local.vigil.bootreset</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/pmset</string>
		<string>-a</string>
		<string>disablesleep</string>
		<string>0</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 0644 "$PLIST"
launchctl bootout system/local.vigil.bootreset 2>/dev/null || true
launchctl bootstrap system "$PLIST" 2>/dev/null || echo "  (launchd will load it at the next boot)"
echo "  installed $PLIST"

# 3. Prove the rule works for the user without a password (setting 0 is a no-op right now).
if sudo -u "$USER_NAME" /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0; then
    echo "  verified: $USER_NAME can switch SleepDisabled without a password"
else
    echo "the rule is installed, but 'sudo -n pmset' still asks $USER_NAME for a password" >&2
    exit 1
fi
