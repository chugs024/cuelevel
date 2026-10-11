#!/bin/zsh
# Assembles CueLevel.app from source.
# Usage: VERSION=1.0.1 BUILD=101 FFMPEG=Engine/ffmpeg Scripts/make-app.sh <output-dir> [--dev]
#   --dev  builds "CueLevel Dev.app" (bundle id local.halllevel.app.dev, own data folder) that never touches the release app's data.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="${1:?output directory}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
DEV=0; [[ "${2:-}" == "--dev" ]] && DEV=1
VERSION="${VERSION:?set VERSION, e.g. 1.0.1}"; BUILD="${BUILD:?set BUILD, an increasing integer}"
FFMPEG="${FFMPEG:-Engine/ffmpeg}"
[[ -x "$FFMPEG" ]] || { echo "✗ No FFmpeg at $FFMPEG (run Scripts/build-ffmpeg-lgpl.sh)"; exit 1; }
NAME=CueLevel; (( DEV )) && NAME="CueLevel Dev"
APP="$OUT/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -parse-as-library -target arm64-apple-macosx13.0 Source/*.swift \
  -o "$APP/Contents/MacOS/CueLevel" -framework SwiftUI -framework AVKit -framework Cocoa
cp Packaging/Info.plist "$APP/Contents/Info.plist"
cp "$FFMPEG" "$APP/Contents/Resources/ffmpeg"
cp Models/speech.rnnn "$APP/Contents/Resources/speech.rnnn"
cp "Models/RNNoise LICENSE.txt" "$APP/Contents/Resources/RNNoise LICENSE.txt"
cp Assets/CueLevel.icns "$APP/Contents/Resources/CueLevel.icns"
NOTICES="$APP/Contents/Resources/Third-party notices"
ditto "Third-party notices" "$NOTICES"
# The GPL imageio-ffmpeg binary is never shipped from this repository; ship the LGPL engine's build record instead.
rm -f "$NOTICES/FFmpeg build and license.txt" "$NOTICES/Provenance.txt" "$NOTICES/imageio-ffmpeg LICENSE.txt"
ENGINE_DIR="$(dirname "$FFMPEG")"
[[ -f "$ENGINE_DIR/BUILD.txt" ]] && cp "$ENGINE_DIR/BUILD.txt" "$NOTICES/FFmpeg build configuration.txt"
[[ -f "$ENGINE_DIR/ffmpeg-7.1.tar.xz.sha256" ]] && cp "$ENGINE_DIR/ffmpeg-7.1.tar.xz.sha256" "$NOTICES/FFmpeg source checksum.txt"
PB=/usr/libexec/PlistBuddy; PLIST="$APP/Contents/Info.plist"
$PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
if (( DEV )); then
  $PB -c "Set :CFBundleIdentifier local.halllevel.app.dev" -c "Set :CFBundleDisplayName CueLevel Dev" "$PLIST"
  $PB -c "Add :CueLevelDataFolder string CueLevel Development" "$PLIST"
fi
codesign --force --options runtime --sign - "$APP/Contents/Resources/ffmpeg"
codesign --force --options runtime --sign - "$APP"
echo "✓ Built $APP ($VERSION, build $BUILD, ad-hoc signed)"
