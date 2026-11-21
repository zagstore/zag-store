//! Experimental offline-only v2 protocol adapter for the real native ADI calls.
//!
//! Not wired into the production worker, listener or probe executable.
//! The caller must provide an isolated, trusted state file location and
//! an already initialized/configured native provider. No network requests.
#[path = "../../../adi_worker_wire_v2.rs"]
pub(crate) mod wire;

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
    let file: File = options.open(state_file)?;
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

/// Runs two phases against one handle. A handle is dropped on every error,
/// including malformed Finish, missing state and disconnection. The release
/// worker does not invoke this function.
fn run_two_phase<R, W, Handle, Start, Finish>(
    state_file: &Path,
    input: &mut R,
    output: &mut W,
    start: Start,
    finish: Finish,
) -> io::Result<()>
where
    R: Read,
    W: Write,
    Start: FnOnce(i64, &[u8]) -> io::Result<(Handle, Vec<u8>)>,
    Finish: FnOnce(&mut Handle, &[u8], &[u8]) -> io::Result<()>,
{
    state_must_be_new(state_file)?;
    let first = read_frame(input)?;
    let wire::Request::Start { identifier, spim } =
        wire::decode_request(&first).map_err(|_| invalid("invalid Start request"))?
    else { return Err(invalid("Start required")); };
    let ds_id = identifier.parse::<i64>().map_err(|_| invalid("invalid ds_id"))?;
    let (mut session, cpim) = start(ds_id, &spim)?;
    write_response(output, &wire::Response::Started(cpim))?;

    let second = read_frame(input)?;
    let wire::Request::Finish { ptm, tk } =
        wire::decode_request(&second).map_err(|_| invalid("invalid Finish request"))?
    else { return Err(invalid("Finish required")); };
    finish(&mut session, &ptm, &tk)?;
    // The supervisor closes stdin only after receiving Finished. Waiting for
    // EOF here would deadlock the split-phase request/response protocol.
    // The session is terminal after this response; the child then exits.
    let state = read_new_state(state_file)?;
    write_response(output, &wire::Response::Finished(state))
}

