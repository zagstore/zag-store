# Saved pairing opens Zag Store without LocalDevVPN

Supersedes one rule of `docs/BETA3-PAIRING-LAUNCH-FIX-2026-11-15.md`: "the
main tab hierarchy cannot mount before positive verification". Everything else
there stands: the gate is process-local, a saved file is never treated as
verification, and every launch verifies again.

## Problem

With a saved pairing and LocalDevVPN disconnected, every cold launch showed the
first-run welcome. The launch check (`startGate2Probe(.localDevVPN)`) cannot
reach `10.7.0.1:49152`, so it ends `.unknown` or `.timedOut`, and only
`.verified` or Skip opened the app. Confirmed on the owner's iPhone on
16 Nov 2026: pairing files intact, the app log shows
`Gate2 health probe failed: Timed out reaching RPPairing at 10.7.0.1:49152`
on each launch, and connecting LocalDevVPN lets the app in at once.

## Rule

`ZagOnboardingPolicy` keeps three facts apart:

| | Meaning | Used for |
|---|---|---|
| `hasSavedPairing` | a record exists (not pending cleanup) | opening the main interface |
| `isPairingVerified` | a live check passed this session | pairing presentation |
| `isConnectionUnavailable` | the last check could not reach the device (`.unknown`, `.timedOut`, `.failed`) | re-checking on reconnect |

`canEnterMain` is a session latch for presentation only. Nothing outside the
app root reads it (checked by `test-zag-onboarding.sh`). Device operations
keep their own guards: `pairingFileExists`, no pending local cleanup and a
native pair-verify on every session.

| State at launch | Result |
|---|---|
| No record | First-run welcome, unchanged |
| Record, VPN connected | Main interface after the splash; the check verifies in the background |
| Record, VPN off or check times out | Main interface; pairing kept and shown as unverified, never as missing |
| Record rejected or unreadable (`.invalid`) | Main interface plus a "Pairing Needs Repair" alert: Repair Pairing opens the existing setup; nothing is removed |
| Record removed while running | Status becomes missing, any in-flight result is discarded, the open interface stays; the next cold launch shows the welcome |

## Reconnect

`ZagLocalVPNMonitor` already refreshes the toolbar connection status on path
changes and app activation (connect-only, no handshake). When its tunnel state
becomes `.operational`, the app root calls `connectionAvailable()`, which
re-runs the launch check once, and only if the last check could not reach the
device. A verified, rejected, missing or in-progress check is left alone, so
reconnects never queue probes. The check waits for native work as before, and
its single deadline is unchanged.

## Deep links

Still held until the splash finishes. With a saved pairing they are released
right after the splash instead of waiting for the network; actions they lead
to verify as usual. Without a record they wait behind the welcome as before.

## Device acceptance (not yet run)

1. With LocalDevVPN off and a saved pairing, cold-launch: the splash, then the
   main interface.
2. Connect LocalDevVPN: the badge turns ready, one check runs and
   Settings → Installation shows the pairing as verified.
3. Installing an app with LocalDevVPN off still fails with the existing
   unreachable message.
4. A rejected pairing shows the repair alert once.
