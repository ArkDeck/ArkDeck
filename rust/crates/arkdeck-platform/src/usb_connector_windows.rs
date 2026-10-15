//! Bounded, read-only Windows hub queries for one existing census attachment.
//! No RockUSB interface, bulk pipe, driver install or device write is exposed.

use crate::usb_connector::{self, Endpoint};
use crate::usb_device_nodes;
use crate::windows::Handle;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock, mpsc};
use std::time::{Duration, Instant};
use windows_sys::Win32::Devices::DeviceAndDriverInstallation::{
    CM_Get_DevNode_PropertyW, CM_Get_Device_ID_Size, CM_Get_Device_IDW,
    CM_Get_Device_Interface_List_SizeW, CM_Get_Device_Interface_ListW, CM_Get_Parent,
    CR_BUFFER_SMALL, CR_SUCCESS,
};
use windows_sys::Win32::Devices::Properties::{DEVPKEY_Device_Address, DEVPROP_TYPE_UINT32};
use windows_sys::Win32::Foundation::{GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows_sys::Win32::System::IO::DeviceIoControl;
use windows_sys::core::GUID;

const WAIT: Duration = Duration::from_secs(5);
const MAX_BYTES: usize = 65_536;
const HUB: GUID = GUID::from_u128(0xf18a0e88_c30c_11d0_8815_00a0c906bed8);
// IOCTL_USB_GET_PORT_CONNECTOR_PROPERTIES: the one supported query.
const CONNECTOR_QUERY: u32 = (0x22 << 16) | (278 << 2);
static RUNNING: OnceLock<Arc<AtomicBool>> = OnceLock::new();

fn invalid(detail: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, detail)
}

struct Budget {
    deadline: Instant,
    cancelled: Arc<AtomicBool>,
}

impl Budget {
    fn check(&self) -> io::Result<()> {
        if self.cancelled.load(Ordering::Acquire) || Instant::now() >= self.deadline {
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "USB connector observation expired",
            ))
        } else {
            Ok(())
        }
    }
}

/// Independently resolve the physical connector of exactly one fresh Runtime
/// census entry. The input is the existing Windows attachment topology, not
/// an ArkForge digest supplied by a caller or by the remote daemon.
pub fn usb_connector_location(topology: &str) -> io::Result<u32> {
    let value = topology
        .parse::<u64>()
        .map_err(|_| invalid("invalid attachment topology"))?;
    if value.to_string() != topology {
        return Err(invalid("attachment topology is not canonical"));
    }
    let topology = topology.to_owned();
    bounded(
        Arc::clone(RUNNING.get_or_init(|| Arc::new(AtomicBool::new(false)))),
        WAIT,
        move |budget| {
            budget.check()?;
            let before = usb_device_nodes::connector_device(&topology)?;
            let endpoint = endpoint(before.1, budget)?;
            let location = usb_connector::location(&endpoint, |endpoint| query(endpoint, budget))?;
            budget.check()?;
            let after = usb_device_nodes::connector_device(&topology)?;
            if before != after || endpoint != self::endpoint(after.1, budget)? {
                return Err(invalid(
                    "USB attachment changed during connector observation",
                ));
            }
            budget.check()?;
            Ok(location)
        },
    )
}

/// A timeout returns to the caller, while an outstanding synchronous OS query
/// retains its own handle, buffer and worker. It prevents another observation
/// and checks cancellation before making any further hub query.
fn bounded<T: Send + 'static>(
    running: Arc<AtomicBool>,
    wait: Duration,
    observe: impl FnOnce(&Budget) -> io::Result<T> + Send + 'static,
) -> io::Result<T> {
    if running
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            "USB connector observation is still outstanding",
        ));
    }
    let cancelled = Arc::new(AtomicBool::new(false));
    let worker_running = Arc::clone(&running);
    let budget = Budget {
        deadline: Instant::now() + wait,
        cancelled: Arc::clone(&cancelled),
    };
    let (sender, receiver) = mpsc::sync_channel(1);
    let worker = std::thread::Builder::new()
        .name("arkdeck-usb-connector".into())
        .spawn(move || {
            struct Guard(Arc<AtomicBool>);
            impl Drop for Guard {
                fn drop(&mut self) {
                    self.0.store(false, Ordering::Release);
                }
            }
            let guard = Guard(worker_running);
            let answer = observe(&budget).and_then(|value| {
                budget.check()?;
                Ok(value)
            });
            drop(guard);
            let _ = sender.send(answer);
        });
    if let Err(error) = worker {
        running.store(false, Ordering::Release);
        return Err(error);
    }
    match receiver.recv_timeout(wait) {
        Ok(answer) => answer,
        Err(_) => {
            cancelled.store(true, Ordering::Release);
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "USB connector observation did not finish",
            ))
        }
    }
}

fn endpoint(device: u32, budget: &Budget) -> io::Result<Endpoint> {
    budget.check()?;
    let mut port = 0u32;
    let mut kind = 0;
    let mut bytes = 4;
    // SAFETY: a current devnode, a fixed property key and correctly sized outputs.
    let code = unsafe {
        CM_Get_DevNode_PropertyW(
            device,
            &DEVPKEY_Device_Address,
            &mut kind,
            (&mut port as *mut u32).cast(),
            &mut bytes,
            0,
        )
    };
    if code != CR_SUCCESS || kind != DEVPROP_TYPE_UINT32 || bytes != 4 {
        return Err(invalid("USB device port is unavailable"));
    }
    let hub = parent_hub(device, budget)?;
    Endpoint::new(&hub, port)
}

