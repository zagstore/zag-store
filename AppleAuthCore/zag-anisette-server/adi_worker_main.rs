//! Standalone offline ADI worker skeleton. No native ADI library is loaded.
//! One bounded framed request in, one generic unavailable response out.
use std::io::{self, Read, Write};

const MAX_MESSAGE_BYTES: usize = 64 * 1024;
const ERROR_RESPONSE: &[u8] = br#"{"version":1,"type":"error","code":"backend_unavailable"}"#;

fn read_request<R: Read>(reader: &mut R) -> io::Result<Vec<u8>> {
    let mut header = [0u8; 4];
    reader.read_exact(&mut header)?;
    let len = u32::from_be_bytes(header) as usize;
    if len == 0 || len > MAX_MESSAGE_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid frame length"));
    }
    let mut payload = vec![0; len];
    reader.read_exact(&mut payload)?;
    let mut extra = [0u8; 1];
    if reader.read(&mut extra)? != 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "trailing input"));
    }
    let value: serde_json::Value = serde_json::from_slice(&payload)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid JSON"))?;
    let obj = value.as_object().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid object"))?;
    if obj.get("version").and_then(serde_json::Value::as_u64) != Some(1) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid version"));
    }
    let required = match obj.get("type").and_then(serde_json::Value::as_str) {
        Some("start") if obj.len() == 4 => ["identifier", "spim"],
        Some("finish") if obj.len() == 4 => ["ptm", "tk"],
        _ => return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid request type")),
    };
    for key in required {
        let valid = obj.get(key).and_then(serde_json::Value::as_str)
            .is_some_and(|s| !s.is_empty() && s.len() <= MAX_MESSAGE_BYTES && !s.chars().any(char::is_control));
        if !valid {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid request field"));
        }
    }
    Ok(payload)
}

#[derive(Debug, PartialEq, Eq)]
enum NativeRequest {
    Start { identifier: String, spim: String },
    Finish { ptm: String, tk: String },
}

fn parse_request(bytes: &[u8]) -> io::Result<NativeRequest> {
    let value: serde_json::Value = serde_json::from_slice(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid request"))?;
    let read = |name: &str| -> io::Result<String> {
        value.get(name).and_then(serde_json::Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid field"))
    };
    match value.get("type").and_then(serde_json::Value::as_str) {
        Some("start") => Ok(NativeRequest::Start {
            identifier: read("identifier")?, spim: read("spim")?,
        }),
        Some("finish") => Ok(NativeRequest::Finish {
            ptm: read("ptm")?, tk: read("tk")?,
        }),
        _ => Err(io::Error::new(io::ErrorKind::InvalidData, "invalid type")),
    }
}

trait NativeAdiBackend {
    fn execute(&mut self, request: NativeRequest) -> io::Result<()>;
}

/// Explicitly disabled until a separately reviewed native implementation is
/// available. Never returns cpim or adi_pb, including for valid requests.
struct DisabledNativeAdiBackend;
impl NativeAdiBackend for DisabledNativeAdiBackend {
    fn execute(&mut self, _request: NativeRequest) -> io::Result<()> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "backend unavailable"))
    }
}

/// Session-owned native handle boundary. No native library is linked:
/// the disabled implementation cannot create a session or emit ADI material.
#[derive(Debug, PartialEq, Eq)]
enum NativeSessionState { Ready, Started, Closed }

struct NativeSession<B: NativeAdiBackend> {
    backend: B,
    state: NativeSessionState,
}
impl<B: NativeAdiBackend> NativeSession<B> {
    fn new(backend: B) -> Self {
        Self { backend, state: NativeSessionState::Ready }
    }
    fn execute(&mut self, request: NativeRequest) -> io::Result<()> {
        let permitted = matches!(
            (&self.state, &request),
            (NativeSessionState::Ready, NativeRequest::Start { .. })
                | (NativeSessionState::Started, NativeRequest::Finish { .. })
        );
        if !permitted {
            self.state = NativeSessionState::Closed;
            return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid native phase"));
        }
        let next = match request {
            NativeRequest::Start { .. } => NativeSessionState::Started,
            NativeRequest::Finish { .. } => NativeSessionState::Closed,
        };
        // Any native failure closes the session permanently; never retry
        // against a potentially half-initialized native provider.
        match self.backend.execute(request) {
            Ok(()) => { self.state = next; Ok(()) }
            Err(error) => { self.state = NativeSessionState::Closed; Err(error) }
        }
    }
}

