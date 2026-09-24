//! A server the daemon launches and keeps, as Swift's `HeadlessHDCServerHost`
//! keeps its foreground `hdc -s <endpoint> -m`: spawned through the verified
//! tool's retained inode in its own process group, its launch provenance read
//! from the kernel at once (PID and birth time, executable path and digest,
//! argv), both streams captured up to a limit while the rest drains, and no
//! budget — a server ends when it is stopped or when it exits on its own,
//! which its owner notices by asking. Nothing here reads an endpoint or
//! decides readiness; that is the provider's, over this.
//!
//! A paired server (Swift's `IdentityBoundDaemonLauncher`, which starts
//! `arkforged`) is also handed one secret on stdin, and the write end of that
//! pipe stays with its owner as the server's liveness: its close is the
//! server's end of input, the proof its owning generation is gone.
use super::macos_process::{RunningChild, input_pipe, spawn_suspended};
use super::tool_process::{
    MAX_CAPTURE_BYTES, capture, drain_group, drain_group_within, finish, poll, validate_environment,
};
use super::{READER_CLEANUP_TIMEOUT, VerifiedTool, invalid};
use crate::macos_server::process_birth;
use std::ffi::{CString, OsString};
use std::fs::File;
use std::io::{self, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

/// Swift's `stopDaemonProcessGroup`: half a second after TERM, half a second
/// after KILL, short of launchd's own budget for the owner's exit.
const PAIRED_TERMINATION_GRACE: Duration = Duration::from_millis(500);
const PAIRED_KILL_GRACE: Duration = Duration::from_millis(500);

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
    /// A paired server's liveness: the write end of its stdin.
    liveness: Option<File>,
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
        Self::spawn(tool, arguments, environment, None, None, capture_bytes)
    }

    /// Swift `IdentityBoundDaemonLauncher.launch`: the verified tool in its own
    /// process group, run in `working_directory`, handed `secret` on stdin; the
    /// pipe's write end stays open in the returned server. `secret` is written
    /// and never kept. A child the whole secret did not reach is stopped and
    /// its launch refused: it could never pair, and nothing is left running
    /// unpaired.
    pub fn launch_paired(
        tool: &VerifiedTool,
        arguments: &[OsString],
        environment: &[(OsString, OsString)],
        working_directory: &Path,
        secret: &[u8],
        capture_bytes: usize,
    ) -> io::Result<Self> {
        let directory = CString::new(working_directory.as_os_str().as_bytes())
            .map_err(|_| invalid("NUL in working directory"))?;
        let (read, write) = input_pipe()?;
        let mut server = Self::spawn(
            tool,
            arguments,
            environment,
            Some(&directory),
            Some(&read),
            capture_bytes,
        )?;
        drop(read);
        let mut liveness = File::from(write);
        if let Err(error) = liveness.write_all(secret) {
            drop(liveness);
            drain_group_within(&server.child, PAIRED_TERMINATION_GRACE, PAIRED_KILL_GRACE);
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
        working_directory: Option<&CString>,
        stdin: Option<&std::os::fd::OwnedFd>,
        capture_bytes: usize,
    ) -> io::Result<Self> {
        if capture_bytes == 0 || capture_bytes > MAX_CAPTURE_BYTES {
            return Err(invalid("server capture must be 1 byte..64 MiB per stream"));
        }
        validate_environment(environment)?;
        tool.revalidate()?;
        // The birth is read while the child is still suspended, before it can
        // run — or end: a server that exits at once (Swift's
        // `foregroundExitReason`) is then an exit its owner sees, never a
        // launch that "could not be recorded" because a zombie has no birth.
        let suspended = spawn_suspended(
            tool,
            arguments,
            environment,
            working_directory.map(CString::as_c_str),
            stdin,
        )?;
        let pid = suspended.pid();
        let birth = process_birth(pid)
            .filter(|birth| birth.start_seconds > 0 && birth.start_microseconds < 1_000_000)
            .ok_or_else(|| {
                io::Error::other("server launch could not be recorded from the kernel")
            })?;
        let mut child = suspended.resume()?;
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
            liveness: None,
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
        // A paired server's end of input first, so that a server handling
        // TERM cannot briefly keep serving an owner that is gone.
        let paired = self.liveness.take().is_some();
        let exit = match self.exit()? {
            Some(exit) => exit,
            None => {
                if paired {
                    drain_group_within(&self.child, PAIRED_TERMINATION_GRACE, PAIRED_KILL_GRACE);
                } else {
                    drain_group(&self.child);
                }
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

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::time::{Duration, Instant};

    /// Swift's foreground server that exits at once: its launch is recorded
    /// (the birth is read while the child is still suspended) and its exit is
    /// what the owner sees — on every launch, not only when the parent wins
    /// the race to the kernel.
    #[test]
    fn a_server_that_ends_at_once_is_recorded_and_reports_its_exit() {
        let root =
            std::env::temp_dir().join(format!("arkdeck-managed-birth-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let script = root.join("ends-at-once");
        fs::write(&script, "#!/bin/sh\nexit 3\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        let digest = format!("{:x}", Sha256::digest(fs::read(&script).unwrap()));
        let tool = VerifiedTool::open(&script, &digest).unwrap();
        for launch in 0..50 {
            let mut server = ManagedServer::launch(&tool, &[], &[], 4096)
                .unwrap_or_else(|error| panic!("launch {launch}: {error}"));
            let record = server.launch_record().clone();
            assert!(record.start_seconds > 0 && record.start_microseconds < 1_000_000);
            let deadline = Instant::now() + Duration::from_secs(20);
            let exit = loop {
                if let Some(exit) = server.exit().unwrap() {
                    break exit;
                }
                assert!(Instant::now() < deadline, "launch {launch} did not end");
                std::thread::sleep(Duration::from_millis(5));
            };
            assert_eq!(exit, ServerExit::Exited(3), "launch {launch}");
            assert_eq!(server.stop().unwrap().exit, ServerExit::Exited(3));
        }
        let _ = fs::remove_dir_all(&root);
    }

    /// Swift `IdentityBoundDaemonLauncher`: the secret arrives on stdin, whole
    /// and nowhere else, in the named working directory; the write end is the
    /// owner's alone, so closing it is the server's end of input. The stand-in
    /// ignores TERM, as a service may, so its exit 11 on end of input is what
    /// proves the owner closed its liveness first.
    #[test]
    fn a_paired_server_reads_its_secret_and_ends_when_its_owner_lets_go() {
        let root =
            std::env::temp_dir().join(format!("arkdeck-managed-paired-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("run")).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let script = root.join("paired");
        fs::write(
            &script,
            "#!/bin/sh\ntrap '' TERM\npwd -P > cwd\nhead -c 32 > secret\ncat > rest\nexit 11\n",
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        let digest = format!("{:x}", Sha256::digest(fs::read(&script).unwrap()));
        let tool = VerifiedTool::open(&script, &digest).unwrap();
        let secret: Vec<u8> = (0u8..32).map(|byte| byte.wrapping_mul(7)).collect();
        let run = fs::canonicalize(root.join("run")).unwrap();
        let mut server =
            ManagedServer::launch_paired(&tool, &[], &[], &run, &secret, 4096).unwrap();
        let deadline = Instant::now() + Duration::from_secs(20);
        while fs::read(run.join("secret")).map_or(true, |bytes| bytes.len() < 32) {
            assert!(Instant::now() < deadline, "the secret never arrived");
            std::thread::sleep(Duration::from_millis(5));
        }
        // It keeps running while its owner holds on.
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(server.exit().unwrap(), None);
        assert_eq!(fs::read(run.join("secret")).unwrap(), secret);
        assert_eq!(
            fs::read_to_string(run.join("cwd")).unwrap().trim_end(),
            run.to_str().unwrap()
        );
        let stopped = server.stop().unwrap();
        assert_eq!(stopped.exit, ServerExit::Exited(11));
        // Nothing but the secret ever crossed the pipe.
        assert!(fs::read(run.join("rest")).unwrap().is_empty());
        let _ = fs::remove_dir_all(&root);
    }
}
