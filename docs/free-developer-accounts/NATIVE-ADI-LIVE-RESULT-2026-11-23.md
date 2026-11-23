# Native ADI — first live machine-provisioning result and next-experiment analysis (2026-11-23)

Owner-authorized, one live attempt on the Ubuntu x86_64 host (`zagstore`), then an
offline analysis phase. No Apple Account, credentials, 2FA, device registration
or certificate were involved; the attempt used account-independent machine
provisioning (`DS_ID = -2`). `main`, production signing and PR #61 are untouched.

## 1. The live result (sanitized)

```
PASS  lookup                 (Apple GsService2 URL bag)
PASS  start-provisioning     (Apple midStartProvisioning returned spim)
PASS  native Start           (our CoreADI consumed spim and produced cpim)
FAIL  finish-provisioning    Apple HTTP status 401 (Apple status ec = -29003)
      native Finish and persist were never reached; the attempt directory was
      removed, so no adi.pb was kept. One attempt, no retry.
```

### Two claims held explicitly as **unproven**
- `-29003` is **not** proven to be an environment/identity mismatch. That is one
  hypothesis among several (it is also consistent with Apple having closed this
  provisioning path to non-genuine-device ADI identities). The code only
  recognises `-29003` as an allow-listed numeric token; it assigns no meaning.
- `native Start` producing a `cpim` proves only that our CoreADI **ran** and
  returned bytes. It does **not** prove Apple considered that `cpim` valid — the
  finish request carrying it was rejected, and we cannot see Apple's reason.

What is established: the failure is **at Apple's `midFinishProvisioning`
response** (a well-formed HTTP 401 carrying an Apple status plist), not a crash
or transport error in our client, and not an authentication failure.

## 2. The metadata actually used, vs the runtime origin

| | Value |
|---|---|
| `client_info` (declared) | `<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>` |
| `user_agent` (declared) | `akd/1.0 CFNetwork/808.1.4` |
| provenance | upstream `anisette-v3-server-default` constant (Dadoum/anisette-v3-server), **unverified** |
| CoreADI runtime origin (from the libs' own ELF strings) | Android: `.note.android.ident`, `Android (… clang …)`, `com.apple.android.music`, `com.apple.StoreServicesCore` |

The declared client is the Apple **desktop** AuthKit/akd stack; the ADI library
is the Apple Music **Android** build. The two describe different platforms. The
`client_info`/`user_agent` strings are a public upstream constant, not private
device data; the machine identity (`device_id`/`local_user`) is a separate
synthetic file and is not reproduced here.

## 3. Can an Android-consistent config be built from *verified* metadata? **Not currently.**

`client_info` is `<model> <platform;version;build> <framework/version (process/version)>`.
- The **framework/process** group can be grounded legitimately in the libraries:
  the real process is `com.apple.android.music` with `StoreServicesCore`; the
  Apple Music app version is readable from the local `applemusic.apk` manifest
  (offline).
- The **device group** — Android device `model`, Android `version`, and `build`
  — are **per-device runtime properties**. They are not in the APK or the libs
  (the Android app composes them in Java from the real device at runtime, per
  `NATIVE_PROVISIONING_RUNBOOK.md`), and the `apk-inspection` directory is empty.

So a fully Android-consistent `client_info` **cannot be assembled from verified
sources we hold**. Supplying those device fields would mean **inventing device
attributes**, which is both disallowed and a confound: a rejection of an
implausible invented device would not distinguish platform from plausibility.
The legitimate source is a real Android device's Apple Music `client_info`.

## 4. Does the proposed experiment change only one variable? **No.**

A coherent macOS→Android switch changes the whole client identity at once —
model, platform, version, build, framework and process (six sub-fields). Changing
only the single `platform` token (`macOS`→`Android`) while keeping a `MacBookPro`
model and `akd` framework yields an **incoherent** identity — a worse mismatch,
not a cleaner control. There is no coherent single-variable form of this change;
it is inherently multi-field.

## 5. Can we retry `finish-provisioning` independently? **No.**

`provisioning_client` runs one session in fixed order — `lookup →
start-provisioning → native Start → finish-provisioning → native Finish →
persist` — and the `spim` from start-provisioning is session-bound; the `cpim`
is derived from it. There is no resume entry point. A new attempt **must repeat
lookup and start-provisioning**. (This corrects an earlier statement that we
could retry finish alone.)

## Proposed next experiment (contingent; **not** runnable from verified metadata yet)

**Change:** replace the `client_info`/`user_agent` pair with a **legitimate
Android pair captured from a real Apple Music install on an Android device**
(model, `Android;version;build`, and `com.apple.android.music/<appVersion>`),
keeping the same CoreADI runtime and the same synthetic machine identity, and
rerun the full provisioning sequence. This is blocked until such a verified
Android pair exists; it will not be fabricated.

**What each outcome would establish**
- `finish-provisioning` **succeeds** → the macOS/Android mismatch was the cause;
  our CoreADI + an Android identity is accepted by Apple for machine
  provisioning (a genuine provisioning breakthrough, server-side).
- `finish-provisioning` **still fails `-29003`** with a coherent Android pair →
  the mismatch hypothesis is refuted; Apple rejects this ADI identity regardless
  of declared platform (path likely closed to non-genuine-device ADI).
- Failure **moves earlier** (e.g. `start-provisioning`) → Apple treats the
  Android client differently at the start step; a separate finding.

**Exact one-shot live operation (requires approval; contacts `gsa.apple.com`):**
```
P=~/zag-adi-setup/zag-adi-review/AppleAuthCore/zag-anisette-server/tools/native-adi-loader-probe/target/release/zag-native-adi-loader-probe
~/zag-adi-setup/zag-adi-review/AppleAuthCore/zag-anisette-server/tools/native-adi-provision.sh \
  --probe "$P" --live --authorize-apple-contact --accept-unverified-metadata \
  --runtime         ~/zag-adi-setup/runtime \
  --state-parent    ~/zag-adi-setup/adi-experiment-state \
  --identity        ~/zag-adi-setup/adi-test-private/test-identity.json \
  --client-metadata <ANDROID_CLIENT_INFO.json>   # the verified Android pair
```
Same guarantees as the first attempt: anonymous machine provisioning only; no
account, credentials, device registration or certificate; one attempt, no retry.

## Does success with Android CoreADI translate to a native iOS implementation? **Only partially — not to self-contained iOS.**

- The CoreADI we run is the **Android** library producing an **Android** machine
  (ADI) identity on a server. Success would prove **our server** can obtain a
  working anisette identity from Apple — which serves the **remote-anisette**
  architecture (the iOS Zag Store client consumes anisette headers from our
  server; the server holds the ADI), **not** a device that provisions itself.
- A truly **native iOS** provisioner would need the iOS device's **own** ADI,
  which lives behind Apple's private, entitlement-gated AuthKit/`akd` frameworks
  that a sideloaded app cannot call. Android CoreADI cannot supply an iOS device
  identity.
- Moreover, upstream reports Apple rejecting Android-CoreADI headers at
  developer **sign-in** (`-80045`) even when provisioning succeeds, so a
  provisioning success would still have to clear the separate sign-in step.

**Net:** an Android-CoreADI provisioning success advances the *server-anisette*
model (useful, and the most credible standalone-iPhone route: iOS client +
our-server anisette), but does **not** yield a self-contained native-iOS
provisioning implementation. That goal remains blocked by iOS's private ADI.
