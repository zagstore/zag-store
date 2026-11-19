# G4: security review package for the Apple Account bridge

Status 19 November 2026 (revised the same day for review readiness; remediation for issue #33 in section 12; closeout of the re-review's four issues in section 13): **implementation ready for an independent security review. Not reviewed. No live Apple service has been contacted.** The author of the bridge has not reviewed it independently. G4 stays open until a reviewer independent of the implementation records the decision in section 10.

## 1. What is under review

| Component | Path | Built into |
|---|---|---|
| Bridge (Rust, C interface) | `AppleAuthCore/zag-apple-bridge` | Nothing yet. Only the test suite links it (`mock`). |
| Swift side | `Feather/Utilities/FreeAccount/ZagIsideloadBridge.swift` | Compiled only with `ZAG_APPLE_BRIDGE`, which no Xcode configuration sets |
| Per-account service hook | `ZagAccountDirectory.Configuration.makeService` | All builds (nil by default: no change) |
| Protocol library | `AppleAuthCore/zag-isideload` (PR #26) | Hardening already listed in its `PROVENANCE.md` |
| Keychain-backed signing | PR #28 (`ZagKeychainSigningKeyFactory`, `signWithKeychainKey`) | Compiled only with `ZAG_ZSIGN_STRICT` |

**Data flow:**
1. The sign-in screen passes the password to `ZagFreeAccountAuthenticator`.
2. The authenticator calls `ZagIsideloadAuthenticationService`, one per account.
3. That service calls the C interface, which hands the request to a bridge slot.
4. The slot drives the bridge backend, which calls `zag-isideload`.
5. `zag-isideload` contacts Apple and the anisette server.

Results flow back as JSON events: `codeRequired`, `signedIn`, `result` or `failed`.

## 2. Network destinations

| Build | Destinations |
|---|---|
| Any Xcode configuration (Debug, Release) | **None.** The bridge is neither compiled nor linked; the test suite checks the project file. |
| Bridge default build | **None.** Every call fails with `disabled` before a backend exists, and the fork's `net_policy` refuses all traffic without `live-network`. |
| Bridge `mock` | None: the scripted backend has no network code. |
| Bridge `live` (the experiment build only) | `gsa.apple.com` and `developerservices2.apple.com` (sign-in and developer services), plus exactly one anisette host: the https URL passed to `configureLive`. |

**How the `live` build enforces this** (fork `net_policy.rs`):
- every request and socket is checked;
- https or wss only, on the default port;
- no credentials in URLs;
- no redirects;
- no proxy or relay.

**Swift `configureLive` refuses unless all of these hold:**
- `ZagLiveAuthentication.isEnabled`, `ZagLivePortal.isEnabled` and `ZagAnisetteLive.isEnabled` are all true. Each is `static let … = false`, and the suite checks that.
- The linked library reports `live`.
- The URL is https.

**Anisette step:** `ZagBridgeAnisetteSource` refuses unless live anisette is enabled.

**Ruled out:**
- no default anisette server;
- no URL can be changed after configuration;
- configuration happens once per process.

## 3. Credential lifecycle

| Secret | Where it exists | How long | Wiped / protected |
|---|---|---|---|
| Apple Account password | Swift `ZagEphemeralSecret`, then copied into a Rust `Zeroizing<String>`; the fork borrows it as `&str` | One sign-in, including the wait for a code | Swift wipes it when the operation ends. Rust's copy is zeroised when the sign-in future ends or is cancelled. The fork's derived buffers are zeroised (`PROVENANCE.md`). **Never stored.** |
| Verification code | Swift `String`, then Rust `Zeroizing<String>`, then the fork | One answer | Rust's copy is zeroised. **Residual:** the fork passes the code by value into an HTTP header, which cannot be wiped. |
| Session (credential) | A token Swift stores in the this-device-only Keychain (`ZagFreeAccountSecretKind.session`). The bridge's token is opaque base64 of `{adsid, developer-services token, duration, expiry}`. | Until it expires, the user signs out, or the account is removed | The bridge zeroises its event buffers after delivery, and its copy of the credential when the cached session is dropped. Swift zeroes the JSON it sends. **Residual:** Swift `String` copies of the token cannot be wiped. |
| Anisette device state | The Keychain (`ZagStore.anisette.bridge`), `AfterFirstUnlockThisDeviceOnly`, never synchronised; each item is named `<account's anisette scope>/<key>` | Until the account is removed (its scope is in the account's ownership record), or until the user removes it as orphaned (Stored Account Data) | **One device state per Apple Account** (owner decision, 19 Nov). Opaque to Zag Store. |
| Signing key | A Keychain key item per account and team (PR #28), `AfterFirstUnlockThisDeviceOnly`, not synchronised | Until the account is removed (its key items are deleted then), or replaced when a new certificate is needed | Zag Store never exports it: it is used only through `SecKeyCreateSignature`. **Not hardware-enforced:** iOS does not enforce `kSecAttrIsExtractable: false` for software RSA keys, and the Secure Enclave cannot hold RSA-2048. Code in the app's process could export it. The exporting test factory is `DEBUG`-only, and the release scan checks it is absent. |

**Not kept anywhere:**
- the password;
- codes;
- the Apple Account address, beyond the masked display form Zag Store already stores;
- tokens in preferences, files or diagnostics.

**Test coverage.** The Swift suite checks that no password or code is in the secret store, and that diagnostics contain no password, code, token or unmasked address.

## 4. Session isolation

- **One slot per account.** `makeService` gives every authenticator its own `ZagIsideloadAuthenticationService` and slot. Every `ZagIsideloadDeveloperPortal` has its own slot too.
- **Binding.** A slot is bound to the Apple Account that signed in through it, or that first used it.
  - The bridge refuses a portal call with another account's credential (`invalidInput`).
  - Signing in a different account through a slot rebinds it and drops the cached portal session.
- **Cached session.** A portal session is reused only for the identical token. An expired session is dropped and reported as `sessionExpired`.
- **Teams.** Portal operations name the team. Signing authorisations are scoped by account and team (`ZagSigningScope`), as before.
- **One sign-in at a time per slot.** A second one gets `busy`.
- **Anisette state, per account (owner decision, 19 Nov).**
  - `zag_bridge_sign_in` takes a required anisette scope. Swift derives it as `"a"` plus 32 hex digits of SHA-256 of the address entered (trimmed, lower-cased), so it is never the address.
  - Every key the anisette provider stores is prefixed with that scope, so no account reads or writes another's device state.
  - The scope is kept inside the session token, so portal sessions reopen with the device state their sign-in used.
  - A missing or malformed scope is refused. There is no shared default.
- **Removal (20 Nov).**
  - At sign-in, the account directory (#28) records the account's anisette scope in its ownership record (`localStateScopes`).
  - `ZagBridgeAnisetteLocalState` makes the anisette Keychain the directory's `ZagAccountLocalState`.
  - Removing an account deletes, in order: its key items, the items of each recorded scope, then its secrets.
  - If the anisette items cannot be deleted, removal fails with `localStateNotRemoved` and the account stays, record included. Removing it again finishes.
  - Scopes with items that no account's record names (an earlier installation, an interrupted removal) are listed in Stored Account Data and removed only on confirmation.
  - Scopes are validated before anything is deleted.
- **Privacy: per-account state does not make accounts unlinkable.**
  - Per-account state stops one account's anisette state being read, overwritten or deleted by another. It does **not** make the accounts unlinkable, and Zag Store does not claim it does.
  - Accounts used from the same device can still be correlated by:
    - **the device serial:** one value is configured for all accounts. If it is unique to this device, the provider and possibly Apple can link every account that uses it;
    - **the IP address:** the same for every account at any moment, seen by Apple and by the anisette provider;
    - **any persistent pseudonymous identifier** the provider or Apple's protocol keeps or derives (for example a provider-side device or client identifier, or timing and usage patterns), whether or not it is visible to Zag Store;
    - **the anisette provider itself:** one provider sees requests for every account.
  - Choosing the provider and the serial (shared, common or per account) is left to **G3**. Nothing in #28 or #29 decides it.
- **Stop condition (owner, 19 Nov).** If the chosen provider requires one device identity shared by all accounts, this is a privacy trade-off. It comes back to the owner before the experiment.

**Tests (Swift):**
- two accounts in one directory;
- the second account does not see the first account's device;
- a portal bound to one account refuses the other account's session;
- each account signs in with its own anisette scope (the scripted backend refuses another's); the scope is a hash, the same for the same address in any case;
- the scope is recorded at sign-in; removing the account deletes exactly its anisette items; orphaned state is listed and removed only on confirmation; invalid scopes are refused (5 checks, on a test-only Keychain service).

**Tests (#28, a fake local state):** a failing anisette removal is reported, the account and record stay, and a repeated removal finishes; another account's state is never removed.

**Tests (Rust):** the same checks, plus rebinding.
- A sign-in without a scope, with a malformed one, or with another account's is refused.
- Two accounts sign in at once with their own scopes.
- Unit test, live build: two scopes never see, overwrite or delete each other's keys, and every stored key carries its scope.

## 5. Logging and diagnostics

- **The bridge logs nothing.** It has no logging dependency of its own, and the fork's `quiet.rs` macros never evaluate their arguments.
- **Failures cross the C interface only as a `FailureKind`:** `disabled`, `notConfigured`, `network`, `rejected`, `twoFactorRejected`, `refused`, `rateLimited`, `sessionExpired`, `malformed`, `cancelled`, `busy`, `invalidInput`, `notSignedIn`, `unsupported`.
  - Text from Apple or from the library is dropped unread (`live.rs`, `classify`).
  - The kind is chosen from the error type alone: the fork's policy refusal, an HTTP status of 401 or 429, a transport error, or the fork's own error type.
- **Swift diagnostics** go through `ZagSensitiveRedactor` as before. The bridge adds no diagnostics entries.
- **Descriptions.** `ZagSessionCredential` and `ZagEphemeralSecret` describe themselves without their contents.

## 6. TLS

All three clients in the live build verify TLS. The fork has no switch to turn that off; upstream's `danger_debug` was removed.

| Client | Verification | Root store |
|---|---|---|
| Apple (`gsa`, `developerservices2`) | rustls with `rustls-platform-verifier` | iOS system trust store, plus Apple's root |
| Anisette HTTP | rustls with `rustls-platform-verifier` | iOS system trust store |
| Anisette websocket | rustls | bundled `webpki-roots` |

- **Crypto provider:** the bridge installs `ring` once, in `IsideloadBackend::new`.
- **Not done:** certificate pinning. Pinning would break whenever Apple rotates certificates; the reviewer should decide whether it is wanted for the anisette host.

## 7. Failure handling

- **Every operation ends with exactly one terminal event**, including when it is cancelled, its slot is closed, its input is malformed, or the operation panics (checked in Rust). Swift does not rely on it for memory safety: the callback context is a registry token, and messages for an operation that has ended are ignored (section 12).
- **Cancellation.** Swift task cancellation and the authenticator's `cancel()` call `zag_bridge_cancel`, which drops the running future, including any request in flight. Swift runs one operation per slot, and cancels only the operation that is still running, so a late cancellation never reaches a newer one (section 12). An operation that completed before the cancellation took effect keeps its outcome.
  - The authenticator's deadline (`operationTimeout`) cancels the same way. Checked: a sign-in that does not answer is stopped in under 3 s with a 0.3 s deadline.
  - A sign-in abandoned at the code prompt is cancelled when the next one starts.
- **Verification codes:**
  - a wrong code keeps the sign-in waiting, as a retry;
  - the authenticator allows 3 attempts;
  - if the backend ends the sign-in, a later code does not sign in;
  - codes that are not digits are refused before they reach Rust and again in Rust.
- **Expired sessions** are reported as invalid (`isValid` returns false), never as success. The portal's error for them is `sessionRejected`.
- **Network failures** become `network` in both services.
- **Retries.** None are automatic; the user retries.
- **Portal refusals** (limits, identifiers in use) become `refused`, which Swift maps to `malformedResponse`. Which refusal it was is deliberately not inferred from Apple's messages. The provisioner enforces the free limits itself before calling.
- **Input bounds:**
  - every buffer crossing the C interface is null-checked and capped at 64 KiB;
  - codes are capped at 16 bytes;
  - JSON requests are parsed into a closed set of operations.

## 8. Feature gates

| Gate | State | Checked by |
|---|---|---|
| `ZAG_APPLE_BRIDGE` (Swift compile flag) | Not set in any Xcode configuration | `test-zag-apple-bridge.sh` (project file) |
| Bridge library linked into the app | No | same |
| Bridge `live` feature, and so `zag-isideload/live-network` | Off by default | Rust tests (default build: `disabled`) |
| `ZagLiveAuthentication`, `ZagLivePortal`, `ZagAnisetteLive` `.isEnabled` | `false` | `test-zag-apple-bridge.sh` |
| Free-account signing gate | Closed (`.production`) | `test-zag-free-account-release-binary.sh` |
| Keychain signing (`ZAG_ZSIGN_STRICT`) | Not set in any configuration | Release scan (PR #28) |
| Release binary markers | Bridge types, `zag_bridge_open_slot` and the anisette Keychain service must be absent | `test-zag-free-account-release-binary.sh` |
| `mock` backend | A test feature only; `configureMock` exists only in `DEBUG` Swift | Rust tests, default build |

## 9. Unresolved live assumptions: each fails closed

None of these can be settled without Apple's services. Each is marked `EXPERIMENT` in the code. Each has been checked to **refuse** when the assumption is wrong, never to proceed on a guessed value.

| # | Assumption | What happens if it is wrong | Check |
|---|---|---|---|
| 1 | **Unit of the token's expiry** (seconds or milliseconds) | `expiry_seconds` accepts a value only if **exactly one** reading falls between 1 minute and 400 days from now. It refuses past values, durations, values that both readings or neither reading would accept, 0 and the maximum, ending the sign-in as `malformed`. Swift's `validated(now:)` applies the same bounds again. | Rust unit test `expiry_unit_is_never_guessed` (live build) |
| 2 | **Which team is the Personal Team** | The bridge reports every team as `unknown`. With **one** team, Zag Store applies the free limits, the strictest. With **several** teams and none identified, sign-in stops (`unexpectedResponse`) instead of choosing one, because signing on an organisation's team would have side effects there. | Swift: "fail closed: with several teams…", "…a single unidentified team gets the free limits" |
| 3 | **Finding a newly issued certificate by its request's identifier** | Not found: `malformed`, and nothing is stored. Found but wrong: the provisioner's proof-of-possession check (the certificate's public key must verify a signature made by this account and team's Keychain key) fails, so nothing is stored. A listing with any certificate lacking a serial or expiry now fails as a whole: dropping it would hide a certificate from the certificate plan and could waste the quota. | `ZagKeychainSigningKeyFactory.check`; PR #28 strict integration (wrong certificate refused); `live.rs` certificates listing |
| 4 | **Certificate request format** (PEM, as upstream) | Apple refuses the request (`refused`), and nothing is created locally beyond the key, which is replaced on the next attempt. A certificate issued for anything else fails the possession check (3). | As in 3 |
| 5 | **Anisette device serial** | **Changed:** there is no default any more (it was `"0"`). `configureLive(anisetteURL:deviceSerial:)` must be given a serial: 1–32 letters or digits, decided with the G3 provider. Missing or malformed: configuration is refused. | Rust live gate test (missing, empty and malformed serials refused); `valid_serial` unit test |
| 6 | **Certificate content in the listing** (`cert_content` of `listAllDevelopmentCerts`) | The bridge passes it when present. Without it, a certificate whose issue response was lost cannot be recognised by key, so provisioning stops with `certificateRequestUnresolved` and requests nothing more, until the user abandons the request. Nothing is revoked. | 7 strict integration "recovery" checks (#28); bridge listing check; Rust live build |
| 7 | **Whether every alias of an Apple Account returns the same `adsid`** | Not assumed. A known account reached through an unrecorded address is refused (`addressNotRecognised`); nothing is merged or stored. | Accounts checks "aliases" (#28) |

**Fixed values that also fail closed:**
- **Verification codes are 6 digits.** A code of another length is refused locally (`ZagTwoFactorPrompt.normalisedCode`), so a different length stops the sign-in.
- **HTTP 401 means `sessionExpired`.** The user is asked to sign in again; nothing proceeds.
- **App IDs without an expiry count as active.** For the free App ID limit, that is the conservative reading.

## 10. Questions and decision record (for the independent reviewer)

**Questions:**
1. Are the residuals acceptable for a supervised experiment with a dedicated account? The residuals are:
   - unwipeable Swift `String` copies of the token and the code;
   - the code in an HTTP header;
   - the token in ordinary heap memory inside the fork while a session object exists.
2. Should the anisette host be pinned?
3. *(Decided by the owner, 19 Nov: per-account anisette state, implemented.)* Is the remaining shared configuration acceptable? That is the one device serial and the one provider (section 4). Per-account state does not give unlinkability: the serial, the IP address and any persistent pseudonymous identifier can correlate accounts. The provider and serial are G3 decisions.
4. Is the binding rule (first use binds a restored slot) sufficient? Should a portal also check the credential against the directory's account record?
5. Anything in sections 2–8 to change before the experiment build is made?

| Field | Entry |
|---|---|
| Reviewer (independent of the implementation) | |
| Date | |
| Commits reviewed (bridge PR head, PR #26 head, PR #28 head) | |
| Checklist (section 11) completed | |
| Findings and required changes | |
| G4 complete | **No** |

## 11. Reviewer checklist

Tick each item, or record a finding. File references are to the bridge PR (#29) unless marked.

### A. Swift/Rust boundary (FFI)
- [ ] `src/ffi.rs`: every pointer is null-checked; lengths are capped (64 KiB; codes 16 bytes); UTF-8 is validated; no pointer is kept after a call returns.
- [ ] `ZagBridgeStorage` callbacks: `retrieve` buffers are freed by `release` (zeroed first); keys are NUL-terminated; failures return non-zero.
- [ ] The callback `context` is a token in `ZagBridgeOperations`, not an object pointer. An operation is registered once and removed once: by the bridge's terminal event, decided by the event *name* and not by whether Swift could parse it, or when its slot closes. Repeated, late, stray and `NULL` callbacks are ignored (section 12).
- [ ] Each started operation delivers exactly one terminal event: on success, failure, cancellation, slot closure, malformed input and panic (`slot.rs`; Rust tests).
- [ ] Events are delivered on a bridge thread. `ZagBridgeEvents`, `ZagBridgeSlot` and `ZagBridgeOperations` are lock-protected. No lock is held while a continuation is resumed, and no Swift actor is entered from that thread.
- [ ] A message Swift cannot read while the bridge carries on is passed to the reader as `malformed`, and the operation is cancelled; the slot stays busy until the bridge's own terminal event.
- [ ] The C header matches the exports (`test-zag-apple-bridge.sh`).

### B. Account isolation
- [ ] One slot per authenticator (`Configuration.makeService`) and per portal instance.
- [ ] A bound slot refuses another account's credential. Rebinding drops the cached session (`slot.rs` `finish_sign_in`, `portal`).
- [ ] Portal operations stay within the account's teams. Signing needs `ZagSigningAuthorization` for exactly one account and team (#28).
- [ ] Anisette state is per account: the scope is required, prefixed to every storage key, and carried in the token (`live.rs` `KeychainStorage`, `StoredToken`). The remaining shared configuration is in question 3.
- [ ] No document or UI claims that per-account anisette state makes accounts unlinkable (section 4, "Privacy").
- [ ] Removing an account removes its anisette items (`ZagBridgeAnisetteLocalState`, `ZagAccountDirectory.remove`); a failure leaves the account removable again; orphaned scopes are listed and removed only on confirmation.
- [ ] Aliases (#28): a known account reached through an address not recorded for it is refused (`addressNotRecognised`); nothing is merged or stored. Apple's `adsid` is SRP-authenticated, but whether aliases share it is not established.

### C. Keychain accessibility and key exportability (#28)
- [ ] Every item is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and not synchronised: sessions and identities (`ZagKeychainFreeAccountSecretStore`), signing keys (`ZagKeychainSigningKeys`) and anisette state (`ZagBridgeAnisetteKeychain`).
- [ ] Writes are add-or-update in place, so a failed write leaves the previous value: the secret store and, since section 12, the anisette store. A Keychain lookup that returns anything but a key reference is refused, not force-cast.
- [ ] Items live in the app's default access group only. There are no `keychain-access-groups`, App Groups or app extensions (`Feather.entitlements`, project).
- [ ] No release code path exports a private key. `ZagSecuritySigningKeyFactory` is `DEBUG`-only, and the release scan checks it. The only remaining `SecKeyCopyExternalRepresentation` calls are on public keys.
- [ ] The limitation is accepted: software RSA keys are exportable by the app's own process (section 3).
- [ ] Lifecycle (`SIGNING-KEY-SECURITY.md` in #28, "Signing-key lifecycle review"): switching, sign-out, removal, missing key, restore.
- [ ] L2, transactional identity creation (#28): a new key in its own slot; one identity write publishes it, only after proof of possession; the journal and bounded retries; abandoned keys removed; no Keychain retagging.
- [ ] L1, reinstall (#28): the ownership record is written before anything else; recovery only after a sign-in Apple accepted for the same account; ambiguous records unused; cleanup lists, then removes only confirmed accounts still orphaned; nothing deleted at launch; enumeration only of Zag Store's own service and key labels.
- [ ] Cleanup revalidation (#28): each item is checked again immediately before deletion (still orphaned, ownership unchanged since confirmation); removed, skipped and failed are reported separately. The Debug page Settings → Apple Accounts → Stored Account Data asks for confirmation and never runs by itself.
- [ ] Certificate request recovery (#28): the journal is marked unconfirmed before sending; a lost response is resolved only by proof of possession against listed certificate data; otherwise `certificateRequestUnresolved` stops further requests until the user abandons the request; nothing is ever revoked (the portal interface has no revoke operation). The bridge passes listed certificate content (`live.rs` `Certificates`); whether Apple includes it is not established.

### D. Two-factor handling
- [ ] Codes are digits only, checked in Swift and again in Rust. Retries are limited to 3 (the authenticator). A code after the backend ends the sign-in does not sign in.
- [ ] SMS shows at most the last two digits of the number.
- [ ] Residual: the fork puts the code in an HTTP header as an ordinary string.

### E. Cancellation
- [ ] Task cancellation, `cancel()`, the deadline and slot closure all reach `zag_bridge_cancel` and drop the running future, including an in-flight request.
- [ ] A sign-in abandoned at the code prompt is cancelled by the next sign-in.
- [ ] Cancellation is per operation in Swift (`ZagBridgeSlot.cancel(_:)`): it reaches the bridge only while that operation is still the one running in its slot. Overlapping operations in a slot are refused as `busy` in Swift and again in Rust (#34).
- [ ] The authenticator refuses calls that arrive while another call waits for an event (actor reentrancy).
- [ ] A cancellation that races a completed certificate request reports the request's real outcome; a cancelled request whose outcome is unknown stays unconfirmed (section 12).
- [ ] A cancelled operation whose terminal event does not arrive within the slot's grace period (5 s) is abandoned by Swift: readers get `cancelled` once, the slot is freed, late events are ignored. `zag_bridge_cancel` is called without the slot lock held; no operation starts in the slot during that call (section 13).
- [ ] An operation cancelled while it waits for its account and team's turn in the provisioner leaves at once, runs nothing and leaves no waiter (section 13).

### F. Credential lifetime
- [ ] The password is never stored; Rust's copy is zeroised on every path, including cancellation.
- [ ] The session token is stored only in the Keychain. Bridge buffers are zeroised after delivery. Residuals: Swift `String` copies, and the fork's heap memory.
- [ ] Session expiry is bounded (1 minute to 400 days) and the unit is not guessed (section 9, item 1).

### G. TLS validation and destinations
- [ ] No switch disables certificate verification (fork `PROVENANCE.md`; source check in `test-zag-isideload-fork.sh`).
- [ ] The allowlist is Apple's two hosts plus the one configured anisette host; https or wss only; no redirects, proxies or ports.
- [ ] The root store for each client is as in section 6. Question 2 below asks whether to pin.

### H. Error propagation
- [ ] Only `FailureKind` values cross the boundary; no upstream text (`classify`).
- [ ] The Swift mappings are as in sections 7 and 9. No error is mapped to success. `isValid` returns `false` only for `sessionExpired`.
- [ ] Unknown events and JSON are refused as `malformed`.

### I. Gates
- [ ] Section 8 holds on the commits reviewed. Run `scripts/test-zag-apple-bridge.sh`, `scripts/test-zag-free-account-release-binary.sh` on a Release build, and `scripts/test-zag-isideload-fork.sh`.

### J. Recovery screens and Release gating (#28, owner decisions 20 Nov)
- [ ] Check Again (`checkUnresolvedCertificateRequest`) only reads the certificate listing: it never submits a request or revokes, acts only if the journal is unchanged after the listing returns, and changes nothing on cancellation, sign-out or network failure.
- [ ] Provisioning, Check Again, Abandon and the unresolved-request query of one account and team run one at a time in the provisioner (`exclusively`). A request that is still out is never settled from another operation's listing, sent again, abandoned or shown as unresolved (section 12).
- [ ] Abandon (`abandonUnresolvedCertificateRequest`) needs confirmation in the UI, warns that an issued certificate may still occupy a slot, removes only the pending key and journal, and works signed out (local only).
- [ ] An unresolved request is never retried in the background (`ZagFreeAccountLifecycle.reason` maps it to `signingFailed`), and signing stops as unresolved until it is settled.
- [ ] Every outcome is reported to the user (`ZagCertificateRecoveryModel.message`): recovered, not issued, still unresolved, abandoned, nothing pending, could not check.
- [ ] Stored Account Data and Certificate Request are Release code; Settings reaches them only `if ZagAppleAccountsFeature.isEnabled` (`false`). The Release scan checks the gate, the files and the entry placement.
- [ ] Removal of signed-out and expired accounts is local and complete (keys, anisette state, secrets); registered accounts are never listed as orphaned.

### Commit set for this review (20 Nov)
- PR #26 (fork) `4b1a6984`: unchanged since G2 was prepared.
- PR #28 `64de6694`: branched from `main` `bcf30a9f`. `main` is now `e077cf04`, which adds only #30's documentation, and #28 merges into it without conflicts.
- PR #29: the head named in its description. It contains #28 `64de6694` through merge commits only, plus the bridge commits.
- Merge order if approved: #26, then #28, then #29. Nothing is merged before the independent G2 and G4 reviews.

## 12. Remediation for issue #33 (for re-review)

These are review findings and test gaps, not confirmed exploits. Nothing here was run against Apple or an anisette server.

**Branches:**
- #34 (`review/g4-anisette-url-validation`, `280d50e8`) is the base. It covers issue items 1 and 2: the full anisette URL policy at configuration time, and slot-level exclusivity in Rust.
- This remediation is stacked on #34. The frozen heads #26, #28 and #29 are unchanged.

### 12.1 Swift/Rust callback ownership (`ZagIsideloadBridge.swift`)

**Before:**
- The context was `Unmanaged.passRetained(events)`. It was released on the first event that *Swift parsed* as terminal.
- Anything Swift could not parse became `failed(.malformed)` and counted as terminal.

**Confirmed defects:**

| # | Defect | Trigger | Effect before |
|---|---|---|---|
| 1 | Early release | A message Swift cannot read while the bridge continues, e.g. `codeRequired` with `codeLength` outside 4–8 | Context released; the bridge's real terminal event then used freed memory |
| 2 | Double release | A repeated terminal event | Use after free and an over-release |
| 3 | Lost reader | Two overlapping `next()` calls (actor reentrancy) | The first continuation was overwritten and never resumed |
| 4 | Cancellation reaching another operation | Rust frees the slot before Swift receives the terminal event; a late cancel handler called the slot-wide `zag_bridge_cancel` | Could stop a newer operation in the same slot |
| 5 | No reclamation | No terminal event ever arrives | The retained context leaked |

Rust delivers exactly one terminal event per started operation, so defects 2 and 5 need a faulty bridge. The Swift side no longer depends on that for memory safety.

**After:**
- **The context is a token.** `ZagBridgeOperations` maps a number to the operation.
  - The bridge's terminal event (`signedIn`, `result` or `failed` by name) removes the operation. So does the slot closing first.
  - Repeated, late, stray, unknown-token and `NULL` callbacks find nothing and are ignored.
- **Unusable messages.** A message Swift cannot use while the bridge continues reaches the reader as `malformed`, and Swift cancels the operation. The slot stays busy until the bridge's own terminal event.
- **One operation per slot in Swift**, until its terminal event reaches Swift. `cancel(_:)` calls `zag_bridge_cancel` only while that operation is still the running one.
- **Readers.** Several readers are served in turn, and none is left waiting.
- **The authenticator** refuses `signIn`, `requestCode` and `submitCode` while another call is waiting (actor reentrancy).
- **Message copies** of each callback are wiped after parsing.

### 12.2 Keychain, account isolation, key deletion and credentials

**Reviewed:**
- `ZagKeychainSigningKeys`:
  - RSA-2048, permanent, `AfterFirstUnlockThisDeviceOnly`, not synchronised.
  - The tag is `<namespace>.signing-key.<account UUID>.<team>[.<slot>]`, with team and slot alphanumeric. The label is per account.
  - Deletion is by tag, or by label for the whole account, repeated until none is left. Other accounts and teams are untouched (Keychain harness and strict tests).
- `ZagKeychainFreeAccountSecretStore`: add-or-update, per-item protection class, deletion scoped by account prefix.
- `ZagBridgeAnisetteKeychain` and `ZagBridgeAnisetteLocalState`.
- Entitlements: no shared access groups or extensions.
- Credential buffers: the password goes from `ZagEphemeralSecret` to a Rust `Zeroizing` copy. The token is wiped from the credential JSON. The C buffers are wiped after delivery.

**Fixed:**
- **The anisette store** was delete-then-add, so a failed add lost the account's anisette state (a new anisette device at the next sign-in). It is now add, or update in place.
- **`ZagKeychainSigningKeys.key(tag:)`** force-cast the Keychain result. A non-key result is now refused.
- **2FA code bytes** passed to `zag_bridge_answer` are wiped. The bridge keeps its own zeroising copy.

**Unchanged and accepted residuals:** listed under 12.6.

### 12.3 Certificate issuance recovery and duplicate prevention (`ZagFreeAccountProvisioner`)

**Confirmed defect: a duplicate request because of actor reentrancy.**
- Two signings of one team at once:
  1. The first writes its request as unconfirmed, then awaits the submission.
  2. The second re-enters and settles that in-flight request from its own listing as "not issued".
  3. With a listing that includes certificate content, the second then sends the same request again: two certificates for one key, and two of the team's slots.
- Check Again racing a retry did the same.
- Abandon could remove the key of a request that was still out.
- **Reproduced** before the fix: the overlap check failed with "sent 2", and the Check Again race failed with "got notIssued".

**Fix:**
- Provisioning, Check Again, Abandon and the unresolved-request query of one account and team run one at a time (`exclusively`). Other scopes are unaffected.
- `abandonUnresolvedCertificateRequest` and `unresolvedCertificateRequest` became `async`. All callers already awaited them.

**Already correct, now covered by tests:**
- A cancellation, timeout, dropped connection or unreadable response after the request was sent leaves it unconfirmed, never "not issued".
- With no certificate content in the listing, signing stops as unresolved and sends nothing, however often it is retried.
- With content, the issued certificate is recovered with no new request.
- Only an explicit refusal (rate limit, session rejected, certificate limit) marks a request "not issued".

### 12.4 Revocation stays impossible through the bridge
- `PortalRequest` has no revocation operation, and `live.rs` never calls the fork's `revoke_development_cert`.
- Rust test `portal_requests_cannot_revoke_a_certificate`: `revokeCertificate`, `revokeDevelopmentCert`, `revoke_development_cert` and `RevokeCertificate` do not deserialise.
- Swift check: a `revokeCertificate` portal request is refused as `invalidInput`.

### 12.5 Evidence

**New tests:**

| Suite | Before | After | New coverage |
|---|---|---|---|
| `test-zag-apple-bridge.sh` (Swift) | 62 | 94 | Ownership: repeated, malformed, stray, `NULL`, unknown-token and missing terminal events through the real C callback. Concurrent readers. Stale-cancel targeting against the mock backend. 40 cancel-versus-complete races. Authenticator reentrancy. Closing at the 2FA prompt. Revocation refused. Anisette in-place update. |
| `test-zag-apple-bridge.sh` (Rust) | default 3, mock 13, live 6 | default 4, mock 14, live 7 | Revocation cannot be deserialised |
| `test-zag-zsign-branch.sh` (strict integration) | 44 | 64 | Overlapping signings, cancellation after issuance, four ambiguous responses, Check Again and Abandon racing a request in flight |

**Mutation checks:** the new bridge checks fail against each of three mutants:
- terminal decided by parsing (fails at "malformed: it stays registered until the bridge's own terminal event");
- slot-wide cancel ("cancel targeting: … left the running sign-in untouched");
- a single overwritten reader ("readers: … none waits forever").

**Full regression:** run sequentially on code commit `a8684417` (macOS, Xcode 26.5, iOS 26.5 simulator). Everything is clean:
- all 44 `scripts/test-zag-*.sh` suites pass, including:
  - `apple-bridge`: Rust 4, 14 and 7; Swift 94;
  - `zsign-branch`: 86 strict, 64 integration, 3 DER;
  - `apple-accounts`: 95;
  - `apple-accounts-ui` walkthrough;
  - `isideload-fork`;
  - `install-control-taps`: 8 of 8;
- the Release build succeeds, and the Release scan passes;
- package guard: 16;
- the canonical IPA is unchanged (`67d1a79b`).

The suites not run are the three that need arguments or the owner's certificate (section 3 of the hand-off).

### 12.6 Remaining limitations and unresolved risks

- **Live behaviour is untested.** None of this has run against Apple or an anisette server.
- ~~**A bridge that never sends a terminal event:** Swift reclaims the operation only when its slot closes. A waiting reader would still wait.~~ Resolved in section 13: a cancelled operation is abandoned after a grace period.
- **Malformed messages while the bridge continues:** the slot is busy until the bridge's terminal event after Swift's cancellation, so an immediate new sign-in can be refused as `busy` (fail closed).
- ~~**Waiting is not cancellation-aware.**~~ Resolved in section 13.
- `currentStep` is shared across scopes, so a failure's reported step can be wrong while two teams provision at once. This affects reporting only.
- **Residual secrets in memory:** the token and code in Swift `String` and `NSString` copies (`JSONSerialization`), `Data` copies returned by the Keychain, and the fork's heap memory (question 1).
- **Key exportability:** software RSA keys can be exported by the app's own process. `kSecAttrIsExtractable` is not enforced for them, and the Secure Enclave cannot hold RSA-2048.
- **Apple-side state:** whether the live listing includes certificate content is unknown. Without it, a lost response stays unresolved until the user abandons it, which may leave an issued certificate occupying a slot (never revoked by Zag Store).
- **Independence:** this remediation was written by the implementer. G4 stays open until the independent reviewer completes section 10 against the remediation head.

## 13. Closeout of the re-review's four issues (for re-review)

The independent re-review of #35 at `fc509858` raised four concurrency and lifecycle issues. Each was investigated against that commit before anything changed.

**Summary:**

| # | Issue | Classification |
|---|---|---|
| 1 | Missing terminal callback and slot destruction | **Confirmed defect, fixed and regression-tested** |
| 2 | Cancellation while waiting for exclusive provisioning access | **Confirmed defect, fixed and regression-tested** |
| 3 | Callback delivery racing slot teardown | **Not reproducible**, with evidence; regression tests added |
| 4 | Lock reentrancy during cancellation | **Potential risk, mitigated and tested.** Not reachable with the current Rust code. |

### 13.1 Missing terminal callback and slot destruction (issue 1)

**Finding:** Every real caller holds its slot while it waits:
- `portal(slot:)` receives the slot as a parameter;
- the portal struct and the authenticator own one.

So the slot cannot deinitialise while one of its operations is outstanding, and the "slot close abandons the operation" fallback from section 12 never ran for them. A cancelled caller whose bridge sent no terminal event waited forever. It kept the slot, the operation and its registry entry alive. Cancellation did not help, because it too waits for the terminal event, and so did the callers' deadlines, because `ZagDeadline`'s task group awaits its child.

**Reproduced at `fc509858`** with a scratch harness:
- a reader holding the slot, a fake operation with no terminal event, and the task cancelled;
- after 8 s the reader was still waiting, the slot was alive, and 1 operation was registered.

**Fix:**
- A cancellation that reaches the bridge starts the slot's grace period (`cancellationGrace`, 5 s). If no terminal event has arrived by then, Swift abandons the operation:
  - `ZagBridgeOperations.abandon` removes the registry entry;
  - `ZagBridgeEvents.abandoned` frees the slot and delivers `cancelled`. Delivery happens at most once because of the `finished` flag, so a reader that already has its terminal event gets nothing more.
- A terminal event within the grace period wins, and the timer then changes nothing.
- Late events for an abandoned operation find no registry entry and are ignored. They cannot reach a newer operation, which has its own token.
- If the bridge is still running the abandoned operation, it refuses a new one in that slot as `busy` (Rust slot exclusivity, #34). This fails closed.

**Evidence:**
- After the fix, the same harness gets `failed(cancelled)`; the slot is released and 0 operations are registered.
- Bridge checks:
  - a cancelled caller holding its slot gets `cancelled` after the grace period;
  - the slot is then released and the operation unregistered;
  - a late terminal event is ignored;
  - exactly one event, then nil;
  - the slot starts a new operation afterwards;
  - the abandoned operation's late event does not reach the new one;
  - a result after cancelling is reported once, as the result.
- Mutant: with the abandonment removed, the bridge suite fails at "missing terminal: a cancelled caller holding its slot gets `cancelled` after the grace period".

### 13.2 Cancellation while waiting for exclusive provisioning access (issue 2)

**Finding:**
- `exclusively()` queued plain `CheckedContinuation`s with no cancellation handling. A cancelled operation waited for the running one to finish (unbounded if that one hung), then entered and failed at its first portal call.
- Releasing the scope woke only the first waiter. A woken waiter that left without taking the scope would have left the rest asleep.
- No certificate was ever issued by a cancelled waiter, because `call()` checks cancellation before sending.

**Reproduced at `fc509858`:** "queue: an operation cancelled while waiting for its team returns at once as cancelled, while the other still runs" failed.

**Fix:**
- Each waiter has a ticket. A cancellation handler removes and resumes that waiter on the actor. It is resumed exactly once, by whichever of the cancellation and the release removes it first.
- A cancelled caller throws `CancellationError` before taking the scope and runs nothing.
- A release resumes every waiter: one takes the scope, cancelled ones leave, and the rest wait again.
- Outcomes when cancelled while waiting:
  - provisioning: `cancelled`;
  - Check Again and Abandon: `checkFailed(.cancelled)`, with nothing changed;
  - the unresolved-request query: nil.

**Evidence:** strict integration checks, 64 → 73:
- a cancelled waiter returns at once while the holder still runs, and leaves no waiter;
- another account's scope is not delayed;
- the holder and both remaining waiters complete;
- Apple was asked once;
- no continuation is left;
- a task cancelled before it waits sends nothing;
- the next signing proceeds and reuses the certificate;
- 24 waiters with half cancelled: 13 done, 12 cancelled, one request, no waiter left.

### 13.3 Callback delivery racing slot teardown (issue 3)

**Finding:** no defect.
- Terminal delivery, slot closure, registry removal, cancellation and abandonment all converge on `ZagBridgeEvents.deliver`. Its `finished` flag, under the lock, passes one terminal event; waiters are resumed outside the lock.
- The registry entry is removed by exactly one of the terminal callback and the abandonment.
- A weak load of a slot that is deinitialising returns nil, and a strong reference taken by a callback prevents the slot from deinitialising.
- No lock is held while Swift calls Rust or resumes a continuation (since 13.4), so there is no lock cycle.

**Evidence at `fc509858`, before any closeout change:**
- five fixed orderings of terminal, close and cancel;
- 400 stress rounds, with terminal delivery, slot closure and cancellation run at once on three threads (`concurrentPerform`).
- Over three runs: orderings 5/5 and stress 1,200/1,200 exactly-once, with 0 operations left registered.

**Regression tests added:**
- the same five orderings, deterministic;
- the 400-round stress run with a 0.05 s grace. In this run: 10 results and 390 cancellations, every reader exactly once, none lost, nothing registered.
- A double resume of a `CheckedContinuation` would crash the test process; none occurred.

### 13.4 Lock reentrancy during cancellation (issue 4)

**Finding:**
- `ZagBridgeSlot.cancel` called `zag_bridge_cancel` while holding the slot's `NSLock`. The terminal event's path (`received` → `slot.ended`) takes the same lock. A bridge answering a cancellation on the calling thread would deadlock.
- **The current Rust does not:**
  - `slot::cancel` only sends on `oneshot` channels and drops the answer sender while holding its own mutex;
  - every terminal event is emitted by a spawned runtime task after that mutex is released, or inline only by the start functions;
  - the start functions run outside Swift's lock.
- So this is not reachable today, but it was one Rust change away from a deadlock.

**Reproduced** with an injected cancel function that delivers the terminal event synchronously: the cancel never returned (a deadlock).

**Fix:**
- The slot marks a cancellation in progress under the lock, then calls the bridge without the lock, then clears the mark.
- While the mark is set, `start` refuses as `busy`, so the slot-wide cancellation still cannot reach an operation started after the one being cancelled.

**Evidence:**
- bridge checks: no deadlock; the operation ends once, and an operation started during the bridge's cancel call is refused; the slot works normally afterwards;
- mutants: with the call made under the lock, the suite fails at "does not deadlock"; without the start guard, it fails at "nothing can start in the slot during the bridge's cancel call".

### 13.5 Verification

**Commits:**
- `6b26c6a9`: bridge, issues 1 and 4, with tests for 1, 3 and 4.
- `86268e66`: provisioner, issue 2, with tests.

**Test counts:**

| Suite | Section 12 | Now |
|---|---|---|
| Bridge Swift | 94 | 110 |
| Bridge Rust, default/mock/live | 4/14/7 | 4/14/7 |
| Strict integration | 64 | 73 |

**Mutation:** the three new bridge mutants each fail the suite. The issue 2 test failed on the unfixed code.

**Full regression:** run sequentially on code commit `86268e66` (macOS, Xcode 26.5, iOS 26.5 simulator). Everything is clean:
- all 44 `scripts/test-zag-*.sh` suites pass, including:
  - `apple-bridge`: Rust 4, 14 and 7; Swift 110;
  - `zsign-branch`: 86 strict, 73 integration, 3 DER;
  - `apple-accounts`: 95;
  - `apple-accounts-ui` walkthrough;
  - `isideload-fork`;
  - `install-control-taps`: 8 of 8;
- the Release build succeeds, and the Release scan passes;
- package guard: 16;
- the canonical IPA is unchanged (`67d1a79b`).

As before, the suites not run are the three that need arguments or the owner's certificate.

### 13.6 Remaining limitations
- **A deliberate design choice:** after the grace period, an operation the bridge still runs is abandoned by Swift. The slot stays busy in Rust until the bridge ends it.
  - For a certificate request, provisioning reports `cancelled`, and the request stays unconfirmed: settled from the listing, or by the user. It is never sent again blindly.
- **An uncancelled reader** whose bridge never sends a terminal event waits until its caller cancels it. Every production caller has a deadline: the authenticator's `operationTimeout` and the provisioner's `ZagDeadline`.
- **Section 12.6 still applies** except where struck through: live behaviour untested, residual secrets in memory, exportable software keys, unknown listing content, and that the implementer wrote this.
