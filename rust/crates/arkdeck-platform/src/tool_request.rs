//! What a caller asks of one verified tool child and what it gets back, as
//! Swift's `ProcessRequest` and `FoundationProcessExecutor` receipt carry it.
//! One set of types for every runner that has a platform spawn: the macOS
//! `posix_spawn` process-group runner (`tool_process.rs`) and the Windows
//! `CreateProcessW` Job-object runner (`windows/tool.rs`, TASK-XPA-005). The
//! budget rule below is the one both apply before anything is spawned.
use crate::invalid;
use std::ffi::OsString;
use std::io;
use std::path::Path;
use std::time::Duration;

pub(crate) const MAX_CAPTURE_BYTES: usize = 64 * 1024 * 1024;
pub(crate) const MAX_TIMEOUT: Duration = Duration::from_secs(3600);

#[derive(Clone, Copy, Debug)]
pub struct ToolLimits {
    pub timeout: Duration,
    /// Each stream keeps this many bytes; the rest is read and dropped.
    pub capture_bytes: usize,
}

/// What a caller asks of one tool child, as Swift's `ProcessRequest` does.
pub struct ToolRequest<'a> {
    pub arguments: &'a [OsString],
    /// Overlaid on the clean base environment (`PATH`, `LANG`, `LC_ALL` on
    /// macOS; `PATH`, `SystemRoot`, `WINDIR` on Windows); the parent's
    /// environment is never inherited. The base and the loader cannot be
    /// overlaid; keys and values carry no NUL and keys no `=`.
    pub environment: &'a [(OsString, OsString)],
    /// Child-only, applied by the spawn itself; the daemon's own directory
    /// never changes. Must be an absolute, canonical, existing directory, as
    /// Swift requires. `None` is `/` on macOS and the Windows directory on
    /// Windows.
    pub working_directory: Option<&'a Path>,
    pub limits: ToolLimits,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolTermination {
    Exited(i32),
    /// A signal ended the child. Unix only: a Windows child always ends
    /// with an exit code.
    Signalled(i32),
    /// The deadline passed; the process group (the Job object on Windows)
    /// was terminated.
    TimedOut,
    /// Cancelled before the child was spawned, or while it ran, when its
    /// process group (Job object) was terminated. `drained` holds when no
    /// member of the group was left: Swift's positive proof that nothing
    /// survived.
    Cancelled {
        drained: bool,
    },
}

#[derive(Debug)]
pub struct ToolExecution {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// Either stream produced more than it kept.
    pub truncated: bool,
    pub termination: ToolTermination,
    /// Swift's receipt `durationSeconds`: monotonic time from the spawn to the
    /// child's end (or to its termination).
    pub duration: Duration,
}

#[derive(Debug)]
pub enum ToolRunError {
    /// Refused before the child ran any executable code.
    Refused(io::Error),
    /// The child may have run; what it did cannot be observed.
    Unobservable(io::Error),
}

/// The budget every tool runner accepts: 1 s..1 h and 1 byte..64 MiB kept
/// per stream.
pub(crate) fn check_limits(limits: ToolLimits) -> io::Result<()> {
    if limits.timeout.is_zero()
        || limits.timeout > MAX_TIMEOUT
        || limits.capture_bytes == 0
        || limits.capture_bytes > MAX_CAPTURE_BYTES
    {
        return Err(invalid(
            "tool budget must be 1 s..1 h and 1 byte..64 MiB per stream",
        ));
    }
    Ok(())
}
