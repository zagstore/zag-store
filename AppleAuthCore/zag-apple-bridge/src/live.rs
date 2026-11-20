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
/// Keychain, kept per account: every key is prefixed with the account's
/// anisette scope, so no account reads or writes another's device state
/// (owner decision, 19 Nov: per-account isolation).
pub(crate) struct KeychainStorage {
    storage: ZagBridgeStorage,
    scope: String,
}

impl KeychainStorage {
    pub(crate) fn new(storage: ZagBridgeStorage, scope: &str) -> Result<Self, Report> {
        if !crate::backend::valid_anisette_scope(scope) {
            return Err(rootcause::report!("anisette scope"));
        }
        Ok(Self { storage, scope: scope.to_string() })
    }

    fn scoped(&self, key: &str) -> Result<CString, Report> {
        CString::new(format!("{}/{key}", self.scope)).map_err(|_| rootcause::report!("storage key"))
    }
}

impl SideloadingStorage for KeychainStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        self.store_data(key, value.as_bytes())
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        Ok(self.retrieve_data(key)?.and_then(|data| String::from_utf8(data).ok()))
    }

    fn store_data(&self, key: &str, value: &[u8]) -> Result<(), Report> {
        let key = self.scoped(key)?;
        match (self.storage.store)(self.storage.context, key.as_ptr(), value.as_ptr(), value.len()) {
            0 => Ok(()),
            _ => Err(rootcause::report!("storage")),
        }
    }

    fn retrieve_data(&self, key: &str) -> Result<Option<Vec<u8>>, Report> {
        let key = self.scoped(key)?;
        let mut pointer = std::ptr::null_mut();
        let mut length = 0usize;
        if (self.storage.retrieve)(self.storage.context, key.as_ptr(), &mut pointer, &mut length) != 0 || pointer.is_null() {
            return Ok(None);
        }
        let data = unsafe { std::slice::from_raw_parts(pointer, length) }.to_vec();
        (self.storage.release)(self.storage.context, pointer, length);
        Ok(Some(data))
    }

    fn delete(&self, key: &str) -> Result<(), Report> {
        let key = self.scoped(key)?;
        (self.storage.delete_item)(self.storage.context, key.as_ptr());
        Ok(())
    }
}

pub struct IsideloadBackend {
    anisette_url: String,
    /// The device serial the anisette provider reports. There is no default:
    /// it is part of the G3 provider decision and is passed in by Swift.
    device_serial: String,
    storage: ZagBridgeStorage,
}

/// 1–32 ASCII letters or digits.
pub(crate) fn valid_serial(serial: &str) -> bool {
    !serial.is_empty() && serial.len() <= 32 && serial.bytes().all(|b| b.is_ascii_alphanumeric())
}

/// Reject unsafe anisette endpoints before constructing a provider, not only
/// when its HTTP or WebSocket client attempts a connection.
fn validate_anisette_url(raw: &str) -> Result<(), Report> {
    // URL parsers normalize an explicit :443 away. Reject explicit authority
    // ports from the raw input before parsing so the policy is unambiguous.
    let authority = raw
        .strip_prefix("https://")
        .ok_or_else(|| rootcause::report!(PolicyError::NotSecure))?
        .split(['/', '?', '#'])
        .next()
        .unwrap_or_default();
    if authority.contains(':') {
        return Err(rootcause::report!(PolicyError::HostNotAllowed).into());
    }
    let url = reqwest::Url::parse(raw)
        .map_err(|_| rootcause::report!(PolicyError::InvalidUrl))?;
    let host = isideload::net_policy::host_of(raw)?;
    isideload::net_policy::check_url(&url, &[host], "https")
        .map_err(|error| rootcause::report!(error))?;
    Ok(())
}

impl IsideloadBackend {
    pub fn new(anisette_url: &str, device_serial: &str, storage: ZagBridgeStorage) -> Result<Self, Report> {
        // Apply the complete URL policy at configuration time. The provider
        // also checks every outbound HTTP and WebSocket request.
        validate_anisette_url(anisette_url)?;
        if !valid_serial(device_serial) {
            return Err(rootcause::report!("device serial"));
        }
        let _ = rustls::crypto::ring::default_provider().install_default();
        Ok(Self { anisette_url: anisette_url.to_string(), device_serial: device_serial.to_string(), storage })
    }

