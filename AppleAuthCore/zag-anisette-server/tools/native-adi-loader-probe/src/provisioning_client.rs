//! Operator-invoked, offline-worker-compatible Apple provisioning coordinator.
//! No Apple credentials are accepted. The coordinator talks only to Apple's
//! approved HTTPS hosts, and the native worker is a separate local child.
use crate::offline_v2_bridge::wire::{self, Request, Response};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use plist::{Dictionary, Value};
use std::io::{self, Read, Write};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};
use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
use std::thread;
use url::Url;

const LOOKUP: &str = "https://gsa.apple.com/grandslam/GsService2/lookup";
const MAX_HTTP_BYTES: usize = 128 * 1024;
const WORKER_DEADLINE: Duration = Duration::from_secs(45);
const MAX_BINARY_BYTES: usize = 12 * 1024;
const MAX_FRAME: usize = wire::MAX_FRAME;

/// Only known Apple GrandSlam provisioning hosts may be used. Deliberately
/// refuse redirects and credential-bearing URLs. Any host additions require review.
fn validated_endpoint(input: &str) -> io::Result<Url> {
    // Check the raw authority before URL normalization: url::Url intentionally
    // drops an explicit default HTTPS port (":443"), which would otherwise
    // defeat the no-explicit-port policy.
    let authority = input.strip_prefix("https://")
        .and_then(|rest| rest.split('/').next())
        .ok_or_else(|| invalid("invalid provisioning URL"))?;
    if !matches!(authority, "gsa.apple.com" | "gsas.apple.com") {
        return Err(invalid("unapproved raw provisioning authority"));
    }
    let url = Url::parse(input).map_err(|_| invalid("invalid provisioning URL"))?;
    if url.scheme() != "https" || url.port().is_some() || !url.username().is_empty()
        || url.password().is_some() || url.query().is_some() || url.fragment().is_some() {
        return Err(invalid("unsafe provisioning URL"));
    }
    // Strict exact-host restriction; no suffix checks or arbitrary domains.
    if !matches!(url.host_str(), Some("gsa.apple.com" | "gsas.apple.com")) {
        return Err(invalid("unapproved provisioning host"));
    }
    Ok(url)
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}
fn transport() -> io::Error {
    io::Error::new(io::ErrorKind::Other, "Apple provisioning transport failed")
}
fn xml_bytes(dict: Dictionary) -> io::Result<Vec<u8>> {
    let mut output = Vec::new();
    Value::Dictionary(dict).to_writer_xml(&mut output).map_err(|_| invalid("invalid plist encoding"))?;
    if output.len() > MAX_HTTP_BYTES { return Err(invalid("oversized request")); }
    Ok(output)
}
fn plist_response(bytes: &[u8]) -> io::Result<Dictionary> {
    Value::from_reader_xml(bytes).map_err(|_| invalid("invalid Apple response plist"))?
        .into_dictionary().ok_or_else(|| invalid("invalid plist root"))
}
fn dictionary_field<'a>(dict: &'a Dictionary, key: &str) -> io::Result<&'a Dictionary> {
    dict.get(key).and_then(Value::as_dictionary).ok_or_else(|| invalid("missing plist dictionary"))
}
fn string_field<'a>(dict: &'a Dictionary, key: &str) -> io::Result<&'a str> {
    dict.get(key).and_then(Value::as_string).ok_or_else(|| invalid("missing plist string"))
}
fn decoded_field(dict: &Dictionary, key: &str) -> io::Result<Vec<u8>> {
    let encoded = string_field(dict, key)?;
    if encoded.is_empty() || encoded.len() > MAX_BINARY_BYTES * 2 { return Err(invalid("oversized provisioning material")); }
    let decoded = STANDARD.decode(encoded).map_err(|_| invalid("invalid provisioning base64"))?;
    if decoded.is_empty() || decoded.len() > MAX_BINARY_BYTES { return Err(invalid("invalid provisioning bytes")); }
    Ok(decoded)
}
fn empty_request() -> io::Result<Vec<u8>> {
    let mut root = Dictionary::new();
    root.insert("Header".to_string(), Value::Dictionary(Dictionary::new()));
    root.insert("Request".to_string(), Value::Dictionary(Dictionary::new()));
    xml_bytes(root)
}
fn finish_request(cpim: &[u8]) -> io::Result<Vec<u8>> {
    if cpim.is_empty() || cpim.len() > MAX_BINARY_BYTES { return Err(invalid("invalid CPIM")); }
    let mut request = Dictionary::new();
    request.insert("cpim".to_string(), Value::String(STANDARD.encode(cpim)));
    let mut root = Dictionary::new();
    root.insert("Header".to_string(), Value::Dictionary(Dictionary::new()));
    root.insert("Request".to_string(), Value::Dictionary(request));
    xml_bytes(root)
}
fn framed_request(req: &Request) -> io::Result<Vec<u8>> {
    let bytes = wire::encode_request(req).map_err(|_| invalid("invalid v2 request"))?;
    let mut result = (bytes.len() as u32).to_be_bytes().to_vec();
    result.extend_from_slice(&bytes);
    Ok(result)
}
fn framed_response<R: Read>(reader: &mut R, request: &Request) -> io::Result<Response> {
    let mut length = [0u8; 4];
    reader.read_exact(&mut length)?;
    let size = u32::from_be_bytes(length) as usize;
    if size == 0 || size > MAX_FRAME { return Err(invalid("invalid worker frame")); }
    let mut bytes = vec![0; size];
    reader.read_exact(&mut bytes)?;
    wire::decode_response(&bytes, request).map_err(|_| invalid("invalid worker response"))
}

