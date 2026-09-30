//! One verified tool child on Windows, as the macOS runner (`tool_process.rs`)
//! runs it for a descriptor-bound provider dispatch (TASK-XPA-005, gate
//! inventory group 5): the pinned executable created suspended by
//! `CreateProcessW` from the argv array (never `cmd.exe` or PowerShell),
//! admitted into a kill-on-close Job object and resumed only once its image
//! is proved to be the retained file; a caller-named environment overlaid on
//! the clean base; a child-only working directory; `NUL` as stdin; each
//! output stream kept to its first bytes while the rest is drained unread; a
//! deadline and a cancellation probe that terminate the whole Job.
//!
//! Windows has no TERM: where macOS gives the group 0.25 s after TERM before
//! KILL, the Job is terminated at once (`TerminateJobObject`). The outcome
//! and its code are the same (`TimedOut`, `Cancelled { drained }`); only the
//! grace a child could have used to exit on its own is absent (T1, recorded
//! as a proposal in the run record).
use super::process::{BASE_ENVIRONMENT, PipeReader, RunningChild, spawn_in, uppercase};
use super::{bool_result, wide};
use crate::process::tool_request::check_limits;
use crate::process::{
    READER_CLEANUP_TIMEOUT, ToolExecution, ToolRequest, ToolRunError, ToolTermination,
};
use crate::{VerifiedTool, invalid};
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Read};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::AsRawHandle;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::ERROR_OPERATION_ABORTED;
use windows_sys::Win32::System::IO::CancelSynchronousIo;

/// Swift `terminateProcessGroup`: how long a killed group has to disappear.
const KILL_GRACE: Duration = Duration::from_secs(1);
/// Swift `waitForGroupToDisappear`: how often the group is looked for.
const DRAIN_PROBE: Duration = Duration::from_millis(10);

/// Names the overlay can never set: the base itself, and the application
/// compatibility layer, which would change how the verified image runs.
const RESERVED_ENVIRONMENT: [&str; 1] = ["__COMPAT_LAYER"];

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
        check_limits(limits).map_err(ToolRunError::Refused)?;
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
        let mut child = spawn_in(
            self,
            request.arguments,
            request.environment,
            directory.as_deref(),
        )
        .map_err(ToolRunError::Refused)?;
        let stop = Arc::new(AtomicBool::new(false));
        let out = Capture::start(
            child.stdout.take().expect("spawn owns stdout"),
            limits.capture_bytes,
            stop.clone(),
        );
        let err = Capture::start(
            child.stderr.take().expect("spawn owns stderr"),
            limits.capture_bytes,
            stop.clone(),
        );
        let (mut status, mut stdout, mut stderr) = (None, None, None);
        let mut failure = None;
        let ended = loop {
            out.poll(&mut stdout);
            err.poll(&mut stderr);
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
            Some(Stop::TimedOut) => Some(ToolTermination::TimedOut),
            Some(Stop::Cancelled) => Some(ToolTermination::Cancelled {
                drained: drain_group(&child),
            }),
            None => None,
        };
        let duration = started.elapsed();
        stop.store(true, Ordering::Release);
        // Terminates the whole Job, descendants holding output handles open
        // included, and waits for it to be empty.
        let cleanup = child.kill_and_wait();
        let deadline = Instant::now() + READER_CLEANUP_TIMEOUT;
        let stdout = out.finish(stdout, deadline);
        let stderr = err.finish(stderr, deadline);
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
            None => match status.expect("finished child").code() {
                Some(code) => ToolTermination::Exited(code),
                None => {
                    return Err(unobservable(io::Error::other(
                        "unrecognized child exit status",
                    )));
                }
            },
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

/// Swift `FoundationProcessExecutor`'s environment validation on Windows:
/// every variable beyond the clean base is named explicitly, none of them
/// can replace the base (`PATH`, `SystemRoot`, `WINDIR`, compared as Windows
/// compares names, ignoring case) or the compatibility layer, and no name is
/// given twice.
pub(crate) fn validate_environment(environment: &[(OsString, OsString)]) -> io::Result<()> {
    let mut seen: Vec<Vec<u16>> = Vec::new();
    for (key, value) in environment {
        let name: Vec<u16> = key.encode_wide().collect();
        if name.is_empty()
            || name.contains(&u16::from(b'='))
            || name.contains(&0)
            || value.encode_wide().any(|unit| unit == 0)
        {
            return Err(invalid(
                "environment keys and values must be non-empty NUL-free text",
            ));
        }
        let folded = uppercase(&name);
        if BASE_ENVIRONMENT
            .iter()
            .chain(RESERVED_ENVIRONMENT.iter())
            .any(|reserved| uppercase(&reserved.encode_utf16().collect::<Vec<_>>()) == folded)
        {
            return Err(invalid(
                "environment cannot override the search path or the loader",
            ));
        }
        if seen.contains(&folded) {
            return Err(invalid("environment names a variable twice"));
        }
        seen.push(folded);
    }
    Ok(())
}

