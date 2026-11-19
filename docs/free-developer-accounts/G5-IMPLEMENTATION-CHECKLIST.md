# G5 implementation checklist (handoff)

Status 19 November 2026: **handoff only. Nothing here is implemented, built or enabled.**

This checklist turns `G5-EXPERIMENT-BUILD-PLAN.md` (revision 3) and `G5-DIAGNOSTIC-LOGGING-SPEC.md` into work items.

**Implementation starts only after:**
- G4 approval of the stack (#35 at its final head);
- the owner's approval to begin G5 implementation.

**Building the experiment IPA additionally needs:** G1, G2, G3 and G6, the §2.2 merges, and the owner's authorisation of campaign `G5-C1`.

## 0. Ground rules for the implementation

- **Branch:** `experiment/g5-live-test` from the post-merge `main` (plan §2.3), as one reviewable experiment commit. GPT-6 reviews it before any build.
- **Every live-enabling change compiles only under `ZAG_LIVE_EXPERIMENT && ZAG_APPLE_BRIDGE && ZAG_ZSIGN_STRICT && !DEBUG`.** Production code paths are unchanged without these conditions.
- **Not touched:**
  - `net_policy.rs`'s `APPLE_HOSTS` and the policy logic (an observer only, item R1);
  - `FeatherApp.swift`;
  - the shared `Info.plist`;
  - the packager original;
  - the canonical IPA;
  - production defaults.
- **No revoke path.** No `mock` feature in app builds. No `DEBUG` in the experiment build.

## 1. Files to modify or add (paths at #35 head `46aaa1c4`)

### Swift: new files (compiled only under the experiment condition)

| # | File | Contents |
|---|---|---|
| N1 | `Feather/Utilities/FreeAccount/ZagLiveExperimentCampaignConstants.swift` | Written by the build check, in its own constants commit: `campaignID`, `campaignNumber`, `notBefore`, `notAfter`, `buildNonce` |
| N2 | `Feather/Utilities/FreeAccount/ZagLiveExperimentCampaign.swift` | The registry (one Keychain item, atomic write plus read-back); the state machine `none → probing → armed → spent → closed`, with `halted` terminal; checks C1–C8; E5 arming with the container marker; the `#error` guards |
| N3 | `Feather/Utilities/FreeAccount/ZagCertificateBudget.swift` | `consume(campaign:accountKey:)`: E1, the single choke point |
| N4 | `Feather/Utilities/FreeAccount/ZagExperimentLogger.swift` | Event schema (§2–§4 of the logging spec), typed fields, per-install `runKey` and ref tokens, `clear` |
| N5 | `Feather/Utilities/FreeAccount/ZagExperimentReport.swift` | Verdict computation; schema validation (§7.1); content rules R1–R7; JSON plus templated Markdown; regenerate-and-compare |
| N6 | `Feather/Views/Settings/FreeAccount/ZagLiveExperimentView.swift` | Banner (campaign, SHA, state), E5 instructions, the export share sheet, the A1–A6 confirmations |

### Swift: existing files to change

| # | File | Change |
|---|---|---|
| M1 | `Utilities/FreeAccount/ZagFreeAccountAuthentication.swift` | `ZagLiveAuthentication.isEnabled` under the condition. Emit `auth.*` events. |
| M2 | `Utilities/FreeAccount/ZagDeveloperPortal.swift` | `ZagLivePortal.isEnabled` under the condition |
| M3 | `Utilities/FreeAccount/ZagAnisetteProvider.swift` | `ZagAnisetteLive.isEnabled` under the condition. Emit `anisette.*` events. |
| M4 | `Utilities/FreeAccount/ZagFreeAccountSigningAdapter.swift` | `ZagFreeAccountSigning.isEnabled` under the condition. Emit `sign.*` events. Before-and-after scan for key files (`keyFileWritten`). |
| M5 | `Utilities/FreeAccount/ZagIsideloadBridge.swift` | `submitCertificateRequest` calls `ZagCertificateBudget.consume` **before** the `call(...)`. Call `configureLive` at launch with the G3 values. Map bridge errors to the `failure` enum. Receive policy and `Date` events from R1/R2. |
| M6 | `Utilities/FreeAccount/ZagFreeAccountProvisioner.swift` | E4 checks (C8) before the first mutating call and before `consume`. Halt on the stop rules. Emit `cert.*` and `portal.*` events. The production retry policy is unchanged; it is cut off by `consume`. |
| M7 | `Views/Settings/FreeAccount/ZagAccountRecoveryViews.swift` | E3: "Abandon Request…" disabled under the condition. Stored Account Data never lists the registry. |
| M8 | `Utilities/FreeAccount/ZagAppleAccounts.swift` | The orphan inventory and removal exclude `ZagStore.live-test.registry`. Account-switch hook for C6. |
| M9 | `Views/Settings/FreeAccount/ZagFreeAccountDebugSignInView.swift` | Split: a live sign-in under `DEBUG \|\| ZAG_LIVE_EXPERIMENT`; the simulation parts stay `DEBUG`-only |
| M10 | `Views/Settings/FreeAccount/ZagAppleAccountsDebugView.swift`, `ZagInstalledProfilesDebugView.swift` | Guard changed to `DEBUG \|\| ZAG_LIVE_EXPERIMENT`. The read-back reports the four results (`verified`, `mismatch`, `notVerified`, `unavailable` with a reason). |
| M11 | `Utilities/ZagFreeAccountRPPairingInstaller.swift` | Map `.unverifiable` to `unavailable`. Emit `install.*` events. Correct the out-of-date PR #25 comment. Wiring the `installedProfiles` hook is **not** in scope. |
| M12 | `Utilities/ZagFirstLaunchReporter.swift`, `ZagActivityReporter.swift` | Compile out sending under the condition, inside `launchBecameInteractive()`. `FeatherApp.swift` stays untouched. Confirm whether `ZagInventorySnapshotRecorder` transmits; if it does, do the same in its `start()`. |
| M13 | Settings entry point (where the Debug screens are listed) | One "Live Test" entry under the condition |

### Rust (`AppleAuthCore/`)

| # | File | Change |
|---|---|---|
| R1 | `zag-isideload/src/net_policy.rs` (`Guard::handle`) | An **observer** callback after `permit(...)`, carrying the decision, host, path template, method and block reason. `APPLE_HOSTS`, `permit` and `check_url` are unchanged, and a diff-only test proves it. Compiled only with `live`. |
| R2 | `zag-apple-bridge/src/live.rs`, `ffi.rs`, `include/zag_apple_bridge.h` | Forward R1 events to Swift through a new callback. Report the `Date` header of the first TLS-verified `gsa.apple.com` response (for C5) as a parsed timestamp only. **No new operation can submit a certificate.** |
| R3 | `zag-apple-bridge/src/backend.rs` | Unchanged revoke refusal. A new test: the certificate-request operation exists exactly once in the op table. |

### Scripts and docs

| # | File | Change |
|---|---|---|
| S1 | `scripts/zag-g5-build-check.sh` (new) | Ledger row checks; nonce and constants commit; the window and monotonic number checks; refuses `DEBUG` in conditions; records SHAs |
| S2 | `scripts/test-zag-g5-experiment.sh` and `scripts/ZagG5ExperimentTests.swift` (new) | T1–T16, C1–C8, the E5 state table, L1–L11 |
| S3 | `scripts/test-zag-free-account-release-binary.sh` | New markers: `zag_bridge_configure_live`, `ZagLiveExperimentCampaign`, `ZagCertificateBudget`, `zag-g5-report/2`, the G3 host, `ZagStore.live-test.registry` |
| S4 | `scripts/test-zag-g5-experiment-binary.sh` (new) | Positive and negative symbol checks on the experiment executable (plan §4.4, check 4) |
| D1 | `docs/free-developer-accounts/G5-CAMPAIGNS.md` (new) | The administrative ledger, with columns as in plan §5.2, E6 |

## 2. Safeguards E1–E6 and checks C1–C8: done when

| Item | Done when |
|---|---|
| E1 budget | `consume` is the only caller path to the bridge's certificate-request op (T11). The registry is written before returning. T1–T16 pass, and the no-`consume` mutant fails them. |
| E2 halt | Every stop rule writes `halted` before showing the stop. No code path writes a state out of `halted` (static check plus T14). |
| E3 no abandon | Abandon disabled under the condition (UI test), and refused in the model too (unit test) |
| E4 account state (C8) | Mutating calls refused unless the lists are empty; the certificate list is re-read before `consume` (T13) |
| E5 durability | The four-row table of plan §5.2 is reproduced in tests with an in-memory Keychain and container. No row arms without "probe present and marker absent". No override symbol exists in the binary. |
| E6 identity, single use, expiry | C1–C7 each tested: refuse and halt, with the expected `campaign.check` event (L11). C5 tested with scripted `Date` values: inside, before, after, and skew over 10 minutes. |

## 3. The certificate-submission choke point

- **Only path:** `ZagIsideloadDeveloperPortal.submitCertificateRequest`. Its first statement is `try ZagCertificateBudget.consume(...)`, and only then the bridge `call`.
- **Static proofs (in S2):**
  - the bridge certificate-request op string appears exactly once in Swift;
  - `submitCertificateRequest` on the live portal is called only from the provisioner;
  - the Rust op table has exactly one certificate-request op and no revoke.
- **Behavioural proofs:** T1–T16, each also run against the no-`consume` mutant.

## 4. Logging tests

L1–L11 (logging spec §10):
- schema round-trip;
- the leak corpus, also with the content rules off;
- the false-positive corpus;
- rule coverage;
- failure-mapping totality;
- ref tokens;
- absence from production;
- verification classes;
- key handling (no private-key export API; `privateKeyExportCalls` 0);
- budget events;
- campaign checks.

## 5. Production-binary checks

1. A clean production build at the experiment commit's parent and at the experiment commit (plan §4.2): the exact Makefile `xcodebuild`, a fresh derived-data directory, no extra settings, before the bridge library exists. S3 passes on both.
2. A scan of the canonical IPA's executable with S3. It passes, and the IPA hash is unchanged at `67d1a79b…eacb11`.
3. Experiment executable (S4):
   - **present:** live markers, the campaign constants and the G3 host;
   - **absent:** `ZagSecuritySigningKeyFactory`, `configureMock`, the simulations, `simulationOnly` and `mock` symbols.
4. The full regression: 44 suites, the package guard, and the bridge (Rust default, mock and live; Swift; strict integration).

## 6. Acceptance criteria for the implementation (before the G5 build request)

- [ ] The experiment commit is reviewed by GPT-6, with every item in §1 accounted for.
- [ ] §2–§5 all pass, with counts recorded. Nothing is claimed that wasn't executed.
- [ ] `git diff` against post-merge `main` shows no change outside §1's files.
- [ ] Without the conditions, the experiment commit's binary is identical in its scan results to `main`'s.
- [ ] No network contact during any test. The mock backend only, test-only.
- [ ] `G5-CAMPAIGNS.md` holds the owner's authorisation row for `G5-C1`, with the window and account label.
- [ ] Every remaining approval in plan §11 is recorded before §4 of the plan runs.

## 7. Open items for the reviewer and owner

| # | Item | Why it matters |
|---|---|---|
| O1 | `ZagInventorySnapshotRecorder`: does it transmit? | Decides whether M12 covers it. Analytics must be compiled out of the experiment. |
| O2 | C5 skew tolerance (10 minutes) and window length (72 hours recommended, at most 7 days) | The owner's choice, recorded in the campaign row |
| O3 | Constants commit per build (N1) | Gives every build a distinct SHA and nonce. The alternative, a nonce injected without a commit, would break "`git diff` is empty". |
| O4 | E5 depends on observed iOS Keychain behaviour | Fail-closed by design. If it fails, a separately reviewed alternative is required. |
