//! NTFS primitives under the durable host store (TASK-XPA-005): the Windows
//! spellings of the POSIX calls `host_store.rs` makes, measured on NTFS by
//! SPK-5. Every open is relative to a held directory handle (`NtCreateFile`
//! with a root directory, the `openat` of Windows), never follows a reparse
//! point (`FILE_OPEN_REPARSE_POINT` plus an attribute check, the `O_NOFOLLOW`)
//! and shares read, write and delete, so a POSIX-semantics replace or delete
//! never fails because another reader holds the name, which keeps its bytes
//! as a Unix reader does. Locks are `LockFileEx` on one byte far beyond any
//! end of file: the lock is mandatory on Windows, so it never covers a byte
//! anyone reads. Owner-only means the owner SID is the token user and the
//! DACL grants nobody else anything, the Windows reading of mode `0600`/`0700`.
use super::identity::{LocalAllocation, Sid, Token};
use super::{bool_result, wide};
use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::mem::{offset_of, size_of};
use std::os::windows::ffi::OsStringExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle};
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};
use std::sync::OnceLock;
use windows_sys::Wdk::Foundation::OBJECT_ATTRIBUTES;
use windows_sys::Wdk::Storage::FileSystem::{
    FILE_DIRECTORY_FILE, FILE_NON_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_REPARSE_POINT,
    FILE_RENAME_INFORMATION, FILE_RENAME_POSIX_SEMANTICS, FILE_SYNCHRONOUS_IO_NONALERT,
    FileRenameInformationEx, NtCreateFile, NtSetInformationFile,
};
use windows_sys::Win32::Foundation::{
    ERROR_LOCK_VIOLATION, ERROR_NO_MORE_FILES, ERROR_STOPPED_ON_SYMLINK, GENERIC_ALL,
    GENERIC_EXECUTE, GENERIC_READ, GENERIC_WRITE, HANDLE, OBJ_CASE_INSENSITIVE,
    RtlNtStatusToDosError, UNICODE_STRING,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SDDL_REVISION_1,
    SE_FILE_OBJECT, SetSecurityInfo,
};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, DACL_SECURITY_INFORMATION, EqualSid, GetAce,
    INHERIT_ONLY_ACE, OWNER_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION,
    PSECURITY_DESCRIPTOR, SECURITY_DESCRIPTOR,
};
use windows_sys::Win32::Storage::FileSystem::{
    DELETE, FILE_ADD_FILE, FILE_ADD_SUBDIRECTORY, FILE_ALL_ACCESS, FILE_APPEND_DATA,
    FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT, FILE_BASIC_INFO, FILE_DELETE_CHILD,
    FILE_DISPOSITION_FLAG_DELETE, FILE_DISPOSITION_FLAG_POSIX_SEMANTICS, FILE_DISPOSITION_INFO_EX,
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_FULL_DIR_INFO,
    FILE_GENERIC_EXECUTE, FILE_GENERIC_READ, FILE_GENERIC_WRITE, FILE_ID_INFO, FILE_LIST_DIRECTORY,
    FILE_READ_ATTRIBUTES, FILE_READ_DATA, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
    FILE_STANDARD_INFO, FILE_TRAVERSE, FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA, FILE_WRITE_EA,
    FileBasicInfo, FileDispositionInfoEx, FileFullDirectoryInfo, FileFullDirectoryRestartInfo,
    FileIdInfo, FileStandardInfo, FlushFileBuffers, GetFileInformationByHandleEx,
    GetFinalPathNameByHandleW, LOCKFILE_EXCLUSIVE_LOCK, LOCKFILE_FAIL_IMMEDIATELY, LockFileEx,
    READ_CONTROL, SYNCHRONIZE, SetFileInformationByHandle, UnlockFileEx, VOLUME_NAME_DOS,
    VOLUME_NAME_GUID, WRITE_DAC, WRITE_OWNER, WriteFile,
};
use windows_sys::Win32::System::IO::OVERLAPPED;

