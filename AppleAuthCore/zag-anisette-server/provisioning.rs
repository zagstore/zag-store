//! Original, offline-testable v3 provisioning protocol state machine.
//! This module does not contact Apple, handle credentials, or load ADI libraries.
//! A production backend must implement the operations and pass separate review.
#![allow(dead_code)]

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ServerMessage {
    GiveIdentifier,
    GiveStartProvisioningData,
    GiveEndProvisioningData { cpim: String },
    ProvisioningSuccess { adi_pb: String },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClientMessage {
    Identifier(String),
    Spim(String),
    Finish { ptm: String, tk: String },
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    AwaitIdentifier,
    AwaitStart,
    AwaitFinish,
    Complete,
    Failed,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtocolError {
    InvalidTransition,
    InvalidField,
    BackendUnavailable,
}
pub trait ProvisioningBackend {
    fn start(&mut self, identifier: &str, spim: &str) -> Result<String, ProtocolError>;
    fn finish(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError>;
}
/// Offline-only adapter boundary for a future ADI provider.
///
/// This interface deliberately exposes no Apple transport, credential storage,
/// or dynamic library loading. Provider errors are mapped to terminal session
/// errors by Session; provider implementations must not log payloads.
pub trait AdiProvider {
    fn start_provisioning(&mut self, identifier: &str, spim: &str) -> Result<String, ProtocolError>;
    fn finish_provisioning(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError>;
}

pub struct AdiBackend<P> {
    provider: P,
}

impl<P: AdiProvider> AdiBackend<P> {
    pub fn new(provider: P) -> Self { Self { provider } }
}

impl<P: AdiProvider> ProvisioningBackend for AdiBackend<P> {
    fn start(&mut self, identifier: &str, spim: &str) -> Result<String, ProtocolError> {
        self.provider.start_provisioning(identifier, spim)
    }
    fn finish(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError> {
        self.provider.finish_provisioning(ptm, tk)
    }
}

/// Explicit, offline-only bridge from the provisioning contract to the
/// reviewed worker IPC. Constructing this adapter does not launch anything;
/// it is intentionally not registered with the HTTP/WebSocket listener.
pub struct OfflineWorkerAdiProvider {
    executable: std::path::PathBuf,
    timeout: std::time::Duration,
}

impl OfflineWorkerAdiProvider {
    pub fn new(executable: std::path::PathBuf, timeout: std::time::Duration) -> Self {
        Self { executable, timeout }
    }

    fn exchange(
        &self,
        request: crate::adi_worker_protocol::WorkerRequest,
    ) -> Result<crate::adi_worker_protocol::WorkerResponse, ProtocolError> {
        crate::adi_worker_lifecycle::execute_offline_worker(
            &self.executable, &self.executable, &request, self.timeout,
        ).map_err(|_| ProtocolError::BackendUnavailable)
    }
}

impl AdiProvider for OfflineWorkerAdiProvider {
    fn start_provisioning(&mut self, identifier: &str, spim: &str) -> Result<String, ProtocolError> {
        use crate::adi_worker_protocol::{WorkerRequest, WorkerResponse};
        match self.exchange(WorkerRequest::Start {
            identifier: identifier.into(), spim: spim.into(),
        })? {
            WorkerResponse::Started { cpim } => Ok(cpim),
            _ => Err(ProtocolError::BackendUnavailable),
        }
    }

    fn finish_provisioning(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError> {
        use crate::adi_worker_protocol::{WorkerRequest, WorkerResponse};
        match self.exchange(WorkerRequest::Finish {
            ptm: ptm.into(), tk: tk.into(),
        })? {
            WorkerResponse::Finished { adi_pb } => Ok(adi_pb),
            _ => Err(ProtocolError::BackendUnavailable),
        }
    }
}

/// A session-owned native transport. The same transport instance must survive
/// Start and Finish; dropping it must cancel and reap its native child.
/// This boundary is deliberately not connected to the network listener.
pub trait NativeSessionTransport {
    fn start(&mut self, identifier: &str, spim: &str) -> Result<String, ProtocolError>;
    fn finish(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError>;
    fn abort(&mut self);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NativePhase { Fresh, AwaitFinish, Terminal }

/// Owns exactly one native transport for the entire provisioning exchange.
/// No executable path, native session handle, or Apple material is exposed.
pub struct SessionOwnedAdiProvider<T: NativeSessionTransport> {
    transport: T,
    phase: NativePhase,
}

impl<T: NativeSessionTransport> SessionOwnedAdiProvider<T> {
    pub fn new(transport: T) -> Self {
        Self { transport, phase: NativePhase::Fresh }
    }
}

impl<T: NativeSessionTransport> AdiProvider for SessionOwnedAdiProvider<T> {
    fn start_provisioning(&mut self, identifier: &str, spim: &str) -> Result<String, ProtocolError> {
        if self.phase != NativePhase::Fresh { return Err(ProtocolError::InvalidTransition); }
        // Mark terminal before crossing the native boundary: a failed Start
        // must never be retried against an ambiguous native handle.
        self.phase = NativePhase::Terminal;
        match self.transport.start(identifier, spim) {
            Ok(cpim) if field_ok(&cpim) => {
                self.phase = NativePhase::AwaitFinish;
                Ok(cpim)
            }
            Ok(_) => {
                self.transport.abort();
                Err(ProtocolError::InvalidField)
            }
            Err(error) => {
                self.transport.abort();
                Err(error)
            }
        }
    }

    fn finish_provisioning(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError> {
        if self.phase != NativePhase::AwaitFinish { return Err(ProtocolError::InvalidTransition); }
        self.phase = NativePhase::Terminal;
        match self.transport.finish(ptm, tk) {
            Ok(adi_pb) if field_ok(&adi_pb) => Ok(adi_pb),
            Ok(_) => {
                self.transport.abort();
                Err(ProtocolError::InvalidField)
            }
            Err(error) => {
                self.transport.abort();
                Err(error)
            }
        }
    }
}

impl<T: NativeSessionTransport> Drop for SessionOwnedAdiProvider<T> {
    fn drop(&mut self) {
        // Abort even after successful Finish: implementations must make
        // cleanup idempotent; never retry a native handle destruction.
        self.transport.abort();
    }
}

/// Offline-only adapter for the existing session-scoped worker backend.
/// This exercises the same native-session ownership contract without loading
/// Apple libraries or enabling the HTTP listener. It is not a subprocess.
#[cfg(test)]
pub struct OfflineSessionTransport<B: crate::session_worker::SessionBackend> {
    session: crate::session_worker::Session<B>,
}
#[cfg(test)]
impl<B: crate::session_worker::SessionBackend> OfflineSessionTransport<B> {
    pub fn new(backend: B) -> Self {
        Self { session: crate::session_worker::Session::new(backend) }
    }
}
#[cfg(test)]
impl<B: crate::session_worker::SessionBackend> NativeSessionTransport for OfflineSessionTransport<B> {
    fn start(&mut self, identifier: &str, spim: &str) -> Result<String, ProtocolError> {
        self.session.start(identifier, spim).map_err(|_| ProtocolError::BackendUnavailable)
    }
    fn finish(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError> {
        self.session.finish(ptm, tk).map_err(|_| ProtocolError::BackendUnavailable)
    }
    fn abort(&mut self) { self.session.cancel(); }
}

/// Test-only bridge from the text provisioning protocol to binary v2 IPC.
/// Text fields here are lowercase hex, solely for the deterministic fixture;
/// real Apple protocol field encoding requires separate validation.
#[cfg(test)]
pub struct OfflineSplitChildTransport {
    child: crate::session_supervisor::SplitV2Session,
    cancel: std::sync::atomic::AtomicBool,
}
#[cfg(test)]
impl OfflineSplitChildTransport {
    pub fn spawn(path: &std::path::Path, args: &[&str], timeout: std::time::Duration)
        -> Result<Self, ProtocolError> {
        Ok(Self {
            child: crate::session_supervisor::SplitV2Session::spawn(path, args, timeout)
                .map_err(|_| ProtocolError::BackendUnavailable)?,
            cancel: std::sync::atomic::AtomicBool::new(false),
        })
    }
    fn decode_hex(text: &str) -> Result<Vec<u8>, ProtocolError> {
        if text.is_empty() || text.len() % 2 != 0 { return Err(ProtocolError::InvalidField); }
        text.as_bytes().chunks_exact(2).map(|pair| {
            let digit = |b: u8| match b {
                b'0'..=b'9' => Ok(b - b'0'),
                b'a'..=b'f' => Ok(b - b'a' + 10),
                _ => Err(ProtocolError::InvalidField),
            };
            Ok((digit(pair[0])? << 4) | digit(pair[1])?)
        }).collect()
    }
    fn encode_hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }
}
#[cfg(test)]
impl NativeSessionTransport for OfflineSplitChildTransport {
    fn start(&mut self, identifier: &str, spim: &str) -> Result<String, ProtocolError> {
        use crate::adi_worker_wire_v2::{Request, Response};
        let request = Request::Start {
            identifier: identifier.into(), spim: Self::decode_hex(spim)?,
        };
        match self.child.exchange(&request, &self.cancel)
            .map_err(|_| ProtocolError::BackendUnavailable)? {
            Response::Started(bytes) => Ok(Self::encode_hex(&bytes)),
            _ => Err(ProtocolError::BackendUnavailable),
        }
    }
    fn finish(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError> {
        use crate::adi_worker_wire_v2::{Request, Response};
        let request = Request::Finish {
            ptm: Self::decode_hex(ptm)?, tk: Self::decode_hex(tk)?,
        };
        match self.child.exchange(&request, &self.cancel)
            .map_err(|_| ProtocolError::BackendUnavailable)? {
            Response::Finished(bytes) => Ok(Self::encode_hex(&bytes)),
            _ => Err(ProtocolError::BackendUnavailable),
        }
    }
    fn abort(&mut self) {
        self.cancel.store(true, std::sync::atomic::Ordering::Release);
    }
}

/// Safe default: provider never produces Apple provisioning material.
pub struct DisabledAdiProvider;
impl AdiProvider for DisabledAdiProvider {
    fn start_provisioning(&mut self, _: &str, _: &str) -> Result<String, ProtocolError> {
        Err(ProtocolError::BackendUnavailable)
    }
    fn finish_provisioning(&mut self, _: &str, _: &str) -> Result<String, ProtocolError> {
        Err(ProtocolError::BackendUnavailable)
    }
}
pub struct OfflineBackend;
impl ProvisioningBackend for OfflineBackend {
    fn start(&mut self, _: &str, _: &str) -> Result<String, ProtocolError> { Err(ProtocolError::BackendUnavailable) }
    fn finish(&mut self, _: &str, _: &str) -> Result<String, ProtocolError> { Err(ProtocolError::BackendUnavailable) }
}
pub struct Session<B> {
    backend: B,
    phase: Phase,
    identifier: Option<String>,
}
fn field_ok(value: &str) -> bool {
    !value.is_empty() && value.len() <= 65536 && !value.chars().any(char::is_control)
}
impl<B: ProvisioningBackend> Session<B> {
    pub fn new(backend: B) -> Self { Self { backend, phase: Phase::AwaitIdentifier, identifier: None } }
    pub fn phase(&self) -> Phase { self.phase }
    pub fn initial(&self) -> ServerMessage { ServerMessage::GiveIdentifier }
    pub fn receive(&mut self, msg: ClientMessage) -> Result<ServerMessage, ProtocolError> {
        match (self.phase, msg) {
            (Phase::AwaitIdentifier, ClientMessage::Identifier(identifier)) if field_ok(&identifier) => {
                self.identifier = Some(identifier);
                self.phase = Phase::AwaitStart;
                Ok(ServerMessage::GiveStartProvisioningData)
            }
            (Phase::AwaitStart, ClientMessage::Spim(spim)) if field_ok(&spim) => {
                let identifier = self.identifier.as_deref().ok_or(ProtocolError::InvalidTransition)?;
                let cpim = match self.backend.start(identifier, &spim) {
                    Ok(value) => value,
                    Err(error) => { self.phase = Phase::Failed; return Err(error); }
                };
                if !field_ok(&cpim) { self.phase = Phase::Failed; return Err(ProtocolError::InvalidField); }
                self.phase = Phase::AwaitFinish;
                Ok(ServerMessage::GiveEndProvisioningData { cpim })
            }
            (Phase::AwaitFinish, ClientMessage::Finish { ptm, tk }) if field_ok(&ptm) && field_ok(&tk) => {
                let adi_pb = match self.backend.finish(&ptm, &tk) {
                    Ok(value) => value,
                    Err(error) => { self.phase = Phase::Failed; return Err(error); }
                };
                if !field_ok(&adi_pb) { self.phase = Phase::Failed; return Err(ProtocolError::InvalidField); }
                self.phase = Phase::Complete;
                Ok(ServerMessage::ProvisioningSuccess { adi_pb })
            }
            (_, ClientMessage::Identifier(v)) if !field_ok(&v) => Err(ProtocolError::InvalidField),
            _ => Err(ProtocolError::InvalidTransition),
        }
    }
}

/// Decodes only the messages expected from Zag's existing v3 client.
/// The session state machine separately rejects out-of-order messages.
pub fn decode_client_message(text: &str) -> Result<ClientMessage, ProtocolError> {
    if text.len() > 65536 { return Err(ProtocolError::InvalidField); }
    let value: serde_json::Value = serde_json::from_str(text).map_err(|_| ProtocolError::InvalidField)?;
    let object = value.as_object().ok_or(ProtocolError::InvalidField)?;
    let read = |key: &str| -> Result<String, ProtocolError> {
        let s = object.get(key).and_then(serde_json::Value::as_str).ok_or(ProtocolError::InvalidField)?;
        if !field_ok(s) { return Err(ProtocolError::InvalidField); }
        Ok(s.to_owned())
    };
    match object.len() {
        1 if object.contains_key("identifier") => Ok(ClientMessage::Identifier(read("identifier")?)),
        1 if object.contains_key("spim") => Ok(ClientMessage::Spim(read("spim")?)),
        2 if object.contains_key("ptm") && object.contains_key("tk") => Ok(ClientMessage::Finish { ptm: read("ptm")?, tk: read("tk")? }),
        _ => Err(ProtocolError::InvalidField),
    }
}

/// Exact JSON result tags expected by remote_v3/mod.rs.
pub fn encode_server_message(msg: &ServerMessage) -> String {
    match msg {
        ServerMessage::GiveIdentifier => serde_json::json!({"result":"GiveIdentifier"}).to_string(),
        ServerMessage::GiveStartProvisioningData => serde_json::json!({"result":"GiveStartProvisioningData"}).to_string(),
        ServerMessage::GiveEndProvisioningData { cpim } => serde_json::json!({"result":"GiveEndProvisioningData","cpim":cpim}).to_string(),
        ServerMessage::ProvisioningSuccess { adi_pb } => serde_json::json!({"result":"ProvisioningSuccess","adi_pb":adi_pb}).to_string(),
    }
}

/// Drives a single decoded WebSocket text frame through the provisioning
/// state machine. A future transport adapter must enforce its own frame-size,
/// session deadline and close-on-error policy.
pub fn process_text_frame<B: ProvisioningBackend>(
    session: &mut Session<B>,
    frame: &str,
) -> Result<String, ProtocolError> {
    let incoming = decode_client_message(frame)?;
    let outgoing = session.receive(incoming)?;
    Ok(encode_server_message(&outgoing))
}

// Intentionally not wired to HTTP or WebSocket: no mock data may be returned
// as valid Apple provisioning output.
#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    #[test]
    fn persistent_subprocess_rejects_bad_reply_and_terminates_provisioning() {
        use std::os::unix::fs::PermissionsExt;
        let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/session_worker_fixture.rs");
        let temp = std::env::temp_dir().join(format!(
            "zag-provider-bad-{}-{:?}", std::process::id(), std::thread::current().id()));
        std::fs::create_dir_all(&temp).unwrap();
        std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o700)).unwrap();
        let executable = temp.join("fixture");
        assert!(std::process::Command::new("rustc")
            .args(["--edition=2021", "-o"]).arg(&executable).arg(&source)
            .status().unwrap().success());
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let transport = OfflineSplitChildTransport::spawn(&executable,
            &["--v2-wrong-phase"], std::time::Duration::from_secs(5)).unwrap();
        let mut session = Session::new(AdiBackend::new(SessionOwnedAdiProvider::new(transport)));
        assert_eq!(session.receive(ClientMessage::Identifier("-2".into())),
            Ok(ServerMessage::GiveStartProvisioningData));
        assert_eq!(session.receive(ClientMessage::Spim("00ff".into())),
            Err(ProtocolError::BackendUnavailable));
        assert_eq!(session.phase(), Phase::Failed);
        assert_eq!(session.receive(ClientMessage::Finish {
            ptm: "ff00".into(), tk: "80".into(),
        }), Err(ProtocolError::InvalidTransition));
        drop(session);
        std::fs::remove_file(&executable).unwrap();
        std::fs::remove_dir(&temp).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn persistent_subprocess_drives_complete_provisioning_protocol() {
        use std::os::unix::fs::PermissionsExt;
        let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/session_worker_fixture.rs");
        let temp = std::env::temp_dir().join(format!(
            "zag-provider-child-{}-{:?}", std::process::id(), std::thread::current().id()));
        std::fs::create_dir_all(&temp).unwrap();
        std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o700)).unwrap();
        let executable = temp.join("fixture");
        assert!(std::process::Command::new("rustc")
            .args(["--edition=2021", "-o"]).arg(&executable).arg(&source)
            .status().unwrap().success());
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let transport = OfflineSplitChildTransport::spawn(&executable,
            &["--v2-split"], std::time::Duration::from_secs(5)).unwrap();
        let mut session = Session::new(AdiBackend::new(SessionOwnedAdiProvider::new(transport)));
        assert_eq!(session.receive(ClientMessage::Identifier("-2".into())),
            Ok(ServerMessage::GiveStartProvisioningData));
        assert_eq!(session.receive(ClientMessage::Spim("00ff".into())),
            Ok(ServerMessage::GiveEndProvisioningData { cpim: "00ff".into() }));
        assert_eq!(session.receive(ClientMessage::Finish {
            ptm: "ff00".into(), tk: "80".into(),
        }), Ok(ServerMessage::ProvisioningSuccess { adi_pb: "ff00".into() }));
        assert_eq!(session.phase(), Phase::Complete);
        assert_eq!(session.receive(ClientMessage::Finish {
            ptm: "ff00".into(), tk: "80".into(),
        }), Err(ProtocolError::InvalidTransition));
        drop(session);
        std::fs::remove_file(&executable).unwrap();
        std::fs::remove_dir(&temp).unwrap();
    }
    #[test]
    fn session_owned_adapter_drives_existing_worker_state_machine() {
        let transport = OfflineSessionTransport::new(crate::session_worker::MockBackend::default());
        let provider = SessionOwnedAdiProvider::new(transport);
        let mut session = Session::new(AdiBackend::new(provider));
        assert_eq!(session.receive(ClientMessage::Identifier("offline-id".into())),
            Ok(ServerMessage::GiveStartProvisioningData));
        assert_eq!(session.receive(ClientMessage::Spim("offline-spim".into())),
            Ok(ServerMessage::GiveEndProvisioningData { cpim: "offline-cpim".into() }));
        assert_eq!(session.receive(ClientMessage::Finish {
            ptm: "offline-ptm".into(), tk: "offline-tk".into(),
        }), Ok(ServerMessage::ProvisioningSuccess { adi_pb: "offline-adi-pb".into() }));
        assert_eq!(session.phase(), Phase::Complete);
        assert_eq!(session.receive(ClientMessage::Finish {
            ptm: "offline-ptm".into(), tk: "offline-tk".into(),
        }), Err(ProtocolError::InvalidTransition));
    }
    #[test]
    fn session_owned_adapter_fails_closed_on_bad_worker_start() {
        let transport = OfflineSessionTransport::new(crate::session_worker::MockBackend::default());
        let provider = SessionOwnedAdiProvider::new(transport);
        let mut session = Session::new(AdiBackend::new(provider));
        assert_eq!(session.receive(ClientMessage::Identifier("offline-id".into())),
            Ok(ServerMessage::GiveStartProvisioningData));
        assert_eq!(session.receive(ClientMessage::Spim("".into())),
            Err(ProtocolError::InvalidTransition));
        // Invalid input cannot advance to native Finish.
        assert_eq!(session.receive(ClientMessage::Finish {
            ptm: "ptm".into(), tk: "tk".into(),
        }), Err(ProtocolError::InvalidTransition));
    }
    #[derive(Default)]
    struct MockNativeTransport {
        counts: std::sync::Arc<std::sync::Mutex<(usize, usize, usize)>>,
        fail_start: bool,
    }
    impl NativeSessionTransport for MockNativeTransport {
        fn start(&mut self, _: &str, _: &str) -> Result<String, ProtocolError> {
            self.counts.lock().unwrap().0 += 1;
            if self.fail_start { Err(ProtocolError::BackendUnavailable) }
            else { Ok("offline-cpim".into()) }
        }
        fn finish(&mut self, _: &str, _: &str) -> Result<String, ProtocolError> {
            self.counts.lock().unwrap().1 += 1;
            Ok("offline-adi".into())
        }
        fn abort(&mut self) { self.counts.lock().unwrap().2 += 1; }
    }
    #[test]
    fn session_owned_provider_preserves_transport_and_rejects_replay() {
        let counts = std::sync::Arc::new(std::sync::Mutex::new((0, 0, 0)));
        let transport = MockNativeTransport { counts: counts.clone(), fail_start: false };
        let mut provider = SessionOwnedAdiProvider::new(transport);
        assert_eq!(provider.finish_provisioning("ptm", "tk"), Err(ProtocolError::InvalidTransition));
        assert_eq!(provider.start_provisioning("id", "spim"), Ok("offline-cpim".into()));
        assert_eq!(provider.start_provisioning("id", "spim"), Err(ProtocolError::InvalidTransition));
        assert_eq!(provider.finish_provisioning("ptm", "tk"), Ok("offline-adi".into()));
        assert_eq!(provider.finish_provisioning("ptm", "tk"), Err(ProtocolError::InvalidTransition));
        drop(provider);
        assert_eq!(*counts.lock().unwrap(), (1, 1, 1));
    }
    #[test]
    fn session_owned_provider_start_failure_is_terminal_and_aborted() {
        let counts = std::sync::Arc::new(std::sync::Mutex::new((0, 0, 0)));
        let transport = MockNativeTransport { counts: counts.clone(), fail_start: true };
        let mut provider = SessionOwnedAdiProvider::new(transport);
        assert_eq!(provider.start_provisioning("id", "spim"), Err(ProtocolError::BackendUnavailable));
        assert_eq!(provider.start_provisioning("id", "spim"), Err(ProtocolError::InvalidTransition));
        assert_eq!(provider.finish_provisioning("ptm", "tk"), Err(ProtocolError::InvalidTransition));
        drop(provider);
        let result = *counts.lock().unwrap();
        assert_eq!((result.0, result.1), (1, 0));
        assert!(result.2 >= 1);
    }

    #[cfg(unix)]
    #[test]
    fn offline_worker_adapter_completes_both_provisioning_phases() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "zag-adi-adapter-{}-{:?}", std::process::id(), std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();

        #[cfg(unix)]

        { use std::os::unix::fs::PermissionsExt; std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap(); }
        let script = dir.join("worker.sh");
        // The shell fixture consumes framed IPC and selects a response by
        // request phase; no Apple provisioning or network access occurs.
        let body = r#"#!/bin/sh
input=$(cat)
case "$input" in
  *'"type":"finish"'*) printf '\000\000\000\061%s' '{"version":1,"type":"finished","adi_pb":"adi_pb"}' ;;
  *'"type":"start"'*) printf '\000\000\000\054%s' '{"version":1,"type":"started","cpim":"cpim"}' ;;
  *) exit 1 ;;
esac
"#;
        std::fs::write(&script, body).unwrap();
        let mut permissions = std::fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&script, permissions).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));
        let provider = OfflineWorkerAdiProvider::new(
            script.clone(), std::time::Duration::from_secs(2),
        );
        let mut session = Session::new(AdiBackend::new(provider));
        assert_eq!(session.receive(ClientMessage::Identifier("device".into())),
            Ok(ServerMessage::GiveStartProvisioningData));
        assert_eq!(session.receive(ClientMessage::Spim("spim".into())),
            Ok(ServerMessage::GiveEndProvisioningData { cpim: "cpim".into() }));
        assert_eq!(session.receive(ClientMessage::Finish { ptm: "ptm".into(), tk: "tk".into() }),
            Ok(ServerMessage::ProvisioningSuccess { adi_pb: "adi_pb".into() }));
        assert_eq!(session.phase(), Phase::Complete);
        std::fs::remove_file(script).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn release_worker_adapter_rejects_provisioning_without_native_backend() {
        // Set only by the cross-platform CI job. Never enables a listener.
        let Ok(path) = std::env::var("ZAG_OFFLINE_WORKER_TEST_EXECUTABLE") else { return; };
        let path = std::path::PathBuf::from(path).canonicalize().unwrap();
        let mut session = Session::new(AdiBackend::new(OfflineWorkerAdiProvider::new(
            path, std::time::Duration::from_secs(3),
        )));
        assert_eq!(session.receive(ClientMessage::Identifier("device".into())),
            Ok(ServerMessage::GiveStartProvisioningData));
        assert_eq!(session.receive(ClientMessage::Spim("spim".into())),
            Err(ProtocolError::BackendUnavailable));
        assert_eq!(session.phase(), Phase::Failed);
    }
    #[test] fn offline_worker_adapter_fails_closed_without_approved_executable() {
        let provider = OfflineWorkerAdiProvider::new(
            std::path::PathBuf::from("/nonexistent/zag-adi-worker"),
            std::time::Duration::from_millis(100),
        );
        let mut session = Session::new(AdiBackend::new(provider));
        assert_eq!(
            session.receive(ClientMessage::Identifier("device".into())),
            Ok(ServerMessage::GiveStartProvisioningData)
        );
        assert_eq!(
            session.receive(ClientMessage::Spim("spim".into())),
            Err(ProtocolError::BackendUnavailable)
        );
        assert_eq!(session.phase(), Phase::Failed);
    }
    #[test] fn disabled_adi_adapter_fails_closed() {
        let mut session = Session::new(AdiBackend::new(DisabledAdiProvider));
        assert_eq!(session.receive(ClientMessage::Identifier("id".into())), Ok(ServerMessage::GiveStartProvisioningData));
        assert_eq!(session.receive(ClientMessage::Spim("spim".into())), Err(ProtocolError::BackendUnavailable));
        assert_eq!(session.phase(), Phase::Failed);
    }
    struct TestAdiProvider;
    impl AdiProvider for TestAdiProvider {
        fn start_provisioning(&mut self, identifier: &str, spim: &str) -> Result<String, ProtocolError> {
            if identifier == "id" && spim == "spim" { Ok("cpim".into()) } else { Err(ProtocolError::InvalidField) }
        }
        fn finish_provisioning(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError> {
            if ptm == "ptm" && tk == "tk" { Ok("adi_pb".into()) } else { Err(ProtocolError::InvalidField) }
        }
    }
    #[test] fn adi_adapter_matches_provisioning_contract() {
        let mut session = Session::new(AdiBackend::new(TestAdiProvider));
        assert_eq!(session.receive(ClientMessage::Identifier("id".into())), Ok(ServerMessage::GiveStartProvisioningData));
        assert_eq!(session.receive(ClientMessage::Spim("spim".into())), Ok(ServerMessage::GiveEndProvisioningData { cpim: "cpim".into() }));
        assert_eq!(session.receive(ClientMessage::Finish { ptm: "ptm".into(), tk: "tk".into() }), Ok(ServerMessage::ProvisioningSuccess { adi_pb: "adi_pb".into() }));
        assert_eq!(session.phase(), Phase::Complete);
    }
    struct BadAdiProvider;
    impl AdiProvider for BadAdiProvider {
        fn start_provisioning(&mut self, _: &str, _: &str) -> Result<String, ProtocolError> {
            Ok(String::new())
        }
        fn finish_provisioning(&mut self, _: &str, _: &str) -> Result<String, ProtocolError> {
            panic!("finish must not run after invalid start")
        }
    }
    #[test] fn invalid_adi_provider_output_terminates_session() {
        let mut session = Session::new(AdiBackend::new(BadAdiProvider));
        assert!(session.receive(ClientMessage::Identifier("id".into())).is_ok());
        assert_eq!(session.receive(ClientMessage::Spim("spim".into())), Err(ProtocolError::InvalidField));
        assert_eq!(session.phase(), Phase::Failed);
        assert_eq!(session.receive(ClientMessage::Finish { ptm: "p".into(), tk: "t".into() }), Err(ProtocolError::InvalidTransition));
    }
    struct FinishErrorAdiProvider;
    impl AdiProvider for FinishErrorAdiProvider {
        fn start_provisioning(&mut self, _: &str, _: &str) -> Result<String, ProtocolError> {
            Ok("cpim".into())
        }
        fn finish_provisioning(&mut self, _: &str, _: &str) -> Result<String, ProtocolError> {
            Err(ProtocolError::BackendUnavailable)
        }
    }
    #[test] fn adi_finish_failure_terminates_session() {
        let mut session = Session::new(AdiBackend::new(FinishErrorAdiProvider));
        assert!(session.receive(ClientMessage::Identifier("id".into())).is_ok());
        assert!(session.receive(ClientMessage::Spim("spim".into())).is_ok());
        assert_eq!(session.receive(ClientMessage::Finish { ptm: "p".into(), tk: "t".into() }), Err(ProtocolError::BackendUnavailable));
        assert_eq!(session.phase(), Phase::Failed);
    }
    struct BoundAdiProvider {
        expected_identifier: &'static str,
        expected_spim: &'static str,
        expected_ptm: &'static str,
        expected_tk: &'static str,
        started: bool,
    }
    impl AdiProvider for BoundAdiProvider {
        fn start_provisioning(&mut self, identifier: &str, spim: &str) -> Result<String, ProtocolError> {
            if self.started || identifier != self.expected_identifier || spim != self.expected_spim {
                return Err(ProtocolError::InvalidField);
            }
            self.started = true;
            Ok(format!("cpim-{}", self.expected_identifier))
        }
        fn finish_provisioning(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError> {
            if !self.started || ptm != self.expected_ptm || tk != self.expected_tk {
                return Err(ProtocolError::InvalidField);
            }
            Ok(format!("adi-{}", self.expected_identifier))
        }
    }
    fn bound_provider(id: &'static str, spim: &'static str, ptm: &'static str, tk: &'static str) -> BoundAdiProvider {
        BoundAdiProvider { expected_identifier: id, expected_spim: spim, expected_ptm: ptm, expected_tk: tk, started: false }
    }
    #[test] fn concurrent_adi_sessions_do_not_share_provider_state() {
        use std::thread;
        let a = thread::spawn(|| {
            let mut session = Session::new(AdiBackend::new(bound_provider("device-a", "spim-a", "ptm-a", "tk-a")));
            assert!(session.receive(ClientMessage::Identifier("device-a".into())).is_ok());
            assert_eq!(session.receive(ClientMessage::Spim("spim-a".into())), Ok(ServerMessage::GiveEndProvisioningData { cpim: "cpim-device-a".into() }));
            assert_eq!(session.receive(ClientMessage::Finish { ptm: "ptm-a".into(), tk: "tk-a".into() }), Ok(ServerMessage::ProvisioningSuccess { adi_pb: "adi-device-a".into() }));
        });
        let b = thread::spawn(|| {
            let mut session = Session::new(AdiBackend::new(bound_provider("device-b", "spim-b", "ptm-b", "tk-b")));
            assert!(session.receive(ClientMessage::Identifier("device-b".into())).is_ok());
            assert_eq!(session.receive(ClientMessage::Spim("spim-a".into())), Err(ProtocolError::InvalidField));
            assert_eq!(session.phase(), Phase::Failed);
            assert_eq!(session.receive(ClientMessage::Spim("spim-b".into())), Err(ProtocolError::InvalidTransition));
        });
        a.join().unwrap();
        b.join().unwrap();
    }
    #[test] fn provisioning_output_cannot_be_reused_across_sessions() {
        let mut a = Session::new(AdiBackend::new(bound_provider("a", "sa", "pa", "ta")));
        let mut b = Session::new(AdiBackend::new(bound_provider("b", "sb", "pb", "tb")));
        assert!(a.receive(ClientMessage::Identifier("a".into())).is_ok());
        assert!(b.receive(ClientMessage::Identifier("b".into())).is_ok());
        assert!(a.receive(ClientMessage::Spim("sa".into())).is_ok());
        assert!(b.receive(ClientMessage::Spim("sb".into())).is_ok());
        assert_eq!(b.receive(ClientMessage::Finish { ptm: "pa".into(), tk: "ta".into() }), Err(ProtocolError::InvalidField));
        assert_eq!(b.phase(), Phase::Failed);
        assert_eq!(a.receive(ClientMessage::Finish { ptm: "pa".into(), tk: "ta".into() }), Ok(ServerMessage::ProvisioningSuccess { adi_pb: "adi-a".into() }));
    }
    #[test] fn offline_never_advances() {
        let mut session = Session::new(OfflineBackend);
        assert_eq!(session.initial(), ServerMessage::GiveIdentifier);
        assert_eq!(session.receive(ClientMessage::Identifier("id".into())), Ok(ServerMessage::GiveStartProvisioningData));
        assert_eq!(session.receive(ClientMessage::Spim("spim".into())), Err(ProtocolError::BackendUnavailable));
        assert_eq!(session.phase(), Phase::Failed);
    }
    #[test] fn backend_failure_is_terminal() {
        let mut session = Session::new(OfflineBackend);
        assert!(session.receive(ClientMessage::Identifier("id".into())).is_ok());
        assert_eq!(session.receive(ClientMessage::Spim("spim".into())), Err(ProtocolError::BackendUnavailable));
        assert_eq!(session.phase(), Phase::Failed);
        assert_eq!(session.receive(ClientMessage::Spim("spim".into())), Err(ProtocolError::InvalidTransition));
    }
    #[test] fn malformed_identifier_rejected() {
        let mut session = Session::new(OfflineBackend);
        assert_eq!(session.receive(ClientMessage::Identifier("\n".into())), Err(ProtocolError::InvalidField));
    }
    struct FakeBackend;
    impl ProvisioningBackend for FakeBackend {
        fn start(&mut self, id: &str, spim: &str) -> Result<String, ProtocolError> {
            if id == "id" && spim == "spim" { Ok("cpim".into()) } else { Err(ProtocolError::InvalidField) }
        }
        fn finish(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError> {
            if ptm == "ptm" && tk == "tk" { Ok("adi_pb".into()) } else { Err(ProtocolError::InvalidField) }
        }
    }
    #[test] fn fake_backend_roundtrip() {
        let mut session = Session::new(FakeBackend);
        assert_eq!(session.receive(ClientMessage::Identifier("id".into())), Ok(ServerMessage::GiveStartProvisioningData));
        assert_eq!(session.receive(ClientMessage::Spim("spim".into())), Ok(ServerMessage::GiveEndProvisioningData { cpim: "cpim".into() }));
        assert_eq!(session.receive(ClientMessage::Finish { ptm: "ptm".into(), tk: "tk".into() }), Ok(ServerMessage::ProvisioningSuccess { adi_pb: "adi_pb".into() }));
        assert_eq!(session.phase(), Phase::Complete);
        assert_eq!(session.receive(ClientMessage::Identifier("id".into())), Err(ProtocolError::InvalidTransition));
    }
    #[test] fn wire_messages_match_client() {
        assert_eq!(encode_server_message(&ServerMessage::GiveIdentifier), r#"{"result":"GiveIdentifier"}"#);
        assert_eq!(encode_server_message(&ServerMessage::GiveStartProvisioningData), r#"{"result":"GiveStartProvisioningData"}"#);
        let cpim: serde_json::Value = serde_json::from_str(&encode_server_message(&ServerMessage::GiveEndProvisioningData { cpim: "test".into() })).unwrap();
        assert_eq!(cpim["result"], "GiveEndProvisioningData");
        assert_eq!(cpim["cpim"], "test");
        assert_eq!(decode_client_message(r#"{"identifier":"abc"}"#), Ok(ClientMessage::Identifier("abc".into())));
        assert_eq!(decode_client_message(r#"{"spim":"xyz"}"#), Ok(ClientMessage::Spim("xyz".into())));
        assert_eq!(decode_client_message(r#"{"ptm":"p","tk":"t"}"#), Ok(ClientMessage::Finish { ptm: "p".into(), tk: "t".into() }));
    }
    #[test] fn invalid_wire_messages_fail_closed() {
        for message in [r#"{}"#, r#"[]"#, r#"{"spim":null}"#, r#"{"spim":""}"#, r#"{"identifier":"x","extra":1}"#, r#"{"ptm":"x"}"#, r#"{"ptm":"x","tk":"y","identifier":"z"}"#] {
            assert_eq!(decode_client_message(message), Err(ProtocolError::InvalidField), "{message}");
        }
    }
    #[test] fn frame_adapter_matches_existing_client_protocol() {
        let mut session = Session::new(FakeBackend);
        assert_eq!(encode_server_message(&session.initial()), r#"{"result":"GiveIdentifier"}"#);
        let step1: serde_json::Value = serde_json::from_str(
            &process_text_frame(&mut session, r#"{"identifier":"id"}"#).unwrap()
        ).unwrap();
        assert_eq!(step1["result"], "GiveStartProvisioningData");
        let step2: serde_json::Value = serde_json::from_str(
            &process_text_frame(&mut session, r#"{"spim":"spim"}"#).unwrap()
        ).unwrap();
        assert_eq!(step2["result"], "GiveEndProvisioningData");
        assert_eq!(step2["cpim"], "cpim");
        let step3: serde_json::Value = serde_json::from_str(
            &process_text_frame(&mut session, r#"{"ptm":"ptm","tk":"tk"}"#).unwrap()
        ).unwrap();
        assert_eq!(step3["result"], "ProvisioningSuccess");
        assert_eq!(step3["adi_pb"], "adi_pb");
        assert_eq!(session.phase(), Phase::Complete);
        assert_eq!(
            process_text_frame(&mut session, r#"{"identifier":"id"}"#),
            Err(ProtocolError::InvalidTransition)
        );
    }
    #[test] fn offline_backend_cannot_produce_provisioning_output() {
        let mut session = Session::new(OfflineBackend);
        assert!(process_text_frame(&mut session, r#"{"identifier":"id"}"#).is_ok());
        assert_eq!(
            process_text_frame(&mut session, r#"{"spim":"spim"}"#),
            Err(ProtocolError::BackendUnavailable)
        );
        assert_eq!(session.phase(), Phase::Failed);
    }
    #[test] fn rejected_frame_does_not_advance_session() {
        let mut session = Session::new(FakeBackend);
        assert_eq!(
            process_text_frame(&mut session, r#"{"identifier":"id","unknown":true}"#),
            Err(ProtocolError::InvalidField)
        );
        assert_eq!(session.phase(), Phase::AwaitIdentifier);
    }
    #[test] fn out_of_order_rejected() {
        let mut session = Session::new(OfflineBackend);
        assert_eq!(session.receive(ClientMessage::Spim("data".into())), Err(ProtocolError::InvalidTransition));
    }
}
