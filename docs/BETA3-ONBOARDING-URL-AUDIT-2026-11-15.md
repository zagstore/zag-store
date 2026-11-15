# Beta 3 welcome flow and URL audit — 2026-11-15

Development branch: `codex/beta3-improvements`; baseline `f2b29d7e`. Onboarding commit: `6c05cea4`. The following separate commit contains URL fixes and this report. No version/build, release metadata, signing keys, production services or other checkouts changed. No IPA, signing, packaging, push or merge.

## Welcome flow

`ZagOnboardingPolicy` captures installation state before app managers initialize. A new installation with no persistent defaults or Documents/Application Support data gets a `pending` marker. Existing installations migrate to `existing` and bypass welcome, including installations with saved privacy preferences. A pending marker survives subsequent store creation and interrupted onboarding. Completion or Skip writes `completed`; state is installation-local and does not depend on app version. Restored app data is conservatively treated as an existing installation. There was no historical first-launch marker, so migration uses existing persisted data rather than claiming to know an installation date.

`ZagWelcomeView` is a scrollable, native full-screen NavigationStack beneath the unchanged cinematic overlay. The splash retains its exact animation, audio, fade and launch gate implementation. Welcome interaction/accessibility waits for that gate. Dynamic Type text, semantic colours, combined VoiceOver feature descriptions, SF Symbols, the existing theme tint, a material card and an iOS 26 glass primary button require no new assets or dependencies.

Set Up Pairing pushes the existing `InstallationView`, which owns the internal RPPairing page (and retains its existing legacy transport on older iOS). Welcome never starts an alternative engine. It observes the existing manager's `.paired` callback and requires its saved record before completing. On entry, an existing saved pairing record also bypasses welcome: the native engine writes that record only after successful pairing, before emitting success. This covers termination between persistence and UI dismissal. This is persisted setup status, not a claim that the tunnel is currently reachable; existing health checks remain responsible for connectivity.

Opening setup, seeing a PIN, cancellation and failure do not record success. Native Back returns to welcome; the existing pairing page retains its retry/error controls. Continue on that page, or Continue Without Pairing on welcome, records dismissal and enters the app. Sources and browsing remain usable without pairing. Later setup stays in Settings → Installation and the Devices page. The pairing engine's existing running/background lifecycle remains unchanged if the user leaves setup while it is waiting.

The main tab hierarchy mounts after onboarding is completed or dismissed, preventing its update sheets and notification requests competing with welcome. Existing installations mount it as before. Incoming links during splash/welcome are held in a bounded process-local queue (up to 16) and dispatched after entry; Shortcuts callbacks still go immediately to their existing operation controller. No queued URL is persisted or logged. Native document-provider grants and physical-device navigation still require device acceptance testing.

## Inbound inventory

Only `feather` and `zagstore` are registered in `Feather/Resources/Info.plist`. The legacy URL type name `thewonderofyou.Feather`, icon identifier and document UTIs are compatibility identifiers and remain unchanged. App-level SwiftUI `onOpenURL` is the single input entry point. There are no UIKit URL callbacks, associated-domains entitlements, universal-link handlers or NSUserActivity continuation paths in this app. An HTTPS website URL alone does not route into Zag Store.

| Scheme / route | Handler and behavior |
| --- | --- |
| `zagstore://home`, `zagstore://discover` | Discover tab; `home` compatibility alias retained |
| `zagstore://sources` | Sources tab |
| `zagstore://sources/your-sources` | Existing Your Sources navigation |
| `zagstore://apps`, `zagstore://library` | Apps tab; library compatibility alias retained |
| `zagstore://activity`, `zagstore://games`, `zagstore://devices`, `zagstore://certificates` | Corresponding existing page; now all generated TabEnum URLs have a central route |
| `zagstore://settings` | Settings root |
| `zagstore://settings/installation` | Existing Installation/RPPairing setup |
| `zagstore://settings/diagnostics/installation` | Installation diagnostics |
| `zagstore://settings/diagnostics/installation/rppairing` | RPPairing diagnostics |
| `zagstore://settings/diagnostics/updates` | Update diagnostics |
| `zagstore://shortcut-callback/{status,off,on}/{success,cancel,error}?id=…` | Existing Mobile Data Toggle controller; optional `result`/`errorMessage`; existing operation ID, command, deadline and result validation retained. Ambiguous duplicate parameters, userinfo, port and fragment rejected. A callback never initiates an operation. |
| `feather://source/<https URL>` | Confirm repository hostname, then existing source fetch/import. Raw nested URL queries/escapes are preserved; an entirely escaped nested URL is decoded once. |
| `feather://install/<https URL>` | Confirm hostname, then download/import to Apps for ordinary review/signing. This route does not itself sign or install. Same encoding rules as source. |
| `feather://import-certificate?p12=…&mobileprovision=…&password=…` | Exactly one of each base64 parameter, decoded once; bounded payloads. Requires user confirmation, then existing password/profile import checks. Temporary signing files removed after success or failure; no automatic signing/installation. |
| `feather://export-certificate` | Explicitly consumed and disabled; no certificate/password export or caller-controlled callback |
| `feather://` | Harmless return from LocalDevVPN's existing `scheme=feather` request; no state mutation |
| `file:` `.ipa` / `.tipa` document delivery | Existing registered document types. Requires an OS security-scope grant or canonical file inside Documents/Inbox, plus a regular file. Resolves symlinks before checking Inbox. Scope held through the asynchronous importer and released on completion/error. |

