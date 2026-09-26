use super::{
    VerifiedTool, denied, invalid, retire_unix_child, same_metadata, terminate_unix_child,
};
use std::ffi::{CStr, CString, OsString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::{ffi::OsStrExt, fs::MetadataExt, process::ExitStatusExt};
use std::process::ExitStatus;

// This Darwin symbol is available from macOS 10.15. libc does not expose it.
// Declaration checked against the active SDK's spawn.h; no shell is involved.
unsafe extern "C" {
    fn posix_spawn_file_actions_addchdir_np(
        actions: *mut libc::posix_spawn_file_actions_t,
        path: *const libc::c_char,
    ) -> libc::c_int;
}

pub(super) struct RunningChild {
    pid: libc::pid_t,
    reaped: bool,
    cleanup_attempted: bool,
    pub(super) stdout: Option<File>,
    pub(super) stderr: Option<File>,
}

impl RunningChild {
    pub(super) fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        // SAFETY: zero is a valid empty siginfo_t representation.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: only reads this child's status. WNOWAIT retains the process ID
        // until group cleanup, so an unrelated process cannot recycle its PID.
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                self.pid as libc::id_t,
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
        if info.si_pid == 0 {
            return Ok(None);
        }
        let raw = match info.si_code {
            libc::CLD_EXITED => info.si_status << 8,
            libc::CLD_KILLED => info.si_status,
            libc::CLD_DUMPED => info.si_status | 0x80,
            _ => return Err(io::Error::other("unexpected child wait status")),
        };
        Ok(Some(ExitStatus::from_raw(raw)))
    }
    pub(super) fn kill_and_wait(&mut self) -> io::Result<()> {
        self.cleanup_attempted = true;
        terminate_unix_child(self.pid, &mut self.reaped)
    }
    /// Deliver `signal` to the child's own process group while its PID is
    /// still retained; a reaped child's group is never signalled.
    pub(super) fn signal_group(&self, signal: libc::c_int) {
        if !self.reaped {
            // SAFETY: WNOWAIT waits keep this PID, and so its fresh process
            // group, reserved until kill_and_wait reaps it.
            unsafe {
                libc::kill(-self.pid, signal);
            }
        }
    }
    /// Swift `processGroupExists` turned false: the leader has exited and no
    /// other member of its process group is left. The leader itself stays a
    /// retained zombie until kill_and_wait reaps it.
    pub(super) fn group_drained(&self) -> bool {
        !self.reaped && only_retained_zombie_remains(self.pid, true).unwrap_or(false)
    }
}
impl Drop for RunningChild {
    fn drop(&mut self) {
        if !self.cleanup_attempted {
            let _ = self.kill_and_wait();
        }
        if !self.reaped {
            retire_unix_child(self.pid);
        }
    }
}

