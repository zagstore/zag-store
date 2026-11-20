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

## Pinned native interface comparison (source inspected)

**Dadoum/Provision**, commit `7717ce1f7b3c9779fe9982005d07b6665071a239`:
`lib/provision/adi.d` declares `extern(C)` function pointer types for
`ADIProvisioningStart` (returns a native session id via `uint*`),
`ADIProvisioningEnd` (takes that session id and PTM/TK buffers), and
`ADIProvisioningDestroy` (releases the session). It also resolves
obfuscated symbols dynamically from `libstoreservicescore.so` using
`AndroidLibrary`, and configures an on-disk provisioning path. These
declarations are **specific to the Android library build**; they are
not evidence of a stable, supported cross-platform Apple ABI.

**SideStore/apple-private-apis**, master commit
`03beb1aa42991ccdad6214dee77e72282bef461f`, is a separate Rust
source candidate whose repository declares MPL-2.0. Its code and native
dependency chain still require a detailed API/license audit. An MPL-2.0
source license does not license Apple's proprietary runtime libraries.

**Integration choice:** retain the Rust worker and its typed Start/Finish
boundary. Do not port Android D function pointers directly into Rust or
assume they work on macOS. Evaluate the SideStore Rust implementation's
native loader and session lifetime first, while keeping the Dadoum
implementation as a compatibility reference. Any implementation must
preserve the same native session handle and provider instance in one child.

References:
- https://github.com/Dadoum/Provision/blob/7717ce1f7b3c9779fe9982005d07b6665071a239/lib/provision/adi.d
- https://github.com/Dadoum/Provision/blob/7717ce1f7b3c9779fe9982005d07b6665071a239/docs/ADI.md
- https://github.com/SideStore/apple-private-apis/tree/03beb1aa42991ccdad6214dee77e72282bef461f

## Zag Store differentiated architecture proposal (review gate)

**Goal:** build a provider-agnostic, isolated ADI subsystem rather than cloning
another project's HTTP service. These are proposed design improvements, not
claims of measured superiority.

### Provider contract and isolation

- Keep the network-facing HTTP/WebSocket layer separate from the worker and
  native libraries. The public layer never accepts worker executable paths,
  library paths, or native session handles.
- Use a typed `AdiEngine` interface with explicit `start`, `finish`, and
  `abort` semantics. A provider is selected from an operator-approved,
  version-pinned allowlist; never from client input. Native handles stay inside
  one supervised child.
- Define a strict `SessionId` internal identifier and a monotonic state
  machine: `Created -> Starting -> AwaitingFinish -> Finishing -> Completed`,
  with terminal `Aborted` on errors or cancellation. Enforce one Finish,
  no replay, and one response per phase.
- Treat provisioning blobs as secrets: bound sizes, never log contents, avoid
  persistence by default, clear buffers where practical, and document limits
  on memory erasure across FFI boundaries.
- Preserve offline fail-closed builds and a kill switch. No mock-success mode
  in release binaries.

### Hardening beyond the current prototype

- Authenticate and scope any local IPC transport; the current supervisor's
  anonymous stdin/stdout is only appropriate for a directly launched child.
- Review Linux and macOS separately for descriptor-bound executable launch,
  filesystem and native-library integrity, sandbox profiles, process limits,
  seccomp where applicable, and crash-dump restrictions. A process group alone
  is not sandboxing.
- Apply per-session deadlines and bounded global concurrency, with a
  per-identifier admission policy and explicit cancellation at every phase.
  Never assume that an asynchronous cancellation can interrupt a blocking
  native call without terminating its process.
- Maintain structured **non-sensitive** telemetry: phase, duration bucket,
  generic error category, provider revision, and count of aborted sessions.
  No identifiers, SPIM/PTM/TK, CPIM, adi.pb, or native stack traces.
- Add deterministic failure-injection tests for crash, timeout, malformed
  output, duplicate Finish, provider mismatch, and worker replacement; compare
  behavior on both supported operating systems.

### Proposed acceptance metrics

1. No successful response from the disabled provider, including malformed
   and replayed requests.
2. One provider instance per session; no native handle crosses process
   boundaries; all terminal paths clean up the child.
3. Bounded memory, time, message size, and active sessions under adversarial
   tests, with OS-specific enforcement documented.
4. Reproducible dependency revisions and explicit review of upstream and
   proprietary library licensing.
5. Successful real-provider integration tests **only** in a separately
   approved isolated environment; production remains disabled until reviewed.

## Cancellation and native-handle lifetime contract

The supervisor may cancel or time out a session by terminating the isolated
worker process. A process kill is **not** a guarantee that a native library's
`destroy_provisioning_session` callback ran; RAII cleanup runs only during
ordinary Rust stack unwinding / returns, not SIGKILL or process abort.

The worker must own each native session handle exclusively, call the matching
native destroy operation on normal completion and recoverable errors, and
never transmit the handle over IPC. Explicit destruction must be idempotent,
and a failed destroy must not be retried blindly against an invalid handle.
The supervisor must retain a hard deadline and kill/reap fallback for blocked
or unresponsive native calls. Do not run the native operation on an unbounded
background thread that could outlive the worker's request.

Acceptance tests must cover ordinary success, Start failure, Finish failure,
protocol rejection, disconnect, deadline expiry, and forced worker death.
For forced death, assert that the child is reaped and no session remains
available through the IPC boundary; **do not** assert that native cleanup
executed. Native library resources must be OS-process-scoped, or provider
documentation must explicitly establish safe recovery after forced death.

The current `NativeSessionHandle` guard is test-only until a real provider
uses it. The release worker still fails closed with its disabled backend.

## SideStore Rust source audit: transport-security blocker

At pinned `SideStore/apple-private-apis` revision
`03beb1aa42991ccdad6214dee77e72282bef461f`,
`omnisette/src/adi_proxy.rs` defines the `ADIProxy` trait with native
`start_provisioning`, `end_provisioning`, and
`destroy_provisioning_session` methods, including a `u32` native session
handle. This confirms that its provider-facing interface can inform our
worker's typed two-phase design.

**Do not import its HTTP provisioning client unchanged.** The same file's
`make_http_client` calls
`ClientBuilder::danger_accept_invalid_certs(true)` and even carries a
TODO to pin Apple's certificate. That disables TLS certificate validation.
It also takes start/finish provisioning URLs from a remote response without
an evident local origin allowlist in the inspected function. Its plist
response parsing includes several `unwrap()` calls on network-derived
values, risking panics on malformed responses.

**Zag Store acceptance gates:** default TLS verification must stay enabled;
validate any discovered endpoint's scheme and approved host before requests;
parse untrusted plist data without panic; limit response body size and
request duration; prohibit sensitive header logging; and keep the network
client outside the native worker unless explicitly justified by the threat
model. Validate these controls with negative tests before enabling live
provisioning. This is a source-level finding, not a claim that an upstream
deployment has been exploited.

The `omnisette/Cargo.toml` also depends on Dadoum's `android-loader`
from the floating `bigger_pages` branch; any reused code requires
immutable dependency pinning and platform-specific loader review.

Sources:
- https://github.com/SideStore/apple-private-apis/blob/03beb1aa42991ccdad6214dee77e72282bef461f/omnisette/src/adi_proxy.rs
- https://github.com/SideStore/apple-private-apis/blob/03beb1aa42991ccdad6214dee77e72282bef461f/omnisette/Cargo.toml

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
