# Update progress, continuous morph and verified post-update messaging

The header, measured 16 pt section gap, note expansion, Learn More URL and
preferences remain unchanged. Normal Update Now directly invokes the existing
certificate, verified download/import/signing and upgrade-only installation path.

## Original artwork and morph

The reference is `ZagSelfUpdateRainbowProgress` in `30741eaf`'s
`ZagSelfUpdateStatusView.swift`, plus the unchanged shared
`ZagSelfUpdateSpectrum.colors` in `ZagAppsTabIcon.swift`: cyan, blue, violet,
pink, cyan, a five-second rotating angular rim, 1.5 pt stroke, rounded fill and
unfilled track. The primary control and diagnostic bar now reuse
`ZagUpdateSpectrumSurface`, which draws that palette/rim with a flowing spectrum,
gloss and low-cost halo strokes in one Canvas. No per-frame blur/shadow filters,
new raster artwork or dependencies are introduced.

One persistent button contains one Canvas surface. `morph` continuously
interpolates the capsule from the full label slot (54 pt minimum) to a 14 pt
track, about the same vertical centre and at the same width. Its radius is always
half its interpolated height. The blue body transforms into spectrum fill;
there is no control opacity swap. The stationary action label alone can fade.
The outer slot and status area stay present, so surrounding card geometry does
not collapse. Dynamic Type can enlarge the slot and status area naturally.
Terminal guidance and safe retry reverse the same 0.42-second morph. Reduced
Motion uses immediate geometry changes; measured fractions otherwise interpolate
linearly for 0.1 seconds without changing reported bytes or percentages.

The previous implementation used a material crossfade plus a separate native
linear meter. It was not a geometric morph. Earlier spectrum code constructed
its gradients in body and animated the containing geometry with every progress
change. The renderer now caches Gradient values, isolates its TimelineView to the
small Canvas, separates the five-second decorative clock from real progress and
uses asynchronous Canvas presentation. No high-frequency model publications or
Markdown parsing drive the clock. Low Power Mode, Reduce Motion, background,
idle and terminal states pause decorative motion. There is no fixed 60 Hz cap.

The app lacked `CADisableMinimumFrameDurationOnPhone`; that documented Boolean
opt-in is the only Info.plist change. SwiftUI still chooses cadence, and 120 fps
is a target, not a promise:
https://developer.apple.com/documentation/bundleresources/information-property-list/cadisableminimumframedurationonphone
https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays
https://developer.apple.com/videos/play/wwdc2021/10021/

URLSession's serial delegate queue still writes and hashes real bytes, publishing
at most 10 Hz plus first/final observations. Unknown download lengths and
verification/import/signing/connection phases never invent a percentage.
Utility-task cached/executable hashing, operation locks, generation checks,
late-publication tokens, manifest authorization and rollback policy remain.

## Observable lifecycle and truthful terminal states

| Boundary | Evidence | Presentation |
|---|---|---|
| Preparing/download | Existing task + URLSession bytes | Preparing/downloading, measured download fraction when length is known |
| Verifying/import | SHA-256 stream result + existing importer | Verifying/importing; indeterminate spectrum |
| Signing | Existing combined signer callback followed by signed identity validation | Preparing signed update; no invented intermediate signing-complete event |
| Device connection | Native 201–204 callbacks | Preparing/connecting to device/service |
| Transfer | Native 205, and 208 when separately streamed | Transferring signed IPA; only real 208 percentage |
| Fully staged | Native 209, after device-side length check | ASCII `IPA verified - waiting for iOS handoff`; expanded **View Installation Steps** capsule, explicitly unconfirmed |
| Installation progress | Native 206 | Actual installer percentage; not installed-executable proof |
| Successful installer return | Native 207 resumes existing continuation | **Reopen After Installation...** capsule; `Update handed off to iOS. Reopen Zag Store after installation.` |
| Ambiguous failure / pending record on launch | Existing conservative recovery policy retains record | **Check Installation...** capsule; unverified status and manual/recovery guidance |
| Proven failure before upgrade / cancellation | Existing recovery policy allows retry | Original **Update Now** capsule; existing error shown |
| Installed replacement | Fresh running identity + executable proof, after release advancement | **Restart to Complete...** capsule; `Update completed. Please restart Zag Store.` |

The indefinite waiting regression came from mapping every pending record to
`.awaitingVerification` with `showsProgress == true`, losing the distinction
between staged transfer, native success and unknown completion. Pending records
now have explicit in-memory handoff presentation facts. They remain the same
conservative persisted recovery records and do not authorize installation.
The app can still be terminated by iOS before a native terminal callback.

Rust explicitly does **not** emit 210 in the separately streamed self-update
path: `upgrade_with_callback` combines request transmission and waiting for iOS.
209 is not transmission/completion proof. If the service remains at 209, the
user gets actionable, accurate instructions rather than an indefinite bar or a
false successful-handoff claim. Existing handling of a genuinely reported 210
is retained; no synthetic event, timer or timeout success is added.

Every final action opens explicit manual guidance, never `exit`, a crash,
private API or a simulated restart. Unconfirmed guidance asks the user to wait
for installation on the Home Screen before reopening. The stronger verified
wording is reserved for installed proof:
https://developer.apple.com/library/archive/qa/qa1561/_index.html

## Replacement prompt

The exact `Replace the installed Zag Store?` prompt is an app-level
`confirmationDialog` in `ZagSelfUpdateStatusView`. Its only presentation trigger
is **Review Beta v2 In-Place Update** under advanced test diagnostics. Normal
Update Now never sets that flag. This deliberate test-candidate authorization
remains: a prepared diagnostic candidate is not itself consent to replace the
app. It invokes the existing upgrade-only path and explicitly forbids automatic
uninstall/fresh-install fallback. No native/system permission prompt is bypassed.

