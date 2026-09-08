use super::{Handle, bool_result, wide};
use crate::{ServerIdentity, denied};
use sha2::{Digest, Sha256};
use std::fs::File;
use std::io;
use std::mem::{offset_of, size_of};
use std::os::windows::ffi::OsStringExt;
use std::os::windows::io::AsRawHandle;
use std::path::PathBuf;
use std::ptr::null_mut;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Authorization::*;
use windows_sys::Win32::Security::WinTrust::*;
use windows_sys::Win32::Security::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::Storage::Packaging::Appx::GetPackageFamilyName;
use windows_sys::Win32::System::SystemServices::SE_GROUP_LOGON_ID;
use windows_sys::Win32::System::Threading::*;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct FileIdentity {
    volume: u64,
    index: [u8; 16],
}

pub(crate) fn file_identity(file: &File) -> io::Result<FileIdentity> {
    let mut info = FILE_ID_INFO::default();
    // SAFETY: file is live and the output structure has the documented size.
    bool_result(unsafe {
        GetFileInformationByHandleEx(
            file.as_raw_handle(),
            FileIdInfo,
            std::ptr::from_mut(&mut info).cast(),
            size_of::<FILE_ID_INFO>() as u32,
        )
    })?;
    Ok(FileIdentity {
        volume: info.VolumeSerialNumber,
        index: info.FileId.Identifier,
    })
}

pub(crate) fn reject_reparse_file(file: &File) -> io::Result<()> {
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    // SAFETY: live file handle and initialized output storage.
    bool_result(unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut info) })?;
    if info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY) != 0 {
        return Err(denied(
            "reparse points and directories cannot be executable identities",
        ));
    }
    Ok(())
}

/// Keep every physical ancestor non-deletable while CreateProcessW resolves
/// the application name. Denying deletion of the final file alone would still
/// permit an attacker to exchange a whole parent directory before spawn.
pub(crate) fn lock_namespace(path: &std::path::Path) -> io::Result<Vec<File>> {
    use std::os::windows::fs::OpenOptionsExt;
    use std::path::{Component, Prefix};
    if !matches!(path.components().next(), Some(Component::Prefix(prefix)) if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_)))
    {
        return Err(denied(
            "verified executable must be on an absolute local drive path",
        ));
    }
    let mut parents: Vec<_> = path
        .parent()
        .ok_or_else(|| denied("missing executable parent"))?
        .ancestors()
        .collect();
    parents.reverse();
    let mut held = Vec::new();
    for parent in parents {
        let directory = std::fs::OpenOptions::new()
            .access_mode(FILE_READ_ATTRIBUTES)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(parent)?;
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        // SAFETY: live directory handle and correctly sized output structure.
        bool_result(unsafe { GetFileInformationByHandle(directory.as_raw_handle(), &mut info) })?;
        if info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0
            || info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
        {
            return Err(denied(
                "executable namespace contains a reparse point or non-directory",
            ));
        }
        held.push(directory);
    }
    Ok(held)
}

pub(crate) struct LocalAllocation(pub *mut std::ffi::c_void);
impl Drop for LocalAllocation {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: exclusively owned result of a LocalAlloc-family API.
            unsafe {
                LocalFree(self.0);
            }
        }
    }
}

pub(crate) struct Sid(Vec<u32>);
impl Sid {
    fn copy(pointer: PSID) -> io::Result<Self> {
        // SAFETY: only called with pointers from a live token/security descriptor.
        if pointer.is_null() || unsafe { IsValidSid(pointer) } == 0 {
            return Err(denied("invalid security identifier"));
        }
        // SAFETY: the SID was validated above.
        let length = unsafe { GetLengthSid(pointer) };
        let mut storage = vec![0u32; (length as usize).div_ceil(size_of::<u32>())];
        // SAFETY: storage is aligned and large enough for length bytes.
        bool_result(unsafe { CopySid(length, storage.as_mut_ptr().cast(), pointer) })?;
        Ok(Self(storage))
    }

    fn pointer(&self) -> PSID {
        self.0.as_ptr().cast_mut().cast()
    }
    pub(crate) fn equals(&self, other: &Self) -> bool {
        // SAFETY: both buffers contain validated copied SIDs.
        unsafe { EqualSid(self.pointer(), other.pointer()) != 0 }
    }
    pub(crate) fn text(&self) -> io::Result<String> {
        let mut result = null_mut();
        // SAFETY: valid SID, output allocation is released below.
        bool_result(unsafe { ConvertSidToStringSidW(self.pointer(), &mut result) })?;
        let _allocation = LocalAllocation(result.cast());
        let mut length = 0;
        // SAFETY: successful API output is NUL-terminated UTF-16.
        unsafe {
            while *result.add(length) != 0 {
                length += 1;
            }
        }
        // SAFETY: determined length is within this API-owned string.
        Ok(String::from_utf16_lossy(unsafe {
            std::slice::from_raw_parts(result, length)
        }))
    }
}

