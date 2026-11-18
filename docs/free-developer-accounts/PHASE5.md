# Free and paid Apple Accounts: multi-account, strict signing and installation prep

Status, 18 November 2026. Draft PR #24, plus the Zsign draft PR zagorskey/Zsign-Zag#1.
- Nothing here is live.
- AppTesters signing, certificate import and RPPairing are unchanged, and the Zsign submodule pointer is unchanged (`ab57916`). A test checks both against the base branch.

## 1. Multi-account

See `MULTI-ACCOUNT.md`.

## 2. Zsign feature branch (not merged, pointer not moved)

Branch `zag-free-account-signing` in `zagorskey/Zsign-Zag`, draft PR #1.

| Problem | Fix |
|---|---|
| Reported "Signed OK!" with no CMS signature | A CMS failure fails the binary. Failed libraries and unparseable executables fail the bundle. Every signed binary is verified before success is reported. |
| Chain chosen by issuer-name hash | The intermediate is chosen by verifying the certificate's signature with its key. Strict mode also requires the certificate to be valid now and to allow code signing. The key must match the certificate, cryptographically. |
| Extensions given the main app's profile and entitlements | `ZagSignComponents`: the app and each extension, each with its own profile and entitlements. Extensions are signed before the app, and the app's seal covers them as signed. |
| No checks per component | Before anything changes, each component is checked for: team, certificate in its profile, App ID (with wildcards), entitlements allowed by the profile, extension ID prefixed by the app's, and profile not expired. |
| Key must be a file | Keys from memory, or a raw signer callback (see `SIGNING-KEY-SECURITY.md`). |

**Explicitly refused:**
- Apple Watch apps (`Watch/`);
- App Clips (`AppClips/`);
- XPC services;
- nested apps;
- extensions inside other bundles;
- test bundles;
- extensions without a profile.

Frameworks and libraries are signed with the app's identity and no entitlements.

**Output verification** (`ZagVerifyComponents`, also usable on its own):
- CMS signature by the identity's certificate over the code directory;
- every page hash, including alternate SHA-256 code directories;
- team and identifier;
- exact entitlements;
- sealed `Info.plist` and `CodeResources`;
- embedded profile per bundle.

**Tests:**
- `Zsign/test/zag/run-tests.sh`: 47 synthetic checks.
- `scripts/test-zag-zsign-branch.sh` runs them from a `git archive` of the branch.
- It also checks that the real AppTesters certificate in the canonical IPA (public data only) is accepted, verified against Apple's WWDR G3.

**Behaviour changes for the existing AppTesters path, to review before approval:**
1. A certificate that Apple's WWDR (G3 or the original) did not actually issue now fails when it loads. The pinned version accepted it and then produced an unsigned app.
2. An app containing a library that cannot be signed now fails instead of "succeeding".
3. The main repo's signing tests use a test authority that is only *named* like WWDR. After the pointer moves, they must pass that authority as an extra intermediate through the strict API.

**Not yet supported:** Watch apps, App Clips, XPC services, ExtensionKit-specific requirements beyond per-bundle profiles, and entitlement *value* checks (only key presence is checked against the profile).

## 3. Production signing path (behind a closed gate)

- `ZagFreeAccountSigningAdapter`, `ZagFreeAccountLifecycle` and `ZagZsignCodeSigner` are now production code, gated by `ZagFreeAccountSigningGate`.
  - `.production` is closed: `ZagFreeAccountSigning.isEnabled = false`.
  - The open gate (`.simulationOnly`) exists only in Debug builds.
  - The Release binary scan confirms no simulation, open gate or synthetic accounts.
