//! Explicit, operator-only provisioning command. The outer process supervises
//! the entire Apple exchange; the internal modes are never a production service.
//! Identity JSON is read only from stdin, never from arguments or environment.
//!
//! `--provision-client-supervised <runtime> <state>` is the single operator
//! command. Its stages, each reported by name on failure:
//!   configuration    identity + private client metadata validated offline
//!   state-directory  a fresh 0700 directory claimed atomically
//!   lookup .. persist  the coordinator's exchange (provisioning_client::Stage)
//!   validate         a separate native process confirms the state is
//!                    provisioned and generates an OTP
//!   record           the identity the state belongs to, saved beside it
//! Any failure or cancellation after the claim removes the state directory.
use crate::{process_watchdog, provisioning_client};
#[path = "../../../client_info_config.rs"]
mod client_info_config;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

const MAX_IDENTITY_BYTES: u64 = 4096;
const MAX_STATUS_BYTES: u64 = 512;
const CHILD_MARKER: &str = "ZAG_ADI_WATCHDOG_CHILD";
const VERIFY_DEADLINE: Duration = Duration::from_secs(30);
/// Stage names a coordinator status line may report.
const COORDINATOR_STAGES: [&str; 7] = ["configuration", "lookup", "start-provisioning", "native-start",
    "finish-provisioning", "native-finish", "persist"];
/// Saved beside adi.pb: the device the state was provisioned for.
const IDENTITY_RECORD: &str = "client-identity.json";

#[derive(serde::Serialize)]
struct TestIdentity {
    device_id: String,
    local_user: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    client_info: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    serial: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    user_agent: Option<String>,
}
impl TestIdentity {
    fn client(&self) -> io::Result<provisioning_client::ClientIdentity<'_>> {
        Ok(provisioning_client::ClientIdentity {
            device_id: &self.device_id,
            local_user: &self.local_user,
            client_info: self.client_info.as_deref().ok_or_else(|| invalid("client info not configured"))?,
            serial: self.serial.as_deref(),
            user_agent: self.user_agent.as_deref().ok_or_else(|| invalid("user agent not configured"))?,
        })
    }
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

