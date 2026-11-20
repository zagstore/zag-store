# G5: redacted diagnostic logging for the first controlled experiment

Status 19 November 2026, **revision 2: specification only. Nothing is implemented.**

This document specifies what the experiment build (`G5-EXPERIMENT-BUILD-PLAN.md`) records, and the failure report the owner can share with GPT-6.
- The logger is compiled only under `ZAG_LIVE_EXPERIMENT`, and is absent from every other build. The clean production build and scan (build plan §4.2) prove this.
- It is implemented only in the reviewed experiment commit (build plan §3.2), after approval.
- Revision 2 addresses GPT-6's findings 4–6 on `5839add7`; §11 lists the corrections.
- Revision 3 (with build plan revision 3) adds the campaign registry events (`campaign.durability`, `campaign.check`, `campaign.window`, `campaign.registryWrite`) and test L11.

## 1. Design principles

1. **Allowlist, not redaction.**
   - Every event is a typed record. Every field has a declared type and format (§7.1).
   - Free text from Apple, the anisette provider, the device or Rust error strings is **never** stored.
   - Errors are mapped to the closed `failure` enum (§6) at the boundary where they occur.
2. **Redaction as a second layer only.**
   - String fields still pass through `ZagSensitiveRedactor` before they are stored.
   - The existing `ZagFreeAccountDiagnostics`, a 50-entry free-text log, is not the experiment record.
   - Its redactor does not cover every identifier format, for example a 25-character device UDID with a hyphen, or a six-digit code. That is why the experiment record does not rely on it.
3. **Nothing leaves the device by itself.**
   - No network upload, analytics or crash reporting. Analytics are compiled out of the experiment build.
   - The report leaves the device only when the owner taps Export and chooses a destination.
4. **Bounded and local.**
   - At most 2,000 events per installation, stored in the app container under the live-test namespace. Excluded from backups (`isExcludedFromBackup`).
   - Deleted by `clear`, by deleting the app, or by rollback (build plan §8.1).
   - The campaign ledger (build plan §5.2) is separate and is **not** cleared with the log.
5. **Correlation without identifiers.**
   - Values that must be compared across events (certificate serial, device, App ID, profile UUID, team) are logged as `ref` tokens: `HMAC-SHA256(runKey, kind ‖ value)`, truncated to 8 lowercase hex characters.
   - `runKey` is 32 random bytes per installation, kept in the live-test Keychain namespace and **never exported**. Tokens therefore can't be reversed or linked to other runs, even for low-entropy values such as a team ID.
   - Wherever possible, a boolean comparison (`matchesExpected: true`) is logged instead of a token.

## 2. Event envelope

Each event is one JSON object, stored as JSON Lines:

| Field | Type and format | Notes |
|---|---|---|
| `seq` | integer, 1…2000 | Monotonic per installation |
| `t` | integer, 0…86,400,000 | Milliseconds since the installation's first event. **No wall-clock time** in events: the report header carries one rounded start time (§8). |
| `phase` | enum | §4 |
| `event` | enum | Per phase, §4 |
| `outcome` | enum | `started`, `ok`, `failed`, `cancelled`, `skipped`, `blocked`, `stopped` |
| `durationMs` | integer, 0…600,000, optional | Rounded to 10 ms |
| `failure` | enum, optional | §6 |
| `fields` | object, optional | Only the fields declared for that event in §4, each with its declared type |
| `stopRule` | enum, optional | The build plan §7.3 rule that fired, if any |

Events that fail schema validation (§7.1) at record time are dropped, and replaced by `{phase: "logger", event: "rejected", fields: {droppedPhase, droppedEvent}}`. They are never stored "as is".

## 3. Value derivations

