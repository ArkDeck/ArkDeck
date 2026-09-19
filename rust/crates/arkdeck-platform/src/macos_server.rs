//! The commandless proof that an HDC server already exists on macOS, ported
//! from Swift's `HDCExact320FSystemIdentityObserver` (TASK-XPA-016, SPK-6).
//!
//! The proof never connects to the endpoint and never launches a client, not
//! even `checkserver`, which may bootstrap a server. It reads what the kernel
//! says through libproc: which processes run the verified executable, which
//! of them owns exactly one TCP listener on the exact registered loopback
//! endpoint, and when that process was born. Two scans must agree before a
//! lease exists, and a lease revalidates against the same birth identity, so
//! a process that exits and a PID that is recycled both fail closed.
//!
//! Beyond Swift, the owner must be the calling user, as the Windows lease
//! requires: a server another account started is refused rather than trusted
//! on its path alone.
use crate::{VerifiedTool, denied, invalid};
use std::ffi::CStr;
use std::io;
use std::net::{Ipv4Addr, SocketAddrV4};
use std::path::{Path, PathBuf};

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

/// Holds a kernel-proven, already-running HDC process through an observation.
/// Acquiring and revalidating it performs no network connect and no process
/// execution, and never starts, stops or adopts an external HDC server.
#[derive(Debug)]
pub struct LoopbackServerLease {
    identity: ServerIdentityReceipt,
}

impl LoopbackServerLease {
    /// Swift `observe`: the endpoint must be the exact IPv4 loopback, the tool
    /// must still verify, and two consecutive scans must name the same process.
    ///
    /// `NotFound` is Swift's `unavailable` (no such process); `PermissionDenied`
    /// is its `unknown` (ambiguous, changed, unregistered or unscannable).
    pub fn acquire(tool: &VerifiedTool, endpoint: SocketAddrV4) -> io::Result<Self> {
        if *endpoint.ip() != Ipv4Addr::LOCALHOST || endpoint.port() == 0 {
            return Err(invalid(
                "HDC observation requires the exact IPv4 loopback endpoint",
            ));
        }
        tool.revalidate()?;
        let first = scan(tool, endpoint)?;
        tool.revalidate()?;
        let second = scan(tool, endpoint)?;
        if first != second {
            return Err(denied(
                "server process/listener identity changed during observation",
            ));
        }
        let lease = Self { identity: second };
        lease.revalidate()?;
        Ok(lease)
    }

    /// The process is still the one observed at acquisition (same birth) and
    /// still owns exactly one registered listener on the endpoint.
    pub fn revalidate(&self) -> io::Result<()> {
        let identity = &self.identity;
        let changed = || denied("HDC server listener identity changed during observation");
        let birth = process_birth(identity.pid).ok_or_else(changed)?;
        if birth.uid != effective_uid()
            || (birth.start_seconds, birth.start_microseconds)
                != (identity.start_seconds, identity.start_microseconds)
        {
            return Err(changed());
        }
        match registered_listener_count(identity.pid, identity.endpoint.port()) {
            ListenerScan::Count(1) => Ok(()),
            _ => Err(changed()),
        }
    }

    pub fn identity(&self) -> &ServerIdentityReceipt {
        &self.identity
    }
}

