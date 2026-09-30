//! The Windows daemon's stop request, the counterpart of the Unix SIGTERM and
//! SIGINT latch (`stop_signal.rs`): a manual-reset event that stays set once
//! a stop is asked for, which the serving loop waits on beside its pipe.
//!
//! Two sources set it. A console Ctrl+C or Ctrl+Break (SIGINT's
//! counterpart) is only recorded by the control handler, never acted on
//! there. A daemon that owns a state root also names its event after that
//! root's instance scope and its own process id
//! ([`InstanceScope::stop_event_name`]), with an owner-only DACL, so that
//! another process of the same user can ask it to stop and drain
//! ([`InstanceScope::request_stop`]), as a same-user SIGTERM does on Unix.
//! No process is ever ended by either.
use super::state::InstanceScope;
use super::{Handle, SecurityDescriptor, bool_result, wide};
use crate::denied;
use std::ffi::OsStr;
use std::io;
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicPtr, Ordering};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::System::Console::{CTRL_BREAK_EVENT, CTRL_C_EVENT, SetConsoleCtrlHandler};
use windows_sys::Win32::System::Threading::*;

/// The installed stop event, for the console control handler; null until
/// `install`. Never closed once published.
static STOP_EVENT: AtomicPtr<std::ffi::c_void> = AtomicPtr::new(null_mut());

/// Runs on a thread the system starts: records the stop and reports the
/// event handled; any other control event keeps its default.
unsafe extern "system" fn record_stop(control: u32) -> windows_sys::core::BOOL {
    if control != CTRL_C_EVENT && control != CTRL_BREAK_EVENT {
        return 0;
    }
    let event = STOP_EVENT.load(Ordering::Acquire);
    if !event.is_null() {
        // SAFETY: the published event stays open for the life of the process.
        unsafe { SetEvent(event) };
    }
    1
}

/// A manual-reset event: never set again once set, and seen by every later
/// look.
fn manual_event(security: Option<&SecurityDescriptor>, name: Option<&str>) -> io::Result<Handle> {
    let attributes = security.map(SecurityDescriptor::attributes);
    let name = name.map(|name| wide(OsStr::new(name))).transpose()?;
    // SAFETY: optional attributes and NUL-terminated name live for the call;
    // the handle is owned at once.
    let event = Handle::new(unsafe {
        CreateEventW(
            attributes.as_ref().map_or(null(), std::ptr::from_ref),
            1,
            0,
            name.as_ref().map_or(null(), |name| name.as_ptr()),
        )
    })?;
    if name.is_some()
        && io::Error::last_os_error().raw_os_error() == Some(ERROR_ALREADY_EXISTS as i32)
    {
        return Err(denied(
            "the daemon's stop event already exists; nothing was started",
        ));
    }
    Ok(event)
}

/// The recorded stop request, installed once per process. Its event is
/// never closed: the control handler may read it at any later time.
pub struct StopSignal {
    event: HANDLE,
}

impl StopSignal {
    /// Records Ctrl+C and Ctrl+Break for the rest of the process and, with a
    /// scope, also answers that scope's named stop event for this process. A
    /// second install is refused: there is one stop request per process.
    pub fn install(scope: Option<&InstanceScope>) -> io::Result<Self> {
        let event = match scope {
            Some(scope) => {
                let user = super::identity::Token::current()?.user()?.text()?;
                let security = SecurityDescriptor::from_sddl(&format!(
                    "O:{user}D:P(A;;GA;;;{user})(A;;GA;;;SY)"
                ))?;
                manual_event(
                    Some(&security),
                    Some(&scope.stop_event_name(std::process::id())),
                )?
            }
            None => manual_event(None, None)?,
        };
        if STOP_EVENT
            .compare_exchange(null_mut(), event.raw(), Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "the stop signal is already installed",
            ));
        }
        let event = event.leak();
        // SAFETY: a handler with the documented signature, added once.
        bool_result(unsafe { SetConsoleCtrlHandler(Some(record_stop), 1) })?;
        Ok(Self { event })
    }

    /// A Runtime-owned composition change uses the same drain as a stop
    /// request. No other process is affected.
    pub fn request_current() -> io::Result<()> {
        let event = STOP_EVENT.load(Ordering::Acquire);
        if event.is_null() {
            return Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "the Runtime stop signal is not installed",
            ));
        }
        // SAFETY: the published event stays open for the life of the process.
        bool_result(unsafe { SetEvent(event) })
    }

    /// Whether a stop has been requested; never consumes the request.
    pub fn requested(&self) -> bool {
        super::signalled(self.event).unwrap_or(false)
    }

    pub(crate) fn raw(&self) -> HANDLE {
        self.event
    }
}

/// A one-way latch that threads wait on beside a pipe
/// (`LocalConnection::wait_readable`): once set it stays set, and every
/// later look sees it.
pub struct Latch(Handle);

impl Latch {
    pub fn new() -> io::Result<Self> {
        Ok(Self(manual_event(None, None)?))
    }

    pub fn set(&self) {
        // SAFETY: a live event this latch owns.
        unsafe { SetEvent(self.0.raw()) };
    }

    pub fn is_set(&self) -> bool {
        super::signalled(self.0.raw()).unwrap_or(false)
    }

    pub(crate) fn raw(&self) -> HANDLE {
        self.0.raw()
    }
}
