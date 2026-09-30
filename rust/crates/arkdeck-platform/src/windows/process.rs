use super::identity::{file_identity, process_image, process_started};
use super::{Handle, bool_result, wide};
use crate::{VerifiedTool, denied, invalid};
use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{self, Read};
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::ExitStatusExt;
use std::process::ExitStatus;
use std::ptr::{null, null_mut};
use std::time::{Duration, Instant};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::Console::HPCON;
use windows_sys::Win32::System::JobObjects::*;
use windows_sys::Win32::System::Pipes::{CreatePipe, PeekNamedPipe};
use windows_sys::Win32::System::SystemInformation::GetWindowsDirectoryW;
use windows_sys::Win32::System::Threading::*;

pub(crate) struct RunningChild {
    process: Handle,
    job: Handle,
    assigned: bool,
    cleaned: bool,
    /// The child's PID and its `GetProcessTimes` creation time, both read
    /// while it was still suspended.
    pub(crate) pid: u32,
    pub(crate) started: u64,
    pub(crate) stdout: Option<PipeReader>,
    pub(crate) stderr: Option<PipeReader>,
}

pub(crate) struct PipeReader(File);

impl PipeReader {
    /// The pipe's read end, for a blocking reader thread.
    pub(crate) fn into_file(self) -> File {
        self.0
    }
}

impl Read for PipeReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let mut available = 0;
        // SAFETY: this is the sole reader for this anonymous pipe. Peek does
        // not consume bytes; a following read never requests more than available.
        let result = unsafe {
            PeekNamedPipe(
                self.0.as_raw_handle(),
                null_mut(),
                0,
                null_mut(),
                &mut available,
                null_mut(),
            )
        };
        if result == 0 {
            let error = io::Error::last_os_error();
            return if matches!(
                error.raw_os_error().map(|code| code as u32),
                Some(ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED)
            ) {
                Ok(0)
            } else {
                Err(error)
            };
        }
        if available == 0 {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        let length = buffer.len().min(available as usize);
        self.0.read(&mut buffer[..length])
    }
}

impl RunningChild {
    pub(crate) fn try_wait(&self) -> io::Result<Option<ExitStatus>> {
        // SAFETY: retained process handle; zero wait only reads kernel state.
        match unsafe { WaitForSingleObject(self.process.raw(), 0) } {
            WAIT_TIMEOUT => Ok(None),
            WAIT_OBJECT_0 => {
                let mut code = 0;
                // SAFETY: valid output and live handle to a terminated process.
                bool_result(unsafe { GetExitCodeProcess(self.process.raw(), &mut code) })?;
                Ok(Some(ExitStatus::from_raw(code)))
            }
            _ => Err(io::Error::last_os_error()),
        }
    }
    /// Terminates every process of the child's Job object at once: the
    /// Windows form of a group kill. There is no TERM on Windows, so no
    /// grace precedes it (gate inventory §8 question 4).
    pub(crate) fn terminate_group(&self) -> io::Result<()> {
        // SAFETY: this unnamed job holds only this child and its
        // descendants; before job assignment the child is still suspended.
        bool_result(unsafe {
            if self.assigned {
                TerminateJobObject(self.job.raw(), TERMINATED_EXIT_CODE)
            } else {
                TerminateProcess(self.process.raw(), TERMINATED_EXIT_CODE)
            }
        })
    }

    /// No process of the child's Job object is left, the child included.
    pub(crate) fn group_drained(&self) -> io::Result<bool> {
        // SAFETY: retained process handle; zero wait only reads kernel state.
        let wait = unsafe { WaitForSingleObject(self.process.raw(), 0) };
        if !matches!(wait, WAIT_OBJECT_0 | WAIT_TIMEOUT) {
            return Err(io::Error::last_os_error());
        }
        Ok(wait == WAIT_OBJECT_0 && (!self.assigned || self.active_processes()? == 0))
    }

