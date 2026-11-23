# Windows CoreADI backend (experimental)

The server can run Apple's Windows `CoreADI64.dll` from iTunes for Windows
instead of the Apple Music for Android libraries. Select it with
`ZAG_ANISETTE_NATIVE_PLATFORM=windows`. The DLL runs natively on Linux
x86_64 in a supervised worker, without Wine (`tools/windows-coreadi-probe`).

**Status:** offline prototype. No Apple contact has been made, and no
Apple-provisioned Windows state exists. Do not install it on a host or
deploy it publicly: see [Licence](#licence) and the
[live-testing gate](#before-one-authorized-live-attempt).

## 1. Windows client identity (offline provenance)

Apple compares the client identity with the ADI that produced the
anisette. A Windows ADI therefore needs the identity of a genuine Windows
client: iTunes' AuthKitWin. Every value below was read offline from the
Apple-signed installer. Nothing was taken from third-party projects or
guessed.

**Source:**
- `iTunes64Setup.exe`, one anonymous download from Apple's CDN (sha256
  `221a2420…29db4d`).
- It contains `iTunes64.msi`: ProductVersion **12.13.12.3**, Manufacturer
  Apple Inc.
- From the MSI: `iTunes.exe`, `CoreFoundation.dll` and `CFNetwork.dll`
  (FileVersion 520.53.30.8).
- `CoreADI64.dll` (sha256 `c83a2b4a…1995ad`) is signed by Apple Inc.
  through a DigiCert code-signing chain. The Authenticode digest was not
  re-verified.

**Template.** `iTunes.exe` statically links AuthKitWin (`authkitwin-185.6`).
Its `CopyClientInfo` (VA `0x14176eb00`) builds the header with
```
CFStringCreateWithFormat("<PC> <%@> <com.apple.AuthKitWin/%d (%@/%@)>", os, ver, clientID, clientVersion)
```

| Field | Value | Provenance |
| --- | --- | --- |
| hardware | `PC` | Literal in the format string (VA `0x14176eb00`). |
| `os` | `Windows;10.0(0,0);<build>` | Built at VA `0x14176c2b0` as `"%@;%@;%@"` from CoreFoundation's `_CFCopySystemVersionDictionary`. CoreFoundation.dll (from `0x1800e6a98`) calls `GetVersionExA` and sets ProductName `Windows`, ProductVersion `"%ld.%ld(%ld,%ld)"` (major, minor, service-pack major, minor) and BuildVersion `"%ld"` (dwBuildNumber). The iTunes.exe manifest declares Windows 10/11 support (`{8e0f7a12-…}`), so `GetVersionExA` reports the real 10.0. |
| `<build>` | **operator choice** | The emulated host's Windows build number. It must be a real Microsoft build, for example 19045 (Windows 10 22H2) or 22631 (Windows 11 23H2). The binaries cannot tell which one to use. |
| `ver` | `1`, or `2` | `2` only when the options dictionary contains the key `pbe`, otherwise `1`. **Unresolved:** which one applies on the provisioning and sign-in path. |
| `clientID` | `com.apple.iTunes` | Taken from `options["AKClientID"]`, with default `com.apple.iCloud`. iTunes passes the CFSTR at `0x141fb23e0` (set at `0x1401cbf10`). |
| `clientVersion` | `12.13.12` | Taken from `options["AKClientVersion"]`, with default `1`. iTunes passes `12.13.12` (at `0x1404d5d50` and `0x1408a6343`). |

Candidate `client_info`:
```
<PC> <Windows;10.0(0,0);BUILD> <com.apple.AuthKitWin/1 (com.apple.iTunes/12.13.12)>
```

**User-Agent: unresolved offline.** AuthKitWin's request builder (VA
`0x14176e210`) sets only `X-Mme-Client-Info`, `X-Mme-Country`,
`Accept-Language` and the anisette headers; it sets no User-Agent. Neither
CFNetwork.dll, iTunes.exe nor CoreFoundation.dll contains a default
User-Agent template. The real value is whatever CFNetwork sends at run
time, which can only be observed from a real iTunes for Windows session.
**Do not invent it.**

The server's readiness requires the served metadata to have platform
`Windows`, a `client_info` starting with `<PC> <Windows;` and the AuthKitWin
framework. It cannot verify that Apple accepts the pair:
`client_metadata_apple_verified` stays false in `/healthz`.

## 2. Worker integration

The server, the v3 API, the bounded concurrency, the deadlines, the worker
isolation and the private work directories are unchanged
(`NATIVE_SERVER.md`). Only the worker and its runtime differ.

