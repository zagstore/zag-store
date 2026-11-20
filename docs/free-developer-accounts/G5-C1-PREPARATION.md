# G5-C1 preparation: draft campaign and outstanding gates

Status, 20 November 2026: **draft. Nothing is authorised, and no live-enabled build exists.**

This file is not the ledger. `scripts/zag-g5-build-check.sh` reads only `G5-CAMPAIGNS.md`, where the campaign table stays empty. The draft below is a list, not a table row, on purpose: any line starting with `|` in the ledger is parsed as a row, and a numbered row that is not `authorised` counts as used. A draft `G5-C1` row there would make the real G5-C1 unbuildable.

## Builds so far

| Build | Location | SHA-256 | Live |
|---|---|---|---|
| Canonical production IPA (unchanged) | `~/Documents/ZagStore-v1.0.0-build1-iOS-AppTesters.ipa` | `67d1a79bf6826039f38113f06b6e83a2a05cc47e2ab63d561781444373eacb11` | no |
| G5-C0 existing-account diagnostic (unsigned) | `~/Documents/ZagStore-Experimental-Builds/G5-C0-existing-account-diagnostic/ZagStore-G5-C0-existing-account-diagnostic-c81f978b-unsigned.ipa` (with `README.md`) | `705c163a839699a2bf02cd283425fde0f57d991f2ad9fd52b24a63439c5e85cc` | no: placeholder constants, bridge without `live` |

## Draft G5-C1 campaign entry (not authorised)

These are the values the owner's authorised row will need. Fields marked **OWNER** are decisions the implementer must not make or invent.

- **ID / Number:** `G5-C1` / `1`. These are fixed: the ledger has no earlier campaign.
- **Authorisation (quoted):** **OWNER.** The owner's own words, in quotation marks. They must contain **"existing account"**, or the build check refuses the existing-account build (`zag-g5-constants.py`). The wording should also name the account by label and say it is not the personal account.
- **notBefore / notAfter (UTC):** **OWNER.** ISO 8601 (`YYYY-MM-DDTHH:MM:SSZ`), at most 7 days apart, and covering the day of the supervised test. Do not set them before the gates below are complete: the window starts counting at once.
- **Account label:** **OWNER.** A single letter for the existing, dedicated Apple Account that has signed apps before. Never Petar's personal Apple Account, and never an address.
- **Provider:** **OWNER, after G3.** The `https` URL of the chosen anisette provider. There is no decision yet; see G3.
- **Serial policy:** `g3Fixed` (the only one the bridge supports). The serial itself is **OWNER**: a made-up value of 1–32 ASCII letters or digits, given privately to the build check as `ZAG_G5_DEVICE_SERIAL`. It is never written in the ledger, never the iPhone's real serial or UDID, and never committed. The fork does not transmit it.
- **Branch SHA, Build nonce, IPA SHA-256:** filled by `zag-g5-build-check.sh constants` and the build; left empty in the authorised row.
- **State:** `authorised` when the owner adds the row; then `built`, `running`, `closed: <class>`.

**Ledger wording to amend (OWNER):** the ledger's introduction says each campaign names "a new dedicated account". The existing-account path (issue #37, `G5-EXISTING-ACCOUNT.md`) uses an existing dedicated account. The owner should amend that sentence when adding the row, so the record does not contradict the authorisation. The build check does not enforce this sentence.

## Outstanding gates

Each gate is approved on its own (`GATES-APPROVAL.md`). Nothing below reopens completed work.

### G2: licence (open; independent desk review started, not signed off)

**Evidence:**
- `G2-LICENCE-REVIEW.md` (provenance, MPL-2.0 obligations, the Sideloader question, §8a re-verification at `027d848e`);
- `G2-THIRD-PARTY-NOTICES-DRAFT.md` (`c81f978b`);
- `AppleAuthCore/zag-isideload/LICENCE-INVENTORY.tsv`.