- The lifecycle checks, in order:
  1. it asks the directory for an authorisation (signed in, unexpired, the app's own scope);
  2. it provisions with team-kind limits;
  3. it loads that scope's identity;
  4. it signs, then installs;
  5. it verifies with the installer, recording the owner, certificate serial and profile UUID.
- An expired, signed-out or removed account cannot trigger signing.
- `ZagRefreshLedgerStore` is the on-disk store:
  - atomic JSON, excluded from backup;
  - interrupted refreshes are marked on launch;
  - a corrupt file is kept aside, never overwritten.
- `schedule(at:)` gives each app's refresh time (after backoff), its reminders, and whether it waits for the user.

## 4. Installation and read-back

- `ZagRPPairingFreeAccountInstaller` packages the signed app as an IPA, exactly as `ArchiveHandler` does, and calls the existing `installGate4IPA`. RPPairing is not modified.
- **Read-back today.** RPPairing's app list gives bundle ID, version, build and signer, but not the profile or its expiry. So `verify` returns `.unverifiable` at best (`.mismatch` if the signer differs). The lifecycle then records the install as `installedUnverified`, and a refresh as `notVerified`, never as successful.
- **Reliable read-back needs** the idevice `misagent` service (list installed profiles: UUID and expiry). The crate already contains it, but RPPairing's build excludes it. Enabling it changes RPPairing's build, so it needs your approval.

## 5. Blockers to the first real free-account installation

1. Live sign-in: gates G1 to G6; see `LIVE-AUTH-GATE-RECOMMENDATIONS.md`.
2. Anisette: the study ends 25 Nov 11:54 GMT; stage 3 is unapproved.
3. The live developer portal: needs the protocol source from G2.
4. Expiry read-back: `misagent` in RPPairing (approval).
5. The Zsign branch: review, approval and the pointer update. This is needed for extensions, no key export and verified output. Ordinary apps already work with the pinned Zsign through the temporary key file.
6. Account UI (Liquid Glass) on top of the directory, and wiring a gated entry point.
7. One supervised experiment with the dedicated test account, after explicit approval.

## Update, 18 November 2026 (owner decisions 1 to 5)

**Zsign (zagorskey/Zsign-Zag#1, head `59020d3`; not merged; pointer still `ab57916`)**
- Each entitlement value is checked against the component's own profile:
  - App ID and team;
  - keychain groups within the team;
  - app groups listed and named `group.*`;
  - push environment, iCloud containers and associated domains;
  - booleans such as `get-task-allow`;
  - unsupported value kinds are refused.
- Profiles must have entitlements, an App ID and an expiry.
- The certificate's issuer must be a valid certificate authority.
- 83 synthetic checks.

**Behaviour changes for AppTesters, if the pointer is moved:**
1. A certificate not cryptographically issued by Apple WWDR now fails with a clear error, before the app is changed. It used to produce an unsigned app reported as signed.
2. An unsignable library fails the signing.

Unchanged and tested:
- PKCS #12 files, modern and legacy RC2, still load.
- Certificate import's revocation check answers exactly as before.
- The canonical IPA's real certificate is accepted.

A positive end-to-end AppTesters signature needs a real certificate with its key, which was not used.

**Integration (isolated):** `signComponents` signs an app with an extension through a Security framework key. It is compiled only with `ZAG_ZSIGN_STRICT`, and covered by 14 checks run against the branch.

**RPPairing read-back (PR #25, draft, separate branch):**
- `zag_installed_profiles` reads the device's installed profiles through misagent. It is read only.
- `ZagInstalledProfileCheck` (on this branch, 8 checks) verifies only an exact match: the embedded profile's UUID, team, App ID and expiry, plus each extension's profile.
- Until #25 is approved, installs remain "not verified".
- Not yet run on a device. Whether misagent lists free-account profiles on current iOS must be confirmed on the owner's device.

**Accounts UI (Debug only):** Settings > Experimental Features > Apple Accounts (Simulated). `test-zag-apple-accounts-ui.sh` runs 11 in-app checks.

**G2:** see `ISIDELOAD-EVALUATION.md` and `SUPERVISED-SIGN-IN-PLAN.md`.
