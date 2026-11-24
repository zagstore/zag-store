# Supervised 2FA completion — PREPARED, NOT RUN

E3 Step B established that the legacy `Mac OS X;` identity authenticates through
SRP (HTTP 200 at `srp-complete`, M2 verified) and the test account then requires
2FA. This plan prepares a supervised run to complete the 2FA exchange and retain
the session. No code is requested, sent or submitted until a separate live
authorization and a launch gate added at that time. All three ADI profiles,
PR #63/#64 (draft) and production are unchanged.

## Phase 1 (done) — precise classification

`rejected(4)` was a label artifact (`4 == AAUTH_NETWORK_ERROR`). The classifier
now reports **`two-factor-required (ceiling reached; SRP verified)`** — but only
when a request was refused at the ceiling *after every accepted request returned
HTTP 200*. That condition is the positive, execution-path proof: apple-auth
issues the post-completion (4th) request only after `proof.verify(M2)` and an
unauthenticated `grandslam_account_state` transition (`authentication.cpp:229-
245`), so SRP success is established by the library's control flow, never
inferred from HTTP 200 alone. A genuine network error (no ceiling refusal, or a
non-200 present) is reported as `transport-failed`. Regression tests cover all
four combinations.

## apple-auth's 2FA state machine (exact requests)

After `srp-complete` returns an unauthenticated account-state
(`authentication.cpp:245-379`):

**SMS path**
1. `GET …/secondaryAuth` — read trusted-phone configuration (no delivery yet).
2. *(select_phone callback — no request)*
3. `PUT …/secondaryAuth/verify/phone` — **triggers SMS delivery**.
4. *(two_factor() code callback — no request)*
5. `POST …/secondaryAuth/verify/phone/securitycode` — **submits the code**;
   success confirmed by an `x-apple-pe-token` response header.
6. loop → `GsService2` SRP **init** + **complete** again (re-auth with the PET)
   → authenticated → session returned.

**Trusted-device path**
1. `GET …/trustedDeviceSecondaryAuth` — **pushes the code** to trusted devices.
2. *(two_factor() code callback — no request)*
3. `GET …/validateCode` (with `security-code` header) — **submits the code**.
4. loop → `GsService2` init + complete re-auth → authenticated → session.

apple-auth already erases the code buffer after use (`WipeCode` / `crypto::wipe`)
and requires exactly six digits.

## Separate request ceilings (defined, enforced)

`ZagTwoFactorPolicy` + `ZagAppleAuthRequestClass.classify(url:method:)` assign
every request to a class and enforce independent ceilings:

| class | requests | ceiling |
|---|---|---|
| authentication | lookup, GsService2 init/complete, re-auth init/complete | 5 |
| verificationInitiation | secondaryAuth config, SMS delivery PUT, trusted-device push | 2 |
| codeSubmission | verify/phone/securitycode, validateCode | 1 |

`allows(_:alreadyAccepted:)` is pure and total; a `verificationInitiation`
request is additionally refused unless consent is granted. Tested for each class
boundary and the consent gate.

## Security controls

- **Explicit consent before any delivery (item 2):** a `verificationInitiation`
  request is refused unless `ZagTwoFactorController.consentToDeliver()` has
  returned true for this run. Default (`ZagDenyingTwoFactorController`) denies,
  so nothing is ever delivered automatically (item 6).
- **Secure interactive code (item 3):** the code comes from
  `provideCode()` (a `SecureField`), is handed straight to apple-auth's
  `two_factor()` callback, and is never logged, persisted, argv/env-passed or
  returned; apple-auth wipes its buffer after use.
- **Clean cancellation (item 4):** denying consent refuses the delivery request;
  returning `nil` from `provideCode()` fails apple-auth's six-digit requirement
  — both abort the one `aauth_client_login` call with no retry.
- **No automatic verification (item 6):** consent defaults false and no code is
  defaulted, so a run with the denying controller performs the 3 auth requests
  and stops at the consent gate.
