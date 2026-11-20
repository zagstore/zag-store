//! Offline-only process boundary for a future separately reviewed ADI provider.
//! No executable is launched by the production listener. No Apple libraries or
//! credentials are loaded. The boundary is exercised exclusively in tests.
#![allow(dead_code)]

use std::{process::{Command, Stdio}, time::{Duration, Instant}};

#[derive(Debug, PartialEq, Eq)]
pub enum ProcessError {
    Spawn,
    UnapprovedExecutable,
    Timeout,
    NonZeroExit,
    UnexpectedOutput,
}

/// Run a fixed, caller-selected local test executable with no shell and no
/// inherited stdin. Production integration requires a separate security review.
/// Output is intentionally discarded: never expose provisioning secrets in logs.
/// Production-facing policy boundary: only the explicitly configured absolute
/// executable path can be probed. Never accept a request-supplied command.
pub fn probe_approved_executable(
    approved: &std::path::Path,
    requested: &std::path::Path,
    timeout: Duration,
) -> Result<(), ProcessError> {
    if !approved.is_absolute() || !requested.is_absolute() || approved != requested {
        return Err(ProcessError::UnapprovedExecutable);
    }
    let canonical_approved = approved.canonicalize().map_err(|_| ProcessError::UnapprovedExecutable)?;
    if canonical_approved != approved {
        return Err(ProcessError::UnapprovedExecutable);
    }
    let metadata = std::fs::symlink_metadata(approved).map_err(|_| ProcessError::UnapprovedExecutable)?;
    if !metadata.file_type().is_file() {
        return Err(ProcessError::UnapprovedExecutable);
    }
    probe_local_executable(approved.to_str().ok_or(ProcessError::UnapprovedExecutable)?, timeout)
}

pub fn probe_local_executable(executable: &str, timeout: Duration) -> Result<(), ProcessError> {
    if timeout.is_zero() || timeout > Duration::from_secs(10) {
        return Err(ProcessError::Timeout);
    }
    let mut child = Command::new(executable)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| ProcessError::Spawn)?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return if status.success() { Ok(()) } else { Err(ProcessError::NonZeroExit) },
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(ProcessError::Timeout);
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(_error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(ProcessError::UnexpectedOutput);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn arbitrary_worker_path_is_rejected() {
        use std::path::Path;
        assert_eq!(
            probe_approved_executable(Path::new("/usr/bin/true"), Path::new("/usr/bin/false"), Duration::from_secs(1)),
            Err(ProcessError::UnapprovedExecutable)
        );
        assert_eq!(
            probe_approved_executable(Path::new("true"), Path::new("true"), Duration::from_secs(1)),
            Err(ProcessError::UnapprovedExecutable)
        );
    }
    #[cfg(unix)]
    #[test]
    fn approved_local_worker_can_run() {
        use std::path::Path;
        assert_eq!(
            probe_approved_executable(Path::new("/usr/bin/true"), Path::new("/usr/bin/true"), Duration::from_secs(1)),
            Ok(())
        );
    }
    #[test]
    fn missing_executable_fails_closed() {
        assert_eq!(probe_local_executable("/nonexistent/zag-adi-provider", Duration::from_secs(1)), Err(ProcessError::Spawn));
    }
    #[test]
    fn zero_timeout_is_rejected_without_spawning() {
        assert_eq!(probe_local_executable("/nonexistent/zag-adi-provider", Duration::ZERO), Err(ProcessError::Timeout));
    }
    #[cfg(unix)]
    #[test]
    fn successful_local_process() {
        assert_eq!(probe_local_executable("/usr/bin/true", Duration::from_secs(2)), Ok(()));
    }
    #[cfg(unix)]
    #[test]
    fn nonzero_local_process_fails_closed() {
        assert_eq!(probe_local_executable("/usr/bin/false", Duration::from_secs(2)), Err(ProcessError::NonZeroExit));
    }
    #[cfg(unix)]
    #[test]
    fn timeout_kills_slow_process() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("zag-adi-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("slow.sh");
        std::fs::write(&script, "#!/bin/sh\nsleep 3\n").unwrap();
        let mut permissions = std::fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&script, permissions).unwrap();
        let started = Instant::now();
        let result = probe_local_executable(script.to_str().unwrap(), Duration::from_millis(100));
        assert_eq!(result, Err(ProcessError::Timeout));
        assert!(started.elapsed() < Duration::from_secs(2));
        std::fs::remove_file(&script).unwrap();
        std::fs::remove_dir(&dir).unwrap();
    }
}
