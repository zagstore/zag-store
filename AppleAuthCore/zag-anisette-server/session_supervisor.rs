//! Offline-only two-phase child supervisor prototype.
//! NOT approved for production: test-only caller-selected executable and mock framing
//! deliberately differ from the reviewed one-shot worker security contract.
//! No network integration, native libraries, or Apple provisioning.
#![allow(dead_code)]
use std::{
    io::{Read, Write},
    path::Path,
    process::{Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
#[cfg(unix)]
use std::os::unix::process::CommandExt;

#[derive(Debug, PartialEq, Eq)]
pub enum SessionError { InvalidTimeout, Spawn, Transport, Timeout, InvalidResponse, NonZeroExit }

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
fn receive<T>(rx: &mpsc::Receiver<T>, deadline: Instant) -> Result<T, SessionError> {
    rx.recv_timeout(remaining(deadline)?).map_err(|_| SessionError::Timeout)
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
    if timeout.is_zero() || timeout > Duration::from_secs(10) {
        return Err(SessionError::InvalidTimeout);
    }
    if start.len() > 64 * 1024 || finish.len() > 64 * 1024 {
        return Err(SessionError::InvalidResponse);
    }
    crate::adi_worker_lifecycle::verify_worker_executable(executable, executable)
        .map_err(|_| SessionError::Spawn)?;
    let start_frame = encode_session_frame(&serde_json::from_str::<serde_json::Value>(start)
        .map_err(|_| SessionError::InvalidResponse)?)
        .map_err(|_| SessionError::InvalidResponse)?;
    let finish_frame = encode_session_frame(&serde_json::from_str::<serde_json::Value>(finish)
        .map_err(|_| SessionError::InvalidResponse)?)
        .map_err(|_| SessionError::InvalidResponse)?;
    let deadline = Instant::now() + timeout;
    let mut cmd = Command::new(executable);
    cmd.args(args).env_clear().current_dir("/")
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    #[cfg(unix)]
    cmd.process_group(0);
    crate::adi_worker_lifecycle::verify_worker_executable(executable, executable)
        .map_err(|_| SessionError::Spawn)?;
    let mut child = cmd.spawn().map_err(|_| SessionError::Spawn)?;
    let pid = child.id();
    let mut stdin = child.stdin.take().ok_or(SessionError::Transport)?;
    let stdout = child.stdout.take().ok_or(SessionError::Transport)?;
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
        if !receive(&write_rx, deadline)? { return Err(SessionError::Transport); }
        let started = receive(&read_rx, deadline)?.ok_or(SessionError::InvalidResponse)?;
        if started.get("type").and_then(serde_json::Value::as_str) != Some("started") {
            return Err(SessionError::InvalidResponse);
        }
        command_tx.send(finish_frame).map_err(|_| SessionError::Transport)?;
        if !receive(&write_rx, deadline)? { return Err(SessionError::Transport); }
        drop(command_tx);
        let finished = receive(&read_rx, deadline)?.ok_or(SessionError::InvalidResponse)?;
        if finished.get("type").and_then(serde_json::Value::as_str) != Some("finished") {
            return Err(SessionError::InvalidResponse);
        }
        // EOF is required after the terminal response; reject extra output.
        if receive(&read_rx, deadline)?.is_some() { return Err(SessionError::InvalidResponse); }
        while Instant::now() < deadline {
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
    fn two_phase_child_roundtrip() {
        let script = "dd bs=1 count=20 2>/dev/null >/dev/null; printf '\\000\\000\\000\\022{\"type\":\"started\"}'; dd bs=1 count=21 2>/dev/null >/dev/null; printf '\\000\\000\\000\\023{\"type\":\"finished\"}'";
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(), &["-c", script],
            "{\"type\":\"start\"}", "{\"type\":\"finish\"}", Duration::from_secs(2)).unwrap();
        assert_eq!(result.0["type"], "started");
        assert_eq!(result.1["type"], "finished");
    }
    #[test]
    fn stalled_child_is_killed_at_deadline() {
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(), &["-c", "read a; sleep 5"],
            "{\"type\":\"start\"}", "{\"type\":\"finish\"}", Duration::from_millis(100));
        assert_eq!(result, Err(SessionError::Timeout));
    }
    #[test]
    fn rejects_noncanonical_worker_path() {
        let result = run_mock_session(Path::new("/definitely/not/a/worker"), &[],
            "{\"type\":\"start\"}", "{\"type\":\"finish\"}", Duration::from_secs(1));
        assert_eq!(result, Err(SessionError::Spawn));
    }
    #[test]
    fn rejects_zero_or_excessive_deadlines_before_spawn() {
        for timeout in [Duration::ZERO, Duration::from_secs(11)] {
            let result = run_mock_session(Path::new("/definitely/not/a/worker"), &[],
                "{\"type\":\"start\"}", "{\"type\":\"finish\"}", timeout);
            assert_eq!(result, Err(SessionError::InvalidTimeout));
        }
    }
    #[test]
    fn unexpected_response_fails_closed() {
        let result = run_mock_session(std::fs::canonicalize("/bin/sh").unwrap().as_path(),
            &["-c", "dd bs=1 count=20 2>/dev/null >/dev/null; printf '\\000\\000\\000\\023{\"type\":\"finished\"}'"],
            "{\"type\":\"start\"}", "{\"type\":\"finish\"}", Duration::from_secs(1));
        assert_eq!(result, Err(SessionError::InvalidResponse));
    }
}
