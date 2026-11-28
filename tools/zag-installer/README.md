# Zag Installer

## Physical verification record

On 27 November 2026 the operator ran all seven original installer tests, verified the official unsigned Zag Store Beta 3 IPA against the pinned release digest, and installed the independently validated Personal Team-signed IPA over trusted USB using Zag Installer from commit `6aa2fc7d7d089c5e0066a947d762917b9a05f1e1`.

CoreDevice confirmed bundle `app.zagstore.ios.FTB8PRW638`, version `1.0.0`, build `3`. This physically verifies the USB developer installation and inventory readback path. Launch confirmation is a separate test and remains unrecorded. The successful install occupied that mapped destination.

The operator subsequently confirmed a successful standalone end-to-end macOS installation with the clean-room anisette integration. This records a physical result for desktop Apple authentication, provisioning, signing, validation and USB installation. The operator also reported successful experimental upgrade testing. The follow-up reports did not specify the installed bundle, version, build, app-data continuity or launch result. The identifiers above belong to the earlier installation-only check.

## Native macOS graphical preview (development only)

The native SwiftUI window now uses the existing verified desktop installer and a
dedicated local, bounded JSON prompt channel. Apple passwords and 2FA codes
are entered through a secure prompt, not logged or sent through the website.
The normal Terminal workflow remains unchanged. The GUI deliberately offers
only official signed-channel installation and explicit in-place upgrade;
developer-only local candidates and recovery stay in the CLI.

From the existing checked-out repository, run:

```sh
cd "$HOME/Documents/ZagStore-claude"
bash tools/zag-installer/run-gui.sh
```

Prerequisites are the same as the CLI: macOS, Xcode, working Python 3,
Cargo/Rust, Homebrew OpenSSL 3, a trusted wired iPhone/iPad, and Apple sign-in.
The launcher compiles a private local macOS executable. It does not build a
self-contained, notarized, redistributable app. The graphical window resolves
the verified repository from `ZAG_INSTALLER_ROOT`; no source is fetched at
runtime.

Offline protocol tests:

```sh
cd tools/zag-installer
python3 -m unittest -v test_ui_protocol
```

**Acceptance pending:** the SwiftUI target must compile on the operator's
Mac, the official Beta 5 channel must be installed or upgraded through the
window, and fresh on-device Signing Setup must be verified independently.
Do not advertise this as a public release until those tests pass. Windows
USB, credential/key storage and installer packaging are not implemented.

## macOS updater integration (0.2.0 development)

The native GUI embeds the pinned official Sparkle 2.10.1 framework (downloaded by
`bootstrap-sparkle.sh`, SHA-256 checked against the official release). The
application has an Updates settings pane and a Check for Updates menu action.
The default scheduled interval is 24 hours; settings are delegated to Sparkle.

**Fail-closed release gate:** the current local launcher sets
`ZagUpdatesReady=false` and deliberately does not include `SUFeedURL` or
`SUPublicEDKey`. The updater does not start and cannot download/replace code.
A redistributable, complete app, dedicated Ed25519 public key, HTTPS desktop
appcast, stable Developer ID signing and update/archive tests are required
before enabling it. Update archive signing private keys must remain in the
operator's macOS Keychain and must never be committed to the repository or
copied to the website. The iOS Beta 5 update feed is unrelated.

The current local installer is ad-hoc signed for development only, still
invokes a source checkout, and is not a distributable desktop package. Do not
publish it or turn on Sparkle based only on a successful GUI launch. In the
current preview, Settings correctly explains why update checks are disabled.

To launch the updated GUI after bootstrapping Sparkle:

```sh
cd "$HOME/Documents/ZagStore-claude"
bash tools/zag-installer/run-gui.sh
```

## Precompiled native-helper staging

Six precompiled helpers have been staged on Intel macOS, and the relocated
OpenSSL 3.5.9 links only to the package-local `libssl.3.dylib` and
`libcrypto.3.dylib`. The native executables also pass the existing
macOS system-library dependency audit.

