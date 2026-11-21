//! Explicit, operator-only provisioning command. The outer process supervises
//! the entire Apple exchange; the internal modes are never a production service.
//! Identity JSON is read only from stdin, never from arguments or environment.
//!
//! `--provision-client-supervised <runtime> <state>` is the single operator
//! command. Its stages, each reported by name on failure:
//!   configuration    identity + private client metadata validated offline
//!   state-directory  a fresh 0700 attempt directory claimed atomically
//!   lookup .. persist  the coordinator's exchange (provisioning_client::Stage)
//!   validate         a separate native process confirms a copy of exactly
//!                    this attempt's adi.pb is provisioned and generates an OTP
//!   record           the identity the state belongs to, saved beside it
//!   publish          atomic, no-replace rename to the final name
//! Any failure or cancellation removes the attempt's directories; the final
//! name only ever holds a complete, verified state (see `supervise`).
use crate::{process_watchdog, provisioning_client};
#[path = "../../../client_info_config.rs"]
mod client_info_config;
use sha2::{Digest, Sha256};
use std::ffi::OsStr;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

const MAX_IDENTITY_BYTES: u64 = 4096;
const MAX_STATUS_BYTES: u64 = 512;
const MAX_STATE_BYTES: u64 = 64 * 1024;
const CHILD_MARKER: &str = "ZAG_ADI_WATCHDOG_CHILD";
const VERIFY_DEADLINE: Duration = Duration::from_secs(30);
/// Stage names a coordinator status line may report.
const COORDINATOR_STAGES: [&str; 7] = ["configuration", "lookup", "start-provisioning", "native-start",
    "finish-provisioning", "native-finish", "persist"];
/// The verifier's complete stdout on success (main.rs --native-verify-state).
pub(crate) const VERIFIED_LINE: &str = "PASS: native state reports provisioned and generated one OTP (contents withheld)";
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
    if !state.components().all(|c| matches!(c, std::path::Component::RootDir | std::path::Component::Normal(_))) {
        return Err(invalid("state path must not contain . or .. components"));
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

/// Where one attempt works before it is published under the final name:
/// hidden siblings named after it. A leftover from a supervisor killed
/// outright is recognisably incomplete and blocks a rerun until removed.
fn attempt_paths(state: &Path) -> io::Result<(PathBuf, PathBuf)> {
    let parent = state.parent().ok_or_else(|| invalid("invalid state parent"))?;
    let name = state.file_name().and_then(OsStr::to_str).ok_or_else(|| invalid("invalid state name"))?;
    Ok((parent.join(format!(".{name}.incomplete")), parent.join(format!(".{name}.verify"))))
}

/// A directory this run created. Dropping it removes it, but only while
/// the path still names that same directory (device and inode), so a
/// directory or symlink put in its place is never removed or followed.
struct Claim { path: PathBuf, dev: u64, ino: u64, keep: bool }
impl Claim {
    fn create(path: &Path) -> io::Result<Self> {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt};
        fs::DirBuilder::new().mode(0o700).create(path)?;
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o777 != 0o700 {
            return Err(invalid("claimed directory is not private"));
        }
        Ok(Self { path: path.to_owned(), dev: metadata.dev(), ino: metadata.ino(), keep: false })
    }
    fn intact(&self) -> bool {
        use std::os::unix::fs::MetadataExt;
        fs::symlink_metadata(&self.path)
            .is_ok_and(|m| m.is_dir() && m.dev() == self.dev && m.ino() == self.ino)
    }
}
impl Drop for Claim {
    fn drop(&mut self) {
        if !self.keep && self.intact() { let _ = fs::remove_dir_all(&self.path); }
    }
}

/// adi.pb read without following a symlink: regular, non-empty, bounded.
/// Made owner-only through the same descriptor, whoever created it.
fn read_state(path: &Path) -> io::Result<Vec<u8>> {
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::fs::OpenOptionsExt;
    let file = fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)
        .map_err(|_| invalid("ADI state file missing or not a regular file"))?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_STATE_BYTES {
        return Err(invalid("invalid ADI state file"));
    }
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    let mut bytes = Vec::new();
    file.take(MAX_STATE_BYTES + 1).read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// Renames `from` to `to`, failing if `to` exists. On Linux this is atomic
