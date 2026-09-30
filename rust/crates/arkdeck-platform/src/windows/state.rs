//! The Windows daemon's state root and single-instance guard (TASK-XPA-002,
//! the platform decision recorded in `rust/README.md` and the S5 run record).
//!
//! * The account's state root is `%LOCALAPPDATA%\ArkDeck\Agentd`, resolved by
//!   the Known Folder API for this process's token and never from the
//!   environment (as the macOS root is never taken from `HOME`). A directory
//!   this process creates there is owner-only: a protected DACL granting the
//!   user SID and SYSTEM, owned by the user SID. A root is opened as a
//!   directory handle that refuses a reparse point and must be owned by the
//!   user SID, and every directory from the drive down to the root is held
//!   open without delete sharing while the daemon runs, so no path it names
//!   under the root can be redirected by renaming an ancestor.
//! * The durable owner lock is `LockFileEx` on a separate lock file of the
//!   root (`instance.lock`; `.owner.lock` for an isolated development root),
//!   on a range beyond its end: NTFS locks are mandatory, so the lock never
//!   covers bytes anyone reads, and the kernel releases it when the holder
//!   dies (SPK-5).
//! * The single-instance guard (the profile's `SingleInstanceGuard`) is a
//!   named mutex in the session namespace, `Local\ArkDeck.Agentd.<user SID>`
//!   (`Local\ArkDeck.Agentd.Dev.<user SID>.<root file id>` for a development
//!   root), created with the same owner-only DACL. An existing object owned
//!   by anyone else refuses the start. It is thread-affine: the thread that
//!   takes it holds it for the life of the daemon, and `WAIT_ABANDONED` means
//!   the previous holder died with it.
use super::identity::{FileIdentity, Token, file_identity, lock_namespace, owned_by_current_user};
use super::{Handle, SecurityDescriptor, bool_result, wide};
use crate::{LocalEndpoint, denied, invalid};
use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{self, Read, Write};
use std::marker::PhantomData;
use std::mem::{offset_of, size_of};
use std::os::windows::ffi::OsStringExt;
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::ptr::null_mut;
use std::time::Duration;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Authorization::{SE_FILE_OBJECT, SE_KERNEL_OBJECT};
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::Com::CoTaskMemFree;
use windows_sys::Win32::System::IO::OVERLAPPED;
use windows_sys::Win32::System::Threading::*;
use windows_sys::Win32::UI::Shell::{FOLDERID_LocalAppData, KF_FLAG_DEFAULT, SHGetKnownFolderPath};

/// The product directory below the account's local application data, and
/// the daemon's state directory below it (design §D.2).
const PRODUCT: &str = "ArkDeck";
const STATE: &str = "Agentd";

/// `FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS`
/// (`winbase.h`): replace the target even while a reader holds it open with
/// delete sharing, which keeps its view (SPK-5).
const RENAME_REPLACE_POSIX: u32 = 0x1 | 0x2;

/// The owner lock's byte range: one byte far beyond any end of file, so the
/// mandatory lock never covers data.
const LOCK_OFFSET: u64 = 0x7fff_ffff_0000_0000;

/// `%LOCALAPPDATA%` as the Known Folder API resolves it for this process's
/// own token. The `LOCALAPPDATA` variable is not read.
fn local_application_data() -> io::Result<PathBuf> {
    let mut path = null_mut();
    // SAFETY: a documented known folder id, the default flags and the calling
    // thread's own token (null); the returned string is freed below.
    let status = unsafe {
        SHGetKnownFolderPath(
            &FOLDERID_LocalAppData,
            KF_FLAG_DEFAULT as u32,
            null_mut(),
            &mut path,
        )
    };
    let result = if status == 0 && !path.is_null() {
        let mut length = 0;
        // SAFETY: a successful call returns a NUL-terminated UTF-16 string.
        unsafe {
            while *path.add(length) != 0 {
                length += 1;
            }
        }
        // SAFETY: the length found above lies within that string.
        Ok(PathBuf::from(OsString::from_wide(unsafe {
            std::slice::from_raw_parts(path, length)
        })))
    } else {
        Err(io::Error::other(format!(
            "the local application data folder is unavailable (HRESULT {status:#010x})"
        )))
    };
    // SAFETY: the callee allocated `path` (or left it null) for the caller to free.
    unsafe { CoTaskMemFree(path.cast()) };
    result
}

