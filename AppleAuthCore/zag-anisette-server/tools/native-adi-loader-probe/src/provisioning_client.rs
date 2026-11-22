//! Operator-invoked Apple provisioning coordinator. No Apple credentials are
//! accepted. The coordinator talks only to Apple's approved HTTPS hosts, and
//! the native worker is a separate local child that owns the ADI session.
//!
//! Request headers mirror the Zag Store v3 client (zag-isideload
//! remote_v3::provision and GrandSlam::base_headers), so a state produced here
//! is provisioned exactly as the client would provision it.
use crate::offline_v2_bridge::wire::{self, Request, Response};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use plist::{Dictionary, Value};
use std::ffi::OsString;
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};
use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
use std::thread;
use url::Url;

const LOOKUP: &str = "https://gsa.apple.com/grandslam/GsService2/lookup";
const MAX_HTTP_BYTES: usize = 128 * 1024;
const WORKER_DEADLINE: Duration = Duration::from_secs(45);
pub(crate) const EXCHANGE_DEADLINE: Duration = Duration::from_secs(90);
/// AuthKit's fixed account-independent ds_id for machine provisioning.
const DS_ID: &str = "-2";
// Sent by GrandSlam::base_headers on every client request.
const XCODE_VERSION: &str = "27.0 (27A5218g)";
const APP_INFO: &str = "com.apple.gs.xcode.auth";

fn remaining(end: Instant) -> io::Result<Duration> {
    let left = end.checked_duration_since(Instant::now())
        .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "Apple provisioning deadline exceeded"))?;
    if left.is_zero() { return Err(io::Error::new(io::ErrorKind::TimedOut, "Apple provisioning deadline exceeded")); }
    Ok(left)
}

const MAX_BINARY_BYTES: usize = 12 * 1024;
const MAX_FRAME: usize = wire::MAX_FRAME;

/// The provisioning step a failure belongs to. Names are stable: operators
/// and scripts match on them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Stage { Lookup, StartProvisioning, NativeStart, FinishProvisioning, NativeFinish, Persist }
impl Stage {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Stage::Lookup => "lookup",
            Stage::StartProvisioning => "start-provisioning",
            Stage::NativeStart => "native-start",
            Stage::FinishProvisioning => "finish-provisioning",
            Stage::NativeFinish => "native-finish",
            Stage::Persist => "persist",
        }
    }
}

/// A failure tagged with its stage. The reason comes only from this
/// module's fixed messages, OS error text or an Apple status code; Apple
/// bodies, identity values and provisioning material never reach it.
#[derive(Debug)]
pub(crate) struct StageError { pub(crate) stage: Stage, pub(crate) reason: String }
impl fmt::Display for StageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.stage.name(), self.reason)
    }
}
pub(crate) fn safe_reason(error: &io::Error) -> String {
    error.to_string().chars().filter(|c| !c.is_control()).take(160).collect()
}
fn at(stage: Stage) -> impl Fn(io::Error) -> StageError {
    move |error| StageError { stage, reason: safe_reason(&error) }
}

