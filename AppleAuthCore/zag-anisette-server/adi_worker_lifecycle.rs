//! Offline-only ADI worker lifecycle: fixed executable, bounded IPC and deadline.
//! Not connected to the HTTP listener. No worker is launched unless explicitly
//! called by a future reviewed integration.
#![allow(dead_code)]
use std::{
    path::Path,
    process::{Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use crate::{
    adi_worker_framing::{read_frame, write_frame},
    adi_worker_protocol::{decode_response, encode_request, WorkerRequest, WorkerResponse},
};

#[derive(Debug, PartialEq, Eq)]
pub enum WorkerError {
    UnapprovedExecutable,
    InvalidTimeout,
    InvalidRequest,
    Spawn,
    Transport,
    Timeout,
    NonZeroExit,
    InvalidResponse,
}

/// Never accepts a command from the network or a request. Caller supplies a
/// preapproved canonical absolute executable, checked again before launch.
/// stderr is discarded and no payload or worker output is logged.
pub fn execute_offline_worker(
    approved: &Path,
    requested: &Path,
    request: &WorkerRequest,
    timeout: Duration,
) -> Result<WorkerResponse, WorkerError> {
    if timeout.is_zero() || timeout > Duration::from_secs(10) {
        return Err(WorkerError::InvalidTimeout);
    }
    if !approved.is_absolute() || approved != requested {
        return Err(WorkerError::UnapprovedExecutable);
    }
    let canonical = approved.canonicalize().map_err(|_| WorkerError::UnapprovedExecutable)?;
    if canonical != approved || !std::fs::symlink_metadata(approved)
        .map_err(|_| WorkerError::UnapprovedExecutable)?
        .file_type().is_file()
    {
        return Err(WorkerError::UnapprovedExecutable);
    }
    let payload = encode_request(request).map_err(|_| WorkerError::InvalidRequest)?;
    let mut child = Command::new(approved)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| WorkerError::Spawn)?;
    // Both pipes are present because they were requested when spawning.
    let mut stdin = child.stdin.take().expect("piped worker stdin");
    let mut stdout = child.stdout.take().expect("piped worker stdout");
    let (sender, receiver) = mpsc::channel();
    let writer = thread::spawn(move || write_frame(&mut stdin, &payload));
    let reader = thread::spawn(move || {
        let result = read_frame(&mut stdout);
        // Do not wait for EOF: the protocol is exactly one response frame.
        let _ = sender.send(result);
    });
    let deadline = Instant::now() + timeout;
    let mut result = None;
    let mut child_exited = false;
    let mut wait_failed = false;
    while Instant::now() < deadline {
        match receiver.try_recv() {
            Ok(frame) => { result = Some(frame); break; }
            Err(mpsc::TryRecvError::Disconnected) => break,
            Err(mpsc::TryRecvError::Empty) => {}
        }
        match child.try_wait() {
            Ok(Some(_)) => {
                child_exited = true;
                // A just-exited child may have written a complete reply.
                // Any inherited stdout held open elsewhere must not extend the deadline.
                result = receiver.recv_timeout(deadline.saturating_duration_since(Instant::now())).ok();
                break;
            }
            Err(_) => { wait_failed = true; break; },
            Ok(None) => {}
        }
        thread::sleep(Duration::from_millis(5));
    }
    // A response alone is not success: the worker must also exit zero.
    // Allow it the remainder of the same deadline to finish normally.
    let mut exited = child.try_wait().map_err(|_| WorkerError::Transport)?;
    while exited.is_none() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
        exited = child.try_wait().map_err(|_| WorkerError::Transport)?;
    }
    let timed_out = exited.is_none();
    if timed_out || wait_failed { let _ = child.kill(); }
    let status = child.wait().map_err(|_| WorkerError::Transport)?;
    // Never join the reader/writer on a failure path. A descendant can retain
    // a pipe indefinitely after its parent exits; joining here could defeat
    // the worker deadline. Detached threads own their handles and eventually
    // exit on EOF / broken pipe, but cannot hold this request open.
    // A future production worker must use a supervised process group.
    if timed_out || (result.is_none() && !child_exited && Instant::now() >= deadline) {
        return Err(WorkerError::Timeout);
    }
    if wait_failed { return Err(WorkerError::Transport); }
    if !status.success() { return Err(WorkerError::NonZeroExit); }
    let frame = result.ok_or(WorkerError::Transport)?.map_err(|_| WorkerError::Transport)?;
    let response = decode_response(&frame, request).map_err(|_| WorkerError::InvalidResponse)?;
    // A positive reply must also have been written successfully, but a worker
    // may close its stdin early after seeing enough data. Treat that as an
    // invalid exchange, never as successful provisioning.
    match writer.is_finished() {
        true => match writer.join() {
            Ok(Ok(())) => {}
            _ => return Err(WorkerError::Transport),
        },
        false => return Err(WorkerError::Transport),
    }
    // The reader has already sent its result; this join cannot block.
    let _ = reader.join();
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> WorkerRequest {
        WorkerRequest::Start { identifier: "device".into(), spim: "spim".into() }
    }
    #[test]
    fn rejects_unapproved_path_and_timeout_before_spawn() {
        assert_eq!(execute_offline_worker(Path::new("/usr/bin/true"), Path::new("/usr/bin/false"), &request(), Duration::from_secs(1)), Err(WorkerError::UnapprovedExecutable));
        assert_eq!(execute_offline_worker(Path::new("/usr/bin/true"), Path::new("/usr/bin/true"), &request(), Duration::ZERO), Err(WorkerError::InvalidTimeout));
        assert_eq!(execute_offline_worker(Path::new("relative"), Path::new("relative"), &request(), Duration::from_secs(1)), Err(WorkerError::UnapprovedExecutable));
    }
    #[cfg(unix)]
    #[test]
    fn worker_with_no_response_fails_closed() {
        let result = execute_offline_worker(Path::new("/usr/bin/true"), Path::new("/usr/bin/true"), &request(), Duration::from_secs(1));
        assert!(matches!(result, Err(WorkerError::Transport) | Err(WorkerError::NonZeroExit)));
    }
    #[cfg(unix)]
    #[test]
    fn nonzero_worker_cannot_produce_success() {
        let result = execute_offline_worker(Path::new("/usr/bin/false"), Path::new("/usr/bin/false"), &request(), Duration::from_secs(1));
        assert!(result.is_err());
    }
}