    fn active_processes(&self) -> io::Result<u32> {
        let mut accounting = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION::default();
        // SAFETY: class and output length match the accounting structure.
        bool_result(unsafe {
            QueryInformationJobObject(
                self.job.raw(),
                JobObjectBasicAccountingInformation,
                std::ptr::from_mut(&mut accounting).cast(),
                size_of::<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>() as u32,
                null_mut(),
            )
        })?;
        Ok(accounting.ActiveProcesses)
    }

    /// The process `process` names is a member of this child's Job object.
    pub(crate) fn job_contains(&self, process: HANDLE) -> io::Result<bool> {
        let mut member = 0;
        // SAFETY: both handles are live; the output is a plain BOOL.
        bool_result(unsafe { IsProcessInJob(process, self.job.raw(), &mut member) })?;
        Ok(self.assigned && member != 0)
    }

    pub(crate) fn kill_and_wait(&mut self) -> io::Result<()> {
        if self.cleaned {
            return Ok(());
        }
        self.terminate_group()?;
        let deadline = Instant::now() + crate::process::CLEANUP_TIMEOUT;
        loop {
            // SAFETY: retained process handle prevents PID-reuse confusion.
            let wait = unsafe { WaitForSingleObject(self.process.raw(), 0) };
            if !matches!(wait, WAIT_OBJECT_0 | WAIT_TIMEOUT) {
                return Err(io::Error::last_os_error());
            }
            let active = if self.assigned {
                self.active_processes()?
            } else {
                0
            };
            if wait == WAIT_OBJECT_0 && active == 0 {
                self.cleaned = true;
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Windows child job did not terminate within cleanup budget",
                ));
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
impl Drop for RunningChild {
    fn drop(&mut self) {
        if !self.cleaned {
            // SAFETY: only exact handles created by this spawn are targeted.
            // Drop must not repeat a timed-out wait. Closing the job is a second
            // kernel-enforced termination request for all assigned descendants.
            unsafe {
                TerminateJobObject(self.job.raw(), TERMINATED_EXIT_CODE);
                if !self.assigned {
                    TerminateProcess(self.process.raw(), TERMINATED_EXIT_CODE);
                }
            }
        }
    }
}

struct Attributes {
    storage: Vec<usize>,
    initialized: bool,
}
impl Attributes {
    /// The explicit list of handles a child inherits.
    fn handles(handles: &mut [HANDLE]) -> io::Result<Self> {
        let size = std::mem::size_of_val(handles);
        // SAFETY: the handle slice outlives the list's use by CreateProcessW.
        unsafe {
            Self::new(
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                handles.as_mut_ptr().cast(),
                size,
            )
        }
    }

    /// The pseudo console a child is attached to: the handle value itself
    /// is the attribute, as `CreatePseudoConsole`'s documentation passes it.
    fn pseudo_console(console: HPCON) -> io::Result<Self> {
        // SAFETY: the attribute is the handle value, not a pointer to it;
        // the caller keeps the console open through CreateProcessW.
        unsafe {
            Self::new(
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE as usize,
                console as *mut std::ffi::c_void,
                size_of::<HPCON>(),
            )
        }
    }

    /// # Safety
    /// `data` and `size` must describe `attribute` as
    /// `UpdateProcThreadAttribute` documents it, live through CreateProcessW.
    unsafe fn new(attribute: usize, data: *mut std::ffi::c_void, size: usize) -> io::Result<Self> {
        let mut length = 0;
        // SAFETY: documented attribute list length query.
        unsafe {
            InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut length);
        }
        if length == 0 || length > 1024 * 1024 {
            return Err(io::Error::last_os_error());
        }
        let mut value = Self {
            storage: vec![0; length.div_ceil(size_of::<usize>())],
            initialized: false,
        };
        // SAFETY: pointer-aligned storage covers the requested byte length.
        bool_result(unsafe {
            InitializeProcThreadAttributeList(value.pointer(), 1, 0, &mut length)
        })?;
        value.initialized = true;
        // SAFETY: the caller guarantees the attribute value; the list is live.
        bool_result(unsafe {
            UpdateProcThreadAttribute(
                value.pointer(),
                0,
                attribute,
                data,
                size,
                null_mut(),
                null(),
            )
        })?;
        Ok(value)
    }
    fn pointer(&mut self) -> LPPROC_THREAD_ATTRIBUTE_LIST {
        self.storage.as_mut_ptr().cast()
    }
}
impl Drop for Attributes {
    fn drop(&mut self) {
        // SAFETY: initialized attribute list, freed before backing storage.
        if self.initialized {
            unsafe {
                DeleteProcThreadAttributeList(self.pointer());
            }
        }
    }
}

/// The exit code of a child its owner terminated (a deadline, a
/// cancellation, a stop or cleanup).
pub(crate) const TERMINATED_EXIT_CODE: u32 = 1;

/// Each output pipe's buffer: a writer blocks only once this much is unread.
const OUTPUT_PIPE_BYTES: u32 = 64 * 1024;

fn output_pipe() -> io::Result<(Handle, Handle)> {
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: null_mut(),
        bInheritHandle: 1,
    };
    let (mut read, mut write) = (null_mut(), null_mut());
    // SAFETY: valid output pointers; both handles immediately enter RAII ownership.
    bool_result(unsafe { CreatePipe(&mut read, &mut write, &attributes, OUTPUT_PIPE_BYTES) })?;
    let read = Handle::new(read)?;
    let write = Handle::new(write)?;
    // SAFETY: only the read handle's inheritance flag is changed.
    bool_result(unsafe { SetHandleInformation(read.raw(), HANDLE_FLAG_INHERIT, 0) })?;
    Ok((read, write))
}

