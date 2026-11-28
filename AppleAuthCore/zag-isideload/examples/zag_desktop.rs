//! Desktop transport for the installer. JSON Lines over private parent/child pipes.
use std::{
    collections::HashMap,
    io::{self, Write},
    sync::Arc,
    time::SystemTime,
};

use base64::prelude::*;
use isideload::{
    anisette::{
        AnisetteClientInfo, AnisetteData, AnisetteDataResponse, AnisetteProvider,
        remote_v3::RemoteV3AnisetteProvider,
    },
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    auth::grandslam::GrandSlam,
    dev::{
        app_ids::AppIdsApi,
        developer_session::DeveloperSession,
        device_type::{
            DeveloperDeviceType::{Any, Ios},
            dev_url,
        },
        devices::DevicesApi,
    },
    net_policy,
    util::{plist::PlistDataExtract, storage::SideloadingStorage},
};
use plist::{Dictionary, Value as Plist};
use plist_macro::plist;
use rootcause::prelude::*;
use serde::Deserialize;
use serde_json::{Value, json};
use zeroize::Zeroizing;

fn relay(event: Value) -> Result<Value, Report> {
    let mut output = io::stdout().lock();
    writeln!(output, "{event}")?;
    output.flush()?;
    let mut line = Zeroizing::new(String::new());
    io::stdin().read_line(&mut line)?;
    serde_json::from_str(&line).map_err(|_| report!("Invalid or cancelled installer response"))
}

fn field<'a>(value: &'a Value, key: &str) -> Result<&'a str, Report> {
    value[key]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| report!("Missing installer field"))
}

struct AnisetteStorage;
impl SideloadingStorage for AnisetteStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        if relay(json!({"event":"state_write", "key":key, "value":value}))? != true {
            bail!("Could not store anisette state");
        }
        Ok(())
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        let value = relay(json!({"event":"state_read", "key":key}))?;
        if value.is_null() {
            return Ok(None);
        }
        Ok(Some(
            value
                .as_str()
                .ok_or_else(|| report!("Invalid anisette state"))?
                .into(),
        ))
    }
}

struct NativeAnisette {
    identity: AnisetteClientInfo,
}

impl NativeAnisette {
    fn new() -> Result<Self, Report> {
        let identity = relay(json!({"event":"native_identity"}))?;
        Ok(Self {
            identity: AnisetteClientInfo {
                client_info: field(&identity, "X-MMe-Client-Info")?.to_string(),
                user_agent: field(&identity, "User-Agent")?.to_string(),
            },
        })
    }

    fn read(&self, prepare: bool) -> Result<AnisetteDataResponse, Report> {
        let headers: HashMap<String, String> =
            serde_json::from_value(relay(json!({"event":"native_headers","prepare":prepare}))?)
                .map_err(|_| report!("Invalid local anisette headers"))?;
        for (name, expected) in [
            ("X-MMe-Client-Info", &self.identity.client_info),
            ("User-Agent", &self.identity.user_agent),
        ] {
            if !headers
                .iter()
                .any(|(key, value)| key.eq_ignore_ascii_case(name) && value == expected)
            {
                bail!("Local anisette identity changed");
            }
        }
        Ok(AnisetteDataResponse::Data(
            AnisetteData::from_local_headers(&headers)?,
        ))
    }
}

#[async_trait::async_trait]
impl AnisetteProvider for NativeAnisette {
    async fn get_anisette_data(&self) -> Result<AnisetteDataResponse, Report> {
        self.read(false)
    }

    async fn get_client_info(&self) -> Result<AnisetteClientInfo, Report> {
        Ok(self.identity.clone())
    }

    async fn provision(&mut self, _: &Arc<GrandSlam>, _: bool) -> Result<(), Report> {
        bail!("Local anisette must be prepared before sign-in")
    }
}

