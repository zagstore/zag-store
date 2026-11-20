//! Offline-only two-phase child supervisor prototype.
//! NOT approved for production: test-only caller-selected executable and mock framing
//! deliberately differ from the reviewed one-shot worker security contract.
//! No network integration, native libraries, or Apple provisioning.
#![allow(dead_code)]
use std::{
    io::Write,
    path::Path,
    process::{Command, Stdio},
    sync::{mpsc, atomic::{AtomicBool, Ordering}},
    thread,
    time::{Duration, Instant},
};
#[cfg(unix)]
use std::os::unix::process::CommandExt;

#[derive(Debug, PartialEq, Eq)]
pub enum SessionError { InvalidTimeout, Spawn, Transport, Timeout, Cancelled, InvalidResponse, NonZeroExit }

#[cfg(unix)]
unsafe extern "C" { fn kill(pid: i32, sig: i32) -> i32; }
#[cfg(unix)]
fn kill_group(pid: u32) {
    if let Ok(pid) = i32::try_from(pid) {
        if pid > 0 { unsafe { kill(-pid, 9); } }
    }
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
    let mut child = cmd.spawn().map_err(|_| SessionError::Spawn)?;
    // Any early error after spawn must still terminate and reap the child.
    let pid = child.id();
    let (Some(mut stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        #[cfg(unix)]
        kill_group(pid);
        let _ = child.kill();
        let _ = child.wait();
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
                Ok(Some(status)) if status.success() => return Ok((started, finished)),
                Ok(Some(_)) => return Err(SessionError::NonZeroExit),
                Ok(None) => thread::sleep(Duration::from_millis(5)),
                Err(_) => return Err(SessionError::Transport),
            }
        }
        Err(SessionError::Timeout)
    })();
    // Always kill the isolated process group, even after success.
    #[cfg(unix)]
    kill_group(pid);
    #[cfg(not(unix))]
    { let _ = child.kill(); }
    let _ = child.wait();
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
