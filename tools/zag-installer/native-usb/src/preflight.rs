//! Read-only signed-IPA handoff preflight. The JSON record is NOT an
//! authorization token. The macOS Python validator must independently verify
//! Apple's signing identities and the signed release before constructing it.
//! No operation in this module opens AFC or modifies a device.
use std::{error::Error, path::Path};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt;

const MAX_IPA: u64 = 512 * 1024 * 1024;
const MAX_PLAN: u64 = 4096;

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Prior {
    pub version: String,
    pub build: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreflightPlan {
    pub schema: u8,
    pub ipa_path: String,
    pub ipa_sha256: String,
    pub ipa_bytes: u64,
    pub bundle_identifier: String,
    pub version: String,
    pub build: String,
    pub minimum_os: String,
    pub device_udid: String,
    pub previous: Option<Prior>,
}

fn version_ok(value: &str) -> bool {
    let segments: Vec<&str> = value.split('.').collect();
    !segments.is_empty() && segments.len() <= 4 && segments.iter().all(|s|
        !s.is_empty() && s.len() <= 9 && s.bytes().all(|c| c.is_ascii_digit()))
}

fn udid_ok(value: &str) -> bool {
    (value.len() == 40 && value.bytes().all(|c| c.is_ascii_hexdigit())) ||
    (value.len() == 25 && value.as_bytes()[8] == b'-'
        && value.bytes().enumerate().all(|(i,c)| i == 8 || c.is_ascii_hexdigit()))
}

fn validate(plan: &PreflightPlan) -> Result<(), Box<dyn Error>> {
    match plan.schema {
        1 if crate::installation::is_personal_team_bundle(&plan.bundle_identifier) => (),
        2 if crate::installation::is_imported_bundle(&plan.bundle_identifier) && plan.previous.is_none() => (),
        _ => return Err("Invalid native preflight destination or schema".into()),
    }
    if !udid_ok(&plan.device_udid) { return Err("Invalid target device UDID".into()); }
    if !version_ok(&plan.version) || !version_ok(&plan.build) || !version_ok(&plan.minimum_os) {
        return Err("Invalid candidate version or minimum iOS".into());
    }
    if let Some(prior) = &plan.previous {
        if !version_ok(&prior.version) || !version_ok(&prior.build) {
            return Err("Invalid previous installed version".into());
        }
    }
    if plan.ipa_bytes == 0 || plan.ipa_bytes > MAX_IPA {
        return Err("Invalid signed IPA length".into());
    }
    if plan.ipa_sha256.len() != 64 || !plan.ipa_sha256.bytes().all(|c|
        c.is_ascii_digit() || (b'a'..=b'f').contains(&c)) {
        return Err("Invalid signed IPA checksum".into());
    }
    let path = Path::new(&plan.ipa_path);
    if !path.is_absolute() || path.extension().and_then(|x|x.to_str()) != Some("ipa") {
        return Err("IPA must be an absolute .ipa file".into());
    }
    Ok(())
}

/// Load a small strict JSON intent, then independently rehash the local
/// candidate. Its content is *not* proof of signed release authorization.
pub async fn verify(path: &Path) -> Result<PreflightPlan, Box<dyn Error>> {
    let meta = tokio::fs::symlink_metadata(path).await?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > MAX_PLAN {
        return Err("Malformed native preflight file".into());
    }
    let data = tokio::fs::read(path).await?;
    let plan: PreflightPlan = serde_json::from_slice(&data)?;
    validate(&plan)?;
    let ipa = Path::new(&plan.ipa_path);
    let info = tokio::fs::symlink_metadata(ipa).await?;
    if !info.is_file() || info.len() != plan.ipa_bytes {
        return Err("Signed IPA file is missing, changed, or is not regular".into());
    }
    let mut input = tokio::fs::File::open(ipa).await?;
    let mut hash = Sha256::new();
    let mut buffer = vec![0u8; 256 * 1024];
    loop {
        let count = input.read(&mut buffer).await?;
        if count == 0 { break; }
        hash.update(&buffer[..count]);
    }
    let found = format!("{:x}", hash.finalize());
    if found != plan.ipa_sha256 {
        return Err("Signed IPA digest differs from the validated intent".into());
    }
    Ok(plan)
}

pub fn device_binding(plan: &PreflightPlan, status: &Value) -> Result<Value, Box<dyn Error>> {
    if status.get("transport").and_then(Value::as_str) != Some("system-usbmuxd")
        || status.get("trust_verified").and_then(Value::as_bool) != Some(true)
        || status.get("developer_mode").and_then(Value::as_bool) != Some(true) {
        return Err("Trusted developer-mode iPhone is unavailable".into());
    }
    let udid = status.get("udid").and_then(Value::as_str).ok_or("Missing USB identity")?;
    if udid.to_ascii_lowercase() != plan.device_udid.to_ascii_lowercase() {
        return Err("Signed IPA plan targets a different iPhone".into());
    }
    let os = status.get("device").and_then(|v|v.get("ProductVersion"))
        .and_then(Value::as_str).ok_or("Missing iOS version")?;
    if !version_ok(os) { return Err("Unsupported iOS version format".into()); }
    fn parts(value: &str) -> [u64;4] {
        let mut out = [0;4];
        for (i, p) in value.split('.').enumerate() {
            out[i] = p.parse().unwrap_or(0);
        }
        out
    }
    if parts(os) < parts(&plan.minimum_os) {
        return Err("Connected iPhone is below the signed IPA minimum iOS".into());
    }
    Ok(json!({
        "preflight":"validated_local_digest_and_device",
        "writes_performed":false,
        "installation_authorized":false,
        "bundleIdentifier":plan.bundle_identifier,
        "version":plan.version,
        "build":plan.build,
        "sha256":plan.ipa_sha256,
        "operation":if plan.previous.is_some() {"upgrade"} else {"fresh_install"},
        "destination_state":"unconfirmed",
        "warning":"This report is not Apple signature verification and cannot authorize installation"
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn plan() -> PreflightPlan {
        PreflightPlan {
            schema:1,
            ipa_path:"/tmp/signed.ipa".into(),
            ipa_sha256:"0".repeat(64),
            ipa_bytes:256,
            bundle_identifier:"app.zagstore.ios.FTB8PRW638".into(),
            version:"1.0.0".into(), build:"5".into(),
            minimum_os:"16.4".into(),
            device_udid:"00000000-0000000000000000".into(),
            previous:None
        }
    }
    #[test]
    fn forged_bundle_wrong_device_and_bad_checksum_rejected() {
        let mut req = plan();
        assert!(validate(&req).is_ok());
        req.bundle_identifier = "com.cwd43.gu29".into();
        assert!(validate(&req).is_err());
        req = plan();
        req.device_udid = "wrong".into();
        assert!(validate(&req).is_err());
        req = plan();
        req.ipa_sha256 = "g".repeat(64);
        assert!(validate(&req).is_err());
        req = plan();
        req.ipa_bytes = 0;
        assert!(validate(&req).is_err());
    }
    #[test]
    fn imported_plan_requires_distinct_schema_and_fresh_install() {
        let mut req = plan();
        req.bundle_identifier = "app.zloader.imported.0123456789abcdef0123456789abcdef.FTB8PRW638".into();
        assert!(validate(&req).is_err());
        req.schema = 2;
        assert!(validate(&req).is_ok());
        req.previous = Some(Prior {version:"1.0.0".into(), build:"1".into()});
        assert!(validate(&req).is_err());
        req.previous = None;
        req.bundle_identifier = "app.zagstore.ios.FTB8PRW638".into();
        assert!(validate(&req).is_err());
    }
    #[test]
    fn unknown_json_fields_fail_closed() {
        let value = json!({
            "schema":1,"ipa_path":"/tmp/signed.ipa","ipa_sha256":"0".repeat(64),
            "ipa_bytes":256,"bundle_identifier":"app.zagstore.ios.FTB8PRW638",
            "version":"1.0.0","build":"5","minimum_os":"16.4",
            "device_udid":"00000000-0000000000000000","previous":null,
            "install_now":true
        });
        assert!(serde_json::from_value::<PreflightPlan>(value).is_err());
    }
    #[test]
    fn preflight_binds_exact_wired_device_without_writes() {
        let request = plan();
        let valid = json!({
            "transport":"system-usbmuxd","trust_verified":true,
            "developer_mode":true,"udid":"00000000-0000000000000000",
            "device":{"ProductVersion":"27.2.1"}
        });
        let output = device_binding(&request,&valid).unwrap();
        assert_eq!(output["writes_performed"],false);
        assert_eq!(output["installation_authorized"],false);
        let mut changed = valid.clone();
        changed["udid"] = json!("11111111-1111111111111111");
        assert!(device_binding(&request,&changed).is_err());
        let mut old_os = valid;
        old_os["device"]["ProductVersion"] = json!("15.7");
        assert!(device_binding(&request,&old_os).is_err());
    }
}
