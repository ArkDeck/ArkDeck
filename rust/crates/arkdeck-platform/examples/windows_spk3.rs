//! Executable OS probe for SPK-3. It does not dispatch device operations or claim
//! product/platform acceptance. The PowerShell harness records each real result.
use arkdeck_platform::{ProcessLimits, VerifiedTool};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::io::{self, Write};
use std::time::Duration;

fn main() {
    if let Err(error) = run() {
        println!(
            "{}",
            json!({"probe":"failure", "error":error.to_string(), "osError":error.raw_os_error()})
        );
        std::process::exit(1);
    }
}

fn run() -> io::Result<()> {
    let arguments: Vec<OsString> = std::env::args_os().skip(1).collect();
    let command = arguments
        .first()
        .and_then(|value| value.to_str())
        .unwrap_or("");
    match command {
        "child-echo" => {
            let strings: Vec<_> = arguments[1..]
                .iter()
                .map(|value| value.to_string_lossy())
                .collect();
            println!(
                "{}",
                json!({"args":strings, "port":std::env::var("OHOS_HDC_SERVER_PORT").ok(), "home":std::env::var("HOME").ok()})
            );
            Ok(())
        }
        "child-many-output" => {
            io::stdout().write_all(&vec![b'x'; 2 * 1024 * 1024])?;
            io::stderr().write_all(&vec![b'y'; 2 * 1024 * 1024])
        }
        "child-sleep" => {
            std::thread::sleep(Duration::from_secs(10));
            Ok(())
        }
        "process-selftest" => process_selftest(),
        #[cfg(windows)]
        "server-auth" | "raw-connect" | "connection-pid" | "raw-squat" | "bind"
        | "guard-server" => windows::run(command, &arguments[1..]),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "expected process-selftest or Windows probe command: server-auth, raw-connect, connection-pid, raw-squat, bind, guard-server",
        )),
    }
}

fn process_selftest() -> io::Result<()> {
    let path = std::env::current_exe()?.canonicalize()?;
    let digest = format!("{:x}", Sha256::digest(std::fs::read(&path)?));
    let tool = VerifiedTool::open(&path, &digest)?;
    let args: Vec<OsString> = [
        "child-echo",
        "",
        "embedded\"quote",
        "trailing\\",
        "space and \"quote\"\\",
        "& | $HOME ; `command`",
        "设备",
    ]
    .iter()
    .map(OsString::from)
    .collect();
    let output = tool.run_read_only_with_environment(
        &args,
        &[("OHOS_HDC_SERVER_PORT".into(), "8710".into())],
        ProcessLimits::default(),
    )?;
    let decoded: serde_json::Value =
        serde_json::from_slice(&output.stdout).map_err(io::Error::other)?;
    let expected: Vec<_> = args[1..]
        .iter()
        .map(|value| value.to_string_lossy())
        .collect();
    if !output.status.success()
        || decoded["args"] != json!(expected)
        || decoded["port"] != "8710"
        || !decoded["home"].is_null()
    {
        return Err(io::Error::other("argv/environment roundtrip failed"));
    }
    let overflow = tool
        .run_read_only(
            &["child-many-output".into()],
            ProcessLimits {
                timeout: Duration::from_secs(2),
                max_output_bytes: 4096,
            },
        )
        .unwrap_err();
    let timeout = tool
        .run_read_only(
            &["child-sleep".into()],
            ProcessLimits {
                timeout: Duration::from_millis(100),
                max_output_bytes: 4096,
            },
        )
        .unwrap_err();
    if overflow.kind() != io::ErrorKind::FileTooLarge || timeout.kind() != io::ErrorKind::TimedOut {
        return Err(io::Error::other("output or timeout refusal failed"));
    }
    println!(
        "{}",
        json!({"probe":"process-selftest","platform":std::env::consts::OS,"executableSha256":digest,"argvRoundtrip":true,"cleanChildEnvironment":true,"outputLimitRefused":true,"timeoutRefused":true,"deviceDispatchCount":0})
    );
    Ok(())
}

