# G5: build plan for the first controlled free Apple Account signing experiment

Status 19 November 2026: **plan only.**
- Nothing in this document has been built, merged, enabled or run.
- No Apple, developer-portal or anisette service has been contacted.

This plan implements the G5 gate of `GATES-APPROVAL.md`. It refines the engineering part of `SUPERVISED-EXPERIMENT-SEQUENCE.md` §1, whose step-by-step owner procedure (§2) it keeps. The companion `G5-DIAGNOSTIC-LOGGING-SPEC.md` defines what the experiment records.

**Mandatory before any of this happens, each recorded separately:**
- G1, the owner's approval of the experiment;
- G2, the independent licence review;
- G3, the anisette provider, device serial and stage 3 decisions;
- G4, independent security approval (GPT-6);
- G6, the dedicated account;
- the owner's explicit G5 authorisation to build.

The author of this plan implemented the code it relies on. It is not an independent review.

## 1. Experiment invariants

The build and the run are designed so that each of these holds even if a step fails:

1. **At most one new development certificate** is issued. A second certificate request is impossible without a new build and a new owner decision (§5.2, E1).
2. **No certificate is ever revoked.** The bridge refuses every revoke operation (`backend.rs`, test `portal_requests_cannot_revoke_a_certificate`). No revoke call is added for the experiment.
3. **An ambiguous outcome stops the run** (§7.3). Nothing is retried automatically, and nothing ambiguous is "resolved" by sending another request.
4. **The canonical production IPA is unchanged:**
   - `~/Documents/ZagStore-v1.0.0-build1-iOS-AppTesters.ipa`, SHA-256 `67d1a79bf6826039f38113f06b6e83a2a05cc47e2ab63d561781444373eacb11`, checked 19 Nov 2026.
   - So are `~/Documents/ZagStore-Package.zsh`, Release builds, releases, update metadata and both websites (§4.6).
5. **Production gates stay off:**
   - The experiment's switches are turned on only by a compile-time flag that appears in no shared configuration. It is passed on one `xcodebuild` command line (§3).
   - Every other build, including Release, keeps the switches off. The Release binary scan proves it.
6. **Only the owner handles credentials, and only on the device.** Passwords, 2FA codes and session tokens never pass through chat, files, logs, screenshots or development tools.

## 2. Source branches and merge dependencies

### 2.1 What exists today (heads verified 19 Nov 2026)

| PR | Branch | Base | Head | Content | Required gate |
|---|---|---|---|---|---|
| #26 | `claude-isideload-fork` | `main` | `4b1a6984` | Trimmed `zag-isideload` fork, network compiled out | G2 |
| #28 | `claude-keychain-signing` | `main` | `64de6694` | Keychain-backed signing (`ZAG_ZSIGN_STRICT` only) | G4 |
| #29 | `claude-isideload-bridge` | #26 | `c6ce0750` | Bridge `zag-apple-bridge` with Swift adapters; `G4-SECURITY-REVIEW.md`; `G2-LICENCE-REVIEW.md` | G2 and G4 |
| #34 | `review/g4-anisette-url-validation` | #29 | `280d50e8` | Anisette URL validation; slot exclusivity | G4 |
| #35 | `review/g4-remediation-callbacks-keychain` | #34 | `46aaa1c4` | Callback ownership, Keychain fixes, duplicate-issuance prevention, §13 closeout | G4 |
| — | `main` | — | `5beb0801` | Production | — |

**Verified ancestry:**
- #26 and #28 are both ancestors of #35. The #35 head therefore contains the whole free-account stack.
- The stack's merge base with `main` is `bcf30a9f`. `main` has five commits since then, touching only documentation and two test scripts (PR #32). [hypothesis] Overlaps are possible in four documents under `docs/free-developer-accounts/`, which would need a documentation-only conflict resolution. No source conflict is expected.

### 2.2 Merge sequence after approval

Each step needs its own approval and is a separate PR merge. None is authorised by this plan.

1. **#26** into `main`, after G2.
2. **#29**, re-targeted to `main`, including #34 and #35 once G4 approves the stack at its final head. Merging #29, #34 and #35 as one reviewed unit is the owner's choice. Their review evidence is per head.
3. **#28.** It is already contained in the stack. If merged separately, it must be first or a no-op.
4. After each merge, run the full regression on the resulting `main` (§4.4).