/// device_id and local_user are required. client_info, serial and
/// user_agent are optional; an empty string means absent, so an identity
/// file with blank placeholders still validates. client_info and user_agent
/// must then come from the private metadata file.
fn read_identity<R: Read>(input: R) -> io::Result<TestIdentity> {
    let mut bytes = Vec::new();
    input.take(MAX_IDENTITY_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.is_empty() || bytes.len() as u64 > MAX_IDENTITY_BYTES {
        return Err(invalid("invalid identity input size"));
    }
    let value: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|_| invalid("invalid identity JSON"))?;
    let object = value.as_object().ok_or_else(|| invalid("identity object required"))?;
    if !object.keys().all(|key|
        matches!(key.as_str(), "device_id" | "client_info" | "local_user" | "serial" | "user_agent"))
    {
        return Err(invalid("identity fields missing or unexpected"));
    }
    let field = |name: &str| -> io::Result<String> {
        object.get(name).and_then(serde_json::Value::as_str)
            .map(str::to_owned).ok_or_else(|| invalid("missing identity string"))
    };
    let optional = |name: &str| -> io::Result<Option<String>> {
        match object.get(name) {
            None => Ok(None),
            Some(serde_json::Value::String(value)) if value.is_empty() => Ok(None),
            Some(serde_json::Value::String(value)) => Ok(Some(value.clone())),
            _ => Err(invalid("invalid optional identity field")),
        }
    };
    Ok(TestIdentity {
        device_id: field("device_id")?,
        local_user: field("local_user")?,
        client_info: optional("client_info")?,
        serial: optional("serial")?,
        user_agent: optional("user_agent")?,
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
    if identity.client_info.as_deref().is_some_and(|existing| existing != configured) {
        return Err(invalid("identity and configured client info disagree"));
    }
    identity.client_info = Some(configured.to_owned());
    let agent = value["user_agent"].as_str().ok_or_else(|| invalid("invalid configured user agent"))?;
    if identity.user_agent.as_deref().is_some_and(|existing| existing != agent) {
        return Err(invalid("identity and configured user agent disagree"));
    }
    identity.user_agent = Some(agent.to_owned());
    Ok(())
}

fn validate_client_derived_identity(identity: &TestIdentity) -> io::Result<()> {
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
        if count == 32 { return Err(invalid("invalid client UUID length")); }
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

/// Complete offline validation shared by the validate modes, the supervisor
/// and the coordinator. Returns the CoreADI Android identifier.
fn validate(identity: &TestIdentity, client_derived: bool, require_metadata: bool) -> io::Result<String> {
    if client_derived { validate_client_derived_identity(identity)?; }
    if require_metadata {
        provisioning_client::validate_identity(&identity.client()?)?;
    } else if identity.local_user.len() != 64 || !identity.local_user.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(invalid("invalid Apple identity headers"));
    }
    provisioning_client::android_identifier(&identity.device_id)
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
    Ok((runtime, state))
}

/// A failed supervised run: the stage name and a reason free of identity
/// values and provisioning material.
#[derive(Debug)]
struct Failure { stage: String, reason: String }
fn fail(stage: &str) -> impl Fn(io::Error) -> Failure + '_ {
    move |error| Failure { stage: stage.to_owned(), reason: provisioning_client::safe_reason(&error) }
}

static CANCELLED: AtomicBool = AtomicBool::new(false);
extern "C" fn on_cancel(_: libc::c_int) { CANCELLED.store(true, Ordering::Release); }
/// Ctrl-C, SIGTERM or a closed terminal stop the run through the normal
/// cleanup path instead of leaving a half-provisioned state directory.
fn install_cancellation() {
    let handler = on_cancel as extern "C" fn(libc::c_int) as libc::sighandler_t;
    unsafe {
        for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] { libc::signal(signal, handler); }
    }
}

/// The children of one supervised run. Deadlines are fields so tests can
/// shorten them; production uses the module constants.
struct Supervision {
    coordinator: Command,
    verifier: Command,
    coordinator_deadline: Duration,
    verify_deadline: Duration,
}

/// Runs a child with piped stdout under the watchdog and returns its exit
/// status plus at most MAX_STATUS_BYTES of its status output.
fn run_child(command: &mut Command, input: &[u8], deadline: Duration, cancel: &AtomicBool)
    -> io::Result<(std::process::ExitStatus, String)>
{
    let mut child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
    let mut pipe = child.stdin.take().ok_or_else(|| invalid("missing child stdin"))?;
    let stdout = child.stdout.take().ok_or_else(|| invalid("missing child stdout"))?;
    let reader = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stdout.take(MAX_STATUS_BYTES).read_to_string(&mut text);
        text
    });
    // A child that exits before reading its input is reported by its status.
    let _ = pipe.write_all(input);
    drop(pipe);
    let status = process_watchdog::wait_cancellable(child, deadline, cancel);
    let text = reader.join().unwrap_or_default();
    Ok((status?, text))
}