| | Android (default) | Windows |
| --- | --- | --- |
| `ZAG_ANISETTE_NATIVE_PLATFORM` | unset or `android` | `windows` |
| Runtime | `lib/x86_64/libstoreservicescore.so`, `libCoreADI.so` | `CoreADI64.dll` at the top of the runtime directory |
| Worker | `tools/native-adi-loader-probe` | `tools/windows-coreadi-probe` |
| Worker identity argument | CoreADI Android identifier | Client identifier as 32 lower-case hex digits |
| Readiness metadata | `Android` platform | `Windows` platform and the AuthKitWin identity |
| `adi_pb` | CoreADI's `adi.pb` | The state container (below) |

A configuration cannot mix the two platforms:
- An Android runtime layout refuses to start a Windows backend, and the
  reverse.
- Metadata for the other platform makes `/readyz` report
  `client_metadata_platform_mismatch`.

The tests cover both (`platforms_are_configured_separately_and_never_mixed`,
`readiness_needs_an_identity_of_the_configured_adi`).

**Worker modes** (`src/worker.rs`) follow the server's contract:
`<worker> <runtime> <mode> <work dir> <identifier hex>`.
- `--native-offline-check`: an empty machine must report NOT_PROVISIONED
  (-45061) and refuse an OTP.
- `--native-headers`: unpacks `<work dir>/adi.pb`, then runs
  IsMachineProvisioned and RequestOTP for ds_id -2.
- `--native-v2-session`: ProvisioningStart, then ProvisioningEnd
  (`0x0b2b3196`). On success it packs CoreADI's state directory, writes it
  to `<work dir>/adi.pb` and returns it; the server checks that the two are
  the same.

The worker shares `adi_worker_wire_v2.rs` with the server and prints
nothing but protocol frames and the PASS line.

**State container** (`src/state.rs`). Windows CoreADI keeps its state in a
directory: `C:\ProgramData\Apple Computer\iTunes\adi\adi.pb` plus
`adi-<hex>.pb`. A v3 client keeps one opaque `adi_pb`, so the worker packs
the directory:
- the magic `ZWADI\0\1\0`;
- then each file in name order: `u16 name length`, name, `u32 length`,
  bytes (big-endian);
- at most 8 files and 16 KiB in total;
- names are restricted to `[A-Za-z0-9._-]` and must not start with `.`.

Packing is deterministic. Parsing rejects truncation, trailing bytes,
duplicates, misordering and path-like names, so `../` cannot reach the
filesystem. Anything that is not a container never reaches CoreADI.

## 3. Machine identity and robustness

**What CoreADI read** (shim call counts, every offline mode):
- **Registry:** no registry function was called. The shims report every key
  as absent.
- **Volume serial:** `GetVolumeInformationW` was not called before
  provisioning.
- **State file name:** the `adi-<hex>.pb` suffix (`99086F85`) stayed the same
  across runs with random volume serials, so it is not derived from the
  serial. Its derivation is unknown.
- **Other host values** are fixed:
  - user name `zag`;
  - module path `C:\Program Files\iTunes\CoreADI64.dll`;
  - the C: drive maps to the private work directory.

**Machine binding.** The synthetic machine is a pure function of the
client identifier: the volume serial is the identifier's first 4 bytes.
- Every worker for a client therefore presents the same machine, and a
  restarted worker or server sees the same inputs.
- The client holds the only copy of the state, so nothing on the server can
  drift.
- **Unverified:** whether ProvisioningEnd or RequestOTP bind the state to
  any host value that offline runs never touched. Only a provisioned state
  can show this.
- **Unverified:** whether RequestOTP rewrites the state files, as a counter
  would. v3 clients do not persist an updated `adi_pb`; the Android backend
  has the same contract.

**Memory safety and bounds:**
- `pe.rs` validates the headers and the section, relocation, import and
  export bounds before mapping. It refuses TLS, delay imports, ordinal
  imports and writable code, and maps nothing W+X.
- Every buffer CoreADI returns (CPIM, machine id, OTP) is capped at 16 KiB,
  copied, then released with StorageDispose, also on failure paths.
