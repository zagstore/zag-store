# Offline session supervisor — implementation contract

Status: **design gate; not implemented or production approved** (2026-11-20).

## Existing protections to reuse

`adi_worker_lifecycle.rs` already validates an approved executable, clears the environment, isolates a Unix process group, bounds a **single request** to ten seconds, kills its process group and reaps its leader. Its framed-to-EOF reader deliberately rejects a second response. **It cannot supervise a two-message native ADI session unchanged.**

`session_worker.rs` now prototypes a stateful Start/Finish mock in one process, but its synchronous `BufRead::read_until` can block indefinitely. Its ten-second deadline is checked only on phase transitions; it cannot interrupt blocked I/O or a native call. Its newline JSON format is intentionally incompatible with production's length-prefixed versioned IPC. Neither component should be connected to the HTTP listener.

## Required supervisor

1. Introduce a separate opt-in supervisor API that owns one child from Start to Finish. Do **not** modify the one-shot `execute_offline_worker` contract or silently reuse its EOF assumption.
2. Before spawn, apply the **same** approved canonical executable, ownership, ancestor permissions and identity checks as the one-shot worker. Share those checks rather than duplicating diverging logic.
3. Create a new versioned **two-message** length-prefixed IPC with strict field allowlists, per-message 64KiB maximum, and explicit `Start`, `Started`, `Finish`, `Finished`, `Cancel`, and terminal `Failed` transitions. The native session handle must remain private to the worker.
4. A parent-side monotonic deadline covers the **whole** session, including both reads, writes, native calls and child exit. Use a separate I/O thread or nonblocking poll, but the supervising thread must never block waiting for an I/O thread to join after deadline.
5. On timeout, malformed output, unexpected EOF, nonzero exit, invalid transition, client disconnect, or cancellation: kill the entire isolated process group and reap the leader. The supervisor must not report success until the worker has exited zero and returned exactly the permitted terminal frame.
6. Bound simultaneous workers, session lifetime and memory; never log identifier, SPIM, PTM, TK, CPIM or adi.pb. No persistence or filesystem access in the mock. For a native backend, provision per-session private storage and ensure it is deleted after both success and failure.
7. Provide deterministic Linux/macOS tests: Start→Finish success; cancellation; idle input; hung Start; hung Finish; truncated frame; extra frame; worker exit; child descendant holding stdout open; and a session attempting to cross-talk with another.

## Unresolved before implementation

- The prototype currently uses `serde_json::Value` and a newline-delimited format, while the existing worker uses strict versioned length framing. Avoid adding a third production wire format.
- On Unix, process groups are cleanup aids, **not** a sandbox. A malicious child can escape its group; production isolation needs a separate review.
- A verified executable path is not race-free execution. Root-controlled immutable deployment or descriptor-bound execution remains necessary.
- MacOS and Linux native library availability, licensing and native state destruction have not been approved.

## Release gate

Until the supervisor has an independently validated two-phase mock integration and all CI jobs pass, keep `/v3/provisioning_session` disabled and do not enable native ADI.
