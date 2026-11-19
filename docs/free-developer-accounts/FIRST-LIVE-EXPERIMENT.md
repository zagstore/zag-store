# The first live free-account installation: smallest path and gate evidence

Status 19 November 2026: **prepared, not approved, nothing live.**
- No Apple endpoint has been contacted, and no live Apple service has been tested.
- Anisette stage 3 is disabled.
- No real credentials have been requested.

The experiment runs only after the owner separately approves it, and after G1–G6 are complete. Each gate is approved on its own. The step-by-step procedure is in `SUPERVISED-EXPERIMENT-SEQUENCE.md`.

## Where things stand

| Item | State |
|---|---|
| Device tests A, B, C and D (iPhone 15 Pro Max) | **All passed** (`DEVICE-TEST-PHASE7.md`, `PHASE7-INTEGRATION.md`) |
| RPPairing PR #25 (installed-profile reader) and Zsign-Zag PR #1 | **In `main`** through PR #27 |
| `main` | `bcf30a9f`, with Zsign pinned to `f34e51a` |
| Validation of `main` | **All 44 `scripts/test-zag-*.sh` suites and the package guard (15 checks) passed** |
| Live Apple services | **Not tested.** Nothing has signed in to Apple, called the developer portal or fetched anisette data. |
| Keychain-backed signing for the experiment | Draft PR #28 (compiled only with `ZAG_ZSIGN_STRICT`) |
| Bridge to `zag-isideload` | Draft bridge PR, stacked on PR #26 (network compiled out; tested only against a scripted backend) |
| `zag-isideload` fork | PR #26, draft and unmerged until the independent licence review (G2) |

## Smallest path: one simple IPA without extensions

The target is one app: a tiny test app with no extensions, frameworks or capabilities beyond the defaults. It is installed once on the owner's iPhone 15 Pro Max, under a **dedicated** free Apple Account (G6), signed in through the Debug-only sign-in screen in a separately named test build (G5).

| Step | Existing component | State | Left for the experiment |
|---|---|---|---|
| 1. Apple Account sign-in (password and 2FA used only in memory) | `ZagFreeAccountAuthenticator` → `ZagIsideloadAuthenticationService` → bridge → `zag-isideload` `auth/` | Bridge written; mock-tested (2FA, cancellation, deadline, expired session, network failure, account switching) | `live` enabled **only** in the experiment build; the anisette provider from G3 |
| 2. Personal Team | Team listing through the bridge | Mock-tested | Confirm how Apple describes a Personal Team (the bridge reports `unknown`, so the free limits apply) |
| 3. Development certificate | `ZagKeychainSigningKeyFactory` (PR #28): a non-extractable Keychain key; the certificate is checked by proof of possession | Tested end to end with a test authority | Certificate request through the bridge |
| 4. Device registration | `ZagIsideloadDeveloperPortal.registerDevice` | Mock-tested | The device's identifier comes from the existing pairing (never logged; the push guard blocks real UDIDs) |
| 5. App ID and provisioning profile | `registerAppID`, `profile(for:)`, `ZagProvisioningProfileCheck` | Mock-tested; profile checks unit-tested | App ID under a Zag Store-specific prefix, counted against the free limits (10 App IDs per 7 days, 3 apps per device) |
| 6. Signing | `ZagFreeAccountSigningAdapter.signWithKeychainKey` → Zsign `signComponents` with the Security-framework callback | Zsign `f34e51a` in `main`; Keychain path tested (PR #28); real-certificate signing passed in B and C | Only in the experiment build (`ZAG_ZSIGN_STRICT`) |
| 7. Installation | RPPairing install (existing pairing; Zag Store's own installer) | Production; D passed | None |
| 8. Read-back | Installed-profile reader (PR #25, in `main`) and `ZagInstalledProfileCheck` | Device test A passed | Confirms that the installed profile matches the one used to sign |
| 9. Sign-out | Revocation and Keychain inventory (G1 amendment b) | Simulated and device-tested | The Keychain inventory after sign-out shows only the expected items |

**Multi-account.** Every step is keyed by account ID and team. The bridge gives each account its own slot and refuses another account's session. A second account is not part of the first experiment.

## G1–G6: separately gated

| Gate | Evidence | State |
|---|---|---|
| **G1 Proposal** | `LIVE-AUTH-REVIEW-PROPOSAL.md`, `LIVE-AUTH-GATE-RECOMMENDATIONS.md`, `SUPERVISED-SIGN-IN-PLAN.md`, this path, `SUPERVISED-EXPERIMENT-SEQUENCE.md` | **Open:** the owner's approval of the experiment, with amendments (a) and (b) |
| **G2 Licence** | PR #26; `G2-LICENCE-REVIEW.md` (bridge PR): reproducible provenance, MPL-2.0 obligations, the Sideloader-reference question | **Open:** independent licence review |
| **G3 Anisette** | Study running; stage 3 disabled | **Open:** the study ends 25 Nov; then the provider decision and the stage 4 privacy review |
| **G4 Code review** | Bridge (draft PR), PR #28; `G4-SECURITY-REVIEW.md` (destinations, credentials, isolation, logging, TLS, failures, gates) | **Open:** independent security review (the implementation's author's own review does not count) |
| **G5 Test build** | Separately named Debug IPAs built four times without touching the canonical IPA (sign-in test; A/B/C; D) | **Open:** the experiment build (bridge with `live`, `ZAG_ZSIGN_STRICT`, live switches) is **not** built. It needs G1–G4 first. |
| **G6 Account readiness** | None yet | **Open:** the owner creates a dedicated Apple Account (no payment method, recovery confirmed); never the personal account |

**Outstanding before the experiment, besides the gates:** the extension test. It needs per-extension profiles, so it is deferred until after the first single-app installation.