pub(super) fn only_retained_zombie_remains(pid: libc::pid_t, group: bool) -> io::Result<bool> {
    // SAFETY: zero is a valid empty siginfo_t; WNOWAIT retains the owned PID.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    // SAFETY: only queries the exact unreaped child and never blocks or reaps it.
    if unsafe {
        libc::waitid(
            libc::P_PID,
            pid as libc::id_t,
            &mut info,
            libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    if info.si_pid != pid {
        return Ok(false);
    }
    if !group {
        return Ok(true);
    }
    // PROC_PGRP_ONLY is 2 in the active macOS SDK's sys/proc_info.h. The query
    // includes live and zombie members; a full/truncated result proves nothing.
    let mut members = [0 as libc::pid_t; 8192];
    // SAFETY: thread-local errno is reset for the API's ambiguous zero result;
    // the bounded PID array supplies the declared byte length.
    let returned = unsafe {
        *libc::__error() = 0;
        libc::proc_listpids(
            2,
            pid as u32,
            members.as_mut_ptr().cast(),
            std::mem::size_of_val(&members) as i32,
        )
    };
    // SAFETY: reads only this thread's errno after the preceding synchronous call.
    if returned < 0
        || (returned == 0 && unsafe { *libc::__error() } != 0)
        || returned as usize >= std::mem::size_of_val(&members)
        || !(returned as usize).is_multiple_of(std::mem::size_of::<libc::pid_t>())
    {
        return Ok(false);
    }
    Ok(
        members[..returned as usize / std::mem::size_of::<libc::pid_t>()]
            .iter()
            .all(|member| *member == pid),
    )
}

struct SpawnSettings {
    actions: libc::posix_spawn_file_actions_t,
    attributes: libc::posix_spawnattr_t,
}
impl SpawnSettings {
    fn new() -> io::Result<Self> {
        let mut actions = std::ptr::null_mut();
        let mut attributes = std::ptr::null_mut();
        // SAFETY: valid out pointers; successful initialization owns each value.
        posix(unsafe { libc::posix_spawn_file_actions_init(&mut actions) })?;
        // SAFETY: valid output for the attribute object.
        if let Err(error) = posix(unsafe { libc::posix_spawnattr_init(&mut attributes) }) {
            // SAFETY: actions was successfully initialized above.
            unsafe {
                libc::posix_spawn_file_actions_destroy(&mut actions);
            }
            return Err(error);
        }
        Ok(Self {
            actions,
            attributes,
        })
    }
}
impl Drop for SpawnSettings {
    fn drop(&mut self) {
        // SAFETY: both values were initialized and are exclusively owned.
        unsafe {
            libc::posix_spawn_file_actions_destroy(&mut self.actions);
            libc::posix_spawnattr_destroy(&mut self.attributes);
        }
    }
}

fn posix(result: libc::c_int) -> io::Result<()> {
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::from_raw_os_error(result))
    }
}

