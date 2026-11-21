# Apple authentication reliability audit

21 November 2026. Base: `feature/native-adi-provider-review` at `c37b6331`. Branch: `claude/auth-reliability`.

**Scope:** sign-in, 2FA, the app token, the anisette provider, its device state, and the bridge's storage. The covered code is `zag-isideload` (`auth/`, `anisette/`, `net_policy.rs`), `zag-apple-bridge/src/live.rs` and Swift's anisette Keychain callbacks.

**Out of scope:** GPT-6's native CoreADI work in `zag-anisette-server` and its tools. Nothing there was modified; one finding there is reported at the end.

**Nothing was tested live.** No Apple contact, no anisette server, no credentials. Every test below is offline.

## Ranked findings

Severity is the damage when the failure happens. Likelihood is how often a real user would hit it.

| # | Finding | Severity | Likelihood | Status |
|---|---|---|---|---|
| R1 | A Keychain read error replaces the anisette device identity | High | Low–medium | Fixed |
| R2 | No HTTP time limits on any Apple or anisette request | High | Medium | Fixed |
| R3 | Provisioning socket: keep-alive pings end provisioning, and a quiet server hangs it | Medium–high | Medium | Fixed |
| R4 | A successful provisioning is lost if the socket close fails | Medium | Low–medium | Fixed |
| R5 | Concurrent callers provision (or reset) the same identity more than once | Medium | Low | Fixed |
| R6 | SMS 2FA always targets phone-number id 1 | Medium | Low | Fixed |
| D1 | Two bridge slots on the same account can each provision | Medium | Low | Documented |
| D2 | A corrupted stored state is silently replaced | Low–medium | Very low | Documented |
| D3 | Leftover sensitive material in reports and `Debug` | Low | Very low | Documented |
| D4 | Smaller protocol assumptions | Low | Low | Documented |
| G1 | GPT-6's area: `zag-anisette-server` CI fails on a stale `Cargo.lock` | — | Every run | Reported |

### R1: a Keychain read error replaces the anisette device identity (fixed)

**Failure.** Suppose the Keychain cannot be read when sign-in starts. Causes include before first unlock, a `securityd` error, or a decode error. The provider then:

1. takes this as "no state";
2. creates a new random identity;
3. provisions it with Apple as a new device;
4. writes it over the stored identity.

The existing identity, and every session made with it, is orphaned. Apple sees a new machine, with the 2FA and new-device prompts that follow. Repeated, this is the kind of churn that gets an account rate-limited.

**Root cause.** It took three layers that each lose information:
- **Swift:** `ZagBridgeAnisetteKeychain.retrieve` returned `1` for both `errSecItemNotFound` and every other error.
- **`live.rs`:** `KeychainStorage::retrieve_data` turned any non-zero code into `Ok(None)`.
- **`remote_v3/mod.rs`:** `get_state` matched `if let Ok(Some(..))`, so even an `Err` started fresh.

The Swift `store` comment already warned that losing this state "registers a new anisette device with Apple". The read path just didn't honour it.

**Fix.**
- **Swift:** `retrieve` now returns `0` (found), `1` (no item) or `2` (unreadable).
- **Rust bridge:** codes other than `0` and `1` become an error.
- **`get_state`:** a storage error stops the operation. Nothing is provisioned and nothing is written.

**Files:**
- `Feather/Utilities/FreeAccount/ZagIsideloadBridge.swift`
- `AppleAuthCore/zag-apple-bridge/src/live.rs`
- `AppleAuthCore/zag-isideload/src/anisette/remote_v3/mod.rs`

**Tests:**
- `persistence_tests::unreadable_storage_never_replaces_the_identity`. I mutation-checked it: restoring the old `unwrap_or(None)` makes it fail.
- `persistence_tests::stored_identity_is_reused_without_provisioning`.
- `persistence_tests::failed_provisioning_stores_nothing`.
- `live::tests::unreadable_keychain_is_an_error_not_an_absent_state`.
- Two new Swift checks in `scripts/ZagAppleBridgeTests.swift`: a missing item reads as 1, and an unusable read as 2.

**Limitation.** A real `errSecInteractionNotAllowed` can't be produced in a test. The Swift check covers the `2` path through an invalid key.

### R2: no HTTP time limits (fixed)

**Failure.** A connection that stalls (bad Wi-Fi, a captive portal, an overloaded server) never completes. That covers:
- Apple's URL bag, SRP init and complete, 2FA, app tokens and developer services;
- the anisette server's `client_info` and `get_headers`.

The sign-in hangs, and the bridge slot stays `signing_in` until the user cancels. This is the classic intermittent "login spins forever" report.

**Root cause.** `net_policy::guarded_client`, which builds every client, set https-only and no-redirects, but no connect or request timeout. reqwest has neither by default. The only time limit anywhere was the 30 s WebSocket connect.

