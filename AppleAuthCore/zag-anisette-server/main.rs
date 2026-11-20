//! Zag-owned minimal anisette HTTP service scaffold.
//! Offline-only: provisioning endpoints deliberately return 503 until a reviewed backend exists.
//! It never answers a WebSocket upgrade with 101, contacts nothing, stores
//! nothing and logs no request data. No third-party server source code is used.
//!
//! The routes are those of the Zag Store fork's v3 client
//! (`zag-isideload/src/anisette/remote_v3`): `GET /v3/client_info`,
//! `POST /v3/get_headers` (JSON) and the `GET` WebSocket upgrade at
//! `/v3/provisioning_session` (reached as `wss://`). Every 503 makes that
//! client stop: `error_for_status` fails, and a non-101 upgrade fails.
mod adi_process;
#[cfg(test)]
mod adi_worker_wire_v2;
mod adi_worker_protocol;
mod adi_worker_framing;
mod adi_worker_lifecycle;
mod provisioning;
mod websocket_transport;

use std::{
    io::{Read, Write},
    net::{Shutdown, SocketAddr, TcpListener, TcpStream},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};

const MAX_HEADER: usize = 8192;
/// A request body (only `get_headers` has one) is never stored: it is
/// drained and discarded, up to this size.
const MAX_BODY: usize = 64 * 1024;
/// The whole request, headers and body, must arrive within this time: a slow
/// client cannot hold a worker.
const REQUEST_DEADLINE: Duration = Duration::from_secs(5);
const MAX_CONNECTIONS: usize = 16;
/// Free on `zagstore-prod-01` (127.0.0.1:18743–18745 are production services).
const DEFAULT_BIND: &str = "127.0.0.1:18760";

struct Response {
    status: &'static str,
    body: &'static str,
    allow: Option<&'static str>,
    upgrade: bool,
}

fn reply(status: &'static str, body: &'static str) -> Response {
    Response { status, body, allow: None, upgrade: false }
}

fn not_allowed(allow: &'static str) -> Response {
    Response { status: "405 Method Not Allowed", body: r#"{"error":"method_not_allowed"}"#, allow: Some(allow), upgrade: false }
}

const OFFLINE: &str = r#"{"error":"provisioning_backend_not_enabled"}"#;

impl Response {
    fn bytes(&self) -> Vec<u8> {
        let mut head = format!(
            "HTTP/1.1 {}\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\nContent-Length: {}\r\n",
            self.status,
            self.body.len()
        );
        if let Some(allow) = self.allow {
            head.push_str(&format!("Allow: {allow}\r\n"));
        }
        if self.upgrade {
            head.push_str("Upgrade: websocket\r\n");
        }
        head.push_str("\r\n");
        let mut bytes = head.into_bytes();
        bytes.extend_from_slice(self.body.as_bytes());
        bytes
    }
}

/// A parsed request head. Header names are lower-cased; values are trimmed.
struct Head {
    method: String,
    path: String,
    headers: Vec<(String, String)>,
}

impl Head {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
    }
    fn count(&self, name: &str) -> usize {
        self.headers.iter().filter(|(n, _)| n == name).count()
    }
    /// Comma-separated tokens of a header, case-insensitively.
    fn has_token(&self, name: &str, token: &str) -> bool {
        self.headers
            .iter()
            .filter(|(n, _)| n == name)
            .flat_map(|(_, v)| v.split(','))
            .any(|t| t.trim().eq_ignore_ascii_case(token))
    }
}

