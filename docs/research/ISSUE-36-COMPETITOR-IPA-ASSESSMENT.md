# Issue #36: competitor IPA findings for anisette, LocalDevVPN, iOS 27 pairing and Apple auth

**Date:** 19 November 2026. **Author:** Claude (implementer of the free-account work, so this is not independent). **Status:** research only. Nothing here changes code, feature gates, the network allowlist, signing services, releases or websites. G4 approval stays with GPT-6.

**Inputs:**
- GPT-6's `ZagStore_Competitor_IPA_Technical_Review_2026-11-19.md` and `ipa_inventory.json`, supplied by the owner.
- Five of the six IPAs, re-examined offline on this Mac. `LCSign-1.4-6.ipa` was not available here, so every LCSign statement below is GPT-6's and unverified by me.
- Zag Store's own repository: `main` `5beb0801`, and the frozen free-account head `c6ce0750` (#29).

**Evidence tags:**
- **[archive observed]**: read from the IPA (Info.plist, entitlements, extension metadata, literal strings). A string proves the code is in the binary, not that it runs or works.
- **[public source]**: published documentation or source, including Zag Store's own repository (cited by file and commit).
- **[hypothesis]**: an inference not yet checked.
- **[live test needed]**: only a controlled, owner-approved experiment can settle it.

## 1. Answer in brief

The three outcomes #36 asks about:

| Question | Answer |
|---|---|
| (a) Reduce dependence on a third-party anisette provider? | **Not cheaply, and not safely for the first experiment.** SideStore's "on-device anisette" is not self-contained: it downloads a package from a third-party host (`zzz.haus`) and runs Android ELF libraries inside a bundled Unicorn CPU emulator (§3.2). Its dependence moves from one third party to another, it executes downloaded native code, and it raises a redistribution question about Apple's binaries. Keep the remote v3 provider for the first experiment, gated by G3. A Zag-operated v3 server is the realistic later route to removing the third party (§3.4). |
| (b) Use the existing external LocalDevVPN with Zag Store on iOS 27? | **Zag Store already does.** Every direct installation in today's releases goes through LocalDevVPN and on-device RemotePairing. This has been demonstrated on an iPhone 15 Pro Max running iOS 27.2 (§4.1). The free-account installer reuses that same installer unchanged. No VPN extension is needed for the first experiment. |
| (c) Simplify pairing? | **Already done; there is nothing to adopt from Tetherless.** Tetherless's iOS 27 "Pair with…" flow advertises the same Bonjour service (`_remotepairing-pairable-host._tcp`) that Zag Store already ships for iOS 17 and later (§4.2). |

