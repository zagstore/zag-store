# Verified-staging completion and transfer-stage cadence

Baseline: `95edee07` (Codex), consolidated into the Claude branch by fast-forward.
No native (Rust) code, signing, metadata, trust store, rollback store, splash
artwork/timing/sound or version/build setting is changed.

## Device evidence

Frames were extracted from the 16 November recordings (9:57, 11:04, 11:44,
12:18 and 1:09 PM, iPhone 15 Pro Max). The status text identifies the native
callback that was last applied:

| Status shown | Native callback |
|---|---|
| `Transferring signed IPA... 88%` | 208 (transfer percentage) |
| `Signed IPA transferred. Reopen Zag Store after iOS finishes installing.` | 209 (`Signed IPA fully staged and size-verified on device`) |
| `Installing update... N%` | 206 (installer percentage) — never seen |
| `Restart to Complete...` | 207 (native completion) — never seen |

In every recording the control stays in the 209 state until the recording ends
(at least 8 s at 1:09 PM) with the app in the foreground and the gradient still
animating. iOS sends no installer progress or completion while Zag Store stays
open. `InstallationProxyClient::watch_completion` waits on `read_plist()` with no
timeout, so the native call does not return.

## A. The final capsule never appeared

`95edee07` selected the final capsule only when the native installer call
returned (207) and kept callback 209 in a busy, thin-bar state. On the device
207 never arrives while Zag Store is open, so the bar stayed indefinitely.

Correction (owner decision, 16 November): verified on-device staging ends the
in-app operation.

- `ZagRPPairingCore.installGate4IPA` takes a `staged` hook, called for callback
  209 in the same main-thread turn as the `.staged` stage change and cleared on
  completion, failure and start-up failure.
- `ZagSelfUpdateCoordinator` records `ZagUpdateHandoffState.stagedOnDevice`
  from that hook, only while this attempt is `.waiting`.
- `ZagSelfUpdateActionState.pendingAttempt(...)` derives the control from the
  coordinator's handoff state: `.stagedOnDevice` or `.reportedComplete` →
  `.handedOff`; `.uncertain` → `.awaitingVerification`; otherwise busy. The view
  no longer reads raw 209/210 stages to choose an outcome.
- A later installer error (-4) still replaces the success state with
  `.uncertain` (pending record kept) or `.none` (record released by the retry
  policy). Late 206 percentages cannot pull the capsule back into a bar.
- `.awaitingVerification` is now a still capsule, not an endless bar, and has no
  status line repeating its title.
- The capsule morph is unchanged: one geometry channel, 0.42 s, cubic
  (0.42, 0)–(0.58, 1) in both directions.

## B. Exact strings

`.handedOff` is the only state with either string:

- capsule: `Restart to Complete...`
- status: `Update successful. Reopen Zag Store to complete.`

`awaitingHandoff` (unreachable) and `confirmed` were removed. `confirmed` showed
`Restart to Complete...` inside the post-relaunch "Zag Store Updated" card, after
the replacement was already running; that card now ends with its verification
text. The inline App Switcher instruction after tapping the capsule is kept; no
popup, diagnostic button, private API, `exit` or forced termination is added.
Installed-identity proof for the splash is unchanged.

## C. Transfer-stage stutter

Download progress is sampled at 10 Hz and observed only by the update screen.
Transfer progress arrives as native callback 208 on the main thread, up to once
per percent. Each callback assigned `@Published gate4State` and
`@Published gate4LastEvent`, wrote UserDefaults with a new ISO 8601 formatter and
logged. The root `VariedTabbarView` (presenter of the update sheet), the live
Library tab, Settings diagnostics, Installation screens and Sources download
buttons observe the whole pairing core, so every percentage re-evaluated those
hierarchies while the gradient was animating. This main-thread work occurs only
in the transfer and installer phases, matching the observed stutter.

Correction:

- `gate4State` stores every exact value and sends it to `gate4StatePublisher`
  (used by the update presentation), but invalidates whole-core observers only on
  a stage change, every ten percentage points and at 100
  (`ZagGate4PublicationPolicy`). One transfer: 11 invalidations instead of 101.
- Diagnostic records and logs for percentages use the same cadence; the retry
  policy still receives every event.
- The root tab view observes only `installedAppsState` through an empty
  background observer with the original `onChange` handler.

Measured on the host: `pthread_create` threads (the Rust worker) do not inherit
the creating thread's QoS on Darwin; they run at default QoS, below the UI
thread, so worker priority was ruled out as a cause.

Not changed: the spectrum, full opacity, left-to-right flow, five-second clock,
morph geometry, `TimelineView(.animation)` cadence and ProMotion opt-in. No frame
rate is claimed; device verification is required (see below).

## Tests

- `test-zag-update-progress-and-message.sh`: replays the device sequence
  (transfer, 209, silence; late 206; 207; error after staging) through the
  production derivation.
- `test-zag-update-transfer-presentation.sh`: every exact percentage reaches the
  presentation in order; whole-core invalidations are 11 for 101 callbacks;
  stored state is exact; root observation is scoped.
- `test-zag-update-morph.sh`: native transport unchanged; Swift core changes
  limited to publication cadence and the 209 hook; callback invariants kept.
- `test-zag-post-update-ab.sh`: local A→B with two real, distinguishable
  executables through the production hasher and one-shot store.

## Remaining device checks

1. Update to a build containing this branch: bar → capsule within 0.42 s of 209,
   with both exact strings, and the reverse of the entry morph.
2. Close and reopen: the new build runs; one splash `Updated to <version> <channel>`.
3. Next ordinary launch: `Sideloading and beyond.`
4. Transfer-stage smoothness with Instruments (Animation Hitches / Core
   Animation FPS) on the iPhone 15 Pro Max, Reduce Motion and Low Power Mode.
5. A failed attempt (e.g. LocalDevVPN off before starting): no success wording;
   the capsule returns to `Update Now` with the error, or to the unverified
   capsule with "Previous update not confirmed" recovery when the record is kept.
