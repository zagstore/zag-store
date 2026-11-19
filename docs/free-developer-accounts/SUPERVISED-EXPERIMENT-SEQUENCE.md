# The supervised live experiment: sequence, stop rules and prerequisites

Status 19 November 2026: **procedure only. Not approved; nothing built; nothing live.** Do not build or enable a live-network experiment IPA until every approval in section 1 is recorded.

**Scope**
- One simple app without extensions, frameworks or extra capabilities.
- One dedicated Apple Account.
- The owner's iPhone 15 Pro Max.
- The owner runs every step on the device and enters the password and codes there. They are never sent through chat, logs or development tools.

## 1. What is required before the first supervised live sign-in

### Approvals, each recorded separately by the owner or the named reviewer

| # | Gate | What completes it |
|---|---|---|
| 1 | **G1** | The owner approves this experiment, with amendments (a) and (b) of `LIVE-AUTH-GATE-RECOMMENDATIONS.md` |
| 2 | **G2** | An independent licence reviewer completes `G2-LICENCE-REVIEW.md` (draft PR #29), decisions A–D and §9, for PR #26 |
| 3 | **G3** | The anisette study ends (25 Nov). The owner then chooses the provider (its https URL) and passes the stage 4 privacy review. Stage 3 stays disabled until then. |
| 4 | **G4** | An independent security reviewer completes `G4-SECURITY-REVIEW.md` (draft PR #29), the §11 checklist and the §10 record, for #29, #26 and #28. Required changes are made and re-reviewed. |
| 5 | **G6** | The owner creates the dedicated Apple Account: no payment method, recovery confirmed, 2FA on, **never the personal account** |
| 6 | **G5** | The owner approves building the experiment IPA, after 1–5 |

### Engineering after the approvals (none of it done now)

1. **Merges, each with the owner's approval:**
   - PR #26 (after G2);
   - the bridge PR;
   - PR #28.
2. **The experiment build (G5).** A separately named build configuration, for example "Zag Store LIVE TEST", that alone:
   - sets `ZAG_APPLE_BRIDGE` and `ZAG_ZSIGN_STRICT`;
   - links `libzag_apple_bridge.a` built for `aarch64-apple-ios` with `--features live`. The bridge compiles for iOS today, in both its default and `live` builds; no `live` library is kept.
   - turns on `ZagLiveAuthentication`, `ZagLivePortal`, `ZagAnisetteLive` and the free-account signing gate (`ZagFreeAccountSigning`) **only under that configuration's flag**. Today all four are unconditional constants set to `false`, and this change needs the owner's approval.
   - calls `ZagIsideloadBridge.configureLive(anisetteURL:deviceSerial:)` with the G3 provider and the device serial decided with it. There is no default serial; a missing one is refused.
   - uses the Debug-only sign-in screen and its own account namespace (`ZagStore.accounts.live-test`);
   - has a different display name. It is packaged with a copy of the packager, never the original.

   The canonical IPA is not replaced. Release builds stay unchanged, and the release scan must still pass on them.
3. **Test app.** A minimal app, for example a single-view app with bundle ID `com.zagstore.livetest.hello`, with no extensions, frameworks, app groups or entitlements beyond the defaults.
4. **Before handing over the build**, run:
   - every `scripts/test-zag-*.sh` suite and the package guard;
   - a check that the experiment IPA contains the bridge and the Release IPA does not.

## 2. The sequence

Each step lists what the owner does, what is expected and when to stop. **Stop** means: cancel in the app, sign out, and report. No step is retried more than once without a new decision.

**Record for every step:**
- time;
- outcome;
- the failure kind if any (never codes, tokens, identifiers or the full address).

| # | Step | Owner's action | Expected | Stop if |
|---|---|---|---|---|
| 0 | Preconditions | Install the experiment IPA (AirDrop → Library → Install). Confirm that the pairing works and that Developer Mode is on. | App launches. The Apple Accounts screen shows "LIVE TEST". | Anything other than the expected build |
| 1 | **Dedicated Apple Account** | Have the dedicated account's details on paper, not in any file | | The personal account is about to be used |
| 2 | **Sign-in and 2FA** | Enter the address and password in the app. Enter the code from a trusted device, or request an SMS. | `awaitingTwoFactor`, then signed in | Two consecutive failures of any kind; a lock or rate-limit message; anything unexpected on the trusted device (an unfamiliar location or a request you did not start) |
| 3 | **Personal Team** | Read the team shown | One team, shown with free limits. The bridge reports its kind as `unknown`, so the free limits apply. Record how Apple described it. | Zero teams, a paid team, or several teams (the app stops rather than choose one) |
| 4 | **Certificate** | Approve "create signing certificate" | A this-device-only Keychain key is created, which Zag Store never exports. The issued certificate matches it by proof of possession. | Possession check fails; certificate limit reached |
| 5 | **Device registration** | Approve "register this iPhone" | The iPhone appears in the team's devices. Its identifier is read from the pairing and never shown or logged. | Device limit; a different device appears |
| 6 | **App ID and profile** | Approve "prepare com.zagstore.livetest.hello" | An App ID is created. The profile passes `ZagProvisioningProfileCheck`: team, bundle, this certificate, this device, expiry about 7 days. | Any check fails; an identifier is unavailable |
| 7 | **Keychain-backed signing** | Approve "sign" | Zsign `signComponents` signs through the Keychain key. Zsign's own verification passes. No key file is written. | Signing or verification fails |
| 8 | **Installation** | Approve "install" | Installed over the existing pairing. The app launches and shows its screen. | Install refused; launch fails (record the device's message) |
| 9 | **Installed-profile verification** | Open Installed Profiles (Read Only) → Read | The installed profile is VERIFIED against the one used to sign | MISMATCH or NOT VERIFIED |
| 10 | Sign-out | Sign out in the app | The session and identity Keychain items are removed. The inventory shows only expected items. | Anything left behind |
| 11 | Afterwards | Delete the test app. Reinstall the canonical IPA. | | |

## 3. What the experiment settles (the `EXPERIMENT` marks in `G4-SECURITY-REVIEW.md` §9, each of which fails closed if wrong)

1. The unit of the session expiry. Step 2 fails validation if it is wrong.
2. How Apple describes a Personal Team (step 3).
3. That a newly issued certificate is found by its request (step 4).
4. The certificate request format (step 4).
5. That anisette provisioning works with the chosen provider and device serial (step 2).

Each is recorded and changed only through a reviewed follow-up, never during the experiment.

## 4. Never during the experiment

- The personal Apple Account or the "Apple Development: zagorskey@gmail.com" identity.
- Passwords, codes or session tokens in chat, logs, screenshots or commits.
- Extensions, a second account or a second app.
- Any change to the canonical IPA, the production website, releases or update metadata.
- Anisette stage 3 before G3.
