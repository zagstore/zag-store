//! The supervised worker modes the anisette server runs for the Windows
//! backend (`ZAG_ANISETTE_NATIVE_PLATFORM=windows`):
//!
//!   <worker> <runtime> <mode> <work dir> <identifier hex>
//!
//! `<runtime>/CoreADI64.dll` is the library; `<work dir>` is the private
//! per-request directory the server creates and removes (`C:\` maps to
//! `<work dir>/c`); the identifier is the client's 16 bytes in lower-case
//! hex. The modes and their output are the Android worker's:
//!
//! * `--native-offline-check`: an empty machine must report NOT_PROVISIONED
//!   and refuse an OTP; prints one PASS line.
//! * `--native-headers`: loads the client's state (`<work dir>/adi.pb`, a
//!   state.rs container) and replies one `headers`/`not_provisioned`/
//!   `native_failure` frame.
//! * `--native-v2-session`: Start then Finish on stdin/stdout frames; on
//!   success writes the packed state to `<work dir>/adi.pb` and returns it.
//!
//! Nothing is logged: stderr is discarded by the server, stdout carries only
//! the protocol. The process makes no network calls.
use crate::adi::{self, CoreAdi};
use crate::{pe, state, win, wire};
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const LIBRARY: &str = "CoreADI64.dll";
/// The fixed, account-independent ds_id of machine provisioning.
const DS_ID: i64 = -2;

/// The synthetic machine for a client: a pure function of its identifier,
/// so every worker for that client sees the same machine and a state stays
/// loadable across worker restarts. No registry values are defined: CoreADI
/// queried none in any offline mode (see WINDOWS_NATIVE_BACKEND.md).
pub fn machine_for(identifier: &[u8; 16]) -> win::Machine {
    win::Machine {
        volume_serial: u32::from_be_bytes(identifier[..4].try_into().unwrap()),
        registry: Default::default(),
    }
}

fn parse_identifier(text: &str) -> Option<[u8; 16]> {
    if text.len() != 32 || !text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) { return None; }
    let mut out = [0u8; 16];
    for (i, byte) in out.iter_mut().enumerate() { *byte = u8::from_str_radix(&text[2 * i..2 * i + 2], 16).ok()?; }
    Some(out)
}

fn private_dir(path: &Path) -> bool {
    path.is_absolute() && fs::symlink_metadata(path).is_ok_and(|m|
        m.is_dir() && m.mode() & 0o077 == 0 && m.uid() == unsafe { libc::geteuid() })
}

pub fn main(args: &[String]) -> ExitCode {
    let [_, runtime, mode, dir, identity] = args else { return ExitCode::from(2) };
    let library = PathBuf::from(runtime).join(LIBRARY);
    let dir = PathBuf::from(dir);
    let Some(identifier) = parse_identifier(identity) else { return ExitCode::from(2) };
    if !Path::new(runtime).is_absolute() || !fs::symlink_metadata(&library).is_ok_and(|m| m.is_file()) || !private_dir(&dir) {
        return ExitCode::from(2);
    }
    let mode = mode.clone();
    win::install(dir.clone(), machine_for(&identifier), false);
    // CoreADI runs on a dedicated thread whose %gs points at its own TEB.
    let worker = std::thread::Builder::new().name("coreadi".into()).stack_size(16 << 20)
        .spawn(move || match mode.as_str() {
            "--native-offline-check" => offline_check(&library),
            "--native-headers" => headers(&library, &dir),
            "--native-v2-session" => session(&library, &dir),
            _ => 2,
        });
    match worker.map(|w| w.join()) {
        Ok(Ok(code)) => ExitCode::from(code),
        _ => ExitCode::from(1),
    }
}

/// Maps the library, runs its CRT initialisation and ADI initialize.
fn load(library: &Path) -> Option<CoreAdi> {
    let bytes = fs::read(library).ok()?;
    win::install_thread_environment().ok()?;
    let image = pe::Image::load(&bytes, &win::resolve).ok()?;
    win::set_module_base(image.base);
    type DllMain = unsafe extern "win64" fn(usize, u32, usize) -> i32;
    let dll_main: DllMain = unsafe { std::mem::transmute(image.entry) };
    if unsafe { dll_main(image.base, 1, 0) } == 0 { return None; }
    let adi = unsafe { CoreAdi::new(image.export("vdfut768ig")?) };
    (adi.initialize().code() >= 0).then_some(adi)
}

