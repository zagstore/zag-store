# Zag Store 1.0.0 Beta 5 (Build 5)

**Your Apple IDs. Your certificates. Your freedom.**

**One store. Multiple Apple IDs. Your own certificates.**

Native Apple ID signing comes to Zag Store. Sign eligible apps on your iPhone or iPad with a free Apple ID and its Personal Team. You can also keep using the paid signing certificates you already own. Both methods are available in the same app.

## Sign with the account you choose

- Add multiple Apple IDs and keep them connected between launches while their sessions remain valid. In **Apple IDs**, choose the active account for new Apple ID signing. Switching accounts leaves the other connections available.
- Sign in directly with Apple and complete Apple’s two-factor verification when required. Zag Store keeps its sessions and signing keys in the device’s Keychain.
- Apps keep their original signing account or certificate. Changing the active account affects new signing jobs. Sign Separate Copy lets you choose a different connected account when a distinct installation is available. If a previously used account needs to sign in again, Zag Store identifies that account when you refresh its apps.
- Continue to import and use supported certificate and provisioning profile pairs. Choose the signing method when you sign. Apple’s Personal Team limits still apply to free signing, and iOS decides whether a particular app can be installed.

## Keep eligible apps current

- **Refresh All** handles eligible apps signed with Apple IDs or supported certificates. Apps with missing credentials, pairing, or verified signing information get an explanation so you can resolve the issue and retry.
- Where the installed signature is still valid and Apple issues a compatible profile, Zag Store renews the profile in place and verifies the new expiry on the device. Compatible apps can share a single profile handoff, reducing repeated device work.
- Enable optional **Automatic Refresh** and **Expiration Notifications** for eligible Apple ID apps in Signing Options. Automatic refresh is subject to iOS scheduling and requires working pairing and account access. Notifications can remind you before a verified expiry and open Refresh All.
- Eligible copies of Zag Store can renew their own profiles when the device can verify the running copy’s signing identity and ownership. Copies signed elsewhere may require their original signing tool for renewal.
- Use **Refresh All Apps** and **Update All Apps** from the Home Screen Quick Actions or the Shortcuts app. Refresh maintains signing eligibility. Update checks for newer app versions.

## Easier to see and manage what’s installed

- The Apps page shows installation progress, verified expiry, and which account or certificate signed an app when that evidence is available. The running Zag Store copy has its own management controls. A verified Apple ID-signed IPA awaiting installation can be exported for local use.
- Account and device capacity views distinguish verified coverage from estimates. Signing progress and recovery messages explain issues with pairing, App IDs, certificates, and profiles.
- Zag Store checks that replacement profiles match the app, device, certificate, and signed permissions. It verifies the result before reporting a renewed expiry. Certificate conflicts ask for a decision before any revocation.
- Settings has clearer routes to Sign App, Apple IDs, Certificates, support, and community links.

Beta 5 requires iOS or iPadOS 16.4 or later. Native Apple sign-in and Personal Team signing have been exercised on a physical device. The full Beta 5 matrix for multi-account migration, mixed signing identities, scheduled reminders, and self-renewal remains in device testing.
