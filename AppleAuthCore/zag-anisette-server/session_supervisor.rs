//! Offline-only two-phase child supervisor prototype.
//! NOT approved for production: test-only caller-selected executable and mock framing
//! deliberately differ from the reviewed one-shot worker security contract.
//! No network integration, native libraries, or Apple provisioning.
#![allow(dead_code)]
use std::{
    io::Write,
    path::Path,
    process::{Command, Stdio},
    sync::{mpsc, atomic::{AtomicBool, AtomicUsize, Ordering}},
    thread,
    time::{Duration, Instant},
};
#[cfg(unix)]
use std::os::unix::process::CommandExt;

#[derive(Debug, PartialEq, Eq)]
pub enum SessionError { InvalidTimeout, Spawn, Busy, Transport, Timeout, Cancelled, InvalidResponse, NonZeroExit }

#[cfg(unix)]
unsafe extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
#[cfg(unix)]
fn kill_group(pid: u32) {
    if let Ok(pid) = i32::try_from(pid) {
        if pid > 0 { unsafe { kill(-pid, 9); } }
    }
}

/// Offline-only admission limiter. Test-local instances permit deterministic
/// saturation tests without competing with Rust's parallel test runner.
struct SessionLimiter {
    active: AtomicUsize,
    maximum: usize,
}
impl SessionLimiter {
    const fn new(maximum: usize) -> Self {
        Self { active: AtomicUsize::new(0), maximum }
    }
    fn acquire(&self) -> Result<SessionPermit<'_>, SessionError> {
        self.active.try_update(Ordering::AcqRel, Ordering::Acquire,
            |active| (active < self.maximum).then_some(active + 1))
            .map_err(|_| SessionError::Busy)?;
        Ok(SessionPermit(self))
    }
}
static MOCK_SESSION_LIMITER: SessionLimiter = SessionLimiter::new(32);
struct SessionPermit<'a>(&'a SessionLimiter);
impl Drop for SessionPermit<'_> {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Shared child cleanup for both the supervised v1 harness and offline v2 tests.
/// Kill the process group before reaping to avoid leaving descendants running.
fn terminate_and_reap(child: &mut std::process::Child) {
    #[cfg(unix)]
    kill_group(child.id());
    let _ = child.kill();
    let _ = child.wait();
}

