# Phase 7 integration: RPPairing PR #25 and Zsign-Zag PR #1

Status 18 November 2026: **integrated and validated on branch `claude-phase7-integration`. Device tests A–D passed. Merges approved by the owner with safeguards; nothing deployed or published.** The canonical IPA is unchanged (`67d1a79b…`).

## What the branch contains

| Commit | Content |
|---|---|
| `21561ef1` | PR #24 head: free-account work and the phase 7 device results |
| `9552a881` | Merge of `claude-device-test-readback` (`7e02da53`): PR #25 (`25cdc49a`, the read-only installed-profile reader) and the Debug-only "Installed Profiles (Read Only)" screen, exactly as device-tested in A |
| `73056a49` | Zsign pointer `ab57916` → `f34e51a` (Zsign-Zag #1, as device-tested in B and C) |
| `164af7ff` | Release scan: Zsign's own `signComponents` is expected now. The app's strict caller and the read-back screen must be absent. |
| `70b38ed2` | Device-link guard: allows exactly #25's three additive blocks in `ZagRPPairingCore.swift` |
| `05ece730` | Signing and morph guards accept exactly the reviewed Zsign commit and #25 files. Lifecycle tests sign test certificates through Zsign's strict entry point. The ordinary path is checked to refuse a fake "WWDR" authority. |

## Validation

| Check | Result |
|---|---|
| All 44 `scripts/test-zag-*.sh` suites, run sequentially on `05ece730` | **44 pass** |
| Package guard (`test-zag-package-guard.sh`) with its real arguments: Release app and first-launch test app | **15 pass**. The canonical IPA and the packager are untouched; the keychain list is restored. |
| Zsign branch suite (86 strict checks, 3 DER comparisons with `codesign`, 14 integration checks) | Pass |
| Free-account signing and lifecycle (92) | Pass (see "Compatibility" for what changed) |
| Release build (`DSTROOT` install, no `DEBUG`) | Succeeds. The release scan is clean: no simulation, strict caller or read-back screen. |
| Real AppTesters certificate on the integrated app (`test-zag-zsign-real-certificate.sh`, Zsign `f34e51a` as pinned) | Ordinary path (as `ZsignHandler`), strict path (non-extractable keychain key) and certificate import all pass. The CMS verifies to Apple Root CA, and `codesign --verify --deep --strict` reports valid. |
| RPPairing core rebuilt from the branch (`build-rust.sh`) | Exports `zag_installed_profiles`. The header is identical to the device-tested #25 build. |
| Merge into `main` (`738c3325`) | Clean, no conflicts. Zsign-Zag #1 fast-forwards onto Zsign-Zag `main` (`ab57916` + 5). |

**Extension scenarios stay blocked:**
- `ZagFreeAccountSigningAdapter` refuses an app with extensions before signing (`extensionsNeedPerBundleSigning`), checked in the suite.
- Zsign's strict path refuses Watch apps, App Clips, XPC services, nested apps and extensions without a profile.
- No per-component profile test has been possible yet.

## Device test D: PASS (owner, iPhone 15 Pro Max, 18 November 2026)

All five checks passed:
- Zag Store installed and launched.
- The existing RPPairing connection stayed functional.
- Installed Profiles (Read Only) worked correctly.
- **A small IPA signed and installed with the AppTesters certificate through the integrated in-app Zsign.**
- **A second IPA containing frameworks also signed and installed.**

This confirms Zsign `f34e51a` inside Zag Store on physical hardware, including an app with frameworks.

## Device test D: the procedure as run

The integrated build has Zsign `f34e51a` *inside* the app and the rebuilt #25 core.
- In B and C only the outer signature came from the new Zsign. The in-app AppTesters signing still used the old pinned Zsign.
- D therefore tests the in-app signing path that would ship.

- **IPA D:** `packages/private-test/INTEGRATION-05ece730/ZagStore-INTEGRATION-TEST-AppTesters-05ece730.ipa`
  - 60,181,049 bytes
  - SHA-256 `0e70dabdcec380096a94e2eac2940acd978525071caa34c12751d10fb459718e`
  - Zag Store 1.0.0 (Build 1), `com.cwd43.gu29`, Debug-flag build, packaged by a packager copy (all checks pass)
- **Install:** the same AirDrop procedure as `DEVICE-TEST-PHASE7.md` (Library → long-press → **Install**, not Sign).

| # | Check | Expected |
|---|---|---|
| D1 | Install and launch | Accepted; stable; Library, Settings and Sources work |
| D2 | Pairing | Still connected |
| D3 | Installed Profiles (Read Only) → Read, then the controls | As in A: VERIFIED, MISMATCH, NOT VERIFIED |
| D4 | **Sign and install one app with the AppTesters certificate, inside Zag Store** | Signs with the integrated Zsign, installs and launches. This is the new evidence. |
| D5 | Sign and install a second, different app (with frameworks if you have one) | Same |
| D6 | Import the AppTesters certificate again in the certificates screen, if convenient | Accepted as before |
| D7 | Afterwards | Reinstall the canonical IPA |

## Compatibility concerns

1. **Stricter ordinary signing (intended).** With Zsign `f34e51a`, the existing AppTesters path:
   - accepts only certificates cryptographically issued by Apple WWDR (G3 or the original), not just WWDR-named ones;
   - fails a bundle with an unsignable library instead of reporting success.

   Real AppTesters signing passes on the Mac. D4 and D5 confirm it on the device. Certificates from unofficial sources that merely carry Apple's issuer name would now be refused, which is intended.
2. **Signature format changes.** DER entitlements and `CDHashes2` now match `codesign`, so macOS verifies Zag Store's signatures. iOS accepted both the old and the new format (B and C).
3. **The RPPairing binary is a local, ignored artifact.** Merging #25 requires rebuilding `RPPairingCore` with `build-rust.sh` before the next release build. Otherwise the app fails to link `zag_installed_profiles`. A release built from an old artifact cannot silently ship without it.
4. **Test coverage moved, not lost.** The free-account lifecycle tests now sign through Zsign's strict entry point with an explicit test authority. The ordinary path cannot be given a test authority, so its positive coverage comes from the real-certificate harness, which needs the owner's certificate and does not run in CI.
5. **Debug-only screen.** "Installed Profiles (Read Only)" is compiled only with `DEBUG`. The release scan enforces its absence.
6. **Live services stay off.** Live sign-in, the live portal and anisette stage 3 are unchanged and disabled. The free-account signing gate stays closed.

## Proposed merges (for the owner's approval; nothing done)

1. **Zsign-Zag PR #1** → Zsign-Zag `main`, fast-forward to `f34e51a`.
2. **Zag Store:** the integration branch (draft PR) → `main`. It contains #24, #25 and the Zsign pointer, so it supersedes merging #24 and #25 separately. Both are then closed as merged through it.
3. **Then, before any release:**
   - rebuild `RPPairingCore`;
   - build;
   - package with the unchanged packager;
   - run the device smoke test.

   Release and canonical IPA replacement stay separate decisions.

**Preconditions:**
- device test D passes (**done**, 18 Nov);
- the owner approves (**approved**, 18 Nov, with safeguards).

**Not included:**
- the isideload fork (PR #26, awaiting the independent licence review);
- any live functionality.