/// Parses the request head (everything before the blank line).
fn parse(head: &[u8]) -> Result<Head, Response> {
    let bad = || reply("400 Bad Request", r#"{"error":"invalid_request"}"#);
    let text = std::str::from_utf8(head).map_err(|_| bad())?;
    let mut lines = text.split("\r\n");
    let mut parts = lines.next().unwrap_or_default().split(' ');
    let (method, target, version) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or(""));
    if parts.next().is_some() || method.is_empty() || !method.bytes().all(|b| b.is_ascii_uppercase()) {
        return Err(bad());
    }
    if version != "HTTP/1.1" {
        let well_formed = version.len() == 8 && version.starts_with("HTTP/") && version.as_bytes()[6] == b'.'
            && version.as_bytes()[5].is_ascii_digit() && version.as_bytes()[7].is_ascii_digit();
        return Err(if well_formed {
            reply("505 HTTP Version Not Supported", r#"{"error":"http_version"}"#)
        } else {
            bad()
        });
    }
    // Origin form only: no absolute URLs, no authority form, nothing to proxy.
    if !target.starts_with('/') || target.contains('#') {
        return Err(bad());
    }
    let path = target.split('?').next().unwrap_or_default().to_string();
    let mut headers = Vec::new();
    for line in lines {
        // Obsolete line folding and lines without a name are refused.
        if line.starts_with([' ', '\t']) {
            return Err(bad());
        }
        let (name, value) = line.split_once(':').ok_or_else(bad)?;
        if name.is_empty() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b)) {
            return Err(bad());
        }
        headers.push((name.to_ascii_lowercase(), value.trim().to_string()));
    }
    Ok(Head { method: method.to_string(), path, headers })
}