fn remaining(deadline: Instant) -> Result<Duration, SessionError> {
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() { Err(SessionError::Timeout) } else { Ok(left) }
}
fn receive<T>(rx: &mpsc::Receiver<T>, deadline: Instant, cancel: &AtomicBool) -> Result<T, SessionError> {
    loop {
        if cancel.load(Ordering::Acquire) { return Err(SessionError::Cancelled); }
        let wait = remaining(deadline)?.min(Duration::from_millis(20));
        match rx.recv_timeout(wait) {
            Ok(value) => return Ok(value),
            Err(mpsc::RecvTimeoutError::Disconnected) => return Err(SessionError::Transport),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
}

/// Reuse the canonical worker protocol rather than a second permissive schema.
fn valid_phase_reply(value: &serde_json::Value, phase: &str) -> bool {
    use crate::adi_worker_protocol::{decode_response, WorkerRequest, WorkerResponse};
    let request = match phase {
        "started" => WorkerRequest::Start { identifier: "mock".into(), spim: "mock".into() },
        "finished" => WorkerRequest::Finish { ptm: "mock".into(), tk: "mock".into() },
        _ => return false,
    };
    let Ok(bytes) = serde_json::to_vec(value) else { return false };
    matches!(
        decode_response(&bytes, &request),
        Ok(WorkerResponse::Started { .. }) if phase == "started"
    ) || matches!(
        decode_response(&bytes, &request),
        Ok(WorkerResponse::Finished { .. }) if phase == "finished"
    )
}

/// Offline-only v2 framing validation at the supervisor boundary.
/// Deliberately does not spawn a worker or activate native provisioning.
#[cfg(test)]
fn validate_v2_exchange(
    start: &crate::adi_worker_wire_v2::Request,
    started: &[u8],
    finish: &crate::adi_worker_wire_v2::Request,
    finished: &[u8],
) -> Result<(), SessionError> {
    use crate::adi_worker_wire_v2::{decode_request, decode_response, encode_request, Response, Request};
    if !matches!(start, Request::Start { .. }) || !matches!(finish, Request::Finish { .. }) {
        return Err(SessionError::InvalidResponse);
    }
    for request in [start, finish] {
        let payload = encode_request(request).map_err(|_| SessionError::InvalidResponse)?;
        let mut frame = Vec::new();
        crate::adi_worker_framing::write_frame(&mut frame, &payload)
            .map_err(|_| SessionError::InvalidResponse)?;
        let roundtrip = crate::adi_worker_framing::read_frame(&mut frame.as_slice())
            .map_err(|_| SessionError::InvalidResponse)?;
        if decode_request(&roundtrip).map_err(|_| SessionError::InvalidResponse)? != *request {
            return Err(SessionError::InvalidResponse);
        }
    }
    if !matches!(decode_response(started, start), Ok(Response::Started(_)))
        || !matches!(decode_response(finished, finish), Ok(Response::Finished(_))) {
        return Err(SessionError::InvalidResponse);
    }
    Ok(())
}

#[cfg(test)]
mod v2_boundary_tests {
    use super::*;
    use crate::adi_worker_wire_v2::{encode_response, Request, Response};
    #[test]
    fn v2_child_process_exchanges_binary_frames() {
        let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/session_worker_fixture.rs");
        let temp = std::env::temp_dir().join(format!("zag-v2-fixture-{}-{:?}", std::process::id(), std::thread::current().id()));
        std::fs::create_dir_all(&temp).unwrap();
        let executable = temp.join("v2-worker-fixture");
        assert!(Command::new("rustc").args(["--edition=2021", "-o"]).arg(&executable).arg(&source).status().unwrap().success());
        let start = Request::Start { identifier: "-2".into(), spim: vec![0, 255] };
        let finish = Request::Finish { ptm: vec![255, 0], tk: vec![128] };
        let cancel = AtomicBool::new(false);
        let result = run_v2_session_cancellable(
            &std::fs::canonicalize(&executable).unwrap(), &["--v2"],
            &start, &finish, Duration::from_secs(5), &cancel,
        );
        let _ = std::fs::remove_file(&executable);
        let _ = std::fs::remove_dir(&temp);
        let (started, finished) = result.expect("supervised v2 exchange must complete");
        assert_eq!(validate_v2_exchange(&start, &started, &finish, &finished), Ok(()));
    }

    #[test]
    fn v2_duplicate_response_fields_from_child_are_rejected() {
        use std::io::Write;
        let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/session_worker_fixture.rs");
        let temp = std::env::temp_dir().join(format!("zag-v2-duplicate-{}-{:?}", std::process::id(), std::thread::current().id()));
        std::fs::create_dir_all(&temp).unwrap();
        let executable = temp.join("v2-duplicate-fixture");
        assert!(Command::new("rustc").args(["--edition=2021", "-o"]).arg(&executable).arg(&source).status().unwrap().success());
        let mut child = Command::new(std::fs::canonicalize(&executable).unwrap())
            .arg("--v2-duplicate").env_clear().stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null())
            .spawn().unwrap();
        let start = Request::Start { identifier: "-2".into(), spim: vec![0, 255] };
        let mut frame = Vec::new();
        crate::adi_worker_framing::write_frame(&mut frame, &crate::adi_worker_wire_v2::encode_request(&start).unwrap()).unwrap();
        child.stdin.take().unwrap().write_all(&frame).unwrap();
        let reply = crate::adi_worker_framing::read_frame(&mut child.stdout.take().unwrap()).unwrap();
        assert!(crate::adi_worker_wire_v2::decode_response(&reply, &start).is_err());
        assert!(child.wait().unwrap().success());
        let _ = std::fs::remove_file(&executable);
        let _ = std::fs::remove_dir(&temp);
    }

    #[test]
    fn v2_wrong_phase_reply_from_child_is_rejected() {
        use std::io::Write;
        let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/session_worker_fixture.rs");
        let temp = std::env::temp_dir().join(format!("zag-v2-phase-{}-{:?}", std::process::id(), std::thread::current().id()));
        std::fs::create_dir_all(&temp).unwrap();
        let executable = temp.join("v2-phase-fixture");
        assert!(Command::new("rustc").args(["--edition=2021", "-o"]).arg(&executable).arg(&source).status().unwrap().success());
        let mut child = Command::new(std::fs::canonicalize(&executable).unwrap())
            .arg("--v2-wrong-phase").env_clear().stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null())
            .spawn().unwrap();
        let start = Request::Start { identifier: "-2".into(), spim: vec![0, 255] };
        let mut frame = Vec::new();
        crate::adi_worker_framing::write_frame(&mut frame, &crate::adi_worker_wire_v2::encode_request(&start).unwrap()).unwrap();
        child.stdin.take().unwrap().write_all(&frame).unwrap();
        let reply = crate::adi_worker_framing::read_frame(&mut child.stdout.take().unwrap()).unwrap();
        assert!(crate::adi_worker_wire_v2::decode_response(&reply, &start).is_err());
        assert!(child.wait().unwrap().success());
        let _ = std::fs::remove_file(&executable);
        let _ = std::fs::remove_dir(&temp);
    }

    #[test]
    fn stalled_v2_child_is_killed_and_reaped_at_deadline() {
        use std::io::Write;
        let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/session_worker_fixture.rs");
        let temp = std::env::temp_dir().join(format!("zag-v2-stall-{}-{:?}", std::process::id(), std::thread::current().id()));
        std::fs::create_dir_all(&temp).unwrap();
        let executable = temp.join("v2-stall-fixture");
        assert!(Command::new("rustc").args(["--edition=2021", "-o"]).arg(&executable).arg(&source).status().unwrap().success());
        let mut command = Command::new(std::fs::canonicalize(&executable).unwrap());
        command.arg("--v2-stall").env_clear().stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null());
        #[cfg(unix)]
        command.process_group(0);
        let mut child = command.spawn().unwrap();
        let mut frame = Vec::new();
        let request = crate::adi_worker_wire_v2::Request::Start { identifier: "-2".into(), spim: vec![0, 255] };
        crate::adi_worker_framing::write_frame(&mut frame, &crate::adi_worker_wire_v2::encode_request(&request).unwrap()).unwrap();
        child.stdin.take().unwrap().write_all(&frame).unwrap();
        let deadline = Instant::now() + Duration::from_millis(150);
        let timed_out = loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(!status.success(), "stalled worker must not report success");
                break false;
            }
            if Instant::now() >= deadline { break true; }
            thread::sleep(Duration::from_millis(5));
        };
        terminate_and_reap(&mut child);
        let _ = std::fs::remove_file(&executable);
        let _ = std::fs::remove_dir(&temp);
        assert!(timed_out, "stalled child must reach the deadline before cleanup");
    }

    #[test]
    fn v2_binary_exchange_uses_bounded_frames_and_correct_phases() {
        let start = Request::Start { identifier: "-2".into(), spim: vec![0, 255, 128] };
        let finish = Request::Finish { ptm: vec![0, 1], tk: vec![255, 0] };
        let started = encode_response(&Response::Started(vec![0, 255])).unwrap();
        let finished = encode_response(&Response::Finished(vec![255, 0])).unwrap();
        assert_eq!(validate_v2_exchange(&start, &started, &finish, &finished), Ok(()));
        assert_eq!(validate_v2_exchange(&start, &finished, &finish, &started), Err(SessionError::InvalidResponse));
        assert_eq!(validate_v2_exchange(&finish, &started, &start, &finished), Err(SessionError::InvalidResponse));
    }
}

