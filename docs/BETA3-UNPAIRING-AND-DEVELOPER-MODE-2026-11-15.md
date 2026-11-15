# Pairing removal semantics and Developer Mode guidance

Development branch: `codex/beta3-improvements`. Starting baseline: `8cfe0387`. No version/build change, release preparation, signing, IPA, upload, push, merge, production infrastructure change or edits to another checkout.

## Root cause and protocol investigation

The old `forgetPairing()` only removed `rppairing.plist` and `rppairing-host-identity.bin`, stopped the local advertiser and cleared in-memory diagnostic status. It made no device request. Its UI label **Unpair This iPhone** implied more than the operation accomplished. If deleting the second file failed after deleting the first, it also had no durable recovery state.

The actual pairing path is `ZagRPPairingCore.start()` → `zag_rppairing_start` → Rust `run_pairing` → `PairableHost.accept`. Zag Store advertises a host named Zag Store, with a Mac-like model. The native responder completes SRP/PIN pairing and exchanges an Ed25519 identity with the device. The resulting local RPPairing record contains an identifier, signing keys and peer information; the separate host-identity file supports advertising. Deleting either file does not send a message to the peer trust store.

Reviewed sources:

- `Feather/RPPairing/ZagRPPairingCore.swift` and its Swift/C event bridge.
- `RPPairingCore/rust-core/src/lib.rs`, its bridge header and pinned dependency features.
- `IDeviceKitten/idevice/src/remote_pairing/{mod,responder,rp_pairing_file,lockdown}.rs`, service implementations and native wrappers (read only).
- `ZagRPPairingUninstall.swift`: this removes an installed application through installation_proxy, then checks installed bundle IDs. It is unrelated to removing pairing trust and is unchanged.

A real **classic Lockdown Unpair** method exists in `IDeviceKitten/idevice/src/services/lockdown.rs`. It sends a `PairRecord.HostID` from a classic Lockdown identity. Zag Store's record is an Ed25519 RPPairing identity, not that HostID record. There is no verified identity mapping or exposed matching revoke operation in the current remote-pairing client, native bridge or peer responder. Sending a guessed HostID or classic request would not establish that this exact Settings entry was removed, and risks affecting another relationship. No such request was added.

As a cross-check, the primary upstream [pymobiledevice3 remote delete-pair implementation](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/cli/remote.py) also deletes a host-local file; its name is not evidence of device-side revocation. No matching remote revoke implementation was found in its reviewed tunnel service.

