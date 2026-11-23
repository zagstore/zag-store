# Phase C — on-device apple-auth anisette integration (2026-11-23)

Turns the verified provisioning success
(`APPLE-AUTH-PROVISIONING-RESULT-2026-11-23.md`) into a production-quality,
on-device anisette provider behind the existing `ZagAnisetteProvider.onDevice`
kind. **Production free-account authentication stays disabled** — this adds the
machine-identity (anisette/ADI) path only; the GrandSlam sign-in gate is still
closed (see `APPLE-AUTH-SIGNIN-EXPERIMENT-PLAN.md`).

## What was built

- **Vendored library** `AppleAuthCore/apple-auth/ZagAppleAuth.xcframework`
  (device arm64 static library + Clang module `ZagAppleAuth`), rebuilt
  reproducibly by `build-apple-auth.sh` from pinned upstreams (apple-auth
  `98c862f7` v0.1.3 MIT, Mbed TLS v3.6.2, nlohmann-json v3.11.3). No Android
  library, Unicorn, desktop companion or external anisette server; core links
  only Mbed TLS.
- **`Feather/Utilities/FreeAccount/ZagAppleAuthMachine.swift`** — the on-device
  machine identity. Owns the ADI provisioning profile only; never an Apple
  Account password, session token, DSID or signing key. State is persisted in
  the this-device-only Keychain (`ZagAppleAuthMachineStore`, its own service,
  never synchronised), separate from the account secret store. A restricted
  `URLSession` transport (`*.apple.com`, HTTPS, ≤3 requests, no redirects, no
  retries, no background); with `allowNetwork == false` it refuses every
  request, so deriving headers from an existing profile is provably offline.
- **`ZagOnDeviceAnisetteProvider.swift`** — a `ZagAnisetteProvider` for the
  `onDevice` kind. Each call derives fresh `X-Apple-*` / `X-Mme-*` headers and
  wraps them in a validated, ≤60 s `ZagAnisetteData`. Deriving never contacts
  Apple; `allowProvisioning` (an authorised live step only) permits one
  provisioning exchange when no profile exists.
- **Catalogue + factory** — `ZagAnisetteProviderCatalogue.onDevice` and
  `ZagAnisetteProviderFactory`, passed as the `ZagAnisetteBroker`'s `make`
  closure.

## Gating (disabled in production)

Two independent gates, both off by default:

- `ZagAppleAuthADI.isEnabled` — needs `ZAG_APPLE_AUTH_ADI`, set only in an
  experiment build.
- `ZagAnisetteLive.isEnabled` — the existing `ZAG_LIVE_EXPERIMENT &&
  ZAG_APPLE_BRIDGE && ZAG_ZSIGN_STRICT && !DEBUG`.

The broker uses the on-device provider only when both are true; otherwise it
falls back to `ZagDisabledAnisetteProvider`, which throws
`liveProvidersDisabled`. A normal (production) build defines neither flag, so
the factory returns `nil` and nothing links or runs. BYOC, AppTesters and the
existing signing paths are untouched.

## Verification

- **Host logic tests** (`scripts/test-zag-on-device-anisette.sh`): 10/10 pass —
  catalogue, gating, header shaping, `ZagAnisetteData` validation/freshness,
  provider-when-unlinked, broker fallback.
- **Actual iOS build**: the production integration + the on-device validation
  harness compile *and link* for `arm64-apple-ios` against the real
  `ZagAppleAuth` module (`-lZagAppleAuth -lc++ -framework CoreFoundation
  -framework Security`).
- **On device (stock iPhone 15 Pro Max, iOS 27)**: the real
  `ZagOnDeviceAnisetteProvider` → `ZagAppleAuthMachine` derived fresh anisette
  from the profile the one authorised provisioning experiment produced,
  migrated into the Keychain store, with **zero network requests**. Sanitized
  result (header *names* and counts only):

  ```json
  { "result": "ok", "library": "0.1.3", "fresh": true, "header_count": 10,
    "network_requests": [],
    "header_names": ["X-Apple-Client-App-Name","X-Apple-I-Client-Time",
      "X-Apple-I-MD","X-Apple-I-MD-LU","X-Apple-I-MD-M","X-Apple-I-MD-RINFO",
      "X-Apple-I-TimeZone","X-Apple-Locale","X-MMe-Client-Info","X-Mme-Device-Id"] }
  ```

  The `X-Apple-I-MD` (one-time password) and `X-Apple-I-MD-M` (machine id) pair
  — the anisette values Apple's sign-in services expect — are generated locally
  on the device from the provisioned profile. No Apple contact occurred.

## What remains gated

Machine anisette only. The next step is the GrandSlam **sign-in** experiment,
which is *prepared but not executed* and needs explicit per-run authorization
before any Apple contact. Nothing here performs sign-in, 2FA, developer-portal
operations, certificate creation, device registration or IPA installation.
