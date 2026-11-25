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

---

## First live team discovery + endpoint correction (2026-11-24 14:45)

First live developer-services request (`ZAG_RUN_MACLEGACY_TEAMS`):
`{ http_status:200, result_code:0, request_count:1, team_count:0, outcome:no-teams,
all three profiles 10/consistent }`.

**Milestone**: Apple **accepted the native developer token** against
developerservices2.apple.com (HTTP 200, resultCode 0) — the standalone
free-account token authenticates to developer services end to end.

**Defect found + fixed (verified against AltSign/SideStore source):** the
`listTeams` action was `viewDeveloper.action`, which returns a `developer` dict
(no `teams` array) — hence resultCode 0 but team_count 0. Corrected to
**`listTeams.action`** (response key `teams`; per-team keys name/teamId/type/
memberships — these now verified, not assumed). All other QH65B2 actions and
response keys matched the source and are unchanged.

**Corrections noted for the certificate phase (not team discovery):** certificate
LISTING and REVOKE use the newer `/services/v1/` JSON API
(`/services/v1/certificates`, POST + `X-HTTP-Method-Override: GET`/`DELETE`,
`application/vnd.api+json`, body `{"urlEncodedQueryParams": …}`, response under
`data`), not the QH65B2 plist actions. `submitDevelopmentCSR` remains the plist
action (`ios/submitDevelopmentCSR.action`, response `certRequest`). The two cert
LIST/REVOKE cases are flagged in code as placeholders to switch at the cert phase.

Re-validated offline after the fix: host tests pass; full arm64 iOS target
builds/links; app reinstalled; the persisted token survives reinstall
(`token_in_store:true`); network-refused selfcheck makes 0 requests; all three
ADI profiles intact. The next live `ZAG_RUN_MACLEGACY_TEAMS` (same persisted
token, one request) should now return `team_count ≥ 1`.

---

## Provisioning offline implementation (2026-11-24) — full models, v1 JSON, consent

Completed offline, no Apple contact; verified against AltSign/SideStore source.

**Models/adapters (all mapped to existing models, reusing them):**
- Devices: `ios/listDevices.action` → `devices[]` (deviceNumber/name); register
  `ios/addDevice.action` → `device`.
- App IDs: `ios/listAppIds.action` → `appIds[]` (appIdId/identifier/expirationDate
  native Date); create `ios/addAppId.action` → `appId`.
- Certificates: LIST + REVOKE via the **`/services/v1/` JSON API** (new
  `ZagDeveloperServicesV1`: POST + `X-HTTP-Method-Override: GET/DELETE`,
  `application/vnd.api+json`, body `{"urlEncodedQueryParams":…}`, results under
  `data`); CSR submit stays the plist `ios/submitDevelopmentCSR.action` → the DER
  comes straight back under `certRequest` (`certContent` raw or
  `certificateContent` base64 — both handled; no re-list). Shared
  `ZagDeveloperServicesProtocol.parseCertificate` (serial leading-zeros stripped).
- Profiles: `ios/downloadTeamProvisioningProfile.action` → `provisioningProfile`
  (`provisioningProfileId` + `encodedProfile`) → existing `ZagIssuedProfile`.

**QH65B2 plist vs /services/v1/ JSON** are handled by separate codecs
(`ZagDeveloperServicesProtocol` / `ZagDeveloperServicesV1`), each with its own
request/response shape and error mapping.

**Consent experience (`ZagMutationConsent.swift`):** `ZagMutationConsentCoordinator`
(ZagAccountMutationConsent, default-deny, up-front whole-plan authorization, thread-
safe) + `ZagAccountMutationConsentView` (SwiftUI) showing each action's title and
consequence (device/App ID/cert/profile — e.g. 7-day expiry, weekly App ID cap)
before any authorization. Read-only actions are never gated.

**Reuse (no duplication):** `ZagNativeDeveloperPortal` (the live
`ZagDeveloperPortalService`) plugs into the existing `ZagFreeAccountProvisioner`,
which already implements discover → reuse → create-if-needed, cert/key
consistency (`ZagKeychainSigningKeyFactory.check` sign/verify) and profile
consistency (`ZagProvisioningProfileCheck`). Non-extractable Keychain keys and
`Zsign.signComponents(…, signer:)` are unchanged. `ZagNativeDeveloperPortal.live(
machine:consent:)` wires the local `developer_headers` bridge + consent.

**Safety preserved:** default-deny construction, host pinned to
developerservices2.apple.com, redirects refused, hard request budget, no retries,
sanitized diagnostics; token/session/3 ADI profiles untouched.

**Validation (offline):** 24 dev-services host tests pass (classification,
endpoint, plist envelope, error mapping, cert parser, v1 codec, consent,
budget, PEM); full arm64 iOS target builds/links; new files type-check against
the real FreeAccount subsystem; device-discovery network-refused preflight =
`{developer_token_persisted:true, preflight-no-network, request_count:0}`, all
three ADI profiles 10/consistent.

### Item 2 — is the device already registered?
Determined by a NEW read-only device-discovery gate `ZAG_RUN_MACLEGACY_DEVICES`
(+ `_SELFCHECK`) BEFORE any `addDevice` is designed: `teams → listDevices`
(≤2 read-only requests), reporting `device_count` and, when `ZAG_EXPECT_UDID` is
set, a `expected_udid_registered` bool (the UDID itself is never logged). The
device already runs our Xcode-provisioned app for this team, so it is plausibly
already registered — discovery confirms it before spending a device-quota
mutation.

**Open item for the addDevice step:** obtaining this device's own iOS UDID on
device (no Mac) is not possible via public API; it must come from the host
(`devicectl`/`xctrace list devices`, passed via `ZAG_EXPECT_UDID`) or an existing
registration. Discovery sidesteps this: if the device is already registered and a
valid cert/profile exist, no mutation is needed.

### Proposed smallest safe first live DISCOVERY experiment (await authorization)
- **Operation**: `ZAG_RUN_MACLEGACY_DEVICES` — `listTeams` then `listDevices`.
- **Endpoints/method**: POST `…/services/QH65B2/listTeams.action` then POST
  `…/services/QH65B2/ios/listDevices.action` (teamId from the first).
- **Request count**: ≤ 2, read-only, no retry, budget-capped.
- **Expected**: HTTP 200, `result_code 0`, `device_count ≥ 0`; with
  `ZAG_EXPECT_UDID`, `expected_udid_registered` true/false.
- **Account impact**: NONE (read-only).
- **Sanitized diagnostics**: outcome, http_status, result_code, device_count,
  expected_udid_registered, request_count — never a UDID/team id/token/body.
- **One-time launch command**:
  ```
  xcrun devicectl device process launch --device 8A6BBCC0-EA51-5B93-AF9C-578A9D39F89D --terminate-existing --environment-variables '{"ZAG_RUN_MACLEGACY_DEVICES":"1"}' dev.zagstore.ptteamprobe
  ```
  (optionally add `"ZAG_EXPECT_UDID":"<device udid from devicectl>"` to check this
  device specifically). This also exercises the first `listDevices` + v1-less read
  path and, with a known UDID, tells us whether `addDevice` is even needed.

---

## Device-identity + reuse audit (2026-11-24) — offline, no Apple contact

Verdicts only below; raw UDIDs/serials are never committed or logged.

### 1–2. Device identity confirmed (authoritative UDID, not the CoreDevice id)
`xcrun devicectl list devices --json` exposes two different identifiers for the
test iPhone: the **CoreDevice identifier** (a `8A6B…` UUID, used by `devicectl
--device`) and `hardwareProperties.udid` — the **authoritative iOS provisioning
UDID** (modern ECID form `00008130-…`). These are NOT equivalent; only the latter
is what the developer portal registers. The locally built Xcode-provisioned test
app's `embedded.mobileprovision` (decoded with `security cms -D`) lists exactly
one `ProvisionedDevices` entry, and it **equals this iPhone's authoritative
provisioning UDID** → the device registered in the team (device_count 1, live
discovery) IS this iPhone.

### 3. Team match (secure, no identifier exposed)
`ZagProfileIdentityAudit` (pure) compares the profile's `TeamIdentifier` against
the team returned by live `listTeams`, and checks whether this device's UDID is
in the profile — returning **only booleans and coarse counts**, never the UDID,
team id, serial, bundle or date. Result for our profile: team matches, device in
profile, bundle matches, 1 device, 3 certs, 7-day profile.

### 4. Certificate listing audited against `/services/v1/` JSON
`ZagNativeDeveloperPortal.certificates()` uses the v1 JSON:API (POST +
`X-HTTP-Method-Override: GET`, `application/vnd.api+json`, `data[]`). A new
read-only live gate `ZAG_RUN_MACLEGACY_CERTS` (+ `_SELFCHECK`) exercises it:
`teams → certificates` (≤2 requests), reporting `certificate_count` and the
nearest expiry in coarse days — no serials. Disabled by default.

