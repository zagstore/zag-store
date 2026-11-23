# Zag Companion v0.1

A macOS companion that provisions, signs, installs and renews iOS apps using a
**free Apple Account**, driving Zag Store's existing signing engine. The private
signing key never leaves the login Keychain.

## What it does

1. Detects a connected, paired iPhone (`devicectl`).
2. Identifies the available Xcode **Personal Team** (free).
3. Lets you select a local `.ipa` and reads its bundle ID / signing needs.
4. Resolves a provisioning profile for that bundle ID + device — reusing one
   Xcode already issued, or (only if you allow it) provisioning a
   bundle-ID-specific temporary Xcode project.
5. Signs the app through **Zag Store's engine** (`ZagExternalKeychainSigningKey`
   + `ZagStrictComponentSigning`), the key staying a Keychain reference.
6. Verifies the signed app (`codesign --verify --strict` **and** Zsign).
7. Installs it on the iPhone and tracks it for renewal.
8. Renews managed apps with a valid profile — re-signing and reinstalling,
   reusing the certificate where possible (no unnecessary new certificates).

## Requirements

- macOS with Xcode installed and signed in to your Apple Account
  (Xcode ▸ Settings ▸ Accounts) so a free **Personal Team** exists.
- A connected, unlocked iPhone that trusts this Mac.
- First launch of a newly-signed app needs a one-time trust:
  **Settings ▸ General ▸ VPN & Device Management ▸ (Developer App) ▸ Trust**.

## Build and launch

```sh
# from the repo root
ZagCompanion/build-zag-companion.sh
open ZagCompanion/build/ZagCompanion.app
```

Then in the window: pick the iPhone and the Personal Team, **Select IPA…**,
and **Install with Zag Companion**. Leave *Allow new Apple-side provisioning*
off to reuse existing profiles only (no device-slot or Apple-side changes);
turn it on to let Xcode register the device and issue a profile for a new
bundle ID.

## Renewal

Free profiles last 7 days. Installed apps appear under **Managed apps**; press
**Renew** before expiry to re-sign and reinstall with a valid profile. The
companion reuses the existing certificate when it can, so routine renewal issues
no new certificate and performs no Apple-side provisioning.

## Pairing with Zag Store (foundation)

v0.1 establishes the companion's Curve25519 identity (stored in the Keychain)
and a pairing code, and the sealed-session primitives (`ZagCompanionPairing`).
The encrypted local transport between Zag Store on iOS and the companion is the
next step. Apple Account credentials, private keys and unprotected signing
material are never transmitted.

## Verifying the engine path (no GUI)

`scripts/test-zag-companion.sh` builds the core and runs the full
install → launch → renew flow on a connected device, using the same code the
app calls.