/// Offline test-only v2 supervisor. The executable is caller-selected and therefore
/// this is NOT an approved production launch path.
#[cfg(test)]
fn run_v2_session_cancellable(
    executable: &Path,
    args: &[&str],
    start: &crate::adi_worker_wire_v2::Request,
    finish: &crate::adi_worker_wire_v2::Request,
    timeout: Duration,
    cancel: &AtomicBool,
) -> Result<(Vec<u8>, Vec<u8>), SessionError> {
    use crate::adi_worker_wire_v2::{encode_request, decode_response, Request, Response};
    if cancel.load(Ordering::Acquire) { return Err(SessionError::Cancelled); }
    if timeout.is_zero() || timeout > Duration::from_secs(10) { return Err(SessionError::InvalidTimeout); }
    if !matches!(start, Request::Start { .. }) || !matches!(finish, Request::Finish { .. }) {
        return Err(SessionError::InvalidResponse);
    }
    let _permit = MOCK_SESSION_LIMITER.acquire()?;
    let frame = |request: &Request| -> Result<Vec<u8>, SessionError> {
        let payload = encode_request(request).map_err(|_| SessionError::InvalidResponse)?;
        let mut frame = Vec::new();
        crate::adi_worker_framing::write_frame(&mut frame, &payload)
            .map_err(|_| SessionError::InvalidResponse)?;
        Ok(frame)
    };
    let start_frame = frame(start)?;
    let finish_frame = frame(finish)?;
    crate::adi_worker_lifecycle::verify_worker_executable(executable, executable)
        .map_err(|_| SessionError::Spawn)?;
    #[cfg(unix)]
    let identity = crate::adi_worker_lifecycle::worker_file_identity(executable)
        .map_err(|_| SessionError::Spawn)?;
    let mut command = Command::new(executable);
    command.args(args).env_clear().current_dir("/")
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    #[cfg(unix)]
    command.process_group(0);
    crate::adi_worker_lifecycle::verify_worker_executable(executable, executable)
        .map_err(|_| SessionError::Spawn)?;
    #[cfg(unix)]
    if crate::adi_worker_lifecycle::worker_file_identity(executable)
        .map_err(|_| SessionError::Spawn)? != identity { return Err(SessionError::Spawn); }
    if cancel.load(Ordering::Acquire) { return Err(SessionError::Cancelled); }
    let mut child = command.spawn().map_err(|_| SessionError::Spawn)?;
    let (Some(mut stdin), Some(mut stdout)) = (child.stdin.take(), child.stdout.take()) else {
        terminate_and_reap(&mut child);
        return Err(SessionError::Transport);
    };
    let (write_tx, write_rx) = mpsc::channel();
    let (read_tx, read_rx) = mpsc::channel();
    let (command_tx, command_rx) = mpsc::channel::<Vec<u8>>();
    thread::spawn(move || {
        for payload in command_rx {
            let ok = stdin.write_all(&payload).and_then(|_| stdin.flush()).is_ok();
            if write_tx.send(ok).is_err() || !ok { break; }
        }
    });
    thread::spawn(move || {
        loop {
            let reply = crate::adi_worker_framing::read_frame(&mut stdout).ok();
            let terminal = reply.is_none();
            if read_tx.send(reply).is_err() || terminal { break; }
        }
    });
    let deadline = Instant::now() + timeout;
    let result = (|| {
        command_tx.send(start_frame).map_err(|_| SessionError::Transport)?;
        if !receive(&write_rx, deadline, cancel)? { return Err(SessionError::Transport); }
        let started = receive(&read_rx, deadline, cancel)?.ok_or(SessionError::InvalidResponse)?;
        if !matches!(decode_response(&started, start), Ok(Response::Started(_))) {
            return Err(SessionError::InvalidResponse);
        }
        command_tx.send(finish_frame).map_err(|_| SessionError::Transport)?;
        if !receive(&write_rx, deadline, cancel)? { return Err(SessionError::Transport); }
        drop(command_tx);
        let finished = receive(&read_rx, deadline, cancel)?.ok_or(SessionError::InvalidResponse)?;
        if !matches!(decode_response(&finished, finish), Ok(Response::Finished(_))) {
            return Err(SessionError::InvalidResponse);
        }
        if receive(&read_rx, deadline, cancel)?.is_some() { return Err(SessionError::InvalidResponse); }
        loop {
            if cancel.load(Ordering::Acquire) { return Err(SessionError::Cancelled); }
            remaining(deadline)?;
            match child.try_wait() {
                Ok(Some(status)) if status.success() => return Ok((started, finished)),
                Ok(Some(_)) => return Err(SessionError::NonZeroExit),
                Ok(None) => thread::sleep(Duration::from_millis(5)),
                Err(_) => return Err(SessionError::Transport),
            }
        }
    })();
    terminate_and_reap(&mut child);
    result
}

