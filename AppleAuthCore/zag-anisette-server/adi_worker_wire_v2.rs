//! Offline-only v2 binary material contract. Not connected to release provisioning.
#![allow(dead_code)]
use serde::de::{self, MapAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fmt;

pub const VERSION: u64 = 2;
pub const MAX_FRAME: usize = 64 * 1024;
const MAX_BINARY: usize = (MAX_FRAME - 512) / 2;

#[derive(Debug, PartialEq, Eq)]
pub enum WireError { Invalid, Oversized, Version, Phase }

struct UniqueObject(BTreeMap<String, Value>);
impl<'de> Deserialize<'de> for UniqueObject {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct UniqueVisitor;
        impl<'de> Visitor<'de> for UniqueVisitor {
            type Value = UniqueObject;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result { f.write_str("unique JSON object") }
            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Self::Value, M::Error> {
                let mut fields = BTreeMap::new();
                while let Some((key, value)) = map.next_entry::<String, Value>()? {
                    if fields.insert(key, value).is_some() { return Err(de::Error::custom("duplicate field")); }
                }
                Ok(UniqueObject(fields))
            }
        }
        deserializer.deserialize_map(UniqueVisitor)
    }
}

fn parse(bytes: &[u8]) -> Result<BTreeMap<String, Value>, WireError> {
    if bytes.len() > MAX_FRAME { return Err(WireError::Oversized); }
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    let obj = UniqueObject::deserialize(&mut deserializer).map_err(|_| WireError::Invalid)?.0;
    deserializer.end().map_err(|_| WireError::Invalid)?;
    if obj.get("version").and_then(Value::as_u64) != Some(VERSION) { return Err(WireError::Version); }
    Ok(obj)
}

fn material(obj: &BTreeMap<String, Value>, name: &str) -> Result<Vec<u8>, WireError> {
    let encoded = obj.get(name).and_then(Value::as_str).ok_or(WireError::Invalid)?;
    if encoded.is_empty() || !encoded.len().is_multiple_of(2) || encoded.len() > MAX_BINARY * 2 {
        return Err(WireError::Invalid);
    }
    let digit = |b: u8| match b { b'0'..=b'9' => Some(b - b'0'), b'a'..=b'f' => Some(b - b'a' + 10), _ => None };
    encoded.as_bytes().as_chunks::<2>().0.iter().map(|pair| {
        Ok((digit(pair[0]).ok_or(WireError::Invalid)? << 4) | digit(pair[1]).ok_or(WireError::Invalid)?)
    }).collect()
}

fn encode_hex(bytes: &[u8]) -> Result<String, WireError> {
    if bytes.is_empty() || bytes.len() > MAX_BINARY { return Err(WireError::Invalid); }
    let mut result = String::with_capacity(bytes.len() * 2);
    for byte in bytes { result.push_str(&format!("{byte:02x}")); }
    Ok(result)
}

#[derive(Debug, PartialEq, Eq)]
pub enum Request { Start { identifier: String, spim: Vec<u8> }, Finish { ptm: Vec<u8>, tk: Vec<u8> } }
#[derive(Debug, PartialEq, Eq)]
pub enum Response { Started(Vec<u8>), Finished(Vec<u8>) }

fn exact(obj: &BTreeMap<String, Value>, names: &[&str]) -> Result<(), WireError> {
    if obj.len() != names.len() || obj.keys().any(|key| !names.contains(&key.as_str())) { return Err(WireError::Invalid); }
    Ok(())
}

pub fn decode_request(bytes: &[u8]) -> Result<Request, WireError> {
    let obj = parse(bytes)?;
    match obj.get("type").and_then(Value::as_str) {
        Some("start") => {
            exact(&obj, &["version", "type", "identifier", "spim_hex"])?;
            let id = obj.get("identifier").and_then(Value::as_str).ok_or(WireError::Invalid)?;
            if id.is_empty() || id.len() > 256 || id.chars().any(char::is_control) { return Err(WireError::Invalid); }
            Ok(Request::Start { identifier: id.into(), spim: material(&obj, "spim_hex")? })
        }
        Some("finish") => {
            exact(&obj, &["version", "type", "ptm_hex", "tk_hex"])?;
            Ok(Request::Finish { ptm: material(&obj, "ptm_hex")?, tk: material(&obj, "tk_hex")? })
        }
        _ => Err(WireError::Phase),
    }
}

