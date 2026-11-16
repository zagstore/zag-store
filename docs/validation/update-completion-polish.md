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

The App Switcher instruction on tap is removed. The final capsule is not
actionable (`isActionable` is true only for `.idle`); hit testing is off and
VoiceOver reads it as static text.

## Closing the app on tap

There is no public iOS API for an app to terminate or relaunch itself.
`exit()` is unsupported for user-facing apps (Apple QA1561) and is excluded by
the owner; `UIApplication.suspend` is private;
`UIApplication.requestSceneSessionDestruction` closes a scene on iPad
multi-window, not the process on iPhone, so the original executable would keep
running. The tap therefore does nothing, and the status line tells the user what
to do.

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

