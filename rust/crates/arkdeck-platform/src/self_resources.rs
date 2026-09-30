//! Resource measurements for the current process. No subprocesses.
//!
//! The two platforms answer the same two questions with their own counters,
//! and the soak's growth bounds compare each only with the same process's own
//! earlier reading:
//!
//! | field | macOS | Windows |
//! | --- | --- | --- |
//! | `max_resident_set_bytes` | `getrusage` `ru_maxrss` | `PeakWorkingSetSize` |
//! | `open_file_descriptor_count` | entries of `/dev/fd` | `GetProcessHandleCount` |
//!
//! Both memory counters are lifetime high-water marks of the pages resident
//! for the process, not its live resident set. A Windows handle is the
//! counterpart of a descriptor: files, pipes, events, threads and every other
//! kernel object the process holds open. The counts are not comparable across
//! platforms.
use std::io;

#[derive(Clone, Copy, Debug)]
pub struct SelfResources {
    /// Darwin ru_maxrss is bytes, and a lifetime high-water mark, not live RSS.
    /// On Windows the peak working set, the same kind of high-water mark.
    pub max_resident_set_bytes: u64,
    /// Open descriptors on macOS; open kernel handles on Windows.
    pub open_file_descriptor_count: u64,
}

#[cfg(target_os = "macos")]
pub fn self_resources() -> io::Result<SelfResources> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    // SAFETY: getrusage initializes this writable rusage on success.
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: successful getrusage initialized every field.
    let usage = unsafe { usage.assume_init() };
    let max_resident_set_bytes = u64::try_from(usage.ru_maxrss)
        .map_err(|_| io::Error::other("negative maximum resident set"))?;
    // This includes the directory enumeration descriptor, consistently in
    // baseline and subsequent measurements (as the Swift fixture does).
    let open_file_descriptor_count = std::fs::read_dir("/dev/fd")?
        .collect::<io::Result<Vec<_>>>()?
        .len() as u64;
    Ok(SelfResources {
        max_resident_set_bytes,
        open_file_descriptor_count,
    })
}

/// The current process's live memory on Windows, beside the high-water mark
/// that [`self_resources`] reports: the working set (pages resident now) and
/// the private bytes (committed memory no other process shares, where a leak
/// shows even while its pages are trimmed from the working set).
#[cfg(windows)]
#[derive(Clone, Copy, Debug)]
pub struct SelfMemory {
    pub working_set_bytes: u64,
    pub private_bytes: u64,
}

#[cfg(windows)]
fn memory_counters()
-> io::Result<windows_sys::Win32::System::ProcessStatus::PROCESS_MEMORY_COUNTERS_EX> {
    use windows_sys::Win32::System::ProcessStatus::{
        K32GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS, PROCESS_MEMORY_COUNTERS_EX,
    };
    use windows_sys::Win32::System::Threading::GetCurrentProcess;
    let mut counters = PROCESS_MEMORY_COUNTERS_EX {
        cb: size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32,
        ..Default::default()
    };
    // SAFETY: the pseudo handle of this process and a writable structure
    // whose declared size is its own; the extended layout begins with the
    // basic one, as the API documents.
    let status = unsafe {
        K32GetProcessMemoryInfo(
            GetCurrentProcess(),
            std::ptr::from_mut(&mut counters).cast::<PROCESS_MEMORY_COUNTERS>(),
            counters.cb,
        )
    };
    if status == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(counters)
}

#[cfg(windows)]
pub fn self_resources() -> io::Result<SelfResources> {
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, GetProcessHandleCount};
    let counters = memory_counters()?;
    let mut handles = 0_u32;
    // SAFETY: the pseudo handle of this process and a writable count.
    if unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut handles) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(SelfResources {
        max_resident_set_bytes: counters.PeakWorkingSetSize as u64,
        open_file_descriptor_count: u64::from(handles),
    })
}

#[cfg(windows)]
pub fn self_memory() -> io::Result<SelfMemory> {
    let counters = memory_counters()?;
    Ok(SelfMemory {
        working_set_bytes: counters.WorkingSetSize as u64,
        private_bytes: counters.PrivateUsage as u64,
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn reports_current_process_without_children() {
        let sample = super::self_resources().unwrap();
        assert!(sample.max_resident_set_bytes > 0);
        assert!(sample.open_file_descriptor_count >= 3);
    }

    #[cfg(windows)]
    #[test]
    fn the_live_working_set_never_exceeds_its_high_water_mark() {
        let memory = super::self_memory().unwrap();
        assert!(memory.working_set_bytes > 0 && memory.private_bytes > 0);
        // Read after the live figure: the peak only ever grows.
        let peak = super::self_resources().unwrap().max_resident_set_bytes;
        assert!(peak >= memory.working_set_bytes, "{peak} {memory:?}");
    }
}
