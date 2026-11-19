//! The live backend (`live` feature only): drives `zag-isideload`, whose
//! network access the same feature enables. Every connection goes through
//! the fork's policy: https only, verified certificates (no switch to turn
//! that off), no redirects, and only Apple's sign-in and developer-services
//! hosts plus the one configured anisette server.
//!
//! Points the supervised experiment confirms before this is relied on are
//! marked "EXPERIMENT". They are about the meaning of values, not about
//! Apple's messages, which stay inside the fork.

use std::ffi::CString;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use rootcause::Report;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use isideload::SideloadError;
use isideload::anisette::AnisetteDataGenerator;
use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{AppToken, AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::auth::grandslam::GrandSlam;
use isideload::dev::app_groups::AppGroupsApi;
use isideload::dev::app_ids::AppIdsApi;
use isideload::dev::certificates::CertificatesApi;
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::device_type::DeveloperDeviceType;
use isideload::dev::devices::DevicesApi;
use isideload::dev::teams::{DeveloperTeam, TeamsApi};
use isideload::net_policy::PolicyError;
use isideload::util::plist::PlistDataExtract;
use isideload::util::storage::SideloadingStorage;

use crate::backend::*;
use crate::ffi::ZagBridgeStorage;

/// Reduces a library error to a kind. Its text is dropped unread.
fn classify(report: &Report) -> BridgeError {
    for part in report.iter_reports() {
        if let Some(policy) = part.downcast_current_context::<PolicyError>() {
            return match policy {
                PolicyError::Disabled => FailureKind::Disabled,
                _ => FailureKind::Network,
            }
            .into();
        }
        if let Some(error) = part.downcast_current_context::<reqwest::Error>() {
            return match error.status() {
                Some(status) if status.as_u16() == 429 => FailureKind::RateLimited,
                Some(status) if status.as_u16() == 401 => FailureKind::SessionExpired,
                _ => FailureKind::Network,
            }
            .into();
        }
        if let Some(error) = part.downcast_current_context::<SideloadError>() {
            return match error {
                SideloadError::AuthWithMessage(..) => FailureKind::Rejected,
                SideloadError::DeveloperError(..) => FailureKind::Refused,
                _ => FailureKind::Malformed,
            }
            .into();
        }
    }
    FailureKind::Malformed.into()
}

/// The anisette provider's device state, in Swift's this-device-only
/// Keychain. One device state is shared by all accounts, as on a real device.
struct KeychainStorage(ZagBridgeStorage);

impl SideloadingStorage for KeychainStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        self.store_data(key, value.as_bytes())
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        Ok(self.retrieve_data(key)?.and_then(|data| String::from_utf8(data).ok()))
    }

    fn store_data(&self, key: &str, value: &[u8]) -> Result<(), Report> {
        let key = CString::new(key).map_err(|_| rootcause::report!("storage key"))?;
        match (self.0.store)(self.0.context, key.as_ptr(), value.as_ptr(), value.len()) {
            0 => Ok(()),
            _ => Err(rootcause::report!("storage")),
        }
    }

    fn retrieve_data(&self, key: &str) -> Result<Option<Vec<u8>>, Report> {
        let key = CString::new(key).map_err(|_| rootcause::report!("storage key"))?;
        let mut pointer = std::ptr::null_mut();
        let mut length = 0usize;
        if (self.0.retrieve)(self.0.context, key.as_ptr(), &mut pointer, &mut length) != 0 || pointer.is_null() {
            return Ok(None);
        }
        let data = unsafe { std::slice::from_raw_parts(pointer, length) }.to_vec();
        (self.0.release)(self.0.context, pointer, length);
        Ok(Some(data))
    }

    fn delete(&self, key: &str) -> Result<(), Report> {
        let key = CString::new(key).map_err(|_| rootcause::report!("storage key"))?;
        (self.0.delete_item)(self.0.context, key.as_ptr());
        Ok(())
    }
}

pub struct IsideloadBackend {
    anisette_url: String,
    storage: ZagBridgeStorage,
}

impl IsideloadBackend {
    pub fn new(anisette_url: &str, storage: ZagBridgeStorage) -> Result<Self, Report> {
        // The provider accepts only an https URL; its host becomes its client's
        // only allowed host.
        isideload::net_policy::host_of(anisette_url)?;
        let _ = rustls::crypto::ring::default_provider().install_default();
        Ok(Self { anisette_url: anisette_url.to_string(), storage })
    }

