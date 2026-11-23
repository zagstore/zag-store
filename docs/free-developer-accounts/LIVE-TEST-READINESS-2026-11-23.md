# Live-test readiness — G2/G3/G4 status, test-build configuration, approval checklist (2026-11-23)

Prepared as part of the integration milestone. It records the **evidence-based**
status of the live-test gates, recommends the first-test provider route,
specifies the dedicated test build, and lays out the G4 approval checklist.
It grants no authorization and enables no gate. Nothing here performs a live
Apple operation.

Sources inspected: `GATES-APPROVAL.md`, `G2-LICENCE-REVIEW.md`,
`G4-SECURITY-REVIEW.md`, `ANISETTE-STUDY.md`, `ISIDELOAD-EVALUATION.md`,
`LIVE-VALIDATION-PROCEDURE.md`.

## Integration validation — HEAD `45a64442` (2026-11-23)

All three sprint PRs are merged into `feature/native-adi-provider-review`:
#54 (`4e899610`, anisette identity isolation), #56 (`51f3cf16`, audit + harness),
#55 (`45a64442`, provisioning diagnostics). `main` untouched.

| Check | Verdict |
|-------|---------|
| iOS Release build (`xcodebuild … -configuration Release`, generic/iOS) | **PASS** (exit 0, BUILD SUCCEEDED) |
| Rust `zag-isideload` tests | **PASS** 53 lib + 2 wrapper |
| Rust `zag-apple-bridge` tests (default / mock / live) | **PASS** 12 / 3 / 8 |
| Clippy (both crates) | **Clean on the merged changes** (only pre-existing warnings in `auth/`/`dev/`; nothing in `known_adi_code`/`diagnostics.rs`; no errors) |
| Offline E2E harness `test-zag-free-account-e2e.sh` | **PASS** all 11 stages (exit 0) |
| Swift: free-account-signing / zsign-branch / certificate-export-disabled / installed-release | **PASS** (exit 0 each) |
| Release feature gates | **Closed** (`developerAccountEnabled`, `ZagFreeAccountSigning.isEnabled` both `#if true` / `#else false`) |
| `test-zag-zsign-real-certificate` | **SKIPPED** — needs real signing material (`ZAG_REAL_APP`/`ZAG_REAL_P12`/…) absent offline; `exit 3` is its skip sentinel, not a failure |
| `test-zag-package-guard` | **N/A offline** — requires two built `.app` arguments + the canonical packager/IPA at `~/Documents`; a provisioned/manual test, not an unconditional offline suite |

**No regression from the merges:** all three changed only Rust (`zag-isideload`,
`zag-apple-bridge`) and docs/scripts; the Zsign signer, RPPairing installer,
AppTesters/BYOC/imported-certificate paths and the packager are untouched, so
the two skipped suites are environmental, not defects.

## G2 — Licensing: **UNRESOLVED**

Two distinct questions must be kept apart: **(A) copyright licensing** of the
code we retain/deploy, and **(B) Apple's service terms** governing Apple's
libraries and services. Both are open; neither is a legal opinion.

### A. Copyright licensing (code)
- **Client (`zag-isideload`).** The licence package (`G2-LICENCE-REVIEW.md`,
  PR #26) is *prepared for an independent reviewer, not reviewed*. The anisette
  client I hardened (`anisette/remote_v3/mod.rs`, `state.rs`) and the `auth/`
  files carry **MPL-2.0** provenance "pending review" (long identical token
  runs vs omnisette/apple-private-apis); `dev/*` are **MIT**-attributed
  (nab138/isideload upstream); Zag Store's own code is GPL-3.0. Decisions A–D in
  §8 of the package are unrecorded.
- **Anisette server — the blocking gap.** The remote path needs a *server*, and
  per `ANISETTE-STUDY.md` stage-4 desk review **neither maintained v3 server
  (`Dadoum/anisette-v3-server`, `SideStore/omnisette-server`) carries any
  licence file** — so there is no grant to deploy or modify either; it needs the
  author's written permission, or a first-party server (new implementation, its
  own approval).

