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
