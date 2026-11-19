# G5: redacted diagnostic logging for the first controlled experiment

Status 19 November 2026: **specification only. Nothing is implemented.**

This document specifies what the experiment build (`G5-EXPERIMENT-BUILD-PLAN.md`) records, and the failure report the owner can share with GPT-6.
- The logger is compiled only under `ZAG_LIVE_EXPERIMENT`, and is absent from every other build. The Release scan proves this.
- It is implemented only in the reviewed experiment commit (build plan §3.2), after approval.

## 1. Design principles

1. **Allowlist, not redaction.**
   - Every event is a typed record. Every field is an enum, a bounded integer, a boolean, a duration, or a value derived as in §3.
   - Free text from Apple, the anisette provider, the device or Rust error strings is **never** stored.
   - Errors are mapped to the closed `failure` enum (§6) at the boundary where they occur.
2. **Redaction as a second layer only.**
   - Every string field still passes through `ZagSensitiveRedactor` before it is stored, and again at export.
   - The existing `ZagFreeAccountDiagnostics`, a 50-entry free-text log, is not the experiment record. It keeps its role in Settings › Diagnostics.
   - Its redactor does not cover every identifier format, for example a 25-character device UDID with a hyphen, or a six-digit code. That is why the experiment record does not rely on it.
3. **Nothing leaves the device by itself.**
   - No network upload, analytics or crash reporting. Analytics are compiled out of the experiment build.
   - The report leaves the device only when the owner taps Export and chooses a destination.
4. **Bounded and local.**
   - At most 2,000 events per experiment ID, stored in the app container under the live-test namespace. Excluded from backups (`isExcludedFromBackup`).
   - Deleted by `clear`, by deleting the app, or by rollback (build plan §8.1).
5. **Correlation without identifiers.**
   - Values that must be compared across events (certificate serial, device, App ID, profile UUID, team) are logged as `ref` tokens: `HMAC-SHA256(runKey, kind ‖ value)`, truncated to 8 hex characters.
   - `runKey` is 32 random bytes generated per experiment ID and kept in the live-test Keychain namespace. It is **never exported**. Tokens therefore can't be reversed or linked to other runs, even for low-entropy values such as a team ID.
   - Wherever possible, a boolean comparison (`matchesExpected: true`) is logged instead of a token.

## 2. Event envelope

Each event is one JSON object, stored as JSON Lines:

| Field | Type | Notes |
|---|---|---|
| `seq` | integer | Monotonic per experiment ID, from 1. |
| `t` | integer | Milliseconds since the experiment's first event. **No wall-clock time** in events: the report header carries one rounded start time (§7). |
| `phase` | enum | §4 |
| `event` | enum | Per phase, §4 |
| `outcome` | enum | `started`, `ok`, `failed`, `cancelled`, `skipped`, `blocked`, `stopped` |
| `durationMs` | integer, optional | Rounded to 10 ms |
| `failure` | enum, optional | §6 |
| `fields` | object, optional | Only the fields listed for that event in §4 |
| `stopRule` | enum, optional | The build plan §7.3 rule that fired, if any |

Events that fail schema validation are dropped, and replaced by `{phase: "logger", event: "rejected", fields: {droppedPhase}}`. They are never stored "as is".

## 3. Value derivations

| Value | Logged as | Never logged |
|---|---|---|
| Apple Account | `account: "A"`, a fixed label (one account per experiment) | address, masked address, DSID, alternative DSID |
| Team | `teamRef` token; `teamCount`; `teamKind` (`personal`, `paid`, `unknown`) | team ID, team name |
| Device | `deviceRef` token; `deviceMatchesPairing: Bool`; `registeredDeviceCount` | UDID, serial number, ECID, device name, IMEI |
| Certificate | `certRef` token; `certificateCount`; `possessionMatch: Bool`; `expiresInDays` (integer); `hasDERContent: Bool` | serial number in clear, certificate bytes, public key, CSR, private key |
| App ID and profile | `appIDRef`, `profileRef` tokens; `bundleMatches: Bool`; `teamMatches`, `certMatches`, `deviceIncluded: Bool`; `expiresInHours` | bundle seed or App ID prefix, profile bytes, profile UUID in clear, entitlement values |
| Anisette | `providerHost` (the single G3 host, from a fixed table); `adiStatePresent: Bool`; `headerSetValid: Bool`; `headerCount` | `adi.pb`, the client identifier, `spim`, `cpim`, `ptm`, `tk`, any `X-Apple-I-*` or `X-Mme-*` value, the device serial sent to the provider |
| Sizes | bucketed: `<1 KB`, `1–10 KB`, `10–100 KB`, `100 KB–1 MB`, `>1 MB` | exact byte counts of responses |
| iOS version | `major.minor` in the report header only | build number |

