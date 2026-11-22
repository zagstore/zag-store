# App Store Connect developer-account signing — architecture and milestones

**Status: offline implementation (M1–M3) behind a closed feature gate. No live
Apple calls, no production deployment, no global enablement.** This document is
the actionable architecture promised in `ASC_API_FEASIBILITY.md`. It builds on
that feasibility assessment and on the preliminary licensing assessment in
`WINDOWS_NATIVE_BACKEND.md` (pending specialist legal review).

The target is **Model 2**: a user brings their **own paid Apple Developer
account** and an App Store Connect API key, which stays on the device. It is a
new, parallel signing method beside the free-account and imported-certificate
methods — never a replacement for free-account anisette authentication.

## 1. Key eligibility and provisioning permissions (verified)

Provisioning over the ASC API (certificates, identifiers, devices, profiles)
needs a **team key with the Admin role**. This holds for both membership types:

| | Individual membership | Organization membership |
| --- | --- | --- |
| Create the key | The sole member is the Account Holder; they enable API access and create a **team key**. | An Admin creates a **team key**. |
| Provisioning access | Inherent (the member is the Account Holder). | The key's role must include Certificates, Identifiers & Profiles — the **Admin** role. |

**Important correction to the feasibility note:** *individual* (user-based)
keys **cannot** call the Provisioning endpoints and carry no issuer ID — only
**team** keys can provision. Zag Store therefore mints **issuer-ID (team-key)**
JWTs and **requires an Issuer ID** during onboarding, which structurally
excludes user-based keys. The code does not assume access: the connection
check probes a provisioning endpoint and reports a `403` as "this key needs a
team key with the Admin role" rather than proceeding.

