//! The commandless proof that an HDC server exists on Windows, the port of the
//! macOS proof (`macos_server.rs`, Swift `HDCExact320FSystemIdentityObserver`)
//! for TASK-XPA-005. It never connects to the endpoint and never launches a
//! client. It reads what the kernel says: the TCP listener table
//! (`GetExtendedTcpTable`, IPv4 and IPv6, with owning PIDs), each owner's
//! image (`QueryFullProcessImageNameW`, then the image file's `FileIdInfo`),
//! and its creation time (`GetProcessTimes`). Exactly one process running
//! the verified file must own exactly one listener on the endpoint, bound to
//! the registered loopback spelling; two scans must agree; the lease then
//! holds that process's handle, so its PID cannot name another process while
//! the lease lives.
//!
//! Windows has no supported read of another process's argv, so nothing here
//! reads one: the image file (the verified tool's own file identity, whose
//! bytes the tool's SHA-256 pin covers), the creation time and the exact
//! listener owned by that PID are the proof. A server this daemon launched is
//! further proved by its own Job object (`ManagedServer::verifies`).
use super::Handle;
use super::identity::{ProcessIdentity, file_identity, process_image, process_started};
use crate::{ServerIdentityReceipt, VerifiedTool, denied, invalid};
use std::io;
use std::mem::{offset_of, size_of};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddrV4};
use std::ptr::null_mut;
use windows_sys::Win32::Foundation::{
    ERROR_INSUFFICIENT_BUFFER, ERROR_INVALID_PARAMETER, ERROR_SUCCESS, WAIT_OBJECT_0,
};
use windows_sys::Win32::NetworkManagement::IpHelper::*;
use windows_sys::Win32::Networking::WinSock::{AF_INET, AF_INET6};
use windows_sys::Win32::System::Threading::{
    OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, WaitForSingleObject,
};

/// Holds a kernel-proven, already-running HDC process through an observation.
/// Acquiring/revalidating this lease performs no network connect and no process
/// execution, and never starts, stops or adopts an external HDC server.
pub struct LoopbackServerLease {
    identity: ServerIdentityReceipt,
    process: ProcessIdentity,
}

impl std::fmt::Debug for LoopbackServerLease {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LoopbackServerLease")
            .field("identity", &self.identity)
            .finish_non_exhaustive()
    }
}

impl LoopbackServerLease {
    /// Swift `observe`: the endpoint must be the exact IPv4 loopback, the tool
    /// must still verify, and two consecutive scans must name the same
    /// process.
    ///
    /// `NotFound` is Swift's `unavailable` (no process of the verified tool
    /// owns a listener on the endpoint); `PermissionDenied` is its `unknown`
    /// (ambiguous, changed, unregistered, another user's, or an owner that
    /// cannot be inspected).
    pub fn acquire(tool: &VerifiedTool, endpoint: SocketAddrV4) -> io::Result<Self> {
        if *endpoint.ip() != Ipv4Addr::LOCALHOST || endpoint.port() == 0 {
            return Err(invalid(
                "HDC observation requires the exact IPv4 loopback endpoint",
            ));
        }
        tool.revalidate()?;
        let (first, _) = scan(tool, endpoint)?;
        tool.revalidate()?;
        let (second, process) = scan(tool, endpoint)?;
        if first != second {
            return Err(denied(
                "server process/listener identity changed during observation",
            ));
        }
        let lease = Self {
            identity: second,
            process,
        };
        lease.revalidate()?;
        Ok(lease)
    }

    /// The process is still the one observed at acquisition (its retained
    /// handle, same creation time) and still owns exactly one registered
    /// listener on the endpoint.
    pub fn revalidate(&self) -> io::Result<()> {
        let changed = || denied("HDC server listener identity changed during observation");
        self.process.require_live().map_err(|_| changed())?;
        let rows = listeners(self.identity.endpoint.port())?;
        match registered_listener_count(&rows, self.process.pid) {
            Some(1) => Ok(()),
            _ => Err(changed()),
        }
    }

