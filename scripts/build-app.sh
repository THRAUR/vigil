#!/bin/sh
# Builds build.noindex/Vigil.app: one release binary in an LSUIElement bundle, ad-hoc signed.
# The ".noindex" folder keeps Spotlight (and so Finder search and the Apps launcher) from listing
# this staging copy next to the installed ~/Applications/Vigil.app.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/VigilCore/Paths.swift)
swift build -c release --product vigil
BIN="$(swift build -c release --show-bin-path)/vigil"
APP=build.noindex/Vigil.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/vigil"
sed "s/@VERSION@/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/Vigil.icns "$APP/Contents/Resources/Vigil.icns"
# The uninstaller ships inside the app, so a release install can always remove itself.
mkdir -p "$APP/Contents/Resources/scripts"
cp uninstall.sh "$APP/Contents/Resources/uninstall.sh"
cp scripts/uninstall-privileged.sh "$APP/Contents/Resources/scripts/uninstall-privileged.sh"
codesign --force --sign - --identifier local.vigil "$APP"
codesign --verify --strict "$APP"
# Never let the staging copy register as an app.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
echo "built $APP ($VERSION, $(du -sh "$APP" | cut -f1))"