/// A single process and native provider own both phases and Destroy.
/// Explicit offline mode only: never connected to the release worker or HTTP
/// listener. SPIM, PTM and TK must come from a separately reviewed client.
#[allow(dead_code)]
pub fn run_native_v2<R: Read, W: Write>(
    native: &NativeFunctions<'_>,
    state_file: &Path,
    input: &mut R,
    output: &mut W,
) -> io::Result<()> {
    run_two_phase(state_file, input, output,
        |ds_id, spim| native.start(ds_id, spim),
        |session, ptm, tk| session.finish(ptm, tk))
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
    fn request_frame(request: &wire::Request) -> Vec<u8> {
        let bytes = wire::encode_request(request).unwrap();
        let mut framed = (bytes.len() as u32).to_be_bytes().to_vec();
        framed.extend_from_slice(&bytes);
        framed
    }

    fn fresh_test_state() -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "zag-native-session-{}-{}",
            std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&dir).unwrap();
        dir.join("adi.pb")
    }

    struct CountedHandle(std::rc::Rc<std::cell::Cell<u32>>);
    impl Drop for CountedHandle {
        fn drop(&mut self) { self.0.set(self.0.get() + 1); }
    }

    #[test]
    fn finish_response_does_not_wait_for_stdin_eof() {
        struct NoEofReader<'a>(&'a [u8]);
        impl Read for NoEofReader<'_> {
            fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
                if self.0.is_empty() {
                    return Err(io::Error::new(io::ErrorKind::WouldBlock,
                        "stdin remains open while supervisor awaits Finished"));
                }
                self.0.read(buf)
            }
        }
        let state = fresh_test_state();
        let mut input = request_frame(&wire::Request::Start {
            identifier: "-2".into(), spim: vec![1],
        });
        input.extend(request_frame(&wire::Request::Finish {
            ptm: vec![2], tk: vec![3],
        }));
        let mut reader = NoEofReader(&input);
        let mut output = Vec::new();
        let state_for_finish = state.clone();
        assert!(run_two_phase(&state, &mut reader, &mut output,
            |_, _| Ok(((), vec![4])),
            move |_, _, _| fs::write(&state_for_finish, [5]),
        ).is_ok());
        let mut replies = output.as_slice();
        let first = wire::Request::Start { identifier: "-2".into(), spim: vec![1] };
        let second = wire::Request::Finish { ptm: vec![2], tk: vec![3] };
        assert_eq!(wire::decode_response(&read_frame(&mut replies).unwrap(), &first),
            Ok(wire::Response::Started(vec![4])));
        assert_eq!(wire::decode_response(&read_frame(&mut replies).unwrap(), &second),
            Ok(wire::Response::Finished(vec![5])));
        fs::remove_file(&state).unwrap();
        fs::remove_dir(state.parent().unwrap()).unwrap();
    }

    #[test]
    fn lifecycle_start_finish_exports_only_new_state_and_destroys_handle() {
        let state = fresh_test_state();
        let destroyed = std::rc::Rc::new(std::cell::Cell::new(0));
        let mut input = request_frame(&wire::Request::Start {
            identifier: "-2".into(), spim: vec![1, 2],
        });
        input.extend(request_frame(&wire::Request::Finish {
            ptm: vec![3], tk: vec![4, 5],
        }));
        let mut output = Vec::new();
        let destroyed_at_start = destroyed.clone();
        assert!(run_two_phase(&state, &mut input.as_slice(), &mut output,
            move |ds_id, spim| {
                assert_eq!(ds_id, -2);
                assert_eq!(spim, [1, 2]);
                Ok((CountedHandle(destroyed_at_start), vec![0, 255]))
            },
            |_handle, ptm, tk| {
                assert_eq!(ptm, [3]);
                assert_eq!(tk, [4, 5]);
                fs::write(&state, [0, 88, 255])
            },
        ).is_ok());
        assert_eq!(destroyed.get(), 1);
        let mut replies = output.as_slice();
        let start = wire::Request::Start { identifier: "-2".into(), spim: vec![1, 2] };
        let finish = wire::Request::Finish { ptm: vec![3], tk: vec![4, 5] };
        assert_eq!(wire::decode_response(&read_frame(&mut replies).unwrap(), &start),
                   Ok(wire::Response::Started(vec![0, 255])));
        assert_eq!(wire::decode_response(&read_frame(&mut replies).unwrap(), &finish),
                   Ok(wire::Response::Finished(vec![0, 88, 255])));
        assert!(replies.is_empty());
        fs::remove_file(&state).unwrap();
        fs::remove_dir(state.parent().unwrap()).unwrap();
    }

    #[test]
    fn malformed_finish_destroys_handle_and_never_reports_finished() {
        let state = fresh_test_state();
        let destroyed = std::rc::Rc::new(std::cell::Cell::new(0));
        let mut input = request_frame(&wire::Request::Start {
            identifier: "-2".into(), spim: vec![1],
        });
        input.extend(request_frame(&wire::Request::Start {
            identifier: "-2".into(), spim: vec![2],
        }));
        let mut output = Vec::new();
        let destroyed_at_start = destroyed.clone();
        assert!(run_two_phase(&state, &mut input.as_slice(), &mut output,
            move |_, _| Ok((CountedHandle(destroyed_at_start), vec![9])),
            |_, _, _| panic!("Finish must not run for a second Start"),
        ).is_err());
        assert_eq!(destroyed.get(), 1);
        let mut replies = output.as_slice();
        let start = wire::Request::Start { identifier: "-2".into(), spim: vec![1] };
        assert_eq!(wire::decode_response(&read_frame(&mut replies).unwrap(), &start),
                   Ok(wire::Response::Started(vec![9])));
        assert!(replies.is_empty());
        fs::remove_dir(state.parent().unwrap()).unwrap();
    }

    #[test]
    fn missing_native_state_destroys_handle_and_never_reports_finished() {
        let state = fresh_test_state();
        let destroyed = std::rc::Rc::new(std::cell::Cell::new(0));
        let mut input = request_frame(&wire::Request::Start {
            identifier: "-2".into(), spim: vec![1],
        });
        input.extend(request_frame(&wire::Request::Finish {
            ptm: vec![3], tk: vec![4],
        }));
        let mut output = Vec::new();
        let destroyed_at_start = destroyed.clone();
        assert!(run_two_phase(&state, &mut input.as_slice(), &mut output,
            move |_, _| Ok((CountedHandle(destroyed_at_start), vec![9])),
            |_, _, _| Ok(()),
        ).is_err());
        assert_eq!(destroyed.get(), 1);
        let mut replies = output.as_slice();
        let start = wire::Request::Start { identifier: "-2".into(), spim: vec![1] };
        assert!(matches!(wire::decode_response(&read_frame(&mut replies).unwrap(), &start),
                         Ok(wire::Response::Started(_))));
        assert!(replies.is_empty());
        fs::remove_dir(state.parent().unwrap()).unwrap();
    }

    #[test]
    fn stale_state_refused_before_native_start() {
        let state = fresh_test_state();
        fs::write(&state, [1, 2, 3]).unwrap();
        let input = request_frame(&wire::Request::Start {
            identifier: "-2".into(), spim: vec![1],
        });
        let mut output = Vec::new();
        assert!(run_two_phase(
            &state, &mut input.as_slice(), &mut output,
            |_, _| -> io::Result<((), Vec<u8>)> { panic!("native Start must not run") },
            |_, _, _| -> io::Result<()> { panic!("native Finish must not run") },
        ).is_err());
        assert!(output.is_empty());
        fs::remove_file(&state).unwrap();
        fs::remove_dir(state.parent().unwrap()).unwrap();
    }

}