## 4. Phases and events

### 4.1 `build`: the experiment build, at launch

| Event | Fields |
|---|---|
| `identity` | `branchSHA8`, `bridgeLibSHA8`, `zsignSHA8`, `experimentId8` (the first 8 characters of the random ID), `flags` (sorted list of the compile conditions present) |
| `configureLive` | `outcome`; `providerHost`; `serialPolicy` (enum: `g3Fixed`, `g3PerAccount`; not the value) |

### 4.2 `transport.preflight`: pairing and LocalDevVPN, before sign-in

| Event | Fields |
|---|---|
| `tunnel` | `vpnInterfacePresent: Bool`; `endpointAccepted: Bool`; `latencyMs` |
| `pairing` | `pairingPresent: Bool`; `pairVerify` (`ok`, `failed`, `notRun`) |
| `developerMode` | `confirmedByOwner: Bool` |

### 4.3 `anisette`

| Event | Fields |
|---|---|
| `clientInfo` | `outcome`; `httpStatus`; `durationMs` |
| `provisioning.start` | `adiStatePresent` (`false` triggers provisioning) |
| `provisioning.step` | `step` (`lookup`, `wsConnect`, `giveIdentifier`, `startMachineProvisioning`, `giveStartData`, `finishMachineProvisioning`, `giveEndData`, `success`); `outcome`; `httpStatus` (Apple steps only); `durationMs` |
| `provisioning.end` | `outcome`; `adiStateStored: Bool` |
| `headers` | `outcome`; `headerSetValid: Bool`; `headerCount`; `fresh: Bool` (`isFresh(maximumAge:)`) |

### 4.4 `net`: every HTTP or WebSocket request by the bridge, and the policy decision

One `net.request` event per request, emitted by the policy guard (`net_policy.rs` `Guard`) before the request is sent, and one `net.response` event after it completes.

| Event | Fields |
|---|---|
| `request` | `client` (`apple`, `anisette`); `host` (see below); `pathTemplate` (see below); `method`; `scheme`; `decision` (`allowed`, `blocked`); `blockReason` (`hostNotAllowed`, `notSecure`, `credentialsInURL`, `portInURL`, `redirect`, `disabled`) |
| `response` | `status`; `durationMs`; `sizeBucket`; `contentKind` (`plist`, `json`, `other`) |
| `tls` | `outcome`; `failure` (`untrusted`, `expired`, `hostname`, `other`) |

**Host and path recording:**
- **`host`:**
  - An allowed host is logged verbatim: `gsa.apple.com`, `developerservices2.apple.com`, or the G3 host.
  - A blocked host is logged verbatim **only if** it ends in `.apple.com` and is at most 64 characters (for example `idmsa.apple.com`). This is the compatibility evidence the experiment exists to collect.
  - Any other blocked host is logged as `nonApple`, with its label count.
- **`pathTemplate`:**
  - Chosen from a fixed table, for example `/grandslam/GsService2`, `/grandslam/GsService2/lookup`, `/auth/verify/trusteddevice`, `/auth/verify/phone`, `/auth/verify/phone/securitycode`, `/services/QH65B2/{op}.action`, `/services/v1/{resource}`, `/v3/client_info`, `/v3/get_headers`, `/v3/provisioning_session`.
  - Path segments that are identifiers become `{id}`. `{op}` and `{resource}` come from a fixed list of known operation names, with `unlisted` for anything else.
  - A path matching no template is logged as `unlisted`.
  - Query strings and fragments are never logged.
- **Lookup:** one `net.lookup` event records which URL keys the GsService2 lookup returned, and for each its host decision (`allowed` or `blocked`, with the blocked host recorded as above). It does not record the URLs.

### 4.5 `auth`: sign-in and 2FA state transitions