const FILE_RENAME_REPLACE_IF_EXISTS: u32 = 0x1;
const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;
const ACCESS_DENIED_ACE_TYPE: u8 = 1;
/// The one byte every host-store lock covers: far beyond the end of any file
/// the store writes, so the mandatory lock never refuses a reader of data
/// (SPK-5: a locked range refuses reads through every other handle).
const LOCK_OFFSET: u64 = u64::MAX - 1;
/// Everything an access-control entry for someone other than the owner may
/// not grant under a "no group or other write" rule (Unix `0o022`).
const WRITE_RIGHTS: u32 = FILE_WRITE_DATA
    | FILE_APPEND_DATA
    | FILE_WRITE_EA
    | FILE_WRITE_ATTRIBUTES
    | FILE_DELETE_CHILD
    | DELETE
    | WRITE_DAC
    | WRITE_OWNER;

/// Shared by every handle the store opens: another holder never makes a
/// replace or delete fail, and never loses the bytes it opened (SPK-5).
pub(crate) const SHARE_ALL: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
/// Read a document's bytes, attributes and security.
pub(crate) const READ: u32 = FILE_READ_DATA | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE;
/// Inspect an entry without reading its bytes.
pub(crate) const INSPECT: u32 = FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE;
/// Read and write a document, flush it and rename or delete it.
pub(crate) const WRITE: u32 = READ | FILE_WRITE_DATA | FILE_APPEND_DATA | DELETE;
/// A held directory: enumerate, traverse and inspect it.
pub(crate) const DIRECTORY: u32 =
    FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE;
/// A held directory the store writes in: also add entries, which is what
/// `FlushFileBuffers` needs of a directory handle (SPK-5: a read-only
/// directory handle is refused). A handle cannot gain this access later by
/// reopening itself, so it is taken when the directory is opened.
pub(crate) const DIRECTORY_WRITE: u32 = DIRECTORY | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Directory,
    NonDirectory,
    Any,
}

pub(crate) fn fail() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "host snapshot refused")
}

/// One name inside a held directory, as UTF-16 without a terminator. Beyond
/// the Unix rule (not empty, `.`, `..` or containing a separator) every
/// character NTFS reserves is refused, `:` above all, which would name an
/// alternate data stream of the entry instead of the entry.
pub(crate) fn segment(name: &str) -> io::Result<Vec<u16>> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name
            .chars()
            .any(|c| matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') || c < ' ')
    {
        return Err(fail());
    }
    Ok(OsStr::new(name).encode_wide_vec())
}

trait EncodeWide {
    fn encode_wide_vec(&self) -> Vec<u16>;
}
impl EncodeWide for OsStr {
    fn encode_wide_vec(&self) -> Vec<u16> {
        use std::os::windows::ffi::OsStrExt;
        self.encode_wide().collect()
    }
}

fn nt_result(status: i32) -> io::Result<()> {
    if status < 0 {
        // SAFETY: a pure status-code translation.
        return Err(io::Error::from_raw_os_error(
            unsafe { RtlNtStatusToDosError(status) } as i32,
        ));
    }
    Ok(())
}

/// A private security descriptor: owner the token user, a protected DACL
/// granting that user alone full access (inherited by children when it is
/// a directory's). Unix creates the same entries `0600`/`0700`.
pub(crate) struct Descriptor(LocalAllocation);
impl Descriptor {
    pub(crate) fn private(directory: bool) -> io::Result<Self> {
        let user = user_text()?;
        let inherit = if directory { "OICI" } else { "" };
        Self::from_sddl(&format!("O:{user}D:P(A;{inherit};FA;;;{user})"))
    }
    /// Owner read only (Unix `0400`), for a sealed payload.
    fn sealed() -> io::Result<Self> {
        let user = user_text()?;
        Self::from_sddl(&format!("D:P(A;;FR;;;{user})"))
    }
    fn from_sddl(sddl: &str) -> io::Result<Self> {
        let sddl = wide(OsStr::new(sddl))?;
        let mut descriptor = null_mut();
        // SAFETY: NUL-terminated SDDL; the allocation is owned below.
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
    pub(crate) fn raw(&self) -> PSECURITY_DESCRIPTOR {
        self.0.0
    }
}

fn user() -> io::Result<&'static Sid> {
    static USER: OnceLock<Option<Sid>> = OnceLock::new();
    USER.get_or_init(|| Token::current().and_then(|token| token.user()).ok())
        .as_ref()
        .ok_or_else(|| io::Error::other("the process token names no user"))
}

fn user_text() -> io::Result<String> {
    user()?.text()
}