struct AppleHttp {
    agent: ureq::Agent,
    device_id: String,
    client_info: String,
    local_user: String,
    serial: String,
}
impl AppleHttp {
    fn new(device_id: &str, client_info: &str, local_user: &str, serial: &str) -> io::Result<Self> {
        if device_id.is_empty() || client_info.is_empty() || device_id.len() > 256
            || client_info.len() > 512 || device_id.chars().any(char::is_control)
            || client_info.chars().any(char::is_control) {
            return Err(invalid("invalid device headers"));
        }
        // Never synthesize identity headers or accept control characters.
        // Values must be stable operator-provided test identities.
        if local_user.len() != 64 || !local_user.bytes().all(|b| b.is_ascii_hexdigit())
            || serial.is_empty() || serial.len() > 64
            || !serial.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
            return Err(invalid("invalid Apple identity headers"));
        }
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(8))
            .timeout_read(Duration::from_secs(12))
            .timeout_write(Duration::from_secs(12))
            .redirects(0)
            .build();
        Ok(Self { agent, device_id: device_id.to_owned(), client_info: client_info.to_owned(),
            local_user: local_user.to_owned(), serial: serial.to_owned() })
    }
    fn get(&self, url: &str) -> io::Result<Dictionary> { self.send(url, None) }
    fn post(&self, url: &str, body: &[u8]) -> io::Result<Dictionary> { self.send(url, Some(body)) }
    fn send(&self, target: &str, body: Option<&[u8]>) -> io::Result<Dictionary> {
        let url = validated_endpoint(target)?;
        let req = match body {
            Some(_) => self.agent.post(url.as_str()),
            None => self.agent.get(url.as_str()),
        }
            .set("User-Agent", "akd/1.0 CFNetwork/808.1.4")
            .set("X-Mme-Device-Id", &self.device_id)
            .set("X-Mme-Client-Info", &self.client_info)
            .set("X-Apple-I-MD-LU", &self.local_user)
            .set("X-Apple-I-SRL-NO", &self.serial)
            .set("Content-Type", "text/x-xml-plist");
        // ureq's default TLS verification is retained; no insecure opt-out.
        // Any redirect is rejected by redirects(0) and status validation.
        let result = match body {
            Some(bytes) => req.send_bytes(bytes),
            None => req.call(),
        }.map_err(|_| transport())?;
        if result.status() != 200 { return Err(transport()); }
        let mut bounded = result.into_reader().take((MAX_HTTP_BYTES + 1) as u64);
        let mut bytes = Vec::new();
        bounded.read_to_end(&mut bytes).map_err(|_| transport())?;
        if bytes.is_empty() || bytes.len() > MAX_HTTP_BYTES { return Err(invalid("invalid HTTP body size")); }
        plist_response(&bytes)
    }
}

