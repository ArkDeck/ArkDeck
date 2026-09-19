#[cfg(not(target_os = "macos"))]
use crate::VerifiedTool;
use crate::{Latch, LocalEndpoint, ServerIdentity, StopSignal, denied, invalid};
use std::fs::{self, DirBuilder};
use std::io::{self, IoSlice, Read, Write};
use std::net::Shutdown;
#[cfg(not(target_os = "macos"))]
use std::net::SocketAddrV4;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub fn default_user_endpoint() -> io::Result<LocalEndpoint> {
    // Separate from the published Swift socket: this skeleton has no authority.
    let root = std::env::temp_dir().canonicalize()?;
    Ok(LocalEndpoint::new(
        root.join(format!("arkdeck-rust-{}", effective_uid()))
            .join("control.sock"),
    ))
}

fn effective_uid() -> u32 {
    // SAFETY: geteuid takes no arguments and has no memory preconditions.
    unsafe { libc::geteuid() }
}

fn private_parent(path: &Path, create: bool) -> io::Result<()> {
    if !path.is_absolute() || path.file_name().is_none() {
        return Err(invalid("local endpoint must be an absolute socket path"));
    }
    let parent = path
        .parent()
        .ok_or_else(|| invalid("missing endpoint parent"))?;
    if create {
        match DirBuilder::new().mode(0o700).create(parent) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }
    let metadata = fs::symlink_metadata(parent)?;
    if !metadata.is_dir()
        || metadata.uid() != effective_uid()
        || metadata.mode() & 0o777 != 0o700
        || parent.canonicalize()? != parent
    {
        return Err(denied(
            "endpoint parent must be a physical owner-only 0700 directory",
        ));
    }
    Ok(())
}

fn validate_socket(path: &Path) -> io::Result<()> {
    private_parent(path, false)?;
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_socket()
        || metadata.uid() != effective_uid()
        || metadata.mode() & 0o777 != 0o600
    {
        return Err(denied("endpoint must be an owner-only 0600 socket"));
    }
    Ok(())
}

fn authenticate(stream: &UnixStream) -> io::Result<()> {
    #[cfg(any(target_os = "macos", target_os = "freebsd", target_os = "openbsd"))]
    let peer_uid = {
        let (mut uid, mut gid) = (0, 0);
        // SAFETY: live stream descriptor and writable uid/gid storage.
        if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0 {
            return Err(io::Error::last_os_error());
        }
        uid
    };
    #[cfg(target_os = "linux")]
    let peer_uid = {
        // SAFETY: ucred is an integer-only C structure.
        let mut credential: libc::ucred = unsafe { std::mem::zeroed() };
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        // SAFETY: storage is valid for length bytes and descriptor is live.
        if unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                std::ptr::from_mut(&mut credential).cast(),
                &mut length,
            )
        } != 0
            || length as usize != std::mem::size_of::<libc::ucred>()
        {
            return Err(io::Error::last_os_error());
        }
        credential.uid
    };
    if peer_uid != effective_uid() {
        return Err(denied("local peer effective UID differs from the daemon"));
    }
    Ok(())
}

pub struct LocalListener {
    listener: UnixListener,
    path: PathBuf,
    device: u64,
    inode: u64,
    _directory_lock: Option<DirectoryLock>,
}

/// The facade's kernel lock on its transport directory, released explicitly
/// when dropped: a descriptor a spawned child still shares must not keep the
/// directory owned after this listener's owner is gone.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
struct DirectoryLock(fs::File);