After these merges, `main` still contains no live capability:
- The bridge library is not linked.
- `ZAG_APPLE_BRIDGE` and `ZAG_ZSIGN_STRICT` are not set.
- All five switches are `false` constants.

The Release scan (`scripts/test-zag-free-account-release-binary.sh`) must confirm this.

### 2.3 The experiment branch (never merged)

- **Branch:** `experiment/g5-live-test`, created from the post-merge `main` SHA.
- **One experiment-only commit** (§3.2), reviewed by GPT-6 before the build.
- **Record:** the branch SHA, the bridge library's SHA-256, and the Zsign submodule SHA (`f34e51a` unless a reviewed change lands).
- **Never merged into `main`.** It is deleted after the experiment report is accepted, and the report records its SHA.

**Fallback, if the owner prefers not to merge before the experiment:** create `experiment/g5-live-test` from the approved #35 head, merged with `main` at that time. Every SHA is recorded the same way. This keeps unexperimented code out of `main`, at the cost of reviewing a merge commit.

## 3. Feature gates

### 3.1 Inventory (at #35 head `46aaa1c4`)

| Gate | Kind | Where | Production value | Experiment value |
|---|---|---|---|---|
| `ZAG_APPLE_BRIDGE` | Swift compilation condition | `ZagIsideloadBridge.swift` (whole file), `ZagAccountRecoveryModels.swift` | unset | set (command line only) |
| `ZAG_ZSIGN_STRICT` | Swift compilation condition | `ZagStrictComponentSigning.swift`, `ZagFreeAccountSigningAdapter.swift` | unset | set (command line only) |
| `DEBUG` | Swift compilation condition | Debug-only screens: `ZagFreeAccountDebugSignInView`, `ZagAppleAccountsDebugView`, `ZagInstalledProfilesDebugView`; the simulations | unset in Release | set (same pattern as device test IPAs A–D) |
| `live` | Cargo feature of `zag-apple-bridge` | turns on `zag-isideload/live-network` and rustls | off | on, for the `aarch64-apple-ios` library only |
| `mock` | Cargo feature | the scripted test backend | off | **off** (never in app builds) |
| `ZagLiveAuthentication.isEnabled` | `static let` | `ZagFreeAccountAuthentication.swift:175` | `false` | `true` under `ZAG_LIVE_EXPERIMENT` only |
| `ZagLivePortal.isEnabled` | `static let` | `ZagDeveloperPortal.swift:119` | `false` | `true` under `ZAG_LIVE_EXPERIMENT` only |
| `ZagAnisetteLive.isEnabled` | `static let` | `ZagAnisetteProvider.swift:210` | `false` | `true` under `ZAG_LIVE_EXPERIMENT` only |
| `ZagFreeAccountSigning.isEnabled` | `static let` | `ZagFreeAccountSigningAdapter.swift:15` | `false` | `true` under `ZAG_LIVE_EXPERIMENT` only |
| `ZagAppleAccountsFeature.isEnabled` | `static let` | `ZagAccountRecoveryModels.swift:13` | `false` | **stays `false`.** The experiment uses the Debug-only screens, not the production Apple Accounts UI. |
| `ZagIsideloadBridge.configureLive(anisetteURL:deviceSerial:)` | runtime; refuses without both values | `ZagIsideloadBridge.swift:290` | never called | called once at launch with the G3 values |
| Network policy `APPLE_HOSTS` | Rust constant | `zag-isideload/src/net_policy.rs:17` | `gsa.apple.com`, `developerservices2.apple.com` | **unchanged.** Plus the single G3 anisette host. |
| Analytics and first-launch reporting | compile-time | `ZAG_FIRST_LAUNCH_TEST_BUILD` and the reporters | as production | **compiled out** in the experiment build (`LIVE-AUTH-GATE-RECOMMENDATIONS.md`, G5) |

### 3.2 The experiment-only commit (proposed; needs owner approval and GPT-6 review)

**1. A new compilation condition, `ZAG_LIVE_EXPERIMENT`, used only in this commit:**

```swift
enum ZagLiveAuthentication {
	#if ZAG_LIVE_EXPERIMENT && ZAG_APPLE_BRIDGE && DEBUG
	static let isEnabled = true
	#else
	static let isEnabled = false
	#endif
}
```