/// Only known Apple GrandSlam provisioning hosts may be used. Deliberately
/// refuse redirects and credential-bearing URLs. Any host additions require review.
fn validated_endpoint(input: &str) -> io::Result<Url> {
    // Check the raw authority before URL normalization: url::Url intentionally
    // drops an explicit default HTTPS port (":443"), which would otherwise
    // defeat the no-explicit-port policy.
    let authority = input.strip_prefix("https://")
        .and_then(|rest| rest.split('/').next())
        .ok_or_else(|| invalid("invalid provisioning URL"))?;
    if !matches!(authority, "gsa.apple.com" | "gsas.apple.com") {
        return Err(invalid("unapproved raw provisioning authority"));
    }
    let url = Url::parse(input).map_err(|_| invalid("invalid provisioning URL"))?;
    if url.scheme() != "https" || url.port().is_some() || !url.username().is_empty()
        || url.password().is_some() || url.query().is_some() || url.fragment().is_some() {
        return Err(invalid("unsafe provisioning URL"));
    }
    // Strict exact-host restriction; no suffix checks or arbitrary domains.
    if !matches!(url.host_str(), Some("gsa.apple.com" | "gsas.apple.com")) {
        return Err(invalid("unapproved provisioning host"));
    }
    Ok(url)
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}
fn transport() -> io::Error {
    io::Error::new(io::ErrorKind::Other, "Apple provisioning transport failed")
}
fn worker_io() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, "native worker channel failed")
}
fn xml_bytes(dict: Dictionary) -> io::Result<Vec<u8>> {
    let mut output = Vec::new();
    Value::Dictionary(dict).to_writer_xml(&mut output).map_err(|_| invalid("invalid plist encoding"))?;
    if output.len() > MAX_HTTP_BYTES { return Err(invalid("oversized request")); }
    Ok(output)
}
fn plist_response(bytes: &[u8]) -> io::Result<Dictionary> {
    Value::from_reader_xml(bytes).map_err(|_| invalid("invalid Apple response plist"))?
        .into_dictionary().ok_or_else(|| invalid("invalid plist root"))
}
fn dictionary_field<'a>(dict: &'a Dictionary, key: &str) -> io::Result<&'a Dictionary> {
    dict.get(key).and_then(Value::as_dictionary).ok_or_else(|| invalid("missing plist dictionary"))
}
fn string_field<'a>(dict: &'a Dictionary, key: &str) -> io::Result<&'a str> {
    dict.get(key).and_then(Value::as_string).ok_or_else(|| invalid("missing plist string"))
}
fn decoded_field(dict: &Dictionary, key: &str) -> io::Result<Vec<u8>> {
    let encoded = string_field(dict, key)?;
    if encoded.is_empty() || encoded.len() > MAX_BINARY_BYTES * 2 { return Err(invalid("oversized provisioning material")); }
    let decoded = STANDARD.decode(encoded).map_err(|_| invalid("invalid provisioning base64"))?;
    if decoded.is_empty() || decoded.len() > MAX_BINARY_BYTES { return Err(invalid("invalid provisioning bytes")); }
    Ok(decoded)
}
/// The `Response` dictionary of a provisioning reply, refused when Apple's
/// own status carries an error code. Only the numeric code is reported.
fn apple_response(reply: &Dictionary) -> io::Result<&Dictionary> {
    let response = dictionary_field(reply, "Response")?;
    if let Some(status) = response.get("Status").and_then(Value::as_dictionary) {
        let code = status.get("ec").and_then(Value::as_signed_integer).unwrap_or(0);
        if code != 0 {
            return Err(io::Error::new(io::ErrorKind::Other, format!("Apple status error {code}")));
        }
    }
    Ok(response)
}
fn empty_request() -> io::Result<Vec<u8>> {
    let mut root = Dictionary::new();
    root.insert("Header".to_string(), Value::Dictionary(Dictionary::new()));
    root.insert("Request".to_string(), Value::Dictionary(Dictionary::new()));
    xml_bytes(root)
}
fn finish_request(cpim: &[u8]) -> io::Result<Vec<u8>> {
    if cpim.is_empty() || cpim.len() > MAX_BINARY_BYTES { return Err(invalid("invalid CPIM")); }
    let mut request = Dictionary::new();
    request.insert("cpim".to_string(), Value::String(STANDARD.encode(cpim)));
    let mut root = Dictionary::new();
    root.insert("Header".to_string(), Value::Dictionary(Dictionary::new()));
    root.insert("Request".to_string(), Value::Dictionary(request));
    xml_bytes(root)
}
fn framed_request(req: &Request) -> io::Result<Vec<u8>> {
    let bytes = wire::encode_request(req).map_err(|_| invalid("invalid v2 request"))?;
    let mut result = (bytes.len() as u32).to_be_bytes().to_vec();
    result.extend_from_slice(&bytes);
    Ok(result)
}
fn framed_response<R: Read>(reader: &mut R, request: &Request) -> io::Result<Response> {
    let mut length = [0u8; 4];
    reader.read_exact(&mut length).map_err(|_| worker_io())?;
    let size = u32::from_be_bytes(length) as usize;
    if size == 0 || size > MAX_FRAME { return Err(invalid("invalid worker frame")); }
    let mut bytes = vec![0; size];
    reader.read_exact(&mut bytes).map_err(|_| worker_io())?;
    wire::decode_response(&bytes, request).map_err(|_| invalid("invalid worker response"))
}

/// The CoreADI Android identifier for a client device ID. Matches the v3
/// reference server (anisette-v3-server): the first 16 characters of the
/// upper-cased UUID. Header generation must derive it the same way, or the
/// provisioned state does not belong to the device that later uses it.
pub(crate) fn android_identifier(device_id: &str) -> io::Result<String> {
    let bytes = device_id.as_bytes();
    if bytes.len() != 36 || ![8, 13, 18, 23].iter().all(|&i| bytes[i] == b'-')
        || !bytes.iter().enumerate().all(|(i, b)| [8, 13, 18, 23].contains(&i) || b.is_ascii_hexdigit()) {
        return Err(invalid("device ID must be a canonical UUID"));
    }
    Ok(device_id[..16].to_ascii_uppercase())
}

/// The client identity sent with provisioning. Serial is optional because
/// the v3 client never sends X-Apple-I-SRL-NO while provisioning; when an
/// operator supplies one, it is validated and sent.
pub(crate) struct ClientIdentity<'a> {
    pub(crate) device_id: &'a str,
    pub(crate) client_info: &'a str,
    pub(crate) local_user: &'a str,
    pub(crate) serial: Option<&'a str>,
    pub(crate) user_agent: &'a str,
}

pub(crate) fn validate_identity(identity: &ClientIdentity<'_>) -> io::Result<()> {
    AppleHttp::new(identity).map(|_| ())
}

/// The coordinator's only way to reach Apple. `device` adds the device
/// headers, which the v3 client sends on provisioning calls but not on the
/// URL bag lookup.
pub(crate) trait AppleTransport {
    fn send(&self, url: &Url, body: Option<&[u8]>, device: bool, end: Instant) -> io::Result<Dictionary>;
}

struct DeviceHeaders { device_id: String, local_user: String, serial: Option<String> }

pub(crate) struct AppleHttp {
    agent: ureq::Agent,
    client_info: String,
    user_agent: String,
    /// None for a lookup-only client, which can never send device headers.
    device: Option<DeviceHeaders>,
}

fn client_headers(client_info: &str, user_agent: &str) -> io::Result<()> {
    if user_agent.is_empty() || user_agent.len() > 512 || user_agent.chars().any(char::is_control) {
        return Err(invalid("invalid configured user agent"));
    }
    if client_info.is_empty() || client_info.len() > 512 || client_info.chars().any(char::is_control) {
        return Err(invalid("invalid device headers"));
    }
    Ok(())
}

/// Apple Root CA (SHA-256 B0B1730E…F024): the file the Zag Store client
/// pins in GrandSlam::build_reqwest_client. gsa.apple.com and gsas.apple.com
/// chain to it, and it is not in the Mozilla roots ureq bundles, which is
/// why lookups failed with UnknownIssuer.
const APPLE_ROOT: &[u8] = include_bytes!("../../../../zag-isideload/src/assets/apple_root.cer");

