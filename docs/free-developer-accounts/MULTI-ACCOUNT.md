# Several Apple Accounts at once

Status, 18 November 2026: on branch `claude-free-developer-accounts` (draft PR #24).
- Models, services and storage are implemented and tested with synthetic accounts only.
- Live sign-in, the live portal, live anisette and free-account signing all stay disabled (`ZagFreeAccountSigning.isEnabled = false`).
- There is no account UI yet. The models are shaped for a Liquid Glass account list: one row per account, its teams beneath, a default marker, and per-app ownership.

## What an account is

| Concept | Type | Notes |
|---|---|---|
| Account | `ZagAppleAccountRecord` | Has a stable `id` (UUID). Also stores `accountKey` (SHA-256 of Apple's own account identifier, never the email), a masked Apple ID and its teams. A changed email keeps the same account. |
| Team | `ZagDeveloperTeam` | Free Personal Team, paid individual or organisation. A paid account can have several teams. |
| Scope | `ZagSigningScope` (`accountID` + `teamID`) | Owns a signing identity, devices, App IDs, profiles and installed apps. |
| Registry | `ZagAccountRegistry` | Holds the accounts, the default scope and the migration flag. Stored under `ZagStore.accounts.registry.v2`; the simulation uses its own namespace. |
| Directory | `actor ZagAccountDirectory` | Handles sign-in, sessions, the default, authorisation and removal. |

## Isolation is enforced below the UI

- **Keychain.**
  - Every item is named `<account>.<kind>[.<team>]`.
  - Signing identities are per account and team.
  - Removing an account deletes exactly its own items, by prefix. This is tested against the real iOS Keychain.
- **Sessions.**
  - Each account has its own authenticator, bound to its ID, and its own session summary (`ZagStore.accounts.session.<id>`).
  - A summary filed under another account's key is never returned.
  - An authenticator bound to one account refuses a sign-in that turns out to be a different Apple Account (`differentAccount`), and stores nothing.
- **Signing.**
  - Signing needs a `ZagSigningAuthorization`. Only the directory can create one, and only while that account is signed in with an unexpired session. It lapses after 10 minutes.
  - The provisioner rejects a request whose account or team differs from its authorisation, or from the account its portal session belongs to.
  - The adapter rejects an authorisation for another team.
- **No substitution.**
  - `signingScope(explicit:)` uses the explicit choice, otherwise the default.
  - A signed-out or expired default is an error (`notSignedIn`). Another account is never used instead.
- **Refreshes.**
  - Every `ZagSignedAppRecord` has an `owner` (`ZagAppOwnership`: scope, team kind, certificate serial, profile UUID).
  - `ZagAccountDirectory.route` sends a refresh only to that owner. Otherwise it is blocked with `signedOut`, `accountRemoved`, `teamUnavailable` or `noOwner`.
  - Clearing a held failure (`resolve(_:account:)`) affects only that account's apps.
- **Failures.** One account's portal or session failure is recorded against its own apps only. Tests show the other accounts keep refreshing.

## Sign-out and removal

- **Sign out.**
  - Removes only that account's session item and summary.
  - Its signing identities and refresh records stay, so signing back in resumes refreshing.
  - Other accounts are untouched.
- **Remove.**
  1. `removalPlan` lists the account, its teams and every installed app it signed.
  2. The user confirms with a choice:
     - **keep until expiry:** apps keep their owner, never refresh, and drop out of the schedule;
     - **forget:** the account's refresh records are deleted.
  3. A confirmation whose app list is out of date is refused.
  4. If the Keychain refuses a deletion, the account is not reported as removed.
  - A removed default moves to a remaining account. No app is ever reassigned to another account.
- **Certificates are never revoked automatically.** The portal interface has no revoke operation.

## Migration from the single-account version

`ZagAccountDirectory.start()` runs once per install:
1. It reads the v1 summary (`ZagStore.freeAccount.session.v1`, or the simulated key in the simulation).
2. It creates the record with the same account ID, so every existing Keychain item stays reachable.
3. It copies the v1 signing identity to the session's team, verifies the copy byte for byte, then deletes the old item.
4. It removes the v1 summary and sets the flag.

Each step is repeatable. If a step fails (tested with a Keychain that refuses deletes), the next launch completes it and nothing is lost. Records from before ownership load with no owner. They are never refreshed automatically: they wait for the user, because guessing an account would break isolation.

## Apple's limits, and what several accounts cannot change

From Apple's [membership comparison](https://developer.apple.com/support/compare-memberships/) and [devices overview](https://developer.apple.com/help/account/devices/devices-overview):

| | Free Personal Team | Paid (individual or organisation) |
|---|---|---|
| Profile lifetime | 7 days | Up to 1 year |
| App IDs | 10, each expiring after 7 days | No published limit |
| Registered devices | 3 per platform | 100 per product family per membership year; removing a device does not free its slot until renewal |
| Apps on a device | **3 apps signed with free profiles, per device** | Not limited this way |

`ZagTeamLimits` encodes exactly these. Two points to be clear about:

1. **The 3-app limit is enforced by the device, not the account.** Signing a fourth app with a second free account does not get round it. Zag Store therefore counts free-team apps from every account together (`freeAppLimitApps`), and the tests confirm a second account cannot install a fourth app. Developer forums report that offloaded apps may still count. Zag Store cannot see those, so iOS may still refuse an install that Zag Store allowed ([forum thread](https://developer.apple.com/forums/thread/49304)).
2. **Unpublished limits are not assumed.** Apple publishes no limit on development certificates per free team. Zag Store reacts to the portal's own refusal and does not revoke anything to make room.

Paid teams are not held to the free 3-app limit or the 10-App-ID limit. Their device limit is per membership year. Third-party summaries such as [Expo's comparison](https://expo.dev/blog/apple-developer-program-explained-free-vs-paid) agree with Apple's pages.

## Tests

| Suite | Checks | Covers |
|---|---|---|
| `scripts/test-zag-apple-accounts.sh` | 52 | Concurrent sign-ins; stable IDs; duplicate sign-in; different-account refusal; per-account sign-out; relaunch restore; per-account session rejection; default, explicit choice and no fallback; expiry; migration (normal, repeated, interrupted); removal (plan, stale confirmation, Keychain failure, default moves); ledger ownership, schedule and on-disk store; limits |
| `scripts/test-zag-free-account-signing.sh` | 84 | Four scopes on one device signed with real Zsign; separate certificates; the device-wide free-app limit across accounts; paid exemption; provisioner bound to its account; routed refreshes; sign-out blocks only its own account; failure isolation; unverifiable expiry; removal |
| `scripts/test-zag-free-account-keychain.sh` | 13 | Team-scoped items, invalid team IDs, per-account deletion, on the simulator's real Keychain |