- The same pattern applies to the other three switches. Requiring all three conditions means a stray `ZAG_LIVE_EXPERIMENT` alone enables nothing.
- A compile-time `#error` stops a build that sets `ZAG_LIVE_EXPERIMENT` without `DEBUG`, without `ZAG_APPLE_BRIDGE` or without `ZAG_ZSIGN_STRICT`.

**2. Experiment configuration**, `ZagLiveExperimentConfiguration`, compiled only under `ZAG_LIVE_EXPERIMENT`:
- the G3 anisette URL and the device-serial policy, as constants recorded in the G3 decision;
- the account namespace `ZagStore.accounts.live-test`, a Keychain namespace that is not production's or the simulation's;
- the test bundle ID `com.zagstore.livetest.hello`;
- the experiment ID, a random value generated at first launch and stored in the live-test namespace.

**3. The safeguards E1 to E4** (§5.2), implemented and unit-tested in this commit.

**4. The diagnostic logger** from `G5-DIAGNOSTIC-LOGGING-SPEC.md`, compiled only under `ZAG_LIVE_EXPERIMENT`.

**5. Visible identification:**
- display name "Zag LIVE TEST";
- a permanent banner on the Debug sign-in and Apple Accounts screens showing "LIVE TEST", the experiment ID and the branch SHA.

**What the commit must not do:**
- change `net_policy.rs`;
- add a revoke path;
- change production defaults;
- touch `FeatherApp.swift`;
- modify the packager original.

## 4. Reproducible isolated build procedure

The steps run only after the G5 authorisation is recorded. Commands are indicative; the exact command lines are recorded in the build record.

### 4.1 Preconditions

1. Clean worktree in `~/Documents/ZagStore-claude`: no new clones or worktrees. Only `scripts/__pycache__/` is allowed as untracked.
2. On the `experiment/g5-live-test` branch, at the recorded SHA.
3. Submodules at their recorded SHAs (`git submodule status`).
4. Record the canonical IPA's SHA-256. It must equal `67d1a79b…eacb11`.
5. Xcode, Rust toolchain and target versions recorded (`xcodebuild -version`, `rustc -V`, `rustup target list --installed`).
6. Do not run `make clean`.

### 4.2 Bridge library

```sh
cargo build --release --manifest-path AppleAuthCore/zag-apple-bridge/Cargo.toml \
  --target aarch64-apple-ios --features live --locked
shasum -a 256 target/aarch64-apple-ios/release/libzag_apple_bridge.a   # record
```

- `--locked` makes the build fail on any dependency drift.
- The library goes in a build-only path. It is never committed, and the Xcode project is not changed to reference it.

### 4.3 App build

A Release-configuration build with the experiment conditions, following the pattern of device test IPAs A–D (`DEVICE-TEST-PHASE7.md`).

```sh
xcodebuild -workspace Feather.xcworkspace -scheme <scheme> -configuration Release \
  -sdk iphoneos -derivedDataPath <scratch>/g5-dd \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEBUG ZAG_APPLE_BRIDGE ZAG_ZSIGN_STRICT ZAG_LIVE_EXPERIMENT' \
  OTHER_LDFLAGS='$(inherited) <path>/libzag_apple_bridge.a' \
  PRODUCT_NAME_DISPLAY='Zag LIVE TEST'   # exact setting name recorded in the build record
```

- The derived-data path is in scratch.
- The flags exist only on this command line. `git diff` after the build must be empty.

### 4.4 Checks before the IPA is handed over

All checks must pass, and each result is recorded with its count:

1. Every `scripts/test-zag-*.sh` suite (44 suites at the time of writing), plus `test-zag-package-guard.sh`. Run on the experiment branch, and on `main` after each merge.
2. The bridge suites: Rust tests (default, mock and live builds), the Swift bridge tests and the strict integration tests.
3. The new E1–E4 and logger unit tests, including the leak corpus in the logging spec §9.
4. **Positive check on the experiment IPA:**
   - the executable contains the bridge symbols (`zag_bridge_configure_live`), the `ZAG_LIVE_EXPERIMENT` markers and the logger;
   - the display name is "Zag LIVE TEST";
   - the embedded G3 host is the only anisette host;
   - no `mock` symbols are present.