| Value | Logged as | Never logged |
|---|---|---|
| Apple Account | `account: "A"`, a fixed label (one account per campaign) | address, masked address, DSID, alternative DSID, the hashed account key used by the ledger |
| Team | `teamRef` token; `teamCount`; `teamKind` (`personal`, `paid`, `unknown`) | team ID, team name |
| Device | `deviceRef` token; `deviceMatchesPairing: Bool`; `registeredDeviceCount` | UDID, serial number, ECID, device name, IMEI |
| Certificate | `certRef` token; `certificateCount`; `possessionMatch: Bool`; `expiresInDays`; `hasDERContent: Bool` | serial number in clear, certificate bytes, public key, CSR, private key |
| App ID and profile | `appIDRef`, `profileRef` tokens; `bundleMatches`, `teamMatches`, `certMatches`, `deviceIncluded: Bool`; `expiresInHours` | bundle seed or App ID prefix, profile bytes, profile UUID in clear, entitlement values |
| Anisette | `providerHost` (the single G3 host); `adiStatePresent: Bool`; `headerSetValid: Bool`; `headerCount` | `adi.pb`, the client identifier, `spim`, `cpim`, `ptm`, `tk`, any `X-Apple-I-*` or `X-Mme-*` value, the device serial sent to the provider |
| Sizes | bucketed: `<1 KB`, `1–10 KB`, `10–100 KB`, `100 KB–1 MB`, `>1 MB` | exact byte counts of responses |
| iOS version | `major.minor` in the report header only | build number |

## 4. Phases and events

### 4.1 `build` and `campaign`

| Event | Fields |
|---|---|
| `build.identity` | `campaignID` (format `G5-C` plus 1–3 digits); `branchSHA8`, `bridgeLibSHA8`, `zsignSHA8`; `installID8`; `conditions` (a sorted subset of `ZAG_APPLE_BRIDGE`, `ZAG_ZSIGN_STRICT`, `ZAG_LIVE_EXPERIMENT`); `debugCompiled: false`. `true` can't be compiled, and any other value fails validation. |
| `build.configureLive` | `outcome`; `providerHost`; `serialPolicy` (`g3Fixed`, `g3PerAccount`; not the value) |
| `campaign.durability` | `registryProbe` (`present`, `absent`); `containerMarker` (`present`, `absent`); `result` (`probeWritten`, `stillProbing`, `armed`) (E5; build plan §5.2) |
| `campaign.state` | `from`, `to` (`none`, `probing`, `armed`, `spent`, `closed`, `halted`); `reason` (a stop rule, `consume` or `end`) |
| `campaign.check` | `check` (`C1`–`C8`); `result` (`pass`, `refuse`) (build plan §5.5). Never nonces, account keys or times. |
| `campaign.window` | `deviceClock` (`inside`, `before`, `after`); `authenticated` (`inside`, `before`, `after`, `notYetChecked`); `skewWithinTenMinutes: Bool`. Never the times themselves. |
| `campaign.registryWrite` | `outcome`; `readBackMatches: Bool` |
| `campaign.accountPin` | `result` (`pinnedNow`, `matches`, `mismatch`). Never the account key. |

### 4.2 `transport.preflight` and `readback.preflight`

| Event | Fields |
|---|---|
| `transport.preflight.tunnel` | `vpnInterfacePresent: Bool`; `endpointAccepted: Bool`; `latencyMs` |
| `transport.preflight.pairing` | `pairingPresent: Bool`; `pairVerify` (`ok`, `failed`, `notRun`) |
| `transport.preflight.developerMode` | `confirmedByOwner: Bool` |
| `readback.preflight` | `result` (`verified`, `mismatch`, `notVerified`, `unavailable`); `unavailableReason` (`pairing`, `tunnel`, `misagent`, `timeout`, `other`; only with `unavailable`); `installedProfileCount`; `ownProfileFound: Bool`. Build plan P3: anything other than `verified` stops the run. |

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
| `request` | `client` (`apple`, `anisette`); `host`; `pathTemplate`; `method`; `scheme`; `decision` (`allowed`, `blocked`); `blockReason` (`hostNotAllowed`, `notSecure`, `credentialsInURL`, `portInURL`, `redirect`, `disabled`) |
| `response` | `status`; `durationMs`; `sizeBucket`; `contentKind` (`plist`, `json`, `other`) |
| `tls` | `outcome`; `failure` (`untrusted`, `expired`, `hostname`, `other`) |
| `lookup` | per URL key returned by the GsService2 lookup: `key` (from the known key list, or `unlisted`), `decision`, and `host` (recorded as below). Never the URL. |

