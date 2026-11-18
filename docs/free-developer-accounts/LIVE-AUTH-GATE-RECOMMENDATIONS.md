# Recommendations for the live sign-in gates

These are recommendations on `LIVE-AUTH-REVIEW-PROPOSAL.md`. Nothing is enabled. This document describes no protocol behaviour.

| Gate | Recommendation |
|---|---|
| **G1 Proposal** | Approve with two amendments. (a) The experiment build must use the multi-account directory, so the session is filed under its own account ID and stays separate from the simulation. (b) The experiment includes sign-out and a Keychain inventory, so we can confirm nothing but that account's own session remains. |
| **G2 Protocol source** | See below. Choose one source, pin it by commit, and review it before any code depends on it. |
| **G3 Anisette** | Let the study finish on 25 Nov without resetting it. Decide on stage 3 from its results and the stage 4 privacy review. If the provider fails either, prefer an on-device approach whose source passes G2's criteria. |
| **G4 Code review** | A reviewer independent of the implementation, using a checklist: no credential persistence, the redactor covers every log path, the host allowlist, rate limits and the kill switch. The release-binary scan is extended to the live service's markers. |
| **G5 Test build** | A separately named Debug IPA. The canonical IPA is not replaced. Analytics are compiled out rather than "proven silent". |
| **G6 Account readiness** | Unchanged: a dedicated account, no payment method, recovery confirmed. Your personal Apple Account is never used. |

## G2: candidate sources for Apple's authentication behaviour

Criteria:
- the licence is compatible with Zag Store's distribution (no AGPL, and no code without a licence);
- the source is public, maintained and pinnable;
- it can be reviewed independently, by someone other than its implementer;
- it is used only as a reference or dependency, with nothing reconstructed from withheld details.

Licences as declared in GitHub's repository metadata on 18 Nov 2026. Confirm each against the LICENSE file before relying on it.

| Source | Declared licence | Notes |
|---|---|---|
| `SideStore/apple-private-apis` (Rust: authentication and anisette crates) | MPL-2.0 | File-level copyleft; usable as an unmodified dependency, with changes to its own files published. Last pushed Nov 2024, so it may be stale. |
| `nab138/isideload` (Rust) | MIT | Builds on a published fork of the crates above with permission. Actively maintained. Permissive. |
| `khcrysalis/Impactor` | MIT | Actively maintained. Permissive. Check what it depends on. |
| `rileytestut/AltSign`, `SideStore/AltSign` | none declared | Do not use: no licence grants no rights. |
| `Dadoum/Provision` (anisette) | not asserted | Do not use until a licence is confirmed. |
| AltStore and SideStore apps | AGPL-3.0 | Excluded by the criteria. |

**Recommendation.**
- Evaluate `isideload` (MIT) first, checking the licence of everything it pulls in.
- Keep `apple-private-apis` (MPL-2.0) as the alternative.
- Whichever you choose, it becomes a pinned dependency behind the existing `ZagAppleAuthenticationService` protocol and the transport policy. Nothing is copied into Zag Store's sources until the reviewer at G4 has read it.

Sources: [GitHub repository metadata](https://github.com/SideStore/apple-private-apis), [isideload](https://github.com/nab138/isideload), [Impactor](https://github.com/khcrysalis/Impactor), [AltSign](https://github.com/rileytestut/AltSign); secondary: [ecosyste.ms entry](https://awesome.ecosyste.ms/projects/github.com%2FSideStore%2Fapple-private-apis), [isideload README](https://docs.rs/crate/isideload/0.1.3/source/README.md).
