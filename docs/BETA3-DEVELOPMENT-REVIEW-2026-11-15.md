# Beta 3 development review — 2026-11-15

Baseline: `87539ba2`, branch `codex/beta3-improvements`. Development only: version 1.0.0/build 3 retained. No release packaging, signing, upload, manifest, trust-key, rollback-sequence or external packaging-script changes.

## Checkout safety and commits

This working directory's `.git` points to `/Users/zagorskey/Documents/Feather-Petar/.git/worktrees/ZagStore-claude`. That metadata's `gitdir` points back to `/Users/zagorskey/Documents/ZagStore-claude/.git`. Normal commits here would therefore modify metadata belonging to the separate checkout. The initial add/commit failed to acquire its index lock; no normal commit was made.

To respect the instruction to leave that checkout untouched, commits were made in an independent bare review repository, `/tmp/zag-beta3-review.git`, using this directory as its work tree. A bundle at `/tmp/zag-beta3-review.bundle` contains the changes relative to the baseline. The original branch reference remains at the baseline; source edits are present in this working directory. These commits must be applied in a correctly registered independent checkout before normal branch development resumes.

- `9c0df584`: first-launch privacy availability.
- `14e1e907`: verified-download reuse and stale/concurrent preparation protection.
- The final documentation commit contains this report; obtain its hash with `git --git-dir=/tmp/zag-beta3-review.git log -1 --oneline`.

## Task 1 — privacy

Copies without a valid attribution document now show **Unavailable** for both first-launch reporting and jailbreak reporting, rather than disabled switches reflecting saved preferences. The explanation explicitly says neither report is sent and distinguishes separately controlled usage statistics. Attributed copies retain their original switches, defaults and opt-out behavior. No preference is rewritten merely by opening Privacy. The reporter's documentation was corrected; its executable behavior and backend contracts are unchanged.

Files:

- `Feather/Views/Settings/ZagFirstLaunchPrivacyView.swift`
- `Feather/Utilities/ZagFirstLaunchReporter.swift` (comment only)
- `scripts/test-zag-first-launch-report.sh`

The existing anonymous foreground/Live Activity reporting implementation is unchanged.

## Task 2 — self-update

Code inspection established these defects:

1. Successful manual preparation never assigned `downloadedReleaseIdentity`, so the existing verified-cache branch was unreachable for manually prepared downloads. It now records identity; repeated preparation rechecks the SHA-256 and reuses valid bytes.
2. A download could suspend across `preferencesChanged()` and then restore an old channel's prepared state. Each download now captures the preference generation and refuses publication if invalidated. Automatic-download errors from an invalidated generation cannot overwrite the new status.
3. Manual and automatic preparation could download concurrently into the same final destination. Manual preparation now participates in the existing download gate and reports an explicit busy error.
4. Preference changes dropped the prepared URL without deleting the known staged file. They now use the existing discard helper.

Files:

- `Feather/Utilities/ZagSelfUpdateCoordinator.swift`
- `scripts/ZagSelfUpdateIntegrityTests.swift`

Regression coverage added for reuse without another request, deleting prepared bytes on preference change, overlapping preparation and invalidating a suspended download. The existing failed-retry test now damages the local cache before retrying, since a valid cached file should be reused.

Review of retained behavior:

- Interrupted/cancelled downloads remove owned partial files; launch removes abandoned partials. A subsequent attempt starts fresh. HTTP range resumption is not implemented; adding it is outside a confirmed-defect fix.
- Downloading/verifying uses indeterminate UI; only actual installer callback percentages drive measured installation progress. No invented download percentage was introduced.
- Streaming SHA-256 verification precedes staging, and the importer verifies its private copy before extraction. Reuse also verifies the cached digest.
- Pending handoff records retain executable identity checks, keychain continuity checks, installer-event classification and launch reconciliation. Ambiguous installer outcomes remain pending; the existing clear-and-retry UI remains available.
- Ed25519 verification, key registry, accepted-sequence protections and production metadata are unchanged.

Remaining limitations: preference changes invalidate a request's result but do not immediately cancel its network transfer. A second request waits for the old operation to finish and the user can retry. Prepared files are not resumed across process restarts. A process-killed verified file can remain on disk until a later preparation replaces it; it is not automatically trusted or imported. Physical-device installation handoff was not exercised.

## Task 3 — lossless size investigation

Read-only source audit: 108 files under `Feather/Resources`, totaling **23,791,402 bytes**. These are source bytes, not a compiled catalogue or IPA size.

SHA-256 duplicate groups:

| Bytes per file | Paths relative to Resources/Assets.xcassets | Assessment |
| ---: | --- | --- |
| 670,632 | `ZagAccountIconDark.imageset/feather_dark.png`; `AppIcon.appiconset/zagstore_dark.png` | Separate account-image and Home Screen roles; retain both. |
| 1,397,365 | `ZagFirewood.appiconset/icon.png`; `ZagFirewood.appiconset/firewood-dark.png` | `icon.png` is not named by that set's Contents.json. Removing source bytes does not establish any compiled/IPA reduction; no deletion applied. |

All seven icon sets remain: AppIcon, ZagMoney (USD), ZagGBP, ZagFirewood, ZagClearGlass, ZagMatrix and ZagNeonFlux. No source artwork or icon declarations changed. Runtime switching through the choices still needs device validation.

Release already uses asset optimization `space`, Swift `-Osize`, dead-code stripping and deployment postprocessing. Debug uses development settings; stripping it for a speculative distribution saving is inappropriate. Existing historical size measurements are in `IPA-SIZE-INVESTIGATION-2026-11-03.md` and are not measurements of this session or Beta 3.

No optimisation was applied: resource bytes **23,791,402 before → 23,791,402 after**, saving **0 bytes**. No new IPA was created, and no new IPA before/after saving is claimed. Further compiled-catalogue, duplicate representation and ZIP-overhead analysis should use an existing exact Beta 3 IPA or an explicitly authorised future packaging comparison. Preserve separate icon idioms/appearances; identical source bytes alone do not establish redundant runtime assets. No debug artifact was identified for safe removal from this session's unbuilt app.

## Task 4 — performance investigation

Inspected launch setup/gating, repository refresh, pull-to-refresh and image-loading paths. Source and Updates pull-to-refresh already await `fetchSources`; repository work is batched and preserves the last successful snapshot, and the fetch service maintains a bounded decoded cache. Games builds its index with detached tasks. Nuke already provides image memory/disk caches. The intentional cinematic splash is included in launch-to-interactive measurements; changing its duration would change established UI behavior.

No new reproducible performance defect or trustworthy device profile was obtained, so no performance rewrite was applied. Main-actor synchronous candidates for measurement include cached-IPA hash revalidation, executable reconciliation hashes and startup cache/directory work. Their presence alone is not evidence of a user-visible stall. UI recomputation, network/image scheduling and frame pacing require controlled runtime measurements before changes.

Recommended follow-up: use the existing opt-in local Performance diagnostics (see `PERFORMANCE-DIAGNOSTICS.md`) for repeated cold/warm launch, refresh and screenshot-gallery samples, then use Instruments Time Profiler/Hangs on a development build to attribute stalls. Keep repository responses/cache state comparable and retain Liquid Glass, transitions, search and navigation.

## Validation

Logs are local under `/tmp/zag-*`; they are not release artifacts.

| Check | Result |
| --- | --- |
| Privacy SwiftUI view with real first-launch/activity reporters and report models, iOS simulator SDK type-check (only theme style stubbed) | Passed. |
| Real self-update coordinator, metadata/rollback/integrity helpers and updated simulator regression harness, compile/link against existing test stubs | Passed; existing unused-result warnings in ZagLogger. No runtime pass claimed. |
| `test-zag-activity-report.sh` | Passed. |
| `test-zag-self-update-recovery.sh` | Passed, including retry policy/device-family checks. |
| `test-zag-repository-refresh.sh` | Passed. |
| `test-zag-first-launch-report.sh` | Presentation/source checks passed. Restricted run had four host failures; broader-access run left three Keychain-dependent assertions failing (finished launch/jailbreak record and no resend after state loss). Backup exclusion passed with broader access. Core reporter/store and its unit tests were not changed. Do not treat the whole suite as passing. |
| `test-zag-background-refresh.sh` | Lifecycle/ledger/once-completion tests passed; metric-store subtest failed two assertions (zero stored metrics and newest metric replacement), producing one failed suite check. No performance/metric-store code changed. |
| Simulator runtime | Blocked: CoreSimulatorService connection refused, including with broader system access. New updater runtime regressions remain unexecuted. |
| Full unsigned Debug iOS build, isolated derived data/dependency copy, no deployment output in `_build` | Attempted; xcodebuild exited 134 before compilation, after developer/cache/FSEvents service errors. Full app build not validated. |
| Whitespace diff check | Passed. |

No device deployment, installation, new release signing or packaging was performed. Additional work needed before release consideration: repair checkout registration without altering the separate checkout, run new updater tests in a functioning simulator, resolve/reproduce host persistence test failures, complete an unsigned full app build, and verify privacy layout plus all seven icon choices on iPhone/iPad. Release remains unauthorised.