| Event | Fields |
|---|---|
| `signin.start` | `outcome: started`. The password is never logged, and neither is its length. |
| `srp` | `step` (`init`, `complete`); `outcome`; `failure` |
| `state` | `from`, `to`: values from `ZagFreeAccountState`, mapped to `signedOut`, `signingIn`, `awaitingTwoFactor`, `signedIn`, `failed` |
| `twoFactor.challenge` | `kind` (`trustedDevice`, `sms`, `unknown`); `smsNumberCount` (integer). **Never** a phone number, masked or not. |
| `twoFactor.request` | `kind`; `outcome` (for an SMS request or a trusted-device push) |
| `twoFactor.submit` | `outcome` (`accepted`, `rejected`); `attemptsRemaining`. **Never** the code, its length or its digits. |
| `twoFactor.limit` | `reason` (`tooManyCodes`, `locked`, `rateLimited`) |
| `session.validate` | `outcome`; `expiryUnit` (`seconds`, `milliseconds`, `invalid`); `expiresInHours`. This settles G4 §9 item 1. |
| `session.store` | `outcome`; `keychainAccessible` (`afterFirstUnlockThisDeviceOnly` or another class name) |
| `signout` | `outcome`; `itemsRemoved` (count) |

### 4.6 `portal`

| Event | Fields |
|---|---|
| `teams` | `outcome`; `teamCount`; `teamKind`; `teamRef` (only when there is exactly one) |
| `device` | `step` (`list`, `register`); `outcome`; `registeredDeviceCount`; `deviceRef`; `deviceMatchesPairing` |
| `appid` | `step` (`list`, `register`); `outcome`; `appIDCount`; `appIDRef`; `capacityRemaining` |
| `rateLimit` | `operation`; `retryAfterSeconds` (if Apple supplies it) |

### 4.7 `cert`: certificate request and recovery states

| Event | Fields |
|---|---|
| `preflight` | `outcome`; `certificateCount`; `hasDERContent: Bool` (E4) |
| `budget` | `submissionsBefore` (0 or 1); `decision` (`allow`, `budgetSpent`) (E1) |
| `key` | `outcome`; `keyClass` (`keychainRSA`); `exportable: false` (asserted); `slot` (`pending`) |
| `journal` | `transition` (`pendingCreated`, `submissionUnconfirmedSet`, `submissionUnconfirmedCleared`, `issuedRecorded`, `unresolved`, `pendingDiscarded`); `attempts` |
| `submit` | `outcome` (`issued`, `refused`, `unknown`); `durationMs`; `failure` |
| `verify` | `possessionMatch: Bool`; `certRef`; `expiresInDays` |
| `recovery` | `action` (`checkAgain`); `result` (`recovered`, `notIssued`, `unresolved`, `checkFailed`); `listingCount` |
| `limit` | `reason` (`certificateMustBeRevoked`); `candidateCount`. **Always followed by a stop.** |
| `swap` | `outcome`: the new identity replaced the previous one only after verification |

A `submit` with `outcome: unknown`, or any interruption between `submissionUnconfirmedSet` and the result, always produces `journal.unresolved` and a stop.

### 4.8 `profile` and `sign`: provisioning and signing results

| Event | Fields |
|---|---|
| `profile.fetch` | `outcome`; `profileRef`; `sizeBucket` |
| `profile.check` | `result` (`ok`, or a `ZagProvisioningProfileCheck.Problem` case name); `teamMatches`, `bundleMatches`, `certMatches`, `deviceIncluded`; `expiresInHours`; `entitlementNames` (sorted **key names** only, for example `application-identifier`, `get-task-allow`; never values) |
| `sign.start` | `componentCount`; `path` (`strictKeychain`) |
| `sign.component` | `index`; `kind` (`app`, `framework`, `extension`); `outcome` |
| `sign.verify` | `zsignVerify` (`ok`, `failed`); `keyFileWritten: false` (asserted; `true` is a safety failure) |
| `sign.package` | `outcome`; `sizeBucket` |

### 4.9 `install`: RPPairing installation outcomes

