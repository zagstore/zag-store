//! Native CoreADI backend for the v3 routes.
//!
//! The server never loads Apple libraries itself. Every native operation runs
//! in a fresh child: the reviewed native worker (the probe binary in
//! `tools/native-adi-loader-probe`), started with a cleared environment in its
//! own process group, for exactly one request, against exactly one private
//! work directory that is removed afterwards. CoreADI state is therefore never
//! shared between requests, and a crashed, hung or misbehaving worker is
//! killed with its whole group and reaped without affecting other requests.
//!
//! The server stores no ADI state: as with every v3 server, the client keeps
//! its `adi.pb` and sends it with each `/v3/get_headers` request. The server
//! contacts nothing; the client relays provisioning messages to Apple.
//!
//! No value from a request, a worker or a state file is ever logged. Errors
//! are fixed strings.
use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{atomic::{AtomicBool, AtomicUsize, Ordering}, mpsc},
    thread,
    time::{Duration, Instant},
};
#[cfg(unix)]
use std::os::unix::{fs::{DirBuilderExt, MetadataExt, OpenOptionsExt}, process::CommandExt};

use crate::adi_worker_framing::{read_frame, write_frame};
use crate::adi_worker_lifecycle::{verify_worker_executable, worker_file_identity};
use crate::adi_worker_wire_v2::{self as wire, Headers};
use crate::provisioning::{NativeSessionTransport, ProtocolError};

/// The fixed, account-independent ds_id AuthKit uses for machine provisioning.
const DS_ID: &str = "-2";
/// `X-Apple-I-MD-RINFO`, as every v3 server reports it.
const ROUTING_INFO: &str = "17106176";
/// Upper bound on a client's `adi.pb` (and on any provisioning material).
pub const MAX_STATE_BYTES: usize = 16 * 1024;
const HEADERS_DEADLINE: Duration = Duration::from_secs(15);
/// Start to Finish includes the client's round trip to Apple.
const SESSION_DEADLINE: Duration = Duration::from_secs(120);
const CHECK_DEADLINE: Duration = Duration::from_secs(30);
const LIBRARIES: [&str; 2] = ["libstoreservicescore.so", "libCoreADI.so"];
/// The Windows CoreADI library, from iTunes for Windows (x64).
const WINDOWS_LIBRARY: &str = "CoreADI64.dll";
/// A fixed identifier for the readiness check's empty, discarded state.
const CHECK_IDENTIFIER: &str = "00010203-0405-06";
const WINDOWS_CHECK_IDENTIFIER: &str = "000102030405060708090a0b0c0d0e0f";

/// Which CoreADI the worker loads. Each has its own runtime layout, worker
/// identity and client identity; a configuration never mixes the two.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NativePlatform {
    /// Apple Music for Android: `<runtime>/lib/x86_64/{libstoreservicescore,libCoreADI}.so`.
    Android,
    /// iTunes for Windows: `<runtime>/CoreADI64.dll`, run by the Windows worker.
    Windows,
}

