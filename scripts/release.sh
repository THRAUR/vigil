#!/bin/sh
# Builds the app and packs dist/Vigil.zip for a GitHub release: Vigil.app plus the install and
# uninstall scripts, so installing needs no Xcode. get.sh downloads and runs it.
set -eu
cd "$(dirname "$0")/.."
./scripts/build-app.sh
rm -rf dist
mkdir -p dist/Vigil/scripts
ditto build.noindex/Vigil.app dist/Vigil/Vigil.app
cp install.sh uninstall.sh README.md LICENSE dist/Vigil/
cp scripts/install-privileged.sh scripts/uninstall-privileged.sh dist/Vigil/scripts/
(cd dist && ditto -c -k --norsrc --noextattr --noqtn --keepParent Vigil Vigil.zip)
echo "packed dist/Vigil.zip ($(du -h dist/Vigil.zip | cut -f1))"
