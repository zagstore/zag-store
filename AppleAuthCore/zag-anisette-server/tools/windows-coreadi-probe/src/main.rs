//! Offline prototype: runs Apple's Windows CoreADI64.dll (from the iTunes
//! for Windows x64 installer) natively on Linux x86_64, without Wine.
//!
//!   zag-windows-coreadi-probe <CoreADI64.dll> <private-root> [--trace]
//!
//! As the server's worker (see worker.rs) it is run as
//!   zag-windows-coreadi-probe <runtime> --native-{offline-check,headers,v2-session} <work dir> <identifier hex>
//!
//! It maps the DLL, binds its imports to the host layer in `win.rs`, runs
//! its CRT initialisation (DllMain), then calls the ADI dispatcher on an
//! empty private machine: initialize, is-provisioned, an OTP request and a
//! provisioning start with bytes Apple never issued. Nothing contacts the
//! network; no ADI material is printed, only status codes and lengths.
#[cfg(not(all(target_os = "linux", target_arch = "x86_64")))]
compile_error!("the Windows CoreADI prototype runs on Linux x86_64 only");

mod adi;
mod pe;
mod state;
mod win;
mod worker;
#[path = "../../../adi_worker_wire_v2.rs"]
mod wire;

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

/// The GrandSlam ds_id for anonymous (machine-only) requests.
const ANONYMOUS_DS_ID: i64 = -2;

fn private_root(path: &Path) -> Result<PathBuf, String> {
    let m = fs::symlink_metadata(path).map_err(|_| "private root missing".to_string())?;
    if !m.is_dir() || m.permissions().mode() & 0o077 != 0 || m.uid() != unsafe { libc::geteuid() } {
        return Err("private root must be a directory owned by this user with mode 0700".into());
    }
    fs::canonicalize(path).map_err(|e| e.to_string())
}

/// Loads, or creates once, the synthetic test machine for this root:
/// `volume_serial=<hex>` and `reg:<key>\<value>=<text>` lines.
fn machine(root: &Path) -> Result<win::Machine, String> {
    let path = root.join("machine.txt");
    if !path.exists() {
        let mut serial = [0u8; 4];
        if unsafe { libc::getrandom(serial.as_mut_ptr().cast(), 4, 0) } != 4 { return Err("getrandom failed".into()); }
        let text = format!("volume_serial={:08X}\n", u32::from_le_bytes(serial));
        fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)
            .and_then(|mut f| std::io::Write::write_all(&mut f, text.as_bytes())).map_err(|e| e.to_string())?;
    }
    let text = fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let mut volume_serial = None;
    let mut registry = BTreeMap::new();
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        if let Some(hex) = line.strip_prefix("volume_serial=") {
            volume_serial = Some(u32::from_str_radix(hex.trim(), 16).map_err(|_| "bad volume_serial")?);
        } else if let Some((key, value)) = line.strip_prefix("reg:").and_then(|r| r.split_once('=')) {
            registry.insert(key.to_owned(), value.to_owned());
        } else {
            return Err("unrecognised machine.txt line".into());
        }
    }
    Ok(win::Machine { volume_serial: volume_serial.ok_or("machine.txt has no volume_serial")?, registry })
}

