//! The records a managed server and the commandless server proof produce,
//! shared by the macOS owners (`managed_server.rs`, `macos_server.rs`) and
//! the Windows ones (`windows/managed.rs`, `windows/server.rs`, TASK-XPA-005).
//! A birth is the process's start time as seconds and microseconds since the
//! Unix epoch: `proc_pidinfo` on macOS, `GetProcessTimes` on Windows.
use std::ffi::OsString;
use std::net::SocketAddrV4;
use std::path::PathBuf;

/// Swift `HDCServerProcessIdentityReceipt`: the birth identity of the one
/// process that owns the registered endpoint with the verified executable.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerIdentityReceipt {
    pub pid: i32,
    pub start_seconds: u64,
    pub start_microseconds: u64,
    pub executable_path: PathBuf,
    pub executable_sha256: String,
    pub endpoint: SocketAddrV4,
}

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
    /// Unix only: a Windows server always ends with an exit code.
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
