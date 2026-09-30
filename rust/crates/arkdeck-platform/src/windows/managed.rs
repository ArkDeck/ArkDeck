//! A server the daemon launches and keeps on Windows, the port of the macOS
//! `ManagedServer` (`managed_server.rs`, Swift `HeadlessHDCServerHost`'s
//! foreground `hdc -s <endpoint> -m`) for TASK-XPA-005: created suspended by
//! `CreateProcessW` from the argv array inside its own kill-on-close Job
//! object, its launch provenance (PID, creation time, executable path and
//! digest, argv) recorded before it runs, both streams captured up to a
//! limit while the rest drains, and no budget. A server ends when it is
//! stopped (`TerminateJobObject`: the whole Job at once, Windows having no
//! TERM), when it exits on its own, or when its owner drops it (the Job is
//! terminated, and closing the Job handle kills anything left).
//!
//! The paired launch (`launch_paired`, `arkforged`) is not ported: no Windows
//! owner needs it yet (GJ-4/GJ-5).
use super::identity::{FileIdentity, ProcessIdentity};
use super::process::{RunningChild, spawn_in};
use super::server::{owns_local_listener, process_started_by_pid, unix_birth};
use super::tool::{Capture, validate_environment};
use crate::process::tool_request::MAX_CAPTURE_BYTES;
use crate::{
    ServerExit, ServerIdentityReceipt, ServerLaunch, ServerStop, VerifiedTool, denied, invalid,
};
use std::ffi::OsString;
use std::io;
use std::process::ExitStatus;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

type Captured = io::Result<(Vec<u8>, bool)>;

/// A launched server, alive until it is stopped or ends on its own.
pub struct ManagedServer {
    child: RunningChild,
    launch: ServerLaunch,
    /// The file the child's image was proved to be before it ran.
    image: FileIdentity,
    stop: Arc<AtomicBool>,
    out: Capture,
    err: Capture,
    stdout: Option<Captured>,
    stderr: Option<Captured>,
    exit: Option<ServerExit>,
}

impl ManagedServer {
    /// Spawns the verified tool with the arguments and the named environment
    /// (overlaid on the runner's clean base) and records its launch from the
    /// kernel while the child is still suspended. A tool whose identity no
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
        // The creation time is read while the child is still suspended, so a
        // server that exits at once is an exit its owner sees, never a launch
        // that could not be recorded.
        let mut child = spawn_in(tool, arguments, environment, None)?;
        let (start_seconds, start_microseconds) = unix_birth(child.started)?;
        let pid = i32::try_from(child.pid)
            .map_err(|_| io::Error::other("server launch could not be recorded from the kernel"))?;
        let stop = Arc::new(AtomicBool::new(false));
        let out = Capture::start(
            child.stdout.take().expect("spawn owns stdout"),
            capture_bytes,
            stop.clone(),
        );
        let err = Capture::start(
            child.stderr.take().expect("spawn owns stderr"),
            capture_bytes,
            stop.clone(),
        );
        Ok(Self {
            child,
            launch: ServerLaunch {
                pid,
                start_seconds,
                start_microseconds,
                executable_path: tool.path.clone(),
                executable_sha256: tool.sha256().to_string(),
                arguments: arguments.to_vec(),
            },
            image: tool.identity.clone(),
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

    /// Swift `sameBirth`: the kernel still reports the launch's creation
    /// time for its PID, so the PID names this child.
    pub fn same_birth(&self) -> bool {
        process_started_by_pid(self.child.pid) == Some(self.child.started)
    }

    /// How the server ended, if it has; `None` while it runs.
    pub fn exit(&mut self) -> io::Result<Option<ServerExit>> {
        if let Some(exit) = self.exit {
            return Ok(Some(exit));
        }
        self.out.poll(&mut self.stdout);
        self.err.poll(&mut self.stderr);
        let Some(status) = self.child.try_wait()? else {
            return Ok(None);
        };
        let exit = classify(status)?;
        self.exit = Some(exit);
        Ok(Some(exit))
    }

    /// Ends the server — its whole Job at once — or takes the end it already
    /// had, and collects what it wrote.
    pub fn stop(mut self) -> io::Result<ServerStop> {
        let exit = match self.exit()? {
            Some(exit) => exit,
            None => {
                self.child.kill_and_wait()?;
                match self.child.try_wait()? {
                    Some(status) => classify(status)?,
                    None => return Err(io::Error::other("server did not end after termination")),
                }
            }
        };
        self.child.kill_and_wait()?;
        self.stop.store(true, Ordering::Release);
        let deadline = Instant::now() + crate::process::READER_CLEANUP_TIMEOUT;
        let (stdout, stdout_dropped) = self.out.finish(self.stdout.take(), deadline)?;
        let (stderr, stderr_dropped) = self.err.finish(self.stderr.take(), deadline)?;
        Ok(ServerStop {
            stdout,
            stderr,
            truncated: stdout_dropped || stderr_dropped,
            exit,
        })
    }

    /// The Windows form of `verifies_managed_process`, without argv: Windows
    /// has no supported read of another process's command line, so the argv
    /// is proved by provenance instead — this server was launched with
    /// exactly `launch_record().arguments`, and the receipt must name this
    /// very child. It holds when the receipt carries a representable
    /// generation; names the launch's PID, creation time, executable path
    /// and digest; that PID still has the creation time (read before and
    /// after the rest); the process it names is alive, runs the file the
    /// launch proved, and is a member of this server's own Job object; the
    /// launch's argv declares the receipt's endpoint (`-s <endpoint>`); and
    /// the process owns a TCP listener on that endpoint's port bound to the
    /// loopback or a wildcard.
    pub fn verifies(&self, receipt: &ServerIdentityReceipt) -> bool {
        let generation = receipt
            .start_seconds
            .checked_mul(1_000_000)
            .and_then(|seconds| seconds.checked_add(receipt.start_microseconds));
        if !generation.is_some_and(|generation| generation > 0 && generation <= i64::MAX as u64) {
            return false;
        }
        let launch = &self.launch;
        if (
            receipt.pid,
            receipt.start_seconds,
            receipt.start_microseconds,
            &receipt.executable_path,
            &receipt.executable_sha256,
        ) != (
            launch.pid,
            launch.start_seconds,
            launch.start_microseconds,
            &launch.executable_path,
            &launch.executable_sha256,
        ) {
            return false;
        }
        if !self.same_birth() {
            return false;
        }
        self.matches(receipt).unwrap_or(false) && self.same_birth()
    }

    fn matches(&self, receipt: &ServerIdentityReceipt) -> io::Result<bool> {
        if self.child.try_wait()?.is_some() {
            return Ok(false);
        }
        let pid = u32::try_from(receipt.pid).map_err(|_| denied("negative PID"))?;
        let process = ProcessIdentity::open(pid)?;
        if process.started != self.child.started
            || process.path != self.launch.executable_path
            || super::file_identity(&process.image)? != self.image
            || !self.child.job_contains(process.process.raw())?
        {
            return Ok(false);
        }
        let endpoint = receipt.endpoint.to_string();
        let declares = self
            .launch
            .arguments
            .iter()
            .position(|argument| argument == "-s")
            .and_then(|option| self.launch.arguments.get(option + 1))
            .is_some_and(|argument| *argument == *endpoint);
        Ok(declares && owns_local_listener(pid, receipt.endpoint)?)
    }
}

fn classify(status: ExitStatus) -> io::Result<ServerExit> {
    status
        .code()
        .map(ServerExit::Exited)
        .ok_or_else(|| io::Error::other("unrecognized server exit status"))
}
