# Native free-account provisioning — architecture & plan (2026-11-24)

Goal: provision and sign an IPA directly on a stock iPhone using a free Apple
Account, with no Mac companion, Android ADI or remote anisette service. This
document records the offline research (Phase 1), the on-device signing
architecture (Phase 2), the implementation done so far (Phase 3), and the first
live experiment to be authorized separately (Phase 4).

Scope rules in force: offline only; PR #63/#64 stay draft; production unchanged;
the authenticated Keychain session and all three ADI profiles are preserved.

---

## PHASE 1 — Developer services

### 1. What apple-auth implements vs. what we implement

apple-auth implements the **authentication layer only**:
- `developer_session` (one `apptokens` POST) → the Xcode developer-services
  token `{account_id, token, expires_at_ms}` (verified live: ~364-day token).
- `developer_headers` (**local, no HTTP**) → the signed header bag:
  `X-Apple-GS-Token`, `X-Apple-I-Identity-Id`, `X-Apple-App-Info:
  com.apple.gs.xcode.auth`, `User-Agent: Xcode`, `X-Xcode-Version`, plus fresh
  anisette (`X-Apple-I-MD`, `-MD-M`, `-MD-LU`, `-MD-RINFO`, `X-Mme-Device-Id`,
  `X-MMe-Client-Info`, client time).

apple-auth implements **none** of the developer-account operations (team, cert,
device, App ID, profile). Those are **ours**, layered on top of
`developer_headers`. That layer is the new `ZagDeveloperServicesProtocol` +
`ZagNativeDeveloperPortal`.

### 2. Working flows surveyed, and our existing code

The operations follow the Xcode / AltStore / SideStore free-account flow against
`developerservices2.apple.com` using the "QH65B2" plist service. **Already
present in Zag Store and reused unchanged:**
- `ZagDeveloperPortalService` — the full operation protocol, with
  `ZagDisabledDeveloperPortal` (safe default) and `ZagDeveloperPortalSimulation`.
- Models: `ZagRegisteredDevice`, `ZagRegisteredAppID`, `ZagRegisteredAppGroup`,
  `ZagDevelopmentCertificate`, `ZagIssuedCertificate`, `ZagCertificateRequest`,
  `ZagIssuedProfile` (+ `ZagIssuedProfile(profileData:)` via `Certificate.decode`).
- `ZagFreeAccountProvisioner` — orchestration (cert plan, budgets, profile check).
- `ZagKeychainSigningKeyFactory` / `ZagKeychainSigningKeys` — key + CSR.
- `ZagCertificateBudget`, `ZagFreeAccountEntitlements`,
  `ZagProvisioningProfileCheck`, `ZagFreeAccountTransport` (bounded HTTPS).
- `Zsign.signComponents(…, signer:)` — the signer with a raw-signer callback.

The only missing piece was a **live** `ZagDeveloperPortalService`. That is what
this phase adds.

### 3. Request sequence (QH65B2 plist service)

Envelope on every request (body, XML plist): `clientId` (XABBG36SBA),
`protocolVersion` (QH65B2), `requestId` (fresh uppercased UUID), `userLocale`
(`["en_US"]`), `teamId` (once known), plus per-action parameters. Auth is by
header (`developer_headers`), never in the body. Endpoint:
`https://developerservices2.apple.com/services/QH65B2/<action>?clientId=…`.

| Stage | Action | Mutates? | Key request params | Key response |
|-------|--------|----------|--------------------|--------------|
| Team discovery | `viewDeveloper.action` (listTeams) | no | — | `teams[].teamId` |
| Devices (list) | `ios/listDevices.action` | no | — | `devices[].deviceNumber,name` |
| Device register | `ios/addDevice.action` | **yes** | `deviceNumber`, `name` | `device` |
| Certs (list) | `ios/listAllDevelopmentCerts.action` | no | — | `certificates[]` |
| Cert create | `ios/submitDevelopmentCSR.action` | **yes** | `csrContent` (PEM), `machineName`, `machineId` | `certRequest`/`certificate` (DER) |
| Cert revoke | `ios/revokeDevelopmentCert.action` | **yes** | `serialNumber` | status |
| App IDs (list) | `ios/listAppIds.action` | no | — | `appIds[].appIdId,identifier` |
| App ID create | `ios/addAppId.action` | **yes** | `identifier`, `name` | `appId` |
| Profile download | `ios/downloadTeamProvisioningProfile.action` | **yes*** | `appIdId` | `provisioningProfile.encodedProfile` |

