//! Darwin continuous elapsed time for overall budgets, not active-work samples.
//! CLOCK_MONOTONIC advances through system sleep on macOS. Never persist an
//! instant or compare origins from different process lifetimes.
use std::{io, time::Duration};

#[derive(Clone, Copy, Debug)]
pub struct ContinuousInstant(Duration);
impl ContinuousInstant {
    pub fn now() -> io::Result<Self> {
        let mut time = std::mem::MaybeUninit::<libc::timespec>::uninit();
        // SAFETY: clock_gettime initializes this writable timespec on success.
        if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, time.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the preceding successful call initialized both fields.
        let time = unsafe { time.assume_init() };
        if time.tv_sec < 0 || !(0..1_000_000_000).contains(&time.tv_nsec) {
            return Err(io::Error::other("invalid continuous clock reading"));
        }
        Ok(Self(Duration::new(time.tv_sec as u64, time.tv_nsec as u32)))
    }
    pub fn elapsed(self) -> io::Result<Duration> {
        Self::now()?
            .0
            .checked_sub(self.0)
            .ok_or_else(|| io::Error::other("continuous clock regressed"))
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn elapsed_reading_is_monotonic() {
        let start = super::ContinuousInstant::now().unwrap();
        let first = start.elapsed().unwrap();
        assert!(start.elapsed().unwrap() >= first);
        // No synthetic claim that this smoke test suspends the host.
    }
}