/// `openat` of Windows: `name` opened relative to `parent` (an empty name
/// reopens `parent` itself), never through a reparse point, with every
/// share mode. `security` applies only when the entry is created.
pub(crate) fn open_relative(
    parent: &File,
    name: &[u16],
    access: u32,
    disposition: u32,
    kind: Kind,
    security: Option<&Descriptor>,
) -> io::Result<File> {
    let file = nt_open(parent, name, access, disposition, kind, security)?;
    refuse_reparse(&file)?;
    Ok(file)
}

/// `fstatat(AT_SYMLINK_NOFOLLOW)`'s open: an entry opened for its attributes
/// and security only, a reparse point as itself.
pub(crate) fn inspect_relative(parent: &File, name: &[u16]) -> io::Result<File> {
    nt_open(parent, name, INSPECT, FILE_OPEN, Kind::Any, None)
}

fn nt_open(
    parent: &File,
    name: &[u16],
    access: u32,
    disposition: u32,
    kind: Kind,
    security: Option<&Descriptor>,
) -> io::Result<File> {
    let bytes = u16::try_from(name.len() * 2).map_err(|_| fail())?;
    let object = UNICODE_STRING {
        Length: bytes,
        MaximumLength: bytes,
        Buffer: name.as_ptr().cast_mut(),
    };
    let attributes = OBJECT_ATTRIBUTES {
        Length: size_of::<OBJECT_ATTRIBUTES>() as u32,
        RootDirectory: parent.as_raw_handle(),
        ObjectName: &object,
        Attributes: OBJ_CASE_INSENSITIVE,
        SecurityDescriptor: security.map_or(null(), |d| d.raw().cast::<SECURITY_DESCRIPTOR>()),
        SecurityQualityOfService: null(),
    };
    let options = FILE_OPEN_REPARSE_POINT
        | FILE_SYNCHRONOUS_IO_NONALERT
        | match kind {
            Kind::Directory => FILE_DIRECTORY_FILE,
            Kind::NonDirectory => FILE_NON_DIRECTORY_FILE,
            Kind::Any => 0,
        };
    let mut handle: HANDLE = null_mut();
    // SAFETY: zeroed storage is a valid IO_STATUS_BLOCK output.
    let mut status_block = unsafe { std::mem::zeroed() };
    // SAFETY: every pointer names a live local for the duration of the call;
    // a successful call returns a new handle this function takes ownership of.
    nt_result(unsafe {
        NtCreateFile(
            &mut handle,
            access | SYNCHRONIZE,
            &attributes,
            &mut status_block,
            null(),
            0,
            SHARE_ALL,
            disposition,
            options,
            null(),
            0,
        )
    })?;
    // SAFETY: NtCreateFile succeeded, so `handle` is a new owned handle.
    Ok(unsafe { File::from_raw_handle(handle) })
}

/// `open(path, O_DIRECTORY | O_NOFOLLOW)`: the directory at an absolute
/// path, its last component not followed.
pub(crate) fn open_directory_path(path: &Path, access: u32) -> io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .access_mode(access)
        .share_mode(SHARE_ALL)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    refuse_reparse(&file)?;
    Ok(file)
}

fn refuse_reparse(file: &File) -> io::Result<()> {
    if basic(file)?.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::from_raw_os_error(
            ERROR_STOPPED_ON_SYMLINK as i32,
        ));
    }
    Ok(())
}

fn information<T: Default>(file: &File, class: i32) -> io::Result<T> {
    let mut value = T::default();
    // SAFETY: a live handle and an output of exactly the class's size.
    bool_result(unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle(),
            class,
            std::ptr::from_mut(&mut value).cast(),
            size_of::<T>() as u32,
        )
    })?;
    Ok(value)
}

fn basic(file: &File) -> io::Result<FILE_BASIC_INFO> {
    information(file, FileBasicInfo)
}

/// What `fstat` answers, from one handle: the volume serial and 128-bit
/// file id (`FileIdInfo`, SPK-5: stable across opens and in-place writes;
/// the dev/ino of Windows), size, link count, kind, and the last-write and
/// change times in 100 ns ticks since 1601.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Stat {
    pub(crate) volume: u64,
    pub(crate) id: [u8; 16],
    pub(crate) size: u64,
    pub(crate) links: u32,
    pub(crate) attributes: u32,
    pub(crate) written: i64,
    pub(crate) changed: i64,
}

