//! The C interface Swift calls (include/zag_apple_bridge.h).
//!
//! Every function returns at once. Results arrive through the event callback
//! as JSON on a bridge thread; the bytes are wiped after the callback returns,
//! so Swift must copy what it keeps. The callback's `context` is released by
//! Swift on the terminal event (`signedIn`, `result` or `failed`), which is
//! delivered exactly once per started operation.

use std::ffi::{c_char, c_void};
use std::slice;

use zeroize::Zeroizing;

use crate::backend::*;
use crate::slot;

pub type EventCallback = extern "C" fn(context: *mut c_void, json: *const u8, length: usize);

/// Swift's storage for the anisette provider's device state (its
/// this-device-only Keychain). `retrieve` returns a buffer that
/// `release` frees.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ZagBridgeStorage {
    pub context: *mut c_void,
    pub store: extern "C" fn(*mut c_void, *const c_char, *const u8, usize) -> i32,
    pub retrieve: extern "C" fn(*mut c_void, *const c_char, *mut *mut u8, *mut usize) -> i32,
    pub delete_item: extern "C" fn(*mut c_void, *const c_char) -> i32,
    pub release: extern "C" fn(*mut c_void, *mut u8, usize),
}

unsafe impl Send for ZagBridgeStorage {}
unsafe impl Sync for ZagBridgeStorage {}

struct Context(*mut c_void);
unsafe impl Send for Context {}
unsafe impl Sync for Context {}

fn emitter(context: *mut c_void, callback: EventCallback) -> slot::Emit {
    let context = Context(context);
    Box::new(move |bytes: &[u8]| {
        let context = &context;
        callback(context.0, bytes.as_ptr(), bytes.len())
    })
}

/// Codes returned by the synchronous calls.
pub const ZAG_BRIDGE_OK: i32 = 0;
pub const ZAG_BRIDGE_DISABLED: i32 = 1;
pub const ZAG_BRIDGE_INVALID: i32 = 2;
pub const ZAG_BRIDGE_UNSUPPORTED: i32 = 3;

pub const ZAG_BRIDGE_ANSWER_CODE: i32 = 0;
pub const ZAG_BRIDGE_ANSWER_SMS: i32 = 1;
pub const ZAG_BRIDGE_ANSWER_CANCEL: i32 = 2;

unsafe fn bytes<'a>(pointer: *const u8, length: usize) -> Option<&'a [u8]> {
    if pointer.is_null() || length == 0 || length > 64 * 1024 {
        return None;
    }
    Some(unsafe { slice::from_raw_parts(pointer, length) })
}

/// 1 when this build can reach the network (the `live` feature), else 0.
#[unsafe(no_mangle)]
pub extern "C" fn zag_bridge_live_compiled() -> i32 {
    crate::LIVE as i32
}

/// Configures the live backend once, with the approved anisette server and
/// the device serial chosen with it (no default exists).
/// Returns `ZAG_BRIDGE_DISABLED` in a build without the `live` feature.
///
/// # Safety
/// `anisette_url` and `device_serial` are NUL-terminated strings; `storage`
/// points to a valid `ZagBridgeStorage` whose functions stay valid for the
/// process lifetime.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zag_bridge_configure_live(
    anisette_url: *const c_char,
    device_serial: *const c_char,
    storage: *const ZagBridgeStorage,
) -> i32 {
    #[cfg(feature = "live")]
    {
        if anisette_url.is_null() || device_serial.is_null() || storage.is_null() || slot::backend_is_set() {
            return ZAG_BRIDGE_INVALID;
        }
        let Ok(url) = unsafe { std::ffi::CStr::from_ptr(anisette_url) }.to_str() else { return ZAG_BRIDGE_INVALID };
        let Ok(serial) = unsafe { std::ffi::CStr::from_ptr(device_serial) }.to_str() else { return ZAG_BRIDGE_INVALID };
        match crate::live::IsideloadBackend::new(url, serial, unsafe { *storage }) {
            Ok(backend) => {
                slot::set_backend(std::sync::Arc::new(backend));
                ZAG_BRIDGE_OK
            }
            Err(_) => ZAG_BRIDGE_INVALID,
        }
    }
    #[cfg(not(feature = "live"))]
    {
        let _ = (anisette_url, device_serial, storage);
        ZAG_BRIDGE_DISABLED
    }
}

