# Native ADI provider integration — isolated implementation branch

Status: **design and source verification only**. This branch must not enable live provisioning, add a native dynamic library to a release artifact, or merge without review.

## Confirmed boundary

The reviewed offline branch implements bounded versioned IPC, a two-phase session supervisor, a standalone Rust mock fixture, cancellation/deadline tests, and an explicitly disabled release worker. The real provider must maintain **one native provider instance and one session handle** across Start and Finish in the same supervised child. The previous one-request/one-child architecture cannot safely implement this lifecycle.

## Native source investigation

Prior source review identified SideStore/omnisette-server's `ProviderInstance` wrapping an `ADIProxyAnisetteProvider<StoreServicesCoreADIProxy<'static>>`. Its Start phase stores a native `u32` session handle; Finish consumes the same handle, and provisioning data lives in an identifier-scoped directory containing `adi.pb`. These are architecture observations, **not** a verified stable ABI or a license to distribute Apple's private frameworks.

Before implementation, pin immutable source revisions for SideStore/omnisette-server, SideStore/apple-private-apis, and the exact omnisette dependency; inspect Cargo.lock, feature flags, build scripts, target OS/architecture, dynamic loading paths, license notices and native ABI. Record verified source URLs and SHA values. Do not guess FFI symbols or create placeholder native calls in release code.

## Verified upstream source checkpoint (20 November 2026)

- `Dadoum/anisette-v3-server` main at **`684895737aaf1a1c4586fcd5b67509ffd500a36c`**; source `source/app.d`, manifest `dub.json`. The manifest pins `Dadoum/Provision` at **`7717ce1f7b3c9779fe9982005d07b6665071a239`**, and uses D dependencies `slf4d` and `vibe-d`. These exact commits are available upstream.
- This implementation is **D**, not a Rust `NativeAdiBackend` crate. Its `app.d` initializes `Device`, `ADI`, and `ProvisioningSession` from `provision`; it also downloads Android Apple Music libraries when missing. Therefore it cannot simply be linked into our Rust worker without a reviewed FFI or separate process/protocol adapter.
- The upstream source stores a device record and ADI provisioning data under configuration/runtime directories. Our existing supervisor clears the child environment and sets cwd to `/`; we must explicitly design controlled paths and avoid accidental persistent state sharing.
- An October–November 2026 upstream issue reports Apple GrandSlam rejecting Android CoreADI/device-identity mismatches; the maintainer discussed alternative Windows/macOS CoreADI implementations and **license work still pending**. This is a functional and legal blocker to assuming that a successfully compiled native backend will complete Apple sign-in.
- Upstream `anisette-v3-server` is a full network service with HTTP/WebSocket endpoints. We must **not** run it as an unrestricted sidecar or substitute its public listener for our bounded private worker IPC.
- **Decision:** keep our Rust release worker disabled. Next investigate `Dadoum/Provision` at its pinned revision for a legally usable, explicit native boundary and compare with `SideStore/apple-private-apis` under a pinned commit. No native linking until API and license review.

Sources:
- https://github.com/Dadoum/anisette-v3-server/tree/684895737aaf1a1c4586fcd5b67509ffd500a36c
- https://github.com/Dadoum/Provision/tree/7717ce1f7b3c9779fe9982005d07b6665071a239
- https://github.com/Dadoum/anisette-v3-server/issues/61

## Implementation milestones

1. Introduce a generic typed two-phase session driver with strict Start/Finish transitions, bounded frames and no mock-success logic in release code. Test with a stateful in-memory backend and failure injection.
2. Add an optional native provider module behind an **off-by-default build feature**, with a documented dependency/license gate. Disabled builds must continue to return `backend_unavailable`.
3. Native session ownership: provider instance and session handle are owned by one child; errors close the session permanently; Drop cleans up native resources and ephemeral material. No native state crosses process boundaries.
4. Supervisor launches only a pinned, trusted executable. Review descriptor-bound launch, native library loading trust, OS resource limits and platform-specific sandboxing. Current path validation and process-group cleanup are insufficient production isolation.
5. Add integration tests for missing library, native initialization failure, Start error, Finish error, replay, phase confusion, malformed/extra frames, premature EOF, crash, cancellation and timeout. Verify zero secret-bearing stdout/stderr and no persistent mock artifacts.
6. Only after independent security, licensing and functional reviews may a separate PR propose a feature-gated listener adapter. HTTP/WebSocket live provisioning remains 503 until explicit rollout approval.

## Non-goals and hard restrictions

- No production deployment, automatic merge, or live Apple provisioning.
- No undocumented guessed Apple private API bindings.
- No distribution of proprietary Apple binaries without verified rights.
- No mock CPIM or adi.pb exposed by the release executable.
- No logging device identifiers, session material, credentials or provisioning blobs.

## Acceptance criteria for this branch

- Exact native dependency provenance, licenses, target platforms and API contracts documented from source.
- Typed session lifecycle tested without native libraries, with release mode fail-closed.
- Remaining OS-specific security and integration blockers explicitly enumerated.
- CI green on Ubuntu and macOS; separate reviewed PR required before enabling native code.
