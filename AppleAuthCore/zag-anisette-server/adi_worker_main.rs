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

/// Offline-only two-phase worker loop. The disabled backend terminates after
/// Start with a generic error; it never emits mock CPIM or adi.pb.
fn run_session<R: Read, W: Write>(input: &mut R, output: &mut W) -> io::Result<()> {
    let mut session = NativeSession::new(DisabledNativeAdiBackend);
    let first = read_session_request(input)?.ok_or_else(|| {
        io::Error::new(io::ErrorKind::UnexpectedEof, "missing Start")
    })?;
    if !matches!(first, NativeRequest::Start { .. }) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Start required"));
    }
    if session.execute(first).is_err() {
        return write_unavailable(output);
    }
    // Future native backends must emit Started before waiting for Finish,
    // and return Finished only after the native session is destroyed.
    Err(io::Error::new(io::ErrorKind::Unsupported, "native session disabled"))
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
    // Fail closed without emitting secret-bearing diagnostics or stdout text.
    if run(&mut io::stdin().lock(), &mut io::stdout().lock()).is_err() {
        std::process::exit(1);
    }
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