fn offline_check(library: &Path) -> u8 {
    let Some(adi) = load(library) else { return 1 };
    let empty = adi.is_machine_provisioned(DS_ID).code() == adi::NOT_PROVISIONED;
    let refused = adi.request_otp(DS_ID).1.is_none();
    if !(empty && refused) { return 1; }
    println!("PASS: empty state reports NOT_PROVISIONED (-45061) and refuses OTPs; no Apple contact");
    0
}

fn headers(library: &Path, dir: &Path) -> u8 {
    let reply = (|| {
        let packed = read_limited(&dir.join("adi.pb"), state::MAX_STATE).ok()?;
        state::unpack(&packed, &state::adi_dir(dir)).ok()?;
        let adi = load(library)?;
        Some(match adi.is_machine_provisioned(DS_ID).code() {
            adi::NOT_PROVISIONED => wire::Headers::NotProvisioned,
            0 => match adi.request_otp(DS_ID) {
                (_, Some((machine_id, otp))) => wire::Headers::Ready { machine_id, otp },
                _ => wire::Headers::NativeFailure,
            },
            _ => wire::Headers::NativeFailure,
        })
    })().unwrap_or(wire::Headers::NativeFailure);
    match wire::encode_headers(&reply).ok().map(|frame| write_frame(&frame)) {
        Some(Ok(())) => 0,
        _ => 1,
    }
}

fn session(library: &Path, dir: &Path) -> u8 {
    let failed = || { let _ = wire::encode_response(&wire::Response::Failed).map(|f| write_frame(&f)); 1 };
    let Some(wire::Request::Start { identifier, spim }) = read_frame().ok().and_then(|f| wire::decode_request(&f).ok()) else { return failed() };
    if identifier.parse::<i64>() != Ok(DS_ID) { return failed(); }
    let Some(adi) = load(library) else { return failed() };
    let Some((cpim, session)) = adi.start_provisioning(DS_ID, &spim).1 else { return failed() };
    let Ok(frame) = wire::encode_response(&wire::Response::Started(cpim)) else { return failed() };
    if write_frame(&frame).is_err() { return 1; }

    let Some(wire::Request::Finish { ptm, tk }) = read_frame().ok().and_then(|f| wire::decode_request(&f).ok()) else { return failed() };
    if adi.end_provisioning(session, &ptm, &tk).code() != 0 { return failed(); }
    let Ok(packed) = state::pack(&state::adi_dir(dir)) else { return failed() };
    let written = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(dir.join("adi.pb"))
        .and_then(|mut f| f.write_all(&packed));
    if written.is_err() { return failed(); }
    match wire::encode_response(&wire::Response::Finished(packed)).ok().map(|f| write_frame(&f)) {
        Some(Ok(())) => 0,
        _ => 1,
    }
}

fn read_limited(path: &Path, max: usize) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    fs::File::open(path)?.take(max as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > max { return Err(io::Error::new(io::ErrorKind::InvalidData, "state too large")); }
    Ok(bytes)
}

fn read_frame() -> io::Result<Vec<u8>> {
    let mut stdin = io::stdin().lock();
    let mut length = [0u8; 4];
    stdin.read_exact(&mut length)?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > wire::MAX_FRAME { return Err(io::Error::new(io::ErrorKind::InvalidData, "frame size")); }
    let mut frame = vec![0u8; length];
    stdin.read_exact(&mut frame)?;
    Ok(frame)
}

fn write_frame(frame: &[u8]) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    stdout.write_all(&(frame.len() as u32).to_be_bytes())?;
    stdout.write_all(frame)?;
    stdout.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_and_machines_are_canonical_and_stable() {
        let id = parse_identifier("000102030405060708090a0b0c0d0e0f").unwrap();
        assert_eq!(id[15], 15);
        assert!(parse_identifier("000102030405060708090A0B0C0D0E0F").is_none());
        assert!(parse_identifier("0001").is_none());
        assert_eq!(machine_for(&id).volume_serial, 0x0001_0203);
        assert_eq!(machine_for(&id).volume_serial, machine_for(&id).volume_serial);
        assert!(machine_for(&id).registry.is_empty());
    }
}
