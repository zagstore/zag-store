# Supervised apple-auth machine-provisioning experiment — plan (awaiting authorization)

Prepared 2026-11-23. **Not executed. No Apple contact has occurred.** Requires
explicit per-run authorization before the single attempt is launched.

Goal: establish whether Apple's provisioning service accepts apple-auth's
**Mac-algorithm ADI** presented directly from a stock iPhone, with a fresh
machine identity — the one question the offline prototype cannot answer.

## Verified against apple-auth's own implementation

The experiment calls apple-auth's `aauth_client_provision()`, whose
implementation is `Client::Impl::provision()` in `src/client/client.cpp`.
Verified sequence (read from source, lines 449–488):

1. `GET https://gsa.apple.com/grandslam/GsService2/lookup` → plist → `urls`
   (yields `midStartProvisioning`, `midFinishProvisioning`).
2. `POST <midStartProvisioning>` with an empty `{Header:{},Request:{}}` plist →
   `Response.spim` (the Apple challenge).
3. Local crypto only: `ProvisioningSession(spim, hardware, now, ProfilePlatform::mac)`
   → `cpim = session.request()`.
4. `POST <midFinishProvisioning>` with `{Request:{cpim}}` → `Response` with
   `ptm`, `tk` (16-byte trust key), `X-Apple-I-MD-RINFO`.
5. Local crypto only: `session.finish(ptm, tk)` → profile persisted.

`iphone` platform maps to the **Mac** ADI algorithm (`client.cpp:398-399`,
`provisioning_platform()`), with the iPhone client-info preset
`<iPhone15,2> <iPhone OS;17.4;21E219> <com.apple.AuthKit/1 (com.apple.akd/1.0)>`.
Exactly these three HTTPS requests reach Apple; nothing else.

## How each of the eight requirements is met

1. **Fresh, internally consistent identity, no fabricated real-device ids.**
   `aauth_client_create(platform=IPHONE, serial_number="")`. apple-auth
   generates a fresh random `device_id` (UUID from `random_bytes(16)`),
   `local_user_hash` (SHA-256 of random), and `hardware_hash`
   (`client.cpp:304-308`). Serial is **absent**: with an empty serial the
   `X-Apple-I-SRL-NO` header is omitted entirely (`client.cpp:426`). The only
   device descriptor sent is apple-auth's shipped iPhone *class* preset
   (model/OS/build), not a unique identifier of any real unit, and not this
   device's identifiers.
2. **Request/response handling verified** against `provision()` above; we call
   the library's own code, not a reimplementation.
3. **Entirely on the iPhone.** Core + client layers compiled for iOS arm64;
   the HTTP transport is in-app `URLSession`. No Mac, Linux server, Android
   CoreADI or remote anisette provider participates at runtime. (A Mac compiled
   and installed the app; it has no runtime role.)
4. **Minimum sequence only.** The app-supplied transport callback
   (`ProvisioningHarness.swift`) pins requests to `https://*.apple.com`,
   **caps total requests at 3**, allows only GET/POST, and **blocks all
   redirects**. Any other URL, method or a 4th request aborts the attempt.
5. **No auth / 2FA / portal / certificate / device registration.** Only
   `aauth_client_provision` is called; `aauth_client_login`,
   `developer_session`, store and portal entry points are never invoked.
6. **No retries, no fallback, no background.** Single synchronous pass; the
   transport never retries; `URLSession` is ephemeral, `waitsForConnectivity =
   false`; no fallback provider exists in this path.
7. **Redaction.** Diagnostics record only method, host, HTTP status, byte
   counts, the stage reached and numeric result codes. No headers, bodies,
   identifiers, keys, `spim`/`cpim`/`ptm`/`tk` or profile bytes are logged or
   written. The result file holds the sanitized JSON only.
8. **This document** is the pre-execution statement of sequence, stopping
   conditions and expected outputs.

## Execution (one trigger, after authorization)

The signed harness is installed but inert on a normal launch (it runs only the
offline self-test). The provisioning attempt fires **only** when launched with
`ZAG_RUN_PROVISION=1`:

```
xcrun devicectl device process launch --device <DEVICE> \
  --environment-variables '{"ZAG_RUN_PROVISION":"1"}' --terminate-existing dev.zagstore.ptteamprobe
```

I will not set that variable until you authorize this specific run. The device
must be unlocked.

## Stopping conditions

- Any transport guard-rail violation (non-Apple host, non-HTTPS, >3 requests,
  redirect) → abort, report the stage.
- Any non-200 Apple HTTP response → stop at that stage, record status + code.
- Completed finish → stop (do **not** proceed to login, headers-over-network,
  portal or signing).
- One attempt only; on any failure, **no retry** — report and stop.

## Expected sanitized outputs and what each means

A JSON report like:

```json
{"library":"…","platform":"iphone","serial":"absent","requests":N,
 "request_log":["GET gsa.apple.com -> 200 (…B)","POST … -> …"],
 "stage":"lookup|start-provisioning|finish-provisioning",
 "status":<code>,"provisioned":true|false,"error":"… codes: …"}
```

- `provisioned:true`, `stage:finish-provisioning` → **Apple accepted the
  Mac-algorithm ADI from a stock iPhone.** The standalone on-device anisette
  route (Phase C) becomes the implementation plan.
- `provisioned:false`, `stage:finish-provisioning`, finish HTTP 401 / code
  −29003 → the barrier is **not** the Android runtime specifically; it is
  broader (identity/client-info class). Redirect away from "swap the ADI
  runtime"; the native-ADI −29003 is then not Android-specific.
- `stage:start-provisioning` non-200 → Apple rejected before the ADI finish;
  an anisette/client-info-shape issue, separate from the ADI-acceptance question.
- `stage:lookup` non-200 → endpoint/transport issue, no ADI conclusion.

No credential, token, device-registration or certificate resource is created or
consumed in any outcome.

## Status

Harness built and signed (apple-auth core + client for iOS arm64, URLSession
transport, env-gated). Awaiting explicit authorization to contact Apple for the
single attempt. PR #63 remains draft; ZagAuthProbe remains installed.
