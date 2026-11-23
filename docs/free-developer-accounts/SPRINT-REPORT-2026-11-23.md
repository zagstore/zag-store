# Free-account signing sprint — consolidated report (2026-11-23)

Objective: get Zag Store as close as technically possible to signing and
installing an IPA directly on an iPhone with a **free** Apple Account — no paid
Developer membership, no desktop companion, no Android dependency — without
performing any unauthorised live Apple operation, without touching `main`, and
without bypassing required reviews.

## Outcome in one line

The full 11-stage workflow is implemented and offline-validated locally; the
only remaining gap is **live Apple acceptance**, which is held behind G4
authorisation, the G2 licensing question and the closed release feature gates.
Two scoped improvements were delivered as reviewable PRs. No part of the build
claims that Apple's live services accept the workflow.

## What was delivered (branches/PRs, none merged to main)

| Phase | Deliverable | Where | State |
|-------|-------------|-------|-------|
| 1 | Anisette provider/client-identity isolation hardening | PR #54 `claude/anisette-identity-isolation` → `feature/native-adi-provider-review` | **Ready for review** (not self-merged; awaits ChatGPT's independent review) |
| 2 | Typed, privacy-preserving provisioning diagnostics | PR #55 `claude/free-account-provisioning-diagnostics` (stacked on #54) | **Draft** |
| 3 | 11-stage workflow audit | `docs/free-developer-accounts/WORKFLOW-AUDIT.md` | This PR |
| 4 | End-to-end offline validation harness | `scripts/test-zag-free-account-e2e.sh` | This PR |
| 5 | Single live iPhone validation procedure (prepared, not performed) | `docs/free-developer-accounts/LIVE-VALIDATION-PROCEDURE.md` | This PR |
| 6 | This report | `docs/free-developer-accounts/SPRINT-REPORT-2026-11-23.md` | This PR |

## Phase 1 — anisette identity isolation (PR #54, head `8984b729`)

State is now keyed by a fingerprint of the normalised endpoint **and** the
effective `/v3/client_info` identity (captured before the storage lock, so no
network runs inside coordination). Equal identity reuses the slot; any other
difference gets a distinct deterministic slot, so old state is preserved and
recovered on revert rather than silently reused or deleted. Unmarked legacy
state is kept, not reprovisioned, and is never claimed by an arbitrary provider;
an unreadable identity marker is a hard failure, not "absent"; a failure between
the marker write and the state write cannot leave adoptable unmarked state. The
authentication classifier is unchanged.

Verification: Rust `zag-isideload` 52 pass / `zag-apple-bridge` wrappers pass;
iOS Release build SUCCEEDED; Swift regressions — signing 94, developer-account
205, portal 43, authentication 90, foundation 96, zsign-branch, apple-accounts
95, device-link — all pass; gates confirmed `#if`-closed; `main` untouched.

Explicitly **not** claimed: does not resolve HTTP 401/503 or ADI -29003.

## Phase 2 — provisioning diagnostics (PR #55, commit `45a283d5`)

`zag-isideload` attaches a typed `ProvisioningFault { stage, code }` as a report
context at each provisioning bail site; `known_adi_code()` recognises codes only
by exact substring against a fixed `KNOWN_ADI_CODES` allow-list (`[-45061,
-29003]`), so no surrounding text can leak. `zag-apple-bridge` adds
`ProvisioningDiagnostic` + `diagnose()`, reading only typed error contexts
(fault, `SideloadError` typed codes, reqwest status, `PolicyError`) and
returning `Unknown` when nothing matches. Every field is a small enum/integer;
a test asserts the serialised form contains no message text. The authentication
classifier is not modified.

Verification: `zag-isideload` 52 pass, `zag-apple-bridge` 16 pass (8 new),
`--features live` compiles, no new clippy warnings.

## Phase 3 — audit

See `WORKFLOW-AUDIT.md`. All 11 stages have real local implementations and
offline suites; no missing local integration; no stubs. The genuine gap is
live Apple acceptance.

## Phase 4 — offline e2e harness

`scripts/test-zag-free-account-e2e.sh` runs the existing per-stage suites in
workflow order against synthetic fixtures and mock/offline backends — it reuses
components and adds no parallel pipeline. Rust stages (2 anisette, 7 bridge)
PASS via the harness; the Swift stages run under the Xcode toolchain and passed
as the per-suite regression batch this session. The harness is explicit that it
cannot prove Apple's live acceptance.

## Phase 5 — live procedure

See `LIVE-VALIDATION-PROCEDURE.md`: one authorised, supervised, stop-on-first-
failure run, with a privacy-preserving evidence bundle. Prepared only — not
performed, and not runnable until G4 (and G2) preconditions hold.

## Remaining blockers (all live/authorisation, not local code)

1. **G2 licensing** — unresolved (`G2-LICENCE-REVIEW.md`); gates the anisette
   path choice.
2. **G4 authorisation** — a live run needs explicit owner approval; held by
   ChatGPT's review for the auth path (Issue #53).
3. **G3 provider** — a recommended anisette provider must meet
   `ANISETTE-STUDY.md` criteria or be explicitly chosen.
4. **Live acceptance unknown** — HTTP 401/503 and ADI -29003 remain Apple-side;
   this sprint improves isolation and diagnosis of them but does not resolve
   them.

## Boundaries honoured

`main` untouched; no release feature gate enabled; no live Apple sign-in,
provisioning, certificate issuance or install performed; no credentials
requested in chat; authentication classifier unchanged; AppTesters / BYOC /
imported-cert / Zsign / RPPairing flows unchanged; native ADI work untouched; no
new runtime dependency; no broad refactor; reviews not bypassed.
