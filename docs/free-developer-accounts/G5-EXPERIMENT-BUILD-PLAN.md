# G5: build plan for the first controlled free Apple Account signing experiment

Status 19 November 2026, **revision 2: plan only.**
- Nothing in this document has been built, merged, enabled or run.
- No Apple, developer-portal or anisette service has been contacted.
- Revision 2 addresses GPT-6's seven findings on revision 1 (`5839add7`); §13 lists each correction.
- Revision 3 addresses GPT-6's final two findings on revision 2 (`a8afce89`); see §12, §5.2 (E5, E6) and the new §5.5. The implementation handoff is `G5-IMPLEMENTATION-CHECKLIST.md`.

This plan implements the G5 gate of `GATES-APPROVAL.md`. It refines the engineering part of `SUPERVISED-EXPERIMENT-SEQUENCE.md` §1, whose step-by-step owner procedure (§2) it keeps. The companion `G5-DIAGNOSTIC-LOGGING-SPEC.md` defines what the experiment records.

**Mandatory before any of this happens, each recorded separately:**
- G1, the owner's approval of the experiment;
- G2, the independent licence review;
- G3, the anisette provider, device serial and stage 3 decisions;
- G4, independent security approval (GPT-6);
- G6, the dedicated account;
- the owner's explicit G5 authorisation to build, naming a campaign (§5.2, E6).

The author of this plan implemented the code it relies on. It is not an independent review.

## 1. Experiment invariants

The build and the run are designed so that each of these holds even if a step fails:

1. **At most one new development certificate per authorised campaign and dedicated Apple Account.**
   - None of these can silently restore the allowance: reinstalling, relaunching, rebuilding, a new install ID, or switching accounts.
   - Another certificate needs a new campaign, and a new campaign needs the owner's written reauthorisation (§5.2: E1, E2, E5, E6).
2. **No certificate is ever revoked.** The bridge refuses every revoke operation (`backend.rs`, test `portal_requests_cannot_revoke_a_certificate`). No revoke call is added for the experiment.
3. **An ambiguous outcome stops the campaign permanently** (§7.3). Nothing is retried automatically, and nothing ambiguous is "resolved" by sending another request.
4. **The canonical production IPA is unchanged:**
   - `~/Documents/ZagStore-v1.0.0-build1-iOS-AppTesters.ipa`, SHA-256 `67d1a79bf6826039f38113f06b6e83a2a05cc47e2ab63d561781444373eacb11`, checked 19 Nov 2026.
   - So are `~/Documents/ZagStore-Package.zsh`, Release builds, releases, update metadata and both websites (§4.6).
5. **Production gates stay off:**
   - The experiment's switches are turned on only by compile-time conditions that appear in no shared configuration. They are passed on one `xcodebuild` command line (§3).
   - The experiment build does **not** set `DEBUG` (§3.3).
   - A separate, clean production build, and a scan of it and of the canonical IPA, prove that every other build keeps the switches off (§4.4).
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
- `ZAG_APPLE_BRIDGE`, `ZAG_ZSIGN_STRICT` and `ZAG_LIVE_EXPERIMENT` are not set.
- All five switches are `false` constants.

The clean production build and scan (§4.4) must confirm this.

### 2.3 The experiment branch (never merged)

- **Branch:** `experiment/g5-live-test`, created from the post-merge `main` SHA.
- **One experiment-only commit** (§3.2), reviewed by GPT-6 before the build.
- **Record:** the branch SHA, the bridge library's SHA-256, and the Zsign submodule SHA (`f34e51a` unless a reviewed change lands).
- **Never merged into `main`.** It is deleted after the campaign is closed, and the campaign ledger records its SHA (E6).

**Fallback, if the owner prefers not to merge before the experiment:** create `experiment/g5-live-test` from the approved #35 head, merged with `main` at that time. Every SHA is recorded the same way.

## 3. Feature gates

### 3.1 Inventory (at #35 head `46aaa1c4`)