    pub fn identity(&self) -> &ServerIdentityReceipt {
        &self.identity
    }
}

/// Swift `scan` over the listener table: every process owning a listener on
/// the endpoint's port is examined; those running the verified file are the
/// candidates, and exactly one must own exactly one registered listener.
fn scan(
    tool: &VerifiedTool,
    endpoint: SocketAddrV4,
) -> io::Result<(ServerIdentityReceipt, ProcessIdentity)> {
    let rows = listeners(endpoint.port())?;
    let mut owners: Vec<u32> = rows.iter().map(|row| row.pid).collect();
    owners.sort_unstable();
    owners.dedup();
    let mut matches = Vec::new();
    for pid in owners {
        let Some(process) = candidate(tool, pid)? else {
            continue;
        };
        match registered_listener_count(&rows, pid) {
            Some(1) => {}
            Some(_) => {
                return Err(denied(
                    "multiple registered listeners belong to the selected HDC process",
                ));
            }
            None => {
                return Err(denied(
                    "selected HDC process owns an unregistered listener address",
                ));
            }
        }
        process
            .require_client_user()
            .map_err(|_| denied("existing HDC server is owned by another user"))?;
        let (start_seconds, start_microseconds) = unix_birth(process.started)?;
        matches.push((
            ServerIdentityReceipt {
                pid: i32::try_from(pid).map_err(|_| denied("HDC server PID is out of range"))?,
                start_seconds,
                start_microseconds,
                executable_path: process.path.clone(),
                executable_sha256: tool.sha256().to_string(),
                endpoint,
            },
            process,
        ));
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

/// The owner of a listener, held, when it runs the verified file; `None`
/// when it runs another image or has already exited. An owner that cannot be
/// inspected might be the server, so it fails the scan rather than being
/// passed over.
fn candidate(tool: &VerifiedTool, pid: u32) -> io::Result<Option<ProcessIdentity>> {
    let uninspectable =
        || denied("the owner of a listener on the HDC endpoint cannot be inspected");
    if pid == 0 {
        return Err(uninspectable());
    }
    let process = match open_process(pid) {
        Ok(process) => process,
        Err(error) if error.raw_os_error() == Some(ERROR_INVALID_PARAMETER as i32) => {
            return Ok(None);
        }
        Err(_) => return Err(uninspectable()),
    };
    let exited = |process: &Handle| {
        // SAFETY: retained process handle with SYNCHRONIZE access.
        unsafe { WaitForSingleObject(process.raw(), 0) == WAIT_OBJECT_0 }
    };
    let image = match process_image(process.raw()) {
        Ok(image) => image,
        Err(_) if exited(&process) => return Ok(None),
        Err(_) => return Err(uninspectable()),
    };
    // An image path that no longer resolves names no file at the verified
    // path, so its process is not a process of the verified tool.
    let Ok(image) = image.canonicalize() else {
        return Ok(None);
    };
    if image != tool.path {
        return Ok(None);
    }
    let gone = exited(&process);
    let identity = match ProcessIdentity::from_handle(process, pid) {
        Ok(identity) => identity,
        Err(_) if gone => return Ok(None),
        Err(error) => return Err(error),
    };
    if file_identity(&identity.image)? != tool.identity {
        return Err(denied(
            "the process at the verified HDC path runs another file than the verified tool",
        ));
    }
    Ok(Some(identity))
}

pub(crate) fn open_process(pid: u32) -> io::Result<Handle> {
    // SAFETY: query-only process access; the owned handle is retained.
    Handle::new(unsafe {
        OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
            0,
            pid,
        )
    })
}

/// The creation time the kernel keeps for the PID now; `None` when no
/// process has it (or it cannot be opened).
pub(crate) fn process_started_by_pid(pid: u32) -> Option<u64> {
    let process = open_process(pid).ok()?;
    process_started(process.raw()).ok()
}

/// 100 ns intervals between 1601-01-01 (`FILETIME`) and 1970-01-01.
const UNIX_EPOCH_FILETIME: u64 = 116_444_736_000_000_000;

/// A `GetProcessTimes` creation time as the receipt's birth: seconds and
/// microseconds since the Unix epoch (the sub-microsecond rest is dropped).
pub(crate) fn unix_birth(started: u64) -> io::Result<(u64, u64)> {
    let since = started
        .checked_sub(UNIX_EPOCH_FILETIME)
        .filter(|since| *since > 0)
        .ok_or_else(|| denied("process creation time precedes the Unix epoch"))?;
    Ok((since / 10_000_000, (since % 10_000_000) / 10))
}

/// One TCP listener as the kernel's table reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Listener {
    pub(crate) pid: u32,
    pub(crate) address: IpAddr,
}

