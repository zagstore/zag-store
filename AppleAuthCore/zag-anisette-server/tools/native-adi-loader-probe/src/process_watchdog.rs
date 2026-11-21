//! Whole-process watchdog for the opt-in provisioning coordinator.
//! Owns the child handle and reaps it on deadline or cancellation; never
//! signals a raw PID. Not wired to the production service.
use std::io;
use std::process::{Child, Command, ExitStatus};
#[cfg(test)]
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use std::thread;

pub(crate) const HARD_DEADLINE: Duration = Duration::from_secs(95);

#[allow(dead_code)]
pub(crate) fn run_bounded(command: &mut Command, deadline: Duration) -> io::Result<ExitStatus> {
    if deadline.is_zero() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "zero process deadline"));
    }
    // Respect caller-specified stdio. The coordinator inherits identity JSON
    // through stdin; no identity material is placed in argv or the environment.
    let child = command.spawn()?;
    wait_bounded(child, deadline)
}

pub(crate) fn wait_bounded(child: Child, deadline: Duration) -> io::Result<ExitStatus> {
    wait_cancellable(child, deadline, &AtomicBool::new(false))
}

/// As wait_bounded, and also kills and reaps the child as soon as `cancel`
/// is set, returning ErrorKind::Interrupted.
pub(crate) fn wait_cancellable(mut child: Child, deadline: Duration, cancel: &AtomicBool) -> io::Result<ExitStatus> {
    if deadline.is_zero() {
        let _ = child.kill();
        let _ = child.wait();
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "zero process deadline"));
    }
    let end = Instant::now() + deadline;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) => {}
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        }
        if cancel.load(Ordering::Acquire) {
            let _ = child.kill();
            child.wait()?;
            return Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled by operator"));
        }
        if Instant::now() >= end {
            let _ = child.kill();
            child.wait()?;
            return Err(io::Error::new(io::ErrorKind::TimedOut, "process deadline exceeded"));
        }
        thread::sleep(Duration::from_millis(20));
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn watchdog_reaps_hung_process() {
        let started = Instant::now();
        let error = run_bounded(
            Command::new("/bin/sh").args(["-c", "exec sleep 10"]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()),
            Duration::from_millis(120),
        ).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn watchdog_preserves_successful_exit() {
        let status = run_bounded(
            Command::new("/bin/sh").args(["-c", "exit 0"]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()),
            Duration::from_secs(2),
        ).unwrap();
        assert!(status.success());
    }

    #[test]
    fn watchdog_rejects_zero_deadline_without_spawning() {
        let error = run_bounded(
            Command::new("/bin/sh").args(["-c", "exit 99"]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()),
            Duration::ZERO,
        ).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }
}
