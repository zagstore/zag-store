# Changelog

This file tracks public Zag Store releases.

## 1.0.0 Beta 3 (build 3): 15 November 2026

Privacy and update-integrity improvements. [Release](https://github.com/zagstore/zag-store/releases/tag/v1.0.0-beta.3)

- Added anonymous foreground usage sessions for website activity statistics, with a separate opt-out in **Settings > Privacy**. A fresh random ID is used for each session; no persistent device identifier or installed-app list is sent.
- Strengthened self-update downloads with bounded-memory streaming and package-integrity checks during import; stale prepared update state is discarded.
- Added automated tests covering usage-session reporting, self-update integrity, import integrity and update-metadata conformance.
- Updated repository/documentation links for the `zagstore` GitHub organisation.
- Incremented the Beta build number to **3**; the Beta update trust key remains `zag-v2-2026-b`.

**Unsigned IPA:** `ZagStore-1.0.0-unsigned.ipa` (must be signed with your own certificate and provisioning profile). SHA-256: `da743f30f32723ab2bb16051734caa109fd75d1fdaa292cdcb70c968d582f741`.

**Verified source commit:** [`87539ba2`](https://github.com/zagstore/zag-store/commit/87539ba2a2dc18b652e4996d3c803916e2d5f137). This is the release-candidate source; the GitHub release and signed in-app update are separate publication steps.

## 1.0.0 Beta 2 (build 2): 13 November 2026

Maintenance and update infrastructure release. [Release](https://github.com/zagstore/zag-store/releases/tag/v1.0.0-beta.2)

- Beta channel update information is signed with the new key `zag-v2-2026-b`, which replaces the retired `zag-v2-2026-a`.
- Signature, expiry and anti-rollback checks stay in place, now with the new key.
- Clearer messages when update information has expired, isn't valid yet, or is signed with a key this version doesn't trust.
- Beta 1 can't verify the new key, so it won't offer this update in the app. Install Beta 2 manually; later Betas arrive in the app.

Unsigned IPA: `ZagStore-1.0.0-unsigned.ipa`, SHA-256 `5bb93c02230a97f3b4eb2c22e4f98ba15f4c5cf71602c2035de139ed81193cd6`. Its exact source is recorded in [Source provenance](docs/SOURCE-PROVENANCE.md).

## 1.0.0 Beta 1 (build 2): 15 October 2026

- First Zag Store beta: Stable, Beta and Nightly channel selection, and manual update checks.
