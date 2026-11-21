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

## Concrete native integration decision (20 November 2026)

The release-compiled worker now has `--offline-v2-session`, a typed
`V2NativeBackend` with `start(identifier, spim)`, `finish(ptm, tk)`, and
`abort()`, and a strict binary v2 codec. Its configured backend is still
`DisabledV2Backend`. The supervised v2 IPC tests have passed on Ubuntu
and macOS; this does **not** prove native provisioning works.

The pinned SideStore source at
`SideStore/apple-private-apis@03beb1aa42991ccdad6214dee77e72282bef461f`,
`omnisette/src/store_services_core.rs`, confirms these native boundaries:

- `ADIProvisioningStart(ds_id, spim, ..., out_cpim, ..., out_session)` yields
  CPIM and a process-local session handle.
- `ADIProvisioningEnd(session, ptm, tk)` reports status, not ADI state bytes.
- `ADIProvisioningDestroy(session)` releases the native handle.
- `ADISetProvisioningPath(path)` selects a directory used for native state;
  this is a possible state-export source, **not** proof of an `adi.pb` format
  or reliable filename on every platform.
- `StoreServicesCoreADIProxy::with_custom_provisioning_path` loads Android
  `libstoreservicescore.so` through `android_loader`. A macOS or Ubuntu
  runner cannot assume this runtime is installed or legally redistributable.

**Next integrated milestone (not a mock):** obtain an authorized, compatible
native runtime and an isolated operator-controlled provisioning directory;
implement a single `V2NativeBackend` that owns its native provider and
session handle, calls the verified native Start/End/Destroy APIs, then exports
and validates the actual native-written state from that directory after End.
Do not manufacture an `adi.pb` file, infer its contents, or return success
without a real state export. Keep the worker disabled if runtime or export
is unavailable. Verify the target OS and CPU architecture before choosing
which native loader to implement.

Source: https://github.com/SideStore/apple-private-apis/blob/03beb1aa42991ccdad6214dee77e72282bef461f/omnisette/src/store_services_core.rs

## Verified operator runtime inventory (20 November 2026)

Operator confirmed on `zagstore-prod-01` (Ubuntu, `x86_64`):

| Local file (under `~/zag-adi-setup/runtime/lib/x86_64/`) | Size | SHA-256 |
|---|---:|---|
| `libCoreADI.so` | 1.6 MB | `ece4ffa6bbe4239e8f0d4714da57e62ce5e3c581d19553a83d78ac897783b905` |
| `libstoreservicescore.so` | 2.3 MB | `d8be230df34c0044758d43e33a8dabd3236b9a4258c4d48cb366911224d52f68` |

Both have ELF magic and machine code 62 (x86-64). Total local runtime size 3.9 MB. This proves **file presence and architecture only**; no dynamic loading or ADI calls have been verified. The files remain outside the repository and should not be committed.

The pinned SideStore `omnisette/Cargo.toml` specifies `android-loader` from `https://github.com/Dadoum/android-loader` branch `bigger_pages`. The pinned `omnisette/src/store_services_core.rs` uses that loader's `AndroidLibrary`, `hook_manager`, and `sysv64` APIs to load Android ELF objects and resolve native symbols. **Plain `dlopen` is not a drop-in replacement.**

Next: isolate an offline loader probe using a pinned revision of `Dadoum/android-loader`, inspect its native dependencies and hooks, and demonstrate actual symbol resolution on Ubuntu before enabling a real provider. After Start/End, confirm the native state storage format rather than assuming `adi.pb` is returned. Do not run provisioning on the public listener until verified.


## Implementation boundary selected (21 November 2026)

The isolated native loader probe now successfully loads the Apple Music Android
libraries, initializes CoreADI, and resolves its typed Start/Finish/Destroy
functions. The Rust probe also contains a supervised coordinator that can perform
Apple's GrandSlam lookup and provisioning requests, but **no successful real
provisioning exchange has been observed**.

The existing `OfflineWorkerAdiProvider` in `provisioning.rs` is **not** a
production-native provider: its `exchange` method starts a new executable for
each Start and Finish call. A native CoreADI session handle cannot survive
that boundary. Do not switch the network listener to this adapter.

### Two separate protocols: do not conflate them

1. **Remote-v3 protocol:** the iSideload client requests GrandSlam URLs and
   exchanges `identifier`, `spim`, `cpim`, `ptm`, `tk`, and `adi_pb`
   with the server over WebSocket. This requires a session-owned provider
   which preserves one native child between Start and Finish.
2. **Probe-owned coordinator:** the native probe itself performs GrandSlam
   lookup, Start/Finish HTTP requests and native Start/Finish in one bounded
   subprocess. It consumes a complete, privately configured identity on stdin
   and writes isolated ADI state. This is **not** an implementation of the
   remote-v3 WebSocket provider and cannot be plugged into the listener as-is.

### Concrete integration sequence

- Define an internal session-owned `AdiProvider` backed by one supervised
  native worker; use the existing typed v2 frame format and preserve the
  child from Start through Finish. Do not call `execute_offline_worker`
  separately for each phase.
- Keep GrandSlam HTTP ownership singular: for remote-v3 clients the client
  owns the Apple lookup and HTTP exchange, while the provider handles only
  native Start/Finish. The standalone probe coordinator remains an
  operator-only diagnostic path.
- Bind each WebSocket session to exactly one child and one client identifier;
  enforce phase order, time limits, bounded frames, cancellation, and
  cleanup. A disconnected session must never be resumed by a different client.
- Keep the listener returning 503 until native provider licensing, private
  identity provenance, and explicit live-test approval are resolved. No
  feature flag or environment variable should silently enable the provider.
- Verify success only with a fresh, nonempty, regular, private `adi.pb`
  produced by an authorized isolated real exchange; never print or commit
  the state file.

### Provenance checkpoint

The local operator's shell history shows both native libraries were extracted
from Apple's official Android Apple Music APK at `apps.mzstatic.com`.
The source is known, but extraction from an official download does **not**
establish a license to run the proprietary libraries as a separate server.
No legal authorization or production approval is inferred from this checkpoint.
