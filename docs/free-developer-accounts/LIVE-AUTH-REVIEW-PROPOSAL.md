# Proposal: security and privacy review for a supervised live sign-in experiment

Status: **proposal only. Nothing here is enabled or scheduled.**
- `ZagLiveAuthentication.isEnabled`, `ZagLivePortal.isEnabled` and `ZagAnisetteLive.isEnabled` stay `false`.
- Anisette stage 3 stays unapproved.
- No step below runs until the owner approves this proposal in writing, and then each gate separately.

This document is deliberately architecture-level. It contains no description of Apple's authentication protocol, and the work it proposes does not reconstruct one.

## 1. Purpose and the one question it answers

Can Zag Store, on the owner's iPhone, sign in to the owner's **dedicated test Apple Account**? Specifically: complete two-factor authentication, list the account's personal team, and then sign out cleanly, with credentials handled as Decision 3 requires.

Success does not mean free-account signing works. Provisioning and signing are separate later experiments, each needing its own approval.

## 2. Scope

**In scope:**
- One sign-in.
- One two-factor verification, entered by the owner on the device.
- One read of the team list.
- A session check.
- Sign-out.
- At most **3 sign-in attempts in the whole experiment**, and at most 1 per 15 minutes.

**Out of scope:**
- Any developer-portal change: no devices, App IDs, certificates or profiles.
- Signing and installing.
- Any account other than the dedicated test account.
- Any automated or background retry.
- Running on any device other than the owner's.

## 3. Prerequisites (each is a gate)

| Gate | Requirement | Who |
|---|---|---|
| G1 | This proposal is approved, with any amendments. | Owner |
| G2 | **Protocol source.** The live service is implemented only from a source the owner approves: a library or specification that is licence-compatible (no AGPL; no code copied from unlicensed repositories) and independently confirmed. Nothing is reconstructed from withheld details. If no acceptable source exists, the experiment stops here. | Owner, then review |
| G3 | **Anisette.** The 7-day study ends on 25 Nov 11:54 GMT and the provider meets the agreed thresholds. The stage 4 privacy review of what the provider receives is complete. Stage 3 (authenticated use) is approved, or the owner chooses a different anisette source. | Owner |
| G4 | **Code review** of the live service before it is built into any IPA. It must show no credential persistence, no logging of secrets, the network allowlist, the rate limits and the kill switch. | Reviewer, then owner |
| G5 | **Test build.** A separate, clearly named Debug-configuration IPA, kept apart from the canonical IPA (which is not replaced). Its Settings entry is visible only in that build. | Claude prepares; owner installs |
| G6 | **Dedicated test account readiness.** It has no payment methods. Its trusted device and phone number are under the owner's control. It is not used for anything else, and recovery is possible if Apple locks it. | Owner |

## 4. Credential and data handling

**Password**
- Typed by the owner, on the device, into a secure field.
- Held only in `ZagEphemeralSecret` for the active operation, then wiped.
- Never written to disk, the Keychain, logs, crash reports, analytics or the pasteboard, including in Debug builds.
- Never shared in chat, issues, PRs or development logs. Claude never asks for it.

**Two-factor code**
- Entered by the owner on the device.
- Used once, then discarded.
- Never logged or persisted.

**Session credential**
- Only the minimum the service requires.
- Stored in the non-synchronizing, this-device-only Keychain under a key separate from the simulation's.
- Deleted on sign-out; deletion is verified.

**Anisette data**
- Used in memory for the operation only.
- Provisioning state follows the stage 4 review's decision.

**Diagnostics**
- In-memory and redacted (`ZagSensitiveRedactor`): Apple ID masked; no tokens, codes, headers or bodies; no device identifiers.
- Exported only by the owner, who reviews them before sharing.

**Analytics and first-launch reporting**
- Disabled for the experiment build, or proven to carry nothing about the experiment.

**Retention**
- After the experiment the owner signs out, and the test build is deleted from the device.
- The redacted diagnostics the owner chooses to keep are the only record.

## 5. Network controls

- `ZagTransportPolicy` allowlist: only the hosts the approved protocol source documents, plus the approved anisette provider. Every other host fails closed.
- System TLS validation only: no overrides, pinning bypasses or custom trust. An existing source check enforces this.
- 20-second request timeouts and a whole-operation deadline.
- No redirects to hosts outside the allowlist.

## 6. Safety controls

**Kill switches**
- The compile-time live flags.
- A Debug-only runtime toggle that is off by default and resets on relaunch.
- Sign-out also cancels any operation in progress.

**Rate limits**
- Enforced in code, not only in process: at most 3 attempts in total, at most 1 per 15 minutes.
- Any failure tells the user to wait, and never retries automatically.

**Abort criteria.** Stop immediately, and leave live flags off in later builds until reviewed, on any of:
- an Apple message about suspicious activity, a lock or a password reset;
- an unexpected trusted-device prompt;
- any request to a host outside the allowlist;
- any secret found in diagnostics;
- any crash during authentication.

**No portal changes.** The experiment build has no provisioning code path enabled.

## 7. Threat model (summary)

| Risk | Mitigation |
|---|---|
| Password or code leaks through logs, crash reports, the pasteboard or screenshots | Ephemeral handling, source checks, a secure field, redacted diagnostics, owner-controlled export |
| Session token stolen from the device | This-device-only Keychain, no sync, deleted on sign-out |
| Man in the middle | System TLS only, host allowlist |
| Anisette provider sees identifying data | Stage 4 review before G3; minimal data; option to choose another source |
| Account locked by Apple | Dedicated account, 3-attempt cap, abort criteria, no retries |
| Terms-of-service exposure | Dedicated account, one supervised session, no automation; the owner accepts the residual risk at G1 |
| The experiment build reaches users | Separate IPA name and location; canonical IPA untouched; never published |

## 8. Procedure (only after G1 to G6)

1. **Before the session.** Claude prepares the test build and a checklist. The owner installs it with a command the owner runs.
2. **Sign-in.** The owner opens Settings > Advanced > Experimental > Apple Account (Live Test). The owner enters the Apple ID and password on the device, then the verification code from their trusted device.
3. **Expected result.** "Signed in", the masked Apple ID, and the personal team's name and kind.
4. **Checks.** The owner runs the session check, then signs out and confirms the session is gone.
5. **Diagnostics.** The owner exports the redacted diagnostics, reviews them, and shares only those if they wish.
6. **Report.** Claude writes the result into the docs without any credential. Claude claims success only for what the owner observed.

## 9. Acceptance criteria

- Sign-in, two-factor verification, team read and sign-out all work as described in section 8.
- No secret appears in any log, diagnostic, crash report or file. This is checked on the exported diagnostics and with a Keychain inventory after sign-out.
- No request goes to a host outside the allowlist.
- No account warnings.

## 10. Decisions for the owner

1. Approve, amend or reject this proposal (G1).
2. Which protocol source, if any, is acceptable (G2).
3. Anisette: stage 3 with the studied provider, a different provider, or wait (G3).
4. Who performs the code review at G4.
5. Whether analytics are compiled out of the experiment build, or proven silent.
