//! One verified tool child as Swift's `FoundationProcessExecutor` runs it for
//! a descriptor-bound provider dispatch (SPK-6 phase 2, TASK-XPA-016): the
//! pinned executable spawned through its retained inode in a new process
//! group, a caller-named environment overlaid on the clean base, a child-only
//! working directory applied by `posix_spawn` file actions, `/dev/null` as
//! stdin, each output stream kept to its first bytes while the rest is drained
//! unread, a timeout that terminates the process group (TERM, then KILL after
//! 0.25 s), and a cancellation probe asked before the spawn and while the
//! child runs. The analyzer runner is this runner with its source retained.
use super::macos_process::RunningChild;
use super::{READER_CLEANUP_TIMEOUT, VerifiedTool, invalid};
use std::ffi::{CString, OsString};
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::time::{Duration, Instant};

pub(super) const MAX_CAPTURE_BYTES: usize = 64 * 1024 * 1024;
pub(super) const MAX_TIMEOUT: Duration = Duration::from_secs(3600);
/// Swift `terminateProcessGroup`: how long TERM has before KILL.
const TERMINATION_GRACE: Duration = Duration::from_millis(250);
/// Swift `terminateProcessGroup`: how long a killed group has to disappear.
const KILL_GRACE: Duration = Duration::from_secs(1);
/// Swift `waitForGroupToDisappear`: how often the group is looked for.
const DRAIN_PROBE: Duration = Duration::from_millis(10);

#[derive(Clone, Copy, Debug)]
pub struct ToolLimits {
    pub timeout: Duration,
    /// Each stream keeps this many bytes; the rest is read and dropped.
    pub capture_bytes: usize,
}