| Gate | Kind | Where | Production value | Experiment value |
|---|---|---|---|---|
| `ZAG_APPLE_BRIDGE` | Swift compilation condition | `ZagIsideloadBridge.swift` (whole file), `ZagAccountRecoveryModels.swift` | unset | set (command line only) |
| `ZAG_ZSIGN_STRICT` | Swift compilation condition | `ZagStrictComponentSigning.swift`, `ZagFreeAccountSigningAdapter.swift` | unset | set (command line only) |
| `ZAG_LIVE_EXPERIMENT` | Swift compilation condition (new, §3.2) | the experiment commit only | unset | set (command line only) |
| `DEBUG` | Swift compilation condition | 13 app files (Debug-only screens, simulations, the test key factory, the bridge's `configureMock`, Debug UI); also debug code in 8 Swift packages (§3.3) | unset in Release | **unset.** A build that sets it together with `ZAG_LIVE_EXPERIMENT` fails to compile (§3.2). |
| `live` | Cargo feature of `zag-apple-bridge` | turns on `zag-isideload/live-network` and rustls | off | on, for the `aarch64-apple-ios` library only |
| `mock` | Cargo feature | the scripted test backend | off | **off** (never in app builds) |
| `ZagLiveAuthentication.isEnabled` | `static let` | `ZagFreeAccountAuthentication.swift:175` | `false` | `true` under the §3.2 condition only |
| `ZagLivePortal.isEnabled` | `static let` | `ZagDeveloperPortal.swift:119` | `false` | `true` under the §3.2 condition only |
| `ZagAnisetteLive.isEnabled` | `static let` | `ZagAnisetteProvider.swift:210` | `false` | `true` under the §3.2 condition only |
| `ZagFreeAccountSigning.isEnabled` | `static let` | `ZagFreeAccountSigningAdapter.swift:15` | `false` | `true` under the §3.2 condition only. Opens `ZagFreeAccountSigningGate.production`; the Debug-only `simulationOnly` gate is not compiled. |
| `ZagAppleAccountsFeature.isEnabled` | `static let` | `ZagAccountRecoveryModels.swift:13` | `false` | **stays `false`.** The experiment uses the screens of §3.2 item 5, not the production Apple Accounts UI. |
| `ZagIsideloadBridge.configureLive(anisetteURL:deviceSerial:)` | runtime; refuses without both values | `ZagIsideloadBridge.swift:290` | never called | called once at launch with the G3 values |
| Network policy `APPLE_HOSTS` | Rust constant | `zag-isideload/src/net_policy.rs:17` | `gsa.apple.com`, `developerservices2.apple.com` | **unchanged.** Plus the single G3 anisette host. |
| Analytics and first-launch reporting | compile-time | `ZAG_FIRST_LAUNCH_TEST_BUILD` and the reporters | as production | **compiled out** in the experiment build (`LIVE-AUTH-GATE-RECOMMENDATIONS.md`, G5) |

### 3.2 The experiment-only commit (proposed; needs owner approval and GPT-6 review)

**1. Compilation conditions.** A new condition, `ZAG_LIVE_EXPERIMENT`. The four switches use this pattern:

```swift
enum ZagLiveAuthentication {
	#if ZAG_LIVE_EXPERIMENT && ZAG_APPLE_BRIDGE && ZAG_ZSIGN_STRICT && !DEBUG
	static let isEnabled = true
	#else
	static let isEnabled = false
	#endif
}
```

One file also carries guards that stop a misconfigured build:

```swift
#if ZAG_LIVE_EXPERIMENT && DEBUG
#error("The live experiment is never built with DEBUG (G5 plan §3.3)")
#endif
#if ZAG_LIVE_EXPERIMENT && !(ZAG_APPLE_BRIDGE && ZAG_ZSIGN_STRICT)
#error("The live experiment needs ZAG_APPLE_BRIDGE and ZAG_ZSIGN_STRICT")
#endif
```

**2. Campaign configuration**, `ZagLiveExperimentCampaign`, compiled only under `ZAG_LIVE_EXPERIMENT`:
- `campaignID` and `campaignNumber`: constants naming the campaign the owner authorised in writing, for example `G5-C1` and `1` (E6). Fixed in the source, never generated at run time.
- `notBefore` and `notAfter`: the authorised window (§5.5).
- `buildNonce`: 16 random bytes.
- These constants live in one file, `ZagLiveExperimentCampaignConstants.swift`. The build procedure writes it and commits it as a separate, mechanical **constants commit** on top of the reviewed experiment commit (§4.4). Every build therefore has its own commit SHA, and the build check verifies that the constants commit changes only that file, in the expected format.
- the G3 anisette URL and the device-serial policy, as recorded in the G3 decision;
- the account namespace `ZagStore.accounts.live-test`;
- the test bundle ID `com.zagstore.livetest.hello`.

A random `installID` is generated per installation for log correlation only. It has no effect on the budget or the halt.

**3. The safeguards E1–E6** (§5.2), with the tests of §5.4.

**4. The diagnostic logger** from `G5-DIAGNOSTIC-LOGGING-SPEC.md`.

**5. The screens the experiment needs**, enabled by changing their guard from `#if DEBUG` to `#if DEBUG || ZAG_LIVE_EXPERIMENT`. Each was reviewed individually:
- a sign-in screen bound to the live authenticator (the simulation-only parts of `ZagFreeAccountDebugSignInView` stay `DEBUG`-only);
- `ZagAppleAccountsDebugView`, the list and sign-out;
- `ZagInstalledProfilesDebugView`, the read-back.

Everything else under `#if DEBUG` stays out of the experiment build, including:
- `ZagSecuritySigningKeyFactory`, which exports private-key bytes and is tests-only;
- `ZagIsideloadBridge.configureMock`;
- `ZagFreeAccountSimulation` and `ZagDeveloperPortalSimulation`;
- `ZagFreeAccountSigningGate.simulationOnly`;
- `testIntermediates`;
- the Debug UI in Settings, Library and the tab bar.

**6. Visible identification:**
- display name "Zag LIVE TEST";
- a permanent banner showing "LIVE TEST", the campaign ID, the branch SHA and the campaign state: `probing`, `armed`, `spent`, `closed` or `halted`.

**What the commit must not do:**
- change `net_policy.rs`;
- add a revoke path;
- change production defaults;
- touch `FeatherApp.swift`;
- modify the packager original.

### 3.3 Release configuration: verified implications (finding 3)

**Verified on 19 Nov 2026**, using `xcodebuild -showBuildSettings` for scheme `Feather`, Release, `generic/platform=iOS`. This reads settings only; nothing was compiled.

| Setting | Production (Makefile command) | Command line adds `DEBUG ZAG_APPLE_BRIDGE ZAG_ZSIGN_STRICT ZAG_LIVE_EXPERIMENT` |
|---|---|---|
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | empty (the target sets `""`) | the four conditions; `$(inherited)` resolves to empty |
| `SWIFT_OPTIMIZATION_LEVEL` | `-Osize` | `-Osize` |
| `SWIFT_COMPILATION_MODE` | `wholemodule` | `wholemodule` |
| `ENABLE_TESTABILITY` | `NO` | `NO` |
| `ENABLE_NS_ASSERTIONS` | `NO` | `NO` |
| `STRIP_INSTALLED_PRODUCT` | `YES` | `YES` |
| `GCC_PREPROCESSOR_DEFINITIONS` | empty | empty, so C, C++ and Objective-C (Zsign, OpenSSL) see no `DEBUG` macro |

**What `DEBUG` would have done in a Release build:**
- **It changes compiled Swift code, not the optimiser.**
  - Swift `assert` is removed at `-Osize` whether or not `DEBUG` is set; `precondition` stays.
  - The Rust library is unaffected.
- **App code.** It compiles in every `#if DEBUG` block of the 13 app files:
  - simulations;
  - `ZagSecuritySigningKeyFactory`, which **exports private-key bytes** (tests only);
  - `ZagIsideloadBridge.configureMock`, which reconfigures the bridge with a scripted backend;
  - the simulation-only signing gate;
  - test intermediates;
  - Debug UI in Settings, Library and the tab bar.
- **Packages.** A build setting given on the command line applies to every target in the build, including Swift packages. In the current package checkouts, `#if DEBUG` code exists in:
  - console-kit (1 file), Nuke (1), swift-argument-parser (2), swift-collections (9), swift-log (2), swift-nio (2), swift-system (4) and vapor (1);
  - IDeviceKitten's `Heartbeat.swift` (1).

  Such code can add checks or change behaviour, which would make the experiment differ from production for reasons unrelated to free accounts.
- **Device test IPAs A–D** were built this way. Revision 1 copied that pattern; revision 2 drops it.

**Decision:**
- The experiment build passes only `ZAG_APPLE_BRIDGE ZAG_ZSIGN_STRICT ZAG_LIVE_EXPERIMENT`. No package source references any `ZAG_` condition; verified by `grep` over the checkouts and local packages, 0 files. Package code is therefore compiled exactly as in production.
- Only the three screens in §3.2 item 5 are added, explicitly.
- The `#error` guard makes `DEBUG` plus `ZAG_LIVE_EXPERIMENT` impossible.

## 4. Reproducible isolated build procedure

The steps run only after the G5 authorisation is recorded. Commands are indicative; the exact command lines are recorded in the build record.

### 4.1 Preconditions

1. Clean worktree in `~/Documents/ZagStore-claude`: no new clones or worktrees. Only `scripts/__pycache__/` is allowed as untracked.
2. On the `experiment/g5-live-test` branch, at the recorded SHA.
3. Submodules at their recorded SHAs (`git submodule status`).
4. Record the canonical IPA's SHA-256. It must equal `67d1a79b…eacb11`.
5. Xcode, Rust toolchain and target versions recorded (`xcodebuild -version`, `rustc -V`, `rustup target list --installed`).
6. The campaign ID in the source matches an `authorised` row in the ledger (E6). The build is refused otherwise.
7. Do not run `make clean`.

### 4.2 Negative production build first (finding 3)

The production configuration is built **before** anything experimental exists on disk, as a separate invocation:

```sh
git switch --detach <post-merge main SHA>             # the experiment commit's parent
git status --porcelain                                 # only scripts/__pycache__/ may appear
xcodebuild -project Feather.xcodeproj -scheme Feather -configuration Release \
  -destination generic/platform=iOS -derivedDataPath <scratch>/g5-prod-clean \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO
```

- This is the exact `xcodebuild` invocation of the `Makefile`'s production target, with no extra build settings. It runs at the experiment commit's parent (the post-merge `main` SHA), so the experiment source is not in the tree. The experiment branch is checked out only afterwards.
- It uses a **new, empty** derived-data directory, so its module cache, package checkouts and build products are its own.
- It runs before the bridge library is built, so no `libzag_apple_bridge.a` exists on disk.
- **Record** the `-showBuildSettings` output for the same command: `SWIFT_ACTIVE_COMPILATION_CONDITIONS` must be empty.
- **Scan** the resulting executable with `scripts/test-zag-free-account-release-binary.sh`, extended to the experiment's markers (`zag_bridge_configure_live`, `ZagLiveExperimentCampaign`, `zag-g5-report/1`, the G3 host).
- **Scan the canonical IPA's executable** read-only with the same scanner. It must pass too, since it is the shipped production binary.
- **Repeat** the same clean command at the experiment commit itself, in another new, empty derived-data directory, still before the bridge library exists. Its scan must also pass. This proves the experiment commit's own code compiles out completely without the three conditions.
- Delete both derived-data directories afterwards. Nothing from them is reused.

### 4.3 Bridge library

```sh
cargo build --release --manifest-path AppleAuthCore/zag-apple-bridge/Cargo.toml \
  --target aarch64-apple-ios --features live --locked
shasum -a 256 target/aarch64-apple-ios/release/libzag_apple_bridge.a   # record
```

- `--locked` makes the build fail on any dependency drift.
- The library goes in a build-only scratch path. It is never committed, and the Xcode project is not changed to reference it.

### 4.4 Experiment app build

```sh
xcodebuild -project Feather.xcodeproj -scheme Feather -configuration Release \
  -destination generic/platform=iOS -derivedDataPath <scratch>/g5-exp \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) ZAG_APPLE_BRIDGE ZAG_ZSIGN_STRICT ZAG_LIVE_EXPERIMENT' \
  OTHER_LDFLAGS='$(inherited) <scratch>/libzag_apple_bridge.a'
```

- This is the same invocation as §4.2, plus the two settings and `INFOPLIST_KEY_CFBundleDisplayName='Zag LIVE TEST'` (the project generates its Info.plist, so the shared `Info.plist` is not edited). It uses its own derived-data directory.
- **Before the build,** `scripts/zag-g5-build-check.sh`:
  - generates `buildNonce`;
  - writes the constants file from the `authorised` ledger row (ID, number and window);
  - makes the constants commit;
  - refuses unless the ledger row is `authorised`, the window has not passed, and `campaignNumber` is greater than every `built` or closed row.
- After the build, the ledger row becomes `built`, with the SHA and nonce.
- `git diff` after the build must be empty.

**Checks before the IPA is handed over.** All must pass, and each result is recorded with its count:
1. Every `scripts/test-zag-*.sh` suite (44 at the time of writing), plus `test-zag-package-guard.sh`. Run on the experiment branch, and on `main` after each merge.
2. The bridge suites: Rust tests (default, mock and live builds), the Swift bridge tests and the strict integration tests.
3. The E1–E6 tests of §5.4, and the logger tests of the logging spec §9.
4. **Positive check on the experiment executable:**
   - it contains `zag_bridge_configure_live`, `ZagLiveExperimentCampaign` with the authorised campaign ID, the logger and the G3 host as the only anisette host;
   - it does **not** contain the `DEBUG`-only symbols, including `ZagSecuritySigningKeyFactory`, `configureMock`, `ZagFreeAccountSimulation`, `ZagDeveloperPortalSimulation` and `simulationOnly`;
   - no `mock` backend symbols are present.
5. **Negative check:** the result of §4.2 is attached to the build record.
6. The canonical IPA hash is unchanged.

### 4.5 Packaging

- Copy `~/Documents/ZagStore-Package.zsh` to scratch, and change only the output path and name in the copy. The original is never edited.
- Sign with the existing AppTesters certificate, as for IPAs A–D. Bundle `com.cwd43.gu29` is unchanged, so the existing pairing and data are kept.
- **Output:** `packages/private-test/LIVE-EXPERIMENT-<campaign>-<sha8>/ZagStore-LIVE-TEST-<campaign>-<sha8>.ipa`. This directory is ignored by git and never committed or uploaded.
- **Record:** size and SHA-256; branch SHA; library SHA-256; tool versions; check results. All go in the ledger row (E6).

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
| A5 | Expected state before the run: zero development certificates, zero App IDs, zero registered devices. Any other state is a stop (E4). |
| A6 | Used on one device only, the owner's iPhone 15 Pro Max, and in one campaign only. |

### 5.2 Experiment-only safeguards (proposed, in the §3.2 commit)

The budget and the halt are bound to the **campaign** (a fixed ID authorised in writing) and to the **dedicated account**, not to an installation. The design has four independent layers, and any one of them blocks a second certificate:

| Layer | Where the state lives | Survives | Lost by |
|---|---|---|---|
| **Device ledger** (E1, E2): the registry, §5.5 | Keychain, `ZagStore.live-test.registry`, `AfterFirstUnlockThisDeviceOnly`, not synchronised | relaunch, rebuild, reinstall (if E5 confirms that items persist after deletion), account switch | device erase, or a Keychain reset |
| **Account pin** (E1) | the device ledger | as above | as above |
| **Account state** (E4) | Apple's own records for the dedicated account | everything on the device | only the owner revoking or deleting outside Zag Store |
| **Campaign ledger** (E6) | `docs/free-developer-accounts/G5-CAMPAIGNS.md` and the build check | everything on the device | nothing: it is the repository's history |

**E1, certificate budget of one, bound to the campaign and the account:**
- **One choke point.** The only code that can send a certificate request is the portal adapter's `submitCertificateRequest`. The experiment wraps it in `ZagCertificateBudget.consume(campaign:accountKey:)`, which runs **before** the bridge call and is not bypassable. A static test (§5.4, T11) proves that no other caller of the bridge's certificate-request operation exists.
- **The ledger record**, a Keychain item keyed by `campaignID` only (not by install ID, account or team), holds:
  - `submissions` (0 or 1);
  - `accountKey`, the hashed account key already used by `ZagAccountOwnershipRecord`;
  - `state`: `probing`, `armed`, `spent`, `closed` or `halted` (§5.5).
- **`consume` refuses** with `.certificateBudgetSpent` unless all of these hold:
  - the record exists and has `submissions == 0`;
  - its state is `armed`;
  - the signed-in account's key equals the pinned `accountKey`, or nothing is pinned yet, in which case this account is pinned now, atomically with the increment.
  - It then writes `submissions = 1` and `state = spent` **before** returning. A write failure refuses the request.
- **What this rules out:**
  - **Switching accounts:** after the pin, any other account is refused (`.experimentAccountMismatch`, which also halts). The budget is per campaign, so a second account never gets a fresh allowance.
  - **A new install ID or a relaunch:** neither touches the record.
  - **Rebuilding with the same campaign ID:** the record persists.
  - **Rebuilding with a new campaign ID:** refused by E6 unless the owner has authorised that campaign.
  - **Retries:** the production retry policy (`ZagPendingSigningKey.maximumAttempts = 3` within 24 h, after a definite refusal) never reaches the bridge, because `consume` refuses.
  - **"Check Again" recovery:** it only reads the listing and never calls `consume`.
- **Removal is refused.** Stored Account Data does not list ledger records, and the experiment build refuses to delete them.

**E2, permanent halt:**
- Any stop rule (§7.3) sets `state = halted` in the campaign's ledger record. It is written before the stop is shown.
- While the record is `halted`, every live operation refuses with `.experimentHalted`, except reading the certificate list for recovery, sign-out and the Stored Account Data inventory.
- **No in-app action clears it**, and neither does reinstalling the same build: the record is keyed by the campaign ID compiled into that build.
- A fresh live experiment needs a new campaign ID, which needs the owner's written reauthorisation (E6) and a new reviewed build.

**E3, no abandonment during a campaign:**
- "Abandon Request…" is disabled for an unresolved certificate request. Abandoning would delete the pending key and let the next signing create a new request; E1 would refuse that request anyway.
- Only "Check Again" (read-only) is allowed.

**E4, account-state check (the account itself as a ledger):**
- Before the first mutating portal call, the campaign is refused and halted unless:
  - the team's certificate list shows **zero certificates**;
  - the App ID list shows zero Zag App IDs;
  - the device list is empty.
- Immediately before `consume`, the certificate list is read again and must still show zero.
- Since Zag Store never revokes, the dedicated account keeps every certificate a campaign issued. After any issuance, every later campaign on that account fails E4, even if every on-device record is lost.

**E5, Keychain durability preflight (strictly fail-closed; revision 3):**
- The device ledger protects across reinstalls only if iOS keeps the app's Keychain items after the app is deleted. That is long-standing behaviour, but it is not a documented guarantee. [live test needed]
- The campaign arms only on **positive proof** that it does. Two stores are compared:
  - the **registry**, a Keychain item (§5.5);
  - a **container marker**, a file in the app's own container, which deleting the app removes.
- The procedure runs without network:

| Launch | Registry probe | Container marker | Result |
|---|---|---|---|
| 1st | absent | absent | Write the probe (registry state `probing`) and the marker. Show "Delete this app, reinstall the same IPA, then open it." Not armed. |
| Relaunch without reinstalling | present | present | Still `probing`; the same instruction. Not armed. |
| After deleting and reinstalling | **present** | **absent** | Proof that the Keychain survived and the container did not. Write `armed` and a new marker. |
| After deleting and reinstalling, Keychain lost | absent | absent | Looks exactly like the first launch, so it writes a new probe and never arms. |

- **Why the app alone can't report failure.** After a Keychain loss, both stores are empty, which is the same as a first launch. The app can't detect the failure, so it never arms on anything but positive proof. Failure therefore always means "not armed".
- **The owner's procedure decides.** The owner performs exactly **one** delete-and-reinstall cycle (build plan P0).
  - If the app then shows "Campaign armed", E5 passed.
  - If it shows the first-launch instruction again, E5 has **failed**. The owner records this, deletes the app and does not repeat the cycle.
- **There is no override.** No setting, gesture, URL scheme or Debug option skips E5, because no `DEBUG` code is compiled in.
- **If E5 fails, the campaign cannot proceed under its existing authorisation.** The campaign is recorded as closed (`INCOMPLETE: durability not proven`) in `G5-CAMPAIGNS.md`. Any alternative, for example relying on E4 and the authorisation window alone, requires all of:
  - a separately documented security review of that alternative;
  - a revised test plan;
  - the owner's explicit approval of a new campaign under it.

  Nothing in this plan is that alternative.

**E6, campaign identity, single use and expiry (revision 3):**

`G5-CAMPAIGNS.md` in the repository is an **administrative** safeguard. It records authorisations, and the build procedure checks it (§4.1, step 6). It cannot constrain an IPA that has already been built. Enforcement inside the binary is specified in §5.5.

The administrative ledger has one row per campaign:
- the ID, a sequential number (`G5-C1`, `G5-C2`, …);
- the owner's written authorisation (quoted);
- the authorisation window (`notBefore`, `notAfter`);
- the dedicated account's label (`A`, not the address);
- the branch SHA, the build nonce and the IPA SHA-256;
- the state: `authorised`, `built`, `running`, or `closed: <class>`.

A campaign is never reused. Each new one needs a new authorisation naming a new dedicated account. E4 refuses any account that a previous campaign used.

### 5.5 Local enforcement inside the experiment binary (revision 3)

**Compiled into each experiment build, as constants:**
- `campaignNumber`: the sequential number of `campaignID`.
- `buildNonce`: 16 random bytes generated by the build procedure (§4.4) and passed as a compile-time constant. Two builds from the same commit therefore differ. The value is recorded in the ledger row.
- `notBefore` and `notAfter`: the authorisation window, at most 7 days and recommended 72 hours.

**One device-wide Keychain item, the registry.**
- Service `ZagStore.live-test.registry`, `AfterFirstUnlockThisDeviceOnly`, not synchronised.
- It is shared by every experiment build, because the bundle ID and access group are unchanged.
- It holds:
  - `highestCampaignNumber`;
  - per campaign: `state`, `buildNonce`, `submissions`, the pinned account key, and the E5 probe and counters.
- **Writes are atomic:** one `SecItemUpdate` of the whole item, then a read-back compared byte-for-byte. A failed write or a failed read-back halts the campaign.
- Ledger records (E1, E2) are fields of this item. The account directory's inventory and "Remove" never list or delete it.

**State machine, enforced by the one function that writes the registry:**

```text
(no record) ─probe→ probing ─E5 proof→ armed ─consume→ spent ─end→ closed
      any state ─stop rule / inconsistency→ halted          (terminal)
      spent, closed, halted never return to probing or armed
```

**Local checks, at every launch and before every live operation:**

| Check | Enforces | Refuses (and halts, where a record exists) when |
|---|---|---|
| C1 Campaign identity | this build and campaign | the registry's record for `campaignID` has a different `buildNonce`. A rebuild, or another IPA claiming the same campaign, can't run it. |
| C2 Single use | one campaign per number | the record's state is `spent`, `closed` or `halted`; live operations other than recovery reads, sign-out and inventory are refused. |
| C3 Monotonic campaigns | an older build can't run after a newer one | `campaignNumber < highestCampaignNumber`. Arming also requires `campaignNumber > highestCampaignNumber`, unless this is the same campaign and build resuming. |
| C4 Window, device clock | expiry | the device clock is outside `notBefore…notAfter` at arming or launch. This check is weak, because the clock can be changed. |
| C5 Window, authenticated time | expiry, independent of the device clock | the `Date` header of the first TLS-verified response from `gsa.apple.com` (the lookup, before any credential is sent) is outside the window, or more than 10 minutes from the device clock. Checked again before `consume`. Only the comparison result is logged. |
| C6 Account pin (E1) | one account | the signed-in account key differs from the pinned key |
| C7 Consistency | tampering or partial loss | a container marker says `armed` or later for this campaign, but the registry record is missing or disagrees. A Keychain loss detected without deleting the app halts the campaign; the registry is rewritten as `halted`. |
| C8 E4 account state | a server-side record that survives every local loss | the account shows any certificate, Zag App ID or device before the first mutating call, or any certificate before `consume` |

**Which protections survive which event:**

| Event | Registry (C1–C3, C6, halt, budget) | Container marker (C7) | Window (C4, C5) | E4 (C8) | Administrative ledger |
|---|---|---|---|---|---|
| Relaunch | survives | survives | applies | applies | applies |
| Delete and reinstall the same IPA | survives (proven by E5 before arming) | lost, by design | applies | applies | applies |
| Rebuild with the same campaign ID | survives; C1 refuses (nonce differs) | lost if the app was replaced | applies | applies | the build check refuses (`built` already) |
| A **previously built IPA launched again**, its campaign spent, closed or halted | survives; C2 refuses | lost | applies | applies | the row is closed |
| A previously built IPA for an **older** campaign, after a newer campaign armed | survives; C3 refuses | lost | applies (the older window has usually expired) | applies | closed |
| A previously built IPA **never armed**, newest number, still inside its window | no record yet: it can arm through E5 | — | applies | applies | the row is `built`; §8.3 deletes the IPA |
| Account switched in the app | survives; C6 refuses and halts | survives | applies | applies to the new account | — |
| **Device erase**, or Keychain reset | **lost** | lost | **applies**: C5 uses Apple's authenticated time | **applies**: the account keeps any certificate, App ID and device a campaign created | applies |
| Device clock changed | survives | survives | C4 is defeated; **C5 still applies** | applies | applies |

**What a device erase leaves exposed:**
- A still-held IPA for a campaign whose window hasn't expired could be reinstalled. It would pass E5 again, because erase wipes the Keychain, and it would arm.
- Before any credential is sent, C5 refuses if the window has passed.
- Inside the window:
  - if the earlier run made any portal change, C8 refuses before any mutating call;
  - if it stopped before any portal change (for example during 2FA), sign-in and read-only calls could run again, but no certificate beyond the first could be issued.
- **Mitigations:** the short window, and deleting the IPA when the campaign closes (§8.3). This is listed in §10 as a residual risk.

### 5.3 Existing safeguards relied upon (G4 scope)

- **Certificate journal:**
  - `ZagPendingSigningKey.submissionUnconfirmed` is set before every request.
  - An outcome that can't be confirmed becomes `certificateRequestUnresolved`, which blocks further requests for that account and team.
  - Recovery reads the listing (`resolveUnconfirmed` → issued, notIssued or unknown) and matches by proof of possession.
- **Exclusivity:** one certificate operation per account and team (the actor's `busyScopes`), and cancellation-aware waiting (#35, §13).
- **Keys:**
  - A software RSA key in the Keychain (`AfterFirstUnlockThisDeviceOnly`, not synchronised, `kSecAttrIsExtractable: false` requested).
  - The new key is swapped in only after its certificate is verified.
  - What this does and does not guarantee is in the logging spec §4.7.
- **Limit reached:** `certificateMustBeRevoked` is offered by the production UI, but in the experiment it is a **stop**. No revoke exists in the bridge.

### 5.4 Budget tests (finding 7), required before the experiment build

- **Harness.** The strict integration harness (`ZagStrictSigningIntegrationTests.swift`): the scripted portal, a real `ZagFreeAccountProvisioner`, and an injectable in-memory Keychain that persists across provisioner instances.
- **Setup.** Every test runs against one campaign ledger, and asserts that the scripted portal saw **at most one** certificate-request call in total. "Refused" means `.certificateBudgetSpent` (or the named error), with no request reaching the portal.

| # | Path | Expected |
|---|---|---|
| T1 | A normal first request | 1 request; ledger `spent`, account pinned |
| T2 | A second provision, same account and team, after issuance | refused |
| T3 | Definite refusal by Apple, then a production retry (`allowsRetry` true) | the retry is refused; 1 request in total |
| T4 | Cancelled **before** the send (while waiting in `exclusively`) | 0 requests; budget not consumed; a later request is allowed once |
| T5 | Cancelled **after** `consume`, before the bridge returns | budget consumed (`spent`); journal `unresolved`; halt set; later requests refused |
| T6 | Lost response, then Check Again → `notIssued`, then signing again | the re-request is refused |
| T7 | Unresolved → abandon (forced past E3 in the test) → new key and request | refused |
| T8 | Relaunch: new provisioner and new process state, same Keychain | refused |
| T9 | Simulated reinstall: preferences wiped, a new `installID`, same Keychain | refused; halt and pin preserved |
| T10 | Account switch: sign out, sign in to a second (scripted) account | refused with `.experimentAccountMismatch`; halt set |
| T11 | Static: the bridge's certificate-request operation is referenced only from `submitCertificateRequest`, and that is called only through `consume` | a source scan finds exactly one call site each; a mutant that bypasses it fails the suite |
| T12 | Concurrent provisions on two teams of the same account, and on two accounts | 1 request in total; the others refused |
| T13 | A new campaign ID in the same Keychain, scripted portal showing one existing certificate | E4 refuses before `consume` |
| T14 | Halted ledger: every live operation | refused, except the certificate-list read, sign-out and inventory |
| T15 | Ledger write fails during `consume` | request refused; 0 requests |
| T16 | Stored Account Data "Remove All" | ledger records untouched |

Each test also runs against a mutant that removes the `consume` call, which must fail the suite.

## 6. Signing and installation sequence

This is `SUPERVISED-EXPERIMENT-SEQUENCE.md` §2, with preflight steps and the safeguards added. "Stop" means: cancel, halt (E2), sign out, export the failure report, and follow §8.

| # | Step | Component | Expected | Logged phase |
|---|---|---|---|---|
| P0 | Install the experiment IPA and open it; C1–C4 pass; then **exactly one** delete-and-reinstall cycle (E5) | E5, §5.5 | "Campaign armed"; banner shows `armed`. The first-launch instruction again is an E5 failure: stop, and the campaign is closed. | `build`, `campaign` |
| P1 | Confirm the "LIVE TEST" banner, the campaign ID and the branch SHA | — | match the ledger row | `build` |
| P2 | Pairing and LocalDevVPN health check (Settings → Installation → Diagnostics); Developer Mode on | existing RPPairing | all stages pass | `transport.preflight` |
| **P3** | **Read-back preflight:** Installed Profiles (Read Only) → Read, before any live operation (finding 6) | RPPairing misagent reader (PR #25, in `main`) and `ZagInstalledProfileCheck` | the reader returns the installed profiles, and Zag Store's own embedded profile is **VERIFIED** (as in device test A) | `readback.preflight` |
| P4 | Owner confirms A1–A6 | — | yes | `preflight.account` |
| 1 | Sign in with password; complete 2FA (trusted device, or SMS once) | `ZagFreeAccountAuthenticator` → bridge → `zag-isideload` | `awaitingTwoFactor` → signed in | `anisette.*`, `auth.*`, `net.*` |
| 2 | Team | team listing | exactly one team, free limits applied (kind `unknown`) | `portal.teams` |
| 3 | E4 account-state check | portal reads | zero certificates, Zag App IDs and devices | `cert.preflight`, `portal.*` |
| 4 | Register this iPhone (UDID from the existing pairing; never shown or logged) | `registerDevice` | device appears; one device | `portal.device` |
| 5 | E4 re-read, then `consume` (E1), then **one** certificate request | provisioner and Keychain key | issued; proof-of-possession match; ledger `spent` | `cert.*` |
| 6 | App ID and profile for `com.zagstore.livetest.hello` | `registerAppID`, `profile(for:)`, `ZagProvisioningProfileCheck` | profile passes: team, bundle, certificate, device, about 7-day expiry | `portal.appid`, `profile.*` |
| 7 | Sign the test app with the Keychain key | `ZagFreeAccountSigningAdapter.signWithKeychainKey` → Zsign `signComponents` (strict) | signature and Zsign verification pass; no key file written | `sign.*` |
| 8 | Install | `ZagFreeAccountRPPairingInstaller` → existing `installGate4IPA`, unchanged | installed; app launches and shows its screen | `install.*` |
| 9 | Read back the test app's profile: Installed Profiles (Read Only) → Read | as P3 | **VERIFIED**: the test app's installed profile matches the one used to sign | `install.verify` |
| 10 | Sign out; Stored Account Data inventory | authenticator; `ZagStoredAccountDataView` | session and identity items removed; only expected items remain, and ledger records are not listed | `auth.signout`, `inventory` |
| 11 | Export the report (owner, share sheet) | logger | report passes the exporter's schema validation | `report` |

**Read-back results are kept distinct (finding 6).** The reader and `ZagInstalledProfileCheck` give one of:

| Result | Meaning | Counts as success? |
|---|---|---|
| `verified` | The device returned its installed profiles, and the expected profile (UUID, team, App ID, expiry) is among them | **Yes, the only success** |
| `mismatch` | A profile with the expected UUID is installed, but a checked field differs | No: stop |
| `notVerified` | The device returned its installed profiles, and the expected one is absent | No: stop |
| `unavailable` | The profiles could not be read (pairing, tunnel, misagent or timeout); maps from `ZagInstallVerification.unverifiable` | **No.** It is never reported as success. At P3 it stops the run before any live operation. At step 9 one non-mutating re-read is allowed; if it is still `unavailable`, the outcome is INCOMPLETE (§7.2). |

**Notes:**
- The free-account installer's own `installedProfiles` hook is not wired, and its comment about PR #25 is out of date. P3 and step 9 therefore use the Debug read-back screen, which device test A has proven and which §3.2 item 5 enables in the experiment build.
- The test app is a minimal single-view app: no extensions, frameworks, app groups or non-default entitlements. It is built separately, and its unsigned IPA's SHA-256 is recorded.

## 7. Pass and fail criteria

### 7.1 Pass: all of these must hold

1. Steps P0–11 completed in order, each with its expected result.
2. Exactly one certificate submission; exactly one certificate issued, matched by proof of possession; zero revoked. Ledger `spent`, with the account pinned.
3. P3 `verified`, step 9 `verified`, and the test app launched.
4. The sign-out inventory shows only expected items.
5. The exported report passed schema validation and contains no prohibited data (logging spec §5 and §7). GPT-6 confirms this independently on reading it.
6. No `policy.blocked` event.
7. The canonical IPA hash is unchanged afterwards.

### 7.2 Outcome classes

| Class | Meaning |
|---|---|
| **PASS** | §7.1 holds |
| **INCOMPLETE** | Everything in §7.1 holds except that step 9 stayed `unavailable` after one re-read. The installation is **not** verified, and this is not a pass. The campaign is closed. A later read-back with a new decision may upgrade the evidence, but never the class. |
| **SAFE STOP** | A stop rule fired, nothing ambiguous remains, and the invariants held. A useful result, not a failure of safety. |
| **UNRESOLVED STOP** | Stopped with `certificateRequestUnresolved` or another ambiguity outstanding. Follow §8.2 and decide later. |
| **SAFETY FAILURE** | Any invariant in §1 was violated: a second certificate request reached the portal, a revocation, a credential in any output, a request to a non-allowed host that was not blocked, a canonical IPA change, or `DEBUG`-only code found in the experiment binary. Halt all free-account work and send it to G4 review. |

Every class closes the campaign (E6). None leaves a reusable allowance.

### 7.3 Stop rules (each sets the E2 halt)

**Preflight:**
- E5 not armed;
- any of C1–C8 refusing (§5.5);
- P2 health check fails;
- P3 read-back is anything other than `verified`;
- the ledger record is not `armed`.

**Authentication:**
- two consecutive failures of any kind;
- a lock, rate-limit or "too many codes" response;
- an unexpected prompt on the trusted device;
- an unrecognised 2FA kind;
- `.experimentAccountMismatch`.

**Network:**
- any `policy.blocked` event, for example a lookup URL outside `APPLE_HOSTS` or an `idmsa.apple.com` redirect;
- a TLS failure.

**Anisette:**
- provisioning failure;
- headers failing `ZagAnisetteData(validating:)`.

**Team:** zero, several, or a paid team.

**Certificate:**
- E4 shows existing certificates, App IDs or devices;
- `certificateMustBeRevoked`;
- `certificateRequestUnresolved`;
- a proof-of-possession mismatch;
- `certificateBudgetSpent`;
- a ledger write failure;
- any timeout, cancellation or app termination between `consume` and the result.

**Device:** device limit; a different device appearing.

**App ID and profile:** any `ZagProvisioningProfileCheck` problem; identifier unavailable; App ID capacity.

**Signing:** a signature or Zsign verification failure; any key file written.

**Installation:**
- install refused;
- install result unknown;
- launch failure;
- read-back `mismatch` or `notVerified`.

**Anything the owner does not recognise.**

**Retry rule:**
- No step is retried without a new decision.
- Only the non-mutating reads may be run once more: the E4 lists, Check Again, and the P3 or step-9 read-back.
- A halted campaign is never resumed. It is closed.

## 8. Rollback procedures

### 8.1 On the device (every outcome)

1. Sign out in the app (`auth.signout`).
2. Open Stored Account Data. Remove only the live-test **account** items it lists. Ledger records are not listed and are kept, so the halt and the spent budget persist. Record the counts, not the contents.
3. Delete the test app `com.zagstore.livetest.hello`.
4. Export the report, then clear the experiment log (logger `clear`).
5. Reinstall the canonical IPA by AirDrop → Library → Install, as after device tests A–D. Data is kept because the bundle ID is unchanged. The canonical build ignores the live-test namespace.
6. Confirm the pairing and the production app work: the Settings → Installation health check.

### 8.2 On the Apple Account

- **Certificate:** left in place. Zag Store never revokes it, and it expires on its own (expiry recorded from the listing). It is also what makes E4 refuse any later campaign on this account.
- **Unresolved request:** left unresolved. "Check Again" may be run once later with a new decision. "Abandon" needs a separate owner decision, outside the campaign.
- **App ID:** counts against 10 per 7 days until it expires. It is not deleted.
- **Device registration:** stays.
- **If compromise is suspected:** the owner changes the dedicated account's password on an Apple device. This also invalidates the session.

### 8.3 In the repository and on the Mac

- Close the campaign row in `G5-CAMPAIGNS.md` with its outcome class.
- `experiment/g5-live-test` is never merged. It is deleted after the report is accepted, and its SHA stays in the ledger.
- The bridge library and both derived-data directories are deleted from scratch. The experiment IPA is kept in `packages/private-test/` (ignored) until the report is accepted, then deleted, with its hash recorded. This prevents reinstalling a closed campaign's build.
- The canonical IPA hash is checked again and recorded.

## 9. What this plan does not cover

- Extensions, multiple apps, a second account, refresh or re-signing within 7 days.
- Automatic refresh, background tasks, Shortcuts.
- Any production UI (`ZagAppleAccountsFeature` stays off).
- Changes to the network policy, BYOC, the AppTesters signing service or the websites.

These follow a PASS through separate decisions.

## 10. Residual limitations (revision 3)

- **Device erase or Keychain reset.**
  - The registry is lost (§5.5).
  - What still applies:
    - C5 expiry, checked against Apple's authenticated time;
    - C8, the account's own certificates, App IDs and devices;
    - the administrative ledger;
    - deletion of the IPA.
  - The exposure: a still-held IPA inside its window, for a campaign that stopped **before any portal change**, could repeat sign-in and read-only calls. It could not issue a certificate the account doesn't already block.
- **E5** depends on observed iOS behaviour. It is strictly fail-closed: no proof, no campaign.
- **C5** trusts the `Date` header of a TLS-verified Apple response, received before any credential is sent. An attacker would need to defeat TLS to forge it.
- **Revocation outside Zag Store.** If the owner revokes the certificate in Xcode or on Apple's website, C8 can no longer see it. The registry and the window still apply.
- **The administrative ledger** controls what gets built and recorded. It cannot reach into a built IPA; §5.5 does that.
- **Someone with the source and the signing certificate** can always build a binary without these checks. The safeguards protect against mistakes and reuse, not against the owner deliberately bypassing them. That is the owner's own risk to manage.

## 11. Approvals checklist (all must be recorded before §4)

| # | Approval | Recorded in |
|---|---|---|
| 1 | G1: experiment approved, with amendments (a) and (b) | `FIRST-LIVE-EXPERIMENT.md` |
| 2 | G2: licence review complete | `G2-LICENCE-REVIEW.md` §9 |
| 3 | G3: provider URL, device-serial policy, per-account anisette state, and **live anisette use for this experiment** (stage 3 or an explicit experiment exception) | `ANISETTE-STUDY.md` |
| 4 | G4: independent approval of the stack at its final head | `G4-SECURITY-REVIEW.md` §10 |
| 5 | Merges in §2.2, each approved | the PRs |
| 6 | §3.2 experiment commit, including the E1–E6 tests (§5.4), reviewed by GPT-6 | the commit's review |
| 7 | G6: account ready (A1–A6, yes or no) | `FIRST-LIVE-EXPERIMENT.md` |
| 8 | **G5: owner authorises building campaign `G5-C1`, with its window (`notBefore`, `notAfter`; at most 7 days) and dedicated account label** | `G5-CAMPAIGNS.md` and `FIRST-LIVE-EXPERIMENT.md` |
| 9 | Owner authorises running it, on a stated date | `G5-CAMPAIGNS.md` |

## 12. Revision 3: GPT-6's final two findings on `a8afce89`

| # | Finding | Correction |
|---|---|---|
| 1 | Keychain durability must be strictly fail-closed | E5 arms only on positive proof: the registry probe is present and the container marker absent, after one delete-and-reinstall. There is no override, and failure means "not armed". After a failure, the campaign is closed and cannot proceed under its authorisation. Any alternative needs a separately documented security review, a revised test plan and explicit owner approval. |
| 2 | The GitHub ledger cannot enforce anything in a built IPA | §5.5 specifies the binary's own enforcement: a compiled campaign number, build nonce and window, and a device-wide registry with a one-way state machine. Checks C1–C8 cover identity, single use, monotonic campaigns, window by device clock and by Apple's authenticated time, account pin, store consistency and account state. The table shows what survives relaunch, reinstall, rebuild, a previously built IPA, an account switch, device erase and a clock change. |

The implementation checklist is in `G5-IMPLEMENTATION-CHECKLIST.md`.

## 13. Revision 2: corrections for GPT-6's review of `5839add7`

| # | Finding | Correction |
|---|---|---|
| 1 | The budget could be reset | The budget is bound to a fixed, owner-authorised **campaign ID** (not a random experiment ID) and pinned to one account (E1). It sits behind one choke point. Three further layers back it: the account's own certificate list (E4), Keychain persistence checked by E5, and a single-use campaign ledger in the repository (E6). Reinstalling, relaunching, rebuilding, a new install ID or switching accounts can't restore it. |
| 2 | The halt could be bypassed by reinstalling | The halt lives in the campaign's ledger record, keyed by the campaign ID compiled into the build. No in-app action clears it. Arming requires the E5 durability proof, so the halt is known to survive reinstalling. A new experiment needs a new, owner-authorised campaign and build (E2, E6). |
| 3 | Release with `DEBUG` | Verified the settings with `-showBuildSettings` (§3.3). `DEBUG` would compile 13 app files' debug code (including the key-exporting test factory and `configureMock`) and debug code in 8 Swift packages. **`DEBUG` is removed from the experiment build.** A `#error` forbids it. The three needed screens are enabled explicitly. The negative check is now a separate clean production build using the exact Makefile command, in a fresh derived-data directory, run before any experiment artefact exists, plus a scan of the canonical IPA (§4.2). |
| 4 | `exportable: false` | See logging spec §4.7: the record now states what is requested, what is enforced and what is assumed. |
| 5 | Leak scanner false positives | See logging spec §7: export validation is now schema-aware. |
| 6 | Read-back | P3 read-back preflight added. `verified` is distinct from `unavailable`, `notVerified` and `mismatch`. New outcome class INCOMPLETE (§6, §7.2). |
| 7 | Budget tests | §5.4, T1–T16, each also run against a mutant that removes `consume`. |