impl Stat {
    pub(crate) fn of(file: &File) -> io::Result<Self> {
        let id: FILE_ID_INFO = information(file, FileIdInfo)?;
        let basic = basic(file)?;
        let standard: FILE_STANDARD_INFO = information(file, FileStandardInfo)?;
        Ok(Self {
            volume: id.VolumeSerialNumber,
            id: id.FileId.Identifier,
            size: u64::try_from(standard.EndOfFile).map_err(|_| fail())?,
            links: standard.NumberOfLinks,
            attributes: basic.FileAttributes,
            written: basic.LastWriteTime,
            changed: basic.ChangeTime,
        })
    }
    pub(crate) fn directory(&self) -> bool {
        self.attributes & FILE_ATTRIBUTE_DIRECTORY != 0 && !self.reparse()
    }
    pub(crate) fn regular(&self) -> bool {
        self.attributes & FILE_ATTRIBUTE_DIRECTORY == 0 && !self.reparse()
    }
    fn reparse(&self) -> bool {
        self.attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
    }
    /// The 64-bit inode the host store reports: NTFS file ids are 64-bit
    /// file references zero-extended to 128 bits. A volume whose ids use the
    /// upper half (ReFS) cannot be reported without losing uniqueness, so it
    /// is refused rather than folded.
    pub(crate) fn inode(&self) -> io::Result<u64> {
        if self.id[8..] != [0; 8] {
            return Err(fail());
        }
        Ok(u64::from_le_bytes(
            self.id[..8].try_into().map_err(|_| fail())?,
        ))
    }
    pub(crate) fn same_file(&self, other: &Self) -> bool {
        (self.volume, self.id) == (other.volume, other.id)
    }
    /// Size and both times: what a write or any metadata change moves.
    pub(crate) fn same_content(&self, other: &Self) -> bool {
        (self.size, self.written, self.changed) == (other.size, other.written, other.changed)
    }
}

/// 100 ns ticks since 1601 as seconds and nanoseconds since 1970.
pub(crate) fn unix_time(ticks: i64) -> (i64, i64) {
    let since_1970 = ticks - 116_444_736_000_000_000;
    (
        since_1970.div_euclid(10_000_000),
        since_1970.rem_euclid(10_000_000) * 100,
    )
}

/// Who may do what to an entry, read from its owner and DACL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Access {
    pub(crate) owner_is_user: bool,
    /// Rights the DACL grants the token user (allowed minus denied).
    pub(crate) user: u32,
    /// Rights the DACL grants anyone else; a NULL DACL grants everything.
    pub(crate) others: u32,
    /// The owner is the token user or one of the [`TRUSTED_PRINCIPALS`]
    /// (the Unix "owned by this user or by root").
    pub(crate) owner_trusted: bool,
    /// Rights the DACL grants anyone but the token user and the
    /// [`TRUSTED_PRINCIPALS`]: the Unix group and other bits of an entry
    /// that may be owned by root.
    pub(crate) untrusted: u32,
}

/// The principals that hold the Unix root's place on Windows: `SYSTEM`, the
/// `Administrators` group and `TrustedInstaller`. What an installer puts
/// under `Program Files` is owned and writable by these alone; they can
/// read and replace any file anyway (backup and restore privileges), so a
/// grant to them changes nothing a caller could rely on.
pub(crate) const TRUSTED_PRINCIPALS: [&str; 3] = [
    "S-1-5-18",
    "S-1-5-32-544",
    "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464",
];

fn trusted_principal(sid: &Sid) -> bool {
    sid.text()
        .is_ok_and(|text| TRUSTED_PRINCIPALS.contains(&text.as_str()))
}