/// Swift `isRegisteredListenerAddress`: exactly the IPv4 loopback, or its
/// IPv4-mapped IPv6 form; wildcards and other addresses never count.
pub(crate) fn is_registered_listener_address(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(address) => address == Ipv4Addr::LOCALHOST,
        IpAddr::V6(address) => address == Ipv4Addr::LOCALHOST.to_ipv6_mapped(),
    }
}

/// Swift `HDCListenerAddressFacts.isLoopbackOrWildcard`: the registered
/// spelling, or the IPv4 or IPv6 wildcard.
pub(crate) fn is_loopback_or_wildcard(address: IpAddr) -> bool {
    is_registered_listener_address(address)
        || address == IpAddr::V4(Ipv4Addr::UNSPECIFIED)
        || address == IpAddr::V6(Ipv6Addr::UNSPECIFIED)
}

/// Swift `registeredListeningEndpointCount`: how many of the process's
/// listeners on the port are registered; `None` once one is not.
fn registered_listener_count(rows: &[Listener], pid: u32) -> Option<usize> {
    let mut count = 0;
    for row in rows.iter().filter(|row| row.pid == pid) {
        if !is_registered_listener_address(row.address) {
            return None;
        }
        count += 1;
    }
    Some(count)
}

/// Swift `ownsListeningEndpoint`: the process owns a listener on the
/// endpoint's port bound to the loopback or a wildcard.
pub(crate) fn owns_local_listener(pid: u32, endpoint: SocketAddrV4) -> io::Result<bool> {
    if *endpoint.ip() != Ipv4Addr::LOCALHOST || endpoint.port() == 0 {
        return Ok(false);
    }
    Ok(listeners(endpoint.port())?
        .iter()
        .any(|row| row.pid == pid && is_loopback_or_wildcard(row.address)))
}

/// Every TCP listener on `port`, IPv4 and IPv6, with its owning PID.
pub(crate) fn listeners(port: u16) -> io::Result<Vec<Listener>> {
    let mut found = Vec::new();
    let (storage, length) = listener_table(AF_INET)?;
    for row in table_rows::<MIB_TCPROW_OWNER_PID>(
        &storage,
        length,
        offset_of!(MIB_TCPTABLE_OWNER_PID, table),
    )? {
        if u16::from_be(row.dwLocalPort as u16) != port {
            continue;
        }
        if row.dwState != MIB_TCP_STATE_LISTEN as u32 {
            return Err(denied("listener table row is not a listener"));
        }
        found.push(Listener {
            pid: row.dwOwningPid,
            address: IpAddr::V4(Ipv4Addr::from(row.dwLocalAddr.to_ne_bytes())),
        });
    }
    let (storage, length) = listener_table(AF_INET6)?;
    for row in table_rows::<MIB_TCP6ROW_OWNER_PID>(
        &storage,
        length,
        offset_of!(MIB_TCP6TABLE_OWNER_PID, table),
    )? {
        if u16::from_be(row.dwLocalPort as u16) != port {
            continue;
        }
        if row.dwState != MIB_TCP_STATE_LISTEN as u32 {
            return Err(denied("listener table row is not a listener"));
        }
        found.push(Listener {
            pid: row.dwOwningPid,
            address: IpAddr::V6(Ipv6Addr::from(row.ucLocalAddr)),
        });
    }
    Ok(found)
}