A separate, opt-in `--precompiled-helpers DIRECTORY` CLI flag now selects
the staged binaries under the same private process lock as normal desktop
installation. The adapter validates the full inventory and disallows runtime
compilation or fallback. This is a development capability only; the GUI
continues to use the original BuildCache unless explicitly changed later.
Do not use this flag with an arbitrary directory or binaries from another
person: the executable files must come from a trusted local build.

**Pending:** package a private Python runtime, program resources, and
Xcode-independent USB transport, then add standalone app bundle verification.
The staging package is not yet a distributable or notarized installer.

## Install or upgrade

Use interactive macOS Terminal with Python 3.9+, stable Rust/Cargo supporting edition 2024, the pinned Zsign submodule, Xcode selected for `xcrun devicectl`, and Homebrew OpenSSL 3. Connect and unlock exactly one trusted iPhone or iPad with Developer Mode enabled. First run needs GitHub access to compile desktop dependencies.

`install` automatically discovers the latest authorized Beta release, downloads its unsigned IPA, and verifies it against the signed manifest before Apple Account sign-in. For a fresh installation, omit `--upgrade` and choose a Personal Team with a vacant destination. `prepare DESTINATION` downloads and verifies the same release without a device or Apple Account sign-in. The original Beta 3 fixture is used only by regression tests.

To upgrade the experimental `FTB8PRW638` copy, use the same Mac, Apple Account and signing identity. The flag requires that exact destination to exist and the authorized release to be newer. The CLI rechecks device and destination after final approval. The typed confirmation is `UPGRADE app.zagstore.ios.FTB8PRW638`.

```sh
cd "$HOME/Documents/ZagStore-claude" && \
ZAG_ANISETTE_URL= PATH="$(brew --prefix openssl@3)/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
python3 tools/zag-installer/zag_installer.py install --upgrade FTB8PRW638 \
  --expect-tag v1.0.0-beta.4
```