pub fn encode_request(request: &Request) -> Result<Vec<u8>, WireError> {
    let value = match request {
        Request::Start { identifier, spim } => json!({"version":VERSION,"type":"start","identifier":identifier,"spim_hex":encode_hex(spim)?}),
        Request::Finish { ptm, tk } => json!({"version":VERSION,"type":"finish","ptm_hex":encode_hex(ptm)?,"tk_hex":encode_hex(tk)?}),
    };
    let bytes = serde_json::to_vec(&value).map_err(|_| WireError::Invalid)?;
    decode_request(&bytes)?;
    Ok(bytes)
}

pub fn decode_response(bytes: &[u8], expected: &Request) -> Result<Response, WireError> {
    let obj = parse(bytes)?;
    exact(&obj, &["version", "type", match expected { Request::Start { .. } => "cpim_hex", Request::Finish { .. } => "adi_pb_hex" }])?;
    match (expected, obj.get("type").and_then(Value::as_str)) {
        (Request::Start { .. }, Some("started")) => Ok(Response::Started(material(&obj, "cpim_hex")?)),
        (Request::Finish { .. }, Some("finished")) => Ok(Response::Finished(material(&obj, "adi_pb_hex")?)),
        _ => Err(WireError::Phase),
    }
}

pub fn encode_response(response: &Response) -> Result<Vec<u8>, WireError> {
    let value = match response {
        Response::Started(bytes) => json!({"version":VERSION,"type":"started","cpim_hex":encode_hex(bytes)?}),
        Response::Finished(bytes) => json!({"version":VERSION,"type":"finished","adi_pb_hex":encode_hex(bytes)?}),
    };
    let encoded = serde_json::to_vec(&value).map_err(|_| WireError::Invalid)?;
    if encoded.len() > MAX_FRAME { return Err(WireError::Oversized); }
    Ok(encoded)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn binary_round_trip_and_phase() {
        let start = Request::Start { identifier: "-2".into(), spim: vec![0, 255, 128] };
        assert_eq!(decode_request(&encode_request(&start).unwrap()), Ok(start));
        let finish = Request::Finish { ptm: vec![0, 10], tk: vec![255] };
        assert_eq!(decode_request(&encode_request(&finish).unwrap()), Ok(finish));
        let started = Response::Started(vec![0, 255]);
        let start = Request::Start { identifier: "-2".into(), spim: vec![1] };
        assert_eq!(decode_response(&encode_response(&started).unwrap(), &start), Ok(started));
        assert_eq!(decode_response(&encode_response(&started).unwrap(), &finish), Err(WireError::Invalid));
        let finished = Response::Finished(vec![255, 0]);
        assert_eq!(decode_response(&encode_response(&finished).unwrap(), &finish), Ok(finished));
    }
    #[test]
    fn rejects_duplicate_unknown_and_invalid_hex() {
        for data in [
            r#"{"version":2,"version":2,"type":"start","identifier":"-2","spim_hex":"00"}"#,
            r#"{"version":2,"type":"start","identifier":"-2","spim_hex":"AA"}"#,
            r#"{"version":2,"type":"start","identifier":"-2","spim_hex":"0"}"#,
            r#"{"version":2,"type":"start","identifier":"-2","spim_hex":"00","extra":1}"#,
            r#"{"version":1,"type":"start","identifier":"-2","spim_hex":"00"}"#,
        ] { assert!(decode_request(data.as_bytes()).is_err()); }
        assert_eq!(decode_request(&vec![b'x'; MAX_FRAME + 1]), Err(WireError::Oversized));
    }
}
