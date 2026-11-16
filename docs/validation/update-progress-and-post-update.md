# Update progress and verified post-update messaging

The update header centres its existing text stack against the unchanged icon.
Section spacing remains the measured 16 pt; release notes and links retain their
approved layout. Normal Update Now directly invokes the existing certificate,
verified download/import/signing and upgrade-only installation path. Explicit
internal diagnostics and system installation permissions retain their checks.

## Progress

The previous UI swapped a full-width button for a separately sized animated
rainbow container. Its repeating gradient and competing geometry animations,
eager Markdown parsing during publications, and synchronous cached/executable
hashing were identifiable sources of layout churn and main-thread stalls. No
runtime frame-time measurements are available in this environment.

One persistent capsule button now contains one label and one native progress
meter. Its material crossfades over 0.24 seconds; measured fractions interpolate
linearly over 0.1 seconds. Reduce Motion disables these animations. The normal
minimum height is 54 pt, with Dynamic Type permitted to increase it.
URLSession's serial delegate queue streams, writes and hashes real bytes;
publications are limited to 10 Hz plus first/final observations. Unknown lengths,
verification, import, signing and handoff use indeterminate activity, never a
fabricated percentage. Cached package and installed-executable SHA-256 work runs
in cancellable utility tasks. Markdown parsing is retained once per release.
Operation locks reject repeated taps. Generation/token checks reject stale
publications and prevent preference changes from submitting an obsolete update.

## What is proof

A verified download proves its SHA-256 only. The existing installer callback
proves the outcome reported by that service, not that this running process has
been replaced. Handoff therefore asks the user to reopen to verify installation.
Only a subsequent running bundle/version/build and executable SHA-256 matching
the staged candidate, and differing from the original executable, can publish
`Update completed. Please restart Zag Store.` and the final action.

`Restart to Complete...` opens explicit manual App Switcher close/reopen guidance;
it does not terminate or relaunch the process. Apple provides no public graceful
self-termination API: https://developer.apple.com/library/archive/qa/qa1561/_index.html

The pending handoff persists its validated discovery channel. A successful
identity reconciliation persists a three-group cinematic caption derived from
the actual installed version/build and recorded channel. Legacy records without
channel metadata never guess one. The notice survives skipped, disabled,
interrupted or late-verification splashes; only the completed final caption
reveal while visible/foreground acknowledges it. Subsequent launches use the
original caption. Video, sound, artwork and reveal timing remain unchanged.

## Validation

Run `scripts/test-zag-update-progress-and-message.sh`,
`scripts/test-zag-update-presentation.sh`,
`scripts/test-zag-post-update-integration.sh` and
`scripts/test-zag-self-update-recovery.sh` (with a writable Swift module cache).
The first runs Foundation policy tests and real URLSession/CryptoKit fixture
transfers. Integration assertions supplement, rather than replace, runtime QA.
Targeted arm64 iPhoneOS SDK type-checks exercise the actual coordinator and
UI/splash code with external installation/CoreData dependency stubs; no app is
signed or packaged.

Device verification remains required: actual installation/relaunch and once-only
caption, all channels, standard/reduced/skipped/disabled splash, interrupted
handoff, network cancellation, repeated taps/channel changes, VoiceOver/Dynamic
Type and perceived progress fluidity. Simulator discovery is bounded; an
unavailable CoreSimulator is not repaired as part of this task.
