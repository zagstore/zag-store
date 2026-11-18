# Device tests, phase 7: installed profiles (PR #25) and Zsign branch signing (Zsign-Zag #1)

Status: **PASS. Owner-run on a physical iPhone 15 Pro Max, 18 November 2026; all three tests passed.** Results below.

The canonical IPA (`~/Documents/ZagStore-v1.0.0-build1-iOS-AppTesters.ipa`, `67d1a79b…`) is not replaced. Every test IPA below:
- is Zag Store 1.0.0 (Build 1), bundle `com.cwd43.gu29`, signed for the existing AppTesters certificate;
- is built from branch `claude-device-test-readback` at `7e02da53`, which is #24 with #25 merged in plus the Debug-only screen below;
- is a Release build with the `DEBUG` flag, so it contains the Debug-only screens.

| IPA | Signed by | Size | SHA-256 |
|---|---|---|---|
| **A** `packages/private-test/DEBUG-PROFILES-7e02da53/ZagStore-DEBUG-PROFILES-TEST-AppTesters-7e02da53.ipa` | `codesign`, via a copy of the usual packager (all packager checks pass) | 60,156,314 | `82159314bb81a610206fd843bb56eb9a84bdecc376cb5654f5c4b12cf3445c17` |
| **B** `packages/private-test/ZSIGN-TEST-f34e51a/ZagStore-ZSIGN-BRANCH-ORDINARY-TEST.ipa` | Zsign branch `f34e51a`, ordinary path (p12 and password, as the app's certificate signing uses it) | 60,418,528 | `17484c4d657dfa55d1b214ee757db3cf7f6d11751c3d18f046d74bf451dd81f5` |
| **C** `packages/private-test/ZSIGN-TEST-f34e51a/ZagStore-ZSIGN-BRANCH-STRICT-TEST.ipa` | Zsign branch `f34e51a`, strict path: the private key is a non-extractable key in a throwaway keychain, used only through `SecKeyCreateSignature` | 60,418,528 | `eee600c2a95ddcad6fd24be0c21cd081f93df91c6ad64ed7ebffdc6ee88a86e8` |

The folders are under `~/Documents/ZagStore-claude/`.

## Results (owner-reported, 18 November 2026)

**A: installed profiles, read only (PR #25): pass**
- Four installed profiles were returned, and all four were readable.
- UUID, team, App ID and expiry were available for all four.
- This app's embedded profile was found and matched: **VERIFIED**.
- Control, altered expiry: **MISMATCH**, as expected.
- Control, absent profile: **NOT VERIFIED**, as expected.

**B: Zsign branch, ordinary path (Zsign-Zag #1): pass**
- iOS accepted the installation.
- Zag Store launched and stayed stable; Library, Settings and Sources worked.
- Pairing stayed connected, and the installed-profiles read-back worked.
- AppTesters signing and installation from inside the app succeeded.

**C: Zsign branch, strict path with the Security framework key (Zsign-Zag #1): pass**
- iOS accepted the installation.
- Zag Store launched and stayed stable; Library, Settings and Sources worked.
- Pairing stayed connected, and the installed-profiles read-back worked.
- AppTesters signing and installation from inside the app succeeded.

**Still not tested:** the extension test with per-component profiles. It is blocked (see the end of this document).

## Install by AirDrop (each IPA, one at a time)

Zag Store installs an imported IPA exactly as it is, without re-signing it, when you choose **Install**, not Sign.

1. On the Mac, Finder: open the IPA's folder, right-click the IPA → Share → AirDrop → your iPhone.
2. On the iPhone, accept, and choose **Zag Store** if asked which app to open it with. The IPA appears in **Library** as an imported app.
3. In Library, long-press the imported "Zag Store" → **Install**. Do not choose Sign. Confirm the self-update prompt. Zag Store closes while iOS replaces it.
4. Open Zag Store again. Settings → About should show **1.0.0 (Build 1)**.

Do not update from the Software Update screen during a test, because it would replace the test build.

**Afterwards**, return to your usual build. AirDrop `~/Documents/ZagStore-v1.0.0-build1-iOS-AppTesters.ipa` and install it the same way (or install it from your usual source). Your data stays because the bundle ID is unchanged.

## Test A: installed profiles, read only (PR #25)

Settings → unlock Advanced (as before) → **Installed Profiles (Read Only)** → **Read Installed Profiles**.

| # | Check | Expected |
|---|---|---|
| A1 | Read succeeds with your existing pairing | A list of installed profiles; no prompt to pair again |
| A2 | Each profile shows a shortened UUID, team ID, App ID, expiry and platforms, plus a device **count** | Shown where available. Where something is unreadable, the row says so instead of failing. No device identifiers or profile names are shown. |
| A3 | "Expected (This App)" shows the embedded profile's short UUID, team, App ID and expiry | Matches the AppTesters profile |
| A4 | "Check" for this app | Green: the installed profile matches the embedded one |
| A5 | Controls: altered expiry | Red, mismatch |
| A6 | Controls: absent profile | Unverifiable, not a false match |
| A7 | Read again twice; then the profiles in iOS Settings → General → VPN & Device Management | Same list each time; nothing removed or changed |
| A8 | **Copy Summary** and paste it to me | Only counts and pass/fail results, with no identifiers. Please check it before sending. |
| A9 | Afterwards: install any app with your AppTesters certificate as usual (sign + install) | Works as before (pairing and installation preserved) |

If reading fails, note the exact message shown. It distinguishes unsupported, not paired and device errors.

## Tests B and C: Zsign branch signatures launch (Zsign-Zag #1)

Install B, then C, as above. For each:

| # | Check | Expected |
|---|---|---|
| Z1 | iOS accepts the install | No "Unable to install" or "integrity could not be verified" |
| Z2 | Zag Store launches and stays open | Library, Settings and Sources work |
| Z3 | Features that use entitlements | Pairing status shows connected; Installed Profiles (Read Only) reads profiles (this proves the keychain-sharing and network entitlements) |
| Z4 | Sign and install one small app with your AppTesters certificate | Works (the ordinary signing path inside the app is the pinned Zsign and is unaffected) |

What has already been checked on the Mac for B and C:
- every page hash and special slot;
- both CodeDirectory hashes in the CMS (v1 and v2);
- every sealed resource;
- the CMS signature to Apple Root CA, with a signer listed in the profile;
- entitlements equal to the profile's;
- the embedded profile;
- `codesign --verify --deep --strict` reports them valid.

The launch on the device is the remaining evidence.

## Not testable with this certificate

**Extension test with per-component profiles:** blocked. The AppTesters profile covers the single explicit App ID `com.cwd43.gu29`, so there is no second profile for an extension. It needs either a wildcard or per-extension profiles from the certificate supplier, or the first free-account experiment, where Zag Store creates the App IDs itself. The multi-component strict path is covered by the Zsign branch's 86 local checks with a test authority only.

## Follow-up: device test D (integration build)

**PASS, 18 November 2026.** The integrated build has Zsign `f34e51a` inside the app and the #25 core.
- Install, launch, pairing and Installed Profiles all worked.
- In-app AppTesters signing and installation succeeded for a small IPA and for an IPA with frameworks.

See `PHASE7-INTEGRATION.md`.