\* Download creates the team profile on demand, so it is treated as a mutation.

### 4. Headers, auth state, validation, free-account limits

- **Headers**: the full `developer_headers` bag + `Content-Type`/`Accept:
  text/x-xml-plist`. The token must be present (`X-Apple-GS-Token`) or the call
  is refused as `.sessionRejected` before any request.
- **Auth state**: requires an authenticated session and a non-expired developer
  token (apple-auth enforces expiry in `developer_headers`).
- **Validation**: HTTP 2xx required; body parsed as plist; `resultCode == 0`
  (or absent) is success; non-zero maps to a typed `ZagPortalError`
  (`sessionRejected`, `rateLimited`, `deviceLimitReached`, `appIDLimitReached`,
  `certificateLimitReached`, `identifierUnavailable`, else `malformedResponse`).
  Response size capped (1 MiB) by the transport.
- **Free-account limits** (community-reported, to confirm live): development
  certificate validity and signed-app validity are **7 days**; a small rolling
  cap of **App IDs per 7 days** (commonly ~10); limited registered devices;
  development (not distribution) certs/profiles only; wildcard App IDs and some
  entitlements (push, app groups in some cases) unavailable. `ZagCertificateBudget`
  and the provisioner already model these.

### 5. Read-only vs. mutating

Encoded once, authoritatively, on `ZagDeveloperServicesAction.isMutating`
(host-tested). Read-only: listTeams/listDevices/listCertificates/listAppIDs/
listAppGroups/listProfiles. Mutating: addDevice/submitCSR/revokeCertificate/
addAppID/addAppGroup/assignAppGroups/downloadProfile. The live portal refuses
every mutating action unless a per-action consent gate returns true; read-only
discovery is never gated.

---

## PHASE 2 — On-device signing architecture

### 6. Zsign reuse on iOS

