# Software update completion polish

Baseline: `983e8dc4`. Device feedback (iPhone 15 Pro Max, 16 November, 1:57 PM
recording and 1:58 PM screenshot): the transfer gradient is smooth and the
bar → pill morph works. Both are preserved: no change to the transfer cadence,
the spectrum, its five-second left-to-right flow, the opaque fill or the morph
geometry and curve.

## Morph

`ZagUpdateMorphSpecification`: 0.35 s (was 0.42), same cubic
(0.42, 0)–(0.58, 1), one shared specification for pill → bar and bar → pill.
The curve is symmetric under time reversal, so the entry is the exact reverse
of the exit. The label opacity and the Canvas `morph` value still share one
`.animation(morphAnimation, value: state.showsProgress)` each; Reduce Motion
removes the animation.

## Status line

`ZagSelfUpdateActionState.statusLine` is a message plus an optional measured
percentage (`ZagUpdateStatusLine`). The control keeps its own presentation of
it:

1. On a new stage or a morph starting, the visible line fades out
   (ease-in, 80 ms). The outgoing line's space is kept until the geometry
   settles, so the card does not change height during the morph.
2. The incoming line is laid out invisibly.
3. The capsule's arrival is observed, not timed: `ZagAnimationArrival` is an
   `Animatable` modifier on the label, under the morph's own transaction and
   curve. SwiftUI sets its `animatableData` for every interpolated frame and
   finally to the exact target.
4. After a 65 ms pause the line fades in (ease-out, 130 ms). The stage crossfade
   is 210 ms in total.

A generation token cancels a pending reveal when anything changes in the
meantime, so interruptions and repeated changes never show an outdated line.
Under Reduce Motion the arrival is reported directly when the geometry changes.
The choreography reads only its own stored targets, because `onChange` actions
and deferred blocks can see a stale `state`.

Same-stage changes (only the percentage) neither fade nor re-reveal. The digits
roll with `ZagNumericTextTransition`, which is the Sources app-count technique
(`contentTransition(.numericText(value:))`, iOS 17+, a short ease on 16.4),
moved to `Feather/Views/Common` and shared by both. Each stage is its own text
identity, so digits never morph into the next message. The Canvas, the gradient
clock and the coalesced 10 Hz transfer progress are untouched.

## Success green

Source: the Zag Store website's BYOC installer,
`wp-content/plugins/zagstore-byoc-installer/assets/digital-seal.css`
(the same token appears in the production-synced copy):

```css
--zds-green: linear-gradient(100deg, #1fe27e 0%, #00c565 50%, #00a352 100%);
```

CSS hex is sRGB, so the stops are built with `Color(.sRGB, ...)` (no system
green). The gradient line follows CSS `linear-gradient(100deg)` geometry
(`ZagUpdateSuccessPalette.gradientLine`). The label stays white with the
website's ink shadows, `rgba(4, 8, 32, .28)` 0 1 px 1 px and `rgba(4, 8, 32, .16)`
0 0 16 px, as on the website's success label. Contrast of white on the stops is
1.7–3.3 : 1. It is a large semibold label with the website's shadow, matching
the website; a dark label would read 6.4–12.2 : 1 but would no longer match it.

The transition is the website's success wave (`.zds-success`): green arrives as
one feathered front travelling left to right over the spectrum, with a soft
crest of light (`rgba(255,255,255,.24)`) only while it travels. Here the wave's
progress is `1 − morph`, so it is driven by the same animation as the geometry
and settles exactly when the capsule does. It needs no extra clock or state.
At rest the capsule is pure green under the existing gloss, fully opaque.

`showsSuccess` is true only for `.handedOff` (verified on-device staging or
native completion). Idle, busy, failed, cancelled, `awaitingVerification` and
any installer error are never green.

## Strings and tap

- Capsule: `Restart to Complete...`
- Status: `Update successful. Reopen Zag Store to complete.`

The App Switcher instruction on tap is removed. (Superseded below: the
capsule now ends the process.)

## Restart to Complete ends the process (follow-up)

