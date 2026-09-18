//! macOS resource measurements for the current process. No subprocesses.
use std::io;

#[derive(Clone, Copy, Debug)]
pub struct SelfResources {
    /// Darwin ru_maxrss is bytes, and a lifetime high-water mark, not live RSS.
    pub max_resident_set_bytes: u64,
    pub open_file_descriptor_count: u64,
}

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

#[cfg(test)]
mod tests {
    #[test]
    fn reports_current_process_without_children() {
        let sample = super::self_resources().unwrap();
        assert!(sample.max_resident_set_bytes > 0);
        assert!(sample.open_file_descriptor_count >= 3);
    }
}
