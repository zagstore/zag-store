//! Explicit, operator-only coordinator launcher. The outer process supervises
//! the entire Apple exchange; the internal mode is never a production service.
//! Identity JSON is read only from stdin, never from arguments or environment.
use crate::{process_watchdog, provisioning_client};
#[path = "../../../client_info_config.rs"]
mod client_info_config;
use std::ffi::OsStr;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const MAX_IDENTITY_BYTES: u64 = 4096;
const CHILD_MARKER: &str = "ZAG_ADI_WATCHDOG_CHILD";

#[derive(serde::Serialize)]
struct TestIdentity {
    device_id: String,
    client_info: String,
    local_user: String,
    serial: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    user_agent: Option<String>,
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

fn read_identity<R: Read>(input: R) -> io::Result<TestIdentity> {
    let mut bytes = Vec::new();
    input.take(MAX_IDENTITY_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.is_empty() || bytes.len() as u64 > MAX_IDENTITY_BYTES {
        return Err(invalid("invalid identity input size"));
    }
    let value: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|_| invalid("invalid identity JSON"))?;
    let object = value.as_object().ok_or_else(|| invalid("identity object required"))?;
    if !(object.len() == 4 || object.len() == 5) || !object.keys().all(|key|
        matches!(key.as_str(), "device_id" | "client_info" | "local_user" | "serial" | "user_agent"))
    {
        return Err(invalid("identity fields missing or unexpected"));
    }
    let field = |name: &str| -> io::Result<String> {
        object.get(name).and_then(serde_json::Value::as_str)
            .map(str::to_owned).ok_or_else(|| invalid("missing identity string"))
    };
    Ok(TestIdentity {
        device_id: field("device_id")?,
        client_info: field("client_info")?,
        local_user: field("local_user")?,
        serial: field("serial")?,
        user_agent: match object.get("user_agent") {
            None => None,
            Some(serde_json::Value::String(value)) => Some(value.clone()),
            _ => return Err(invalid("invalid user agent field")),
        },
    })
}

// Client-generated identity: UUID is the exact 16-byte keychain identifier;
// MD-LU is the SHA-256 digest of those bytes (not of the UUID text).
// This check is opt-in: other legitimate identity providers may differ.
// The HTTP service and supervised launcher use exactly the same private
// configuration parser. Never synthesize or silently override an identity.
fn apply_configured_metadata(identity: &mut TestIdentity) -> io::Result<()> {
    let Some(path) = std::env::var_os("ZAG_ANISETTE_CLIENT_INFO_FILE") else {
        return Ok(());
    };
    apply_metadata_file(identity, Path::new(&path))
}

fn apply_metadata_file(identity: &mut TestIdentity, path: &Path) -> io::Result<()> {
    let metadata = client_info_config::read_config(path)?;
    let value: serde_json::Value = serde_json::from_str(&metadata)?;
    let configured = value["client_info"].as_str().ok_or_else(|| invalid("invalid configured client info"))?;
    if !identity.client_info.is_empty() && identity.client_info != configured {
        return Err(invalid("identity and configured client info disagree"));
    }
    identity.client_info = configured.to_owned();
    let agent = value["user_agent"].as_str().ok_or_else(|| invalid("invalid configured user agent"))?;
    if identity.user_agent.as_deref().is_some_and(|existing| existing != agent) {
        return Err(invalid("identity and configured user agent disagree"));
    }
    identity.user_agent = Some(agent.to_owned());
    Ok(())
}

fn validate_client_derived_identity(identity: &TestIdentity) -> io::Result<()> {
    provisioning_client::validate_identity(
        &identity.device_id, &identity.client_info,
        &identity.local_user, &identity.serial,
    )?;
    let id = identity.device_id.as_bytes();
    if id.len() != 36 || ![8, 13, 18, 23].iter().all(|&i| id[i] == b'-') {
        return Err(invalid("client identity requires canonical UUID"));
    }
    let mut raw = [0u8; 16];
    let mut nibbles = [0u8; 32];
    let mut count = 0;
    for &c in id {
        if c == b'-' { continue; }
        let digit = match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            _ => return Err(invalid("client identity requires lowercase UUID hex")),
        };
        nibbles[count] = digit;
        count += 1;
    }
    if count != 32 { return Err(invalid("invalid client UUID length")); }
    for i in 0..16 { raw[i] = (nibbles[2*i] << 4) | nibbles[2*i+1]; }
    let digest = Sha256::digest(raw);
    let expected: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    if !identity.local_user.eq_ignore_ascii_case(&expected) {
        return Err(invalid("client identity UUID and MD-LU mismatch"));
    }
    Ok(())
}

