# Free Apple Developer Accounts: Phase 3 groundwork (simulated)

Status, 18 November 2026: the developer-portal interface and the provisioning coordinator are on branch `claude-free-developer-accounts` (draft PR #24). They are tested against a simulated portal.
- **The live portal is not implemented and is disabled** (`ZagLivePortal.isEnabled = false`).
- Live sign-in and live anisette stay disabled.
- Stage 3 of the anisette study is not approved.

## What was built

| File | Purpose |
|---|---|
| `ZagDeveloperPortal.swift` | `ZagDeveloperPortalService`: the operations a free team needs (devices, App IDs, app groups, development certificates, profiles). It has typed results and errors, and a disabled live stub. Also: `ZagSigningKeyFactory` (on-device key and certificate request, disabled), `ZagSigningIdentity` (key and certificate, kept in the Keychain), and `ZagProvisioningProfileCheck`. |
| `ZagFreeAccountProvisioner.swift` | `ZagFreeAccountProvisioner` actor: provisions an app and its extensions for one device and team, and returns everything signing needs. |
| `ZagDeveloperPortalSimulation.swift` (Debug only) | An in-memory team with the published free-account limits (3 devices, 10 App IDs lasting 7 days, 7-day profiles), a certificate limit, foreign-owned identifiers, injected failures and tampered profiles. Also a synthetic key factory. |

The coordinator reuses the Phase 1 plans unchanged: `ZagInstallSlotPlan`, `ZagDeviceRegistrationPlan`, `ZagAppIDPlan`, `ZagCertificatePlan`, `ZagBundleIdentifierMapping` and `ZagFreeAccountEntitlements.resolve`.

## Behaviour

1. **Request.** Bundle IDs are mapped for the team: the app, then extensions under it, with duplicates refused. An invalid request is refused locally.
2. **Install slots.** Three apps from the team on the device stop provisioning *before Apple is asked*. A refresh of an installed app needs no slot.
3. **Device.** Reused if registered. A fourth device is refused.
4. **App ID capacity.** Checked from Apple's list *before* any certificate or App ID is created, and reported with the time the next slot frees.
5. **Certificate.** The stored identity is reused when Apple still lists its certificate with at least 7 days left. Otherwise a key is made on the device and only the request is sent. At the limit, the user is offered certificates to revoke, soonest-expiring first. **Nothing is ever revoked automatically.** If the Keychain refuses the key, provisioning stops.
6. **App IDs.** Missing ones are registered. An identifier owned by another team is reported.
7. **App groups.** Mapped for the team, registered and assigned per App ID.
8. **Profiles.** Each one is checked: team, bundle ID, `application-identifier`, the device, the certificate, and at least an hour left. Then entitlements are resolved against it. Capabilities a free team lacks (for example push notifications or Network Extensions) are reported as rejected, not granted.
9. **Result.** Mapped bundle IDs, profiles, resolved entitlements, the certificate serial, the earliest expiry, and a record of what this run created.

Every portal call has a deadline and honours cancellation. Failures map to user-facing messages: session expired, network, rate limited, unexpected response, timed out, cancelled, unavailable. Diagnostics never contain the device identifier, certificate or key.

## Test evidence

- `scripts/test-zag-free-account-portal.sh`: **43 checks**, passing on 4 consecutive runs. They cover:
  - first provisioning with an extension, an app group, keychain groups and rejected capabilities;
  - re-provisioning with no changes;
  - a refresh after 7 days;
  - every limit checked before any change;
  - certificate limit, renewal and Keychain failure;
  - all 6 profile defects;
  - session, network, rate-limit, malformed, timeout and cancellation failures;
  - the disabled live path.
- The Debug-only checks (`test-zag-free-account-sign-in.sh`, `test-zag-free-account-release-binary.sh`) now also cover the portal simulation: it is wrapped in `#if DEBUG`, has no network path, and is absent from Release builds.

## Remaining before a real free-account signing test

1. **Live portal service** (`ZagDeveloperPortalService`) behind `ZagLivePortal.isEnabled`. Like live sign-in, it needs independently confirmed service behaviour, a security review, and supervised testing with the dedicated account. Nothing about it is reconstructed here.
2. **On-device key and certificate request** (`ZagSigningKeyFactory`): RSA key generation and a standard certificate signing request, using the system's Security framework or the OpenSSL the app already ships. The key never leaves the device.
3. **Profile reading.** Fill `ZagIssuedProfile` from the signed profile file, reusing the app's existing profile parsing.
4. **Signing hand-off.** Pass the identity, profiles and resolved entitlements to the existing Zsign signer (Phase 4). Record the result in the Phase 1 refresh ledger.
5. **Installation.** The existing RPPairing installer, then verification of the installed expiry.
