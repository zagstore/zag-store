# Zag Installer

## Physical verification record

On 27 November 2026 the operator ran all seven original installer tests, verified the official unsigned Zag Store Beta 3 IPA against the pinned release digest, and installed the independently validated Personal Team-signed IPA over trusted USB using Zag Installer from commit `6aa2fc7d7d089c5e0066a947d762917b9a05f1e1`.

CoreDevice confirmed bundle `app.zagstore.ios.FTB8PRW638`, version `1.0.0`, build `3`. This physically verifies the USB developer installation and inventory readback path. Launch confirmation is a separate test and remains unrecorded. The successful install occupied that mapped destination.

## Phase 2 physical acceptance

Use interactive macOS Terminal from this checkout, with Python 3.9+, stable Rust/Cargo supporting edition 2024 and the locked dependencies, the pinned Zsign submodule, Xcode selected for `xcrun devicectl`, Homebrew OpenSSL 3, and the Apple Root CA PEM used for the original check. Connect and unlock exactly one trusted iPhone or iPad with Developer Mode enabled.

Set `ZAG_ANISETTE_URL` in your Terminal environment to the HTTPS origin of your authorized anisette v3 instance. The CLI uses the repository's v3 client and has no default endpoint. A working instance whose identity Apple accepts is a live-test prerequisite. This change does not deploy or configure one.

Run this command with the official unsigned IPA already in Downloads. Select a Personal Team with an unoccupied mapped destination and capacity for a desktop development certificate. The installer asks before portal mutations, asks separately before submitting a CSR, and validates the signed IPA before offering the final `INSTALL` prompt.

```sh
PATH="$(brew --prefix openssl@3)/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 python3 tools/zag-installer/zag_installer.py install "$HOME/Downloads/ZagStore-1.0.0-beta.3.ipa" --apple-root "$HOME/Downloads/AppleRootCA.pem"
```

Record the exact installed bundle, version and build reported by the CLI. Confirm app launch separately. The occupied `FTB8PRW638` destination requires `--replace FTB8PRW638` and the final typed confirmation `REPLACE app.zagstore.ios.FTB8PRW638`. Use that mode only with operator approval and a desktop-owned certificate or available issuance capacity. The installer performs another USB identity and destination inventory check immediately before CoreDevice runs. CoreDevice does not offer an atomic conditional install, so avoid simultaneous installation from another tool.

`prepare` still downloads or verifies the exact official release. `install-signed` remains the fresh-install-only path for the independently validated and digest-pinned Phase 1 artifact.

## Desktop workflow and boundaries

- The Rust desktop process uses the existing GrandSlam, SMS and trusted-device 2FA, developer-session and remote anisette v3 code. Apple receives sign-in traffic directly over the existing Apple host allowlist. The anisette client exchanges only its own protocol data with the configured service. Passwords and verification codes come from hidden Terminal prompts and travel to the Rust process over local pipes. The developer session is used in memory for one run. Start a new invocation if Apple expires or rejects it.
- The portal uses Apple's team membership evidence to select an active Personal Team. It uses the certificate inventory protocol already used by the native app, checks a candidate leaf against the local public key, and submits a public CSR only with consent. Apple capacity and pending-request failures preserve all existing certificates. The local issuance journal is written before submission. After an ambiguous result, a subsequent run reconciles against a matching leaf in authenticated inventory and refuses a second CSR while the first outcome is unresolved.
- macOS Keychain holds nonsynchronizing records for anisette state, RSA key material and issuance state. Anisette state is scoped to the sign-in name and provider. Signing state is scoped to Apple's authenticated account identifier and the team. The key is handled locally in process memory and private pipes. The CLI never sends private keys, Apple credentials or pairing records to the Zag Store website.
- The installer registers the USB device and exact team-mapped App ID if absent. It verifies Apple's profile CMS before signing and checks Personal Team status, device membership, signing leaf, expiration, and the exact entitlement grant. The adapter signs the single provisioned app in Beta 3, including its existing nested code, using the pinned strict Zsign implementation. The independently maintained validator checks the resulting IPA's Mach-O signatures, Apple Development identity, embedded profile and entitlements before installation.
- The device and credential adapters are macOS-specific. The Rust Apple protocol code and archive/provisioning orchestration are separate from those adapters. A Windows credential, signer and USB integration remains future work.

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