/// What a caller asks of one tool child, as Swift's `ProcessRequest` does.
pub struct ToolRequest<'a> {
    pub arguments: &'a [OsString],
    /// Overlaid on the clean base environment (`PATH`, `LANG`, `LC_ALL`); the
    /// parent's environment is never inherited. `PATH` and dynamic-loader
    /// variables cannot be overlaid; keys and values carry no NUL and keys no
    /// `=`.
    pub environment: &'a [(OsString, OsString)],
    /// Child-only, applied by the spawn's file actions; the daemon's own
    /// directory never changes. Must be an absolute, canonical, existing
    /// directory, as Swift requires. `None` is `/`.
    pub working_directory: Option<&'a Path>,
    pub limits: ToolLimits,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolTermination {
    Exited(i32),
    Signalled(i32),
    /// The deadline passed; the process group was terminated.
    TimedOut,
    /// Cancelled before the child was spawned, or while it ran, when its
    /// process group was terminated. `drained` holds when no member of the
    /// group was left: Swift's positive proof that nothing survived.
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

/// Why a child that had not finished was stopped.
#[derive(Clone, Copy)]
enum Stop {
    TimedOut,
    Cancelled,
}

impl VerifiedTool {
    /// Run the pinned executable once. `cancelled` is asked before the spawn
    /// and while the child runs.
    pub fn run_tool(
        &self,
        request: &ToolRequest<'_>,
        cancelled: &dyn Fn() -> bool,
    ) -> Result<ToolExecution, ToolRunError> {
        let limits = request.limits;
        if limits.timeout.is_zero()
            || limits.timeout > MAX_TIMEOUT
            || limits.capture_bytes == 0
            || limits.capture_bytes > MAX_CAPTURE_BYTES
        {
            return Err(ToolRunError::Refused(invalid(
                "tool budget must be 1 s..1 h and 1 byte..64 MiB per stream",
            )));
        }
        validate_environment(request.environment).map_err(ToolRunError::Refused)?;
        let directory = request
            .working_directory
            .map(validate_working_directory)
            .transpose()
            .map_err(ToolRunError::Refused)?;
        self.revalidate().map_err(ToolRunError::Refused)?;
        // Swift's executor checks for a cancellation before it spawns; one
        // seen there leaves no child, and so nothing to drain.
        if cancelled() {
            return Ok(ToolExecution {
                stdout: Vec::new(),
                stderr: Vec::new(),
                truncated: false,
                termination: ToolTermination::Cancelled { drained: true },
                duration: Duration::ZERO,
            });
        }
        let started = Instant::now();
        // The child starts suspended and is killed unless the retained
        // executable still verifies, so any failure here ran no tool code.
        let mut child = super::spawn_in(
            self,
            request.arguments,
            request.environment,
            directory.as_deref(),
        )
        .map_err(ToolRunError::Refused)?;
        let stdout = child.stdout.take().expect("spawn owns stdout");
        let stderr = child.stderr.take().expect("spawn owns stderr");
        let stop = Arc::new(AtomicBool::new(false));
        let out = capture(stdout, limits.capture_bytes, stop.clone());
        let err = capture(stderr, limits.capture_bytes, stop.clone());
        let (mut status, mut stdout, mut stderr) = (None, None, None);
        let mut failure = None;
        let ended = loop {
            poll(&out, &mut stdout);
            poll(&err, &mut stderr);
            if stdout.as_ref().is_some_and(Result::is_err)
                || stderr.as_ref().is_some_and(Result::is_err)
            {
                break None;
            }
            if status.is_none() {
                match child.try_wait() {
                    Ok(value) => status = value,
                    Err(error) => {
                        failure = Some(error);
                        break None;
                    }
                }
            }
            if status.is_some() && stdout.is_some() && stderr.is_some() {
                break None;
            }
            if cancelled() {
                break Some(Stop::Cancelled);
            }
            if started.elapsed() >= limits.timeout {
                break Some(Stop::TimedOut);
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        let stopped = match ended {
            Some(Stop::TimedOut) => {
                child.signal_group(libc::SIGTERM);
                let grace = Instant::now() + TERMINATION_GRACE;
                while Instant::now() < grace && matches!(child.try_wait(), Ok(None)) {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Some(ToolTermination::TimedOut)
            }
            Some(Stop::Cancelled) => Some(ToolTermination::Cancelled {
                drained: drain_group(&child),
            }),
            None => None,
        };
        let duration = started.elapsed();
        stop.store(true, Ordering::Release);
        // Collects the whole group, descendants holding output handles open
        // included, and reaps the child.
        let cleanup = child.kill_and_wait();
        let deadline = Instant::now() + READER_CLEANUP_TIMEOUT;
        let stdout = finish(&out, stdout, deadline);
        let stderr = finish(&err, stderr, deadline);
        let unobservable = ToolRunError::Unobservable;
        let ((stdout, stdout_dropped), (stderr, stderr_dropped)) = if stopped.is_some() {
            // A terminated child's partial output is kept, never judged.
            (stdout.unwrap_or_default(), stderr.unwrap_or_default())
        } else {
            if let Some(error) = failure {
                return Err(unobservable(error));
            }
            cleanup.map_err(unobservable)?;
            (stdout.map_err(unobservable)?, stderr.map_err(unobservable)?)
        };
        let termination = match stopped {
            Some(termination) => termination,
            None => {
                let status = status.expect("finished child");
                match (status.code(), status.signal()) {
                    (Some(code), _) => ToolTermination::Exited(code),
                    (None, Some(signal)) => ToolTermination::Signalled(signal),
                    (None, None) => {
                        return Err(unobservable(io::Error::other(
                            "unrecognized child wait status",
                        )));
                    }
                }
            }
        };
        Ok(ToolExecution {
            stdout,
            stderr,
            truncated: stdout_dropped || stderr_dropped,
            termination,
            duration,
        })
    }
}

/// Swift `FoundationProcessExecutor`'s environment validation: a caller names
/// every variable beyond the clean base explicitly, and none of them can
/// redirect the loader or the search path the identity-bound spawn fixed.
pub(super) fn validate_environment(environment: &[(OsString, OsString)]) -> io::Result<()> {
    for (key, value) in environment {
        let key = key.as_bytes();
        if key.is_empty()
            || key.contains(&b'=')
            || key.contains(&0)
            || value.as_bytes().contains(&0)
        {
            return Err(invalid(
                "environment keys and values must be non-empty NUL-free text",
            ));
        }
        if key == b"PATH"
            || key == b"LC_ALL"
            || key.starts_with(b"DYLD_")
            || key.starts_with(b"LD_")
        {
            return Err(invalid(
                "environment cannot override the search path or the loader",
            ));
        }
    }
    Ok(())
}

/// Swift's `workingDirectoryUnavailable` rule: absolute, canonical and an
/// existing directory; the daemon's own directory never changes.
pub(super) fn validate_working_directory(directory: &Path) -> io::Result<CString> {
    if !directory.is_absolute() || directory.as_os_str().as_bytes().contains(&0) {
        return Err(invalid(
            "working directory must be an absolute NUL-free path",
        ));
    }
    let canonical =
        std::fs::canonicalize(directory).map_err(|_| invalid("working directory unavailable"))?;
    if canonical != directory || !canonical.is_dir() {
        return Err(invalid("working directory unavailable"));
    }
    CString::new(canonical.as_os_str().as_bytes())
        .map_err(|_| invalid("working directory must be an absolute NUL-free path"))
}

/// Swift `terminateProcessGroup`: TERM the child's process group, KILL it if
/// a member is left after 0.25 s, and report whether none is left once the
/// following second is over.
pub(super) fn drain_group(child: &RunningChild) -> bool {
    child.signal_group(libc::SIGTERM);
    wait_until_drained(child, TERMINATION_GRACE) || {
        child.signal_group(libc::SIGKILL);
        wait_until_drained(child, KILL_GRACE)
    }
}

/// Swift `waitForGroupToDisappear`: the group looked for every 10 ms, and
/// once more when the time is up.
fn wait_until_drained(child: &RunningChild, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if child.group_drained() {
            return true;
        }
        std::thread::sleep(DRAIN_PROBE);
    }
    child.group_drained()
}

/// Swift `ProcessOutputBuffer.append`: keep the first `limit` bytes and note
/// that more arrived, reading on so the child never blocks on a full pipe.
/// The reader wakes when the pipe is readable, as Swift's does; a reader that
/// slept between empty reads would bound the child's output rate by its sleep.
pub(super) fn capture(
    mut pipe: File,
    limit: usize,
    stop: Arc<AtomicBool>,
) -> Receiver<io::Result<(Vec<u8>, bool)>> {
    let (sender, receiver) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let result = (|| {
            let mut kept = Vec::new();
            let mut dropped = false;
            let mut buffer = [0; 65536];
            loop {
                if stop.load(Ordering::Acquire) {
                    return Ok((kept, dropped));
                }
                let mut readable = libc::pollfd {
                    fd: pipe.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                // SAFETY: one live descriptor; the bounded wait keeps `stop`
                // observable when a descendant holds the pipe open.
                let ready = unsafe { libc::poll(&mut readable, 1, 50) };
                if ready < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error);
                }
                if ready == 0 {
                    continue;
                }
                // Drain what the pipe holds; the descriptor is nonblocking.
                loop {
                    let size = match pipe.read(&mut buffer) {
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                        value => value?,
                    };
                    if size == 0 {
                        return Ok((kept, dropped));
                    }
                    let room = limit.saturating_sub(kept.len());
                    kept.extend_from_slice(&buffer[..size.min(room)]);
                    dropped |= size > room;
                }
            }
        })();
        drop(pipe);
        let _ = sender.send(result);
    });
    receiver
}

pub(super) fn poll<T>(receiver: &Receiver<io::Result<T>>, result: &mut Option<io::Result<T>>) {
    if result.is_some() {
        return;
    }
    *result = match receiver.try_recv() {
        Ok(output) => Some(output),
        Err(TryRecvError::Empty) => None,
        Err(TryRecvError::Disconnected) => Some(Err(io::Error::other(
            "tool output reader stopped without a result",
        ))),
    };
}

pub(super) fn finish<T>(
    receiver: &Receiver<io::Result<T>>,
    result: Option<io::Result<T>>,
    deadline: Instant,
) -> io::Result<T> {
    result.unwrap_or_else(|| {
        receiver
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .map_err(|_| {
                io::Error::new(
                    io::ErrorKind::TimedOut,
                    "tool output reader did not finish after cleanup",
                )
            })?
    })
}
