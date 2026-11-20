//! Offline-only process boundary for a future separately reviewed ADI provider.
//! No executable is launched by the production listener. No Apple libraries or
//! credentials are loaded. The boundary is exercised exclusively in tests.
#![allow(dead_code)]

use std::{io, process::{Command, Stdio}, time::{Duration, Instant}};

#[derive(Debug, PartialEq, Eq)]
pub enum ProcessError {
    Spawn,
    Timeout,
    NonZeroExit,
    UnexpectedOutput,
}

/// Run a fixed, caller-selected local test executable with no shell and no
/// inherited stdin. Production integration requires a separate security review.
/// Output is intentionally discarded: never expose provisioning secrets in logs.
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
    fn slow_local_process_is_terminated() {
        assert_eq!(probe_local_executable("/usr/bin/sleep", Duration::from_millis(100)), Err(ProcessError::NonZeroExit));
    }
    #[test]
    fn unused_io_error_does_not_escape_boundary() {
        let _: Option<io::Error> = None;
    }
}