/// The only trust anchor for Apple requests. The endpoint allow-list
/// admits only these two Apple hosts, so no other root is needed; neither
/// the host's certificate store nor bundled roots are consulted. Hostname
/// and chain verification are rustls's defaults.
fn apple_roots() -> io::Result<rustls::RootCertStore> {
    let mut roots = rustls::RootCertStore::empty();
    roots.add(rustls::pki_types::CertificateDer::from(APPLE_ROOT))
        .map_err(|_| invalid("embedded Apple Root CA is invalid"))?;
    Ok(roots)
}

fn agent() -> io::Result<ureq::Agent> {
    let provider = std::sync::Arc::new(rustls::crypto::ring::default_provider());
    let tls = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions().map_err(|_| invalid("TLS configuration failed"))?
        .with_root_certificates(apple_roots()?)
        .with_no_client_auth();
    Ok(ureq::AgentBuilder::new()
        .tls_config(std::sync::Arc::new(tls))
        .timeout_connect(Duration::from_secs(8))
        .timeout_read(Duration::from_secs(12))
        .timeout_write(Duration::from_secs(12))
        .redirects(0)
        .build())
}

/// Names a transport failure without its message text: DNS, TLS (with
/// rustls's reason, e.g. an untrusted issuer), connect, timeout or a
/// malformed response. Never includes headers, bodies or identity values.
fn transport_reason(error: &ureq::Transport) -> String {
    use std::error::Error as _;
    let mut cause: Option<&(dyn std::error::Error + 'static)> = error.source();
    while let Some(current) = cause {
        let tls = current.downcast_ref::<rustls::Error>().or_else(|| current.downcast_ref::<io::Error>()
            .and_then(|io| io.get_ref()).and_then(|inner| inner.downcast_ref::<rustls::Error>()));
        if let Some(tls) = tls {
            return match tls {
                rustls::Error::InvalidCertificate(reason) => format!("TLS certificate rejected ({reason:?})"),
                other => format!("TLS handshake failed ({})", tls_kind(other)),
            };
        }
        if let Some(io) = current.downcast_ref::<io::Error>() {
            if matches!(io.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock) {
                return "Apple connection timed out".into();
            }
        }
        cause = current.source();
    }
    match error.kind() {
        ureq::ErrorKind::Dns => "DNS resolution failed".into(),
        ureq::ErrorKind::ConnectionFailed => "connection to Apple failed".into(),
        ureq::ErrorKind::Io => "I/O error talking to Apple".into(),
        ureq::ErrorKind::BadStatus | ureq::ErrorKind::BadHeader => "malformed HTTP response from Apple".into(),
        kind => format!("unexpected transport error ({kind:?})"),
    }
}

/// The variant name of a non-certificate rustls error, without payloads.
fn tls_kind(error: &rustls::Error) -> String {
    format!("{error:?}").split(['(', ' ', '{']).next().unwrap_or("unknown").to_owned()
}

impl AppleHttp {
    /// A client for the credential-free URL bag lookup only: it holds no
    /// device identity, so it cannot send one.
    pub(crate) fn lookup_only(client_info: &str, user_agent: &str) -> io::Result<Self> {
        client_headers(client_info, user_agent)?;
        Ok(Self { agent: agent()?, client_info: client_info.to_owned(), user_agent: user_agent.to_owned(), device: None })
    }

    pub(crate) fn new(identity: &ClientIdentity<'_>) -> io::Result<Self> {
        let ClientIdentity { device_id, client_info, local_user, serial, user_agent } = *identity;
        client_headers(client_info, user_agent)?;
        if device_id.is_empty() || device_id.len() > 256 || device_id.chars().any(char::is_control) {
            return Err(invalid("invalid device headers"));
        }
        // Never synthesize identity headers or accept control characters.
        // Values must be stable operator-provided test identities.
        if local_user.len() != 64 || !local_user.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(invalid("invalid Apple identity headers"));
        }
        if let Some(serial) = serial {
            if serial.is_empty() || serial.len() > 64
                || !serial.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
                return Err(invalid("invalid Apple identity headers"));
            }
        }
        Ok(Self {
            agent: agent()?, client_info: client_info.to_owned(), user_agent: user_agent.to_owned(),
            device: Some(DeviceHeaders {
                device_id: device_id.to_owned(), local_user: local_user.to_owned(), serial: serial.map(str::to_owned),
            }),
        })
    }
}
impl AppleHttp {
    /// Every header of one request, in order: the client's GrandSlam base
    /// headers, plus the two provisioning headers when `device` is set
    /// (zag-isideload `GrandSlam::base_headers` and
    /// `RemoteV3AnisetteProvider::provisioning_headers`).
    fn headers(&self, device: bool) -> io::Result<Vec<(&'static str, &str)>> {
        let mut headers = vec![
            ("Content-Type", "text/x-xml-plist"),
            ("Accept", "text/x-xml-plist"),
            ("X-Mme-Client-Info", self.client_info.as_str()),
            ("User-Agent", self.user_agent.as_str()),
            ("X-Xcode-Version", XCODE_VERSION),
            ("X-Apple-App-Info", APP_INFO),
            ("Connection", "close"),
        ];
        if device {
            let ids = self.device.as_ref().ok_or_else(|| invalid("lookup-only client has no device headers"))?;
            headers.push(("X-Apple-I-MD-LU", ids.local_user.as_str()));
            headers.push(("X-Mme-Device-Id", ids.device_id.as_str()));
            if let Some(serial) = &ids.serial { headers.push(("X-Apple-I-SRL-NO", serial.as_str())); }
        }
        Ok(headers)
    }
}