/// Swift `scan`: every process running the verified executable is examined;
/// exactly one must own exactly one registered listener on the endpoint.
fn scan(tool: &VerifiedTool, endpoint: SocketAddrV4) -> io::Result<ServerIdentityReceipt> {
    let processes = all_process_ids().ok_or_else(|| denied("macOS process scan failed"))?;
    let mut matches = Vec::new();
    for pid in processes {
        let Some(path) = executable_path(pid) else {
            continue;
        };
        if path != tool.path {
            continue;
        }
        let count = match registered_listener_count(pid, endpoint.port()) {
            ListenerScan::Count(count) => count,
            // Listed a moment ago, gone before its sockets could be read: it
            // owns nothing now, so it is no candidate rather than a failed
            // scan. A server restarting under the scan is caught by the two
            // scans having to agree, not by this process.
            ListenerScan::Vanished => continue,
            ListenerScan::UnregisteredAddress => {
                return Err(denied(
                    "selected HDC process owns an unregistered listener address",
                ));
            }
            ListenerScan::Failed => {
                return Err(denied(
                    "macOS socket scan failed for the selected HDC process",
                ));
            }
        };
        if count > 1 {
            return Err(denied(
                "multiple registered listeners belong to the selected HDC process",
            ));
        }
        if count == 0 {
            continue;
        }
        let Some(birth) = process_birth(pid) else {
            continue;
        };
        if birth.uid != effective_uid() {
            return Err(denied("existing HDC server is owned by another user"));
        }
        matches.push(ServerIdentityReceipt {
            pid,
            start_seconds: birth.start_seconds,
            start_microseconds: birth.start_microseconds,
            executable_path: path,
            executable_sha256: tool.sha256().to_string(),
            endpoint,
        });
    }
    match matches.len() {
        0 => Err(io::Error::new(
            io::ErrorKind::NotFound,
            "no existing selected HDC process owns the exact endpoint",
        )),
        1 => Ok(matches.remove(0)),
        _ => Err(denied("multiple selected HDC processes own the endpoint")),
    }
}

enum ListenerScan {
    Count(usize),
    UnregisteredAddress,
    /// The process exited between being listed and being scanned.
    Vanished,
    /// The kernel would not say (another user's process, or a scan error):
    /// the process may own the endpoint, so nothing can be proved.
    Failed,
}

/// Swift `registeredListeningEndpointCount`: the process's TCP listeners on
/// the port, each of which must be the registered loopback spelling.
fn registered_listener_count(pid: i32, port: u16) -> ListenerScan {
    let listeners = match listening_sockets(pid) {
        Ok(listeners) => listeners,
        Err(ScanFailure::Vanished) => return ListenerScan::Vanished,
        Err(ScanFailure::Unscannable) => return ListenerScan::Failed,
    };
    let mut count = 0;
    for listener in listeners.iter().filter(|listener| listener.port == port) {
        let bytes: &[u8] = match listener.family {
            libc::AF_INET => &listener.address[..4],
            libc::AF_INET6 => &listener.address[..16],
            _ => return ListenerScan::UnregisteredAddress,
        };
        if is_registered_listener_address(listener.family, bytes) {
            count += 1;
        } else {
            return ListenerScan::UnregisteredAddress;
        }
    }
    ListenerScan::Count(count)
}

