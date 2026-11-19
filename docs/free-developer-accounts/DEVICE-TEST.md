# Device test: debug-only Apple Account sign-in screen

Status: **PASS. Owner-run on a physical iPhone 15 Pro Max, 18 November 2026; results below.**

## The build

- Source: branch `claude-free-developer-accounts` at `09516af4`. The Release configuration is compiled with the `DEBUG` flag added, the same pattern as `scripts/build-zag-first-launch-test.sh`. That flag is what the screen and its Settings entry depend on. Otherwise it enables only some navigation logging.
  - The Xcode Debug configuration cannot go through the existing packager: it produces version `1.0.0-debug` and a different bundle ID.
- Packaged with the existing `~/Documents/ZagStore-Package.zsh`: AppTesters signature, profile, entitlements and the first-launch guard all passed.
- **Test IPA, kept for future testing:** `packages/private-test/DEBUG-SIGNIN-9e73d8b0/ZagStore-DEBUG-SIGNIN-TEST-AppTesters-09516af4.ipa`
  - SHA-256 `2cf357087cfe46a2f37934ea5e34636576d8736192943f3fd0c2b67c3cf2e7b1`
  - Zag Store 1.0.0 (Build 1), bundle `com.cwd43.gu29`.
  - It was the canonical IPA during the test.
- **Canonical IPA:** restored after the test to the private Nightly build 1 (`67d1a79b…`), from its byte-identical copy at `packages/private-test/FINAL-1299f1e9/ZagStore-Nightly-build1-INSTALL-THIS-AppTesters-1299f1e9.ipa`.
- Staging, logs and hashes: `packages/private-test/DEBUG-SIGNIN-9e73d8b0/`. RPPairing and its build configuration were not modified.

## Results (owner-reported, 18 November 2026)

Run by the owner on an iPhone 15 Pro Max with the test IPA above. **All scenarios exercised passed; no failures observed.**

| Area (checklist items) | Result |
|---|---|
| Simulated sign-in and 2FA, including an invalid then a valid code (3–6) | Pass |
| Keychain session persists across app restarts (7) | Pass |
| Session revocation (8) and sign-in cancellation (9) | Pass |
| Network timeout and cancellation while signing in (10) | Pass |
| Invalid credentials rejected (11) | Pass |
| Simulated authentication works in Airplane Mode (12) | Pass |
| All four error scenarios show their messages (13) | Pass |
| Sign-out persists after restarting the app (14) | Pass |
| Diagnostics expose no sensitive credentials (15) | Pass |
| Existing AppTesters certificate signing, pairing and IPA installation work normally (16) | Pass |

The owner's report does not separately mention items 1–2 (screen hidden while Advanced settings is locked, reachable only from its Settings entry). The source checks above enforce both.

## Install (you run this; the iPhone must be connected and trusted)

```bash
xcrun devicectl list devices
W=$(mktemp -d) && unzip -q packages/private-test/DEBUG-SIGNIN-9e73d8b0/ZagStore-DEBUG-SIGNIN-TEST-AppTesters-09516af4.ipa -d "$W" \
  && xcrun devicectl device install app --device "<identifier of your iPhone from the list above>" "$W/Payload/Feather.app"
```

Run it from `~/Documents/ZagStore-claude`, or install the test IPA the way you normally do. It replaces the installed Zag Store (`com.cwd43.gu29`) and keeps its data. The build number is 1, so Zag Store may offer a software update; **don't update during the test**.

## Checklist

Use only the test account the screen offers: `tester@example.invalid`, `zag-simulated-password`, code `123456`. **Never type a real Apple Account, password or code.**

| # | Do | Expect |
|---|---|---|
| 1 | Open Settings with Advanced settings locked. Scroll to the bottom; search for "Apple Account" | No "Apple Account (Simulated)" anywhere |
| 2 | Tap the lock in the Settings toolbar, accept the warning | Experimental Features shows **Apple Account (Simulated)**; it is the only way in |
| 3 | Open it, tap **Fill Test Account**, **Sign In** ("Apple Responds: Asks for Verification Code") | Code sheet appears; the password field is empty |
| 4 | Enter `111111`, **Verify** | "That code was not accepted. 2 attempts left." |
| 5 | **Send Code by Text Message** | Message ends "•• •• 00", no full number |
| 6 | Enter `123456`, **Verify** | Signed In, `t•••@example.invalid`, Personal Team (Simulated), expiry about 30 days out |
| 7 | Force-quit Zag Store, reopen, go back to the screen | Still Signed In (session restored from the Keychain) |
| 8 | **Revoke Session** | Session Expired; **Sign In Again** returns to sign-in |
| 9 | Fill, set "Asks for Verification Code", Sign In, then **Cancel** on the code sheet | "Sign-in was cancelled."; nothing signed in |
| 10 | Set "No Response (Timeout)", Sign In, tap **Cancel** while it spins | Cancelled. Repeat without cancelling: about 8 s, then a network failure |
| 11 | Type `someone@example.com` with the test password | "Your Apple Account email or password was not accepted." (only `@example.invalid` works) |
| 12 | Turn on **Airplane Mode**, repeat steps 3–6 | Works exactly the same: the simulation needs no network |
| 13 | Try "Account Locked", "Too Many Attempts", "Malformed Response", "Anisette Provider Unavailable" | Each shows its own message; nothing signed in |
| 14 | Sign in, then **Sign Out**; force-quit and reopen | Not Signed In, also after relaunch |
| 15 | Read the Diagnostics section | Events only; no password, code or full address |
| 16 | Turn Airplane Mode off. Sign and install one small app the way you usually do (imported certificate), and check pairing status | Same as before this build |

Report each number as pass or fail. For a failure, add a screenshot.

## After a test: restore the canonical IPA (done on 18 November)

```bash
cd ~/Documents/ZagStore-claude
cp packages/private-test/FINAL-1299f1e9/ZagStore-Nightly-build1-INSTALL-THIS-AppTesters-1299f1e9.ipa \
   ~/Documents/ZagStore-v1.0.0-build1-iOS-AppTesters.ipa
shasum -a 256 ~/Documents/ZagStore-v1.0.0-build1-iOS-AppTesters.ipa   # expect 67d1a79b…
```

The test IPA is never the canonical IPA now, so this applies only if it is copied there again. Afterwards, reinstall your usual Zag Store build on the iPhone. The simulated session uses its own Keychain service (`app.zagstore.free-account.simulation`) and preferences key. Sign out in the screen before reinstalling to leave nothing behind.

## Already verified without the device

- The screen's only entry point is the Settings link in the Advanced section (source check).
- The simulation and the screen contain no transport, URL or live service, and accept only `@example.invalid` (source and state tests).
- The Release binary contains no simulation UI or test credentials. The signed test IPA contains all 8 markers, which proves the scan detects them.
- The simulator walkthrough of the real screen: 14 steps, 10 checks.