    fn provider(&self) -> Result<RemoteV3AnisetteProvider, Report> {
        // EXPERIMENT: the device serial the provider reports; "0" as upstream.
        RemoteV3AnisetteProvider::new(&self.anisette_url, Box::new(KeychainStorage(self.storage)), "0".into())
    }
}

/// The opaque token Swift stores: everything needed to reopen a portal
/// session, and nothing more.
#[derive(serde::Serialize, serde::Deserialize)]
struct StoredToken {
    adsid: String,
    token: String,
    duration: u64,
    expiry: u64,
}

impl Drop for StoredToken {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.adsid.zeroize();
        self.token.zeroize();
    }
}

/// EXPERIMENT: the unit of the token's expiry (milliseconds is assumed when
/// the value is too large to be seconds).
fn expiry_seconds(expiry: u64) -> u64 {
    if expiry > 100_000_000_000 { expiry / 1000 } else { expiry }
}

fn to_team(team: &DeveloperTeam) -> Team {
    Team {
        identifier: team.team_id.clone(),
        name: team.name.clone().unwrap_or_else(|| "Team".into()),
        kind: "unknown".into(),
    }
}

#[async_trait]
impl Backend for IsideloadBackend {
    async fn sign_in(&self, email: &str, password: Zeroizing<String>, prompter: &Prompter) -> BridgeResult<SignedIn> {
        let provider = self.provider().map_err(|r| classify(&r))?;
        let mut account = AppleAccount::builder(email)
            .anisette_provider(provider)
            .build()
            .await
            .map_err(|r| classify(&r))?;
        // The 2FA callback must be 'static; it reaches the prompter through a
        // channel owned by this call.
        let (ask_tx, mut ask_rx) = tokio::sync::mpsc::unbounded_channel::<(CodePrompt, tokio::sync::oneshot::Sender<CodeAction>)>();
        let callback = move |params: TwoFactorCallbackParams| {
            let ask_tx = ask_tx.clone();
            async move {
                let sms = params.sms;
                let selected = params.selected_number_id.or_else(|| params.numbers.first().map(|n| n.id));
                let masked = params
                    .numbers
                    .iter()
                    .find(|n| Some(n.id) == selected)
                    .map(|n| n.last_two_digits.chars().filter(char::is_ascii_digit).take(2).collect::<String>());
                let prompt = CodePrompt {
                    method: if sms { TwoFactorMethod::Sms } else { TwoFactorMethod::TrustedDevice },
                    code_length: 6,
                    masked_destination: if sms { masked } else { None },
                    can_request_sms: !sms && selected.is_some(),
                    retry: params.last_error.is_some(),
                };
                let (answer_tx, answer_rx) = tokio::sync::oneshot::channel();
                if ask_tx.send((prompt, answer_tx)).is_err() {
                    return Ok(TwoFactorCallbackResponse::Abort);
                }
                Ok(match answer_rx.await.unwrap_or(CodeAction::Cancel) {
                    CodeAction::Submit(code) => TwoFactorCallbackResponse::SubmitCode(code.to_string()),
                    CodeAction::RequestSms => match selected {
                        Some(id) => TwoFactorCallbackResponse::SendSms(id),
                        None => TwoFactorCallbackResponse::Abort,
                    },
                    CodeAction::Cancel => TwoFactorCallbackResponse::Abort,
                })
            }
        };
        let relay = async {
            while let Some((prompt, answer)) = ask_rx.recv().await {
                let _ = answer.send(prompter.ask(prompt).await);
            }
        };
        let login = account.login(&password, callback);
        let result = tokio::select! {
            result = login => result,
            _ = relay => Err(rootcause::report!("relay ended")),
        };
        drop(password);
        result.map_err(|r| classify(&r))?;

        let token = account.get_app_token("xcode.auth").await.map_err(|r| classify(&r))?;
        let adsid = account
            .spd
            .as_ref()
            .and_then(|spd| spd.get_string("adsid").ok())
            .ok_or(BridgeError::new(FailureKind::Malformed))?;
        let mut session = DeveloperSession::new(token.clone(), adsid.clone(), account.grandslam_client.clone(), account.anisette_generator.clone());
        let teams = session.list_teams().await.map_err(|r| classify(&r))?.iter().map(to_team).collect();
        let stored = StoredToken { adsid: adsid.clone(), token: token.token.clone(), duration: token.duration, expiry: token.expiry };
        let opaque = Zeroizing::new(STANDARD.encode(Zeroizing::new(serde_json::to_vec(&stored).map_err(|_| BridgeError::new(FailureKind::Malformed))?)));
        Ok(SignedIn {
            credential: Credential { account_identifier: adsid, token: opaque, expires_at: expiry_seconds(token.expiry) },
            teams,
        })
    }