/// Claims `state`, runs the coordinator and the verifier, and records the
/// identity. On any failure after the claim, the directory is removed.
fn supervise(state: &Path, identity: &[u8], record: &[u8], mut run: Supervision, cancel: &AtomicBool)
    -> Result<(), Failure>
{
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new().mode(0o700).create(state).map_err(fail("state-directory"))?;
    }
    let result = (|| {
        let (status, output) = run_child(&mut run.coordinator, identity, run.coordinator_deadline, cancel)
            .map_err(|error| if error.kind() == io::ErrorKind::Interrupted { fail("cancelled")(error) }
                             else { fail("coordinator")(error) })?;
        let line = output.lines().next().unwrap_or("");
        if !status.success() || line != "OK" {
            return Err(match line.strip_prefix("FAIL ").and_then(|rest| rest.split_once(' ')) {
                Some((stage, reason)) if COORDINATOR_STAGES.contains(&stage) => Failure {
                    stage: stage.into(),
                    reason: reason.chars().filter(|c| !c.is_control()).take(160).collect(),
                },
                Some(_) => Failure { stage: "coordinator".into(), reason: "invalid status line".into() },
                None => Failure { stage: "coordinator".into(), reason: "exited without a status (signal or crash)".into() },
            });
        }
        // The coordinator verified adi.pb against the worker's result; check
        // once more from here, without following a symlink.
        let artifact = fs::symlink_metadata(state.join("adi.pb"))
            .map_err(|_| fail("persist")(invalid("coordinator succeeded without ADI state file")))?;
        if !artifact.file_type().is_file() || artifact.len() == 0 {
            return Err(fail("persist")(invalid("coordinator produced invalid ADI state file")));
        }
        let (status, output) = run_child(&mut run.verifier, &[], run.verify_deadline, cancel)
            .map_err(|error| if error.kind() == io::ErrorKind::Interrupted { fail("cancelled")(error) }
                             else { fail("validate")(error) })?;
        if !status.success() || !output.starts_with("PASS") {
            return Err(fail("validate")(invalid("native state failed provisioned/OTP verification")));
        }
        {
            use std::os::unix::fs::OpenOptionsExt;
            let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o600)
                .open(state.join(IDENTITY_RECORD)).map_err(fail("record"))?;
            file.write_all(record).and_then(|_| file.sync_all()).map_err(fail("record"))?;
        }
        fs::File::open(state).and_then(|dir| dir.sync_all()).map_err(fail("record"))
    })();
    if result.is_err() {
        // Only this run's directory: it was created above and its parent
        // is private to this user.
        let _ = fs::remove_dir_all(state);
    }
    result
}

