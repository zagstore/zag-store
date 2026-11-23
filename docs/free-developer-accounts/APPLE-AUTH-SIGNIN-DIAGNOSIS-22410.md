# GrandSlam -22410 — offline diagnosis (2026-11-23)

Root-cause assessment of the single live sign-in attempt
(`rejected(-22410)`). No Apple contact, no retry, no credential handling, no
re-provisioning. Evidence is apple-auth's source (pinned `98c862f7`), our
integration, the sanitized result, and public implementations.

## Findings

### 1. `-22410` is Apple's genuine error code, extracted faithfully — HIGH
`src/client/authentication.cpp` `status()` reads `response["Status"]["ec"]` and,
when non-zero, throws `Apple authentication rejected (code <ec>)`; the login
wrapper re-wraps it as `GrandSlam <op>: …`. So `-22410` is Apple's own `ec`
value from the GrandSlam response, not an apple-auth or Zag Store classification.
**Not a parsing or classification defect.**

### 2. It is not our request construction — HIGH
We call apple-auth's own `aauth_client_login`; apple-auth builds the request,
`cpd` (`client_data`) and headers (`authentication_headers`) itself. Our iOS
transport only ferries bytes to `*.apple.com`. There is no request-shaping code
of ours that could differ from upstream. `authentication_headers()` *requires*
the six anisette headers (`X-Apple-I-MD`, `-M`, `-MD-LU`, `-MD-RINFO`,
`X-Mme-Device-Id`, `X-MMe-Client-Info`); our provider supplied all of them (the
on-device result showed 10 headers incl. these six), so the request passed
apple-auth's own anisette precondition and reached Apple's auth logic.

### 3. It is a well-formed HTTP 200 rejection, not the common edge failures, and
not wrong-credentials — HIGH
`status()` runs only after `require(response.status == 200)` and a successful
plist parse. So Apple returned a normal GSA plist carrying `ec = -22410` — this
is **not** the HTTP 503 (Xcode sub-identity in client-info) or 429 (rate-limit)
failures that dominate the current ecosystem reports, and **not** `-20101`, the
documented "incorrect Apple ID or password" code. Our client-info uses the
iPhone/akd preset (`<iPhone15,2> <iPhone OS;17.4;21E219> <com.apple.AuthKit/1
(com.apple.akd/1.0)>`), not the Xcode identity that triggers 503s.

### 4. The exact meaning of `-22410` is undocumented — UNKNOWN (not guessed)
apple-auth has no error-code table (it surfaces Apple's `ec` directly). Public
search found `-20101` (bad credentials) but **no** source defining `-22410`
(theapplewiki is 403; TN3107 is the Sign-in-with-Apple REST API, not GSA). We do
not assign it a meaning. What we can say is bounded: a server-side,
account/policy-class rejection returned in a valid GSA response.

### 5. The failing stage was not recorded — the first attempt's gap
Our first result captured only the code, not whether the `ec` arrived at SRP
`init` or `complete`. By analogy with `-20101` (which Apple returns at `init`,
without `sp`), an account/policy `ec` like `-22410` is **plausibly** an
init-stage (pre-password) rejection — but this is an inference, **LOW–MEDIUM**
confidence, and is exactly what the next attempt should settle.

## Smallest corrections implemented (offline, this branch)

- `ZagAppleAuthSignInReport` now carries `stage` (lookup / srp-init /
  srp-complete, derived from the request count) and `requestCount`, so the next
  attempt locates the rejection without exposing any request content.
- `grandSlamCode` now matches only a negative integer (an `ec`), so an HTTP
  status or SRP iteration count can never be misread as a rejection code; a new
  `grandSlamHTTPStatus` + `.httpError(status:)` outcome distinguishes the
  503/429 edge failures from a GrandSlam `ec` rejection.
- Host tests extended (19/19); compiles and links for `arm64-apple-ios`.

## Account setup to verify first (offline, no password, no sign-in)

GrandSlam sign-in for developer/sideload use generally needs: a full Apple
Account (not managed/child), **two-factor authentication enabled**, the current
Terms & Conditions accepted, and ideally one prior interactive sign-in. These
are checkable in the test account's settings without a password or another
attempt. `-22410` being an account/policy-class `ec` (finding 3/4) makes account
state the first thing to rule out.

## What one next supervised attempt would establish

With the stage/count capture above, one attempt would show whether `-22410`
arrives at **SRP init** (a pre-password account/policy rejection — points at
account state/T&Cs/eligibility) or **SRP complete** (password/account-
verification stage). That single bit, plus confirming the account's 2FA/T&C
state beforehand, should localize the cause.

### Optional, higher-signal (needs approval; modifies vendored apple-auth)
Patch `status()` to include Apple's human-readable `em` string in the thrown
message (generic, non-credential; email-like substrings redacted before
surfacing). One attempt would then return Apple's own description of `-22410`.
Not applied yet, because it changes the vendored library and its reproducible
build.
