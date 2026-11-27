# Zag Installer

## Physical verification record

On 27 November 2026 the operator ran all seven original installer tests, verified the official unsigned Zag Store Beta 3 IPA against the pinned release digest, and installed the independently validated Personal Team-signed IPA over trusted USB using Zag Installer from commit `6aa2fc7d7d089c5e0066a947d762917b9a05f1e1`.

CoreDevice confirmed bundle `app.zagstore.ios.FTB8PRW638`, version `1.0.0`, build `3`. This physically verifies the USB developer installation and inventory readback path. Launch confirmation is a separate test and remains unrecorded. The successful install occupied that mapped destination.

The operator subsequently confirmed a successful standalone end-to-end macOS installation with the clean-room anisette integration. This records a physical result for desktop Apple authentication, provisioning, signing, validation and USB installation. The follow-up report did not specify the installed bundle, version, build or launch result. The identifiers above belong to the earlier installation-only check.

## Install or upgrade

Use interactive macOS Terminal with Python 3.9+, stable Rust/Cargo supporting edition 2024, the pinned Zsign submodule, Xcode selected for `xcrun devicectl`, Homebrew OpenSSL 3, and the Apple Root CA PEM used for the original check. Connect and unlock exactly one trusted iPhone or iPad with Developer Mode enabled. First run needs GitHub access to compile desktop dependencies.

`install` automatically discovers the latest authorized Beta release, downloads its unsigned IPA, and verifies it against the signed manifest before Apple Account sign-in. For a fresh installation, omit `--upgrade` and choose a Personal Team with a vacant destination. `prepare DESTINATION` downloads and verifies the same release without a device or Apple Account sign-in. The original Beta 3 fixture is used only by regression tests.

To upgrade the experimental `FTB8PRW638` copy, use the same Mac, Apple Account and signing identity. The flag requires that exact destination to exist and the authorized release to be newer. The CLI rechecks device and destination after final approval. The typed confirmation is `UPGRADE app.zagstore.ios.FTB8PRW638`.

```sh
cd "$HOME/Documents/ZagStore-claude" && \
ZAG_ANISETTE_URL= PATH="$(brew --prefix openssl@3)/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
python3 tools/zag-installer/zag_installer.py install --upgrade FTB8PRW638 \
  --expect-tag v1.0.0-beta.4 --apple-root "$HOME/Downloads/AppleRootCA.pem"
```

**Release check, 27 November 2026.** The production Beta v2 manifest has a valid signature and identifies sequence 10, Beta 4, version `1.0.0`, build `4`, minimum iOS `16.4`. The public GitHub asset was downloaded and its SHA-256 matched the signed value. The manifest expired at `2026-11-24T00:44:40Z`, so the command stops until a fresh signed manifest authorizes Beta 4. [Official Beta channel](https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/v2/beta.json)

The desktop helper uses the app's v2 verifier, production trust anchors, expiry policy and rollback/equal-sequence checks, with a separate desktop Keychain service. The installer checks the downloaded IPA digest, canonical bundle, version, build, minimum OS and absence of an embedded profile. The device inventory supplies the current build, iOS version and device family.

Upgrades reuse an Apple-listed, unexpired certificate matching the authenticated account and team's existing Keychain private key. An installation receipt, when present, also pins the exact signing leaf for the connected device. An earlier install has no desktop receipt, so the installer can confirm local key ownership and the mapped destination while CoreDevice and iOS enforce in-place signing compatibility. Upgrades never request a new key or certificate and never uninstall the existing copy. App launch and application-data continuity still need a physical Beta 4 upgrade test.

## Desktop workflow and boundaries

- The Rust desktop process uses the existing GrandSlam, SMS and trusted-device 2FA, and developer-session code. Apple receives sign-in traffic directly over the existing Apple host allowlist. Passwords and verification codes come from hidden Terminal prompts and travel to that process over local pipes. The ADI helper receives no credentials. The developer session is used in memory for one run. Start a new invocation if Apple expires or rejects it.
- Rust selects clean-room ADI or the existing v3 client through the same `AnisetteProvider` trait. There is no automatic provider fallback. For an independently authorized v3 service, explicitly set `ZAG_ANISETTE_URL` to its HTTPS origin and confirm the displayed origin. The CLI checks provider metadata and obtains a valid anisette response before requesting the password. Setting an origin is a separate choice from using the default local path.
- The portal uses Apple's team membership evidence to select an active Personal Team. It uses the certificate inventory protocol already used by the native app, checks a candidate leaf against the local public key, and submits a public CSR only with consent. Apple capacity and pending-request failures preserve all existing certificates. The local issuance journal is written before submission. After an ambiguous result, a subsequent run reconciles against a matching leaf in authenticated inventory and refuses a second CSR while the first outcome is unresolved.
- macOS Keychain holds nonsynchronizing records for anisette state, RSA key material and issuance state. Anisette state is scoped to the sign-in name and provider. Signing state is scoped to Apple's authenticated account identifier and the team. The key is handled locally in process memory and private pipes. The CLI never sends private keys, Apple credentials or pairing records to the Zag Store website.
- The installer registers the USB device and exact team-mapped App ID if absent. It verifies Apple's profile CMS before signing and checks Personal Team status, device membership, signing leaf, expiration, and the exact entitlement grant. The adapter uses the pinned strict Zsign implementation for the app and its nested code, with individual profiles for supported extensions. The independently maintained validator checks the resulting IPA's Mach-O signatures, Apple Development identity, embedded profile and entitlements before installation.
- The device and credential adapters are macOS-specific. The Rust Apple protocol code and archive/provisioning orchestration are separate from those adapters. A Windows credential, signer and USB integration remains future work.