/// `O:<user>D:P(A;OICI;FA;;;<user>)(A;OICI;FA;;;SY)`: owned by the user SID,
/// full access for that user and SYSTEM only, nothing inherited from above.
fn owner_only(container: bool) -> io::Result<SecurityDescriptor> {
    let user = Token::current()?.user()?.text()?;
    let inherit = if container { "OICI" } else { "" };
    SecurityDescriptor::from_sddl(&format!(
        "O:{user}D:P(A;{inherit};GA;;;{user})(A;{inherit};GA;;;SY)"
    ))
}

/// Creates `path` as an owner-only directory, or leaves an existing one as
/// it is for [`open_directory`] to judge.
fn create_private_directory(path: &Path) -> io::Result<()> {
    let security = owner_only(true)?;
    let attributes = security.attributes();
    let name = wide(path.as_os_str())?;
    // SAFETY: NUL-terminated path and a security descriptor alive for the call.
    if unsafe { CreateDirectoryW(name.as_ptr(), &attributes) } == 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(ERROR_ALREADY_EXISTS as i32) {
            return Err(error);
        }
    }
    Ok(())
}

/// A directory handle: never through a reparse point, owned by this user,
/// and writable, so that the directory itself can be flushed after a
/// rename in it (SPK-5).
fn open_directory(path: &Path) -> io::Result<File> {
    let directory = std::fs::OpenOptions::new()
        .access_mode(GENERIC_READ | GENERIC_WRITE)
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    // SAFETY: live handle and initialized output storage.
    bool_result(unsafe { GetFileInformationByHandle(directory.as_raw_handle(), &mut info) })?;
    if info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
        || info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
    {
        return Err(denied(
            "a daemon state root must be a directory, never a reparse point",
        ));
    }
    if !owned_by_current_user(directory.as_raw_handle(), SE_FILE_OBJECT)? {
        return Err(denied(
            "a daemon state root must be owned by the daemon's user",
        ));
    }
    Ok(directory)
}

/// The path the file system resolves this open handle to.
fn final_path(file: &File) -> io::Result<PathBuf> {
    let mut buffer = vec![0u16; 32768];
    // SAFETY: live handle and a writable buffer of the stated capacity.
    let length = unsafe {
        GetFinalPathNameByHandleW(
            file.as_raw_handle(),
            buffer.as_mut_ptr(),
            buffer.len() as u32,
            FILE_NAME_NORMALIZED | VOLUME_NAME_DOS,
        )
    } as usize;
    if length == 0 {
        return Err(io::Error::last_os_error());
    }
    if length >= buffer.len() {
        return Err(invalid("the state root's path is too long"));
    }
    Ok(PathBuf::from(OsString::from_wide(&buffer[..length])))
}

/// Where the daemon keeps its state, opened and pinned.
pub struct StateRoot {
    path: PathBuf,
    directory: File,
    identity: FileIdentity,
    development: bool,
    _namespace: Vec<File>,
}

impl StateRoot {
    /// The account's root, `%LOCALAPPDATA%\ArkDeck\Agentd`, and its product
    /// parent, each created owner-only if absent.
    pub fn account() -> io::Result<Self> {
        let product = local_application_data()?.join(PRODUCT);
        create_private_directory(&product)?;
        open_directory(&product)?;
        let state = product.join(STATE);
        create_private_directory(&state)?;
        Self::open(&state, false)
    }

    /// An isolated development root: an existing directory of this user,
    /// never the account's product directory or anything below it.
    /// Containment is decided on opened handles, by file identity, never by
    /// comparing path strings.
    pub fn development(root: &Path) -> io::Result<Self> {
        let opened = Self::open(root, true)?;
        let product = local_application_data()?.join(PRODUCT);
        let product = match std::fs::OpenOptions::new()
            .access_mode(FILE_READ_ATTRIBUTES)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
            .open(&product)
        {
            Ok(product) => Some(file_identity(&product)?),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        };
        if let Some(product) = product {
            // `_namespace` holds every ancestor open without delete sharing,
            // so this walk sees the directories the root stays below.
            let resolved = final_path(&opened.directory)?;
            for ancestor in resolved.ancestors() {
                let directory = std::fs::OpenOptions::new()
                    .access_mode(FILE_READ_ATTRIBUTES)
                    .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
                    .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
                    .open(ancestor)?;
                if file_identity(&directory)? == product {
                    return Err(denied(
                        "development state must be separate from installed ArkDeck state",
                    ));
                }
            }
        }
        Ok(opened)
    }

