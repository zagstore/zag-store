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
                let cpim = self.backend.start(identifier, &spim)?;
                if !field_ok(&cpim) { return Err(ProtocolError::InvalidField); }
                self.phase = Phase::AwaitFinish;
                Ok(ServerMessage::GiveEndProvisioningData { cpim })
            }
            (Phase::AwaitFinish, ClientMessage::Finish { ptm, tk }) if field_ok(&ptm) && field_ok(&tk) => {
                let adi_pb = self.backend.finish(&ptm, &tk)?;
                if !field_ok(&adi_pb) { return Err(ProtocolError::InvalidField); }
                self.phase = Phase::Complete;
                Ok(ServerMessage::ProvisioningSuccess { adi_pb })
            }
            (_, ClientMessage::Identifier(v)) if !field_ok(&v) => Err(ProtocolError::InvalidField),
            _ => Err(ProtocolError::InvalidTransition),
        }
    }
}
// Intentionally not wired to HTTP or WebSocket: no mock data may be returned
// as valid Apple provisioning output.
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn offline_never_advances() {
        let mut session = Session::new(OfflineBackend);
        assert_eq!(session.initial(), ServerMessage::GiveIdentifier);
        assert_eq!(session.receive(ClientMessage::Identifier("id".into())), Ok(ServerMessage::GiveStartProvisioningData));
        assert_eq!(session.receive(ClientMessage::Spim("spim".into())), Err(ProtocolError::BackendUnavailable));
        assert_eq!(session.phase(), Phase::AwaitStart);
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
    #[test] fn out_of_order_rejected() {
        let mut session = Session::new(OfflineBackend);
        assert_eq!(session.receive(ClientMessage::Spim("data".into())), Err(ProtocolError::InvalidTransition));
    }
}