## Post-update splash and local-only strategy

The cinematic view, audio, timing and acknowledgement code from `ea191fff` are
unchanged. The pending record now also stores the original version. A subsequent
running bundle/version/build and executable SHA-256 must match the candidate and
differ from the original; the release identity must advance. Re-signing at the
same version/build cannot trigger a new-release message, even with a different
executable hash. Older records without a source version require an advancing
build, conservatively suppressing messages if advancement cannot be established.
Channel labels come from recorded validated discovery metadata, not guesses.

A verified notice persists until the final caption reveal actually finishes
while visible/foreground. Skip, disabled splash, background/interruption and
late verification retain it. Subsequent acknowledged launches restore the exact
original normal caption. Legacy records lacking channel metadata announce no
channel rather than guessing Beta.

The public Beta 3 artifact does not contain this code and cannot validate it.
Do not publish or replace that artifact. Automated tests use an isolated
UserDefaults suite and synthetic installed identities to exercise distinct local
release labels, real/different executable hashes, all three channels, failed or
incomplete replacement, same-version/build rejection and one-shot acknowledgement.

For a future separately authorized **device** round trip, use two isolated local
development configurations with a test bundle ID and distinguishable *test-only*
version/build labels in generated temporary build settings, a matching local
signed metadata fixture and isolated rollback storage. Both test executables
must include the new reconciliation/splash code. Do not edit production version
settings, signing identities, manifests, channels or release endpoints. Validate
A→B once, ordinary relaunch, skip/disabled/interrupted splash and failed handoff;
try a differently signed B with the same B release labels and require no new
release announcement. This task does not generate, sign or package those builds.

## Validation and environment limits

- `scripts/test-zag-update-progress-and-message.sh`: byte sampling, phase/action
  policies, continuous morph geometry, power/accessibility policy, release
  advancement, one-shot persistence, real URLSession/CryptoKit fixture transfers.
- `scripts/test-zag-update-morph.sh`: real production Canvas pixel rendering at
  five intermediate morphs, stable width/centre, filled/unfilled distinction,
  original colours and progress-independent motion, plus integration assertions.
- `scripts/test-zag-update-presentation.sh`,
  `scripts/test-zag-post-update-integration.sh` and
  `scripts/test-zag-self-update-recovery.sh`: approved layout, original action
  boundaries, native callback truth, prompt safety, proof/recovery/security and
  unchanged splash timing.
- Swift parsing and arm64 iPhoneOS SDK type-checks cover the actual coordinator,
  integrity harness and update/splash UI with external dependency stubs. These
  are not a full linked app build or a runtime installation test.

The supplied 11:04:54 AM recording exists (27.9567 seconds), but AVFoundation
frame extraction fails with `AVFoundationErrorDomain -11821`, underlying OSStatus
`-12911`. A temporary software decoder download failed due unavailable DNS. No
frames were decoded, so the recording's animation has not been visually reviewed.
`xcrun xctrace list devices` exits with SIGSEGV (-11) before listing devices;
real-device frame-time profiling is unavailable. Do not infer frame rate from
source assertions or offscreen macOS Canvas renders. Device QA must check actual
ProMotion frame pacing, morph interruption/reversal, all themes, Dynamic Type,
VoiceOver, power modes and the controlled installation/relaunch sequence.

## Changed paths

- `Feather/Utilities/ZagSelfUpdateCoordinator.swift` — handoff facts and source identity.
- `Feather/Utilities/ZagPostUpdateMessage.swift` — advancing-release requirement.
- `Feather/Utilities/ZagUpdateProgressPresentation.swift` — terminal guidance, real-percent labels, geometry and power policy.
- `Feather/Views/Settings/ZagUpdateSpectrumSurface.swift` — shared cached Canvas renderer.
- `Feather/Views/Settings/ZagSelfUpdateActionControl.swift` — persistent morph and stable status slot.
- `Feather/Views/Settings/ZagSelfUpdateStatusView.swift` — actual event mapping, guidance and diagnostic renderer reuse.
- `Feather/Resources/Info.plist` — documented ProMotion opt-in only.
- `scripts/ZagUpdateProgressAndMessageTests.swift` — model, release-proof and persistence regressions.
- `scripts/ZagUpdateMorphRenderingTests.swift` — production Canvas pixels and actual control layout.
- `scripts/test-zag-update-morph.sh` — renderer and lifecycle integration checks.
- `scripts/test-zag-update-presentation.sh` — approved presentation regression checks.
- `scripts/test-zag-post-update-integration.sh` — completion status now belongs to the shared control policy.
- `scripts/test-zag-import-integrity.sh` — includes the progress helper required by the already-shared integrity utility.
- `docs/validation/update-progress-and-post-update.md` — implementation boundaries, evidence and local test plan.

Existing metadata expiry and vector-conformance suites were also attempted both
inside and outside the sandbox. Both remain blocked by host Keychain
`OSStatus -50`; the expiry test stops on a thrown store error and the vector
suite reports 33 downstream failures because accepted sequence state cannot be
stored. The metadata verifier, trust store, rollback store and verified pipeline
are byte-identical to the baseline. A separate no-Keychain smoke check against
the existing reference vector verifies actual Ed25519 acceptance, rejection of
untrusted/bad signatures, and channel enforcement; this does not substitute for
rollback-persistence tests. Importer integrity passes 14 checks using its real
private-copy extraction path. No security policy was relaxed for this host.
