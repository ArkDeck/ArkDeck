//! Local-only Windows transport. See design F.2 and Microsoft's Named Pipe
//! Security and Access Rights / GetNamedPipeServerProcessId API references.
use crate::{LocalEndpoint, ServerIdentity, denied, invalid};
use std::ffi::OsStr;
use std::io::{self, Read, Write};
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::ptr::{null, null_mut};
use std::sync::Mutex;
use std::time::Duration;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Authorization::*;
use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::IO::*;
use windows_sys::Win32::System::Pipes::*;
use windows_sys::Win32::System::Threading::*;

mod account;
mod daemon_start;
mod host_fs;
pub(crate) mod host_store;
mod identity;
mod managed;
mod process;
mod server;
mod state;
mod stop;
mod tool;
pub use account::{application_support_directory, arkdeck_application_support_root};
pub use daemon_start::{
    DetachedDaemon, StarterLock, await_pipe_instance, pipe_present, verify_daemon_image,
};
pub use identity::ImagePin;
pub(crate) use identity::{FileIdentity, file_identity, lock_namespace, reject_reparse_file};
use identity::{LocalAllocation, ProcessIdentity, Token, require_pipe_owner};
pub use managed::ManagedServer;
pub(crate) use process::spawn;
pub use server::LoopbackServerLease;
pub use state::{
    GuardAcquisition, GuardObject, InstanceScope, OWNER_ONLY_REMEDY, OwnerLock,
    SingleInstanceGuard, StateRoot,
};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
pub use stop::{Latch, StopSignal, send_console_break};

pub(crate) struct Handle(OwnedHandle);
impl Handle {
    pub(crate) fn new(handle: HANDLE) -> io::Result<Self> {
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: caller transfers a newly acquired, valid kernel handle.
        Ok(Self(unsafe { OwnedHandle::from_raw_handle(handle) }))
    }
    pub(crate) fn raw(&self) -> HANDLE {
        self.0.as_raw_handle()
    }
    /// Gives up ownership: the handle stays open for the life of the process.
    pub(crate) fn leak(self) -> HANDLE {
        std::os::windows::io::IntoRawHandle::into_raw_handle(self.0)
    }
    pub(crate) fn into_file(self) -> std::fs::File {
        self.0.into()
    }
}

pub(crate) fn bool_result(result: i32) -> io::Result<()> {
    if result == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

pub(crate) fn wide(value: &OsStr) -> io::Result<Vec<u16>> {
    let mut value: Vec<u16> = value.encode_wide().collect();
    if value.contains(&0) {
        return Err(invalid(
            "NUL is not permitted in Windows paths or arguments",
        ));
    }
    value.push(0);
    Ok(value)
}

pub fn default_user_endpoint() -> io::Result<LocalEndpoint> {
    let sid = Token::current()?.logon()?.text()?;
    Ok(LocalEndpoint::new(format!(
        r"\\.\pipe\arkdeck-agentd-{sid}"
    )))
}

fn endpoint_name(endpoint: &LocalEndpoint) -> io::Result<Vec<u16>> {
    let name = endpoint
        .as_path()
        .to_str()
        .ok_or_else(|| invalid("invalid local pipe name"))?;
    if !name.starts_with(r"\\.\pipe\arkdeck-")
        || name.len() > 240
        || name[r"\\.\pipe\".len()..].contains(['\\', '/', ':'])
    {
        return Err(invalid(
            "only a local ArkDeck named pipe endpoint is accepted",
        ));
    }
    wide(endpoint.as_path().as_os_str())
}

/// A self-relative security descriptor made from SDDL, for creating an
/// object with exactly that owner and DACL; never inherited by a child.
pub(crate) struct SecurityDescriptor(LocalAllocation);
impl SecurityDescriptor {
    pub(crate) fn from_sddl(sddl: &str) -> io::Result<Self> {
        let sddl = wide(OsStr::new(sddl))?;
        let mut descriptor = null_mut();
        // SAFETY: NUL-terminated SDDL and valid allocation output pointer.
        bool_result(unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                SDDL_REVISION_1,
                &mut descriptor,
                null_mut(),
            )
        })?;
        Ok(Self(LocalAllocation(descriptor)))
    }
    pub(crate) fn attributes(&self) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.0.0,
            bInheritHandle: 0,
        }
    }
}

