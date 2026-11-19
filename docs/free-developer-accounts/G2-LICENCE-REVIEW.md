# G2: licence review package for the retained `zag-isideload` sources

Status 19 November 2026 (checklist added the same day): **prepared for an independent reviewer. Not reviewed.** The author of the fork and of this package has not reviewed it independently, and this is not a legal opinion. G2 stays open until a reviewer independent of the implementation records the decision below.

**Scope**
- `AppleAuthCore/zag-isideload` (PR #26, draft).
- Its use by Zag Store's bridge `AppleAuthCore/zag-apple-bridge` (bridge PR, draft, stacked on #26).

Not in scope: the RPPairing core, Zsign, and the rest of Zag Store, which are under the repository's GPL-3.0 `LICENSE`.

## 1. Provenance

| Item | Value |
|---|---|
| Upstream | [`nab138/isideload`](https://github.com/nab138/isideload) at `326e56229d0790d5d3ac9ec0f8cb1d47f8bc1bc5` (crate 0.5.2), MIT, "Copyright (c) 2025 nab138" |
| Kept | `auth/` (Apple Account sign-in), `dev/` (developer portal), `anisette/` (remote v3 client), `util/` |
| Removed | `sideload/` (signing, installation, bundles, certificate identity), keyring and file storage, device utilities, wasm relay, `examples/`, the bundled WWDR certificate |
| Complete record of changes | `upstream-changes.diff` (20 file sections) and the table in `PROVENANCE.md` |
| Comparison sources | [`SideStore/apple-private-apis`](https://github.com/SideStore/apple-private-apis) at `03beb1aa4299` (MPL-2.0); [`Dadoum/Sideloader`](https://github.com/Dadoum/Sideloader) at `631abccace36` (GPL-3.0, written in D) |

## 2. Reproducing the evidence

```
git clone https://github.com/nab138/isideload            u  && git -C u  checkout 326e56229d0790d5d3ac9ec0f8cb1d47f8bc1bc5
git clone https://github.com/SideStore/apple-private-apis apa && git -C apa checkout 03beb1aa4299
git clone https://github.com/Dadoum/Sideloader          sl && git -C sl checkout 631abccace36
scripts/zag-g2-reproduce.sh u apa sl
```

The script runs two checks, contacting nothing:
1. It checks each checkout's commit.
2. It confirms that the fork differs from upstream **exactly** as recorded in `upstream-changes.diff`. Only the later `.gitignore` is excluded.

It then prints the similarity evidence below, using `scripts/zag_g2_similarity.py`, which this package adds. That tool counts three things:
- **shared string literals:** distinct, more than three characters;
- **shared comments:** four or more words, compared as lower-case words;
- **the three longest common token runs:** computed after removing literals and comments and lower-casing identifiers.

**Shared literals** are mostly protocol names that any implementation must use. **Long identical token runs** and **copied comments** point to copied code.

The run below used archives of the same commits, so the commit check was not applicable. The diff check passed.

| Retained file | Compared with | Literals | Comments | Longest runs | Marked |
|---|---|---|---|---|---|
| `auth/apple_account.rs` | apple-private-apis `icloud-auth/src/client.rs` | 23 | **3** | **29, 26, 26** | MPL-2.0, pending review |
| `auth/apple_account.rs` | Sideloader `server/appleaccount.d` | 25 | 1 | 8, 8, 7 | |
| `auth/grandslam.rs` | `icloud-auth/src/client.rs` | 7 | 0 | **27**, 15, 15 | MPL-2.0, pending review |
| `anisette/remote_v3/state.rs` | omnisette `remote_anisette_v3.rs` | 4 | 0 | **160, 93**, 41 | MPL-2.0 (upstream says "borrowed from") |
| `anisette/remote_v3/mod.rs` | omnisette `remote_anisette_v3.rs` | 21 | 0 | **44, 24**, 20 | MPL-2.0, pending review |
| `dev/developer_session.rs` | Sideloader `server/developersession.d` | 9 | 0 | 7, 5, 5 | MIT (question 2) |
| `dev/app_ids.rs` | same | 7 | 0 | 4, 4, 4 | MIT (question 2) |
| `dev/certificates.rs` | same | 8 | 0 | 5, 4, 4 | MIT (question 2) |
| `dev/devices.rs` | same | 5 | 0 | 5, 4, 4 | MIT (question 2) |
| `dev/app_groups.rs` | same | 7 | 0 | 4, 3, 3 | MIT (question 2) |
| `dev/teams.rs` | same | 1 | 0 | 3, 3, 3 | MIT (question 2) |
| *removed* `sideload/bundle.rs` | Sideloader `sideload/bundle.d` | 6 | 0 | 5, 4, 4 | removed |
| *removed* `sideload/application.rs` | Sideloader `sideload/application.d` | 1 | 0 | 5, 5, 5 | removed |

**Difference from `PROVENANCE.md`.** The figures in `PROVENANCE.md` (18 Nov) came from an earlier, unrecorded run of the same method. They differ slightly in literal counts and in the longest runs: for example, `apple_account.rs` showed 27 literals and runs of 52, 30 and 26. The committed tool is now the reproducible reference. Neither run changes any file's marking.

## 3. MPL-2.0 obligations, if the reviewer confirms the four files are covered

MPL-2.0 is file-level copyleft. This list sets out what Zag Store would have to do. It is for the reviewer to confirm.
1. **Source availability (MPL 3.2(a)).** When Zag Store distributes the app (executable form), recipients must be told how to obtain the source of the covered files, at no more than the cost of distribution. The fork is in Zag Store's public repository; the app's acknowledgements would point to it.
2. **Notices (MPL 3.1, 3.4).** The covered files must keep the MPL notice. Their headers are marked, and `LICENSE-MPL-2.0` is in the crate. The upstream copyright and MIT notices must stay (`LICENSE-isideload-MIT`).
3. **Modifications.** Changes to covered files stay under MPL-2.0. The fork's changes to `apple_account.rs`, `grandslam.rs`, `remote_v3/mod.rs` and `state.rs` are recorded in `upstream-changes.diff`.
4. **Larger work (MPL 3.3).** Zag Store (GPL-3.0) may combine with MPL-2.0 files: MPL-2.0 is GPL-compatible unless marked "Incompatible With Secondary Licenses", and these are not. The bridge is Zag Store's own GPL-3.0 code and stays separate from the covered files.
5. **App distribution.** Zag Store is distributed outside the App Store, as an IPA and through AppTesters signing. No store terms add restrictions that conflict with MPL-2.0 or GPL-3.0. *(Reviewer to confirm for each channel used.)*

**Not done yet, for the release that would first include the bridge:** an acknowledgements entry in the app for isideload (MIT), apple-private-apis/omnisette (MPL-2.0, if confirmed) and the Rust dependencies (section 4).

## 4. Dependencies

`AppleAuthCore/zag-isideload/LICENCE-INVENTORY.tsv` lists every crate in the fork's lockfile, with its licence and whether it is compiled for `aarch64-apple-ios`.
- 186 crates are compiled for iOS. All are permissive.
- No GPL, LGPL, AGPL or MPL crate is compiled.

The bridge's lockfile starts from the fork's, so the reviewed versions carry over. In the bridge's default and `live` builds, it adds nine crates beyond that reviewed set (`cargo metadata --filter-platform aarch64-apple-ios`):

| Crate | Licence | Note |
|---|---|---|
| `ring` 0.17.14 | Apache-2.0 AND ISC | TLS crypto provider for rustls (live build) |
| `zlib-rs` 0.6.8 | Zlib | |
| `base16ct` 1.0.0, `serdect` 0.4.3 | Apache-2.0 OR MIT | |
| `tokio-macros` 2.7.2 | MIT | build time only (procedural macro) |
| `time-macros` 0.2.32 | MIT OR Apache-2.0 | build time only |
| `cc` 1.10.0, `find-msvc-tools` 0.1.15, `shlex` 2.0.1 | MIT OR Apache-2.0 | build time only (compiling `ring`) |

None is copyleft. `ring`'s licence includes OpenSSL-derived code under ISC terms, which require keeping the notice. That notice would go in the acknowledgements.

## 5. The unresolved Sideloader-reference concern

Upstream's README says Dadoum/Sideloader (GPL-3.0) "was used as a reference for how apple private developer endpoints work".

**What the evidence shows:**
- The retained `dev/` files share protocol literals with Sideloader's `developersession.d`: endpoint names and parameter keys.
- They share no comments.
- Their longest common token runs are 7 tokens or fewer.
- Sideloader is written in D and the fork in Rust, so token comparison understates translated structure.

**What it does not show:**
- whether the Rust code was written by translating Sideloader's D code, as opposed to learning the endpoints from it;
- whether endpoint names, parameter keys and call order are protectable expression at all.

The two removed files that cite Sideloader (`sideload/bundle.rs`, `sideload/application.rs`) are not part of the fork. Removing them does not settle the question for `dev/`.

**Options for the reviewer:**
- **(a)** treat `dev/` as MIT (functional facts learnt from a reference);
- **(b)** ask upstream (nab138) how `dev/` was written;
- **(c)** have `dev/` rewritten clean-room from public descriptions by someone who has not read Sideloader;
- **(d)** treat `dev/` as GPL-3.0-derived. Zag Store is GPL-3.0 itself, so this would not block distribution, but it would change the fork's licensing and notices.

## 6. Questions for the reviewer

1. Are the four files in section 2 marked MPL-2.0 covered by MPL-2.0? Are the obligations in section 3 complete and sufficient for each distribution channel?
2. Which option in section 5 applies to `dev/`?
3. Do the MIT and ISC notices need anything beyond an acknowledgements entry and the source in the public repository?
4. Are there contributor concerns for the files with several authors (BK0STAR, jkcoxson, JamiNeedsSleep, AnInteger)? Their commits are listed in `PROVENANCE.md`.

## 7. Files that need an independent decision

All paths are under `AppleAuthCore/zag-isideload/src/`. Every retained file is listed once.

**Decision A: MPL-2.0 coverage.** These carry an MPL-2.0 header, pending review.

| File | Lines | Why |
|---|---|---|
| `auth/apple_account.rs` | 1,157 | 3 comments shared with apple-private-apis `client.rs`; token runs of 29, 26 and 26 |
| `auth/grandslam.rs` | 270 | a token run of 27 against `client.rs` |
| `anisette/remote_v3/state.rs` | 90 | upstream says "borrowed from" omnisette; a token run of 160 |
| `anisette/remote_v3/mod.rs` | 423 | token runs of 44 and 24 against omnisette |

**Decision B: the Sideloader reference.** Option (a), (b), (c) or (d) from section 5.

| File | Lines |
|---|---|
| `dev/developer_session.rs` | 187 |
| `dev/app_ids.rs` | 243 |
| `dev/certificates.rs` | 181 |
| `dev/devices.rs` | 103 |
| `dev/app_groups.rs` | 123 |
| `dev/teams.rs` | 36 |
| `dev/device_type.rs` | 29 |
| `dev/mod.rs` | 17 |

**Decision C: contributors other than upstream's author.**

| File | Contributors |
|---|---|
| `auth/apple_account.rs` | BK0STAR (2 commits), jkcoxson (1) |
| `anisette/remote_v3/mod.rs` | JamiNeedsSleep (2), AnInteger (1), jkcoxson (1) |
| `anisette/mod.rs` | jkcoxson (1) |
| `dev/devices.rs` | jkcoxson (1) |

**Decision D: a data file.**
- `assets/apple_root.cer` is Apple's root certificate, embedded so the Apple client can verify Apple's servers.
- It is identical to upstream's file. Its SHA-256 fingerprint, `B0B1730E…01F024`, is that of Apple's published "Apple Root CA".
- It is publicly distributed by Apple. The reviewer should confirm that redistributing it in the app needs no notice.

**No decision expected.** These are upstream MIT, or Zag Store's own additions (MIT) for `net_policy.rs`, `quiet.rs` and the `websocket.rs` rewrite:
- `anisette/mod.rs`, `anisette/remote_v3/websocket.rs`
- `auth/builder.rs`, `auth/mod.rs`
- `lib.rs`, `net_policy.rs`, `quiet.rs`
- `util/callbacks.rs`, `util/mod.rs`, `util/plist.rs`, `util/storage.rs`

## 8. Reviewer checklist

**Provenance**
- [ ] The three checkouts are at the pinned commits, and `scripts/zag-g2-reproduce.sh` reports "differs from upstream exactly as recorded".
- [ ] `upstream-changes.diff` was read. No retained file adds protocol behaviour beyond upstream: the changes are hardening and removal only (`PROVENANCE.md` table).
- [ ] The removed `sideload/` files are absent, and nothing retained imports them.

**MPL-2.0 (Decision A)**
- [ ] Each of the four files is covered or not covered, and why.
- [ ] If covered: MPL notices are intact in each file header, and `LICENSE-MPL-2.0` is present.
- [ ] If covered: Zag Store's modifications to those files are recorded and stay MPL-2.0.
- [ ] If covered: source availability for executable distribution (MPL 3.2(a)) is met by the public repository, plus a pointer in the app's acknowledgements.
- [ ] The larger-work combination with GPL-3.0 Zag Store is permitted (MPL 3.3; no "Incompatible With Secondary Licenses" notice).

**Sideloader (Decision B)**
- [ ] An option is chosen for the eight `dev/` files (section 5), with reasons.
- [ ] If (b) or (c): who acts, and by when.

**Contributors (Decision C)**
- [ ] The listed contributors' commits are accepted under upstream's MIT licence, or need follow-up.

**Dependencies**
- [ ] `LICENCE-INVENTORY.tsv`: 186 crates compiled for iOS, all permissive; none GPL, LGPL, AGPL or MPL.
- [ ] `r-efi` (whose options include LGPL-2.1) is not compiled for iOS.
- [ ] The bridge's nine additional crates (section 4) are permissive.
- [ ] Notices are needed for:
  - `ring`: ISC, including OpenSSL-derived code;
  - `webpki-roots`: CDLA-Permissive-2.0;
  - the Apache-2.0 crates: NOTICE files, where present.
- [ ] `srp` is pinned to a release candidate (`=0.7.0-rc.3`). This is a provenance and maintenance question, not a licence one.

**Distribution**
- [ ] The obligations hold for each channel Zag Store uses: IPA download, AppTesters, and any source.
- [ ] The acknowledgements entry for the first release that includes the bridge is drafted, covering isideload, the MPL-covered files, Rust dependencies, `ring` and `webpki-roots`. It is **not written yet**.

## 9. Decision record (for the independent reviewer)

| Field | Entry |
|---|---|
| Reviewer (independent of the implementation) | |
| Date | |
| Commit reviewed (PR #26 head) | |
| Decisions A–D (section 7) | |
| Checklist (section 8) completed | |
| Answers to section 6 | |
| Conditions before distribution | |
| G2 complete | **No** |