/// Apple's numeric status from a rejected response body, read from
/// `Response.Status.ec` or `Status.ec`. Only the integer is kept: the
/// message text and every other field are discarded unread.
fn rejection_status(bytes: &[u8]) -> Option<i64> {
    let root = Value::from_reader_xml(bytes).ok()?.into_dictionary()?;
    let response = root.get("Response").and_then(Value::as_dictionary).unwrap_or(&root);
    response.get("Status").and_then(Value::as_dictionary)?.get("ec")?.as_signed_integer()
}

/// "Apple HTTP status N" plus what the bounded body says, so a policy
/// rejection (a plist with an Apple status code) is distinguishable from
/// a gateway or proxy error (no plist).
fn http_rejection(code: u16, response: ureq::Response) -> io::Error {
    let mut bytes = Vec::new();
    let read = response.into_reader().take(MAX_HTTP_BYTES as u64).read_to_end(&mut bytes);
    let detail = match (read, rejection_status(&bytes)) {
        (_, Some(ec)) => format!("Apple status {ec}"),
        (Ok(_), None) if bytes.is_empty() => "empty body".to_owned(),
        (Ok(_), None) => "no Apple status in body".to_owned(),
        (Err(_), None) => "body unreadable".to_owned(),
    };
    io::Error::new(io::ErrorKind::Other, format!("Apple HTTP status {code} ({detail})"))
}

impl AppleTransport for AppleHttp {
    fn send(&self, url: &Url, body: Option<&[u8]>, device: bool, end: Instant) -> io::Result<Dictionary> {
        let url = validated_endpoint(url.as_str())?;
        let budget = remaining(end)?;
        let mut req = match body {
            Some(_) => self.agent.post(url.as_str()),
            None => self.agent.get(url.as_str()),
        }
            .timeout(budget);
        for (name, value) in self.headers(device)? { req = req.set(name, value); }
        // ureq's default TLS verification is retained; no insecure opt-out.
        // Any redirect is rejected by redirects(0) and status validation.
        let result = match body {
            Some(bytes) => req.send_bytes(bytes),
            None => req.call(),
        }.map_err(|error| match error {
            ureq::Error::Status(code, response) => http_rejection(code, response),
            ureq::Error::Transport(error) => io::Error::new(io::ErrorKind::Other, transport_reason(&error)),
        })?;
        if result.status() != 200 {
            return Err(io::Error::new(io::ErrorKind::Other, format!("Apple HTTP status {}", result.status())));
        }
        let mut bounded = result.into_reader().take((MAX_HTTP_BYTES + 1) as u64);
        let mut bytes = Vec::new();
        bounded.read_to_end(&mut bytes).map_err(|_| transport())?;
        if bytes.is_empty() || bytes.len() > MAX_HTTP_BYTES { return Err(invalid("invalid HTTP body size")); }
        remaining(end)?;
        plist_response(&bytes)
    }
}

/// Owns the Child handle until it is reaped. Never signals a bare PID:
/// kill() operates on the still-owned Child, preventing PID-reuse races.
/// Abort requests and the hard deadline are both handled by this thread.
fn supervise_child(
    mut child: Child,
    deadline: Duration,
    abort: Arc<AtomicBool>,
) -> thread::JoinHandle<io::Result<(ExitStatus, bool)>> {
    thread::spawn(move || {
        let end = Instant::now() + deadline;
        loop {
            if let Some(status) = child.try_wait()? {
                return Ok((status, false));
            }
            if abort.load(Ordering::Acquire) || Instant::now() >= end {
                let timed_out = Instant::now() >= end;
                child.kill()?;
                let status = child.wait()?;
                return Ok((status, timed_out));
            }
            thread::sleep(Duration::from_millis(20));
        }
    })
}

/// How to launch the native worker: the probe itself in --native-v2-session
/// mode in production, a fixture in the offline integration tests.
pub(crate) struct WorkerCommand { pub(crate) program: PathBuf, pub(crate) args: Vec<OsString> }
impl WorkerCommand {
    pub(crate) fn native(worker_binary: &Path, runtime_root: &Path, state_dir: &Path, android_id: &str) -> Self {
        Self {
            program: worker_binary.to_owned(),
            args: vec![runtime_root.into(), "--native-v2-session".into(), state_dir.into(), android_id.into()],
        }
    }
}

fn spawn_worker(worker: &WorkerCommand) -> io::Result<Child> {
    let mut command = Command::new(&worker.program);
    command.args(&worker.args)
        .env_clear()
        .current_dir("/")
        .stdin(Stdio::piped()).stdout(Stdio::piped())
        .stderr(Stdio::null());
    // On Linux, the kernel kills the native worker if the isolated coordinator
    // dies (including an external watchdog SIGKILL). No raw PID signaling or
    // PID-reuse-sensitive cleanup is needed. Parent identity is rechecked after
    // prctl to close the fork-to-prctl parent-exit race.
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::process::CommandExt;
        let coordinator_pid = unsafe { libc::getpid() };
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::getppid() != coordinator_pid {
                    return Err(io::Error::new(io::ErrorKind::Other, "coordinator exited"));
                }
                Ok(())
            });
        }
    }
    command.spawn().map_err(|_| io::Error::new(io::ErrorKind::Other, "native worker failed to start"))
}

