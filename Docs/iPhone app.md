# CueLevel for iPhone and iPad

The same levelling as the Mac app's lossless mode, done entirely on the device.

## How it differs from the Mac app
- **Engine.** iOS can't run the FFmpeg program, so `Mobile/Engine` measures and writes audio with Apple's frameworks:
  - BS.1770-4 / EBU R 128 loudness, true peak, loudness range, momentary and short-term curves (Accelerate);
  - decoding and lossless writing (AVFoundation).
  `Tests/mobile-engine-tests.swift` checks every number against FFmpeg on each build. At the last check:
  - loudness within 0.01–0.08 LU;
  - the momentary curve identical;
  - Even out found the same stretches;
  - levelling was a pure gain change;
  - the video picture was copied bit for bit.
- **Shared code.** `Source/Model.swift`, `Plan.swift`, `ClipGain.swift`, `CueEdit.swift` and `ReferenceLibrary.swift` are compiled into both apps, so the plan, Even out and "already good" rules are the same.
- **Not in the first version:**
  - the clip gain editor (Edit mode);
  - Mark as good (adding references);
  - transcripts;
  - the non-lossless processing modes.
- **Files.**
  - Originals are copied into the app and never changed.
  - Levelled copies go to Files › On My iPhone › CueLevel › Levelled, as `<name>_LVL-18.wav` or `.mov`.

## Building
- `cd Mobile && xcodegen generate` makes `CueLevelMobile.xcodeproj`. The project file is generated, not committed.
- Every push runs **iPhone and iPad app** (`.github/workflows/ios.yml`), which:
  - builds for the simulator;
  - adds a synthesised example show (`Mobile/Scripts/make-demo-cues.sh`);
  - measures and levels it;
  - checks the levelled files with FFmpeg;
  - saves screenshots of every screen as the `iphone-screens` artifact.

## TestFlight (one-time setup)
1. **Create an App Store Connect API key.** App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → **+**.
   - Use **Admin** access, so Xcode can create the distribution certificate and profile itself.
   - Download the .p8 file, which you can only download once.
   - Note the Key ID and the Issuer ID.
2. **Add three repository secrets** in GitHub → chugs024/cuelevel → Settings → Secrets and variables → Actions:
   - `ASC_KEY_ID`: the Key ID
   - `ASC_ISSUER_ID`: the Issuer ID
   - `ASC_KEY_P8`: the whole text of the .p8 file
3. **Register the bundle ID and create the app.**
   - Register bundle ID `com.cuelevel.app` at developer.apple.com → Identifiers.
   - Create the app in App Store Connect → Apps → **+**: platform iOS, that bundle ID, SKU `cuelevel-ios`.
4. **Upload a build.** Run **iPhone and iPad TestFlight** from the Actions tab with a version (for example 1.0.0). The build number is set automatically.
5. **Install it.** The build appears in TestFlight after Apple's processing, usually 10–30 minutes. In App Store Connect → TestFlight, add yourself as an internal tester, then install from the TestFlight app on the phone.
