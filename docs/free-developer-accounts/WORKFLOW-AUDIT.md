# Free-account signing/install workflow — 11-stage audit (2026-11-23)

Purpose: for each stage of signing and installing an IPA with a **free** Apple
Account (no paid Developer Programme, no desktop companion, no Android
dependency), record where the stage is implemented locally, what already
validates it offline, and what — if anything — is missing as **local**
integration versus what remains blocked on **live Apple** behaviour.

Scope held during this audit: no live Apple sign-in, provisioning, certificate
issuance or install was performed; feature gates
(`ZagSigningMethod.developerAccountEnabled`, `ZagFreeAccountSigning.isEnabled`)
stay closed in normal builds; the authentication classifier and the
AppTesters / BYOC / imported-certificate / Zsign / RPPairing flows are
unchanged. Where Apple's live acceptance is uncertain it is marked as needing
live verification rather than asserted.

Legend — **Local**: implemented and offline-validated in this repo.
**Live-gated**: local code complete; real success requires an authorised live
run (G4) that has not been performed.

| # | Stage | Primary implementation | Offline validation | Status |
|---|-------|------------------------|--------------------|--------|
| 1 | Sign-in + two-factor | `zag-apple-bridge` `live::sign_in` + `Prompter` (trusted-device / SMS / request-SMS / cancel); Swift `ZagFreeAccountAuthentication`, `ZagFreeAccountSignInModel` | `test-zag-free-account-sign-in.sh`, `test-zag-free-account-authentication.sh`, bridge 2FA/cancel/expiry/redaction in `test-zag-apple-bridge.sh` | Local ✓ · Live-gated |
| 2 | Anisette provisioning | `zag-isideload` `anisette::remote_v3::RemoteV3AnisetteProvider`; Swift `ZagAnisetteProvider` | `test-zag-isideload-fork.sh` (incl. identity-isolation + diagnostics suites added in PR #54/#55) | Local ✓ · Live-gated |
| 3 | Session persistence | `KeychainStorage` (account-scoped, fail-closed) in bridge; Swift `ZagFreeAccountSecretStore`, `ZagFreeAccountState` | `test-zag-free-account-keychain.sh`, `test-zag-free-account-foundation.sh` | Local ✓ |
| 4 | Team discovery | `PortalRequest::Teams` → `isideload::dev::teams`; Swift `ZagDeveloperPortal.teams` | `test-zag-apple-accounts.sh`, `test-zag-free-account-portal.sh` | Local ✓ · Live-gated |
| 5 | Device registration | `PortalRequest::RegisterDevice` → `isideload::dev::devices`; Swift `registerDevice` | `test-zag-free-account-portal.sh`, `test-zag-device-link.sh` | Local ✓ · Live-gated |
| 6 | App ID registration | `PortalRequest::RegisterAppId` → `isideload::dev::app_ids`; Swift `registerAppID` | `test-zag-free-account-portal.sh` | Local ✓ · Live-gated |
| 7 | Development certificate | `PortalRequest::SubmitCertificateRequest` → `isideload::dev::certificates`; Swift `ZagKeychainSigningKey`, `ZagSigningKey`, `ZagCertificateBudget` | `test-zag-free-account-portal.sh`, `test-zag-apple-bridge.sh`, `test-zag-zsign-real-certificate.sh` | Local ✓ · Live-gated |
| 8 | Provisioning profile | `PortalRequest::Profile` → `isideload::dev` profile issue; Swift profile handling | `test-zag-free-account-portal.sh` | Local ✓ · Live-gated |
| 9 | Zsign signing | `ZagZsignCodeSigner`, `ZagStrictComponentSigning`, `ZsignHandler` | `test-zag-free-account-signing.sh`, `test-zag-zsign-branch.sh` | Local ✓ |
| 10 | RPPairing install | `ZagFreeAccountRPPairingInstaller`, `ZagRPPairingCore` / `ZagRPPairingBridge` (misagent/install transport) | `test-zag-device-link.sh`, `test-zag-install-control-taps.sh` | Local ✓ · Live-gated (needs paired device + LocalDevVPN) |
| 11 | Post-install verification | `ZagInstalledProfileCheck.verify`, `ZagInstallExpectation`, `ZagFreeAccountLifecycle` (wired to RPPairing installed-profile readback, commit `94cd58f6`) | `test-zag-free-account-signing.sh`, `test-zag-installed-release.sh` | Local ✓ · Live-gated |

## Findings

1. **No missing local integration.** Every one of the 11 stages has real
   (non-simulation) local code and an offline suite that exercises it. The
   repo contains no `TODO`/`unimplemented`/`fatalError` stub in the
   free-account path; the only "not yet" strings are documentation or the
   deliberate campaign placeholders that refuse by design
   (`ZagLiveExperimentCampaignConstants`). Consistent with the project rule,
   no fix was fabricated for already-correct code.

2. **The orchestration already exists** end to end: `ZagFreeAccountLifecycle`
   (sign → install → verify) and `ZagASCSigningCoordinator` drive the real
   signer and the real installer; `ZagLiveExperimentView` is the gated UI
   entry. These are reused — no parallel pipeline was added.

3. **The genuine gap is live Apple acceptance, not code.** Stages 1, 2, 4–8,
   10 and 11 are marked Live-gated: their success depends on Apple's live
   sign-in, anisette provisioning, portal writes and the on-device install
   transport, which are held behind G4 authorisation and the closed feature
   gates. This audit did not and must not assert that Apple accepts the
   workflow; see `LIVE-VALIDATION-PROCEDURE.md` for the single authorised
   procedure that would establish that, and `ANISETTE-STUDY.md` /
   `G2-LICENCE-REVIEW.md` for the provider and licensing preconditions that
   remain open.

4. **Improvement delivered this sprint** (separate PRs, not merged to main):
   PR #54 isolates anisette provisioning state by provider/effective client
   identity (prevents cross-identity reuse); PR #55 adds typed,
   privacy-preserving provisioning-failure diagnostics (stage + allow-listed
   numeric code, no message/blob/identifier exposure). Neither claims to
   resolve HTTP 401/503 or ADI -29003.

## How to reproduce the offline audit

`scripts/test-zag-free-account-e2e.sh` runs the per-stage suites above in
workflow order against synthetic fixtures and mock/offline backends (no Apple
contact). `--list` prints the stage→suite map; `--rust` runs only the
Xcode-free stages.