pub(super) fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let (read, write) = input_pipe()?;
    // SAFETY: nonblocking read permits bounded cancellation even if a child
    // deliberately leaves an inherited descriptor open in a detached descendant.
    if unsafe { libc::fcntl(read.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((read, write))
}

/// A pipe whose read end a child reads as its stdin: both ends close on exec,
/// and the read end blocks, as a child reading its input expects — a
/// nonblocking flag would be shared with the child through the open file.
pub(super) fn input_pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut descriptors = [-1; 2];
    // SAFETY: two valid integer output slots.
    if unsafe { libc::pipe(descriptors.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: pipe returned two newly owned descriptors.
    let (read, write) = unsafe {
        (
            OwnedFd::from_raw_fd(descriptors[0]),
            OwnedFd::from_raw_fd(descriptors[1]),
        )
    };
    for descriptor in [&read, &write] {
        // SAFETY: live descriptor; only close-on-exec flag is set.
        if unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok((read, write))
}

pub(super) fn spawn(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
) -> io::Result<RunningChild> {
    spawn_in(tool, args, environment, None)
}

/// `spawn` with a child-only working directory (`/` when `None`), applied by
/// the spawn's file actions so the daemon's own directory never changes.
pub(super) fn spawn_in(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
    working_directory: Option<&CStr>,
) -> io::Result<RunningChild> {
    spawn_suspended(tool, args, environment, working_directory, None)?.resume()
}

/// A child spawned on the retained inode and not yet running: it has the PID
/// and the birth the kernel reports and has executed no tool code, so what
/// the spawn itself established can be recorded before `resume` lets it run
/// — a server that ends at once is then an exit its owner sees, never a
/// launch that could not be recorded. Dropped unresumed, it is killed.
pub(super) struct SuspendedChild {
    child: RunningChild,
    start: Start,
}

/// How `resume` lets a suspended child run.
enum Start {
    /// Created suspended by `posix_spawn`: SIGCONT.
    Continue,
    /// A forked copy waiting to become the tool (`spawn_suspended_ignoring`):
    /// the byte it waits for, and its report, which its `exec` closes unread
    /// and which otherwise carries the error that stopped it.
    Handshake { start: File, report: File },
}

impl SuspendedChild {
    pub(super) fn pid(&self) -> libc::pid_t {
        self.child.pid
    }

    /// Lets the child run.
    pub(super) fn resume(self) -> io::Result<RunningChild> {
        let Self { child, start } = self;
        match start {
            Start::Continue => {
                // SAFETY: retained, unreaped child PID still names the suspended process.
                if unsafe { libc::kill(child.pid, libc::SIGCONT) } != 0 {
                    return Err(io::Error::last_os_error());
                }
            }
            Start::Handshake {
                mut start,
                mut report,
            } => {
                // A copy already gone takes no byte; its report says why.
                let _ = start.write_all(&[1]);
                drop(start);
                let mut answer = Vec::new();
                report.read_to_end(&mut answer)?;
                if !answer.is_empty() {
                    // It never became the tool; dropped here, it is reaped.
                    return Err(match <[u8; 4]>::try_from(answer.as_slice()) {
                        Ok(code) => io::Error::from_raw_os_error(i32::from_ne_bytes(code)),
                        Err(_) => io::Error::other("the child's start report was cut short"),
                    });
                }
            }
        }
        Ok(child)
    }
}

/// `spawn_in` up to the moment the child would run: created suspended on the
/// retained inode, the tool re-proved, the child returned still suspended.
/// `stdin` is the read end of a pipe the caller keeps writing, or `/dev/null`
/// when `None`.
pub(super) fn spawn_suspended(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
    working_directory: Option<&CStr>,
    stdin: Option<&OwnedFd>,
) -> io::Result<SuspendedChild> {
    let inode_path = inode_launch_path(tool)?;
    spawn_suspended_at(
        tool,
        &inode_path,
        args,
        environment,
        working_directory,
        stdin,
    )
}

/// Swift's `.verifiedCanonicalPath` launch: `bound` and the tool verified,
/// the child spawned suspended at the tool's canonical path, `bound` and the
/// tool verified again, the child's first executable mapping proved to be the
/// retained inode, and only then continued. A child refused here is killed
/// before it ran tool code.
pub(super) fn spawn_canonical(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
    working_directory: Option<&CStr>,
    bound: &dyn Fn() -> io::Result<()>,
) -> io::Result<RunningChild> {
    bound()?;
    tool.revalidate()?;
    let canonical = CString::new(tool.path.as_os_str().as_bytes())
        .map_err(|_| invalid("canonical executable path contains NUL"))?;
    let suspended =
        spawn_suspended_at(tool, &canonical, args, environment, working_directory, None)?;
    bound()?;
    verify_suspended_mapping(suspended.pid(), tool)?;
    suspended.resume()
}

/// `struct proc_regioninfo` (`sys/proc_info.h`).
#[repr(C)]
struct RegionInfo {
    protection: u32,
    max_protection: u32,
    inheritance: u32,
    flags: u32,
    offset: u64,
    behavior: u32,
    user_wired_count: u32,
    user_tag: u32,
    pages_resident: u32,
    pages_shared_now_private: u32,
    pages_swapped_out: u32,
    pages_dirtied: u32,
    ref_count: u32,
    shadow_depth: u32,
    share_mode: u32,
    private_pages_resident: u32,
    shared_pages_resident: u32,
    obj_id: u32,
    depth: u32,
    address: u64,
    size: u64,
}

/// `struct proc_regionwithpathinfo`.
#[repr(C)]
struct RegionWithPathInfo {
    region: RegionInfo,
    vnode: libc::vnode_info_path,
}

/// `PROC_PIDREGIONPATHINFO`.
const REGION_PATH_INFO: libc::c_int = 8;
/// `VM_PROT_EXECUTE`.
const EXECUTE: u32 = 4;

/// Swift `verifySuspendedExecutableMapping`: a child created suspended has run
/// no code of its own, so the first executable region the kernel reports is
/// its main executable, which must be the retained file's device and inode.
fn verify_suspended_mapping(pid: libc::pid_t, tool: &VerifiedTool) -> io::Result<()> {
    // SAFETY: zero is a valid representation of these plain C structures.
    let mut information: RegionWithPathInfo = unsafe { std::mem::zeroed() };
    let expected = std::mem::size_of::<RegionWithPathInfo>() as libc::c_int;
    // SAFETY: the buffer is exactly `expected` bytes of the structure the
    // flavor fills, and the PID is the retained, suspended child.
    let actual = unsafe {
        libc::proc_pidinfo(
            pid,
            REGION_PATH_INFO,
            0,
            (&mut information as *mut RegionWithPathInfo).cast(),
            expected,
        )
    };
    let mapped = &information.vnode.vip_vi.vi_stat;
    if actual != expected
        || information.region.protection & EXECUTE == 0
        || u64::from(mapped.vst_dev) != tool.initial.dev() as u32 as u64
        || mapped.vst_ino != tool.initial.ino()
    {
        return Err(denied(
            "the suspended child's executable mapping is not the verified file",
        ));
    }
    Ok(())
}

/// `spawn_suspended` at `launch`, the path the kernel resolves the program by.
fn spawn_suspended_at(
    tool: &VerifiedTool,
    launch: &CStr,
    args: &[OsString],
    environment: &[(OsString, OsString)],
    working_directory: Option<&CStr>,
    stdin: Option<&OwnedFd>,
) -> io::Result<SuspendedChild> {
    let (out_read, out_write) = pipe()?;
    let (err_read, err_write) = pipe()?;
    let mut settings = SpawnSettings::new()?;
    // SAFETY: actions/attributes are initialized; all named descriptors are live.
    unsafe {
        posix(posix_spawn_file_actions_addchdir_np(
            &mut settings.actions,
            working_directory.unwrap_or(c"/").as_ptr(),
        ))?;
        match stdin {
            // Only the read end crosses: every other descriptor, the write end
            // included, closes on exec (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so the
            // caller's close is the child's end of input.
            Some(read) => posix(libc::posix_spawn_file_actions_adddup2(
                &mut settings.actions,
                read.as_raw_fd(),
                libc::STDIN_FILENO,
            ))?,
            None => posix(libc::posix_spawn_file_actions_addopen(
                &mut settings.actions,
                libc::STDIN_FILENO,
                c"/dev/null".as_ptr(),
                libc::O_RDONLY,
                0,
            ))?,
        }
        posix(libc::posix_spawn_file_actions_adddup2(
            &mut settings.actions,
            out_write.as_raw_fd(),
            libc::STDOUT_FILENO,
        ))?;
        posix(libc::posix_spawn_file_actions_adddup2(
            &mut settings.actions,
            err_write.as_raw_fd(),
            libc::STDERR_FILENO,
        ))?;
        posix(libc::posix_spawnattr_setflags(
            &mut settings.attributes,
            (libc::POSIX_SPAWN_SETPGROUP
                | libc::POSIX_SPAWN_START_SUSPENDED
                | libc::POSIX_SPAWN_CLOEXEC_DEFAULT) as i16,
        ))?;
        posix(libc::posix_spawnattr_setpgroup(&mut settings.attributes, 0))?;
    }
    let (argv, env) = argv_and_environment(tool, args, environment)?;
    let mut argv_pointers: Vec<*mut libc::c_char> = argv
        .iter()
        .map(|argument| argument.as_ptr().cast_mut())
        .collect();
    argv_pointers.push(std::ptr::null_mut());
    let mut env_pointers: Vec<*mut libc::c_char> =
        env.iter().map(|value| value.as_ptr().cast_mut()).collect();
    env_pointers.push(std::ptr::null_mut());
    let mut pid = 0;
    // SAFETY: argv/env are NUL-terminated pointer arrays, all strings and spawn
    // settings remain live. The child starts suspended at `launch`.
    posix(unsafe {
        libc::posix_spawn(
            &mut pid,
            launch.as_ptr(),
            &settings.actions,
            &settings.attributes,
            argv_pointers.as_ptr(),
            env_pointers.as_ptr(),
        )
    })?;
    let child = RunningChild {
        pid,
        reaped: false,
        cleanup_attempted: false,
        stdout: Some(out_read.into()),
        stderr: Some(err_read.into()),
    };
    drop(out_write);
    drop(err_write);
    // Every failed check drops the suspended child and kills it before tool code.
    tool.revalidate()?;
    Ok(SuspendedChild {
        child,
        start: Start::Continue,
    })
}

/// `spawn_suspended` for a child that starts with the `ignored` signals
/// ignored, as a child of Swift's daemon starts with SIGINT and SIGTERM
/// ignored: the daemon ignores both before it starts any child
/// (`main.swift` 377-378), an ignored disposition survives `exec`, and its
/// `IdentityBoundDaemonLauncher` resets none.
///
/// `posix_spawn` can reset a disposition to its default but never set one to
/// ignore, and this process catches both signals (`StopSignal`): to ignore
/// them here, even for the moment of one spawn, would drop a stop request and
/// hand the ignore to any other child spawned meanwhile. So a forked copy of
/// this thread ignores them in itself alone and waits. It is the child: its
/// PID and birth are the tool's, and it has executed no tool code. `resume`
/// sends the byte it waits for, and it becomes the tool on the retained inode
/// with what `spawn_suspended` gives a child: the working directory, `stdin`
/// or `/dev/null`, the two capture pipes and no other descriptor, its own
/// process group, and this thread's signal mask. Every signal stays blocked
/// in the copy until then, so no handler it inherited runs there, and from
/// the fork to its `exec` it makes only async-signal-safe calls, over values
/// made before the fork. A copy that cannot become the tool reports why and
/// ends; the error is `resume`'s.
pub(super) fn spawn_suspended_ignoring(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
    working_directory: Option<&CStr>,
    stdin: Option<&OwnedFd>,
    ignored: &[libc::c_int],
) -> io::Result<SuspendedChild> {
    let launch = inode_launch_path(tool)?;
    let (out_read, out_write) = pipe()?;
    let (err_read, err_write) = pipe()?;
    let (start_read, start_write) = input_pipe()?;
    let (report_read, report_write) = input_pipe()?;
    let (argv, env) = argv_and_environment(tool, args, environment)?;
    let mut argv_pointers: Vec<*const libc::c_char> =
        argv.iter().map(|argument| argument.as_ptr()).collect();
    argv_pointers.push(std::ptr::null());
    let mut env_pointers: Vec<*const libc::c_char> =
        env.iter().map(|value| value.as_ptr()).collect();
    env_pointers.push(std::ptr::null());
    // SAFETY: zero is a valid empty sigaction and sigset; the fields the copy
    // reads are set below.
    let mut ignore: libc::sigaction = unsafe { std::mem::zeroed() };
    ignore.sa_sigaction = libc::SIG_IGN;
    // SAFETY: as above.
    let (mut all, mut mask): (libc::sigset_t, libc::sigset_t) =
        unsafe { (std::mem::zeroed(), std::mem::zeroed()) };
    // SAFETY: owned, writable sigsets.
    unsafe {
        libc::sigemptyset(&mut ignore.sa_mask);
        libc::sigfillset(&mut all);
    }
    // The child's mask is this thread's, as `posix_spawn` leaves it.
    // SAFETY: an owned sigset; nothing is changed.
    posix(unsafe { libc::pthread_sigmask(libc::SIG_BLOCK, std::ptr::null(), &mut mask) })?;
    let plan = ForkPlan {
        launch: &launch,
        argv: &argv_pointers,
        env: &env_pointers,
        directory: working_directory.unwrap_or(c"/"),
        stdin: stdin.map(AsRawFd::as_raw_fd),
        stdout: out_write.as_raw_fd(),
        stderr: err_write.as_raw_fd(),
        start: start_read.as_raw_fd(),
        start_peer: start_write.as_raw_fd(),
        report: report_write.as_raw_fd(),
        // SAFETY: getdtablesize takes nothing and only reads a limit.
        descriptors: unsafe { libc::getdtablesize() },
        ignored,
        ignore: &ignore,
        mask: &mask,
    };
    // Every signal blocked on this thread across the fork, so the copy
    // starts with all of them blocked.
    // SAFETY: an owned sigset; only this thread's mask changes.
    posix(unsafe { libc::pthread_sigmask(libc::SIG_SETMASK, &all, std::ptr::null_mut()) })?;
    // SAFETY: the copy runs `ForkPlan::become_tool` alone, which never returns.
    let pid = unsafe { libc::fork() };
    if pid == 0 {
        // SAFETY: the forked copy, before any other call: see `become_tool`.
        unsafe { plan.become_tool() }
    }
    let forked = io::Error::last_os_error();
    // SAFETY: restores this thread's own mask, kept above.
    unsafe { libc::pthread_sigmask(libc::SIG_SETMASK, &mask, std::ptr::null_mut()) };
    if pid < 0 {
        return Err(forked);
    }
    // Its own process group whichever of the two sets it first, so the
    // group a drop kills is the copy's before it has become the tool.
    // SAFETY: the copy is this process's unreaped child.
    unsafe { libc::setpgid(pid, pid) };
    let child = RunningChild {
        pid,
        reaped: false,
        cleanup_attempted: false,
        stdout: Some(out_read.into()),
        stderr: Some(err_read.into()),
    };
    drop((out_write, err_write, start_read, report_write));
    let suspended = SuspendedChild {
        child,
        start: Start::Handshake {
            start: start_write.into(),
            report: report_read.into(),
        },
    };
    // A tool that no longer verifies runs nothing: the copy is killed unresumed.
    tool.revalidate()?;
    Ok(suspended)
}

/// What the forked copy of `spawn_suspended_ignoring` needs, made before the
/// fork: it allocates nothing and reads only these.
struct ForkPlan<'a> {
    launch: &'a CStr,
    argv: &'a [*const libc::c_char],
    env: &'a [*const libc::c_char],
    directory: &'a CStr,
    stdin: Option<libc::c_int>,
    stdout: libc::c_int,
    stderr: libc::c_int,
    start: libc::c_int,
    /// The owner's end of the start, which the copy closes at once so that
    /// the owner's close is an end it sees.
    start_peer: libc::c_int,
    report: libc::c_int,
    descriptors: libc::c_int,
    ignored: &'a [libc::c_int],
    ignore: &'a libc::sigaction,
    mask: &'a libc::sigset_t,
}

impl ForkPlan<'_> {
    /// Ignores the signals, waits for the start, and becomes the tool with
    /// the descriptors, directory and mask `spawn_suspended` gives a child;
    /// otherwise reports the error and ends. Its owner's end of the start
    /// without a byte ends it with nothing to report.
    ///
    /// # Safety
    ///
    /// Called only in the child of `fork` (every signal blocked), and first:
    /// from here to `execve` or `_exit` only async-signal-safe calls are made.
    unsafe fn become_tool(&self) -> ! {
        let fail = || -> ! {
            // SAFETY: this thread's errno, then one write to the report and
            // the copy's end, all async-signal-safe.
            unsafe {
                let error = *libc::__error();
                libc::write(
                    self.report,
                    std::ptr::from_ref(&error).cast(),
                    std::mem::size_of::<libc::c_int>(),
                );
                libc::_exit(127)
            }
        };
        // SAFETY: async-signal-safe calls on this copy's own state and on
        // descriptors and values made before the fork.
        unsafe {
            libc::close(self.start_peer);
            if libc::setpgid(0, 0) != 0 {
                fail();
            }
            for &signal in self.ignored {
                if libc::sigaction(signal, self.ignore, std::ptr::null_mut()) != 0 {
                    fail();
                }
            }
            let mut byte = 0u8;
            loop {
                match libc::read(self.start, std::ptr::from_mut(&mut byte).cast(), 1) {
                    1 => break,
                    -1 if *libc::__error() == libc::EINTR => {}
                    _ => libc::_exit(127),
                }
            }
            if libc::chdir(self.directory.as_ptr()) != 0 {
                fail();
            }
            let input = match self.stdin {
                Some(read) => read,
                None => libc::open(c"/dev/null".as_ptr(), libc::O_RDONLY),
            };
            if input < 0
                || libc::dup2(input, libc::STDIN_FILENO) < 0
                || libc::dup2(self.stdout, libc::STDOUT_FILENO) < 0
                || libc::dup2(self.stderr, libc::STDERR_FILENO) < 0
            {
                fail();
            }
            // `POSIX_SPAWN_CLOEXEC_DEFAULT`: nothing else crosses. The report
            // stays open to the `exec`, which closes it (close-on-exec).
            for descriptor in 3..self.descriptors {
                if descriptor != self.report {
                    libc::close(descriptor);
                }
            }
            let error = libc::pthread_sigmask(libc::SIG_SETMASK, self.mask, std::ptr::null_mut());
            if error != 0 {
                *libc::__error() = error;
                fail();
            }
            libc::execve(self.launch.as_ptr(), self.argv.as_ptr(), self.env.as_ptr());
            fail()
        }
    }
}

/// argv[0] is the tool's real path, or the role it was given as its argument
/// zero; the environment is the clean base every identity-bound spawn gets,
/// plus what the caller named.
fn argv_and_environment(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
) -> io::Result<(Vec<CString>, Vec<CString>)> {
    let zero = tool
        .argument_zero
        .as_deref()
        .unwrap_or(tool.path.as_os_str());
    let argv: Vec<CString> = std::iter::once(zero)
        .chain(args.iter().map(OsString::as_os_str))
        .map(|argument| CString::new(argument.as_bytes()).map_err(|_| invalid("NUL in argv")))
        .collect::<io::Result<_>>()?;
    let mut env = vec![
        CString::new("PATH=/usr/bin:/bin").unwrap(),
        CString::new("LANG=C").unwrap(),
        CString::new("LC_ALL=C").unwrap(),
    ];
    for (key, value) in environment {
        env.push(
            CString::new(format!(
                "{}={}",
                key.to_string_lossy(),
                value.to_string_lossy()
            ))
            .map_err(|_| invalid("NUL in environment"))?,
        );
    }
    Ok((argv, env))
}

pub(super) fn inode_launch_path(tool: &VerifiedTool) -> io::Result<CString> {
    let inode_path = format!("/.vol/{}/{}", tool.initial.dev(), tool.initial.ino());
    if !same_metadata(&tool.initial, &std::fs::metadata(&inode_path)?) {
        return Err(denied("inode-bound executable path unavailable"));
    }
    CString::new(inode_path).map_err(|_| invalid("invalid inode path"))
}

/// A client on a pseudo-terminal, as Swift's `PersistentDeviceShellChannel`
/// spawns it: the slave is the child's stdin, stdout and stderr with echo and
/// newline translation off, the master comes back nonblocking, and the child
/// starts suspended in its own process group on the retained inode and is
/// continued only once the tool still verifies.
pub(super) fn spawn_pty(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
    working_directory: Option<&CStr>,
    keep_output_translation: bool,
) -> io::Result<(libc::pid_t, OwnedFd)> {
    let inode_path = inode_launch_path(tool)?;
    let (mut master_fd, mut slave_fd) = (-1, -1);
    // SAFETY: two valid integer output slots; name, termios and window size
    // are optional and left null.
    if unsafe {
        libc::openpty(
            &mut master_fd,
            &mut slave_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: openpty returned two newly owned descriptors.
    let (master, slave) = unsafe {
        (
            OwnedFd::from_raw_fd(master_fd),
            OwnedFd::from_raw_fd(slave_fd),
        )
    };
    // SAFETY: zero is a valid empty termios; tcgetattr fills it.
    let mut terminal: libc::termios = unsafe { std::mem::zeroed() };
    // SAFETY: the slave is a live terminal descriptor; the struct is exclusively owned.
    if unsafe { libc::tcgetattr(slave.as_raw_fd(), &mut terminal) } != 0 {
        return Err(io::Error::last_os_error());
    }
    terminal.c_lflag &= !(libc::ECHO | libc::ECHONL);
    if !keep_output_translation {
        terminal.c_oflag &= !libc::ONLCR;
    }
    // SAFETY: same descriptor and struct as above.
    if unsafe { libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &terminal) } != 0 {
        return Err(io::Error::last_os_error());
    }
    for descriptor in [&master, &slave] {
        // SAFETY: live descriptor; only close-on-exec is set.
        if unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    // SAFETY: the master is read with bounded polls; nonblocking keeps every
    // wait observable.
    if unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut settings = SpawnSettings::new()?;
    // SAFETY: actions/attributes are initialized; the slave is live.
    unsafe {
        posix(posix_spawn_file_actions_addchdir_np(
            &mut settings.actions,
            working_directory.unwrap_or(c"/").as_ptr(),
        ))?;
        for target in [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO] {
            posix(libc::posix_spawn_file_actions_adddup2(
                &mut settings.actions,
                slave.as_raw_fd(),
                target,
            ))?;
        }
        posix(libc::posix_spawnattr_setflags(
            &mut settings.attributes,
            (libc::POSIX_SPAWN_SETPGROUP
                | libc::POSIX_SPAWN_START_SUSPENDED
                | libc::POSIX_SPAWN_CLOEXEC_DEFAULT) as i16,
        ))?;
        posix(libc::posix_spawnattr_setpgroup(&mut settings.attributes, 0))?;
    }
    let (argv, env) = argv_and_environment(tool, args, environment)?;
    let mut argv_pointers: Vec<*mut libc::c_char> = argv
        .iter()
        .map(|argument| argument.as_ptr().cast_mut())
        .collect();
    argv_pointers.push(std::ptr::null_mut());
    let mut env_pointers: Vec<*mut libc::c_char> =
        env.iter().map(|value| value.as_ptr().cast_mut()).collect();
    env_pointers.push(std::ptr::null_mut());
    let mut pid = 0;
    // SAFETY: argv/env are NUL-terminated pointer arrays, all strings and spawn
    // settings remain live. The child starts suspended on the retained inode.
    posix(unsafe {
        libc::posix_spawn(
            &mut pid,
            inode_path.as_ptr(),
            &settings.actions,
            &settings.attributes,
            argv_pointers.as_ptr(),
            env_pointers.as_ptr(),
        )
    })?;
    drop(slave);
    if let Err(error) = tool.revalidate() {
        // SAFETY: the suspended child ran no tool code; its own group is
        // killed and the PID reaped before the error is returned.
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
            let mut status = 0;
            libc::waitpid(pid, &mut status, 0);
        }
        return Err(error);
    }
    // SAFETY: the unreaped child PID still names the suspended process.
    if unsafe { libc::kill(pid, libc::SIGCONT) } != 0 {
        let error = io::Error::last_os_error();
        // SAFETY: as above.
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
            let mut status = 0;
            libc::waitpid(pid, &mut status, 0);
        }
        return Err(error);
    }
    Ok((pid, master))
}
