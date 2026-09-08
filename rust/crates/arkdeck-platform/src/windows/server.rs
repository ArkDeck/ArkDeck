use super::identity::{ProcessIdentity, file_identity};
use crate::{VerifiedTool, denied, invalid};
use std::io;
use std::mem::{offset_of, size_of};
use std::net::{Ipv4Addr, SocketAddrV4};
use std::ptr::null_mut;
use windows_sys::Win32::Foundation::{ERROR_INSUFFICIENT_BUFFER, ERROR_SUCCESS};
use windows_sys::Win32::NetworkManagement::IpHelper::*;
use windows_sys::Win32::Networking::WinSock::AF_INET;

/// Holds a kernel-proven, already-running HDC process through an observation.
/// Acquiring/revalidating this lease performs no network connect and no process
/// execution, and never starts, stops or adopts an external HDC server.
pub struct LoopbackServerLease {
    endpoint: SocketAddrV4,
    process: ProcessIdentity,
}

impl LoopbackServerLease {
    pub fn acquire(tool: &VerifiedTool, endpoint: SocketAddrV4) -> io::Result<Self> {
        if *endpoint.ip() != Ipv4Addr::LOCALHOST || endpoint.port() == 0 {
            return Err(invalid(
                "HDC observation requires the exact IPv4 loopback endpoint",
            ));
        }
        tool.revalidate()?;
        let pid = listener_pid(endpoint)?;
        let process = ProcessIdentity::open(pid)?;
        if process.path.canonicalize()? != tool.path
            || file_identity(&process.image)? != tool.identity
        {
            return Err(denied(
                "existing HDC server executable differs from the verified tool",
            ));
        }
        process.require_client_user()?;
        let lease = Self { endpoint, process };
        lease.revalidate()?;
        Ok(lease)
    }

    pub fn revalidate(&self) -> io::Result<()> {
        self.process.require_live()?;
        if listener_pid(self.endpoint)? != self.process.pid {
            return Err(denied(
                "HDC server listener identity changed during observation",
            ));
        }
        Ok(())
    }
}

fn listener_pid(endpoint: SocketAddrV4) -> io::Result<u32> {
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
                u32::from(AF_INET),
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
                u32::from(AF_INET),
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
        let rows = listener_rows(&storage, length as usize)?;
        let mut selected = None;
        for row in rows {
            let address = Ipv4Addr::from(row.dwLocalAddr.to_ne_bytes());
            let port = u16::from_be(row.dwLocalPort as u16);
            if port == endpoint.port() && (address == *endpoint.ip() || address.is_unspecified()) {
                if address != *endpoint.ip()
                    || row.dwState != MIB_TCP_STATE_LISTEN as u32
                    || row.dwOwningPid == 0
                    || selected.is_some()
                {
                    return Err(denied(
                        "HDC loopback listener is wildcard, unknown or ambiguous",
                    ));
                }
                selected = Some(row.dwOwningPid);
            }
        }
        return selected.ok_or_else(|| {
            denied("no pre-existing HDC server on the exact loopback endpoint; zero HDC spawn")
        });
    }
    Err(denied("TCP listener table did not stabilize"))
}

fn listener_rows(storage: &[u32], length: usize) -> io::Result<&[MIB_TCPROW_OWNER_PID]> {
    if length < size_of::<u32>() || length > std::mem::size_of_val(storage) {
        return Err(denied("truncated listener table header"));
    }
    let count = storage[0] as usize;
    if count == 0 {
        return Ok(&[]);
    }
    let offset = offset_of!(MIB_TCPTABLE_OWNER_PID, table);
    if length < offset || count > (length - offset) / size_of::<MIB_TCPROW_OWNER_PID>() {
        return Err(denied("invalid listener table length"));
    }
    // SAFETY: DWORD alignment and the documented offset align every row. The
    // header and count were checked before constructing any reference or slice.
    Ok(unsafe {
        std::slice::from_raw_parts(storage.as_ptr().cast::<u8>().add(offset).cast(), count)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_listener_table_needs_only_the_count_header() {
        assert!(listener_rows(&[0], 4).unwrap().is_empty());
        assert!(listener_rows(&[], 0).is_err());
        assert!(listener_rows(&[0], 3).is_err());
        assert!(listener_rows(&[0], 8).is_err());
    }

    #[test]
    fn listener_count_cannot_use_padding_or_unreturned_rows() {
        let row_bytes = size_of::<MIB_TCPROW_OWNER_PID>();
        let length = offset_of!(MIB_TCPTABLE_OWNER_PID, table) + row_bytes;
        let mut words = vec![0; length / size_of::<u32>()];
        words[0] = 1;
        assert_eq!(listener_rows(&words, length).unwrap().len(), 1);
        assert!(listener_rows(&words, length - 1).is_err());
        words[0] = u32::MAX;
        assert!(listener_rows(&words, length).is_err());
    }
}