/// Read one bounded frame without requiring EOF, for a future long-lived
/// session worker. This is deliberately separate from the one-shot parser.
#[allow(dead_code)]
fn read_session_request<R: Read>(reader: &mut R) -> io::Result<Option<NativeRequest>> {
    let mut header = [0u8; 4];
    let first = reader.read(&mut header[..1])?;
    if first == 0 { return Ok(None); }
    reader.read_exact(&mut header[1..])?;
    let len = u32::from_be_bytes(header) as usize;
    if len == 0 || len > MAX_MESSAGE_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid frame length"));
    }
    let mut payload = vec![0u8; len];
    reader.read_exact(&mut payload)?;
    // Reuse the strict v1 field allowlist from the one-shot parser without
    // exposing any provisioning data in errors.
    let mut framed = Vec::with_capacity(4 + len);
    framed.extend_from_slice(&header);
    framed.extend_from_slice(&payload);
    let validated = read_request(&mut framed.as_slice())?;
    parse_request(&validated).map(Some)
}

#[allow(dead_code)]
fn write_unavailable<W: Write>(output: &mut W) -> io::Result<()> {
    output.write_all(&(ERROR_RESPONSE.len() as u32).to_be_bytes())?;
    output.write_all(ERROR_RESPONSE)?;
    output.flush()
}

/// Offline-only two-phase worker, using the same typed driver as a future
/// native provider. The only configured provider always fails closed.
fn run_session<R: Read, W: Write>(input: &mut R, output: &mut W) -> io::Result<()> {
    match run_typed_session(input, output, DisabledMaterialBackend) {
        Err(error) if error.kind() == io::ErrorKind::Unsupported => write_unavailable(output),
        result => result,
    }
}

/// Typed output contract for an eventual reviewed native backend. The release
/// worker still uses the disabled backend and cannot generate ADI material.
enum SessionMaterial {
    Started { cpim: String },
    Finished { adi_pb: String },
}

trait StatefulMaterialBackend {
    fn start(&mut self, identifier: &str, spim: &str) -> io::Result<String>;
    fn finish(&mut self, ptm: &str, tk: &str) -> io::Result<String>;
    /// Called on every terminal path, including failure or dropped sessions.
    /// Implementations must make cleanup idempotent.
    fn abort(&mut self) {}
}

/// Owns one native provider instance and requests cleanup on all exit paths.
struct MaterialSession<B: StatefulMaterialBackend>(B);
impl<B: StatefulMaterialBackend> Drop for MaterialSession<B> {
    fn drop(&mut self) { self.0.abort(); }
}

fn write_material<W: Write>(output: &mut W, material: SessionMaterial) -> io::Result<()> {
    let payload = match material {
        SessionMaterial::Started { cpim } =>
            serde_json::json!({"version":1,"type":"started","cpim":cpim}),
        SessionMaterial::Finished { adi_pb } =>
            serde_json::json!({"version":1,"type":"finished","adi_pb":adi_pb}),
    };
    let bytes = serde_json::to_vec(&payload)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "serialization"))?;
    if bytes.len() > MAX_MESSAGE_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "response too large"));
    }
    output.write_all(&(bytes.len() as u32).to_be_bytes())?;
    output.write_all(&bytes)?;
    output.flush()
}

/// Reusable typed session driver. This is not reachable from the release
/// executable until native provider provenance and launch security are reviewed.
fn validate_material(value: &str) -> io::Result<()> {
    if value.is_empty() || value.len() > MAX_MESSAGE_BYTES || value.chars().any(char::is_control) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid provider material"));
    }
    Ok(())
}

