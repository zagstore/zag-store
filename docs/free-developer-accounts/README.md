# Free Apple Developer Accounts: research, architecture and plan

Status: Phase 0 (research), Phase 1 (foundation) and the Phase 2 groundwork (see `PHASE2.md`) done on branch
`claude-free-developer-accounts`, 18 November 2026. Nothing user-visible ships
yet. The free-account method stays hidden (`ZagSigningMethodAvailability.freeAccountEnabled = false`)
until it can sign and install end to end.

Each claim below is marked with its evidence:

- **[source]**: read in the project's code, at the commit or path given.
- **[doc]**: stated in official or project documentation.
- **[claim]**: the developer says so, but there's no code to check.
- **[report]**: reported by the community.
- **[hypothesis]**: not yet tested.

Reference sources were downloaded from GitHub on 18 November 2026 and read, not built.

## A. The four reference projects

### SideStore: the main technical reference

The code is at `github.com/SideStore/SideStore` (`develop`, last pushed 7 Nov 2026) and is licensed AGPL-3.0 **[source]**.

**Apple Account sign-in and the developer portal**
- These live in `SideStore/SideSign` (pinned at `752d1ef6`) and the older `SideStore/AltSign` **[source]**.
- Sign-in uses GrandSlam: SRP-6a against `gsa.apple.com/grandslam/GsService2`.
- Two-factor authentication works with a trusted device (`/auth/verify/trusteddevice`, then `/grandslam/GsService2/validate`) or by SMS (`/auth/verify/phone/put?mode=sms`). These are in `AltSign/Sources/ALTAppleAPI+Authentication.swift` **[source]**.
- The portal calls go to `developerservices2.apple.com/services/QH65B2/` as plist POSTs:
  - teams: `listTeams.action`;
  - devices: `ios/listDevices.action` and `ios/addDevice.action`;
  - certificates: `ios/submitDevelopmentCSR.action` (and its listing);
  - App IDs: `ios/listAppIds.action`, `ios/addAppId.action`, `ios/updateAppId.action`, `ios/deleteAppId.action`;
  - app groups: `ios/listApplicationGroups.action`, `ios/addApplicationGroup.action`, `ios/assignApplicationGroupToAppId.action`;
  - profiles: `ios/downloadTeamProvisioningProfile.action` and `ios/deleteProvisioningProfile.action`.
  
  All are in `ALTAppleAPI+Operations.swift` **[source]**.
- Every response carries a `resultCode`, where 0 means success, and errors carry a `userString` or `resultString` **[source]**.
- A team is "free" when its type is `Individual` and its first membership name contains "free" (`Model/ALTTeam.swift`) **[source]**.

**Anisette**
- Every GrandSlam request and every portal request carries anisette headers:
  - `X-Apple-I-MD` (a one-time password) and `X-Apple-I-MD-M` (the machine ID);
  - `X-Apple-I-MD-LU`, `X-Apple-I-MD-RINFO`, `X-Mme-Device-Id`, `X-Apple-I-SRL-NO` and `X-MMe-Client-Info`.
  
  **[source]**
- SideStore gets them in one of two ways **[source]**:
  1. **A remote "anisette v3" server.** The default list is `servers.sidestore.io/servers.json` and the default server `ani.sidestore.io` (`SideStore/AppConstants.swift:98-99`). The device keeps its own ADI provisioning blob (`adi.pb`) in the Keychain, and the server computes the one-time password. **The server sees the device's anisette identity but not the Apple Account password.** The SRP exchange happens directly between the device and Apple.
  2. **On-device "ODA"**, from `Core/Anisette/OnDeviceAnisetteManager.swift` and `mahee96/AnisetteKit`:
     - It downloads Apple's Android ADI libraries (`libstoreservicescore.so` and `libCoreADI.so`), using metadata from `zzz.haus/oda.json`.
     - It runs them in an in-process Unicorn emulator using its interpreter backend, so it needs no JIT.
     - Provisioning still goes through a remote endpoint.

**Device connection**
- The newer code uses `minimuxer` (AGPL-3.0) plus `mahee96/RemotePairingKit` for RPPairing and CDTunnel **[source]**.
- The device reaches its own lockdown and CoreDevice services through a loopback VPN: LocalDevVPN, formerly WireGuard or StosVPN.
- The pairing file is imported once, and on iOS 27 it can be made on the device itself. **[doc]** (docs.sidestore.io pairing-file pages) **[report]**

