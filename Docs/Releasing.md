# Releasing CueLevel updates

## How it works
1. Code lives here (private). Each push to `main` runs **Build and test** on a GitHub-hosted Mac.
2. **Release** (run from the Actions tab, or ask Claude) builds the LGPL FFmpeg engine (cached), runs the tests, builds
   `CueLevel.app`, signs it with the Developer ID certificate, notarises and staples the app and DMG, then publishes:
   - the DMG as a GitHub Release on the public `chugs024/cuelevel-updates` repository, and
   - `appcast.json` (version, build, download URL, SHA-256, notes) on that repository's `main` branch.
3. CueLevel reads `https://raw.githubusercontent.com/chugs024/cuelevel-updates/main/appcast.json` at launch (at most every
   6 hours) and twice a day. If the build is newer, it shows "CueLevel x.y.z is ready". Installing:
   downloads the DMG → checks the SHA-256 → checks the app is signed by team 327ABFB3W2 → Gatekeeper assessment →
   swaps the app (the old copy goes to the Trash) → reopens. Anything that fails a check is not installed.
   Users can turn automatic checks off in About CueLevel; CueLevel → Check for Updates… always works.

Only measurements and code are in this repository. Reference recordings, DMGs and the GPL imageio-ffmpeg binary are
never committed (see `.gitignore`).

## One-time setup: repository secrets
Settings → Secrets and variables → Actions → New repository secret, in **chugs024/cuelevel**:

| Secret | What to put in it |
|---|---|
| `MACOS_CERTIFICATE_P12` | Your "Developer ID Application" certificate **with its private key**, exported from Keychain Access as .p12, then base64: `base64 -i DeveloperID.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you chose when exporting the .p12 |
| `NOTARY_APPLE_ID` | The Apple ID email of the developer account |
| `NOTARY_PASSWORD` | An app-specific password from account.apple.com → Sign-In and Security → App-Specific Passwords |
| `UPDATES_TOKEN` | A fine-grained personal access token: github.com → Settings → Developer settings → Fine-grained tokens → Generate. Repository access: only `chugs024/cuelevel-updates`. Permissions: **Contents: Read and write**. |

Instead of the Apple ID pair you can use an App Store Connect API key: `NOTARY_KEY_P8` (base64 of the .p8),
`NOTARY_KEY_ID`, `NOTARY_ISSUER`.

## Version numbers
Use `MAJOR.MINOR.PATCH` (e.g. 1.1.0). The build number is set automatically (100 + run number) and always increases,
which is what the update check compares.