**Fastest safe route (§7):** the first free-account sign-and-install experiment is blocked only by the Apple side: G2 licensing, G4 approval, the G3 provider decision (its study ends 25 Nov), and owner authorisation. It is not blocked by transport or pairing. The experiment can reuse the existing pairing, LocalDevVPN and installer without changes. The installed profile can be read back with the misagent reader already in `main` (PR #25 through #27, device test A passed), using the Debug-only Installed Profiles screen. *(Corrected 19 Nov; see §10.)*

## 2. Verification of GPT-6's report

I re-checked the five IPAs present in `~/Downloads`. They were extracted to a scratch directory and inspected with `unzip`, `plutil`, `codesign -d` and `strings`. Nothing was executed.

| Claim | Result |
|---|---|
| SHA-256 values, embedded versions and minimum iOS for SideStore, Tetherless Modern and Legacy, AltStore Classic and ESign | **Match.** The local AltStore file is named without "(1)" but has the same hash. [archive observed] |
| No IPA includes a VPN or Network Extension | **Confirmed** for all five. The only extensions are WidgetKit widgets in SideStore and AltStore. [archive observed] |
| Entitlements | Tetherless (both variants): `get-task-allow` only. SideStore: no entitlements blob was readable with `codesign`. AltStore: application-identifier, aps-environment, siri, team-identifier, app groups and get-task-allow. ESign: application-identifier, team-identifier and get-task-allow. None has a Network Extension entitlement. [archive observed] |
| SideStore strings: `OnDeviceAnisetteManager`, `AnisetteKit`, `adi.pb`, `ani.sidestore.io`, `servers.sidestore.io`, `localdevvpn://`, the "lockdown protocol on iOS 26.4+" warning, minimuxer and misagent | **All present.** [archive observed] |
| Tetherless strings: "On-device pairing needs iOS 27", Start Pairing, RemoteXPC, installation_proxy, `anisette.ipaside.com`, GsService2, start/finish machine provisioning, `auth.itunes.apple.com`, `RefreshAllAppsIntent` | **All present in Modern**, and the checked subset is also present in Legacy. [archive observed] |
| AltStore: "Remote AltServer requires LocalDevVPN" | **Present.** [archive observed] |
| ESign has no Apple Account or anisette path | **Consistent:** 0 hits for `gsa.apple.com` and `anisette`, and 50 hits for `umeng`. [archive observed] |
| LCSign (ZSign, embedded PKCS#12, MobileGestalt entitlement) | **Not verified.** The IPA isn't on this Mac. |

**Three findings GPT-6's report does not include, each of which changes a conclusion:**

1. SideStore's on-device anisette downloads its engine from a third-party host and emulates Android libraries (§3.2).
2. Tetherless's `auth.itunes.apple.com` strings sit with App Store purchase and download code, not developer signing code (§5.2).
3. Zag Store already ships the external-LocalDevVPN transport and the self-pairing approach that #36 asks about (§4).

## 3. Anisette (G3)

### 3.1 How Zag Store's current design works

From `c6ce0750` `AppleAuthCore/zag-isideload/src/anisette/remote_v3/mod.rs`. [public source]
- **Provider:** a remote v3 provider whose https/wss host is supplied by the caller and is the client's only allowed anisette host (`net_policy.rs`).
- **Provisioning:**
  - The device opens `wss://<provider>/v3/provisioning_session`.
  - The device itself calls Apple's `midStartProvisioning` and `midFinishProvisioning`. These URLs come from the GsService2 lookup and are policy-checked against `gsa.apple.com`.
  - The device relays `spim`, `cpim`, `ptm` and `tk` between Apple and the provider.
  - The provider returns `adi.pb`, which Zag Store stores per scope.
- **Each sign-in:** `POST /v3/get_headers` with the client identifier and `adi.pb`.
- **What the provider never receives:** the Apple Account name, password or 2FA code.
- **What the provider does receive:** a stable client identifier, the machine-provisioning state, the device serial Zag Store chooses to report, the client's IP address and the request timing. [hypothesis: correlation is possible from these]

**G3 study status.** I ran `scripts/zag-anisette-study.sh report`, which is local and makes no network request. Provider `ani.sidestore.io`:
- 42 probes, 100% available;
- latency median 1.03 s, p95 4.25 s;
- one leaf certificate, expiring 4 Dec 2026.

The study is on day 2 of 7, so there is no verdict until 25 Nov. Its p95 latency is under the 5 s threshold, but its median is under 1.5 s only narrowly. Stage 3 (live anisette requests) is still not approved.

### 3.2 What SideStore's "on-device anisette" actually is

[archive observed] Strings in the SideStore 0.7.0 executable:
- `[AnisetteProvider] Fetching anisette via On-Device Anisette (ODA)...`
- `https://zzz.haus/oda.json`, `Failed to download On-Device Anisette package`, `Failed to decompress On-Device Anisette archive`, `Downloaded On-Device Anisette payload is not valid Base64 data`
- `[Emulator] Loading ELF library '%s'`, `Invalid ELF magic or not 64-bit ELF`, `Calling DT_INIT_ARRAY`, `uc_open()`, and Unicorn and QEMU source paths, including `qemu/tcg/tci.c` (QEMU's interpreter, which needs no JIT)
- `ADILoadLibraryWithPath`, `ADISetAndroidID`, `ADIProvisioningStart` and `ADIProvisioningEnd`, plus `__android_log_print`
- `Native adi.pb missing. Starting automatic local provisioning...`, `Fetching provisioning URLs from Apple lookup...`, `Sending CPIM to Apple finish provisioning...`
- no `.so`, `.apk` or ADI files in the IPA itself

[hypothesis] SideStore downloads Apple's Android anisette libraries at run time from `zzz.haus` and runs them under emulation on the iPhone, then provisions directly with Apple. This would remove the anisette server from every sign-in, but:

| Concern | Assessment |
|---|---|
| Third-party dependency | It moves rather than disappears: the code now comes from `zzz.haus` instead of the headers coming from `ani.sidestore.io`. A compromised package host delivers native code that runs inside the app. That is a worse failure mode than a compromised header server, which only returns data. |
| Licensing | The emulated libraries are Apple's proprietary Android binaries. Downloading and running them raises a redistribution and terms question that G2 must answer. SideStore's integration is AGPL-3.0 and SideSign's is GPL-3.0, so we cannot copy them (§6). |
| Security posture | Executing downloaded native code conflicts with Zag Store's deny-by-default network design. It would need a new allowed host, a pinned hash or signature for the package, and an interpreter running untrusted input in-process. |
| Reliability | GPT-6 links SideStore issues #1450 and #1458, which report provisioning races and failures (reported upstream, not reproduced here). Performance of an interpreted emulator on device is unknown. [live test needed] |
| Privacy | Better on one axis: no provider sees each sign-in. Apple still sees the device's IP address and the machine-provisioning state. |

**Recommendation:** do not pursue on-device emulation for the first experiment. Revisit it only if G2 clears the binaries' provenance and a pinned, owner-hosted package is possible.

### 3.3 Tetherless

[archive observed] `https://anisette.ipaside.com`, `AnisetteRemoteClient`, `anisette-identity.json`, `amdAnisetteHeaders`, and `anisette get_headers failed`. This is a remote provider, the same model as Zag Store. Also present: `https://anisette.ipaside.com/loopback.p12`. [hypothesis] Tetherless downloads a PKCS#12 identity from its anisette host, purpose unknown. Zag Store must never fetch signing or TLS identities from a third party. This is noted only as an anti-pattern.

### 3.4 Options for G3

| Option | Third party sees | Code we run | Licence | Maintenance | First experiment? |
|---|---|---|---|---|---|
| **A. Public v3 provider** (current design; `ani.sidestore.io` under study) | identifier, `adi.pb`, serial, IP, timing | our MPL/MIT client only | MPL-2.0 files already marked (`PROVENANCE.md`) | provider's uptime; Apple-side changes are the provider's problem | **Yes, after G3** |
| **B. Zag-operated v3 server** (e.g. a self-hosted open-source v3 server) | nobody outside Zag; Zag's server sees what A's provider sees | the same client; a new server to run | the server's own licence, plus the Apple-library question moving to our server | ours: hosting, updates and security | No. Possible later, as a G3 decision |
| **C. On-device emulation** (SideStore ODA) | the package host sees downloads; nothing at sign-in | an emulator plus downloaded Apple ELF libraries in-process | unresolved (Apple binaries; AGPL/GPL integration) | high | **No** |
| **D. Bring your own provider URL** | whoever the user chooses | same as A | same as A | the user's | Not yet; settings UI only after G3 |

**Recommendation:** A for the first experiment, with one anisette state per account. Still an open G4 §10 question 3, but it is the safer default for correlation. Plan B as the route to removing the third party. Reject C for now.

**G3 acceptance criteria (proposed):**
1. The study report on 25 Nov meets the documented thresholds.
2. A stage 4 privacy review (desk only) is recorded.
3. The owner chooses the provider URL and the device serial policy.
4. A decision on per-account anisette state.
5. Stage 3 approved or explicitly declined in writing.

## 4. Installation transport and pairing (G5)

### 4.1 Zag Store already uses an external LocalDevVPN

[public source: Zag `main` `5beb0801`]
- `HOW_IT_WORKS.md` and `docs/INSTALL.md`:
  - LocalDevVPN loops traffic back to the device's own services at `10.7.0.1`.
  - Zag Store runs Pair-Verify with saved credentials, then a TLS-PSK tunnel, then RSD.
  - It uploads with AFC to `PublicStaging` and installs through `installation_proxy`.
- `Feather/Utilities/ZagLocalVPNMonitor.swift` and `ZagLockdownProbe.swift`:
  - three-layer tunnel status;
  - a connect-only check of `10.7.0.1:49152`;
  - a legacy lockdown query used only as diagnostic evidence ("the RPPairing transport does not use this port").
- `Info.plist`: `LSApplicationQueriesSchemes = [localdevvpn]`, and `NSBonjourServices = [_remotepairing-pairable-host._tcp]`.
- The free-account installer, `ZagFreeAccountRPPairingInstaller.swift`, calls the existing `installGate4IPA` "exactly as the Library and Settings installs call it". It is closed while the free-account gate is closed.
- Device evidence: `docs/IPA-SIZE-INVESTIGATION-2026-11-03.md` records in-place installs that launch on a paired iPhone 15 Pro Max running iOS 27.2.

So the "external LocalDevVPN instead of our own VPN extension" question is already settled in production. The open questions are narrower:

| # | Question | Tag | How to settle |
|---|---|---|---|
| T1 | Does a free-account-signed app install through the same path? | [live test needed] | §7, step 5. `installation_proxy` validates the embedded profile, which should not depend on the transport. |
| T2 | SideStore warns that "LocalDevVPN may not support the lockdown protocol on iOS 26.4+". | [archive observed] warning; [hypothesis] it concerns the legacy lockdown port (62078) that SideStore's minimuxer uses. Zag uses RPPairing and RSD on iOS 17+, and its iOS 27.2 installs work. | No action for iOS 17+. Zag's legacy pairing-file path covers only iOS 16.4–16.7, where the warning doesn't apply. |
| T3 | Mobile data | [public source] Zag already detects "connection refused" with Mobile Data on, and has the Mobile Data Toggle Shortcut flow. | Unchanged. |
| T4 | Reading the installed profile and its expiry | [public source] **Already possible:** the RPPairing `misagent` reader (PR #25) is in `main` through PR #27 (`bcf30a9f`), and device test A passed (`DEVICE-TEST-PHASE7.md`). The free-account installer's own `installedProfiles` hook is not wired, and its comment saying #25 is a draft is out of date. *(Corrected; see §10.)* | Verify through the Debug-only Installed Profiles (Read Only) screen, as `SUPERVISED-EXPERIMENT-SEQUENCE.md` step 9 does. Wire the installer hook before any automatic refresh. |
| T5 | A free account's 3-app and 7-day limits, and refresh | [live test needed] | After the first success (§7, step 7). |

### 4.2 Tetherless's iOS 27 "Pair with…"

[archive observed] Tetherless Modern:
- `NSBonjourServices = [_remotepairing-pairable-host._tcp]`, and a local-network usage string.
- `TunnelListenerHost`, `allowsPairSetup`, `allowsPinlessPairing`, `attemptPairVerify`, `CDTunnel`.
- "On-device pairing needs iOS 27 … on earlier versions, import a pairing file instead", and "check that Developer Mode is on".

[public source] Zag Store advertises the same pairable-host service and shows the six-digit SRP PIN from `IDeviceKitten/idevice/src/remote_pairing/responder.rs`. Its own docs say "iOS 17+, Developer Mode, LocalDevVPN connected" (`docs/INSTALL.md`, Beta 3 pairing docs).

**Conclusion:** Tetherless confirms the approach, but Zag Store has nothing to adopt from it. [hypothesis] Tetherless's "iOS 27" floor is probably a product choice or a feature of its own implementation, since Zag pairs this way on iOS 17+. Worth confirming only if a user reports pairing failing on iOS 17–26. One small UX idea: Tetherless names failure causes in its messages ("stale pairing", "Forget Pairing, then pair again", "LocalDevVPN probably isn't connected"). Zag's diagnostics already cover the same ground, so this is a review item, not work.

## 5. Apple authentication compatibility (for the eventual experiment)

### 5.1 Our allowlist against the competitors' strings

[public source] `c6ce0750` `net_policy.rs`:
- `APPLE_HOSTS = ["gsa.apple.com", "developerservices2.apple.com"]`, plus the one configured anisette host.
- https/wss only; no redirects; no credentials or ports in URLs.

Our fork resolves most Apple URLs from the GsService2 lookup (`gsService`, `trustedDeviceSecondaryAuth`, `validateCode`, `midStartProvisioning`, `midFinishProvisioning`), and hard-codes the SMS paths under `gsa.apple.com/auth/verify/phone`.

| Host or path in competitor strings | Who | Needed by Zag? | Action |
|---|---|---|---|
| `gsa.apple.com/grandslam/GsService2`, `/lookup`, `/validate`; `/auth/verify/trusteddevice`, `/auth/verify/phone*` | SideStore, Tetherless | Yes; covered | None |
| `developerservices2.apple.com/services/QH65B2/…`, `/services/v1/…` | SideStore, Tetherless | Yes; covered | None |
| `auth.itunes.apple.com/auth/v1/otp/1.5/{sync,finish}`, `auth/v1/native` | Tetherless | **No** [hypothesis, strong]: these sit with `buyProduct`, `volumeStoreDownloadProduct`, `storeFront`, "Store login" and the `DecryptView` account cards, which is Tetherless's App Store download/decrypt feature [archive observed] | **Do not add.** Decryption is out of scope. |
| `idmsa.apple.com/appleauth/auth/devices` | SideStore | Unknown | Record if the experiment's lookup or 2FA ever points there. The strict policy fails closed, which is the intended behaviour. [live test needed] |
| `developer.apple.com/services-account/v1/`, `account.apple.com` | SideStore | No evidence it's needed | None |
| `gs.apple.com/TSS`, personalised DDI from `raw.githubusercontent.com` | SideStore | No: that is for developer disk images and JIT, not installation | Out of scope |

### 5.2 Observations to collect in the experiment (redacted)

For each request:
- the host and path template (with IDs replaced);
- the method, HTTP status and phase (lookup, SRP, 2FA, portal operation);
- the latency;
- whether the network policy permitted or blocked it.

Also collect:
- for each lookup, the hosts named (names only);
- the 2FA kind offered (trusted device or SMS);
- the team type and the number of teams;
- the free-account limits as reported;
- whether the certificate listing includes DER content (true/false only);
- the serial hash of any certificate issued.

**Never collect:** passwords, codes, tokens, ADI or `adi.pb` contents, UDIDs or serials in clear.

**Decision rule:** a blocked request is recorded and the run stops. Any widening of the allowlist is a separate, reviewed change citing the recorded request, never a competitor string.

## 6. BYOC, Zsign and licences

| Package | Relevance | Rule for Zag |
|---|---|---|
| ESign 5.0.2 | P12 and profile import; `MobileInstallation` selectors; UMeng analytics; `NSAllowsArbitraryLoads` [archive observed] | A UX reference for BYOC only. Copy nothing. Never relax ATS. |
| LCSign 1.4 | ZSign-based (per GPT-6; unverified here); embedded PKCS#12; requests a private MobileGestalt entitlement | Zag already ships its own Zsign integration. LCSign is a behavioural comparator only. Never embed identities; never depend on private entitlements. |
| Tetherless | "Custom cert" OTA mode; `loopback.p12` download [archive observed] | Zag's BYOC publishing gate is unchanged. Never fetch identities remotely. |
| SideStore (AGPL-3.0), SideSign (GPL-3.0) | Reference behaviour only | No code copying without a G2 licence and provenance review. Nothing in this report was copied; only literal strings were read for evidence. |
| AltStore Classic 2.3.1 | AltServer-hosted model; device-restricted profiles | Background only |

No change to BYOC, Zsign or the publishing gate is proposed.

## 7. Fastest safe route to the first free-account sign and install

Each step needs the gate shown, and none is authorised by this report.

| Step | Work | Gate or owner | Acceptance |
|---|---|---|---|
| 1 | Finish the G4 re-review of #35 (stacked on #34) | GPT-6 | Written approval, or new issues |
| 2 | G2 licence and provenance decision for `zag-isideload` (MPL-2.0 files, MIT, the GPL-3.0 reference question) | Owner and reviewer | Recorded decision |
| 3 | G3: study report on 25 Nov, privacy desk review, provider and serial choice, per-account state decision | Owner | §3.4 criteria |
| 4 | Experiment build: an isolated Debug or preview build with the free-account gate on only in that build; a dedicated Apple Account with no payment method, whose 2FA the owner holds; production IPA and gates unchanged | Owner (explicit) | The build's feature flags are listed; the canonical IPA hash is unchanged |
| 5 | **Single run:** sign in → register this device (UDID from the existing pairing) → list certificates → issue at most one → one App ID and profile → sign one small test app → install through the existing RPPairing installer | Owner, present | App launches on device; one certificate issued; nothing revoked; redacted log (§5.2); installed profile VERIFIED by the read-back screen |
| 6 | Wire the installer's `installedProfiles` hook to the existing misagent reader | Review | The installer reports VERIFIED without the Debug screen |
| 7 | Refresh within 7 days; the 3-app limit; expiry behaviour; Shortcuts-assisted refresh | Later | Documented results |

**What I would not do first:**
- build a Packet Tunnel extension (needs a paid entitlement and duplicates LocalDevVPN);
- on-device anisette emulation;
- widen the allowlist;
- tweak injection or decryption.

## 8. Gaps and priorities

| Priority | Gap | Owner |
|---|---|---|
| P0 | G4 approval (#35); G2 decision; G3 decision after 25 Nov | GPT-6; owner |
| P1 | An experiment build plan listing exactly which gates open and where (doc only) | Claude, on request |
| P1 | Redacted experiment logger spec matching §5.2 (doc only; no code until approved) | Claude, on request |
| P2 | Wire the free-account installer to the existing misagent reader (#25 is in `main`) | Claude, on request |
| P2 | Owner-operated v3 server feasibility (licence, hosting, Apple-library provenance) | Claude research, on request |
| P3 | Pairing failure-message review against Tetherless's wording | Low |

## 9. Limits of this assessment

- Static strings only. Nothing was executed, installed, paired or contacted.
- The SideStore ODA reading of §3.2 is an inference from log strings. I did not fetch `oda.json`, which would mean contacting a third-party host.
- LCSign was not re-examined.
- The Tetherless `auth.itunes.apple.com` association rests on co-located strings, not control flow.
- The G3 study is incomplete.
- Every Apple behaviour stays [live test needed].

## 10. Correction (19 November 2026)

The first version of this report (`88b2590a`) said the installed-profile (`misagent`) reader was an unapproved draft (PR #25), so the experiment could only report "installed, not verifiable". That was wrong. I relied on an out-of-date comment in `ZagFreeAccountRPPairingInstaller.swift`.
- PR #25 was merged into `main` through PR #27 (`bcf30a9f`), and device test A passed (`DEVICE-TEST-PHASE7.md`).
- What remains is only wiring the free-account installer's own `installedProfiles` hook.
- §1, §4.1 (T4), §7 and §8 are corrected. The conclusions on anisette, LocalDevVPN, pairing and the allowlist are unchanged.
