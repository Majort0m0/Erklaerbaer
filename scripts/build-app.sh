#!/bin/bash
# Builds Erklärbär.app (release; formerly Screenkast) and installs it to /Applications.
# The executable, bundle id and project format keep the old internal name.
#
# With Xcode and an Apple Developer team the app gets the camera "Erklärbär" for meetings: a camera
# extension (VirtualCamera/, built with Xcode, which also creates the provisioning profiles) inside
# Contents/Library/SystemExtensions. macOS installs camera extensions only from apps in /Applications.
# Also the microphone "Erklärbär": an audio driver (VirtualCamera/Audio) in Contents/Library/Audio.
# Without Xcode or team (or with SCREENKAST_NO_CAMERA=1) the app is built as before, without the camera,
# signed with the local certificate "Screenkast Dev" or ad hoc.
#
# NOTE: A build with the camera is signed for development: it only starts on Macs registered in the
# team. Builds for others (GitHub releases) must not contain it until a Developer ID build exists:
#   SCREENKAST_ZIP=~/Desktop/Erklaerbaer-<version>-macOS.zip scripts/build-app.sh
# builds without camera and microphone and writes only the zip: nothing is installed or removed.
#
# The bundle is assembled and signed in a temporary folder: the project lives in
# ~/Documents, which iCloud Drive syncs, and the file provider attaches Finder info
# to new bundles there - codesign rejects that ("detritus not allowed").
set -euo pipefail
cd "$(dirname "$0")/.."

# Build products outside iCloud as well: in ~/Documents SwiftPM sometimes reports
# "Build complete" without relinking ("unable to attach DB: disk I/O error").
CACHE="$HOME/Library/Caches/Screenkast"
BUILD_DIR="${SCREENKAST_BUILD_DIR:-$CACHE/build}"
swift build -c release --scratch-path "$BUILD_DIR"
BIN="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)/Screenkast"

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi

# --- Camera extension (Xcode signs it and creates the profiles with the team's account) ---
ZIP="${SCREENKAST_ZIP:-}"
if [ -n "$ZIP" ]; then SCREENKAST_NO_CAMERA=1; fi
TEAM="${SCREENKAST_TEAM:-NX325K9BL8}"
EXT_ID="local.screenkast.app.camera"
XC_DIR="$CACHE/xcode"
WITH_CAMERA=0
if [ "${SCREENKAST_NO_CAMERA:-0}" != 1 ] && xcodebuild -version >/dev/null 2>&1 \
   && security find-identity -v -p codesigning | grep -q "Apple Development"; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  # Camera and driver numbers follow only their own sources, not the app's version: the app replaces
  # an installed camera (and asks for the password for the driver) only when that part changed.
  # The fixed "23" is the app build they were introduced with; it only keeps the numbers looking alike.
  SERIES=23
  # The extension's build number follows its sources. Raising VirtualCamera/Extension/revision.txt forces a new one: when
  # macOS replaced a camera that was in use, it sometimes does not start the new one; installing
  # another version while none runs (or a restart of the Mac) fixes that.
  HASH=$(cat VirtualCamera/Extension/*.swift VirtualCamera/Extension/Info.plist VirtualCamera/Extension/*.entitlements \
           VirtualCamera/Extension/revision.txt Sources/Screenkast/Live/VirtualCameraIDs.swift | shasum | cut -c1-6)
  CAMERA_BUILD="$SERIES.$((16#$HASH))"
  # The microphone driver likewise: the app offers to update an installed one only when it changed.
  AUDIO_HASH=$(cat VirtualCamera/Audio/*.c VirtualCamera/Audio/Info.plist | shasum | cut -c1-6)
  AUDIO_BUILD="$SERIES.$((16#$AUDIO_HASH))"
  rm -rf "$XC_DIR/products"
  if xcodebuild -project VirtualCamera/VirtualCamera.xcodeproj -alltargets -configuration Release -quiet \
       -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
       SYMROOT="$XC_DIR/products" OBJROOT="$XC_DIR/intermediates" \
       MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$CAMERA_BUILD" AUDIO_BUILD="$AUDIO_BUILD"; then
    WITH_CAMERA=1
  else
    echo "Die Kamera-Erweiterung ließ sich nicht bauen - die App entsteht ohne sie." >&2
  fi
fi

APP_NAME="Erklärbär"
WORK="$(mktemp -d)"
STAGE="$WORK/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Screenkast"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

if [ "$WITH_CAMERA" = 1 ]; then
  PRODUCTS="$XC_DIR/products/Release"
  HOST="$PRODUCTS/ProfileHost.app"
  mkdir -p "$STAGE/Contents/Library/SystemExtensions"
  ditto "$PRODUCTS/$EXT_ID.systemextension" "$STAGE/Contents/Library/SystemExtensions/$EXT_ID.systemextension"
  # The microphone driver: the app copies it to /Library/Audio/Plug-Ins/HAL when asked to.
  mkdir -p "$STAGE/Contents/Library/Audio"
  ditto "$PRODUCTS/ErklaerbaerAudio.driver" "$STAGE/Contents/Library/Audio/ErklaerbaerAudio.driver"
  # The stand-in app has the bundle id of Erklärbär: its profile and entitlements are the app's.
  cp "$HOST/Contents/embedded.provisionprofile" "$STAGE/Contents/embedded.provisionprofile"
  codesign -d --entitlements - --xml "$HOST" > "$WORK/entitlements.plist" 2>/dev/null
  # Sign with exactly the certificate Xcode used for the profile.
  (cd "$WORK" && codesign -d --extract-certificates "$HOST" 2>/dev/null)
  IDENTITY=$(openssl x509 -inform DER -in "$WORK/codesign0" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
  xattr -cr "$STAGE"
  codesign --force --sign "$IDENTITY" --entitlements "$WORK/entitlements.plist" --generate-entitlement-der --timestamp=none "$STAGE"
  echo "Signiert mit: $(openssl x509 -inform DER -in "$WORK/codesign0" -noout -subject | sed 's/.*CN=//; s/,.*//') (mit Kamera „Erklärbär“)"
  DEFAULT_DIR="/Applications"
else
  xattr -cr "$STAGE"
  # Sign with the local self-signed certificate "Screenkast Dev" when it exists: its
  # designated requirement stays the same across builds, so macOS keeps the screen,
  # microphone and camera permissions. Without it the app is signed ad hoc, and every
  # rebuild looks like a new app to macOS (permissions have to be granted again).
  IDENTITY="${SCREENKAST_SIGN_IDENTITY:-Screenkast Dev}"
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$STAGE"
    echo "Signiert mit: $IDENTITY (ohne Kamera)"
  else
    codesign --force --sign - --timestamp=none "$STAGE"
    echo "Ad-hoc signiert (Zertifikat \"$IDENTITY\" nicht gefunden, ohne Kamera)"
  fi
  DEFAULT_DIR="$HOME/Applications"
fi

if [ -n "$ZIP" ]; then
  codesign --verify --strict "$STAGE"
  mkdir -p "$(dirname "$ZIP")"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$STAGE" "$ZIP"
  rm -rf "$WORK"
  echo "Fertig (nicht installiert): $ZIP"
  exit 0
fi

DEST_DIR="${SCREENKAST_APP_DIR:-$DEFAULT_DIR}"
DEST="$DEST_DIR/$APP_NAME.app"
mkdir -p "$DEST_DIR"
DEST_NFD=$(printf '%s' "$DEST" | iconv -f UTF-8 -t UTF-8-MAC)
if pgrep -f "$DEST/Contents/MacOS/" >/dev/null || pgrep -f "$DEST_NFD/Contents/MacOS/" >/dev/null; then
  echo "Hinweis: Erklärbär läuft gerade - nach dem Installieren bitte neu starten." >&2
fi
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
rm -rf "$WORK"
codesign --verify --strict "$DEST"

# Only one copy of the app may stay installed (same bundle id confuses Launch Services): the app under
# its former name, and the copy in the other Applications folder.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for OLD in "$HOME/Applications/Screenkast.app" "/Applications/Screenkast.app" "$HOME/Applications/$APP_NAME.app" "/Applications/$APP_NAME.app"; do
  if [ "$OLD" != "$DEST" ] && [ -d "$OLD" ]; then
    # Process paths carry "ä" decomposed (a + combining diaeresis): look for both spellings.
    OLD_NFD=$(printf '%s' "$OLD" | iconv -f UTF-8 -t UTF-8-MAC)
    if pgrep -f "$OLD/Contents/MacOS/" >/dev/null || pgrep -f "$OLD_NFD/Contents/MacOS/" >/dev/null; then
      echo "Alte Kopie läuft noch und bleibt vorerst: $OLD (nach dem Beenden das Skript erneut starten oder die Kopie löschen)" >&2
      continue
    fi
    "$LSREGISTER" -u "$OLD" 2>/dev/null || true
    rm -rf "$OLD"
    echo "Alte Kopie entfernt: $OLD"
  fi
done
"$LSREGISTER" -f "$DEST" 2>/dev/null || true

# Older versions of this script built into ./build (inside iCloud) - remove that copy.
rm -rf build/Screenkast.app

echo "Fertig: $DEST"
