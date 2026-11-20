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
        assert_eq!(session.phase(), Phase::AwaitStart);
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