pub(crate) struct Token(Handle);

struct TokenInformation {
    storage: Vec<usize>,
    length: usize,
}

impl TokenInformation {
    fn header<T: Copy>(&self) -> io::Result<T> {
        if self.length < size_of::<T>() {
            return Err(denied("truncated token information"));
        }
        // SAFETY: valid returned length covers this fixed-size header. Read a
        // value, not a reference to a struct containing a flexible array.
        Ok(unsafe { self.storage.as_ptr().cast::<T>().read_unaligned() })
    }

    fn groups(&self) -> io::Result<&[SID_AND_ATTRIBUTES]> {
        let count = self.header::<u32>()? as usize;
        if count == 0 {
            return Ok(&[]);
        }
        let offset = offset_of!(TOKEN_GROUPS, Groups);
        if self.length < offset || count > (self.length - offset) / size_of::<SID_AND_ATTRIBUTES>()
        {
            return Err(denied("invalid token group count"));
        }
        // SAFETY: usize-aligned storage and the documented member offset provide
        // SID_AND_ATTRIBUTES alignment; count is bounded by valid returned bytes.
        Ok(unsafe {
            std::slice::from_raw_parts(self.storage.as_ptr().cast::<u8>().add(offset).cast(), count)
        })
    }
}

impl Token {
    pub(crate) fn current() -> io::Result<Self> {
        // SAFETY: GetCurrentProcess is a borrowed pseudo-handle.
        Self::for_process(unsafe { GetCurrentProcess() })
    }
    fn for_process(process: HANDLE) -> io::Result<Self> {
        let mut token = null_mut();
        // SAFETY: process is live; returned token is taken into RAII ownership.
        bool_result(unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) })?;
        Ok(Self(Handle::new(token)?))
    }
    fn information(&self, kind: TOKEN_INFORMATION_CLASS) -> io::Result<TokenInformation> {
        let mut length = 0;
        // SAFETY: size query with null output is documented.
        unsafe {
            GetTokenInformation(self.0.raw(), kind, null_mut(), 0, &mut length);
        }
        if length == 0 || length > 1024 * 1024 {
            return Err(io::Error::last_os_error());
        }
        let capacity = length;
        let mut storage = vec![0usize; (capacity as usize).div_ceil(size_of::<usize>())];
        // SAFETY: storage is pointer-aligned and at least length bytes long.
        bool_result(unsafe {
            GetTokenInformation(
                self.0.raw(),
                kind,
                storage.as_mut_ptr().cast(),
                capacity,
                &mut length,
            )
        })?;
        if length > capacity {
            return Err(denied("token information exceeds allocated buffer"));
        }
        Ok(TokenInformation {
            storage,
            length: length as usize,
        })
    }
    pub(crate) fn owner(&self) -> io::Result<Sid> {
        let storage = self.information(TokenOwner)?;
        Sid::copy(storage.header::<TOKEN_OWNER>()?.Owner)
    }
    fn user(&self) -> io::Result<Sid> {
        let storage = self.information(TokenUser)?;
        Sid::copy(storage.header::<TOKEN_USER>()?.User.Sid)
    }
    fn elevated(&self) -> io::Result<bool> {
        let storage = self.information(TokenElevation)?;
        Ok(storage.header::<TOKEN_ELEVATION>()?.TokenIsElevated != 0)
    }
    pub(crate) fn logon(&self) -> io::Result<Sid> {
        let storage = self.information(TokenGroups)?;
        for group in storage.groups()? {
            if group.Attributes & SE_GROUP_LOGON_ID as u32 == SE_GROUP_LOGON_ID as u32 {
                return Sid::copy(group.Sid);
            }
        }
        Err(denied("token has no logon SID"))
    }
}

