#!/bin/zsh
# Developer ID signing → notarise + staple app → DMG → notarise + staple DMG → Gatekeeper check.
# Usage: SIGN_IDENTITY="Developer ID Application: …" Scripts/sign-and-package.sh <dir containing CueLevel.app> <version>
# Notary credentials (one of):
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER   (App Store Connect API key, .p8)
#   NOTARY_APPLE_ID + NOTARY_PASSWORD + NOTARY_TEAM   (Apple ID + app-specific password)
#   NOTARY_PROFILE                                    (keychain profile from `xcrun notarytool store-credentials`)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(cd "${1:?folder}" && pwd)"; VERSION="${2:?version}"
APP="$OUT/CueLevel.app"; DMG="$OUT/CueLevel-$VERSION.dmg"
IDENTITY="${SIGN_IDENTITY:?SIGN_IDENTITY}"
if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then NOTARY=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then NOTARY=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "${NOTARY_TEAM:-327ABFB3W2}")
else NOTARY=(--keychain-profile "${NOTARY_PROFILE:-CueLevel-notary}"); fi
[[ -e "$DMG" ]] && { echo "✗ $DMG already exists; release files are never overwritten."; exit 1; }

echo "== Sign"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/ffmpeg"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "== Notarise app"
ZIP="$OUT/notarise.zip"; ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "${NOTARY[@]}" --wait --timeout 45m
xcrun stapler staple "$APP"; rm -f "$ZIP"

echo "== DMG"
STAGE="$OUT/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/CueLevel.app"; ln -s /Applications "$STAGE/Applications"
cp "Docs/Read me.txt" "$STAGE/Read me.txt"
hdiutil create -volname "CueLevel $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "== Notarise DMG"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait --timeout 45m
xcrun stapler staple "$DMG"

echo "== Verify"
spctl -a -t open --context context:primary-signature -vv "$DMG"
MOUNT="$(mktemp -d)"; hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
spctl -a -vv "$MOUNT/CueLevel.app"
# Apple's ticket lookup occasionally drops the connection; retry a few times before failing.
for attempt in 1 2 3 4 5; do xcrun stapler validate "$MOUNT/CueLevel.app" && break; [[ $attempt == 5 ]] && exit 1; sleep $((attempt * 10)); done
codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[subject.OU] = "327ABFB3W2"' "$MOUNT/CueLevel.app"
hdiutil detach "$MOUNT" >/dev/null
echo "✓ $DMG"