struct PipeSecurity(SecurityDescriptor);
impl PipeSecurity {
    fn new() -> io::Result<Self> {
        let token = Token::current()?;
        Ok(Self(SecurityDescriptor::from_sddl(&format!(
            "O:{}D:P(A;;GA;;;{})",
            token.owner()?.text()?,
            token.logon()?.text()?
        ))?))
    }
    fn attributes(&self) -> SECURITY_ATTRIBUTES {
        self.0.attributes()
    }
}

fn create_instance(name: &[u16], security: &PipeSecurity, first: bool) -> io::Result<Handle> {
    let attributes = security.attributes();
    let flags = PIPE_ACCESS_DUPLEX
        | FILE_FLAG_OVERLAPPED
        | if first {
            FILE_FLAG_FIRST_PIPE_INSTANCE
        } else {
            0
        };
    // SAFETY: name and security descriptor outlive this synchronous creation call.
    let handle = unsafe {
        CreateNamedPipeW(
            name.as_ptr(),
            flags,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES,
            64 * 1024,
            64 * 1024,
            5000,
            &attributes,
        )
    };
    Handle::new(handle).map_err(|error| match error.raw_os_error() {
        Some(code) if held_by_another_instance(code, first) => {
            let name = String::from_utf16_lossy(&name[..name.len().saturating_sub(1)]);
            io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!(
                    "named pipe {name} is held by another instance (Win32 error {code}); daemon did not start"
                ),
            )
        }
        _ => error,
    })
}

/// Whether creating a pipe instance failed because another server already
/// holds the name. A holder that allows further instances refuses
/// `FILE_FLAG_FIRST_PIPE_INSTANCE` with `ERROR_ACCESS_DENIED`; one that
/// created the name with a single instance (or has used up its own limit)
/// refuses the first instance with `ERROR_PIPE_BUSY` instead. Both are the
/// same held name and fail closed alike: nothing waits for or retries
/// against the holder.
fn held_by_another_instance(code: i32, first: bool) -> bool {
    code == ERROR_ACCESS_DENIED as i32 || (first && code == ERROR_PIPE_BUSY as i32)
}

pub struct LocalListener {
    name: Vec<u16>,
    security: PipeSecurity,
    pending: Handle,
}

impl LocalListener {
    pub fn bind(endpoint: &LocalEndpoint) -> io::Result<Self> {
        let name = endpoint_name(endpoint)?;
        let security = PipeSecurity::new()?;
        let pending = create_instance(&name, &security, true)?;
        Ok(Self {
            name,
            security,
            pending,
        })
    }

    pub fn accept(&mut self) -> io::Result<LocalConnection> {
        self.accept_or_stop(None)?
            .ok_or_else(|| io::Error::other("an accept without a stop source was stopped"))
    }

    /// The next authenticated connection, or `None` once `stop` has been
    /// requested, whichever is ready first; a requested stop wins over a
    /// waiting connection, which is then never accepted.
    pub fn accept_until(&mut self, stop: &StopSignal) -> io::Result<Option<LocalConnection>> {
        self.accept_or_stop(Some(stop.raw()))
    }

    /// As [`Self::accept_until`], for a serving generation's own latch.
    pub fn accept_until_latch(&mut self, stop: &Latch) -> io::Result<Option<LocalConnection>> {
        self.accept_or_stop(Some(stop.raw()))
    }

    /// Stops listening: the waiting pipe instance is closed, so a client is
    /// refused from now on (every instance still connected keeps the name,
    /// which no second daemon can then create with
    /// `FILE_FLAG_FIRST_PIPE_INSTANCE`). The Unix facade hands back its
    /// transport directory's lock here; a pipe has none, and the daemon's
    /// owner lock and single-instance guard stay with its composition until
    /// it has drained.
    pub fn stop_listening(self) -> ListenerLock {
        drop(self);
        ListenerLock { _private: () }
    }

