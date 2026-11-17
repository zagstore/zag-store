# Beta 3 per-cold-launch pairing gate correction

Branch: `codex/beta3-improvements`. Baseline: `cf2bca9c`. This supersedes the installation-local onboarding rules in the earlier onboarding/URL audit. No version/build, pairing engine, splash timing/audio, privacy reporter, updater security, dock styling or public URL route changes.

## Root cause

The previous gate was wrong for the required operational-pairing behavior:

- `ZagOnboardingPolicy.begin` returned false for saved `completed` or `existing` markers. Without a marker it also skipped welcome for any persistent defaults or existing Documents/Application Support data. Unpairing never reset these markers. An install over the same bundle's existing container therefore bypassed welcome regardless of pairing status.
- `ZagWelcomeView.onAppear` also dismissed welcome solely when `pairingFileExists` was true. A stale or revoked file was treated as successful pairing without a live check.

The exact device's stored marker was not inspected; both incorrect suppression paths were reproduced in automated regression coverage. This was an implementation defect, not an installation/build-number problem.

## Correction

`ZagOnboardingPolicy` is now entirely process-local. It reads and writes no defaults, completion flags, installation history or version data. Its initial state blocks the main interface. Each new process must verify again, including installations over an existing app with the same version and build. Old onboarding defaults are ignored and left untouched; no unrelated data or pairing records are deleted.

`ZagPairingLaunchCoordinator` starts once per process, in parallel with the unmodified splash. Missing records lead to welcome; existing records only permit a verification attempt. The coordinator waits for existing native work before starting verification, with one 15-second deadline covering both transport waiting and the health check. There is no second pairing engine.

`ZagRPPairingLaunchService` bridges to the existing `startGate2Probe(endpoint: .localDevVPN)`. Its existing native diagnostic mode validates a copy of the saved credentials without pair-setup fallback or rewriting the record, then checks the tunnel, RSD and installation/device services, including the existing temporary staging health check. Only a new terminal `.complete` result counts as operational verification. Cached publisher values, partial Pair-Verify results and experimental-endpoint results cannot grant entry.

Unreadable/rejected credentials show setup guidance. Unreachable/disrupted services show unknown status with Retry; generic verification failure also stays in welcome. Timeout shows unknown status and Retry. The deadline cancels this coordinator's observation/wait, not the native worker: late results cannot open the main app. A retry waits for an earlier worker to finish before starting a new check, and is also bounded. No native transport is overlapped or force-reset. If a native operation remains unavailable, Skip always allows entry for the current session.

Set Up Pairing still opens `InstallationView`. It is disabled while the current launch check is pending to avoid competing with native work. Back, existing failure/retry controls and Continue Without Pairing remain available. A fresh authenticated native `.paired` event dismisses welcome; a file appearing, opening setup or a replayed success does not. On the next cold launch, even a successful pairing must pass live verification again.

Skip affects only this process. Background/foreground transitions and repeated SwiftUI tasks do not restart the gate. Splash remains on its original clock; if verification is still pending when it finishes, welcome displays checking status and Skip. The main tab hierarchy cannot mount before positive verification or Skip. Pending deep links are held in the existing bounded, memory-only queue until both the splash and pairing gate allow entry; existing active Shortcuts callbacks retain their immediate controller path.

## Modified files

- `Feather/FeatherApp.swift`: process-lifetime coordinator, gate and deferred link dispatch.
- `Feather/Utilities/ZagOnboardingPolicy.swift`: in-memory launch state machine and bounded URL queue.
- `Feather/Utilities/ZagPairingLaunchCoordinator.swift`: bounded asynchronous verification, retry, session skip and stale-result rejection.
- `Feather/Utilities/ZagRPPairingLaunchService.swift`: existing native verifier/setup event bridge.
- `Feather/Views/Settings/ZagWelcomeView.swift`: checking/unknown/failure states, Retry and session-only Skip; removes file-existence bypass.
- `scripts/ZagOnboardingPolicyTests.swift`, `scripts/ZagPairingLaunchServiceTests.swift`, `scripts/test-zag-onboarding.sh`: regressions and app-integration checks.
- This report.

## Validation

Passed:

- **34 launch/coordinator regressions**: no pairing; retained install data/legacy markers; completed onboarding then unpairing; invalid/stale/revoked records; unknown/failure; verification timeout; busy/unavailable native service; retry; late results; verified bypass; session Skip then cold relaunch; new native pairing success then cold revalidation; background/repeated tasks; links pending during verification/splash and released once after verification or Skip.
- **11 production event-bridge regressions**, compiled with the real launch bridge and existing failure classifier, substituting only the native engine boundary: cached successes, production endpoint, partial verification rejection, terminal completion, experimental endpoint exclusion, invalid/rejected credentials, unknown transport, startup failure, setup start vs fresh success.
- Integration assertions confirm the app has no persisted/file-existence bypass and uses the same gate for setup, Retry and deferred URLs.
- Existing deep-link suite (59 cases plus configuration checks), device-link, activity reporter, self-update recovery, background refresh, repository refresh and disabled certificate-export suites.
- iPhoneOS SDK type-check of the real welcome, state machine, coordinator, service bridge and failure classifier at arm64/iOS 16.4, stubbing the existing native engine and unrelated UI providers.
- iPhoneOS SDK type-check of the real app root with the new gate/welcome and existing URL policy/router, stubbing unrelated services and views; existing onChange deprecation warnings only.
- Changed Swift syntax and whitespace checks. Byte comparison confirms the complete cinematic splash/launch gate, native RPPairing engine, privacy reporters, updater coordinator/hash/signature/rollback sources and version/build/project settings are unchanged.

Full iPhoneOS Release build was attempted twice with `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGNING_REQUIRED=NO`, generic iOS destination and isolated derived data, dependencies and destination under `/tmp/zag-pairing-launch-release*`. Both restricted and broader-access attempts exited **134 before compilation**. Logs report `DVTFilePathFSEvents: Failed to start fs event stream` and `DVTDeveloperPaths` failing `DARWIN_USER_CACHE_DIR` confstr with error **5 (Input/output error)**. No full build pass claimed; no simulator repair attempted.

Logs: `/tmp/zag-pairing-launch-*.log`.

## Real-device acceptance still required

The automated tests exercise production state/event handling with a controllable native boundary, not an actual iPhone handshake. Verify on the iPhone: unpair → force-quit → launch → splash → welcome on every attempt; skip → force-quit → welcome again; stale/revoked records; permission/network failure and timeout with Retry; successful pairing then verified cold bypass; same-build installation over retained data; background return without interruption; deep links during checks. Confirm the existing local VPN is operational for the positive Gate 2 bypass case.

No IPA, signing, packaging, publishing, push, merge or Beta 4 preparation was performed. Other checkouts and production infrastructure were not modified.