**Fix.** In `guarded_client`, so every client gets it: a 15 s connect timeout (TCP and TLS) and a 60 s limit for the whole request. A timeout surfaces as a reqwest error with no status, which `classify` reports as `Network`, so the app can tell the user to retry.

**File:** `AppleAuthCore/zag-isideload/src/net_policy.rs`.

**Tests:**
- `net_policy::tests::stalled_server_times_out`: a local server accepts and never answers, and the request ends with `is_timeout()` in under 2 s.
- `net_policy::tests::every_client_has_time_limits`: a source check that `guarded_client` applies the constants.

**Limitation.** 60 s is a judgment call. It is generous for GSA, and well above the 0.84 s median and 3.4 s 95th percentile measured for `ani.sidestore.io` in the anisette study.

### R3: the provisioning socket fails on keep-alives and hangs on silence (fixed)

**Failure.**
- **Keep-alive.** tungstenite delivers `Ping` and `Pong` frames to the reader. `AppWebSocket::next` mapped everything that was not text to `Close`, so a server that pings during provisioning ended it as "Provisioning socket closed unexpectedly". The ping could come from the server itself or from a proxy such as Cloudflare or Nginx.
- **Silence.** After the connect there was no time limit, so a server that went quiet mid-exchange hung provisioning for good.

**Fix.**
- Ping, pong and raw frames are skipped; tungstenite still answers pings itself. Binary data still ends the exchange.
- Each message wait is limited to 60 s.

**File:** `AppleAuthCore/zag-isideload/src/anisette/remote_v3/websocket.rs`.

**Test:** `websocket::tests::keep_alive_frames_do_not_end_provisioning`.

**Limitation.** The 60 s message timeout isn't unit-tested, because `connect` needs the live network policy.

### R4: a successful provisioning is lost on a failed close (fixed)

**Failure.** On `ProvisioningSuccess` the code set `adi_pb`, then ran `ws.close().await?`. If the server had already dropped the socket, the close failed and `get_state` returned the error before storing the state. The device was provisioned with Apple but never persisted, so the next launch provisioned another one.

**Fix.** The close result is ignored once `adi_pb` has been received.

**File:** `AppleAuthCore/zag-isideload/src/anisette/remote_v3/mod.rs`.

**Tests:** none specific; it needs a live socket. The persistence tests cover the store step that follows.

### R5: duplicate provisioning by concurrent callers (fixed)

**Failure.** `AnisetteDataGenerator` is cloned: sign-in passes it to `DeveloperSession`, and the clones share one provider. When several callers found the provider unprovisioned, each waited for the write lock and then each provisioned in turn. On `-45061` (incorrectly provisioned), each of them reset the identity, throwing away the device the previous caller had just made.

**Fix.** Under the write lock, the provider is asked again before provisioning. This is double-checked locking.

**File:** `AppleAuthCore/zag-isideload/src/anisette/mod.rs`.

**Tests:**
- `anisette::tests::concurrent_callers_provision_once`: three concurrent callers, one provisioning.
- `anisette::tests::concurrent_callers_reset_once`: the same for the reset path.

Both are mutation-checked: without the re-check, they count 3 provisionings, not 1.

### R6: SMS 2FA always targets number id 1 (fixed)

**Failure.** When GSA answers `au = secondaryAuth`, the login state became `NeedsSMS2FA(1)`, with the comment "just start by trying 1". On an account whose trusted numbers are numbered differently, the first SMS request failed and 2FA could not continue.

**Fix.** Once the account's trusted numbers are known and none of them is `1`, the first number is used. A valid choice, including the user's own, is never changed.

**File:** `AppleAuthCore/zag-isideload/src/auth/apple_account.rs`.

**Test:** `auth::apple_account::tests::sms_goes_to_a_number_the_account_has`.

### D1: two slots, one account (documented, not fixed)

The bridge's busy flag is per slot. Two slots working on the same anisette scope at once each build their own provider, with their own in-memory state. For example: `sign_in` on one and `open_session` plus a portal call on another. If both find no stored state, both provision, and the last write wins.

R5 doesn't cover this, because the providers are separate.

**Suggested fix.** In `live.rs`, keep a process-wide map from scope to a `tokio::sync::Mutex`. Hold the lock around provisioning, and re-read storage under it. I didn't make this change: whether the Swift UI can actually run two slots on the same account at once should be checked first, and if it can't, this is defensive only.

### D2: corrupted stored state (documented)

If the stored state exists but cannot be parsed, `get_state` starts fresh and overwrites it, as upstream does. Recovery is reasonable here, because the old state is unusable, but nothing records that it happened.

