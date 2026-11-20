//! Offline-only two-phase child supervisor prototype.
//! NOT approved for production: caller-selected executable and newline framing
//! deliberately differ from the reviewed one-shot worker security contract.
//! No network integration, native libraries, or Apple provisioning.
#![allow(dead_code)]
use std::{
    io::{BufRead, BufReader, Write},
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
/// Each reply must be a single newline-terminated JSON object of at most 64KiB.
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
    if start.len() > 64 * 1024 || finish.len() > 64 * 1024
        || !start.ends_with('\n') || !finish.ends_with('\n') {
        return Err(SessionError::InvalidResponse);
    }
    let deadline = Instant::now() + timeout;
    let mut cmd = Command::new(executable);
    cmd.args(args).env_clear().current_dir("/")
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    #[cfg(unix)]
    cmd.process_group(0);
    let mut child = cmd.spawn().map_err(|_| SessionError::Spawn)?;
    let pid = child.id();
    let mut stdin = child.stdin.take().ok_or(SessionError::Transport)?;
    let stdout = child.stdout.take().ok_or(SessionError::Transport)?;
    let (write_tx, write_rx) = mpsc::channel();
    let (read_tx, read_rx) = mpsc::channel();
    let (command_tx, command_rx) = mpsc::channel::<String>();
    thread::spawn(move || {
        for payload in command_rx {
            let result = stdin.write_all(payload.as_bytes()).and_then(|_| stdin.flush());
            if write_tx.send(result.is_ok()).is_err() { break; }
            if result.is_err() { break; }
        }
    });
    thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        loop {
            let mut line = Vec::new();
            let result = reader.by_ref().take(65_537).read_until(b'\n', &mut line);
            let outcome = match result {
                Ok(n) if n > 0 && n <= 65_536 && line.ends_with(b"\n") =>
                    serde_json::from_slice::<serde_json::Value>(&line).ok(),
                _ => None,
            };
            if read_tx.send(outcome).is_err() { break; }
        }
    });
    let result = (|| {
        command_tx.send(start.to_string()).map_err(|_| SessionError::Transport)?;
        if !receive(&write_rx, deadline)? { return Err(SessionError::Transport); }
        let started = receive(&read_rx, deadline)?.ok_or(SessionError::InvalidResponse)?;
        if started.get("type").and_then(serde_json::Value::as_str) != Some("started") {
            return Err(SessionError::InvalidResponse);
        }
        command_tx.send(finish.to_string()).map_err(|_| SessionError::Transport)?;
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

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn two_phase_child_roundtrip() {
        let script = "read a; echo '{\"type\":\"started\"}'; read b; echo '{\"type\":\"finished\"}'";
        let result = run_mock_session(Path::new("/bin/sh"), &["-c", script],
            "{\"type\":\"start\"}\n", "{\"type\":\"finish\"}\n", Duration::from_secs(2)).unwrap();
        assert_eq!(result.0["type"], "started");
        assert_eq!(result.1["type"], "finished");
    }
    #[test]
    fn stalled_child_is_killed_at_deadline() {
        let result = run_mock_session(Path::new("/bin/sh"), &["-c", "read a; sleep 5"],
            "{\"type\":\"start\"}\n", "{\"type\":\"finish\"}\n", Duration::from_millis(100));
        assert_eq!(result, Err(SessionError::Timeout));
    }
    #[test]
    fn unexpected_response_fails_closed() {
        let result = run_mock_session(Path::new("/bin/sh"),
            &["-c", "read a; echo '{\"type\":\"finished\"}'"],
            "{\"type\":\"start\"}\n", "{\"type\":\"finish\"}\n", Duration::from_secs(1));
        assert_eq!(result, Err(SessionError::InvalidResponse));
    }
}