#[cfg(windows)]
mod windows {
    use super::*;
    use arkdeck_platform::{LocalConnection, LocalEndpoint, LocalListener, ServerIdentity};
    use std::mem::size_of;
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use std::ptr::{null, null_mut};
    use windows_sys::Win32::Foundation::*;
    use windows_sys::Win32::Security::Authorization::*;
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::Storage::FileSystem::*;
    use windows_sys::Win32::Storage::Packaging::Appx::GetPackageFamilyName;
    use windows_sys::Win32::System::Pipes::*;
    use windows_sys::Win32::System::Threading::GetCurrentProcess;

    fn wide(value: &std::ffi::OsStr) -> io::Result<Vec<u16>> {
        let mut encoded: Vec<u16> = value.encode_wide().collect();
        if encoded.contains(&0) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "NUL in probe argument",
            ));
        }
        encoded.push(0);
        Ok(encoded)
    }
    fn handle(raw: HANDLE) -> io::Result<OwnedHandle> {
        if raw.is_null() || raw == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: takes ownership of a fresh, valid handle from a Win32 API.
        Ok(unsafe { OwnedHandle::from_raw_handle(raw) })
    }
    fn endpoint(arguments: &[OsString]) -> io::Result<&OsString> {
        arguments
            .first()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing pipe endpoint"))
    }
    pub(super) fn run(command: &str, arguments: &[OsString]) -> io::Result<()> {
        let endpoint = endpoint(arguments)?;
        if command == "raw-squat" {
            return squat(endpoint);
        }
        if command == "guard-server" {
            if !endpoint
                .to_string_lossy()
                .starts_with(r"\\.\pipe\arkdeck-spk3-")
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "guard-server requires an isolated arkdeck-spk3-* endpoint",
                ));
            }
            let mut listener = LocalListener::bind(&LocalEndpoint::new(endpoint))?;
            println!(
                "{}",
                json!({"probe":"guard-server-ready", "pid":std::process::id()})
            );
            io::stdout().flush()?;
            let result = listener.accept();
            // The observable frame-consumer branch is entered only when the
            // production transport returns an authenticated connection.
            let handler_entries = usize::from(result.is_ok());
            println!(
                "{}",
                json!({"probe":"guard-server-result", "authenticated":result.is_ok(), "frameConsumerEntries":handler_entries, "error":result.as_ref().err().map(ToString::to_string)})
            );
            return Ok(());
        }
        if command == "bind" {
            let outcome = LocalListener::bind(&LocalEndpoint::new(endpoint));
            println!(
                "{}",
                json!({"probe":"bind", "accepted":outcome.is_ok(), "error":outcome.as_ref().err().map(ToString::to_string), "osError":outcome.as_ref().err().and_then(io::Error::raw_os_error)})
            );
            return Ok(());
        }
        if command == "server-auth" {
            let executable = arguments.get(1).ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "missing installed daemon path")
            })?;
            let mut identity = ServerIdentity::new(executable);
            identity.authenticode_sha256 = arguments
                .get(2)
                .and_then(|value| value.to_str())
                .filter(|value| *value != "-")
                .map(str::to_owned);
            identity.package_family = arguments
                .get(3)
                .and_then(|value| value.to_str())
                .filter(|value| *value != "-")
                .map(str::to_owned);
            let result = LocalConnection::connect(&LocalEndpoint::new(endpoint), &identity);
            println!(
                "{}",
                json!({"probe":"server-auth", "accepted":result.is_ok(), "peerPid":result.as_ref().ok().map(LocalConnection::authenticated_peer_pid), "clientPackageFamily":client_package_family(), "framesSent":0, "error":result.as_ref().err().map(ToString::to_string), "osError":result.as_ref().err().and_then(io::Error::raw_os_error)})
            );
            return Ok(());
        }
        let name = wide(endpoint)?;
        // Test-only raw client sends no bytes. This isolates OS account denial
        // and verifies the server-PID API on an actual CreateFileW client handle.
        // SAFETY: NUL-terminated name; acquired handle is immediately RAII-owned.
        let opened = handle(unsafe {
            CreateFileW(
                name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE | READ_CONTROL,
                0,
                null(),
                OPEN_EXISTING,
                SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                null_mut(),
            )
        });
        let mut pid = 0;
        let mut pid_result = None;
        if command == "connection-pid"
            && let Ok(pipe) = &opened
        {
            // SAFETY: actual client pipe handle and valid output pointer.
            let result = unsafe { GetNamedPipeServerProcessId(pipe.as_raw_handle(), &mut pid) };
            pid_result = Some(result != 0);
        }
        println!(
            "{}",
            json!({"probe":command,"connected":opened.is_ok(),"serverPidAvailable":pid_result,"serverPid":pid,"framesSent":0,"osError":opened.as_ref().err().and_then(io::Error::raw_os_error)})
        );
        Ok(())
    }

    fn client_package_family() -> Option<String> {
        let mut length = 0;
        // SAFETY: current-process pseudo-handle and documented size query.
        let status = unsafe { GetPackageFamilyName(GetCurrentProcess(), &mut length, null_mut()) };
        if status != ERROR_INSUFFICIENT_BUFFER || length == 0 || length > 4096 {
            return None;
        }
        let mut output = vec![0u16; length as usize];
        // SAFETY: output buffer is sized from the preceding query.
        if unsafe { GetPackageFamilyName(GetCurrentProcess(), &mut length, output.as_mut_ptr()) }
            != ERROR_SUCCESS
        {
            return None;
        }
        Some(String::from_utf16_lossy(&output[..length as usize - 1]))
    }

    fn squat(endpoint: &OsString) -> io::Result<()> {
        // This deliberately permissive hostile-server fixture cannot occupy the
        // default product endpoint. The harness uses an isolated diagnostic name.
        if !endpoint
            .to_string_lossy()
            .starts_with(r"\\.\pipe\arkdeck-spk3-")
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "squatter requires an isolated arkdeck-spk3-* endpoint",
            ));
        }
        let sddl = wide(std::ffi::OsStr::new("D:P(A;;GA;;;WD)"))?;
        let mut descriptor = null_mut();
        // SAFETY: NUL-terminated SDDL and output descriptor pointer.
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                null_mut(),
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        let attributes = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        let name = wide(endpoint)?;
        // SAFETY: creation consumes the live name/descriptor synchronously.
        let opened = handle(unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                4096,
                4096,
                5000,
                &attributes,
            )
        });
        // SAFETY: descriptor came from the LocalAlloc-family conversion API.
        unsafe {
            LocalFree(descriptor);
        }
        let pipe = opened?;
        println!(
            "{}",
            json!({"probe":"squatter-ready", "pid":std::process::id()})
        );
        io::stdout().flush()?;
        // SAFETY: synchronous test fixture handle, no OVERLAPPED argument.
        if unsafe { ConnectNamedPipe(pipe.as_raw_handle(), null_mut()) } == 0
            && io::Error::last_os_error().raw_os_error() != Some(ERROR_PIPE_CONNECTED as i32)
        {
            return Err(io::Error::last_os_error());
        }
        let mut bytes = [0u8; 4096];
        let mut read = 0;
        // SAFETY: writable bounded byte array and synchronous pipe handle.
        let result = unsafe {
            ReadFile(
                pipe.as_raw_handle(),
                bytes.as_mut_ptr(),
                bytes.len() as u32,
                &mut read,
                null_mut(),
            )
        };
        if result == 0 && !matches!(io::Error::last_os_error().raw_os_error(), Some(109 | 233)) {
            return Err(io::Error::last_os_error());
        }
        println!(
            "{}",
            json!({"probe":"squatter-result", "receivedBytes":read})
        );
        Ok(())
    }
}