/// Swift `isRegisteredListenerAddress`: exactly the IPv4 loopback, or its
/// IPv4-mapped IPv6 form; wildcards and port-only matches never count.
pub(crate) fn is_registered_listener_address(family: i32, address: &[u8]) -> bool {
    if family == libc::AF_INET {
        return address == [127, 0, 0, 1];
    }
    if family != libc::AF_INET6 || address.len() != 16 {
        return false;
    }
    address[..10].iter().all(|byte| *byte == 0)
        && address[10] == 0xFF
        && address[11] == 0xFF
        && address[12..] == [127, 0, 0, 1]
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
struct RawListener {
    family: i32,
    port: u16,
    address: [u8; 16],
}

// Compiled from src/macos_procscan.c by build.rs.
unsafe extern "C" {
    fn arkdeck_macos_listening_sockets(
        pid: libc::pid_t,
        out: *mut RawListener,
        capacity: libc::c_int,
    ) -> libc::c_int;
}

const MAX_LISTENERS: usize = 64;
/// The helper's report of a process that no longer exists.
const VANISHED: libc::c_int = -3;

#[derive(Debug, PartialEq, Eq)]
enum ScanFailure {
    Vanished,
    Unscannable,
}

fn listening_sockets(pid: i32) -> Result<Vec<RawListener>, ScanFailure> {
    let mut listeners = [RawListener {
        family: 0,
        port: 0,
        address: [0; 16],
    }; MAX_LISTENERS];
    // SAFETY: the array supplies exactly `MAX_LISTENERS` writable entries and
    // the callee fills at most that many; a fuller process is reported as -2.
    let found = unsafe {
        arkdeck_macos_listening_sockets(pid, listeners.as_mut_ptr(), MAX_LISTENERS as libc::c_int)
    };
    if found == VANISHED {
        return Err(ScanFailure::Vanished);
    }
    usize::try_from(found)
        .map(|count| listeners[..count].to_vec())
        .map_err(|_| ScanFailure::Unscannable)
}

fn all_process_ids() -> Option<Vec<i32>> {
    // SAFETY: a null buffer with zero size only asks for the current count.
    let estimated = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    let capacity = usize::try_from(estimated).unwrap_or(0).max(64) + 64;
    let mut values = vec![0 as libc::pid_t; capacity];
    let bytes = std::mem::size_of_val(values.as_slice());
    // SAFETY: the buffer holds `capacity` PIDs and the declared byte length
    // matches it; the call returns how many PIDs it wrote.
    let count = unsafe {
        libc::proc_listallpids(
            values.as_mut_ptr().cast(),
            libc::c_int::try_from(bytes).ok()?,
        )
    };
    let count = usize::try_from(count).ok().filter(|count| *count > 0)?;
    Some(
        values
            .into_iter()
            .take(count.min(capacity))
            .filter(|pid| *pid > 0)
            .collect(),
    )
}

/// Swift `executablePath`: the path libproc reports, with symlinks resolved.
fn executable_path(pid: i32) -> Option<PathBuf> {
    let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: the buffer is writable for its declared length and the callee
    // NUL-terminates a successful result.
    let length = unsafe {
        libc::proc_pidpath(
            pid,
            buffer.as_mut_ptr().cast(),
            u32::try_from(buffer.len()).ok()?,
        )
    };
    if length <= 0 {
        return None;
    }
    let path = CStr::from_bytes_until_nul(&buffer).ok()?;
    let path = Path::new(std::str::from_utf8(path.to_bytes()).ok()?);
    std::fs::canonicalize(path).ok()
}

pub(crate) struct ProcessBirth {
    pub(crate) uid: u32,
    pub(crate) start_seconds: u64,
    pub(crate) start_microseconds: u64,
}

/// Swift `startIdentity`: the birth time the kernel keeps for the PID.
pub(crate) fn process_birth(pid: i32) -> Option<ProcessBirth> {
    // SAFETY: zero is a valid empty proc_bsdinfo representation.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = libc::c_int::try_from(std::mem::size_of::<libc::proc_bsdinfo>()).ok()?;
    // SAFETY: the out pointer is a live proc_bsdinfo of the declared size.
    let returned = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    if returned != size || info.pbi_pid != u32::try_from(pid).ok()? {
        return None;
    }
    Some(ProcessBirth {
        uid: info.pbi_uid,
        start_seconds: info.pbi_start_tvsec,
        start_microseconds: info.pbi_start_tvusec,
    })
}

fn effective_uid() -> u32 {
    // SAFETY: geteuid takes no arguments and has no memory preconditions.
    unsafe { libc::geteuid() }
}

/// Swift `HDCCommandlessServerIdentity.verifiesManagedProcess`: the managed
/// ownership predicate bracketed by the observed birth identity, so that a
/// PID recycled between the status observation and this inspection fails
/// closed. The receipt must carry a representable generation and name a
/// process still born when it says; that process must match the launch as
/// Swift's `SystemHDCManagedServerProcessInspector` checks it — alive,
/// running the receipt's executable, its complete argv after argv[0] equal to
/// the launch's, that argv declaring the endpoint (`-s <endpoint>`), and a TCP
/// listener of its own on the endpoint's port bound to the loopback or a
/// wildcard; then the same birth once more.
pub fn verifies_managed_process(receipt: &ServerIdentityReceipt, arguments: &[String]) -> bool {
    let same_birth = || {
        receipt.pid > 0
            && process_birth(receipt.pid).is_some_and(|birth| {
                (birth.start_seconds, birth.start_microseconds)
                    == (receipt.start_seconds, receipt.start_microseconds)
            })
    };
    let generation = receipt
        .start_seconds
        .checked_mul(1_000_000)
        .and_then(|seconds| seconds.checked_add(receipt.start_microseconds));
    if !generation.is_some_and(|generation| generation > 0 && generation <= i64::MAX as u64) {
        return false;
    }
    if !same_birth() {
        return false;
    }
    managed_process_matches(receipt, arguments) && same_birth()
}

/// Swift `SystemHDCManagedServerProcessInspector.matches`.
fn managed_process_matches(receipt: &ServerIdentityReceipt, arguments: &[String]) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let pid = receipt.pid;
    if pid <= 0 || !receipt.executable_path.is_absolute() {
        return false;
    }
    // Swift `FileManager.isExecutableFile`: access(2) for execution.
    let Ok(path) = std::ffi::CString::new(receipt.executable_path.as_os_str().as_bytes()) else {
        return false;
    };
    // SAFETY: the C string is NUL-terminated and outlives the call.
    if unsafe { libc::access(path.as_ptr(), libc::X_OK) } != 0 {
        return false;
    }
    // SAFETY: signal 0 delivers nothing; it asks whether the PID exists.
    if unsafe { libc::kill(pid, 0) } != 0 {
        return false;
    }
    let Some(running) = executable_path(pid) else {
        return false;
    };
    let Ok(tool) = std::fs::canonicalize(&receipt.executable_path) else {
        return false;
    };
    if running != tool {
        return false;
    }
    if process_arguments(pid).as_deref() != Some(arguments) {
        return false;
    }
    let endpoint = receipt.endpoint.to_string();
    let declares = arguments
        .iter()
        .position(|argument| argument == "-s")
        .and_then(|option| arguments.get(option + 1))
        .is_some_and(|argument| *argument == endpoint);
    declares && owns_local_listener(pid, receipt.endpoint)
}