impl NativePlatform {
    pub fn name(self) -> &'static str {
        match self { NativePlatform::Android => "android", NativePlatform::Windows => "windows" }
    }

    /// The platform field (`<model> <platform;version;build> <...>`) a client
    /// identity must carry for this ADI: Apple compares the two.
    pub fn client_platform(self) -> &'static str {
        match self { NativePlatform::Android => "Android", NativePlatform::Windows => "Windows" }
    }

    /// Whether the served client metadata describes a client of this ADI.
    /// Windows: iTunes' AuthKitWin identity, `<PC> <Windows;...> <com.apple.AuthKitWin/N (...)>`.
    pub fn accepts(self, metadata: &crate::client_info_config::ClientMetadata) -> bool {
        if metadata.platform() != self.client_platform() { return false; }
        match self {
            NativePlatform::Android => true,
            NativePlatform::Windows => metadata.client_info.starts_with("<PC> <Windows;")
                && metadata.client_info.contains("> <com.apple.AuthKitWin/"),
        }
    }

    /// The identity argument of a worker for a client identifier. Android:
    /// the CoreADI Android identifier. Windows: the identifier in lower-case
    /// hex, from which the worker derives its synthetic machine.
    fn worker_identity(self, identifier: &[u8; 16]) -> String {
        match self {
            NativePlatform::Android => android_identifier(identifier),
            NativePlatform::Windows => identifier.iter().map(|b| format!("{b:02x}")).collect(),
        }
    }

    fn check_identity(self) -> &'static str {
        match self { NativePlatform::Android => CHECK_IDENTIFIER, NativePlatform::Windows => WINDOWS_CHECK_IDENTIFIER }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendError {
    /// Configuration or host refused at startup.
    Config(&'static str),
    /// Every native worker slot is in use.
    Busy,
    /// The request (identifier, state or material) is malformed.
    InvalidInput,
    /// The worker could not be started, crashed, timed out or replied
    /// incorrectly. It has been killed and reaped.
    Worker,
}

impl BackendError {
    /// A fixed description, safe to log.
    pub fn reason(self) -> &'static str {
        match self {
            BackendError::Config(reason) => reason,
            BackendError::Busy => "all native workers are busy",
            BackendError::InvalidInput => "invalid request",
            BackendError::Worker => "native worker failed",
        }
    }
}

pub struct NativeConfig {
    pub platform: NativePlatform,
    pub worker: PathBuf,
    pub runtime: PathBuf,
    pub state_dir: PathBuf,
    pub max_workers: usize,
    /// Deadlines for one `/v3/get_headers` worker and one provisioning
    /// session (Start to Finish, including the client's Apple round trip).
    pub headers_deadline: Duration,
    pub session_deadline: Duration,
}

impl NativeConfig {
    /// `None` when the native backend is not configured (the server then
    /// stays offline-only, as before). A partial or invalid configuration is
    /// an error, never a silent fallback.
    pub fn from_env() -> Result<Option<Self>, &'static str> {
        let var = |name| std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from);
        let (worker, runtime, state_dir) = (
            var("ZAG_ANISETTE_NATIVE_WORKER"),
            var("ZAG_ANISETTE_NATIVE_RUNTIME"),
            var("ZAG_ANISETTE_STATE_DIR"),
        );
        // Unset keeps the original Android backend; Windows is always explicit.
        let platform = match std::env::var("ZAG_ANISETTE_NATIVE_PLATFORM").as_deref() {
            Err(_) | Ok("android") => NativePlatform::Android,
            Ok("windows") => NativePlatform::Windows,
            Ok(_) => return Err("ZAG_ANISETTE_NATIVE_PLATFORM must be android or windows"),
        };
        let max_workers = match std::env::var("ZAG_ANISETTE_MAX_NATIVE_WORKERS") {
            Err(_) => 4,
            Ok(text) => match text.parse::<usize>() {
                Ok(n) if (1..=16).contains(&n) => n,
                _ => return Err("ZAG_ANISETTE_MAX_NATIVE_WORKERS must be 1 to 16"),
            },
        };
        match (worker, runtime, state_dir) {
            (None, None, None) => Ok(None),
            (Some(worker), Some(runtime), Some(state_dir)) => Ok(Some(Self {
                platform, worker, runtime, state_dir, max_workers,
                headers_deadline: HEADERS_DEADLINE, session_deadline: SESSION_DEADLINE,
            })),
            _ => Err("ZAG_ANISETTE_NATIVE_WORKER, ZAG_ANISETTE_NATIVE_RUNTIME and ZAG_ANISETTE_STATE_DIR must be set together"),
        }
    }
}

pub struct NativeBackend {
    config: NativeConfig,
    work: PathBuf,
    active: AtomicUsize,
    ready: AtomicBool,
}

/// A held worker slot; released on drop.
pub struct Permit<'a>(&'a AtomicUsize);
impl Drop for Permit<'_> {
    fn drop(&mut self) { self.0.fetch_sub(1, Ordering::AcqRel); }
}

