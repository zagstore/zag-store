# Native ADI implementation candidates — desk review (2026-11-20)

This is research and a review plan, **not** authorization to download Apple's proprietary libraries, contact Apple's provisioning services, enable live provisioning, or deploy a native provider.

## Shortlist

1. **SideStore/omnisette-server** — https://github.com/SideStore/omnisette-server
   - Existing open-source Rust server wrapper with v1/v3 anisette support. Its README says it has largely been superseded by Dadoum's anisette-v3-server.
   - Documents native `libstoreservicescore.so` and `libCoreADI.so` dependencies from the Android Apple Music package. Those binaries are Apple's, not source available under the server's license.
   - Good architectural reference for the protocol and native boundary; do not copy its implementation or assume licensing compatibility without checking actual dependency licenses and source revisions.

2. **Dadoum/Provision** — https://github.com/Dadoum/Provision
   - Native provisioning project (D/C/C++ components) with `libprovision` and ADI state. The project documentation warns that `adi.pb` identifies a machine and must not be leaked.
   - A candidate for examining the native call graph and state lifecycle; introducing its toolchain and native dependencies would substantially expand our deployment and security surface.

3. **SideStore/apple-private-apis** — https://github.com/SideStore/apple-private-apis
   - Investigate the `omnisette` crate's exact native API, dependency versions, platform support, and license before selecting a Rust-facing bridge. A related fork documents MPL-2.0 licensing, but verify upstream independently.

4. **AnisetteKit** — https://github.com/mahee96/AnisetteKit
   - Swift on-device emulator-oriented project using Unicorn and Linux AArch64 libraries. Its architecture is primarily aimed at Apple platforms rather than our Ubuntu server; evaluate only as an alternative, not as a drop-in backend.

## Preferred investigation sequence

- Inspect upstream license files, build manifests, and concrete start/finish ADI interfaces at pinned revisions.
- Establish whether a native provider can run on Ubuntu 26.04 / the production CPU architecture and what macOS CI can realistically test without proprietary binaries.
- Define the ADI state persistence mechanism between our **separate** Start and Finish subprocesses. Require per-session binding, expiry, replay rejection, at-rest protection, and cleanup. The current IPC has no session token; it must not be exposed to untrusted callers as-is.
- Determine a legally authorized source and deployment policy for proprietary Apple libraries. Do **not** commit or redistribute them.
- Build a mock native backend and deterministic tests before any real dependency. Keep the network listener returning 503 until a separately reviewed production gate.

## Decision

**No native provider selected yet.** The first implementation candidate to audit is SideStore's Rust `omnisette` stack, with Dadoum/Provision as a cross-check for state handling. Selection requires actual source and license review, not README-level claims.