impl Access {
    pub(crate) fn of(file: &File) -> io::Result<Self> {
        let mut owner = null_mut();
        let mut dacl: *mut ACL = null_mut();
        let mut descriptor = null_mut();
        // SAFETY: a live handle opened with READ_CONTROL; the returned
        // pointers point into `descriptor`, which is freed below.
        let status = unsafe {
            GetSecurityInfo(
                file.as_raw_handle(),
                SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                &mut owner,
                null_mut(),
                &mut dacl,
                null_mut(),
                &mut descriptor,
            )
        };
        let _descriptor = LocalAllocation(descriptor);
        if status != 0 {
            return Err(io::Error::from_raw_os_error(status as i32));
        }
        let user = user()?;
        let owner = Sid::copy(owner)?;
        let owner_is_user = owner.equals(user);
        let owner_trusted = owner_is_user || trusted_principal(&owner);
        if dacl.is_null() {
            return Ok(Self {
                owner_is_user,
                user: FILE_ALL_ACCESS,
                others: FILE_ALL_ACCESS,
                owner_trusted,
                untrusted: FILE_ALL_ACCESS,
            });
        }
        let (mut allowed, mut denied, mut others, mut untrusted) = (0, 0, 0, 0);
        // SAFETY: a valid ACL returned by GetSecurityInfo.
        let count = unsafe { (*dacl).AceCount };
        for index in 0..u32::from(count) {
            let mut ace = null_mut();
            // SAFETY: index is below the ACL's own count.
            bool_result(unsafe { GetAce(dacl, index, &mut ace) })?;
            // SAFETY: every ACE starts with its header.
            let header = unsafe { *ace.cast::<ACE_HEADER>() };
            if u32::from(header.AceFlags) & INHERIT_ONLY_ACE != 0 {
                continue;
            }
            match header.AceType {
                ACCESS_ALLOWED_ACE_TYPE | ACCESS_DENIED_ACE_TYPE => {}
                // Object and callback entries are not what the store writes
                // and cannot be read as a plain grant: refuse the entry.
                _ => {
                    return Ok(Self {
                        owner_is_user,
                        user: 0,
                        others: FILE_ALL_ACCESS,
                        owner_trusted,
                        untrusted: FILE_ALL_ACCESS,
                    });
                }
            }
            // SAFETY: both kinds share the ACCESS_ALLOWED_ACE layout; the
            // SID starts at SidStart inside the ACE.
            let (mask, sid) = unsafe {
                let entry = ace.cast::<ACCESS_ALLOWED_ACE>();
                (
                    (*entry).Mask,
                    ace.cast::<u8>()
                        .add(offset_of!(ACCESS_ALLOWED_ACE, SidStart)),
                )
            };
            let mask = generic(mask);
            // SAFETY: a SID inside a valid ACE and the cached user SID.
            let is_user = unsafe { EqualSid(sid.cast(), user.pointer()) } != 0;
            match (header.AceType, is_user) {
                (ACCESS_ALLOWED_ACE_TYPE, true) => allowed |= mask & !denied,
                (ACCESS_ALLOWED_ACE_TYPE, false) => {
                    others |= mask;
                    if !trusted_principal(&Sid::copy(sid.cast())?) {
                        untrusted |= mask;
                    }
                }
                (_, true) => denied |= mask,
                (_, false) => {}
            }
        }
        Ok(Self {
            owner_is_user,
            user: allowed,
            others,
            owner_trusted,
            untrusted,
        })
    }
    /// Unix "owned by this user or root, `mode & 0o022 == 0`": the owner is
    /// trusted and nobody else may change the entry.
    pub(crate) fn trusted_write_only(&self) -> bool {
        self.owner_trusted && self.untrusted & WRITE_RIGHTS == 0
    }
    /// [`Self::trusted_write_only`] of a directory others may only add
    /// entries to (the Unix sticky `/tmp`, or `/Applications`): adding an
    /// entry never replaces, renames or removes one that exists.
    pub(crate) fn trusted_write_only_but_add(&self) -> bool {
        self.owner_trusted
            && self.untrusted & WRITE_RIGHTS & !(FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY) == 0
    }
    /// Unix "owned by this user, `mode & 0o077 == 0`" where root still reads
    /// everything: owned by the token user and nobody but the user and the
    /// trusted principals is granted anything.
    pub(crate) fn owner_private(&self) -> bool {
        self.owner_is_user && self.untrusted == 0
    }
    /// Unix `mode & 0o077 == 0`: nobody but the owner is granted anything.
    pub(crate) fn private(&self) -> bool {
        self.others == 0
    }
    /// Unix `mode & 0o022 == 0`: nobody but the owner may change it.
    pub(crate) fn no_public_write(&self) -> bool {
        self.others & WRITE_RIGHTS == 0
    }
    /// Unix owner `rw-` on a file: the owner may read and write its data.
    pub(crate) fn owner_read_write(&self) -> bool {
        self.user & (FILE_READ_DATA | FILE_WRITE_DATA) == FILE_READ_DATA | FILE_WRITE_DATA
    }
    /// Unix owner `rwx` on a directory: list, traverse, add and remove.
    pub(crate) fn owner_full_directory(&self) -> bool {
        let needed = FILE_LIST_DIRECTORY
            | FILE_TRAVERSE
            | FILE_ADD_FILE
            | FILE_ADD_SUBDIRECTORY
            | FILE_DELETE_CHILD;
        self.user & needed == needed
    }
}