    /// A provider over one account's anisette device state.
    fn provider(&self, scope: &str) -> Result<RemoteV3AnisetteProvider, Report> {
        RemoteV3AnisetteProvider::new(&self.anisette_url, Box::new(KeychainStorage::new(self.storage, scope)?), self.device_serial.clone())
    }
}

/// The opaque token Swift stores: everything needed to reopen a portal
/// session, and nothing more.
#[derive(serde::Serialize, serde::Deserialize)]
struct StoredToken {
    /// The account's anisette scope: portal sessions reopen with the same
    /// device state the sign-in used.
    anisette_scope: String,
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

/// EXPERIMENT: the token's expiry, in seconds since 1970, only when exactly
/// one reading (seconds or milliseconds) gives a time between one minute and
/// 400 days from now (Zag Store's own session bounds). Anything else is
/// refused (`None`), so no unit is guessed.
pub(crate) fn expiry_seconds(expiry: u64, now: u64) -> Option<u64> {
    let plausible = |t: u64| t >= now.saturating_add(60) && t <= now.saturating_add(400 * 86_400);
    match (plausible(expiry), plausible(expiry / 1000)) {
        (true, false) => Some(expiry),
        (false, true) => Some(expiry / 1000),
        _ => None,
    }
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(u64::MAX)
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
    async fn sign_in(&self, anisette_scope: &str, email: &str, password: Zeroizing<String>, prompter: &Prompter) -> BridgeResult<SignedIn> {
        let provider = self.provider(anisette_scope).map_err(|_| BridgeError::new(FailureKind::InvalidInput))?;
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
        let stored = StoredToken {
            anisette_scope: anisette_scope.to_string(),
            adsid: adsid.clone(),
            token: token.token.clone(),
            duration: token.duration,
            expiry: token.expiry,
        };
        let opaque = Zeroizing::new(STANDARD.encode(Zeroizing::new(serde_json::to_vec(&stored).map_err(|_| BridgeError::new(FailureKind::Malformed))?)));
        Ok(SignedIn {
            credential: Credential {
                account_identifier: adsid,
                token: opaque,
                expires_at: expiry_seconds(token.expiry, unix_now()).ok_or(BridgeError::new(FailureKind::Malformed))?,
            },
            teams,
        })
    }

    async fn open_session(&self, credential: &Credential) -> BridgeResult<Box<dyn PortalSession>> {
        if credential.expires_at <= unix_now() {
            return Err(FailureKind::SessionExpired.into());
        }
        let decoded = Zeroizing::new(STANDARD.decode(credential.token.as_bytes()).map_err(|_| BridgeError::new(FailureKind::InvalidInput))?);
        let stored: StoredToken = serde_json::from_slice(&decoded).map_err(|_| BridgeError::new(FailureKind::InvalidInput))?;
        if stored.adsid != credential.account_identifier {
            return Err(FailureKind::InvalidInput.into());
        }
        let provider = self.provider(&stored.anisette_scope).map_err(|_| BridgeError::new(FailureKind::InvalidInput))?;
        let generator = AnisetteDataGenerator::new(Arc::new(tokio::sync::RwLock::new(provider)));
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
                // Every development certificate the endpoint lists:
                // `list_ios_certs` drops those labelled with another platform,
                // which would undercount an existing account (or make one look
                // empty). The count is E4's, the inventory's and the budget's.
                let certificates = self.session.list_all_development_certs(&team(&t), ios()).await.map_err(c)?;
                // A certificate without a serial or an expiry fails the whole
                // listing: dropping it would hide it from the certificate plan.
                // Its content, when Apple includes it, lets a certificate whose
                // issue response was lost be recognised by its key.
                let listed = certificates
                    .into_iter()
                    .map(|cert| {
                        Some(Certificate {
                            serial_number: cert.serial_number?,
                            name: cert.name.unwrap_or_default(),
                            machine_name: cert.machine_name,
                            expires_at: seconds(cert.expiration_date)?,
                            data: cert.cert_content.map(|content| STANDARD.encode(content.as_ref() as &[u8])).filter(|encoded| !encoded.is_empty()),
                        })
                    })
                    .collect::<Option<Vec<_>>>()
                    .ok_or(BridgeError::new(FailureKind::Malformed))?;
                value(&listed)
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

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_795_000_000;

    #[test]
    fn expiry_unit_is_never_guessed() {
        let in_a_day = NOW + 86_400;
        assert_eq!(expiry_seconds(in_a_day, NOW), Some(in_a_day), "seconds");
        assert_eq!(expiry_seconds(in_a_day * 1000, NOW), Some(in_a_day), "milliseconds");
        assert_eq!(expiry_seconds(NOW - 10, NOW), None, "already past");
        assert_eq!(expiry_seconds(NOW + 30, NOW), None, "under a minute");
        assert_eq!(expiry_seconds(NOW + 401 * 86_400, NOW), None, "beyond 400 days");
        assert_eq!(expiry_seconds(3600, NOW), None, "a duration, not a time");
        assert_eq!(expiry_seconds(0, NOW), None);
        assert_eq!(expiry_seconds(u64::MAX, NOW), None);
    }

    mod memory {
        use std::collections::HashMap;
        use std::ffi::{CStr, c_char, c_void};
        use std::sync::Mutex;

        pub static ITEMS: Mutex<Option<HashMap<String, Vec<u8>>>> = Mutex::new(None);

        fn key(k: *const c_char) -> String {
            unsafe { CStr::from_ptr(k) }.to_str().unwrap().to_string()
        }
        pub extern "C" fn store(_: *mut c_void, k: *const c_char, v: *const u8, n: usize) -> i32 {
            let value = unsafe { std::slice::from_raw_parts(v, n) }.to_vec();
            ITEMS.lock().unwrap().get_or_insert_with(HashMap::new).insert(key(k), value);
            0
        }
        pub extern "C" fn retrieve(_: *mut c_void, k: *const c_char, v: *mut *mut u8, n: *mut usize) -> i32 {
            let Some(value) = ITEMS.lock().unwrap().get_or_insert_with(HashMap::new).get(&key(k)).cloned() else { return 1 };
            let boxed = value.into_boxed_slice();
            unsafe {
                *n = boxed.len();
                *v = Box::into_raw(boxed) as *mut u8;
            }
            0
        }
        pub extern "C" fn delete_item(_: *mut c_void, k: *const c_char) -> i32 {
            ITEMS.lock().unwrap().get_or_insert_with(HashMap::new).remove(&key(k));
            0
        }
        pub extern "C" fn release(_: *mut c_void, v: *mut u8, n: usize) {
            drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(v, n)) });
        }
    }

    #[test]
    fn anisette_state_is_kept_per_account() {
        let storage = ZagBridgeStorage {
            context: std::ptr::null_mut(),
            store: memory::store,
            retrieve: memory::retrieve,
            delete_item: memory::delete_item,
            release: memory::release,
        };
        let first = KeychainStorage::new(storage, "a0123456789abcdef").unwrap();
        let second = KeychainStorage::new(storage, "bfedcba9876543210").unwrap();
        first.store("adi.pb", "first device").unwrap();
        assert_eq!(second.retrieve("adi.pb").unwrap(), None, "another account never reads this account's state");
        second.store("adi.pb", "second device").unwrap();
        assert_eq!(first.retrieve("adi.pb").unwrap().as_deref(), Some("first device"));
        assert_eq!(second.retrieve("adi.pb").unwrap().as_deref(), Some("second device"));
        second.delete("adi.pb").unwrap();
        assert_eq!(first.retrieve("adi.pb").unwrap().as_deref(), Some("first device"), "deleting one account's state leaves the other's");
        let keys: Vec<String> = memory::ITEMS.lock().unwrap().as_ref().unwrap().keys().cloned().collect();
        assert_eq!(keys, vec!["a0123456789abcdef/adi.pb".to_string()], "every stored key carries its account's scope");
        for scope in ["", "has space", "a/b", &"a".repeat(65)] {
            assert!(KeychainStorage::new(storage, scope).is_err(), "scope {scope:?} is refused");
        }
    }

    #[test]
    fn anisette_configuration_rejects_unsafe_urls() {
        for url in [
            "http://anisette.example/v3",
            "https://user:secret@anisette.example/v3",
            "https://anisette.example:8443/v3",
            "https://anisette.example:443/v3",
            "https://",
        ] {
            assert!(validate_anisette_url(url).is_err(), "accepted {url:?}");
        }
        assert!(validate_anisette_url("https://anisette.example/v3").is_ok());
    }

    #[test]
    fn device_serial_has_no_default_and_is_bounded() {
        assert!(!valid_serial(""));
        assert!(!valid_serial("has space"));
        assert!(!valid_serial(&"A".repeat(33)));
        assert!(valid_serial("C02ZAGTEST01"));
    }
}
