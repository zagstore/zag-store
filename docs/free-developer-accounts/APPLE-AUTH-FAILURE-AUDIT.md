# Apple-auth developer-session / login failure audit (offline, 2026-11-24)

Scope: offline source audit of two live failures, no Apple contact. PR #63/#64
stay draft; production unchanged; the authenticated Keychain session and all
three ADI profiles are preserved (read-only inspection only).

## Two failures under investigation

| # | Flow | HTTP | ec | Apple em |
|---|------|------|----|----------|
| F1 | apptokens (stored-session developer-session) | 200 | **-22411** | "This action cannot be completed at this time" |
| F2 | fresh GrandSlam login (SRP) | 200 | **-22406** | "Enter the correct password for this Apple Account." |

Both are **HTTP 200 with a non-zero `Status.ec`** in the GrandSlam response
body, surfaced by `status()` (authentication.cpp): `if ec != 0 throw`. Neither
is a transport/HTTP failure — Apple received a well-formed request and declined
it at the application layer.

---

## 1. apptokens request construction — audited, no defect

`exchange_developer_session` (authentication.cpp:382) builds exactly:

```
POST https://gsa.apple.com/grandslam/GsService2
Request fields: { o:"apptokens", u:<adsid>, app:["com.apple.gs.xcode.auth"],
                  c:<challenge bytes>, t:<GsIdmsToken>,
                  checksum:HMAC-SHA256(sk, "apptokens"+adsid+app), cpd:client_data(headers) }
headers: authentication_headers(fresh anisette) + apply_xcode_headers
```

This matches the documented pyprovision / AltServer `fetchAppToken` /
`apptokens` construction field-for-field: same `o`/`u`/`app`/`c`/`t`, same
`checksum = HMAC-SHA256(session_key, "apptokens" + dsid + app_id)`, same `cpd`
anisette bag. **Confirmed: the request construction is correct and not the
cause of F1.** The request even reached Apple's application layer and returned a
structured `Status` (request_count 1), i.e. it was well-formed enough to be
processed and then declined.

## 2. Token type / service id / session fields / encryption / account state — verified

- **Service id / token**: `com.apple.gs.xcode.auth`, operation `apptokens`;
  response token read from `t["com.apple.gs.xcode.auth"].token` (+ `expiry`).
  This is the Xcode developer-services token, separable from certificate /
  device / App ID / profile issuance (confirmed earlier).
- **Session fields required**: `adsid` (== account_id), `sk` (require exactly 32
  bytes), `c` challenge (require non-empty, ≤4096), `GsIdmsToken`, and account
  state `authenticated` (PET present). All are required *before* the request.
- **Encryption**: response `et` envelope, `"XYZ"` 3-byte prefix as AAD, 16-byte
  GCM IV at offset 3, ciphertext, 16-byte tag; AES-256-GCM keyed by `sk`.
  Standard GrandSlam app-token envelope.
- **Expected account state**: `grandslam_account_state({}, session) ==
  authenticated` is required in both `from_plist` and the exchange.

## 3. Reconstructed vs original session — byte-identical, no material difference

`AccountSession` = `{ account_id, pet, plist }` where `plist` is the **raw
decrypted GrandSlam session bytes**. `aauth_account_session_plist` returns those
bytes verbatim; `aauth_account_session_from_plist` parses the same bytes,
re-requires `authenticated` state, and rebuilds `{adsid, pet, raw bytes}`. The
exchange reads `sk`/`c`/`GsIdmsToken` from `plist`. **The round-trip is
byte-exact — the reconstructed session is materially identical to the original
authenticated session.** That the stored-session exchange reached request_count
1 proves the reconstruction passed every local `require` (adsid match, 32-byte
sk, non-empty challenge, authenticated state). So F1 is **not** a reconstruction
defect; the difference between stored and fresh is only server-side token
*freshness*, not field content.

## 4. Commit 907d8fa3 (fresh-login → developer-session) — audited

- **Ownership/lifetime**: the fresh `session` from `aauth_client_login` is used
  by `exchangeDeveloper` **before** `aauth_account_session_free(session)`, freed
  exactly once, on the owning thread. No use-after-free, no double-free. The
  stored-session path frees its reconstructed `account` via its own `defer`.
- **Classification**: the apptokens `POST /grandslam/GsService2` classifies as
  `.authentication` (not `.verificationInitiation`), so it is **never**
  consent-gated and shares the authentication ceiling.
- **Ceiling**: the combined flow raises `authenticationCeiling` 5 → 6 so a full
  2FA login (5 auth) plus the apptokens exchange (1 auth) fits; verification and
  code-submission ceilings are untouched. Regression tests added.

## 5. Can developer-session trigger unexpected authentication / verification? No — confirmed

`developer_session(client, account)` takes **no credentials, no verification
options and no callbacks**. It issues a single apptokens POST. It cannot run
SRP, cannot invoke the 2FA code/phone callbacks (those exist only on
`aauth_client_login`), and its request is authentication-class so it never trips
the verification-initiation consent gate. **A developer-session exchange cannot
initiate a login or a verification delivery.** Locked by new regression tests.

## 6. Explanations — confirmed facts vs hypotheses

**F1 (-22411), confirmed**: well-formed apptokens request; Apple returned
`Status.ec -22411` em "This action cannot be completed at this time" in a 200;
the stored session was byte-valid and authenticated; construction matches
known-working clients. **Hypotheses (not confirmed offline, undocumented code)**:
(a) server-side staleness of the session's `GsIdmsToken`/challenge by the time
of the exchange — plausible, but the exact 2h43m figure below is the *login*
gap, not a measured token TTL; (b) an account-level precondition for Xcode token
issuance (e.g. never used with Xcode / developer-agreement) — possible but
free-account apptokens generally works in the ecosystem, so weaker; (c) a
transient server condition. We have **not** yet observed an apptokens exchange
from a *fresh* session, so F1's root cause is not isolated.

