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

## Source-level findings: SideStore/omnisette-server (20 November 2026)

Inspected upstream `Cargo.toml`, `src/provider_instance.rs`, and `src/provisioning_session.rs` directly. These observations are source-level, not a successful native build.

- `Cargo.toml` pulls `omnisette` from `https://github.com/SideStore/apple-private-apis.git` with `async` feature. It does not pin the dependency to a Git revision in the manifest; any adoption must pin a reviewed commit and lockfile.
- `ProviderInstance` owns `ADIProxyAnisetteProvider<StoreServicesCoreADIProxy<'static>>` and a provisioning directory. Its constructor sets the device identifier from a 16-byte identifier formatted as UUID, and derives a SHA-256 local-user UUID.
- Start calls `adi_proxy().start_provisioning(DS_ID, spim)` and returns a native `StartProvisioningData` containing `session: u32` and `cpim`.
- Finish calls `adi_proxy().end_provisioning(session, ptm, tk)` **on the existing provider instance**, then reads `adi.pb` from its provisioning directory. The WebSocket actor holds both the provider instance and native session handle until completion.
- On disconnect the actor attempts `destroy_provisioning_session(session)`. `ProviderInstance::drop` attempts to remove its per-identifier provisioning directory.
- This establishes a **blocking architectural mismatch** with Zag's separate process per Start/Finish request. Zag's current IPC has no native session handle, no durable per-session state, and no worker ownership mechanism. Do not pretend that simply forwarding `ptm`/`tk` to a new worker reproduces upstream behavior.
- Upstream creates per-identifier directories and reads/writes `adi.pb` on disk. Before using a similar design, require non-shared per-session paths, restrictive permissions, no symlink traversal, atomic lifecycle and deletion, and a clear threat model for sensitive material.
- The upstream server repository has an open issue about a missing license file (issue #16). Its `omnisette` dependency repository reports MPL-2.0, but that does **not** by itself license the wrapper's code or Apple's proprietary shared libraries.

### Architecture decision gate

**Preferred for investigation:** a single long-lived, per-session isolated worker process that owns the native provider instance from Start through Finish, with a bounded authenticated local transport and forced cleanup on timeout/disconnect. This is a design direction, **not** an approved implementation. Before implementing it, explicitly resolve its conflict with the existing one-request-one-process, framed-to-EOF worker security contract and review resource limits, process ownership, and session cancellation. A persistent service or encrypted state reconstruction are alternatives, but neither is currently verified against the native library's lifecycle.

Do not wire any native library into the existing `DisabledNativeAdiBackend` until this state-lifetime issue and license review are resolved.