**Host and path recording:**
- **`host`:**
  - An allowed host is logged verbatim: `gsa.apple.com`, `developerservices2.apple.com`, or the G3 host.
  - A blocked host is logged verbatim only if it is a valid DNS name ending in `.apple.com`, of at most 64 characters, with no label of 16 or more hexadecimal characters. Otherwise it is logged as `nonApple` or `appleUnusual`.
- **`pathTemplate`:**
  - Chosen from a fixed table, for example `/grandslam/GsService2`, `/grandslam/GsService2/lookup`, `/auth/verify/trusteddevice`, `/auth/verify/phone`, `/auth/verify/phone/securitycode`, `/services/QH65B2/{op}.action`, `/services/v1/{resource}`, `/v3/client_info`, `/v3/get_headers`, `/v3/provisioning_session`.
  - `{op}` and `{resource}` come from fixed lists; anything else is `unlisted`.
  - Query strings and fragments are never logged.

### 4.5 `auth`: sign-in and 2FA state transitions

| Event | Fields |
|---|---|
| `signin.start` | `outcome: started`. The password is never logged, and neither is its length. |
| `srp` | `step` (`init`, `complete`); `outcome`; `failure` |
| `state` | `from`, `to` (`signedOut`, `signingIn`, `awaitingTwoFactor`, `signedIn`, `failed`) |
| `twoFactor.challenge` | `kind` (`trustedDevice`, `sms`, `unknown`); `smsNumberCount`. **Never** a phone number, masked or not. |
| `twoFactor.request` | `kind`; `outcome` |
| `twoFactor.submit` | `outcome` (`accepted`, `rejected`); `attemptsRemaining` (0…3). **Never** the code, its length or its digits. |
| `twoFactor.limit` | `reason` (`tooManyCodes`, `locked`, `rateLimited`) |
| `session.validate` | `outcome`; `expiryUnit` (`seconds`, `milliseconds`, `invalid`); `expiresInHours`. This settles G4 §9 item 1. |
| `session.store` | `outcome`; `keychainAccessible` (`afterFirstUnlockThisDeviceOnly` or another class name from the fixed list) |
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
| `preflight` | `outcome`; `certificateCount`; `zagAppIDCount`; `registeredDeviceCount`; `hasDERContent: Bool` (E4) |
| `budget` | `submissionsBefore` (0 or 1); `ledgerState`; `accountPin` (`pinnedNow`, `matches`, `mismatch`); `decision` (`allow`, `budgetSpent`, `accountMismatch`, `halted`, `ledgerWriteFailed`) (E1) |
| `key` | see below |
| `journal` | `transition` (`pendingCreated`, `submissionUnconfirmedSet`, `submissionUnconfirmedCleared`, `issuedRecorded`, `unresolved`, `pendingDiscarded`); `attempts` |
| `submit` | `outcome` (`issued`, `refused`, `unknown`); `durationMs`; `failure` |
| `verify` | `possessionMatch: Bool`; `certRef`; `expiresInDays` |
| `recovery` | `action` (`checkAgain`); `result` (`recovered`, `notIssued`, `unresolved`, `checkFailed`); `listingCount` |
| `limit` | `reason` (`certificateMustBeRevoked`); `candidateCount`. **Always followed by a stop.** |
| `swap` | `outcome`: the new identity replaced the previous one only after verification |

**The `cert.key` event (finding 4).** Revision 1 asserted `exportable: false`. That overstated what the platform guarantees. The event now records three kinds of fact separately.

What the key **is**, from the creation attributes in `ZagKeychainSigningKey.create`, logged as constants:
- `keyClass: "softwareRSA2048"`. The key is not in the Secure Enclave, which does not support RSA.
- `permanent: true`, `synchronizable: false`, `accessibility: "afterFirstUnlockThisDeviceOnly"`.
- `extractableAttributeRequested: false`, the value passed for `kSecAttrIsExtractable`.

What the **workflow does**, measured:
- `privateKeyExportCalls`: the number of calls made to Zag Store's single private-key accessor wrapper with an export intent. Expected `0`.
  - In the experiment build, every Zag code path that touches a `SecKey` private key goes through `ZagKeychainSigningKeys`. It uses the key only by reference: `SecKeyCreateSignature` for the CSR, and the Zsign strict-signing callback.
  - A source test (§10, L9) proves there is no `SecKeyCopyExternalRepresentation`, `SecItemExport` or `kSecReturnData` query on a private key in any file compiled into the experiment build.
  - The only such call in the code base, in `ZagSecuritySigningKeyFactory`, is `DEBUG`-only and absent from the experiment build (build plan §3.3).
