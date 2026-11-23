# GrandSlam sign-in experiment — PREPARED, NOT EXECUTED

Status: **awaiting explicit per-run authorization. Do not contact Apple until
the owner says so.** This is the planned next step after the Phase C on-device
anisette integration (`APPLE-AUTH-PHASE-C-INTEGRATION-2026-11-23.md`). It is the
first step that would authenticate an Apple Account, so it is gated exactly like
the provisioning experiment was.

## Objective

Establish whether Apple's GrandSlam sign-in (`gsa.apple.com … /grandslam/
GsService2`) accepts a SRP authentication from the stock iPhone when the request
carries anisette headers derived on-device from apple-auth's Mac-algorithm ADI
profile — the profile proven in the provisioning experiment and now served by
`ZagOnDeviceAnisetteProvider`. Known risk: `-80045` (anisette/identity
mismatch), the sign-in analogue of the `-29003` barrier; this experiment is how
we would learn whether the on-device profile clears it.

## Scope — exactly one attempt

Allowed, and nothing more:

1. A **test Apple Account** (not the owner's personal account). Username +
   password entered at run time; the password is used once and never stored.
2. The minimum GrandSlam SRP sign-in exchange only: `init` (SRP A) → `complete`
   (SRP M1/M2), carrying on-device anisette headers from the provisioned
   profile.
3. Reuse the existing `ZagAppleAuthMachine` profile (no re-provisioning) and its
   restricted transport (`*.apple.com`, HTTPS, ≤3 requests, no redirect, no
   retry, no background, no fallback provider).

## Explicitly forbidden

- No 2FA/SMS trigger beyond what a single sign-in attempt returns; no automatic
  code submission. If Apple requires 2FA, the experiment **stops and reports**.
- No developer-portal operations, team lookup, certificate creation or
  download, device registration, or provisioning-profile issuance.
- No IPA signing or installation.
- No account session, DSID or token persisted; no retries; no second account.

## Exact request sequence

1. `POST …/grandslam/GsService2` — SRP `init`: send SRP ephemeral A + the test
   username, with on-device anisette headers. Expect a salt + server ephemeral
   B (or an error code).
2. `POST …/grandslam/GsService2` — SRP `complete`: send M1 derived from the
   password. Expect M2 + an `spd`/status (or an error code, e.g. `-80045` /
   `-20101`).

Stop after step 2 regardless of outcome.

## Stopping conditions

Stop immediately and report on any of: a `-80045` (or other) rejection; a 2FA
requirement; any non-sign-in request attempted; >3 requests; a redirect; a
transport error; or success (M2 verified). On success, record only that sign-in
was accepted — do **not** proceed to any developer-services call.

## Expected sanitized outputs

Per request: endpoint host, HTTP status, and the GrandSlam status code only.
Never log the password, SRP secrets, salt, M1/M2, DSID, session token, cookies
or anisette values. Reuse `ZagSensitiveRedactor`. The result records
pass/fail + the status code class, nothing identifying.

## Harness (built, env-gated, not run against Apple)

`docs/free-developer-accounts/apple-auth-prototype/ZagSignInProbe/`. It drives
the **real** Phase C integration, not a parallel implementation:

- `ZagOnDeviceAnisetteProvider` generates fresh on-device anisette, then
- `ZagAppleAuthMachine.signInExperiment(email:password:allowNetwork:)` performs
  one bounded GrandSlam SRP sign-in via apple-auth's `aauth_client_login`, using
  the machine's existing Keychain-backed profile (no re-provisioning). The
  transport is bounded (≤6 requests, no redirects, no retries); a 2FA code
  callback and a phone-selection callback both only *mark and cancel*, so no
  code is submitted and no SMS is triggered. The account session is freed
  immediately; the password is used once and never stored, logged or returned.
- `ZagSignInCredentialStore` keeps the test credentials in the this-device-only
  Keychain, seeded through a `SecureField` entry screen — never via env var,
  argv, log or result file.

Three launch behaviours:

- default launch → credential entry screen (no Apple contact);
- plain launch of the self-check executable → `run(live: false)`, the whole path
  with the transport refused (no Apple contact);
- `ZAG_RUN_SIGNIN=1` → `run(live: true)`, the single authorised attempt.

### Local validation (no Apple contact) — done

Host logic tests cover outcome classification, `-80045`/`-20101` code parsing,
and the unlinked/gated behaviour (15/15). The integration compiles and links for
`arm64-apple-ios`. The offline self-check was executed on the stock iPhone:

```json
{ "mode": "selfcheck", "anisette_fresh": true, "anisette_header_count": 10,
  "credential": "absent", "outcome": "transport-failed", "result": "ran" }
```

i.e. fresh anisette was generated on-device from the provisioned profile and the
sign-in path ran with the transport refused — **zero Apple contact**.

### Sanitized output format (both self-check and live)

A JSON object with only: `mode`, `anisette_fresh`, `anisette_header_count`,
`credential` (`present`/`absent`), `outcome` (`authenticated` /
`two-factor-required (not submitted)` / `rejected(<code>)` / `transport-failed`
/ `not-provisioned`), and `result`. No email, password, SRP value, salt, M1/M2,
DSID, token, cookie or anisette value ever appears.

## What authorization is needed

One sentence from the owner authorizing a single on-device GrandSlam sign-in
attempt with the test Apple Account. On that authorization I will build and
install the entry app, have the test credentials seeded in the Keychain, and
then the live launch (`ZAG_RUN_SIGNIN=1`) is run once — the same discipline as
the provisioning experiment. Until then the harness stays committed in draft and
un-run against Apple.
