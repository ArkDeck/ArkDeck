use crate::{denied, invalid};
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::fs::{File, Metadata};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::time::{Duration, Instant};

const MAX_TOOL_BYTES: u64 = 512 * 1024 * 1024;
pub(crate) const CLEANUP_TIMEOUT: Duration = Duration::from_secs(5);
const READER_CLEANUP_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug)]
pub struct ProcessLimits {
    pub timeout: Duration,
    /// Combined stdout and stderr limit, not a separate budget for each pipe.
    pub max_output_bytes: usize,
}

impl Default for ProcessLimits {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(10),
            max_output_bytes: 1024 * 1024,
        }
    }
}

#[derive(Debug)]
pub struct ProcessOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub status: ExitStatus,
}

/// A retained regular-file handle with a caller-supplied, trusted hash pin.
/// No executable is selected by name search and no shell is invoked.
pub struct VerifiedTool {
    pub(crate) file: File,
    pub(crate) path: PathBuf,
    sha256: String,
    initial: Metadata,
    #[cfg(windows)]
    pub(crate) identity: crate::windows::FileIdentity,
    #[cfg(windows)]
    _namespace: Vec<File>,
}

impl VerifiedTool {
    pub fn open(path: impl AsRef<Path>, expected_sha256: &str) -> io::Result<Self> {
        let path = path.as_ref();
        if !path.is_absolute()
            || expected_sha256.len() != 64
            || !expected_sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(invalid(
                "executable requires an absolute path and lowercase SHA256",
            ));
        }
        if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
            return Err(denied("executable symlink is not accepted"));
        }
        let path = path.canonicalize()?;
        #[cfg(windows)]
        let namespace = crate::windows::lock_namespace(&path)?;
        let file = open_locked_file(&path)?;
        let initial = file.metadata()?;
        validate_metadata(&initial)?;
        #[cfg(windows)]
        let identity = crate::windows::file_identity(&file)?;
        let tool = Self {
            file,
            path,
            sha256: expected_sha256.into(),
            initial,
            #[cfg(windows)]
            identity,
            #[cfg(windows)]
            _namespace: namespace,
        };
        tool.revalidate()?;
        Ok(tool)
    }

    pub fn sha256(&self) -> &str {
        &self.sha256
    }

    pub fn run_read_only(
        &self,
        args: &[OsString],
        limits: ProcessLimits,
    ) -> io::Result<ProcessOutput> {
        self.run_read_only_with_environment(args, &[], limits)
    }

    /// Only provider-owned HDC endpoint selection may extend the clean child
    /// environment. PATH, dynamic-loader variables and shell text are rejected.
    pub fn run_read_only_with_environment(
        &self,
        args: &[OsString],
        environment: &[(OsString, OsString)],
        limits: ProcessLimits,
    ) -> io::Result<ProcessOutput> {
        if limits.timeout.is_zero()
            || limits.timeout > Duration::from_secs(60)
            || limits.max_output_bytes == 0
            || limits.max_output_bytes > 8 * 1024 * 1024
        {
            return Err(invalid(
                "read-only process budget must be 1..60 seconds and 1..8 MiB",
            ));
        }
        if environment.len() > 1
            || environment.iter().any(|(key, value)| {
                key != "OHOS_HDC_SERVER_PORT"
                    || value
                        .to_str()
                        .and_then(|v| v.parse::<u16>().ok())
                        .is_none_or(|v| v == 0)
            })
        {
            return Err(invalid(
                "only a numeric provider-owned HDC server port is allowed",
            ));
        }
        self.revalidate()?;
        let started = Instant::now();
        let mut child = spawn(self, args, environment)?;
        // Spawn is identity-bound; recheck retained bytes before consuming output.
        if let Err(error) = self.revalidate() {
            child.kill_and_wait()?;
            return Err(error);
        }
        let stdout = child.stdout.take().expect("spawn owns stdout");
        let stderr = child.stderr.take().expect("spawn owns stderr");
        let count = Arc::new(AtomicUsize::new(0));
        let overflow = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let out = reader(
            stdout,
            count.clone(),
            overflow.clone(),
            stop.clone(),
            limits.max_output_bytes,
        );
        let err = reader(
            stderr,
            count,
            overflow.clone(),
            stop.clone(),
            limits.max_output_bytes,
        );
        let mut status = None;
        let mut stdout = None;
        let mut stderr = None;
        let failure = loop {
            poll_reader(&out, &mut stdout);
            poll_reader(&err, &mut stderr);
            if overflow.load(Ordering::Acquire) {
                break Some(io::Error::new(
                    io::ErrorKind::FileTooLarge,
                    "combined process output limit exceeded",
                ));
            }
            if stdout.as_ref().is_some_and(Result::is_err)
                || stderr.as_ref().is_some_and(Result::is_err)
            {
                break None;
            }
            if started.elapsed() >= limits.timeout {
                break Some(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "read-only process deadline exceeded",
                ));
            }
            if status.is_none() {
                match child.try_wait() {
                    Ok(value) => status = value,
                    Err(error) => break Some(error),
                }
            }
            if status.is_some() && stdout.is_some() && stderr.is_some() {
                break None;
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        // Includes descendants holding output handles open. Existing HDC servers
        // were not started by this process and do not belong to this group/job.
        stop.store(true, Ordering::Release);
        let cleanup = child.kill_and_wait();
        let reader_deadline = Instant::now() + READER_CLEANUP_TIMEOUT;
        let stdout = finish_reader(&out, stdout, reader_deadline);
        let stderr = finish_reader(&err, stderr, reader_deadline);
        cleanup.map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("read-only process cleanup failed: {error}"),
            )
        })?;
        let (stdout, stderr) = (stdout?, stderr?);
        if let Some(error) = failure {
            return Err(error);
        }
        self.revalidate()?;
        Ok(ProcessOutput {
            stdout,
            stderr,
            status: status.expect("finished child"),
        })
    }

    pub(crate) fn revalidate(&self) -> io::Result<()> {
        let before = self.file.metadata()?;
        validate_metadata(&before)?;
        if !same_metadata(&self.initial, &before) {
            return Err(denied("retained executable identity changed"));
        }
        #[cfg(windows)]
        if crate::windows::file_identity(&self.file)? != self.identity {
            return Err(denied("retained executable file identity changed"));
        }
        if hash_file(&self.file, before.len())? != self.sha256 {
            return Err(denied("executable hash does not match its trusted pin"));
        }
        let after = self.file.metadata()?;
        if !same_metadata(&before, &after) {
            return Err(denied("executable changed while hashing"));
        }
        // A renamed/replaced installation is not silently followed.
        let current = open_locked_file(&self.path)?;
        if !same_metadata(&self.initial, &current.metadata()?) {
            return Err(denied("executable path no longer names the retained file"));
        }
        #[cfg(windows)]
        if crate::windows::file_identity(&current)? != self.identity {
            return Err(denied("executable path identity changed"));
        }
        Ok(())
    }
}

