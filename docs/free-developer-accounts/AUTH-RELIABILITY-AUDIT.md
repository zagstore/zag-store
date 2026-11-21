# Apple authentication reliability audit

21 November 2026. Base: `feature/native-adi-provider-review` at `c37b6331`. Branch: `claude/auth-reliability`. The first pass fixed R1–R6 (`93a39d36`); the second fixed D1–D4.

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
| D1 | Two bridge sessions on the same account can each provision | Medium | Low | Fixed |
| D2 | A corrupted stored state is replaced with no record | Low–medium | Very low | Fixed |
| D3 | Sensitive material in `Debug` output and error reports | Low | Very low | Fixed |
| D4 | Negative token times, unexpected `hsc`, 429 retries without backoff | Low | Low | Fixed |
| G1 | GPT-6's area: `zag-anisette-server` CI fails on a stale `Cargo.lock` | — | Every run | Fixed by GPT-6 (`1be6498c`) |

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

### D1: two sessions, one account (fixed)

**Failure.** The bridge's busy flag is per slot. Two slots working on the same anisette scope at once each build their own provider, with their own in-memory state. For example: `sign_in` on one, and `open_session` plus a portal call on another. If both found no stored state, both provisioned a device with Apple, and the last write won. The other session was left with an orphaned device. R5's re-check doesn't help here, because the two providers don't share a lock.

**Fix.** `RemoteV3AnisetteProvider::set_state_scope` names the stored state's scope, and the bridge passes the account's anisette scope. `get_state` now runs entirely under a process-wide lock for that scope.

**How it works.** Under the lock, `get_state` reads storage again, then:
- **Stored and provisioned:** the stored device is used. If it is not this provider's own device, it is *adopted*: another session made it meanwhile.
- **On a reset (`-45061`):** only this provider's own rejected device is refused. A different stored device is a replacement another session already made, so it is adopted, not reset again.
- **Otherwise:** a new device is made, provisioned and stored before the lock is released.

**Lock details.** The lock registry holds weak references, so entries for scopes nobody uses are dropped. A provider without a scope gets a lock of its own, which keeps the old behaviour.

**A side effect, on purpose.** A stored state that is used unchanged is no longer written back. That's one Keychain write less per sign-in.

**Files:**
- `zag-isideload/src/anisette/remote_v3/mod.rs`
- `zag-apple-bridge/src/live.rs`

**Tests:** two independent providers sharing one storage.
- `persistence_tests::two_sessions_for_one_account_provision_one_device`: both find no state; the result is one provisioning and one identity for both, which is the stored one.
- `persistence_tests::two_sessions_resetting_one_device_reset_it_once`: both use device X and both are told it's rejected; the result is one reset, and both end on the same new device.

Both tests were mutation-checked against two mutants. Without the lock, each counts 2 provisionings. With the lock but storage read before taking it, each again counts 2. Each passed 20 of 20 repeated runs.

**Limitations.**
- The lock is per process. The app runs one bridge, so this covers it, but two processes sharing a Keychain would not be coordinated.
- The test replaces the network exchange with a short sleep (a `cfg(test)` hook), because a real exchange needs Apple.

### D2: corrupted stored state (fixed)

**Behaviour kept.** A stored state that cannot be parsed is still replaced by a new device. Recovery stays automatic, because the old state is unusable.

**What's new.** Every outcome is now counted, per process, as a data-free `StateChange`:
- `Loaded`;
- `Adopted`;
- `Created`;
- `ReplacedCorrupt`;
- `Reset`.

It has no fields, so no identifier or provisioning material can get into it. The bridge exports the counts as `zag_bridge_anisette_state_count(kind)`, which returns numbers only (0 for an unknown kind).

**Test:** `persistence_tests::corrupted_state_is_replaced_and_counted_without_data`. The replacement is stored and provisioned, and the counter goes up. There is also `anisette_state_counts_are_data_free_numbers` in `tests/bridge.rs`.

**Limitation, deliberately not wired up yet:** nothing in Swift reads the counter. The experiment logger has a fixed, reviewed event schema (`ZagExperimentLogger.events`, part of the G4 evidence). Adding an `anisette.state` event there should go through that review, not this branch.

### D3: sensitive output (fixed)

**`Debug` implementations.** These are now hand-written and withhold the values:

| Type | Shows | Withholds |
|---|---|---|
| `AnisetteData` | only `generated_at` | the one-time password, machine ID, device ID and routing info |
| `AnisetteState` | `provisioned` | the identifier and `adi_pb` |
| `AppToken` | duration and expiry | the token |
| `TwoFactorCallbackResponse::SubmitCode` | `SubmitCode(<withheld>)` | the 2FA code |