/// Swift `ownsListeningEndpoint`: the endpoint must be the IPv4 loopback with
/// a port, and the process must own a TCP listener on that port whose local
/// address is the loopback or a wildcard bind that serves it (real `hdc`
/// listens dual-stack; the kernel labels that listener by its IPv4 address).
fn owns_local_listener(pid: i32, endpoint: SocketAddrV4) -> bool {
    if *endpoint.ip() != Ipv4Addr::LOCALHOST || endpoint.port() == 0 {
        return false;
    }
    let Ok(listeners) = listening_sockets(pid) else {
        return false;
    };
    listeners.iter().any(|listener| {
        listener.port == endpoint.port()
            && is_loopback_or_wildcard(listener.family, &listener.address)
    })
}

/// Swift `HDCListenerAddressFacts.isLoopbackOrWildcard`: exactly the IPv4
/// loopback or its mapped IPv6 form, or the IPv4 or IPv6 wildcard.
fn is_loopback_or_wildcard(family: i32, address: &[u8; 16]) -> bool {
    if family == libc::AF_INET {
        return address[..4] == [0, 0, 0, 0] || address[..4] == [127, 0, 0, 1];
    }
    family == libc::AF_INET6
        && (address.iter().all(|byte| *byte == 0)
            || is_registered_listener_address(family, &address[..]))
}

