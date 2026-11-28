# ZagSignInProbe — GrandSlam sign-in experiment (env-gated, not run)

An isolated, reproducible harness for **at most one** GrandSlam SRP sign-in,
driving the real Phase C integration. See
`docs/free-developer-accounts/APPLE-AUTH-SIGNIN-EXPERIMENT-PLAN.md` for the full
plan, request sequence, stopping conditions and sanitized output format.

## Files

- `ZagSignInExperimentRunner.swift` — the shared run: fresh anisette via
  `ZagOnDeviceAnisetteProvider`, then `ZagAppleAuthMachine.signInExperiment`.
  `live: false` refuses the transport (offline); `live: true` is the authorised
  attempt. Emits a sanitized report (names/counts/classification only).
- `ZagSignInCredentialStore.swift` — test credentials in the this-device-only
  Keychain; never env/argv/log/file.
- `SelfCheckMain.swift` — offline self-check executable (plain launch → no Apple
  contact). Expected `transport-failed` with anisette headers present.
- `SignInAppMain.swift` — the app: default launch shows the secure credential
  entry screen; `ZAG_RUN_SIGNIN=1` runs the single authorised live attempt.

## Build

Compile against `AppleAuthCore/apple-auth/ZagAppleAuth.xcframework` together
with the three integration sources (`ZagAnisetteProvider`,
`ZagAppleAuthMachine`, `ZagOnDeviceAnisetteProvider`) and the two-symbol
`ZagDeadline`/`ZagTransportError` stub, `arm64-apple-ios`. The self-check builds
as a plain executable; the app bundles with the credential-entry UI. Sign into
an app bundle whose id shares the container and Keychain that already hold the
provisioned profile, so no re-provisioning occurs.

## Status

Built and validated locally with **no Apple contact** (host tests 15/15;
compiles+links for iOS; offline self-check ran on the stock iPhone). The live
run is **not executed** and requires explicit per-run authorization.