`Zsign` is C++/OpenSSL compiled into the app; it already runs on iOS in Zag
Store. `Zsign.signComponents(appPath:certificate:signer:components:…)` takes a
**raw-signer callback** (`(Data) -> Data?`, RSA PKCS#1 v1.5 over a DigestInfo).
This is the whole signing path we need; nothing new is required for signing.

### 7 & 8. Private-key generation, storage and isolation

Already implemented in `ZagKeychainSigningKeys` and verified sound:
- RSA-2048 key generated as a **Keychain key item**, `kSecAttrIsPermanent`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, **not synchronized**,
  **`kSecAttrIsExtractable: false`**.
- The CSR (`ZagCertificateSigningRequest.make`) is built from the key
  **reference**; the private key is never exported.
- Signing uses `SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15Raw, …)`
  passed to Zsign's `signer` callback, so **the private key never leaves the
  Secure Enclave-backed Keychain** even during CMS signing. One key per
  account+team, slot-rotated so a new key never displaces the one in use until
  its certificate is issued, verified (sign/verify round-trip) and stored.

Isolation is preserved **because** zsign signs through the callback rather than
a PEM/PKCS#12 private key — the tension between "key never leaves the store" and
"signer needs to sign" is resolved by the raw-signer design.

### 9. Profile install, entitlements, bundle-ID validation

- The downloaded `.mobileprovision` is parsed by `ZagIssuedProfile(profileData:)`
  (`Certificate.decode`) and checked by `ZagProvisioningProfileCheck` **before
  use**: team, bundle id, device present, certificate serial present, ≥1h
  validity left, and `application-identifier == <team>.<bundle>`.
- Entitlements (`ZagFreeAccountEntitlements`) are derived to match the App ID and
  must carry `application-identifier`, `com.apple.developer.team-identifier` and
  `keychain-access-groups: [<team>.*]` (the omission we hit earlier). zsign
  embeds the profile and entitlements per component (app + appex).
- Bundle-ID validation: free App IDs are explicit (no wildcard); the signed
  bundle id must equal the App ID the profile was issued for.

### 10. iOS limitations that could block a standalone flow

- **Installation**: an on-device signer cannot itself install an arbitrary app;
  installation needs a path (the app's existing sideload bridge / user action).
  This is the one genuinely external step and is unchanged by this work.
- **Crypto**: RSA-2048 + PKCS#1 signing and CSR are available via Security.
  Secure Enclave only does EC P-256; Apple dev certs are RSA, so the key is a
  software-protected (non-extractable) Keychain key, not a SE key.
- **Sandbox**: the this-device-only Keychain requires the correct
  `keychain-access-groups`; anisette and the session depend on it.
- **Free-account 7-day expiry** means re-provisioning weekly; already handled by
  `ZagFreeAccountRefresh`.

---

## PHASE 3 — Implementation (done, offline, disabled by default)

New files:
- `ZagPortalError.swift` — the typed portal error (extracted so the codec is
  host-testable without the model graph).
- `ZagDeveloperServicesProtocol.swift` — the **pure** codec: endpoint builder,
  plist request envelope, response parse + resultCode→error mapping, PEM
  wrapper, and `ZagRequestBudget` (hard request ceiling, no retries). Plus
  `ZagDeveloperServicesAction` with the read-only/mutating classification.
- `ZagNativeDeveloperPortal.swift` — the live `ZagDeveloperPortalService`:
  bounded transport pinned to `developerservices2.apple.com`, a
  `developer_headers` provider, a **per-action consent gate**
  (`ZagAccountMutationConsent`, default-deny), a shared request budget, and the
  read-only `teams()` discovery. **Not constructed by default** — the subsystem
  still defaults to `ZagDisabledDeveloperPortal`; the native portal is built only
  at an explicitly enabled live step.

Validation (offline): `scripts/test-zag-developer-services.sh` — 34 host tests
pass (classification, endpoint, request envelope, response/error mapping, budget,
PEM). The two codec files compile for arm64 iOS. `ZagNativeDeveloperPortal`
type-checks cleanly against the real FreeAccount subsystem (conformance + model
usage correct). No Apple contact; session and all three ADI profiles preserved.

Outstanding before any live provisioning:
- A thin bridge method exposing `developer_headers` as `[String:String]` to the
  portal's `HeadersProvider` (local, no HTTP). Deferred to the live wiring step.
- Confirm the QH65B2 field names and `resultCode` values against live responses
  (the envelope shape is stable; exact keys are reverse-engineered).
- A SwiftUI consent surface for mutating operations.

---

## PHASE 4 — First live experiment (to be authorized separately; DO NOT run yet)

**Smallest safe experiment: read-only team discovery.** It mutates nothing and
exercises the whole native path (token → headers → developerservices2 → parse).

- **Operation**: `ZagNativeDeveloperPortal.teams()` → listTeams.
- **Endpoint / method**: `POST
  https://developerservices2.apple.com/services/QH65B2/viewDeveloper.action?clientId=XABBG36SBA`.
- **Auth headers**: the full `developer_headers` bag from the existing developer
  token (reuse the session; mint a fresh developer-session if needed via the
  already-working combined login→dev-session), `Content-Type`/`Accept:
  text/x-xml-plist`.
- **Max requests**: 1 (team discovery). If a fresh developer-session must be
  minted first, that adds the known combined-login budget (≤6 auth + 1 apptokens)
  and is a separate, already-authorized operation.
- **Expected success**: HTTP 200, plist `resultCode 0`, `teams[]` with at least
  one `teamId` (the free account's personal team). Reported sanitized as team
  count + membership type only — never the teamId value, token or headers.
- **Sanitized diagnostics**: `{ outcome, http_status, result_code, team_count,
  membership_type, request_count, profiles_intact }`. No identifiers, no token.
- **Account-state changes**: **none** (read-only).
- **Failure handling**: `resultCode` → typed error (sessionRejected → re-auth;
  rateLimited → stop and back off; else malformedResponse → capture sanitized
  body shape, stop). One request, no retries. Budget refuses anything beyond.
- **One-time launch command** (after the live wiring step adds the gate; shown
  for review, not to run now):
  ```
  xcrun devicectl device process launch --device 8A6BBCC0-EA51-5B93-AF9C-578A9D39F89D --terminate-existing --environment-variables '{"ZAG_RUN_MACLEGACY_TEAMS":"1"}' dev.zagstore.ptteamprobe
  ```

This confirms the token is accepted by developer services and returns the team
id needed for every subsequent (mutating, consent-gated) operation. Only after a
clean team-discovery result would we propose the next step (read-only
list-devices / list-certificates), still before any mutation.

---

## Live-wiring step (2026-11-24, offline) — bridge + team-discovery gate

Implemented offline, no Apple contact:
- **Developer token persistence** (`ZagDeveloperTokenStore`): `{account_id,
  token, expires_at_ms}` stored opaque in the this-device-only Keychain (mac-
  legacy scope). `exchangeDeveloper` now persists a **verified** token (present +
  GS header) on success, so a future authorized dev-session run populates it.
  The token bytes are never logged or returned.
- **`developer_headers` bridge** (`ZagAppleAuthMachine.developerHeaders()`):
  LOCAL (no HTTP; a refused transport guarantees it). Loads the persisted token
  + this scope's ADI and returns the header bag, or nil when no usable token is
  persisted. Reads only — alters no ADI profile.
- **Production wiring**: `ZagNativeDeveloperPortal.live(machine:consent:)` feeds
  the bridge into the portal's `HeadersProvider`.
- **Gate `ZAG_RUN_MACLEGACY_TEAMS`** (+ `_SELFCHECK`), disabled by default:
  exactly one read-only team-discovery request via the persisted token, through
  an ephemeral session pinned to developerservices2.apple.com, redirects
  refused, no retry, budget 1. In the probe it mirrors
  `ZagNativeDeveloperPortal.teams()` using the shared pure codec (the probe
  stubs the production transport). It calls **only** listTeams; the default-deny
  consent means no mutating action is reachable (regression-tested).

### Is a usable developer token currently persisted? **No.**
The 13:56 developer token was transient (parsed, verified, reported sanitized,
discarded). Only the authenticated account **session** is persisted. The safe
acquisition path (no silent login): a future **authorized** developer-session
run — the stored-session `ZAG_RUN_MACLEGACY_DEVSESSION` (1 request) or the
combined `ZAG_RUN_MACLEGACY_LOGIN_DEVSESSION` — now persists the verified token;
team discovery then uses it in one request. Until then the gate makes **zero**
requests and reports `no-developer-token-persisted`.

### Offline preflight result (network-refused, on device)
`{ mode:selfcheck-teams, developer_token_persisted:false,
outcome:"no-developer-token-persisted", request_count:0, result:ran,
iphone_baseline 10/consistent, mac_experiment 10/consistent }`. No Apple
contact; session and all three ADI profiles intact.

### Verification against source (item 7)
The `apptokens` exchange and `developer_headers` were verified against apple-
auth source. The QH65B2 endpoint paths, `clientId`/`protocolVersion` and
`resultCode` values are reverse-engineered from the Xcode/AltStore/SideStore
flow and are **treated as assumptions** (so marked in code and tests); the plist
envelope shape and the parser are validated by 39 host tests. Live responses
will confirm the exact field names.

### Exact request + success criteria (team discovery)
- `POST https://developerservices2.apple.com/services/QH65B2/viewDeveloper.action?clientId=XABBG36SBA`,
  `Content-Type`/`Accept: text/x-xml-plist`, body = envelope (clientId,
  protocolVersion QH65B2, requestId UUID, userLocale), auth = `developer_headers`.
- Max requests: **1**. Success: HTTP 200, `resultCode 0`, `teams[]` ≥ 1.
- Reported sanitized: outcome, http_status, result_code, team_count,
  membership_type, request_count. Never a team id, token, header or body.
- Account-state change: **none** (read-only).

### One-time launch command (await authorization; do NOT run yet)
First a token must be persisted (an authorized dev-session run). Then:
```
xcrun devicectl device process launch --device 8A6BBCC0-EA51-5B93-AF9C-578A9D39F89D --terminate-existing --environment-variables '{"ZAG_RUN_MACLEGACY_TEAMS":"1"}' dev.zagstore.ptteamprobe
```