**Suggestion.** Report a reset as a distinct, data-free diagnostic, so "a new device was registered" can be seen.

### D3: leftover sensitive material (documented)

**Already true, verified:**
- Logging is compiled out (`quiet.rs`: the macros never evaluate their arguments).
- The bridge's `classify` drops every report's text, so only a `FailureKind` reaches Swift.
- Password-derived buffers are `Zeroizing`.
- `StoredToken` zeroizes on drop.

**Residual, harmless today but one refactor away from leaking:**
- `AnisetteData` derives `Debug`, including the one-time password.
- Reports attach raw response bodies in three places:
  - `plist_request` on a parse failure;
  - the trusted-device 2FA parse failure;
  - the SMS failure messages.
  These could carry masked phone numbers.

**Suggestion.** A hand-written `Debug` that redacts the OTP, and no response bodies in reports.

### D4: smaller protocol assumptions (documented)

- **Unknown `hsc`.** An unexpected `Status.hsc` is treated as logged in. The failure then shows up later, at the app token.
- **Negative expiry.** `get_app_token` casts a signed `expiry` and `duration` with `as u64`. A negative value becomes huge. `expiry_seconds` in the bridge then refuses it as `Malformed`, after a sign-in that succeeded.
- **429 retries.** These are immediate, with no backoff and no `Retry-After`. They are off by default by the fork's design (`err_429_retries: None`). If they are ever enabled, they need a backoff first.
- **URL bag.** It is fetched on every `sign_in` and every `open_session`. One transient failure fails a session reopen; it is classified as `Network`, so the app can retry.

### G1: GPT-6's area, `zag-anisette-server` (reported only)

**The CI suite fails before it runs.** `.github/workflows/g3-anisette-offline.yml` runs `cargo test --locked`. Since `libc` was added to `Cargo.toml`, the committed `Cargo.lock` no longer lists it, so cargo refuses: "cannot update the lock file … because --locked was passed".

**Suggested fix:** run `cargo build` in `AppleAuthCore/zag-anisette-server` and commit the one-line `Cargo.lock` change (`"libc"` added to the package's dependencies).

**Also seen on this Mac (macOS 26, Darwin 25.6), without `--locked`:** 8 subprocess tests fail with `BackendUnavailable`. Examples are `provisioning.rs:449` and `session_supervisor.rs:463`. The other 27 pass. The workflow's matrix includes `macos-latest`, so this may fail there too once the lock file is fixed.

## Observability: telling Apple outages from our bugs

Everything below is counts and buckets. No identifiers, account data or response text.

1. **Stage × outcome counters.**
   - The stages: `url_bag`, `anisette_client_info`, `anisette_headers`, `anisette_provision`, `gsa_init`, `gsa_complete`, `2fa_send`, `2fa_verify`, `app_token`, `teams`.
   - The outcomes: `ok`, `timeout`, `connect`, `http_4xx`, `http_5xx`, `gsa_error`, `malformed`, `cancelled`.
2. **GSA error codes as numbers only.** Record `ec`, never `em`, bucketed into the known set (`-21669`, `-22979`/`-22981`, `-28248`, `-45061`, …) plus "other".
3. **Latency buckets per stage:** <1 s, 1–5 s, 5–30 s, timeout.
4. **Anisette state events:**
   - loaded;
   - created (no state);
   - reset (`-45061`);
   - replaced (corrupt, D2);
   - storage unreadable (R1).
   A rise in "created" on devices that had already signed in is the R1 class of bug.

**How to read it:**
- **An Apple outage:** `http_5xx` and `timeout` rising together across installs at `url_bag` and `gsa_*`, while `anisette_*` stays healthy.
- **A provider outage:** the same at `anisette_*` only.
- **Our own bug:** `malformed` at one stage, or a jump right after a release, or "created" events on devices that already had state.

**API note.** The bridge's `FailureKind::Network` currently merges timeout, connect failure and 5xx. Splitting it is an API change for Swift, so it is a recommendation only. A server-side synthetic check, for example a URL bag request every few minutes, would contact Apple, and needs its own approval.

## Test results

| Suite | Result |
|---|---|
| `zag-isideload`: `cargo test` (default) | 18 passed (9 before) |
| `zag-isideload`: `cargo test --features live-network` | 19 passed |
| `zag-apple-bridge`: `cargo test` / `--features live` | passed / 8 passed (1 new) |
| `scripts/test-zag-apple-bridge.sh` | 112 checks passed (2 new) |
| `scripts/test-zag-existing-account.sh` | 122 checks passed |
| `scripts/test-zag-g5-experiment.sh` | 419 checks passed |
| `scripts/test-zag-free-account-*.sh` | authentication 90, foundation 96, Keychain, portal 43, signing 94, release binary, sign-in 43, sign-in UI: passed |