impl NativeBackend {
    /// Validates the configuration, recovers the work area and runs the
    /// native readiness check. No Apple contact, no provisioning.
    pub fn open(config: NativeConfig) -> Result<Self, BackendError> {
        verify_worker_executable(&config.worker, &config.worker)
            .map_err(|_| BackendError::Config("native worker is not an approved executable"))?;
        check_runtime(config.platform, &config.runtime)?;
        check_private_dir(&config.state_dir)?;
        let work = config.state_dir.join("work");
        match fs::symlink_metadata(&work) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                fs::DirBuilder::new().mode(0o700).create(&work)
                    .map_err(|_| BackendError::Config("cannot create the work directory"))?;
            }
            _ => check_private_dir(&work)?,
        }
        recover_work(&work)?;
        let backend = Self { config, work, active: AtomicUsize::new(0), ready: AtomicBool::new(false) };
        backend.readiness_check()?;
        backend.ready.store(true, Ordering::Release);
        Ok(backend)
    }

    pub fn ready(&self) -> bool { self.ready.load(Ordering::Acquire) }
    pub fn platform(&self) -> NativePlatform { self.config.platform }
    pub fn max_workers(&self) -> usize { self.config.max_workers }
    pub fn active_workers(&self) -> usize { self.active.load(Ordering::Acquire) }

    pub fn permit(&self) -> Result<Permit<'_>, BackendError> {
        let mut current = self.active.load(Ordering::Acquire);
        loop {
            if current >= self.config.max_workers { return Err(BackendError::Busy); }
            match self.active.compare_exchange(current, current + 1, Ordering::AcqRel, Ordering::Acquire) {
                Ok(_) => return Ok(Permit(&self.active)),
                Err(actual) => current = actual,
            }
        }
    }

    /// Real CoreADI, an empty private state: the libraries must load and
    /// report NOT_PROVISIONED (-45061) and refuse an OTP.
    fn readiness_check(&self) -> Result<(), BackendError> {
        let dir = WorkDir::create(&self.work).map_err(|_| BackendError::Config("cannot create a work directory"))?;
        let mut worker = Worker::spawn(&self.config, "--native-offline-check", dir.path(), self.config.platform.check_identity(), CHECK_DEADLINE)
            .map_err(|_| BackendError::Config("native worker could not be started"))?;
        let output = worker.read_to_end(4096);
        let exited = worker.wait_success();
        let passed = output.is_ok_and(|text| String::from_utf8_lossy(&text).lines()
            .any(|line| line.starts_with("PASS: empty state reports NOT_PROVISIONED")));
        if exited && passed { Ok(()) } else { Err(BackendError::Config("native readiness check failed")) }
    }

    /// `/v3/get_headers`: one OTP for the client's own state.
    pub fn headers(&self, identifier: &[u8; 16], adi_pb: &[u8]) -> Result<Headers, BackendError> {
        if adi_pb.is_empty() || adi_pb.len() > MAX_STATE_BYTES { return Err(BackendError::InvalidInput); }
        let _permit = self.permit()?;
        let dir = WorkDir::create(&self.work).map_err(|_| BackendError::Worker)?;
        write_private(&dir.path().join("adi.pb"), adi_pb).map_err(|_| BackendError::Worker)?;
        let mut worker = Worker::spawn(&self.config, "--native-headers", dir.path(),
            &self.config.platform.worker_identity(identifier), self.config.headers_deadline)
            .map_err(|_| BackendError::Worker)?;
        let frame = worker.receive().map_err(|_| BackendError::Worker)?;
        let reply = wire::decode_headers(&frame).map_err(|_| BackendError::Worker)?;
        if !worker.wait_success() { return Err(BackendError::Worker); }
        Ok(reply)
    }

    /// A transport for one provisioning WebSocket session.
    pub fn session(&self) -> NativeTransport<'_> {
        NativeTransport { backend: self, worker: None, dir: None }
    }
}

