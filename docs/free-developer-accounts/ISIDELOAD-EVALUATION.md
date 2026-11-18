# Evaluation: `nab138/isideload` as the protocol source (gate G2)

Status, 18 November 2026: **evaluation only.**
- Nothing is integrated, built into Zag Store or run.
- The sources were downloaded as data and read; no build scripts were executed.
- This document is architecture-level and describes no protocol behaviour.

## Pinned candidates

| Candidate | Pin | Licence (from the LICENSE file) | Last change |
|---|---|---|---|
| `nab138/isideload` | commit `326e56229d07` (crate 0.5.2) | MIT, "Copyright (c) 2025 nab138" | 28 Oct 2026 |
| `SideStore/apple-private-apis` (alternative) | commit `03beb1aa4299` | MPL-2.0 (root LICENSE; the crates declare no licence field) | 14 Nov 2024 |

## isideload: what it contains

5,844 lines of Rust in four areas:
- `auth`: Apple Account sign-in;
- `dev`: developer portal teams, devices, App IDs, groups and certificates;
- `anisette`: a remote v3 client;
- `sideload`: signing and installation through idevice.

`isideload` no longer depends on `apple-private-apis`. It has its own implementation.

Zag Store would use **only `auth`, `dev` and `anisette`**:
- signing stays in Zsign, with Keychain-held keys;
- installation stays in RPPairing.

## Licences, verified

**isideload itself.** MIT, and the LICENSE file matches the crate's declared licence.

**Transitive dependencies.**
- All 416 crates in `isideload`'s `Cargo.lock` were checked against crates.io.
- No GPL or AGPL crate is in the lockfile.
- 412 are permissive: MIT, Apache-2.0, BSD, ISC, Zlib, Unicode-3.0, CDLA-Permissive-2.0 or Unlicense.
- `r-efi` offers LGPL only as one of three options, so MIT can be chosen.

**Issues to resolve before any integration:**

1. **`apple-codesign-quick` 0.1.0 is LGPL-2.1-or-later and a required dependency** (published by Dadoum).
   - Statically linking LGPL code into an iOS app brings obligations: users must be able to relink the app.
   - Those obligations are hard to meet for an IPA.
   - It belongs to the signing code, which Zag Store does not need. A build without it needs either a feature flag upstream or a small fork that removes `sideload`.
2. **Provenance notes in the source.**
   - `sideload/bundle.rs` and `sideload/application.rs` say they were "made using Dadoum/Sideloader as a reference". That project is **GPL-3.0**.
   - `anisette/remote_v3/state.rs` says its serialisation was "borrowed from" `apple-private-apis/omnisette`, which is MPL-2.0. If code was copied, that file is MPL-covered. This is file-level copyleft, compatible with distribution if the file's source stays available.
   - `sideload/cert_identity.rs` borrows from Impactor (MIT).
   - The two GPL-referenced files are in `sideload`, which Zag Store would exclude. Even so, a licence reviewer should confirm that excluding them is enough.
3. **Crates published by the same author.**
   - `isideload-p12-keystore` is a fork of `p12-keystore`, at a release candidate.
   - `isideload-vfs` lists **no source repository**, so it can be reviewed only from the published crate.
   - Both are only used for signing and storage. Confirm they drop out with `sideload` excluded.

## Security assumptions observed

| Finding | Consequence for Zag Store |
|---|---|
| Storage is pluggable (a `Storage` trait). The defaults are the OS keyring, a file, or memory. | Supply Zag Store's own storage: this-device-only Keychain, under the account directory's per-account keys. Disable the `keyring-storage` default. |
| Only anisette state and signing keys are written to storage. The password is not passed to storage. | Consistent with the never-persist-passwords rule. Still to confirm in the G4 review. |
| No `zeroize` in isideload's own code: password strings are ordinary strings. | It can't match `ZagEphemeralSecret`'s wiping. Keep the password in Swift until the call, and accept or patch the library's in-memory copy. Record this at G4. |
| `danger_debug(true)` turns off TLS certificate validation for Apple sign-in. | Must never be reachable. Add a source check that the integration never calls it, and a review item. |
| Debug-level `tracing` lines print anisette provisioning messages. | Do not install a tracing subscriber in the app (without one, tracing does nothing). Add a source check. |
| Default anisette server `ani.iloader.app`; Zag Store's study measures `ani.sidestore.io`. | The anisette URL must come from Zag Store's G3 decision, never the library default. |
| Uses `rsa` 0.9 (advisory RUSTSEC-2023-0071: a timing side channel in RSA decryption). | It is used by signing-side code. Confirm it is absent, or unused for private-key operations, once `sideload` is excluded. |
| `srp` 0.7.0-rc.3 is a release candidate (RustCrypto, a reputable maintainer). | Pin it exactly. Re-check when a stable release exists. |
| No `unsafe` in isideload's own source. | Good. |

## iOS compatibility (from manifests; not yet compiled)

- **Toolchain.** Edition 2024; the local Rust 1.98 supports it.
- **TLS.** `rustls` with `ring`, and `reqwest` with rustls. These are standard on iOS, and Zag Store's RPPairing core already builds Rust for `aarch64-apple-ios`.
- **Dependencies to disable.**
  - `keyring-storage` (replaced by Zag Store's Keychain);
  - `install` (it pulls crates.io `idevice` 0.1.61 next to RPPairing's pinned fork);
  - `tokio-mt`, if a single-threaded runtime is used.
- **Bridging to Swift.** A small C interface in a separate static library, like RPPairing's, with no secrets crossing it except the password (once) and the session token (into the Keychain).
- **Not yet done.** An actual iOS build. It runs third-party build scripts, so it should happen only after this evaluation is accepted.

## Alternative: apple-private-apis

- **Licence.** MPL-2.0: file-level copyleft, usable as an unmodified dependency.
- **Maintenance.** No changes since November 2024.
- **Reproducibility.** No `Cargo.lock` is committed, so its transitive versions are not pinned.
- **Licence declarations.** Its crates declare no licence field.
- **Anisette.** The local anisette option loads Apple's Android libraries at run time. Zag Store must not use or redistribute those.
- **Verdict.** Acceptable as a reference, but a weaker dependency than isideload.

## Recommendation

1. Proceed with isideload **only as `auth` + `dev` + `anisette`**, through a fork pinned to `326e56229d07` that removes `sideload` and its dependencies. That drops the LGPL crate and the GPL-referenced files.
2. Before any code depends on it:
   - re-run this licence inventory on the fork's lockfile;
   - get a licence reviewer's opinion on the provenance notes;
   - complete the G4 code review of the remaining approximately 3,000 lines.
3. Keep apple-private-apis as the fallback.

Nothing here enables live authentication.