Unknown/malformed actions, insecure nested URLs, missing parameters, credential-bearing import URLs and non-file URLs ending in `.ipa` are rejected with a generic message. Navigation URLs reject unexpected query, fragment, credentials and ports. Unsupported links cannot erase a valid pending route. No new public URL scheme was introduced; no legacy scheme removed.

## Outbound inventory and external dependencies

| URL or family | Origin / verification boundary |
| --- | --- |
| `localdevvpn://enable?scheme=feather` | Existing Installation and legacy Tunnel page; bare `localdevvpn://` is queried with `canOpenURL`. `LSApplicationQueriesSchemes` retains `localdevvpn`. Compatibility return scheme preserved. Requires the installed third-party app for live verification. |
| `shortcuts://x-callback-url/run-shortcut` | Existing Mobile Data Toggle protocol. Name, command and nested success/cancel/error URLs use strict percent encoding. Requires Apple's Shortcuts app and the actual Shortcut for live verification. |
| `shareddocuments://…` | Existing `URL.toSharedDocumentsURL()` transforms encoded local file URLs for Files actions in archives, app info, settings and certificates. User initiated; not an inbound privileged route. Files integration requires a device. |
| `UIApplication.openSettingsURLString` | System Settings/Acknowledgements actions; system-provided URL retained. |
| `https://zagstore.app/shortcuts/mobile-data-fix/` | Existing Shortcut setup page; website contents, iCloud destination and installed Shortcut not checked live. |
| `https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/{stable,beta,nightly}.json` and `/releases/v2/{beta,nightly}.json` | Existing self-update channel discovery (stable has no v2 endpoint); metadata discovery redirect refusal, Ed25519/key registry, sequence rollback state and signed IPA restrictions unchanged. Diagnostics retain their existing `/releases/v2-test/beta-1.0.0-3.json` endpoint. Reachability/publication not assumed. |
| Signed `https://github.com/…/zag-store-releases/releases/download/…` IPA URLs | Existing verified streaming download, SHA-256 reuse and private-copy verification before import unchanged. No external update-install callback introduced. |
| Repository package/source HTTPS URLs | Confirmed external imports use the existing fetch/download pipeline. Redirects cannot downgrade an HTTPS origin, carry credentials or switch into local/custom schemes. HTTPS CDN redirects remain supported; existing HTTP-origin repository compatibility remains. |
| Repository website/news links | HTTP(S) only, no credentials; a repository cannot turn its Visit Website/Open action into a custom-scheme or file action. Browser/server redirects after a deliberate web open remain the browser's responsibility. |
| App Store LocalDevVPN download, GitHub feedback/support, donation providers, artwork/catalogue and privacy reporting HTTPS endpoints | Existing web/service links. App feedback and the Sources support prompt incorrectly targeted upstream Feather; their URL targets now point to `https://github.com/zagstore/zag-store`. Credit/attribution links in About, source format help and AltStore-format repository URLs remain intentional and unchanged. No live availability or server-side contract check claimed. |

Opening an already-installed app uses the existing bundle-identifier LaunchServices helper rather than generating a URL. RPPairing/install progress/completion uses native callbacks and existing state machines. No active `itms-services`, `altstore` or `sidestore` URL route/generator was found in the app; `itms-services` remains in historical localized explanatory text. No scheme was added for those references.

## Confirmed URL defects corrected