    async fn open_session(&self, credential: &Credential) -> BridgeResult<Box<dyn PortalSession>> {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(u64::MAX);
        if credential.expires_at <= now {
            return Err(FailureKind::SessionExpired.into());
        }
        let decoded = Zeroizing::new(STANDARD.decode(credential.token.as_bytes()).map_err(|_| BridgeError::new(FailureKind::InvalidInput))?);
        let stored: StoredToken = serde_json::from_slice(&decoded).map_err(|_| BridgeError::new(FailureKind::InvalidInput))?;
        if stored.adsid != credential.account_identifier {
            return Err(FailureKind::InvalidInput.into());
        }
        let generator = AnisetteDataGenerator::new(Arc::new(tokio::sync::RwLock::new(self.provider().map_err(|r| classify(&r))?)));
        let client_info = generator.get_client_info().await.map_err(|r| classify(&r))?;
        let grandslam = GrandSlam::new(client_info).await.map_err(|r| classify(&r))?;
        let token = AppToken { token: stored.token.clone(), duration: stored.duration, expiry: stored.expiry };
        let session = DeveloperSession::new(token, stored.adsid.clone(), Arc::new(grandslam), generator);
        Ok(Box::new(LiveSession { session }))
    }
}

struct LiveSession {
    session: DeveloperSession,
}