impl Drop for DirectoryLock {
    fn drop(&mut self) {
        // SAFETY: live directory descriptor this lock owns.
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

/// What a listener that stopped listening still holds: the transport
/// directory's lock, if it was bound as the facade, until this is dropped.
pub struct ListenerLock {
    _lock: Option<DirectoryLock>,
}

impl LocalListener {
    pub fn bind(endpoint: &LocalEndpoint) -> io::Result<Self> {
        private_parent(endpoint.as_path(), true)?;
        // Never unlink an existing endpoint, including a seemingly stale socket.
        let listener = UnixListener::bind(endpoint.as_path())?;
        fs::set_permissions(endpoint.as_path(), fs::Permissions::from_mode(0o600))?;
        validate_socket(endpoint.as_path())?;
        let metadata = fs::symlink_metadata(endpoint.as_path())?;
        Ok(Self {
            listener,
            path: endpoint.as_path().into(),
            device: metadata.dev(),
            inode: metadata.ino(),
            _directory_lock: None,
        })
    }

    /// Facade restart owns a kernel lock on the transport directory before
    /// reclaiming a dead socket. This writes no lock/Runtime record. The default
    /// foundation bind still refuses every occupied name unchanged.
    #[cfg(target_os = "macos")]
    pub fn bind_facade(endpoint: &LocalEndpoint) -> io::Result<Self> {
        private_parent(endpoint.as_path(), false)?;
        let parent = endpoint.as_path().parent().expect("validated parent");
        let lock = fs::File::open(parent)?;
        // SAFETY: live directory descriptor, nonblocking advisory transport lock.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(denied("another facade owns the public transport directory"));
        }
        match fs::symlink_metadata(endpoint.as_path()) {
            Ok(_) => {
                validate_socket(endpoint.as_path())?;
                match UnixStream::connect(endpoint.as_path()) {
                    Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
                        fs::remove_file(endpoint.as_path())?;
                    }
                    _ => return Err(denied("public transport endpoint is already occupied")),
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let lock = DirectoryLock(lock);
        let mut listener = Self::bind(endpoint)?;
        listener._directory_lock = Some(lock);
        Ok(listener)
    }

    pub fn accept(&mut self) -> io::Result<LocalConnection> {
        let (stream, _) = self.listener.accept()?;
        authenticate(&stream)?;
        Ok(LocalConnection(stream))
    }

    /// The next authenticated connection, or `None` once `stop` has been
    /// requested, whichever is ready first; a requested stop wins over a
    /// waiting connection, which is then never accepted.
    pub fn accept_until(&mut self, stop: &StopSignal) -> io::Result<Option<LocalConnection>> {
        loop {
            let mut descriptors = [
                libc::pollfd {
                    fd: stop.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: self.listener.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            // SAFETY: two live descriptors in writable storage; no timeout.
            if unsafe { libc::poll(descriptors.as_mut_ptr(), 2, -1) } < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if descriptors[0].revents != 0 {
                return Ok(None);
            }
            if descriptors[1].revents == 0 {
                continue;
            }
            // A connection its peer abandoned after poll leaves nothing to
            // accept: the listener must not block then.
            self.listener.set_nonblocking(true)?;
            let accepted = self.listener.accept();
            self.listener.set_nonblocking(false)?;
            match accepted {
                Ok((stream, _)) => {
                    // An accepted BSD socket inherits the listener's O_NONBLOCK.
                    stream.set_nonblocking(false)?;
                    authenticate(&stream)?;
                    return Ok(Some(LocalConnection(stream)));
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => continue,
                Err(error) => return Err(error),
            }
        }
    }

    /// Stops listening, as dropping the listener does: the socket is closed
    /// and this listener's own name removed, so a client is refused from now
    /// on. The transport directory's lock is handed back instead, to be
    /// released only once the owner has drained, so that no second owner
    /// starts while this one still answers.
    pub fn stop_listening(mut self) -> ListenerLock {
        ListenerLock {
            _lock: self._directory_lock.take(),
        }
    }
}

impl Drop for LocalListener {
    fn drop(&mut self) {
        // Only remove this listener's own inode; a replacement is never touched.
        if let Ok(metadata) = fs::symlink_metadata(&self.path)
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
            && metadata.file_type().is_socket()
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

pub struct LocalConnection(UnixStream);

impl LocalConnection {
    pub fn connect(endpoint: &LocalEndpoint, _identity: &ServerIdentity) -> io::Result<Self> {
        validate_socket(endpoint.as_path())?;
        let stream = UnixStream::connect(endpoint.as_path())?;
        authenticate(&stream)?;
        Ok(Self(stream))
    }

    /// A second handle that ends this connection from another thread.
    pub fn closer(&self) -> io::Result<ConnectionCloser> {
        Ok(ConnectionCloser(self.0.try_clone()?))
    }

    /// Waits until this connection has something to read (or its peer has
    /// gone, which the read then reports), the latch is set, or `timeout`
    /// passes; a set latch is seen first. Nothing is read.
    pub fn wait_readable(&self, latch: &Latch, timeout: Duration) -> io::Result<Readiness> {
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let wait = libc::c_int::try_from(left.as_millis()).unwrap_or(libc::c_int::MAX);
            let mut descriptors = [
                libc::pollfd {
                    fd: latch.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: self.0.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            // SAFETY: two live descriptors in writable storage.
            if unsafe { libc::poll(descriptors.as_mut_ptr(), 2, wait) } < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if descriptors[0].revents != 0 {
                return Ok(Readiness::Latched);
            }
            if descriptors[1].revents != 0 {
                return Ok(Readiness::Readable);
            }
            if Instant::now() >= deadline {
                return Ok(Readiness::TimedOut);
            }
        }
    }

    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.0.set_read_timeout(timeout)
    }

    pub fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.0.set_write_timeout(timeout)
    }
}

/// What [`LocalConnection::wait_readable`] saw first.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Readiness {
    Readable,
    Latched,
    TimedOut,
}

/// Ends a connection from outside the thread that serves it: both
/// directions are shut down, so a read waiting on it returns at once and a
/// later write fails.
pub struct ConnectionCloser(UnixStream);

impl ConnectionCloser {
    pub fn close(&self) {
        let _ = self.0.shutdown(Shutdown::Both);
    }
}

impl Read for LocalConnection {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        self.0.read(bytes)
    }
}

impl Write for LocalConnection {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0.write(bytes)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.0.flush()
    }
    fn write_vectored(&mut self, bytes: &[IoSlice<'_>]) -> io::Result<usize> {
        self.0.write_vectored(bytes)
    }
}

/// Unix platforms other than macOS remain a parser/contract shadow until their
/// commandless HDC listener inspection is ported. No HDC invocation is
/// permitted on missing proof; macOS proves it in `macos_server`.
#[cfg(not(target_os = "macos"))]
pub struct LoopbackServerLease;

#[cfg(not(target_os = "macos"))]
impl LoopbackServerLease {
    pub fn acquire(_tool: &VerifiedTool, _endpoint: SocketAddrV4) -> io::Result<Self> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "commandless existing HDC server identity is not implemented on this platform",
        ))
    }

    pub fn revalidate(&self) -> io::Result<()> {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "no server lease",
        ))
    }
}

impl AsRawFd for LocalConnection {
    fn as_raw_fd(&self) -> std::os::fd::RawFd {
        self.0.as_raw_fd()
    }
}