/// Tests only: configures the scripted backend (`mock::MockScript` as JSON).
///
/// # Safety
/// `json` points to `length` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zag_bridge_configure_mock(json: *const u8, length: usize) -> i32 {
    #[cfg(feature = "mock")]
    {
        let Some(json) = (unsafe { bytes(json, length) }) else { return ZAG_BRIDGE_INVALID };
        match crate::mock::MockBackend::from_json(json) {
            Some(backend) => {
                slot::set_backend(std::sync::Arc::new(backend));
                ZAG_BRIDGE_OK
            }
            None => ZAG_BRIDGE_INVALID,
        }
    }
    #[cfg(not(feature = "mock"))]
    {
        let _ = (json, length);
        ZAG_BRIDGE_UNSUPPORTED
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn zag_bridge_open_slot() -> u64 {
    slot::open()
}

#[unsafe(no_mangle)]
pub extern "C" fn zag_bridge_close_slot(slot_id: u64) {
    slot::close(slot_id)
}

/// Starts a sign-in in `slot_id`. The password is copied into a zeroising
/// buffer; Swift wipes its own copy when this returns. `anisette_scope`
/// names the account's own anisette device state (1–64 letters, digits or
/// hyphens); there is no shared default.
///
/// # Safety
/// `anisette_scope` is a NUL-terminated string; the other pointers are
/// readable for their lengths; `callback` and `context` stay valid until the
/// terminal event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zag_bridge_sign_in(
    slot_id: u64,
    anisette_scope: *const c_char,
    email: *const u8,
    email_length: usize,
    password: *const u8,
    password_length: usize,
    context: *mut c_void,
    callback: EventCallback,
) {
    let emit = emitter(context, callback);
    let scope = (!anisette_scope.is_null())
        .then(|| unsafe { std::ffi::CStr::from_ptr(anisette_scope) }.to_str().ok())
        .flatten()
        .filter(|s| crate::backend::valid_anisette_scope(s))
        .map(str::to_owned);
    let email = unsafe { bytes(email, email_length) }.and_then(|b| std::str::from_utf8(b).ok()).map(str::to_owned);
    let password = unsafe { bytes(password, password_length) }
        .and_then(|b| std::str::from_utf8(b).ok())
        .map(|p| Zeroizing::new(p.to_owned()));
    match (scope, email, password) {
        (Some(scope), Some(email), Some(password)) => slot::sign_in(slot_id, scope, email, password, emit),
        _ => emit(br#"{"event":"failed","kind":"invalidInput"}"#),
    }
}

/// Answers the current verification-code prompt of `slot_id`.
///
/// # Safety
/// `code` is readable for `code_length` bytes when `action` is
/// `ZAG_BRIDGE_ANSWER_CODE`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zag_bridge_answer(slot_id: u64, action: i32, code: *const u8, code_length: usize) -> i32 {
    let action = match action {
        ZAG_BRIDGE_ANSWER_CODE => {
            let Some(code) = (unsafe { bytes(code, code_length) })
                .filter(|code| code.len() <= 16 && code.iter().all(u8::is_ascii_digit))
            else {
                return ZAG_BRIDGE_INVALID;
            };
            CodeAction::Submit(Zeroizing::new(String::from_utf8_lossy(code).into_owned()))
        }
        ZAG_BRIDGE_ANSWER_SMS => CodeAction::RequestSms,
        ZAG_BRIDGE_ANSWER_CANCEL => CodeAction::Cancel,
        _ => return ZAG_BRIDGE_INVALID,
    };
    match slot::answer(slot_id, action) {
        Ok(()) => ZAG_BRIDGE_OK,
        Err(_) => ZAG_BRIDGE_INVALID,
    }
}

/// Cancels every operation running in `slot_id`; each still delivers its
/// terminal event (`failed`, `cancelled`).
#[unsafe(no_mangle)]
pub extern "C" fn zag_bridge_cancel(slot_id: u64) -> i32 {
    match slot::cancel(slot_id) {
        Ok(()) => ZAG_BRIDGE_OK,
        Err(_) => ZAG_BRIDGE_INVALID,
    }
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct CredentialInput {
    account_identifier: String,
    token: Zeroizing<String>,
    expires_at: u64,
}

/// Runs one portal operation (`backend::PortalRequest` as JSON) with the
/// credential (JSON: accountIdentifier, token, expiresAt).
///
/// # Safety
/// The pointers are readable for their lengths; `callback` and `context`
/// stay valid until the terminal event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zag_bridge_portal(
    slot_id: u64,
    credential: *const u8,
    credential_length: usize,
    request: *const u8,
    request_length: usize,
    context: *mut c_void,
    callback: EventCallback,
) {
    let emit = emitter(context, callback);
    let credential = unsafe { bytes(credential, credential_length) }
        .and_then(|b| serde_json::from_slice::<CredentialInput>(b).ok())
        .map(|c| Credential { account_identifier: c.account_identifier, token: c.token, expires_at: c.expires_at });
    let request = unsafe { bytes(request, request_length) }.and_then(|b| serde_json::from_slice::<PortalRequest>(b).ok());
    match (credential, request) {
        (Some(credential), Some(request)) => slot::portal(slot_id, credential, request, emit),
        _ => emit(br#"{"event":"failed","kind":"invalidInput"}"#),
    }
}

/// G5 (observation only): seconds since 1970 of the `Date` header of the
/// latest response from an Apple host, received over verified TLS; 0 if
/// none yet. The experiment checks its authorisation window against it.
#[unsafe(no_mangle)]
pub extern "C" fn zag_bridge_last_apple_date() -> i64 {
    isideload::net_policy::observe::last_apple_date()
}

/// G5 (observation only): delivers every network-policy decision recorded
/// since the last call, as one JSON array, synchronously through `callback`
/// (the bytes are valid only during the call). Entries carry the host, the
/// path without its query, the method, whether it was allowed and why not.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zag_bridge_take_policy_decisions(context: *mut c_void, callback: EventCallback) {
    let decisions: Vec<serde_json::Value> = isideload::net_policy::observe::take()
        .into_iter()
        .map(|d| {
            serde_json::json!({
                "host": d.host, "path": d.path, "method": d.method, "scheme": d.scheme,
                "allowed": d.allowed, "reason": d.reason,
            })
        })
        .collect();
    let bytes = Zeroizing::new(serde_json::to_vec(&decisions).unwrap_or_else(|_| b"[]".to_vec()));
    callback(context, bytes.as_ptr(), bytes.len());
}
