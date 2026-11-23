# apple-auth as a standalone, Android-free iOS anisette/ADI implementation

Date: 2026-11-23. Branch: `claude-apple-auth-ios` (off
`feature/native-adi-provider-review`). No change to `main`, production signing,
BYOC, AppTesters or Zag Companion (PR #61). No Apple provisioning request was
issued; every result below is offline.

Primary question: can apple-auth give Zag Store a genuinely standalone,
Android-free anisette implementation on stock iOS? **On the evidence so far,
yes for the offline building blocks — proven on device. The one unanswered
question is Apple-side acceptance of a provisioning finish, which is unchanged
from the native-ADI line and requires a supervised live test.**

## 1. Phase A — source verification (no blocker)

apple-auth (`98c862f7…`, v0.1.3, MIT) is a **clean-room C++20 reimplementation**
of the ADI protocol, not a loader for Apple's platform libraries:

- `src/adi/{core,provisioning,key_derivation,parameters,mac,android,otp,state}.cpp`
  plus `src/crypto/*` (SRP, session crypto) and `src/sap/*` contain the actual
  algorithm (AES round-key derivation, provisioning mixer/seed, OTP). A search
  for `dlopen` / `LoadLibrary` / `libCoreADI` / `libstoreservicescore` /
  `.dylib` across `src` and `include` returns **nothing**. It loads no Apple
  binaries and emulates no Android library.
- Platforms are presets, not runtimes: `DevicePlatform::{windows,mac,iphone,android}`.
  The iPhone preset is `<iPhone15,2> <iPhone OS;17.4;21E219> <AuthKit/akd>`.
  Per upstream, the iPhone preset runs the **Mac** ADI algorithm with an iPhone
  client-info; native iOS ADI is explicitly not investigated. That is a
  client-identity question, not a code-availability one.
- **No private entitlements, no SEP/IOKit/Keychain, no privileged services.**
  The ADI "hardware id" is a software-derived hash (`hardware_id()` over host
  strings, with an `"apple-auth:hardware:v1:"` binding-domain fallback) — not a
  hardware attestation. On device we can pass the device's **real** model / iOS
  version / build; no impersonation of Apple hardware is required.
- Dependencies are iOS-portable: **Mbed TLS** (Apache-2.0) for the core; curl
  (desktop-only — iOS supplies its own transport), libplist (LGPL-2.1) and
  nlohmann-json (MIT) are client-layer only. **No Unicorn/QEMU** and so none of
  AnisetteKit's AGPL/GPL-only transitive-dependency concerns. libplist LGPL-2.1 is
  acceptable under Zag Store's GPL-3.0 (which satisfies the relink/source
  obligation); the on-device core we built does not even link it.
- Full Swift surface (`swift/AppleAuth`, `examples/ios_login.swift`):
  `Device(directory:platform:.iphone) → login(email:password:) →
  developerSession()` — the developer-services session is the hook into our
  existing portal/signing architecture.

## 2. Phase B — stock-iOS prototype (compiled and executed)

Built with `xcrun clang`/Xcode only (no CMake/vcpkg):

- Mbed TLS `v3.6.2` compiled for iOS arm64 (108/108 sources).
- apple-auth **core** compiled for iOS arm64 (the 17 `add_library(apple_auth)`
  sources, linking only Mbed TLS) — unmodified, all C-API entry points present.
- A SwiftUI app (`ZagAuthProbe`) calls the C API via a bridging header, signed
  with a **free Apple Account Personal Team** development certificate and its
  profile (applied with `codesign`, no Apple contact), installed on the
  iPhone 15 Pro Max (stock iOS 27) via `devicectl`.

On-device self-test result (sanitized), identical in shape to the host run:

```json
{"library_version":"0.1.3",
 "identity":{"status":0,"len":20,"nonzero":true},
 "state":{"key_len":32,"blob_len":76,"persisted":true,"roundtrip_ok":true},
 "otp_counter":{"status":0,"value":598490xx},
 "srp_client":{"status":0,"public_len":256,"nonzero":true},
 "provisioning_begin":{"status":2,"executed":true},
 "overall_ok":true}
```

What this establishes, running on the device with an ordinarily-signed app:

- Swift ↔ C ↔ C++ interop and the library execute on stock iOS.
- Local identity initialization (software hardware id).
- Persistent state: session key → `encrypt` → **persist to Documents** →
  reload → `decrypt` → byte-exact round-trip.
- Anisette OTP time-counter derivation.
- GrandSlam SRP client start (256-byte / 2048-bit client public value).
- The ADI provisioning entry executes and validates input (`status 2` on a
  synthetic challenge; a real Apple spim is required for success — not tested).