    fn open(path: &Path, development: bool) -> io::Result<Self> {
        if !path.is_absolute() {
            return Err(invalid("a daemon state root must be an absolute path"));
        }
        // Every directory from the drive down to the root, held open without
        // delete sharing: none can be renamed or replaced while the daemon runs.
        let namespace = lock_namespace(&path.join(STATE))?;
        let directory = open_directory(path)?;
        let identity = file_identity(&directory)?;
        Ok(Self {
            path: path.to_path_buf(),
            directory,
            identity,
            development,
            _namespace: namespace,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The name every kernel object of this root's daemon derives from.
    pub fn scope(&self) -> io::Result<InstanceScope> {
        let user = Token::current()?.user()?.text()?;
        Ok(InstanceScope(if self.development {
            format!("ArkDeck.Agentd.Dev.{user}.{}", self.identity.text())
        } else {
            format!("ArkDeck.Agentd.{user}")
        }))
    }

    /// The endpoint this root's daemon serves: the account's logon-scoped
    /// pipe, or for a development root one named after the root's identity
    /// (a pipe cannot live inside a directory).
    pub fn endpoint(&self) -> io::Result<LocalEndpoint> {
        if !self.development {
            return super::default_user_endpoint();
        }
        let logon = Token::current()?.logon()?.text()?;
        Ok(LocalEndpoint::new(format!(
            r"\\.\pipe\arkdeck-agentd-dev-{logon}-{}",
            self.identity.text()
        )))
    }

    /// The owner lock file this root is held by.
    pub fn owner_lock_name(&self) -> &'static str {
        if self.development {
            ".owner.lock"
        } else {
            "instance.lock"
        }
    }

    /// Takes this root's owner lock without waiting; `None` while another
    /// process holds it.
    pub fn lock_owner(&self) -> io::Result<Option<OwnerLock>> {
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .security_qos_flags(0)
            .open(self.path.join(self.owner_lock_name()))?;
        super::identity::reject_reparse_file(&file)?;
        let mut overlapped = OVERLAPPED::default();
        overlapped.Anonymous.Anonymous.Offset = LOCK_OFFSET as u32;
        overlapped.Anonymous.Anonymous.OffsetHigh = (LOCK_OFFSET >> 32) as u32;
        // SAFETY: live file handle and an OVERLAPPED naming the range; the
        // handle is synchronous, so the call completes before it returns.
        let locked = unsafe {
            LockFileEx(
                file.as_raw_handle(),
                LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                0,
                1,
                0,
                &mut overlapped,
            )
        };
        if locked == 0 {
            let error = io::Error::last_os_error();
            return if error.raw_os_error() == Some(ERROR_LOCK_VIOLATION as i32) {
                Ok(None)
            } else {
                Err(error)
            };
        }
        Ok(Some(OwnerLock(file)))
    }

    /// A document of this root, at most `limit` bytes; `None` if there is none.
    pub fn read_document(&self, name: &str, limit: u64) -> io::Result<Option<Vec<u8>>> {
        let file = match std::fs::OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(self.path.join(document_name(name)?))
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        super::identity::reject_reparse_file(&file)?;
        let mut bytes = Vec::new();
        file.take(limit).read_to_end(&mut bytes)?;
        Ok(Some(bytes))
    }

    /// Replaces a document of this root in one step: the bytes are written
    /// and flushed to a new file beside it, which is renamed over the
    /// document with POSIX semantics, and the directory is flushed. A reader
    /// sees the old document or the new one, never a mixture.
    pub fn publish_document(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        let name = document_name(name)?;
        let nonce = u64::from_le_bytes(crate::random_bytes()?);
        let staged = self.path.join(format!(".{name}.{nonce:016x}.tmp"));
        let security = owner_only(false)?;
        let attributes = security.attributes();
        let wide_staged = wide(staged.as_os_str())?;
        // SAFETY: NUL-terminated path, security attributes alive for the call;
        // the new handle is owned at once.
        let file = Handle::new(unsafe {
            CreateFileW(
                wide_staged.as_ptr(),
                GENERIC_WRITE | DELETE,
                FILE_SHARE_READ | FILE_SHARE_DELETE,
                &attributes,
                CREATE_NEW,
                FILE_ATTRIBUTE_NORMAL,
                null_mut(),
            )
        })?
        .into_file();
        let published = (|| {
            (&file).write_all(bytes)?;
            file.sync_all()?;
            rename_replacing(&file, &self.path.join(name))?;
            // SAFETY: the directory handle was opened with GENERIC_WRITE.
            bool_result(unsafe { FlushFileBuffers(self.directory.as_raw_handle()) })
        })();
        if published.is_err() {
            drop(file);
            let _ = std::fs::remove_file(&staged);
        }
        published
    }
}

/// Only a plain file name directly inside the root.
fn document_name(name: &str) -> io::Result<&str> {
    if name.is_empty() || name.contains(['\\', '/', ':']) || name == "." || name == ".." {
        return Err(invalid("a state document is named by a plain file name"));
    }
    Ok(name)
}

/// `SetFileInformationByHandle(FileRenameInfoEx)` with
/// [`RENAME_REPLACE_POSIX`], naming the target by its full path.
fn rename_replacing(file: &File, target: &Path) -> io::Result<()> {
    let name: Vec<u16> = wide(target.as_os_str())?;
    let name = &name[..name.len() - 1];
    let offset = offset_of!(FILE_RENAME_INFO, FileName);
    let length = offset + size_of_val(name) + size_of::<u16>();
    let mut storage = vec![0u64; length.div_ceil(size_of::<u64>())];
    let info = storage.as_mut_ptr().cast::<FILE_RENAME_INFO>();
    // SAFETY: the u64 storage is aligned for FILE_RENAME_INFO and holds its
    // header and the name with its NUL; each write stays inside it.
    unsafe {
        (*info).Anonymous.Flags = RENAME_REPLACE_POSIX;
        (*info).RootDirectory = null_mut();
        (*info).FileNameLength = size_of_val(name) as u32;
        std::ptr::copy_nonoverlapping(
            name.as_ptr(),
            storage.as_mut_ptr().cast::<u8>().add(offset).cast::<u16>(),
            name.len(),
        );
    }
    // SAFETY: live handle opened with DELETE access and the buffer above.
    bool_result(unsafe {
        SetFileInformationByHandle(
            file.as_raw_handle(),
            FileRenameInfoEx,
            storage.as_ptr().cast(),
            length as u32,
        )
    })
}

/// A held owner lock, released when dropped (and by the kernel at once if
/// the process dies).
pub struct OwnerLock(File);

impl Drop for OwnerLock {
    fn drop(&mut self) {
        let mut overlapped = OVERLAPPED::default();
        overlapped.Anonymous.Anonymous.Offset = LOCK_OFFSET as u32;
        overlapped.Anonymous.Anonymous.OffsetHigh = (LOCK_OFFSET >> 32) as u32;
        // SAFETY: the range this lock took on its own live handle.
        unsafe {
            UnlockFileEx(self.0.as_raw_handle(), 0, 1, 0, &mut overlapped);
        }
    }
}

/// The base name of one daemon's kernel objects, in the session namespace.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstanceScope(String);

impl InstanceScope {
    /// The single-instance guard's name.
    pub fn guard_name(&self) -> String {
        format!(r"Local\{}", self.0)
    }

    /// The stop event of the daemon with this process id.
    pub fn stop_event_name(&self, pid: u32) -> String {
        format!(r"Local\{}.Stop.{pid}", self.0)
    }

    /// Asks the daemon with this process id to stop and drain, as SIGTERM
    /// asks the Unix daemon: its stop event, which only this user can set,
    /// is set. Nothing else is signalled and no process is ended.
    pub fn request_stop(&self, pid: u32) -> io::Result<()> {
        let name = wide(OsStr::new(&self.stop_event_name(pid)))?;
        // SAFETY: NUL-terminated name; the handle is owned at once.
        let event = Handle::new(unsafe {
            OpenEventW(EVENT_MODIFY_STATE | READ_CONTROL, 0, name.as_ptr())
        })?;
        if !owned_by_current_user(event.raw(), SE_KERNEL_OBJECT)? {
            return Err(denied("the daemon's stop event is not this user's"));
        }
        // SAFETY: live event handle with EVENT_MODIFY_STATE.
        bool_result(unsafe { SetEvent(event.raw()) })
    }
}

/// What taking the single-instance guard found.
pub enum GuardAcquisition {
    /// This thread now holds the guard; `abandoned` if its previous holder
    /// died holding it.
    Owned {
        guard: SingleInstanceGuard,
        abandoned: bool,
    },
    /// Another daemon holds it.
    Held,
}

/// The held single-instance guard. It belongs to the thread that took it
/// (a mutex is thread-affine), so it can be neither sent nor shared; it is
/// released when dropped, and a process that ends holding it leaves it
/// abandoned for its successor.
pub struct SingleInstanceGuard {
    mutex: Handle,
    _thread: PhantomData<*const ()>,
}

/// The single-instance guard object of one scope, opened (created if no
/// one holds it open) but not taken. Holding it keeps the object, and so an
/// abandonment, alive for whoever takes it next.
pub struct GuardObject(Handle);

impl GuardObject {
    /// Opens the guard of `scope`. An existing guard object that is not this
    /// user's, or that this user may not open, refuses the start.
    pub fn open(scope: &InstanceScope) -> io::Result<Self> {
        let security = owner_only(false)?;
        let attributes = security.attributes();
        let name = wide(OsStr::new(&scope.guard_name()))?;
        // SAFETY: NUL-terminated name and security attributes alive for the
        // call; the handle is owned at once.
        let mutex = Handle::new(unsafe { CreateMutexW(&attributes, 0, name.as_ptr()) }).map_err(
            |error| {
                if error.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) {
                    io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "the single-instance guard exists and is not this user's; nothing was \
                         started",
                    )
                } else {
                    error
                }
            },
        )?;
        if !owned_by_current_user(mutex.raw(), SE_KERNEL_OBJECT)? {
            return Err(denied(
                "the single-instance guard is owned by another account; nothing was started",
            ));
        }
        Ok(Self(mutex))
    }

