# Zag Installer

## Physical verification record

On 27 November 2026 the operator ran all seven original installer tests, verified the official unsigned Zag Store Beta 3 IPA against the pinned release digest, and installed the independently validated Personal Team-signed IPA over trusted USB using Zag Installer from commit `6aa2fc7d7d089c5e0066a947d762917b9a05f1e1`.

CoreDevice confirmed bundle `app.zagstore.ios.FTB8PRW638`, version `1.0.0`, build `3`. This physically verifies the USB developer installation and inventory readback path. Launch confirmation is a separate test and remains unrecorded. The successful install occupied that mapped destination.

## Phase 2 physical acceptance

Use interactive macOS Terminal from this checkout, with Python 3.9+, stable Rust/Cargo supporting edition 2024 and the locked dependencies, the pinned Zsign submodule, Xcode selected for `xcrun devicectl`, Homebrew OpenSSL 3, and the Apple Root CA PEM used for the original check. Connect and unlock exactly one trusted iPhone or iPad with Developer Mode enabled.

The default provider builds the same pinned clean-room `apple-auth` library used by the iOS app, targeting macOS. The first run needs GitHub access to fetch its build dependencies. It asks for `ANISETTE` consent before establishing a fresh desktop machine profile directly with Apple. A previously provisioned desktop profile can generate headers locally. No `ZAG_ANISETTE_URL` is required.
Run this command with the official unsigned IPA already in Downloads. Select a Personal Team with an unoccupied mapped destination and capacity for a desktop development certificate. The installer asks before portal mutations, asks separately before submitting a CSR, and validates the signed IPA before offering the final `INSTALL` prompt.

```sh
cd "$HOME/Documents/ZagStore-claude" && \
ZAG_ANISETTE_URL= PATH="$(brew --prefix openssl@3)/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
python3 tools/zag-installer/zag_installer.py install \
  "$HOME/Downloads/ZagStore-1.0.0-beta.3.ipa" --apple-root "$HOME/Downloads/AppleRootCA.pem"
```

Record the exact installed bundle, version and build reported by the CLI. Confirm app launch separately. The occupied `FTB8PRW638` destination requires `--replace FTB8PRW638` and the final typed confirmation `REPLACE app.zagstore.ios.FTB8PRW638`. Use that mode only with operator approval and a desktop-owned certificate or available issuance capacity. The installer performs another USB identity and destination inventory check immediately before CoreDevice runs. CoreDevice does not offer an atomic conditional install, so avoid simultaneous installation from another tool.

`prepare` still downloads or verifies the exact official release. `install-signed` remains the fresh-install-only path for the independently validated and digest-pinned Phase 1 artifact.

## Desktop workflow and boundaries

- The Rust desktop process uses the existing GrandSlam, SMS and trusted-device 2FA, and developer-session code. Apple receives sign-in traffic directly over the existing Apple host allowlist. Passwords and verification codes come from hidden Terminal prompts and travel to that process over local pipes. The ADI helper receives no credentials. The developer session is used in memory for one run. Start a new invocation if Apple expires or rejects it.
- Rust selects clean-room ADI or the existing v3 client through the same `AnisetteProvider` trait. There is no automatic provider fallback. For an independently authorized v3 service, explicitly set `ZAG_ANISETTE_URL` to its HTTPS origin and confirm the displayed origin. The CLI checks provider metadata and obtains a valid anisette response before requesting the password. Setting an origin is a separate choice from using the default local path.
- The portal uses Apple's team membership evidence to select an active Personal Team. It uses the certificate inventory protocol already used by the native app, checks a candidate leaf against the local public key, and submits a public CSR only with consent. Apple capacity and pending-request failures preserve all existing certificates. The local issuance journal is written before submission. After an ambiguous result, a subsequent run reconciles against a matching leaf in authenticated inventory and refuses a second CSR while the first outcome is unresolved.
- macOS Keychain holds nonsynchronizing records for anisette state, RSA key material and issuance state. Anisette state is scoped to the sign-in name and provider. Signing state is scoped to Apple's authenticated account identifier and the team. The key is handled locally in process memory and private pipes. The CLI never sends private keys, Apple credentials or pairing records to the Zag Store website.
- The installer registers the USB device and exact team-mapped App ID if absent. It verifies Apple's profile CMS before signing and checks Personal Team status, device membership, signing leaf, expiration, and the exact entitlement grant. The adapter signs the single provisioned app in Beta 3, including its existing nested code, using the pinned strict Zsign implementation. The independently maintained validator checks the resulting IPA's Mach-O signatures, Apple Development identity, embedded profile and entitlements before installation.
- The device and credential adapters are macOS-specific. The Rust Apple protocol code and archive/provisioning orchestration are separate from those adapters. A Windows credential, signer and USB integration remains future work.

