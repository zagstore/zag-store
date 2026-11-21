//! Operator-run native loader probe. The default and preflight modes do not
//! provision; --native-v2-session is reached only from the supervised
//! coordinator in probe_cli, and --native-verify-state only checks its result.
mod native_session;
mod offline_v2_bridge;
mod provisioning_client;
mod process_watchdog;
mod probe_cli;
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
/// AuthKit's fixed account-independent ds_id for machine provisioning.
const DS_ID: i64 = -2;

/// A state directory claimed (created 0700) by the supervisor: absolute,
/// a real directory owned by this user, private, and empty unless an
/// existing provisioned state is being verified.
fn claimed_state_dir(arg: Option<std::ffi::OsString>, provisioned: bool) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let path = PathBuf::from(arg.ok_or("missing claimed state directory")?);
    if !path.is_absolute() { return Err("state directory must be absolute".into()); }
    let metadata = std::fs::symlink_metadata(&path).map_err(|_| "claimed state directory missing")?;
    if !metadata.is_dir() { return Err("claimed state path is not a directory".into()); }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.permissions().mode() & 0o077 != 0 {
            return Err("claimed state directory must be private".into());
        }
    }
    let empty = std::fs::read_dir(&path)?.next().is_none();
    if !provisioned && !empty { return Err("claimed state directory is not empty".into()); }
    if provisioned && empty { return Err("state directory holds no state".into()); }
    Ok(path)
}
macro_rules! report {
    ($($args:tt)*) => {
        if std::env::args_os().nth(2).as_deref().and_then(std::ffi::OsStr::to_str)
            .is_some_and(|m| matches!(m, "--native-v2-session" | "--native-verify-state" | "--native-offline-check")) {
            eprintln!($($args)*);
        } else {
            println!($($args)*);
        }
    };
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    if probe_cli::dispatch()? { return Ok(()); }
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
    // Modes that act on a state directory claimed by the supervisor.
    let claimed = matches!(mode, Some("--native-v2-session" | "--native-verify-state" | "--native-offline-check"));
    if mode == Some("--initialize-core") || mode == Some("--configure-state") || mode == Some("--native-abi-preflight") || claimed {
        // All calls are explicitly opt-in. Only --native-v2-session handles
        // provisioning material, and only from its supervised coordinator.
        let init: sysv64_type!(fn(*const u8) -> i32) = unsafe {
            std::mem::transmute(lib.get_symbol("kq56gsgHG6").ok_or("missing CoreADI initializer")?)
        };
        let native_dir = CString::new(dir.to_str().ok_or("non-UTF8 native directory")?)?;
        eprintln!("Initializing CoreADI from {} (no provisioning)", dir.display());
        let status = init(native_dir.as_ptr().cast());
        report!("CoreADI initialization status: {status}");
        if status != 0 { return Err(format!("CoreADI initialization failed: {status}").into()); }
        report!("PASS: CoreADI initialized; no provisioning executed");

        if mode == Some("--configure-state") || mode == Some("--native-abi-preflight") || claimed {
            // Use an absolute, private test directory. Never reuse production ADI state.
            let state = if claimed {
                claimed_state_dir(std::env::args_os().nth(3), mode == Some("--native-verify-state"))?
            } else {
                let state = root.join("probe-state");
                std::fs::create_dir_all(&state)?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700))?;
                }
                state
            };
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
            let operator_identifier = if claimed {
                let value = std::env::args().nth(4).ok_or("missing Android identifier")?;
                if value.is_empty() || value.len() > 256 || value.bytes().any(|b| b == 0 || b.is_ascii_control()) {
                    return Err("invalid Android identifier".into());
                }
                if std::env::args_os().nth(5).is_some() { return Err("unexpected native arguments".into()); }
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
            if mode == Some("--native-abi-preflight") || claimed {
                let native = native_session::NativeFunctions::resolve(&lib)?;
                match mode {
                    Some("--native-v2-session") => {
                        // A claimed directory must be fresh to CoreADI as well.
                        if native.is_provisioned(DS_ID)? { return Err("state already provisioned".into()); }
                        offline_v2_bridge::run_native_v2(
                            &native, &state.join("adi.pb"),
                            &mut std::io::stdin().lock(), &mut std::io::stdout().lock(),
                        )?;
                        return Ok(());
                    }
                    Some("--native-verify-state") => {
                        if !native.is_provisioned(DS_ID)? { return Err("state is not provisioned".into()); }
                        native.check_otp(DS_ID)?;
                        println!("PASS: native state reports provisioned and generated one OTP (contents withheld)");
                        return Ok(());
                    }
                    Some("--native-offline-check") => {
                        // Offline ABI check of the two state queries: an empty
                        // directory must read as unprovisioned and refuse OTPs.
                        if native.is_provisioned(DS_ID)? { return Err("empty state reported provisioned".into()); }
                        if native.check_otp(DS_ID).is_ok() { return Err("unprovisioned state generated an OTP".into()); }
                        println!("PASS: empty state reports NOT_PROVISIONED ({}) and refuses OTPs; no Apple contact",
                            native_session::NOT_PROVISIONED);
                        return Ok(());
                    }
                    _ => {}
                }
                report!("PASS: typed native Start/End/Destroy/Dispose functions bound; no provisioning executed");
            }
        }
    }
    report!("PASS: native StoreServicesCore loaded and required symbols resolved; no provisioning executed");
    Ok(())
}