5. **Negative check on a fresh Release build from the same SHA, without the flags:** `test-zag-free-account-release-binary.sh` passes, so there is no bridge, no live markers and no logger.
6. The canonical IPA hash is unchanged.

### 4.5 Packaging

- Copy `~/Documents/ZagStore-Package.zsh` to scratch, and change only the output path and name in the copy. The original is never edited.
- Sign with the existing AppTesters certificate, as for IPAs A–D. Bundle `com.cwd43.gu29` is unchanged, so the existing pairing and data are kept.
- **Output:** `packages/private-test/LIVE-EXPERIMENT-<sha8>/ZagStore-LIVE-TEST-<sha8>.ipa`. This directory is ignored by git and never committed or uploaded.
- **Record:** size and SHA-256; branch SHA; library SHA-256; tool versions; check results.

### 4.6 What never happens

- Replacing or re-signing the canonical IPA.
- Editing the original packager.
- Publishing a release, tag or update metadata.
- Deploying to either website.
- Uploading the experiment IPA anywhere.
- Installing it by any route other than the owner's AirDrop plus Library → Install.

## 5. The dedicated Apple Account and certificate safeguards

### 5.1 Account requirements (G6, recorded as yes or no only)

| # | Requirement |
|---|---|
| A1 | Newly created for this experiment. **Never** the personal account, or any account that has signed apps before. |
| A2 | No payment method; not enrolled in the Apple Developer Program (a free Personal Team only). |
| A3 | 2FA on, with a trusted device or number the owner controls. Recovery confirmed. |
| A4 | Details kept off every computer file, chat and screenshot (on paper, per `SUPERVISED-EXPERIMENT-SEQUENCE.md`). |
| A5 | Expected state before the run: zero development certificates, zero App IDs, zero registered devices. Any other state is a stop (step P3). |
| A6 | Used on one device only, the owner's iPhone 15 Pro Max, and in one app build only, this experiment's. |

### 5.2 Experiment-only safeguards (proposed, in the §3.2 commit)

**E1, certificate budget of one:**
- A `certificateSubmissions` counter for the experiment ID, stored in the live-test Keychain namespace so that a reinstall does not reset it.
- It is checked and incremented **before** the request is sent.
- When it is 1, the provisioner refuses any further certificate request with `.certificateBudgetSpent`. This applies even to a retry of the same pending request, which the production policy (`ZagPendingSigningKey.maximumAttempts = 3` within 24 h) would allow after a definite refusal.
- Only a new build with a new experiment ID can issue another, which needs a new owner decision.

**E2, persistent halt:**
- Any stop rule in §7.3 sets a halt flag in the live-test namespace.
- While it is set, every live operation refuses with `.experimentHalted`, except reading the certificate list for recovery, sign-out and the Stored Account Data inventory.
- It is cleared only by deleting the app and installing a new experiment build.

**E3, no abandonment during the run:**
- In the experiment build, "Abandon Request…" is disabled for an unresolved certificate request. Abandoning would let the next signing request a second certificate.
- Only "Check Again" is allowed, and it only reads the list.

**E4, preflight read:**
- Before the first certificate request, list the team's certificates.
- Anything other than zero existing certificates stops the run (A5). This also proves the listing call works before anything is created.

### 5.3 Existing safeguards relied upon (G4 scope)

- **Certificate journal:**
  - `ZagPendingSigningKey.submissionUnconfirmed` is set before every request.
  - An outcome that can't be confirmed becomes `certificateRequestUnresolved`, which blocks further requests for that account and team.
  - Recovery reads the listing (`resolveUnconfirmed` → issued, notIssued or unknown) and matches by proof of possession.