/// The body length the request declares. Chunked or otherwise encoded bodies
/// and conflicting lengths are refused (no request smuggling behind a proxy).
fn body_length(head: &Head) -> Result<usize, Response> {
    if head.count("transfer-encoding") > 0 {
        return Err(reply("400 Bad Request", r#"{"error":"transfer_encoding_refused"}"#));
    }
    match head.count("content-length") {
        0 => Ok(0),
        1 => {
            let value = head.header("content-length").unwrap_or_default();
            if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
                return Err(reply("400 Bad Request", r#"{"error":"invalid_content_length"}"#));
            }
            match value.parse::<usize>() {
                Ok(n) if n <= MAX_BODY => Ok(n),
                _ => Err(reply("413 Content Too Large", r#"{"error":"body_limit"}"#)),
            }
        }
        _ => Err(reply("400 Bad Request", r#"{"error":"invalid_content_length"}"#)),
    }
}

/// A WebSocket opening handshake as RFC 6455 §4.2.1 requires it.
// RFC 6455 requires a base64-encoded 16-byte nonce. Reject noncanonical
// encodings as well as malformed characters, without adding a runtime crate.
fn valid_websocket_key(key: &str) -> bool {
    let bytes = key.as_bytes();
    if bytes.len() != 24 || &bytes[22..] != b"==" {
        return false;
    }
    let digit = |b: u8| -> Option<u8> {
        match b {
            b'A'..=b'Z' => Some(b - b'A'),
            b'a'..=b'z' => Some(b - b'a' + 26),
            b'0'..=b'9' => Some(b - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    };
    let Some(last) = digit(bytes[21]) else { return false };
    bytes[..21].iter().all(|&b| digit(b).is_some()) && last & 0x0f == 0
}

fn is_websocket_upgrade(head: &Head) -> bool {
    let key_ok = head.count("sec-websocket-key") == 1
        && head.header("sec-websocket-key").is_some_and(valid_websocket_key);
    head.has_token("upgrade", "websocket")
        && head.has_token("connection", "upgrade")
        && head.header("sec-websocket-version") == Some("13")
        && head.count("host") == 1
        && key_ok
}

/// The response for a parsed request. Exact, method-restricted routes only:
/// never a wildcard proxy to Apple.
fn route(head: &Head) -> Response {
    let method = head.method.as_str();
    match head.path.as_str() {
        "/healthz" if method == "GET" => reply("200 OK", r#"{"status":"offline_only"}"#),
        "/healthz" => not_allowed("GET"),
        "/v3/client_info" if method == "GET" => reply("503 Service Unavailable", OFFLINE),
        "/v3/client_info" => not_allowed("GET"),
        "/v3/get_headers" if method == "POST" => {
            if !head.header("content-type").is_some_and(|t| t.split(';').next().unwrap_or("").trim().eq_ignore_ascii_case("application/json")) {
                return reply("415 Unsupported Media Type", r#"{"error":"json_required"}"#);
            }
            reply("503 Service Unavailable", OFFLINE)
        }
        "/v3/get_headers" => not_allowed("POST"),
        "/v3/provisioning_session" if method == "GET" => {
            if head.count("upgrade") == 0 {
                return Response { status: "426 Upgrade Required", body: r#"{"error":"websocket_required"}"#, allow: None, upgrade: true };
            }
            if !is_websocket_upgrade(head) {
                return reply("400 Bad Request", r#"{"error":"invalid_websocket_upgrade"}"#);
            }
            // A valid upgrade is still refused: never 101 while offline.
            reply("503 Service Unavailable", OFFLINE)
        }
        "/v3/provisioning_session" => not_allowed("GET"),
        _ => reply("404 Not Found", r#"{"error":"not_found"}"#),
    }
}

/// The response for a complete request: head (with its terminating blank
/// line) and the declared body length.
fn respond(request_head: &[u8]) -> (Response, usize) {
    let head = match parse(request_head) {
        Ok(head) => head,
        Err(response) => return (response, 0),
    };
    match body_length(&head) {
        Ok(length) if length > 0 && head.method != "POST" => (reply("400 Bad Request", r#"{"error":"unexpected_body"}"#), 0),
        Ok(length) => (route(&head), length),
        Err(response) => (response, 0),
    }
}

/// Reads with the time left before `deadline`; an expired deadline is a timeout.
fn read_before(stream: &mut TcpStream, buf: &mut [u8], deadline: Instant) -> std::io::Result<usize> {
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() {
        return Err(std::io::ErrorKind::TimedOut.into());
    }
    stream.set_read_timeout(Some(left))?;
    stream.read(buf)
}

fn offline_socket_enabled() -> bool {
    std::env::var("ZAG_ANISETTE_OFFLINE_WS_TEST").ok().as_deref() == Some("1")
}

fn handle(stream: TcpStream) -> std::io::Result<()> {
    handle_with_offline_mode(stream, offline_socket_enabled())
}

fn handle_with_offline_mode(mut stream: TcpStream, offline_mode: bool) -> std::io::Result<()> {
    let deadline = Instant::now() + REQUEST_DEADLINE;
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;
    let mut buf = vec![0u8; MAX_HEADER];
    let mut count = 0;
    let end = loop {
        if let Some(i) = buf[..count].windows(4).position(|w| w == b"\r\n\r\n") {
            break Some(i);
        }
        if count == MAX_HEADER {
            break None;
        }
        match read_before(&mut stream, &mut buf[count..], deadline) {
            Ok(0) => return Ok(()), // closed before a complete request: nothing to answer
            Ok(n) => count += n,
            Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {
                let _ = stream.write_all(&reply("408 Request Timeout", r#"{"error":"timeout"}"#).bytes());
                return Ok(());
            }
            Err(e) => return Err(e),
        }
    };
    let (response, body) = match end {
        None => (reply("431 Request Header Fields Too Large", r#"{"error":"header_limit"}"#), 0),
        Some(i) => respond(&buf[..i]),
    };
    // Explicit loopback-only test mode. The request bytes consumed by the
    // HTTP parser are replayed to Tungstenite, including any coalesced data.
    // The only backend available here is OfflineBackend, which cannot
    // generate provisioning credentials.
    if offline_mode && response.status == "503 Service Unavailable" {
        if let Some(i) = end {
            if let Ok(head) = parse(&buf[..i]) {
                if head.path == "/v3/provisioning_session"
                    && head.method == "GET"
                    && is_websocket_upgrade(&head)
                    && body == 0
                {
                    let prefix = buf[..count].to_vec();
                    buf.fill(0);
                    return websocket_transport::serve_offline_socket(stream, prefix)
                        .map_err(std::io::Error::other);
                }
            }
        }
    }
    // Drain (and discard) the declared body so the client reads the response
    // rather than a reset. Nothing of it is kept.
    let mut left = body.saturating_sub(count - end.map_or(count, |i| i + 4));
    let mut sink = [0u8; 4096];
    while left > 0 {
        match read_before(&mut stream, &mut sink[..left.min(4096)], deadline) {
            Ok(0) | Err(_) => break,
            Ok(n) => left -= n,
        }
    }
    sink.fill(0);
    buf.fill(0);
    stream.write_all(&response.bytes())?;
    let _ = stream.shutdown(Shutdown::Write);
    // Read (and discard) anything still arriving, bounded, so closing does
    // not reset the connection before the client has read the response.
    let linger = (Instant::now() + Duration::from_secs(1)).min(deadline);
    let mut drained = 0;
    while drained < MAX_BODY {
        match read_before(&mut stream, &mut sink, linger) {
            Ok(0) | Err(_) => break,
            Ok(n) => drained += n,
        }
    }
    sink.fill(0);
    Ok(())
}

/// Loopback only: an explicitly configured HTTPS reverse proxy goes in front.
fn bind_address(configured: Option<&str>) -> Result<SocketAddr, String> {
    let text = configured.unwrap_or(DEFAULT_BIND);
    let address: SocketAddr = text.parse().map_err(|_| format!("invalid bind address {text:?}"))?;
    if !address.ip().is_loopback() {
        return Err(format!("refusing to bind to a non-loopback address ({address})"));
    }
    Ok(address)
}

fn serve(listener: TcpListener) {
    let active = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        if active.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
            active.fetch_sub(1, Ordering::SeqCst);
            // Read what has arrived (briefly, discarded) so the reply is not
            // lost to a reset, then refuse.
            let _ = stream.set_read_timeout(Some(Duration::from_millis(100)));
            let mut discard = [0u8; MAX_HEADER];
            let _ = stream.read(&mut discard);
            let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
            let _ = stream.write_all(&reply("503 Service Unavailable", r#"{"error":"busy"}"#).bytes());
            let _ = stream.shutdown(Shutdown::Write);
            continue;
        }
        let active = Arc::clone(&active);
        thread::spawn(move || {
            let _ = handle(stream);
            active.fetch_sub(1, Ordering::SeqCst);
        });
    }
}

fn main() {
    let address = match bind_address(std::env::var("ZAG_ANISETTE_BIND").ok().as_deref()) {
        Ok(address) => address,
        Err(message) => {
            eprintln!("zag-anisette-server: {message}");
            std::process::exit(2);
        }
    };
    let listener = match TcpListener::bind(address) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("zag-anisette-server: cannot bind {address}: {}", error.kind());
            std::process::exit(1);
        }
    };
    // The only output: no request data is ever written anywhere.
    eprintln!("zag-anisette-server: offline-only, listening on {address}");
    serve(listener);
}

#[cfg(test)]
mod session_worker;
#[cfg(test)]
mod session_supervisor;

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "dGhlIHNhbXBsZSBub25jZQ==";

    fn status(request: &str) -> String {
        let head = request.strip_suffix("\r\n\r\n").expect("test requests end with a blank line");
        let (response, _) = respond(head.as_bytes());
        response.status.to_string()
    }

    fn upgrade(extra: &str) -> String {
        format!("GET /v3/provisioning_session HTTP/1.1\r\nHost: anisette.example\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {KEY}\r\nSec-WebSocket-Version: 13\r\n{extra}\r\n")
    }

    // Routes, as the fork's v3 client calls them.
    #[test]
    fn health() {
        assert_eq!(status("GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n"), "200 OK");
        assert_eq!(status("POST /healthz HTTP/1.1\r\nHost: x\r\n\r\n"), "405 Method Not Allowed");
    }
    #[test]
    fn client_info_is_offline() {
        assert_eq!(status("GET /v3/client_info HTTP/1.1\r\nHost: x\r\n\r\n"), "503 Service Unavailable");
    }
    #[test]
    fn client_info_post_is_rejected() {
        assert_eq!(status("POST /v3/client_info HTTP/1.1\r\nHost: x\r\n\r\n"), "405 Method Not Allowed");
        assert!(String::from_utf8(not_allowed("GET").bytes()).unwrap().contains("\r\nAllow: GET\r\n"));
    }
    #[test]
    fn get_headers_never_provisions() {
        let json = "POST /v3/get_headers HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n";
        assert_eq!(status(json), "503 Service Unavailable");
        assert_eq!(status("POST /v3/get_headers HTTP/1.1\r\nHost: x\r\nContent-Type: application/json; charset=utf-8\r\n\r\n"), "503 Service Unavailable");
    }
    #[test]
    fn get_headers_requires_post_and_json() {
        assert_eq!(status("GET /v3/get_headers HTTP/1.1\r\nHost: x\r\n\r\n"), "405 Method Not Allowed");
        assert_eq!(status("POST /v3/get_headers HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\n\r\n"), "415 Unsupported Media Type");
    }
    #[test]
    fn valid_websocket_upgrade_is_refused_never_switched() {
        let (response, _) = respond(upgrade("").trim_end_matches("\r\n").as_bytes());
        assert_eq!(response.status, "503 Service Unavailable");
        assert!(!String::from_utf8(response.bytes()).unwrap().contains("101"));
    }
    #[test]
    fn websocket_key_is_canonical() {
        assert!(valid_websocket_key(KEY));
        assert!(!valid_websocket_key("AAAAAAAAAAAAAAAAAAAAAB=="));
        assert!(valid_websocket_key("AAAAAAAAAAAAAAAAAAAAAA=="));
        assert!(!valid_websocket_key("AAAAAAAAAAAAAAAAAAAAAA="));
        assert!(!valid_websocket_key("AAAAAAAAAAAAAAAAAAAAA/=="));
        assert!(!valid_websocket_key("AAAAAAAAAAAAAAAAAAAAA-=="));
    }
    #[test]
    fn websocket_upgrade_requirements() {
        assert_eq!(status("GET /v3/provisioning_session HTTP/1.1\r\nHost: x\r\n\r\n"), "426 Upgrade Required");
        assert_eq!(status("POST /v3/provisioning_session HTTP/1.1\r\nHost: x\r\n\r\n"), "405 Method Not Allowed");
        let broken = [
            upgrade("").replace("Sec-WebSocket-Version: 13", "Sec-WebSocket-Version: 8"),
            upgrade("").replace(KEY, "short=="),
            upgrade("").replace("Connection: Upgrade", "Connection: keep-alive"),
            upgrade("").replace("Host: anisette.example\r\n", ""),
            upgrade(&format!("Sec-WebSocket-Key: {KEY}\r\n")),
        ];
        for request in broken {
            assert_eq!(status(&request), "400 Bad Request", "{request}");
        }
        // Token lists and case, as clients send them.
        assert_eq!(status(&upgrade("").replace("Connection: Upgrade", "Connection: keep-alive, upgrade")), "503 Service Unavailable");
    }
    #[test]
    fn unknown_and_public_routes_are_not_found() {
        for path in ["/", "/v3/unknown", "/v3", "/v1", "/v3/client_info/", "/V3/client_info"] {
            assert_eq!(status(&format!("GET {path} HTTP/1.1\r\nHost: x\r\n\r\n")), "404 Not Found", "{path}");
        }
    }

    // Request parsing.
    #[test]
    fn malformed_requests() {
        for request in [
            "GET /healthz HTTP/1.1 extra\r\n\r\n",
            "get /healthz HTTP/1.1\r\n\r\n",
            "GET http://apple.com/ HTTP/1.1\r\n\r\n",
            "CONNECT gsa.apple.com:443 HTTP/1.1\r\n\r\n",
            "GET /healthz#x HTTP/1.1\r\n\r\n",
            "GET /healthz HTTP/1.1\r\nNo-Colon\r\n\r\n",
            "GET /healthz HTTP/1.1\r\nA: b\r\n folded\r\n\r\n",
            "GET /healthz HTTP/1.1\r\nBad Name: x\r\n\r\n",
            "GET /healthz HTTP/1.1\\r\\n\r\n\r\n",
        ] {
            assert_eq!(status(request), "400 Bad Request", "{request:?}");
        }
        assert_eq!(status("GET /healthz HTTP/1.0\r\n\r\n"), "505 HTTP Version Not Supported");
        assert_eq!(respond(&[0xff, 0xfe]).0.status, "400 Bad Request");
    }
    #[test]
    fn bodies_and_smuggling() {
        let post = "POST /v3/get_headers HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n";
        assert_eq!(status(&format!("{post}Transfer-Encoding: chunked\r\n\r\n")), "400 Bad Request");
        assert_eq!(status(&format!("{post}Content-Length: 2\r\nContent-Length: 3\r\n\r\n")), "400 Bad Request");
        assert_eq!(status(&format!("{post}Content-Length: -1\r\n\r\n")), "400 Bad Request");
        assert_eq!(status(&format!("{post}Content-Length: 999999999\r\n\r\n")), "413 Content Too Large");
        assert_eq!(status("GET /v3/client_info HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n"), "400 Bad Request");
        assert_eq!(respond(format!("{post}Content-Length: 65536").as_bytes()).1, MAX_BODY);
    }
    #[test]
    fn bind_is_loopback_only() {
        assert_eq!(bind_address(None).unwrap().to_string(), DEFAULT_BIND);
        assert!(bind_address(Some("[::1]:9000")).is_ok());
        assert!(bind_address(Some("0.0.0.0:18760")).is_err());
        assert!(bind_address(Some("91.98.120.230:18760")).is_err());
        assert!(bind_address(Some("[::]:18760")).is_err());
        assert!(bind_address(Some("nonsense")).is_err());
        // 18743–18745 are production services on zagstore-prod-01.
        assert!(!(18743..=18745).contains(&bind_address(None).unwrap().port()));
    }
    #[test]
    fn writes_no_request_data() {
        let source = include_str!("main.rs");
        let production = &source[..source.find("#[cfg(test)]").unwrap()];
        assert_eq!(production.matches("eprintln!").count(), 3, "only the startup and bind-failure messages");
        assert!(!production.replace("eprintln!(", "").contains("println!("));
        for forbidden in ["dbg!(", "log::", "tracing::", "std::fs", "File::", "TcpStream::connect", "UdpSocket"] {
            assert!(!production.contains(forbidden), "{forbidden}");
        }
    }

    // Over a real socket.
    fn server() -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || serve(listener));
        address
    }
    fn exchange(address: SocketAddr, request: &[u8]) -> String {
        let mut stream = TcpStream::connect(address).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        stream.write_all(request).unwrap();
        let mut out = String::new();
        stream.read_to_string(&mut out).unwrap();
        out
    }
    #[test]
    fn socket_routes_and_body_drain() {
        let address = server();
        assert!(exchange(address, b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n").starts_with("HTTP/1.1 200 OK"));
        let body = "{\"identifier\":\"AAAA\",\"adi_pb\":\"BBBB\"}";
        let post = format!("POST /v3/get_headers HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len());
        let out = exchange(address, post.as_bytes());
        assert!(out.starts_with("HTTP/1.1 503") && !out.contains("BBBB"), "{out}");
        assert!(exchange(address, upgrade("").as_bytes()).starts_with("HTTP/1.1 503"));
        let large = vec![b'a'; MAX_HEADER + 10];
        assert!(exchange(address, &large).starts_with("HTTP/1.1 431"));
    }
    #[test]
    fn slow_client_times_out_and_does_not_block_others() {
        let address = server();
        let mut slow = TcpStream::connect(address).unwrap();
        slow.write_all(b"GET /heal").unwrap();
        let started = Instant::now();
        assert!(exchange(address, b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n").starts_with("HTTP/1.1 200 OK"));
        assert!(started.elapsed() < Duration::from_secs(2), "a slow client blocked another");
        slow.set_read_timeout(Some(REQUEST_DEADLINE + Duration::from_secs(5))).unwrap();
        let mut out = String::new();
        let _ = slow.read_to_string(&mut out);
        assert!(out.starts_with("HTTP/1.1 408"), "{out}");
    }
    #[test]
    fn real_websocket_client_is_refused() {
        // tungstenite 0.29 (the fork's) performs a standard client handshake:
        // the upgrade must fail with the 503, never switch protocols.
        let address = server();
        let url = format!("ws://{address}/v3/provisioning_session");
        let stream = TcpStream::connect(address).unwrap();
        match tungstenite::client(url.as_str(), stream) {
            Err(tungstenite::HandshakeError::Failure(tungstenite::Error::Http(response))) => assert_eq!(response.status().as_u16(), 503),
            Err(other) => panic!("unexpected handshake failure: {other}"),
            Ok(_) => panic!("the upgrade switched protocols"),
        }
    }
    #[test]
    fn connection_cap() {
        let address = server();
        let held: Vec<TcpStream> = (0..MAX_CONNECTIONS).map(|_| TcpStream::connect(address).unwrap()).collect();
        thread::sleep(Duration::from_millis(200));
        assert!(exchange(address, b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n").starts_with("HTTP/1.1 503"));
        drop(held);
        let deadline = Instant::now() + REQUEST_DEADLINE + Duration::from_secs(5);
        while Instant::now() < deadline {
            if exchange(address, b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n").starts_with("HTTP/1.1 200") {
                return;
            }
            thread::sleep(Duration::from_millis(100));
        }
        panic!("capacity was not released");
    }
}

#[cfg(test)]
mod offline_http_websocket_integration {
    use super::*;
    use tungstenite::Message;

    #[test]
    fn http_listener_hands_off_websocket_with_buffered_handshake() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            handle_with_offline_mode(stream, true)
        });
        let stream = TcpStream::connect(address).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let (mut ws, response) = tungstenite::client(
            format!("ws://{address}/v3/provisioning_session"), stream
        ).unwrap();
        assert_eq!(response.status().as_u16(), 101);
        let first: serde_json::Value =
            serde_json::from_str(&ws.read().unwrap().into_text().unwrap()).unwrap();
        assert_eq!(first["result"], "GiveIdentifier");
        ws.send(Message::Text(r#"{"identifier":"offline-test"}"#.into())).unwrap();
        let second: serde_json::Value =
            serde_json::from_str(&ws.read().unwrap().into_text().unwrap()).unwrap();
        assert_eq!(second["result"], "GiveStartProvisioningData");
        ws.send(Message::Text(r#"{"spim":"offline-test"}"#.into())).unwrap();
        let third: serde_json::Value =
            serde_json::from_str(&ws.read().unwrap().into_text().unwrap()).unwrap();
        assert_eq!(third["result"], "StartProvisioningError");
        assert_eq!(third["message"], "backend_not_enabled");
        assert!(worker.join().unwrap().is_ok());
    }

    #[test]
    fn disabled_mode_refuses_upgrade() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            handle_with_offline_mode(stream, false)
        });
        let stream = TcpStream::connect(address).unwrap();
        let result = tungstenite::client(
            format!("ws://{address}/v3/provisioning_session"), stream
        );
        assert!(result.is_err());
        assert!(worker.join().unwrap().is_ok());
    }
}