fn reader(
    mut pipe: impl Read + Send + 'static,
    count: Arc<AtomicUsize>,
    overflow: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    limit: usize,
) -> Receiver<io::Result<Vec<u8>>> {
    let (sender, receiver) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let result = (|| {
            let mut output = Vec::new();
            let mut buffer = [0; 8192];
            loop {
                if stop.load(Ordering::Acquire) {
                    return Ok(output);
                }
                let size = match pipe.read(&mut buffer) {
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(5));
                        continue;
                    }
                    value => value?,
                };
                if size == 0 {
                    return Ok(output);
                }
                if count.fetch_add(size, Ordering::AcqRel).saturating_add(size) > limit {
                    overflow.store(true, Ordering::Release);
                    return Err(io::Error::new(
                        io::ErrorKind::FileTooLarge,
                        "process output limit exceeded",
                    ));
                }
                output.extend_from_slice(&buffer[..size]);
            }
        })();
        // Completion means the read handle is closed, even when an unrelated
        // process still holds a writer. The caller never performs an unbounded join.
        drop(pipe);
        let _ = sender.send(result);
    });
    receiver
}

fn poll_reader(receiver: &Receiver<io::Result<Vec<u8>>>, result: &mut Option<io::Result<Vec<u8>>>) {
    if result.is_some() {
        return;
    }
    *result = match receiver.try_recv() {
        Ok(output) => Some(output),
        Err(TryRecvError::Empty) => None,
        Err(TryRecvError::Disconnected) => Some(Err(io::Error::other(
            "process output reader stopped without a result",
        ))),
    };
}