**Reviewer decisions so far** (GPT-6 on PR #38, 20 November, "G2 NOT YET SIGNED OFF"):
- **A (MPL):** treat the four marked files as MPL-2.0 and keep their notices.
- **B (Sideloader):** request provenance clarification from upstream for `dev/`, keeping a GPL-3.0 attribution path as the fallback.
- **C (contributors):** keep all notices and verify upstream history.
- **D (Apple Root CA):** redistribution is an open question; verify Apple's terms or use platform trust anchors.

**Needed for approval:**
1. The upstream provenance answer for `dev/` (decision B), or the reviewer's acceptance of the GPL-3.0 fallback.
2. Apple Root CA: either verified terms or a switch to platform trust anchors (decision D).
3. The notices collected from the exact pinned versions (MIT, MPL, *ring* ISC, webpki-roots, Apache NOTICE files).
4. The §9 decision record completed by the independent reviewer, with **G2 complete: Yes**, or with a stated scope.

**Question for the reviewer and owner (not decided here):** the reviewer's distribution blocker (in-app acknowledgements) is stated for a *public* IPA. Whether G2 may be signed off for a single private, unpublished experiment build on the owner's own iPhone, with distribution conditions deferred, is the reviewer's decision to record. It must not be assumed.

### G3: anisette provider and serial (open; the study ends 25 November)

**Evidence:**
- `ANISETTE-STUDY.md`: the interim figures to day 2 (100% up, median 0.84 s, 95th percentile 3.40 s, one leaf certificate expiring 4 December) and the stage 4 desk review.

**Facts that shape the decision:**
- No published privacy policy, retention statement or operator was found for `ani.sidestore.io`. Under the proposed criteria it can only be a "community provider with a notice".
- Stage 3 (real anisette data) is impossible without contacting Apple, so compatibility is unproven until the first live sign-in. A provider failure there is a stop, not a retry.
- The provider receives the anisette identifier, the provisioning messages, `adi_pb`, the IP address and the timing. It never receives the Apple ID, the password, codes or tokens.

**Needed for approval (after 25 November):**
1. The final 7-day study report (`zag-anisette-study.sh report`) against the approval criteria.
2. The owner's provider decision: `ani.sidestore.io` as a community provider with a notice, or a self-hosted v3 server. The decision includes its `https` URL for the ledger.
3. The serial: `g3Fixed` with a made-up value, given privately.
4. Two questions for G4 to settle: whether the anisette host is pinned (§10 question 2), and whether the shared serial/provider configuration is accepted (§10 question 3).

### G4: security (open; follow-ups closed, full sign-off outstanding)

**Evidence:**
- `G4-SECURITY-REVIEW.md` (§2–§9; §11 checklist; §12–§14 remediation and summary);
- `G5-EXISTING-ACCOUNT.md`;
- PR #38 test evidence: the existing-account suite (122 checks, 3 mutants), the G5 suite (419), the Rust and iOS link checks, and the release isolation scan.

**Reviewer status** (GPT-6 on PR #38, 20 November):
- **Verified from source:** the preflight's gating; the read-only portal reader; local Keychain errors blocking; approvals bound to the account and team and journalled before sending; consumed mutations kept in the journal.
- **The three follow-ups at `3f5ae654`:** PASS (the budget followed by a journal failure, cross-campaign replay, listing completeness), "on supplied evidence".
- **Not yet done:**
  - the full portal and bridge request path;
  - the credential and 2FA lifecycle;
  - the cancellation and TOCTOU boundaries;
  - crash and reinstall semantics;
  - reproduction of the Rust and iOS builds and the tests;
  - the remaining changed files.
- **Stated residual:** whether Apple's listings are complete (pagination) cannot be shown offline.

**Needed for approval:**
1. **Scope.** The §11 checklist and §10 questions 1, 2, 4 and 5. The commit set must be extended: `G4-SECURITY-REVIEW.md` lists PRs #26, #28 and #29, while the experiment and existing-account code is on PR #38 (`experiment/g5-existing-account`). The reviewer should record the PR #38 head as reviewed.
2. **Reproduction.** The reviewer runs `scripts/test-zag-existing-account.sh`, `scripts/test-zag-g5-experiment.sh`, `scripts/test-zag-g5-experiment-link.sh` (both modes) and the Rust tests, or accepts the reported results in writing.
3. **The pagination residual.** The reviewer's decision on how it is handled. One option needs no code: before the run, the owner reads the account's certificate count read-only (Xcode › Settings › Accounts › Manage Certificates) and compares it with the inventory report, then stops if they differ.
4. **The §10 decision record** completed by the independent reviewer, with **G4 complete: Yes**.

### Also required (outside G2–G4)

- **G1:** the owner's written approval of the experiment, quoted in `FIRST-LIVE-EXPERIMENT.md`. It is recorded there as "not approved". The authorisation to *prepare* the experiment is not this approval.
- **G6:** account readiness for the existing dedicated account: not the personal account; 2FA reachable; not in the paid Developer Program. The G6 procedure in `FIRST-LIVE-EXPERIMENT.md` was written for an empty new account. For this path, its "expected: empty" step is replaced by the read-only inventory, and A1–A6 on the Live Test screen restate the rest.
- **G5:** after G1–G4 and G6, the owner's authorised ledger row (above). Then, and only then, the live build: the constants commit, the iOS bridge library with `--features live`, `link-settings … existing-account`, and the binary scan (`G5-EXISTING-ACCOUNT.md`, supervised procedure steps 1–3).

## Not done in this preparation

The live bridge was not compiled, no network access was enabled, and nothing was sent to Apple or to a provider. There was no sign-in, certificate request, device or App ID registration, or profile. `main` and the canonical IPA are unchanged, and PR #38 stays a draft.
