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

#[cfg(test)]
mod tests {
    use super::{ScanFailure, is_registered_listener_address, listening_sockets};

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
