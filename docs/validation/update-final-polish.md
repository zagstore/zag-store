# Update control final polish — 16 November 2026

This records the `ab4ee2e8` baseline. For the subsequent morph/transfer isolation
and exact completion wording, see [Symmetric update morph](update-symmetric-transfer.md).

Baseline: `232bc2d2` + `d2237fdc`. This is a presentation correction; the
coordinator, native installer, persisted update proof, splash implementation,
security policies, manifests, version/build and signing configuration are unchanged.

## Evidence and root causes

The 11:44:12 AM screenshot was visually inspected alongside the approved
9:56:32 AM screenshot. The header and main section geometry match. The new empty
area between Update Now and Learn More comes from the control's permanently
laid-out hidden status paragraph plus its 8 pt VStack gap. Removing that hidden
paragraph restores the actual 54 pt idle control; the existing card's 18 pt
spacing and Learn More's 44 pt touch target remain verbatim. The main sections
still have their approved 16 pt gap. No offsets or negative padding are added.
Busy/terminal status uses only its real intrinsic text height. The accepted
54→14 pt capsule morph slot is preserved; it no longer reserves a second,
invisible status region underneath it.

The 11:44:30 AM MP4 exists and reports approximately 20.1 seconds. AVFoundation
cannot decode its frames (`-11821`, underlying `-12911`). No recording frames were
reviewed; screenshot evidence and production-renderer pixel tests are distinct
from motion/profile evidence. The previous software-decoder download attempt
was blocked by unavailable DNS; no dependency was added to the repository.

The old gradient translated both endpoints negatively as phase increased,
which moved its features right-to-left. Endpoints now move positively from
`width * (phase - 1)` to `width * (phase + 1)`. Two repeated spectrum cycles keep
the visible interval covered and the five-second wrap seamless. Actual rendered
pixels verify that an identical feature moves right, independently of progress.

The old morph could blend several partially transparent layers without an
opaque filled backing, and its white gloss reached 48% opacity. In addition,
applying `.disabled` to the complete native button allowed disabled appearance
to affect the artwork. Filled morph frames now have an opaque backing; at full
compression the spectrum itself is opaque. The gloss peaks at 12%. Busy
activation is blocked by hit-testing, action guards and accessibility traits,
without disabling/dimming the entire renderer. Pixel tests on a transparent
background require alpha 255 at idle, intermediate morph and progress states.
Unfilled track translucency is intentional and remains distinct.

## Rendering/performance boundary

The palette and five-second rim/flow, continuous geometry and real progress
remain intact. Cached Gradient values and the small isolated TimelineView
remain; it still uses system animation cadence with no 60 Hz cap. Low Power
Mode, Reduce Motion, inactive scene and idle/terminal states pause decoration.
The tiny Canvas now presents synchronously with its parent display frame,
removing an additional asynchronous presentation path. A redundant full-fill
backing draw is omitted in steady progress. No blur, per-frame text layout,
Markdown parsing, artificial percentage, extra model publication or parent
animation is introduced. Existing 10 Hz byte sampling and background hashing
are unchanged.

These are structural reductions in compositing/presentation work, not proof of
120 fps. `devicectl list devices --timeout 10` aborts with exit -6 before listing
any device; earlier `xctrace` discovery also failed. No actual-device frame-time
profile or post-change ProMotion acceptance test is available. It remains
necessary to check on the iPhone under normal/Low Power/Reduce Motion conditions.

## Terminal state and restart interaction

The earlier label **View Installation Steps** was the deliberate presentation of
native 209 (file staged/size-checked), not a missing installation-success callback.
209 is not proof that Upgrade completed. The following native call combines
request submission and waiting for iOS, and may not return before iOS replaces
the running process. This presentation correction does not manufacture an event.

| State | Capsule | Visible status |
|---|---|---|
| Staged transfer | Reopen After Installation... | Signed IPA transferred. Reopen Zag Store after iOS finishes installing. |
| Successful installer return | Reopen After Installation... | Update handed off to iOS. Reopen Zag Store after installation. |
| Ambiguous/unverified installation | Reopen to Check Update | Installation not verified. Reopen Zag Store to check. |
| Fresh installed identity proof | Restart to Complete... | Update completed. Please restart Zag Store. |