/// The kernel's complete launch record of a process (`KERN_PROCARGS2`): the
/// argument count, the executable path, the NUL-separated arguments and then
/// the environment, byte for byte. `None` when the kernel refuses (another
/// user's process, a process that has exited). A privacy check scans these
/// bytes for a secret that must never have reached a child's argv or
/// environment.
pub fn process_argument_record(pid: i32) -> Option<Vec<u8>> {
    // <sys/sysctl.h>
    const KERN_ARGMAX: libc::c_int = 8;
    const KERN_PROCARGS2: libc::c_int = 49;
    let mut maximum: libc::c_int = 0;
    let mut maximum_size = std::mem::size_of::<libc::c_int>();
    let mut name = [libc::CTL_KERN, KERN_ARGMAX];
    // SAFETY: the name is a live two-entry MIB and the out pointer a live
    // c_int of the declared size; nothing is written to the kernel.
    let status = unsafe {
        libc::sysctl(
            name.as_mut_ptr(),
            2,
            (&mut maximum as *mut libc::c_int).cast(),
            &mut maximum_size,
            std::ptr::null_mut(),
            0,
        )
    };
    let maximum = usize::try_from(maximum).ok()?;
    if status != 0 || maximum <= std::mem::size_of::<i32>() {
        return None;
    }
    let mut buffer = vec![0u8; maximum];
    let mut actual = buffer.len();
    let mut name = [libc::CTL_KERN, KERN_PROCARGS2, pid];
    // SAFETY: the name is a live three-entry MIB, the buffer is writable for
    // its declared length and the kernel reports how much it wrote.
    let status = unsafe {
        libc::sysctl(
            name.as_mut_ptr(),
            3,
            buffer.as_mut_ptr().cast(),
            &mut actual,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 || actual <= std::mem::size_of::<i32>() || actual > buffer.len() {
        return None;
    }
    buffer.truncate(actual);
    Some(buffer)
}

/// Swift `arguments(for:)`: the complete argv of a process after argv[0], as
/// the kernel keeps it (`KERN_PROCARGS2`: the argument count, the executable
/// path, then the NUL-separated arguments). `None` when the kernel refuses
/// or the record is not shaped so.
pub fn process_arguments(pid: i32) -> Option<Vec<String>> {
    let buffer = process_argument_record(pid)?;
    let actual = buffer.len();
    let count = i32::from_ne_bytes(buffer[..4].try_into().ok()?);
    let count = usize::try_from(count).ok().filter(|count| *count > 0)?;
    let mut cursor = std::mem::size_of::<i32>();
    // The executable path, then its padding.
    while cursor < actual && buffer[cursor] != 0 {
        cursor += 1;
    }
    while cursor < actual && buffer[cursor] == 0 {
        cursor += 1;
    }
    let mut values = Vec::with_capacity(count);
    for _ in 0..count {
        while cursor < actual && buffer[cursor] == 0 {
            cursor += 1;
        }
        if cursor >= actual {
            return None;
        }
        let start = cursor;
        while cursor < actual && buffer[cursor] != 0 {
            cursor += 1;
        }
        if cursor >= actual {
            return None;
        }
        values.push(String::from_utf8_lossy(&buffer[start..cursor]).into_owned());
    }
    if values.is_empty() {
        return None;
    }
    values.remove(0);
    Some(values)
}

#[cfg(test)]
mod tests {
    use super::{
        ScanFailure, ServerIdentityReceipt, is_loopback_or_wildcard,
        is_registered_listener_address, listening_sockets, owns_local_listener, process_arguments,
        process_birth, verifies_managed_process,
    };
    use std::net::{Ipv4Addr, SocketAddrV4, TcpListener};

    /// The kernel's argv of this very process is the one it was started
    /// with, after argv[0]; a process that does not exist has none.
    #[test]
    fn process_arguments_are_this_process_s_own_and_absent_for_no_process() {
        let pid = i32::try_from(std::process::id()).unwrap();
        let expected: Vec<String> = std::env::args().skip(1).collect();
        assert_eq!(process_arguments(pid), Some(expected));
        assert_eq!(process_arguments(99_999_999), None);
    }

    /// A listener this process binds on the loopback or the wildcard is owned
    /// on its port; another port, another host or a dead process is not.
    #[test]
    fn a_loopback_or_wildcard_listener_of_this_process_is_owned_on_its_port() {
        let pid = i32::try_from(std::process::id()).unwrap();
        let loopback = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = loopback.local_addr().unwrap().port();
        assert!(owns_local_listener(
            pid,
            SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)
        ));
        let wildcard = TcpListener::bind("0.0.0.0:0").unwrap();
        let wildcard_port = wildcard.local_addr().unwrap().port();
        assert!(owns_local_listener(
            pid,
            SocketAddrV4::new(Ipv4Addr::LOCALHOST, wildcard_port)
        ));
        assert!(!owns_local_listener(
            pid,
            SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0)
        ));
        assert!(!owns_local_listener(
            pid,
            SocketAddrV4::new(Ipv4Addr::new(10, 0, 0, 1), port)
        ));
        assert!(!owns_local_listener(
            99_999_999,
            SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)
        ));
        drop(loopback);
        assert!(!owns_local_listener(
            pid,
            SocketAddrV4::new(Ipv4Addr::LOCALHOST, port)
        ));
        let mut mapped = [0u8; 16];
        mapped[10] = 0xFF;
        mapped[11] = 0xFF;
        mapped[12..].copy_from_slice(&[127, 0, 0, 1]);
        assert!(is_loopback_or_wildcard(libc::AF_INET6, &mapped));
        assert!(is_loopback_or_wildcard(libc::AF_INET6, &[0; 16]));
        let mut other = [0u8; 16];
        other[15] = 1;
        assert!(!is_loopback_or_wildcard(libc::AF_INET6, &other));
        assert!(!is_loopback_or_wildcard(0, &[0; 16]));
    }

    /// This process, with its real birth and argv, is no managed HDC server:
    /// its argv declares no endpoint and it owns no listener there. A dead
    /// PID, a wrong birth and a wrong argv fail before anything else.
    #[test]
    fn a_process_that_is_not_the_launched_server_is_never_managed() {
        let pid = i32::try_from(std::process::id()).unwrap();
        let birth = process_birth(pid).unwrap();
        let arguments: Vec<String> = std::env::args().skip(1).collect();
        let receipt = ServerIdentityReceipt {
            pid,
            start_seconds: birth.start_seconds,
            start_microseconds: birth.start_microseconds,
            executable_path: std::env::current_exe().unwrap(),
            executable_sha256: "0".repeat(64),
            endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710),
        };
        assert!(!verifies_managed_process(&receipt, &arguments));
        let mut wrong_arguments = arguments.clone();
        wrong_arguments.push("-m".into());
        assert!(!verifies_managed_process(&receipt, &wrong_arguments));
        let reborn = ServerIdentityReceipt {
            start_seconds: birth.start_seconds + 1,
            ..receipt.clone()
        };
        assert!(!verifies_managed_process(&reborn, &arguments));
        let dead = ServerIdentityReceipt {
            pid: 99_999_999,
            ..receipt.clone()
        };
        assert!(!verifies_managed_process(&dead, &arguments));
        let unborn = ServerIdentityReceipt {
            start_seconds: 0,
            start_microseconds: 0,
            ..receipt
        };
        assert!(!verifies_managed_process(&unborn, &arguments));
    }

    /// A PID the kernel has no process for is a vanished candidate, never a
    /// failed scan; a process this user may not inspect stays unscannable.
    #[test]
    fn a_missing_process_is_vanished_and_an_uninspectable_one_is_unscannable() {
        assert_eq!(
            listening_sockets(99_999_999).unwrap_err(),
            ScanFailure::Vanished
        );
        // SAFETY: geteuid takes no arguments and has no memory preconditions.
        if unsafe { libc::geteuid() } != 0 {
            assert_eq!(listening_sockets(1).unwrap_err(), ScanFailure::Unscannable);
        }
    }

    /// Swift `testHSO6_ListenerNormalizationRejectsWildcardPortOnlyAndUnregisteredAddresses`.
    #[test]
    fn listener_normalization_rejects_wildcard_port_only_and_unregistered_addresses() {
        assert!(is_registered_listener_address(
            libc::AF_INET,
            &[127, 0, 0, 1]
        ));
        let mut mapped = [0u8; 16];
        mapped[10] = 0xFF;
        mapped[11] = 0xFF;
        mapped[12..].copy_from_slice(&[127, 0, 0, 1]);
        assert!(is_registered_listener_address(libc::AF_INET6, &mapped));
        assert!(!is_registered_listener_address(
            libc::AF_INET,
            &[0, 0, 0, 0]
        ));
        assert!(!is_registered_listener_address(libc::AF_INET6, &[0; 16]));
        assert!(!is_registered_listener_address(
            libc::AF_INET,
            &[127, 0, 0, 2]
        ));
        let mut loopback6 = [0u8; 16];
        loopback6[15] = 1;
        assert!(!is_registered_listener_address(libc::AF_INET6, &loopback6));
        assert!(!is_registered_listener_address(
            libc::AF_UNIX,
            &[127, 0, 0, 1]
        ));
        assert!(!is_registered_listener_address(
            libc::AF_INET6,
            &[127, 0, 0, 1]
        ));
        assert!(!is_registered_listener_address(0, &[127, 0, 0, 1]));
    }
}