**F2 (-22406), confirmed**: rejection at `srp-complete`; Apple returned
`Status.ec -22406` em "Enter the correct password"; request_count 3 (lookup /
srp-init / srp-complete), all 200; the identical credential and the identical
`aauth_client_login` code path authenticated successfully earlier the same day;
the password-handling code is unchanged between the two runs. **Hypotheses (not
confirmed offline)**: (a) Apple throttle / soft-lock surfacing as a password
error; (b) the account password was changed or invalidated since the earlier
success; (c) an account security hold requiring web re-validation. The earlier
success makes "password was simply wrong" unlikely, but (a), (b) and (c) are all
consistent with the evidence and **cannot be distinguished offline**. We are
**not** asserting rate-limiting as the cause.

## 7. Corrected timeline (2026-11-24)

- **~10:52** — trusted login **authenticated** in 3 requests; session stored.
  (The 2FA code acceptance was the preceding attempt, ~10:4x.)
- **~13:22 / ~13:27** — two stored-session developer-session exchanges →
  **-22411** (≈ 2h30m after the successful login).
- **13:35** — fresh-login → developer-session: login rejected at srp-complete
  with **-22406** (**2h43m** after the successful login).

(Prior notes said "~45 min"; corrected to **2h43m** between the 10:52 success
and the 13:35 fresh-login failure.)

## 8. Regression tests added

In `scripts/ZagOnDeviceAnisetteTests.swift`:
- apptokens `POST /grandslam/GsService2` classifies as `.authentication`
  (never consent-gated / never a verification initiation).
- authentication class never requires consent (unlike verification).
- combined-flow ceiling: `authenticationCeiling` 6 admits 5 login + 1 apptokens
  and refuses a 7th; verification/code ceilings unchanged.

All host tests pass; the fix compiles and links for arm64 iOS; the combined-flow
on-device preflight (network refused) reports `transport-failed` / request_count
0 with all three profiles intact.

## 9. Preservation

The authenticated Keychain session (`mac-legacy-experiment` scope) and all three
ADI profiles (`device`, `mac-experiment`, `mac-legacy-experiment`) were only
read, never modified or deleted. No credential refresh, no 2FA, no cert/device/
profile/signing. PR #63/#64 draft; production unchanged.

## 10. Decision tree for the next experiment

```
Is the account healthy right now?
├─ Verify OUT OF BAND first (no code change, no our-app Apple request):
│  sign in to appleid.apple.com with the stored password.
│
├─ Password REJECTED on the web too
│     → F2 is a real account-state/password problem, not our code.
│       Resolve the account (reset/unlock) before ANY further live run.
│       No live request justified until the web sign-in succeeds.
│
├─ Password ACCEPTED on the web, but a security prompt / lock was shown
│     → clear it on the web; treat as throttle/hold. WAIT (hours), then one run.
│
└─ Password ACCEPTED on the web cleanly
      → F2 was most likely a transient throttle at 13:35.
        Justified next live request: ONE combined fresh-login→developer-session
        (ZAG_RUN_MACLEGACY_LOGIN_DEVSESSION). This is the decisive test because
        it exercises apptokens from a FRESH session (never yet observed):
          ├─ login authenticates AND developer_outcome = verified
          │     → SUCCESS. F1 was session staleness; fix confirmed. Proceed to
          │       design the cert/device/profile stage (offline) for approval.
          ├─ login authenticates BUT apptokens returns -22411 again
          │     → F1 is NOT staleness. Points to an account-level Xcode/
          │       developer precondition. Investigate offline (developer
          │       agreement / first Xcode use); no more apptokens runs meanwhile.
          └─ login rejected -22406 again
                → F2 persists despite a healthy web sign-in. Stop. Capture the
                  full sanitized trace; escalate as an account/edge condition,
                  not a code defect.
```

**Evidence that justifies another live request**: a clean web sign-in with the
stored password (confirms the credential + account health) — and then exactly
one run, because the combined flow is the single experiment that isolates F1
(fresh-session apptokens) and re-tests F2 together, at minimum request cost.
**No live request is justified while the web sign-in is failing or shows a
security hold.**

---

## RESOLUTION (2026-11-24 13:56) — fresh-session developer-session SUCCEEDED

`ZAG_RUN_MACLEGACY_LOGIN_DEVSESSION` (combined fresh-login → developer-session):

```json
{ "outcome":"authenticated", "two_factor_completed":true, "session_stored":true,
  "accepted_by_class":{"authentication":4},
  "http_trace":[lookup 200, srp-init 200, srp-complete 200, apptokens 200],
  "developer_outcome":"developer-session (verified: token + GS header)",
  "developer_token_present":true, "developer_has_gs_token_header":true,
  "developer_expires_in_days":364, "all three profiles":"10/consistent" }
```

Decision-tree outcome = **success branch**:
- **F1 (-22411) was session staleness.** A developer-session exchanged from the
  FRESH in-memory session (the apptokens POST, the 4th authentication-class
  request) is accepted and returns a verified token valid ~364 days. The
  option-B fix is confirmed live.
- **F2 (-22406 at 13:35) was transient.** The same credential authenticated
  cleanly here via a trusted 3-request login (no 2FA prompt), so the account and
  password are healthy — consistent with a momentary throttle at 13:35, not a
  code fault and not a changed password.

Milestone: on a stock iPhone with a free Apple account — no Mac, companion,
external anisette server, or Android ADI — we now have standalone GrandSlam
authentication (with 2FA when required) AND a verified Xcode developer-services
token. Next stage (cert / device / App ID / profile / signing) is NOT started;
it awaits separate authorization and will be designed offline first.