The normal flow no longer presents the Installation and Reopening alert. A
terminal capsule tap reveals one short App Switcher instruction **inline** and
moves accessibility focus to it. It neither starts a second update nor claims to
close/restart the process. Busy taps are ignored. The existing verified-status UI acknowledgement is saved
when leaving that panel, keeping the inline steps visible while it is open;
the cinematic one-shot acknowledgement is unchanged. Recovery confirmations and
the advanced test-candidate replacement safeguard remain unchanged. Long
explanations are visible only in the existing developer diagnostics area.

There is no supported public graceful self-termination/restart API:
https://developer.apple.com/library/archive/qa/qa1561/_index.html
No exit, abort, suspend selector, private URL or artificial crash is used.

## Post-update splash: what is tested

The actual `ZagPostUpdateMessage`/store policies are executed, not just inspected:

- Distinguishable synthetic A→B release identities with matching target hash
  create the dynamic message; wrong/current-old hashes and IDs do not.
- Same-version/build replacement is rejected even with a different executable.
- Failed/cancelled and interrupted replacements create no success notice.
- A persisted handoff without installed proof creates no splash notice.
- Pending notices survive store recreation and skipped/unacknowledged reveals.
- Successful display acknowledgement consumes the notice; a recreated store
  representing the next ordinary launch has no message.
- Stable, Beta and Nightly generate the actual supplied version/channel/build in
  exactly three reveal groups. No `1.0.0 Beta 3` constant is introduced.

Source integration checks additionally preserve the fresh running executable
proof and actual final-reveal callback guards. These **do not establish a real
installed A→B update or an actual iPhone cinematic reveal**. Those remain
unverified. No test app or IPA is built, signed or installed under this task's
restrictions; the existing published Beta 3 artifact is not changed. The isolated
future local-build plan remains in `update-progress-and-post-update.md` and must
use test-only configuration/metadata rather than production version changes.

## Changed files and available validation

Production changes:

- `Feather/Utilities/ZagUpdateProgressPresentation.swift`: concise terminal labels,
  truthful status and short manual reopening instruction.
- `Feather/Views/Settings/ZagSelfUpdateActionControl.swift`: intrinsic status layout,
  opaque interactive treatment and inline instructions.
- `Feather/Views/Settings/ZagUpdateSpectrumSurface.swift`: opaque fill, restrained
  gloss, source-correct left-to-right flow and reduced presentation work.
- `Feather/Views/Settings/ZagSelfUpdateStatusView.swift`: remove normal modal wiring,
  keep detailed explanations in existing diagnostics.

Tests: `ZagUpdateProgressAndMessageTests.swift`,
`ZagUpdateMorphRenderingTests.swift`, `test-zag-update-morph.sh`,
`test-zag-update-presentation.sh`, `test-zag-post-update-integration.sh`.

Run the above plus `test-zag-update-progress-and-message.sh`,
`test-zag-self-update-recovery.sh` and `test-zag-import-integrity.sh` with a writable
module cache. Rendering/layout checks use the real production Canvas and control
on the host, with only the UIKit-specific theme conversion adapted for macOS.
They verify compact idle/busy/terminal layout, alpha, saturation, direction,
intermediate geometry and Dynamic Type growth. Targeted arm64 iPhoneOS SDK
checks exercise the actual update view/helper code and unchanged coordinator
against external dependency stubs; they are not a full linked app or device run.

Available checks passed: 84 byte-progress/message policy checks, 41 actual Canvas
and control-layout checks, 38 release-note/presentation checks, 15 real streaming
checks, 14 importer integrity checks, installation recovery tests and source
integration guards. All changed Swift files parse. Arm64 iPhoneOS SDK type-checks
pass for the update/splash UI and coordinator/integrity harness with external
dependency stubs. The core check emits only the pre-existing unused `try?`
warning in `ZagLogger`; the host render build retains the compatible iOS 16.4
`onChange` overload, which is deprecated on newer host SDKs.
