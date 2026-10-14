#!/bin/zsh
# Type-checks the whole app and runs the engine/reference/lossless tests against an FFmpeg build.
# Usage: FFMPEG=Engine/ffmpeg Scripts/run-tests.sh
# Works in a scratch folder that mirrors the handoff layout the tests expect; the repository is not modified.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
FFMPEG="${FFMPEG:-Engine/ffmpeg}"; FFMPEG="$(cd "$(dirname "$FFMPEG")" && pwd)/$(basename "$FFMPEG")"
[[ -x "$FFMPEG" ]] || { echo "✗ No FFmpeg at $FFMPEG"; exit 1; }
export CUELEVEL_FFMPEG="$FFMPEG"
T=(-parse-as-library -target arm64-apple-macosx13.0)
FW=(-framework SwiftUI -framework AVKit -framework Cocoa -framework Speech)
echo "== Type-checking the full app"
xcrun swiftc -typecheck $T Source/*.swift
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/outputs/CueLevel" "$SCRATCH/work/v07-tests"
cp -R "Reference Library" "$SCRATCH/outputs/CueLevel/Reference Library"
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i "testsrc2=s=640x360:r=25:d=6" -f lavfi -i "sine=frequency=330:sample_rate=48000:duration=6" \
  -af "volume=-14dB" -c:v mpeg4 -q:v 5 -c:a aac -b:a 192k -shortest "$SCRATCH/work/test.mp4"
echo "== Engine, reference, lossless and update tests"
LIB=(Source/AudioEngine.swift Source/ClipGain.swift Source/CueEdit.swift Source/Transcript.swift Source/ReferenceLibrary.swift Source/Workspace.swift Source/Updater.swift Source/Plan.swift)
xcrun swiftc -O $T $LIB Tests/tests.swift $FW -o "$SCRATCH/cuelevel-tests"
(cd "$SCRATCH" && ./cuelevel-tests)
echo "ALL CHECKS PASSED"