| Event | Fields |
|---|---|
| `start` | `transport` (`rppairing`); `network` (`wifi`, `cellularWithShortcut`, `other`) |
| `step` | `step` (`pairVerify`, `tunnel`, `rsd`, `afcUpload`, `installProxy`); `outcome`; `durationMs`; `failure` |
| `result` | `outcome` (`installed`, `refused`, `unknown`); `deviceErrorClass` (mapped enum, for example `signatureInvalid`, `profileMissing`, `profileExpired`, `deviceNotProvisioned`, `entitlementMismatch`, `other`). **Never** the device's raw message. |
| `launch` | `confirmedByOwner: Bool` |
| `verify` | `result` (`verified`, `mismatch`, `notVerified`, `unverifiable`); `installedProfileCount` |

### 4.10 `preflight.account`, `inventory`, `stop`, `report`

| Event | Fields |
|---|---|
| `preflight.account` | `a1`–`a6`: Bool (owner-confirmed; build plan §5.1) |
| `inventory` | `sessionItems`, `identityItems`, `pendingItems`, `anisetteItems`, `orphanItems` (counts) |
| `stop` | `stopRule`; `haltSet: Bool`; `ambiguityOutstanding: Bool` |
| `report.export` | `selfCheck` (`passed`, `blocked`); `eventCount` |

## 5. Prohibited data (never recorded, in any field, event or export)

| Category | Includes |
|---|---|
| Credentials | Apple Account password (and its length); 2FA codes (and their length or digits); SMS phone numbers, including masked |
| Tokens and sessions | GrandSlam tokens, `GsIdmsToken`, `myacinfo`, session tokens, cookies, `Authorization` headers, SRP values (`A`, `B`, `M1`, `M2`, salt, iterations), PET, HB tokens |
| Account identifiers | Apple Account address (in full or masked), DSID, alternative DSID, person ID, team ID, team name |
| Keys and certificates | private keys, PEM or DER blocks, CSRs, public keys, certificate bytes, serial numbers in clear, Keychain persistent references |
| Raw device identifiers | UDID, serial number, ECID, IMEI, device name, Wi-Fi or Bluetooth address, the device serial reported to anisette |
| Anisette provisioning data | `adi.pb`, the client or keychain identifier, `spim`, `cpim`, `ptm`, `tk`, every `X-Apple-I-*` and `X-Mme-*` header value, the `anisette-identity` contents |
| Free text from remote parties | Apple error descriptions, provider error bodies, the device's installation messages, Rust error strings (mapped to enums instead) |
| Payloads | request or response bodies, plists, profile bytes, IPA contents, URLs with query strings |
| Pairing material | pairing records, host keys, the six-digit pairing PIN, TLS-PSK values |

**If a value can't be classified, it isn't logged.** A field not in §4 is a schema violation and is dropped (§2).

## 6. The `failure` enum

A closed set, mapped at the boundary where each error occurs:
- `network.offline`, `network.timeout`, `network.tls`, `policy.blocked`;
- `http.4xx`, `http.5xx`, `http.429`;
- `apple.authFailed`, `apple.accountLocked`, `apple.twoFactorRejected`, `apple.twoFactorLimit`, `apple.sessionRejected`, `apple.unexpectedResponse`;
- `anisette.unavailable`, `anisette.provisioningFailed`, `anisette.invalidHeaders`;
- `portal.rateLimited`, `portal.deviceLimit`, `portal.appIDCapacity`, `portal.identifierUnavailable`, `portal.certificateLimit`, `portal.unexpectedResponse`;
- `cert.unresolved`, `cert.possessionMismatch`, `cert.budgetSpent`;
- `profile.invalid`;
- `sign.failed`, `sign.verifyFailed`;
- `install.refused`, `install.unknown`, `install.transport`;
- `keychain.storage`, `cancelled`, `deadline`, `experiment.halted`, `internal`.

Each maps from the existing Swift kinds (`ZagProvisioningFailure.Kind`, `ZagFreeAccountFailure`, `ZagAuthenticationServiceError`, `ZagAnisetteError`, `ZagPortalError`, `ZagBridgeFailure`, `ZagRPPairingFailureKind`) by a total `switch`. A new case can't compile without a mapping.

## 7. The structured failure report (for GPT-6)

Produced by **Export Report** in the experiment build, as two files the owner shares together: `g5-report-<experimentId8>.json` (machine-readable) and `g5-report-<experimentId8>.md` (the same content, readable).

