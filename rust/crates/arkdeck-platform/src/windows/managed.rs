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
//! A paired server (`launch_paired`, Swift's `IdentityBoundDaemonLauncher`,
//! which starts `arkforged`; TASK-XPA-010) is also handed one secret on
//! stdin, and the write end of that pipe stays with its owner as the
//! server's liveness: its close is the server's end of input, the proof its
//! owning generation is gone. Its stop closes that input first, gives the
//! server the half second macOS gives it before KILL to end on its own, and
//! only then terminates its Job.
use super::identity::{FileIdentity, ProcessIdentity};
use super::process::{RunningChild, input_pipe, spawn_in, spawn_paired};
use super::server::{owns_local_listener, process_started_by_pid, unix_birth};
use super::tool::{Capture, validate_environment};
use crate::process::tool_request::MAX_CAPTURE_BYTES;
use crate::{
    ServerExit, ServerIdentityReceipt, ServerLaunch, ServerStop, VerifiedTool, denied, invalid,
};
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Write};
use std::path::Path;
use std::process::ExitStatus;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// How long a paired server has, after its end of input, to end on its own
/// before its Job is terminated: macOS's `stopDaemonProcessGroup` sends TERM
/// (which `arkforged` starts ignoring) and KILLs half a second later.
/// Windows has no TERM, so the end of input alone opens that half second.
const PAIRED_INPUT_GRACE: Duration = Duration::from_millis(500);

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
    /// A paired server's liveness: the write end of its stdin.
    liveness: Option<File>,
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
        Self::spawn(tool, arguments, environment, None, capture_bytes)
    }

    /// Swift `IdentityBoundDaemonLauncher.launch`: the verified tool in its
    /// own Job, run in `working_directory` (absolute and canonical, as a tool
    /// request's), handed `secret` on stdin; the pipe's write end stays open
    /// in the returned server. `secret` is written and never kept. A child
    /// the whole secret did not reach is stopped and its launch refused: it
    /// could never pair, and nothing is left running unpaired.
    ///
    /// Windows has no signal disposition to hand the child: there is no
    /// TERM, and a console break cannot reach a child created without a
    /// console. Its end of input is the only way its owner asks it to end.
    pub fn launch_paired(
        tool: &VerifiedTool,
        arguments: &[OsString],
        environment: &[(OsString, OsString)],
        working_directory: &Path,
        secret: &[u8],
        capture_bytes: usize,
    ) -> io::Result<Self> {
        let directory = super::tool::validate_working_directory(working_directory)?;
        let (read, write) = input_pipe()?;
        let mut server = Self::spawn(
            tool,
            arguments,
            environment,
            Some((&directory, &read)),
            capture_bytes,
        )?;
        drop(read);
        let mut liveness = write.into_file();
        if let Err(error) = liveness.write_all(secret) {
            drop(liveness);
            let _ = server.child.kill_and_wait();
            return Err(io::Error::other(format!(
                "the child started but the secret did not reach it ({error}); it is left \
                 unpaired rather than started with a partial handshake"
            )));
        }
        server.liveness = Some(liveness);
        Ok(server)
    }

    fn spawn(
        tool: &VerifiedTool,
        arguments: &[OsString],
        environment: &[(OsString, OsString)],
        paired: Option<(&[u16], &super::Handle)>,
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
        let mut child = match paired {
            None => spawn_in(tool, arguments, environment, None)?,
            Some((directory, input)) => {
                spawn_paired(tool, arguments, environment, directory, input)?
            }
        };
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
            liveness: None,
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

    /// Ends the server — a paired server's end of input first, then its
    /// whole Job at once — or takes the end it already had, and collects
    /// what it wrote.
    pub fn stop(mut self) -> io::Result<ServerStop> {
        let exit = self.end()?;
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

    /// The end `stop` gives a server: a paired server's end of input, then
    /// the half second it has to end on its own, then its Job terminated;
    /// or the end it already had.
    fn end(&mut self) -> io::Result<ServerExit> {
        let paired = self.liveness.take().is_some();
        if let Some(exit) = self.exit()? {
            return Ok(exit);
        }
        if paired {
            let deadline = Instant::now() + PAIRED_INPUT_GRACE;
            while Instant::now() < deadline {
                if let Some(exit) = self.exit()? {
                    return Ok(exit);
                }
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        self.child.kill_and_wait()?;
        match self.child.try_wait()? {
            Some(status) => classify(status),
            None => Err(io::Error::other("server did not end after termination")),
        }
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

/// A paired server its owner lets go of without stopping it is ended as its
/// stop ends it: its end of input first, so that it sees its owner go, and
/// only then its Job. Left to the child's own drop, its Job would be
/// terminated before its input closed. An unpaired server is still left to
/// that drop, and a server `stop` ended has nothing left here.
impl Drop for ManagedServer {
    fn drop(&mut self) {
        if self.liveness.is_none() {
            return;
        }
        let _ = self.end();
        let _ = self.child.kill_and_wait();
        self.stop.store(true, Ordering::Release);
    }
}

fn classify(status: ExitStatus) -> io::Result<ServerExit> {
    status
        .code()
        .map(ServerExit::Exited)
        .ok_or_else(|| io::Error::other("unrecognized server exit status"))
}
