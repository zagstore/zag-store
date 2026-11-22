//! WebSocket transport for `/v3/provisioning_session`. Without the native
//! backend the listener refuses every upgrade with 503 (the offline harness
//! below is test-only). With it, `serve_native_socket` runs the session.
//! Unit tests exercise real RFC 6455 framing over loopback.
#![allow(dead_code)]
use std::{io::{Read, Write}, net::TcpStream, time::Duration};
use tungstenite::{accept_with_config, protocol::WebSocketConfig, Message};

use crate::native_backend::{parse_identifier, NativeBackend};
use crate::provisioning::{
    decode_client_message, encode_server_message, process_text_frame, AdiBackend, ClientMessage,
    OfflineBackend, Phase, ProtocolError, Session, SessionOwnedAdiProvider,
};

const MAX_FRAME: usize = 64 * 1024;

/// Replay HTTP handshake bytes already read by the outer parser.
pub struct PrefixedStream {
    prefix: std::io::Cursor<Vec<u8>>,
    stream: TcpStream,
}
impl PrefixedStream {
    pub fn new(stream: TcpStream, prefix: Vec<u8>) -> Self {
        Self { prefix: std::io::Cursor::new(prefix), stream }
    }
}
impl Read for PrefixedStream {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        let n = self.prefix.read(out)?;
        if n != 0 { Ok(n) } else { self.stream.read(out) }
    }
}
impl Write for PrefixedStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> { self.stream.write(buf) }
    fn flush(&mut self) -> std::io::Result<()> { self.stream.flush() }
}


/// Serve a single local test connection using the real WebSocket protocol.
/// The backend remains unavailable; no successful provisioning is possible.
pub fn serve_offline_socket(stream: TcpStream, request_prefix: Vec<u8>) -> Result<(), String> {
    stream.set_read_timeout(Some(Duration::from_secs(5))).map_err(|e| e.to_string())?;
    stream.set_write_timeout(Some(Duration::from_secs(5))).map_err(|e| e.to_string())?;
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(MAX_FRAME);
    config.max_frame_size = Some(MAX_FRAME);
    let mut socket = accept_with_config(PrefixedStream::new(stream, request_prefix), Some(config))
        .map_err(|e| e.to_string())?;
    let mut session = Session::new(OfflineBackend);
    socket.send(Message::Text(encode_server_message(&session.initial()).into())).map_err(|e| e.to_string())?;
    loop {
        match socket.read() {
            Ok(Message::Text(frame)) => {
                if frame.len() > MAX_FRAME {
                    let _ = socket.close(None);
                    return Err("frame_limit".into());
                }
                match process_text_frame(&mut session, frame.as_str()) {
                    Ok(reply) => socket.send(Message::Text(reply.into())).map_err(|e| e.to_string())?,
                    Err(ProtocolError::BackendUnavailable) => {
                        let failure = serde_json::json!({"result":"StartProvisioningError","message":"backend_not_enabled"});
                        let _ = socket.send(Message::Text(failure.to_string().into()));
                        let _ = socket.close(None);
                        return Ok(());
                    }
                    Err(_) => {
                        let _ = socket.close(None);
                        return Err("invalid_provisioning_message".into());
                    }
                }
            }
            Ok(Message::Close(_)) => return Ok(()),
            Ok(Message::Ping(data)) => socket.send(Message::Pong(data)).map_err(|e| e.to_string())?,
            Ok(_) => { let _ = socket.close(None); return Err("unsupported_frame".into()); }
            Err(_) => return Err("socket_closed_or_timeout".into()),
        }
    }
}

/// Per-message wait: the client relays each step to Apple in between.
const MESSAGE_WAIT: Duration = Duration::from_secs(30);

fn send_json<S: Read + Write>(socket: &mut tungstenite::WebSocket<S>, value: serde_json::Value) -> Result<(), String> {
    socket.send(Message::Text(value.to_string().into())).map_err(|_| "send_failed".to_string())
}