/// (RENAME_NOREPLACE); elsewhere (test hosts only) it is check-then-rename
/// inside the operator's private parent.
fn rename_no_replace(from: &Path, to: &Path) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::ffi::OsStrExt;
        let from = std::ffi::CString::new(from.as_os_str().as_bytes())?;
        let to = std::ffi::CString::new(to.as_os_str().as_bytes())?;
        if unsafe { libc::renameat2(libc::AT_FDCWD, from.as_ptr(), libc::AT_FDCWD, to.as_ptr(), libc::RENAME_NOREPLACE) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        if fs::symlink_metadata(to).is_ok() {
            return Err(io::Error::new(io::ErrorKind::AlreadyExists, "state path already exists"));
        }
        fs::rename(from, to)
    }
}

/// The children of one supervised run, built for attempt_paths(state).
/// Deadlines are fields so tests can shorten them.
struct Supervision {
    coordinator: Command,
    verifier: Command,
    coordinator_deadline: Duration,
    verify_deadline: Duration,
}

/// Runs a child as its own supervised process group and returns its exit
/// status plus at most MAX_STATUS_BYTES of its output. Input is written
/// and output read on helper threads, so a child that never reads its
/// stdin, or a descendant holding its stdout, cannot stall supervision;
/// when the watchdog returns, the whole group is dead.
fn run_child(command: &mut Command, input: Vec<u8>, deadline: Duration, cancel: &AtomicBool)
    -> io::Result<(std::process::ExitStatus, Vec<u8>)>
{
    let mut child = process_watchdog::supervised(
        command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null())).spawn()?;
    let mut stdin = child.stdin.take().ok_or_else(|| invalid("missing child stdin"))?;
    let stdout = child.stdout.take().ok_or_else(|| invalid("missing child stdout"))?;
    // A child that exits before reading its input is reported by its status.
    std::thread::spawn(move || { let _ = stdin.write_all(&input); });
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut output = Vec::new();
        let _ = stdout.take(MAX_STATUS_BYTES).read_to_end(&mut output);
        let _ = sender.send(output);
    });
    let status = process_watchdog::wait_cancellable(child, deadline, cancel)?;
    // Only a process that escaped the group could still hold the pipe.
    let output = receiver.recv_timeout(Duration::from_secs(2))
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "child output did not close"))?;
    Ok((status, output))
}

fn child_error(stage: &str) -> impl Fn(io::Error) -> Failure + '_ {
    move |error| if error.kind() == io::ErrorKind::Interrupted { fail("cancelled")(error) } else { fail(stage)(error) }
}