pub(crate) fn spawn(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
) -> io::Result<RunningChild> {
    spawn_in(tool, args, environment, None)
}

/// The names of the base environment every child starts from, nothing
/// inherited: the system directory as the only search path, and the two
/// names the system itself needs.
pub(crate) const BASE_ENVIRONMENT: [&str; 3] = ["PATH", "SystemRoot", "WINDIR"];

/// `spawn` with a child-only working directory (NUL-terminated UTF-16,
/// validated by the caller; `None` is the Windows directory). The
/// environment rows are overlaid on the base; a caller validates them first.
pub(crate) fn spawn_in(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
    working_directory: Option<&[u16]>,
) -> io::Result<RunningChild> {
    spawn_with(tool, args, environment, working_directory, None, None)
}

/// `spawn_in` with `input` — the inheritable read end of an [`input_pipe`] —
/// as the child's stdin in place of `NUL`: the paired server's launch
/// (`arkforged`, TASK-XPA-010). The caller keeps the write end and drops its
/// own copy of `input` once this returns.
pub(crate) fn spawn_paired(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
    working_directory: &[u16],
    input: &Handle,
) -> io::Result<RunningChild> {
    spawn_with(
        tool,
        args,
        environment,
        Some(working_directory),
        None,
        Some(input),
    )
}

/// A child's input pipe: the read end inheritable, the write end the
/// owner's alone, so that closing it is the child's end of input.
pub(crate) fn input_pipe() -> io::Result<(Handle, Handle)> {
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: null_mut(),
        bInheritHandle: 1,
    };
    let (mut read, mut write) = (null_mut(), null_mut());
    // SAFETY: valid output pointers; both handles immediately enter RAII ownership.
    bool_result(unsafe { CreatePipe(&mut read, &mut write, &attributes, 0) })?;
    let read = Handle::new(read)?;
    let write = Handle::new(write)?;
    // SAFETY: only the write handle's inheritance flag is changed.
    bool_result(unsafe { SetHandleInformation(write.raw(), HANDLE_FLAG_INHERIT, 0) })?;
    Ok((read, write))
}