/// The kernel's listener table of one address family, as DWORD-aligned
/// storage and the byte length the kernel wrote.
fn listener_table(family: u16) -> io::Result<(Vec<u32>, usize)> {
    // Table contents may grow between size query and read. Retry only the
    // commandless size/read operation; never retry an HDC observation here.
    for _ in 0..3 {
        let mut length = 0;
        // SAFETY: documented size query, no output allocation.
        let query = unsafe {
            GetExtendedTcpTable(
                null_mut(),
                &mut length,
                0,
                u32::from(family),
                TCP_TABLE_OWNER_PID_LISTENER,
                0,
            )
        };
        if query != ERROR_INSUFFICIENT_BUFFER || length == 0 || length > 16 * 1024 * 1024 {
            return Err(denied("TCP listener table identity unavailable"));
        }
        let capacity = length;
        let mut storage = vec![0u32; (capacity as usize).div_ceil(size_of::<u32>())];
        // SAFETY: DWORD-aligned storage covers the queried byte length.
        let status = unsafe {
            GetExtendedTcpTable(
                storage.as_mut_ptr().cast(),
                &mut length,
                0,
                u32::from(family),
                TCP_TABLE_OWNER_PID_LISTENER,
                0,
            )
        };
        if status == ERROR_INSUFFICIENT_BUFFER {
            continue;
        }
        if status != ERROR_SUCCESS {
            return Err(io::Error::from_raw_os_error(status as i32));
        }
        if length > capacity {
            return Err(denied("listener table exceeds allocated buffer"));
        }
        return Ok((storage, length as usize));
    }
    Err(denied("TCP listener table did not stabilize"))
}

