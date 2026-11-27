# Zag Store 1.0.0 Beta 5 release readiness

## Scope and baseline

The official public Beta 4 v2 release metadata points to the IPA with source identifier `29db51a3`. The public asset was independently downloaded during the prior installer work. Its SHA-256 matched the production-signed manifest and its bundle reported `app.zagstore.ios`, version `1.0.0`, build `4`, and minimum iOS `16.4`. The same source commit is an ancestor of this release candidate. The pre-preparation comparison against `1d348940` spans 597 commits and 393 changed files. At the prior check the signed manifest was already expired. Beta 5 requires its own current signed manifest and published asset after release approval.

| Area | Changes since public Beta 4 |
| --- | --- |
| Native Apple signing | On-device clean-room anisette and Apple sign-in, 2FA, developer sessions, Personal Team discovery, account-scoped developer certificate recovery, profile creation, strict signing and paired installation. |
| Account management | Persistent catalog with explicit active account, separate sign-out and reauthentication, migration from the single-account store, recognized ownership even when an account disconnects. |
| Certificate path | Kept the existing certificate/profile import and signer. Added identity recognition, renewal eligibility and signing-identity display. Ordinary paid certificates and Apple ID signing are selectable independently of the App Store Connect API-key feature. |
| Renewal and batches | Refresh All plans by recorded owner, serializes device writes, coalesces compatible profile handoff, verifies readback and later expiry, reports recoverable failures and uses bounded fallback where appropriate. Update All, Quick Actions and Shortcuts share batch coordination. |
| Maintenance | Automatic profile-only refresh when due and allowed by iOS, opt-in expiration notifications, and ownership-checked running installation management including self-renewal. |
| Interface and reliability | Signing method selection, progress and recovery, Apps inventory and expiry, linked-device and account capacity, certificate labeling, feedback and support navigation, guarded archive handling and cancellation. |
| Release and tooling | Native authentication and Zsign dependencies, compatibility and diagnostic tools, host regressions and private desktop installer development. Experiment, OTA, diagnostic and server scaffolding are outside the user-facing announcement. |

## Credential and migration review

- Native sign-in directs Apple ID authentication and provisioning to Apple through the existing HTTPS transports. The password and verification code are entered for authentication. Session and developer token data are stored in scoped device Keychain entries. No plaintext-password persistence or website credential handoff was found in the native signing path.
- ADI machine state is device-scoped, with separate temporary and permanent account credential scopes. Migration verifies the token’s account identity, copies and reads back credentials before committing the catalog, honors signed-out records, and rolls back completed writes on failure. Explicit activation requires a usable token for a known account. Active selection affects new signing. Refresh consults the recorded owner and does not substitute another account.
- Signing keys, pending requests and installed ownership receipts are keyed by account and team. Certificate-capacity and ambiguous issuance paths preserve existing certificates. Controlled replacement retains explicit consent and matches the selected certificate. Profile-only renewal checks signed application identity, entitlements, certificate, device, and readback. A changed identity or unverified expiry stops renewal.
- The iOS v2 production key registry, signature verifier, discovery, expiry, and rollback implementation are byte-for-byte unchanged against the Beta 4 baseline. Desktop uses the same manifest verifier, system TLS for HTTPS, and the existing pinned Apple Root CA for Apple profile CMS verification. No production keys were accessed.

## Externally signed Zag Store self-renewal

The app can inspect the running executable and its embedded profile. Enrollment additionally needs one connected Personal Team account whose on-device Keychain contains a signing identity with the exact running leaf. A Mac-only key and receipt cannot satisfy that lookup. Signing in on the phone with the same Apple ID leaves this blocker in place. Keep the existing ownership rule.

A future profile-only adoption flow would need a separate, explicit enrollment backed by a fresh Personal Team session, Apple inventory containing the same development leaf, paired readback, and exact signed component entitlements. It would have to verify that an updated profile is accepted, extends expiry, and leaves the original executable signature unchanged. Profile renewal also ends when that leaf expires, is revoked, or no longer appears in the team inventory. The existing desktop install or upgrade is evidence for USB installation, separately from profile adoption.

## Physical evidence and release gates

The operator has reported successful native iOS Apple ID authentication and signing, and successful desktop end-to-end installation and upgrade. The maintenance acceptance record also describes a physical baseline for compatible profile handoff. Those results do not cover the final Build 5 binary, device migration of multiple accounts, mixed-identity refresh, iOS scheduling and notification delivery, paid-certificate install or launch on this candidate, or a desktop-signed copy’s self-renewal. Use the [device acceptance checklist](APPLE-ID-MAINTENANCE-ACCEPTANCE.md) for those cases. Complete acceptance before representing them as physically validated.

## Automated results and remaining verification

- Passed 23 desktop installer tests, 56 Rust tests, 86 strict-signing checks, three DER entitlement comparisons against codesign, and six desktop network diagnostic checks. The desktop release and ADI helpers compiled. The download helper refused an unsafe origin and emitted a redacted TLS error in this session.
- Passed native sign-in and readiness, account activity, batch policy, background refresh, developer services, deep-link routing and installed-release presentation. Offline v2 signature and payload validation passed. Production v2 trust and policy files match the public Beta 4 baseline.
- The broader offline harness passed mock authentication, anisette, portal, device transport and App ID/profile stages. Host Keychain operations failed with OSStatus `-50`, including a minimal disposable-item probe. Simulator access was unavailable, the synthetic PKCS#12 import failed with a CSSM parameter error, and the bridge suite stopped at its anisette-store update assertion. Keychain-backed expiry and golden-vector tests could not complete successfully. The integrated signing harness also stopped at its directory-wide baseline guard. Its sole handler difference from public Beta 4 is the IPA safety check before extraction in `AppFileHandler`. The underlying certificate signer `ZsignHandler.swift` is unchanged and the targeted Zsign suite passed. A paid-certificate signing and launch test on the Build 5 binary remains required.
- Both app target configurations declare build 5. The Release marketing version, bundle identifier, deployment target and Beta channel passed source checks. The unsigned Xcode Release build aborted with file-event and user-cache errors in this session, and the simulator-based update check and app-dependent package guard remain incomplete. No Build 5 IPA was produced. Run local packaging and inspect the generated bundle metadata before candidate device testing.

## Local packaging

From the existing `ZagStore-claude` checkout, with its Xcode and Rust prerequisites available:

```sh
cd "$HOME/Documents/ZagStore-claude" && make iphoneos
```

The local output is `packages/ZagStore.ipa`. This packages the Release target with the canonical bundle ID and no Apple provisioning profile. The local ad-hoc seals are for archive integrity and are replaced by the installation signer. Source build settings specify version `1.0.0`, build `5`, Beta channel and iOS/iPadOS `16.4`. Publication, manifest signing, release assets and website changes are separate release operations.
