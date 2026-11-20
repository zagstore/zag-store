//! Zag-owned minimal anisette HTTP service scaffold.
//! Offline-only: provisioning endpoints deliberately return 503 until a reviewed backend exists.
//! No third-party server source code is used.
use std::{io::{Read, Write}, net::{TcpListener, TcpStream}, time::Duration};

const MAX_HEADER: usize = 8192;
fn response(code: &str, body: &str) -> Vec<u8> {
    format!("HTTP/1.1 {code}\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}", body.len()).into_bytes()
}
fn route(request: &[u8]) -> Vec<u8> {
    let first = request.split(|b| *b == b'\n').next().unwrap_or_default();
    let first = match std::str::from_utf8(first) { Ok(s) => s.trim_end_matches('\r'), Err(_) => return response("400 Bad Request", r#"{"error":"invalid_request"}"#) };
    let mut parts = first.split(' ');
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("");
    if parts.next() != Some("HTTP/1.1") || parts.next().is_some() {
        return response("400 Bad Request", r#"{"error":"invalid_request"}"#);
    }
    if method == "GET" && path == "/healthz" {
        return response("200 OK", r#"{"status":"offline_only"}"#);
    }
    // Exact, method-restricted routes only: never expose a wildcard proxy to Apple.
    if matches!(path, "/v3/client_info" | "/v3/get_headers" | "/v3/provisioning_session") {
        if (path == "/v3/client_info" && method != "GET") || (path == "/v3/get_headers" && method != "POST") { return response("405 Method Not Allowed", r#"{"error":"method_not_allowed"}"#); }
        return response("503 Service Unavailable", r#"{"error":"provisioning_backend_not_enabled"}"#);
    }
    if path.starts_with("/v3/") { return response("404 Not Found", r#"{"error":"not_found"}"#); }
    response("404 Not Found", r#"{"error":"not_found"}"#)
}
fn handle(mut stream: TcpStream) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;
    let mut buf = [0u8; MAX_HEADER];
    let mut count = 0;
    while count < MAX_HEADER {
        let n = stream.read(&mut buf[count..])?;
        if n == 0 { break; }
        count += n;
        if buf[..count].windows(4).any(|w| w == b"\r\n\r\n") { break; }
    }
    let reply = if !buf[..count].windows(4).any(|w| w == b"\r\n\r\n") {
        response("431 Request Header Fields Too Large", r#"{"error":"header_limit"}"#)
    } else { route(&buf[..count]) };
    stream.write_all(&reply)
}
fn main() -> std::io::Result<()> {
    // Loopback only. Put an explicitly configured HTTPS reverse proxy in front.
    let listener = TcpListener::bind("127.0.0.1:18744")?;
    for stream in listener.incoming() {
        if let Ok(stream) = stream { let _ = handle(stream); }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn health() { assert!(String::from_utf8(route(b"GET /healthz HTTP/1.1\r\n")).unwrap().contains("200 OK")); }
    #[test] fn never_provisions() { assert!(String::from_utf8(route(b"POST /v3/get_headers HTTP/1.1\r\n")).unwrap().contains("503 Service Unavailable")); }
    #[test] fn unknown_v3_is_not_proxied() { assert!(String::from_utf8(route(b"POST /v3/unknown HTTP/1.1\r\n")).unwrap().contains("404 Not Found")); }
    #[test] fn get_cannot_provision() { assert!(String::from_utf8(route(b"GET /v3/get_headers HTTP/1.1\r\n")).unwrap().contains("405 Method Not Allowed")); }
    #[test] fn client_info_is_offline() { assert!(String::from_utf8(route(b"GET /v3/client_info HTTP/1.1\r\n")).unwrap().contains("503 Service Unavailable")); }
    #[test] fn websocket_upgrade_is_disabled() { assert!(String::from_utf8(route(b"GET /v3/provisioning_session HTTP/1.1\r\n")).unwrap().contains("503 Service Unavailable")); }
    #[test] fn no_public_routes() { assert!(String::from_utf8(route(b"GET / HTTP/1.1\r\n")).unwrap().contains("404 Not Found")); }
}
