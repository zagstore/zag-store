# Free Apple Developer Accounts: Phase 2 groundwork

Status, 18 November 2026: the testable foundation is on branch `claude-free-developer-accounts` (draft PR #24).
- **Live Apple Account sign-in is not implemented and is disabled** (`ZagLiveAuthentication.isEnabled = false`).
- **Live anisette providers are disabled** (`ZagAnisetteLive.isEnabled = false`).
- Every test uses simulated services and synthetic credentials.

The owner's decisions (18 November) were:
1. a configurable remote anisette provider, with a recommended default and a custom provider under Advanced, and no Zag Store service yet;
2. reuse OpenSSL rather than add AGPL code, based only on independently verified behaviour;
3. **never persist the Apple Account password**, not even as an option.

## 1. SideStore: architecture assessment

This assessment is at the level of structure and design. No SideStore code was copied, and none is needed for what follows.

**What SideStore gets right, and what Zag Store adopts as independent designs:**

- **Pluggable anisette with a server list.** The user can choose or add a provider, and the device keeps its own anisette state.
  - Zag Store has `ZagAnisetteProviderConfiguration`, `ZagAnisetteProviderSettings` and `ZagAnisetteBroker`.
  - Zag Store also adds an explicit evaluation status per provider, health records, and *no* silent fallback to a different provider unless the user allows it, because a different provider sees the device's anisette identity.
- **Separate layers.** Anisette, account authentication, the developer portal, signing and device transport are separate components.
  - Zag Store keeps these as protocols: `ZagAnisetteSource`, `ZagAppleAuthenticationService` and `ZagHTTPTransport`.
  - Each is injected into `ZagFreeAccountAuthenticator`, so every path is testable without the network.
- **An operation pipeline with a final verification step.** SideStore installs and refreshes through discrete operations, ending with verification.
  - Zag Store's Phase 1 refresh ledger already refuses success without a verified newer expiry.
  - The installer will follow the same pattern in Phase 4.

**What Zag Store deliberately does differently (safer, more maintainable):**

- **TLS and logging.** Some reference code in this ecosystem turns off TLS certificate validation, or prints session values to the console while debugging.
  - Zag Store's transport never overrides server trust. A source check enforces this: no `serverTrust`, no challenge handler, no ATS exceptions.
  - Free-account code contains no logging calls at all; diagnostics go only through `ZagSensitiveRedactor`.
- **Background keep-alive.** SideStore can keep itself alive in the background with a silent-audio or location loop. Zag Store won't. Refresh will be honest best-effort, plus Shortcuts.
- **Strict validation.** Reference code often force-unwraps service responses. Zag Store validates every response into typed values first (`ZagAuthenticatedSession.validated`, `ZagAnisetteData(validating:)`).
  - Anything unexpected becomes `unexpectedResponse`, which is never retried automatically and never stored.
- **The password.** It's held in a wipeable buffer (`ZagEphemeralSecret`) only for the sign-in operation, including the wait for a code. It's zeroed on success, failure, cancellation and timeout, and has no Keychain slot.
- **Licensing.** Pure-Swift signing and authentication kits exist, but they're AGPL. Zag Store reuses Zsign (signing) and the OpenSSL it already ships (where cryptography is needed), so the licence is unchanged.
- **Safety by default.** Live services are behind compile-time switches that default to off. Source checks fail the build tests if they're enabled with no supervised plan.

## 2. What was built in Phase 2 (groundwork)

| File | Purpose |
|---|---|
| `ZagFreeAccountTransport.swift` | The injectable `ZagHTTPTransport`; a `ZagTransportPolicy` (HTTPS only, host allow-list also applied to redirects, no credentials in URLs, header-injection checks, bounded timeouts and response size); an ephemeral `URLSession` transport (no cookies, cache or stored credentials; system TLS validation); `ZagDeadline` for timeouts. |
| `ZagAnisetteProvider.swift` | Anisette data validated and never printed; providers by kind (remote, first-party, on-device); per-provider evaluation status; the recommended default plus a validated custom URL; settings persistence; the broker with deadlines, staleness checks, health and opt-in fallback; disabled live providers. |
| `ZagFreeAccountAuthentication.swift` | Wipeable password; two-factor challenge and prompt model (trusted device, SMS, masked numbers only, local code validation, attempts left); the session credential, kept only in the Keychain; strict session validation; the service protocol with a disabled live stub; session summary storage; redacted diagnostics. Also the `ZagFreeAccountAuthenticator` actor: sign-in, code entry, SMS fallback, cancellation, deadlines, restore at launch, validation of a stored session, and sign-out that removes everything or reports failure. |
| `ZagFreeAccountState.swift` | New failure kind `unavailable` ("not available in this version"). |

Phase 1 is unchanged otherwise, and so are BYOC, certificate signing and RPPairing installation.

**OpenSSL isn't used in this phase.** Nothing here needs it. It stays reserved for the authentication cryptography, once that's specified and verified under the supervised plan.

## 3. Anisette provider evaluation (before any live use)

| Criterion | How it will be checked |
|---|---|
| Security | TLS with a valid public certificate chain (no pinning bypass); HTTPS-only redirects; operator identity; whether the server keeps per-device data |
| Privacy | What the provider receives (the device's anisette identity, never credentials); retention policy; logging statements |
| Availability | Supervised probes at different times over at least a week; latency; error rates |
| Compatibility | Responses accepted by `ZagAnisetteData(validating:)`; behaviour on errors |
| Failure handling | Clear "provider unavailable" in the app; no silent switch to another provider |

`ZagAnisetteProviderCatalogue.recommended` (SideStore's public server) stays `pending` until this evaluation is done and you approve it.

## 4. Supervised real-account test plan (not started)

**Prerequisites:**
- A dedicated Apple Account that you own, used for nothing else, with two-factor authentication turned on.
- A test iPhone you choose.
- An evaluated anisette provider.

**Rules:**
- **You type your credentials and verification codes only into Zag Store on your device**, never into chat, terminals or logs.
- Claude never receives them.
- Diagnostics are reviewed only in their redacted form.

**Remaining requirements before the first live test:**
1. **Live anisette provider.** Implement it against the evaluated provider, behind `ZagAnisetteLive.isEnabled`, in a separate commit.
2. **Live authentication service.** Implement `ZagAppleAuthenticationService` for Apple's services, behind `ZagLiveAuthentication.isEnabled`, using OpenSSL primitives with published test vectors.
   - It must have its own security review.
   - The protocol behaviour it relies on must be documented and independently confirmed before it's enabled.
3. **Test build.** A sign-in screen in a debug-only test build. It isn't shown in release builds until Phase 4.

**Test cases (run by you, observed through redacted diagnostics):**
1. Sign in with the correct password and a trusted-device code: expect signed in with the Personal Team, the session in the Keychain, and the password wiped.
2. Wrong password: expect "not accepted" and nothing stored.
3. Wrong verification code twice, then the correct one: expect a retry prompt, then signed in.
4. Request the code by SMS: expect a masked number only.
5. Cancel at the code prompt: expect "cancelled" and nothing stored.
6. Aeroplane mode during sign-in: expect a network failure within the timeout.
7. Provider unavailable (custom URL to a stopped server): expect "anisette unavailable", and Apple not contacted.
8. Relaunch the app: expect the session restored without the network.
9. Sign out: expect the Keychain item and the summary both gone (checked with the simulator Keychain test's method on the device build).
10. After the session expires, or is revoked by changing the password: expect "sign in again".

**Exit criteria:** every case behaves as described, no secret appears in diagnostics, and you sign off. Only then does Phase 3 (signing with an issued profile) start.

## 5. Test evidence

- `scripts/test-zag-free-account-authentication.sh`: **90 checks**, passing on 6 consecutive runs (the timing-dependent tests aren't flaky). They cover:
  - malformed responses (8 cases);
  - unavailable, slow, stale and malformed providers;
  - an expired session;
  - failed two-factor (wrong codes, attempt limit, window expiry);
  - cancellation during sign-in, at the prompt and while a code is checked;
  - Keychain write and delete failures;
  - redaction;
  - the disabled live path.
- `scripts/test-zag-free-account-foundation.sh`: the 96 Phase 1 checks, plus source checks:
  - no Apple service URLs, no logging, only the transport uses `URLSession`, no TLS overrides;
  - live switches off;
  - no free-account UI.
- `scripts/test-zag-free-account-keychain.sh`: 9 checks against the iOS Simulator's real Keychain.
- Release iOS build of the app (`CODE_SIGNING_ALLOWED=NO`).