/// `spawn_in` with the child attached to a pseudo console instead of pipes
/// (TASK-XPA-011, G19): its standard handles are the console's, it inherits
/// no handle at all, and everything else — the suspended start, the image
/// proof before resume, the kill-on-close Job, the clean environment and the
/// argv array — is the same. The caller keeps `console` open until the
/// child's Job has ended.
pub(crate) fn spawn_attached(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
    working_directory: Option<&[u16]>,
    console: HPCON,
) -> io::Result<RunningChild> {
    spawn_with(
        tool,
        args,
        environment,
        working_directory,
        Some(console),
        None,
    )
}

fn spawn_with(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
    working_directory: Option<&[u16]>,
    console: Option<HPCON>,
    input: Option<&Handle>,
) -> io::Result<RunningChild> {
    if !tool
        .path
        .extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("exe"))
    {
        return Err(invalid(
            "verified Windows tools must be executable images, not shell scripts",
        ));
    }
    let application = wide(tool.path.as_os_str())?;
    let mut command_line = command_line(tool.path.as_os_str(), args)?;
    // Pipes: NUL stdin (or the paired input) and two output pipes, the only
    // handles inherited. The list stays live through CreateProcessW.
    let mut pipes = None;
    let mut inherited: [HANDLE; 3];
    let mut standard_input: HANDLE = null_mut();
    let mut attributes = match console {
        None => {
            let (stdout, out_write) = output_pipe()?;
            let (stderr, err_write) = output_pipe()?;
            let inheritable = SECURITY_ATTRIBUTES {
                nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: null_mut(),
                bInheritHandle: 1,
            };
            let stdin = match input {
                Some(_) => None,
                None => {
                    let null_name = wide(OsStr::new("NUL"))?;
                    // SAFETY: NUL is a fixed host device; read-only and explicitly inherited.
                    Some(Handle::new(unsafe {
                        CreateFileW(
                            null_name.as_ptr(),
                            GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE,
                            &inheritable,
                            OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL,
                            null_mut(),
                        )
                    })?)
                }
            };
            let pipes = pipes.insert((stdin, out_write, err_write, stdout, stderr));
            let stdin = match (&pipes.0, input) {
                (Some(stdin), _) | (None, Some(stdin)) => stdin.raw(),
                (None, None) => unreachable!("NUL is opened when no input is named"),
            };
            standard_input = stdin;
            inherited = [stdin, pipes.1.raw(), pipes.2.raw()];
            Attributes::handles(&mut inherited)?
        }
        Some(console) => Attributes::pseudo_console(console)?,
    };
    let startup = STARTUPINFOEXW {
        StartupInfo: match &pipes {
            Some((_, out_write, err_write, _, _)) => STARTUPINFOW {
                cb: size_of::<STARTUPINFOEXW>() as u32,
                dwFlags: STARTF_USESTDHANDLES,
                hStdInput: standard_input,
                hStdOutput: out_write.raw(),
                hStdError: err_write.raw(),
                ..Default::default()
            },
            // Null standard handles: with nothing inherited, the child
            // takes the pseudo console's own input and output, never this
            // process's (possibly redirected) standard handles.
            None => STARTUPINFOW {
                cb: size_of::<STARTUPINFOEXW>() as u32,
                dwFlags: STARTF_USESTDHANDLES,
                ..Default::default()
            },
        },
        lpAttributeList: attributes.pointer(),
    };
    // SAFETY: unnamed job, no inherited/shared handles.
    let job = Handle::new(unsafe { CreateJobObjectW(null(), null()) })?;
    let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    // SAFETY: limit structure size and class agree.
    bool_result(unsafe {
        SetInformationJobObject(
            job.raw(),
            JobObjectExtendedLimitInformation,
            std::ptr::from_ref(&limits).cast(),
            size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        )
    })?;
    let mut windows_directory = vec![0u16; 32768];
    // SAFETY: bounded output UTF-16 buffer.
    let length = unsafe {
        GetWindowsDirectoryW(
            windows_directory.as_mut_ptr(),
            windows_directory.len() as u32,
        )
    } as usize;
    if length == 0 || length >= windows_directory.len() {
        return Err(io::Error::last_os_error());
    }
    windows_directory.truncate(length + 1);
    let root = String::from_utf16(&windows_directory[..length])
        .map_err(|_| invalid("invalid Windows system directory"))?;
    let system = format!("{root}\\System32");
    let mut environment_rows: Vec<(Vec<u16>, Vec<u16>)> = BASE_ENVIRONMENT
        .iter()
        .zip([system.as_str(), root.as_str(), root.as_str()])
        .map(|(key, value)| (key.encode_utf16().collect(), value.encode_utf16().collect()))
        .collect();
    for (key, value) in environment {
        environment_rows.push((key.encode_wide().collect(), value.encode_wide().collect()));
    }
    // CreateProcessW takes the block sorted by name, case-insensitively.
    environment_rows.sort_by_cached_key(|(key, _)| uppercase(key));
    let mut environment_block = Vec::new();
    for (key, value) in environment_rows {
        if key.is_empty()
            || key.contains(&0)
            || key.contains(&u16::from(b'='))
            || value.contains(&0)
        {
            return Err(invalid(
                "environment names must be non-empty without = or NUL, values without NUL",
            ));
        }
        environment_block.extend(key);
        environment_block.push(u16::from(b'='));
        environment_block.extend(value);
        environment_block.push(0);
    }
    environment_block.push(0);
    let mut info = PROCESS_INFORMATION::default();
    // A child on a pseudo console gets that console; one on pipes gets none.
    let creation = CREATE_SUSPENDED
        | CREATE_UNICODE_ENVIRONMENT
        | EXTENDED_STARTUPINFO_PRESENT
        | if pipes.is_some() { CREATE_NO_WINDOW } else { 0 };
    // SAFETY: all pointers are backed by live arrays; argv is encoded by the
    // Windows C-runtime quoting rules, application name is absolute. Creation is
    // suspended: no tool code runs before identity and job checks below.
    bool_result(unsafe {
        CreateProcessW(
            application.as_ptr(),
            command_line.as_mut_ptr(),
            null(),
            null(),
            i32::from(pipes.is_some()),
            creation,
            environment_block.as_ptr().cast(),
            working_directory.map_or(windows_directory.as_ptr(), <[u16]>::as_ptr),
            &startup.StartupInfo,
            &mut info,
        )
    })?;
    let process = Handle::new(info.hProcess)?;
    let thread = Handle::new(info.hThread)?;
    let mut child = RunningChild {
        process,
        job,
        assigned: false,
        cleaned: false,
        pid: info.dwProcessId,
        started: 0,
        stdout: None,
        stderr: None,
    };
    let mut pipes = pipes.map(|(stdin, out_write, err_write, stdout, stderr)| {
        child.stdout = Some(PipeReader(stdout.into_file()));
        child.stderr = Some(PipeReader(stderr.into_file()));
        (stdin, out_write, err_write)
    });
    let admitted = (|| {
        // SAFETY: child is suspended and has not had a chance to spawn descendants.
        bool_result(unsafe { AssignProcessToJobObject(child.job.raw(), child.process.raw()) })?;
        child.assigned = true;
        // Read while suspended: a child that ends at once still has a birth.
        child.started = process_started(child.process.raw())?;
        let image_path = process_image(child.process.raw())?.canonicalize()?;
        let image = crate::process::open_locked_file(&image_path)?;
        if image_path != tool.path || file_identity(&image)? != tool.identity {
            return Err(denied(
                "suspended child image differs from retained verified executable",
            ));
        }
        tool.revalidate()?;
        // SAFETY: resume only this newly-created child's initial thread.
        if unsafe { ResumeThread(thread.raw()) } == u32::MAX {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    })();
    if let Err(error) = admitted {
        child.kill_and_wait().map_err(|cleanup| {
            io::Error::new(
                cleanup.kind(),
                format!(
                    "suspended child cleanup failed after admission refusal ({error}): {cleanup}"
                ),
            )
        })?;
        return Err(error);
    }
    // The child holds its own copies of the pipe ends it writes.
    pipes.take();
    Ok(child)
}