    fn accept_or_stop(&mut self, stop: Option<HANDLE>) -> io::Result<Option<LocalConnection>> {
        if let Some(stop) = stop
            && signalled(stop)?
        {
            return Ok(None);
        }
        let event = new_event()?;
        let mut overlapped = OVERLAPPED {
            hEvent: event.raw(),
            ..Default::default()
        };
        // SAFETY: overlapped/event remain valid until completion is collected.
        let connection = if unsafe { ConnectNamedPipe(self.pending.raw(), &mut overlapped) } == 0 {
            let error = io::Error::last_os_error();
            match error.raw_os_error().map(|code| code as u32) {
                Some(ERROR_PIPE_CONNECTED) => Ok(()),
                Some(ERROR_IO_PENDING) => match stop {
                    None => complete(self.pending.raw(), &mut overlapped, None).map(|_| ()),
                    Some(stop) => {
                        if !connected_before_stop(self.pending.raw(), &overlapped, stop)? {
                            // A client that connected meanwhile is never
                            // served; stopping closes its instance.
                            return Ok(None);
                        }
                        Ok(())
                    }
                },
                _ => Err(error),
            }
        } else {
            Ok(())
        };
        if let Some(stop) = stop
            && signalled(stop)?
        {
            return Ok(None);
        }
        if let Err(error) = connection {
            if matches!(
                error.raw_os_error().map(|code| code as u32),
                Some(ERROR_NO_DATA | ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED)
            ) {
                // A client may close between connect and authentication. Keep
                // the endpoint owned while replacing the spent instance.
                let next = create_instance(&self.name, &self.security, false)?;
                self.pending = next;
                return Err(denied("pipe client disconnected before authentication"));
            }
            return Err(error);
        }
        // Keep a pipe instance continuously owned; a second daemon cannot win
        // FIRST_PIPE_INSTANCE between accepting and constructing the next slot.
        let next = create_instance(&self.name, &self.security, false)?;
        let connected = std::mem::replace(&mut self.pending, next);
        let peer = (|| {
            let pid = connection_pid(connected.raw(), false)?;
            let peer = ProcessIdentity::open(pid)?;
            peer.require_client_user()?;
            if connection_pid(connected.raw(), false)? != pid {
                return Err(denied("pipe client PID changed during authentication"));
            }
            peer.require_live()?;
            Ok(peer)
        })()
        .map_err(|error| {
            io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("pipe client authentication refused: {error}"),
            )
        })?;
        Ok(Some(LocalConnection::new(connected, peer)))
    }
}

/// Waits for a pending `ConnectNamedPipe` or the stop, whichever is first;
/// the stop wins when both are signalled. A stopped wait cancels the connect
/// and collects its completion before the OVERLAPPED may be freed.
fn connected_before_stop(pipe: HANDLE, overlapped: &OVERLAPPED, stop: HANDLE) -> io::Result<bool> {
    let handles = [stop, overlapped.hEvent];
    // SAFETY: two live handles; the stop comes first.
    let wait = unsafe { WaitForMultipleObjects(2, handles.as_ptr(), 0, INFINITE) };
    let wait_error = io::Error::last_os_error();
    let mut transferred = 0;
    if wait == WAIT_OBJECT_0 + 1 {
        // SAFETY: the signalled operation's result, valid output storage.
        bool_result(unsafe { GetOverlappedResult(pipe, overlapped, &mut transferred, 0) })?;
        return Ok(true);
    }
    // SAFETY: cancel this exact operation and wait for its completion.
    unsafe {
        CancelIoEx(pipe, overlapped);
        GetOverlappedResult(pipe, overlapped, &mut transferred, 1);
    }
    if wait == WAIT_OBJECT_0 {
        Ok(false)
    } else {
        Err(wait_error)
    }
}

/// What a listener that stopped listening still holds. A pipe has no
/// transport lock of its own (see [`LocalListener::stop_listening`]).
pub struct ListenerLock {
    _private: (),
}

/// What [`LocalConnection::wait_readable`] saw first.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Readiness {
    Readable,
    Latched,
    TimedOut,
}

/// Ends a connection from outside the thread that serves it: every
/// transfer in flight on it is cancelled, and every later one finds it ended
/// (a read reports its end, a write fails). The pipe itself is closed when
/// its connection is dropped, so a peer still reads the replies already
/// written before it sees the end.
pub struct ConnectionCloser {
    pipe: Handle,
    closed: Arc<AtomicBool>,
}