**Refresh**
- SideStore uses three mechanisms:
  - the legacy background fetch (`application(_:performFetchWithCompletionHandler:)` in `AltStore/AppDelegate.swift:408`), which also refreshes apps when enabled;
  - a **silent audio loop** or a **background location** session to keep the app alive (`Core/BackgroundServices/`);
  - App Intents `RefreshAllAppsIntent` and `AppShortcuts`, for use in Shortcuts automations.
  
  **[source]**
- `Info.plist` declares the background modes `audio`, `fetch`, `location`, `remote-notification` and `processing` **[source]**.
- **Background fetch can run a refresh, but iOS decides if and when; nothing guarantees an unattended refresh.**

**Signing**
- `SideSign`, via `mahee96/CodeSignKit`, is a second, pure-Swift signer: Mach-O, CodeDirectory, CMS, PKCS#12 **[source]**.
- Before that, AltSign used `ldid` plus Apple's `corecrypto` sources **[source]**.
- `ResignAppOperation.swift` rewrites the bundle IDs, the extensions' IDs, and the `BGTaskSchedulerPermittedIdentifiers` **[source]**.

### Tetherless

- `github.com/pwnapplehat/TetherlessiOS` contains only a README, a Cloudflare website (`index.html`, `wrangler.jsonc`) and images. **The app's source isn't public** **[source]**.
- The README says it works on iOS 17.4 and later, with a "Modern" build for iOS 26+ and a "Legacy" build for 17.4–18.x. **[claim]** It also says:
  - free Apple Account signing requires **LocalDevVPN** plus a one-time pairing, and on-device "Pair with…" needs **iOS 27**;
  - certificates, App IDs and devices can be viewed, and certificates revoked;
  - a "Refresh All" action is provided.
- **Automatic refresh is a Shortcuts *Personal Automation*:** on a time of day, "Enable LocalDevVPN" runs, then "Refresh All Apps" **[claim]**.
  - This is the most credible route to unattended refresh: the automation runs on schedule without opening the app. **[hypothesis to verify]**
  - It still depends on the Apple session remaining valid. Tetherless says "If Apple ever signs you out, just sign in again — that one step can't be automated". **[claim]**

### AirSign (rPlay)

- There's no public source code. The only primary source found is a TestFlight listing ("Join the rPlay AirSign beta") **[doc]**.
- Free-account signing, a built-in tunnel that replaces LocalDevVPN, and iOS 27 onboarding are all **unverified**. No technical documentation was found.
- **Feasibility of a built-in tunnel:**
  - Embedding a Packet Tunnel Network Extension needs the `com.apple.developer.networking.networkextension` entitlement (`packet-tunnel-provider`) **[doc]**.
  - Free Personal Teams can't enable the Network Extensions capability on iOS. **[doc]** Apple DTS answers in developer.apple.com/forums threads 746373 and 769825 say this, referring to the "Apple Developer" column of *Supported capabilities (iOS)*; Xcode's error reads "Personal development teams … do not support Network Extensions". Still to confirm against a Personal Team profile in Phase 2.
  - So a Zag Store signed with a free account **can't** carry its own tunnel.
  - A Zag Store signed with a paid certificate could, but only if that certificate's App ID has Network Extensions enabled.
  - An app that appears to do this on a free account is probably using a separate VPN app, a profile-based VPN, or private behaviour. **[hypothesis]**

### LCSign

- `github.com/huamidev/LCSign` returns 404. The developer says their GitHub account was suspended **[report]**.
- No source was found. Look-alike projects describe themselves as "built on zsign … with certificate/profile pairing validation" (for example `Callia218/LCSignClone`) **[claim]**.
- What's worth adopting needs no source, and Zag Store already has most of it:
  - **certificate and profile matching:** `ZagCertificateImportValidation`, `ZagCertificateHealthView`;
  - **pre-signing audits:** `ZagSigningAuditView`;
  - **entitlement comparison:** `ZagEntitlementCompatibility`.
- **Loopback HTTPS install servers are not needed and will not be used.**
  - Zag Store installs over RPPairing.
  - An itms-services/HTTPS approach would need a TLS key trusted on the device, and shared keys are exactly the risk the brief forbids.

## B. Architecture decision

**Local-first (Architecture A), with one external dependency: anisette.**

Everything else happens on the iPhone:
- sign-in (SRP), two-factor authentication, the portal calls, key generation, the CSR, Zsign signing, and RPPairing installation.

The Apple Account password goes only to Apple, through the SRP exchange, and is never stored. The session token and private key stay in this device's Keychain.