fn run(dll: PathBuf, root: PathBuf) -> Result<bool, String> {
    let bytes = fs::read(&dll).map_err(|e| format!("cannot read the DLL: {e}"))?;
    win::install_thread_environment().map_err(|e| format!("thread environment: {e}"))?;
    let image = pe::Image::load(&bytes, &win::resolve).map_err(|e| format!("load: {e}"))?;
    win::set_module_base(image.base);
    println!("PASS load: {} bytes mapped at {:#x}; relocated, {} imports bound to host functions; exports {:?}",
        image.size, image.base, "all", image.export_names());

    type DllMain = unsafe extern "win64" fn(usize, u32, usize) -> i32;
    let dll_main: DllMain = unsafe { std::mem::transmute(image.entry) };
    let attached = unsafe { dll_main(image.base, 1 /* DLL_PROCESS_ATTACH */, 0) };
    if attached == 0 { return Err("DllMain(DLL_PROCESS_ATTACH) returned FALSE".into()); }
    println!("PASS DllMain: CRT initialised (returned {attached})");

    let dispatcher = image.export("vdfut768ig").ok_or("no vdfut768ig export")?;
    let adi = unsafe { adi::CoreAdi::new(dispatcher) };
    let mut ok = true;
    let mut check = |name: &str, pass: bool, detail: String| {
        println!("{} {name}: {detail}", if pass { "PASS" } else { "FAIL" });
        ok &= pass;
    };

    // Initialize and tear-down report a non-negative count on success.
    let s = adi.initialize();
    check("initialize", s.code() >= 0, format!("{s:?}"));
    let s = adi.is_machine_provisioned(ANONYMOUS_DS_ID);
    check("is_machine_provisioned (empty machine)", s.code() == adi::NOT_PROVISIONED,
        format!("{s:?}, expected {} (not provisioned)", adi::NOT_PROVISIONED));
    let (s, otp) = adi.request_otp(ANONYMOUS_DS_ID);
    check("request_otp (empty machine)", s.code() != 0 && otp.is_none(),
        format!("{s:?}; an unprovisioned machine must refuse an OTP"));
    let spim = b"zag offline test: bytes Apple never issued";
    let (s, cpim) = adi.start_provisioning(ANONYMOUS_DS_ID, spim);
    check("start_provisioning (non-Apple SPIM)", s.code() != 0 && cpim.is_none(),
        format!("{s:?}; a SPIM Apple never issued must be rejected"));
    let s = adi.is_machine_provisioned(ANONYMOUS_DS_ID);
    check("is_machine_provisioned (after rejected start)", s.code() == adi::NOT_PROVISIONED, format!("{s:?}"));
    let s = adi.tear_down();
    check("tear_down", s.code() >= 0, format!("{s:?}"));

    println!("== host effects (synthetic machine; no Apple material)");
    for e in win::events() { println!("  {e}"); }
    println!("== Windows API calls");
    let calls: Vec<String> = win::calls().into_iter().map(|(n, c)| format!("{n}x{c}")).collect();
    println!("  {}", calls.join(" "));
    println!("== private root files");
    let mut stack = vec![root.clone()];
    while let Some(dir) = stack.pop() {
        for e in fs::read_dir(&dir).map_err(|e| e.to_string())?.flatten() {
            let m = e.metadata().map_err(|e| e.to_string())?;
            if m.is_dir() { stack.push(e.path()); continue; }
            println!("  {} {:o} {} bytes", e.path().strip_prefix(&root).unwrap().display(), m.permissions().mode() & 0o777, m.len());
        }
    }
    Ok(ok)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    // The supervised worker modes the anisette server runs.
    if args.get(2).is_some_and(|mode| mode.starts_with("--native-")) {
        return worker::main(&args);
    }
    let trace = args.iter().any(|a| a == "--trace");
    let positional: Vec<&String> = args.iter().skip(1).filter(|a| *a != "--trace").collect();
    let [dll, root] = positional.as_slice() else {
        eprintln!("usage: zag-windows-coreadi-probe <CoreADI64.dll> <private-root> [--trace]");
        return ExitCode::from(2);
    };
    let root = match private_root(Path::new(root)) {
        Ok(r) => r,
        Err(e) => { eprintln!("FAIL: {e}"); return ExitCode::from(2); }
    };
    let machine = match machine(&root) {
        Ok(m) => m,
        Err(e) => { eprintln!("FAIL machine: {e}"); return ExitCode::from(2); }
    };
    win::install(root.clone(), machine, trace);
    let dll = PathBuf::from(dll);
    // CoreADI runs on a dedicated thread whose %gs points at its own TEB.
    let worker = std::thread::Builder::new().name("coreadi".into()).stack_size(16 << 20)
        .spawn(move || run(dll, root)).expect("spawn");
    match worker.join() {
        Ok(Ok(true)) => { println!("RESULT: Windows CoreADI ran natively on Linux; empty machine reports NOT_PROVISIONED; no network contact"); ExitCode::SUCCESS }
        Ok(Ok(false)) => { println!("RESULT: FAIL (see above)"); ExitCode::from(1) }
        Ok(Err(e)) => { eprintln!("FAIL: {e}"); ExitCode::from(1) }
        Err(_) => { eprintln!("FAIL: worker panicked"); ExitCode::from(1) }
    }
}