- `keyFileWritten: Bool`: whether any file under the app's temporary and caches directories was created during signing with PKCS #1 or PKCS #8 key structure. Checked by the signing step before and after. `true` is a safety failure.

What is **not** claimed:
- That iOS enforces `kSecAttrIsExtractable` for software keys in the data-protection Keychain. Apple does not document this for iOS, and Zag Store does not rely on it.
- That the key is non-exportable. A software key held by this app could be exported by code running in this app's process. The guarantee is about the workflow, not the platform.
- This matches the G4 limitation ("software RSA keys can be exported by the app's own process"). [live test needed, optional] An export attempt on a test key on the device would settle the platform behaviour, but it is not part of the experiment.

A `submit` with `outcome: unknown`, or any interruption between `budget decision: allow` and the result, always produces `journal.unresolved` and a stop.

### 4.8 `profile` and `sign`: provisioning and signing results

| Event | Fields |
|---|---|
| `profile.fetch` | `outcome`; `profileRef`; `sizeBucket` |
| `profile.check` | `result` (`ok`, or a `ZagProvisioningProfileCheck.Problem` case name); `teamMatches`, `bundleMatches`, `certMatches`, `deviceIncluded`; `expiresInHours`; `entitlementNames` (sorted **key names** from a fixed list, for example `application-identifier`, `get-task-allow`; `unlisted` otherwise; never values) |
| `sign.start` | `componentCount`; `path` (`strictKeychain`) |
| `sign.component` | `index`; `kind` (`app`, `framework`, `extension`); `outcome` |
| `sign.verify` | `zsignVerify` (`ok`, `failed`); `keyFileWritten` (see §4.7) |
| `sign.package` | `outcome`; `sizeBucket` |

### 4.9 `install`: RPPairing installation outcomes

| Event | Fields |
|---|---|
| `start` | `transport` (`rppairing`); `network` (`wifi`, `cellularWithShortcut`, `other`) |
| `step` | `step` (`pairVerify`, `tunnel`, `rsd`, `afcUpload`, `installProxy`); `outcome`; `durationMs`; `failure` |
| `result` | `outcome` (`installed`, `refused`, `unknown`); `deviceErrorClass` (`signatureInvalid`, `profileMissing`, `profileExpired`, `deviceNotProvisioned`, `entitlementMismatch`, `other`). **Never** the device's raw message. |
| `launch` | `confirmedByOwner: Bool` |
| `verify` | `result` (`verified`, `mismatch`, `notVerified`, `unavailable`); `unavailableReason` (as in §4.2); `attempt` (1 or 2); `installedProfileCount` |

**`verified` is the only success (finding 6).**
- `unavailable` means the profiles could not be read. It maps from `ZagInstallVerification.unverifiable` and is never presented, summarised or counted as success.
- The report's verdict uses it to classify an otherwise complete run as INCOMPLETE (build plan §7.2).
- The UI wording follows the same rule: "Not verified: the installed profiles could not be read" is never shown with a success icon.

### 4.10 `preflight.account`, `inventory`, `stop`, `report`

| Event | Fields |
|---|---|
| `preflight.account` | `a1`–`a6`: Bool (owner-confirmed; build plan §5.1) |
| `inventory` | `sessionItems`, `identityItems`, `pendingItems`, `anisetteItems`, `orphanItems` (counts); `ledgerRecordsPreserved: Bool` |
| `stop` | `stopRule`; `haltSet: Bool`; `ambiguityOutstanding: Bool` |
| `report.export` | `validation` (`passed`, `blocked`); `blockedRule` (a §7 rule ID, never the matching text); `eventCount` |

## 5. Prohibited data (never recorded, in any field, event or export)

