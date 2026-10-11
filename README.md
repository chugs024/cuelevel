# CueLevel

Lossless loudness levelling for event playback (macOS 13+, Apple silicon). Private source.

| Folder | What it holds |
|---|---|
| `Source/` | The app (SwiftUI, built with `swiftc`; no Xcode project) |
| `Tests/` | Engine, reference, lossless, catalogue and update tests |
| `Scripts/` | FFmpeg (LGPL) build, app assembly, tests, signing/notarisation, appcast |
| `Reference Library/` | Measurements of approved reference cues (never the recordings) |
| `Assets/`, `Models/`, `Third-party notices/`, `Packaging/` | Icon, RNNoise model, licences, Info.plist template |
| `Docs/` | Read me (ships in the DMG), release readiness, development notes, [Releasing](Docs/Releasing.md) |

## Shipping an update
Every push to `main` is built and tested on a GitHub Mac (**Build and test**). To release, run the **Release** workflow
(Actions → Release → Run workflow) with a version number and notes. It signs, notarises and publishes to
[`chugs024/cuelevel-updates`](https://github.com/chugs024/cuelevel-updates); installed copies offer the update within
12 hours (or at once via CueLevel → Check for Updates…). One-time setup: [Docs/Releasing.md](Docs/Releasing.md).

## Local build on a Mac
```sh
Scripts/build-ffmpeg-lgpl.sh            # once, ~5 min → Engine/ffmpeg
FFMPEG=Engine/ffmpeg Scripts/run-tests.sh
VERSION=1.1.0 BUILD=100 FFMPEG=Engine/ffmpeg Scripts/make-app.sh build --dev
```
