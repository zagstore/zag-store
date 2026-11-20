//! Offline, operator-run native loader smoke probe. Does not call ADI provisioning.
mod native_session;
mod offline_v2_bridge;
mod provisioning_client;
mod process_watchdog;
use android_loader::android_library::AndroidLibrary;
use android_loader::{hook_manager, sysv64};
use std::collections::HashMap;
use std::ffi::{c_char, CString};
use android_loader::sysv64_type;
use std::path::PathBuf;

#[sysv64]
fn arc4random() -> u32 { rand::random() }

static mut ERRNO: i32 = 0;
#[sysv64]
unsafe fn __errno_location() -> *mut i32 {
    ERRNO = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
    &raw mut ERRNO
}
#[sysv64]
unsafe fn __system_property_get(_name: *const c_char, value: *mut c_char) -> i32 {
    if !value.is_null() { *value = b'0' as c_char; }
    1
}
macro_rules! report {
    ($($args:tt)*) => {
        if std::env::args_os().nth(2).as_deref() == Some(std::ffi::OsStr::new("--native-v2-session")) {
            eprintln!($($args)*);
        } else {
            println!($($args)*);
        }
    };
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = PathBuf::from(std::env::args_os().nth(1).ok_or("usage: zag-native-adi-loader-probe <runtime-root>")?);
    let arch = if cfg!(target_arch = "x86_64") { "x86_64" } else if cfg!(target_arch = "aarch64") { "arm64-v8a" } else { return Err("unsupported host architecture".into()); };
    let dir = root.join("lib").join(arch);
    for name in ["libstoreservicescore.so", "libCoreADI.so"] {
        if !dir.join(name).is_file() { return Err(format!("missing {}", dir.join(name).display()).into()); }
    }
    let mut hooks = HashMap::new();
    hooks.insert("arc4random".to_string(), arc4random as *const () as usize);
    hooks.insert("__system_property_get".to_string(), __system_property_get as *const () as usize);
    hooks.insert("__errno".to_string(), __errno_location as *const () as usize);
    hooks.insert("chmod".to_string(), libc::chmod as *const () as usize);
    hooks.insert("close".to_string(), libc::close as *const () as usize);
    hooks.insert("free".to_string(), libc::free as *const () as usize);
    hooks.insert("fstat".to_string(), libc::fstat as *const () as usize);
    hooks.insert("ftruncate".to_string(), libc::ftruncate as *const () as usize);
    hooks.insert("gettimeofday".to_string(), libc::gettimeofday as *const () as usize);
    hooks.insert("lstat".to_string(), libc::lstat as *const () as usize);
    hooks.insert("malloc".to_string(), libc::malloc as *const () as usize);
    hooks.insert("mkdir".to_string(), libc::mkdir as *const () as usize);
    hooks.insert("open".to_string(), libc::open as *const () as usize);
    hooks.insert("read".to_string(), libc::read as *const () as usize);
    hooks.insert("strncpy".to_string(), libc::strncpy as *const () as usize);
    hooks.insert("umask".to_string(), libc::umask as *const () as usize);
    hooks.insert("write".to_string(), libc::write as *const () as usize);
    hook_manager::add_hooks(hooks);
    eprintln!("Loading {}", dir.join("libstoreservicescore.so").display());
    let lib = AndroidLibrary::load(dir.join("libstoreservicescore.so").to_str().ok_or("non-UTF8 runtime path")?)?;
    let symbols = [
        ("load_core_adi", "kq56gsgHG6"),
        ("set_android_id", "Sph98paBcz"),
        ("set_provisioning_path", "nf92ngaK92"),
        ("start_provisioning", "rsegvyrt87"),
        ("end_provisioning", "uv5t6nhkui"),
        ("destroy_session", "fy34trz2st"),
        ("dispose_buffer", "jk24uiwqrg"),
    ];
    let mut missing = false;
    for (label, symbol) in symbols {
        let found = lib.get_symbol(symbol).is_some();
        report!("{label}: {}", if found { "resolved" } else { "MISSING" });
        missing |= !found;
    }
    if missing { return Err("required native symbols missing".into()); }
    let mode = std::env::args_os().nth(2);
    let mode = mode.as_deref().and_then(std::ffi::OsStr::to_str);
    if mode == Some("--initialize-core") || mode == Some("--configure-state") || mode == Some("--native-abi-preflight") || mode == Some("--native-v2-session") {
        // All calls are explicitly opt-in. Never initiate provisioning in this probe.
        let init: sysv64_type!(fn(*const u8) -> i32) = unsafe {
            std::mem::transmute(lib.get_symbol("kq56gsgHG6").ok_or("missing CoreADI initializer")?)
        };
        let native_dir = CString::new(dir.to_str().ok_or("non-UTF8 native directory")?)?;
        eprintln!("Initializing CoreADI from {} (no provisioning)", dir.display());
        let status = init(native_dir.as_ptr().cast());
        report!("CoreADI initialization status: {status}");
        if status != 0 { return Err(format!("CoreADI initialization failed: {status}").into()); }
        report!("PASS: CoreADI initialized; no provisioning executed");

        if mode == Some("--configure-state") || mode == Some("--native-abi-preflight") || mode == Some("--native-v2-session") {
            // Use an absolute, private test directory. Never reuse production ADI state.
            let state = if mode == Some("--native-v2-session") {
                let candidate = PathBuf::from(std::env::args_os().nth(3).ok_or("missing fresh state directory")?);
                if !candidate.is_absolute() { return Err("state directory must be absolute".into()); }
                if candidate.exists() { return Err("state directory already exists".into()); }
                std::fs::create_dir(&candidate)?;
                candidate
            } else { root.join("probe-state") };
            std::fs::create_dir_all(&state)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700))?;
            }
            let state = state.canonicalize()?;
            let state_cstr = CString::new(state.to_str().ok_or("non-UTF8 state path")?)?;
            let set_path: sysv64_type!(fn(*const u8) -> i32) = unsafe {
                std::mem::transmute(lib.get_symbol("nf92ngaK92").ok_or("missing set_provisioning_path")?)
            };
            eprintln!("Configuring isolated native state path: {}", state.display());
            let path_status = set_path(state_cstr.as_ptr().cast());
            report!("ADI provisioning path status: {path_status}");
            if path_status != 0 { return Err(format!("native state path rejected: {path_status}").into()); }

            // Fixed probe-only identifier: not an Apple ID, device serial, or user credential.
            let operator_identifier = if mode == Some("--native-v2-session") {
                let value = std::env::args().nth(4).ok_or("missing Android identifier")?;
                if value.is_empty() || value.len() > 256 || value.bytes().any(|b| b == 0 || b.is_ascii_control()) {
                    return Err("invalid Android identifier".into());
                }
                value
            } else { "zagadi-probe0001".to_owned() };
            let identifier = operator_identifier.as_bytes();
            let set_id: sysv64_type!(fn(*const u8, u32) -> i32) = unsafe {
                std::mem::transmute(lib.get_symbol("Sph98paBcz").ok_or("missing set_android_id")?)
            };
            let id_status = set_id(identifier.as_ptr(), identifier.len() as u32);
            report!("ADI Android identifier status: {id_status}");
            if id_status != 0 { return Err(format!("native Android identifier rejected: {id_status}").into()); }
            report!("PASS: isolated provisioning path and Android identifier configured");
            if mode == Some("--native-abi-preflight") || mode == Some("--native-v2-session") {
                let _native = native_session::NativeFunctions::resolve(&lib)?;
                if mode == Some("--native-v2-session") {
                    offline_v2_bridge::run_native_v2(
                        &_native, &state.join("adi.pb"),
                        &mut std::io::stdin().lock(), &mut std::io::stdout().lock(),
                    )?;
                    return Ok(());
                }
                report!("PASS: typed native Start/End/Destroy/Dispose functions bound; no provisioning executed");
            }
        }
    }
    report!("PASS: native StoreServicesCore loaded and required symbols resolved; no provisioning executed");
    Ok(())
}