| Category | Includes |
|---|---|
| Credentials | Apple Account password (and its length); 2FA codes (and their length or digits); SMS phone numbers, including masked |
| Tokens and sessions | GrandSlam tokens, `GsIdmsToken`, `myacinfo`, session tokens, cookies, `Authorization` headers, SRP values (`A`, `B`, `M1`, `M2`, salt, iterations), PET, HB tokens |
| Account identifiers | Apple Account address (in full or masked), DSID, alternative DSID, person ID, team ID, team name, the ledger's hashed account key |
| Keys and certificates | private keys, PEM or DER blocks, CSRs, public keys, certificate bytes, serial numbers in clear, Keychain persistent references, `runKey` |
| Raw device identifiers | UDID, serial number, ECID, IMEI, device name, Wi-Fi or Bluetooth address, the device serial reported to anisette |
| Anisette provisioning data | `adi.pb`, the client or keychain identifier, `spim`, `cpim`, `ptm`, `tk`, every `X-Apple-I-*` and `X-Mme-*` header value, the `anisette-identity` contents |
| Free text from remote parties | Apple error descriptions, provider error bodies, the device's installation messages, Rust error strings (mapped to enums instead) |
| Payloads | request or response bodies, plists, profile bytes, IPA contents, URLs with query strings |
| Pairing material | pairing records, host keys, the six-digit pairing PIN, TLS-PSK values |

**If a value can't be classified, it isn't logged.**

## 6. The `failure` enum

A closed set, mapped at the boundary where each error occurs:
- `network.offline`, `network.timeout`, `network.tls`, `policy.blocked`;
- `http.4xx`, `http.5xx`, `http.429`;
- `apple.authFailed`, `apple.accountLocked`, `apple.twoFactorRejected`, `apple.twoFactorLimit`, `apple.sessionRejected`, `apple.unexpectedResponse`;
- `anisette.unavailable`, `anisette.provisioningFailed`, `anisette.invalidHeaders`;
- `portal.rateLimited`, `portal.deviceLimit`, `portal.appIDCapacity`, `portal.identifierUnavailable`, `portal.certificateLimit`, `portal.unexpectedResponse`;
- `cert.unresolved`, `cert.possessionMismatch`, `cert.budgetSpent`, `cert.ledgerWriteFailed`;
- `experiment.halted`, `experiment.accountMismatch`, `experiment.notArmed`;
- `profile.invalid`;
- `sign.failed`, `sign.verifyFailed`;
- `install.refused`, `install.unknown`, `install.transport`;
- `readback.unavailable`, `keychain.storage`, `cancelled`, `deadline`, `internal`.

Each maps from the existing Swift kinds by a total `switch`, so a new case can't compile without a mapping. The existing kinds are `ZagProvisioningFailure.Kind`, `ZagFreeAccountFailure`, `ZagAuthenticationServiceError`, `ZagAnisetteError`, `ZagPortalError`, `ZagBridgeFailure` and `ZagRPPairingFailureKind`.

## 7. Export validation: schema-aware (finding 5)

Revision 1 scanned the serialised text with patterns, including "any 6-digit number". That would reject legitimate values such as `durationMs: 123456` or `t: 654321`. Revision 2 validates **by schema first**, then applies content patterns only where free-form characters could occur.

### 7.1 Per-field validation (every field, record time and export time)

Every field in §2 and §4 has exactly one declared format. A value is accepted only if it matches:

| Format | Rule | Example fields |
|---|---|---|
| `enum(name)` | member of the named closed set | `phase`, `outcome`, `failure`, `teamKind`, `result` |
| `int(min…max)` | JSON integer within the declared range; no strings, floats or leading zeros | `seq` 1…2000, `t` 0…86,400,000, `durationMs` 0…600,000, `httpStatus` 100…599, `attemptsRemaining` 0…3, the counts 0…500, `expiresInDays` 0…400 |
| `bool` | `true` or `false` | `possessionMatch`, `keyFileWritten` |
| `sha8` | exactly 8 characters `[0-9a-f]` | `branchSHA8`, `bridgeLibSHA8`, `zsignSHA8`, `installID8` |
| `ref8` | exactly 8 characters `[0-9a-f]`, in a field named `*Ref` | `certRef`, `deviceRef` |
| `campaign` | `^G5-C[0-9]{1,3}$` | `campaignID` |
| `host` | an allowed host verbatim, or the §4.4 blocked-host rule | `host`, `providerHost` |
| `template` | a member of the path-template table | `pathTemplate` |
| `list(enum)` | at most 64 members of the named set, sorted, unique | `entitlementNames`, `conditions` |