There is no public iOS API for an app to terminate or relaunch itself;
`UIApplication.suspend` is private and scene destruction does not end the
process on iPhone. The owner has explicitly authorised `exit(0)` for Zag
Store's sideloaded distribution. `exit(0)` is an unsupported iOS lifecycle
operation (Apple Technical Q&A QA1561) and may not be acceptable for other
distribution channels. It is a normal exit, not a crash: no `abort`,
`fatalError`, signal or private API.

- The same control and rendering: in the success state the existing button
  becomes interactive once its presentation has settled (capsule arrived,
  success line visible). Nothing visual changes; the whole capsule is the tap
  target, with the same touch tolerance as `Update Now`.
- `ZagUpdateCompletion.allowsTermination`: the action state is `.handedOff`, the
  coordinator's handoff is `.stagedOnDevice` or `.reportedComplete`, and the
  pending-installation record exists. Staging (209) comes after signing,
  hashing and the complete, size-verified transfer, so none of those is still
  running. Every other state (idle, busy, failed, cancelled, unverified) is
  refused.
- At most once: the control ignores further taps, and `complete` refuses a
  second request.
- Persistence: the pending record (expected and originating executable hashes)
  is written to preferences before the transfer begins. The tap only calls
  `UserDefaults.synchronize()` before `exit(0)`. Nothing is marked installed and
  the one-shot splash is not touched. On the next launch the existing
  executable-hash verification alone decides whether `Updated to <version>
  <channel>` appears; a failed install, same-build reinstall or unchanged
  executable does not show it.

Superseded for Beta 4 (see "Upgrade acknowledgment" below): success, and with
it `Restart to Complete...`, now waits for installation_proxy's own answer to
the Upgrade request, not for staging (209).

## Upgrade acknowledgment (Beta 4)

Previously callback 209 (staged) ended the operation, before the native layer
had even opened installation_proxy, and nothing reported the Upgrade request.
Writing the request is not proof either: until installd reads it, the bytes can
die with the process, and installd can still reject it.

The self-update path in `RPPairingCore/rust-core/src/lib.rs` now runs the
Upgrade exchange itself (`run_self_upgrade`) instead of the crate's
`upgrade_with_callback`, which discards replies that carry no percentage. Same
command, framing and connection as the crate (`upgrade_command_frame` produces
the identical `{Command, ClientOptions{CFBundleIdentifier}, PackagePath}` XML
plist, length-prefixed):

- 210: the request was written and flushed. Never success.
- 211: installd's first reply without `Error`/`ErrorDescription`. This is the
  acknowledgment: iOS has the request and is processing it.
- 206: each `PercentComplete`; 207 after `Status` `Complete`, as before.
- Any `Error` or `ErrorDescription` (before or after 211), an invalid frame or
  a closed stream ends the attempt with -4.

No timers in the native exchange. Other bundle IDs keep the crate's helper.

Swift: 209 is only a stage. 210 records `gate4SelfUpdateCommandSent` and starts
a bounded wait (`ZagUpgradeAcknowledgement.timeout`, 20 s); 211 moves the
handoff to `.acceptedByInstaller`, the only new success state. A request still
unanswered at the timeout becomes `.unacknowledged`, shown as "Installation not
verified" and never green; a late 211 still counts. Errors keep the existing
recovery (`.uncertain`, or `.none` when the retry policy proves nothing was
sent). Late callbacks and timeouts are tied to their attempt.

Tests: 8 native `self_upgrade_tests` (frame equals the crate's command; 210
then 211 on the first error-free reply; status without a percentage; immediate
string, integer and description-only rejections never acknowledge; a later
rejection fails; silence or EOF is not an acknowledgment; a failed write emits
nothing; oversized and non-dictionary replies). Swift: the acknowledgment and
timeout transitions, 209 and 210 alone stay a progress bar, an unanswered
request is never success, and termination only after `.acceptedByInstaller` or
completion. Device check: on the iPhone, confirm 211 arrives in the foreground
(the Gate4 history shows `Gate4 callback 211`) before iOS replaces the app.