impl ConnectionCloser {
    pub fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        // SAFETY: a live duplicate of the connection's pipe handle; a null
        // OVERLAPPED cancels every operation this process has on the pipe.
        unsafe {
            CancelIoEx(self.pipe.raw(), null());
        }
    }
}

/// Whether a stop or latch event is set now; nothing is consumed.
fn signalled(event: HANDLE) -> io::Result<bool> {
    // SAFETY: a live event handle; no wait.
    match unsafe { WaitForSingleObject(event, 0) } {
        WAIT_OBJECT_0 => Ok(true),
        WAIT_TIMEOUT => Ok(false),
        _ => Err(io::Error::last_os_error()),
    }
}

pub struct LocalConnection {
    pipe: Handle,
    // Set by this connection's closer; every transfer looks at it.
    closed: Arc<AtomicBool>,
    // Pins the connection's original process object and immutable image file.
    peer: ProcessIdentity,
    read_timeout: Mutex<Option<Duration>>,
    write_timeout: Mutex<Option<Duration>>,
}

impl LocalConnection {
    fn new(pipe: Handle, peer: ProcessIdentity) -> Self {
        Self {
            pipe,
            closed: Arc::new(AtomicBool::new(false)),
            peer,
            read_timeout: Mutex::new(Some(Duration::from_secs(10))),
            write_timeout: Mutex::new(Some(Duration::from_secs(10))),
        }
    }
    pub fn connect(endpoint: &LocalEndpoint, expected: &ServerIdentity) -> io::Result<Self> {
        let name = endpoint_name(endpoint)?;
        // SQOS prevents an untrusted server from impersonating beyond identification.
        // SAFETY: valid NUL-terminated name; result is immediately RAII-owned.
        let pipe = Handle::new(unsafe {
            CreateFileW(
                name.as_ptr(),
                GENERIC_READ | GENERIC_WRITE | READ_CONTROL,
                0,
                null(),
                OPEN_EXISTING,
                FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                null_mut(),
            )
        })?;
        require_pipe_owner(pipe.raw())?;
        // Never silently downgrade if this API fails: SPK-3 must record the host
        // outcome. Until such a reviewed boundary decision, send zero frames.
        let pid = connection_pid(pipe.raw(), true)?;
        let peer = ProcessIdentity::open(pid)?;
        peer.require_server(expected)?;
        if connection_pid(pipe.raw(), true)? != pid {
            return Err(denied("pipe server PID changed during authentication"));
        }
        Ok(Self::new(pipe, peer))
    }
    /// A second handle that ends this connection from another thread.
    pub fn closer(&self) -> io::Result<ConnectionCloser> {
        let mut duplicate = null_mut();
        // SAFETY: duplicates this connection's live pipe handle within this
        // process, not inheritable; the copy is owned at once.
        bool_result(unsafe {
            DuplicateHandle(
                GetCurrentProcess(),
                self.pipe.raw(),
                GetCurrentProcess(),
                &mut duplicate,
                0,
                0,
                DUPLICATE_SAME_ACCESS,
            )
        })?;
        Ok(ConnectionCloser {
            pipe: Handle::new(duplicate)?,
            closed: Arc::clone(&self.closed),
        })
    }

