# zag-isideload: provenance and licence evidence

Status, 18 November 2026: **a preliminary technical and licence audit, prepared for independent review.**
- It is not a legal opinion, and this licence review is **not independently completed**.
- Nothing in this crate is used by Zag Store yet.
- Live network access is compiled out (see "Network").

## Source

**Upstream.** `nab138/isideload`, commit `326e56229d0790d5d3ac9ec0f8cb1d47f8bc1bc5`, crate 0.5.2.
- Licence: MIT, "Copyright (c) 2025 nab138" (`LICENSE-isideload-MIT`).
- The upstream tree was downloaded as an archive and read as data.

**Kept.** `auth/` (Apple Account sign-in), `dev/` (developer portal), `anisette/` (remote v3 client), and `util/` (plist helpers, storage trait, callbacks).

**Removed.**
- `sideload/`: signing, installation, certificate identity and bundles. This includes `sideload/bundle.rs` and `sideload/application.rs`, which name Dadoum/Sideloader (GPL-3.0) as their reference, and `sideload/cert_identity.rs` (Impactor, MIT).
- The keyring and file storage backends.
- The device utilities.
- The wasm relay middleware.
- The `examples/` folder.
- `assets/AppleWWDRCAG3.cer`.

`upstream-changes.diff` is the complete diff from upstream to this fork, excluding the lockfile, tests and licence files.

## Changes (security)

| Upstream behaviour | In this fork |
|---|---|
| `danger_debug(true)` disables TLS certificate validation for Apple sign-in | Removed with its plumbing. Certificates are always verified, and there is no switch. |
| `tracing` logs, including anisette provisioning messages at debug level | `quiet.rs` macros keep the call sites but never evaluate or format their arguments. Nothing is logged. |
| Optional proxy and websocket relay sending every request to a third-party URL | Removed. |
| Default anisette server `ani.iloader.app`; `set_url` changes the server after creation | Removed. The caller must supply the server; it becomes that client's only allowed host. |
| `http://` anisette servers allowed (`ws://` socket) | Refused. Only https and wss. |
| Any host; redirects followed | `net_policy.rs` allows only `gsa.apple.com` and `developerservices2.apple.com` for the Apple client, and only the configured host for the anisette client. Every request is checked; no redirects, no credentials or ports in URLs. |
| Up to 10 automatic retries after HTTP 429 | No automatic retries; the caller decides. |
| Default storage: OS keyring or files | No default. The caller supplies storage (Zag Store: its this-device-only Keychain). |
| Password-derived buffers left in memory | Wiped on drop, on every path (`zeroize::Zeroizing`). The password itself is borrowed (`&str`) and never stored by this crate. |
| Network | Every request and socket is refused unless the `live-network` cargo feature is enabled. It is off by default and not enabled by Zag Store without the owner's approval. |

**Not changed.** Protocol behaviour.
- The retained sign-in, portal and anisette logic is upstream's, apart from the plumbing above.
- No protocol behaviour was added or reconstructed.

**Known residual exposure, for the G4 review.**
- The two-factor code is passed by value into an HTTP header and cannot be wiped.
- Session tokens live in ordinary heap memory in `AppleAccount` while it exists.
- The account's email is kept for the session.
- No TLS crypto provider is compiled in yet. rustls needs one installed at run time; the bridge will add `ring` (Apache-2.0 AND ISC).
- Root stores differ by connection:
  - the Apple and anisette HTTP clients use `rustls-platform-verifier`, which on iOS is the system trust store, plus Apple's root for the Apple client;
  - the anisette websocket uses the bundled `webpki-roots`.

## Licence of each retained file

Method:
- **Upstream commit authors** come from GitHub's commit history at the pinned commit.
- **Similarity** compares each file with the corresponding file in each related project. It counts:
  - shared string literals;
  - shared comments of four words or more;
  - the longest common token runs, after removing string literals and comments and normalising identifier case.

  Shared literals are mostly protocol names and parameters, which any implementation must use. Long identical token runs and copied comments suggest copied code.
- **Comparison sources:**
  - `SideStore/apple-private-apis` at `03beb1aa4299` (MPL-2.0);
  - `Dadoum/Sideloader` at `631abccace36` (GPL-3.0, written in D, so token similarity is inherently low).

