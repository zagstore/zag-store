# Zag Installer prototype

This CLI verifies or downloads the exact official unsigned Beta 3 release. On macOS it can attempt a fresh USB install using the separately verified Personal Team Beta 3 test artifact. It does not sign in to Apple or create a signed IPA. The desk-side install probe and production bootstrap are different milestones.

## Operator test

Requires Python 3.9+, a macOS-compatible Xcode selected for `xcrun devicectl`, Homebrew OpenSSL 3, and the Apple Root CA PEM used for earlier preflight. The tool can run on Intel and Apple Silicon Macs with those dependencies. Only the current Mac environment was exercised. Connect and unlock the same target iPhone. Approve Trust and enable Developer Mode through the native prompts. The test signing profile must still be valid and cover this device.

Run this single Terminal command. The CLI has no compilation step. The first process tests the host-side checks. The second verifies the official unsigned input. The last verifies and stages the existing signed copy and waits for an explicit `INSTALL` confirmation. The device identifier is derived from the connected phone and stays local.

```sh
cd ~/Documents/ZagStore-AppleID-Test && \
export PATH="$(brew --prefix openssl@3)/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 && \
python3 -m unittest discover -s tools/zag-installer && \
python3 tools/zag-installer/zag_installer.py prepare "$HOME/Downloads/ZagStore-1.0.0-beta.3.ipa" && \
python3 tools/zag-installer/zag_installer.py install-signed "$HOME/Downloads/ZagStore-Signed.ipa" \
  --team FTB8PRW638 --apple-root "$HOME/Downloads/AppleRootCA.pem"
```

The signed test copy is separately pinned and must map exactly to `app.zagstore.ios.FTB8PRW638`, distinct from AppTesters' `com.cwd43.gu29`. It expires on 3 December 2026 at 23:29 UTC according to the prior verification. The validator independently rechecks expiry, certificate purpose and binding, signatures, entitlements and connected-device eligibility. The CLI rejects a pre-existing mapped destination, repeats discovery and collision checks after approval, and verifies the installed version and build by device inventory. Open the newly installed app to verify launch and confirm the AppTesters copy still launches. The prototype has no uninstall or revocation operation. No background service is started.

## Desktop integration findings

- `AppleAuthCore/zag-isideload` is the existing MIT/MPL-2.0 Rust fork for authentication, 2FA, sessions, and developer portal requests. It deliberately omits the upstream signer and device installer. Its network policy and explicit TLS allowlist should carry into any desktop client. `zag-apple-bridge` exposes analogous operations through FFI, with a native-provider callback for the iOS app. The iOS callback cannot simply be referenced from a desktop process. A supported provider or separately authorized anisette architecture and its failure behavior still need validation. Native anisette artifacts in an untracked local checkout are outside this prototype.
- The native production signer orchestrates Zsign with Swift, Keychain, profile validation and IPA work. The C++ signer can be evaluated on desktop separately from iOS storage and Keychain integration. A local auth/provisioning/signing adapter must reconcile groups and extensions, preserve exact mapping and never auto-revoke. Reusing the Rust library handles protocol logic but does not establish cross-platform certificate or signing behavior.
- IDeviceKitten exposes host usbmuxd connection, lockdown, AFC and Installation Proxy, plus RSD client support. Its tools include desktop examples. First trusted USB install uses CoreDevice in this prototype. A Windows adapter still needs a supported Apple device driver/usbmuxd path, compatible signing backend and physical testing. The platform-neutral artifact functions can run independently of that adapter. [Apple command-line tooling](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference) · [Upstream desktop driver notes](https://github.com/nab138/iloader)
- Zag Store's current self-renewal enrollment binds the running signer to the exact local account-scoped signing identity. A signature created on the Mac has no matching private key in the phone's Keychain. Subsequent reauthentication is not sufficient. Before considering handover, test a profile-only adoption design that verifies authenticated Personal Team ownership, the original signing leaf's membership and validity, authenticated installed profile readback, and exact signed entitlements across all components. Do not export passwords, keys, sessions or pairing records to the website. The installed app can create its own separately authorized pairing using its existing Settings flow.
