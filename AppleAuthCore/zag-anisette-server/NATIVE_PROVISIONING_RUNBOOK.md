# Native ADI provisioning — end-to-end prototype and runbook

Status (21 November 2026): the complete pipeline is implemented and tested
offline. It has **not** been run against Apple. No service, listener or
production configuration uses it.

## Architecture decision

No Android runtime, emulator or JVM is involved. The only compatibility layer
is `Dadoum/android-loader` (pinned at `dfa86501`): an ELF loader that maps
`libstoreservicescore.so` / `libCoreADI.so` from the Apple Music APK into an
ordinary Linux process, with a short list of libc hooks (`main.rs`). Only those two
libraries are loaded; the other extracted APK libraries are unused. Replacing
android-loader would mean reimplementing the same loader, so it stays.

```
operator ─▶ supervisor (probe --provision-client-supervised)
              │ configuration · state-directory claim · validate · record
              ├─▶ coordinator (--client-coordinator-process, env cleared)
              │     lookup ▶ midStartProvisioning ▶ [worker Start] ▶
              │     midFinishProvisioning ▶ [worker End] ▶ persist
              │     └─▶ native worker (--native-v2-session, PDEATHSIG)
              │           one CoreADI session handle; v2 framing on pipes
              └─▶ verifier (--native-verify-state): provisioned + one OTP
```

* The Apple exchange mirrors the Zag Store v3 client (`zag-isideload`
  `remote_v3::provision`, `GrandSlam::base_headers`): the URL bag lookup carries
  no device headers; the two provisioning calls add `X-Apple-I-MD-LU` and
  `X-Mme-Device-Id`. The client sends no serial, so serial is optional here.
* CoreADI's Android identifier is the first 16 characters of the upper-cased
  device UUID, as in anisette-v3-server. A header-generating server must derive
  it identically, or the state does not match the device.
* ds_id is AuthKit's fixed `-2`.

## Stages and failure reporting

| Stage | Meaning |
| --- | --- |
| `configuration` | identity JSON, client metadata file, paths |
| `state-directory` | atomic 0700 claim of `.<name>.incomplete` |
| `lookup` | URL bag fetch and endpoint allow-list |
| `start-provisioning` | `midStartProvisioning` (Apple status `ec` checked) |
| `native-start` | CoreADI Start in the worker |
| `finish-provisioning` | `midFinishProvisioning` |
| `native-finish` | CoreADI End and worker exit |
| `persist` | adi.pb identical to the worker result, 0600, fsync; digest reported to the supervisor and rechecked by it |
| `validate` | separate process, on a private copy of exactly those bytes: provisioned and generates an OTP |
| `record` | `client-identity.json` (with `adi_pb_sha256`) written beside adi.pb |
| `publish` | no-replace atomic rename of `.<name>.incomplete` to `<name>` |
| `cancelled` / `coordinator` | operator signal / coordinator crash |

Failure output is one line, `FAIL stage=<stage> reason=<reason>`. Reasons are
fixed messages, OS errors, `Apple HTTP status N` or `Apple status error N`.
They never contain identity values, tokens, SPIM/CPIM/PTM/TK or adi.pb.
Process supervision: the coordinator and the verifier each lead their own
process group (and on Linux die with the supervisor). Exit, timeout (95 s
coordinator, 30 s verifier) or SIGINT/SIGTERM/SIGHUP kills the whole group
before it is reaped, so no descendant or inherited pipe outlives a stage.

State lifecycle: the final `<name>` appears only through the publish rename,
after verification and fsync, so it always holds a complete, verified state.
Any failure removes the attempt's `.incomplete` and `.verify` directories,
but only while they are still the directories this run created (checked by
device and inode); a directory or symlink put in their place is never
removed or followed. A supervisor killed outright (SIGKILL, power loss) can
leave `.<name>.incomplete`; it is never treated as provisioned, and it
blocks a rerun under the same name until the operator inspects and removes it.
Neither an existing `<name>` nor an existing attempt directory is reused or
overwritten.

## Client identity and metadata

How the values relate, and where each requirement comes from:
**code** means our code enforces it, **upstream** means an upstream
implementation convention, and **Apple** means verified against Apple
(nothing yet).

| Value | Derivation | Basis |
| --- | --- | --- |
| keychain identifier | 16 random bytes, made and kept by the client | code (zag-isideload `AnisetteState`) |
| `X-Mme-Device-Id` (`device_id`) | lowercase UUID text of those bytes | code |
| `X-Apple-I-MD-LU` (`local_user`) | lowercase hex SHA-256 of the 16 bytes | code (checked by `--validate-client-identity`) |
| CoreADI Android identifier | first 16 characters of the upper-cased UUID | upstream (anisette-v3-server), adopted by our code |
| `X-Mme-Client-Info` / `User-Agent` | served by the server at `/v3/client_info`; the client sends this pair on every GrandSlam request | code (zag-isideload `GrandSlam::base_headers`) |
| same pair for the whole life of one `adi.pb` | provisioning and header serving must use one pair | code (fingerprint in `client-identity.json`) |
| pair describes one client | UA's leading product names the client_info framework or process (`akd/1.0` with `(com.apple.akd/1.0)`) | upstream (every known pair) |
| pair accepted with Android CoreADI | — | **unverified**; upstream #61 reports `-80045` for the Mac pair |
| `X-Apple-I-SRL-NO` | not sent while provisioning | code (client sends none) |