fn validate_paths(runtime: &Path, state: &Path) -> io::Result<()> {
    if !runtime.is_absolute() || !runtime.is_dir() || !state.is_absolute() {
        return Err(invalid("absolute runtime and fresh state paths required"));
    }
    if state.exists() || fs::symlink_metadata(state).is_ok() {
        return Err(invalid("state path must not exist"));
    }
    let parent = state.parent().ok_or_else(|| invalid("invalid state parent"))?;
    let metadata = fs::symlink_metadata(parent)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(invalid("private state parent must be a directory"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if metadata.uid() != unsafe { libc::geteuid() } ||
           metadata.permissions().mode() & 0o077 != 0 {
            return Err(invalid("state parent must be owned by current user and mode 0700"));
        }
    }
    Ok(())
}

fn paths<I: Iterator<Item = std::ffi::OsString>>(mut args: I) -> io::Result<(PathBuf, PathBuf)> {
    let runtime = PathBuf::from(args.next().ok_or_else(|| invalid("missing runtime root"))?);
    let state = PathBuf::from(args.next().ok_or_else(|| invalid("missing private state path"))?);
    if args.next().is_some() { return Err(invalid("unexpected provision arguments")); }
    validate_paths(&runtime, &state)?;
    Ok((runtime, state))
}

/// Return true for a handled isolated mode; other modes remain in main.rs.
pub(crate) fn dispatch() -> Result<bool, Box<dyn std::error::Error>> {
    let mut args = std::env::args_os();
    let _binary = args.next();
    let Some(mode) = args.next() else { return Ok(false); };
    if mode != OsStr::new("--provision-supervised")
        && mode != OsStr::new("--coordinator-process")
        && mode != OsStr::new("--validate-identity")
        && mode != OsStr::new("--validate-client-identity")
        && mode != OsStr::new("--provision-client-supervised")
        && mode != OsStr::new("--client-coordinator-process")
        && mode != OsStr::new("--metadata-readiness") { return Ok(false); }
    if mode == OsStr::new("--metadata-readiness") {
        if args.next().is_some() {
            return Err(invalid("unexpected metadata readiness arguments").into());
        }
        let Some(path) = std::env::var_os("ZAG_ANISETTE_CLIENT_INFO_FILE") else {
            println!("BLOCKED: private client metadata not configured; no credentials required");
            return Ok(true);
        };
        match client_info_config::read_config(Path::new(&path)) {
            Ok(_) => println!("PASS: private client metadata is readable and structurally valid (Apple compatibility unverified)"),
            Err(_) => println!("BLOCKED: private client metadata is missing or invalid; no credentials required"),
        }
        return Ok(true);
    }
    if mode == OsStr::new("--validate-identity") || mode == OsStr::new("--validate-client-identity") {
        if args.next().is_some() { return Err(invalid("unexpected identity validation arguments").into()); }
        let mut identity = read_identity(io::stdin().lock())?;
        apply_configured_metadata(&mut identity)?;
        if mode == OsStr::new("--validate-client-identity") {
            validate_client_derived_identity(&identity)?;
            println!("PASS: client-derived identity validated offline");
        } else {
            provisioning_client::validate_identity(
                &identity.device_id, &identity.client_info,
                &identity.local_user, &identity.serial,
            )?;
            println!("PASS: identity input validated offline");
        }
        return Ok(true);
    }

    let (runtime, state) = paths(args)?;
    if mode == OsStr::new("--provision-supervised") || mode == OsStr::new("--provision-client-supervised") {
        let binary = std::env::current_exe()?.canonicalize()?;
        let mut identity = read_identity(io::stdin().lock())?;
        apply_configured_metadata(&mut identity)?;
        if mode == OsStr::new("--provision-client-supervised") {
            validate_client_derived_identity(&identity)?;
        } else {
            provisioning_client::validate_identity(&identity.device_id, &identity.client_info, &identity.local_user, &identity.serial)?;
        }
        if std::env::var_os("ZAG_ANISETTE_CLIENT_INFO_FILE").is_none() || identity.user_agent.is_none() {
            return Err(invalid("supervised provisioning requires private client metadata configuration").into());
        }
        let identity_bytes = serde_json::to_vec(&identity).map_err(|_| invalid("invalid identity encoding"))?;
        let mut cmd = Command::new(binary);
        cmd.arg(if mode == OsStr::new("--provision-client-supervised") {
                "--client-coordinator-process"
            } else {
                "--coordinator-process"
            })
            .arg(&runtime).arg(&state)
            .env_clear().env(CHILD_MARKER, "1")
            .current_dir("/")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // The coordinator receives validated identity only through a private pipe.
        // Its environment remains cleared and no metadata enters argv.
        let mut child = cmd.spawn()?;
        let mut pipe = child.stdin.take().ok_or_else(|| invalid("missing coordinator stdin"))?;
        let write_result = pipe.write_all(&identity_bytes);
        drop(pipe);
        if let Err(error) = write_result {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error.into());
        }
        let status = process_watchdog::wait_bounded(child, process_watchdog::HARD_DEADLINE)?;
        if !status.success() {
            return Err(invalid("isolated coordinator failed (check that complete identity JSON was supplied on stdin)").into());
        }
        // The native bridge writes adi.pb itself. Confirm that this invocation
        // produced a regular, non-symlink file before reporting success.
        let artifact = state.join("adi.pb");
        let metadata = fs::symlink_metadata(&artifact)
            .map_err(|_| invalid("coordinator succeeded without ADI state file"))?;
        if !metadata.file_type().is_file() || metadata.len() == 0 {
            return Err(invalid("coordinator produced invalid ADI state file").into());
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&artifact, fs::Permissions::from_mode(0o600))?;
        }
        println!("PASS: supervised isolated ADI state generated and secured");
    } else {
        if std::env::var(CHILD_MARKER).ok().as_deref() != Some("1") {
            return Err(invalid("internal coordinator requires watchdog marker").into());
        }
        // No Apple request is made until a complete, valid operator-supplied
        // identity has been parsed. Never echo the identity or ADI material.
        let identity = read_identity(io::stdin().lock())?;
        let user_agent = identity.user_agent.as_deref().ok_or_else(|| invalid("coordinator requires configured user agent"))?;
        if mode == OsStr::new("--client-coordinator-process") {
            validate_client_derived_identity(&identity)?;
        }
        let worker = std::env::current_exe()?.canonicalize()?;
        let _adi = provisioning_client::provision_with_worker(
            &worker, &runtime, &state,
            &identity.device_id, &identity.client_info,
            &identity.local_user, &identity.serial, user_agent,
        )?;
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn metadata_file_sets_both_fields_and_rejects_conflicts() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!(
            "zag-adi-metadata-contract-{}-{:?}", std::process::id(), std::thread::current().id()
        ));
        fs::create_dir(&root).unwrap();
        let path = root.join("metadata.json");
        fs::write(&path, r#"{"client_info":"offline-client","user_agent":"offline-agent/1.0"}"#).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let mut identity = TestIdentity {
            device_id: "device".into(), local_user: "a".repeat(64),
            client_info: String::new(), serial: "TEST-123".into(), user_agent: None,
        };
        apply_metadata_file(&mut identity, &path).unwrap();
        assert_eq!(identity.client_info, "offline-client");
        assert_eq!(identity.user_agent.as_deref(), Some("offline-agent/1.0"));
        let bytes = serde_json::to_vec(&identity).unwrap();
        let parsed = read_identity(bytes.as_slice()).unwrap();
        assert_eq!(parsed.user_agent.as_deref(), Some("offline-agent/1.0"));
        identity.user_agent = Some("conflicting-agent".into());
        assert!(apply_metadata_file(&mut identity, &path).is_err());
        identity.user_agent = None;
        identity.client_info = "conflicting-client".into();
        assert!(apply_metadata_file(&mut identity, &path).is_err());
        fs::remove_file(path).unwrap();
        fs::remove_dir(root).unwrap();
    }

    #[test]
    fn identity_json_must_be_complete_and_bounded() {
        assert!(read_identity("{}".as_bytes()).is_err());
        assert!(read_identity("".as_bytes()).is_err());
        assert!(read_identity(vec![b'x'; 4097].as_slice()).is_err());
        assert!(read_identity(br#"{"device_id":"a","client_info":"b","local_user":"c","serial":"d","unknown":1}"#.as_slice()).is_err());
        let valid = br#"{"device_id":"a","client_info":"b","local_user":"c","serial":"d"}"#;
        let value = read_identity(valid.as_slice()).unwrap();
        assert_eq!(value.device_id, "a");
    }

    #[test]
    fn provision_path_args_reject_relative_and_extra() {
        let p = vec!["relative".into(), "/nonexistent-state".into()].into_iter();
        assert!(paths(p).is_err());
        let p = vec!["/".into(), "/tmp/state".into(), "extra".into()].into_iter();
        assert!(paths(p).is_err());
    }
    #[test]
    fn client_identity_matches_known_vector_and_rejects_mismatch() {
        let mut identity = TestIdentity {
            device_id: "00010203-0405-0607-0809-0a0b0c0d0e0f".into(),
            local_user: "be45cb2605bf36bebde684841a28f0fd43c69850a3dce5fedba69928ee3a8991".into(),
            client_info: "offline-test".into(),
            serial: "TEST-123".into(),
            user_agent: None,
        };
        assert!(validate_client_derived_identity(&identity).is_ok());
        identity.local_user.replace_range(0..1, "a");
        assert!(validate_client_derived_identity(&identity).is_err());
        identity.device_id = "00010203-0405-0607-0809-0a0b0c0d0e0g".into();
        assert!(validate_client_derived_identity(&identity).is_err());
    }

}
