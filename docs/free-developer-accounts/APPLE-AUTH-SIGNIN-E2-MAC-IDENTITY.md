# E2 — consistent Mac-identity experiment (PREPARED, NOT RUN)

Tests the leading -22410 hypothesis (H1a in
`APPLE-AUTH-SIGNIN-COMPAT-22410.md`): the provisioned baseline presents **iPhone
client-info** while running apple-auth's **Mac** ADI algorithm; E2 presents a
**consistent Mac identity** (macOS client-info + Mac algorithm) and sees whether
GrandSlam init proceeds where the hybrid was rejected.

Status: **awaiting explicit per-run authorization.** No Apple contact. The
existing provisioned iPhone profile (`device` scope) is untouched; the Mac
identity lives in its own Keychain scope (`mac-experiment`).

## What actually differs (source fact, not assumption)

In apple-auth both `DevicePlatform::iphone` and `::mac` map to
`ProfilePlatform::mac`, so they share the **same** Mac ADI algorithm, the same
identity derivation (`local_user_hash = base64(device_id)`), the same request
construction and the same restricted transport. The **only** difference E2
introduces is the `X-MMe-Client-Info` / device fields:

| | baseline (`device`) | E2 (`mac-experiment`) |
|---|---|---|
| client-info | `<iPhone15,2> <iPhone OS;17.4;21E219> …akd` | `<MacBookPro18,3> <macOS;13.1;22C65> …akd` |
| ADI algorithm | Mac | Mac (identical) |
| `X-Apple-I-MD-LU` | base64(device_id) | base64(device_id) (identical) |
| serial | absent | absent |

So E2 changes exactly one variable — the declared OS environment — making the
client-info **consistent** with the algorithm it already runs. No fabricated
hardware attestation, no private entitlement, no claim of genuine Mac hardware:
it is apple-auth's default *software* Mac identity, exactly as the iPhone one is
a software identity.

## Preparation (done, offline)

- `ZagAppleAuthPlatform { iphone, mac }`; `ZagAppleAuthMachine(scope:platform:)`
  threads the platform through the single `withClient` client builder (→
  `AAUTH_DEVICE_MAC`, `iphone_device = nil`), so provisioning **and** sign-in on
  one machine instance use the same platform by construction (no cross-phase
  drift). Baseline default stays `.iphone` / `device`.
- `ZagAppleAuthMachine.clientInfoConsistent(headers, platform:)` — offline
  assertion that the anisette client-info names the platform's OS token
  (`macOS` vs `iPhone OS`). Wired into the provider path and the provision step.
- Harness reuse: the same `ZagOnDeviceAnisetteProvider`,
  `ZagAppleAuthMachine.signInExperiment`, bounded transport (≤6, no redirect, no
  retry, no fallback), 2FA detect-and-cancel, Keychain credential store and
  sanitized reporting. App gates: `ZAG_RUN_MAC_PROVISION` and
  `ZAG_RUN_MAC_SIGNIN`, each writing a sanitized JSON result.
- Validation, no Apple contact: host tests 32/32 (incl. the consistency
  matrix); the full Mac harness compiles **and links** for `arm64-apple-ios`;
  an offline on-device run confirmed isolation —
  `{iphone_baseline_header_count:10, iphone_consistent:true,
  mac_scope_provisioned:false, mac_offline:"not-provisioned"}`.

## Exact live sequence (two separate authorizations)

**Step A — provision the Mac identity** (`ZAG_RUN_MAC_PROVISION=1`):
1. `POST …/lookup/anisette` provisioning handshake → stores the Mac profile in
   the `mac-experiment` scope. Proves the Mac environment can be provisioned
   on-device (parallels the proven iPhone provisioning). Reports header count +
   `client_info_consistent`.

**Step B — one bounded GrandSlam sign-in** (`ZAG_RUN_MAC_SIGNIN=1`), only after
A succeeds and a separate authorization:
2. `POST …/grandslam/GsService2` SRP **init** (A2k + username, Mac anisette in
   `cpd`). **This is the discriminator.** Proceeds (salt + B returned, or a
   *different* code) ⇒ the iPhone/Mac client-info mismatch was the cause of
   -22410 (H1a confirmed). Still `-22410` at init ⇒ the hybrid was not the
   cause; the clean-room anisette is rejected regardless of a consistent
   environment (H1b), pointing to E3/E1 or a deeper gap.
3. `POST …/grandslam/GsService2` SRP **complete** (M1) — only reached if init
   proceeds; bounded, no retry. Stops after this regardless of outcome.

## Can this be done without modifying the working profile?

**Yes.** E2 provisions and signs in entirely within the separate
`mac-experiment` Keychain scope. The `device`-scope iPhone profile is never
read-for-write, re-provisioned or overwritten — the offline on-device run above
confirms it still derives its 10 consistent headers and the Mac scope starts
empty. Nothing in E2 can regress the proven baseline.

Objective unchanged: standalone on-device authentication — no Android libraries,
no Mac companion, no external anisette server. E2's "Mac identity" is only the
client-info string the on-device engine already had the algorithm for.