/// Confirms that the worker's reported state is exactly the adi.pb in the
/// claimed directory (no symlink, regular, non-empty), then makes it
/// owner-only and durable. Returns its SHA-256 (hex), which binds the
/// supervisor's later checks to these exact bytes.
fn persist_state(state_dir: &Path, reported: &[u8]) -> io::Result<String> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let mut file = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW)
        .open(state_dir.join("adi.pb")).map_err(|_| invalid("native worker left no ADI state file"))?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_FRAME as u64 {
        return Err(invalid("invalid ADI state file"));
    }
    let mut stored = Vec::new();
    (&mut file).take(MAX_FRAME as u64 + 1).read_to_end(&mut stored)?;
    if stored != reported { return Err(invalid("ADI state file differs from worker result")); }
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    file.sync_all()?;
    fs::File::open(state_dir)?.sync_all()?;
    Ok(sha256_hex(&stored))
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Runs the complete provisioning exchange for one claimed, empty state
/// directory: URL bag lookup, midStartProvisioning, native Start,
/// midFinishProvisioning, native End, and verified persistence of adi.pb.
/// The native worker lives only inside this call and is reaped on every path.
/// Returns the SHA-256 (hex) of the persisted adi.pb.
pub(crate) fn provision<T: AppleTransport>(
    apple: &T,
    worker: &WorkerCommand,
    state_dir: &Path,
    deadline: Duration,
) -> Result<String, StageError> {
    let end = Instant::now() + deadline;
    let lookup = (|| {
        let bag = apple.send(&validated_endpoint(LOOKUP)?, None, false, end)?;
        let urls = dictionary_field(&bag, "urls")?;
        Ok((validated_endpoint(string_field(urls, "midStartProvisioning")?)?,
            validated_endpoint(string_field(urls, "midFinishProvisioning")?)?))
    })();
    let (start_url, finish_url) = lookup.map_err(at(Stage::Lookup))?;
    let spim = (|| {
        let reply = apple.send(&start_url, Some(&empty_request()?), true, end)?;
        decoded_field(apple_response(&reply)?, "spim")
    })().map_err(at(Stage::StartProvisioning))?;

    // Do not start a native worker once the Apple exchange budget has expired.
    let worker_budget = WORKER_DEADLINE.min(remaining(end).map_err(at(Stage::NativeStart))?);
    let mut child = spawn_worker(worker).map_err(at(Stage::NativeStart))?;
    // Extract pipes before transferring exclusive Child ownership to the
    // supervisor. All process termination/reaping occurs in that thread.
    let mut stdin = child.stdin.take();
    let stdout = child.stdout.take();
    let abort = Arc::new(AtomicBool::new(false));
    // The native worker cannot outlive the remaining exchange budget.
    let supervisor = supervise_child(child, worker_budget, Arc::clone(&abort));
    let mut stdout = stdout;
    let result = (|| {
        let (Some(input), Some(output)) = (stdin.as_mut(), stdout.as_mut()) else {
            return Err(at(Stage::NativeStart)(worker_io()));
        };
        let start = Request::Start { identifier: DS_ID.into(), spim };
        let cpim = (|| {
            input.write_all(&framed_request(&start)?).map_err(|_| worker_io())?;
            input.flush().map_err(|_| worker_io())?;
            match framed_response(output, &start)? {
                Response::Started(data) => Ok(data),
                _ => Err(invalid("native worker rejected Start")),
            }
        })().map_err(at(Stage::NativeStart))?;
        let (ptm, tk) = (|| {
            let reply = apple.send(&finish_url, Some(&finish_request(&cpim)?), true, end)?;
            let response = apple_response(&reply)?;
            Ok((decoded_field(response, "ptm")?, decoded_field(response, "tk")?))
        })().map_err(at(Stage::FinishProvisioning))?;
        let finish = Request::Finish { ptm, tk };
        (|| {
            remaining(end)?;
            input.write_all(&framed_request(&finish)?).map_err(|_| worker_io())?;
            input.flush().map_err(|_| worker_io())?;
            let adi_pb = match framed_response(output, &finish)? {
                Response::Finished(data) => data,
                _ => return Err(invalid("native worker rejected Finish")),
            };
            let mut extra = [0u8; 1];
            if output.read(&mut extra).map_err(|_| worker_io())? != 0 {
                return Err(invalid("native worker trailing output"));
            }
            Ok(adi_pb)
        })().map_err(at(Stage::NativeFinish))
    })();
    if result.is_err() { abort.store(true, Ordering::Release); }
    drop(stdin.take());
    drop(stdout);
    // The stage that failed first is the one reported; the worker's exit
    // after an abort is a consequence, not a separate failure.
    let joined = supervisor.join();
    let adi_pb = result?;
    let (status, timed_out) = joined
        .map_err(|_| at(Stage::NativeFinish)(worker_io()))?
        .map_err(at(Stage::NativeFinish))?;
    if timed_out {
        return Err(at(Stage::NativeFinish)(io::Error::new(io::ErrorKind::TimedOut, "native worker deadline exceeded")));
    }
    if !status.success() {
        return Err(at(Stage::NativeFinish)(io::Error::new(io::ErrorKind::Other, "native worker exited with failure")));
    }
    persist_state(state_dir, &adi_pb).map_err(at(Stage::Persist))
}