/// Runs exactly one mock Start and Finish in the SAME child process.
/// This function is a test harness, not a safe executable-launch API.
/// Each reply must be one bounded length-prefixed JSON frame.
pub fn run_mock_session(
    executable: &Path,
    args: &[&str],
    start: &str,
    finish: &str,
    timeout: Duration,
) -> Result<(serde_json::Value, serde_json::Value), SessionError> {
    let cancel = AtomicBool::new(false);
    run_mock_session_cancellable(executable, args, start, finish, timeout, &cancel)
}

/// Test-only cancellation signal, checked during every IPC wait and child exit.
pub fn run_mock_session_cancellable(
    executable: &Path,
    args: &[&str],
    start: &str,
    finish: &str,
    timeout: Duration,
    cancel: &AtomicBool,
) -> Result<(serde_json::Value, serde_json::Value), SessionError> {
    if cancel.load(Ordering::Acquire) { return Err(SessionError::Cancelled); }
    let _permit = MOCK_SESSION_LIMITER.acquire()?;
    if timeout.is_zero() || timeout > Duration::from_secs(10) {
        return Err(SessionError::InvalidTimeout);
    }
    if start.len() > 64 * 1024 || finish.len() > 64 * 1024 {
        return Err(SessionError::InvalidResponse);
    }
    crate::adi_worker_lifecycle::verify_worker_executable(executable, executable)
        .map_err(|_| SessionError::Spawn)?;
    #[cfg(unix)]
    let initial_identity = crate::adi_worker_lifecycle::worker_file_identity(executable)
        .map_err(|_| SessionError::Spawn)?;
    let start_frame = encode_session_frame(&serde_json::from_str::<serde_json::Value>(start)
        .map_err(|_| SessionError::InvalidResponse)?)
        .map_err(|_| SessionError::InvalidResponse)?;
    let finish_frame = encode_session_frame(&serde_json::from_str::<serde_json::Value>(finish)
        .map_err(|_| SessionError::InvalidResponse)?)
        .map_err(|_| SessionError::InvalidResponse)?;
    use crate::adi_worker_protocol::{decode_request, WorkerRequest};
    let start_request = decode_request(&start_frame[4..])
        .map_err(|_| SessionError::InvalidResponse)?;
    let finish_request = decode_request(&finish_frame[4..])
        .map_err(|_| SessionError::InvalidResponse)?;
    if !matches!(start_request, WorkerRequest::Start { .. })
        || !matches!(finish_request, WorkerRequest::Finish { .. }) {
        return Err(SessionError::InvalidResponse);
    }
    let deadline = Instant::now() + timeout;
    let mut cmd = Command::new(executable);
    cmd.args(args).env_clear().current_dir("/")
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    #[cfg(unix)]
    cmd.process_group(0);
    crate::adi_worker_lifecycle::verify_worker_executable(executable, executable)
        .map_err(|_| SessionError::Spawn)?;
    #[cfg(unix)]
    if crate::adi_worker_lifecycle::worker_file_identity(executable)
        .map_err(|_| SessionError::Spawn)? != initial_identity {
        return Err(SessionError::Spawn);
    }
    if cancel.load(Ordering::Acquire) { return Err(SessionError::Cancelled); }
    let mut child = cmd.spawn().map_err(|_| SessionError::Spawn)?;
    // Any early error after spawn must still terminate and reap the child.
    let (Some(mut stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        terminate_and_reap(&mut child);
        return Err(SessionError::Transport);
    };
    let (write_tx, write_rx) = mpsc::channel();
    let (read_tx, read_rx) = mpsc::channel();
    let (command_tx, command_rx) = mpsc::channel::<Vec<u8>>();
    thread::spawn(move || {
        for payload in command_rx {
            let result = stdin.write_all(&payload).and_then(|_| stdin.flush());
            if write_tx.send(result.is_ok()).is_err() { break; }
            if result.is_err() { break; }
        }
    });
    thread::spawn(move || {
        let mut reader = stdout;
        loop {
            let outcome = crate::adi_worker_framing::read_frame(&mut reader)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
            let terminal = outcome.is_none();
            if read_tx.send(outcome).is_err() || terminal { break; }
        }
    });
    let result = (|| {
        if cancel.load(Ordering::Acquire) { return Err(SessionError::Cancelled); }
        command_tx.send(start_frame).map_err(|_| SessionError::Transport)?;
        if !receive(&write_rx, deadline, cancel)? { return Err(SessionError::Transport); }
        let started = receive(&read_rx, deadline, cancel)?.ok_or(SessionError::InvalidResponse)?;
        let started_bytes = serde_json::to_vec(&started).map_err(|_| SessionError::InvalidResponse)?;
        if !matches!(crate::adi_worker_protocol::decode_response(&started_bytes, &start_request),
            Ok(crate::adi_worker_protocol::WorkerResponse::Started { .. })) {
            return Err(SessionError::InvalidResponse);
        }
        if !valid_phase_reply(&started, "started") {
            return Err(SessionError::InvalidResponse);
        }
        if cancel.load(Ordering::Acquire) { return Err(SessionError::Cancelled); }
        command_tx.send(finish_frame).map_err(|_| SessionError::Transport)?;
        if !receive(&write_rx, deadline, cancel)? { return Err(SessionError::Transport); }
        drop(command_tx);
        let finished = receive(&read_rx, deadline, cancel)?.ok_or(SessionError::InvalidResponse)?;
        let finished_bytes = serde_json::to_vec(&finished).map_err(|_| SessionError::InvalidResponse)?;
        if !matches!(crate::adi_worker_protocol::decode_response(&finished_bytes, &finish_request),
            Ok(crate::adi_worker_protocol::WorkerResponse::Finished { .. })) {
            return Err(SessionError::InvalidResponse);
        }
        if !valid_phase_reply(&finished, "finished") {
            return Err(SessionError::InvalidResponse);
        }
        // EOF is required after the terminal response; reject extra output.
        if receive(&read_rx, deadline, cancel)?.is_some() { return Err(SessionError::InvalidResponse); }
        while Instant::now() < deadline {
            if cancel.load(Ordering::Acquire) { return Err(SessionError::Cancelled); }
            match child.try_wait() {
                Ok(Some(status)) if status.success() => {
                    if cancel.load(Ordering::Acquire) { return Err(SessionError::Cancelled); }
                    return Ok((started, finished));
                },
                Ok(Some(_)) => return Err(SessionError::NonZeroExit),
                Ok(None) => thread::sleep(Duration::from_millis(5)),
                Err(_) => return Err(SessionError::Transport),
            }
        }
        Err(SessionError::Timeout)
    })();
    // Always terminate and reap the isolated process group, even after success.
    terminate_and_reap(&mut child);
    result
}


/// Strict two-phase framing used by the future production session transport.
/// Unlike the legacy mock line protocol, each message uses the existing
/// four-byte big-endian length prefix and the shared 64KiB wire limit.
#[derive(Debug, PartialEq, Eq)]
pub enum SessionFrameError { Framing, Json, WrongPhase }

pub fn encode_session_frame(value: &serde_json::Value) -> Result<Vec<u8>, SessionFrameError> {
    let bytes = serde_json::to_vec(value).map_err(|_| SessionFrameError::Json)?;
    let mut frame = Vec::new();
    crate::adi_worker_framing::write_frame(&mut frame, &bytes)
        .map_err(|_| SessionFrameError::Framing)?;
    Ok(frame)
}

pub fn decode_session_frame<R: std::io::Read>(
    reader: &mut R,
    expected_type: &str,
) -> Result<serde_json::Value, SessionFrameError> {
    let bytes = crate::adi_worker_framing::read_frame(reader)
        .map_err(|_| SessionFrameError::Framing)?;
    let value: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| SessionFrameError::Json)?;
    if value.as_object().and_then(|obj| obj.get("type"))
        .and_then(serde_json::Value::as_str) != Some(expected_type) {
        return Err(SessionFrameError::WrongPhase);
    }
    Ok(value)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn local_admission_limiter_rejects_excess_and_recovers() {
        let limiter = SessionLimiter::new(2);
        let first = limiter.acquire().unwrap();
        let second = limiter.acquire().unwrap();
        assert!(matches!(limiter.acquire(), Err(SessionError::Busy)));
        drop(first);
        let third = limiter.acquire().unwrap();
        assert!(matches!(limiter.acquire(), Err(SessionError::Busy)));
        drop(second);
        drop(third);
        assert_eq!(limiter.active.load(Ordering::Acquire), 0);
        assert!(limiter.acquire().is_ok());
    }
    #[test]
    fn strict_frames_roundtrip_in_phase_order() {
        let start = serde_json::json!({"type":"started","cpim":"mock"});
        let finish = serde_json::json!({"type":"finished","adi_pb":"mock"});
        let mut stream = encode_session_frame(&start).unwrap();
        stream.extend(encode_session_frame(&finish).unwrap());
        let mut input = stream.as_slice();
        assert_eq!(decode_session_frame(&mut input, "started"), Ok(start));
        assert_eq!(decode_session_frame(&mut input, "finished"), Ok(finish));
        assert!(input.is_empty());
    }
    #[test]
    fn strict_frames_reject_wrong_phase_and_invalid_header() {
        let finish = serde_json::json!({"type":"finished"});
        let frame = encode_session_frame(&finish).unwrap();
        assert_eq!(decode_session_frame(&mut frame.as_slice(), "started"), Err(SessionFrameError::WrongPhase));
        let oversized = ((crate::adi_worker_protocol::MAX_MESSAGE_BYTES + 1) as u32).to_be_bytes();
        assert_eq!(decode_session_frame(&mut oversized.as_slice(), "started"), Err(SessionFrameError::Framing));
        assert_eq!(decode_session_frame(&mut 0u32.to_be_bytes().as_slice(), "started"), Err(SessionFrameError::Framing));
    }
    #[test]
    fn rejects_unknown_fields_and_wrong_versions() {
        assert!(!valid_phase_reply(&serde_json::json!({"type":"started","unexpected":true}), "started"));
        assert!(!valid_phase_reply(&serde_json::json!({"type":"finished","version":2}), "finished"));
        assert!(!valid_phase_reply(&serde_json::json!({"type":"started","cpim":""}), "started"));
        assert!(valid_phase_reply(&serde_json::json!({"type":"started","version":1,"cpim":"mock"}), "started"));
    }
    #[test]
    fn standalone_rust_fixture_rejects_incorrect_phase_before_launch() {
        let executable = std::fs::canonicalize("/bin/sh").unwrap();
        let start = r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#;
        let finish = r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#;
        for (first, second) in [(finish, start), (start, start), (finish, finish)] {
            assert_eq!(
                run_mock_session(&executable, &["-c", "exit 99"], first, second,
                    Duration::from_secs(1)),
                Err(SessionError::InvalidResponse),
            );
        }
    }

    #[test]
    fn supervisor_cancellation_before_spawn_never_runs_fixture() {
        let executable = std::fs::canonicalize("/bin/sh").unwrap();
        let cancelled = AtomicBool::new(true);
        assert_eq!(
            run_mock_session_cancellable(
                &executable, &["-c", "exit 99"],
                r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
                r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
                Duration::from_secs(1), &cancelled,
            ),
            Err(SessionError::Cancelled),
        );
    }
    #[test]
    fn standalone_rust_fixture_completes_supervised_two_phase_session() {
        let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/session_worker_fixture.rs");
        let temp = std::env::temp_dir().join(format!(
            "zag-rust-session-fixture-{}-{:?}",
            std::process::id(), std::thread::current().id()
        ));
        std::fs::create_dir_all(&temp).unwrap();
        let executable = temp.join("session-fixture");
        let compile = Command::new("rustc")
            .args(["--edition=2021", "-o"])
            .arg(&executable).arg(&source).status().unwrap();
        assert!(compile.success(), "standalone fixture must compile");
        // macOS /var is a symlink to /private/var; executable validation
        // deliberately rejects noncanonical paths.
        let canonical_executable = std::fs::canonicalize(&executable).unwrap();
        let result = run_mock_session(
            &canonical_executable, &[],
            r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
            r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
            Duration::from_secs(5),
        );
        let _ = std::fs::remove_file(&executable);
        let _ = std::fs::remove_dir(&temp);
        let (started, finished) = result.expect("supervisor must complete both phases");
        assert_eq!(started["cpim"], "mock");
        assert_eq!(finished["adi_pb"], "mock");
    }
    #[test]
    fn rust_worker_fixture_runs_under_session_supervisor() {
        // The Rust test executable hosts a mock backend only when explicitly
        // invoked as an ignored test; the release worker cannot produce CPIM.
        let executable = std::env::current_exe().unwrap();
        let result = run_mock_session(
            &executable,
            &["--exact", "adi_worker_main::tests::rust_session_child_entry", "--ignored", "--nocapture"],
            r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
            r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
            Duration::from_secs(3),
        );
        // Test harness stdout includes its own reporting; the strict
        // supervisor must reject it rather than accept mixed protocol output.
        assert!(matches!(result, Err(SessionError::InvalidResponse | SessionError::Transport | SessionError::NonZeroExit)),
            "untrusted child stdout must fail closed: {result:?}");
    }
    #[test]
    fn two_phase_child_roundtrip() {
        let script = "dd bs=1 count=66 2>/dev/null >/dev/null; printf '\\000\\000\\000\\054{\"version\":1,\"type\":\"started\",\"cpim\":\"mock\"}'; dd bs=1 count=58 2>/dev/null >/dev/null; printf '\\000\\000\\000\\057{\"version\":1,\"type\":\"finished\",\"adi_pb\":\"mock\"}'";
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(), &["-c", script],
            "{\"version\":1,\"type\":\"start\",\"identifier\":\"mock\",\"spim\":\"mock\"}", "{\"version\":1,\"type\":\"finish\",\"ptm\":\"mock\",\"tk\":\"mock\"}", Duration::from_secs(2)).unwrap();
        assert_eq!(result.0["type"], "started");
        assert_eq!(result.1["type"], "finished");
    }
    #[test]
    fn rejects_invalid_request_shapes_before_launch() {
        let executable = std::fs::canonicalize("/bin/sh").unwrap();
        let valid_start = r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#;
        let valid_finish = r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#;
        for (start, finish) in [
            (r#"{"version":2,"type":"start","identifier":"mock","spim":"mock"}"#, valid_finish),
            (valid_finish, valid_finish),
            (valid_start, valid_start),
            (r#"{"version":1,"type":"start","identifier":"mock","spim":"mock","extra":true}"#, valid_finish),
        ] {
            let result = run_mock_session(&executable, &["-c", "exit 99"],
                start, finish, Duration::from_secs(1));
            assert_eq!(result, Err(SessionError::InvalidResponse));
        }
    }
    #[test]
    fn stalled_child_is_killed_at_deadline() {
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(), &["-c", "read a; sleep 5"],
            "{\"version\":1,\"type\":\"start\",\"identifier\":\"mock\",\"spim\":\"mock\"}", "{\"version\":1,\"type\":\"finish\",\"ptm\":\"mock\",\"tk\":\"mock\"}", Duration::from_millis(100));
        assert_eq!(result, Err(SessionError::Timeout));
    }
    #[test]
    fn cancellation_during_blocked_start_terminates_session() {
        let cancel = std::sync::Arc::new(AtomicBool::new(false));
        let signal = std::sync::Arc::clone(&cancel);
        let notifier = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(80));
            signal.store(true, Ordering::Release);
        });
        let result = run_mock_session_cancellable(
            std::fs::canonicalize("/bin/sh").unwrap().as_path(),
            &["-c", "sleep 5"],
            r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
            r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
            Duration::from_secs(2), &cancel);
        notifier.join().unwrap();
        assert_eq!(result, Err(SessionError::Cancelled));
    }
    #[test]
    fn cancellation_during_blocked_finish_terminates_session() {
        let script = "dd bs=1 count=66 2>/dev/null >/dev/null; printf '\\000\\000\\000\\054{\\\"version\\\":1,\\\"type\\\":\\\"started\\\",\\\"cpim\\\":\\\"mock\\\"}'; dd bs=1 count=58 2>/dev/null >/dev/null; sleep 5";
        let cancel = std::sync::Arc::new(AtomicBool::new(false));
        let signal = std::sync::Arc::clone(&cancel);
        let notifier = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(150));
            signal.store(true, Ordering::Release);
        });
        let result = run_mock_session_cancellable(
            std::fs::canonicalize("/bin/sh").unwrap().as_path(),
            &["-c", script],
            r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
            r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
            Duration::from_secs(2), &cancel);
        notifier.join().unwrap();
        assert!(matches!(result, Err(SessionError::Cancelled | SessionError::InvalidResponse)),
            "blocked Finish must fail closed: {result:?}");
    }
    #[test]
    fn stalled_finish_phase_times_out() {
        let script = "dd bs=1 count=66 2>/dev/null >/dev/null; printf '\\000\\000\\000\\054{\"version\":1,\"type\":\"started\",\"cpim\":\"mock\"}'; dd bs=1 count=58 2>/dev/null >/dev/null; sleep 5";
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(),
            &["-c", script],
            r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
            r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
            Duration::from_millis(200));
        assert_eq!(result, Err(SessionError::Timeout));
    }
    #[test]
    fn descendant_holding_stdout_cannot_extend_deadline() {
        // The shell exits after sending both frames, but a background
        // descendant inherits stdout and keeps the pipe open.
        let script = concat!(
            "dd bs=1 count=66 2>/dev/null >/dev/null; ",
            "printf '\\000\\000\\000\\054{\\\"version\\\":1,\\\"type\\\":\\\"started\\\",\\\"cpim\\\":\\\"mock\\\"}'; ",
            "dd bs=1 count=58 2>/dev/null >/dev/null; ",
            "printf '\\000\\000\\000\\057{\\\"version\\\":1,\\\"type\\\":\\\"finished\\\",\\\"adi_pb\\\":\\\"mock\\\"}'; ",
            "sleep 5 & exit 0"
        );
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(),
            &["-c", script],
            r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
            r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
            Duration::from_millis(200));
        assert!(matches!(result, Err(SessionError::Timeout | SessionError::InvalidResponse)),
            "descendant-held stdout must fail closed: {result:?}");
    }
    #[test]
    fn worker_that_never_replies_times_out() {
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(),
            &["-c", "sleep 5"],
            r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
            r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
            Duration::from_millis(150));
        assert_eq!(result, Err(SessionError::Timeout));
    }
    #[test]
    fn worker_that_never_closes_stdout_times_out() {
        let script = "dd bs=1 count=66 2>/dev/null >/dev/null; printf '\\000\\000\\000\\054{\"version\":1,\"type\":\"started\",\"cpim\":\"mock\"}'; dd bs=1 count=58 2>/dev/null >/dev/null; printf '\\000\\000\\000\\057{\"version\":1,\"type\":\"finished\",\"adi_pb\":\"mock\"}'; sleep 5";
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(),
            &["-c", script],
            r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
            r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
            Duration::from_millis(200));
        assert_eq!(result, Err(SessionError::Timeout));
    }
    #[test]
    fn rejects_extra_frame_after_finish() {
        let script = concat!(
            "dd bs=1 count=66 2>/dev/null >/dev/null; ",
            "printf '\\000\\000\\000\\054{\\\"version\\\":1,\\\"type\\\":\\\"started\\\",\\\"cpim\\\":\\\"mock\\\"}'; ",
            "dd bs=1 count=58 2>/dev/null >/dev/null; ",
            "printf '\\000\\000\\000\\057{\\\"version\\\":1,\\\"type\\\":\\\"finished\\\",\\\"adi_pb\\\":\\\"mock\\\"}'; ",
            "printf '\\000\\000\\000\\057{\\\"version\\\":1,\\\"type\\\":\\\"finished\\\",\\\"adi_pb\\\":\\\"mock\\\"}'"
        );
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(),
            &["-c", script],
            r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
            r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
            Duration::from_secs(2));
        assert_eq!(result, Err(SessionError::InvalidResponse));
    }
    #[test]
    fn malformed_worker_frame_fails_closed() {
        let script = "dd bs=1 count=66 2>/dev/null >/dev/null; printf '\\000\\000\\000\\000'";
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(),
            &["-c", script],
            r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
            r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
            Duration::from_secs(1));
        assert_eq!(result, Err(SessionError::InvalidResponse));
    }
    #[test]
    fn worker_exit_before_start_reply_fails_closed() {
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(),
            &["-c", "exit 0"],
            r#"{"version":1,"type":"start","identifier":"mock","spim":"mock"}"#,
            r#"{"version":1,"type":"finish","ptm":"mock","tk":"mock"}"#,
            Duration::from_secs(1));
        assert!(matches!(result, Err(SessionError::Transport) | Err(SessionError::InvalidResponse)));
    }
    #[test]
    fn rejects_noncanonical_worker_path() {
        let result = run_mock_session(Path::new("/definitely/not/a/worker"), &[],
            "{\"version\":1,\"type\":\"start\",\"identifier\":\"mock\",\"spim\":\"mock\"}", "{\"version\":1,\"type\":\"finish\",\"ptm\":\"mock\",\"tk\":\"mock\"}", Duration::from_secs(1));
        assert_eq!(result, Err(SessionError::Spawn));
    }
    #[test]
    fn rejects_zero_or_excessive_deadlines_before_spawn() {
        for timeout in [Duration::ZERO, Duration::from_secs(11)] {
            let result = run_mock_session(Path::new("/definitely/not/a/worker"), &[],
                "{\"version\":1,\"type\":\"start\",\"identifier\":\"mock\",\"spim\":\"mock\"}", "{\"version\":1,\"type\":\"finish\",\"ptm\":\"mock\",\"tk\":\"mock\"}", timeout);
            assert_eq!(result, Err(SessionError::InvalidTimeout));
        }
    }
    #[test]
    fn unexpected_response_fails_closed() {
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(),
            &["-c", "dd bs=1 count=66 2>/dev/null >/dev/null; printf '\\000\\000\\000\\057{\"version\":1,\"type\":\"finished\",\"adi_pb\":\"mock\"}'"],
            "{\"version\":1,\"type\":\"start\",\"identifier\":\"mock\",\"spim\":\"mock\"}", "{\"version\":1,\"type\":\"finish\",\"ptm\":\"mock\",\"tk\":\"mock\"}", Duration::from_secs(1));
        assert_eq!(result, Err(SessionError::InvalidResponse));
    }
}
