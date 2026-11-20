//! Explicit, operator-only coordinator launcher. The outer process supervises
//! the entire Apple exchange; the internal mode is never a production service.
//! Identity JSON is read only from stdin, never from arguments or environment.
use crate::{process_watchdog, provisioning_client};
use std::ffi::OsStr;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const MAX_IDENTITY_BYTES: u64 = 4096;
const CHILD_MARKER: &str = "ZAG_ADI_WATCHDOG_CHILD";

struct TestIdentity {
    device_id: String,
    client_info: String,
    local_user: String,
    serial: String,
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
    if object.len() != 4 || !object.keys().all(|key|
        matches!(key.as_str(), "device_id" | "client_info" | "local_user" | "serial"))
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
    })
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
        && mode != OsStr::new("--coordinator-process") { return Ok(false); }

    let (runtime, state) = paths(args)?;
    if mode == OsStr::new("--provision-supervised") {
        let binary = std::env::current_exe()?.canonicalize()?;
        let mut cmd = Command::new(binary);
        cmd.arg("--coordinator-process")
            .arg(runtime).arg(state)
            .env_clear().env(CHILD_MARKER, "1")
            .current_dir("/")
            .stdin(Stdio::inherit())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let status = process_watchdog::run_bounded(&mut cmd, process_watchdog::HARD_DEADLINE)?;
        if !status.success() {
            return Err(invalid("isolated coordinator failed (check that complete identity JSON was supplied on stdin)").into());
        }
        println!("PASS: supervised isolated ADI state generated");
    } else {
        if std::env::var(CHILD_MARKER).ok().as_deref() != Some("1") {
            return Err(invalid("internal coordinator requires watchdog marker").into());
        }
        // No Apple request is made until a complete, valid operator-supplied
        // identity has been parsed. Never echo the identity or ADI material.
        let identity = read_identity(io::stdin().lock())?;
        let worker = std::env::current_exe()?.canonicalize()?;
        let _adi = provisioning_client::provision_with_worker(
            &worker, &runtime, &state,
            &identity.device_id, &identity.client_info,
            &identity.local_user, &identity.serial,
        )?;
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
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
}