fn generic(mask: u32) -> u32 {
    let mut mapped = mask & !(GENERIC_ALL | GENERIC_READ | GENERIC_WRITE | GENERIC_EXECUTE);
    if mask & GENERIC_ALL != 0 {
        mapped |= FILE_ALL_ACCESS;
    }
    if mask & GENERIC_READ != 0 {
        mapped |= FILE_GENERIC_READ;
    }
    if mask & GENERIC_WRITE != 0 {
        mapped |= FILE_GENERIC_WRITE;
    }
    if mask & GENERIC_EXECUTE != 0 {
        mapped |= FILE_GENERIC_EXECUTE;
    }
    mapped
}

/// Make an entry owner-only (`chmod 0700`/`0400` of Windows): its DACL
/// replaced by a protected one. The owner is never changed here.
pub(crate) fn set_dacl(file: &File, descriptor: &Descriptor) -> io::Result<()> {
    let mut present = 0;
    let mut dacl = null_mut();
    let mut defaulted = 0;
    // SAFETY: a valid self-relative descriptor built from SDDL.
    bool_result(unsafe {
        windows_sys::Win32::Security::GetSecurityDescriptorDacl(
            descriptor.raw(),
            &mut present,
            &mut dacl,
            &mut defaulted,
        )
    })?;
    if present == 0 || dacl.is_null() {
        return Err(fail());
    }
    // SAFETY: a live handle opened with WRITE_DAC and a valid ACL.
    let status = unsafe {
        SetSecurityInfo(
            file.as_raw_handle(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            null_mut(),
            null_mut(),
            dacl,
            null(),
        )
    };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    Ok(())
}

/// The sealed-payload DACL: owner read only.
pub(crate) fn seal(file: &File) -> io::Result<()> {
    set_dacl(file, &Descriptor::sealed()?)
}

/// `fsync`/`F_FULLFSYNC` of Windows: `FlushFileBuffers`, which writes the
/// file's data and metadata through the device cache.
pub(crate) fn flush(file: &File) -> io::Result<()> {
    // SAFETY: a live handle opened with write access.
    bool_result(unsafe { FlushFileBuffers(file.as_raw_handle()) })
}

/// A directory's namespace barrier: `FlushFileBuffers` on the held
/// directory handle, which must have been opened with [`DIRECTORY_WRITE`].
pub(crate) fn flush_directory(directory: &File) -> io::Result<()> {
    flush(directory)
}

/// `renameat` (`replace`) or `renameatx_np(RENAME_EXCL)`: the entry `source`
/// is open on, given the name `name` in `directory`, with POSIX semantics
/// so a target another handle holds is still replaced (SPK-5). The source
/// handle must have been opened with DELETE access. `NtSetInformationFile`
/// is called directly: the Win32 `SetFileInformationByHandle` refuses a
/// rename relative to a root directory handle (`ERROR_INVALID_PARAMETER`).
pub(crate) fn rename(
    source: &File,
    directory: &File,
    name: &[u16],
    replace: bool,
) -> io::Result<()> {
    let header = offset_of!(FILE_RENAME_INFORMATION, FileName);
    let size = header + name.len() * 2 + 2;
    let mut buffer = vec![0u64; size.div_ceil(8)];
    let info = buffer.as_mut_ptr().cast::<FILE_RENAME_INFORMATION>();
    // SAFETY: the u64 buffer is aligned for, and at least as large as, the
    // header plus the name and its terminator.
    unsafe {
        (*info).Anonymous.Flags = FILE_RENAME_POSIX_SEMANTICS
            | if replace {
                FILE_RENAME_REPLACE_IF_EXISTS
            } else {
                0
            };
        (*info).RootDirectory = directory.as_raw_handle();
        (*info).FileNameLength = (name.len() * 2) as u32;
        std::ptr::copy_nonoverlapping(name.as_ptr(), (*info).FileName.as_mut_ptr(), name.len());
    }
    // SAFETY: zeroed storage is a valid IO_STATUS_BLOCK output.
    let mut status_block = unsafe { std::mem::zeroed() };
    // SAFETY: a live source handle and the rename information built above.
    nt_result(unsafe {
        NtSetInformationFile(
            source.as_raw_handle(),
            &mut status_block,
            info.cast(),
            size as u32,
            FileRenameInformationEx,
        )
    })
}

/// `unlinkat` of the entry `file` is open on (opened with DELETE access),
/// with POSIX semantics: its name is gone when this handle closes, even
/// while other handles still read it.
pub(crate) fn delete(file: &File) -> io::Result<()> {
    let info = FILE_DISPOSITION_INFO_EX {
        Flags: FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS,
    };
    // SAFETY: a live handle and a correctly sized disposition.
    bool_result(unsafe {
        SetFileInformationByHandle(
            file.as_raw_handle(),
            FileDispositionInfoEx,
            std::ptr::from_ref(&info).cast(),
            size_of::<FILE_DISPOSITION_INFO_EX>() as u32,
        )
    })
}

/// `unlinkat(directory, name, directory ? AT_REMOVEDIR : 0)`.
pub(crate) fn unlink(directory: &File, name: &[u16], kind: Kind) -> io::Result<()> {
    let entry = open_relative(
        directory,
        name,
        DELETE | FILE_READ_ATTRIBUTES,
        FILE_OPEN,
        kind,
        None,
    )?;
    delete(&entry)
}

/// `flock(LOCK_EX)` of Windows on the store's lock byte: `Ok(false)` when
/// `wait` is not set and another handle holds it.
pub(crate) fn lock(file: &File, wait: bool) -> io::Result<bool> {
    let mut overlapped = overlapped(LOCK_OFFSET);
    let flags = LOCKFILE_EXCLUSIVE_LOCK | if wait { 0 } else { LOCKFILE_FAIL_IMMEDIATELY };
    // SAFETY: a live synchronous handle and a live OVERLAPPED naming the
    // offset; a synchronous handle completes before the call returns.
    if unsafe { LockFileEx(file.as_raw_handle(), flags, 0, 1, 0, &mut overlapped) } != 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    if !wait && error.raw_os_error() == Some(ERROR_LOCK_VIOLATION as i32) {
        return Ok(false);
    }
    Err(error)
}

pub(crate) fn unlock(file: &File) {
    let mut overlapped = overlapped(LOCK_OFFSET);
    // SAFETY: a live handle; unlocking a range this handle holds.
    unsafe {
        UnlockFileEx(file.as_raw_handle(), 0, 1, 0, &mut overlapped);
    }
}

fn overlapped(offset: u64) -> OVERLAPPED {
    let mut overlapped = OVERLAPPED::default();
    overlapped.Anonymous.Anonymous.Offset = offset as u32;
    overlapped.Anonymous.Anonymous.OffsetHigh = (offset >> 32) as u32;
    overlapped
}

/// `write` on an `O_APPEND` descriptor: every byte written at the end of
/// the file as it is at the time of the write, whatever the handle's
/// position (the documented 0xFFFFFFFF/0xFFFFFFFF offset).
pub(crate) fn append_all(file: &File, mut bytes: &[u8]) -> io::Result<()> {
    while !bytes.is_empty() {
        let mut overlapped = overlapped(u64::MAX);
        let chunk = bytes.len().min(1 << 30) as u32;
        let mut written = 0;
        // SAFETY: a live synchronous handle, a readable buffer of `chunk`
        // bytes and a live OVERLAPPED naming end of file.
        bool_result(unsafe {
            WriteFile(
                file.as_raw_handle(),
                bytes.as_ptr(),
                chunk,
                &mut written,
                &mut overlapped,
            )
        })?;
        if written == 0 {
            return Err(io::ErrorKind::WriteZero.into());
        }
        bytes = &bytes[written as usize..];
    }
    Ok(())
}

/// The names in a held directory (without `.` and `..`), read through a
/// fresh handle so each enumeration starts at its own beginning.
pub(crate) fn names(directory: &File, maximum: usize) -> io::Result<Vec<String>> {
    // Measured: a reopen asking for FILE_LIST_DIRECTORY alone is refused
    // (ERROR_ACCESS_DENIED) where one with the held directory's read rights
    // is granted.
    let listing = open_relative(directory, &[], DIRECTORY, FILE_OPEN, Kind::Directory, None)?;
    let mut names = Vec::new();
    let mut buffer = vec![0u64; 8192];
    let mut class = FileFullDirectoryRestartInfo;
    loop {
        // SAFETY: a live directory handle and a writable, aligned buffer.
        let listed = unsafe {
            GetFileInformationByHandleEx(
                listing.as_raw_handle(),
                class,
                buffer.as_mut_ptr().cast(),
                (buffer.len() * 8) as u32,
            )
        };
        if listed == 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(ERROR_NO_MORE_FILES as i32) {
                break;
            }
            return Err(error);
        }
        class = FileFullDirectoryInfo;
        let mut offset = 0usize;
        loop {
            let base = buffer.as_ptr().cast::<u8>();
            // SAFETY: the system wrote a chain of entries inside `buffer`;
            // each entry's name length stays within it.
            let (next, name) = unsafe {
                let entry = base.add(offset).cast::<FILE_FULL_DIR_INFO>();
                let length = (*entry).FileNameLength as usize / 2;
                let name = std::slice::from_raw_parts(
                    base.add(offset + offset_of!(FILE_FULL_DIR_INFO, FileName))
                        .cast::<u16>(),
                    length,
                );
                ((*entry).NextEntryOffset as usize, name)
            };
            let name = String::from_utf16(name).map_err(|_| fail())?;
            if name != "." && name != ".." {
                if names.len() >= maximum {
                    return Err(fail());
                }
                names.push(name);
            }
            if next == 0 {
                break;
            }
            offset += next;
        }
    }
    names.sort();
    Ok(names)
}