- **Secure session retention (item 7):** on `AAUTH_OK`, the returned session is
  stored by `ZagAppleAuthSessionStore` as opaque bytes in the this-device-only
  Keychain (like the machine profile). The DSID, GrandSlam token and every
  session field are never logged, printed, returned to callers or surfaced in
  diagnostics; callers learn only `hasSession`. (Wired at the live step; the
  store is not invoked by any current path. The exact session-serialization API
  is confirmed when the live gate is added.)

## Offline validation (done, no Apple contact)

Host tests (all pass): the four network-outcome combinations; URL→class for
every endpoint; per-class ceiling boundaries; the consent gate; the denying
controller; and a Keychain session-store round-trip. Compiles and links
`arm64-apple-ios` with the new file included.

## Proposed supervised procedure (awaiting separate authorization)

1. **Offline pre-flight** (zero Apple contact): confirm the legacy profile still
   derives 10 consistent headers and credentials are present.
2. **Add a launch gate** `ZAG_RUN_MACLEGACY_2FA` wiring a real
   `ZagTwoFactorController` (consent prompt + `SecureField` code entry) and the
   policy-aware transport, on the `mac-legacy-experiment` identity.
3. **One supervised live run:**
   - 3 authentication requests (as E3 Step B), then the app shows the account
     state and **asks for explicit consent** before any delivery.
   - On consent: ≤2 verification-initiation requests (Apple delivers the code),
     the user enters it in a `SecureField`, then 1 code-submission request and
     the re-auth init/complete.
   - Ceilings: authentication 5, verificationInitiation 2, codeSubmission 1; no
     retries, redirects or fallback.
4. **Success evidence (not inferred from 200):** `aauth_client_login` returns
   `AAUTH_OK`, i.e. apple-auth verified Apple's M2, completed the 2FA exchange
   (the securitycode response carried `x-apple-pe-token`), and the re-auth
   account-state was `authenticated`. The session is retained in the Keychain;
   the report records only `authenticated: true` + `has_session: true`, never a
   token.
5. **Stop** regardless of outcome; no repeat without fresh authorization.

Objective unchanged: fully standalone on-device authentication — no Android
libraries, no Mac companion, no remote anisette server.

---

## E3 2FA harness — WIRED & PREFLIGHTED (offline), 2026-11-24

The supervised harness is implemented and validated offline; no live 2FA has
run. `ZAG_RUN_MACLEGACY_2FA` is disabled by default.

### Interactive sequence (what the supervised run does)
1. **Authenticate** — 3 GrandSlam requests (lookup, SRP init, SRP complete) on
   the `mac-legacy-experiment` identity, exactly as E3 Step B. No code can be
   delivered here.
2. **Consent gate** — if the account requires 2FA, the first post-completion
   request is refused until the user taps **Consent & send code**. Denying or
   **Cancel** aborts with no delivery.
3. **Choose number (SMS only)** — if Apple uses SMS, the trusted numbers are
   presented and the user selects one (no number is auto-selected). Trusted-
   device 2FA pushes to devices with no selection.
4. **Enter code** — Apple delivers the code; the user types it in a SecureField
   and taps **Submit code** (a separate explicit action). The code is never
   shown back, logged, persisted or written to the report.
5. **Complete** — apple-auth submits the code and re-authenticates; on a
   positive `AAUTH_OK` with valid session material, the opaque session is stored
   in the this-device-only Keychain. **Cancel** is available at every stage.

### Every possible Apple-contacting action (and nothing else)
- `GET /grandslam/GsService2/lookup` — URL-bag lookup (authentication).
- `POST /grandslam/GsService2` ×2 — SRP init + complete (authentication).
- **[consent-gated]** `GET <secondaryAuth>` — SMS config, OR
  `GET <trustedDeviceSecondaryAuth>` — trusted-device push (verification-init).
- **[consent-gated]** `PUT <secondaryAuth>/verify/phone` — SMS delivery
  (verification-init).
