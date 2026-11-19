# G4: security review package for the Apple Account bridge

Status 19 November 2026: **implementation ready for an independent security review. Not reviewed. No live Apple service has been contacted.** The author of the bridge has not reviewed it independently. G4 stays open until a reviewer independent of the implementation records the decision in section 10.

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
| Anisette device state | The Keychain (`ZagStore.anisette.bridge`), `AfterFirstUnlockThisDeviceOnly`, never synchronised | Device lifetime | One device state is shared by all accounts, as on a real Apple device. Opaque to Zag Store. |
| Signing key | A Keychain key item per account and team (PR #28) | Until the account or team is removed | Never exported. Signing goes through the key reference only. |

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
- **Shared state.** The only state shared between slots is the configured backend, and in `live` the anisette device state.

**Tests (Swift):**
- two accounts in one directory;
- the second account does not see the first account's device;
- a portal bound to one account refuses the other account's session.

**Tests (Rust):** the same checks, plus rebinding.

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

- **Every operation ends with exactly one terminal event**, including when it is cancelled, its slot is closed, its input is malformed, or the operation panics (checked in Rust). Swift's per-operation event queue is released on that event.
- **Cancellation.** Swift task cancellation and the authenticator's `cancel()` call `zag_bridge_cancel`, which drops the running future, including any request in flight.
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

## 9. Points the supervised experiment must confirm (marked `EXPERIMENT` in `live.rs`)

These concern the meaning of values. They are not protocol messages; those stay inside the fork.
1. **Token expiry unit.** Milliseconds is assumed when the value is too large to be seconds. A wrong unit would fail the session's validation: the expiry must be between 1 minute and 400 days away. It cannot silently extend a session.
2. **Team kind.** The bridge reports `unknown` for every team, and Zag Store applies the free limits, the strictest.
3. **Locating a newly issued certificate.** It is found by the request's identifier, as upstream does. If it is not found, the result is `malformed`.
4. **Certificate request format.** The request is sent as PEM, as upstream's own requests were.
5. **Anisette device serial.** `"0"`, as upstream.

## 10. Questions and decision record (for the independent reviewer)

**Questions:**
1. Are the residuals acceptable for a supervised experiment with a dedicated account? The residuals are:
   - unwipeable Swift `String` copies of the token and the code;
   - the code in an HTTP header;
   - the token in ordinary heap memory inside the fork while a session object exists.
2. Should the anisette host be pinned?
3. Is a shared anisette device state across accounts acceptable, or should each account have its own?
4. Is the binding rule (first use binds a restored slot) sufficient? Should a portal also check the credential against the directory's account record?
5. Anything in sections 2–8 to change before the experiment build is made?

| Field | Entry |
|---|---|
| Reviewer (independent of the implementation) | |
| Date | |
| Commits reviewed (bridge PR head, PR #26 head, PR #28 head) | |
| Findings and required changes | |
| G4 complete | **No** |