**Release check, 27 November 2026.** The production Beta v2 manifest has a valid signature and identifies sequence 10, Beta 4, version `1.0.0`, build `4`, minimum iOS `16.4`. The public GitHub asset was downloaded and its SHA-256 matched the signed value. The manifest expired at `2026-11-24T00:44:40Z`, so the command stops until a fresh signed manifest authorizes Beta 4. [Official Beta channel](https://raw.githubusercontent.com/zagorskey/zag-store-releases/main/releases/v2/beta.json)

HTTPS discovery and downloads use the macOS trust store through URLSession. No Python CA file is needed. The installer derives the separate profile CMS trust anchor from the repository's pinned Apple Root CA. An explicit `--apple-root` override must match that pin. Network diagnostics report the failing stage and a fixed DNS, connectivity, TLS, timeout, or HTTP message without showing URLs or response content.

The desktop helper uses the app's v2 verifier, production trust anchors, expiry policy and rollback/equal-sequence checks, with a separate desktop Keychain service. The installer checks the downloaded IPA digest, canonical bundle, version, build, minimum OS and absence of an embedded profile. The device inventory supplies the current build, iOS version and device family.

Upgrades reuse an Apple-listed, unexpired certificate matching the authenticated account and team's existing Keychain private key. An installation receipt, when present, also pins the exact signing leaf for the connected device. An earlier install has no desktop receipt, so the installer can confirm local key ownership and the mapped destination while CoreDevice and iOS enforce in-place signing compatibility. Upgrades never request a new key or certificate and never uninstall the existing copy. App launch and application-data continuity still need a physical Beta 4 upgrade test.

## Developer-only local candidate upgrade

`upgrade-local-candidate` accepts a locally packaged IPA, an independently obtained SHA-256, and the exact expected version and build. It upgrades only the existing experimental `app.zagstore.ios.FTB8PRW638` copy. Use the Mac and Apple Account that hold its existing desktop signing identity. The installer requires the same in-place upgrade checks and typed confirmation as a channel upgrade, including an active Apple certificate matching the local key. It does not create a replacement signing identity.

The local IPA is read into private staging and verified before sign-in. This command does not read or update production manifest state. The regular `install` and `prepare` commands continue to require signed v2 release metadata.

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

## Desktop signing identity handoff

The operator confirmed Apple error `7460` on the experimental `FTB8PRW638` copy when its certificate's private key existed only on the Mac. The operator later confirmed that the revised Beta 5 manually received and imported that key, then refreshed itself on the iPhone. Automatic setup reuses that import and ownership flow.

The manual recovery command asks the active Apple ID to prepare a one-time transfer under **Apple IDs → Zag Store Installation → Receive Desktop Signing Identity**. The target must be a mapped Personal Team installation with a valid profile and working on-device installation pairing. The Mac uses USB CoreDevice app-container copies for two named files. The iPhone displays a 24-hex-character fingerprint of the request for the operator to type on the Mac before authorizing the transfer. No credentials, tokens, anisette state or pairing records are transferred. [CoreDevice file transfer](https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line)

The request binds an ephemeral X25519 public key, nonce and ten-minute expiry to the connected device UDID, exact running bundle, Personal Team, certificate DER and opaque account-scoped desktop key lookup. The Mac verifies the entered fingerprint, checks the installed destination and signing receipt if available, and proves the available desktop key matches the running certificate. The sender uses X25519, HKDF-SHA256 and AES-GCM with the exact request bytes as authenticated data. Only ciphertext is written for delivery. The phone keeps the recipient key in memory, consumes each request on attempted import, and refuses ciphertext from expired, interrupted or superseded requests.

On import, iOS checks the same active authenticated account, live Personal Team and exact certificate in Apple's read-only inventory, paired device and running signer. It proves key possession, imports into a scoped Keychain key item, then commits the certificate reference for the existing signing and renewal pipeline. It preserves other accounts, different existing identities and pending issuance journals. A confirmed 7460 refusal journal is compatible with reuse. Unknown or issued-but-unreconciled pending requests fail closed. Duplicate imports of the same identity and interrupted metadata commits reuse the same scoped key slot. The existing running-installation verification independently checks paired readback and ownership before enabling profile-only renewal.

### Automatic first-launch setup

After installing a package that declares the new setup receiver, both the signed-channel and local-candidate commands start Signing Setup automatically. CoreDevice launches the exact installed app. If iOS refuses the launch, unlock the phone and open that copy manually. Zag Store detects the pending setup on launch or foreground entry, checks for an already verified identity, and presents setup when needed. A new import requires one **Authorize Signing Identity** tap. [Apple CoreDevice launch and transfer](https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line)

The trusted, paired USB CoreDevice service delivers a one-time 256-bit bootstrap secret to the exact app's private Caches directory. The app consumes the file and the Mac deletes its staging copy after delivery. The protocol trusts the paired developer connection and the installed app's sandbox. Finder-visible Documents files do not carry the automatic bootstrap secret. Separate HMAC-SHA256 labels authenticate the request, encrypted response, cancellation, and acknowledgement for this transaction. The request still binds the active authenticated account, UDID, bundle, Personal Team and exact certificate. The response still uses X25519, HKDF-SHA256 and AES-GCM. A stale or partial message cannot trigger delivery or acknowledge completion.

The Mac displays `"signing_setup":"verified"` only after an authenticated acknowledgement bound to the transfer request or an independently reverified existing scoped key. On the phone that requires matching key possession and the existing running-installation ownership and profile readback checks. A disconnect can be retried without reinstalling. A cancelled or expired setup cannot be reused.

**Apple sign-in and pairing prerequisites.** Setup reuses a connected iPhone session for the same Apple account. On a fresh phone installation, the Rust installer holds an in-memory Xcode developer token with its desktop anisette identity. The iOS account store expects a native app-owned apple-auth session and its associated local device state. This implementation has no supported conversion or Apple session continuation between them. The iPhone therefore presents its existing Apple sign-in and verification when no matching session is connected. Developer Mode and iOS USB trust still need system approval when required. Zag Store also needs its own installation pairing for inventory and profile readback. Setup provides a direct link to that flow. It does not move pairing records, passwords, sessions or anisette state.

### Physical acceptance for the experimental copy

Use an independently hashed, automation-enabled local Beta 5 IPA from this commit. The release configuration stays at `1.0.0`, Beta, build `5`. This command requires the experimental copy already installed and the same desktop signing identity:

```sh
cd "$HOME/Documents/ZagStore-claude" &&
printf 'Verified automation-enabled Beta 5 SHA-256: ' && IFS= read -r zag_setup_sha &&
PATH="$(brew --prefix openssl@3)/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
python3 tools/zag-installer/zag_installer.py upgrade-local-candidate \
  "$HOME/Downloads/ZagStore-1.0.0-beta.5-automatic-setup.ipa" \
  --sha256 "$zag_setup_sha" --version 1.0.0 --build 5 --replace-same-build
```

Approve `REPLACE app.zagstore.ios.FTB8PRW638`. Complete the phone prerequisites if prompted. For a new import, tap **Authorize Signing Identity** once. Confirm the CLI reports verified, with no code entry. To test first import independently from the previously validated manual setup, use an eligible test device or account that has not received the desktop key. The existing experimental copy may correctly skip transfer after its exact identity and ownership are reverified. Test signing and Refresh All with the same original Apple ID, verify profile-only readback when Apple issues a later expiry, and confirm the AppTesters copy still launches. A same-build device inventory cannot distinguish binary bytes, so confirm the new Signing Setup UI appears.

If setup is interrupted after installation, reconnect the same iPhone and retry using its saved setup receipt:

```sh
cd "$HOME/Documents/ZagStore-claude" &&
PATH="$(brew --prefix openssl@3)/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 \
python3 tools/zag-installer/zag_installer.py setup --team FTB8PRW638
```

The advanced manual recovery command remains `python3 tools/zag-installer/zag_installer.py handoff --team FTB8PRW638`, with the Homebrew OpenSSL 3 directory on PATH. It uses the existing Settings screen and code verification. Automatic setup exposes its device operations through an adapter, so a future graphical installer can reuse the orchestration. The automatic CoreDevice launch, transfer and acknowledgement still require physical acceptance.

## Profile-only on-device adoption design

A desktop-signed install can potentially renew its profile while its original Apple Development certificate remains valid and authorized on the team. The device would install a newly issued profile that grants the **existing** signature's certificate and entitlements. It would not generate a signature, so the protocol needs no transfer of the desktop key. The implemented handoff uses the existing exact-leaf enrollment. Profile-only adoption without transferring a signing key remains a separate design.

The current `ZagNativeAccountInstall.verifyRunningInstallation()` path binds ownership to a matching on-device account-scoped signing identity. Keep that path and its checks intact. A separate explicit profile-only enrollment would need all of the following:

1. Reauthenticate on the phone and obtain exactly one active Personal Team matching the running signer's team. Require the exact desktop bundle mapping and a fresh authenticated Apple certificate inventory containing the same valid development leaf by DER equality. Team ID, serial, display name and a desktop-supplied receipt are insufficient by themselves.
2. Verify the running app and each provisioned component against the exact signer across executable slices. Derive entitlements from the actual signed code. Use the independently paired phone to confirm the installed app, version, build and reliable signer evidence, and read the installed profiles back from that device.
3. Verify Apple CMS trust and exact per-component identifier, device, leaf, entitlement grants and expiry on the installed profiles. Require exactly one account/team owner and bind the resulting profile-only receipt to the local account, device, build, signer fingerprint and full component inventory. Preserve the current reservation, conflict and readback checks when creating or updating this receipt.
4. On refresh recheck ownership and request a profile covering the unchanged leaf and exact signed entitlements. Read back the installed profiles and verify the executable identity is unchanged before updating the receipt. Disable adoption or renewal on account, signer, device, bundle, component or entitlement mismatch, and when the certificate expires or leaves Apple inventory. A different leaf or a new build requires an independently authorized signing workflow.

Test the design separately with a disposable artifact signed only on the Mac. Acceptance requires authenticated on-device readback, successful refresh with a later effective expiry, unchanged code signature, and continued launch on the phone. Include negative tests for a missing leaf, wrong account or team, wrong device, mismatched component entitlements and an existing inventory owner. Neither adoption nor the viable profile-only lifetime for a desktop-signed Zag Store build has been physically established.

## Test status

The installer regression suite exercises offline source and installation guards, interactive 2FA choices, account isolation and certificate recovery, Personal Team profile binding, and failure before any device installation. The signed-manifest upgrade path has offline regression coverage. Physical upgrade and launch remain separate acceptance steps.


## Native signed IPA preflight (read-only development milestone)

The isolated native helper now accepts `zag-usb preflight PLAN.json` in
addition to `status`, `inspect` and `inventory`. It does **not** support
`install`, `upgrade` or writing to an iPhone. The preflight record binds a
specific signed IPA file path, exact local SHA-256 and byte length, mapped
Personal Team bundle, version, build, minimum iOS and wired-device UDID.
Rust rejects unknown JSON fields and recomputes the digest from disk, then
checks the native USB pairing and device identity. This can detect a changed
file or unexpectedly swapped iPhone **without** importing the Apple ID into
Rust.

`native_preflight.create` is the macOS producer. It invokes the existing
pinned `artifact.validate` checks for Apple code signatures, development
certificates and provisioning profiles, checks exact release metadata, and
runs the provided current-release authorization check before writing a
private plan with `native_preflight.write_private`. A plan contains no private
keys or Apple login material. The plan's JSON itself is **not** signed and
cannot establish authorization if created by an untrusted process. In
particular, Rust's `preflight` reports
`"installation_authorized":false` and is deliberately not connected to
Installation Proxy.

The installed AppTesters copy `com.cwd43.gu29` is exposed as a legacy
diagnostic only and is **never** a Personal Team upgrade target. An empty
native Personal Team inventory does not prove the destination is vacant;
fresh native installation remains blocked. The existing Xcode/CoreDevice
CLI installation path is not modified.

Run development checks without modifying an iPhone:

```sh
cd "$HOME/Documents/ZagStore-claude"
(cd tools/zag-installer && python3 -m unittest -q test_zag_installer)
cargo test --release --manifest-path tools/zag-installer/native-usb/Cargo.toml
cargo build --release --manifest-path tools/zag-installer/native-usb/Cargo.toml
```

The Python tests can alternatively be run from `tools/zag-installer` with
`python3 -m unittest -q test_zag_installer`. A real signed IPA from the
existing signing pipeline is required for meaningful complete preflight
validation. Never mistake an arbitrary JSON file for a signed release.


## Native House Arrest encrypted signing-setup transport

The standalone Rust helper now implements `handoff-read` and `handoff-write` for
the **existing** private signing setup protocol. Python `StandaloneUSB` maps
`copy_from_app` and `copy_to_app` to these commands. The encrypted
payload and bootstrap messages continue to be constructed, authenticated and
validated by `handoff.py`; the Rust layer only transports those exact files.

The implementation requires exactly one trusted USB-connected iPhone in
Developer Mode, an affirmative exact installed Personal Team bundle inventory,
and a limited set of existing request/response paths. It refuses the AppTesters
bundle, arbitrary paths, oversized messages, linked files, changed local
ciphertext and missing installed destinations. Outbound files are created by
Python with exclusive mode 0600 and checked by Rust before writing. The
transport verifies the delivered file byte-for-byte via SHA-256 readback.
No private key plaintext is sent to Rust as an argument or written to
any iPhone file. The temporary setup bootstrap does contain an authenticated
transaction secret and is created mode 0600.

**Release status:** This is a development transport. On-device House Arrest
permissions for Personal Team copies and end-to-end encrypted setup have **not
been physically verified** on iOS 27. The existing standalone GUI remains
read-only, and standalone CLI installation/provisioning remains disabled by
the top-level guard. The native launch path will require further development;
the existing automatic handoff can instruct the user to open the app manually.

Development validation (read-only):

```sh
cd "$HOME/Documents/ZagStore-claude"
(cd tools/zag-installer && python3 -m unittest -q test_zag_installer test_handoff)
cargo test --release --manifest-path tools/zag-installer/native-usb/Cargo.toml
cargo build --release --manifest-path tools/zag-installer/native-usb/Cargo.toml
```

Do not run `handoff-write` against a phone without an authorised on-device
setup session. `zag-usb install` remains unsupported.


## Exact Personal Team destination preparation

The native USB helper now supports read-only `inventory-team TEAM`. This
performs all three Apple broad inventory checks and the separate exact
Installation Proxy User/Any lookup for `app.zagstore.ios.TEAM`.
The Python installer uses this targeted result for its own destination
selection. A missing record means **not reported by the checked inventories**,
not proven vacant; a real installation would still require exact Apple
signature/profile verification, user confirmation, a second destination
check, and Installation Proxy acceptance.

The signed IPA validation path now also calls
`StandaloneUSB.preflight_signed` before requesting installation approval.
The preflight record is created after the existing Apple signing validation,
validated independently by the native USB helper against the device and
local digest, and then deleted. A report with a claimed installation
authorization or mismatched destination is refused.

The internal Rust install state machine now accepts a separately approved
fresh destination, while demanding a stable exact prior version/build for
upgrades and checking the state again after remote IPA staging.

**Current limitation:** This prepares the first-install flow but does not
enable it. The macOS standalone CLI still blocks provisioning and
installation, `StandaloneUSB.install` still rejects writes, and `zag-usb
install` is intentionally not a supported command. The AppTesters
installation `com.cwd43.gu29` is not an upgrade or uninstall target.


## Developer-only native installation path (not a release capability)

The full native Installation Proxy writer is now reachable **only** when
`zag-usb` is compiled with Cargo feature `native-install-dev`, which
is disabled by default. This feature is intentionally excluded from
`package-engine.sh`, the distributed GUI, and ordinary release builds.
The development-only Rust command is `install-signed-dev`, which
requires a strict plan, unguessable staging token, and exact
`INSTALL/UPGRADE BUNDLE ON UDID` confirmation. It validates the IPA digest,
paired USB device, mapped bundle, minimum iOS and stable destination both
before and after staging, then performs Installation Proxy install/upgrade
and independently checks installed version/build. It does not uninstall or
modify the legacy `com.cwd43.gu29` bundle.

The Python CLI enables this branch only with **all** of the following:
`--usb-transport standalone`, `--native-install-dev`, interactive Terminal
(rather than the GUI), and official `install` mode. Its Apple signing
validation, profile/certificate checks, current release authorization,
Personal Team selection, user confirmation, targeted inventory and
independent native preflight still apply. Unlike the old CoreDevice
backend, the new native branch stages the **intact signed IPA**; it does
not unpack and rewrite the executable bundle before installation.

**Important security boundary:** a JSON preflight record is not signed
and the developer-only Rust command cannot independently prove Apple's
signature chain or the authorized signed release. It trusts the macOS
signing frontend's prior validation and the explicit local developer
confirmation. It must not be enabled in distributed builds or used as an
unattended API. No physical iOS 27 installation has yet been verified;
do not treat the feature as production ready.

To compile both paths without replacing the default release binary:

```sh
cd "$HOME/Documents/ZagStore-claude"
(cd tools/zag-installer && python3 -m unittest -q test_zag_installer test_handoff)
cargo test --release --manifest-path tools/zag-installer/native-usb/Cargo.toml
cargo build --release --manifest-path tools/zag-installer/native-usb/Cargo.toml
cargo test --release --features native-install-dev \
  --target-dir /tmp/zag-native-dev-build \
  --manifest-path tools/zag-installer/native-usb/Cargo.toml
```

Do **not** copy the feature-enabled binary into the installed GUI. The
default release helper must continue rejecting `install` and
`install-signed-dev`. The experimental code remains on the development
branch and should be reviewed before any physical write to an iPhone.