- `POST <secondaryAuth>/verify/phone/securitycode` — SMS code submit, OR
  `GET <validateCode>` (security-code header) — trusted-device submit
  (code-submission).
- `POST /grandslam/GsService2` ×2 — re-auth after 2FA (authentication).
Transport is HTTPS-only, `*.apple.com` only, GET/POST/PUT only, no redirects, no
retries. Offline (`allowNetwork` false) refuses all of them.

### Request limits (one bounded sequence, no retries)
- authentication ≤ 5, verification-initiation ≤ 2, code-submission ≤ 1;
  overall ≤ 8. A verification-initiation request also requires consent.

### Success evidence (never inferred from HTTP 200)
`aauth_client_login` returns `AAUTH_OK` and non-empty `aauth_account_session_plist`
material; the report records `two_factor_completed: true`, `session_stored:
true`, and per-class counts — never a code, token or session.

### Offline validation (done)
- Host tests: all pass (classifier, per-class ceilings, consent gate,
  coordinator cancellation, session-store round-trip).
- iOS `arm64` compile + link: clean.
- On-device preflight, network refused (`ZAG_RUN_MACLEGACY_2FA_SELFCHECK`):
  `outcome transport-failed`, `request_count 0`, `stage pre-request` (zero Apple
  contact); mac-legacy 10 consistent headers, credential present; all three ADI
  profiles intact (mac-legacy / mac-experiment / iphone each 10 consistent).

### One-time launch command (awaiting separate authorization)
The signed app is already installed and preflighted. When authorized, run with
the `!` prefix in Claude Code:

```
xcrun devicectl device process launch --device 8A6BBCC0-EA51-5B93-AF9C-578A9D39F89D --terminate-existing --environment-variables '{"ZAG_RUN_MACLEGACY_2FA":"1"}' dev.zagstore.ptteamprobe
```

---

## Live attempt 1 (2026-11-24) — 2FA accepted; our ceiling cut off the last step

One supervised live run (trusted-device 2FA). Sanitized result:

```json
{ "mode":"live-2fa", "request_count":6, "http_trace":[6×200],
  "accepted_by_class":{"authentication":5,"verificationInitiation":1},
  "outcome":"two-factor-required (ceiling reached; SRP verified)",
  "two_factor_completed":false, "session_stored":false,
  "mac_legacy":"10/consistent","mac_experiment":"10/consistent","iphone":"10/consistent" }
```

**Reconstruction (fits the counts exactly).** lookup + SRP init + SRP complete
(3 auth, 200) → consent granted → trusted-device push (1 verification, 200) →
**code submitted and accepted** (200) → re-auth init (200) → re-auth **complete
refused at the authentication ceiling**. `code-submission: 0` while re-auth ran
is the tell: the trusted-device `validateCode` submit is served under
`/grandslam/GsService2`, and the classifier checked that path *before* the
code-submit signal, so it mis-counted the submit as authentication, exhausting
the auth ceiling (5) and refusing the final re-auth `complete`.

**Conclusion.** The code entered was accepted by Apple — the 2FA exchange
succeeded on Apple's side — and our own classifier-ordering bug refused the last
request, so `AAUTH_OK` was never observed and no session was stored. Standalone
on-device authentication through the full 2FA flow is therefore essentially
proven; we did not capture the terminal success only because of our bound.

**Fix (offline, applied).** `classify` now checks the code-submit signal
(securitycode path or `security-code` header) BEFORE the GsService2 rule, so a
GsService2-hosted `validateCode` counts as code-submission. With that, the
trusted-device sequence is auth 5 / verification 1 / code 1 (all within the
5/2/1 ceilings) and the final re-auth `complete` is accepted. A regression test
covers the GsService2-hosted validateCode case; `refusals` (class + reason) is
now in the report to make any future ceiling stop explicit. Re-validated: host
tests pass, arm64 iOS links, on-device preflight (network refused) clean, all
three profiles intact. The fixed app is installed; the live launch command is
unchanged. No further live attempt without separate authorization.