fn run_typed_session<R: Read, W: Write, B: StatefulMaterialBackend>(
    input: &mut R, output: &mut W, backend: B,
) -> io::Result<()> {
    let mut backend = MaterialSession(backend);
    let first = read_session_request(input)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "missing Start"))?;
    let NativeRequest::Start { identifier, spim } = first else {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Start required"));
    };
    let cpim = backend.0.start(&identifier, &spim)?;
    validate_material(&cpim)?;
    write_material(output, SessionMaterial::Started { cpim })?;
    let second = read_session_request(input)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "missing Finish"))?;
    let NativeRequest::Finish { ptm, tk } = second else {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Finish required"));
    };
    let adi_pb = backend.0.finish(&ptm, &tk)?;
    validate_material(&adi_pb)?;
    let mut extra = [0u8; 1];
    if input.read(&mut extra)? != 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "extra input"));
    }
    write_material(output, SessionMaterial::Finished { adi_pb })
}

struct DisabledMaterialBackend;
impl StatefulMaterialBackend for DisabledMaterialBackend {
    fn start(&mut self, _: &str, _: &str) -> io::Result<String> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "backend unavailable"))
    }
    fn finish(&mut self, _: &str, _: &str) -> io::Result<String> {
        Err(io::Error::new(io::ErrorKind::Unsupported, "backend unavailable"))
    }
}

/// Drive two phases over one stream with a backend instance retained across
/// both requests. Only tests supply a successful mock backend; the executable
/// continues to use DisabledNativeAdiBackend exclusively.
#[cfg(test)]
fn run_two_phase_test_session<R: Read, W: Write, B: NativeAdiBackend>(
    input: &mut R, output: &mut W, backend: B,
) -> io::Result<()> {
    let mut session = NativeSession::new(backend);
    let start = read_session_request(input)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "missing Start"))?;
    if !matches!(start, NativeRequest::Start { .. }) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Start required"));
    }
    session.execute(start)?;
    let started = br#"{"version":1,"type":"started","cpim":"mock"}"#;
    output.write_all(&(started.len() as u32).to_be_bytes())?;
    output.write_all(started)?;
    output.flush()?;
    let finish = read_session_request(input)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "missing Finish"))?;
    if !matches!(finish, NativeRequest::Finish { .. }) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Finish required"));
    }
    session.execute(finish)?;
    let mut extra = [0u8; 1];
    if input.read(&mut extra)? != 0 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "extra input"));
    }
    let finished = br#"{"version":1,"type":"finished","adi_pb":"mock"}"#;
    output.write_all(&(finished.len() as u32).to_be_bytes())?;
    output.write_all(finished)?;
    output.flush()
}

fn run<R: Read, W: Write>(input: &mut R, output: &mut W) -> io::Result<()> {
    let request = read_request(input)?;
    // Parse into a typed request before invoking a future native backend.
    // The disabled backend must never synthesize provisioning material.
    let request = parse_request(&request)?;
    let _ = NativeSession::new(DisabledNativeAdiBackend).execute(request);
    output.write_all(&(ERROR_RESPONSE.len() as u32).to_be_bytes())?;
    output.write_all(ERROR_RESPONSE)?;
    output.flush()
}