**What this guarantees:**
- An unknown field, a field in the wrong event, a value of the wrong type, or a value out of range is **rejected**.
- Integers are legitimate wherever the schema declares an integer field with a range. No numeric pattern rule applies to them, so durations, counts and status codes never trigger a false positive.
- A 2FA code can't appear as an integer: no integer field exists that could carry one, and values outside a field's range are rejected. Six-digit values fit only `t` and `durationMs`, and those are measured by the logger itself, never copied from input.
- Strings are constrained to enums, hashes, the campaign format, hosts and templates. No free-form string field exists.

### 7.2 Content rules (export time, defence in depth)

After §7.1 passes, the exporter also checks the **only** values that contain free-form characters: `host` values that were logged verbatim because they were blocked, and every **key name**. Each must not:
- **R1** contain `@`;
- **R2** contain `-----BEGIN`;
- **R3** contain `X-Apple-` or `X-Mme-` (case-insensitive);
- **R4** contain a run of 16 or more hexadecimal characters;
- **R5** contain a run of 24 or more base64 characters;
- **R6** match a UDID shape: 40 hex, or 8 hex, a hyphen and 16 hex;
- **R7** be a key name from §5, for example `password`, `dsid`, `token`, `adi` or `udid`.

R4–R6 are **not** applied to `sha8` or `ref8` fields, which §7.1 has already constrained to exactly 8 hex characters, or to integer fields. That is where revision 1's false positives came from.

**The Markdown report** is generated only from the validated JSON by a fixed template. The exporter regenerates it and compares it byte-for-byte before writing. Nothing outside the template can enter it.

### 7.3 Outcome

- **Any** failure blocks the export entirely. The exporter writes `report.export` with `validation: blocked` and `blockedRule`: a §7.1 field path and rule name, or R1–R7. The offending value is never shown.
- A blocked export is a logger defect. It is reported and fixed in a reviewed change. The owner never edits a report by hand to make it pass.

## 8. The structured failure report (for GPT-6)

Produced by **Export Report**, as two files the owner shares together: `g5-report-<campaignID>-<installID8>.json` and `.md`.

```text
header:
  schema: "zag-g5-report/2"
  campaignID, installID8, branchSHA8, bridgeLibSHA8, zsignSHA8, ipaSHA8
  startedAtUTC: rounded down to the hour
  iOS: major.minor; device: model class (e.g. "iPhone 15 Pro Max"), no identifiers
  gates: { G1..G6: recorded yes/no as entered at build time }
  providerHost, serialPolicy, conditions, debugCompiled: false
campaign:
  durability (E5), armed, ledgerState at start and at end, accountPin result
verdict:
  class: PASS | INCOMPLETE | SAFE STOP | UNRESOLVED STOP | SAFETY FAILURE   (build plan §7.2)
  stopRule (if any), firstFailure: { seq, phase, event, failure }
  invariants: { certificateRequestsSent (must be ≤ 1), certificatesIssued,
                certificatesRevoked (must be 0), blockedRequests,
                privateKeyExportCalls (must be 0), keyFileWritten (must be false),
                exportValidation }
  verification: { preflight: verified|mismatch|notVerified|unavailable,
                  install:   verified|mismatch|notVerified|unavailable|notReached }
summary by phase:
  per phase: started/ok/failed counts, total duration, last outcome
compatibility observations:
  lookup keys and host decisions; 2FA kind offered; session expiry unit;
  teamKind and teamCount; free limits seen; hasDERContent; profile expiry hours;
  entitlement key names; install deviceErrorClass (if any)
outstanding state:
  unresolvedCertificateRequest: Bool; haltSet: Bool; inventory counts after sign-out
events:
  the full event list (§2), in order
owner notes:
  fixed choices only (e.g. "trusted-device prompt looked expected: yes/no"); no free text
```

**Verdict rules:**
- `verification.install` must be `verified` for `PASS`.
- `unavailable` there, with everything else passing, yields `INCOMPLETE`. It is never `PASS`.

## 9. Retention and handling