### 5. Reusable existing resources (before any mutation)
The profile and live discovery show these already exist for the free Personal
Team `V54K5JYGS4` and are reusable by the discover→reuse path:
- **Team** — the free Personal Team (membership "Xcode Free Provisioning").
- **Device registration** — this iPhone (confirmed above); `addDevice` NOT needed.
- **App ID** — `dev.zagstore.ptteamprobe` (the profile's application-identifier).

NOT reusable for native standalone signing:
- **Signing certificate / private key.** The profile embeds 3 developer certs,
  but their private keys live in the **Mac login keychain** (Xcode's) — NOT on
  the device. Our native flow signs with a device-Keychain **non-extractable**
  key, so a NEW certificate must be issued for that key via `submitDevelopmentCSR`.
- **The Xcode profile** references those Mac certs, so a native run creates its
  own profile tying the new (device-key) cert + existing App ID + existing device.

### 6. Certificate-issuance flow (reuses existing key factory + CSR; already wired)
No new signing code needed — the existing pieces compose:
`ZagKeychainSigningKeyFactory.makePendingKey` creates a non-extractable RSA key in
the device Keychain and a `ZagCertificateRequest` (CSR) from it (key never
exported); `ZagNativeDeveloperPortal.submitCertificateRequest` sends the PEM CSR
(public request only) and returns the issued cert. **Public-key match is verified
by a real sign/verify round-trip** in `ZagKeychainSigningKeyFactory.check`: it
signs a fresh 32-byte challenge with the Keychain private key
(`SecKeyCreateSignature`) and verifies it with the certificate's public key
(`SecCertificateCopyKey` → `SecKeyVerifySignature`). `ZagFreeAccountProvisioner`
already calls this after CSR submission and discards any cert that no longer
matches its key.

### 7. Lifecycles are independent (do not infer one from another)
Three independent validity windows, confirmed from the live/offline artifacts:
- **Developer token** ~364 days (apptokens).
- **Signing certificate** ~1 year (our cert's notAfter is `2027-09-27`).
- **Provisioning profile** 7 days (`TimeToLive 7`; expires `2026-11-30`).
A valid developer token does NOT imply a valid cert or an unexpired profile, and
an unexpired cert does NOT imply an unexpired profile. Free Personal Team
restrictions still apply (small device/App-ID/certificate caps, 7-day profiles);
the `ZAG_RUN_MACLEGACY_CERTS` count check exists precisely to see whether a new
CSR would exceed the certificate cap before submitting one.

### Smallest safe next live read-only experiment (await authorization)
`ZAG_RUN_MACLEGACY_CERTS` — `listTeams → certificates` (v1 JSON), ≤2 read-only
requests, no account impact. Confirms the current certificate count vs the free-
team cap (and nearest expiry) BEFORE any CSR is ever designed. Launch:
```
xcrun devicectl device process launch --device 8A6BBCC0-EA51-5B93-AF9C-578A9D39F89D --terminate-existing --environment-variables '{"ZAG_RUN_MACLEGACY_CERTS":"1"}' dev.zagstore.ptteamprobe
```
Reports: outcome, http_status, certificate_count, nearest_cert_expires_in_days,
request_count — no serials/ids. No mutation.

---

## Certificate-issuance path (2026-11-24) — offline, prepared not run

The native CSR path, ready for a single separately-authorized live submission.

### Exact certificate-issuance request + expected response
- **Request** — one POST to `https://developerservices2.apple.com/services/QH65B2/ios/submitDevelopmentCSR.action`, headers `Content-Type`/`Accept: text/x-xml-plist` + the local `developer_headers` bag (X-Apple-GS-Token, identity, Xcode headers, anisette). XML-plist body:
  `clientId=XABBG36SBA`, `protocolVersion=QH65B2`, `requestId=<UUID>`, `userLocale=[en_US]`, `teamId=<team>`, `csrContent=<PEM CERTIFICATE REQUEST>`, `machineName="Zag Store"`, `machineId=<UUID>`. The PEM is the **public** CSR only; the RSA-2048 private key stays non-extractable in the Keychain.
- **Expected response** — `resultCode 0` with a `certRequest` dict carrying the DER in `certContent` (raw) or `certificateContent` (base64); parsed by the shared `parseCertificate` (no re-list needed). Certificate-cap exhaustion returns `resultCode 3540/7458` → `ZagPortalError.certificateLimitReached`.

### Consent behaviour + state transitions
`.submitCSR` is a mutation gated by `ZagMutationConsentCoordinator` (default-deny). The supervised screen (`ZagAccountMutationConsentView`, plan `[.submitCSR]`) shows the consequence — *"Creates a new development certificate in your Apple Developer Personal Team, for this device's private key. Free accounts allow only a small number; an old one may need to be revoked."* — before anything is sent.
- **Consent → Authorize** → `coordinator.authorize([.submitCSR])` → `mayPerform(.submitCSR)==true` → run the bounded sequence.
- **Consent → Cancel** → nothing is sent to Apple (`request_count 0`, outcome `cancelled`).
- Without authorization the runner reaches discovery only and reports `consent-required` (no CSR).

### Certificate-cap handling (inferred vs authoritative)
`ZagCertificateCapPreflight.evaluate(count)` yields `withinInferredCap` or `inferredCapacityRisk` — explicitly **non-authoritative** (`authoritative:false`); it warns but never blocks. The only authoritative capacity verdict is Apple's `certificateLimitReached` at submit time. On that error the runner **stops immediately**, preserves the pending key, performs **no revocation**, and reports `revoke_candidate_count`. Revocation (`ZagCertificateRevocation`, v1 `DELETE /services/v1/certificates/<id>`) is a **separate, separately-consented** action that identifies the certificate unambiguously by its v1 `id`; `ZagActiveCertificateGuard` refuses the active Xcode certificate (matched by SHA-1 / serial) unless an explicit override is set, and classifies the two legacy certs as **unknown-usage, never "unused"**. A capacity error can never trigger a revoke (building the request needs an explicit `id`).

### Keychain persistence + recovery behaviour
`ZagPendingCSRStore` journals one `ZagPendingCSRState` per scope (this-device-only Keychain) beside the signing key:
- First run creates the non-extractable key + CSR and stores `{keySlot, request, startedAt, attempts:0}`.
- A retry **reuses the stored request bytes and key** (no new key → no orphans; no new request → no duplicates).
- Before each send `submissionUnconfirmed=true` is written; a crash between send and response leaves it set, and the next run **resolves it against the team's certificate listing** (public-key match) rather than resubmitting — recovering a lost-response certificate or clearing the flag.
- `nextStep(at:)`: `reuseIssued` / `resolveUnconfirmed` / `submit` / `exhausted` (retry budget 3, lifetime 24h; on exhaustion the key is kept for review).
- On issuance the certificate is accepted as usable only after: **public-key match** (sign/verify round-trip, `ZagKeychainSigningKeyFactory.check`), **not expired**, and **team association** (DER carries `OU=<teamID>`).

### Test results
24-case issuance/policy suite + the full developer-services suite pass (**84/84** host checks): cap preflight, active-cert guard (protect/override, legacy=unknown), revocation codec (id + DER SHA-1, v1 DELETE, synthetic 2xx/403/errors), pending-CSR journal (submit/resolve/reuse/exhausted). Full arm64 iOS target builds and links with the signing stack. New files type-check against the real FreeAccount subsystem. CSR network-refused preflight = `{mode:selfcheck-csr, mutation_authorized:false, outcome:preflight-no-network, request_count:0}`, developer token persisted, all three ADI profiles 10/consistent. Also fixed a latent duplicate `ZagDeveloperTeam` (renamed the native one to `ZagNativeDeveloperTeam`).

### One-time launch command for a single live CSR submission (await authorization)
```
xcrun devicectl device process launch --device 8A6BBCC0-EA51-5B93-AF9C-578A9D39F89D --terminate-existing --environment-variables '{"ZAG_RUN_MACLEGACY_CSR":"1"}' dev.zagstore.ptteamprobe
```
This shows the consent screen first; only on Authorize is one CSR submitted (bounded: teams + certificates + one submit, no retry). **Not executed.**

---

## CSR diagnostics + reconciliation (2026-11-24) — offline, no Apple contact

Corrections after the attempt-1 CSR returned a client-classified `rate-limited`
whose raw Apple result code was never captured.

### 1. Exact fault capture
`ZagDeveloperServicesProtocol.fault(body:httpStatus:)` records a
`ZagDeveloperServicesFault{classification, resultCode, httpStatus, message}`
WITHOUT throwing, so the raw Apple `resultCode`, HTTP status and a redacted,
length-bounded message (`sanitizeMessage`: strips email/token-like text + control
chars, caps at 160) are preserved. No credentials, identifiers, headers, CSR
contents or sensitive bodies are ever recorded. The CSR path now records these
into the journal (`lastResultCode/lastHTTPStatus/lastMessage/lastClassification`).

### 2. Classifier audit — confirmed throttle vs ambiguous
The old map treated `resultCode 4` as a rate-limit; that was wrong and almost
certainly mislabeled attempt 1. Corrected: **only** HTTP 429 and the verified
throttle codes (7460/7788) are `confirmedRateLimit`; every other unknown non-zero
code is `ambiguousRejection` — never silently called a throttle. `throwIfError`
no longer maps `4` to rateLimited.

### 3–4. Reconciliation state machine (`ZagCSRReconciliation`)
A "no matching certificate" listing does **not** by itself clear
`submissionUnconfirmed`. `decide(match:submit:)`:
- **matching certificate found** → `recover` (verify key + team + validity, then adopt);
- **no match + authoritative rejection** (cap / device / App-ID / session / identifier / confirmed 429) → `retryable` (clear the flag, allow one resubmit of the same key+CSR);
- **no match + ambiguous (or no recorded verdict)** → `preserveForReview`;
- **no match + transport-incomplete**, or **listing unavailable** → `preserveUnconfirmed`.
The read-only `runCSRReconcile` gate (`ZAG_RUN_MACLEGACY_CSR_RECONCILE` + `_SELFCHECK`)
fetches a fresh listing and applies this — no CSR, no revoke, no key creation.

### 5. Key/CSR reuse
The pending non-extractable Keychain key and the original CSR bytes are reused on
any retry (`ZagPendingCSRState`), never regenerated or resubmitted automatically.

### 6–8. Tests + build + preflight
110/110 host checks (duplicate prevention, delayed certificate visibility,
ambiguous responses, rate-limit classification, certificate-cap errors, crash
recovery). Full arm64 iOS target builds/links; new files type-check against the
real subsystem. Network-refused reconcile preflight reads the real attempt-1
journal: `{journal_submission_unconfirmed:true, submit_verdict:none, decision:preserveUnconfirmed, request_count:0}`, developer token + all three ADI profiles intact.

### Current journal state + what would resolve it
The attempt-1 journal is `submissionUnconfirmed = true` with **no recorded submit
verdict** (attempt 1 predated fault capture, so its result code is unknown —
consistent with not treating the throttle as confirmed). The pending
non-extractable key and CSR are preserved. Safe resolution evidence:
- **Recover** iff a fresh `/services/v1/certificates` listing contains a
  certificate whose public key matches the pending key (verify key + team + validity).
- Otherwise, because the submit verdict is unknown (not an authoritative
  rejection), the journal is **preserved for explicit review** — it is NOT
  cleared or retried on an empty listing.

### Smallest separately-authorized read-only reconciliation experiment
`ZAG_RUN_MACLEGACY_CSR_RECONCILE` — `listTeams` + `certificates` (≤2 read-only
requests, no CSR/revoke/key-creation). Reports `listing_match`, `decision` and
the journal's recorded verdict. Launch (await authorization):
```
xcrun devicectl device process launch --device 8A6BBCC0-EA51-5B93-AF9C-578A9D39F89D --terminate-existing --environment-variables '{"ZAG_RUN_MACLEGACY_CSR_RECONCILE":"1"}' dev.zagstore.ptteamprobe
```
No arbitrary wait period is asserted as an Apple requirement; it is not run here.

---

## One-time operator CSR-retry override (2026-11-24) — offline, no Apple contact

A single-use, evidence-bound, human-reviewed transition that lets exactly one
authorized CSR resubmission proceed after reconciliation showed no certificate
was issued. Nothing is ever cleared automatically.

### State transitions
```
submissionUnconfirmed --(operator override, bound to evidence)--> retryableAfterReview
retryableAfterReview  --(consumed at submit time, persisted BEFORE send)--> (single submission)
   submit success   -> issuedSerial set, submissionUnconfirmed=false
   submit cap/limit  -> record fault, STOP, no revoke (item 9); evidence cleared
   submit ambiguous  -> submissionUnconfirmed stays true, evidence cleared -> reconcile again (item 10)
```
`nextStep`: issued→reuseIssued; retryableAfterReview→submitAfterReview; else
unconfirmed→resolveUnconfirmed; else submit/exhausted. The override flag is
consumed (set false, saved) **before** the request leaves the device, so a crash
or replay cannot reuse it — at most one submission per authorized experiment.

### How the evidence is validated (`ZagReconciliationOverride.apply`)
The override is refused unless ALL hold, bound to the exact pending item:
- journal is `submissionUnconfirmed`, not issued, not already overridden (replay guard);
- evidence present, a complete read-only listing (`listingComplete && httpStatus==200`);
- `matchingPublicKeyFound == false` (a found cert means *recover*, never retry);
- `originalVerdictUnknown == true` (a known verdict uses the normal path);
- `evidence.keySlot == journal.keySlot`, `evidence.account == expected`,
  `evidence.teamID == journal.team`, `evidence.csrSHA256 == SHA256(journal.request)`;
- evidence age in `[0, 3600]s` (stale or future-dated is refused).
Rejections are typed (`noEvidence/evidenceIncomplete/matchFound/verdictNotUnknown/
keyBindingMismatch/teamMismatch/accountMismatch/csrMismatch/evidenceStale/
journalNotUnconfirmed`). The original CSR and non-extractable Keychain key are
never regenerated; the evidence is recorded by the read-only reconcile run.

### Validation
130/130 host checks (success transition, replay/duplicate prevention, stale &
future-dated evidence, wrong key/team/account/CSR, incomplete/ambiguous/match-
found evidence, post-consume reconcile-again). Full arm64 iOS build/link.
Offline override preflight against the REAL attempt-1 journal returns
`{journal_submission_unconfirmed:true, has_evidence:false, outcome:override-rejected,
rejection:noEvidence, request_count:0}`, token + 3 ADI profiles intact.

### Proposed one-time live sequence (await separate authorization — NOT run)
The attempt-1 journal has no recorded evidence (the 18:34 reconcile predated
evidence capture), so the override is correctly blocked. To proceed:
1. **Re-run the read-only reconcile** (records fresh evidence if still not-found):
   `ZAG_RUN_MACLEGACY_CSR_RECONCILE` — ≤2 read-only requests, no CSR/revoke/key.
2. **Run the offline override** (no network): `ZAG_RUN_MACLEGACY_CSR_OVERRIDE` —
   transitions to `retryableAfterReview` iff the evidence validates.
3. **One consented CSR**: `ZAG_RUN_MACLEGACY_CSR` — shows the consent screen, then
   submits once (reusing the same key + CSR). May return `certificateLimitReached`
   (count 3 vs inferred cap 2) → stop, surface revoke candidates (active Xcode
   cert protected) for a separate decision. No step is run here; no throttle wait
   is asserted as an Apple requirement.
```
xcrun devicectl device process launch --device 8A6BBCC0-EA51-5B93-AF9C-578A9D39F89D --terminate-existing --environment-variables '{"ZAG_RUN_MACLEGACY_CSR_OVERRIDE":"1"}' dev.zagstore.ptteamprobe
```

---

## resultCode 7460 — classifier correction + certificate investigation (2026-11-24)

Offline-only. No Apple network requests, no revocation, no CSR, no new keys.

### The observed response (verified)
Our second explicitly-authorized CSR returned, exactly:
- HTTP status `200`
- Apple `resultCode` `7460`
- Apple message: *"You already have a current iOS Development certificate or a pending certificate request."*
- No certificate issued for our pending device-local key; retry authorization consumed; journal remains `submissionUnconfirmed`; key + CSR + token + 3 ADI profiles preserved.

### Root cause of the classifier bug
`7460` was mapped (in both `throwIfError` and `fault()`) to a rate-limit — a value inherited without evidence and grouped with `7788`. The actual condition is an **existing development certificate or a pending certificate request**, an application-level conflict, not HTTP throttling. This is also what mislabeled the first attempt as "rate-limited".

### Correction (code)
- New typed error `ZagPortalError.existingCertificateOrPendingRequest` and classification `ZagDeveloperServicesFault.Classification.existingCertificateOrPendingRequest`.
- `7460` now maps to it in `throwIfError` and `fault()`, preserving the exact raw code, HTTP status and (redacted, bounded) message.
- Kept DISTINCT: genuine HTTP 429 throttling (`confirmedRateLimit`), verified certificate-cap codes (`certificateLimitReached`, 3540/7458), existing-cert/pending conflict (`7460`), auth failures (`sessionRejected`), and ambiguous/undocumented codes (`ambiguousRejection`).
- `7788` is no longer asserted to be a throttle: with no evidence and its only companion (7460) disproven, it now falls to the explicit "unknown" bucket. Not reclassified to any positive meaning.
- Reconciliation: a confirmed conflict maps to a new `SubmitVerdict.confirmedConflict` → `preserveForReview` (a blind resubmit of the same CSR would simply recur), never auto-cleared to retryable. `submissionUnconfirmed` is not auto-cleared; revocation is not presented as the only recovery.
- HTTP 200 carrying an Apple application-level error remains an error throughout.

### Certificate inventory (team V54K5JYGS4) — evidence tiers
| Fact | Tier | Basis |
|---|---|---|
| 3 development certificates on the team | **Verified** | live listing 15:36 + two reconciles, stable |
| All 3 currently non-expired | **Verified** | nearest expiry 286 days out |
| One is the Mac's active Xcode "Apple Development" cert (SHA-1 suffix `5657782A`, OU `V54K5JYGS4`, expires 2027-09-27, private key in Mac login keychain) | **Verified** | local keychain + cert subject |
| Mac keychain holds exactly ONE Apple Development private key for this team | **Verified** | `security find-identity` |
| Our pending device-local key matches none of the 3 | **Verified** | reconcile not-found, twice |
| 7460 is caused by the team already having a current dev certificate | **Inferred** | a current valid cert (the Xcode one) exists; message wording |
| A server-side pending certificate request also exists | **Unknown** | our listing enumerates issued certs, not pending requests; 7460 explicitly admits this cause |
| The two non-Xcode certs' origin/usage/keys | **Unknown** | no local private keys; could be prior tooling (AltStore/Sideloadly/our experiments) |
| Which single certificate "causes" 7460 | **Unknown** | 7460 is account-level, not cert-specific |
| Exact numeric development-certificate cap for a free Personal Team | **Unknown** | only known: 3 present, a 4th refused |

**The one-development-certificate Personal Team limit is NOT a verified fact.** Three certificates are present; the evidence shows only that we are at or above some unknown cap and/or that a current cert or pending request blocks a new one.

### Non-destructive alternatives (architectural evaluation only)
- **Reuse an existing certificate whose key is on another device** — only the Xcode cert has a local (Mac) key. Using it to sign on the iPhone means importing that key onto the device, which breaks the device-local, non-extractable-key invariant. **Conflicts.**
- **Transfer a signing identity** — requires exporting the private key. **Conflicts** with the non-extractable design.
- **External signing without exporting the key** — the key-holder (Mac) performs the signature, i.e. a Mac companion / signing service. **Excluded** by the no-Mac goal.
- **An Apple-supported separate device-local certificate for this team** — that is exactly our CSR; it is refused while a current certificate or pending request exists. No supported path to an additional independent certificate beyond the (unknown) cap without freeing a slot.
- **Paid Apple Developer Program** — would materially raise certificate allowances and enables the ASC API signing path already scoped (PR #50/#51). **Excluded** here; abandons the free-account goal. Noted, not implemented.

### Risks of revoking an existing certificate
- Revoking the Xcode cert `5657782A` would break Xcode signing on the Mac. **Protected — never revoke.**
- Revoking either non-Xcode cert carries **unknown, unquantified risk**: apps signed with a revoked certificate can stop launching, and these certs' usage is not established. They are `unknownUsage`, never assumed unused merely for being legacy-named or absent from the iPhone Keychain.
- Even after a revoke, a new certificate is only guaranteed to issue if the cause was a cap — which is unproven. If the cause is a pending request, revocation does not help.

### Recommended next action (requires separate authorization — not run here)
Do NOT revoke anything. The lowest-risk next step is a **read-only probe for outstanding pending certificate requests** — the untested half of the 7460 message. Our current tooling lists issued certificates only; if the developer-services API exposes a pending-requests listing, a pending request from our own attempts may resolve into a certificate (reconcile would recover it) or age out, with no revocation needed. If no such listing exists, document that as a gap. Only if the account is confirmed to be at a genuine, cap-driven limit should an explicit, separately-consented revocation of a specific, usage-established certificate be considered.

---

## Imported-identity bootstrap (one-time Mac→iPhone) — offline prototype (2026-11-24)

A SEPARATE, opt-in signing path (`ZagImportedSigningIdentity`) that lets a user
import a password-protected PKCS#12 development identity once, then sign on the
iPhone. The device-generated, non-extractable key path is unchanged and
preferred. No real identity was exported/transferred; fixtures are synthetic.

### Feasibility verdict: FEASIBLE
| Question | Verdict | Basis |
|---|---|---|
| Active Xcode key exportable? | Yes (mechanism) | Mac login-keychain Apple Development keys export as PKCS#12 via the standard flow; not exported here |
| Cert type compatible with dev profiles? | Yes | Apple Development cert, OU `V54K5JYGS4` — the type dev profiles embed |
| Key algorithm supported by the Zsign callback? | Yes | RSA-2048; the callback is `SecKeyCreateSignature(.rsaSignatureDigestPKCS1v15Raw)` — host test produces a 256-byte signature |
| Security.framework import/use? | Yes | `SecPKCS12Import → SecIdentity → cert+key`, signs with `SecKeyCreateSignature` (proven on host; iOS API identical) |
| ThisDeviceOnly protection? | Yes | stored `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, non-synchronized |
| Reuse the cert without a new CSR? | Yes | signing uses the imported cert+key directly |

### The imported path (`ZagImportedSigningIdentity`)
- `importIdentity(pkcs12:password:)` — `SecPKCS12Import`; wrong password / corrupt → `wrongPasswordOrCorrupt`; passphrase used only transiently, never stored or logged.
- `validate(_:now:expectedTeam:)` — key↔cert correspondence (challenge sign/verify, the same proof the device path uses), development-suitability (CN prefix), validity window, and optional team (OU) — typed failures (`keyCertMismatch`, `certExpired`, `notDevelopmentCertificate`, `teamMismatch`).
- `zsignSigner(_:)` — returns the **same** `ZagKeychainSigningKeys.signer` closure the device-key path hands to Zsign, so the signing pipeline is unchanged.
- `store/load/delete` — Keychain identity items, ThisDeviceOnly, under a dedicated label prefix, never conflated with the non-extractable device keys.
- Certificate parsing uses the iOS-safe DER inspector `ZagCertificateInspection` (extended with the subject OU); `SecCertificateCopyValues`/`kSecOIDX509V1*` are macOS-only and are not used.

### Security distinction (preserved in model + UI)
`ZagImportedIdentityInfo.isNonExtractable` is ALWAYS `false`. An imported key is
extractable key material — a weaker posture than a device-generated
non-extractable key. This path is a bootstrap/prototype, not a permanent
replacement, and the two are never represented as equivalent.

### Provisioning reuse (Phase 3)
A development profile is reusable with the imported identity only if it embeds a
certificate whose serial matches the imported identity AND its device UDID,
bundle identifier, entitlements and expiry validate — team match alone is
insufficient. `ZagProfileIdentityAudit` already validates team/device/bundle/
expiry; serial-membership against the imported identity is the remaining wiring,
to be exercised against a real profile under separate authorization.

### Pending-certificate-request endpoint (Phase 4)
Bounded offline search of our codec (`ZagDeveloperServicesAction`) and the
AltSign/SideStore action vocabulary finds **no** mechanism to list *pending*
certificate requests: the known actions are listTeams / listDevices /
listAllDevelopmentCerts / listAppIds / listApplicationGroups /
listProvisioningProfiles / addDevice / submitDevelopmentCSR / revokeDevelopmentCert,
and the v1 JSON lists *issued* certificates only. The `submissionUnconfirmed` /
`unresolvedRequest` references in the code are our OWN local journal, not an
Apple query. No pending-request endpoint is implemented or invoked.

### Can the imported identity sign an IPA entirely on-device?
The signing primitive — yes: the Zsign callback over the imported key is the
same one the device path uses and runs on iOS (proven: 256-byte RSA-2048
signature, verified against the certificate's public key). A COMPLETE IPA also
needs a provisioning profile embedding this cert + the target device UDID +
matching entitlements; that reuse is identified but not yet exercised live.

### Remaining steps to transfer the real identity securely (each needs authorization)
1. On the Mac, export the Apple Development identity once as a strong-password PKCS#12.
2. User-initiated in-app import (file picker / share sheet) — never via logs or temp files.
3. In-app: prompt for the export password, `SecPKCS12Import`, validate (correspondence + team `V54K5JYGS4` + development + validity), store ThisDeviceOnly, zero the password and plaintext promptly.
4. Validate/reuse a development profile embedding this cert's serial + device UDID + bundle + entitlements + expiry.
5. Sign the IPA on-device via the existing Zsign callback; install.

### Free Personal Team limitations (carried forward)
7-day provisioning profiles (weekly re-sign), limited devices/App IDs, and the
existing-certificate/pending-request conflict (resultCode 7460) when issuing new
certificates — which this bootstrap sidesteps by reusing an existing identity
rather than requesting another.

---

## Imported-identity signing pipeline — complete offline vertical slice (2026-11-24)

Builds on the imported-identity bootstrap: profile↔identity↔device↔bundle
validation, explicit identity selection, the import UX, and an end-to-end
offline signing proof. Device-generated non-extractable path unchanged.

### Components
- `ZagMobileProvision` — iOS-safe `.mobileprovision` parsing (scans the CMS blob for the embedded cleartext plist; no macOS-only CMSDecoder), yielding team, `DeveloperCertificates` (DER), `ProvisionedDevices`, expiry, `application-identifier`, entitlement keys.
- `ZagImportedIdentityProfileMatch.evaluate(...)` — authoritative, fail-closed compatibility: certificate present in `DeveloperCertificates` (compared by **DER SHA-256**, not serial), team match, device **provisioning UDID** in `ProvisionedDevices` (never a CoreDevice id), not expired, bundle id under `application-identifier` (with `*` / trailing `.*` wildcard semantics), requested entitlements ⊆ profile entitlements, development-signing suitability.
- `ZagSigningSource` — explicit `.deviceGenerated(keySlot:)` vs `.imported(label:)`; **no silent fallback**. `ZagImportedSigningIdentity.resolve(label:…)` re-validates and returns the Zsign signer + cert DER, or a typed failure — it never substitutes the device key.
- `ZagImportedSigningIdentity.zsignSigner` — the SAME `ZagKeychainSigningKeys.signer` closure the device path hands Zsign (raw PKCS#1 v1.5 DigestInfo).
- `ZagImportedIdentityImportView` / `…Model` — file picker (`.p12`/`.pfx`), secure passphrase, preview (cert/team/serial/expiry), explicit confirm, ThisDeviceOnly store, failure + removal states, and a plain statement that an imported key is extractable — not a device-generated non-extractable key. Passphrase + `.p12` bytes are in memory only and cleared after use; no plaintext file, no password logging.

### End-to-end offline validation (40/40 host checks)
Import (correct/wrong/corrupt), correspondence (match + mismatch), development/team/expiry validation, non-development rejection, sign/verify round-trip + tamper rejection, Zsign callback 256-byte RSA-2048 signature; profile parse; the full match matrix (compatible + certificateNotInProfile + teamMismatch + deviceNotProvisioned + profileExpired + bundleMismatch + disallowedEntitlements + notDevelopmentCertificate); wildcard semantics; explicit source selection; and the crux — **a signature by the imported key verifies under the EXACT certificate the profile embeds**. Full arm64 iOS build/link; dev-services suite 150/150; device-generated path untouched.

### Is the existing Xcode-generated provisioning profile reusable?
**Conditional — must verify its actual bytes, not assume.** It embeds the right
certificate (the Xcode `5657782A` cert) and team `V54K5JYGS4`, so two of the
checks would pass. Reuse additionally requires that the profile's
`ProvisionedDevices` lists THIS iPhone's provisioning UDID and that it has not
expired. Free Personal Team profiles expire in **7 days**, so an Xcode profile
is very likely already expired, and it may not list this specific device. The
validation to decide is implemented (`ZagImportedIdentityProfileMatch`); it needs
the real profile fed in. We did not inspect a real profile in this pass.

### First real iPhone signing + installation — exact minimal sequence
1. **Mac (offline):** Keychain Access → export the "Apple Development: …" identity as a strong-password `.p12`.
2. **iPhone (offline):** Zag Store → import screen → choose the `.p12` → passphrase → preview → confirm → stored ThisDeviceOnly.
3. **Compatible profile:**
   - *Offline* if a compatible, unexpired profile that lists this iPhone's provisioning UDID is already on hand (e.g. copied from the Mac's `~/Library/MobileDevice/Provisioning Profiles` or a built app's `embedded.mobileprovision`) — validated by `ZagImportedIdentityProfileMatch`.
   - *Requires Apple Developer Services* to obtain or **renew** a profile (7-day expiry), register this device's UDID, or mint a new App ID (QH65B2 `listProvisioningProfiles`/download). The imported **certificate** needs no Apple contact.
4. **Sign (offline):** select `ZagSigningSource.imported(label:)`, resolve → signer + cert, confirm profile match, run the existing Zsign path with the imported signer + `embedded.mobileprovision`; verify offline.
5. **Install + launch (offline transport):** install via the developer disk; iOS validates the signature + profile at install and launch. No Apple network for the install itself, but the profile's validity traces to Apple-issued data.

**Offline:** Mac export, iPhone import, signing, verification, install/launch, and reuse of an already-obtained compatible profile.
**Requires Apple Developer Services:** obtaining or renewing a provisioning profile, registering a new device, or a new App ID.

### Remaining blockers
1. A compatible, **unexpired** development profile that lists this iPhone's provisioning UDID — the Xcode profile is likely expired (7-day) and may need an Apple renewal.
2. The real export → import → install steps are gated behind explicit authorization (not performed).
3. The Mach-O/CMS assembly runs through Zsign on-device; the signing primitive it uses is proven here, but a full on-device IPA was not produced in this offline pass.

---

## Real-profile readiness + CMS/entitlement hardening (2026-11-24)

Offline inspection of the actual Xcode profile, plus two security corrections.
No Apple contact, no export, no install.

### The real profile (`75c25062…`, decoded + CMS-verified on the Mac)
`iOS Team Provisioning Profile: dev.zagstore.ptteamprobe`. `security cms -D`
verified its signature. Facts (identifiers masked):
| Field | Value |
|---|---|
| Created / Expires | 2026-11-23 / **2026-11-30** (7-day TTL) |
| Usable now? | **YES — ~5 days left** (as of 2026-11-24) |
| TeamIdentifier | `V54K…` (our team) |
| application-identifier | `V54K….dev.zagstore.ptteamprobe` (exact, matches target) |
| DeveloperCertificates | 3; one SHA-256 **matches** the Mac login-keychain Apple Development cert (the importable identity) |
| ProvisionedDevices | 1, and it **is** our iPhone's authoritative provisioning UDID |
| Entitlements | `application-identifier` (str), `com.apple.developer.team-identifier` (str), `get-task-allow` (bool true), `keychain-access-groups` ([`V54K5JYGS4.*`]) |

**Verdict: usable right now, until 2026-11-30.** Every compatibility dimension
passes against the importable identity: certificate present (DER match), team,
device, bundle, entitlements, validity. After 2026-11-30 it expires (7-day
free-team limit) and a renewal — which requires Apple Developer Services — would
be needed. Nothing needs renewing or changing before then.

### Security fix 1 — CMS trust (fail closed)
`ZagMobileProvision` previously located the plist inside the `.mobileprovision`
bytes without verifying the CMS signature — untrusted bytes could carry a forged
plist. Corrected:
- `extractUnverifiedPlist` / `parseUnverified` are explicitly UNVERIFIED (preview/display only).
- `parseVerified(_:verifier:)` returns contents only from a verifier-authenticated signed payload, and fails closed otherwise.
- `cmsVerificationAvailable` is currently **false** — iOS has no public high-level CMS-verify API (CMSDecoder is macOS-only); a vendored iOS CMS verifier is the identified missing piece.
- `ZagImportedIdentityProfileMatch.evaluate(..., cmsVerified:)` gates on verification FIRST and returns `.profileNotCMSVerified` when false, so real on-device signing refuses an unverified profile. (A profile verified on the Mac at export time, or a future vendored verifier, satisfies the gate.)

### Security fix 2 — entitlement values, not just keys
`ZagEntitlementAudit` now compares requested entitlements against the profile's
grant by VALUE and structure, failing closed:
- booleans must match exactly (cannot request `get-task-allow=true` the profile denies);
- strings match with wildcard rules (`*`, trailing `*` prefix) — covers `application-identifier` and `keychain-access-groups`;
- arrays require every requested element to be covered by a granted element;
- unsupported/complex values, type mismatches, or ungranted keys are rejected.

### Tests / build
Imported-identity + profile + entitlement suite: **56/56** (incl. CMS-unverified
fail-closed, boolean/string/array/wildcard entitlement rules, type-mismatch
rejection). dev-services 150/150. Full arm64 iOS build/link; subsystem typecheck
clean; device-generated path untouched.

### Shortest real-device sequence (unchanged flow; trust gates added)
1. **Mac (offline):** export the Apple Development identity as a strong-password `.p12`, AND capture the CMS-verified profile (the Mac verifies it) — *user authorization*.
2. **iPhone (offline):** import the `.p12` (preview → confirm → ThisDeviceOnly) — *user authorization*.
3. **Profile trust:** supply the profile as CMS-verified (verified on the Mac at export, or via a future on-device verifier). Until the iOS verifier exists, the profile must be marked verified by the trusted Mac-side step; otherwise signing fails closed.
4. **Sign (offline):** `ZagSigningSource.imported` → resolve → match (now valid, ≤2026-11-30) → Zsign with the imported signer + this `embedded.mobileprovision`; verify.
5. **Install + launch (offline transport):** iOS validates signature + profile.

**Requires Apple Developer Services:** only a profile **renewal after 2026-11-30**
(or a new device/App ID). Everything else is offline + user authorization.

---

## On-device CMS verification — the final trust gate (2026-11-24)

Closes the gap flagged in the readiness pass: the iPhone now cryptographically
verifies a provisioning profile itself, with no Mac-supplied trust boolean,
sidecar or digest shortcut.

### `ZagCMSVerifier` (new)
A small, auditable CMS (PKCS#7 SignedData, RFC 5652) verifier. It reuses the
repo's existing `ZagDER` ASN.1 walker for STRUCTURE only; all cryptography is
the Security framework — nothing re-implements ASN.1 crypto from scratch:
- **Signature:** locates the signer by `issuerAndSerialNumber`, and
  `SecKeyVerifySignature` checks the RSA signature. With CMS signed attributes
  present (as Apple profiles have), the `messageDigest` attribute must equal the
  digest of the eContent (binding the authentic payload to the signature) and
  the signature is checked over the DER of the signed attributes re-encoded with
  the SET tag. SHA-256 and SHA-1 digests supported.
- **Chain:** `SecTrust` with `SecPolicyCreateBasicX509`, `anchorCertificatesOnly`,
  and the verify date set — so certificate validity windows are enforced.
- **Trust anchor:** the classic **Apple Root CA**, pinned by SHA-256
  `b0b1730e…1001f024` (public, well-known). The anchor certificate is taken from
  the CMS's own certificate set but is trusted ONLY when its fingerprint equals
  the pinned value; a substituted root fails the fingerprint check, and SHA-256
  preimage resistance prevents forging one.
- **Fail closed:** malformed CMS, not-SignedData, no signer cert, digest
  mismatch, bad signature, no pinned anchor, or an untrusted/expired chain each
  return a typed failure and NO payload. The only success output is the
  authenticated eContent bytes.

### Integration
- `ZagMobileProvision.parseAppleVerified` parses ONLY the content
  `ZagCMSVerifier` authenticates; `cmsVerificationAvailable` is now `true`.
- `ZagSigningPreflight.prepare(...)` is the single real-signing entry point. It
  derives the `cmsVerified` flag passed to the compatibility check solely from a
  successful `ZagCMSVerifier.verify` — there is deliberately no parameter by
  which a caller can assert `cmsVerified = true`.

### Cryptographic test results
`scripts/test-zag-cms-verifier.sh` — **11/11** against a synthetic
root→intermediate→signer chain and the REAL Apple profile:
valid+trusted → authenticated payload; tampered payload → digest mismatch;
corrupted signature → bad signature; untrusted root (pinned to the synthetic
root) → no trusted anchor; malformed bytes → rejected; wrong pinned fingerprint
→ rejected; verify-date past validity → untrusted chain; **the real
`75c25062…` profile verifies against the pinned Apple Root CA and fails closed
when one byte is flipped.** Preflight composition (in the imported-identity
suite): verified+compatible → ready; untrusted CMS (identical contents) →
profileNotTrusted; wrong anchor → profileNotTrusted; verified but wrong device →
incompatible (not ready). Imported-identity suite 59 checks; dev-services
150/150. Full arm64 iOS build/link; subsystem typecheck clean.

### Shortest real-device test sequence + where trust/authorization sit
1. **Export (Mac) — offline, USER AUTHORIZATION.** Keychain Access → export the Apple Development identity as a strong-password `.p12`.
2. **Transfer to iPhone — offline, USER AUTHORIZATION.** Move the password-protected `.p12` (e.g. AirDrop/Files). The profile bytes can travel unprotected; their trust comes from CMS verification, not the transfer.
3. **Import — offline.** Import UX: preview → confirm → ThisDeviceOnly.
4. **Independent on-device profile verification — offline, NOW IMPLEMENTED.** `ZagCMSVerifier` validates the profile's signature + chain to the pinned Apple Root CA on the device; no Mac boolean involved.
5. **Sign the IPA — offline.** `ZagSigningSource.imported` → preflight `.ready` → Zsign with the imported signer + this `embedded.mobileprovision`.
6. **Install + launch — offline transport, USER AUTHORIZATION.**

**No Apple network is required** for the first real test (the profile is valid
through 2026-11-30 and the certificate already exists); only a profile renewal
after that date would.

### Remaining integration gaps (NOT yet done — end-to-end signing is NOT proven)
- **No complete IPA has actually been signed yet.** The Zsign Mach-O/CMS
  assembly runs on-device and has not been executed end-to-end against a real
  app bundle in this offline pass. The signing primitive and the preflight are
  proven; the full IPA output is not.
- Real key export, transfer, import and installation are gated on explicit
  authorization and have not been performed.
- The verifier handles the `issuerAndSerialNumber` signer form Apple profiles
  use; the `subjectKeyIdentifier` (v3) form is rejected (fail closed).

---

## First real on-device signing experiment — the device harness (2026-11-24)

The supervised experiment runs entirely inside the Zag Store (Feather) app on
the iPhone; this CLI cannot drive the device, so this is the harness the
operator runs. The passphrase is typed on-device and never leaves it.

### Step 1 result (verified offline, on the Mac)
The active login-keychain identity **"Apple Development: …(R3DNK3YV9S)"**, team
OU `V54K5JYGS4`, valid to 2027-09-27, has certificate DER SHA-256 `7f64f574…`
that **exactly matches `DeveloperCertificates[2]`** in profile `75c25062…`. The
profile is CMS-valid and expires **2026-11-30**. Identity↔profile match holds.

### What was built
- `ZagSigningExperiment` — the runner. Import+validate identity (ThisDeviceOnly) → sign/verify a test payload → verify the profile with `ZagCMSVerifier` → require `ZagSigningPreflight.prepare` = ready → assemble a minimal single-binary `dev.zagstore.ptteamprobe` app around the running executable → `Zsign.signComponents` with the imported-identity signer callback → `Zsign.verifyComponents` (library's own re-check) → an INDEPENDENT (non-Zsign) verify (our `ZagCMSVerifier` on the embedded profile + Mach-O CMS-signature inspection + bundle id + entitlements) → package the IPA. Fails closed, no retry, **no install/launch**. The report is sanitized (no passphrase/key/full identifiers).
- `ZagSigningExperimentView` — the on-device driver: pick `.p12` + profile (or "use this app's embedded profile"), passphrase `SecureField` (cleared after the single run), Run, sanitized step list.
- A `#if ZAG_SIGNING_EXPERIMENT` entry under Settings → Experimental Features ("First Signing Experiment").

### Key findings
- **Signer wiring already proven.** The imported-identity `zsignSigner` returns the identical `ZagKeychainSigningKeys.signer(key)` callback the existing offline `ZagStrictSigningIntegrationTests` drives through `Zsign.signComponents`/`verifyComponents`. The imported `SecKey` yields the same signer.
- **The real Apple cert chains without extra input.** Zsign embeds the Apple WWDR intermediates (`s_szAppleDevCACertG3`/`s_szAppleDevCACert`) and picks the one that actually issued the signing certificate, verifying its signature. So the imported Apple Development cert chains correctly with no `extraIntermediates` (the runner passes none), matching the production release path.

### Operator run procedure (on the iPhone)
1. **Export (Mac, done by you):** Keychain Access → export the "Apple Development: …(R3DNK3YV9S)" identity as a strong-password `.p12`, outside any repo/shared/cloud folder.
2. **Build the experiment app:** build Feather with `-D ZAG_SIGNING_EXPERIMENT` (Other Swift Flags) under your Personal Team (automatic signing), onto the test iPhone via Xcode.
3. **Transfer inputs to the iPhone:** AirDrop the `.p12`; the profile is already in the app (use "this app's embedded profile") or transfer `75c25062….mobileprovision`.
4. **Run:** Settings → Experimental Features → **First Signing Experiment** → choose the `.p12`, choose/confirm the profile, type the passphrase, **Run**.
5. **Capture:** screenshot the sanitized step list and the final "ready / not ready" line and paste it back here for analysis. **Do not install the IPA** — installation is a separate authorization.

### Verification done this pass
Focused arm64-iOS typecheck of the new runner + view (clean). The guarded
`Zsign` calls match the `ZsignSwift` wrapper signatures; the full Zsign link
happens in your Xcode build. Regression: CMS 11/11, imported-identity 59,
dev-services 150/150.

### Remaining blockers / honest status
- **End-to-end signing is NOT yet proven** — no complete IPA has been signed; that happens when you run the harness on the device. This pass delivered the harness, not a signed artifact.
- Steps 2–5 require your on-device action (export, build, transfer, run); I cannot drive the device from the CLI.
- The device-membership preflight check is self-consistent on-device (the provisioning UDID is not readable via a public iOS API; the profile lists one device and the OS installed the app under it).

---

## Native standalone provisioning — 7460 root cause + certificate-conflict recovery (2026-11-24)

Returns the primary objective to fully standalone on-device provisioning (no
Mac, no .p12, no imported identity). The imported-identity code is preserved,
not extended. All offline; no Apple requests, no CSR, no revocation.

### Phase 1 — 7460 root cause (verified vs hypothesis)
**What produced it (verified, from the code + the live account's public data):**
- Endpoint `POST https://developerservices2.apple.com/services/QH65B2/ios/submitDevelopmentCSR.action?clientId=XABBG36SBA`. Certificate type = development, implicit in the action (no explicit `certificateType` parameter). Body params: `csrContent` (PEM of our PKCS#10 — CN + RSA-2048 public key, SHA-256 self-signed), `machineName="Zag Store"`, `machineId` = a fresh random UUID per call. CSR built by `ZagCertificateSigningRequest.make`.
- Response: **HTTP 200, resultCode 7460** — a well-formed request that reached issuance and was refused at the application level (not transport, not malformed, not HTTP 429).
- The team already holds **three valid development certificates**, all for the same account/team (`…(R3DNK3YV9S)` / `V54K5JYGS4`): two legacy **"iPhone Developer"** (expire 2027-09-06 and 2027-09-12) and one modern **"Apple Development"** (2027-09-27, the active Xcode cert). Same issuance category (iOS development signing), different naming eras.
- **None of the three matches our device-generated non-extractable key.**
- Apple exposes **no read-only API for PENDING certificate requests**: `listAllDevelopmentCerts` and `/services/v1/certificates` list ISSUED certificates only. The pending arm of 7460 is therefore not directly observable — only inferable from our own journal, or ruled out when a later-listed certificate matches our key.

**Conclusion:** 7460 here is the **"existing certificate"** arm — the free Personal Team already has current development certificates and Apple will not issue another for our new key. This is an account/team-wide state, not a payload defect; the random `machineId` does not avoid it.

**Hypotheses (explicitly NOT asserted as fact):**
- A specific numeric certificate cap. Three valid certs are present and a new CSR is refused; whether the limit is 2, 3 or a per-machine "one current" rule is **unproven**. No cap is assumed anywhere in the code.
- Whether the random `machineId` (AltStore/SideStore persist a stable one) contributes. Established tools persist a machine id; ours is per-call. Not shown to be causal.
- Which arm (existing vs pending) in the general case — Apple conflates them; we disambiguate from the readable issued-cert listing.

**Is our CSR request protocol-correct?** Structurally yes — it matches the AltSign/SideStore `submitDevelopmentCSR` shape. Two deviations are noted as follow-ups, neither proven to cause 7460: the per-call random `machineId`, and reliance on the action's implicit certificate type.

**How established tools handle it without a Mac/export:** AltStore / SideStore / Xcode free provisioning generate the key on-device and, when the free team is at its development-certificate allotment, **revoke an existing free-team development certificate to make room**, then submit the new CSR. They never import a desktop identity. The revoke-to-replace behaviour is community-documented for free-team signing (not Apple-documented).

### Phase 2/3 — the legitimate native recovery path
The recovery architecture already present is reused, not duplicated:
`ZagExistingAccountPreflight` (read-only reuse/needs-new/blocked inventory),
`ZagCertificateRecoveryModel` + the provisioner's recovery service (Check Again /
Abandon for an unconfirmed request), `ZagActiveCertificateGuard` (protects the
active Xcode cert) and `ZagCertificateRevocation` (consent-gated, explicit `id`,
never auto). The missing authoritative piece — now added — is:

**`ZagCertificateConflictResolution`** (pure, no I/O, no revoke): given the 7460
conflict plus the readable issued-certificate listing, the serials this device
holds a matching key for, and the active-cert guard, it decides:
- `recoverExisting(serial)` — a listed valid cert matches a key we hold → reuse; nothing requested or revoked.
- `resolvePendingRequest` — no existing valid dev cert listed → the pending arm → Check Again / Abandon (never a blind resubmit).
- `replacementRequired(candidates)` — existing valid certs, none reusable → the user must EXPLICITLY choose one to replace; candidates **exclude the active Xcode certificate**; nothing is revoked until the user decides.
- `onlyActiveCertificatePresent` — the sole valid cert is the protected active one → a separate authorization is required.
- `listingUnavailable` — unreadable listing decides nothing (never treated as empty).

For the current test account this resolves to **`onlyActiveCertificatePresent`
or `replacementRequired`** depending on how many of the three the listing marks
revocable — and because the active cert is protected and no other cert is held,
**no automatic path exists; replacement needs the owner's explicit, informed
consent**, which is exactly the intended behaviour.

### Phase 4 — remaining native pipeline gaps
From a device-generated development certificate to an installed IPA, reusing the
completed components (`ZagCMSVerifier`, entitlement validation, preflight, Zsign
`signComponents`):
1. **Certificate (the blocker):** resolved in design by the above; obtaining a device-key certificate still requires either a genuine free slot or an owner-consented replacement. **No signable device-key certificate exists yet** for this account.
2. Device registration / App ID: native portal has `addDevice` / `addAppID` (consent-gated); not exercised live.
3. Profile: `downloadTeamProvisioningProfile` (creates/renews — a mutation) → `ZagCMSVerifier` verifies it. Ready.
4. Sign / verify IPA on-device: `ZagSigningPreflight` + `Zsign.signComponents` + independent verify — implemented (the imported-identity harness exercises the same path).
5. Install / launch: RPPairing installer — out of scope (no install authorized).

### Phase 5 — offline milestone delivered
`ZagCertificateConflictResolution` + 11 focused tests (both 7460 arms, reuse
priority, active-cert exclusion, replacement candidate ordering, autonomous-vs-
consent). dev-services suite otherwise unchanged (the lone intermittent
"coarse days" check is a day-boundary flake, passes on rerun). CMS 11/11,
imported-identity suite green. Full arm64 iOS build/link; subsystem typecheck
clean. The non-extractable device key architecture is untouched; the imported
path is preserved and not used as a fallback.

---

## Replacement preparation: legacy-cert audit, stable machineId, replacement coordinator (2026-11-24)

Offline preparation for a possible owner-authorized replacement of a legacy
development certificate. No Apple requests, revocations, CSRs, new keys, imports
or installs.

### Legacy certificate audit (read-only, masked)
All three team certificates are the same account/team (`…(R3DNK3YV9S)` /
`V54K5JYGS4`), EKU **Code Signing**, issued Sep 2026, valid one year:
| cert | type | serial | sha1 | expires | key on this device? | usage |
|---|---|---|---|---|---|---|
| legacy A | iPhone Developer | …5EBF18 | 8ECC4AB7… | 2027-09-06 | no | **unknown** |
| legacy B | iPhone Developer | …97B76D | 8E128662… | 2027-09-12 | no | **unknown** |
| active | Apple Development | …16EED9 | 5657782A… | 2027-09-27 | yes (Mac/Xcode) | **active — protected** |

The two legacy certs are the older free-account ("iPhone Developer") naming, a
different era from Xcode's "Apple Development"; the coexistence suggests they
came from a different free-signing tool/flow. **We hold no private key for
either legacy cert, and have no verifiable evidence that either is unused.**
Both remain `unknownUsage`; neither is labelled safe to revoke.

**Least-disruptive candidate (heuristic, not an evidence of safety):** legacy A
(…5EBF18) — soonest to expire (2027-09-06), so replacing it forfeits the least
remaining validity, and it is not the active Xcode cert. This is only an
ordering heuristic; usage is unknown, so revocation still needs the owner's
explicit, informed decision. (`ZagCertificateConflictResolution` already orders
replacement candidates soonest-expiring first, so legacy A surfaces first.)

### machineId correction
The native CSR sent `machineId = UUID().uuidString.uppercased()` — a fresh value
per request. Corrected to a **stable, securely persisted** identifier
(`ZagMachineIdentifier`): an opaque per-install UUID created once and kept in the
Keychain (ThisDeviceOnly, not synced, generic-password item
`app.zagstore.anisette.appleauth.machineid.v1`). `submitDevelopmentCSR` now sends
`ZagMachineIdentifier.current()`. This matches the established protocol's
machine-identity semantics and stops the account from accruing certificates that
look like they came from many machines. It is a label, not a key: the pending
non-extractable key and CSR are untouched and are NOT regenerated.

### Certificate-replacement coordinator (`ZagCertificateReplacementCoordinator`)
A pure, Codable, interruption-surviving state machine (no I/O; never revokes or
requests). Enforced and tested:
- The user selects the **exact** certificate (id + serial + sha1 captured at selection).
- The **active Xcode cert is rejected at selection** (`protectedActiveCertificate`).
- Revocation needs a **separate explicit confirmation** (`confirmRevoke`); `mayRevoke` is true only in `revokeConfirmed`.
- CSR submission needs a **second, separate authorization** (`authorizeCSR`), reachable only from a *succeeded* revoke; `maySubmitCSR` is true only in `csrAuthorized`.
- **No chained mutations / no auto-retry:** each step is a distinct event; skipping a gate yields `abandoned(.illegalTransition)`; terminal states ignore further events.
- A **failed or ambiguous revoke halts** (`revokeHalted`) and can never advance to CSR.
- **Interruption recovery:** a revoke in flight becomes `revokeHalted(.interruptedDuringRevoke)` (needs an out-of-band re-check); a CSR in flight becomes `submissionUnconfirmed` (hand to `ZagCSRReconciliation`); neither ever becomes `completed`. State round-trips through Codable for a durable journal.

### Tests / build
Added focused tests (dev-services suite, ALL PASS): machineId stability/persistence/
corrupt-replacement; wrong/skip transitions → illegal; protected-cert rejection;
duplicate-operation no-ops; failed & ambiguous revoke cannot advance; interruption
recovery for both mutations; Codable round-trip. Full arm64 iOS build/link clean;
subsystem typecheck clean. Non-extractable key architecture untouched; imported
path not involved.

### Next proposed LIVE operation (requires separate authorization) + risks
1. **Read-only recheck** of the team's certificate listing to re-confirm, at the
   moment of action, that the candidate (legacy A, …5EBF18) is still present and
   is not the active cert. Risk: none (read-only).
2. **Revoke legacy A** (one `DELETE /services/v1/certificates/<id>`), gated on
   explicit confirmation. **Risks:** any app or workflow still signed with legacy
   A's identity would lose that signing identity; because its private key is not
   on this device and its usage is unknown, we cannot rule out that something
   elsewhere depends on it. Irreversible (a revoked cert cannot be un-revoked).
3. **Submit the preserved CSR** for the device-generated key (second, separate
   authorization). **Risks:** if the free team enforces a per-machine/per-account
   rule rather than a simple count, a single freed slot may still not admit the
   new CSR (another 7460); the coordinator halts rather than retrying.

Stop before any account mutation.

---

## Certificate-replacement integration: driver, consent, journal, UI (2026-11-25)

Connects the pure `ZagCertificateReplacementCoordinator` to the native portal
client, the mutation-consent coordinator and a durable journal, plus a native
SwiftUI workflow. Offline only — no Apple requests, revocations, CSRs, new keys,
imports or installs; the entry point is behind the DISABLED portal and a gate
(`ZAG_CERT_REPLACEMENT_EXPERIMENT`).

### Integrated components
- **`ZagReplacementPortal`** — a narrow seam over the already-existing portal ops
  (read-only `revocableCertificates`, `revokeCertificate`, `submitCertificateRequest`).
  `ZagNativeDeveloperPortal` conforms directly; **no new Apple endpoint** (the new
  `revocableCertificates` reuses the established `/services/v1/certificates` GET,
  preserving the v1 `id` + DER SHA-1 so a revoke targets the exact certificate).
- **`ZagCertificateReplacementService`** — stateless, fully-tested helpers:
  `verifyTargetForRevoke` (fresh-listing re-verification), `classifyRevokeFailure`
  / `classifySubmitFailure`, `reconcileVerdict`.
- **`ZagCertificateReplacementDriver`** (`actor`) — owns the journal, consent and
  portal; drives the coordinator; persists the journal before every network step.
- **Coordinator evolution** — `revokeHalted` now carries the full target, and
  `reconcileHaltedRevoke(verdict:)` re-enters a halted flow only from a read-only
  re-listing (gone → `revoked`; present → `selected`; unavailable → stays halted).
- **UI** — `ZagCertificateReplacementView` + `ZagCertificateReplacementModel`
  (@MainActor): inventory & status, the protected active cert flagged IN USE,
  per-candidate unknown-usage warnings, exact selection, a separate destructive
  revoke confirmation, a separate CSR authorization screen, and recovery /
  reconciliation screens. A standing disclaimer states replacement is **not
  guaranteed** to resolve 7460.

### Independent authorization & interruption safeguards
- Revoke and CSR are **two separate driver calls**, each taking its own consent
  (`.revokeCertificate`, then `.submitCSR`); the revoke's consent is cancelled on
  success so it cannot carry into the CSR.
- **Before revoke:** refresh the listing; confirm the exact cert still exists,
  its SHA-1 still matches, and it is not the protected active cert; else fail
  closed (`targetNoLongerPresent` / `fingerprintMismatch` / `targetNowActive` /
  `listingUnavailable`) with no mutation.
- **After a successful revoke:** persist `revoked` and **STOP** — the CSR is never
  auto-submitted (test-proven: `submitCalls == 0` at that point).
- **Before CSR:** a second consent, reachable only from `revoked`; it is consumed
  and the `submitting` write-ahead persisted **before** transmission; submitted
  **exactly once**, no retry.
- **Write-ahead + recovery:** `revoking`/`submitting` are persisted before the
  call, so launch recovery turns an interrupted revoke into
  `revokeHalted(.interruptedDuringRevoke)` and an interrupted CSR into
  `submissionUnconfirmed` — never `completed`.
- **Ambiguity:** any revoke failure is treated as ambiguous and halts; it cannot
  advance to the CSR until a **read-only reconciliation** proves the cert gone.
  A **repeated 7460** after a successful revoke is surfaced as `repeatedConflict`
  (the flow abandons; it is never mistaken for success) — i.e. a freed slot is
  never assumed to create an available issuance slot.

### Is the whole workflow executable on a stock iPhone?
No — by design and by authorization. All logic, gating, consent, journalling,
recovery and UI are implemented and tested offline, but the three live steps
(list / revoke / submit) run only against the DISABLED portal here. Executing
them needs a live portal (currently behind `ZagLivePortal.isEnabled == false`)
and the owner's separate, explicit authorization. The original device-generated
signing path is untouched.

### Validation
213-check dev-services suite (full replacement, repeated 7460, ambiguous revoke
→ reconcile both ways, interrupted revoke, interrupted CSR, protected-cert
rejection, stale inventory, fingerprint mismatch) + CMS 11/11 + imported-identity
green. Whole-directory arm64-iOS typecheck clean; arm64-iOS whole-module codegen
of the new files (incl. the SwiftUI view) produced a Mach-O object. (The lone
intermittent "coarse days" check is the pre-existing day-boundary flake.)

### Current native CSR & Keychain state
Unchanged: the preserved device-generated non-extractable RSA-2048 key and its
original CSR remain pending and are NOT regenerated. `machineId` remains the
stable per-install Keychain value. The replacement flow, when authorized, would
reuse that exact key/CSR for the post-revoke submission.

### Minimum separately-authorized live sequence to test replacement
1. Enable the live portal for one bounded session (owner action).
2. Read-only `revocableCertificates` to populate and verify the inventory.
3. Owner selects the exact legacy candidate (…5EBF18); confirm it is not the
   active cert and its fingerprint matches.
4. Explicit revoke confirmation → ONE `revokeCertificate`. Then STOP and persist.
5. Read-only re-list to confirm the revoke landed (reconcile if ambiguous).
6. Separate CSR authorization → ONE `submitCertificateRequest` reusing the
   preserved key/CSR. **Risks:** revocation is irreversible and may break an
   unknown dependent; the CSR may still 7460 if the team enforces a per-machine/
   account rule rather than a count — the flow halts, never retries.
