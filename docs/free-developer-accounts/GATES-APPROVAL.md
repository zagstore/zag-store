# Remaining decisions before the first supervised live sign-in

Status 19 November 2026: **no gate is complete.**
- G2 and G4 need reviewers independent of the implementation. The implementation's author has not reviewed them and cannot complete them.
- Each decision is recorded separately, by the person named, in the place named.
- Nothing here enables live functionality.

| Gate | Decision | Decided by | Exact evidence required | Recorded in |
|---|---|---|---|---|
| **G1 Proposal** | Approve the supervised experiment as specified | Owner | `SUPERVISED-EXPERIMENT-SEQUENCE.md` read and accepted, with `LIVE-AUTH-GATE-RECOMMENDATIONS.md` amendments (a) and (b). One app without extensions, one dedicated account, the owner's iPhone. | Owner's written approval, quoted in `FIRST-LIVE-EXPERIMENT.md` |
| **G2 Licence** | Decisions A–D for the retained isideload sources | Independent licence reviewer | `G2-LICENCE-REVIEW.md` (#29): `scripts/zag-g2-reproduce.sh` output from the reviewer's own checkouts; the §8 checklist completed; A (4 MPL files), B (8 `dev/` files: option a–d), C (4 files with other contributors), D (`apple_root.cer`); the acknowledgements text approved | `G2-LICENCE-REVIEW.md` §9, at PR #26's reviewed head |
| **G3 Anisette** | Choose the provider (its https URL) and the device serial reported to it; pass the stage 4 privacy review; then decide on stage 3 | Owner | The study report after it ends on 25 Nov (`scripts/zag-anisette-study.sh report`); the stage 4 privacy review in `ANISETTE-STUDY.md`. The bridge refuses to run without both values. | `ANISETTE-STUDY.md` |
| **G4 Code review** | Accept the bridge, fork hardening and Keychain signing for a supervised experiment | Independent security reviewer | `G4-SECURITY-REVIEW.md` (#29): the §11 checklist (29 items) completed against the heads of #29, #26 and #28; answers to the §10 questions; findings fixed and re-reviewed; `test-zag-apple-bridge.sh`, `test-zag-isideload-fork.sh` and the release scan run by the reviewer | `G4-SECURITY-REVIEW.md` §10 |
| **G5 Test build** | Allow the experiment IPA to be built | Owner, after G1–G4 and G6 | The experiment-build plan in `SUPERVISED-EXPERIMENT-SEQUENCE.md` §1, including the flag-gated change to the four live switches (needs its own approval); then a regression run and an IPA check (the experiment IPA contains the bridge; Release does not) | `FIRST-LIVE-EXPERIMENT.md` |
| **G6 Account** | A dedicated Apple Account is ready | Owner | Account created (never the personal one); no payment method; 2FA on; recovery confirmed; details kept off every computer file | `FIRST-LIVE-EXPERIMENT.md` (a yes or no only; no account details) |

## Decisions outside G1–G6 that block or shape the experiment

| Decision | Options | Where |
|---|---|---|
| Merges: #26 (after G2), #29 and #28 | Approve each, in that order | The PRs |
| L1: orphaned Keychain items after a reinstall | (a) a guarded sweep on fresh install, (b) deterministic account IDs, (c) document a manual reset | `SIGNING-KEY-SECURITY.md` (#28) |
| L2: a failed certificate request discards a still-valid key | Swap the key in only after the certificate is issued, or accept | same |
| Anisette device state shared by accounts | Accept, or one per account | `G4-SECURITY-REVIEW.md` §10, question 3 |
| Pinning the anisette host | Pin or not | `G4-SECURITY-REVIEW.md` §10, question 2 |
| Merging #30 (documentation only) | Merge independently, or with #29 | #30 |
