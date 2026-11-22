# Native anisette server

The Zag Store anisette server can now run Apple Music's CoreADI libraries
natively on Ubuntu (x86_64) for the routes the Zag Store v3 client calls.

**Not production-ready yet.** No Apple-provisioned state has been obtained:
`finishMachineProvisioning` returns HTTP 401 across public implementations
since 17 November 2026 (see `NATIVE_PROVISIONING_RUNBOOK.md`). Two things
remain unverified until a provisioned state exists:
- that real Apple-issued states produce OTPs through this path;
- that Apple accepts those OTPs at sign-in.

## Architecture

```
Zag Store client ──HTTPS──▶ reverse proxy ──▶ zag-anisette-server (127.0.0.1:18760)
   │  relays spim/cpim/ptm/tk                      │ one supervised child per request
   ▼                                               ▼
 Apple (GrandSlam)                 zag-native-adi-worker ──▶ libstoreservicescore.so / libCoreADI.so
                                   (private work dir, own process group)
```

**Contract.** The server implements the routes of `zag-isideload`'s
`remote_v3`, and answers them exactly as anisette-v3-server does:

| Route | Behaviour |
| --- | --- |
| `GET /v3/client_info` | Serves the private metadata file. Unchanged. |
| `POST /v3/get_headers` | Takes `{identifier, adi_pb[, sim, device_id, md_lu]}`. On success it returns `{"result":"Headers","X-Apple-I-MD","X-Apple-I-MD-M","X-Apple-I-MD-RINFO":"17106176"}`, otherwise `{"result":"GetHeadersError","message"}`. A state Apple never provisioned produces a message containing `-45061`, which the client turns into `IncorrectlyProvisioned` and re-provisions. The resync fields are accepted and ignored, as upstream does. |
| `GET /v3/provisioning_session` (WebSocket) | `GiveIdentifier` → `{identifier}` → `GiveStartProvisioningData` → `{spim}` → `GiveEndProvisioningData{cpim}` → `{ptm,tk}` → `ProvisioningSuccess{adi_pb}`. The failure tags are `InvalidIdentifier`, `StartProvisioningError`, `EndProvisioningError` and `Timeout`. |
| `GET /healthz` | Liveness, backend and worker counts. |
| `GET /readyz` | 200 only when the native readiness check passed and the client metadata is readable and advertises the ADI's own platform (Android). Otherwise 503 with a reason, e.g. `client_metadata_platform_mismatch`: Apple rejects desktop identities with Android CoreADI. |

**The server stores no client state.** As with every v3 server, the client
keeps its `adi.pb` and sends it with each `get_headers` request.

**The server contacts nothing.** The client relays the provisioning messages
to Apple. The systemd unit also denies all non-loopback IP traffic.

**Isolation.** The server process never loads Apple code. Each `get_headers`
request and each provisioning session runs in a fresh worker:
- The worker is the reviewed probe binary from `tools/native-adi-loader-probe`,
  installed as `zag-native-adi-worker`.
- It runs in its own private `work/<random>` directory and its own process
  group, with a cleared environment.
- On Linux it gets SIGKILL if the server dies.

Native state is therefore never shared between requests. Concurrent requests
cannot corrupt each other, and a crashed or hung worker affects only its own
request.

**Worker modes.** The server and worker exchange length-prefixed v2 wire
frames (`adi_worker_wire_v2.rs`). The worker runs in one of three modes:
- `--native-offline-check`: the readiness check. An empty state must report
  NOT_PROVISIONED and refuse an OTP.
- `--native-headers`: `ADIGetLoginCode`, then `ADIOTPRequest` for ds_id -2.
  It replies `headers`, `not_provisioned` or `native_failure`.
- `--native-v2-session`: Start and Finish in one process. The server checks
  that the reported `adi.pb` is the file CoreADI wrote.