## Validation

- `test-zag-update-progress-and-message.sh`: duration 0.34–0.36 and the
  unchanged curve; time-reversal symmetry; status line and stage logic; pause
  50–80 ms and crossfade 150–220 ms; exact palette and CSS gradient geometry;
  the wave travels left to right and is fully opaque at rest; the crest only
  during travel; green only for `.handedOff`; only `Update Now` acts.
- `test-zag-update-morph.sh`: production Canvas pixels. The resting success
  capsule matches the website gradient at three points (within the gloss), is
  opaque, is green on the left and spectrum on the right mid-wave, green
  coverage grows monotonically with the return, and the ordinary capsule is not
  green. Source checks: tracked arrival (no delay derived from the duration), a
  single `onChange`, no stale `state` reads, no `disablesAnimations`, the shared
  digit transition, no system green, no sheet/popover/exit.
- `test-zag-update-choreography.sh` (new; simulator): the production control
  sampled on screen every other display frame:
  - no new status text while the capsule is mid-morph;
  - the first line appears after the bar arrives;
  - the old line is gone before the capsule settles;
  - the success line appears after it;
  - percentages never fade the line or move the bar;
  - the settled centre is #00c565 (±16);
  - an interrupted morph shows no stale line and is not green.

  Sampling runs at about 10 Hz in the simulator, so it checks ordering and
  invariants, not durations.

## Remaining device checks

1. Pill → bar and bar → pill both feel like 0.35 s, with no snap or overshoot
   (Instruments: Animation Hitches on the iPhone 15 Pro Max).
2. The green wave reads as smooth on device, with no banding or bloom.
3. The status line appears just after each morph, never overlapping the old
   line; transfer percentages roll their digits without stutter.
4. Reduce Motion: instant geometry, short opacity fades only.
5. Low Power Mode: the gradient pauses; the green state is still correct.
6. Interrupted morph (a stage change within ~0.1 s of tapping): a two-line
   title can briefly overhang the shrinking capsule while the labels crossfade.
   This was already the case at `983e8dc4` and only occurs on this path.
7. Restart to Complete on the iPhone: Zag Store exits; how SpringBoard and the
   App Switcher present this, and whether iOS then completes the upgrade, have
   not been observed on a device.

## Card tap boundaries (follow-up)

Device report: tapping the green `Restart to Complete...` capsule opened Learn
More. Root cause, reproduced with real coordinate taps
(`test-zag-update-card-taps.sh`): the capsule and the Learn More `Link` share one
Form section row. In a Form/List row, a default-styled button or link makes the
whole row its tap target. The final capsule (and the busy bar) are deliberately
not hit-testable, so taps there — and on empty card space — fell through to the
row and activated the link. The frames never overlapped. Fix: the link, now
`ZagSelfUpdateLearnMoreLink`, uses `.buttonStyle(.borderless)` so it responds
only within its own frame. A simulator screenshot of the card is pixel-identical
before and after.

## Bar end clipping (follow-up)

Device report: both rounded ends of the progress bar were cut flat. Root cause:
the capsule path spans the Canvas's full width, and its halo (5 pt) and rim
(1.5 pt) are stroked centred on that edge, so half of each lies outside the
Canvas, which draws only inside its own bounds. No ancestor clips. Fix: the
Canvas extends `ZagUpdateSpectrumSurface.drawingOutset` (4 pt) past the layout
frame on every side (`.padding(-drawingOutset)`), and the shape is drawn at
exactly the same coordinates. Layout, width, height, radius, glow, spectrum,
morph and the success capsule are unchanged.

Measured on screen in the iOS simulator (`test-zag-update-choreography.sh`):
with the old bounds the bar's visible extent is exactly the 360-point frame
(0…359, clipped); with the fix it is −3…362, the same at both ends, while the
resting success capsule still fills exactly 0…359. On macOS the host renderer
does not clip a Canvas, so `test-zag-update-morph.sh` instead checks that the
strokes stay within the outset, equal at both ends, across bar and intermediate
morph frames.

