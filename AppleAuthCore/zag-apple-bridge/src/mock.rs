//! Tests only (`mock` feature): a scripted backend at the bridge's own
//! boundary. It models outcomes (a code is required, a session has expired,
//! the network failed) and never Apple's messages. Its accounts, passwords
//! and codes are fixed test values.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::backend::*;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MockAccount {
    pub email: String,
    pub password: String,
    pub account_identifier: String,
    /// "none", "trustedDevice" or "sms".
    #[serde(default = "none")]
    pub two_factor: String,
    #[serde(default)]
    pub code: String,
    #[serde(default)]
    pub sms_code: String,
    #[serde(default)]
    pub teams: Vec<Team>,
    /// A failure the sign-in ends with after the password (and any code).
    #[serde(default)]
    pub sign_in_failure: Option<FailureKind>,
    /// A failure every portal operation ends with.
    #[serde(default)]
    pub portal_failure: Option<FailureKind>,
    /// Seconds an issued session lasts (default one hour).
    #[serde(default = "hour")]
    pub session_lifetime: u64,
    /// The sign-in waits this long before answering, so it can be cancelled.
    #[serde(default)]
    pub delay_milliseconds: u64,
    /// DER certificate (base64) returned for a certificate request.
    #[serde(default)]
    pub issued_certificate: Option<String>,
    #[serde(default)]
    pub profile: Option<String>,
    /// The sign-in panics (checks that a terminal event still arrives).
    #[serde(default)]
    pub panics: bool,
    /// The anisette scope this account must be signed in with, if any.
    #[serde(default)]
    pub anisette_scope: Option<String>,
    /// The certificate listing includes each certificate's content (whether
    /// Apple's does is not established; by default the mock leaves it out).
    #[serde(default)]
    pub lists_certificate_content: bool,
}

fn none() -> String {
    "none".into()
}

fn hour() -> u64 {
    3600
}

#[derive(Debug, Deserialize)]
pub struct MockScript {
    pub accounts: Vec<MockAccount>,
}

#[derive(Default)]
struct PortalState {
    devices: Vec<Device>,
    app_ids: Vec<AppId>,
    groups: Vec<String>,
    certificates: Vec<Certificate>,
}

pub struct MockBackend {
    accounts: Vec<MockAccount>,
    /// Issued tokens: token → (account identifier, expiry).
    tokens: Mutex<HashMap<String, (String, u64)>>,
    /// Portal state per account identifier.
    portal: std::sync::Arc<Mutex<HashMap<String, PortalState>>>,
}

pub(crate) fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl MockBackend {
    pub fn from_json(json: &[u8]) -> Option<Self> {
        let script: MockScript = serde_json::from_slice(json).ok()?;
        Some(Self { accounts: script.accounts, tokens: Default::default(), portal: Default::default() })
    }

    fn account(&self, identifier: &str) -> Option<&MockAccount> {
        self.accounts.iter().find(|a| a.account_identifier == identifier)
    }
}

#[async_trait]
impl Backend for MockBackend {
    async fn sign_in(&self, anisette_scope: &str, email: &str, password: Zeroizing<String>, prompter: &Prompter) -> BridgeResult<SignedIn> {
        let account = self
            .accounts
            .iter()
            .find(|a| a.email.eq_ignore_ascii_case(email))
            .ok_or(BridgeError::new(FailureKind::Rejected))?;
        // A scripted account can require its own anisette scope, so tests
        // check that each account is signed in with its own device state.
        if account.anisette_scope.as_deref().is_some_and(|expected| expected != anisette_scope) {
            return Err(FailureKind::InvalidInput.into());
        }
        if account.delay_milliseconds > 0 {
            tokio::time::sleep(Duration::from_millis(account.delay_milliseconds)).await;
        }
        if account.panics {
            panic!("scripted panic");
        }
        if account.sign_in_failure == Some(FailureKind::Network) {
            return Err(FailureKind::Network.into());
        }
        if *password != account.password {
            return Err(FailureKind::Rejected.into());
        }
        if account.two_factor != "none" {
            let mut sms = account.two_factor == "sms";
            let mut retry = false;
            loop {
                let prompt = CodePrompt {
                    method: if sms { TwoFactorMethod::Sms } else { TwoFactorMethod::TrustedDevice },
                    code_length: 6,
                    masked_destination: sms.then(|| "12".to_string()),
                    can_request_sms: !sms,
                    retry,
                };
                match prompter.ask(prompt).await {
                    CodeAction::Cancel => return Err(FailureKind::Cancelled.into()),
                    CodeAction::RequestSms => sms = true,
                    CodeAction::Submit(code) => {
                        let expected = if sms { &account.sms_code } else { &account.code };
                        if *code == *expected {
                            break;
                        }
                        if retry {
                            return Err(FailureKind::TwoFactorRejected.into());
                        }
                        retry = true;
                    }
                }
            }
        }
        if let Some(failure) = account.sign_in_failure {
            return Err(failure.into());
        }
        let token = format!("mock-session-{}-{}", account.account_identifier, self.tokens.lock().unwrap().len() + 1);
        let expires_at = now() + account.session_lifetime;
        self.tokens.lock().unwrap().insert(token.clone(), (account.account_identifier.clone(), expires_at));
        Ok(SignedIn {
            credential: Credential { account_identifier: account.account_identifier.clone(), token: Zeroizing::new(token), expires_at },
            teams: account.teams.clone(),
        })
    }

