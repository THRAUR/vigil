#!/bin/bash
# One-line install of the latest Vigil release:
#   curl -fsSL https://raw.githubusercontent.com/THRAUR/vigil/main/get.sh | bash
# Downloads Vigil.zip from the latest GitHub release and runs its install.sh, which asks for your
# password once (for the sudoers rule that lets Vigil switch `pmset -a disablesleep 0|1`).
set -euo pipefail
REPO="${VIGIL_REPO:-THRAUR/vigil}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/vigil.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
echo "→ Downloading the latest Vigil release from github.com/$REPO"
curl -fsSL "https://github.com/$REPO/releases/latest/download/Vigil.zip" -o "$TMP/Vigil.zip"
ditto -x -k "$TMP/Vigil.zip" "$TMP"
"$TMP/Vigil/install.sh" "$@" </dev/tty
