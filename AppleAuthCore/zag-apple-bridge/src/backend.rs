//! What the bridge asks of an Apple Account backend, independent of how it is
//! implemented: `live::IsideloadBackend` (zag-isideload) or, in tests only,
//! `mock::MockBackend`. Nothing here carries a message from Apple or from the
//! library: failures are reduced to a `FailureKind`, so no upstream text (which
//! may contain an email address or a token) can reach Swift or a log.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use zeroize::Zeroizing;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FailureKind {
    /// Network access is compiled out (the `live` feature is off).
    Disabled,
    /// No anisette provider has been configured.
    NotConfigured,
    Network,
    /// Apple did not accept the sign-in.
    Rejected,
    TwoFactorRejected,
    /// Apple refused a portal operation (for example a limit or an identifier
    /// in use). Which one is not inferred from Apple's messages.
    Refused,
    RateLimited,
    /// Apple no longer accepts the session.
    SessionExpired,
    Malformed,
    Cancelled,
    /// Another operation is already running in this slot.
    Busy,
    /// A malformed or missing argument from Swift.
    InvalidInput,
    NotSignedIn,
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BridgeError {
    pub kind: FailureKind,
}

impl BridgeError {
    pub fn new(kind: FailureKind) -> Self {
        Self { kind }
    }
}

impl From<FailureKind> for BridgeError {
    fn from(kind: FailureKind) -> Self {
        Self { kind }
    }
}

pub type BridgeResult<T> = Result<T, BridgeError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TwoFactorMethod {
    TrustedDevice,
    Sms,
}

/// What the verification-code sheet needs. `masked_destination` is at most
/// the last two digits of a phone number.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodePrompt {
    pub method: TwoFactorMethod,
    pub code_length: u8,
    pub masked_destination: Option<String>,
    pub can_request_sms: bool,
    /// The previous code was not accepted.
    pub retry: bool,
}

/// The user's answer to a `CodePrompt`.
pub enum CodeAction {
    Submit(Zeroizing<String>),
    RequestSms,
    Cancel,
}

/// Asks the user for verification codes during one sign-in. Each prompt is
/// answered through `answers`, which the slot feeds from Swift.
pub struct Prompter {
    pub(crate) prompts: mpsc::UnboundedSender<CodePrompt>,
    pub(crate) answers: tokio::sync::Mutex<mpsc::UnboundedReceiver<CodeAction>>,
}

impl Prompter {
    pub async fn ask(&self, prompt: CodePrompt) -> CodeAction {
        if self.prompts.send(prompt).is_err() {
            return CodeAction::Cancel;
        }
        self.answers.lock().await.recv().await.unwrap_or(CodeAction::Cancel)
    }
}

/// The minimal session secret Swift keeps in the this-device-only Keychain.
pub struct Credential {
    pub account_identifier: String,
    pub token: Zeroizing<String>,
    /// Unix seconds.
    pub expires_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Team {
    pub identifier: String,
    pub name: String,
    /// `personalFree`, `individualPaid`, `organization` or `unknown`. The live
    /// backend reports `unknown` until the supervised experiment has shown how
    /// Apple describes a Personal Team; Zag Store applies the free limits to
    /// `unknown`, which are the strictest.
    pub kind: String,
}

pub struct SignedIn {
    pub credential: Credential,
    pub teams: Vec<Team>,
}

/// One developer-portal operation, for one team.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum PortalRequest {
    Teams,
    #[serde(rename_all = "camelCase")]
    Devices { team: String },
    #[serde(rename_all = "camelCase")]
    RegisterDevice { team: String, udid: String, name: String },
    #[serde(rename_all = "camelCase")]
    AppIds { team: String },
    #[serde(rename_all = "camelCase")]
    RegisterAppId { team: String, bundle_identifier: String, name: String },
    #[serde(rename_all = "camelCase")]
    AppGroups { team: String },
    #[serde(rename_all = "camelCase")]
    RegisterAppGroup { team: String, identifier: String },
    #[serde(rename_all = "camelCase")]
    AssignAppGroups { team: String, groups: Vec<String>, app_id: String },
    #[serde(rename_all = "camelCase")]
    Certificates { team: String },
    /// `request` is the DER certificate signing request, base64.
    #[serde(rename_all = "camelCase")]
    SubmitCertificateRequest { team: String, request: String, machine_name: String },
    #[serde(rename_all = "camelCase")]
    Profile { team: String, app_id: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Device {
    pub udid: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppId {
    /// The portal's identifier for the App ID.
    pub identifier: String,
    pub bundle_identifier: String,
    /// Unix seconds, when the portal reports one.
    pub expires_at: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Certificate {
    pub serial_number: String,
    pub name: String,
    pub machine_name: Option<String>,
    /// Unix seconds.
    pub expires_at: u64,
    /// DER, base64; present for a certificate just issued.
    pub data: Option<String>,
}

/// Opens portal sessions and signs in.
#[async_trait]
pub trait Backend: Send + Sync {
    async fn sign_in(&self, email: &str, password: Zeroizing<String>, prompter: &Prompter) -> BridgeResult<SignedIn>;
    async fn open_session(&self, credential: &Credential) -> BridgeResult<Box<dyn PortalSession>>;
}

/// A signed-in developer-portal session for one account.
#[async_trait]
pub trait PortalSession: Send {
    /// The operation's result as JSON (a list, an object or `null`).
    async fn call(&mut self, request: PortalRequest) -> BridgeResult<serde_json::Value>;
}