- Home's route used non-existent tab raw value `home`; generated Discover/Activity/Games/Devices/Certificates URLs lacked consistent central handling.
- Independent child onOpenURL handlers could disagree with central parsing and accept unsupported path suffixes. They now use one route pipeline, with cold-start pending-route selection.
- Routes to pages absent from the configured dock previously selected a fallback or a non-existent tab. They now open the existing target page in a dismissible native sheet; dock configuration/styling and slide transitions are unchanged.
- Legacy imports searched for `/source/` or `/install/` anywhere in a URL. The parser now matches the real scheme/authority and preserves nested query encoding without double decoding.
- The generic fallback passed any URL ending in `.ipa` to the local importer, did not balance document security scope and allowed arbitrary sandbox paths. It now accepts only authorized document deliveries.
- External signing/source/download links acted immediately. Imports now require a user decision; disabled certificate export stays disabled and bounded temporary certificate data is cleaned up.
- Shortcut callbacks accepted duplicate parameters and extra authority components. Existing nonce/deadline validation is retained and malformed callbacks stay consumed by the callback controller.
- Generic source/package redirects could downgrade HTTPS or leave web schemes. Task delegates now enforce the tested redirect policy, preserving the existing shared fetch session/cache behavior.
- Repository website/news metadata could invoke arbitrary custom schemes. These browser actions now accept HTTP(S) only.

## Validation

Passed:

- `scripts/test-zag-onboarding.sh`: fresh install, pending restart, dismissal/update persistence, legacy preferences/data migration and consent preservation.
- `scripts/test-zag-deep-links.sh`: 59 route/encoding/compatibility/security checks, plus registered scheme and support-link checks. Includes canonical Inbox/symlink checks, document grants, duplicate callbacks and certificate inputs.
- `scripts/test-zag-device-link.sh`: existing pairing/network and Shortcuts protocol regressions.
- `scripts/test-zag-background-refresh.sh`: complete suite, including six redirect-policy cases and diagnostics persistence/failure migration.
- `scripts/test-zag-repository-refresh.sh`: all 46 behavioral checks and pipeline checks, with the real shared-session fetch implementation. An initial custom-session implementation bypassed the test URLProtocol interception; it was replaced with a task delegate on the existing shared session, and the suite passes. No test failures were waived.
- Activity reporter, self-update recovery and disabled certificate-export suites.
- Welcome view SDK type-check at iOS simulator deployment target 16.4, stubbing only the existing pairing manager/Installation destination/theme provider.
- App root SDK type-check with real onboarding/URL policy and router, stubbing unrelated app services/views; existing onChange deprecation warnings only.
- Root tab container and legacy tab container SDK type-check with real routing and stubs for unrelated models/pages; existing onChange warnings only.
- Real NBFetchService iOS SDK type-check, all changed Swift source syntax checks and whitespace checks.
- Byte comparison confirms the entire cinematic splash/launch gate, privacy reporters, updater coordinator/integrity/signature/rollback sources, URL registration, project and version/build settings remain unchanged from the validation baseline. About assets/layout and dock styling were not modified.

Outstanding environment/device validation:

- First-launch host tests repeat the four known restricted-environment persistence failures: Keychain completion (launch and jailbreak), suppression after file loss and backup exclusion. The previous checkpoint isolated host SecItemAdd OSStatus `-50`, with the backup attribute passing outside restrictions. Reporter/store code is unchanged. Presentation and non-persistence behavior pass; the suite is not reported as a full pass.
- CoreSimulator remains unavailable from the preceding checkpoint (service lookup refused, NSPOSIX 61); no repair attempt or simulator runtime pass claimed. Xcode previously exited 134 before compilation with FSEvents/developer-cache errors. No full app build was repeated or claimed here.
- On-device acceptance remains necessary for Splash → Welcome → Pairing → app; Skip; saved-pairing bypass; pairing failure/retry/Back; app switching through LocalDevVPN; document-provider scope; hidden-dock deep-link sheets; dark/light mode, large accessibility text and small screens. Navigation and state paths were inspected and selectively type-checked, not exercised in a running iOS app.

Logs are under `/tmp/zag-onboarding-*.log`, `/tmp/zag-deep-links.log`, `/tmp/zag-welcome-typecheck.log`, `/tmp/zag-app-typecheck.log`, `/tmp/zag-tabs-typecheck.log` and `/tmp/zag-fetch-typecheck.log`. These are development validation outputs. The branch is suitable for further feature work; device acceptance and full app compilation remain outstanding. Beta 4 release preparation is not authorized and was not started.