- On the device: until `clear`, app deletion or rollback (build plan §8.1). The campaign ledger is retained separately.
- Shared only by the owner, to GPT-6 and Claude, as a sanitised Markdown file under `docs/free-developer-accounts/` after a final manual read, or as an issue attachment.
- **The pre-push guard stays in force:** it refuses the real device UDID.

## 10. Tests the implementation must ship with (before the experiment build)

| # | Test |
|---|---|
| L1 | **Schema round-trip.** Every event type round-trips. An unknown field, a wrong type, or an out-of-range integer is rejected at record time and produces `logger.rejected`. |
| L2 | **Leak corpus.** A scripted mock run (bridge `mock` backend; test-only, never in app builds) plants synthetic secrets in every input: a password, a 6-digit 2FA code, a fake DSID, a fake UDID in both formats, a fake serial, fake `adi.pb` and identifier, PEM, `X-Apple-I-MD` values, emails, phone numbers, a fake team ID. The exported report contains none of them. It is run once with the §7.2 content rules disabled, to prove §7.1 alone suffices. |
| L3 | **False-positive corpus (finding 5).** A valid report with boundary integers passes validation unchanged: `durationMs` 0, 123456 and 600000; `t` 999999; `httpStatus` 100 and 599; counts 0 and 500; `sha8` and `ref8` values of all digits (`12345678`) and all letters (`abcdef01`); and the longest allowed blocked `.apple.com` host. |
| L4 | **Rule coverage.** Each §7.1 format, and each of R1–R7, blocks a crafted report. The `blockedRule` names the rule, and the output contains no offending value. |
| L5 | **Mapping totality.** A compile-time `switch` over every failure kind. |
| L6 | **Ref tokens.** The same value gives the same token within an installation and different tokens across installations. `runKey` never appears in an export. |
| L7 | **Absence from production.** The clean production build (build plan §4.2) contains none of the logger's markers (`zag-g5-report/2`, the event names). |
| L8 | **Verification classes.** Scripted read-back results `verified`, `mismatch`, `notVerified` and `unavailable` produce distinct events and verdicts. `unavailable` on otherwise passing runs yields `INCOMPLETE`, never `PASS`. P3 `unavailable` stops the run before any live operation. |
| L9 | **Key handling.** A source scan of every file compiled into the experiment build finds no private-key export API: `SecKeyCopyExternalRepresentation` on a private key, `SecItemExport`, or a `kSecReturnData` query for `kSecClassKey`. `privateKeyExportCalls` is 0 after a full mock run. A mutant that exports the key raises the counter and fails the suite. |
| L10 | **Budget events.** The build plan's T1–T16 each emit the expected `cert.budget` and `campaign.state` events. |
| L11 | **Campaign checks.** Each of C1–C8 refusing emits `campaign.check result: refuse`, followed by the expected `campaign.state` transition. The exported report contains no nonce, account key or timestamp other than the header's rounded start hour. |

## 11. Revision 2: corrections for GPT-6's review of `5839add7`

| # | Finding | Correction |
|---|---|---|
| 4 | `exportable: false` was inaccurate | §4.7 now separates three things. **Requested:** `kSecAttrIsExtractable: false`; a software RSA key; this device only. **Measured:** `privateKeyExportCalls`, expected 0, backed by a source scan (L9), plus `keyFileWritten`. **Not claimed:** that iOS enforces non-extractability, or that the key is non-exportable. The process could export it; the workflow does not. |
| 5 | Leak scanner false positives | §7 validates every field against a declared type and range first, so legitimate integers are never pattern-scanned. Content rules R1–R7 then apply only to the remaining free-form values: verbatim blocked hosts and key names. A false-positive corpus test (L3) is added. Prohibited data is still rejected (L2, L4). |
| 6 | Read-back | `readback.preflight` added (build plan P3). The verify result now distinguishes `verified`, `mismatch`, `notVerified` and `unavailable`, with a reason. `unavailable` is never success. The report has separate preflight and install verification fields, and the INCOMPLETE verdict (L8). |
| 1, 2, 7 | Budget, halt and their tests | `campaign.*` events, the `cert.budget` fields and L10 record the campaign-bound ledger of build plan §5.2 and §5.4. |
