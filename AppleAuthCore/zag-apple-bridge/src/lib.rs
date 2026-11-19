//! Zag Store's bridge from its Swift Apple Account and developer-portal
//! interfaces to the trimmed `zag-isideload` fork.
//!
//! - Network access exists only with the `live` feature, which enables
//!   `zag-isideload/live-network`. Without it (every normal Debug and Release
//!   build) no backend can be configured and every operation fails with
//!   `disabled` before anything is attempted. The fork's own policy also
//!   refuses all traffic.
//! - The `mock` feature (tests only) adds a scripted backend, mocked at this
//!   crate's backend boundary, never at the level of Apple's messages.
//! - Passwords and codes arrive as bytes, are held in zeroising buffers and are
//!   never stored. Session tokens are returned to Swift (which keeps them in its
//!   this-device-only Keychain) and wiped from the bridge's buffers after
//!   delivery.
//! - Nothing is logged. Failures reach Swift only as a `FailureKind`, never as
//!   text from Apple or from the library.

pub mod backend;
pub mod ffi;
pub mod slot;

#[cfg(feature = "live")]
mod live;
#[cfg(feature = "mock")]
pub mod mock;

/// True only in a build with the `live` feature.
pub const LIVE: bool = cfg!(feature = "live");