/// Swift's `workingDirectoryUnavailable` rule on Windows: absolute, equal to
/// its own canonical form (`\\?\` spelled, as `VerifiedTool` paths are) and
/// an existing directory; the daemon's own directory never changes.
pub(crate) fn validate_working_directory(directory: &Path) -> io::Result<Vec<u16>> {
    if !directory.is_absolute() || directory.as_os_str().encode_wide().any(|unit| unit == 0) {
        return Err(invalid(
            "working directory must be an absolute NUL-free path",
        ));
    }
    let canonical =
        std::fs::canonicalize(directory).map_err(|_| invalid("working directory unavailable"))?;
    if canonical != directory || !canonical.is_dir() {
        return Err(invalid("working directory unavailable"));
    }
    wide(canonical.as_os_str())
}

/// Swift `terminateProcessGroup` on Windows: the Job is terminated at once,
/// and reported drained when none of its processes is left within the
/// second that follows.
fn drain_group(child: &RunningChild) -> bool {
    if child.terminate_group().is_err() {
        return false;
    }
    let deadline = Instant::now() + KILL_GRACE;
    loop {
        match child.group_drained() {
            Ok(true) => return true,
            Ok(false) => {}
            Err(_) => return false,
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(DRAIN_PROBE);
    }
}

type Captured = io::Result<(Vec<u8>, bool)>;

/// Swift `ProcessOutputBuffer.append` over one anonymous pipe: keep the first
/// `limit` bytes and note that more arrived, reading on so the child never
/// blocks on a full pipe. The reader blocks in `ReadFile` and so wakes as
/// soon as bytes arrive; the owner cancels that read (`CancelSynchronousIo`)
/// once it stops, for a writer that outlived the Job cannot keep it.
pub(crate) struct Capture {
    receiver: Receiver<Captured>,
    thread: JoinHandle<()>,
}

impl Capture {
    pub(crate) fn start(pipe: PipeReader, limit: usize, stop: Arc<AtomicBool>) -> Self {
        let mut pipe: File = pipe.into_file();
        let (sender, receiver) = mpsc::sync_channel(1);
        let thread = std::thread::spawn(move || {
            let result = (|| {
                let mut kept = Vec::new();
                let mut dropped = false;
                let mut buffer = vec![0; 65536];
                loop {
                    if stop.load(Ordering::Acquire) {
                        return Ok((kept, dropped));
                    }
                    let size = match pipe.read(&mut buffer) {
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => 0,
                        Err(error)
                            if error.raw_os_error() == Some(ERROR_OPERATION_ABORTED as i32) =>
                        {
                            // Only the owner cancels, and only once it stopped.
                            continue;
                        }
                        value => value?,
                    };
                    if size == 0 {
                        return Ok((kept, dropped));
                    }
                    let room = limit.saturating_sub(kept.len());
                    kept.extend_from_slice(&buffer[..size.min(room)]);
                    dropped |= size > room;
                }
            })();
            drop(pipe);
            let _ = sender.send(result);
        });
        Self { receiver, thread }
    }

    pub(crate) fn poll(&self, result: &mut Option<Captured>) {
        if result.is_some() {
            return;
        }
        *result = match self.receiver.try_recv() {
            Ok(output) => Some(output),
            Err(TryRecvError::Empty) => None,
            Err(TryRecvError::Disconnected) => Some(Err(io::Error::other(
                "tool output reader stopped without a result",
            ))),
        };
    }

    /// The reader's result once the owner has stopped it: its blocked read
    /// cancelled until it answers, never waited for past `deadline`.
    pub(crate) fn finish(&self, result: Option<Captured>, deadline: Instant) -> Captured {
        if let Some(result) = result {
            return result;
        }
        loop {
            let wait = deadline
                .saturating_duration_since(Instant::now())
                .min(Duration::from_millis(10));
            match self.receiver.recv_timeout(wait) {
                Ok(result) => return result,
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(io::Error::other(
                        "tool output reader stopped without a result",
                    ));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "tool output reader did not finish after cleanup",
                ));
            }
            // SAFETY: the reader thread is live or has just ended (its
            // handle stays valid while the JoinHandle is held); with no read
            // pending this cancels nothing and fails harmlessly.
            let _ = bool_result(unsafe { CancelSynchronousIo(self.thread.as_raw_handle()) });
        }
    }
}