    /// Takes the guard on the calling thread, waiting at most `wait` for its
    /// holder to let it go: the daemon's own start does not wait; a
    /// successor handed over to may.
    pub fn acquire(self, wait: Duration) -> io::Result<GuardAcquisition> {
        let millis = wait.as_millis().min(u128::from(INFINITE - 1)) as u32;
        // SAFETY: live mutex handle with SYNCHRONIZE access.
        let abandoned = match unsafe { WaitForSingleObject(self.0.raw(), millis) } {
            WAIT_OBJECT_0 => false,
            WAIT_ABANDONED => true,
            WAIT_TIMEOUT => return Ok(GuardAcquisition::Held),
            _ => return Err(io::Error::last_os_error()),
        };
        Ok(GuardAcquisition::Owned {
            guard: SingleInstanceGuard {
                mutex: self.0,
                _thread: PhantomData,
            },
            abandoned,
        })
    }
}

impl SingleInstanceGuard {
    /// Opens the guard of `scope` and takes it on the calling thread
    /// ([`GuardObject::open`], [`GuardObject::acquire`]).
    pub fn acquire(scope: &InstanceScope, wait: Duration) -> io::Result<GuardAcquisition> {
        GuardObject::open(scope)?.acquire(wait)
    }
}

impl Drop for SingleInstanceGuard {
    fn drop(&mut self) {
        // SAFETY: this thread owns the mutex (the guard cannot leave it).
        unsafe {
            ReleaseMutex(self.mutex.raw());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Directory(PathBuf);
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn directory() -> Directory {
        let nonce = u64::from_le_bytes(crate::random_bytes().unwrap());
        let path = std::env::temp_dir().join(format!("ad-state-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        Directory(path)
    }

    #[test]
    fn the_account_folder_comes_from_the_known_folder_api() {
        let folder = local_application_data().unwrap();
        assert!(folder.is_absolute(), "{folder:?}");
        assert!(folder.is_dir(), "{folder:?}");
    }

    #[test]
    fn a_created_directory_is_owner_only_and_refuses_a_reparse_point() {
        let parent = directory();
        let private = parent.0.join("private");
        create_private_directory(&private).unwrap();
        // Idempotent over an existing directory.
        create_private_directory(&private).unwrap();
        let opened = open_directory(&private).unwrap();
        assert!(owned_by_current_user(opened.as_raw_handle(), SE_FILE_OBJECT).unwrap());
        let file = parent.0.join("file");
        std::fs::write(&file, b"x").unwrap();
        assert!(open_directory(&file).is_err());
    }

    #[test]
    fn the_owner_lock_excludes_a_second_holder_until_released() {
        let root = directory();
        let state = StateRoot::development(&root.0).unwrap();
        let held = state.lock_owner().unwrap().expect("first holder");
        // Mandatory NTFS locks refuse a second handle even in one process.
        assert!(state.lock_owner().unwrap().is_none());
        // The range is beyond the end of file: the file stays readable.
        std::fs::read(root.0.join(".owner.lock")).unwrap();
        drop(held);
        assert!(state.lock_owner().unwrap().is_some());
    }

    #[test]
    fn a_document_is_replaced_in_one_step_while_a_reader_holds_it() {
        let root = directory();
        let state = StateRoot::development(&root.0).unwrap();
        assert_eq!(state.read_document("instance.json", 64).unwrap(), None);
        state.publish_document("instance.json", b"first").unwrap();
        let reader = std::fs::File::open(root.0.join("instance.json")).unwrap();
        state.publish_document("instance.json", b"second").unwrap();
        let mut old = Vec::new();
        (&reader).read_to_end(&mut old).unwrap();
        assert_eq!(old, b"first");
        assert_eq!(
            state.read_document("instance.json", 64).unwrap().as_deref(),
            Some(&b"second"[..])
        );
        assert!(state.publish_document("../escape", b"x").is_err());
        let leftovers: Vec<_> = std::fs::read_dir(&root.0)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .filter(|name| name.to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }

    #[test]
    fn a_development_root_derives_its_own_scope_and_endpoint() {
        let first = directory();
        let second = directory();
        let one = StateRoot::development(&first.0).unwrap();
        let other = StateRoot::development(&second.0).unwrap();
        let scope = one.scope().unwrap();
        assert!(
            scope
                .guard_name()
                .starts_with(r"Local\ArkDeck.Agentd.Dev.S-1-")
        );
        assert_ne!(scope, other.scope().unwrap());
        assert_eq!(
            scope,
            StateRoot::development(&first.0).unwrap().scope().unwrap()
        );
        let endpoint = one.endpoint().unwrap();
        let name = endpoint.as_path().to_str().unwrap();
        assert!(
            name.starts_with(r"\\.\pipe\arkdeck-agentd-dev-S-1-5-5-"),
            "{name}"
        );
        super::super::endpoint_name(&endpoint).unwrap();
        assert!(StateRoot::development(Path::new("relative")).is_err());
    }

    #[test]
    fn the_guard_is_held_once_and_reads_abandoned_after_its_holder_dies() {
        let root = directory();
        let scope = StateRoot::development(&root.0).unwrap().scope().unwrap();
        let (taken, release) = (
            std::sync::mpsc::channel::<()>(),
            std::sync::mpsc::channel::<bool>(),
        );
        let holder = {
            let scope = scope.clone();
            let (taken, release) = (taken.0, release.1);
            std::thread::spawn(move || {
                let GuardAcquisition::Owned { guard, abandoned } =
                    SingleInstanceGuard::acquire(&scope, Duration::ZERO).unwrap()
                else {
                    panic!("the first holder found the guard held");
                };
                assert!(!abandoned);
                taken.send(()).unwrap();
                if release.recv().unwrap() {
                    drop(guard);
                } else {
                    // The thread ends holding it, as a daemon that dies does.
                    std::mem::forget(guard);
                }
            })
        };
        taken.1.recv().unwrap();
        assert!(matches!(
            SingleInstanceGuard::acquire(&scope, Duration::ZERO).unwrap(),
            GuardAcquisition::Held
        ));
        release.0.send(false).unwrap();
        holder.join().unwrap();
        let GuardAcquisition::Owned { guard, abandoned } =
            SingleInstanceGuard::acquire(&scope, Duration::ZERO).unwrap()
        else {
            panic!("an abandoned guard must be taken");
        };
        assert!(abandoned);
        drop(guard);
        let GuardAcquisition::Owned { abandoned, .. } =
            SingleInstanceGuard::acquire(&scope, Duration::ZERO).unwrap()
        else {
            panic!("a released guard must be taken");
        };
        assert!(!abandoned);
    }
}