/// Return true for a handled isolated mode; other modes remain in main.rs.
pub(crate) fn dispatch() -> Result<bool, Box<dyn std::error::Error>> {
    let mut args = std::env::args_os();
    let _binary = args.next();
    let Some(mode) = args.next() else { return Ok(false); };
    let Some(mode) = mode.to_str().filter(|mode| matches!(*mode,
        "--provision-supervised" | "--coordinator-process"
        | "--validate-identity" | "--validate-client-identity"
        | "--provision-client-supervised" | "--client-coordinator-process"
        | "--metadata-readiness")) else { return Ok(false); };
    let client_derived = mode.contains("client");
    if mode == "--metadata-readiness" {
        if args.next().is_some() {
            return Err(invalid("unexpected metadata readiness arguments").into());
        }
        let Some(path) = std::env::var_os("ZAG_ANISETTE_CLIENT_INFO_FILE") else {
            return Err(invalid("BLOCKED: private client metadata not configured; no credentials required").into());
        };
        client_info_config::read_config(Path::new(&path))
            .map_err(|_| invalid("BLOCKED: private client metadata is missing or invalid; no credentials required"))?;
        println!("PASS: private client metadata is readable and structurally valid (Apple compatibility unverified)");
        return Ok(true);
    }
    if mode.starts_with("--validate-") {
        if args.next().is_some() { return Err(invalid("unexpected identity validation arguments").into()); }
        let mut identity = read_identity(io::stdin().lock())?;
        apply_configured_metadata(&mut identity)?;
        let configured = identity.client_info.is_some() && identity.user_agent.is_some();
        validate(&identity, client_derived, configured)?;
        println!("PASS: {} validated offline{}",
            if client_derived { "client-derived identity" } else { "identity input" },
            if configured { "" } else { " (client metadata not configured: provisioning BLOCKED)" });
        return Ok(true);
    }

    let (runtime, state) = paths(args)?;
    if mode.starts_with("--provision") {
        let result = (|| {
            validate_paths(&runtime, &state).map_err(fail("configuration"))?;
            let mut identity = read_identity(io::stdin().lock()).map_err(fail("configuration"))?;
            apply_configured_metadata(&mut identity).map_err(fail("configuration"))?;
            if std::env::var_os("ZAG_ANISETTE_CLIENT_INFO_FILE").is_none() {
                return Err(fail("configuration")(invalid("private client metadata configuration required")));
            }
            let android_id = validate(&identity, client_derived, true).map_err(fail("configuration"))?;
            let identity_bytes = serde_json::to_vec(&identity)
                .map_err(|_| fail("configuration")(invalid("invalid identity encoding")))?;
            let mut record = serde_json::to_value(&identity)
                .map_err(|_| fail("configuration")(invalid("invalid identity encoding")))?;
            record["android_identifier"] = android_id.clone().into();
            record["ds_id"] = (-2).into();
            let record = serde_json::to_vec_pretty(&record)
                .map_err(|_| fail("configuration")(invalid("invalid identity encoding")))?;
            println!("PASS configuration: identity and client metadata validated offline");

            let binary = std::env::current_exe().and_then(|path| path.canonicalize())
                .map_err(fail("configuration"))?;
            let mut coordinator = Command::new(&binary);
            coordinator.arg(if client_derived { "--client-coordinator-process" } else { "--coordinator-process" })
                .arg(&runtime).arg(&state)
                .env_clear().env(CHILD_MARKER, "1")
                .current_dir("/");
            let mut verifier = Command::new(&binary);
            verifier.arg(&runtime).arg("--native-verify-state").arg(&state).arg(&android_id)
                .env_clear().current_dir("/");
            install_cancellation();
            // The coordinator receives validated identity only through a
            // private pipe. Its environment is cleared; argv holds paths only.
            supervise(&state, &identity_bytes, &record, Supervision {
                coordinator, verifier,
                coordinator_deadline: process_watchdog::HARD_DEADLINE,
                verify_deadline: VERIFY_DEADLINE,
            }, &CANCELLED)
        })();
        match result {
            Ok(()) => {
                println!("PASS provisioning: lookup, start-provisioning, native-start, finish-provisioning, native-finish, persist");
                println!("PASS validate: native state reports provisioned and generated one OTP (contents withheld)");
                println!("PASS record: {IDENTITY_RECORD} saved beside adi.pb (0600)");
                println!("RESULT provisioned state at {}", state.display());
            }
            Err(failure) => {
                eprintln!("FAIL stage={} reason={}", failure.stage, failure.reason);
                if failure.stage != "configuration" && failure.stage != "state-directory" {
                    eprintln!("Claimed state directory removed; nothing was kept.");
                }
                std::process::exit(2);
            }
        }
    } else {
        if std::env::var(CHILD_MARKER).ok().as_deref() != Some("1") {
            return Err(invalid("internal coordinator requires watchdog marker").into());
        }
        // No Apple request is made until a complete, valid identity has been
        // parsed. Report one status line; never echo identity or ADI material.
        let outcome = (|| {
            let identity = read_identity(io::stdin().lock()).map_err(fail("configuration"))?;
            let android_id = validate(&identity, client_derived, true).map_err(fail("configuration"))?;
            let client = identity.client().map_err(fail("configuration"))?;
            let apple = provisioning_client::AppleHttp::new(&client).map_err(fail("configuration"))?;
            let worker = std::env::current_exe().and_then(|path| path.canonicalize())
                .map_err(fail("configuration"))?;
            let command = provisioning_client::WorkerCommand::native(&worker, &runtime, &state, &android_id);
            provisioning_client::provision(&apple, &command, &state, provisioning_client::EXCHANGE_DEADLINE)
                .map_err(|error| Failure { stage: error.stage.name().into(), reason: error.reason })
        })();
        match outcome {
            Ok(()) => println!("OK"),
            Err(failure) => {
                println!("FAIL {} {}", failure.stage, failure.reason);
                std::process::exit(1);
            }
        }
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn private_dir(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "zag-adi-{name}-{}-{:?}", std::process::id(), std::thread::current().id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        root
    }

    #[test]
    fn metadata_file_sets_both_fields_and_rejects_conflicts() {
        let root = private_dir("metadata-contract");
        let path = root.join("metadata.json");
        fs::write(&path, r#"{"client_info":"offline-client","user_agent":"offline-agent/1.0"}"#).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        // Blank placeholders, as in an identity that lacks client metadata.
        let mut identity = read_identity(
            br#"{"device_id":"d","local_user":"l","client_info":"","serial":""}"#.as_slice()).unwrap();
        assert!(identity.client_info.is_none() && identity.serial.is_none());
        apply_metadata_file(&mut identity, &path).unwrap();
        assert_eq!(identity.client_info.as_deref(), Some("offline-client"));
        assert_eq!(identity.user_agent.as_deref(), Some("offline-agent/1.0"));
        let bytes = serde_json::to_vec(&identity).unwrap();
        let parsed = read_identity(bytes.as_slice()).unwrap();
        assert_eq!(parsed.user_agent.as_deref(), Some("offline-agent/1.0"));
        assert!(parsed.serial.is_none());
        identity.user_agent = Some("conflicting-agent".into());
        assert!(apply_metadata_file(&mut identity, &path).is_err());
        identity.user_agent = None;
        identity.client_info = Some("conflicting-client".into());
        assert!(apply_metadata_file(&mut identity, &path).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn identity_json_must_be_complete_and_bounded() {
        assert!(read_identity("{}".as_bytes()).is_err());
        assert!(read_identity("".as_bytes()).is_err());
        assert!(read_identity(vec![b'x'; 4097].as_slice()).is_err());
        assert!(read_identity(br#"{"device_id":"a","local_user":"c","unknown":1}"#.as_slice()).is_err());
        assert!(read_identity(br#"{"device_id":"a","local_user":"c","serial":5}"#.as_slice()).is_err());
        let value = read_identity(br#"{"device_id":"a","local_user":"c"}"#.as_slice()).unwrap();
        assert_eq!(value.device_id, "a");
    }

    #[test]
    fn client_identity_matches_known_vector_and_blocks_without_metadata() {
        let mut identity = TestIdentity {
            device_id: "00010203-0405-0607-0809-0a0b0c0d0e0f".into(),
            local_user: "be45cb2605bf36bebde684841a28f0fd43c69850a3dce5fedba69928ee3a8991".into(),
            client_info: None, serial: None, user_agent: None,
        };
        assert_eq!(validate(&identity, true, false).unwrap(), "00010203-0405-06");
        // Provisioning needs client metadata; it is never invented.
        assert!(validate(&identity, true, true).is_err());
        identity.client_info = Some("offline-client".into());
        identity.user_agent = Some("offline-agent/1.0".into());
        assert!(validate(&identity, true, true).is_ok());
        identity.local_user.replace_range(0..1, "a");
        assert!(validate(&identity, true, true).is_err());
        identity.device_id = "00010203-0405-0607-0809-0a0b0c0d0e0g".into();
        assert!(validate(&identity, true, false).is_err());
        identity.device_id = "00010203-0405-0607-0809-0a0b0c0d0e0f0".into();
        assert!(validate(&identity, true, false).is_err());
    }

    #[test]
    fn provision_paths_reject_relative_existing_and_public_parents() {
        assert!(paths(vec!["/".into(), "/tmp/state".into(), "extra".into()].into_iter()).is_err());
        let root = private_dir("paths");
        assert!(validate_paths(Path::new("relative"), &root.join("state")).is_err());
        assert!(validate_paths(Path::new("/"), &root).is_err());
        assert!(validate_paths(Path::new("/"), &root.join("state")).is_ok());
        fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(validate_paths(Path::new("/"), &root.join("state")).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    // ---- Offline integration of the supervisor ----
    // Shell children stand in for the coordinator and the native verifier,
    // so the claim, status protocol, deadlines, cancellation, cleanup and
    // record run exactly as in production.

    fn sh(script: &str, state: &Path) -> Command {
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script).arg("sh").arg(state);
        command
    }
    const GOOD_COORDINATOR: &str = r#"cat >/dev/null; printf state > "$1/adi.pb"; echo OK"#;
    const GOOD_VERIFIER: &str = "echo 'PASS: verified'";

    fn supervise_with(coordinator: &str, verifier: &str, cancel: bool) -> (Result<(), Failure>, PathBuf) {
        let root = private_dir("supervise");
        let state = root.join("state");
        let flag = AtomicBool::new(cancel);
        let result = supervise(&state, b"{}", b"{\"record\":true}", Supervision {
            coordinator: sh(coordinator, &state), verifier: sh(verifier, &state),
            coordinator_deadline: Duration::from_secs(5), verify_deadline: Duration::from_millis(400),
        }, &flag);
        (result, root)
    }

    #[test]
    fn supervised_run_keeps_only_verified_state_with_its_record() {
        let (result, root) = supervise_with(GOOD_COORDINATOR, GOOD_VERIFIER, false);
        result.unwrap();
        let state = root.join("state");
        assert_eq!(fs::metadata(&state).unwrap().permissions().mode() & 0o777, 0o700);
        let record = state.join(IDENTITY_RECORD);
        assert_eq!(fs::read(&record).unwrap(), b"{\"record\":true}");
        assert_eq!(fs::metadata(&record).unwrap().permissions().mode() & 0o777, 0o600);
        // A second run never reuses or overwrites an existing state.
        let flag = AtomicBool::new(false);
        let again = supervise(&state, b"{}", b"{}", Supervision {
            coordinator: sh(GOOD_COORDINATOR, &state), verifier: sh(GOOD_VERIFIER, &state),
            coordinator_deadline: Duration::from_secs(5), verify_deadline: Duration::from_secs(5),
        }, &flag).unwrap_err();
        assert_eq!(again.stage, "state-directory");
        assert!(state.join("adi.pb").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn supervised_failures_name_the_stage_and_remove_the_claim() {
        let cases = [
            ("echo 'FAIL native-start native worker failed to start'; exit 1", GOOD_VERIFIER, false, "native-start"),
            // A status line cannot smuggle control characters or odd stage names.
            ("printf 'FAIL native-start bad\\033[2J reason\\n'; exit 1", GOOD_VERIFIER, false, "native-start"),
            ("echo 'FAIL invented-stage x'; exit 1", GOOD_VERIFIER, false, "coordinator"),
            ("kill -9 $$", GOOD_VERIFIER, false, "coordinator"),
            ("cat >/dev/null; echo OK", GOOD_VERIFIER, false, "persist"),
            (r#"ln -s /etc/hosts "$1/adi.pb"; echo OK"#, GOOD_VERIFIER, false, "persist"),
            (GOOD_COORDINATOR, "echo 'FAIL'; exit 1", false, "validate"),
            (GOOD_COORDINATOR, "sleep 10", false, "validate"),
            ("sleep 10", GOOD_VERIFIER, true, "cancelled"),
        ];
        for (coordinator, verifier, cancel, stage) in cases {
            let (result, root) = supervise_with(coordinator, verifier, cancel);
            let failure = result.unwrap_err();
            assert_eq!(failure.stage, stage, "{coordinator}: {failure:?}");
            assert!(!failure.reason.chars().any(char::is_control));
            assert!(!root.join("state").exists(), "{coordinator}: claim not removed");
            fs::remove_dir_all(root).unwrap();
        }
    }
}
