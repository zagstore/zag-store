//! Whole-process watchdog for the opt-in provisioning coordinator.
//! Supervised children lead their own process group. The watchdog detects
//! exit without reaping, kills the whole group while the leader is still
//! unreaped (so the group ID cannot have been reused), then reaps. Any
//! descendant, and with it any inherited pipe, is gone when it returns.
//! Not wired to the production service.
use std::io;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus};
#[cfg(test)]
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use std::thread;

pub(crate) const HARD_DEADLINE: Duration = Duration::from_secs(95);

/// Configures `command` for group supervision: a new process group, kept
/// out of the terminal's signals (the supervisor handles those), and on
/// Linux killed by the kernel if the supervisor itself dies.
pub(crate) fn supervised(command: &mut Command) -> &mut Command {
    command.process_group(0);
    #[cfg(target_os = "linux")]
    {
        let supervisor = unsafe { libc::getpid() };
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::getppid() != supervisor {
                    return Err(io::Error::new(io::ErrorKind::Other, "supervisor exited"));
                }
                Ok(())
            });
        }
    }
    command
}

#[allow(dead_code)]
pub(crate) fn run_bounded(command: &mut Command, deadline: Duration) -> io::Result<ExitStatus> {
    if deadline.is_zero() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "zero process deadline"));
    }
    // Respect caller-specified stdio. The coordinator inherits identity JSON
    // through stdin; no identity material is placed in argv or the environment.
    let child = supervised(command).spawn()?;
    wait_bounded(child, deadline)
}

pub(crate) fn wait_bounded(child: Child, deadline: Duration) -> io::Result<ExitStatus> {
    wait_cancellable(child, deadline, &AtomicBool::new(false))
}

/// Whether the child has exited, without reaping it.
fn exited(child: &Child) -> io::Result<bool> {
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    let flags = libc::WEXITED | libc::WNOHANG | libc::WNOWAIT;
    if unsafe { libc::waitid(libc::P_PID, child.id() as libc::id_t, &mut info, flags) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { info.si_pid() } != 0)
}

/// Waits for a child spawned through `supervised`, and kills and reaps it,
/// with its whole group, on exit, deadline (TimedOut) or `cancel`
/// (Interrupted).
pub(crate) fn wait_cancellable(mut child: Child, deadline: Duration, cancel: &AtomicBool) -> io::Result<ExitStatus> {
    let end = Instant::now() + deadline;
    let outcome = loop {
        if deadline.is_zero() {
            break Err(io::Error::new(io::ErrorKind::InvalidInput, "zero process deadline"));
        }
        match exited(&child) {
            Ok(true) => break Ok(()),
            Ok(false) => {}
            Err(error) => break Err(error),
        }
        if cancel.load(Ordering::Acquire) {
            break Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled by operator"));
        }
        if Instant::now() >= end {
            break Err(io::Error::new(io::ErrorKind::TimedOut, "process deadline exceeded"));
        }
        thread::sleep(Duration::from_millis(20));
    };
    // The leader is unreaped here, so its PID is still the group's ID.
    unsafe { libc::killpg(child.id() as libc::pid_t, libc::SIGKILL); }
    let _ = child.kill();
    let status = child.wait()?;
    outcome.map(|()| status)
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
    fn watchdog_kills_descendants_of_an_exited_child() {
        let dir = std::env::temp_dir().join(format!("zag-adi-watchdog-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir(&dir).unwrap();
        let pid_file = dir.join("pid");
        let status = run_bounded(
            Command::new("/bin/sh").arg("-c").arg(r#"sleep 30 & echo $! > "$1"; exit 0"#).arg("sh").arg(&pid_file)
                .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()),
            Duration::from_secs(5),
        ).unwrap();
        assert!(status.success());
        let pid: libc::pid_t = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
        let started = Instant::now();
        while unsafe { libc::kill(pid, 0) } == 0 {
            assert!(started.elapsed() < Duration::from_secs(3), "descendant survived");
            thread::sleep(Duration::from_millis(20));
        }
        std::fs::remove_dir_all(dir).unwrap();
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
