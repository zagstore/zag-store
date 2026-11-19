# Free Apple Developer Accounts: signing groundwork

Status, 18 November 2026: on branch `claude-free-developer-accounts` (draft PR #24). It is tested end to end without any Apple service.
- Live sign-in, live anisette, the live developer portal and anisette stage 3 all remain disabled.
- The AppTesters signing path (`ZsignHandler`, `SigningHandler`) is unchanged. A test checks this against the base branch.
- Zsign and RPPairing are unchanged.

## What was built

| File | Purpose |
|---|---|
| `ZagSigningKey.swift` | `ZagSecuritySigningKeyFactory`: an RSA 2048 key made with the Security framework, in memory only (`kSecAttrIsPermanent: false`). It builds a PKCS #10 certificate signing request signed with SHA-256, and checks that an issued certificate is for its key. Also `ZagCertificateSigningRequest` (make, validate) and `ZagCertificateInspection` (serial, common name, expiry, public key). |
| `ZagDeveloperPortal.swift` | `ZagIssuedProfile(profileData:)` reads a signed profile with Zag Store's own parser. `ZagSigningKeyFactory` gained `check(certificate:privateKey:)`. |
| `CertificateModel.swift`, `CertificateReader.swift` | The parser's decoding moved, unchanged, into `Certificate.decode(profileData:)`. `CertificateReader` calls it, so AppTesters import and free accounts share one parser. |
| `ZagFreeAccountProvisioner.swift` | A newly issued certificate must be for the key just made. Its serial and expiry are read from the certificate itself. |
| `ZagFreeAccountSigningAdapter.swift` (Debug only) | The test adapter from a provisioning result to the existing Zsign signer, plus the sign, install and refresh lifecycle around it. Nothing in the app calls it. |
| `ZagDeveloperPortalSimulation.swift` (Debug only) | Can take a `ZagSimulatedIssuer`, so tests get real certificates and signed profiles. |

## Key handling

- **Creation.** The key is made in memory by the Security framework, and the factory never writes it to the Keychain itself.
- **Export.** It is exported once, as PKCS #1. Zsign needs the key as a file at signing time.
- **Storage.** It is stored only as `ZagSigningIdentity`, under the existing `signingPrivateKey` secret in the non-synchronizing, this-device-only Keychain. The identity describes itself as `[signing identity <serial>]`, without the key.
- **During signing.** The key file is created with mode 0600, inside a folder with mode 0700 in the app's temporary directory. Afterwards it is overwritten and the folder is removed, whether signing succeeds or fails. Tests check the permissions during signing and that nothing remains afterwards.
- **What leaves the device.** Only the certificate signing request, which holds the public key. A test checks the request contains no private-key material.
- **Logging.** None of the key, provisioner or adapter code logs; a source check enforces this. Diagnostics contain no key or device ID.
- **Revocation.** Certificates are never revoked automatically. The portal interface has no revoke operation at all, and a source check enforces that.

## Signing with the existing Zsign

The adapter calls `Zsign.sign` exactly as `ZsignHandler` does:
- the private key file goes where the PKCS #12 file normally goes, which Zsign reads directly;
- Zsign takes the matching certificate from the profile;
- the profile is embedded;
- the bundle ID is changed to the team's.

After signing, the adapter checks that the bundle ID, the embedded profile and a CMS signature are all present.

Two findings from reading and running Zsign. Neither was changed.

1. **Extensions.** Zsign signs every nested extension with the main app's entitlements, and embeds the profile only in the main app (`Zsign/src/archo.cpp`, `bundle.cpp`). A free team needs each extension signed for its own App ID with its own profile. The adapter therefore refuses apps with extensions, App Clips or watch apps before signing. A test records the evidence.

   **Supporting such apps needs a change to the Zsign fork:** per-bundle profiles and entitlements. That is your decision.

2. **Silent signing failure.** Zsign makes the CMS signature only for certificates issued under Apple's WWDR intermediates, matched by issuer-name hash. For any other issuer it still reports "Signed OK!", but the result has no signature. The adapter reads the signature from the executable and refuses such a result. A test covers this.

## Test evidence

`scripts/test-zag-free-account-signing.sh`: **56 checks plus 4 source and branch checks.** It:
- builds the app's own Zsign sources for macOS (`scripts/zag-build-zsign-macos.sh`, out of tree, never writing inside `Zsign/`);
- compiles a real arm64 iOS executable;
- uses two throwaway local test authorities, deleted after each run. One has the subject name of Apple's WWDR G3 intermediate, purely so Zsign takes its normal signing path; it is self-generated and trusted by nothing. The other has an ordinary name.

What it covers:
- **Keys and requests.** RSA 2048 PKCS #1 keys. OpenSSL independently verifies each request and reads it as SHA-256 RSA 2048 with CN=Zag Store. Requests hold no private-key material. Damaged, altered, truncated and 1024-bit requests are refused.
- **Certificates.** An issued certificate is matched to its key, with serial and expiry. Wrong-key and unreadable certificates are refused. Dates after 2049 are read correctly.
- **Profiles.** Read with Zag Store's parser; team, bundle, device and certificate agree with `Certificate.decode`. Unreadable profiles are refused.
- **Signing.**
  - The provisioner gets a certificate for the on-device key.
  - Zsign signs the app; the team's bundle ID and this App ID's profile are embedded.
  - `codesign` reads the team identifier and team.
  - OpenSSL verifies the CMS signature over the code directory, and the signer is exactly the issued certificate.
  - The signed entitlements are the resolved ones (team App ID, team keychain group, no push).
  - Nothing is left on disk.
- **Guards.** Apps with extensions are refused, with the Zsign evidence recorded. Also refused: an identity mismatch, an app that isn't the provisioned one, a Zsign failure, and an unsigned "success".
- **Lifecycle on a stand-in device.**
  - The install is recorded from the expiry the device reports back: 7 days, with reminders scheduled.
  - The urgency progression is checked: normal for days 1–3, eligible on day 4, recommended on day 5.
  - A day-5 refresh reuses the certificate and App ID, so nothing new is created, and is verified with a new 7-day expiry.
  - After expiry, the app is first in Refresh All, and refreshing re-registers its lapsed App ID.
  - A refresh the device doesn't confirm is recorded as "not verified", never as done.
  - Install failures back off.
  - An expired session holds automatic refreshes until the user signs in.
  - None of these is signed: a profile without the device, a fourth app, or anything at the certificate limit. At the limit, nothing is revoked either.
  - The default build cannot provision or sign.

## Remaining before the first real free-account signing test

See the report in PR #24 and `LIVE-AUTH-REVIEW-PROPOSAL.md`. In short:
1. live sign-in;
2. anisette (the study ends 25 Nov; stage 3 not approved);
3. the live portal;
4. a production installer that wraps the existing RPPairing installer and reads the installed expiry back;
5. a production wiring of the adapter and the refresh ledger;
6. optionally, per-extension signing in the Zsign fork.