/// The CoreADI Android identifier for a client identifier: the upper-cased
/// UUID text of the 16 bytes, first 16 characters (anisette-v3-server; the
/// coordinator's `android_identifier` from the device ID gives the same).
pub fn android_identifier(identifier: &[u8; 16]) -> String {
    let hex: String = identifier.iter().map(|b| format!("{b:02X}")).collect();
    format!("{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..14])
}

/// The response body for `/v3/get_headers`, as the client decodes it.
/// A state Apple never provisioned carries "-45061", which the client
/// turns into `IncorrectlyProvisioned` and re-provisions.
pub fn headers_response(result: Result<Headers, BackendError>) -> (&'static str, String) {
    let error = |message: &str| serde_json::json!({"result": "GetHeadersError", "message": message}).to_string();
    match result {
        Ok(Headers::Ready { machine_id, otp }) => ("200 OK", serde_json::json!({
            "result": "Headers",
            "X-Apple-I-MD": base64_encode(&otp),
            "X-Apple-I-MD-M": base64_encode(&machine_id),
            "X-Apple-I-MD-RINFO": ROUTING_INFO,
        }).to_string()),
        Ok(Headers::NotProvisioned) => ("200 OK", error("ADI error -45061: not provisioned")),
        Ok(Headers::NativeFailure) => ("200 OK", error("native ADI rejected the state")),
        Err(BackendError::InvalidInput) => ("200 OK", error("invalid identifier or adi_pb")),
        Err(BackendError::Busy) => ("503 Service Unavailable", r#"{"error":"busy"}"#.into()),
        Err(_) => ("503 Service Unavailable", r#"{"error":"native_worker_failed"}"#.into()),
    }
}

/// Parses a `/v3/get_headers` body: `identifier` (16 bytes) and `adi_pb`,
/// both standard base64. The resync fields the client adds (`sim`,
/// `device_id`, `md_lu`) are accepted and ignored, as anisette-v3-server
/// does; no other field is allowed.
pub fn parse_headers_request(body: &[u8]) -> Result<([u8; 16], Vec<u8>), BackendError> {
    let value: serde_json::Value = serde_json::from_slice(body).map_err(|_| BackendError::InvalidInput)?;
    let object = value.as_object().ok_or(BackendError::InvalidInput)?;
    if !object.keys().all(|k| matches!(k.as_str(), "identifier" | "adi_pb" | "sim" | "device_id" | "md_lu"))
        || !object.values().all(serde_json::Value::is_string) {
        return Err(BackendError::InvalidInput);
    }
    let text = |key: &str| object.get(key).and_then(serde_json::Value::as_str).ok_or(BackendError::InvalidInput);
    let identifier = parse_identifier(text("identifier")?)?;
    let adi_pb = base64_decode(text("adi_pb")?, MAX_STATE_BYTES).ok_or(BackendError::InvalidInput)?;
    Ok((identifier, adi_pb))
}

pub fn parse_identifier(text: &str) -> Result<[u8; 16], BackendError> {
    base64_decode(text, 16).and_then(|bytes| bytes.try_into().ok()).ok_or(BackendError::InvalidInput)
}

/// One provisioning exchange. The worker starts at Start, in a fresh empty
/// work directory, and the same process performs Finish; dropping or
/// aborting kills it and removes the directory.
pub struct NativeTransport<'a> {
    backend: &'a NativeBackend,
    worker: Option<Worker>,
    dir: Option<WorkDir>,
}

impl NativeTransport<'_> {
    fn exchange(&mut self, request: &wire::Request) -> Result<wire::Response, ProtocolError> {
        let worker = self.worker.as_mut().ok_or(ProtocolError::BackendUnavailable)?;
        let payload = wire::encode_request(request).map_err(|_| ProtocolError::InvalidField)?;
        worker.send(&payload).map_err(|_| ProtocolError::BackendUnavailable)?;
        let frame = worker.receive().map_err(|_| ProtocolError::BackendUnavailable)?;
        wire::decode_response(&frame, request).map_err(|_| ProtocolError::BackendUnavailable)
    }
}

impl NativeSessionTransport for NativeTransport<'_> {
    fn start(&mut self, identifier: &str, spim: &str) -> Result<String, ProtocolError> {
        if self.worker.is_some() { return Err(ProtocolError::InvalidTransition); }
        let identifier = parse_identifier(identifier).map_err(|_| ProtocolError::InvalidField)?;
        let spim = base64_decode(spim, MAX_STATE_BYTES).ok_or(ProtocolError::InvalidField)?;
        let dir = WorkDir::create(&self.backend.work).map_err(|_| ProtocolError::BackendUnavailable)?;
        let worker = Worker::spawn(&self.backend.config, "--native-v2-session", dir.path(),
            &self.backend.config.platform.worker_identity(&identifier), self.backend.config.session_deadline)
            .map_err(|_| ProtocolError::BackendUnavailable)?;
        self.dir = Some(dir);
        self.worker = Some(worker);
        match self.exchange(&wire::Request::Start { identifier: DS_ID.into(), spim })? {
            wire::Response::Started(cpim) => Ok(base64_encode(&cpim)),
            _ => Err(ProtocolError::BackendUnavailable),
        }
    }

    fn finish(&mut self, ptm: &str, tk: &str) -> Result<String, ProtocolError> {
        let ptm = base64_decode(ptm, MAX_STATE_BYTES).ok_or(ProtocolError::InvalidField)?;
        let tk = base64_decode(tk, MAX_STATE_BYTES).ok_or(ProtocolError::InvalidField)?;
        let adi_pb = match self.exchange(&wire::Request::Finish { ptm, tk })? {
            wire::Response::Finished(adi_pb) => adi_pb,
            _ => return Err(ProtocolError::BackendUnavailable),
        };
        let worker = self.worker.as_mut().ok_or(ProtocolError::BackendUnavailable)?;
        if !worker.wait_success() { return Err(ProtocolError::BackendUnavailable); }
        // The reply must be exactly the state CoreADI wrote for this session.
        let dir = self.dir.as_ref().ok_or(ProtocolError::BackendUnavailable)?;
        let stored = read_private(&dir.path().join("adi.pb")).map_err(|_| ProtocolError::BackendUnavailable)?;
        if stored != adi_pb { return Err(ProtocolError::BackendUnavailable); }
        Ok(base64_encode(&adi_pb))
    }

    fn abort(&mut self) {
        self.worker.take();
        self.dir.take();
    }
}