/// The coordinator's result: exit 0 and exactly `OK <sha256 of adi.pb>`.
/// Anything else is a failure, named by a valid `FAIL <stage> <reason>`
/// line or attributed to the coordinator.
fn coordinator_result(status: std::process::ExitStatus, output: &[u8]) -> Result<String, Failure> {
    let text = std::str::from_utf8(output).unwrap_or("");
    let digest = text.strip_prefix("OK ").and_then(|rest| rest.strip_suffix('\n'))
        .filter(|d| d.len() == 64 && d.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
    match digest {
        Some(digest) if status.success() => return Ok(digest.to_owned()),
        _ => {}
    }
    let line = text.lines().next().unwrap_or("");
    Err(match line.strip_prefix("FAIL ").and_then(|rest| rest.split_once(' ')) {
        Some((stage, reason)) if !status.success() && COORDINATOR_STAGES.contains(&stage) => Failure {
            stage: stage.into(),
            reason: reason.chars().filter(|c| !c.is_control()).take(160).collect(),
        },
        Some(_) => Failure { stage: "coordinator".into(), reason: "invalid status line".into() },
        None => Failure { stage: "coordinator".into(), reason: "exited without a valid status (signal or crash)".into() },
    })
}

/// One supervised attempt for the final path `state`:
///  1. claim `.state.incomplete` (0700, must not exist);
///  2. coordinator provisions into it and reports the adi.pb digest;
///  3. the file there must have that digest;
///  4. a copy of exactly those bytes, alone in a claimed `.state.verify`,
///     must pass the native verifier (provisioned + one OTP);
///  5. the kept file must still have the digest; the identity record is
///     written and everything fsynced;
///  6. `.state.incomplete` is renamed to `state` without replacing anything.
/// The final name therefore only ever holds a complete, verified state.
/// Every failure, timeout or cancellation removes both claims.
fn supervise(state: &Path, identity: Vec<u8>, mut record: serde_json::Value, mut run: Supervision, cancel: &AtomicBool)
    -> Result<(), Failure>
{
    let (staging_path, verify_path) = attempt_paths(state).map_err(fail("configuration"))?;
    let mut staging = Claim::create(&staging_path).map_err(fail("state-directory"))?;
    let (status, output) = run_child(&mut run.coordinator, identity, run.coordinator_deadline, cancel)
        .map_err(child_error("coordinator"))?;
    let digest = coordinator_result(status, &output)?;
    let adi_pb = read_state(&staging_path.join("adi.pb")).map_err(fail("persist"))?;
    if provisioning_client::sha256_hex(&adi_pb) != digest {
        return Err(fail("persist")(invalid("ADI state file differs from the coordinator's result")));
    }
    {
        let verify = Claim::create(&verify_path).map_err(fail("validate"))?;
        write_private(&verify.path.join("adi.pb"), &adi_pb).map_err(fail("validate"))?;
        let (status, output) = run_child(&mut run.verifier, Vec::new(), run.verify_deadline, cancel)
            .map_err(child_error("validate"))?;
        if !status.success() || output != format!("{VERIFIED_LINE}\n").as_bytes() {
            return Err(fail("validate")(invalid("native state failed provisioned/OTP verification")));
        }
    }
    let kept = read_state(&staging_path.join("adi.pb")).map_err(fail("persist"))?;
    if kept != adi_pb {
        return Err(fail("persist")(invalid("ADI state file changed during verification")));
    }
    record["adi_pb_sha256"] = digest.into();
    let record = serde_json::to_vec_pretty(&record).map_err(|_| fail("record")(invalid("invalid record encoding")))?;
    write_private(&staging_path.join(IDENTITY_RECORD), &record).map_err(fail("record"))?;
    fs::File::open(&staging_path).and_then(|dir| dir.sync_all()).map_err(fail("record"))?;
    if cancel.load(Ordering::Acquire) {
        return Err(fail("cancelled")(io::Error::new(io::ErrorKind::Interrupted, "cancelled by operator")));
    }
    if !staging.intact() {
        return Err(fail("publish")(invalid("claimed directory was replaced")));
    }
    rename_no_replace(&staging_path, state).map_err(fail("publish"))?;
    staging.keep = true;
    let parent = state.parent().ok_or_else(|| fail("publish")(invalid("invalid state parent")))?;
    fs::File::open(parent).and_then(|dir| dir.sync_all()).map_err(fail("publish"))?;
    Ok(())
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
            println!("PASS configuration: identity and client metadata validated offline");

            let (staging, verify) = attempt_paths(&state).map_err(fail("configuration"))?;
            let binary = std::env::current_exe().and_then(|path| path.canonicalize())
                .map_err(fail("configuration"))?;
            let mut coordinator = Command::new(&binary);
            coordinator.arg(if client_derived { "--client-coordinator-process" } else { "--coordinator-process" })
                .arg(&runtime).arg(&staging)
                .env_clear().env(CHILD_MARKER, "1")
                .current_dir("/");
            let mut verifier = Command::new(&binary);
            verifier.arg(&runtime).arg("--native-verify-state").arg(&verify).arg(&android_id)
                .env_clear().current_dir("/");
            // Every file CoreADI or this run creates is owner-only.
            unsafe { libc::umask(0o077); }
            install_cancellation();
            // The coordinator receives validated identity only through a
            // private pipe. Its environment is cleared; argv holds paths only.
            supervise(&state, identity_bytes, record, Supervision {
                coordinator, verifier,
                coordinator_deadline: process_watchdog::HARD_DEADLINE,
                verify_deadline: VERIFY_DEADLINE,
            }, &CANCELLED)
        })();
        match result {
            Ok(()) => {
                println!("PASS provisioning: lookup, start-provisioning, native-start, finish-provisioning, native-finish, persist");
                println!("PASS validate: a copy of this attempt's adi.pb reports provisioned and generated one OTP (contents withheld)");
                println!("PASS record: {IDENTITY_RECORD} saved beside adi.pb (0600)");
                println!("PASS publish: state moved to its final name only after verification");
                println!("RESULT provisioned state at {}", state.display());
            }
            Err(failure) => {
                eprintln!("FAIL stage={} reason={}", failure.stage, failure.reason);
                if failure.stage != "configuration" && failure.stage != "state-directory" {
                    eprintln!("This attempt's directories were removed; nothing was kept.");
                } else if failure.stage == "state-directory" {
                    eprintln!("An earlier attempt's .incomplete directory may remain; remove it after inspection.");
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
            Ok(digest) => println!("OK {digest}"),
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
    // Shell children stand in for the coordinator ($1 = attempt directory)
    // and the native verifier ($2 = verification copy), so the claims,
    // status protocol, process groups, deadlines, cancellation, cleanup,
    // record and publication run exactly as in production.

    fn sh(script: &str, args: &[&Path]) -> Command {
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script).arg("sh").args(args);
        command
    }
    fn good_coordinator() -> String {
        format!(r#"cat >/dev/null; printf state > "$1/adi.pb"; echo "OK {}""#, provisioning_client::sha256_hex(b"state"))
    }
    /// Passes only for an exact, lone copy of the attempt's adi.pb, and only
    /// while nothing exists yet under the final name ($3).
    fn good_verifier() -> String {
        format!(r#"cmp -s "$1/adi.pb" "$2/adi.pb" && [ "$(ls -A "$2")" = adi.pb ] && [ ! -e "$3" ] && echo '{VERIFIED_LINE}'"#)
    }

    struct Run { root: PathBuf, state: PathBuf }
    fn supervise_with(coordinator: &str, verifier: &str, cancel: bool) -> (Result<(), Failure>, Run) {
        let root = private_dir("supervise");
        let state = root.join("state");
        let (staging, verify) = attempt_paths(&state).unwrap();
        let flag = AtomicBool::new(cancel);
        let result = supervise(&state, b"{}".to_vec(), serde_json::json!({"device_id": "d"}), Supervision {
            coordinator: sh(coordinator, &[&staging, &verify, &state]),
            verifier: sh(verifier, &[&staging, &verify, &state]),
            coordinator_deadline: Duration::from_secs(5), verify_deadline: Duration::from_millis(400),
        }, &flag);
        (result, Run { root, state })
    }
    fn entries(dir: &Path) -> Vec<String> {
        let mut names: Vec<_> = fs::read_dir(dir).unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
        names.sort();
        names
    }

    #[test]
    fn supervised_run_publishes_only_a_verified_complete_state() {
        let (result, run) = supervise_with(&good_coordinator(), &good_verifier(), false);
        result.unwrap();
        assert_eq!(entries(&run.root), ["state"], "no attempt directories left");
        assert_eq!(fs::metadata(&run.state).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(entries(&run.state), ["adi.pb", IDENTITY_RECORD]);
        for name in ["adi.pb", IDENTITY_RECORD] {
            assert_eq!(fs::metadata(run.state.join(name)).unwrap().permissions().mode() & 0o777, 0o600);
        }
        assert_eq!(fs::read(run.state.join("adi.pb")).unwrap(), b"state");
        let record: serde_json::Value = serde_json::from_slice(&fs::read(run.state.join(IDENTITY_RECORD)).unwrap()).unwrap();
        assert_eq!(record["adi_pb_sha256"], provisioning_client::sha256_hex(b"state"));
        assert_eq!(record["device_id"], "d");
        // A second attempt for the same name never touches the published state.
        let (staging, verify) = attempt_paths(&run.state).unwrap();
        let failure = supervise(&run.state, Vec::new(), serde_json::json!({}), Supervision {
            coordinator: sh(&good_coordinator(), &[&staging]),
            verifier: sh(&good_verifier(), &[&staging, &verify, Path::new("/nonexistent")]),
            coordinator_deadline: Duration::from_secs(5), verify_deadline: Duration::from_secs(5),
        }, &AtomicBool::new(false)).unwrap_err();
        assert_eq!(failure.stage, "publish", "{failure:?}");
        assert_eq!(fs::read(run.state.join("adi.pb")).unwrap(), b"state");
        assert_eq!(entries(&run.root), ["state"]);
        fs::remove_dir_all(run.root).unwrap();
    }

    #[test]
    fn supervised_failures_name_the_stage_and_leave_nothing_behind() {
        let good = good_coordinator();
        let verifier = good_verifier();
        let cases: [(&str, &str, bool, &str); 14] = [
            ("echo 'FAIL native-start native worker failed to start'; exit 1", &verifier, false, "native-start"),
            // A status line cannot smuggle control characters or odd stage names.
            ("printf 'FAIL native-start bad\\033[2J reason\\n'; exit 1", &verifier, false, "native-start"),
            ("echo 'FAIL invented-stage x'; exit 1", &verifier, false, "coordinator"),
            ("kill -9 $$", &verifier, false, "coordinator"),
            // Success needs exit 0 and the exact digest line.
            (&format!("{good}; exit 1"), &verifier, false, "coordinator"),
            (r#"cat >/dev/null; printf state > "$1/adi.pb"; echo OK"#, &verifier, false, "coordinator"),
            (&format!("{good}; echo trailing"), &verifier, false, "coordinator"),
            // The file must be exactly what the coordinator reported.
            (&good.replace("printf state", "printf other"), &verifier, false, "persist"),
            (&good.replace(r#"printf state > "$1/adi.pb""#, r#"ln -s /etc/hosts "$1/adi.pb""#), &verifier, false, "persist"),
            (&good, "echo 'FAIL'; exit 1", false, "validate"),
            (&good, &format!("echo '{VERIFIED_LINE} extra'"), false, "validate"),
            (&good, "sleep 10", false, "validate"),
            // A change to the kept state during verification is caught.
            (&good, &format!(r#"printf other > "$1/adi.pb"; echo '{VERIFIED_LINE}'"#), false, "persist"),
            ("sleep 10", &verifier, true, "cancelled"),
        ];
        for (coordinator, verifier, cancel, stage) in cases {
            let started = std::time::Instant::now();
            let (result, run) = supervise_with(coordinator, verifier, cancel);
            let failure = result.unwrap_err();
            assert_eq!(failure.stage, stage, "{coordinator} / {verifier}: {failure:?}");
            assert!(!failure.reason.chars().any(char::is_control));
            assert!(started.elapsed() < Duration::from_secs(4), "{coordinator}: not bounded");
            assert!(entries(&run.root).is_empty(), "{coordinator}: left {:?}", entries(&run.root));
            fs::remove_dir_all(run.root).unwrap();
        }
    }

    #[test]
    fn descendants_holding_pipes_cannot_stall_or_outlive_supervision() {
        // The coordinator succeeds but leaves a background child holding
        // its stdout; previously the supervisor waited for it indefinitely.
        let pid_note = "echo $! > \"$1.pid\"";
        let coordinator = format!("sleep 30 & {pid_note}; {}", good_coordinator());
        let started = std::time::Instant::now();
        let (result, run) = supervise_with(&coordinator, &good_verifier(), false);
        result.unwrap();
        assert!(started.elapsed() < Duration::from_secs(4));
        let pid: libc::pid_t = fs::read_to_string(run.root.join(".state.incomplete.pid")).unwrap().trim().parse().unwrap();
        let waited = std::time::Instant::now();
        while unsafe { libc::kill(pid, 0) } == 0 {
            assert!(waited.elapsed() < Duration::from_secs(3), "descendant survived");
            std::thread::sleep(Duration::from_millis(20));
        }
        fs::remove_dir_all(run.root).unwrap();

        // A child that never reads a large input is still bounded.
        let started = std::time::Instant::now();
        let error = run_child(&mut sh("exec sleep 30", &[]), vec![0; 512 * 1024],
            Duration::from_millis(300), &AtomicBool::new(false)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn cleanup_never_removes_a_directory_or_link_put_in_place_of_a_claim() {
        let root = private_dir("cleanup-decoy-target");
        fs::write(root.join("precious"), b"keep").unwrap();
        for (swap, kept) in [
            (r#"mv "$1" "$1.moved"; mkdir -m 700 "$1"; echo keep > "$1/decoy"; exit 1"#, ".state.incomplete/decoy"),
            (&*format!(r#"mv "$1" "$1.moved"; ln -s '{}' "$1"; exit 1"#, root.display()), ".state.incomplete/precious"),
        ] {
            let (result, run) = supervise_with(swap, &good_verifier(), false);
            assert_eq!(result.unwrap_err().stage, "coordinator");
            assert!(run.root.join(kept).exists(), "{swap}: substituted path was removed");
            assert!(!run.state.exists());
            fs::remove_dir_all(run.root).unwrap();
        }
        assert_eq!(fs::read(root.join("precious")).unwrap(), b"keep");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn an_interrupted_earlier_attempt_blocks_and_is_left_for_inspection() {
        let root = private_dir("leftover");
        let state = root.join("state");
        let (staging, verify) = attempt_paths(&state).unwrap();
        fs::create_dir(&staging).unwrap();
        fs::write(staging.join("adi.pb"), b"from a killed run").unwrap();
        let failure = supervise(&state, Vec::new(), serde_json::json!({}), Supervision {
            coordinator: sh(&good_coordinator(), &[&staging]), verifier: sh(&good_verifier(), &[&staging, &verify, &state]),
            coordinator_deadline: Duration::from_secs(5), verify_deadline: Duration::from_secs(5),
        }, &AtomicBool::new(false)).unwrap_err();
        assert_eq!(failure.stage, "state-directory");
        assert_eq!(fs::read(staging.join("adi.pb")).unwrap(), b"from a killed run");
        assert!(!state.exists());
        fs::remove_dir_all(root).unwrap();
    }
}
