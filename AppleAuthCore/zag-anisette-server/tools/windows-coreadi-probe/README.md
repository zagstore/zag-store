# Windows CoreADI on Linux (offline prototype)

This crate runs Apple's **Windows** `CoreADI64.dll` natively on Linux
x86_64, without Wine. It is the first step towards a desktop-ADI backend,
the direction chosen after PR #46 found that Apple rejects the Android
CoreADI used together with a desktop identity.

**Status: offline prototype.** No network access, no Apple ID and no
provisioning. It shows that the library loads and that its real entry
points run. It does not show that Apple accepts anything the library
produces.

## How it works

- **`pe.rs`** is a minimal PE32+ loader. It maps the sections, applies the
  DIR64 base relocations, binds every import by name to host code, and
  applies section protections. A writable code section is refused, so no
  mapping is ever writable and executable at once. TLS directories, delay
  imports and ordinal imports are refused.
- **`win.rs`** provides the 103 Windows functions the DLL imports from
  KERNEL32, ADVAPI32, SHLWAPI and SHELL32, using the win64 ABI.
  - Files are confined to a private root: `C:\` maps to `<root>/c`, and
    `..` is refused. New files are 0600 and directories 0700.
  - `CryptGenRandom` reads from `getrandom`.
  - The registry and the volume serial come from `machine.txt`, a synthetic
    test machine created once per root.
  - No other library is ever loaded: `LoadLibraryExW` refuses every request,
    and the runtime falls back to the functions it imports.
  - Exception dispatch (`RaiseException`, the `Rtl*Unwind` functions) and the
    console functions abort with the name of the API that was reached.
  - A minimal TEB/PEB sits behind `%gs`. `__chkstk` reads the stack limits
    from it, and the code also reads the TEB self pointer and the PEB.
- **`adi.rs`** calls the dispatcher export `vdfut768ig(code, &params)`.
  - A request is fixed-width big-endian: `u32 1`, `u32 1`, then the message
    fields, with pointers as u64.
  - The status comes back in the first four bytes of the same buffer.

Two behaviours Windows provides had to be matched:
- A conversion into a buffer that is too small fills the buffer as far as
  it goes and then fails.
- Path outputs are zeroed after the terminating NUL.

CoreADI converts whole `MAX_PATH` buffers and relies on both.

## Results (Ubuntu 25.10, x86_64)

The DLL is `CoreADI64.dll` from `iTunes64Setup.exe`, downloaded from
`secure-appldnld.apple.com` (installer SHA-256 `221a2420…29db4d`, DLL
SHA-256 `c83a2b4a…1995ad`). Its signer certificate is Apple Inc.; the
Authenticode digest was not re-verified.

The probe ran under a user systemd sandbox: no network, `@system-service`
syscall filter, `ProtectSystem=strict`.

| Step | Result |
| --- | --- |
| load, relocate, bind all imports | PASS |
| `DllMain(DLL_PROCESS_ATTACH)`, CRT initialisation | PASS, returns 1 |
| initialize (`0x12db31c5`) | 1 |
| is_machine_provisioned(-2), empty machine | **-45061** (not provisioned) |
| request_otp(-2), empty machine | **-45061** |
| start_provisioning with bytes Apple never issued | **-45031** (rejected) |
| tear_down | 1 |

**State location.** CoreADI keeps its state at
`C:\ProgramData\Apple Computer\iTunes\adi\adi.pb`, plus a machine-specific
`adi-<hex>.pb`. It takes a named mutex `Global\adi-pb-unique`.

**Repeatability.** Three runs on fresh roots gave identical results.

**Failure handling.** A truncated DLL and a group-readable root are both
refused cleanly.

Run it:
```sh
cargo build --release
mkdir -m 700 root
target/release/zag-windows-coreadi-probe /private/CoreADI64.dll root [--trace]
```

The DLL is Apple's and is never committed. Extract it yourself from the
official installer.

## Not yet shown

- **A provisioning exchange.** Start with a real SPIM, then Finish. That
  needs authorization for Apple contact.
- **A matching identity.** `iTunes.exe` (which statically links AuthKitWin
  `authkitwin-185.6`) contains the template
  `<PC> <%@> <com.apple.AuthKitWin/%d (%@/%@)>`. The values it fills in
  (Windows version field, AuthKitWin version, app bundle id and version)
  have not been sourced yet.
- **Which machine values bind the state.** No registry or volume query
  happened before provisioning. They may happen during Start/Finish.
- **C++ exception paths.** Unsupported, and they abort if reached.
- **Integration as a worker mode** behind the existing v3 server, with its
  supervision and isolation.