## Why the iOS provider can run on desktop

The working `ZagNativeAccountSignInView` calls `ZagAppleAuthMachine.nativeLogin`, prepares ADI before sign-in with 2FA, and then obtains an Apple developer session. `nativeLogin` selects `.macLegacy` with the device-local ADI Keychain scope and a separate staged session scope. It calls `aauth_client_provision`, `aauth_client_headers` and `aauth_client_state` from the bundled clean-room AppleAuth library. The separate provider catalogue and remote v3 bridge are outside this sign-in path. [Sign-in entry point](../../Feather/Views/Settings/FreeAccount/ZagNativeAccountSignInView.swift#L144) · [Provider configuration](../../Feather/Utilities/FreeAccount/ZagAppleAuthMachine.swift#L276) · [Successful iOS developer session](../../docs/free-developer-accounts/APPLE-AUTH-DEVSESSION-PLAN.md)

The checked-in static library is an iOS arm64 slice and cannot link into a macOS process. Its C++ source and C ABI can be rebuilt for macOS without AuthKit or its entitlements. The desktop helper uses the same Mac ADI algorithm, legacy client-info and User-Agent, and the same in-memory provisioning API. It provisions a distinct desktop identity. The iPhone's state and credentials stay on the phone.

The desktop transport permits only the Apple HTTPS ADI lookup, start and finish sequence, uses system TLS verification and refuses redirects. The Rust adapter checks consistent client identity and required anisette headers before asking for the password. The operator has confirmed acceptance of these headers in the standalone physical desktop workflow.

## Profile-only on-device adoption design

A desktop-signed install can potentially renew its profile while its original Apple Development certificate remains valid and authorized on the team. The device would install a newly issued profile that grants the **existing** signature's certificate and entitlements. It would not generate a signature, so the protocol needs no transfer of the desktop key. The installer has no adoption or transfer operation.

The current `ZagNativeAccountInstall.verifyRunningInstallation()` path binds ownership to a matching on-device account-scoped signing identity. Keep that path and its checks intact. A separate explicit profile-only enrollment would need all of the following:

1. Reauthenticate on the phone and obtain exactly one active Personal Team matching the running signer's team. Require the exact desktop bundle mapping and a fresh authenticated Apple certificate inventory containing the same valid development leaf by DER equality. Team ID, serial, display name and a desktop-supplied receipt are insufficient by themselves.
2. Verify the running app and each provisioned component against the exact signer across executable slices. Derive entitlements from the actual signed code. Use the independently paired phone to confirm the installed app, version, build and reliable signer evidence, and read the installed profiles back from that device.
3. Verify Apple CMS trust and exact per-component identifier, device, leaf, entitlement grants and expiry on the installed profiles. Require exactly one account/team owner and bind the resulting profile-only receipt to the local account, device, build, signer fingerprint and full component inventory. Preserve the current reservation, conflict and readback checks when creating or updating this receipt.
4. On refresh recheck ownership and request a profile covering the unchanged leaf and exact signed entitlements. Read back the installed profiles and verify the executable identity is unchanged before updating the receipt. Disable adoption or renewal on account, signer, device, bundle, component or entitlement mismatch, and when the certificate expires or leaves Apple inventory. A different leaf or a new build requires an independently authorized signing workflow.

Test the design separately with a disposable artifact signed only on the Mac. Acceptance requires authenticated on-device readback, successful refresh with a later effective expiry, unchanged code signature, and continued launch on the phone. Include negative tests for a missing leaf, wrong account or team, wrong device, mismatched component entitlements and an existing inventory owner. Neither adoption nor the viable profile-only lifetime for a desktop-signed Zag Store build has been physically established.

## Test status

The installer regression suite exercises offline source and installation guards, interactive 2FA choices, account isolation and certificate recovery, Personal Team profile binding, and failure before any device installation. The signed-manifest upgrade path has offline regression coverage. Physical upgrade and launch remain separate acceptance steps.