fn finish_reader(
    receiver: &Receiver<io::Result<Vec<u8>>>,
    result: Option<io::Result<Vec<u8>>>,
    deadline: Instant,
) -> io::Result<Vec<u8>> {
    result.unwrap_or_else(|| {
        receiver
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .map_err(|error| match error {
                mpsc::RecvTimeoutError::Timeout => io::Error::new(
                    io::ErrorKind::TimedOut,
                    "process output reader did not finish after cancellation",
                ),
                mpsc::RecvTimeoutError::Disconnected => {
                    io::Error::other("process output reader stopped without a result")
                }
            })?
    })
}

#[cfg(unix)]
struct ChildSignalFailure {
    target: libc::pid_t,
    error: io::Error,
}

#[cfg(unix)]
fn child_signal_error(failures: &[ChildSignalFailure]) -> Option<io::Error> {
    failures.first().map(|failure| {
        io::Error::new(
            failure.error.kind(),
            format!(
                "cannot terminate child target {}: {}",
                failure.target, failure.error
            ),
        )
    })
}

#[cfg(target_os = "macos")]
fn pending_macos_permission_failures(
    pid: libc::pid_t,
    failures: &mut Vec<ChildSignalFailure>,
    mut proof: impl FnMut(libc::pid_t, bool) -> io::Result<bool>,
) -> io::Result<bool> {
    let mut pending = false;
    let mut index = 0;
    while index < failures.len() {
        let failure = &failures[index];
        if failure.error.raw_os_error() == Some(libc::EPERM) {
            if proof(pid, failure.target < 0)? {
                failures.remove(index);
                continue;
            }
            pending = true;
        }
        index += 1;
    }
    Ok(pending)
}

#[cfg(unix)]
fn terminate_unix_child(pid: libc::pid_t, reaped: &mut bool) -> io::Result<()> {
    if *reaped {
        return Ok(());
    }
    let deadline = Instant::now() + CLEANUP_TIMEOUT;
    let mut signal_failures = Vec::new();
    for target in [-pid, pid] {
        // SAFETY: waitid uses WNOWAIT, so this child PID remains reserved until
        // waitpid below. The fresh child process group cannot be our own group.
        if unsafe { libc::kill(target, libc::SIGKILL) } != 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                // Keep every target and its raw errno until cleanup is resolved.
                // In particular, ErrorKind::PermissionDenied also covers EACCES,
                // which is not eligible for Darwin's retained-zombie proof.
                signal_failures.push(ChildSignalFailure { target, error });
            }
        }
    }
    loop {
        #[cfg(target_os = "macos")]
        if Instant::now() < deadline {
            // A signal may see an exiting process before waitid exposes its
            // terminal status. Preserve its PID and defer only EPERM until the
            // same exact child/group proof becomes available within this budget.
            let pending =
                pending_macos_permission_failures(pid, &mut signal_failures, |pid, group| {
                    macos_process::only_retained_zombie_remains(pid, group)
                        .map(|proven| proven && Instant::now() < deadline)
                });
            let pending = match pending {
                Ok(pending) => pending,
                Err(error) => {
                    if error.raw_os_error() == Some(libc::ECHILD) {
                        // The owned PID is no longer retained: neither this loop
                        // nor Drop may signal or query a replacement process.
                        *reaped = true;
                    }
                    return Err(error);
                }
            };
            if pending && Instant::now() < deadline {
                std::thread::sleep(
                    Duration::from_millis(5)
                        .min(deadline.saturating_duration_since(Instant::now())),
                );
                continue;
            }
        }
        // SAFETY: reap only this owned child, without a blocking wait.
        let waited = unsafe { libc::waitpid(pid, std::ptr::null_mut(), libc::WNOHANG) };
        if waited == pid {
            *reaped = true;
            return child_signal_error(&signal_failures).map_or(Ok(()), Err);
        }
        if waited < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ECHILD) {
                *reaped = true;
            }
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
        if Instant::now() >= deadline {
            return Err(child_signal_error(&signal_failures).unwrap_or_else(|| {
                io::Error::new(
                    io::ErrorKind::TimedOut,
                    "terminated child did not exit within cleanup budget",
                )
            }));
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(unix)]
fn retire_unix_child(pid: libc::pid_t) {
    // A failed bounded cleanup must not extend the caller's deadline in Drop.
    // Retain the unreaped child ID in a reaper until the kernel reports exit.
    // SAFETY: no successful waitpid has released this child PID.
    unsafe {
        libc::kill(-pid, libc::SIGKILL);
        libc::kill(pid, libc::SIGKILL);
    }
    std::thread::spawn(move || {
        // SAFETY: this is the sole remaining owner of the unreaped child PID.
        while unsafe { libc::waitpid(pid, std::ptr::null_mut(), 0) } < 0 {
            if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                break;
            }
        }
    });
}

