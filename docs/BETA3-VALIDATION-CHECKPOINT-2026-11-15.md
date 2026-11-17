# Beta 3 recovery validation — 2026-11-15

Branch: `codex/beta3-improvements`. Recovered implementation: `d8eff267192cfed11e85ad97430b46e9c29dc490`. Git metadata is now local `.git`; the working tree started clean. Version/build remain unchanged (1.0.0, build 3; existing Debug suffix retained).

## Recovered implementation

Inspection confirms unattributed copies render both first-launch controls as **Unavailable**. Opening the view only refreshes status; it does not rewrite saved sharing preferences. Anonymous usage sharing retains its independent preference and reporter.

Manual preparation records the verified release identity and rehashes cached bytes before reuse. Manual and automatic preparation share the download gate. Preference changes increment the generation, discard prepared bytes and prevent suspended downloads publishing stale results. Partial files are removed. Preference invalidation does not immediately cancel network transport.

The recovered diff changes no Ed25519 verifier, SHA-256 helper, trust store or rollback store. Imports still receive the signed digest and verify the importer's own copy. No protections were weakened to accommodate host test failures.

## Validation results

- **Passed:** activity reporter suite; self-update recovery suite (including device-family and retry policy); repository refresh suite.
- **Passed after correction:** complete background refresh suite, including once-completion, identifiers, continued-task ledger, fetch diagnostics and refresh lifecycle. Added failed-migration preservation coverage.
- **Passed:** self-update integrity harness compile/link against the real coordinator and security helpers, targeting the iOS simulator SDK; all importer/source integrity checks. Only an existing unused-result warning in ZagLogger. Runtime reuse/concurrency/invalidation regressions could not run.
- **Passed:** Python offline v2 verification with the normal interpreter: disposable signer, Unicode payload, forged signature, payload tampering, wrong channel/key and IPA digest mismatch. `python3 -I` cannot import this environment's user-installed cryptography dependency; normal invocation passes.
- **Partial:** first-launch suite presentation and non-Keychain behavior pass. Restricted run fails four persistence assertions. Broader-access run fixes backup exclusion but retains three Keychain failures (launch completion, suppression after file loss, jailbreak completion).
- **Blocked by host Keychain:** disposable SecItemAdd probes return OSStatus **-50**, including a basic item without the iOS accessibility attribute, with broader access. Swift v2 expiry aborts with `StoreError.keychain(-50)`; vector conformance reports 33 failures rooted in unavailable accepted-sequence persistence. These suites do not establish an app security defect or a runtime pass. Device/simulator validation remains necessary.
- **Blocked by CoreSimulator:** `xcrun simctl list devices booted` exits 72: NSPOSIXErrorDomain 61, “Connection refused”, unable to look up `com.apple.CoreSimulator.CoreSimulatorService (1051.54)` in the bootstrap. No simulator repair attempted.
- **Blocked before compilation:** unsigned Debug generic iOS build, both restricted and broader-access attempts, exits **134**. Logs report DVTFilePathFSEvents failure and DVTDeveloperPaths `DARWIN_USER_CACHE_DIR` confstr error 5 (Input/output error). Neither reaches compiler diagnostics. Derived data, dependencies and destination were isolated under `/tmp/zag-checkpoint-build*`.
- **Passed:** whitespace diff check. Swift's initial default-module-cache permission error was avoided by directing CLANG_MODULE_CACHE_PATH and SWIFT_MODULECACHE_PATH to `/tmp/zag-checkpoint-module-cache`.

## Confirmed defect corrected

`NBRepositoryFetchDiagnostics.record` assumed the caches directory existed and removed legacy UserDefaults metrics even if the file write failed. This reproduced in the isolated background harness even with broader access. It now creates the parent directory and only removes legacy data after a successful atomic write. The existing fresh-cache regression passes; added coverage obstructs the destination and verifies legacy bytes remain readable after failure.

Logs: `/tmp/zag-checkpoint-*.log` (local validation output, not release artifacts).

The branch is ready for additional feature work, with full app build and iOS runtime validation still outstanding. No IPA, release preparation, version change, production infrastructure change, push or merge was performed. The separate ZagStore-claude and Feather-Petar checkouts were untouched.
