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

fn run<R: Read, W: Write>(input: &mut R, output: &mut W) -> io::Result<()> {
    let _request = read_request(input)?;
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