/// Read-only check of the exact lookup the coordinator performs: one GET
/// of the URL bag with the client headers (never device headers), then the
/// same parsing and endpoint validation. Returns a redacted summary.
pub(crate) fn diagnose_lookup(apple: &AppleHttp, deadline: Duration) -> io::Result<String> {
    let end = Instant::now() + deadline;
    let bag = apple.send(&validated_endpoint(LOOKUP)?, None, false, end)?;
    let urls = dictionary_field(&bag, "urls")?;
    let mut endpoints = Vec::new();
    for key in ["midStartProvisioning", "midFinishProvisioning"] {
        let url = validated_endpoint(string_field(urls, key)?)?;
        endpoints.push(format!("{key}={}{}", url.host_str().unwrap_or(""), url.path()));
    }
    Ok(format!("HTTP 200, URL bag parsed ({} entries); {}", urls.len(), endpoints.join(", ")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::os::unix::fs::PermissionsExt;

    #[cfg(unix)]
    #[test]
    fn supervisor_reaps_hung_child_without_raw_pid_signals() {
        let child = Command::new("/bin/sh")
            .args(["-c", "exec sleep 10"])
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
            .spawn().unwrap();
        let started = Instant::now();
        let abort = Arc::new(AtomicBool::new(false));
        let worker = supervise_child(child, Duration::from_millis(120), abort);
        let (status, timed_out) = worker.join().unwrap().unwrap();
        assert!(timed_out);
        assert!(!status.success());
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn expired_exchange_budget_fails_closed() {
        let end = Instant::now() - Duration::from_millis(1);
        assert_eq!(remaining(end).unwrap_err().kind(), io::ErrorKind::TimedOut);
        let user = "A".repeat(64);
        let http = AppleHttp::new(&identity("device", "client", &user, Some("TEST"), "agent")).unwrap();
        let error = http.send(&validated_endpoint(LOOKUP).unwrap(), None, false, end).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    }

    fn identity<'a>(device_id: &'a str, client_info: &'a str, local_user: &'a str,
                    serial: Option<&'a str>, user_agent: &'a str) -> ClientIdentity<'a> {
        ClientIdentity { device_id, client_info, local_user, serial, user_agent }
    }

    #[test]
    fn identity_headers_reject_missing_or_injected_values() {
        let user = "A".repeat(64);
        let ok = |id: ClientIdentity<'_>| AppleHttp::new(&id).is_ok();
        assert!(ok(identity("device", "client", &user, Some("TEST-123"), "agent")));
        // The v3 client sends no serial while provisioning.
        assert!(ok(identity("device", "client", &user, None, "agent")));
        assert!(!ok(identity("device", "client", "", None, "agent")));
        assert!(!ok(identity("device", "client", &user, Some(""), "agent")));
        assert!(!ok(identity("device", "client", &user, Some("TEST\r\nInjected"), "agent")));
        assert!(!ok(identity("device", "client\nInjected", &user, None, "agent")));
        assert!(!ok(identity("device", "", &user, None, "agent")));
        assert!(!ok(identity("device", "client", &("A".repeat(63) + "Z"), None, "agent")));
        for agent in ["", "bad\r\nInjected", "bad\0agent", &"x".repeat(513)] {
            assert!(!ok(identity("device", "client", &user, None, agent)));
        }
    }

    #[test]
    fn apple_requests_trust_exactly_the_pinned_apple_root() {
        // The same certificate as the client's asset, Apple's published root.
        assert_eq!(sha256_hex(APPLE_ROOT), "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024");
        assert_eq!(apple_roots().unwrap().len(), 1);
        assert!(agent().is_ok());
        // A lookup-only client cannot be made to send device headers.
        let apple = AppleHttp::lookup_only("<a> <b;c;d> <e/1 (f/1)>", "f/1").unwrap();
        let error = apple.send(&validated_endpoint(LOOKUP).unwrap(), None, true, Instant::now() + Duration::from_secs(5));
        assert_eq!(error.unwrap_err().to_string(), "lookup-only client has no device headers");
    }

    #[test]
    fn android_identifier_matches_reference_derivation() {
        assert_eq!(android_identifier("00010203-0405-0607-0809-0a0b0c0d0e0f").unwrap(), "00010203-0405-06");
        for bad in ["", "not-a-uuid", "00010203-0405-0607-0809-0a0b0c0d0e0g", "000102030405060708090a0b0c0d0e0f"] {
            assert!(android_identifier(bad).is_err());
        }
    }

    #[test]
    fn endpoint_allowlist_is_strict() {
        for good in [
            "https://gsa.apple.com/grandslam/GsService2/lookup",
            "https://gsas.apple.com/another/path",
        ] { assert!(validated_endpoint(good).is_ok()); }
        for bad in [
            "http://gsa.apple.com/a",
            "https://gsa.apple.com.evil.example/a",
            "https://evil.example/a", "https://user@gsa.apple.com/a",
            "https://gsa.apple.com:443/a", "https://gsa.apple.com/a?token=x",
            "https://gsa.apple.com/a#fragment", "file:///etc/passwd",
        ] { assert!(validated_endpoint(bad).is_err()); }
    }

    // ---- Offline integration of the whole exchange ----
    //
    // A scripted Apple and a fixture worker (tests/fixtures/fake_native_worker.py)
    // run the real coordinator, framing, supervision and persistence code.
    // Nothing here contacts Apple or loads native libraries.

    const SPIM: &[u8] = b"offline-spim";
    const CPIM: &[u8] = b"offline-cpim";
    const PTM: &[u8] = b"offline-ptm";
    const TK: &[u8] = b"offline-tk";
    const ADI_PB: &[u8] = b"offline-adi-pb";

    #[derive(Clone, Copy, PartialEq)]
    enum AppleScript { Ok, BadBag, StartStatus, NoSpim, FinishHttp, NoTk, SlowFinish }

    struct FakeApple { script: AppleScript, calls: RefCell<Vec<(String, bool, Option<Vec<u8>>)>> }
    impl FakeApple {
        fn new(script: AppleScript) -> Self { Self { script, calls: RefCell::new(Vec::new()) } }
    }
    fn reply(entries: &[(&str, Value)]) -> Dictionary {
        let mut response = Dictionary::new();
        for (key, value) in entries { response.insert((*key).into(), value.clone()); }
        let mut root = Dictionary::new();
        root.insert("Response".into(), Value::Dictionary(response));
        root
    }
    fn status(code: i64) -> Value {
        let mut status = Dictionary::new();
        status.insert("ec".into(), Value::Integer(code.into()));
        Value::Dictionary(status)
    }
    impl AppleTransport for FakeApple {
        fn send(&self, url: &Url, body: Option<&[u8]>, device: bool, end: Instant) -> io::Result<Dictionary> {
            self.calls.borrow_mut().push((url.path().to_owned(), device, body.map(<[u8]>::to_vec)));
            remaining(end)?;
            let b64 = |bytes: &[u8]| Value::String(STANDARD.encode(bytes));
            Ok(match url.path() {
                "/grandslam/GsService2/lookup" => {
                    let mut urls = Dictionary::new();
                    let finish = if self.script == AppleScript::BadBag { "https://evil.example/finish" }
                                 else { "https://gsa.apple.com/grandslam/MidService/finishProvisioning" };
                    urls.insert("midStartProvisioning".into(), "https://gsa.apple.com/grandslam/MidService/startProvisioning".into());
                    urls.insert("midFinishProvisioning".into(), finish.into());
                    let mut root = Dictionary::new();
                    root.insert("urls".into(), Value::Dictionary(urls));
                    root
                }
                "/grandslam/MidService/startProvisioning" => match self.script {
                    AppleScript::StartStatus => reply(&[("Status", status(-5000)), ("spim", b64(SPIM))]),
                    AppleScript::NoSpim => reply(&[("Status", status(0))]),
                    _ => reply(&[("Status", status(0)), ("spim", b64(SPIM))]),
                },
                "/grandslam/MidService/finishProvisioning" => match self.script {
                    AppleScript::FinishHttp => return Err(io::Error::new(io::ErrorKind::Other, "Apple HTTP status 503")),
                    AppleScript::NoTk => reply(&[("ptm", b64(PTM))]),
                    AppleScript::SlowFinish => {
                        thread::sleep(Duration::from_millis(400));
                        remaining(end)?;
                        unreachable!("deadline must expire first")
                    }
                    _ => reply(&[("Status", status(0)), ("ptm", b64(PTM)), ("tk", b64(TK))]),
                },
                _ => panic!("unexpected endpoint"),
            })
        }
    }

    fn claimed_dir() -> PathBuf {
        use std::sync::atomic::AtomicU64;
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "zag-adi-e2e-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        dir
    }
    fn fixture(script: &str, state: &Path) -> WorkerCommand {
        WorkerCommand {
            program: Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake_native_worker.py"),
            args: vec![script.into(), state.into()],
        }
    }
    fn run(apple: AppleScript, worker: &str, deadline: Duration) -> (Result<String, StageError>, PathBuf, FakeApple) {
        let state = claimed_dir();
        let apple = FakeApple::new(apple);
        let result = provision(&apple, &fixture(worker, &state), &state, deadline);
        (result, state, apple)
    }

    #[test]
    fn offline_exchange_persists_verified_state_in_client_order() {
        let (result, state, apple) = run(AppleScript::Ok, "ok", EXCHANGE_DEADLINE);
        assert_eq!(result.unwrap(), sha256_hex(ADI_PB));
        let stored = state.join("adi.pb");
        assert_eq!(fs::read(&stored).unwrap(), ADI_PB);
        assert_eq!(fs::metadata(&stored).unwrap().permissions().mode() & 0o777, 0o600);
        let calls = apple.calls.borrow();
        let paths: Vec<_> = calls.iter().map(|(p, d, _)| (p.as_str(), *d)).collect();
        assert_eq!(paths, [
            ("/grandslam/GsService2/lookup", false),
            ("/grandslam/MidService/startProvisioning", true),
            ("/grandslam/MidService/finishProvisioning", true),
        ]);
        // The finish request carries exactly the worker's CPIM.
        let finish = plist_response(calls[2].2.as_deref().unwrap()).unwrap();
        let request = dictionary_field(&finish, "Request").unwrap();
        assert_eq!(decoded_field(request, "cpim").unwrap(), CPIM);
        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn offline_exchange_reports_the_failing_stage_and_reaps_the_worker() {
        let cases = [
            (AppleScript::BadBag, "ok", Stage::Lookup),
            (AppleScript::StartStatus, "ok", Stage::StartProvisioning),
            (AppleScript::NoSpim, "ok", Stage::StartProvisioning),
            (AppleScript::Ok, "reject-start", Stage::NativeStart),
            (AppleScript::Ok, "exit-at-start", Stage::NativeStart),
            (AppleScript::FinishHttp, "ok", Stage::FinishProvisioning),
            (AppleScript::NoTk, "ok", Stage::FinishProvisioning),
            (AppleScript::FinishHttp, "hang-after-start", Stage::FinishProvisioning),
            (AppleScript::Ok, "reject-finish", Stage::NativeFinish),
            (AppleScript::Ok, "fail-after-finish", Stage::NativeFinish),
            (AppleScript::Ok, "no-state", Stage::Persist),
            (AppleScript::Ok, "mismatched-state", Stage::Persist),
        ];
        for (apple, worker, stage) in cases {
            let started = Instant::now();
            let (result, state, _) = run(apple, worker, EXCHANGE_DEADLINE);
            let error = result.expect_err(worker);
            assert_eq!(error.stage, stage, "{worker}: {error}");
            // Aborted workers are killed, not waited out.
            assert!(started.elapsed() < Duration::from_secs(5), "{worker}");
            // No material ever appears in a reported reason.
            for secret in [SPIM, CPIM, PTM, TK, ADI_PB] {
                assert!(!error.reason.contains(std::str::from_utf8(secret).unwrap()));
            }
            if matches!(stage, Stage::Lookup | Stage::StartProvisioning) {
                assert!(fs::read_dir(&state).unwrap().next().is_none(), "no worker before SPIM");
            }
            fs::remove_dir_all(state).unwrap();
        }
        let (result, state, _) = run(AppleScript::StartStatus, "ok", EXCHANGE_DEADLINE);
        assert_eq!(result.unwrap_err().reason, "Apple status error -5000");
        fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn offline_exchange_deadline_cancels_hung_worker_and_slow_apple() {
        for (apple, worker, stage) in [
            (AppleScript::Ok, "hang-at-start", Stage::NativeStart),
            (AppleScript::SlowFinish, "ok", Stage::FinishProvisioning),
        ] {
            let started = Instant::now();
            let (result, state, _) = run(apple, worker, Duration::from_millis(300));
            let error = result.unwrap_err();
            assert_eq!(error.stage, stage, "{worker}: {error}");
            assert!(started.elapsed() < Duration::from_secs(3), "{worker}");
            fs::remove_dir_all(state).unwrap();
        }
    }

    #[test]
    fn plist_contract_rejects_missing_and_invalid_material() {
        let bytes = empty_request().unwrap();
        let value = plist_response(&bytes).unwrap();
        assert!(dictionary_field(&value, "Request").is_ok());
        assert!(decoded_field(&value, "spim").is_err());
        let mut response = Dictionary::new();
        response.insert("spim".to_string(), Value::String(STANDARD.encode([0, 255, 64])));
        assert_eq!(decoded_field(&response, "spim").unwrap(), vec![0, 255, 64]);
        response.insert("spim".to_string(), Value::String("invalid!!".into()));
        assert!(decoded_field(&response, "spim").is_err());
        assert!(finish_request(&[]).is_err());
    }

    /// The bodies Dadoum/Provision@main lib/provision/adi.d posts
    /// (ProvisioningSession.provision), as an offline reference fixture.
    const PROVISION_START: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>Header</key>\n\t<dict/>\n\t<key>Request</key>\n\t<dict/>\n</dict>\n</plist>";
    const PROVISION_FINISH: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>Header</key>\n\t<dict/>\n\t<key>Request</key>\n\t<dict>\n\t\t<key>cpim</key>\n\t\t<string>%s</string>\n\t</dict>\n</dict>\n</plist>";

    #[test]
    fn provisioning_requests_match_the_reference_implementations() {
        // Bodies: the same plist as Provision's, with CPIM as standard base64
        // of the native Start output (anisette-v3-server Base64.encode).
        let cpim = [0u8, 1, 2, 250, 251, 255];
        assert_eq!(plist_response(&empty_request().unwrap()).unwrap(),
            plist_response(PROVISION_START.as_bytes()).unwrap());
        let finish = PROVISION_FINISH.replace("%s", &STANDARD.encode(cpim));
        assert_eq!(plist_response(&finish_request(&cpim).unwrap()).unwrap(),
            plist_response(finish.as_bytes()).unwrap());
        // Headers: exactly the client's GrandSlam base headers, plus MD-LU and
        // Device-Id only on provisioning requests, and no serial unless given.
        let user = "a".repeat(64);
        let http = AppleHttp::new(&identity("device", "client", &user, None, "agent")).unwrap();
        let names = |device| http.headers(device).unwrap().into_iter().map(|(n, _)| n).collect::<Vec<_>>();
        let base = ["Content-Type", "Accept", "X-Mme-Client-Info", "User-Agent", "X-Xcode-Version", "X-Apple-App-Info", "Connection"];
        assert_eq!(names(false), base);
        assert_eq!(names(true), [&base[..], &["X-Apple-I-MD-LU", "X-Mme-Device-Id"]].concat());
        let values: std::collections::HashMap<_, _> = http.headers(true).unwrap().into_iter().collect();
        assert_eq!((values["X-Apple-I-MD-LU"], values["X-Mme-Device-Id"]), (user.as_str(), "device"));
        assert_eq!((values["X-Mme-Client-Info"], values["User-Agent"]), ("client", "agent"));
        // The lookup-only client never has device headers.
        assert!(AppleHttp::lookup_only("client", "agent").unwrap().headers(true).is_err());
    }

    #[test]
    fn rejected_responses_keep_only_apple_status_code() {
        let mut status = Dictionary::new();
        status.insert("ec".into(), Value::Integer((-29002).into()));
        status.insert("em".into(), Value::String("private message".into()));
        let mut response = Dictionary::new();
        response.insert("Status".into(), Value::Dictionary(status.clone()));
        let mut nested = Dictionary::new();
        nested.insert("Response".into(), Value::Dictionary(response));
        assert_eq!(rejection_status(&xml_bytes(nested).unwrap()), Some(-29002));
        let mut top = Dictionary::new();
        top.insert("Status".into(), Value::Dictionary(status));
        assert_eq!(rejection_status(&xml_bytes(top).unwrap()), Some(-29002));
        for body in [&b""[..], b"<html>Unauthorized</html>", b"<plist><dict/></plist>"] {
            assert_eq!(rejection_status(body), None);
        }
    }
}
