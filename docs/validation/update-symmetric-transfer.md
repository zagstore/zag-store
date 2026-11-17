# Symmetric update morph and isolated transfer presentation

Baseline: `ab4ee2e8`. No installer, credential, manifest, SHA-256, Ed25519,
rollback, persisted handoff proof, splash artwork/timing/sound or version/build
configuration is edited.

## Root causes and correction

The entry and exit already requested a 0.42-second height animation, but the
Canvas used one `AnimatablePair(morph, progress)` under nested geometry and
percentage animation modifiers. Incoming download/transfer targets could
retarget that shared vector with a 0.1-second transaction during entry. Exit
usually occurred after percentage updates stopped, so it appeared smoother.
The label also used a separate asymmetric ease-out. Additionally, the brief
pending-record-before-installer-start state and callback 209 selected non-busy
capsules, reversing the control before the operation had returned. Those pending
states now retain the busy geometry until a legitimate terminal outcome.
There is now precisely one
geometry animation channel (`animatableData: Double`, the morph amount), driven
in both directions by one symmetric cubic specification: 0.42 s,
(0.42, 0), (0.58, 1). The stationary label uses that same specification. Height
still interpolates 54→14 / 14→54; radius remains half height, and centre/width
are unchanged. No parent layout animation, view swap or artificial startup
delay is introduced.

Transfer callback 208 (and installation percentage callback 206) publishes the
raw native state and diagnostic state on the main actor. The old update screen
observed the entire pairing core, so these publications invalidated its Form,
header, release notes and preferences in addition to the small control. The
native transfer itself already runs asynchronously in Rust; download I/O,
import/signing work and hashing retain their existing background mechanisms.
Certificate selection/Core Data access correctly remain on their existing actor.

`ZagUpdateInstallerPresentation` now subscribes to the native stage publisher
and only publishes **structural stage changes** to the screen. It does not
forward its child percentage publisher. `ZagUpdateTransferPresentation` keeps
real, monotonic, in-range samples per transfer/installation phase, drops
redundant/late values, and coalesces percentage-only UI publications to 10 Hz.
The first real phase sample is immediate; queued previous-phase values are
invalidated by generation. It never generates completion percentages.
Native callback capture, retry classification, raw percentages and successful
completion continuation are untouched.

Only `ZagUpdateTransferActionControl` observes those coalesced values. The
Canvas's separate `ZagUpdateVisualProgress` interpolates displayed values over
0.1 s, retargeting from the current display value and never extrapolating beyond
an observed target. Phase resets and Reduce Motion/Low Power updates use actual
values directly. The decorative five-second clock is a third independent path:
it keeps its existing TimelineView identity, opacity, palette, left-to-right
phase and power policy. No percentage-based SwiftUI animation remains on the
Canvas or its ancestors. Existing developer-only diagnostics use their own
small live-observer wrappers, preserving live details without invalidating the
normal screen.

Percentage formatting also corrects Double round-trip underflow (e.g. an
integer installer percentage must not be printed one lower). An incomplete
byte fraction is never rounded up to 100%.

## Exact completion semantics

The final capsule is exactly:

`Restart to Complete...`

The status is exactly:

`Update successful. Reopen Zag Store to complete.`

Normal completion reaches those strings only after the coordinator's existing
native installation call **returns success**. Transfer callback 209, submission
callback 210, a 100% transfer, an interrupted operation and ambiguous pending
records cannot select that final state; they keep their existing truthful status
inside the progress presentation. In particular, 210 no longer selects the
handed-off success UI. Confirmed installed identity on a subsequent launch also
uses the same requested presentation, with the stronger proof unchanged.

The normal previous-attempt warning is not shown beside a currently successful
handoff. Its pending proof record is retained, and normal recovery remains
available for failures/ambiguous outcomes and a subsequent unverified launch.

This wording describes successful installer operation/handoff, not proof that
the replacement is already running. It is not read by installed-update
reconciliation or the splash-message store. The actual running identity and
executable hash are still required before the one-shot caption is eligible.

The existing short, inline manual-reopen interaction remains. No confirmation,
instruction sheet, diagnostic popup, private API, exit, abort or automatic
termination is added. No new user-facing copy is introduced beyond the two
requested final strings.