/// One supervised native worker process. Its own process group, a cleared
/// environment, `/` as working directory, stderr discarded, and (on Linux)
/// SIGKILL if the server dies. Every exit path kills the group and reaps.
struct Worker {
    child: Child,
    stdin: Option<ChildStdin>,
    frames: mpsc::Receiver<Option<Vec<u8>>>,
    stdout: Option<std::process::ChildStdout>,
    deadline: Instant,
    reaped: bool,
}

impl Worker {
    fn spawn(config: &NativeConfig, mode: &str, dir: &Path, android_id: &str, limit: Duration) -> io::Result<Self> {
        let refused = || io::Error::new(io::ErrorKind::PermissionDenied, "worker refused");
        verify_worker_executable(&config.worker, &config.worker).map_err(|_| refused())?;
        let identity = worker_file_identity(&config.worker).map_err(|_| refused())?;
        let mut command = Command::new(&config.worker);
        command.arg(&config.runtime).arg(mode).arg(dir).arg(android_id)
            .env_clear().current_dir("/")
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null())
            .process_group(0);
        #[cfg(target_os = "linux")]
        {
            let server = unsafe { libc::getpid() };
            unsafe {
                command.pre_exec(move || {
                    if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 { return Err(io::Error::last_os_error()); }
                    if libc::getppid() != server { return Err(io::Error::other("server exited")); }
                    Ok(())
                });
            }
        }
        if worker_file_identity(&config.worker).map_err(|_| refused())? != identity { return Err(refused()); }
        let mut child = command.spawn()?;
        let stdin = child.stdin.take();
        let stdout = child.stdout.take();
        let (sender, frames) = mpsc::channel();
        let mut worker = Self { child, stdin, frames, stdout, deadline: Instant::now() + limit, reaped: false };
        // Frame mode starts a reader; read_to_end takes stdout instead.
        if mode != "--native-offline-check" {
            let mut stdout = worker.stdout.take().ok_or_else(refused)?;
            thread::spawn(move || loop {
                let frame = read_frame(&mut stdout).ok();
                let end = frame.is_none();
                if sender.send(frame).is_err() || end { break; }
            });
        }
        Ok(worker)
    }

    fn left(&self) -> io::Result<Duration> {
        let left = self.deadline.saturating_duration_since(Instant::now());
        if left.is_zero() { Err(io::ErrorKind::TimedOut.into()) } else { Ok(left) }
    }

    fn send(&mut self, payload: &[u8]) -> io::Result<()> {
        self.left()?;
        // Frames are far below the pipe buffer, so this write cannot block
        // on a worker that stopped reading.
        let stdin = self.stdin.as_mut().ok_or(io::ErrorKind::BrokenPipe)?;
        write_frame(stdin, payload).map_err(|_| io::Error::from(io::ErrorKind::BrokenPipe))
    }

    fn receive(&mut self) -> io::Result<Vec<u8>> {
        match self.frames.recv_timeout(self.left()?) {
            Ok(Some(frame)) => Ok(frame),
            Ok(None) | Err(mpsc::RecvTimeoutError::Disconnected) => Err(io::ErrorKind::UnexpectedEof.into()),
            Err(mpsc::RecvTimeoutError::Timeout) => Err(io::ErrorKind::TimedOut.into()),
        }
    }

    /// Unframed, bounded output (the readiness check only), within the deadline.
    fn read_to_end(&mut self, limit: usize) -> io::Result<Vec<u8>> {
        let mut stdout = self.stdout.take().ok_or(io::ErrorKind::BrokenPipe)?;
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let mut bytes = Vec::new();
            let result = (&mut stdout).take(limit as u64).read_to_end(&mut bytes).map(|_| bytes);
            let _ = sender.send(result);
        });
        receiver.recv_timeout(self.left()?).map_err(|_| io::Error::from(io::ErrorKind::TimedOut))?
    }

    /// Closes stdin and waits, within the deadline, for exit status 0.
    fn wait_success(&mut self) -> bool {
        self.stdin.take();
        while Instant::now() < self.deadline {
            if exited_unreaped(self.child.id()) {
                self.reap();
                return matches!(self.child.try_wait(), Ok(Some(status)) if status.success());
            }
            thread::sleep(Duration::from_millis(5));
        }
        false
    }

    /// Kills the group while the leader is unreaped (so the group ID cannot
    /// have been reused), then reaps the leader.
    fn reap(&mut self) {
        if self.reaped { return; }
        if let Ok(pid) = i32::try_from(self.child.id()) {
            unsafe { libc::kill(-pid, libc::SIGKILL); }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        self.reaped = true;
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        self.stdin.take();
        self.reap();
    }
}