fn team(identifier: &str) -> DeveloperTeam {
    DeveloperTeam { name: None, team_id: identifier.to_string(), r#type: None, status: None }
}

fn seconds(date: Option<plist::Date>) -> Option<u64> {
    date.and_then(|d| SystemTime::from(d).duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs())
}

fn value<T: serde::Serialize>(value: &T) -> BridgeResult<Value> {
    serde_json::to_value(value).map_err(|_| FailureKind::Malformed.into())
}

fn certificate_pem(der: &[u8]) -> String {
    let body = STANDARD.encode(der);
    let lines: Vec<&str> = body.as_bytes().chunks(64).map(|c| std::str::from_utf8(c).unwrap_or_default()).collect();
    format!("-----BEGIN CERTIFICATE REQUEST-----\n{}\n-----END CERTIFICATE REQUEST-----\n", lines.join("\n"))
}

impl LiveSession {
    async fn app_id(&mut self, team: &DeveloperTeam, identifier: &str) -> BridgeResult<isideload::dev::app_ids::AppId> {
        let list = self.session.list_app_ids(team, DeveloperDeviceType::Ios).await.map_err(|r| classify(&r))?;
        list.app_ids.into_iter().find(|a| a.app_id_id == identifier).ok_or(FailureKind::InvalidInput.into())
    }
}

#[async_trait]
impl PortalSession for LiveSession {
    async fn call(&mut self, request: PortalRequest) -> BridgeResult<Value> {
        let ios = || DeveloperDeviceType::Ios;
        let c = |r: Report| classify(&r);
        match request {
            PortalRequest::Teams => value(&self.session.list_teams().await.map_err(c)?.iter().map(to_team).collect::<Vec<_>>()),
            PortalRequest::Devices { team: t } => {
                let devices = self.session.list_devices(&team(&t), ios()).await.map_err(c)?;
                value(&devices
                    .into_iter()
                    .map(|d| Device { udid: d.device_number, name: d.name.unwrap_or_default() })
                    .collect::<Vec<_>>())
            }
            PortalRequest::RegisterDevice { team: t, udid, name } => {
                let d = self.session.add_device(&team(&t), &name, &udid, ios()).await.map_err(c)?;
                value(&Device { udid: d.device_number, name: d.name.unwrap_or(name) })
            }
            PortalRequest::AppIds { team: t } => {
                let list = self.session.list_app_ids(&team(&t), ios()).await.map_err(c)?;
                value(&list
                    .app_ids
                    .into_iter()
                    .map(|a| AppId { identifier: a.app_id_id, bundle_identifier: a.identifier, expires_at: seconds(a.expiration_date) })
                    .collect::<Vec<_>>())
            }
            PortalRequest::RegisterAppId { team: t, bundle_identifier, name } => {
                let a = self.session.add_app_id(&team(&t), &name, &bundle_identifier, ios()).await.map_err(c)?;
                value(&AppId { identifier: a.app_id_id, bundle_identifier: a.identifier, expires_at: seconds(a.expiration_date) })
            }
            PortalRequest::AppGroups { team: t } => {
                let groups = self.session.list_app_groups(&team(&t), ios()).await.map_err(c)?;
                Ok(Value::Array(groups.into_iter().map(|g| json!({ "identifier": g.application_group })).collect()))
            }
            PortalRequest::RegisterAppGroup { team: t, identifier } => {
                let g = self.session.add_app_group(&team(&t), &identifier, &identifier, ios()).await.map_err(c)?;
                Ok(json!({ "identifier": g.application_group }))
            }
            PortalRequest::AssignAppGroups { team: t, groups, app_id } => {
                let developer_team = team(&t);
                let app = self.app_id(&developer_team, &app_id).await?;
                let known = self.session.list_app_groups(&developer_team, ios()).await.map_err(c)?;
                for wanted in &groups {
                    let group = known.iter().find(|g| &g.application_group == wanted).ok_or(BridgeError::new(FailureKind::InvalidInput))?;
                    self.session.assign_app_group(&developer_team, group, &app, ios()).await.map_err(c)?;
                }
                Ok(Value::Null)
            }
            PortalRequest::Certificates { team: t } => {
                let certificates = self.session.list_ios_certs(&team(&t)).await.map_err(c)?;
                value(&certificates
                    .into_iter()
                    .filter_map(|cert| {
                        Some(Certificate {
                            serial_number: cert.serial_number?,
                            name: cert.name.unwrap_or_default(),
                            machine_name: cert.machine_name,
                            expires_at: seconds(cert.expiration_date)?,
                            data: None,
                        })
                    })
                    .collect::<Vec<_>>())
            }
            PortalRequest::SubmitCertificateRequest { team: t, request, machine_name } => {
                let developer_team = team(&t);
                let der = STANDARD.decode(request).map_err(|_| BridgeError::new(FailureKind::InvalidInput))?;
                let submitted = self
                    .session
                    .submit_development_csr(&developer_team, certificate_pem(&der), machine_name, ios())
                    .await
                    .map_err(c)?;
                // EXPERIMENT: the issued certificate is found by the request's
                // identifier, as upstream does.
                let issued = self
                    .session
                    .list_ios_certs(&developer_team)
                    .await
                    .map_err(c)?
                    .into_iter()
                    .find(|cert| cert.certificate_id.as_deref() == Some(submitted.cert_request_id.as_str()))
                    .ok_or(BridgeError::new(FailureKind::Malformed))?;
                value(&Certificate {
                    serial_number: issued.serial_number.ok_or(BridgeError::new(FailureKind::Malformed))?,
                    name: issued.name.unwrap_or_default(),
                    machine_name: issued.machine_name,
                    expires_at: seconds(issued.expiration_date).ok_or(BridgeError::new(FailureKind::Malformed))?,
                    data: Some(STANDARD.encode(issued.cert_content.ok_or(BridgeError::new(FailureKind::Malformed))?.as_ref() as &[u8])),
                })
            }
            PortalRequest::Profile { team: t, app_id } => {
                let developer_team = team(&t);
                let app = self.app_id(&developer_team, &app_id).await?;
                let profile = self
                    .session
                    .download_team_provisioning_profile(&developer_team, &app, ios())
                    .await
                    .map_err(c)?;
                Ok(json!({ "data": STANDARD.encode(AsRef::<[u8]>::as_ref(&profile.encoded_profile)) }))
            }
        }
    }
}