What this does **not** establish (stated plainly): it does not prove Apple
accepts a provisioning finish, and `provisioning_begin` producing/validating
material is not Apple acceptance. A synthetic challenge returning INVALID_DATA
is expected, not a success signal.

## 3. Phase C — minimum integration path (assessment only; not built)

The provider abstraction already supports this. `ZagAnisetteProvider.Kind` has
an `onDevice` case; `ZagAnisetteData` is a validated `X-Apple-*`/`X-Mme-*`
header set with a ≤60 s freshness window; `ZagAnisetteSource.anisetteData()` is
the single method to implement. apple-auth's `Profile.otp_header()` and
`machine_id_header()` produce exactly `X-Apple-I-MD` and `X-Apple-I-MD-M`.

Minimum path, behind the existing `onDevice` kind, with `ZagAnisetteLive`
staying gated off (`ZAG_LIVE_EXPERIMENT && ZAG_APPLE_BRIDGE && ZAG_ZSIGN_STRICT
&& !DEBUG`):

1. Vendor the apple-auth **core** (17 sources) + Mbed TLS as an xcframework or
   in-target sources; expose `c_api.h` to Swift (as the prototype does).
2. One-time per account: provision a `Device(platform:.iphone)` with the
   device's real attributes; persist the encrypted profile via
   `aauth_session_*` in the app's this-device-only Keychain.
3. Implement an on-device `ZagAnisetteSource` that returns a fresh
   `ZagAnisetteData` from the profile's OTP + machine-id headers.
4. `zag-apple-bridge` / `zag-isideload` consume anisette through the existing
   `AnisetteProvider` seam, so the GrandSlam/developer-portal and signing
   pipeline are unchanged; only the anisette *source* becomes on-device.

This replaces the remote anisette server and the Linux Android-CoreADI runtime
for the anisette role, without redesigning auth or signing.

## 4. How this relates to the native-ADI −29003 result

The native-ADI line failed at Apple's `midFinishProvisioning` (HTTP 401 /
ec −29003) with a macOS-declared client-info over an Android CoreADI runtime
(see `NATIVE-ADI-LIVE-RESULT-2026-11-23.md`). The SideStore report that
Android-ADI servers fail finish with −29003 while Mac-backed providers succeed
is consistent with that, but remains a hypothesis — not proof of the cause.
apple-auth's relevance: its iPhone preset uses the **Mac** ADI algorithm, which
is the "Mac-backed" class reported to succeed. That is the reason to test it,
not a guarantee. The November 503 `macOS;` vs `Mac OS X;` client-info issue is a
different authentication stage and is not assumed to explain our finish failure.

## 5. Remaining live validation (stop here — authorization required)

Everything above is offline. One tightly scoped supervised experiment would
answer the open question, changing the single variable of **ADI implementation**
(apple-auth Mac-algorithm core) while holding account, device and network
constant:

- Operation: provision a `Device(platform:.iphone)` through apple-auth on the
  device (or host harness) with a test Apple Account, i.e. `lookup →
  start-provisioning → finish-provisioning`, and stop at the first of: auth
  rejection, provisioning rejection (capture stage + sanitized ec), or a
  completed provision.
- What each outcome establishes:
  - **Finish succeeds** → the Mac-algorithm ADI is accepted where Android
    CoreADI was not; the standalone on-device anisette route is viable and
    Phase C becomes the implementation plan.
  - **Finish fails −29003 again** → the barrier is not the Android runtime
    specifically; it is broader (e.g. identity/client-info class), redirecting
    effort away from "swap the ADI runtime".
  - **Auth fails earlier** → an account/2FA/anisette-shape issue, independent of
    the ADI finish question.
- Constraints: one attempt, no automatic retry; no new device registration or
  certificate issuance; no credentials/tokens/identifiers logged or committed;
  no TLS weakening; stop and report on any auth/authorization rejection.

This experiment is **not** run here and requires explicit per-run authorization,
exactly as the native-ADI live test did.

## 6. iOS-platform vs implementation obstacles (unchanged framing)

- Platform-walled (not solvable by us): a sideloaded app obtaining the device's
  *genuine* on-device ADI via private AuthKit/`akd` (AltDaemonModern needs
  `com.apple.authkit.client.private` + jailbreak). We do **not** pursue private
  entitlements or sandbox bypass. apple-auth does **not** need these — it
  computes ADI itself in portable C++.
- Implementation/experiment (potentially solvable, pending Apple policy):
  whether Apple accepts an apple-auth-computed (Mac-algorithm) provisioning
  finish for a free account. That is the §5 experiment.

## Status

Offline success. No further large implementation until a direction is chosen.
The reproducible prototype is under `apple-auth-prototype/`.