/// The v3 provisioning session with the native backend, as anisette-v3-server
/// runs it and the Zag Store client (`remote_v3::provision`) expects:
/// GiveIdentifier, {identifier}, GiveStartProvisioningData, {spim},
/// GiveEndProvisioningData {cpim}, {ptm, tk}, ProvisioningSuccess {adi_pb}.
/// Failures are InvalidIdentifier, StartProvisioningError,
/// EndProvisioningError or Timeout, then close. The server contacts nothing:
/// the client relays spim, cpim, ptm and tk to and from Apple. No material is
/// kept or logged; the worker and its directory are gone when this returns.
pub fn serve_native_socket(stream: TcpStream, request_prefix: Vec<u8>, backend: &NativeBackend) -> Result<(), String> {
    stream.set_read_timeout(Some(MESSAGE_WAIT)).map_err(|_| "socket_setup".to_string())?;
    stream.set_write_timeout(Some(Duration::from_secs(5))).map_err(|_| "socket_setup".to_string())?;
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(MAX_FRAME);
    config.max_frame_size = Some(MAX_FRAME);
    let mut socket = accept_with_config(PrefixedStream::new(stream, request_prefix), Some(config))
        .map_err(|_| "handshake_failed".to_string())?;
    let mut session = Session::new(AdiBackend::new(SessionOwnedAdiProvider::new(backend.session())));
    socket.send(Message::Text(encode_server_message(&session.initial()).into())).map_err(|_| "send_failed".to_string())?;
    let result = loop {
        let frame = match socket.read() {
            Ok(Message::Text(frame)) => frame,
            Ok(Message::Ping(data)) => { socket.send(Message::Pong(data)).map_err(|_| "send_failed".to_string())?; continue; }
            Ok(Message::Close(_)) => break Ok(()),
            Ok(_) => break Err("unsupported_frame".to_string()),
            Err(tungstenite::Error::Io(error)) if matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {
                let _ = send_json(&mut socket, serde_json::json!({"result": "Timeout"}));
                break Err("timeout".to_string());
            }
            Err(_) => break Err("socket_closed".to_string()),
        };
        let phase = session.phase();
        if phase == Phase::AwaitIdentifier {
            let valid = matches!(decode_client_message(frame.as_str()),
                Ok(ClientMessage::Identifier(ref id)) if parse_identifier(id).is_ok());
            if !valid {
                let _ = send_json(&mut socket, serde_json::json!({"result": "InvalidIdentifier"}));
                break Err("invalid_identifier".to_string());
            }
        }
        match process_text_frame(&mut session, frame.as_str()) {
            Ok(reply) => {
                socket.send(Message::Text(reply.into())).map_err(|_| "send_failed".to_string())?;
                if session.phase() == Phase::Complete { break Ok(()); }
            }
            Err(error) => {
                let (result, message) = match (phase, error) {
                    (Phase::AwaitFinish, ProtocolError::InvalidField) => ("EndProvisioningError", "invalid ptm or tk"),
                    (Phase::AwaitFinish, _) => ("EndProvisioningError", "native ADI rejected the provisioning data"),
                    (_, ProtocolError::InvalidField) => ("StartProvisioningError", "invalid spim"),
                    (_, ProtocolError::InvalidTransition) => ("StartProvisioningError", "unexpected message"),
                    (_, ProtocolError::BackendUnavailable) => ("StartProvisioningError", "native ADI rejected the provisioning data"),
                };
                let _ = send_json(&mut socket, serde_json::json!({"result": result, "message": message}));
                break Err("provisioning_failed".to_string());
            }
        }
    };
    let _ = socket.close(None);
    let _ = socket.flush();
    // The session (and with it the worker and its directory) ends here.
    drop(session);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{net::TcpListener, thread};

    #[test]
    fn real_websocket_offline_handshake_and_fail_closed() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            serve_offline_socket(stream, Vec::new())
        });
        let stream = TcpStream::connect(address).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let (mut ws, _) = tungstenite::client(format!("ws://{address}/v3/provisioning_session"), stream).unwrap();
        let first = ws.read().unwrap().into_text().unwrap();
        assert_eq!(first.as_str(), encode_server_message(&crate::provisioning::ServerMessage::GiveIdentifier));
        ws.send(Message::Text(r#"{"identifier":"test-id"}"#.into())).unwrap();
        let second: serde_json::Value = serde_json::from_str(&ws.read().unwrap().into_text().unwrap()).unwrap();
        assert_eq!(second["result"], "GiveStartProvisioningData");
        ws.send(Message::Text(r#"{"spim":"test-spim"}"#.into())).unwrap();
        let third: serde_json::Value = serde_json::from_str(&ws.read().unwrap().into_text().unwrap()).unwrap();
        assert_eq!(third["result"], "StartProvisioningError");
        assert_eq!(third["message"], "backend_not_enabled");
        assert!(worker.join().unwrap().is_ok());
    }
}