fn parent_hub(device: u32, budget: &Budget) -> io::Result<String> {
    budget.check()?;
    let mut parent = 0;
    // SAFETY: current devnode and a live output; this only reads the PnP tree.
    if unsafe { CM_Get_Parent(&mut parent, device, 0) } != CR_SUCCESS {
        return Err(invalid("USB parent is unavailable"));
    }
    let mut count = 0;
    // SAFETY: parent devnode and a live size output.
    if unsafe { CM_Get_Device_ID_Size(&mut count, parent, 0) } != CR_SUCCESS
        || !(1..4096).contains(&count)
    {
        return Err(invalid("USB parent identity is unavailable"));
    }
    let mut id = vec![0u16; count as usize + 1];
    // SAFETY: the allocated UTF-16 buffer is large enough for the returned size.
    if unsafe { CM_Get_Device_IDW(parent, id.as_mut_ptr(), id.len() as u32, 0) } != CR_SUCCESS {
        return Err(invalid("USB parent identity changed"));
    }
    for _ in 0..3 {
        budget.check()?;
        let mut count = 0;
        // SAFETY: the fixed hub class, terminated parent ID and size output.
        // Zero flags select present interfaces only.
        if unsafe { CM_Get_Device_Interface_List_SizeW(&mut count, &HUB, id.as_ptr(), 0) }
            != CR_SUCCESS
            || !(2..=MAX_BYTES as u32 / 2).contains(&count)
        {
            return Err(invalid("USB parent has no bounded active hub interface"));
        }
        let mut paths = vec![0u16; count as usize];
        // SAFETY: the list buffer has exactly the requested number of UTF-16 units.
        let code = unsafe {
            CM_Get_Device_Interface_ListW(&HUB, id.as_ptr(), paths.as_mut_ptr(), count, 0)
        };
        if code == CR_BUFFER_SMALL {
            continue;
        }
        if code != CR_SUCCESS {
            return Err(invalid("USB parent interface is unavailable"));
        }
        let end = paths
            .iter()
            .position(|unit| *unit == 0)
            .ok_or_else(|| invalid("unterminated USB hub path"))?;
        if end == 0 || end + 1 == paths.len() || paths[end + 1..].iter().any(|unit| *unit != 0) {
            return Err(invalid("USB parent interface is missing or ambiguous"));
        }
        return String::from_utf16(&paths[..end]).map_err(|_| invalid("invalid USB hub path"));
    }
    Err(invalid("USB parent interface kept changing"))
}

fn query(endpoint: &Endpoint, budget: &Budget) -> io::Result<Option<Endpoint>> {
    budget.check()?;
    let path: Vec<u16> = format!(r"\\?\{}", endpoint.hub)
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    // SAFETY: an independently discovered exact hub interface, terminated path,
    // no inherited handle and a synchronous handle retained through the query.
    let raw = unsafe {
        CreateFileW(
            path.as_ptr(),
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            std::ptr::null_mut(),
        )
    };
    if raw == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    let handle = Handle::new(raw)?;
    budget.check()?;
    let mut bytes = vec![0u8; MAX_BYTES];
    bytes[..4].copy_from_slice(&endpoint.port.to_le_bytes());
    // CompanionIndex remains zero (USB 3/xHCI); multiple companions are refused.
    let mut returned = 0;
    // SAFETY: one closed read-only IOCTL, one owned input/output buffer, live
    // size output, and synchronous completion. A timed-out caller never frees it.
    let ok = unsafe {
        DeviceIoControl(
            handle.raw(),
            CONNECTOR_QUERY,
            bytes.as_ptr().cast(),
            bytes.len() as u32,
            bytes.as_mut_ptr().cast(),
            bytes.len() as u32,
            &mut returned,
            std::ptr::null_mut(),
        )
    };
    if ok == 0 {
        return Err(io::Error::last_os_error());
    }
    budget.check()?;
    if returned as usize > bytes.len() {
        return Err(invalid("oversized USB connector response"));
    }
    bytes.truncate(returned as usize);
    usb_connector::companion(&bytes, endpoint.port)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timed_out_query_retains_its_worker_and_cannot_query_again() {
        let running = Arc::new(AtomicBool::new(false));
        let (started, entered) = mpsc::sync_channel(1);
        let (release, blocked) = mpsc::sync_channel(1);
        let (finished, ended) = mpsc::sync_channel(1);
        let worker_running = Arc::clone(&running);
        let worker = std::thread::spawn(move || {
            bounded(worker_running, Duration::from_millis(100), move |budget| {
                started.send(()).unwrap();
                blocked.recv().unwrap();
                let result = budget.check();
                finished.send(result.is_err()).unwrap();
                result
            })
        });
        entered.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(
            worker.join().unwrap().unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
        assert_eq!(
            bounded(Arc::clone(&running), WAIT, |_| Ok(()))
                .unwrap_err()
                .kind(),
            io::ErrorKind::WouldBlock
        );
        release.send(()).unwrap();
        assert!(ended.recv_timeout(Duration::from_secs(2)).unwrap());
    }
}