/// A UTF-16 name folded as the environment block sorts and compares names.
pub(crate) fn uppercase(name: &[u16]) -> Vec<u16> {
    let mut folded = Vec::with_capacity(name.len());
    for unit in char::decode_utf16(name.iter().copied()) {
        match unit {
            Ok(character) => {
                let mut buffer = [0; 2];
                for upper in character.to_uppercase() {
                    folded.extend_from_slice(upper.encode_utf16(&mut buffer));
                }
            }
            Err(unpaired) => folded.push(unpaired.unpaired_surrogate()),
        }
    }
    folded
}

/// Encode an argv array for CreateProcessW's C-runtime parser. This never runs
/// cmd.exe/PowerShell and characters such as & | $ remain literal arguments.
fn command_line(executable: &OsStr, args: &[OsString]) -> io::Result<Vec<u16>> {
    let mut output = Vec::new();
    for argument in std::iter::once(executable).chain(args.iter().map(OsString::as_os_str)) {
        if !output.is_empty() {
            output.push(b' ' as u16);
        }
        output.push(b'"' as u16);
        let mut slashes = 0;
        for ch in argument.encode_wide() {
            if ch == 0 {
                return Err(invalid("NUL is not permitted in argv"));
            }
            if ch == b'\\' as u16 {
                slashes += 1;
                continue;
            }
            if ch == b'"' as u16 {
                output.extend(std::iter::repeat_n(b'\\' as u16, slashes * 2 + 1));
            } else {
                output.extend(std::iter::repeat_n(b'\\' as u16, slashes));
            }
            slashes = 0;
            output.push(ch);
        }
        output.extend(std::iter::repeat_n(b'\\' as u16, slashes * 2));
        output.push(b'"' as u16);
    }
    output.push(0);
    if output.len() > 32767 {
        return Err(invalid("Windows command line is too long"));
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn argv_preserves_empty_quotes_slashes_and_shell_metacharacters() {
        let encoded = command_line(
            OsStr::new(r"C:\Program Files\hdc.exe"),
            &["".into(), "a\"b\\".into(), "& | $HOME".into()],
        )
        .unwrap();
        assert_eq!(
            String::from_utf16(&encoded[..encoded.len() - 1]).unwrap(),
            "\"C:\\Program Files\\hdc.exe\" \"\" \"a\\\"b\\\\\" \"& | $HOME\""
        );
    }
    #[test]
    fn argv_rejects_embedded_nul() {
        assert!(command_line(OsStr::new("tool.exe"), &["bad\0arg".into()]).is_err());
    }

    #[test]
    fn pipe_reader_never_blocks_on_an_open_silent_writer() {
        let (read, write) = output_pipe().unwrap();
        let mut reader = PipeReader(read.into_file());
        assert_eq!(
            reader.read(&mut [0; 8]).unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        use std::io::Write;
        write.into_file().write_all(b"bytes").unwrap();
        let mut bytes = [0; 8];
        assert_eq!(reader.read(&mut bytes).unwrap(), 5);
        assert_eq!(&bytes[..5], b"bytes");
        assert_eq!(reader.read(&mut bytes).unwrap(), 0);
    }

    #[test]
    fn invalid_job_cleanup_is_reported_to_the_caller() {
        // Deliberately use valid event handles of the wrong kernel object type.
        // This cannot terminate a process and exercises the real API failure.
        let mut child = RunningChild {
            // SAFETY: unnamed event creation has no pointer preconditions.
            process: Handle::new(unsafe { CreateEventW(null(), 1, 0, null()) }).unwrap(),
            // SAFETY: separate unnamed event, never a process/job handle.
            job: Handle::new(unsafe { CreateEventW(null(), 1, 0, null()) }).unwrap(),
            assigned: true,
            cleaned: false,
            pid: 0,
            started: 0,
            stdout: None,
            stderr: None,
        };
        assert!(child.kill_and_wait().is_err());
    }

    const TREE_REPORT: &str = "ARKDECK_JOB_TREE_REPORT";
    const HANG: &str = "ARKDECK_JOB_TREE_HANG";

    /// A grandchild's body: selected by name in a re-execution of this test
    /// binary with `ARKDECK_JOB_TREE_HANG` set, it never ends on its own.
    /// Run as an ordinary test, it does nothing.
    #[test]
    fn job_tree_grandchild() {
        if std::env::var_os(HANG).is_some() {
            loop {
                std::thread::park();
            }
        }
    }

    /// A child's body: it starts a grandchild (which joins the child's Job),
    /// names it in the report file (written whole, then renamed) and never
    /// ends on its own. Run as an ordinary test, it does nothing.
    #[test]
    fn job_tree_child() {
        let Some(report) = std::env::var_os(TREE_REPORT) else {
            return;
        };
        let mut grandchild = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "windows::process::tests::job_tree_grandchild"])
            .env(HANG, "1")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let report = std::path::PathBuf::from(report);
        let partial = report.with_extension("partial");
        std::fs::write(&partial, grandchild.id().to_string()).unwrap();
        std::fs::rename(&partial, &report).unwrap();
        // The grandchild never ends on its own: this waits until the Job
        // ends them both.
        let _ = grandchild.wait();
        loop {
            std::thread::park();
        }
    }

    /// Kill-on-close alone: a child whose owner neither terminated nor
    /// waited for its Job (the cleanup is skipped here on purpose) still
    /// ends with its whole tree once the last Job handle closes.
    #[test]
    fn closing_the_job_handle_kills_a_live_child_tree() {
        use sha2::{Digest, Sha256};
        let executable = std::env::current_exe().unwrap().canonicalize().unwrap();
        let digest = format!("{:x}", Sha256::digest(std::fs::read(&executable).unwrap()));
        let tool = VerifiedTool::open(&executable, &digest).unwrap();
        let directory = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-job-tree-{:032x}",
            u128::from_le_bytes(crate::random_bytes().unwrap())
        ));
        std::fs::create_dir(&directory).unwrap();
        let report = directory.join("grandchild");
        let mut child = spawn_in(
            &tool,
            &[
                "--exact".into(),
                "windows::process::tests::job_tree_child".into(),
            ],
            &[(TREE_REPORT.into(), report.clone().into_os_string())],
            None,
        )
        .unwrap();
        let open = |pid| {
            // SAFETY: query-only access; the handle is owned at once.
            Handle::new(unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                    0,
                    pid,
                )
            })
            .unwrap()
        };
        let ended_within = |process: &Handle, within: Duration| {
            // SAFETY: live owned process handle with SYNCHRONIZE access.
            let wait = unsafe { WaitForSingleObject(process.raw(), within.as_millis() as u32) };
            assert!(wait == WAIT_OBJECT_0 || wait == WAIT_TIMEOUT);
            wait == WAIT_OBJECT_0
        };
        let child_process = open(child.pid);
        let deadline = Instant::now() + Duration::from_secs(20);
        let pid = loop {
            if let Some(pid) = std::fs::read_to_string(&report)
                .ok()
                .and_then(|text| text.parse::<u32>().ok())
            {
                break pid;
            }
            assert!(Instant::now() < deadline, "the grandchild was never named");
            assert!(!ended_within(&child_process, Duration::from_millis(10)));
        };
        let grandchild = open(pid);
        // Opened while the grandchild is alive: it is a member of the Job.
        assert!(child.job_contains(grandchild.raw()).unwrap());
        assert!(!ended_within(&grandchild, Duration::ZERO));
        // Skip the owner's own termination: only the Job handle closes.
        child.cleaned = true;
        drop(child);
        assert!(ended_within(&child_process, Duration::from_secs(5)));
        assert!(ended_within(&grandchild, Duration::from_secs(5)));
        let _ = std::fs::remove_dir_all(&directory);
    }
}
