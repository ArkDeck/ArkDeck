//! A server the daemon launches and keeps, as Swift's `HeadlessHDCServerHost`
//! keeps its foreground `hdc -s <endpoint> -m`: spawned through the verified
//! tool's retained inode in its own process group, its launch provenance read
//! from the kernel at once (PID and birth time, executable path and digest,
//! argv), both streams captured up to a limit while the rest drains, and no
//! budget — a server ends when it is stopped or when it exits on its own,
//! which its owner notices by asking. Nothing here reads an endpoint or
//! decides readiness; that is the provider's, over this.
use super::macos_process::{RunningChild, spawn_in};
use super::tool_process::{
    MAX_CAPTURE_BYTES, capture, drain_group, finish, poll, validate_environment,
};
use super::{READER_CLEANUP_TIMEOUT, VerifiedTool, invalid};
use crate::macos_server::process_birth;
use std::ffi::OsString;
use std::io;
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::ExitStatus;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::time::Instant;

/// Swift `HDCManagedProcessLaunch`: what the spawn itself recorded, which no
/// reader can manufacture later from a PID or an endpoint.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerLaunch {
    pub pid: i32,
    pub start_seconds: u64,
    pub start_microseconds: u64,
    pub executable_path: PathBuf,
    pub executable_sha256: String,
    pub arguments: Vec<OsString>,
}

/// How a server ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServerExit {
    Exited(i32),
    Signalled(i32),
}

/// What a stopped server left: both streams as captured and how it ended.
#[derive(Debug)]
pub struct ServerStop {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// Either stream went past the capture.
    pub truncated: bool,
    pub exit: ServerExit,
}

type Captured = io::Result<(Vec<u8>, bool)>;

/// A launched server, alive until it is stopped or ends on its own.
pub struct ManagedServer {
    child: RunningChild,
    launch: ServerLaunch,
    stop: Arc<AtomicBool>,
    out: Receiver<Captured>,
    err: Receiver<Captured>,
    stdout: Option<Captured>,
    stderr: Option<Captured>,
    exit: Option<ServerExit>,
}

impl ManagedServer {
    /// Spawns the verified tool with the arguments and the named environment
    /// (overlaid on the runner's clean base) and records its launch from the
    /// kernel before anything else can happen to it. A tool whose identity no
    /// longer verifies, an environment the runner refuses, or a capture
    /// outside 1 byte..64 MiB launches nothing.
    pub fn launch(
        tool: &VerifiedTool,
        arguments: &[OsString],
        environment: &[(OsString, OsString)],
        capture_bytes: usize,
    ) -> io::Result<Self> {
        if capture_bytes == 0 || capture_bytes > MAX_CAPTURE_BYTES {
            return Err(invalid("server capture must be 1 byte..64 MiB per stream"));
        }
        validate_environment(environment)?;
        tool.revalidate()?;
        let mut child = spawn_in(tool, arguments, environment, None)?;
        let pid = child.pid();
        let birth = process_birth(pid)
            .filter(|birth| birth.start_seconds > 0 && birth.start_microseconds < 1_000_000)
            .ok_or_else(|| {
                io::Error::other("server launch could not be recorded from the kernel")
            })?;
        let stop = Arc::new(AtomicBool::new(false));
        let out = capture(
            child.stdout.take().expect("spawn owns stdout"),
            capture_bytes,
            stop.clone(),
        );
        let err = capture(
            child.stderr.take().expect("spawn owns stderr"),
            capture_bytes,
            stop.clone(),
        );
        Ok(Self {
            child,
            launch: ServerLaunch {
                pid,
                start_seconds: birth.start_seconds,
                start_microseconds: birth.start_microseconds,
                executable_path: std::fs::canonicalize(&tool.path)
                    .unwrap_or_else(|_| tool.path.clone()),
                executable_sha256: tool.sha256().to_string(),
                arguments: arguments.to_vec(),
            },
            stop,
            out,
            err,
            stdout: None,
            stderr: None,
            exit: None,
        })
    }

    pub fn launch_record(&self) -> &ServerLaunch {
        &self.launch
    }

    /// Swift `sameBirth`: the kernel still reports the launch's birth for its
    /// PID, so the PID has not been recycled.
    pub fn same_birth(&self) -> bool {
        process_birth(self.launch.pid).is_some_and(|birth| {
            (birth.start_seconds, birth.start_microseconds)
                == (self.launch.start_seconds, self.launch.start_microseconds)
        })
    }

    /// How the server ended, if it has; `None` while it runs.
    pub fn exit(&mut self) -> io::Result<Option<ServerExit>> {
        if let Some(exit) = self.exit {
            return Ok(Some(exit));
        }
        poll(&self.out, &mut self.stdout);
        poll(&self.err, &mut self.stderr);
        let Some(status) = self.child.try_wait()? else {
            return Ok(None);
        };
        let exit = classify(status);
        self.exit = Some(exit);
        Ok(Some(exit))
    }

    /// Ends the server — TERM to its group, then KILL — or takes the end it
    /// already had, and collects what it wrote.
    pub fn stop(mut self) -> io::Result<ServerStop> {
        let exit = match self.exit()? {
            Some(exit) => exit,
            None => {
                drain_group(&self.child);
                match self.child.try_wait()? {
                    Some(status) => classify(status),
                    None => return Err(io::Error::other("server did not end after termination")),
                }
            }
        };
        self.child.kill_and_wait()?;
        self.stop.store(true, Ordering::Release);
        let deadline = Instant::now() + READER_CLEANUP_TIMEOUT;
        let (stdout, stdout_dropped) = finish(&self.out, self.stdout.take(), deadline)?;
        let (stderr, stderr_dropped) = finish(&self.err, self.stderr.take(), deadline)?;
        Ok(ServerStop {
            stdout,
            stderr,
            truncated: stdout_dropped || stderr_dropped,
            exit,
        })
    }
}

fn classify(status: ExitStatus) -> ServerExit {
    match (status.code(), status.signal()) {
        (Some(code), _) => ServerExit::Exited(code),
        (None, Some(signal)) => ServerExit::Signalled(signal),
        (None, None) => ServerExit::Exited(status.into_raw()),
    }
}
