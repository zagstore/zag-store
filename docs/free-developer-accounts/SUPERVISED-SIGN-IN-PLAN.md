# Plan: one supervised sign-in with the dedicated test account

Status, 18 November 2026: **plan only.**
- Live authentication, the live portal and anisette stage 3 stay disabled.
- Each step below needs the owner's separate, explicit approval.
- It extends `LIVE-AUTH-REVIEW-PROPOSAL.md`, sections 1 to 9.

## What changes from the proposal

- **G2 has a concrete candidate:** `isideload` without its signing code. See `ISIDELOAD-EVALUATION.md`.
- **The multi-account directory is in place.** The experiment's session is filed under its own account ID and namespace (`ZagStore.accounts.live-test`), apart from the simulation.
- **The Debug-only Apple Accounts screen exists.** The live test reuses it with a live service behind a separate, Debug-only flag.

## Implementation plan (after G1 and G2)

1. **Fork and trim.**
   - Fork isideload at `326e56229d07` into the Zag Store organisation.
   - Remove `sideload`, the `install` feature and `keyring-storage`.
   - Commit the lockfile, then re-run the licence inventory: no GPL, AGPL or LGPL crates should remain.
2. **Bridge.**
   - Build a static library, `ZagAppleAuthCore`, with a C interface for exactly four operations: sign in, submit code, list teams, sign out.
   - Storage callbacks go to Swift (the Keychain), and the anisette URL comes from Swift.
   - No tracing subscriber is installed.
3. **Service.**
   - `ZagLiveAuthenticationService` implements the existing `ZagAppleAuthenticationService` protocol.
   - It is compiled only with `ZAG_LIVE_AUTH_TEST`, set solely by a separately named Debug scheme.
   - `ZagLiveAuthentication.isEnabled` stays `false` everywhere else.
4. **Controls.**
   - The `ZagTransportPolicy` host allowlist, taken from the trimmed source.
   - The 3-attempt and 15-minute limits, enforced in code.
   - A runtime kill switch that is off by default.
   - Sign-out cancels everything.
5. **Tests before any device.**
   - A mock C interface returns scripted results.
   - The existing authentication suites run against the live service's adapter.
   - Source checks cover:
     - no `danger_debug`;
     - no tracing subscriber;
     - no password reaching storage;
     - no host outside the allowlist.
   - The Release binary scan shows none of it in Release.
6. **Test build (G5).**
   - `ZagStore-LIVE-AUTH-TEST-…ipa`, stored apart from the canonical IPA, never published.
   - The owner installs it with a command they run themselves.

## Security-review checklist (G4)

**Credentials**
- [ ] The password is used once, by the sign-in call, then wiped on the Swift side. The library's own copy is documented, and patched if feasible.
- [ ] The password never reaches storage, logs, crash reports, analytics, the pasteboard or diagnostics, including in Debug builds.
- [ ] The two-factor code is used once, never persisted, never logged.
- [ ] Only the session credential is stored: Keychain, after first unlock, this device only, under its account ID. Sign-out deletes it, and a Keychain inventory verifies the deletion.

**Network**
- [ ] TLS uses the system or webpki roots, with no override. `danger_debug` is unreachable, checked by source.
- [ ] Requests go only to hosts on the allowlist; everything else fails closed. Redirects are checked.
- [ ] The anisette URL is the G3-approved provider, never the library default.

**Logging**
- [ ] No tracing subscriber; diagnostics go only through `ZagSensitiveRedactor`.
- [ ] The exported diagnostics are checked for the Apple ID, tokens, codes, device identifiers and anisette data.

**Isolation and safety**
- [ ] A live session cannot be filed under a simulated account, or the reverse.
- [ ] Rate limits and the kill switch are enforced and tested. There is no automatic retry.
- [ ] No portal-changing operation exists in the experiment build.

**Supply chain**
- [ ] The fork is pinned, the lockfile committed and the licence inventory attached.
- [ ] The release-candidate crates are pinned exactly.
- [ ] Every crate compiled has been read or has a known reputable publisher.

**Release safety**
- [ ] The Release build contains none of the live test code (binary scan).
- [ ] The canonical IPA is unchanged.

## Procedure and acceptance

These are unchanged from the proposal, sections 8 and 9:
- one sign-in;
- the owner types everything on the device;
- the team is read;
- the session is checked;
- sign-out is verified;
- the redacted diagnostics are reviewed by the owner.

Success is claimed only for what the owner observes against Apple's live service.
