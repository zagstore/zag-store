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
#[cfg(unix)]
use std::os::unix::{fs::PermissionsExt, process::CommandExt};

#[cfg(unix)]
unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}

/// The worker is launched as its own process group on Unix.
/// Send SIGKILL to the whole group, not just the direct child.
#[cfg(unix)]
fn terminate_group(pid: u32) {
    if let Ok(pid) = i32::try_from(pid) {
        if pid > 0 {
            // SAFETY: negative PID targets the isolated group created below.
            unsafe { kill(-pid, 9); }
        }
    }
}

use crate::{
    adi_worker_framing::{read_single_frame_to_eof, write_frame},
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
    // Reject mutable-by-other-users executables. This does not eliminate
    // path replacement races: trusted deployment must also protect every
    // parent directory and eventually bind launch to a verified file handle.
    #[cfg(unix)]
    if std::fs::metadata(approved)
        .map_err(|_| WorkerError::UnapprovedExecutable)?
        .permissions()
        .mode() & 0o022 != 0
    {
        return Err(WorkerError::UnapprovedExecutable);
    }
    // The executable's containing directory must not permit another
    // group member or user to replace its directory entry. A complete
    // deployment audit must also validate ancestor directories.
    #[cfg(unix)]
    if std::fs::symlink_metadata(
        approved.parent().ok_or(WorkerError::UnapprovedExecutable)?
    )
        .map_err(|_| WorkerError::UnapprovedExecutable)?
        .permissions()
        .mode() & 0o022 != 0
    {
        return Err(WorkerError::UnapprovedExecutable);
    }
    let payload = encode_request(request).map_err(|_| WorkerError::InvalidRequest)?;
    let mut command = Command::new(approved);
    // Do not leak the HTTP process's credentials, proxy settings, dynamic
    // loader configuration, or working directory into a worker.
    // Future worker dependencies must be added through an explicit allowlist.
    command.env_clear()
        .current_dir("/")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(unix)]
    command.process_group(0);
    let mut child = command.spawn().map_err(|_error| {
        // Error kind and OS code only; never print executable arguments,
        // provisioning payloads, paths, or environment values.
        #[cfg(test)]
        eprintln!("offline worker spawn: kind={:?} os={:?}", _error.kind(), _error.raw_os_error());
        WorkerError::Spawn
    })?;
    // Both pipes are present because they were requested when spawning.
    let mut stdin = child.stdin.take().expect("piped worker stdin");
    let mut stdout = child.stdout.take().expect("piped worker stdout");
    let (sender, receiver) = mpsc::channel();
    let writer = thread::spawn(move || write_frame(&mut stdin, &payload));
    let reader = thread::spawn(move || {
        let result = read_single_frame_to_eof(&mut stdout);
        // Require EOF after the single frame; the parent deadline bounds this read.
        let _ = sender.send(result);
    });
    let deadline = Instant::now() + timeout;
    let mut result = None;
    let mut wait_failed = false;
    while Instant::now() < deadline {
        match receiver.try_recv() {
            Ok(frame) => { result = Some(frame); break; }
            Err(mpsc::TryRecvError::Disconnected) => break,
            Err(mpsc::TryRecvError::Empty) => {}
        }
        match child.try_wait() {
            Ok(Some(_)) => {
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
    // Terminate the isolated group before reaping the leader. This also
    // closes inherited pipes held by descendants of a worker that exited.
    // Group cleanup is unconditional: a successful direct child is not
    // allowed to leave helpers running.
    #[cfg(unix)]
    terminate_group(child.id());
    #[cfg(not(unix))]
    if timed_out || wait_failed { let _ = child.kill(); }
    let status = child.wait().map_err(|_| WorkerError::Transport)?;
    // Never join the reader/writer on a failure path. A descendant can retain
    // a pipe indefinitely after its parent exits; joining here could defeat
    // the worker deadline. Detached threads own their handles and eventually
    // exit on EOF / broken pipe, but cannot hold this request open.
    // On Unix the process group is killed above; uninterruptible I/O or
    // descendants that deliberately create a new session still require
    // stronger sandbox/process-tree supervision before production use.
    if timed_out || (result.is_none() && Instant::now() >= deadline) {
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
    fn writable_worker_directory_is_rejected() {
        let dir = std::env::temp_dir().join(format!(
            "zag-adi-dir-perms-{}-{:?}", std::process::id(), std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("worker.sh");
        std::fs::write(&script, "#!/bin/sh\\nexit 0\\n").unwrap();
        let mut executable = std::fs::metadata(&script).unwrap().permissions();
        executable.set_mode(0o700);
        std::fs::set_permissions(&script, executable).unwrap();
        for mode in [0o770, 0o707] {
            let mut permissions = std::fs::metadata(&dir).unwrap().permissions();
            permissions.set_mode(mode);
            std::fs::set_permissions(&dir, permissions).unwrap();
            assert_eq!(
                execute_offline_worker(&script, &script, &request(), Duration::from_secs(1)),
                Err(WorkerError::UnapprovedExecutable)
            );
        }
        let mut permissions = std::fs::metadata(&dir).unwrap().permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&dir, permissions).unwrap();
        std::fs::remove_file(script).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn group_or_world_writable_worker_is_rejected() {
        let dir = std::env::temp_dir().join(format!(
            "zag-adi-permissions-{}-{:?}", std::process::id(), std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("worker.sh");
        std::fs::write(&script, "#!/bin/sh\nexit 0\n").unwrap();
        for mode in [0o722, 0o702, 0o777] {
            let mut perms = std::fs::metadata(&script).unwrap().permissions();
            perms.set_mode(mode);
            std::fs::set_permissions(&script, perms).unwrap();
            assert_eq!(
                execute_offline_worker(&script, &script, &request(), Duration::from_secs(1)),
                Err(WorkerError::UnapprovedExecutable)
            );
        }
        std::fs::remove_file(script).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn worker_with_no_response_fails_closed() {
        let path = Path::new("/usr/bin/true").canonicalize().unwrap();
        let result = execute_offline_worker(&path, &path, &request(), Duration::from_secs(1));
        assert!(matches!(result, Err(WorkerError::Transport) | Err(WorkerError::NonZeroExit)));
    }
    #[cfg(unix)]
    #[test]
    fn worker_leaving_stdout_open_cannot_block_past_deadline() {
        use std::os::unix::fs::PermissionsExt;
        // The parent process exits promptly, but its child retains the
        // stdout descriptor. No IPC frame is produced.
        let dir = std::env::temp_dir().join(format!("zag-adi-lifecycle-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("worker.sh");
        std::fs::write(&script, "#!/bin/sh\nsleep 2 &\nexit 0\n").unwrap();
        let mut mode = std::fs::metadata(&script).unwrap().permissions();
        mode.set_mode(0o700);
        std::fs::set_permissions(&script, mode).unwrap();
        let started = Instant::now();
        let result = execute_offline_worker(&script, &script, &request(), Duration::from_millis(100));
        assert!(result.is_err(), "{result:?}");
        assert!(started.elapsed() < Duration::from_secs(1), "worker deadline exceeded");
        std::fs::remove_file(script).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn timed_out_worker_descendant_cannot_write_after_return() {
        use std::os::unix::fs::PermissionsExt;
        // A background helper inherits the worker's process group. If only
        // the direct child is killed, the helper creates the marker later.
        let dir = std::env::temp_dir().join(format!(
            "zag-adi-descendants-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("worker.sh");
        let marker = dir.join("escaped");
        let body = format!(
            "#!/bin/sh\n(sleep 0.3; echo escaped > '{}') &\nsleep 5\n",
            marker.display()
        );
        std::fs::write(&script, body).unwrap();
        let mut mode = std::fs::metadata(&script).unwrap().permissions();
        mode.set_mode(0o700);
        std::fs::set_permissions(&script, mode).unwrap();
        let started = Instant::now();
        let result = execute_offline_worker(
            &script, &script, &request(), Duration::from_millis(100)
        );
        assert_eq!(result, Err(WorkerError::Timeout));
        assert!(started.elapsed() < Duration::from_secs(1));
        std::thread::sleep(Duration::from_millis(450));
        assert!(!marker.exists(), "descendant survived worker timeout");
        std::fs::remove_file(script).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn worker_does_not_inherit_environment_or_working_directory() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!(
            "zag-adi-env-{}-{:?}", std::process::id(), std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("worker.sh");
        let marker = dir.join("isolated");
        // HOME is set in GitHub runners and most shells. The worker should
        // have neither HOME nor the caller's current working directory.
        let body = format!(
            "#!/bin/sh\nif [ -z \"${{HOME+x}}\" ] && [ \"$PWD\" = / ]; then echo ok > '{}'; fi\n",
            marker.display()
        );
        std::fs::write(&script, body).unwrap();
        let mut mode = std::fs::metadata(&script).unwrap().permissions();
        mode.set_mode(0o700);
        std::fs::set_permissions(&script, mode).unwrap();
        let result = execute_offline_worker(&script, &script, &request(), Duration::from_secs(1));
        assert!(result.is_err(), "{result:?}");
        assert!(marker.exists(), "worker inherited environment or working directory");
        std::fs::remove_file(marker).unwrap();
        std::fs::remove_file(script).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn nonzero_worker_cannot_produce_success() {
        let path = Path::new("/usr/bin/false").canonicalize().unwrap();
        let result = execute_offline_worker(&path, &path, &request(), Duration::from_secs(1));
        assert!(result.is_err());
    }
}