    async fn open_session(&self, credential: &Credential) -> BridgeResult<Box<dyn PortalSession>> {
        let (owner, expires_at) = self
            .tokens
            .lock()
            .unwrap()
            .get(credential.token.as_str())
            .cloned()
            .ok_or(BridgeError::new(FailureKind::SessionExpired))?;
        if owner != credential.account_identifier {
            return Err(FailureKind::SessionExpired.into());
        }
        let account = self.account(&owner).cloned().ok_or(BridgeError::new(FailureKind::SessionExpired))?;
        Ok(Box::new(MockSession { account, expires_at, portal: self.portal.clone() }))
    }
}

struct MockSession {
    account: MockAccount,
    expires_at: u64,
    portal: std::sync::Arc<Mutex<HashMap<String, PortalState>>>,
}

#[async_trait]
impl PortalSession for MockSession {
    async fn call(&mut self, request: PortalRequest) -> BridgeResult<Value> {
        if now() >= self.expires_at {
            return Err(FailureKind::SessionExpired.into());
        }
        if let Some(failure) = self.account.portal_failure {
            return Err(failure.into());
        }
        let team_ok = |team: &str| self.account.teams.iter().any(|t| t.identifier == team);
        let mut portal = self.portal.lock().unwrap();
        let state = portal.entry(self.account.account_identifier.clone()).or_default();
        match request {
            PortalRequest::Teams => to_value(&self.account.teams),
            PortalRequest::Devices { team } if team_ok(&team) => to_value(&state.devices),
            PortalRequest::RegisterDevice { team, udid, name } if team_ok(&team) => {
                let device = Device { udid, name };
                state.devices.push(device.clone());
                to_value(&device)
            }
            PortalRequest::AppIds { team } if team_ok(&team) => to_value(&state.app_ids),
            PortalRequest::RegisterAppId { team, bundle_identifier, .. } if team_ok(&team) => {
                let app_id = AppId {
                    identifier: format!("APPID{}", state.app_ids.len() + 1),
                    bundle_identifier,
                    expires_at: Some(now() + 7 * 86_400),
                };
                state.app_ids.push(app_id.clone());
                to_value(&app_id)
            }
            PortalRequest::AppGroups { team } if team_ok(&team) => {
                Ok(Value::Array(state.groups.iter().map(|g| json!({ "identifier": g })).collect()))
            }
            PortalRequest::RegisterAppGroup { team, identifier } if team_ok(&team) => {
                state.groups.push(identifier.clone());
                Ok(json!({ "identifier": identifier }))
            }
            PortalRequest::AssignAppGroups { team, .. } if team_ok(&team) => Ok(Value::Null),
            PortalRequest::Certificates { team } if team_ok(&team) => to_value(&state.certificates),
            PortalRequest::SubmitCertificateRequest { team, machine_name, .. } if team_ok(&team) => {
                let certificate = Certificate {
                    serial_number: format!("{:016X}", state.certificates.len() + 1),
                    name: "Apple Development: Mock".into(),
                    machine_name: Some(machine_name),
                    expires_at: now() + 7 * 86_400,
                    data: self.account.issued_certificate.clone(),
                };
                let listed = if self.account.lists_certificate_content { certificate.data.clone() } else { None };
                state.certificates.push(Certificate { data: listed, ..certificate.clone() });
                to_value(&certificate)
            }
            PortalRequest::Profile { team, .. } if team_ok(&team) => {
                Ok(json!({ "data": self.account.profile.clone().ok_or(BridgeError::new(FailureKind::Malformed))? }))
            }
            _ => Err(FailureKind::InvalidInput.into()),
        }
    }
}

fn to_value<T: serde::Serialize>(value: &T) -> BridgeResult<Value> {
    serde_json::to_value(value).map_err(|_| FailureKind::Malformed.into())
}