**Supervision.** The production `Worker` in `native_backend.rs` is derived
from the test-only `SplitV2Session` prototype:
- It enforces a deadline per request (`get_headers` 15 s; provisioning
  session 120 s, which includes the client's Apple round trip).
- It detects exit without reaping (`waitid WNOWAIT`), kills the group while
  the leader is unreaped, then reaps. This kills descendants too.
- Every work directory is removed on drop.
- `ZAG_ANISETTE_MAX_NATIVE_WORKERS` (default 4, at most 16) bounds the
  concurrent workers. Excess requests get `503 {"error":"busy"}`.

**What is validated, and when:**
- **At startup:** the worker must be an approved executable (absolute,
  canonical, root-owned in a root-owned path, not group- or world-writable).
  The libraries must be regular files writable only by root. The state
  directory must be 0700 and owned by the service user. Leftover work
  directories from an interrupted run are removed; anything unexpected stops
  startup. Finally the real readiness check runs.
- **Per request:** `identifier` must be exactly 16 bytes and `adi_pb` 1 to
  16 KiB, both canonical base64. The worker uses the CoreADI Android
  identifier derived from the request's identifier (same derivation as the
  coordinator), so a state bound to another identity is rejected by CoreADI.
- **State validity** (corrupt, foreign, expired or never provisioned) is
  decided by CoreADI. It is reported as `GetHeadersError`, never as headers.

**Logging.** Nothing from a request, a worker or a state is logged. The
only output is the startup or refusal line; worker stderr is discarded.

## Deployment (Ubuntu)

**Do not install or enable on a production host without explicit approval.**
The installer only prepares the service; it starts it only with `--enable`.

Build the two binaries:
```sh
cd AppleAuthCore/zag-anisette-server && cargo build --release --locked
cd tools/native-adi-loader-probe && cargo build --release --offline
```

Install (as root, on approval):
```sh
sudo deploy/install-native-anisette.sh install \
  --server target/release/zag-anisette-server \
  --worker tools/native-adi-loader-probe/target/release/zag-native-adi-loader-probe \
  --runtime /path/to/runtime \
  --client-metadata /path/to/private/client-info.json   # add --enable to start it
```

The installer:
- creates the system account `zag-anisette` (no login, no home);
- copies both binaries and both libraries into
  `/usr/local/lib/zag-anisette/releases/<UTC time>-<worker hash>/`, root
  0755/0644;
- installs `/var/lib/zag-anisette` (0700, service user) with
  `client-info.json` (0600). An existing metadata file is never replaced;
- writes `/etc/zag-anisette/native.env`, keeping the previous one as
  `native.env.prev`;
- points `/usr/local/bin/zag-anisette-server` at the release;
- installs `deploy/zag-anisette-native.service`.

**The unit (`deploy/zag-anisette-native.service`):**
- Runs as the service user with no capabilities, `NoNewPrivileges`,
  `ProtectSystem=strict` and `ProtectHome`. The state directory is the only
  writable path.
- Uses private `/tmp` and devices, a syscall filter (`@system-service`) and
  `IPAddressDeny=any` except localhost.
- Restarts on failure with a start-rate limit. `KillMode=control-group` on
  stop.
- `MemoryDenyWriteExecute` is deliberately not set: the library loader maps
  code itself.

**Checks.** Run these after starting:
```sh
curl -s http://127.0.0.1:18760/readyz   # {"ready":true}
curl -s http://127.0.0.1:18760/healthz  # backend, client_metadata, workers
sudo deploy/install-native-anisette.sh status
```

**Rollback.** `sudo deploy/install-native-anisette.sh rollback` restores
`native.env.prev` and the previous server binary, then restarts the service
if it is running. Releases are never overwritten. To remove the service:
1. `systemctl disable --now zag-anisette-native`
2. Delete the unit, `/etc/zag-anisette` and the release directories.
3. Keep or delete `/var/lib/zag-anisette`. It holds only the metadata file
   and the transient work area.

**Recovery.** A killed server leaves at most some work directories behind.
The next start removes them before serving. A startup refusal prints one
fixed reason, and the server exits so that systemd's restart limit applies:
```sh
journalctl -u zag-anisette-native
```

## Remaining before production

1. **A valid Apple-provisioned state.** Provision through the WebSocket with
   the Zag Store client, or through the operator coordinator in
   `NATIVE_PROVISIONING_RUNBOOK.md`. Either way it needs the owner's
   authorization, and Apple's `finishMachineProvisioning` must accept it
   (currently 401).
2. **A live check:** that `get_headers` on that state yields OTPs Apple accepts
   at Apple ID sign-in, with the configured client metadata (an unverified
   macOS pair today).
3. **Licence review** of the Apple Music libraries' use (G2/G3), and the
   owner's approval to install on a host.