### Metadata file

One private file (`ZAG_ANISETTE_CLIENT_INFO_FILE`) is the single source for
both `/v3/client_info` and provisioning (`client_info_config.rs`):

```json
{"client_info": "...", "user_agent": "...",
 "provenance": {"source": "where this pair came from", "apple_verified": false}}
```

* The file must be regular, not a symlink, owned by the operator, and owner-only.
* `client_info` must be `<model> <platform;version;build> <framework/version (process/version)>`,
  and both values must be printable ASCII header text. Placeholders fail.
* Only `client_info` and `user_agent` are ever served. Existing two-field files
  keep working for `/v3/client_info`.
* Provisioning requires `provenance`. If `apple_verified` is false, it also
  requires `--accept-unverified-metadata` for that attempt.
* `apple_verified` is the operator's statement that Apple accepted this exact
  pair. It cannot be checked offline, and no tool sets it on its own.
* Each provisioned state records `metadata_sha256` (SHA-256 of the served body)
  and its provenance. `--metadata-check-state` and the preflight flag any
  state made with another pair.

### Sources found (21 November 2026)

| Source | Status |
| --- | --- |
| Private test identity | identity only: `client_info` is blank, `serial` is blank (absent) |
| `~/zag-adi-setup/private-config/` | empty |
| Server environment and units | no `ZAG_ANISETTE_CLIENT_INFO_FILE`; no anisette service |
| App campaign constants | `anisetteURL` and serial unset (G3 placeholders) |
| Apple Music Android libraries | no client-info template; Android builds it in Java from device properties, which this host does not have |
| `tools/client-metadata-candidates.json` | `anisette-v3-server-default`, sourced from upstream code at a pinned commit; unverified |

No verified pair exists. Choosing one is the owner's decision.

## Running it

Build on the Ubuntu host (x86_64):
`cargo build --release` in `tools/native-adi-loader-probe`.

Private inputs, each a 0600 file owned by the operator:

* identity JSON: `device_id` (lowercase canonical UUID) and `local_user`
  (SHA-256 of the UUID's 16 bytes). `serial` is optional; blank fields count
  as absent. Generated by the client, never by this tool.
* client metadata JSON: see above. This is the same file the native
  server's `/v3/client_info` serves.

The state parent directory must be 0700 and owned by the operator.

```
P="tools/native-adi-provision.sh --probe <probe>"
$P --discover --identity <identity.json> --state-parent <dir> --metadata-dir <private-config>
$P --prepare-metadata --client-metadata <private-config>/client-info.json \
   --from-candidate anisette-v3-server-default      # or --from-file FILE --source TEXT
$P --preflight --runtime <runtime> --state-parent <dir> \
   --identity <identity.json> --client-metadata <private-config>/client-info.json
```

`--discover` classifies every source as verified, unverified or unusable. It
prints no identity values. `--prepare-metadata` never overwrites an existing
file. `--preflight` checks the libraries, metadata, identity and existing
states offline, then lists exactly what still blocks a live attempt. It also
confirms in a native process that an empty state reads `NOT_PROVISIONED
(-45061)` and refuses OTPs. It makes no Apple contact. `--live
--authorize-apple-contact [--accept-unverified-metadata]` runs the preflight and then exactly one supervised
provisioning run into `<dir>/adi-state-<UTC time>`.

## What is required for the first live attempt

1. **Client metadata (owner decision).** Prepare the private file from a
   chosen source. The test identity carries no pair, and none exists on the
   host. The only sourced candidate is the upstream default, which is
   unverified, so a live attempt also needs `--accept-unverified-metadata`. Upstream (Dadoum/anisette-v3-server#61) reports that since about October
   2026 GrandSlam sign-in rejects Android CoreADI headers presented with a Mac
   client identity (`-80045`). An Android client identity reportedly worked
   for one tester and returned a non-plist response for another. Provisioning
   may therefore succeed while later sign-in fails; this tool proves only the
   former.
2. **Operator authorization** for contact with `gsa.apple.com` from the
   Ubuntu host. The G2 and G3 licence questions about using Apple's Android
   libraries stay open; this tool does not resolve them.
3. A one-off 0700 state parent outside production paths.

A success prints `PASS` for provisioning, validate, record and publish, and then
`RESULT provisioned state at <dir>`. Anything else is a failure at the named
stage.
