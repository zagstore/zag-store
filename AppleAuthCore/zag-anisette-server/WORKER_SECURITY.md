# Offline ADI worker launch security contract

Status: **review-only; NOT approved for production**. The HTTP listener remains disconnected from the worker.

## Current checks

- Exact approved absolute canonical executable path; no symlink at the executable.
- Unix executable must not be group/world writable, and its ancestors are checked for writable permissions (with a root-owned sticky-directory exception).
- Non-test Unix builds require a root-owned executable and root-owned ancestor directories. Tests use disposable user-owned fixtures.
- On macOS, temporary test paths must be canonicalized because `/var` resolves through `/private/var`; validation intentionally rejects aliases.
- Executable device/inode is rechecked immediately before spawn.
- Child receives an empty environment and a fixed working directory; IPC is bounded and requires one complete response followed by EOF.
- Child process group is killed on completion or timeout. This is not a sandbox: descendants can create new sessions or otherwise evade group cleanup.

## Critical unresolved risks

**Path-to-exec race:** the executable can still be replaced between the final metadata check and `Command::spawn`. Even a stable inode does not protect against in-place modification by its owner. Root ownership and a trusted installation hierarchy reduce this risk under an unprivileged attacker model but do not provide descriptor-bound execution. Do not advertise this launcher as race-free.

**Trusted ancestry:** a root-owned sticky directory is accepted for development fixtures, but a production executable must reside in a root-controlled, non-writable-by-service-account directory hierarchy. A privileged installer should stage and atomically publish a verified worker, with restrictive permissions. Audit mounts, hard links, ACLs, ownership of every ancestor, and filesystem trust before enabling live ADI.

**Platform-specific launch:** review a descriptor-bound or otherwise OS-verified execution strategy separately for Linux and macOS. Do not assume Linux `fexecve`/`execveat` semantics apply to macOS, or that scripts behave like native executables.

**Process isolation:** process groups are not a containment boundary. A real worker requires an explicit sandbox, resource limits, least privilege, and process-tree supervision appropriate to its OS.

## Release gates

1. Linux CI green for build, unit tests, and Clippy; macOS native build/tests separately green.
2. Offline IPC success, malformed output, second frame, truncated frame, timeout, nonzero exit, and descendant cleanup tests green.
3. Security review of executable trust and race-free launch on the actual deployment OS.
4. Real ADI provider developed separately, behind an explicit opt-in integration boundary.
5. No live Apple provisioning, production deployment, or merge to main without a reviewed approval.