pub(crate) fn require_pipe_owner(pipe: HANDLE) -> io::Result<()> {
    let mut owner = null_mut();
    let mut descriptor = null_mut();
    // SAFETY: live pipe handle; GetSecurityInfo allocates the security descriptor.
    let status = unsafe {
        GetSecurityInfo(
            pipe,
            SE_KERNEL_OBJECT,
            OWNER_SECURITY_INFORMATION,
            &mut owner,
            null_mut(),
            null_mut(),
            null_mut(),
            &mut descriptor,
        )
    };
    let _allocation = LocalAllocation(descriptor);
    if status != ERROR_SUCCESS {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    if !Sid::copy(owner)?.equals(&Token::current()?.owner()?) {
        return Err(denied(
            "pipe owner SID differs from the client token owner; zero frames sent",
        ));
    }
    Ok(())
}

pub(crate) struct ProcessIdentity {
    pub(crate) process: Handle,
    pub(crate) image: File,
    pub(crate) pid: u32,
    pub(crate) started: u64,
    pub(crate) path: PathBuf,
    _namespace: Vec<File>,
}

impl ProcessIdentity {
    pub(crate) fn open(pid: u32) -> io::Result<Self> {
        // SAFETY: query-only process access, owned handle is retained.
        let process = Handle::new(unsafe {
            OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, 0, pid)
        })?;
        Self::from_handle(process, pid)
    }
    pub(crate) fn from_handle(process: Handle, pid: u32) -> io::Result<Self> {
        let path = process_image(process.raw())?.canonicalize()?;
        let namespace = lock_namespace(&path)?;
        let image = crate::process::open_locked_file(&path)?;
        let identity = Self {
            started: process_started(process.raw())?,
            process,
            image,
            pid,
            path,
            _namespace: namespace,
        };
        identity.require_live()?;
        Ok(identity)
    }
    pub(crate) fn require_live(&self) -> io::Result<()> {
        // SAFETY: the retained process handle has SYNCHRONIZE access. Exit code
        // 259 is legal and must not be mistaken for a still-running process.
        if unsafe { WaitForSingleObject(self.process.raw(), 0) } != WAIT_TIMEOUT
            || process_started(self.process.raw())? != self.started
        {
            return Err(denied("authenticated peer process exited or changed"));
        }
        Ok(())
    }
    pub(crate) fn require_client_user(&self) -> io::Result<()> {
        let peer = Token::for_process(self.process.raw())?;
        let current = Token::current()?;
        if !peer.user()?.equals(&current.user()?) || peer.elevated()? != current.elevated()? {
            return Err(denied(
                "pipe client user SID or elevation differs from daemon",
            ));
        }
        Ok(())
    }
    pub(crate) fn require_server(&self, expected: &ServerIdentity) -> io::Result<()> {
        if !expected.executable.is_absolute()
            || self.path.canonicalize()? != expected.executable.canonicalize()?
        {
            return Err(denied(
                "pipe server image differs from installed daemon; zero frames sent",
            ));
        }
        let installed = crate::process::open_locked_file(&expected.executable)?;
        if file_identity(&installed)? != file_identity(&self.image)? {
            return Err(denied(
                "installed daemon file identity differs from server image",
            ));
        }
        let package_matches = match &expected.package_family {
            Some(family) => {
                !family.is_empty()
                    && package_family(self.process.raw())
                        .as_ref()
                        .is_ok_and(|actual| actual == family)
            }
            None => false,
        };
        let signature_matches = match &expected.authenticode_sha256 {
            Some(pin) => verify_signature(&self.image, &self.path, pin).is_ok(),
            None => false,
        };
        if !package_matches && !signature_matches {
            return Err(denied(
                "pipe server lacks the installed package or trusted signing identity; zero frames sent",
            ));
        }
        self.require_live()
    }
}

pub(crate) fn process_image(process: HANDLE) -> io::Result<PathBuf> {
    let mut path = vec![0u16; 32768];
    let mut length = path.len() as u32;
    // SAFETY: writable UTF-16 buffer with supplied capacity.
    bool_result(unsafe { QueryFullProcessImageNameW(process, 0, path.as_mut_ptr(), &mut length) })?;
    Ok(PathBuf::from(std::ffi::OsString::from_wide(
        &path[..length as usize],
    )))
}

fn process_started(process: HANDLE) -> io::Result<u64> {
    let (mut creation, mut exit, mut kernel, mut user) = (
        FILETIME::default(),
        FILETIME::default(),
        FILETIME::default(),
        FILETIME::default(),
    );
    // SAFETY: four valid FILETIME output pointers and a live process handle.
    bool_result(unsafe {
        GetProcessTimes(process, &mut creation, &mut exit, &mut kernel, &mut user)
    })?;
    Ok((u64::from(creation.dwHighDateTime) << 32) | u64::from(creation.dwLowDateTime))
}

