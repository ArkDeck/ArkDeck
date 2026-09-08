use super::{
    VerifiedTool, denied, invalid, retire_unix_child, same_metadata, terminate_unix_child,
};
use std::ffi::{CString, OsString};
use std::fs::File;
use std::io;
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

pub(super) fn only_retained_zombie_remains(pid: libc::pid_t, group: bool) -> bool {
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
        || info.si_pid != pid
    {
        return false;
    }
    if !group {
        return true;
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
        return false;
    }
    members[..returned as usize / std::mem::size_of::<libc::pid_t>()]
        .iter()
        .all(|member| *member == pid)
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

fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
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
    // SAFETY: nonblocking read permits bounded cancellation even if a child
    // deliberately leaves an inherited descriptor open in a detached descendant.
    if unsafe { libc::fcntl(read.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((read, write))
}

pub(super) fn spawn(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
) -> io::Result<RunningChild> {
    let inode_path = format!("/.vol/{}/{}", tool.initial.dev(), tool.initial.ino());
    if !same_metadata(&tool.initial, &std::fs::metadata(&inode_path)?) {
        return Err(denied("inode-bound executable path unavailable"));
    }
    let inode_path = CString::new(inode_path).map_err(|_| invalid("invalid inode path"))?;
    let (out_read, out_write) = pipe()?;
    let (err_read, err_write) = pipe()?;
    let mut settings = SpawnSettings::new()?;
    // SAFETY: actions/attributes are initialized; all named descriptors are live.
    unsafe {
        posix(posix_spawn_file_actions_addchdir_np(
            &mut settings.actions,
            c"/".as_ptr(),
        ))?;
        posix(libc::posix_spawn_file_actions_addopen(
            &mut settings.actions,
            libc::STDIN_FILENO,
            c"/dev/null".as_ptr(),
            libc::O_RDONLY,
            0,
        ))?;
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
    let argv: Vec<CString> = std::iter::once(tool.path.as_os_str())
        .chain(args.iter().map(OsString::as_os_str))
        .map(|argument| CString::new(argument.as_bytes()).map_err(|_| invalid("NUL in argv")))
        .collect::<io::Result<_>>()?;
    let mut argv_pointers: Vec<*mut libc::c_char> = argv
        .iter()
        .map(|argument| argument.as_ptr().cast_mut())
        .collect();
    argv_pointers.push(std::ptr::null_mut());
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
    // SAFETY: retained, unreaped child PID still names the suspended process.
    if unsafe { libc::kill(pid, libc::SIGCONT) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(child)
}
