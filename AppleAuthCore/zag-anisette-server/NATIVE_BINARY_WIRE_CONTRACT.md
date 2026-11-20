# Native ADI binary wire contract — review draft

Status: **not enabled**. The release worker remains backed by `DisabledMaterialBackend`. This document defines the requirements for a future reviewed protocol revision; it does not claim native provisioning works.

## Current v1 compatibility

The current v1 JSON messages contain string fields `spim`, `cpim`, `ptm`, `tk`, and `adi_pb`. The v1 decoder checks bounds, required fields and message phase, but does **not** define a binary encoding. The test-only SideStore-shaped bridge currently uses canonical lowercase hexadecimal internally. **Do not treat that test convention as an interoperable production v1 format.** A deployed client must not silently reinterpret existing v1 strings as hex.

## Proposed v2 contract

Use an explicit `version: 2` and a named encoding field for each opaque byte payload, e.g. `spim_hex`, `cpim_hex`, `ptm_hex`, `tk_hex`, `adi_pb_hex`. Keep the message phase and expected response type checks. Accept only even-length lowercase ASCII hexadecimal, reject empty payloads, reject unknown or duplicate fields, and validate the **entire encoded JSON frame** against the 64 KiB bound before allocating decoded bytes. Enforce a smaller per-field cap that leaves room for the JSON envelope. Never log raw provisioning material.

Both ends must negotiate the same version before enabling a native backend; a v1 supervisor must reject v2 rather than interpreting it as v1. Add test vectors with NUL, non-UTF-8 bytes, maximum lengths, malformed hex, wrong phase, extra fields, duplicate JSON keys, and unexpected EOF. A transport test must prove Start -> Started -> Finish -> Finished -> EOF without deadlock.

## Native provider lifecycle

Native `start_provisioning(ds_id, spim)` yields a process-local handle and opaque CPIM bytes. Native `end_provisioning(handle, ptm, tk)` returns success/failure, **not** the persisted ADI state. Export of the provisioned state is a separate platform-specific operation requiring source review and tests. The handle must be destroyed exactly once on success and on recoverable errors. A forced process kill does not run Rust destructors; the native library must tolerate process termination without persistent corruption.

Never enable the upstream HTTP helper unchanged: its TLS certificate validation is disabled. Native Apple library sourcing, redistribution rights, platform compatibility, secure state persistence, and server-side endpoint validation remain unresolved blockers.

## Activation gate

Before release: implement and review v2 encoder/decoder in both supervisor and worker, provide a genuine licensed native backend and tested state exporter, exercise cancellation and forced-kill recovery, pass Ubuntu/macOS CI, and conduct an explicit security review. No production activation or main-branch merge is authorized by this draft.