    /// Waits until this connection has something to read (or its peer has
    /// gone, or its closer ended it, which the read then reports), the latch
    /// is set, or `timeout` passes; a set latch is seen first. Nothing is
    /// read: a zero-byte read completes once data is there.
    pub fn wait_readable(&self, latch: &Latch, timeout: Duration) -> io::Result<Readiness> {
        if latch.is_set() {
            return Ok(Readiness::Latched);
        }
        if self.closed.load(Ordering::SeqCst) {
            return Ok(Readiness::Readable);
        }
        let event = new_event()?;
        let overlapped = OVERLAPPED {
            hEvent: event.raw(),
            ..Default::default()
        };
        let mut nothing = 0u8;
        // SAFETY: a zero-length read into live storage; the OVERLAPPED and
        // its event stay alive until its completion is collected below.
        let started = unsafe {
            ReadFile(
                self.pipe.raw(),
                &mut nothing,
                0,
                null_mut(),
                std::ptr::from_ref(&overlapped).cast_mut(),
            )
        };
        if started != 0 {
            return Ok(Readiness::Readable);
        }
        if io::Error::last_os_error().raw_os_error() != Some(ERROR_IO_PENDING as i32) {
            // A pipe that ended or failed: the read reports it.
            return Ok(Readiness::Readable);
        }
        if self.closed.load(Ordering::SeqCst) {
            // SAFETY: cancel this exact operation; its completion is collected below.
            unsafe { CancelIoEx(self.pipe.raw(), &overlapped) };
        }
        let millis = timeout.as_millis().min(u128::from(u32::MAX - 1)) as u32;
        let handles = [latch.raw(), event.raw()];
        // SAFETY: two live handles; the latch comes first, so it wins when
        // both are signalled.
        let wait = unsafe { WaitForMultipleObjects(2, handles.as_ptr(), 0, millis) };
        let wait_error = io::Error::last_os_error();
        if wait != WAIT_OBJECT_0 + 1 {
            // SAFETY: cancel this exact operation; collected below.
            unsafe { CancelIoEx(self.pipe.raw(), &overlapped) };
        }
        let mut transferred = 0;
        // SAFETY: waits for this operation's completion before the OVERLAPPED
        // and the byte are freed.
        let completed =
            unsafe { GetOverlappedResult(self.pipe.raw(), &overlapped, &mut transferred, 1) };
        let cancelled = completed == 0
            && io::Error::last_os_error().raw_os_error() == Some(ERROR_OPERATION_ABORTED as i32);
        Ok(match wait {
            WAIT_OBJECT_0 => Readiness::Latched,
            _ if !cancelled => Readiness::Readable,
            _ if self.closed.load(Ordering::SeqCst) => Readiness::Readable,
            WAIT_TIMEOUT => Readiness::TimedOut,
            _ => return Err(wait_error),
        })
    }

    /// The process ID returned for this exact pipe instance, retained for SPK-3.
    pub fn authenticated_peer_pid(&self) -> u32 {
        self.peer.pid
    }
    /// Expiry requests cancellation; returning the borrowed buffer still waits
    /// for safe kernel completion. Native cancellation latency is a SPK-3 check.
    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        validate_timeout(timeout)?;
        *self
            .read_timeout
            .lock()
            .map_err(|_| io::Error::other("read timeout lock poisoned"))? = timeout;
        Ok(())
    }
    /// Expiry requests cancellation and drains it before releasing the buffer.
    pub fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        validate_timeout(timeout)?;
        *self
            .write_timeout
            .lock()
            .map_err(|_| io::Error::other("write timeout lock poisoned"))? = timeout;
        Ok(())
    }
}

fn validate_timeout(timeout: Option<Duration>) -> io::Result<()> {
    if timeout.is_some_and(|value| value.is_zero()) {
        Err(invalid("zero IO timeout"))
    } else {
        Ok(())
    }
}

