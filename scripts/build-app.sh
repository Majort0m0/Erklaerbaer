#!/bin/bash
# Builds Erklärbär.app (release; formerly Screenkast) and installs it to ~/Applications.
# The executable, bundle id and project format keep the old internal name.
#
# The bundle is assembled and signed in a temporary folder: the project lives in
# ~/Documents, which iCloud Drive syncs, and the file provider attaches Finder info
# to new bundles there - codesign rejects that ("detritus not allowed").
set -euo pipefail
cd "$(dirname "$0")/.."

# Build products outside iCloud as well: in ~/Documents SwiftPM sometimes reports
# "Build complete" without relinking ("unable to attach DB: disk I/O error").
BUILD_DIR="${SCREENKAST_BUILD_DIR:-$HOME/Library/Caches/Screenkast/build}"
swift build -c release --scratch-path "$BUILD_DIR"
BIN="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)/Screenkast"

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi

APP_NAME="Erklärbär"
STAGE="$(mktemp -d)/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Screenkast"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
xattr -cr "$STAGE"

# Sign with the local self-signed certificate "Screenkast Dev" when it exists: its
# designated requirement stays the same across builds, so macOS keeps the screen,
# microphone and camera permissions. Without it the app is signed ad hoc, and every
# rebuild looks like a new app to macOS (permissions have to be granted again).
IDENTITY="${SCREENKAST_SIGN_IDENTITY:-Screenkast Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$STAGE"
  echo "Signiert mit: $IDENTITY"
else
  codesign --force --sign - --timestamp=none "$STAGE"
  echo "Ad-hoc signiert (Zertifikat \"$IDENTITY\" nicht gefunden)"
fi

DEST_DIR="${SCREENKAST_APP_DIR:-$HOME/Applications}"
DEST="$DEST_DIR/$APP_NAME.app"
# The app under its former name (same bundle id) would confuse Launch Services.
rm -rf "$DEST_DIR/Screenkast.app"
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
rm -rf "$(dirname "$STAGE")"
codesign --verify "$DEST"

# Older versions of this script built into ./build (inside iCloud) - remove that copy.
rm -rf build/Screenkast.app

echo "Fertig: $DEST"