- Path and string shims match Windows semantics exactly:
  - partial copy and error 122 on overflow;
  - zero fill after the NUL;
  - `..` refused when mapping `C:\`.

**Unsupported Windows APIs abort.** These are the `Rtl*` unwind functions,
`RaiseException`, `UnhandledExceptionFilter` and the console functions.
- An abort kills only that worker. The server then reports the request as
  failed: `GetHeadersError` or a provisioning error, never headers.
- No offline mode reached any of them.

**Cleanup:**
- The worker never unmaps the image or calls TearDown/SessionDestroy (the
  SessionDestroy layout is unknown). The process exits instead, and the
  server kills its process group and removes the work directory.
- The e2e tests assert that no workers and no work entries remain.

## 4. Offline validation (Ubuntu, 22 November 2026)

**Suites (run directly):**
- Server suite: 136 passed, including both real-library e2e tests.
- Windows worker: 11 unit tests.
- Android probe: 42 tests.

**The real v3 path** (`real_windows_coreadi_rejects_unprovisioned_material_offline`)
runs the real `CoreADI64.dll` through the real Windows worker and the real
listener:

| Check | Result |
| --- | --- |
| Startup readiness | The real check passes: NOT_PROVISIONED, OTP refused. |
| `get_headers` with plain bytes | `GetHeadersError` ("native ADI rejected the state"); the container parser refuses them before CoreADI. |
| `get_headers` with a forged, well-formed container, 8 at once against 3 slots | CoreADI rejects each one that runs with `-45061`; the others get `503 busy`. Never headers. |
| WebSocket with a SPIM Apple never issued | `StartProvisioningError`. |
| Afterwards | No workers and no work entries left. |

**Under the systemd unit's restrictions.** The real-path e2e tests (Android
and Windows) pass under **24 of the unit's 29 hardening properties**
(`systemd-run --user`). These include:
- `ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges` and `UMask=0077`;
- `SystemCallFilter=@system-service` and `RestrictNamespaces`;
- `RestrictAddressFamilies`, `IPAddressDeny=any` and `MemoryMax=768M`.

`ProtectHome` was `read-only` instead of `yes`, because the test tree lives
in a 0700 home directory. Every worker mode runs inside these e2e tests.
Run alone, the Windows worker gave the same results in all three modes
under 22 of the properties.

The remaining five properties need a system manager: `CapabilityBoundingSet=`,
`PrivateDevices`, `ProtectKernelModules`, `ProtectKernelLogs` and
`ProtectClock`.
- The worker only maps memory and uses files, so none of them should affect
  it.
- This is **not verified** under the system unit, because that needs root on
  the host.

A user manager also implies a user namespace. Inside it, root-owned `/tmp`
appears to belong to `nobody`, so the server's executable check correctly
refuses workers under `/tmp`. A system unit has no such namespace.

**What this does not prove:** that Apple accepts CPIM from this worker, that
ProvisioningEnd succeeds with Apple's PTM/TK, or that OTPs from a
provisioned state are accepted at sign-in.

## Licence

The licence ships in the installer: `License.rtf`, English variants, "iTUNES
FOR WINDOWS SOFTWARE LICENSE AGREEMENT", EA1827, dated 1/31/2023. Its terms
apply to the DLLs it ships, including `CoreADI64.dll`. Quoted:

- **2A** grants "a limited, non-exclusive licence to download, install and
  use one (1) copy of the Apple Software on each compatible computer you own
  or control".
- **2B**: "You may not make the Apple Software available over a network
  where it could be used by multiple computers at the same time." And: "the
  Apple proprietary libraries ("Apple DLLs") included with the Apple
  Software are only licensed for use with the Apple Software."
- **2C**: you may not "copy (except as expressly permitted by this
  Licence), decompile, reverse engineer, disassemble, attempt to derive the
  source code of, decrypt, modify or create derivative works of the Apple
  Software … (except as and only to the extent any foregoing restriction is
  prohibited by applicable law …)".
- **3**: "You may not rent, lease, lend, redistribute or sublicense the
  Apple Software."
- **6**: rights terminate automatically on non-compliance.
- **11**: governed by California law; for consumers in the United Kingdom,
  by the law of their residence.

**On their face, these terms conflict with this backend:**
- Loading `CoreADI64.dll` outside iTunes conflicts with 2B (Apple DLLs only
  with the Apple Software).
- Serving anisette to many clients conflicts with 2B (available over a
  network to multiple computers).
- The offline analysis (disassembly of iTunes.exe and CoreFoundation.dll)
  conflicts with 2C, unless an applicable-law exception covers it.
- Hosting or shipping the DLL conflicts with 3.

**Unresolved, for the owner and counsel:**
- whether an interoperability exception applies to the analysis and to
  this use, under the operator's jurisdiction;
- whether any form of hosted service is compatible with 2B at all;
- whether the Apple Media Services or iCloud terms (section 5) add limits
  on the service side.

**Rules until resolved:**
- Never commit, release or upload any Apple DLL. The repository contains
  none; the worker loads the operator's own copy.
- Never deploy publicly.
- The installer refuses `--platform windows` without `--licence-reviewed`.

The Android backend's licence review (G2/G3) is separate and also open.

## Before one authorized live attempt

1. **The owner's decision on the licence questions above.** This blocks
   any further use, not only deployment.
2. **The identity:**
   - choose a real Windows build number;
   - settle `AuthKitWin/1` versus `/2`;
   - obtain the real User-Agent, from a real iTunes for Windows session on
     a Windows machine the owner controls. Offline analysis cannot supply
     it.
3. **A non-personal test account** and explicit authorization for one
   provisioning attempt: one `startMachineProvisioning` and one
   `finishMachineProvisioning` through the WebSocket. Then, only if it
   succeeds, one `get_headers` and one sign-in check.
4. **Retry policy:** stop after the first failure and record Apple's `ec`
   value. Never retry automatically.
5. **Install the server on a non-production host** with the owner's
   approval. Use the system unit, not production ports 18743–18745.
