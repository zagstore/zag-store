# ADI integration decision (offline review)

Status: **interface implemented; real ADI provider NOT implemented or authorized for deployment**.

## Candidate and compatibility

Dadoum/Provision (https://github.com/Dadoum/Provision) exposes ADI provisioning functionality and an anisette server. It is written in D and its current implementation uses Apple-specific shared libraries (`libstoreservicescore.so` and `libCoreADI.so`). Its README states those Apple libraries are not redistributed for legal reasons. It is not a drop-in Rust `AdiProvider` implementation. Check repository licence files and third-party dependencies before any code reuse.

Zag's existing client (`AppleAuthCore/zag-isideload/src/anisette/remote_v3/mod.rs`) expects `/v3/client_info`, `/v3/get_headers`, and `/v3/provisioning_session`. A candidate that only generates headers is not sufficient: provisioning message semantics, per-device state, OTP generation and response formats must all match.

## Integration gate

1. Obtain a documented, legally usable provider and verify its licence and ABI/protocol compatibility. Do **not** copy third-party source into Zag without licence review.
2. Implement `AdiProvider` as an isolated adapter. Keep `DisabledAdiProvider` as the only provider used by the server listener until separate authorization.
3. Add offline conformance tests: identifier/SPIM -> CPIM; PTM/TK -> ADI blob; malformed and oversized fields; provider failure at both stages; concurrent sessions and isolation; sensitive data never logged.
4. Design persistent per-device ADI storage with restrictive permissions, explicit retention and backup policy; never expose ADI state or Apple Account credentials through logs or error responses.
5. Independently review outbound hosts, TLS validation, request timeouts and secrets handling. No Apple network calls, proprietary-library retrieval or production deployment without explicit authorization.
6. Only after these gates, test with a dedicated non-primary Apple Account and one device, then review before merging.

## Current blocker

No approved ADI runtime/provider is available in this repository. The offline Rust transport and adapter passing CI does **not** imply real anisette headers or free-account signing are functional.
