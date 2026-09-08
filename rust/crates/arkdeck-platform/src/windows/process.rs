use super::identity::{file_identity, process_image};
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
use windows_sys::Win32::System::JobObjects::*;
use windows_sys::Win32::System::Pipes::{CreatePipe, PeekNamedPipe};
use windows_sys::Win32::System::SystemInformation::GetWindowsDirectoryW;
use windows_sys::Win32::System::Threading::*;

pub(crate) struct RunningChild {
    process: Handle,
    job: Handle,
    assigned: bool,
    cleaned: bool,
    pub(crate) stdout: Option<PipeReader>,
    pub(crate) stderr: Option<PipeReader>,
}

pub(crate) struct PipeReader(File);

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
    pub(crate) fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
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
    pub(crate) fn kill_and_wait(&mut self) -> io::Result<()> {
        if self.cleaned {
            return Ok(());
        }
        // SAFETY: this unnamed job contains only this read-only child and its
        // descendants. Before job assignment the child is still suspended.
        bool_result(unsafe {
            if self.assigned {
                TerminateJobObject(self.job.raw(), 1)
            } else {
                TerminateProcess(self.process.raw(), 1)
            }
        })?;
        let deadline = Instant::now() + crate::process::CLEANUP_TIMEOUT;
        loop {
            // SAFETY: retained process handle prevents PID-reuse confusion.
            let wait = unsafe { WaitForSingleObject(self.process.raw(), 0) };
            if !matches!(wait, WAIT_OBJECT_0 | WAIT_TIMEOUT) {
                return Err(io::Error::last_os_error());
            }
            let mut accounting = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION::default();
            if self.assigned {
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
            }
            if wait == WAIT_OBJECT_0 && accounting.ActiveProcesses == 0 {
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
                TerminateJobObject(self.job.raw(), 1);
                if !self.assigned {
                    TerminateProcess(self.process.raw(), 1);
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
    fn new(handles: &mut [HANDLE]) -> io::Result<Self> {
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
        // SAFETY: handle slice and list remain live through CreateProcessW.
        bool_result(unsafe {
            UpdateProcThreadAttribute(
                value.pointer(),
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                handles.as_mut_ptr().cast(),
                std::mem::size_of_val(handles),
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

fn output_pipe() -> io::Result<(Handle, Handle)> {
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
    // SAFETY: only the read handle's inheritance flag is changed.
    bool_result(unsafe { SetHandleInformation(read.raw(), HANDLE_FLAG_INHERIT, 0) })?;
    Ok((read, write))
}

pub(crate) fn spawn(
    tool: &VerifiedTool,
    args: &[OsString],
    environment: &[(OsString, OsString)],
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
    let (stdout, out_write) = output_pipe()?;
    let (stderr, err_write) = output_pipe()?;
    let inheritable = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: null_mut(),
        bInheritHandle: 1,
    };
    let null_name = wide(OsStr::new("NUL"))?;
    // SAFETY: NUL is a fixed host device; read-only and explicitly inherited.
    let stdin = Handle::new(unsafe {
        CreateFileW(
            null_name.as_ptr(),
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            &inheritable,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null_mut(),
        )
    })?;
    let mut inherited = [stdin.raw(), out_write.raw(), err_write.raw()];
    let mut attributes = Attributes::new(&mut inherited)?;
    let startup = STARTUPINFOEXW {
        StartupInfo: STARTUPINFOW {
            cb: size_of::<STARTUPINFOEXW>() as u32,
            dwFlags: STARTF_USESTDHANDLES,
            hStdInput: stdin.raw(),
            hStdOutput: out_write.raw(),
            hStdError: err_write.raw(),
            ..Default::default()
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
    let mut environment_rows = vec![
        format!("PATH={root}\\System32"),
        format!("SystemRoot={root}"),
        format!("WINDIR={root}"),
    ];
    for (key, value) in environment {
        environment_rows.push(format!(
            "{}={}",
            key.to_string_lossy(),
            value.to_string_lossy()
        ));
    }
    environment_rows.sort_unstable_by_key(|row| row.to_ascii_uppercase());
    let mut environment_block = Vec::new();
    for row in environment_rows {
        environment_block.extend(wide(OsStr::new(&row))?);
    }
    environment_block.push(0);
    let mut info = PROCESS_INFORMATION::default();
    // SAFETY: all pointers are backed by live arrays; argv is encoded by the
    // Windows C-runtime quoting rules, application name is absolute. Creation is
    // suspended: no tool code runs before identity and job checks below.
    bool_result(unsafe {
        CreateProcessW(
            application.as_ptr(),
            command_line.as_mut_ptr(),
            null(),
            null(),
            1,
            CREATE_SUSPENDED
                | CREATE_NO_WINDOW
                | CREATE_UNICODE_ENVIRONMENT
                | EXTENDED_STARTUPINFO_PRESENT,
            environment_block.as_ptr().cast(),
            windows_directory.as_ptr(),
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
        stdout: Some(PipeReader(stdout.into_file())),
        stderr: Some(PipeReader(stderr.into_file())),
    };
    let admitted = (|| {
        // SAFETY: child is suspended and has not had a chance to spawn descendants.
        bool_result(unsafe { AssignProcessToJobObject(child.job.raw(), child.process.raw()) })?;
        child.assigned = true;
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
    drop(out_write);
    drop(err_write);
    Ok(child)
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
            stdout: None,
            stderr: None,
        };
        assert!(child.kill_and_wait().is_err());
    }
}
