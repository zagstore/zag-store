# G5 existing-account path (issue #37)

Status, 19 November 2026: **implemented and tested offline; not authorised.** Nothing here has contacted Apple or an anisette provider.

The owner has confirmed that the Apple Account for the first test has signed apps before. The empty-account campaign's E4 ("no certificates, App IDs or devices") cannot pass for it. This path is a separate build mode; the empty-account campaign is unchanged.

## What is different, and what is not

| | Empty-account campaign | Existing-account path |
|---|---|---|
| Build conditions | `ZAG_APPLE_BRIDGE ZAG_ZSIGN_STRICT ZAG_LIVE_EXPERIMENT` | the same plus `ZAG_EXISTING_ACCOUNT_EXPERIMENT` |
| E4 before the first change | the three listings must be empty (`verifyAccountState`, unchanged) | an accepted read-only inventory (`ZagExistingAccountPreflight.run`); without one, every change is refused (C8) |
| Changes | whatever provisioning needs, bounded by the one-use certificate budget | only those the inventory requires **and** the owner approves, each separately, each sent at most once (`ZagExistingAccountApprovals`) |
| Budget recheck | certificate listing still empty | certificate listing unchanged since the inventory |

Unchanged in both:
- the campaign (E5 arming, C1–C8, stop rules, halt);
- the one-use certificate budget;
- C5 in the bridge, before credentials;
- the network guard;
- no revocation, deletion or retries.

## The inventory (read-only)

- **Calls:** it sees the portal only through `ZagPortalReader`: certificates, devices and App IDs, nothing else. Profiles have no read-only listing (the portal's profile call creates or renews one), so a profile is always an approved change.
- **Failures:** a listing that fails, is refused, is malformed or is cancelled is **unknown**, never empty. An unknown inventory decides nothing and is not accepted.
- **Reuse of a certificate:** only when this app holds its private key in this iPhone's Keychain, for this account and team, proven to match the certificate (and, when the listing includes the certificate itself, identical to the stored one), with at least 7 days left.
- **Other certificates:** those made elsewhere (Xcode, other sideloaders, other Macs) are counted and left alone.
- **Device:** identified by the UDID the paired iPhone reported over its verified pairing.
- **Decision:** one of the following:
  - reuse possible (only the profile needed);
  - needs new assets (the list);
  - blocked: not a Personal Team, more than one team, no device identity, this iPhone registered twice, the device list full, the test App ID twice, no App ID capacity, a duplicated certificate serial, or an earlier certificate request with an unknown outcome;
  - unknown (which listing).
- **Report:** redacted. It shows counts, booleans and days left only; no UDID, serial, bundle identifier, address or team ID.

## Approvals

- **What can be approved:** only the changes the accepted inventory requires, for its account and team: a certificate, the device, the App ID, the profile. App groups are never approvable.
- **Before sending:** each change is written to the journal (a this-device-only Keychain item, read back) **before** it is sent. A failed write refuses.
- **No retries:** after sending, whatever the outcome, that change is never sent again in this campaign. A new campaign is needed.
- **Order for the certificate:**
  1. approval checked (a refusal leaves the budget unspent);
  2. the budget consumed (listing unchanged);
  3. the journal written;
  4. sent.

## Remaining blockers before any live step

1. ~~Owner decision on which account.~~ **Resolved 19 November 2026:** the owner will use another available account that has signed before, **not** the personal Apple Account. The standing rule ("never the personal Apple Account or the `Apple Development: zagorskey@gmail.com` identity") stays in force, and A1 on the screen restates it.
2. **G2 and G4:** independent review of this branch (G4 includes this path's code). Neither is complete.
3. **G3:** provider and serial decision. The study ends 25 November.
4. **The authorisation row:** in `G5-CAMPAIGNS.md`, whose quoted authorisation says "existing account". The build check refuses an existing-account build for any other row, and the empty-account build for such a row.
5. **The owner's G5 authorisation** to build the IPA.

## Supervised procedure (after 1–5)

On the Mac:
1. `ZAG_G5_CONDITIONS="ZAG_APPLE_BRIDGE ZAG_ZSIGN_STRICT ZAG_LIVE_EXPERIMENT ZAG_EXISTING_ACCOUNT_EXPERIMENT" scripts/zag-g5-build-check.sh constants`, with the private serial. This makes the constants commit.
2. Build with `zag-g5-build-check.sh link-settings <iOS bridge library> existing-account`.
3. Scan with `test-zag-g5-experiment-binary.sh <app> G5-C<n> <host> existing-account`. Record the IPA SHA-256 in the ledger.

On the iPhone:

4. **Install and arm (E5).** Install, open Live Test, delete Zag Store, reinstall the same IPA, open Live Test again: the state must read `armed`.
5. **Pair.** Settings › Pairing must show this iPhone paired.
6. **Confirm A1–A6** on the screen.
7. **Sign in.** Enter the account and password; the 2FA code arrives by trusted device or SMS. C5 must pass first: if Apple's time is outside the window, nothing but the credential-free lookup is sent and the campaign stops.
8. **Read Installed Profiles (P3):** must read "verified".
9. **Read Account Inventory (read-only).** Read the report and the decision.
   - **Blocked or unknown:** stop. Note the decision in the ledger; nothing was changed.
   - **Certificate needed with two or more valid certificates from elsewhere:** Apple will probably refuse (free accounts are limited). Zag Store never revokes, so the owner either removes one in Xcode, outside Zag Store, then starts a new campaign; or accepts that the request will stop the campaign.
10. **Approve each listed change**, one toggle each. Approve only what you accept being created.
11. **Choose the test IPA** (`com.zagstore.livetest.hello`) and tap **Provision, Sign and Install**. Expect only the approved changes.
12. **Confirm launch.** Open the test app, then confirm on the screen ("opened" or "did not open").
13. **Export the report.** Then close the campaign in the ledger with its verdict.

Any stop rule ends the campaign. A new attempt needs a new campaign number and a new authorisation.

## Tests

- `scripts/test-zag-existing-account.sh`:
  - static checks;
  - D1–D12 (decision rules), J1–J10 (journal) and X1–X15 (end to end through the real provisioner, bridge adapter, budget and campaign over a simulated, previously used team);
  - S1 mode matching;
  - two mutants that must fail: the journal bypassed, and a preflight that writes.
- `scripts/test-zag-g5-experiment.sh`: the empty-account campaign, unchanged.
- `scripts/test-zag-g5-experiment-link.sh existing-account`: links the mode for iOS (placeholder constants, no live network) and scans it.
- The release scan: forbids this path's markers in production.