fn validate_metadata(metadata: &Metadata) -> io::Result<()> {
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_TOOL_BYTES {
        return Err(denied("executable must be a bounded nonempty regular file"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        // SAFETY: geteuid has no memory preconditions.
        let uid = unsafe { libc::geteuid() };
        if (metadata.uid() != 0 && metadata.uid() != uid)
            || metadata.mode() & 0o022 != 0
            || metadata.mode() & 0o111 == 0
        {
            return Err(denied(
                "executable owner, permissions or executable bits are unsafe",
            ));
        }
    }
    Ok(())
}

fn same_metadata(left: &Metadata, right: &Metadata) -> bool {
    let base = left.len() == right.len() && left.modified().ok() == right.modified().ok();
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        base && left.dev() == right.dev()
            && left.ino() == right.ino()
            && left.uid() == right.uid()
            && left.mode() == right.mode()
            && left.ctime() == right.ctime()
            && left.ctime_nsec() == right.ctime_nsec()
    }
    #[cfg(windows)]
    {
        base
    }
}

fn hash_file(file: &File, length: u64) -> io::Result<String> {
    let mut hasher = Sha256::new();
    let mut buffer = [0; 65536];
    let mut offset = 0;
    while offset < length {
        #[cfg(unix)]
        let count = {
            use std::os::unix::fs::FileExt;
            file.read_at(&mut buffer, offset)?
        };
        #[cfg(windows)]
        let count = {
            use std::os::windows::fs::FileExt;
            file.seek_read(&mut buffer, offset)?
        };
        if count == 0 {
            return Err(denied("executable truncated during hashing"));
        }
        hasher.update(&buffer[..count]);
        offset += count as u64;
    }
    if offset != length {
        return Err(denied("executable grew during hashing"));
    }
    Ok(format!("{:x}", hasher.finalize()))
}

pub(crate) fn open_locked_file(path: &Path) -> io::Result<File> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::{
            FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
        };
        // Deny writes and deletion for the entire verification/spawn lifetime.
        options
            .share_mode(FILE_SHARE_READ)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let file = options.open(path)?;
    #[cfg(windows)]
    crate::windows::reject_reparse_file(&file)?;
    Ok(file)
}

#[cfg(all(unix, not(target_os = "macos")))]
struct RunningChild {
    child: std::process::Child,
    reaped: bool,
    cleanup_attempted: bool,
    stdout: Option<std::process::ChildStdout>,
    stderr: Option<std::process::ChildStderr>,
}

