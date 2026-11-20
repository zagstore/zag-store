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

fn run<R: Read, W: Write>(input: &mut R, output: &mut W) -> io::Result<()> {
    let request = read_request(input)?;
    // Parse into a typed request before invoking a future native backend.
    // The disabled backend must never synthesize provisioning material.
    let request = parse_request(&request)?;
    let _ = DisabledNativeAdiBackend.execute(request);
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