fn package_family(process: HANDLE) -> io::Result<String> {
    let mut length = 0;
    // SAFETY: documented buffer length query.
    let status = unsafe { GetPackageFamilyName(process, &mut length, null_mut()) };
    if status != ERROR_INSUFFICIENT_BUFFER || length == 0 || length > 4096 {
        return Err(denied("server has no expected MSIX package identity"));
    }
    let mut output = vec![0u16; length as usize];
    // SAFETY: output buffer is large enough for the queried length.
    let status = unsafe { GetPackageFamilyName(process, &mut length, output.as_mut_ptr()) };
    if status != ERROR_SUCCESS {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    Ok(String::from_utf16_lossy(&output[..length as usize - 1]))
}

fn verify_signature(file: &File, path: &std::path::Path, pin: &str) -> io::Result<()> {
    if pin.len() != 64
        || !pin
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(denied("invalid installed signer certificate SHA256"));
    }
    let path = wide(path.as_os_str())?;
    let mut file_info = WINTRUST_FILE_INFO {
        cbStruct: size_of::<WINTRUST_FILE_INFO>() as u32,
        pcwszFilePath: path.as_ptr(),
        hFile: file.as_raw_handle(),
        ..Default::default()
    };
    let mut data = WINTRUST_DATA {
        cbStruct: size_of::<WINTRUST_DATA>() as u32,
        dwUIChoice: WTD_UI_NONE,
        fdwRevocationChecks: WTD_REVOKE_WHOLECHAIN,
        dwUnionChoice: WTD_CHOICE_FILE,
        Anonymous: WINTRUST_DATA_0 {
            pFile: &mut file_info,
        },
        dwStateAction: WTD_STATEACTION_VERIFY,
        dwProvFlags: WTD_CACHE_ONLY_URL_RETRIEVAL | WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT,
        ..Default::default()
    };
    let mut action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    // SAFETY: file/path/data remain alive throughout verify, inspect and close.
    let result = unsafe {
        let status = WinVerifyTrust(
            INVALID_HANDLE_VALUE,
            &mut action,
            std::ptr::from_mut(&mut data).cast(),
        );
        let verified = if status == 0 {
            let provider = WTHelperProvDataFromStateData(data.hWVTStateData);
            let signer = if provider.is_null() {
                null_mut()
            } else {
                WTHelperGetProvSignerFromChain(provider, 0, 0, 0)
            };
            let certificate = if signer.is_null() {
                null_mut()
            } else {
                WTHelperGetProvCertFromChain(signer, 0)
            };
            if certificate.is_null() || (*certificate).pCert.is_null() {
                false
            } else {
                let context = &*(*certificate).pCert;
                let bytes = std::slice::from_raw_parts(
                    context.pbCertEncoded,
                    context.cbCertEncoded as usize,
                );
                format!("{:x}", Sha256::digest(bytes)) == pin
            }
        } else {
            false
        };
        data.dwStateAction = WTD_STATEACTION_CLOSE;
        WinVerifyTrust(
            INVALID_HANDLE_VALUE,
            &mut action,
            std::ptr::from_mut(&mut data).cast(),
        );
        verified
    };
    if !result {
        return Err(denied(
            "daemon Authenticode trust or publisher certificate pin failed",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_headers_and_flexible_arrays_use_returned_length() {
        let mut information = TokenInformation {
            storage: vec![0; 8],
            length: 0,
        };
        assert!(information.header::<TOKEN_OWNER>().is_err());
        assert!(information.groups().is_err());
        information.length = size_of::<u32>();
        assert!(information.groups().unwrap().is_empty());
        information.storage[0] = 1;
        assert!(information.groups().is_err());
        information.length = offset_of!(TOKEN_GROUPS, Groups) + size_of::<SID_AND_ATTRIBUTES>();
        assert_eq!(information.groups().unwrap().len(), 1);
        information.length -= 1;
        assert!(information.groups().is_err());
    }

    #[test]
    fn exited_process_with_code_259_is_not_live() {
        struct SuspendedChild(Handle);
        impl Drop for SuspendedChild {
            fn drop(&mut self) {
                // SAFETY: exact test child handle, never the caller or a reused PID.
                unsafe {
                    TerminateProcess(self.0.raw(), 259);
                }
            }
        }
        let application = wide(std::env::current_exe().unwrap().as_os_str()).unwrap();
        let startup = STARTUPINFOW {
            cb: size_of::<STARTUPINFOW>() as u32,
            ..Default::default()
        };
        let mut info = PROCESS_INFORMATION::default();
        // SAFETY: current test image starts suspended, so no test or other child
        // code runs. Its process and thread handles immediately gain RAII owners.
        bool_result(unsafe {
            CreateProcessW(
                application.as_ptr(),
                null_mut(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                CREATE_SUSPENDED | CREATE_NO_WINDOW,
                std::ptr::null(),
                std::ptr::null(),
                &startup,
                &mut info,
            )
        })
        .unwrap();
        let child = SuspendedChild(Handle::new(info.hProcess).unwrap());
        let _thread = Handle::new(info.hThread).unwrap();
        let identity = ProcessIdentity::open(info.dwProcessId).unwrap();
        identity.require_live().unwrap();
        // SAFETY: test-owned suspended process; 259 is a valid final exit code.
        bool_result(unsafe { TerminateProcess(child.0.raw(), 259) }).unwrap();
        // SAFETY: retained process handle remains valid after its exit.
        assert_eq!(
            unsafe { WaitForSingleObject(child.0.raw(), 5000) },
            WAIT_OBJECT_0
        );
        assert_eq!(
            identity.require_live().unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
    }
}