async fn two_factor(params: TwoFactorCallbackParams) -> Result<TwoFactorCallbackResponse, Report> {
    use TwoFactorCallbackResponse::*;
    let numbers: Vec<_> = params
        .numbers
        .iter()
        .map(|n| {
            json!({
                "id": n.id, "last_two": n.last_two_digits,
            })
        })
        .collect();
    let answer = relay(json!({"event":"two_factor", "unknown":params.unknown,
        "sms":params.sms, "retry":params.last_error.is_some(), "numbers":numbers}))?;
    match field(&answer, "action")? {
        "code" if !params.unknown => {
            let code = field(&answer, "code")?;
            if code.len() == 6 && code.bytes().all(|b| b.is_ascii_digit()) {
                return Ok(SubmitCode(code.into()));
            }
        }
        "sms" => {
            if let Some(number) = params.numbers.iter().find(|n| answer["id"] == n.id) {
                return Ok(SendSms(number.id));
            }
        }
        "devices" => return Ok(SendToDevices),
        "resend" if !params.unknown => return Ok(ResendCode),
        _ => (),
    }
    Ok(Abort)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TeamRow {
    team_id: String,
    name: Option<String>,
    status: Option<String>,
    #[serde(rename = "type")]
    membership_type: Option<String>,
    #[serde(default)]
    memberships: Vec<Membership>,
}

#[derive(Deserialize)]
struct Membership {
    name: Option<String>,
}

fn personal_team(row: &TeamRow) -> bool {
    let statuses = ["inactive", "expired", "disabled", "revoked", "pending"];
    row.team_id.len() == 10
        && row
            .team_id
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
        && !row
            .status
            .as_deref()
            .is_some_and(|s| statuses.contains(&s.to_ascii_lowercase().as_str()))
        && (row
            .memberships
            .iter()
            .filter_map(|m| m.name.as_deref())
            .chain(row.membership_type.as_deref())
            .any(|label| {
                let label = label.to_ascii_lowercase();
                label.contains("personal") || label.contains("free")
            })
            || row
                .name
                .as_deref()
                .is_some_and(|name| name.to_ascii_lowercase().ends_with("(personal team)")))
}

fn certificate_data(attributes: &Value) -> Option<Vec<u8>> {
    let text = attributes["certificateContent"]
        .as_str()
        .or_else(|| attributes["certContent"].as_str())?;
    let encoded: String = text
        .lines()
        .filter(|line| !line.starts_with("-----"))
        .flat_map(str::chars)
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    BASE64_STANDARD
        .decode(encoded)
        .ok()
        .filter(|der| !der.is_empty())
}

fn safe_resource_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

// Personal Team certificate inventory uses the same JSON:API transport as
// ZagNativeDeveloperPortal. All requests still pass the Rust Apple allowlist.
async fn certificate_response(
    session: &mut DeveloperSession,
    team_id: &str,
    id: Option<&str>,
) -> Result<Value, Report> {
    let base = "https://developerservices2.apple.com/services/v1/certificates";
    let path = if let Some(id) = id {
        if !safe_resource_id(id) {
            bail!("Invalid Apple certificate resource ID");
        }
        format!("{base}/{id}")
    } else {
        base.to_string()
    };
    let mut headers = session.get_headers().await?;
    for (name, value) in [
        ("x-http-method-override", "GET"),
        ("accept-language", "en-us"),
        ("accept", "application/vnd.api+json"),
        ("content-type", "application/vnd.api+json"),
    ] {
        headers.insert(name, reqwest::header::HeaderValue::from_static(value));
    }
    let response = session
        .get_grandslam_client()
        .post(&path)?
        .headers(headers)
        .body(json!({"urlEncodedQueryParams":format!("teamId={team_id}")}).to_string())
        .send()
        .await?
        .error_for_status()?
        .json::<Value>()
        .await?;
    if response["errors"]
        .as_array()
        .is_some_and(|errors| !errors.is_empty())
    {
        bail!("Apple certificate inventory returned an error");
    }
    Ok(response)
}

async fn inventory(
    session: &mut DeveloperSession,
    team_id: &str,
    only: Option<&str>,
) -> Result<Vec<Vec<u8>>, Report> {
    let result = certificate_response(session, team_id, None).await?;
    let rows = result["data"]
        .as_array()
        .filter(|rows| rows.len() <= 32)
        .ok_or_else(|| report!("Missing or oversized Apple certificate inventory"))?;
    let mut certificates = Vec::new();
    for row in rows {
        let id = field(row, "id")?;
        if only.is_some_and(|want| id != want) {
            continue;
        }
        let attributes = &row["attributes"];
        if let Some(der) = certificate_data(attributes) {
            certificates.push(der);
            continue;
        }
        let listed_serial = attributes["serialNumber"]
            .as_str()
            .or_else(|| attributes["serialNum"].as_str())
            .ok_or_else(|| report!("Missing Apple certificate metadata"))?;
        let detail = certificate_response(session, team_id, Some(id)).await?;
        let data = &detail["data"];
        let attributes = &data["attributes"];
        let serial = attributes["serialNumber"]
            .as_str()
            .or_else(|| attributes["serialNum"].as_str())
            .ok_or_else(|| report!("Missing Apple certificate detail serial"))?;
        if data["id"] != id
            || !serial
                .trim_start_matches('0')
                .eq_ignore_ascii_case(listed_serial.trim_start_matches('0'))
        {
            bail!("Apple certificate detail did not match its inventory record");
        }
        certificates.push(
            certificate_data(attributes)
                .ok_or_else(|| report!("Missing Apple certificate data"))?,
        );
    }
    Ok(certificates)
}

fn developer_code(error: &Report) -> Option<i64> {
    error.iter_reports().find_map(|node| {
        match node.downcast_current_context::<isideload::SideloadError>()? {
            isideload::SideloadError::AuthWithMessage(code, _)
            | isideload::SideloadError::DeveloperError(code, _) => Some(*code),
            _ => None,
        }
    })
}

fn plist_blob(row: &Dictionary, key: &str) -> Option<Vec<u8>> {
    match row.get(key)? {
        Plist::Data(bytes) => Some(bytes.clone()),
        Plist::String(encoded) => certificate_data(&json!({"certContent":encoded})),
        _ => None,
    }
    .filter(|bytes| !bytes.is_empty())
}

async fn issue_certificate(
    session: &mut DeveloperSession,
    team_id: &str,
    answer: &Value,
) -> Result<Vec<u8>, Report> {
    let csr = field(answer, "csr")?;
    let machine_id = field(answer, "machine_id")?;
    uuid::Uuid::parse_str(machine_id)?;
    let request = session.send_dev_request_no_response(&dev_url("submitDevelopmentCSR", Ios), plist!(dict {
        "teamId": team_id, "csrContent": csr, "machineName": "Zag Installer", "machineId": machine_id,
    })).await;
    let result = match request {
        Ok(result) => result,
        Err(error) => {
            if matches!(developer_code(&error), Some(3540 | 7458 | 7460)) {
                // These submission failures definitively refused this request.
                relay(json!({"event":"certificate_refused"}))?;
            }
            return Err(error);
        }
    };
    let row = result
        .get("certRequest")
        .or_else(|| result.get("certificate"))
        .and_then(Plist::as_dictionary)
        .ok_or_else(|| report!("Missing issuance receipt"))?;
    if let Some(der) =
        plist_blob(row, "certificateContent").or_else(|| plist_blob(row, "certContent"))
    {
        return Ok(der);
    }
    let id = row
        .get("certificateId")
        .or_else(|| row.get("certRequestId"))
        .and_then(Plist::as_string)
        .filter(|id| safe_resource_id(id))
        .ok_or_else(|| report!("Missing issued certificate identifier"))?;
    let mut issued = inventory(session, team_id, Some(id)).await?;
    if issued.len() != 1 {
        bail!("Issued certificate unavailable or ambiguous");
    }
    Ok(issued.remove(0))
}

// Publish only fixed stage names. Apple response bodies can contain account or device data.
async fn run(stage: &mut &'static str) -> Result<(), Report> {
    if !net_policy::LIVE_NETWORK {
        bail!("Desktop networking was disabled at build time");
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let config = relay(json!({"event":"configuration"}))?;
    let udid = field(&config, "udid")?;
    let suffixes = config["suffixes"]
        .as_array()
        .filter(|v| !v.is_empty() && v.len() <= 32)
        .ok_or_else(|| report!("Invalid component list"))?;
    let suffixes: Vec<&str> = suffixes
        .iter()
        .map(|item| {
            item.as_str()
                .filter(|s| {
                    s.is_empty()
                        || (s.len() <= 200
                            && s.starts_with('.')
                            && s[1..].split('.').all(|part| {
                                !part.is_empty()
                                    && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                            }))
                })
                .ok_or_else(|| report!("Invalid component identifier"))
        })
        .collect::<Result<_, Report>>()?;
    let imported_prefix = if config.get("imported_prefix").is_some() {
        let prefix = field(&config, "imported_prefix")?;
        let digest = prefix.strip_prefix("app.zloader.imported.")
            .ok_or_else(|| report!("Invalid imported namespace"))?;
        if digest.len() != 32 || !digest.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || suffixes.iter().filter(|s| s.is_empty()).count() != 1
            || suffixes.iter().any(|s| s.len() > 180)
            || suffixes.iter().map(|s| s.to_ascii_lowercase()).collect::<std::collections::HashSet<_>>().len() != suffixes.len()
            || config["provider"] != "native" || config["account_bootstrap"] == true
        {
            bail!("Invalid imported provisioning configuration");
        }
        Some(prefix)
    } else {
        None
    };
    let email = field(&config, "email")?;
    let builder = AppleAccount::builder(email);
    *stage = "anisette preflight";
    let builder = match field(&config, "provider")? {
        "native" => {
            let native = NativeAnisette::new()?;
            native.read(true)?;
            builder.anisette_provider(native)
        }
        "remote" => {
            let endpoint = field(&config, "endpoint")?;
            let url = reqwest::Url::parse(endpoint)?;
            net_policy::check_url(&url, &[net_policy::host_of(endpoint)?], "https")?;
            if url.path() != "/" || url.query().is_some() || url.fragment().is_some() {
                bail!("Expected an anisette HTTPS origin");
            }
            builder.anisette_provider(RemoteV3AnisetteProvider::new(
                endpoint,
                Box::new(AnisetteStorage),
                "".into(),
            )?)
        }
        _ => bail!("Unknown anisette provider"),
    };
    let mut account = builder.build().await?;
    account
        .anisette_generator
        .get_anisette_data(account.grandslam_client.clone())
        .await?;
    *stage = "Apple sign-in or verification";
    let password = Zeroizing::new(
        relay(json!({"event":"password"}))?
            .as_str()
            .filter(|value| !value.is_empty())
            .ok_or_else(|| report!("No password"))?
            .to_string(),
    );
    account.login(&password, two_factor).await?;
    drop(password);

    *stage = "Apple developer session";
    let adsid = account
        .spd
        .as_ref()
        .ok_or_else(|| report!("Missing authenticated identity"))?
        .get_string("adsid")?;
    if adsid.is_empty() {
        bail!("Missing authenticated identity");
    }
    let token = account.get_app_token("xcode.auth").await?;
    let expires = if token.expiry >= 1_000_000_000_000 {
        token.expiry / 1000
    } else {
        token.expiry
    };
    let check_session = || {
        let now = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)?
            .as_secs();
        if expires <= now {
            bail!("Apple developer session expired");
        }
        Ok::<(), Report>(())
    };
    check_session()?;
    // Only an explicitly authorised native development installer requests a
    // portable developer token. Never export the password, SPD or ADI state.
    let portable = if config["account_bootstrap"] == true {
        Some(json!({"accountID": &adsid, "token": &token.token,
                    "expiresAtMs": expires.checked_mul(1000).ok_or_else(|| report!("Invalid token expiry"))?}))
    } else {
        None
    };
    let mut session = DeveloperSession::new(
        token,
        adsid.clone(),
        account.grandslam_client.clone(),
        account.anisette_generator.clone(),
    );
    drop(account);
    let teams: Vec<TeamRow> = session
        .send_dev_request(&dev_url("listTeams", Any), None, "teams")
        .await?;
    let personal: Vec<_> = teams.iter().filter(|row| personal_team(row)).collect();
    let choice = relay(
        json!({"event":"team","account":adsid,"teams":personal.iter()
        .map(|t| json!({"id":t.team_id,"name":t.name})).collect::<Vec<_>>()}),
    )?;
    let team_id = &personal
        .iter()
        .find(|t| choice.as_str() == Some(t.team_id.as_str()))
        .ok_or_else(|| report!("Personal Team unavailable"))?
        .team_id;
    let team = isideload::dev::teams::DeveloperTeam {
        team_id: team_id.clone(),
        name: None,
        r#type: None,
        status: None,
    };

    if let Some(credential) = portable {
        if relay(json!({"event":"account_bootstrap","credential":credential}))? != true {
            bail!("Desktop account transfer was not accepted");
        }
    }
    *stage = "development certificate inventory";
    check_session()?;
    let available = inventory(&mut session, team_id, None).await?;
    let answer = relay(json!({"event":"certificate","certificates":available.iter()
        .map(|der| BASE64_STANDARD.encode(der)).collect::<Vec<_>>()}))?;
    let certificate = if let Some(index) = answer["index"].as_u64() {
        available
            .get(usize::try_from(index)?)
            .ok_or_else(|| report!("Invalid certificate selection"))?
            .clone()
    } else {
        *stage = "Apple certificate submission or issuance lookup";
        check_session()?;
        issue_certificate(&mut session, team_id, &answer).await?
    };
    if relay(json!({"event":"certificate_selected", "der":BASE64_STANDARD.encode(&certificate)}))?
        != true
    {
        bail!("Certificate does not belong to the local key");
    }

    *stage = "Apple device registration";
    check_session()?;
    let devices = session.list_devices(&team, Ios).await?;
    if let Some(device) = devices
        .iter()
        .find(|device| device.device_number.eq_ignore_ascii_case(udid))
    {
        if device.status.as_deref().is_some_and(|status| {
            ["disabled", "inactive"].contains(&status.to_ascii_lowercase().as_str())
        }) {
            bail!("The Apple device registration is inactive");
        }
    } else {
        let device = session
            .add_device(&team, "Zag Installer USB Device", udid, Ios)
            .await?;
        if !device.device_number.eq_ignore_ascii_case(udid) {
            bail!("Device registration returned a different UDID");
        }
    }
    *stage = "Apple app identifier registration";
    check_session()?;
    let response = session
        .send_dev_request_no_response(
            &dev_url("listAppIds", Ios),
            plist!(dict {"teamId": team_id}),
        )
        .await?;
    for suffix in suffixes {
        *stage = "Apple app identifier registration";
        check_session()?;
        let identifier = format!("{}.{team_id}{suffix}", imported_prefix.unwrap_or("app.zagstore.ios"));
        let mut app_id = None;
        if let Some(list) = response.get("appIds") {
            let rows = list
                .as_array()
                .ok_or_else(|| report!("Invalid App ID inventory"))?;
            app_id = rows
                .iter()
                .filter_map(Plist::as_dictionary)
                .find(|row| {
                    row.get("identifier").and_then(Plist::as_string) == Some(identifier.as_str())
                })
                .map(|row| {
                    row.get("appIdId")
                        .or_else(|| row.get("appIdentifierId"))
                        .and_then(Plist::as_string)
                        .map(str::to_string)
                        .ok_or_else(|| report!("Missing registered App ID"))
                })
                .transpose()?;
        } else if response
            .get("resultCode")
            .and_then(Plist::as_signed_integer)
            != Some(0)
        {
            bail!("Missing App ID inventory");
        }
        let app_id = if let Some(app_id) = app_id {
            app_id
        } else {
            let name = if let Some(prefix) = imported_prefix {
                if suffix.is_empty() {
                    format!("zLoader {}", &prefix[prefix.len() - 12..])
                } else {
                    // Distinguish App ID display names without exposing the source app name.
                    let index = suffix[1..].replace(['.', '-'], " ");
                    let short: String = index.chars().take(40).collect();
                    format!("zLoader {} {}", &prefix[prefix.len() - 12..], short)
                }
            } else if suffix.is_empty() {
                "Zag Store".to_string()
            } else {
                format!("Zag Store {}", suffix[1..].replace(['.', '-'], " "))
            };
            let app = session.add_app_id(&team, &name, &identifier, Ios).await?;
            if app.identifier != identifier {
                bail!("Unexpected app identifier");
            }
            app.app_id_id
        };
        *stage = "Apple Personal Team profile";
        check_session()?;
        let result = session
            .send_dev_request_no_response(
                &dev_url("downloadTeamProvisioningProfile", Ios),
                plist!(dict {"teamId": team_id, "appIdId": &app_id}),
            )
            .await?;
        let profile = result
            .get("provisioningProfile")
            .and_then(Plist::as_dictionary)
            .ok_or_else(|| report!("Missing Apple provisioning profile"))?;
        let profile = plist_blob(profile, "encodedProfile")
            .ok_or_else(|| report!("Missing embedded profile data"))?;
        let _: Value = relay(
            json!({"event":"profile", "suffix":suffix, "data":BASE64_STANDARD.encode(profile)}),
        )?;
    }
    Ok(())
}

fn network_hint(report: &Report) -> Option<&'static str> {
    use std::error::Error;
    for node in report.iter_reports() {
        let direct = node.downcast_current_context::<reqwest::Error>();
        let wrapped = node
            .downcast_current_context::<reqwest_middleware::Error>()
            .and_then(|error| match error {
                reqwest_middleware::Error::Reqwest(reqwest) => Some(reqwest),
                _ => None,
            });
        let Some(error) = direct.or(wrapped) else {
            continue;
        };
        if let Some(status) = error.status() {
            return Some(match status.as_u16() {
                401 | 403 => "The server rejected access. Check the provider or sign in again before retrying.",
                429 => "The server is rate limiting requests. Wait and retry.",
                500..=599 => "The server is temporarily unavailable. Try again later.",
                _ => "The server returned an unexpected HTTP response.",
            });
        }
        if error.is_timeout() {
            return Some("The request timed out. Check connectivity and retry.");
        }
        let mut cause = error.source();
        while let Some(source) = cause {
            if source.is::<rustls::Error>() {
                return Some(
                    "TLS failed. Check the Mac's date, macOS trust settings, or an intercepting proxy.",
                );
            }
            cause = source.source();
        }
        if error.is_connect() {
            return Some(
                "The server could not be reached. Check DNS, connectivity, and firewall settings.",
            );
        }
        return Some(
            "The network response could not be processed. Try again on a stable connection.",
        );
    }
    None
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let mut stage = "installer configuration";
    if let Err(error) = run(&mut stage).await {
        let code = developer_code(&error);
        let _ = writeln!(
            io::stdout(),
            "{}",
            json!({"event":"failure","stage":stage,"code":code,"network_hint":network_hint(&error)})
        );
        std::process::exit(1);
    }
}