/// Owns the Child handle until it is reaped. Never signals a bare PID:
/// kill() operates on the still-owned Child, preventing PID-reuse races.
/// Abort requests and the hard deadline are both handled by this thread.
fn supervise_child(
    mut child: Child,
    deadline: Duration,
    abort: Arc<AtomicBool>,
) -> thread::JoinHandle<io::Result<(ExitStatus, bool)>> {
    thread::spawn(move || {
        let end = Instant::now() + deadline;
        loop {
            if let Some(status) = child.try_wait()? {
                return Ok((status, false));
            }
            if abort.load(Ordering::Acquire) || Instant::now() >= end {
                let timed_out = Instant::now() >= end;
                child.kill()?;
                let status = child.wait()?;
                return Ok((status, timed_out));
            }
            thread::sleep(Duration::from_millis(20));
        }
    })
}

/// Native child remains in its own process. Only a single local worker
/// executable and operator-supplied empty private directory are allowed.
/// The child is not registered as a production service.
#[allow(dead_code)]
pub fn provision_with_worker(
    worker_binary: &std::path::Path,
    runtime_root: &std::path::Path,
    fresh_state_dir: &std::path::Path,
    device_id: &str,
    client_info: &str,
    local_user: &str,
    serial: &str,
) -> io::Result<Vec<u8>> {
    if !worker_binary.is_file() || !runtime_root.is_dir() || !fresh_state_dir.is_absolute() {
        return Err(invalid("invalid isolated worker configuration"));
    }
    if fresh_state_dir.exists() { return Err(invalid("state directory already exists")); }
    let http = AppleHttp::new(device_id, client_info, local_user, serial)?;
    let lookup = http.get(LOOKUP)?;
    let bag = dictionary_field(&lookup, "urls")?;
    let start_url = validated_endpoint(string_field(bag, "midStartProvisioning")?)?;
    let finish_url = validated_endpoint(string_field(bag, "midFinishProvisioning")?)?;
    let start_body = empty_request()?;
    let start_reply = http.post(start_url.as_str(), &start_body)?;
    let spim = decoded_field(dictionary_field(&start_reply, "Response")?, "spim")?;

    let mut child = Command::new(worker_binary)
        .arg(runtime_root)
        .arg("--native-v2-session")
        .arg(fresh_state_dir)
        .arg(device_id)
        .env_clear()
        .current_dir("/")
        .stdin(Stdio::piped()).stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn().map_err(|_| transport())?;
    // Extract pipes before transferring exclusive Child ownership to the
    // supervisor. All process termination/reaping occurs in that thread.
    let mut stdin = Some(child.stdin.take().ok_or_else(transport)?);
    let mut stdout = child.stdout.take().ok_or_else(transport)?;
    let abort = Arc::new(AtomicBool::new(false));
    let supervisor = supervise_child(child, WORKER_DEADLINE, Arc::clone(&abort));
    let result = (|| {
        let start = Request::Start { identifier: "-2".into(), spim };
        stdin.as_mut().ok_or_else(transport)?.write_all(&framed_request(&start)?)?;
        stdin.as_mut().ok_or_else(transport)?.flush()?;
        let cpim = match framed_response(&mut stdout, &start)? {
            Response::Started(data) => data,
            _ => return Err(invalid("worker rejected Start")),
        };
        let body = finish_request(&cpim)?;
        let finish_reply = http.post(finish_url.as_str(), &body)?;
        let reply = dictionary_field(&finish_reply, "Response")?;
        let ptm = decoded_field(reply, "ptm")?;
        let tk = decoded_field(reply, "tk")?;
        let finish = Request::Finish { ptm, tk };
        stdin.as_mut().ok_or_else(transport)?.write_all(&framed_request(&finish)?)?;
        stdin.as_mut().ok_or_else(transport)?.flush()?;
        drop(stdin.take());
        let adi_pb = match framed_response(&mut stdout, &finish)? {
            Response::Finished(data) => data,
            _ => return Err(invalid("worker rejected Finish")),
        };
        let mut extra = [0u8; 1];
        if stdout.read(&mut extra)? != 0 { return Err(invalid("worker trailing output")); }
        Ok(adi_pb)
    })();
    if result.is_err() { abort.store(true, Ordering::Release); }
    drop(stdin.take());
    drop(stdout);
    let (status, timed_out) = supervisor.join().map_err(|_| transport())??;
    if timed_out { return Err(io::Error::new(io::ErrorKind::TimedOut, "native worker deadline exceeded")); }
    if !status.success() { return Err(transport()); }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    #[test]
    fn supervisor_reaps_hung_child_without_raw_pid_signals() {
        let child = Command::new("/bin/sh")
            .args(["-c", "exec sleep 10"])
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
            .spawn().unwrap();
        let started = Instant::now();
        let abort = Arc::new(AtomicBool::new(false));
        let worker = supervise_child(child, Duration::from_millis(120), abort);
        let (status, timed_out) = worker.join().unwrap().unwrap();
        assert!(timed_out);
        assert!(!status.success());
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[cfg(unix)]
    #[test]
    fn supervisor_preserves_successful_exit() {
        let child = Command::new("/bin/sh").args(["-c", "exit 0"])
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
            .spawn().unwrap();
        let worker = supervise_child(child, Duration::from_secs(2),
            Arc::new(AtomicBool::new(false)));
        let (status, timed_out) = worker.join().unwrap().unwrap();
        assert!(status.success());
        assert!(!timed_out);
    }

    #[test]
    fn identity_headers_reject_missing_or_injected_values() {
        let user = "A".repeat(64);
        assert!(AppleHttp::new("device", "client", &user, "TEST-123").is_ok());
        assert!(AppleHttp::new("device", "client", "", "TEST-123").is_err());
        assert!(AppleHttp::new("device", "client", &user, "").is_err());
        assert!(AppleHttp::new("device", "client", &user, "TEST\r\nInjected").is_err());
        assert!(AppleHttp::new("device", "client\nInjected", &user, "TEST").is_err());
        assert!(AppleHttp::new("device", "client", &("A".repeat(63) + "Z"), "TEST").is_err());
    }

    #[test]
    fn endpoint_allowlist_is_strict() {
        for good in [
            "https://gsa.apple.com/grandslam/GsService2/lookup",
            "https://gsas.apple.com/another/path",
        ] { assert!(validated_endpoint(good).is_ok()); }
        for bad in [
            "http://gsa.apple.com/a",
            "https://gsa.apple.com.evil.example/a",
            "https://evil.example/a", "https://user@gsa.apple.com/a",
            "https://gsa.apple.com:443/a", "https://gsa.apple.com/a?token=x",
            "https://gsa.apple.com/a#fragment", "file:///etc/passwd",
        ] { assert!(validated_endpoint(bad).is_err()); }
    }
    #[test]
    fn plist_contract_rejects_missing_and_invalid_material() {
        let bytes = empty_request().unwrap();
        let value = plist_response(&bytes).unwrap();
        assert!(dictionary_field(&value, "Request").is_ok());
        assert!(decoded_field(&value, "spim").is_err());
        let mut response = Dictionary::new();
        response.insert("spim".to_string(), Value::String(STANDARD.encode([0, 255, 64])));
        assert_eq!(decoded_field(&response, "spim").unwrap(), vec![0, 255, 64]);
        response.insert("spim".to_string(), Value::String("invalid!!".into()));
        assert!(decoded_field(&response, "spim").is_err());
        assert!(finish_request(&[]).is_err());
    }
}