fn main() {
    // Explicit offline session mode is not connected to the HTTP listener.
    // No native backend is loaded in either mode.
    let mut args = std::env::args_os();
    let _executable = args.next();
    let mode = match (args.next(), args.next()) {
        (None, None) => false,
        (Some(flag), None) if flag == "--offline-session" => true,
        _ => std::process::exit(2),
    };
    // Fail closed without emitting secret-bearing diagnostics or stdout text.
    let result = if mode {
        run_session(&mut io::stdin().lock(), &mut io::stdout().lock())
    } else {
        run(&mut io::stdin().lock(), &mut io::stdout().lock())
    };
    if result.is_err() { std::process::exit(1); }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn frame(value: &[u8]) -> Vec<u8> {
        let mut framed = (value.len() as u32).to_be_bytes().to_vec();
        framed.extend_from_slice(value);
        framed
    }
    #[test]
    fn valid_start_and_finish_only_return_unavailable() {
        for request in [
            br#"{"version":1,"type":"start","identifier":"id","spim":"spim"}"#.as_slice(),
            br#"{"version":1,"type":"finish","ptm":"ptm","tk":"tk"}"#,
        ] {
            let mut output = Vec::new();
            assert!(run(&mut frame(request).as_slice(), &mut output).is_ok());
            assert_eq!(output, frame(ERROR_RESPONSE));
        }
    }
    #[test]
    fn worker_binary_process_roundtrip_is_fail_closed() {
        use std::process::{Command, Stdio};
        use std::io::Write as _;
        let executable = std::env::var_os("CARGO_BIN_EXE_zag-adi-worker");
        // Cargo's unit-test runner does not guarantee this variable. The
        // workflow's explicit binary smoke step covers subprocess execution.
        let Some(executable) = executable else { return; };
        let mut child = Command::new(executable)
            .stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        child.stdin.take().unwrap().write_all(&frame(
            br#"{"version":1,"type":"start","identifier":"id","spim":"spim"}"#
        )).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, frame(ERROR_RESPONSE));
    }
    #[cfg(unix)]
    #[test]
    fn rust_session_child_process_uses_same_backend_instance() {
        use std::process::{Command, Stdio};
        let executable = std::env::current_exe().unwrap();
        let mut child = Command::new(executable)
            .arg("--exact").arg("tests::rust_session_child_entry")
            .arg("--ignored").arg("--nocapture")
            .stdin(Stdio::piped()).stdout(Stdio::piped())
            .stderr(Stdio::null()).spawn().unwrap();
        let mut input = frame(br#"{"version":1,"type":"start","identifier":"id","spim":"s"}"#);
        input.extend(frame(br#"{"version":1,"type":"finish","ptm":"p","tk":"t"}"#));
        child.stdin.take().unwrap().write_all(&input).unwrap();
        let result = child.wait_with_output().unwrap();
        assert!(result.status.success());
        // Rust test harness emits text around the child fixture's frames;
        // validate the exact framed protocol subsequence.
        let mut expected = frame(br#"{"version":1,"type":"started","cpim":"mock"}"#);
        expected.extend(frame(br#"{"version":1,"type":"finished","adi_pb":"mock"}"#));
        assert!(result.stdout.windows(expected.len()).any(|w| w == expected));
    }

    #[cfg(unix)]
    #[test]
    #[ignore = "subprocess fixture invoked only by parent test"]
    fn rust_session_child_entry() {
        struct Mock(u8);
        impl NativeAdiBackend for Mock {
            fn execute(&mut self, request: NativeRequest) -> io::Result<()> {
                match request {
                    NativeRequest::Start { .. } if self.0 == 0 => self.0 = 1,
                    NativeRequest::Finish { .. } if self.0 == 1 => self.0 = 2,
                    _ => return Err(io::Error::new(io::ErrorKind::InvalidData, "phase")),
                }
                Ok(())
            }
        }
        run_two_phase_test_session(
            &mut io::stdin().lock(), &mut io::stdout().lock(), Mock(0),
        ).unwrap();
    }
    #[test]
    fn typed_session_cleans_up_after_success_and_finish_failure() {
        use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
        struct Tracked {
            cleaned: Arc<AtomicUsize>,
            fail_finish: bool,
        }
        impl StatefulMaterialBackend for Tracked {
            fn start(&mut self, _: &str, _: &str) -> io::Result<String> {
                Ok("cpim".into())
            }
            fn finish(&mut self, _: &str, _: &str) -> io::Result<String> {
                if self.fail_finish { Err(io::Error::other("finish failure")) }
                else { Ok("adi".into()) }
            }
            fn abort(&mut self) { self.cleaned.fetch_add(1, Ordering::SeqCst); }
        }
        for fail_finish in [false, true] {
            let cleaned = Arc::new(AtomicUsize::new(0));
            let mut input = frame(br#"{"version":1,"type":"start","identifier":"id","spim":"s"}"#);
            input.extend(frame(br#"{"version":1,"type":"finish","ptm":"p","tk":"t"}"#));
            let mut output = Vec::new();
            let result = run_typed_session(
                &mut input.as_slice(), &mut output,
                Tracked { cleaned: cleaned.clone(), fail_finish },
            );
            assert_eq!(result.is_err(), fail_finish);
            assert_eq!(cleaned.load(Ordering::SeqCst), 1);
            assert!(output.windows(b"\"type\":\"started\"".len()).any(|w| w == b"\"type\":\"started\""));
        }
    }

    #[test]
    fn typed_session_cleans_up_after_finish_first() {
        use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
        struct Tracked(Arc<AtomicUsize>);
        impl StatefulMaterialBackend for Tracked {
            fn start(&mut self, _: &str, _: &str) -> io::Result<String> {
                panic!("invalid phase")
            }
            fn finish(&mut self, _: &str, _: &str) -> io::Result<String> {
                panic!("invalid phase")
            }
            fn abort(&mut self) { self.0.fetch_add(1, Ordering::SeqCst); }
        }
        let cleaned = Arc::new(AtomicUsize::new(0));
        let input = frame(br#"{"version":1,"type":"finish","ptm":"p","tk":"t"}"#);
        let mut output = Vec::new();
        assert!(run_typed_session(&mut input.as_slice(), &mut output, Tracked(cleaned.clone())).is_err());
        assert!(output.is_empty());
        assert_eq!(cleaned.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn typed_session_cleans_up_provider_after_start_failure() {
        use std::sync::{Arc, atomic::{AtomicUsize, Ordering}};
        struct Fail(Arc<AtomicUsize>);
        impl StatefulMaterialBackend for Fail {
            fn start(&mut self, _: &str, _: &str) -> io::Result<String> {
                Err(io::Error::other("failure"))
            }
            fn finish(&mut self, _: &str, _: &str) -> io::Result<String> {
                panic!("finish after failure")
            }
            fn abort(&mut self) { self.0.fetch_add(1, Ordering::SeqCst); }
        }
        let cleaned = Arc::new(AtomicUsize::new(0));
        let input = frame(br#"{"version":1,"type":"start","identifier":"id","spim":"s"}"#);
        let mut output = Vec::new();
        assert!(run_typed_session(&mut input.as_slice(), &mut output, Fail(cleaned.clone())).is_err());
        assert!(output.is_empty());
        assert_eq!(cleaned.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn typed_session_rejects_invalid_native_material_without_output() {
        struct Bad;
        impl StatefulMaterialBackend for Bad {
            fn start(&mut self, _: &str, _: &str) -> io::Result<String> {
                Ok("bad\nmaterial".into())
            }
            fn finish(&mut self, _: &str, _: &str) -> io::Result<String> {
                panic!("finish must not run")
            }
        }
        let input = frame(br#"{"version":1,"type":"start","identifier":"id","spim":"s"}"#);
        let mut output = Vec::new();
        assert!(run_typed_session(&mut input.as_slice(), &mut output, Bad).is_err());
        assert!(output.is_empty());
    }

    #[test]
    fn typed_session_rejects_finish_first_without_invoking_backend() {
        struct Never;
        impl StatefulMaterialBackend for Never {
            fn start(&mut self, _: &str, _: &str) -> io::Result<String> {
                panic!("unexpected start")
            }
            fn finish(&mut self, _: &str, _: &str) -> io::Result<String> {
                panic!("unexpected finish")
            }
        }
        let input = frame(br#"{"version":1,"type":"finish","ptm":"p","tk":"t"}"#);
        let mut output = Vec::new();
        assert!(run_typed_session(&mut input.as_slice(), &mut output, Never).is_err());
        assert!(output.is_empty());
    }

    #[test]
    fn typed_session_never_emits_finished_when_extra_input_follows_finish() {
        struct Mock;
        impl StatefulMaterialBackend for Mock {
            fn start(&mut self, _: &str, _: &str) -> io::Result<String> {
                Ok("cpim-test".into())
            }
            fn finish(&mut self, _: &str, _: &str) -> io::Result<String> {
                Ok("adi-test".into())
            }
        }
        let mut input = frame(br#"{"version":1,"type":"start","identifier":"id","spim":"s"}"#);
        input.extend(frame(br#"{"version":1,"type":"finish","ptm":"p","tk":"t"}"#));
        input.push(0);
        let mut output = Vec::new();
        assert!(run_typed_session(&mut input.as_slice(), &mut output, Mock).is_err());
        assert_eq!(output, frame(br#"{"cpim":"cpim-test","type":"started","version":1}"#));
    }

    #[test]
    fn typed_session_start_error_never_emits_material() {
        struct Fail;
        impl StatefulMaterialBackend for Fail {
            fn start(&mut self, _: &str, _: &str) -> io::Result<String> {
                Err(io::Error::other("native failure"))
            }
            fn finish(&mut self, _: &str, _: &str) -> io::Result<String> {
                panic!("finish after failed start")
            }
        }
        let input = frame(br#"{"version":1,"type":"start","identifier":"id","spim":"s"}"#);
        let mut output = Vec::new();
        assert!(run_typed_session(&mut input.as_slice(), &mut output, Fail).is_err());
        assert!(output.is_empty());
    }

    #[test]
    fn typed_session_backend_produces_strict_phase_responses() {
        struct Mock { started: bool }
        impl StatefulMaterialBackend for Mock {
            fn start(&mut self, identifier: &str, spim: &str) -> io::Result<String> {
                assert_eq!((identifier, spim), ("id", "spim"));
                assert!(!self.started);
                self.started = true;
                Ok("cpim-test".into())
            }
            fn finish(&mut self, ptm: &str, tk: &str) -> io::Result<String> {
                assert!(self.started);
                assert_eq!((ptm, tk), ("ptm", "tk"));
                Ok("adi-test".into())
            }
        }
        let mut input = frame(br#"{"version":1,"type":"start","identifier":"id","spim":"spim"}"#);
        input.extend(frame(br#"{"version":1,"type":"finish","ptm":"ptm","tk":"tk"}"#));
        let mut output = Vec::new();
        run_typed_session(&mut input.as_slice(), &mut output, Mock { started: false }).unwrap();
        let mut expected = frame(br#"{"cpim":"cpim-test","type":"started","version":1}"#);
        expected.extend(frame(br#"{"adi_pb":"adi-test","type":"finished","version":1}"#));
        assert_eq!(output, expected);
    }
    #[test]
    fn rust_worker_two_frame_session_preserves_backend_instance() {
        struct StatefulMock(u8);
        impl NativeAdiBackend for StatefulMock {
            fn execute(&mut self, request: NativeRequest) -> io::Result<()> {
                match request {
                    NativeRequest::Start { .. } if self.0 == 0 => self.0 = 1,
                    NativeRequest::Finish { .. } if self.0 == 1 => self.0 = 2,
                    _ => return Err(io::Error::new(io::ErrorKind::InvalidData, "wrong phase")),
                }
                Ok(())
            }
        }
        let mut input = frame(br#"{"version":1,"type":"start","identifier":"id","spim":"s"}"#);
        input.extend(frame(br#"{"version":1,"type":"finish","ptm":"p","tk":"t"}"#));
        let mut output = Vec::new();
        run_two_phase_test_session(&mut input.as_slice(), &mut output, StatefulMock(0)).unwrap();
        let mut expected = frame(br#"{"version":1,"type":"started","cpim":"mock"}"#);
        expected.extend(frame(br#"{"version":1,"type":"finished","adi_pb":"mock"}"#));
        assert_eq!(output, expected);
    }
    #[test]
    fn mock_backend_retains_one_session_across_both_phases() {
        struct StatefulMock { starts: usize, finishes: usize }
        impl NativeAdiBackend for StatefulMock {
            fn execute(&mut self, request: NativeRequest) -> io::Result<()> {
                match request {
                    NativeRequest::Start { .. } => {
                        assert_eq!((self.starts, self.finishes), (0, 0));
                        self.starts += 1;
                    }
                    NativeRequest::Finish { .. } => {
                        assert_eq!((self.starts, self.finishes), (1, 0));
                        self.finishes += 1;
                    }
                }
                Ok(())
            }
        }
        let mut session = NativeSession::new(StatefulMock { starts: 0, finishes: 0 });
        let start = frame(br#"{"version":1,"type":"start","identifier":"id","spim":"s"}"#);
        let finish = frame(br#"{"version":1,"type":"finish","ptm":"p","tk":"t"}"#);
        let first = read_session_request(&mut start.as_slice()).unwrap().unwrap();
        let second = read_session_request(&mut finish.as_slice()).unwrap().unwrap();
        assert!(session.execute(first).is_ok());
        assert_eq!(session.state, NativeSessionState::Started);
        assert!(session.execute(second).is_ok());
        assert_eq!(session.state, NativeSessionState::Closed);
        assert_eq!((session.backend.starts, session.backend.finishes), (1, 1));
    }
    #[test]
    fn session_mode_is_fail_closed_without_native_provider() {
        let start = frame(br#"{"version":1,"type":"start","identifier":"id","spim":"spim"}"#);
        let mut output = Vec::new();
        assert!(run_session(&mut start.as_slice(), &mut output).is_ok());
        assert_eq!(output, frame(ERROR_RESPONSE));
        for invalid in [
            frame(br#"{"version":1,"type":"finish","ptm":"p","tk":"t"}"#),
            frame(br#"{"version":2,"type":"start","identifier":"id","spim":"s"}"#),
            (65537u32).to_be_bytes().to_vec(),
        ] {
            let mut output = Vec::new();
            assert!(run_session(&mut invalid.as_slice(), &mut output).is_err());
            assert!(output.is_empty());
        }
    }
    #[test]
    fn native_session_enforces_phase_order_and_terminal_failure() {
        struct MockBackend;
        impl NativeAdiBackend for MockBackend {
            fn execute(&mut self, _: NativeRequest) -> io::Result<()> { Ok(()) }
        }
        let mut session = NativeSession::new(MockBackend);
        assert!(session.execute(NativeRequest::Finish {
            ptm: "p".into(), tk: "t".into(),
        }).is_err());
        assert_eq!(session.state, NativeSessionState::Closed);
        assert!(session.execute(NativeRequest::Start {
            identifier: "id".into(), spim: "s".into(),
        }).is_err());

        let mut valid = NativeSession::new(MockBackend);
        assert!(valid.execute(NativeRequest::Start {
            identifier: "id".into(), spim: "s".into(),
        }).is_ok());
        assert_eq!(valid.state, NativeSessionState::Started);
        assert!(valid.execute(NativeRequest::Finish {
            ptm: "p".into(), tk: "t".into(),
        }).is_ok());
        assert_eq!(valid.state, NativeSessionState::Closed);
        assert!(valid.execute(NativeRequest::Finish {
            ptm: "p".into(), tk: "t".into(),
        }).is_err());

        let mut disabled = NativeSession::new(DisabledNativeAdiBackend);
        assert!(disabled.execute(NativeRequest::Start {
            identifier: "id".into(), spim: "s".into(),
        }).is_err());
        assert_eq!(disabled.state, NativeSessionState::Closed);
    }
    #[test]
    fn native_backend_is_explicitly_disabled_for_both_phases() {
        let mut backend = DisabledNativeAdiBackend;
        assert!(backend.execute(NativeRequest::Start {
            identifier: "id".into(), spim: "spim".into(),
        }).is_err());
        assert!(backend.execute(NativeRequest::Finish {
            ptm: "ptm".into(), tk: "tk".into(),
        }).is_err());
    }
    #[test]
    fn malformed_trailing_and_oversized_input_fail_without_output() {
        for request in [
            frame(br#"{"version":1,"type":"start","identifier":"id"}"#),
            frame(br#"{"version":2,"type":"start","identifier":"id","spim":"s"}"#),
            frame(b"not json"),
            { let mut bytes = frame(br#"{"version":1,"type":"start","identifier":"id","spim":"s"}"#); bytes.push(1); bytes },
            (65537u32).to_be_bytes().to_vec(),
        ] {
            let mut output = Vec::new();
            assert!(run(&mut request.as_slice(), &mut output).is_err());
            assert!(output.is_empty());
        }
    }
}