Apple documents user-controlled removal from the paired-device details through Settings/Safety Check, and describes Developer Mode/Device Hub pairing. Device Hub is a Mac development tool, not an app-accessible trust-management API. Zag Store's advertised remote host explains the related paired-device presentation, but this app cannot read the system's list to independently match or confirm its deletion. [Apple: Device Hub access and Unpair](https://support.apple.com/en-by/guide/personal-safety/ips37dbab2a1/1.0/web/1.0), [Apple: Device Hub pairing](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub).

**Conclusion:** no documented, supported app-accessible operation for revoking this specific RPPairing entry was established. This is not proof that the operating system has no internal mechanism. Under the supported-only requirement, automatic device-side revocation is not implemented. No private framework, undocumented selector, guessed protocol opcode, Settings URL, global trust reset or unrelated-record deletion is used.

## Corrected local-only behavior

The same native Control row/icon/confirmation appearance is retained. Its action now says **Forget Local Pairing**, or **Retry Local Cleanup** when recovery is pending. It still asks for confirmation. The confirmation, permanent Control footer instructions and completion message explicitly distinguish local deletion from revocation in Settings. The status reads **Saved Locally** rather than claiming live pairing solely from a file; incomplete cleanup reads **Cleanup Required** with an attention indicator. Completion says that iOS trust **has not been revoked or verified** by Zag Store.

Manual steps: open the paired-device list in Settings (Privacy & Security → Developer Mode on the reported workflow; Developer → Paired Computers on some versions), select only Zag Store, open its details and choose Unpair. Apple's documented Safety Check → Manage Sharing & Access flow also exposes a Developer Mode paired-device list with an information/Unpair action. Screen labels vary by OS; the exact Zag Store entry must be checked on the device. Remove system trust first, then forget the local files. Do not remove other computers/apps or reset all trust.

`ZagLocalPairingRemoval` is deliberately local-only and has no revoke API or full-unpair result type. Before touching either file, the core persists a non-secret cleanup-intent flag. Cleanup targets only the exact credential and host-identity URLs. It attempts both removals, verifies both paths are absent and only then clears the flag. Missing files are idempotent; unreadable paths are errors, not proof of absence. A directory substituted at a file path is refused; symlink deletion removes the link rather than its target.

If any step fails, the flag remains, the UI reports incomplete local cleanup and Retry remains available even if the primary credential file is already gone. A restart retains the retry intent. Retrying removes only surviving local files. There is no claim of an atomic two-file transaction or rollback of system trust. OS-terminated execution still requires resuming local cleanup if the pending intent remains.

All active native workers block explicit cleanup. While cleanup is pending, new pairing/device-service work cannot reuse incomplete material. Gate 2 handles this as an immediate failure rather than queuing forever. Cached native readiness is invalidated after cleanup/failure. The launch adapter excludes pending cleanup from usable records and ignores success events while that flag is set. A cold launch after local removal therefore shows welcome; re-pairing still requires the existing authenticated native success/live verification. Ordinary background returns do not reopen onboarding. No installation, LocalDevVPN, protocol, key derivation or native Rust behavior is rewritten.

## Developer Mode detection and UI

The existing Gate 2 bridge carries product/device information, service stages and pairing-readiness results; none is an authoritative Developer Mode boolean. Pair-Verify, file presence, a working VPN, a successful install, app debug status and the current process's entitlements are not used as substitutes.

The dependency contains device-tooling queries: `AmfiClient.get_developer_mode_status()` reads a `success`/`status` boolean, and `ImageMounter.query_developer_mode_status()` reads `DeveloperModeStatus`. Classic Lockdown tools also query the AMFI domain. These require authenticated device-service access; they are not a documented public local iOS app API, and the current Zag Store diagnostics do not request or export them. Their existence is not evidence that this device/OS/transport allows a reliable, supported app-side read. No new AMFI/private-service query, reboot/enable command, entitlement or speculative inference was added.

Accordingly the Installation Status section now has one compact, initially collapsed native **Developer Mode — Check in Settings** disclosure, with the existing icon column, theme tint and secondary typography. This is deliberately unknown status; it never displays fabricated Enabled/Disabled badges. Its help gives the five manual steps: open Settings; Privacy & Security → Developer Mode; turn it on; restart when prompted; confirm Turn On and enter the passcode after restarting. It notes that the option may appear only after development pairing begins and explicitly distinguishes Developer Mode from the separate Pair with Zag Store approval. No new Settings URL or automation is used. Apple's confirmation-button label can vary by OS.

Sources: [Apple: enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device), [Apple: first-pairing visibility](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub). Public navigation remains limited as documented by [UIApplication.openSettingsURLString](https://developer.apple.com/documentation/uikit/uiapplication/opensettingsurlstring), which opens the app's own Settings page, not Developer Mode.

Guidance files: `Feather/Utilities/ZagDeveloperModeGuidance.swift`, `Feather/Views/Settings/Installation/ZagDeveloperModeGuidanceView.swift`, its single insertion in `InstallationView.swift`, `scripts/ZagDeveloperModeGuidanceTests.swift`, `scripts/test-zag-developer-mode-guidance.sh`, and this report. This is a separate commit from unpairing correction `b8bd1816`.

## Unpairing validation

Passed:

- **37 local-removal checks**: success limited to a local outcome; missing/stale bytes; repeated attempts; deletion failure of either/both files; recovery intent across defaults-store recreation; retry; permission/read failure; refused recursive deletion; symlink target preservation; unrelated record preservation; cold-launch welcome and verified re-pair gate; truthful remaining-trust messages.
- **48 onboarding/event checks** (34 coordinator + 14 production bridge), including pending cleanup blocking retained files and late success callbacks.
- Existing device-link/installation/LocalDevVPN suite, including real host install-job/pause/resume/control tests; self-update recovery; 28 notification tests; 59 deep-link cases and configuration checks; pairing interface source guards.
- Targeted arm64/iOS 16.4 SDK type-check of the actual Installation/RPPairing view prefix and new local helper, with unrelated model/list/diagnostics scaffolding stubbed. A second targeted check compiles the actual native `forgetPairing`/invalidation bodies with stubbed external state/services.
- The installer equality guard now allows only the reviewed local cleanup method, its exact pending-state guards/declaration/error wording, and the previously allowed PIN presentation. All installer/transport implementation outside those specified guards remains byte-equal to the historical baseline. Separate tests exercise the changed cleanup and launch bridge. No failing installation behavior was waived.

**Not applicable / not claimed:** automatic device-side unpair success/failure tests, or automatic system revocation verification. There is no supported revocation branch to test. No mock device-side success is presented as evidence of a working iOS revoke operation. Manual revocation success/failure and genuine re-pairing need the iPhone.

## Developer Mode validation

Passed: eight guidance checks plus native disclosure integration guards (unknown status, five steps, restart/confirmation/passcode, delayed option visibility and separation from pairing). Targeted arm64/iOS 16.4 SDK compilation includes the real Installation/RPPairing view prefix, vector icon, local cleanup helper and Developer Mode view/model, with unrelated external scaffolding stubbed. No enabled/disabled detection path or real device-service query is claimed or simulated.

## Remaining device acceptance

Remove only Zag Store through the system paired-device details; confirm the entry disappears. Test local forgetting before/after manual removal and confirm the app never claims system trust was revoked. Check Retry after local cleanup errors, cold launch with no usable credentials, and a fresh pairing followed by an operational cold-launch check. Verify the existing row alignment/icons, confirmation bubble, collapsed/expanded Developer Mode guide, small-screen text, Dynamic Type/VoiceOver, tint and light/dark appearance. Confirm the five Developer Mode steps on the target iOS version independently of pairing. No full app build or simulator/runtime pass is claimed; previous CoreSimulator/Xcode blockers were not repaired or bypassed.

Logs: `/tmp/zag-developer-mode-guidance.log`, `/tmp/zag-developer-mode-typecheck.log`, `/tmp/zag-local-pairing-removal.log`, `/tmp/zag-unpair-*.log`, `/tmp/zag-local-removal-core-typecheck.log`.