/// Whether the child has exited, without reaping it.
fn exited_unreaped(pid: u32) -> bool {
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    let status = unsafe {
        libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOHANG | libc::WNOWAIT)
    };
    #[cfg(target_os = "linux")]
    let pid = unsafe { info.si_pid() };
    #[cfg(not(target_os = "linux"))]
    let pid = info.si_pid;
    status == 0 && pid != 0
}

/// A private, uniquely named directory under the work area, removed on drop.
struct WorkDir(PathBuf);
impl WorkDir {
    fn create(work: &Path) -> io::Result<Self> {
        let mut random = [0u8; 16];
        fs::File::open("/dev/urandom")?.read_exact(&mut random)?;
        let name: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let path = work.join(name);
        fs::DirBuilder::new().mode(0o700).create(&path)?;
        Ok(Self(path))
    }
    fn path(&self) -> &Path { &self.0 }
}
impl Drop for WorkDir {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
}

fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o600)
        .custom_flags(libc::O_NOFOLLOW).open(path)?;
    file.write_all(bytes)
}

fn read_private(path: &Path) -> io::Result<Vec<u8>> {
    let file = fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_STATE_BYTES as u64 {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut bytes = Vec::new();
    file.take(MAX_STATE_BYTES as u64).read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// Owned by this user, a real directory, owner-only.
fn check_private_dir(path: &Path) -> Result<(), BackendError> {
    let refused = BackendError::Config("state directory must be absolute, private (0700) and owned by the service user");
    if !path.is_absolute() { return Err(refused); }
    let metadata = fs::symlink_metadata(path).map_err(|_| refused)?;
    if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o077 != 0 {
        return Err(refused);
    }
    Ok(())
}

/// The platform's libraries: regular files, not links, writable by nobody
/// but their owner (root, outside test builds), as is their directory.
/// Android: the two Apple Music libraries; Windows: CoreADI64.dll.
fn check_runtime(platform: NativePlatform, runtime: &Path) -> Result<(), BackendError> {
    let refused = BackendError::Config("native runtime libraries are missing or not protected");
    if !runtime.is_absolute() { return Err(refused); }
    let protected = |path: &Path, directory: bool| fs::symlink_metadata(path).is_ok_and(|m|
        (if directory { m.is_dir() } else { m.is_file() })
        && m.mode() & 0o022 == 0
        && (cfg!(test) || m.uid() == 0));
    let ok = match platform {
        NativePlatform::Android => {
            let dir = runtime.join("lib").join("x86_64");
            protected(&dir, true) && LIBRARIES.iter().all(|name| protected(&dir.join(name), false))
        }
        NativePlatform::Windows => protected(runtime, true) && protected(&runtime.join(WINDOWS_LIBRARY), false),
    };
    if !ok { return Err(refused); }
    Ok(())
}

/// Removes what interrupted requests left in the work area. Only private
/// directories this user owns are removed; anything else stops startup.
fn recover_work(work: &Path) -> Result<(), BackendError> {
    let refused = BackendError::Config("work directory holds an entry that is not a private directory");
    for entry in fs::read_dir(work).map_err(|_| refused)? {
        let path = entry.map_err(|_| refused)?.path();
        let metadata = fs::symlink_metadata(&path).map_err(|_| refused)?;
        if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } {
            return Err(refused);
        }
        fs::remove_dir_all(&path).map_err(|_| refused)?;
    }
    Ok(())
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 with padding.
pub fn base64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() { out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char); } else { out.push('='); }
        }
    }
    out
}

