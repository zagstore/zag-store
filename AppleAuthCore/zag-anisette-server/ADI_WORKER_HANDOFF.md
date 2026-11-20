# Real ADI worker implementation — independent review handoff

## Status and ownership
This document is a scoped implementation brief, **not** evidence that a real ADI provider exists or that another agent has started work. Keep the real provider on a separate feature branch and submit a PR against `review/zag-anisette-server`. Do not merge or deploy without explicit approval.

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