impl Read for LocalConnection {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        if bytes.is_empty() {
            return Ok(0);
        }
        let timeout = *self
            .read_timeout
            .lock()
            .map_err(|_| io::Error::other("read timeout lock poisoned"))?;
        transfer(
            self.pipe.raw(),
            &self.closed,
            bytes.as_mut_ptr(),
            bytes.len(),
            timeout,
            false,
        )
    }
}
impl Write for LocalConnection {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.is_empty() {
            return Ok(0);
        }
        self.peer.require_live()?;
        let timeout = *self
            .write_timeout
            .lock()
            .map_err(|_| io::Error::other("write timeout lock poisoned"))?;
        transfer(
            self.pipe.raw(),
            &self.closed,
            bytes.as_ptr().cast_mut(),
            bytes.len(),
            timeout,
            true,
        )
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn connection_pid(pipe: HANDLE, server: bool) -> io::Result<u32> {
    let mut pid = 0;
    // SAFETY: connected pipe handle and valid output storage.
    let result = unsafe {
        if server {
            GetNamedPipeServerProcessId(pipe, &mut pid)
        } else {
            GetNamedPipeClientProcessId(pipe, &mut pid)
        }
    };
    bool_result(result)?;
    if pid == 0 {
        return Err(denied(
            "connection process identity unavailable; zero frames sent",
        ));
    }
    Ok(pid)
}

fn new_event() -> io::Result<Handle> {
    // SAFETY: unnamed manual-reset event; result is RAII-owned.
    Handle::new(unsafe { CreateEventW(null(), 1, 0, null()) })
}

fn complete(
    pipe: HANDLE,
    overlapped: &mut OVERLAPPED,
    timeout: Option<Duration>,
) -> io::Result<u32> {
    let millis = timeout.map_or(INFINITE, |value| {
        value.as_millis().max(1).min(u128::from(u32::MAX - 1)) as u32
    });
    // SAFETY: event belongs to this in-flight operation and remains live.
    let wait = unsafe { WaitForSingleObject(overlapped.hEvent, millis) };
    let mut transferred = 0;
    if wait != WAIT_OBJECT_0 {
        let wait_error = io::Error::last_os_error();
        // SAFETY: cancel this exact operation and drain completion before the
        // stack OVERLAPPED or user buffer may be freed, including timeout paths.
        unsafe {
            CancelIoEx(pipe, overlapped);
            GetOverlappedResult(pipe, overlapped, &mut transferred, 1);
        }
        return Err(if wait == WAIT_TIMEOUT {
            io::Error::new(io::ErrorKind::TimedOut, "named pipe IO deadline exceeded")
        } else {
            wait_error
        });
    }
    // SAFETY: signaled operation, valid transferred byte output.
    bool_result(unsafe { GetOverlappedResult(pipe, overlapped, &mut transferred, 0) })?;
    Ok(transferred)
}

fn transfer(
    pipe: HANDLE,
    closed: &AtomicBool,
    buffer: *mut u8,
    length: usize,
    timeout: Option<Duration>,
    writing: bool,
) -> io::Result<usize> {
    // A connection its closer ended reads its end and refuses writes.
    if closed.load(Ordering::SeqCst) {
        return if writing {
            Err(io::Error::from(io::ErrorKind::BrokenPipe))
        } else {
            Ok(0)
        };
    }
    let event = new_event()?;
    let mut overlapped = OVERLAPPED {
        hEvent: event.raw(),
        ..Default::default()
    };
    let length = length.min(u32::MAX as usize) as u32;
    // SAFETY: called with a slice's valid buffer; only Read uses its mutable
    // variant; buffer/OVERLAPPED/event remain alive until completion is drained.
    let result = unsafe {
        if writing {
            WriteFile(pipe, buffer, length, null_mut(), &mut overlapped)
        } else {
            ReadFile(pipe, buffer, length, null_mut(), &mut overlapped)
        }
    };
    let completion = if result != 0 {
        let mut transferred = 0;
        // SAFETY: a synchronous success also reports its byte count through the
        // OVERLAPPED result, never the synchronous ReadFile/WriteFile out pointer.
        bool_result(unsafe { GetOverlappedResult(pipe, &overlapped, &mut transferred, 0) })
            .map(|_| transferred)
    } else {
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(ERROR_IO_PENDING as i32) {
            // A close between the look above and this transfer starting
            // could not cancel it: cancel it here.
            if closed.load(Ordering::SeqCst) {
                // SAFETY: cancel this exact operation; `complete` drains it.
                unsafe { CancelIoEx(pipe, &overlapped) };
            }
            complete(pipe, &mut overlapped, timeout)
        } else {
            Err(error)
        }
    };
    match completion {
        Ok(count) => Ok(count as usize),
        Err(error)
            if !writing
                && matches!(
                    error.raw_os_error().map(|code| code as u32),
                    Some(ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED)
                ) =>
        {
            Ok(0)
        }
        // Cancelled by the connection's closer: its end.
        Err(_) if closed.load(Ordering::SeqCst) => {
            if writing {
                Err(io::Error::from(io::ErrorKind::BrokenPipe))
            } else {
                Ok(0)
            }
        }
        Err(error) => Err(error),
    }
}
