# The first live free-account installation: smallest path and gate evidence

Status 18 November 2026: **prepared, not approved, nothing live.**
- No Apple endpoint has been contacted.
- Anisette stage 3 is disabled.
- No real credentials have been requested.

The experiment runs only after the owner separately approves it, and after the gates below are complete.

## Smallest path: one simple IPA without extensions

The target is one app: a tiny test app with no extensions, frameworks or capabilities beyond the defaults. It is installed once on the owner's iPhone 15 Pro Max, under a **dedicated** free Apple Account (G6), signed in through the Debug-only sign-in screen in a separately named test build (G5).

Most of the steps already exist behind their disabled live implementations. The work left is the bridge from those Swift services to the trimmed `zag-isideload` (PR #26), plus the approved anisette provider.

| Step | Existing component | State | Left for the experiment |
|---|---|---|---|
| 1. Apple Account sign-in (password and 2FA used only in memory) | `ZagFreeAccountAuthentication`, `ZagFreeAccountSignInModel`, Debug sign-in screen (device-tested with the simulation, 18 Nov) | Live service disabled | Bridge to `zag-isideload` `auth/`, with `live-network` enabled **only** in the experiment build; anisette provider from G3 |
| 2. Personal Team | `ZagAppleAccounts` (per-account directory and session in the this-device-only Keychain) | Simulated | Team listing through the bridge (`dev/teams`) |
| 3. Development certificate | `ZagFreeAccountProvisioner`, `ZagSigningKeyFactory` / `ZagKeychainSigningKey` (key generated on device, non-extractable) | Disabled factory in Release; Keychain key tested | Certificate request through the bridge; the issued certificate is checked against the Keychain key (`check`) |
| 4. Device registration | `ZagDeveloperPortalService.registerDevice` | Disabled | The device's identifier comes from the existing pairing (never logged; the push guard blocks real UDIDs) |
| 5. App ID and provisioning profile | `registerAppID`, `profile(for:)`, `ZagProvisioningProfileCheck` | Disabled; checks unit-tested | Bridge; App ID under a Zag Store-specific prefix, counted against the free limits (10 App IDs per 7 days, 3 apps per device) |
| 6. Signing | `ZagFreeAccountSigningAdapter` → Zsign strict path (`signComponents`) | Zsign branch: real-certificate signing and verification pass with a non-extractable key (B/C in `DEVICE-TEST-PHASE7.md`); on-device launch pending | The production Zsign pointer moves only with the owner's approval |
| 7. Installation | RPPairing install (existing pairing; Zag Store's own installer) | Production | None |
| 8. Read-back | `ZagInstalledProfileCheck` + installed-profile reader (PR #25) | Device test A pending | Confirms the profile actually installed matches the one used to sign |
| 9. Sign-out | Revocation and Keychain inventory (G1 amendment b) | Simulated and device-tested | Keychain inventory after sign-out shows only the expected items |

**Multi-account.** Every step is keyed by account ID and team. `zag-isideload` keeps each `AppleAccount` independent, with storage supplied per caller. A second account is not part of the first experiment.

## G1–G6 checklist with the evidence so far

| Gate | Evidence gathered | State |
|---|---|---|
| **G1 Proposal** | `LIVE-AUTH-REVIEW-PROPOSAL.md`, `LIVE-AUTH-GATE-RECOMMENDATIONS.md`, `SUPERVISED-SIGN-IN-PLAN.md`, and this smallest path | **Incomplete:** the owner's approval of this experiment, with amendments (a) and (b) |
| **G2 Protocol source** | Trimmed, hardened fork, PR #26 (network compiled out, 15 checks pass), `PROVENANCE.md` with per-file evidence and the dependency inventory | **Incomplete:** independent licence review (four files marked MPL-2.0 pending review; the Sideloader-reference question for `dev/`) |
| **G3 Anisette** | Study running, stage 3 disabled | **Incomplete:** the study ends 25 Nov; then the provider decision and the stage 4 privacy review |
| **G4 Code review** | Checklist in `SUPERVISED-SIGN-IN-PLAN.md`; fork hardening (no logging, no insecure TLS, allowlist, zeroised password buffers) | **Incomplete:** the bridge is not written yet; then a reviewer independent of the implementation |
| **G5 Test build** | Separately named Debug IPAs built three times without touching the canonical IPA (sign-in test 18 Nov; phase 7 A/B/C) | **Partly ready:** the experiment build itself (bridge + `live-network`) does not exist yet |
| **G6 Account readiness** | None yet | **Incomplete:** the owner creates a dedicated Apple Account (no payment method, recovery confirmed); never the personal account |

**Also outstanding before the experiment** (not gates):
- device tests A, B and C;
- the extension test, which needs per-extension profiles and is therefore deferred to after the first single-app installation.
