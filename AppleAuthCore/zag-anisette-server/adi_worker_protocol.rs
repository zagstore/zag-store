//! Versioned, bounded JSON IPC contract for a future separately reviewed ADI worker.
//! No worker is spawned, no Apple API is contacted, and the HTTP listener remains offline.
#![allow(dead_code)]
use serde_json::{json, Value};

pub const MAX_MESSAGE_BYTES: usize = 64 * 1024;
pub const PROTOCOL_VERSION: u64 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WireError {
    Oversized,
    Malformed,
    UnsupportedVersion,
    UnexpectedMessage,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkerRequest {
    Start { identifier: String, spim: String },
    Finish { ptm: String, tk: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkerResponse {
    Started { cpim: String },
    Finished { adi_pb: String },
    Failed,
}

fn field(value: &Value, key: &str) -> Result<String, WireError> {
    let text = value.get(key).and_then(Value::as_str).ok_or(WireError::Malformed)?;
    if text.is_empty() || text.len() > MAX_MESSAGE_BYTES || text.chars().any(char::is_control) {
        return Err(WireError::Malformed);
    }
    Ok(text.to_owned())
}

fn object(bytes: &[u8]) -> Result<Value, WireError> {
    if bytes.len() > MAX_MESSAGE_BYTES { return Err(WireError::Oversized); }
    let value: Value = serde_json::from_slice(bytes).map_err(|_| WireError::Malformed)?;
    let map = value.as_object().ok_or(WireError::Malformed)?;
    if map.get("version").and_then(Value::as_u64) != Some(PROTOCOL_VERSION) {
        return Err(WireError::UnsupportedVersion);
    }
    Ok(value)
}

pub fn encode_request(request: &WorkerRequest) -> Result<Vec<u8>, WireError> {
    let value = match request {
        WorkerRequest::Start { identifier, spim } => json!({"version":PROTOCOL_VERSION,"type":"start","identifier":identifier,"spim":spim}),
        WorkerRequest::Finish { ptm, tk } => json!({"version":PROTOCOL_VERSION,"type":"finish","ptm":ptm,"tk":tk}),
    };
    let bytes = serde_json::to_vec(&value).map_err(|_| WireError::Malformed)?;
    decode_request(&bytes)?;
    Ok(bytes)
}

pub fn decode_request(bytes: &[u8]) -> Result<WorkerRequest, WireError> {
    let value = object(bytes)?;
    let map = value.as_object().ok_or(WireError::Malformed)?;
    match value.get("type").and_then(Value::as_str) {
        Some("start") if map.len() == 4 => Ok(WorkerRequest::Start { identifier: field(&value, "identifier")?, spim: field(&value, "spim")? }),
        Some("finish") if map.len() == 4 => Ok(WorkerRequest::Finish { ptm: field(&value, "ptm")?, tk: field(&value, "tk")? }),
        _ => Err(WireError::UnexpectedMessage),
    }
}

/// The caller specifies which reply is expected; a late reply from another
/// phase must never be interpreted as successful provisioning.
pub fn decode_response(bytes: &[u8], expected: &WorkerRequest) -> Result<WorkerResponse, WireError> {
    let value = object(bytes)?;
    let map = value.as_object().ok_or(WireError::Malformed)?;
    match (expected, value.get("type").and_then(Value::as_str)) {
        (WorkerRequest::Start { .. }, Some("started")) if map.len() == 3 =>
            Ok(WorkerResponse::Started { cpim: field(&value, "cpim")? }),
        (WorkerRequest::Finish { .. }, Some("finished")) if map.len() == 3 =>
            Ok(WorkerResponse::Finished { adi_pb: field(&value, "adi_pb")? }),
        (_, Some("error")) if map.len() == 3 && value.get("code").and_then(Value::as_str) == Some("backend_unavailable") =>
            Ok(WorkerResponse::Failed),
        _ => Err(WireError::UnexpectedMessage),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn start() -> WorkerRequest { WorkerRequest::Start { identifier: "device".into(), spim: "spim".into() } }
    fn finish() -> WorkerRequest { WorkerRequest::Finish { ptm: "ptm".into(), tk: "tk".into() } }
    #[test] fn request_roundtrip() {
        for request in [start(), finish()] {
            assert_eq!(decode_request(&encode_request(&request).unwrap()), Ok(request));
        }
    }
    #[test] fn exact_expected_responses() {
        assert_eq!(decode_response(br#"{"version":1,"type":"started","cpim":"abc"}"#, &start()), Ok(WorkerResponse::Started { cpim:"abc".into() }));
        assert_eq!(decode_response(br#"{"version":1,"type":"finished","adi_pb":"abc"}"#, &finish()), Ok(WorkerResponse::Finished { adi_pb:"abc".into() }));
        assert_eq!(decode_response(br#"{"version":1,"type":"error","code":"backend_unavailable"}"#, &start()), Ok(WorkerResponse::Failed));
    }
    #[test] fn rejects_malformed_version_and_extra_fields() {
        for message in [
            br#"not json"#.as_slice(),
            br#"[]"#,
            br#"{"version":1,"type":"started","cpim":null}"#,
            br#"{"version":1,"type":"started","cpim":""}"#,
            br#"{"version":1,"type":"started","cpim":"x","extra":1}"#,
        ] { assert!(decode_response(message, &start()).is_err()); }
        assert_eq!(decode_response(br#"{"version":2,"type":"started","cpim":"x"}"#, &start()), Err(WireError::UnsupportedVersion));
        assert_eq!(decode_response(br#"{"type":"started","cpim":"x"}"#, &start()), Err(WireError::UnsupportedVersion));
    }
    #[test] fn rejects_cross_phase_and_unknown_errors() {
        assert_eq!(decode_response(br#"{"version":1,"type":"finished","adi_pb":"x"}"#, &start()), Err(WireError::UnexpectedMessage));
        assert_eq!(decode_response(br#"{"version":1,"type":"started","cpim":"x"}"#, &finish()), Err(WireError::UnexpectedMessage));
        assert_eq!(decode_response(br#"{"version":1,"type":"error","code":"secret"}"#, &start()), Err(WireError::UnexpectedMessage));
    }
    #[test] fn enforces_exact_wire_limit() {
        let huge = vec![b'x'; MAX_MESSAGE_BYTES + 1];
        assert_eq!(decode_request(&huge), Err(WireError::Oversized));
        assert_eq!(decode_response(&huge, &start()), Err(WireError::Oversized));
        let oversized = WorkerRequest::Start { identifier: "x".repeat(MAX_MESSAGE_BYTES), spim: "s".into() };
        assert_eq!(encode_request(&oversized), Err(WireError::Oversized));
    }
    #[test] fn rejects_control_characters_and_wrong_request_shape() {
        assert_eq!(decode_request(br#"{"version":1,"type":"start","identifier":"a\n","spim":"b"}"#), Err(WireError::Malformed));
        assert_eq!(decode_request(br#"{"version":1,"type":"start","identifier":"a"}"#), Err(WireError::UnexpectedMessage));
    }
}
