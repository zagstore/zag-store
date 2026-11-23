//! Supervised, owner-authorized scoped live probe (`live` feature only).
//!
//! Runs **stages 1-3** of the standalone free-account flow — Apple
//! authentication (with 2FA) and anisette/ADI provisioning — against an
//! owner-designated anisette provider and test account, then STOPS before any
//! developer-portal call. It registers no device, issues no certificate,
//! creates no App ID or profile, and never retries. It prints only a
//! privacy-preserving [`crate::diagnostics::ProvisioningDiagnostic`]; the
//! password and any 2FA code are read from the controlling terminal into
//! zeroizing buffers and are never logged, stored or committed.
//!
//! Non-secret inputs come from the environment:
//!   * `ZAG_PROBE_ANISETTE_URL` — `https://<provider>/…` (policy-checked)
//!   * `ZAG_PROBE_SERIAL`       — 1-32 ASCII alphanumerics
//!   * `ZAG_PROBE_EMAIL`        — the test account's Apple ID
//!
//! The anisette device state lives only in process memory for the run, so no
//! real Keychain is touched and nothing persists.

use std::collections::HashMap;
use std::ffi::{CStr, c_char, c_void};
use std::io::{BufRead, Write};
use std::sync::Mutex;

use zeroize::{Zeroize, Zeroizing};

use crate::backend::{CodeAction, Prompter, TwoFactorMethod};
use crate::ffi::ZagBridgeStorage;
use crate::live::IsideloadBackend;

/// Ephemeral, in-process anisette device state for this one run. Not a
/// Keychain: it is discarded when the process exits.
static STORE: Mutex<Option<HashMap<String, Vec<u8>>>> = Mutex::new(None);

extern "C" fn store(_: *mut c_void, k: *const c_char, v: *const u8, n: usize) -> i32 {
    let key = unsafe { CStr::from_ptr(k) }.to_string_lossy().into_owned();
    let val = unsafe { std::slice::from_raw_parts(v, n) }.to_vec();
    STORE.lock().unwrap().get_or_insert_with(HashMap::new).insert(key, val);
    0
}

extern "C" fn retrieve(_: *mut c_void, k: *const c_char, v: *mut *mut u8, n: *mut usize) -> i32 {
    let key = unsafe { CStr::from_ptr(k) }.to_string_lossy().into_owned();
    let Some(val) = STORE.lock().unwrap().get_or_insert_with(HashMap::new).get(&key).cloned() else {
        return 1; // "no item" — exactly as the Swift Keychain reports an absent key
    };
    let boxed = val.into_boxed_slice();
    unsafe {
        *n = boxed.len();
        *v = Box::into_raw(boxed) as *mut u8;
    }
    0
}

extern "C" fn delete_item(_: *mut c_void, k: *const c_char) -> i32 {
    let key = unsafe { CStr::from_ptr(k) }.to_string_lossy().into_owned();
    STORE.lock().unwrap().get_or_insert_with(HashMap::new).remove(&key);
    0
}

extern "C" fn release(_: *mut c_void, v: *mut u8, n: usize) {
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(v, n)) });
}

/// Reads one line from the controlling terminal with echo disabled, into a
/// zeroizing buffer. The source line is zeroized after the copy.
fn read_secret(prompt: &str) -> Zeroizing<String> {
    eprint!("{prompt}");
    let _ = std::io::stderr().flush();
    let _ = std::process::Command::new("stty").arg("-echo").status();
    let mut line = String::new();
    let _ = std::io::stdin().lock().read_line(&mut line);
    let _ = std::process::Command::new("stty").arg("echo").status();
    eprintln!();
    let secret = Zeroizing::new(line.trim_end_matches(['\n', '\r']).to_string());
    line.zeroize();
    secret
}

/// Reads one line from the terminal with echo on (for a one-time 2FA code).
fn read_line_plain(prompt: &str) -> String {
    eprint!("{prompt}");
    let _ = std::io::stderr().flush();
    let mut line = String::new();
    let _ = std::io::stdin().lock().read_line(&mut line);
    line.trim_end_matches(['\n', '\r']).to_string()
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

/// Entry point for the `zag-scoped-probe` binary. Returns a process exit code:
/// 0 = auth + provisioning succeeded (stopped before any portal call),
/// 1 = a diagnosed failure was printed, 2 = misconfiguration (nothing sent).
pub fn run() -> i32 {
    let (Some(url), Some(serial), Some(email)) =
        (env("ZAG_PROBE_ANISETTE_URL"), env("ZAG_PROBE_SERIAL"), env("ZAG_PROBE_EMAIL"))
    else {
        eprintln!("Set ZAG_PROBE_ANISETTE_URL, ZAG_PROBE_SERIAL and ZAG_PROBE_EMAIL.");
        return 2;
    };

    let storage = ZagBridgeStorage {
        context: std::ptr::null_mut(),
        store,
        retrieve,
        delete_item,
        release,
    };
    let backend = match IsideloadBackend::new(&url, &serial, storage) {
        Ok(backend) => backend,
        Err(_) => {
            eprintln!("Invalid provider URL or serial (https-only, allow-listed host, 1-32 alphanumerics).");
            return 2;
        }
    };

    eprintln!("Scoped live probe — stages 1-3 only (auth + anisette provisioning).");
    eprintln!("It will STOP before team discovery; it registers no device and issues no certificate.");
    let password = read_secret(&format!("Apple ID password for {email} (hidden): "));

    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(_) => {
            eprintln!("Could not start the async runtime.");
            return 2;
        }
    };

    let (prompter, mut prompts_rx, answers_tx) = Prompter::channel();
    // Drive 2FA prompts from the terminal. A dropped prompter ends this loop.
    runtime.spawn(async move {
        while let Some(prompt) = prompts_rx.recv().await {
            let label = match prompt.method {
                TwoFactorMethod::Sms => "SMS",
                TwoFactorMethod::TrustedDevice => "trusted-device",
            };
            let length = prompt.code_length;
            let retry = if prompt.retry { " (previous code rejected)" } else { "" };
            let code = tokio::task::spawn_blocking(move || {
                read_line_plain(&format!("Enter the {length}-digit {label} code{retry}: "))
            })
            .await
            .unwrap_or_default();
            if answers_tx.send(CodeAction::Submit(Zeroizing::new(code))).is_err() {
                break;
            }
        }
    });

    let result = runtime.block_on(backend.probe_provisioning("zag-probe-ephemeral", &email, password, &prompter));
    match result {
        Ok(()) => {
            println!(
                "{}",
                serde_json::json!({
                    "probe": "ok",
                    "note": "auth + anisette provisioning succeeded; STOPPED before team discovery — no Apple-account resource consumed"
                })
            );
            0
        }
        Err(diagnostic) => {
            println!("{}", serde_json::to_string(&diagnostic).unwrap_or_else(|_| "{\"probe\":\"error\"}".into()));
            1
        }
    }
}