/// The path the system reports for an open handle: `\\?\D:\…` (DOS) or
/// `\\?\Volume{…}\…` (GUID), without resolving anything the handle does not
/// already name.
pub(crate) fn final_path(file: &File, guid: bool) -> io::Result<PathBuf> {
    let mut buffer = vec![0u16; 32768];
    let flags = if guid {
        VOLUME_NAME_GUID
    } else {
        VOLUME_NAME_DOS
    };
    // SAFETY: a live handle and a writable buffer of the stated length.
    let length = unsafe {
        GetFinalPathNameByHandleW(
            file.as_raw_handle(),
            buffer.as_mut_ptr(),
            buffer.len() as u32,
            flags,
        )
    } as usize;
    if length == 0 || length >= buffer.len() {
        return Err(io::Error::last_os_error());
    }
    Ok(PathBuf::from(std::ffi::OsString::from_wide(
        &buffer[..length],
    )))
}

/// The Unix `path.canonicalize()? == path` rule: an absolute local path
/// whose opened directory the system names with exactly this spelling, so
/// no component is a link, a junction, a short name or a different case.
/// Both the plain (`D:\…`) and the verbatim (`\\?\D:\…`) spelling qualify.
pub(crate) fn canonical(path: &Path, opened: &File) -> io::Result<()> {
    use std::path::{Component, Prefix};
    let local = matches!(
        path.components().next(),
        Some(Component::Prefix(prefix))
            if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_))
    );
    if !local || !path.is_absolute() {
        return Err(fail());
    }
    let reported = final_path(opened, false)?;
    let plain = reported
        .as_os_str()
        .to_str()
        .and_then(|text| text.strip_prefix(r"\\?\"))
        .map(PathBuf::from);
    if reported != path && plain.as_deref() != Some(path) {
        return Err(fail());
    }
    Ok(())
}

/// Create `path` and every missing ancestor with the private directory
/// descriptor (Unix `DirBuilder::new().recursive(true).mode(0o700)`).
/// Existing levels are left as they are.
pub(crate) fn create_private_directories(path: &Path) -> io::Result<()> {
    use windows_sys::Win32::Security::SECURITY_ATTRIBUTES;
    use windows_sys::Win32::Storage::FileSystem::CreateDirectoryW;
    let mut missing = Vec::new();
    let mut current = Some(path);
    while let Some(level) = current {
        match std::fs::symlink_metadata(level) {
            Ok(metadata) if metadata.is_dir() => break,
            Ok(_) => return Err(io::ErrorKind::AlreadyExists.into()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => missing.push(level),
            Err(error) => return Err(error),
        }
        current = level.parent();
    }
    let descriptor = Descriptor::private(true)?;
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: descriptor.raw(),
        bInheritHandle: 0,
    };
    for level in missing.into_iter().rev() {
        let name = wide(level.as_os_str())?;
        // SAFETY: a NUL-terminated path and live security attributes.
        if unsafe { CreateDirectoryW(name.as_ptr(), &attributes) } == 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error);
            }
        }
    }
    Ok(())
}