/// The rows of a listener table whose header (a DWORD count) is followed by
/// rows at `offset`; only rows inside the returned length are ever read.
fn table_rows<T>(storage: &[u32], length: usize, offset: usize) -> io::Result<&[T]> {
    const {
        assert!(std::mem::align_of::<T>() <= std::mem::align_of::<u32>());
    }
    if length < size_of::<u32>() || length > std::mem::size_of_val(storage) {
        return Err(denied("truncated listener table header"));
    }
    let count = storage[0] as usize;
    if count == 0 {
        return Ok(&[]);
    }
    if length < offset || count > (length - offset) / size_of::<T>() {
        return Err(denied("invalid listener table length"));
    }
    // SAFETY: DWORD alignment (asserted above for T) and the documented
    // offset align every row. The header and count were checked before
    // constructing any reference or slice.
    Ok(unsafe {
        std::slice::from_raw_parts(storage.as_ptr().cast::<u8>().add(offset).cast(), count)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rows<T>(storage: &[u32], length: usize) -> io::Result<&[T]> {
        table_rows::<T>(storage, length, offset_of!(MIB_TCPTABLE_OWNER_PID, table))
    }

    #[test]
    fn empty_listener_table_needs_only_the_count_header() {
        assert!(rows::<MIB_TCPROW_OWNER_PID>(&[0], 4).unwrap().is_empty());
        assert!(rows::<MIB_TCPROW_OWNER_PID>(&[], 0).is_err());
        assert!(rows::<MIB_TCPROW_OWNER_PID>(&[0], 3).is_err());
        assert!(rows::<MIB_TCPROW_OWNER_PID>(&[0], 8).is_err());
    }

    #[test]
    fn listener_count_cannot_use_padding_or_unreturned_rows() {
        let row_bytes = size_of::<MIB_TCPROW_OWNER_PID>();
        let length = offset_of!(MIB_TCPTABLE_OWNER_PID, table) + row_bytes;
        let mut words = vec![0; length / size_of::<u32>()];
        words[0] = 1;
        assert_eq!(
            rows::<MIB_TCPROW_OWNER_PID>(&words, length).unwrap().len(),
            1
        );
        assert!(rows::<MIB_TCPROW_OWNER_PID>(&words, length - 1).is_err());
        words[0] = u32::MAX;
        assert!(rows::<MIB_TCPROW_OWNER_PID>(&words, length).is_err());
    }

    #[test]
    fn ipv6_rows_are_bounded_by_their_own_size() {
        let offset = offset_of!(MIB_TCP6TABLE_OWNER_PID, table);
        let length = offset + size_of::<MIB_TCP6ROW_OWNER_PID>();
        let mut words = vec![0; length / size_of::<u32>()];
        words[0] = 1;
        assert_eq!(
            table_rows::<MIB_TCP6ROW_OWNER_PID>(&words, length, offset)
                .unwrap()
                .len(),
            1
        );
        words[0] = 2;
        assert!(table_rows::<MIB_TCP6ROW_OWNER_PID>(&words, length, offset).is_err());
    }

    /// Swift `testHSO6_ListenerNormalizationRejectsWildcardPortOnlyAndUnregisteredAddresses`.
    #[test]
    fn listener_normalization_rejects_wildcard_and_unregistered_addresses() {
        let mapped = IpAddr::V6(Ipv4Addr::LOCALHOST.to_ipv6_mapped());
        assert!(is_registered_listener_address(IpAddr::V4(
            Ipv4Addr::LOCALHOST
        )));
        assert!(is_registered_listener_address(mapped));
        for unregistered in [
            IpAddr::V4(Ipv4Addr::UNSPECIFIED),
            IpAddr::V4(Ipv4Addr::new(127, 0, 0, 2)),
            IpAddr::V6(Ipv6Addr::UNSPECIFIED),
            IpAddr::V6(Ipv6Addr::LOCALHOST),
        ] {
            assert!(
                !is_registered_listener_address(unregistered),
                "{unregistered}"
            );
        }
        assert!(is_loopback_or_wildcard(IpAddr::V4(Ipv4Addr::UNSPECIFIED)));
        assert!(is_loopback_or_wildcard(IpAddr::V6(Ipv6Addr::UNSPECIFIED)));
        assert!(is_loopback_or_wildcard(mapped));
        assert!(!is_loopback_or_wildcard(IpAddr::V6(Ipv6Addr::LOCALHOST)));
        assert!(!is_loopback_or_wildcard(IpAddr::V4(Ipv4Addr::new(
            10, 0, 0, 1
        ))));
    }

    #[test]
    fn a_process_with_two_or_an_unregistered_listener_is_never_counted_as_one() {
        let loopback = IpAddr::V4(Ipv4Addr::LOCALHOST);
        let mapped = IpAddr::V6(Ipv4Addr::LOCALHOST.to_ipv6_mapped());
        let row = |pid, address| Listener { pid, address };
        assert_eq!(registered_listener_count(&[row(7, loopback)], 7), Some(1));
        assert_eq!(registered_listener_count(&[row(8, loopback)], 7), Some(0));
        assert_eq!(
            registered_listener_count(&[row(7, loopback), row(7, mapped)], 7),
            Some(2)
        );
        assert_eq!(
            registered_listener_count(
                &[row(7, loopback), row(7, IpAddr::V4(Ipv4Addr::UNSPECIFIED))],
                7
            ),
            None
        );
    }

    #[test]
    fn a_birth_is_unix_seconds_and_microseconds() {
        // 2026-09-30T00:00:00.1234567Z as a FILETIME.
        let seconds = 1_790_726_400u64;
        let started = UNIX_EPOCH_FILETIME + seconds * 10_000_000 + 1_234_567;
        assert_eq!(unix_birth(started).unwrap(), (seconds, 123_456));
        assert!(unix_birth(UNIX_EPOCH_FILETIME).is_err());
        assert!(unix_birth(1).is_err());
    }
}