## Tests and limits

- `test-zag-update-transfer-presentation.sh` compiles the production presentation
  classes against a host native-input stub and feeds callback bursts. 101 fixture
  sample inputs cause one structural screen-stage publication, rather than 101
  percentage/diagnostic-driven invalidations. The child retains the latest real
  value with bounded publications. Tests cover duplicates/regression, phase
  resets, queued values after failure, invalid samples and completion without a
  fabricated percentage. These are publisher-level tests, not device frame data.
- `test-zag-update-progress-and-message.sh` executes morph timing symmetry,
  reverse geometry, continuous progress retargeting, bounded interpolation,
  exact final strings, non-success exclusion, integer percentage accuracy and
  existing one-shot installed-identity/store policies for all channels. It also
  runs real URLSession/CryptoKit streaming fixtures.
- `test-zag-update-morph.sh` renders actual Canvas pixels and control layouts,
  including full opacity, left-to-right flow, compact spacing, intermediate
  geometry, Dynamic Type and progress changes that cannot modify animatable
  geometry. Integration assertions preserve one shared animation definition,
  stable renderer identity and scoped observation.
- Existing release-note/presentation, post-update integration, importer integrity
  and installation recovery suites are retained. The approved 16 pt section gap,
  header/channel geometry and Learn More URL/handler remain unchanged.
- Swift parsing and targeted arm64 iPhoneOS SDK type-checks exercise the actual
  UI/presentation code and coordinator/integrity harness with external dependency
  stubs. They are not a full linked app build or native runtime installation.

The supplied 12:18:26 PM recording exists (18.6375 s), but AVFoundation frame
extraction fails with `-11821`, underlying `-12911`. Its motion could not be
reviewed here. `xcrun xctrace list devices` exits -11 before listing a usable
runtime. No actual-device frame-time profile, 120 fps claim, genuine installed
A→B test or iPhone cinematic reveal verification is possible here. Remaining QA
is actual entry/exit reversal and transfer-stage pacing on the iPhone, power and
accessibility settings, failure/retry, native success and a distinguishable local
replacement/relaunch with exactly one verified splash notice. No app is signed,
packaged or published to force that test.

## Changed production paths

- `Feather/Utilities/ZagUpdateProgressPresentation.swift`: timing, visual progress,
  formatting and exact success presentation policy.
- `Feather/Utilities/ZagUpdateTransferPresentation.swift`: scoped, phase-safe
  coalescing of real native percentages.
- `Feather/Views/Settings/ZagUpdateInstallerPresentation.swift`: structural stage
  observation, live transfer control and isolated developer details.
- `Feather/Views/Settings/ZagUpdateSpectrumSurface.swift`: geometry-only animation
  and independent visual interpolation; original drawing preserved.
- `Feather/Views/Settings/ZagSelfUpdateActionControl.swift`: one animation
  specification for label/shape; percentage transaction removed.
- `Feather/Views/Settings/ZagSelfUpdateStatusView.swift`: phase-only observation,
  measured-control child and no premature submission success.

Regression files: `scripts/ZagUpdateProgressAndMessageTests.swift`,
`scripts/ZagUpdateMorphRenderingTests.swift`,
`scripts/ZagUpdateTransferPresentationTests.swift`,
`scripts/ZagUpdateTransferCoreStub.swift`,
`scripts/test-zag-update-transfer-presentation.sh`,
`scripts/test-zag-update-morph.sh`, `scripts/test-zag-update-presentation.sh`,
`scripts/test-zag-post-update-integration.sh`.

Available results: 101 progress/message policy checks, 11 observer/coalescing
checks, 42 actual Canvas/control rendering checks, 38 presentation checks,
15 real streaming checks, 14 importer integrity checks, installation recovery
and post-update integration guards passed. All changed Swift files parse.
Targeted arm64 iPhoneOS UI and coordinator/integrity-harness type-checks pass
with dependency stubs; the core check retains only the pre-existing unused
`try?` warning in `ZagLogger`. Host SwiftUI builds retain the iOS 16.4-compatible
`onChange` overload, which newer host SDKs deprecate.