**Anisette can't be produced on iOS by a sandboxed app** using Apple's own frameworks (AuthKit and AOSKit are private). The options:

| Option | Privacy | Risk | Licence |
|---|---|---|---|
| 1. Remote anisette v3 server, chosen by the user (SideStore's or self-hosted) | Server sees the device's ADI identity, not credentials | Third-party outage and trust | Nothing linked |
| 2. Zag-run anisette v3 server (Architecture B, smallest possible service) | Same, but we control it | We operate a service that emulates Apple's Android libraries | `Dadoum/anisette-v3-server` has no licence file: we'd need our own implementation |
| 3. On-device emulation (AnisetteKit) | Best | Downloads and executes Apple's proprietary Android binaries at runtime; heavy (Unicorn); App ID and legal risk | AGPL-3.0 |

**Recommendation:** start with option 1 behind a `ZagAnisetteProvider` protocol:
- the user chooses the server, with clear disclosure, and Zag Store chooses no default without your approval;
- option 2 is evaluated later only if option 1 is unreliable.

**This needs your decision before Phase 2** (see section H).

## C. What Zag Store already has, and how it's reused

| Need | Existing component | Plan |
|---|---|---|
| Signing | `ZsignHandler` (p12 + profile + entitlements; embeds profiles in extensions) | **Reuse unchanged.** The free-account key and certificate become a PKCS#12 written to a temporary file; profiles per extension are added in Phase 3. No second signer (SideSign/CodeSignKit are AGPL and duplicate Zsign). |
| Certificate storage | `CertificatePair` + `Storage+Certificate` (Core Data, `.p12` files, `getProvisionFileDecoded`) | Reuse for display and selection, plus a free-account marker. Note: the existing p12 **password is stored in Core Data in plaintext**; free-account keys don't use that path. |
| Profile parsing | `CertificateReader` (`Certificate` model: ExpirationDate, Entitlements, TeamIdentifier, ProvisionedDevices) | Reuse for expiry and entitlements of issued profiles. |
| Entitlement checks | `ZagEntitlementCompatibility` (was private in `CertificatesInfoView`) | **Moved** to `Utilities/ZagEntitlementCompatibility.swift`, byte-identical, and reused by `ZagFreeAccountEntitlements`. |
| Pairing and transport | `ZagRPPairingCore` (Rust core on `idevice`, MIT), `ZagLocalVPNMonitor`, `ZagLockdownProbe`, `ZagDeviceLink`, `ZagDeveloperModeGuidance` | Reuse unchanged for readiness checks and installation (`installGate4IPA`). `refreshInstalledApps` gives the installed list for app-slot counting and refresh verification. |
| Background work | `BackgroundTaskManager`, `ZagBackgroundTaskIdentifiers`, `BGTaskScheduler` registration in `FeatherApp.swift`, `UIBackgroundModes` audio and fetch | Reuse for best-effort refresh. **No silent-audio or location keep-alive** for refresh: misusing background modes risks the app and battery, and the existing audio mode is for its own feature. |
| BYOC | Website plugin and signing service | Unchanged. In the app it's only listed as an external method; no Apple Account data ever goes to the server. |

## D. Security and licensing

**Threat model (the assets and what protects them)**

- **Apple Account password.**
  - It's used once, for SRP, and never written to disk or the Keychain (`ZagFreeAccountSecretKind` has no password kind; this is tested).
  - The cost is that an expired session needs the user to sign in again. **Owner decision (18 November): the password is never persisted, not even as an option.**
- **Session token and DSID.**
  - Kept in the Keychain as `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronised, under service `app.zagstore.free-account.v1`.
  - "After first unlock" is needed so a background or Shortcut refresh can read it.
  - Signing out deletes every secret of the account (tested on the simulator Keychain).
- **Development private key.**
  - Apple development certificates are RSA, and Zsign needs the raw key as PKCS#12.
  - So it **can't** be a non-exportable Secure Enclave key, which is P-256 only. Zag Store must not claim Secure Enclave protection.
  - It's stored in the Keychain (same class as the session token). It's written to a temporary PKCS#12 only for the duration of a signing, and deleted afterwards (Phase 3).
- **Anisette identity.** It's per device, kept in the Keychain if the provider has state, and shared only with the server the user chose.
- **Logs and diagnostics.** `ZagSensitiveRedactor` removes:
  - email addresses;
  - `X-Apple-*`, `X-Mme-*`, Authorization and Cookie headers;
  - `myacinfo`, DSID, token and password values, including inside plists;
  - PEM blocks, and base64 or hex runs of 32 characters or more.
  
  Phase 1 code logs nothing; a test enforces this.
- **Apple service responses.** Phase 2 parsers will refuse unknown shapes as `unexpectedResponse`, which is never retried automatically, so a protocol change doesn't hammer Apple or lock the account.
- **Account risk.** Using Apple's Xcode developer services from a third-party client isn't an Apple-documented API. Apple can change it or restrict accounts. The UI must say this plainly and must not suggest Apple endorses it ("Sign in with your Apple Account", never "Sign in with Apple").

**Licensing**

Zag Store is GPL-3.0 (Feather).
- **AGPL-3.0:** SideStore, minimuxer, em_proxy, and `mahee96/AnisetteKit`, `CodeSignKit`, `GSACryptoKit` and `RemotePairingKit` **[source]**.
  - GPL-3.0 section 13 allows combining with AGPL-3.0 code, but the AGPL parts then carry their network-use source obligation.
- **No licence file:** `SideStore/AltSign`, `rileytestut/AltSign`, `SideStore/SideSign` and `Dadoum/anisette-v3-server` **[source]**. With no licence, there's no right to copy.
- Apple `corecrypto`, which AltSign vendors, has a restrictive Apple licence.
- **Decision taken in Phase 1:** no code was copied. The Apple protocol facts (endpoint names, header names, response keys) are interoperability facts and will be implemented independently.
- **Needs your approval:** linking any AGPL package, for example GSACryptoKit for SRP.
  - The alternative for SRP-6a is our own implementation on the OpenSSL that Zsign already ships (BIGNUM, PBKDF2, AES-CBC/GCM), which keeps the licence unchanged.

## E. Phase 1: what was implemented

All of it is in `Feather/Utilities/FreeAccount/`:

| File | Contents |
|---|---|
| `ZagSigningMethod.swift` | The three signing methods, their status line, and the rule that only implemented methods are listed. |
| `ZagFreeAccountState.swift` | Team model (free, paid, organisation, unknown → strictest limits); a session summary with no secrets and a masked Apple ID; two-factor methods; failures with a human message, a recovery action and whether retrying is sensible; a sign-in state machine that rejects impossible transitions. |
| `ZagFreeAccountProvisioning.swift` | Apple's published free limits, with source and date. Capacity is either "from Apple" or "unknown", never invented. The rest: deterministic bundle-ID, extension and app-group mapping; App ID planning (reuse, register, or exhausted with when the next slot frees, never revoking); certificate planning (reuse a valid certificate whose key is on this device, create one, or ask the user to revoke one); device registration; the 3-app install slots, where refreshing an installed app needs no slot. |
| `ZagFreeAccountEntitlements.swift` | Entitlements from the app's request, rewritten for the team (application identifier, team ID, keychain groups, app groups) and kept only if the profile allows them. Each one left out is reported. |
| `ZagFreeAccountRefresh.swift` | Urgency from the real profile and certificate expiry. Days 1–3 normal, 4 eligible, 5 recommended, 6–7 urgent for 7-day profiles; thresholds scale for shorter profiles and are configurable. Reminder dates. The refresh ledger. |
| `ZagFreeAccountSecretStore.swift` | Keychain secret store and log redaction. |

The refresh ledger gives:
- one refresh per app at a time;
- success only when the installed expiry is later than before;
- interrupted refreshes recorded as failures after a relaunch;
- backoff from 1 minute up to 6 hours;
- failures that need the user are not retried automatically until the cause is resolved;
- Refresh All ordering.

## F. Test evidence

- `scripts/test-zag-free-account-foundation.sh`: **96 checks plus 3 source checks**, compiled with `-warnings-as-errors`. The source checks confirm there are no network calls or logging, no free-account UI, and only one entitlement matcher.
- `scripts/test-zag-free-account-keychain.sh`: **9 checks** in a throwaway iOS Simulator app against the real iOS Keychain:
  - accessibility class is after first unlock, this device only;
  - nothing is synchronised;
  - items are replaced in place;
  - signing out removes only that account's secrets;
  - no items are left behind.
- A Release iOS build of the whole app with the new files (`xcodebuild … CODE_SIGNING_ALLOWED=NO build`).

**Not tested, because there is nothing to test yet:**
- every Apple interaction;
- anisette;
- signing with an issued profile;
- installing;
- background and Shortcut execution.

## G. Compatibility matrix

| | iOS 16.4–16.x | iOS 17.0–17.3 | iOS 17.4–18.x | iOS 26 | iOS 27 |
|---|---|---|---|---|---|
| Free-account sign-in and provisioning (network only) | yes [hypothesis] | yes [hypothesis] | yes | yes | yes |
| Install transport | lockdown pairing over loopback VPN (Zag Store targets 16.4: needs verifying with the RPPairing core) | RPPairing + CoreDevice tunnel | RPPairing (LocalDevVPN) | RPPairing (LocalDevVPN) | RPPairing; on-device pairing reported [report] |
| Pairing file | from a computer | from a computer | from a computer | from a computer | on device (Settings › Developer Mode) [report] |
| Developer Mode required | no | yes | yes | yes | yes |
| Built-in tunnel without LocalDevVPN | no (Network Extension entitlement not available to free teams) | no | no | no | no |
| Background refresh | best effort | best effort | best effort | best effort | best effort |
| Shortcuts automation | iOS 16 App Intents available | yes | yes | yes | yes |

## H. Roadmap and the shortest route to a beta

**Decisions needed before Phase 2:**
1. Anisette source: option 1 (user-chosen server), option 2 (we host one), or option 3 (on-device, AGPL).
2. SRP: our own implementation on the bundled OpenSSL (recommended, keeps the licence), or link GSACryptoKit (AGPL).
3. Whether storing the Apple Account password in the Keychain may ever be offered (default: never).

**The phases:**

**Phase 2 — sign-in and provisioning (biggest risk).** Build on a test Apple Account owned by you:
- `ZagAnisetteProvider`;
- the GrandSlam SRP client and two-factor authentication;
- the portal client: teams, devices, certificate CSR (RSA 2048 generated on the device), App IDs, app groups, profiles.

It must be validated against Apple's real responses; mocks alone don't count.

**Phase 3 — signing.**
- PKCS#12 from the key and the certificate.
- Bundle-ID rewrite in `SigningHandler` (it already rewrites the plugin IDs).
- A profile per extension.
- `ZagFreeAccountEntitlements`.
- Verification with the existing `ZagMachOSignatureInspector`.

**Phase 4 — installation.**
- Readiness from `ZagRPPairingCore` and `ZagLocalVPNMonitor`, install with `installGate4IPA`, then verify the result with `refreshInstalledApps`.
- Then turn on `freeAccountEnabled` and add the UI under Settings › Signing Options. Phases 2–4 make a usable beta.

**Phase 5 — refresh.**
- Refresh one app, Refresh All, and self-refresh (the existing self-update verification and rollback protections apply).
- Local notifications from `reminderDates`.
- App Intents "Refresh All Apps" for a Shortcuts automation after "Enable LocalDevVPN".
- BGTask best-effort refresh.
- Copy that never promises a refresh while locked.

**Phase 6 — built-in tunnel research.** Only with paid-team signing and the Network Extension entitlement, isolated from production.

**Phase 7 — finishing.** Accessibility, performance, security audit, device matrix, documentation.

**Risks:**
- Apple changes GrandSlam, anisette or the portal protocol.
- Account restrictions on accounts used this way.
- Anisette server availability.
- A free account's 3-app limit: Zag Store itself uses one slot if it's signed with the same account.
- iOS 16 transport support in the RPPairing core.

**Phase 7 working documents (18 Nov 2026).**
- `FIRST-LIVE-EXPERIMENT.md`: the smallest path to the first supervised free-account installation, and the G1–G6 evidence.
- `SUPERVISED-EXPERIMENT-SEQUENCE.md`: the supervised live experiment step by step, its stop rules, and what is required before the first live sign-in.
- `GATES-APPROVAL.md`: the remaining G1–G6 decisions, who makes each one, and the exact evidence each requires.
- `DEVICE-TEST-PHASE7.md`: the installed-profiles (PR #25) and Zsign branch device tests.
- `WEBSITE-INSTALL-FEASIBILITY.md`: installing from zagstore.app with a visitor's free account.
- The trimmed isideload fork and its provenance evidence: PR #26, `AppleAuthCore/zag-isideload/PROVENANCE.md`.

**G4 working documents (19 Nov 2026; not reviewed).**
- `G4-SECURITY-REVIEW.md`: the bridge (`AppleAuthCore/zag-apple-bridge`) for the independent security review. Covers network destinations, the credential lifecycle, session isolation, logging, TLS, failure handling and feature gates.
- `G2-LICENCE-REVIEW.md`: the reproducible licence-review package for the retained isideload sources (`scripts/zag-g2-reproduce.sh`).
