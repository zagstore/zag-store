# Third-party notices for the experimental Apple Account bridge

**Status: draft, 20 November 2026. NOT a complete redistributable notice bundle.**
This file is limited to the isolated `experiment/g5-existing-account` branch. It does not change the production application or certify G2 compliance.

## isideload

The retained `AppleAuthCore/zag-isideload` fork is based on [nab138/isideload](https://github.com/nab138/isideload), upstream commit `326e56229d0790d5d3ac9ec0f8cb1d47f8bc1bc5`, licensed MIT; upstream attribution: **Copyright (c) 2025 nab138**.

The fork's upstream MIT license is preserved at `AppleAuthCore/zag-isideload/LICENSE-isideload-MIT`. Changes are recorded in `AppleAuthCore/zag-isideload/upstream-changes.diff` and `AppleAuthCore/zag-isideload/PROVENANCE.md`.

## MPL-2.0-covered source

For compliance purposes, treat these retained files as Mozilla Public License 2.0 covered:

- `AppleAuthCore/zag-isideload/src/auth/apple_account.rs`
- `AppleAuthCore/zag-isideload/src/auth/grandslam.rs`
- `AppleAuthCore/zag-isideload/src/anisette/remote_v3/mod.rs`
- `AppleAuthCore/zag-isideload/src/anisette/remote_v3/state.rs`

The upstream provenance review identifies code associated with SideStore's `apple-private-apis` / omnisette / icloud-auth. Preserve their file-level notices and changes under MPL-2.0. The fork contains `LICENSE-MPL-2.0`. When distributed, recipients must be given a working source link for the exact distributed revision and the MPL-2.0 license terms.

## Rust dependencies

The fork's pinned dependency inventory is `AppleAuthCore/zag-isideload/LICENCE-INVENTORY.tsv`. The bridge additionally uses dependencies including `ring` (Apache-2.0 **AND** ISC, including upstream third-party notices), `webpki-roots` (CDLA-Permissive-2.0), and other MIT/Apache-2.0/BSD/ISC/Zlib/Unicode-3.0-licensed crates. Their applicable license texts and NOTICE files must be collected from the exact pinned versions, not reconstructed from this summary.

## Unresolved before distribution

- Confirm provenance of retained `dev/` source relative to Dadoum/Sideloader (GPL-3.0); preserve the possibility of GPL attribution pending upstream clarification.
- Confirm redistribution terms for the bundled `assets/apple_root.cer`, or use platform trust anchors if appropriate.
- Collect and reproduce all required upstream copyright, ISC and Apache NOTICE texts for the exact distributed build.
- Integrate a visible acknowledgements/source-link entry in the app and verify all distribution channels.
- Independently check exact dependency versions, upstream commits, source links and legal notices.

**This document is not permission to ship the bridge publicly.** See `docs/free-developer-accounts/G2-LICENCE-REVIEW.md` for the evidence and remaining G2 decision record.