#[cfg(all(unix, not(target_os = "macos")))]
impl RunningChild {
    fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        use std::os::unix::process::ExitStatusExt;
        // SAFETY: siginfo_t permits a zero-initialized output representation.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: only queries the retained child; WNOWAIT prevents its PID
        // from being recycled before the isolated process group is cleaned up.
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                self.child.id(),
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        if result != 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ECHILD) {
                self.reaped = true;
            }
            return Err(error);
        }
        // SAFETY: successful waitid initialized the SIGCHLD union fields.
        let (pid, status) = unsafe { (info.si_pid(), info.si_status()) };
        if pid == 0 {
            return Ok(None);
        }
        let raw = match info.si_code {
            libc::CLD_EXITED => status << 8,
            libc::CLD_KILLED => status,
            libc::CLD_DUMPED => status | 0x80,
            _ => return Err(io::Error::other("unexpected child wait status")),
        };
        Ok(Some(ExitStatus::from_raw(raw)))
    }
    fn kill_and_wait(&mut self) -> io::Result<()> {
        self.cleanup_attempted = true;
        terminate_unix_child(self.child.id() as libc::pid_t, &mut self.reaped)
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
impl Drop for RunningChild {
    fn drop(&mut self) {
        if !self.cleanup_attempted {
            let _ = self.kill_and_wait();
        }
        if !self.reaped {
            retire_unix_child(self.child.id() as libc::pid_t);
        }
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
fn spawn(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
) -> io::Result<RunningChild> {
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    let execution_path = {
        use std::os::fd::AsRawFd;
        PathBuf::from(format!("/proc/self/fd/{}", tool.file.as_raw_fd()))
    };
    let mut command = Command::new(execution_path);
    command
        .arg0(&tool.path)
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("LANG", "C")
        .env("LC_ALL", "C")
        .envs(environment.iter().map(|(key, value)| (key, value)))
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    let mut child = command.spawn()?;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let running = RunningChild {
        child,
        reaped: false,
        cleanup_attempted: false,
        stdout,
        stderr,
    };
    use std::os::fd::AsRawFd;
    for descriptor in [
        running.stdout.as_ref().expect("piped stdout").as_raw_fd(),
        running.stderr.as_ref().expect("piped stderr").as_raw_fd(),
    ] {
        // SAFETY: live output descriptors; nonblocking readers can honor the
        // deadline even when a descendant escaped the original process group.
        if unsafe { libc::fcntl(descriptor, libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(running)
}

#[cfg(windows)]
use crate::windows::spawn;

#[cfg(target_os = "macos")]
#[path = "macos_process.rs"]
mod macos_process;
#[cfg(target_os = "macos")]
use macos_process::spawn;

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_cleanup_defers_eperm_until_retained_terminal_proof_is_available() {
        let pid = 321;
        let mut failures = vec![
            ChildSignalFailure {
                target: -pid,
                error: io::Error::from_raw_os_error(libc::EPERM),
            },
            ChildSignalFailure {
                target: pid,
                error: io::Error::from_raw_os_error(libc::EPERM),
            },
        ];
        let mut queried = Vec::new();
        // The first poll occurs while the child is exiting. Cleanup must retain
        // both raw errors and must not proceed to the reaping branch yet.
        assert!(
            pending_macos_permission_failures(pid, &mut failures, |observed_pid, group| {
                queried.push((observed_pid, group));
                Ok(false)
            })
            .unwrap()
        );
        assert_eq!(queried, [(pid, true), (pid, false)]);
        assert_eq!(failures.len(), 2);
        assert!(
            failures
                .iter()
                .all(|failure| failure.error.raw_os_error() == Some(libc::EPERM))
        );
        // A later poll has both the owned zombie and the complete group proof.
        // This is the only transition that permits reaping without a signal error.
        assert!(
            !pending_macos_permission_failures(pid, &mut failures, |observed_pid, _| {
                assert_eq!(observed_pid, pid);
                Ok(true)
            })
            .unwrap()
        );
        assert!(child_signal_error(&failures).is_none());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_cleanup_retains_unproven_group_error_after_direct_child_exit() {
        let pid = 321;
        let mut failures = vec![
            ChildSignalFailure {
                target: -pid,
                error: io::Error::from_raw_os_error(libc::EPERM),
            },
            ChildSignalFailure {
                target: pid,
                error: io::Error::from_raw_os_error(libc::EPERM),
            },
        ];
        // The child is terminal, but a live member or an incomplete group table
        // prevents the group proof. Reaching the deadline must return this error.
        assert!(
            pending_macos_permission_failures(pid, &mut failures, |_, group| Ok(!group)).unwrap()
        );
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].target, -pid);
        assert_eq!(failures[0].error.raw_os_error(), Some(libc::EPERM));
        let error = child_signal_error(&failures).unwrap();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert!(error.to_string().contains("child target -321"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_cleanup_never_clears_non_eperm_signal_errors() {
        let pid = 321;
        for errno in [libc::EACCES, libc::EIO] {
            let mut failures = vec![ChildSignalFailure {
                target: -pid,
                error: io::Error::from_raw_os_error(errno),
            }];
            assert!(
                !pending_macos_permission_failures(pid, &mut failures, |_, _| {
                    panic!("non-EPERM failure cannot use the zombie exception")
                })
                .unwrap()
            );
            assert_eq!(failures[0].error.raw_os_error(), Some(errno));
            let error = child_signal_error(&failures).unwrap();
            assert_eq!(error.kind(), io::Error::from_raw_os_error(errno).kind());
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_cleanup_stops_proof_queries_when_child_ownership_is_lost() {
        let pid = 321;
        let mut failures = vec![
            ChildSignalFailure {
                target: -pid,
                error: io::Error::from_raw_os_error(libc::EPERM),
            },
            ChildSignalFailure {
                target: pid,
                error: io::Error::from_raw_os_error(libc::EPERM),
            },
        ];
        let mut queries = 0;
        let error = pending_macos_permission_failures(pid, &mut failures, |_, _| {
            queries += 1;
            Err(io::Error::from_raw_os_error(libc::ECHILD))
        })
        .unwrap_err();
        assert_eq!(error.raw_os_error(), Some(libc::ECHILD));
        assert_eq!(queries, 1);
        assert_eq!(failures.len(), 2);
    }

    #[test]
    fn reader_completion_never_joins_a_blocked_reader() {
        struct BlockingReader {
            entered: mpsc::SyncSender<()>,
            released: mpsc::Receiver<()>,
        }
        impl Read for BlockingReader {
            fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
                self.entered.send(()).unwrap();
                self.released.recv().unwrap();
                Ok(0)
            }
        }
        let (entered, ready) = mpsc::sync_channel(1);
        let (release, released) = mpsc::sync_channel(1);
        let stop = Arc::new(AtomicBool::new(false));
        let receiver = reader(
            BlockingReader { entered, released },
            Arc::new(AtomicUsize::new(0)),
            Arc::new(AtomicBool::new(false)),
            stop.clone(),
            1024,
        );
        ready.recv_timeout(Duration::from_secs(1)).unwrap();
        stop.store(true, Ordering::Release);
        let started = Instant::now();
        let error =
            finish_reader(&receiver, None, started + Duration::from_millis(50)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(1));
        release.send(()).unwrap();
        assert!(
            receiver
                .recv_timeout(Duration::from_secs(1))
                .unwrap()
                .unwrap()
                .is_empty()
        );
    }

    #[cfg(unix)]
    #[test]
    fn reader_cancels_while_a_writer_remains_open() {
        let (pipe, _held_writer) = std::os::unix::net::UnixStream::pair().unwrap();
        pipe.set_nonblocking(true).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let receiver = reader(
            pipe,
            Arc::new(AtomicUsize::new(0)),
            Arc::new(AtomicBool::new(false)),
            stop.clone(),
            1024,
        );
        stop.store(true, Ordering::Release);
        assert!(
            finish_reader(&receiver, None, Instant::now() + Duration::from_secs(1))
                .unwrap()
                .is_empty()
        );
    }
}
