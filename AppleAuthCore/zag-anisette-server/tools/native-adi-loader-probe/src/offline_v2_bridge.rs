//! Experimental offline-only v2 protocol adapter for the real native ADI calls.
//!
//! Not wired into the production worker, listener or probe executable.
//! The caller must provide an isolated, trusted state file location and
//! an already initialized/configured native provider. No network requests.
#[path = "../../../adi_worker_wire_v2.rs"]
mod wire;

use crate::native_session::NativeFunctions;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::Path;

fn invalid(detail: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, detail)
}
fn read_frame<R: Read>(input: &mut R) -> io::Result<Vec<u8>> {
    let mut header = [0u8; 4];
    input.read_exact(&mut header)?;
    let len = u32::from_be_bytes(header) as usize;
    if len == 0 || len > wire::MAX_FRAME { return Err(invalid("invalid frame length")); }
    let mut payload = vec![0u8; len];
    input.read_exact(&mut payload)?;
    Ok(payload)
}
fn write_response<W: Write>(output: &mut W, response: &wire::Response) -> io::Result<()> {
    let payload = wire::encode_response(response).map_err(|_| invalid("invalid response"))?;
    if payload.len() > wire::MAX_FRAME { return Err(invalid("response too large")); }
    output.write_all(&(payload.len() as u32).to_be_bytes())?;
    output.write_all(&payload)?;
    output.flush()
}
fn no_extra_input<R: Read>(input: &mut R) -> io::Result<()> {
    let mut byte = [0u8; 1];
    if input.read(&mut byte)? != 0 { return Err(invalid("trailing input")); }
    Ok(())
}

/// Refuse a preexisting state file: stale or unrelated ADI bytes must never
/// be returned as the result of the current provisioning session.
fn state_must_be_new(state_file: &Path) -> io::Result<()> {
    match fs::symlink_metadata(state_file) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
        Ok(_) => Err(invalid("preexisting ADI state file")),
    }
}

/// Export the specific state file produced by CoreADI, without following a
/// final-path symlink. This is not a format validator for Apple's private data.
fn read_new_state(state_file: &Path) -> io::Result<Vec<u8>> {
    #[cfg(unix)]
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW);
    let mut file: File = options.open(state_file)?;
    let meta = file.metadata()?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > wire::MAX_FRAME as u64 / 4 {
        return Err(invalid("invalid native state file"));
    }
    let mut bytes = Vec::with_capacity(meta.len() as usize);
    file.take(wire::MAX_FRAME as u64 / 4 + 1).read_to_end(&mut bytes)?;
    if bytes.is_empty() || bytes.len() > (wire::MAX_FRAME - 512) / 4 {
        return Err(invalid("invalid native state material"));
    }
    Ok(bytes)
}

/// A single process and native provider must own both phases and Destroy.
/// This is intentionally not reachable from any release command-line mode.
/// Real SPIM, PTM and TK must be supplied by an independently verified client.
#[allow(dead_code)]
pub fn run_native_v2<R: Read, W: Write>(
    native: &NativeFunctions<'_>,
    state_file: &Path,
    input: &mut R,
    output: &mut W,
) -> io::Result<()> {
    state_must_be_new(state_file)?;
    let first = read_frame(input)?;
    let wire::Request::Start { identifier, spim } =
        wire::decode_request(&first).map_err(|_| invalid("invalid Start request"))?
    else { return Err(invalid("Start required")); };
    let ds_id = identifier.parse::<i64>().map_err(|_| invalid("invalid ds_id"))?;
    let (mut session, cpim) = native.start(ds_id, &spim)?;
    write_response(output, &wire::Response::Started(cpim))?;

    let second = read_frame(input)?;
    let wire::Request::Finish { ptm, tk } =
        wire::decode_request(&second).map_err(|_| invalid("invalid Finish request"))?
    else { return Err(invalid("Finish required")); };
    session.finish(&ptm, &tk)?;
    no_extra_input(input)?;
    let state = read_new_state(state_file)?;
    write_response(output, &wire::Response::Finished(state))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn v2_framing_round_trip_is_exact() {
        let request = wire::Request::Start { identifier: "-2".into(), spim: vec![0, 255] };
        let payload = wire::encode_request(&request).unwrap();
        let mut framed = (payload.len() as u32).to_be_bytes().to_vec();
        framed.extend_from_slice(&payload);
        assert_eq!(read_frame(&mut framed.as_slice()).unwrap(), payload);
        let mut out = Vec::new();
        write_response(&mut out, &wire::Response::Started(vec![0, 255])).unwrap();
        assert_eq!(wire::decode_response(&read_frame(&mut out.as_slice()).unwrap(), &request),
                   Ok(wire::Response::Started(vec![0, 255])));
    }
    #[test]
    fn rejects_oversized_and_empty_frames() {
        for len in [0u32, (wire::MAX_FRAME + 1) as u32] {
            assert!(read_frame(&mut len.to_be_bytes().as_slice()).is_err());
        }
    }
    #[test]
    fn rejects_missing_and_preexisting_state() {
        let root = std::env::temp_dir().join(format!("zag-native-state-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let state = root.join("adi.pb");
        let _ = fs::remove_file(&state);
        assert!(state_must_be_new(&state).is_ok());
        assert!(read_new_state(&state).is_err());
        fs::write(&state, [0x01, 0x02]).unwrap();
        assert!(state_must_be_new(&state).is_err());
        assert_eq!(read_new_state(&state).unwrap(), vec![1, 2]);
        fs::remove_file(&state).unwrap();
        fs::remove_dir(&root).unwrap();
    }
}
