//! The daemon's stop request, as Swift's daemon takes it: SIGTERM and SIGINT
//! are caught for the rest of the process and only recorded, never acted on
//! inside the handler. The handler writes one byte to a pipe whose read end
//! the serving loop waits on beside its listener, so a stop wakes the loop
//! at once and every later look still sees it.
//!
//! A caught signal, unlike an ignored or blocked one, is reset to its
//! default action across `exec`, so a tool or server the daemon launches
//! keeps the default SIGTERM and SIGINT and its own signal mask.
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicI32, Ordering};

/// The pipe's write end, for the handler; -1 until `install`.
static STOP_WRITE: AtomicI32 = AtomicI32::new(-1);

/// The signals that ask the daemon to stop.
const STOP_SIGNALS: [libc::c_int; 2] = [libc::SIGTERM, libc::SIGINT];

#[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
fn errno_location() -> *mut libc::c_int {
    // SAFETY: returns the calling thread's errno slot; takes no arguments.
    unsafe { libc::__error() }
}

#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "freebsd")))]
fn errno_location() -> *mut libc::c_int {
    // SAFETY: returns the calling thread's errno slot; takes no arguments.
    unsafe { libc::__errno_location() }
}

/// Only async-signal-safe work: one nonblocking write, with the interrupted
/// thread's errno put back. A full pipe drops the byte; the stop is already
/// recorded by the bytes before it.
extern "C" fn record_stop(_signal: libc::c_int) {
    let slot = errno_location();
    // SAFETY: the calling thread's own errno slot.
    let saved = unsafe { *slot };
    let descriptor = STOP_WRITE.load(Ordering::Acquire);
    if descriptor >= 0 {
        let byte = 1u8;
        // SAFETY: write(2) is async-signal-safe; the write end stays open for
        // the life of the process once published.
        unsafe {
            libc::write(descriptor, std::ptr::from_ref(&byte).cast(), 1);
        }
    }
    // SAFETY: as above.
    unsafe { *slot = saved };
}

/// The recorded stop request, installed once per process.
pub struct StopSignal {
    read: OwnedFd,
}

impl StopSignal {
    /// Catches SIGTERM and SIGINT for the rest of the process. A second
    /// install is refused: there is one stop request per process.
    pub fn install() -> io::Result<Self> {
        let (read, write) = pipe()?;
        if STOP_WRITE
            .compare_exchange(-1, write.as_raw_fd(), Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "the stop signal is already installed",
            ));
        }
        // The handler may write to it at any later time: never closed.
        let _ = write.into_raw_fd();
        for signal in STOP_SIGNALS {
            // SAFETY: zero is a valid empty sigaction before its fields are set.
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = record_stop as extern "C" fn(libc::c_int) as libc::sighandler_t;
            action.sa_flags = libc::SA_RESTART;
            // SAFETY: the action's mask is owned, writable storage.
            unsafe { libc::sigemptyset(&mut action.sa_mask) };
            // SAFETY: a fully initialized action for a catchable signal; the
            // previous action is not needed.
            if unsafe { libc::sigaction(signal, &action, std::ptr::null_mut()) } != 0 {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(Self { read })
    }

    /// Whether a stop has been requested; never consumes the request.
    pub fn requested(&self) -> bool {
        readable_now(self.read.as_raw_fd())
    }
}

impl AsRawFd for StopSignal {
    fn as_raw_fd(&self) -> RawFd {
        self.read.as_raw_fd()
    }
}

/// A one-way latch that threads wait on beside a descriptor
/// (`LocalConnection::wait_readable`): once set it stays set, and every
/// later look sees it.
pub struct Latch {
    read: OwnedFd,
    write: OwnedFd,
}

impl Latch {
    pub fn new() -> io::Result<Self> {
        let (read, write) = pipe()?;
        Ok(Self { read, write })
    }

    pub fn set(&self) {
        let byte = 1u8;
        // SAFETY: a live nonblocking descriptor this latch owns. A full pipe
        // is a latch already set.
        unsafe {
            libc::write(self.write.as_raw_fd(), std::ptr::from_ref(&byte).cast(), 1);
        }
    }

    pub fn is_set(&self) -> bool {
        readable_now(self.read.as_raw_fd())
    }
}

impl AsRawFd for Latch {
    fn as_raw_fd(&self) -> RawFd {
        self.read.as_raw_fd()
    }
}

/// A close-on-exec, nonblocking pipe: its read end and its write end.
fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut descriptors = [0; 2];
    // SAFETY: writable storage for the two descriptors pipe(2) returns.
    if unsafe { libc::pipe(descriptors.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: pipe(2) just returned these two descriptors to this call.
    let (read, write) = unsafe {
        (
            OwnedFd::from_raw_fd(descriptors[0]),
            OwnedFd::from_raw_fd(descriptors[1]),
        )
    };
    for descriptor in [read.as_raw_fd(), write.as_raw_fd()] {
        set_flags(descriptor)?;
    }
    Ok((read, write))
}

/// The descriptor has something to read now; nothing is consumed.
fn readable_now(descriptor: RawFd) -> bool {
    let mut polled = libc::pollfd {
        fd: descriptor,
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: one live descriptor in writable storage; no wait.
    unsafe { libc::poll(&mut polled, 1, 0) > 0 && polled.revents != 0 }
}

/// Close-on-exec, and nonblocking so that neither the handler nor a reader
/// can ever wait on the pipe.
fn set_flags(descriptor: RawFd) -> io::Result<()> {
    // SAFETY: fcntl on a live descriptor this module owns.
    unsafe {
        let descriptor_flags = libc::fcntl(descriptor, libc::F_GETFD);
        let status_flags = libc::fcntl(descriptor, libc::F_GETFL);
        if descriptor_flags < 0
            || status_flags < 0
            || libc::fcntl(
                descriptor,
                libc::F_SETFD,
                descriptor_flags | libc::FD_CLOEXEC,
            ) < 0
            || libc::fcntl(descriptor, libc::F_SETFL, status_flags | libc::O_NONBLOCK) < 0
        {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}