| File (lines) | Upstream authors (commits) | Evidence | Status for the reviewer |
|---|---|---|---|
| `auth/apple_account.rs` (1,148) | nab138 33, BK0STAR 2, jkcoxson 1 | Against apple-private-apis `icloud-auth/src/client.rs`: 27 shared literals, 3 shared comments, longest common token runs **52, 30, 26**. Against Sideloader `appleaccount.d`: 35 shared literals, 1 shared comment (an endpoint path), longest run 14. | **Likely derived from MPL-2.0 code.** Marked MPL-2.0 pending review. |
| `auth/grandslam.rs` (261) | nab138 16 | Against `icloud-auth/src/client.rs`: longest runs **27, 12**. | **Possibly derived from MPL-2.0 code.** Marked MPL-2.0 pending review. |
| `anisette/remote_v3/state.rs` (81) | nab138 2 | Upstream comment: serialisation "borrowed from" omnisette `remote_anisette_v3.rs`. Longest run **161** tokens. | **Derived from MPL-2.0 code** (stated upstream). Marked MPL-2.0. |
| `anisette/remote_v3/mod.rs` (414) | nab138 18, JamiNeedsSleep 2, AnInteger 1, jkcoxson 1 | Against omnisette `remote_anisette_v3.rs`: 22 shared literals, longest runs **44, 24** (response type definitions). | **Possibly derived from MPL-2.0 code.** Marked MPL-2.0 pending review. |
| `dev/developer_session.rs` (187) | nab138 4 | Against Sideloader `developersession.d`: 9 shared literals, 0 shared comments, longest run 7. | Upstream README: Sideloader "was used as a reference for how apple private developer endpoints work". No sign of copied expression found by this method. Reviewer to decide. |
| `dev/app_ids.rs` (243) | nab138 6 | Same comparison: 7 literals, 0 comments, longest run 7. | As above. |
| `dev/certificates.rs` (181) | nab138 3 | Same comparison: 8 literals, 0 comments, longest run 7. | As above. |
| `dev/devices.rs` (103) | nab138 3, jkcoxson 1 | Same comparison: 5 literals, 0 comments, longest run 6. | As above. |
| `dev/app_groups.rs` (123) | nab138 3 | Same comparison: 7 literals, 0 comments, longest run 6. | As above. |
| `dev/teams.rs` (36) | nab138 2 | Same comparison: 1 literal, longest run 3. | As above. |
| `dev/device_type.rs` (29), `dev/mod.rs` (17) | nab138 | Too small to compare meaningfully. | As above. |
| `anisette/mod.rs` (200), `util/*` (235), `lib.rs` (71), `auth/builder.rs` (91) | nab138; jkcoxson 1 (`anisette/mod.rs`) | Not compared individually. Upstream code plus this fork's edits. | MIT (upstream licence). |
| `net_policy.rs`, `quiet.rs`, `tests/network_gate.rs`, and the `websocket.rs` rewrite | Zag Store | New in this fork. | MIT. |

**Removed files that cite GPL-3.0 Sideloader as their reference:**
- `sideload/bundle.rs`: 6 shared literals, 0 shared comments, longest run 6.
- `sideload/application.rs`: 1 shared literal, longest run 5.

Both handle app bundles: reading and rewriting Info.plist, and finding extensions and frameworks. No retained file imports from them. Removing them does not by itself settle whether the retained `dev/` code, which the README says used Sideloader as a reference for endpoints, owes anything to GPL-3.0. That question is listed for the reviewer.

## Dependencies

`LICENCE-INVENTORY.tsv` lists every crate in `Cargo.lock`: the licence declared on crates.io (checked 18 November 2026), and whether it is compiled for `aarch64-apple-ios`.
- **186 crates are compiled for iOS. All are permissive:** MIT and/or Apache-2.0, BSD, ISC, Zlib, Unicode-3.0, CDLA-Permissive-2.0 (root certificate data), and Unlicense OR MIT.
- **No GPL, LGPL, AGPL or MPL crate is compiled.**
- `r-efi` (MIT OR Apache-2.0 OR LGPL-2.1-or-later) is in the lockfile but not compiled for iOS.
- The upstream `apple-codesign-quick` (LGPL-2.1-or-later), `rsa` (RUSTSEC-2023-0071), `idevice`, `keyring`, `isideload-p12-keystore`, `isideload-vfs`, `zip` and `rcgen` are no longer dependencies.
- `srp` is pinned exactly to the release candidate `=0.7.0-rc.3` (RustCrypto).

## Questions for the independent reviewer

1. Are `auth/apple_account.rs`, `auth/grandslam.rs`, `anisette/remote_v3/mod.rs` and `state.rs` MPL-2.0-covered? If so, is publishing this fork's source with the MPL notices, as here, sufficient for distribution in an iOS app?
2. Does upstream's statement that Sideloader (GPL-3.0) was "a reference for how apple private developer endpoints work" create any obligation for the retained `dev/` files, given the evidence above?
3. Do upstream's MIT terms need any further notice in Zag Store's distributed app or its acknowledgements?
4. Are there contributor or provenance concerns for the files with several authors (BK0STAR, jkcoxson, JamiNeedsSleep, AnInteger)?

## Reproducing

`scripts/test-zag-isideload-fork.sh` (Zag Store repository) runs all of the following:
- the tests with and without `live-network`;
- the iOS build check;
- source checks for the removed behaviours;
- the dependency licence check against this inventory.

The similarity numbers above come from comparing the pinned upstream files with the pinned comparison sources.