### B. Apple service terms (not a copyright question)
- Every v3 anisette server requires Apple's proprietary Android ADI libraries
  (`libCoreADI.so`, `libstoreservicescore.so`) extracted from the Apple Music
  APK. Whether they may be used this way is governed by **Apple's terms**, not an
  open-source licence, and **fetching them contacts Apple**. This is unresolved
  and is separate from (A).
- Native/Android ADI as an Apple *device identity* is additionally rejected at
  runtime (ADI -29003) — a technical-compatibility fact, discussed under G3.

- **Verdict:** a licence-tracked *client* exists (MPL-2.0/MIT, pending review),
  but **no legally usable anisette *implementation* (client + a licensed server
  that is clear under Apple's terms) is confirmed available** for live testing.
  G2 cannot be declared cleared without a defensible independent review of (A)
  and an explicit decision on (B).

## G3 — Provider: **not yet decided; recommended route = remote anisette client, NOT native ADI**

- **Study in progress — now below threshold.** The `ANISETTE-STUDY.md`
  reliability study (stages 1–2, approved) runs against `ani.sidestore.io` until
  **25 Nov 2026**. The **day-5 passive report (2026-11-23)** has **degraded**
  from the day-2 snapshot: availability **83.44%** (126/151 probes) vs the ≥99%
  threshold, a longest outage of **7.8 h** vs the ≤2 h threshold, and **25 ×
  HTTP 502**; latency is still fine (median 0.50 s, p95 3.40 s). **No verdict is
  given before the period ends**, and stage 3 (live anisette) is **not
  approved**. The bridge refuses to run without an owner-chosen provider URL and
  device serial.
- **Is a licensed, documented provider available? No.** The only studied
  provider is both unlicensed (G2.A) and, on current evidence, failing the
  reliability criteria. There is no alternative licensed public provider
  identified.
- **Native ADI is not the credible first route.** Per PR #49 and
  `ISIDELOAD-EVALUATION.md`, Apple's Android CoreADI libraries are not
  licensable as hosted multi-user auth, and the -29003 end-provisioning
  mismatch is exactly an Android-ADI-vs-claimed-platform rejection. **Do not
  assume Android CoreADI is accepted as an Apple device identity** — the
  ecosystem-wide 401s since 2026-11-17 reinforce this.
- **Recommendation:** the **remote anisette provider (the `remote_v3` client)**
  is the most technically credible and compatible route and the only one with a
  known (if pending) client licence. It is gated on: (1) the study's 25 Nov
  verdict + stage-4 privacy decisions (DNS-only vs proxied TLS, origin
  certificate), and (2) a **licensed server** — the G2 blocker above. It must
  not rely on native/Android ADI for the first test.

## G4 — Authorization & credential security: **prepared, NOT reviewed**

`G4-SECURITY-REVIEW.md` is ready for an independent security reviewer (29-item
§11 checklist + §10 questions); not reviewed; no live Apple service contacted.

**Credential-security verification of the proposed test build (confirmed by
inspection, not a substitute for the independent review):**
- *Confidentiality* — passwords/2FA codes arrive as bytes in zeroising buffers,
  are never stored and never logged; session tokens go to the device Keychain
  and are wiped from bridge buffers after delivery (`zag-apple-bridge` lib
  header; G4 §1 data-flow).
- *Restricted diagnostics* — failures surface to Swift only as a `FailureKind`;
  the new `ProvisioningDiagnostic` (PR #55) carries only enums/integers (stage,
  source, HTTP status, allow-listed code, retryability) — no message, blob,
  token or identifier can serialise (asserted by test). `known_adi_code()`
  recognises only whole-token allow-listed codes.
- *No unauthorised live operations* — in any Xcode configuration the bridge is
  neither compiled nor linked (`ZAG_APPLE_BRIDGE` is set by no configuration);
  the bridge default build fails every call with `disabled` and `net_policy`
  refuses all traffic without the `live-network` feature; the release gates
  (`developerAccountEnabled`, `ZagFreeAccountSigning.isEnabled`) are `false`.

**G4 approval checklist (prepared; the owner/independent reviewer grants, not me):**
- [ ] Independent security reviewer completes `G4-SECURITY-REVIEW.md` §11 (29
      items) against the current integration head and records §10 decisions.
- [ ] §10 open questions decided: anisette host pinning (yes/no); anisette
      device state shared vs per-account.
- [ ] `test-zag-apple-bridge.sh`, `test-zag-isideload-fork.sh` and the release
      scan run by the reviewer.
- [ ] PR #55 (diagnostics) final-merged by its reviewer.
- [ ] Confirmed: the test build sets only the dedicated compilation conditions
      below and leaves the Release configuration unchanged.

## Phase 5 — dedicated iPhone (iOS 27) test build

**Target:** one iPhone on iOS 27 the owner controls; one app, no extensions; a
dedicated free Apple Account (G6); the existing experimental free-account path.
**Do not enable production or release gates** — these are *compilation
conditions set in a dedicated scheme/xcconfig only*, which satisfy the existing
`#if` guards in that build alone and never alter the Release configuration's
`#else false` branches or any source default.

**Compilation conditions for the dedicated test scheme:**
- `ZAG_APPLE_BRIDGE` — links the bridge (set by no shipping configuration).
- `ZAG_ZSIGN_STRICT` — Keychain-resident signing key (required by the guards).
- `ZAG_LIVE_EXPERIMENT` (non-DEBUG) — enables `ZagFreeAccountSigning.isEnabled`
  for the experiment's one test app.
- (Paid developer-account path only, not needed for free-account: the
  `ZAG_DEVELOPER_ACCOUNT_LIVE_TEST` guard, which `#error`s without
  `ZAG_ZSIGN_STRICT`.)
- Rust bridge built with `--features live`; the campaign must be *armed*
  (`ZagLiveExperimentCampaign`) with the owner-chosen provider URL + device
  serial. Release builds set none of these.

**Stage reachability in this configuration (confirmed by code path, offline):**

| # | Stage | Reached via |
|---|-------|-------------|
| 1 | Auth + 2FA | `ZagFreeAccountAuthenticator` → bridge `sign_in` + `Prompter` |
| 2 | Anisette provisioning | `RemoteV3AnisetteProvider` (owner-chosen provider) |
| 3 | Session persistence | device Keychain via `KeychainStorage` / `ZagFreeAccountSecretStore` |
| 4 | Team discovery | `PortalRequest::Teams` |
| 5 | Device registration | `PortalRequest::RegisterDevice` |
| 6 | App ID | `PortalRequest::RegisterAppId` |
| 7 | Certificate | `PortalRequest::SubmitCertificateRequest` + `ZagKeychainSigningKey` |
| 8 | Profile | `PortalRequest::Profile` |
| 9 | IPA signing | `ZagZsignCodeSigner` / `ZagStrictComponentSigning` |
| 10 | RPPairing install | `ZagFreeAccountRPPairingInstaller` (needs pairing + LocalDevVPN) |
| 11 | Installed-profile verify | `ZagInstalledProfileCheck.verify` (wired `94cd58f6`) |

**Failures → safe diagnostics:** every stage reports through `FailureKind` and,
for provisioning, the PR #55 `ProvisioningDiagnostic` (stage + allow-listed
code, no sensitive text). The full stop-on-first-failure run is in
`LIVE-VALIDATION-PROCEDURE.md`.

**Rollback plan:**
1. Stop at the first failing stage; record only its `FailureKind` /
   `ProvisioningDiagnostic`.
2. Uninstall the test app from the device; it shares nothing with release
   installs (separate bundle, separate account).
3. Delete the dedicated test build and its DerivedData; the shipping schemes are
   untouched, so no rebuild of release artifacts is needed.
4. If portal state was created (device/App ID/certificate), note the counts
   against the free-account limits; certificates can be revoked from the account
   if needed. No release certificate or profile is affected.
5. Tear down the anisette study/provider access if it was enabled for the run.
6. Confirm gates still read `false` in Release (`grep` the two gate files).

## Exact remaining prerequisites for the first authorized live test

1. **G2** — independent licence decision on the client **and** a licensed (or
   first-party) anisette server + a decision on Apple's libraries.
2. **G3** — the 25 Nov study verdict + stage-4 privacy decisions; owner chooses
   the provider URL and device serial.
3. **G4** — independent security review completed; §10 questions decided; PR #55
   merged.
4. **G1 / G5 / G6** — owner approves the supervised experiment, the test-build
   plan, and confirms the dedicated account is ready.
5. **Owner's explicit authorization** of the single live run (not granted here).