Sources: Apple — [Creating API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api),
[Role permissions](https://developer.apple.com/help/app-store-connect/reference/role-permissions),
[Account roles](https://developer.apple.com/help/account/manage-your-team/roles/);
and the fastlane and Apple-forum notes that individual keys cannot use the
Provisioning endpoints.

## 2. On-device vs backend

Every ASC operation is plain HTTPS plus a locally minted JWT, so for Model 2
**everything runs on-device and no Zag Store server is involved**:

| Step | Where | Component |
| --- | --- | --- |
| Generate signing key + CSR | Device | existing `ZagSigningKey` / `ZagSigningKeyFactory` |
| Mint ES256 JWT from the `.p8` | Device | `ZagASCToken` (CryptoKit P-256) |
| REST calls (devices, certificates, bundle IDs, profiles) | Device | `ZagASCClient` + `ZagASCDeveloperPortal` |
| Read the target device UDID | Device | existing lockdown/RPPairing pairing |
| Sign the IPA | Device | existing `ZagFreeAccountSigningAdapter` (Zsign) |
| Install + verify | Device | existing RPPairing installer + `ZagInstalledProfileCheck` |

## 3. How it maps onto the existing pipeline

The free-account path already abstracts Apple behind
`ZagDeveloperPortalService`, and the provisioner, signing adapter, installer and
verification are driven through it. The ASC integration reuses that seam:

- **`ZagASCClient`** — a typed client over the shared `ZagHTTPTransport` (the
  real transport keeps the system's TLS validation; tests use a mock). Reads
  list resources; writes create a certificate (from the device's CSR), a
  device, a bundle ID and a profile. The host is held without a scheme and the
  URL is built with `URLComponents`, so no Apple URL string appears in source.
- **`ZagASCDeveloperPortal: ZagDeveloperPortalService`** — translates the portal
  operations to ASC calls and the responses back into the shared domain types,
  decoding the downloaded `.mobileprovision` with the existing parser.
- **`ZagASCProvisioner`** — produces the same `ZagProvisioningResult` the free
  path produces, reusing the shared plans (`ZagDeviceRegistrationPlan`,
  `ZagAppIDPlan`, `ZagCertificatePlan`), `ZagProvisioningProfileCheck`, the
  profile parser and the entitlement resolver. It is simpler than the free
  provisioner (no certificate journaling: the ASC API is not lossy the way
  GrandSlam is). Paid limits (`ZagTeamLimits.forTeam(.individualPaid)`:
  100 devices, no 7-day/10-App-ID cap) already exist.
- **`ZagASCSigningCoordinator`** — ties provisioning to the **existing** signing
  adapter and installer, producing a signed, installed, verified
  `ZagSignedAppRecord`. Its authorisation is a new, additive
  `ZagSigningAuthorization.developerAccount(...)` factory; the free-account
  directory and the G5 experiment are untouched.
- **`ZagDeveloperAccountService`** — the app wiring for one connected account
  (stored credential → client → provisioner → coordinator), with every
  dependency injected. `ZagDeveloperAccountLive` supplies the real ones: the
  App Store Connect-only transport (made in the transport file), a dedicated
  Keychain store and Keychain-held signing keys, the existing adapter on its
  strict Keychain-key path, and the existing RPPairing installer, which reads
  the device's installed profiles back so an install is verified. Adapter and
  installer run behind their own `.developerAccount` gates, so free-account
  signing stays closed.
- **UI** — a *Signing Methods* section in the existing Signing screen, shown
  only while the gate is open, opens the Developer Account screen: connect a
  key, install a Library app (cancellable), disconnect, or remove the account.

**Profiles are idempotent.** Zag Store keeps one development profile per App
ID under a fixed name (`Zag Store <bundle ID>`). A refresh reuses it while it
is `ACTIVE`, names this device and signing certificate, and stays valid for at
least 30 more days; otherwise it is deleted and replaced, so profiles never
accumulate. Apps already installed keep the profile embedded in them.

**Status is precise.** The connection check is read-only, so it reports
*Credentials validated — provisioning unverified*; *Provisioning verified* is
shown only after a write with the key (device, bundle ID, certificate or
profile) has succeeded.

Apps receive a team-suffixed bundle identifier (e.g. `com.example.app.TEAMID`),
exactly as on the free path, so an app keeps its data across refreshes and
never collides with another team's identifier.

## 4. Can ASC API do the whole signing workflow?

No — and that is expected. ASC issues *provisioning assets only*. The complete
workflow also needs the device-made key + CSR, the ES256 JWT minter, the local
Zsign signer and the installer — all of which Zag Store already has or adds in
`ZagASCToken`. ASC never signs the IPA.

## 5. Security boundaries

- The `.p8`, the ES256 JWTs and the signing private key **never leave the
  device** and are **never uploaded to any Zag Store server**. The `.p8` is
  held in the Keychain (`.developerAPIKey`, this device only, after first
  unlock, not synchronised); JWTs live ≤20 minutes in memory; the signing key
  stays in the Keychain via the existing strict path.
- The onboarding model keeps the imported `.p8` in a private field, never a
  published property, and clears it once stored. Nothing is logged (the offline
  guard forbids `print`, `os_log`, `Logger` and any embedded Apple URL in the
  ASC sources).
- Account removal clears the key through the shared store's `deleteAll`;
  disconnect removes just the key; a revoked key surfaces as a `401`/`403` the
  user can act on.
- The feature is inaccessible unless `developerAccountEnabled` is set (closed in
  every release build); the onboarding model and the signing coordinator both
  refuse to act when the gate is closed.

## 6. Milestones

- **M1 — foundation (done, offline).** `ZagASCToken`, `ZagASCClient` reads,
  per-account Keychain credential storage, SwiftUI onboarding, the gate.
- **M2 — provisioning (done, offline).** ASC write operations, the ASC portal,
  the provisioner producing a `ZagProvisioningResult` and storing the identity.
- **M3 — sign + install (done, offline).** The coordinator reusing the existing
  adapter + installer + verification; the additive developer-account
  authorisation.
- **Integration (done, offline).** App wiring, precise status, idempotent
  profiles, and every request checked against Apple's published OpenAPI
  document (`scripts/zag-asc-openapi-check.py`, version 4.6.1). Tests:
  `scripts/test-zag-developer-account.sh` (177 offline checks over a stateful
  mock of the ASC API).
- **Live validation (gated, not in this work).** Point the same code at one
  real paid account and one device, behind explicit authorisation, in a
  live-test build (§8). Only after a verified install + refresh would the gate
  be opened for releases.

## 7. Remaining Apple Developer Program restrictions

- **$99/year per user**; serves **no free Apple IDs** — a paid, parallel method,
  never a replacement for the free path.
- Development profiles authorise the user's **own registered devices only**;
  redistribution to third parties is out of scope (Ad Hoc/TestFlight/App Store).
- **100 devices per type per membership year**, with no mid-year deletion (only
  disable); one active key per concern.
- App groups are **not** part of M2; an app that requests them fails cleanly
  rather than being signed without them.
- The team key must carry Certificates, Identifiers & Profiles (Admin) access.

## 8. Minimum live-test steps (pending separate authorisation)

Live testing is **not** part of this offline work and needs explicit
authorisation plus the owner's own paid account and device. When authorised:

1. In App Store Connect → Users and Access → Integrations, create a **Team Key**
   with the **Admin** role; download the `.p8` once; note the **Key ID** and the
   **Issuer ID**. Note the ten-character **Team ID** from the membership page.
2. Build a live-test app: Release with
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) ZAG_ZSIGN_STRICT ZAG_DEVELOPER_ACCOUNT_LIVE_TEST'`
   (the live-test condition is a compile error without `ZAG_ZSIGN_STRICT`;
   nothing in the project sets either). Sign and install it as a personal test
   build only.
3. Settings → Signing → Signing Methods → Developer Account: import the `.p8`,
   enter the Key ID, Issuer ID and Team ID, and Connect. The status reads
   *Credentials validated — provisioning unverified*: a read-only check cannot
   show that the key may create anything.
4. With the iPhone paired, choose one single-target Library app (no
   extensions, no app groups) and Install. The first successful write turns
   the status into *Provisioning verified*.
5. Confirm the app launches. The screen reports *Installed and verified* only
   when the device's installed profile matches the team, App ID and expiry.
   Install again: it should reuse everything and make no writes.

Expected first-run failures and what they mean: `403` on the first write →
the key can read but not provision (not a team key with the Admin role); `invalidTeamID` → the Team ID is wrong; profile
`certificateMissing`/`deviceMissing` → the device or certificate was not yet
registered when the profile was cut (re-run). There are open developer reports
of `POST /v1/certificates` intermittently failing (~Jan 2026); confirm against
the real account before relying on it.
