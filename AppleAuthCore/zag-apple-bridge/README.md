# zag-apple-bridge

This crate is Zag Store's bridge from its Swift Apple Account and developer-portal interfaces (`ZagAppleAuthenticationService`, `ZagDeveloperPortalService`) to the trimmed `zag-isideload` fork in `../zag-isideload`.

It is Zag Store's own code, under the repository's `LICENSE` (GPL-3.0). It links `zag-isideload`, which is MIT, with four files marked MPL-2.0 pending review; see `docs/free-developer-accounts/G2-LICENCE-REVIEW.md`.

**Status: G4 implementation for review. Not enabled anywhere; no live Apple service has been contacted.**

## Builds

| Build | Network | Use |
|---|---|---|
| default | **none**: every call fails with `disabled` | the only build any app configuration could link (none does) |
| `--features mock` | none: scripted test backend | `scripts/test-zag-apple-bridge.sh` |
| `--features live` | `zag-isideload/live-network`, through the fork's allowlist | only the separately approved supervised-experiment build |

No Xcode configuration compiles the Swift side (`ZAG_APPLE_BRIDGE`) or links this library. The test suite checks this.

## Layout

| Path | What it holds |
|---|---|
| `src/backend.rs` | The backend interface, failure kinds and portal requests |
| `src/slot.rs` | Per-account slots: one sign-in at a time, account binding, cached portal session, cancellation |
| `src/ffi.rs`, `include/zag_apple_bridge.h` | The C interface Swift calls |
| `src/live.rs` (`live` only) | Drives `zag-isideload`; places to confirm under supervision are marked `EXPERIMENT` |
| `src/mock.rs` (`mock` only) | The scripted backend, mocked at this crate's boundary, never at the level of Apple's messages |
| `tests/bridge.rs` | Rust checks for each build |
| `Feather/Utilities/FreeAccount/ZagIsideloadBridge.swift` | The Swift side (`#if ZAG_APPLE_BRIDGE`) |

## Testing

```
scripts/test-zag-apple-bridge.sh
```