**Error reports.** Bodies and values are gone:
- **`SensitivePlistAttachment`:** now keeps only the top-level key names, sorted, at most 64. Values are dropped when the attachment is made. Upstream's `DEBUG_SENSITIVE` switch, which printed whole plists (tokens, SPD), is removed. This attachment covers every `get_*` lookup failure.
- **GrandSlam (`plist_request`) and the trusted-device 2FA response:** go through `parse_response_plist`, which reports the body's length, never its content. GrandSlam's "missing `Response`" error shows key names only.
- **SMS send, SMS verify and trusted-number failures:** report the HTTP status and body length, not the body. Those bodies carry the trusted phone numbers.
- **Anisette server errors** (`GetHeadersError`, `Start`/`EndProvisioningError`): report the message length only. The message can echo Apple's response.

**Tests:**
- `util::plist::tests::reports_name_keys_but_never_show_values`
- `util::plist::tests::unparseable_bodies_are_not_reported`
- `anisette::tests::debug_output_withholds_anisette_values`
- `auth::apple_account::tests::debug_output_withholds_codes_and_tokens`
- `auth::apple_account::tests::sms_failures_do_not_report_the_body`

Each checks both the `Display` and the `Debug` rendering.

**Kept on purpose:** Apple's structured SMS error code, title and message (for example "Incorrect verification code"). These are Apple's own user-facing wording, not raw bodies.

### D4: protocol hardening (fixed)

**Negative token times.** `get_app_token` cast the signed `duration` and `expiry` with `as u64`, so `-5` became 18446744073709551611. They are now converted with `u64::try_from`, and a negative value is an error.
- Valid values are unchanged.
- Zero is still accepted; judging plausibility is the bridge's job (`expiry_seconds`).
- The parsing moved to `app_token_from`.
- **Test:** `app_token_times_must_not_be_negative`.

**Unexpected `hsc`.** Any `Status.hsc` other than 409 used to count as signed in, so the failure surfaced later as a confusing app-token error. The status handling moved to `login_state_for`:
- `au` is handled as before;
- no `hsc`, or a 2xx `hsc`, means signed in;
- 409 means a 2FA code was already sent;
- **any other `hsc` is now an error that reports only its number.**

**Tests:**
- `valid_statuses_keep_their_meaning`: 200, no `hsc`, 409, `au` taking precedence, `secondaryAuth`, `repair`, and unknown `au`.
- `unexpected_statuses_are_errors_not_sign_ins`: 401, 403, 434, 500, 503, −1 and an out-of-range integer, with `em` never reported.

**Kept as upstream:** an unknown `au` value still becomes `NeedsExtraStep`, which counts as signed in only when the SPD holds a PET token. I found no evidence to justify changing it.

**429 retries.** These stay **off by default**: `err_429_retries: None`, and a test pins that. If a caller enables them, `plist_request` now waits before each retry instead of resending at once. It waits Apple's `Retry-After` in seconds (at least 1, at most 120), or otherwise 2, 4, 8 … seconds, capped at 32. The recursion became a loop.
- **Tests:** `retries_back_off`, `retry_after_is_honoured_within_bounds` and `retries_stay_off_by_default`.
- **Limitation:** an HTTP-date `Retry-After` falls back to the backoff instead of being parsed.

### G1: GPT-6's area, `zag-anisette-server` (reported; fixed by GPT-6 in `1be6498c`)

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

These are the results after the second pass, D1–D4. Everything is offline, with no Apple contact and no credentials.

| Suite | Result |
|---|---|
| `zag-isideload`: `cargo test` | 32 passed (9 at `c37b6331`, 18 after R1–R6) |
| `zag-isideload`: `cargo test --features live-network` | 33 passed |
| Concurrency tests (R5 ×2, D1 ×2, D2) | 20 of 20 repeated runs passed |
| `zag-apple-bridge`: `cargo test` / `--features live` / `--features mock` | 4 + 4 / 8 + 4 / 3 + 15 passed |
| `scripts/test-zag-apple-bridge.sh` | 112 checks passed |
| `scripts/test-zag-existing-account.sh` | 122 checks passed |
| `scripts/test-zag-g5-experiment.sh` | 419 checks passed |
| `scripts/test-zag-free-account-*.sh` | authentication 90, portal 43, signing 94, Keychain, foundation 96: passed |

**Mutation checks.** Each of these fails when its fix is removed:
- R1: the storage-read stop;
- R5: the re-check under the write lock;
- D1: the scope lock, and the re-read after taking it.

**Not run.** `zag-anisette-server` (GPT-6's) was not run on this pass, and nothing in it was touched.
