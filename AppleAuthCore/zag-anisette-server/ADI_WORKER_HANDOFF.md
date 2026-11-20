# Real ADI worker implementation — independent review handoff

## Status and ownership
This document is a scoped implementation brief, **not** evidence that a real ADI provider exists or that another agent has started work. Keep the real provider on a separate feature branch and submit a PR against `review/zag-anisette-server`. Do not merge or deploy without explicit approval.

## November 20 implementation checkpoint: two-phase session is now the target

**The one-shot contract below is legacy and is not sufficient for a native
provider that keeps an in-memory ADI session.** Do not implement a production
provider against independent Start and Finish subprocesses. The required
architecture is one supervised child process per provisioning session:

1. Supervisor launches one approved worker with bounded stdin/stdout, a single
   absolute deadline, cancellation, admission limits and process-group cleanup.
2. Child reads a strict framed Start request, retains its native provider
   instance and native session handle, and emits exactly one Started frame.
3. The *same child* reads strict framed Finish, consumes the retained handle,
   writes Finished, closes stdout and exits successfully.
4. Any malformed request, extra frame, premature EOF, native error, timeout,
   cancellation, child crash, or unexpected output fails closed and destroys
   the session. Never return mock CPIM or adi.pb from a release executable.

**Verified offline:** the supervisor has a standalone Rust fixture at
`tests/session_worker_fixture.rs` compiled only by tests; the supervisor
test `standalone_rust_fixture_completes_supervised_two_phase_session` passed
on Ubuntu and macOS at commit `0c8d3c82`. The release `zag-adi-worker`
still uses `DisabledNativeAdiBackend`; `--offline-session` remains
unavailable for real provisioning. Cancellation-boundary changes at
`94724a18` require their own CI confirmation.

**Implementation order for the independent native-provider branch:**

- Review and pin the exact `SideStore/apple-private-apis` and `omnisette`
  source revisions, feature flags, native dynamic-library requirements,
  license obligations, and supported OS/architectures. The native interface
  must be verified from source, not guessed.
- Define an owned `NativeAdiSession` that holds the provider and native
  session handle across both requests. Its Drop path must release native
  resources and securely dispose of ephemeral state. Native error types
  must be mapped to generic wire errors.
- Replace the test-only session response path with a generic typed session
  driver that is reusable by the disabled release backend and test backend.
  The release binary must never include a mock-success switch.
- Connect the real provider to the **supervised two-phase** path only after
  independent FFI and process-isolation review. The HTTP/WebSocket server
  stays 503 until a separate rollout approval.
- Address descriptor-bound execution / path-to-exec race, OS-level resource
  limits, and native-library loading trust before deployment.

**Unresolved security caveat:** the existing executable validation compares
canonical paths and file identity before spawn, but the subsequent
path-based exec is not race-free. Unix process groups are cleanup tools, not
a sandbox. Do not describe the current supervisor as production-secure.

---

## Existing offline contract
- `provisioning.rs`: `Session<AdiBackend<P>>`, `AdiProvider`, and the opt-in `OfflineWorkerAdiProvider`.
- `adi_worker_protocol.rs`: JSON version 1, exact request/response fields, max 65536 bytes.
- `adi_worker_framing.rs`: one four-byte big-endian length-prefixed request and exactly one response, then EOF.
- `adi_worker_lifecycle.rs`: one approved absolute canonical executable, max 10 seconds, cleared environment, cwd `/`, bounded pipes, group termination, Unix ownership and permission checks.
- HTTP and WebSocket listeners remain offline-only; live provisioning returns 503.

## Worker behavior
The standalone worker reads **exactly one** framed request on stdin and writes **exactly one** framed response on stdout, closes stdout, and exits. No banners, logging, diagnostics, or other bytes on stdout. Errors should be generic and must not contain sensitive material.

Requests:
- `{"version":1,"type":"start","identifier":"...","spim":"..."}`
- `{"version":1,"type":"finish","ptm":"...","tk":"..."}`

Responses:
- `{"version":1,"type":"started","cpim":"..."}`
- `{"version":1,"type":"finished","adi_pb":"..."}`
- `{"version":1,"type":"error","code":"backend_unavailable"}`

The provider must reject invalid shapes, unknown versions, oversized frames, malformed encodings, unexpected phase replies, trailing bytes, and multiple frames. Do not invent Apple material or return test values from production code.

## Security and operational review gates
1. Identify and document the authorized ADI implementation and its provenance, supported platforms, dependencies, licensing, and exact native interfaces. Do not assume an undocumented Apple API is available.
2. Isolate the native ADI dependency in the worker, never in the HTTP process. No network-facing worker execution or caller-selected executable path.
3. Define how any state needed between Start and Finish is persisted, authenticated, scoped to a session, bounded in lifetime, and securely erased. The existing per-request subprocess protocol **does not** itself preserve in-memory state.
4. Protect provisioning material and device identifiers: no request/response logging, crash-dump exposure, unencrypted persistent secrets, or secret-bearing error messages.
5. Review deployment path ownership and immutability, descriptor-bound launch feasibility on Linux and macOS, child process isolation, deadline enforcement, and resource limits. The current path-based pre-spawn checks are **not race-free**.
6. Add mock-native and negative tests for each phase, cross-phase confusion, state replay, process crashes, timeout, malformed/trailing frames, worker errors, and unavailable native dependency.
7. Run locked Rust build, tests and Clippy on Linux and macOS. Require independent review of native FFI and operational threat model before enabling a real worker.
8. Keep live provisioning disabled until a separate, explicit production-readiness review and rollout authorization.

## Suggested independent PR scope
First PR: worker executable skeleton with strict IPC parsing and a disabled native-provider stub; full offline tests. Second PR: reviewed native ADI integration and session-state handling. Third PR: deployment hardening and explicit feature-gated listener integration. Do not collapse these gates into a production launch.

## Existing Zag Store code and current boundary (reviewed 20 November 2026)
- `Feather/Utilities/FreeAccount/ZagAnisetteProvider.swift` defines the Swift client-side anisette header validation and remote-provider settings. It is **not** a native ADI library or implementation.
- `docs/free-developer-accounts/ANISETTE-STUDY.md` documents an availability-only study of a public remote provider. Its compatibility stage is explicitly not approved; do not treat this as native ADI validation.
- No native ADI implementation or native ABI was identified in these inspected files. Before adding FFI, locate a concrete implementation with source provenance and review its licensing and state requirements.