/// Strict, canonical standard base64 (padding required, no whitespace);
/// at most `max` decoded bytes and never empty.
pub fn base64_decode(text: &str, max: usize) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if bytes.is_empty() || bytes.len() % 4 != 0 || bytes.len() / 4 * 3 > max + 2 { return None; }
    let value = |b: u8| ALPHABET.iter().position(|&a| a == b).map(|v| v as u32);
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let chunks = bytes.len() / 4;
    for (index, chunk) in bytes.chunks(4).enumerate() {
        let pad = chunk.iter().rev().take_while(|&&b| b == b'=').count();
        if pad > 2 || (pad > 0 && index + 1 != chunks) { return None; }
        let mut n = 0u32;
        for &b in &chunk[..4 - pad] { n = n << 6 | value(b)?; }
        n <<= 6 * pad as u32;
        // Canonical: the bits dropped by padding must be zero.
        if (pad == 1 && n & 0xff != 0) || (pad == 2 && n & 0xffff != 0) { return None; }
        out.push((n >> 16) as u8);
        if pad < 2 { out.push((n >> 8) as u8); }
        if pad < 1 { out.push(n as u8); }
    }
    if out.is_empty() || out.len() > max { return None; }
    Some(out)
}

#[cfg(test)]
#[path = "native_backend_tests.rs"]
mod tests;