```text
header:
  schema: "zag-g5-report/1"
  experimentId8, branchSHA8, bridgeLibSHA8, zsignSHA8, ipaSHA8 (experiment IPA, entered at build)
  startedAtUTC: rounded down to the hour
  iOS: major.minor; device: model class (e.g. "iPhone 15 Pro Max"), no identifiers
  gates: { G1..G6: recorded yes/no as entered at build time }
  providerHost, serialPolicy
verdict:
  class: PASS | SAFE STOP | UNRESOLVED STOP | SAFETY FAILURE   (build plan §7.2)
  stopRule (if any), firstFailure: { seq, phase, event, failure }
  invariants: { certificatesIssued, certificatesRevoked (must be 0), submissions,
                blockedRequests, keyFileWritten (must be false), reportSelfCheck }
summary by phase:
  per phase: started/ok/failed counts, total duration, last outcome
compatibility observations (the experiment's purpose):
  lookup keys and host decisions; 2FA kind offered; session expiry unit;
  teamKind and teamCount; free limits seen; hasDERContent; profile expiry hours;
  entitlement key names; install deviceErrorClass (if any)
outstanding state:
  unresolvedCertificateRequest: Bool; haltSet: Bool; inventory counts after sign-out
events:
  the full event list (§2), in order
owner notes:
  fixed choices only (e.g. "trusted-device prompt looked expected: yes/no");
  no free-text field
```

**Exporter self-check.** Before writing either file, the exporter scans the serialised output. It **blocks** the export (logging `report.export selfCheck: blocked` and naming the matching rule, not the text) if it finds any of:
- an email address;
- a PEM header;
- a base64 run of 24 or more characters;
- a hex run of 16 or more characters, other than the fields named `*SHA8` and `*Ref`, whose formats are checked exactly;
- a UDID pattern: 40 hex characters, or 8 hex characters, a hyphen and 16 hex characters;
- a 6-digit number outside the integer fields of the schema;
- a field name from §5;
- any URL with a query string;
- `X-Apple-` or `X-Mme-`.

A blocked export is a logger defect and is reported as such. The owner never edits the report by hand to make it pass.

## 8. Retention and handling

- On the device: until `clear`, app deletion or rollback (build plan §8.1).
- Shared only by the owner, to GPT-6 and Claude, through the repository as a sanitised Markdown file under `docs/free-developer-accounts/` after a final manual read, or as an issue attachment.
- **The pre-push guard stays in force:** it refuses the real device UDID.
- The JSON is not committed if the Markdown suffices.

## 9. Tests the implementation must ship with (before the experiment build)

1. **Schema tests.** Every event type round-trips, and an unknown field is dropped and replaced by `logger.rejected`.
2. **Leak corpus.**
   - Run a scripted mock run (the bridge `mock` backend, test-only) with synthetic secrets planted in every input: a password, a 6-digit code, a fake DSID, a fake UDID in both formats, a fake serial, fake `adi.pb` and identifier, PEM, `X-Apple-I-MD` values, emails and phone numbers.
   - The exported report must contain none of them. Run it with the self-check off too, to prove the allowlist alone suffices.
3. **Self-check tests.** Each §7 rule blocks a crafted report, and a clean report passes.
4. **Mapping totality.** A compile-time `switch` over every failure kind.
5. **Ref tokens.**
   - The same value gives the same token within a run, and different tokens across runs.
   - `runKey` never appears in an export.
6. **Absence from Release.** `test-zag-free-account-release-binary.sh` is extended with the logger's markers, for example `zag-g5-report/1`.
7. **Budget and halt (E1 and E2) events.** Covered by the mock run: `cert.budget` reports `budgetSpent` on a second request, and a stop sets the halt and blocks the next live operation.

## 10. Mapping from requested coverage to this spec

| Requirement | Section |
|---|---|
| Authentication and anisette phases | §4.3, §4.5 |
| Network destination and policy decisions | §4.4 |
| 2FA state transitions without codes | §4.5 (`twoFactor.*`), §5 |
| Certificate request and recovery states | §4.7 |
| Provisioning and signing results | §4.6, §4.8 |
| RPPairing installation outcomes | §4.2, §4.9 |
| Prohibitions | §5, §7 self-check, §9 leak corpus |
| Structured failure report for GPT-6 | §7 |
