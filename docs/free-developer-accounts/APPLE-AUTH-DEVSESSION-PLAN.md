# Developer-session integration — offline research & implementation

Next stage after standalone authentication: exchange the retained authenticated
session for an Xcode developer-services token. Offline only so far; no live
developer-session request has run. PR #63/#64 draft, production unchanged.

## 1. The APIs (inputs / outputs / ownership / lifetime)

`aauth_client_developer_session(client, account, &out)` — `client/client.cpp:637`
→ `netdetail::exchange_developer_session` (`authentication.cpp:382`).
- **In:** an authenticated `aauth_account_session` (borrowed, not consumed). It
  must hold `adsid`, a 32-byte `sk`, the `c` challenge and `GsIdmsToken`, and its
  account-state must be `authenticated` (`require(... == authenticated)`).
- **Does:** one request — `POST https://gsa.apple.com/grandslam/GsService2` with
  an `apptokens` body for application `com.apple.gs.xcode.auth`, using the
  client's current anisette headers + Xcode headers. Requires HTTP 200, then the
  GrandSlam `ec` check, then AES-GCM-decrypts the `et` envelope with `sk` and
  reads the token + expiry.
- **Out:** `aauth_client_buffer` JSON `{account_id, token, expires_at_ms}`; the
  caller frees it with `aauth_client_buffer_free`. The token/account id are
  secrets.
- **Lifetime:** `expires_at_ms` (0 = no stated expiry). `developer_headers`
  refuses an expired session.

`aauth_client_developer_headers(client, account_id, token, expires_at_ms, &out)`
— `client.cpp:647`. **No HTTP.** Returns the client's anisette headers plus
`X-Apple-GS-Token`, `X-Apple-I-Identity-Id`, and Xcode headers
(`X-Apple-App-Info`, `User-Agent: Xcode`, `X-Xcode-Version`). These are the
headers for subsequent developer-services requests.

## 2. Reusing the stored session (no GrandSlam login)

`aauth_account_session_from_plist(bytes, size, &account)` reconstructs the
session from the opaque plist retained in this scope's Keychain
(`ZagAppleAuthSessionStore`). With the scope's provisioned ADI client restored
(same identity → same anisette), `developer_session(account)` needs no login:
it calls `grandslam_account_state({}, session)`, which reads the session's PET
token and returns `authenticated` directly. One Apple request, no SRP, no 2FA.

## 3. Documented vs reverse-engineered

The `apptokens` exchange over GrandSlam `GsService2` for
`com.apple.gs.xcode.auth`, and the Xcode headers, are the **reverse-engineered**
Xcode developer-auth flow (not a documented Apple API). The only Apple-published
input is the Xcode version string (`X-Xcode-Version 27.2 (27B52)`, per
developer.apple.com/news). The subsequent developer-services endpoints
(certs/devices/App IDs/profiles) are a separate, also-RE REST surface — out of
scope here.

## 4. Minimum Apple requests

Developer-session acquisition = **exactly one** request (`POST GsService2`
apptokens). The GsService2 URL is hardcoded, so no URL-bag lookup is needed.

## 5. Separability

Developer-session is fully separable from certificate issuance, device
registration and provisioning-profile creation: `developer_session` returns only
a token; those operations are later `developerservices2.apple.com` calls that
consume `developer_headers`. This experiment performs none of them.

## 6. The experiment (implemented, gated off)

`ZagAppleAuthMachine.developerSession(allowNetwork:)` →
`driveDeveloperSession`: restores the ADI client + the stored session, calls
`aauth_client_developer_session` through a transport capped at **1 request, no
retries**, then derives `developer_headers` locally to verify the token. Gates:
`ZAG_RUN_MACLEGACY_DEVSESSION` (live) and `…_DEVSESSION_SELFCHECK` (offline,
transport refused). Report is sanitized (see §7).

## 7. Secrets

The token, account id, cookies and session bytes are never logged, echoed or
returned. The report carries only: outcome, request_count, `token_present`
(bool), `has_gs_token_header` (bool), `developer_header_count`, coarse
`expires_in_days`, and the sanitized http_trace.

## 8. Preservation

Read-only: the stored session and all three ADI profiles are reused, not
modified. The report re-derives mac-legacy headers and checks mac-experiment and
iphone (each 10 consistent).

## 9. Offline tests & patch

Smallest additive patch (new method + report + 2 gates + a `load` on the session
store). Host tests cover the verified-success classifier (token + unexpired + GS
header; shortfalls → failed/expired) and the session-store byte round-trip.

## 10. Verified success (not HTTP 200)

apple-auth returns OK only after 200 + the `ec` check + an AES-GCM decrypt of the
token envelope with `sk`. On top of that we require a non-empty token, an
unexpired session, and that `developer_headers` derives `X-Apple-GS-Token`. Only
then is the outcome `developer-session (verified)`; any shortfall is
`failed`/`expired`.

## Why the second authentication needed only three requests

`grandslam_account_state` (`authentication.cpp:139`) returns `authenticated` when
the SRP-complete response omits the 2FA mode (`Status.au` not
`secondaryAuth`/`trustedDeviceSecondaryAuth`) and the session carries a PET
token. Whether Apple sets `au` is a **server-side** decision keyed to the machine
identity in the anisette headers (`X-Apple-I-MD-M` / `X-Apple-I-MD-LU`, from the
provisioned ADI). Completing 2FA on attempt 1 made Apple trust that machine;
attempt 2 reused the same `mac-legacy` ADI profile, so Apple returned a PET
directly with no `au` challenge → authenticated in 3 requests. The trust is not
in our stored session — it is Apple's per-machine-identity trust window.

## Offline validation (done, no Apple contact)

Host tests pass; arm64 iOS compile + link clean; on-device preflight
(`…_DEVSESSION_SELFCHECK`): `outcome transport-failed`, `request_count 0` (zero
Apple contact), retained session present (not `no-session`), all three ADI
profiles intact.

## Proposed first live developer-session experiment (awaiting authorization)

One supervised run: restore the ADI client + stored session, exchange exactly one
`apptokens` developer token (cap 1, no retry), verify `developer_headers`, report
sanitized. No login, cert, device, App ID, profile or signing. Launch (with `!`):

```
xcrun devicectl device process launch --device 8A6BBCC0-EA51-5B93-AF9C-578A9D39F89D --terminate-existing --environment-variables '{"ZAG_RUN_MACLEGACY_DEVSESSION":"1"}' dev.zagstore.ptteamprobe
```

Expected on success: `outcome "developer-session (verified: token + GS header)"`,
`request_count 1`, `token_present true`, `has_gs_token_header true`, profiles
intact. If the stored session's trust window has lapsed, `failed`/`expired` —
then a fresh authenticated login would be the prerequisite (separate request).