- **Exclusivity:** one certificate operation per account and team (the actor's `busyScopes`), and cancellation-aware waiting (#35, §13).
- **Keys:** a this-device-only Keychain key that Zag Store never exports. The new key is swapped in only after its certificate is verified.
- **Limit reached:** `certificateMustBeRevoked` is offered by the production UI, but in the experiment it is a **stop** (§7.3). No revoke exists in the bridge.

## 6. Signing and installation sequence

This is `SUPERVISED-EXPERIMENT-SEQUENCE.md` §2, with preflight steps and the safeguards added. Each step logs the events named in the logging spec. "Stop" means: cancel, set the halt (E2), sign out, export the failure report, and follow §8.

| # | Step | Component | Expected | Logged phase |
|---|---|---|---|---|
| P1 | Install the experiment IPA (AirDrop → Library → Install). Confirm the "LIVE TEST" banner and the experiment ID. | existing installer | correct build, SHA on banner | `build` |
| P2 | Pairing and LocalDevVPN health check (Settings → Installation → Diagnostics); Developer Mode on | existing RPPairing | all stages pass | `transport.preflight` |
| P3 | Owner confirms A1–A6 | — | yes | `preflight.account` (a yes or no only) |
| 1 | Sign in with password; complete 2FA (trusted device, or SMS once) | `ZagFreeAccountAuthenticator` → bridge → `zag-isideload` | `awaitingTwoFactor` → signed in | `anisette.*`, `auth.*`, `net.*` |
| 2 | Team | team listing | exactly one team, free limits applied (kind `unknown`) | `portal.teams` |
| 3 | E4 preflight: list certificates | portal | zero certificates | `cert.preflight` |
| 4 | Register this iPhone (UDID from the existing pairing; never shown or logged) | `registerDevice` | device appears; one device | `portal.device` |
| 5 | Request **one** certificate (E1 consumed) | provisioner and Keychain key | issued; proof-of-possession match | `cert.*` |
| 6 | App ID and profile for `com.zagstore.livetest.hello` | `registerAppID`, `profile(for:)`, `ZagProvisioningProfileCheck` | profile passes: team, bundle, certificate, device, about 7-day expiry | `portal.appid`, `profile.*` |
| 7 | Sign the test app with the Keychain key | `ZagFreeAccountSigningAdapter.signWithKeychainKey` → Zsign `signComponents` (strict) | signature and Zsign verification pass; no key file written | `sign.*` |
| 8 | Install | `ZagFreeAccountRPPairingInstaller` → existing `installGate4IPA`, unchanged | installed; app launches and shows its screen | `install.*` |
| 9 | Read back: Installed Profiles (Read Only) → Read | RPPairing misagent reader (PR #25, in `main` through #27) and `ZagInstalledProfileCheck` | **VERIFIED** | `install.verify` |
| 10 | Sign out; Stored Account Data inventory | authenticator; `ZagStoredAccountDataView` | session and identity items removed; only expected items remain | `auth.signout`, `inventory` |
| 11 | Export the report (owner, share sheet) | logger | report passes the exporter self-check | `report` |

**Notes:**
- The installer's own `installedProfiles` hook (`ZagFreeAccountRPPairingInstaller.swift`) is not wired, and its comment about PR #25 is out of date. Step 9 therefore uses the Debug-only read-back screen, which device test A has proven. Wiring the hook is not part of this experiment.
- The test app is a minimal single-view app: no extensions, frameworks, app groups or non-default entitlements. It is built separately, and its unsigned IPA's SHA-256 is recorded.

## 7. Pass and fail criteria

### 7.1 Pass: all of these must hold

1. Steps P1–11 completed in order, each with its expected result.
2. Exactly one certificate submission; exactly one certificate issued, matched by proof of possession; zero revoked.
3. Step 9 VERIFIED, and the test app launched.
4. The sign-out inventory shows only expected items.
5. The exported report passes the self-check and contains no prohibited data (logging spec §8). GPT-6 confirms this independently on reading it.
6. Every network request went to an allowed host. No `policy.blocked` event, or, if one occurred, the run stopped as designed (that run is "safe stop", not "pass").
7. The canonical IPA hash is unchanged afterwards.

### 7.2 Outcome classes

| Class | Meaning |
|---|---|
| **PASS** | §7.1 holds |
| **SAFE STOP** | A stop rule fired, nothing ambiguous remains, and the invariants held. A useful result, not a failure of safety. |
| **UNRESOLVED STOP** | Stopped with `certificateRequestUnresolved` or another ambiguity outstanding. Follow §8.2 and decide later. |
| **SAFETY FAILURE** | Any invariant in §1 was violated: a second certificate, a revocation, a credential in any output, a request to a non-allowed host that was not blocked, or a canonical IPA change. Halt all free-account work and send it to G4 review. |

### 7.3 Stop rules (each sets the E2 halt)

**Authentication:**
- two consecutive failures of any kind;
- a lock, rate-limit or "too many codes" response;
- an unexpected prompt on the trusted device;
- an unexpected or unrecognised 2FA kind.

**Network:**
- any `policy.blocked` event, for example a lookup URL outside `APPLE_HOSTS` or an `idmsa.apple.com` redirect;
- a TLS failure.

**Anisette:**
- provisioning failure;
- headers failing `ZagAnisetteData(validating:)`.

**Team:** zero, several, or a paid team.

**Certificate:**
- existing certificates at E4;
- `certificateMustBeRevoked`;
- `certificateRequestUnresolved`;
- a proof-of-possession mismatch;
- `certificateBudgetSpent`;
- any timeout, cancellation or app termination between "request sent" and "result received".

**Device:** device limit; a different device appearing.

**App ID and profile:** any `ZagProvisioningProfileCheck` problem; identifier unavailable; App ID capacity.

**Signing:** a signature or Zsign verification failure; any key file written.

**Installation:**
- install refused;
- install result unknown, such as a transport drop after upload;
- launch failure;
- read-back MISMATCH or NOT VERIFIED.

**Anything the owner does not recognise.**

**Retry rule:** no step is retried without a new decision. The only exception is the non-mutating reads: preflight list, Check Again and read-back. Each of these may be run once more.

## 8. Rollback procedures

### 8.1 On the device (every outcome)

1. Sign out in the app (`auth.signout`).
2. Open Stored Account Data. Remove only the live-test namespace items it lists. Record the counts, not the contents.
3. Delete the test app `com.zagstore.livetest.hello`.
4. Export the report, then clear the experiment log (logger `clear`).
5. Reinstall the canonical IPA by AirDrop → Library → Install, as after device tests A–D. Data is kept because the bundle ID is unchanged.
6. Confirm the pairing and the production app work: the Settings → Installation health check.

### 8.2 On the Apple Account

- **Certificate:** left in place. Zag Store never revokes it, and it expires on its own (expiry recorded from the listing). If the owner ever wants it gone, they revoke it themselves outside Zag Store, outside this experiment.
- **Unresolved request:** left unresolved. "Check Again" may be run once later with a new decision. "Abandon" (which deletes the pending key and allows a new request) needs a separate owner decision, outside this experiment.
- **App ID:** counts against 10 per 7 days until it expires. It is not deleted.
- **Device registration:** stays. Removal is not needed.
- **If compromise is suspected:** the owner changes the dedicated account's password on an Apple device. This also invalidates the session.

### 8.3 In the repository and on the Mac

- `experiment/g5-live-test` is never merged. It is deleted after the report is accepted, and its SHA is recorded.
- The bridge library and derived data are deleted from scratch. The experiment IPA is kept in `packages/private-test/` (ignored) until the report is accepted, then deleted, with its hash recorded.
- The canonical IPA hash is checked again and recorded.

## 9. What this plan does not cover

- Extensions, multiple apps, a second account, refresh or re-signing within 7 days.
- Automatic refresh, background tasks, Shortcuts.
- Any production UI (`ZagAppleAccountsFeature` stays off).
- Changes to the network policy, BYOC, the AppTesters signing service or the websites.

These follow a PASS through separate decisions.

## 10. Approvals checklist (all must be recorded before §4)

| # | Approval | Recorded in |
|---|---|---|
| 1 | G1: experiment approved, with amendments (a) and (b) | `FIRST-LIVE-EXPERIMENT.md` |
| 2 | G2: licence review complete | `G2-LICENCE-REVIEW.md` §9 |
| 3 | G3: provider URL, device-serial policy, per-account anisette state, and **live anisette use for this experiment** (stage 3 or an explicit experiment exception) | `ANISETTE-STUDY.md` |
| 4 | G4: independent approval of the stack at its final head | `G4-SECURITY-REVIEW.md` §10 |
| 5 | Merges in §2.2, each approved | the PRs |
| 6 | §3.2 experiment commit, reviewed by GPT-6 | the commit's review |
| 7 | G6: account ready (A1–A6, yes or no) | `FIRST-LIVE-EXPERIMENT.md` |
| 8 | **G5: owner authorises building the experiment IPA** | `FIRST-LIVE-EXPERIMENT.md` |
| 9 | Owner authorises running it, on a stated date | `FIRST-LIVE-EXPERIMENT.md` |
