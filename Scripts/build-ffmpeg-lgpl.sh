#!/bin/zsh
# Builds the LGPL-only FFmpeg 7.1 engine CueLevel ships (Apple silicon, macOS 13+).
# Usage: Scripts/build-ffmpeg-lgpl.sh [output-dir]   (default: Engine/)
# CueLevel never encodes video and uses only FFmpeg's own decoders, filters and its native AAC, FLAC and PCM encoders,
# so no GPL component is needed. The source archive is kept next to the binary for the LGPL source offer.
set -euo pipefail
cd "$(dirname "$0")/.."
VER=7.1
ENGINE="${1:-$PWD/Engine}"; mkdir -p "$ENGINE"; ENGINE="$(cd "$ENGINE" && pwd)"
WORK="$(mktemp -d)"
[[ -f "$ENGINE/ffmpeg-$VER.tar.xz" ]] || curl -fsSL -o "$ENGINE/ffmpeg-$VER.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
shasum -a 256 "$ENGINE/ffmpeg-$VER.tar.xz" > "$ENGINE/ffmpeg-$VER.tar.xz.sha256"
tar -xf "$ENGINE/ffmpeg-$VER.tar.xz" -C "$WORK"
cd "$WORK/ffmpeg-$VER"
CONFIG=(--arch=arm64 --target-os=darwin --cc=clang --extra-cflags=-mmacosx-version-min=13.0 --extra-ldflags=-mmacosx-version-min=13.0
        --enable-static --disable-shared --disable-gpl --disable-nonfree --disable-autodetect --enable-zlib
        --disable-doc --disable-ffplay --disable-ffprobe --disable-network --disable-debug)
./configure "${CONFIG[@]}" >/dev/null
make -j"$(sysctl -n hw.ncpu)" ffmpeg >/dev/null
cp ffmpeg "$ENGINE/ffmpeg"
print -r -- "FFmpeg $VER built $(date -u +%Y-%m-%dT%H:%MZ) with: ./configure ${CONFIG[*]}" > "$ENGINE/BUILD.txt"
cd "$ENGINE"; rm -rf "$WORK"
./ffmpeg -hide_banner -L | grep -q "Lesser General Public" || { echo "✗ Not an LGPL build"; exit 1; }
./ffmpeg -hide_banner -buildconf | grep -q -- "--enable-gpl" && { echo "✗ GPL enabled"; exit 1; }
for f in loudnorm dynaudnorm acompressor afftdn arnndn adeclip adynamicequalizer deesser equalizer highpass treble astats ebur128 ametadata alimiter aresample volume aformat apad atrim asetpts anull; do
  ./ffmpeg -hide_banner -h filter=$f 2>&1 | grep -q "Unknown filter" && { echo "✗ Missing filter $f"; exit 1; }
done
for e in aac flac pcm_s24le pcm_f32le; do ./ffmpeg -hide_banner -h encoder=$e 2>&1 | grep -q "not recognized" && { echo "✗ Missing encoder $e"; exit 1; }; done
echo "✓ LGPL engine ready: $ENGINE/ffmpeg"