## Why the iOS provider can run on desktop

The working `ZagNativeAccountSignInView` calls `ZagAppleAuthMachine.nativeLogin`, prepares ADI before sign-in with 2FA, and then obtains an Apple developer session. `nativeLogin` selects `.macLegacy` with the device-local ADI Keychain scope and a separate staged session scope. It calls `aauth_client_provision`, `aauth_client_headers` and `aauth_client_state` from the bundled clean-room AppleAuth library. The separate provider catalogue and remote v3 bridge are outside this sign-in path. [Sign-in entry point](../../Feather/Views/Settings/FreeAccount/ZagNativeAccountSignInView.swift#L144) · [Provider configuration](../../Feather/Utilities/FreeAccount/ZagAppleAuthMachine.swift#L276) · [Successful iOS developer session](../../docs/free-developer-accounts/APPLE-AUTH-DEVSESSION-PLAN.md)

The checked-in static library is an iOS arm64 slice and cannot link into a macOS process. Its C++ source and C ABI can be rebuilt for macOS without AuthKit or its entitlements. The desktop helper uses the same Mac ADI algorithm, legacy client-info and User-Agent, and the same in-memory provisioning API. It provisions a distinct desktop identity. The iPhone's state and credentials stay on the phone.

The desktop transport permits only the Apple HTTPS ADI lookup, start and finish sequence, uses system TLS verification and refuses redirects. The Rust adapter checks consistent client identity and required anisette headers before asking for the password. The iOS result is evidence for the ADI implementation and identity, while acceptance of those headers with this desktop Rust sign-in and developer session still requires a physical test.

## Profile-only on-device adoption design

A desktop-signed install can potentially renew its profile while its original Apple Development certificate remains valid and authorized on the team. The device would install a newly issued profile that grants the **existing** signature's certificate and entitlements. It would not generate a signature, so the protocol needs no transfer of the desktop key. The installer has no adoption or transfer operation.

The current `ZagNativeAccountInstall.verifyRunningInstallation()` path binds ownership to a matching on-device account-scoped signing identity. Keep that path and its checks intact. A separate explicit profile-only enrollment would need all of the following:

1. Reauthenticate on the phone and obtain exactly one active Personal Team matching the running signer's team. Require the exact desktop bundle mapping and a fresh authenticated Apple certificate inventory containing the same valid development leaf by DER equality. Team ID, serial, display name and a desktop-supplied receipt are insufficient by themselves.
2. Verify the running app and each provisioned component against the exact signer across executable slices. Derive entitlements from the actual signed code. Use the independently paired phone to confirm the installed app, version, build and reliable signer evidence, and read the installed profiles back from that device.
3. Verify Apple CMS trust and exact per-component identifier, device, leaf, entitlement grants and expiry on the installed profiles. Require exactly one account/team owner and bind the resulting profile-only receipt to the local account, device, build, signer fingerprint and full component inventory. Preserve the current reservation, conflict and readback checks when creating or updating this receipt.
4. On refresh recheck ownership and request a profile covering the unchanged leaf and exact signed entitlements. Read back the installed profiles and verify the executable identity is unchanged before updating the receipt. Disable adoption or renewal on account, signer, device, bundle, component or entitlement mismatch, and when the certificate expires or leaves Apple inventory. A different leaf or a new build requires an independently authorized signing workflow.

Test the design separately with a disposable artifact signed only on the Mac. Acceptance requires authenticated on-device readback, successful refresh with a later effective expiry, unchanged code signature, and continued launch on the phone. Include negative tests for a missing leaf, wrong account or team, wrong device, mismatched component entitlements and an existing inventory owner. Neither adoption nor the viable profile-only lifetime for a desktop-signed Zag Store build has been physically established.

## Test status

The installer regression suite exercises offline source and installation guards, interactive 2FA choices, account isolation and certificate recovery, Personal Team profile binding, and failure before any device installation. Live desktop Apple sign-in, portal issuance, signing with the resulting Apple identity, installation of that newly signed IPA, and launch remain acceptance steps.
