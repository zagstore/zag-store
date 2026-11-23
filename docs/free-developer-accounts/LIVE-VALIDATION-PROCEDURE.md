# Single live iPhone validation procedure — free Apple Account (prepared, NOT performed)

This document **prepares** one authorised, supervised end-to-end validation of
the free-account sign → sign → install workflow on a real iPhone. It is a
procedure to be run by the owner with explicit approval; **nothing here has
been executed**, and no step may run without the owner's go-ahead. It does not
widen any gate — it names the conditions and steps, and the evidence to
capture, so a single run can either confirm or disprove live acceptance.

Read first (not duplicated here): `GATES-APPROVAL.md` (G2–G5 state),
`G4-SECURITY-REVIEW.md` (credential handling), `ANISETTE-STUDY.md` (provider
precondition), `DEVICE-TEST.md` / `SUPERVISED-SIGN-IN-PLAN.md` (device + sign-in
setup), `G2-LICENCE-REVIEW.md` (licensing, still open).

## Preconditions — all must hold before any step runs

- **Authorisation.** Owner has explicitly approved this specific live run. G4
  approval is recorded. (Absent G4, stop here.)
- **Licensing (G2).** Unresolved per `G2-LICENCE-REVIEW.md`. If G2 is not
  cleared for the chosen anisette path, this run does not proceed.
- **Provider (G3 / anisette study).** A recommended anisette provider has met
  the `ANISETTE-STUDY.md` criteria, or the owner has explicitly chosen the
  provider for this run.
- **Build.** A dedicated test build with the free-account path enabled only
  under its compile gate — `ZAG_DEVELOPER_ACCOUNT_LIVE_TEST` /
  the experiment conditions — never a release build. Release gates
  (`developerAccountEnabled`, `ZagFreeAccountSigning.isEnabled`) stay `false`.
- **Device.** One iPhone the owner controls, paired, Developer Mode on, and a
  LocalDevVPN connection available for the RPPairing direct install transport
  (stage 10 precondition).
- **Account.** A free Apple Account the owner designates for the test. Not the
  owner's primary account unless they choose it. Credentials are entered on the
  device, never pasted into this chat.

## The run (one pass, stop on first failure)

For each stage, do the action, then capture **only** the privacy-preserving
evidence listed. Stop at the first stage that fails and record the structured
diagnostic (see PR #55 `ProvisioningDiagnostic`: stage, source, HTTP status,
allow-listed code, retryability) — never raw Apple text, blobs or identifiers.

1. **Sign-in + 2FA** — sign in on device; complete the trusted-device or SMS
   challenge. Capture: success/failure, `FailureKind` if any, whether 2FA was
   requested. No password/code is logged.
2. **Anisette provisioning** — observe provider exchange. Capture: provisioned
   yes/no; on failure the `ProvisioningStage` + allow-listed code (e.g. -45061,
   -29003) only.
3. **Session persistence** — confirm the session is stored in the device
   Keychain and survives app relaunch. Capture: present/absent.
4. **Team discovery** — list teams. Capture: team count (not identifiers).
5. **Device registration** — register the test device if absent. Capture:
   registered/already-present; count against the free-account device limit.
6. **App ID** — register the app's bundle ID. Capture: success; count against
   the free-account App ID limit.
7. **Development certificate** — submit the CSR; confirm issuance. Capture:
   issued/already-present; count against the free-account certificate budget
   (`ZagCertificateBudget`), since free accounts are tightly limited.
8. **Provisioning profile** — fetch the profile for the App ID. Capture:
   obtained yes/no; expiry present.
9. **Zsign signing** — sign the IPA with the issued cert/profile via
   `ZagStrictComponentSigning`. Capture: `zsignVerify` ok/failed, nested-bundle
   count.
10. **RPPairing install** — install the signed app over the direct transport.
    Capture: install result; transport availability.
11. **Post-install verification** — read back the installed profile and confirm
    it matches the `ZagInstallExpectation`. Capture: verification verdict.

## Evidence bundle

Collect into one report: per-stage pass/fail, the structured diagnostic for any
failure, and the free-account limit counters (devices, App IDs, certificates)
observed. Exclude passwords, 2FA codes, tokens, cookies, UDIDs, serials, raw
provisioning blobs, full response bodies and sensitive headers — the diagnostic
and limit types already exclude these by construction.

## Safety stops

- Stop immediately on: a provider back-off / rate-limit (twice), an auth
  rejection whose cause is unknown, a certificate-budget exhaustion, or any
  prompt to enter credentials outside the device.
- Do not retry an auth or provisioning failure to "get past" a server
  restriction. Record the diagnostic and stop.
- A single failure is a valid outcome: it tells us the exact stage and category
  without asserting anything about Apple's overall acceptance.

## After the run

Record the result in a dated entry under `docs/free-developer-accounts/` and
update `GATES-APPROVAL.md`. A pass validates only the account, device, provider
and moment tested — not general availability. Do not enable any release gate on
the strength of one run.
