use super::publisher::{self, PublisherIdentity};
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

impl FileIdentity {
    /// The volume serial and the 128-bit file id, in lowercase hexadecimal:
    /// a name for this file that no path spelling or rename changes.
    pub(crate) fn text(&self) -> String {
        let index: String = self
            .index
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        format!("{:016x}-{index}", self.volume)
    }
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
    pub(crate) fn copy(pointer: PSID) -> io::Result<Self> {
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

    pub(crate) fn pointer(&self) -> PSID {
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
    pub(crate) fn user(&self) -> io::Result<Sid> {
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

/// Whether the kernel object or file behind `handle` is owned by this
/// process's user SID (the handle needs `READ_CONTROL`).
pub(crate) fn owned_by_current_user(handle: HANDLE, kind: SE_OBJECT_TYPE) -> io::Result<bool> {
    let mut owner = null_mut();
    let mut descriptor = null_mut();
    // SAFETY: live handle; GetSecurityInfo allocates the security descriptor,
    // which the allocation guard releases.
    let status = unsafe {
        GetSecurityInfo(
            handle,
            kind,
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
    Ok(Sid::copy(owner)?.equals(&Token::current()?.user()?))
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
        // A partial or malformed publisher identity refuses the server
        // outright, whatever else is configured (maintainer ruling 17).
        let pins = SignerPins::configured(expected)?;
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
        let signature_matches =
            !pins.is_empty() && verify_signature(&self.image, &self.path, &pins).is_ok();
        if !package_matches && !signature_matches {
            return Err(denied(
                "pipe server lacks the installed package or trusted signing identity; zero frames sent",
            ));
        }
        self.require_live()
    }
}

/// What vouches for an installed daemon image before it runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ImagePin {
    /// The image's Authenticode signature satisfies a signing pin: the
    /// development signer's certificate SHA-256 or the production publisher
    /// identity (maintainer ruling 17).
    Signer,
    /// A package family is pinned; only a running process has one, so it is
    /// proved on the pipe server after the start, never before.
    PackageFamily,
}

/// An installed daemon image checked before it is started, held so that it
/// is the file started: its path's directories cannot be renamed and the
/// file cannot be written or deleted while this lives.
pub(crate) struct VerifiedImage {
    pub(crate) pin: ImagePin,
    pub(crate) path: PathBuf,
    _file: File,
    _namespace: Vec<File>,
}

/// Checks the pinned daemon image as a file: an absolute local path, a
/// regular file, and, when a signing pin is configured (certificate SHA-256
/// or publisher identity), a trusted Authenticode signature that satisfies
/// it; otherwise a package family, proved later on the running server. A
/// partial or malformed publisher identity, or no identity at all, refuses.
pub(crate) fn verify_installed_image(expected: &ServerIdentity) -> io::Result<VerifiedImage> {
    // Read before anything is opened: a partial publisher identity refuses
    // whatever else is configured (maintainer ruling 17).
    let pins = SignerPins::configured(expected)?;
    if !expected.executable.is_absolute() {
        return Err(denied("the installed daemon path must be absolute"));
    }
    let path = expected.executable.canonicalize()?;
    let namespace = lock_namespace(&path)?;
    let file = crate::process::open_locked_file(&path)?;
    let family = expected
        .package_family
        .as_deref()
        .is_some_and(|family| !family.is_empty());
    let pin = if !pins.is_empty() {
        match verify_signature(&file, &path, &pins) {
            Ok(()) => ImagePin::Signer,
            Err(_) if family => ImagePin::PackageFamily,
            Err(error) => return Err(error),
        }
    } else if family {
        ImagePin::PackageFamily
    } else {
        return Err(denied(
            "no installed daemon identity is configured (a signer certificate SHA-256, a              publisher identity or a package family)",
        ));
    };
    Ok(VerifiedImage {
        pin,
        path,
        _file: file,
        _namespace: namespace,
    })
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

pub(crate) fn process_started(process: HANDLE) -> io::Result<u64> {
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

/// The signing pins configured for an installed daemon: the development
/// signer's certificate SHA-256, and the production xcopy daemon's publisher
/// identity (maintainer ruling 17). Either that is configured may vouch for
/// the image; the package family is checked separately on the process.
pub(crate) struct SignerPins {
    certificate: Option<String>,
    publisher: Option<PublisherIdentity>,
}

impl SignerPins {
    /// Reads the pins from the installation inputs. A publisher identity with
    /// only one of its two values, or a malformed one, is an error: the
    /// caller refuses with zero frames rather than falling back.
    pub(crate) fn configured(expected: &ServerIdentity) -> io::Result<Self> {
        Ok(Self {
            certificate: expected.authenticode_sha256.clone(),
            publisher: PublisherIdentity::from_config(
                expected.publisher_organization.as_deref(),
                expected.publisher_eku.as_deref(),
            )?,
        })
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.certificate.is_none() && self.publisher.is_none()
    }
}

/// `WinVerifyTrust` (generic Authenticode policy, whole-chain revocation from
/// cache only, root excluded) must accept the image, and its verified signer
/// chain must then satisfy one configured pin: the leaf certificate's SHA-256
/// for the development signer, or the publisher identity for Artifact Signing.
fn verify_signature(file: &File, path: &std::path::Path, pins: &SignerPins) -> io::Result<()> {
    if pins.is_empty() {
        return Err(denied("no daemon signing identity is configured"));
    }
    if let Some(pin) = &pins.certificate
        && (pin.len() != 64
            || !pin
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
    {
        return Err(denied("invalid installed signer certificate SHA256"));
    }
    let chain = trusted_signer_chain(file, path)?;
    let certificate_matches = pins.certificate.as_ref().is_some_and(|pin| {
        chain
            .first()
            .is_some_and(|leaf| format!("{:x}", Sha256::digest(leaf)) == *pin)
    });
    let publisher_matches = pins.publisher.as_ref().is_some_and(|publisher| {
        publisher::chain_matches(&chain, publisher::ARTIFACT_SIGNING_ROOT_SHA256, publisher)
    });
    if !certificate_matches && !publisher_matches {
        return Err(denied(
            "daemon Authenticode trust or publisher identity pin failed",
        ));
    }
    Ok(())
}

/// The DER certificates, leaf first and root last, of the first signer of an
/// image that `WinVerifyTrust` accepted; an error when it did not.
fn trusted_signer_chain(file: &File, path: &std::path::Path) -> io::Result<Vec<Vec<u8>>> {
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
    // SAFETY: file/path/data remain alive throughout verify, inspect and close;
    // the certificates are copied out before the state is closed.
    let chain = unsafe {
        let status = WinVerifyTrust(
            INVALID_HANDLE_VALUE,
            &mut action,
            std::ptr::from_mut(&mut data).cast(),
        );
        let mut chain = Vec::new();
        if status == 0 {
            let provider = WTHelperProvDataFromStateData(data.hWVTStateData);
            let signer = if provider.is_null() {
                null_mut()
            } else {
                WTHelperGetProvSignerFromChain(provider, 0, 0, 0)
            };
            let count = if signer.is_null() {
                0
            } else {
                (*signer).csCertChain
            };
            for index in 0..count {
                let certificate = WTHelperGetProvCertFromChain(signer, index);
                if certificate.is_null() || (*certificate).pCert.is_null() {
                    chain.clear();
                    break;
                }
                let context = &*(*certificate).pCert;
                chain.push(
                    std::slice::from_raw_parts(
                        context.pbCertEncoded,
                        context.cbCertEncoded as usize,
                    )
                    .to_vec(),
                );
            }
        }
        data.dwStateAction = WTD_STATEACTION_CLOSE;
        WinVerifyTrust(
            INVALID_HANDLE_VALUE,
            &mut action,
            std::ptr::from_mut(&mut data).cast(),
        );
        chain
    };
    if chain.is_empty() {
        return Err(denied("daemon Authenticode trust failed"));
    }
    Ok(chain)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROFILE_EKU: &str = "1.3.6.1.4.1.311.97.990309390.766961637.194916062.941502583";

    fn pins(
        certificate: Option<&str>,
        organization: Option<&str>,
        eku: Option<&str>,
    ) -> SignerPins {
        let mut identity = ServerIdentity::new("C:\\unused.exe");
        identity.authenticode_sha256 = certificate.map(str::to_owned);
        identity.publisher_organization = organization.map(str::to_owned);
        identity.publisher_eku = eku.map(str::to_owned);
        SignerPins::configured(&identity).unwrap()
    }

    /// A copy of a small system executable in a private temporary directory,
    /// removed on drop.
    struct Copy(PathBuf);
    impl Copy {
        fn new(tag: &str) -> Self {
            let directory = std::env::temp_dir().join(format!(
                "arkdeck-publisher-{tag}-{}-{}",
                std::process::id(),
                crate::random_bytes::<8>()
                    .unwrap()
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<String>()
            ));
            std::fs::create_dir(&directory).unwrap();
            let system = PathBuf::from(std::env::var_os("SystemRoot").unwrap());
            let path = directory.join("daemon.exe");
            std::fs::copy(system.join("System32").join("whoami.exe"), &path).unwrap();
            Self(path)
        }
        fn verify(&self, pins: &SignerPins) -> io::Result<()> {
            let file = File::open(&self.0)?;
            verify_signature(&file, &self.0, pins)
        }
    }
    impl Drop for Copy {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(self.0.parent().unwrap());
        }
    }

    #[test]
    fn partial_publisher_configuration_is_refused_whatever_else_is_set() {
        let mut identity = ServerIdentity::new("C:\\unused.exe");
        identity.authenticode_sha256 = Some("0".repeat(64));
        identity.package_family = Some("Contoso.ArkDeck_8wekyb3d8bbwe".into());
        identity.publisher_organization = Some("Contoso Ltd".into());
        assert!(SignerPins::configured(&identity).is_err());
        identity.publisher_organization = None;
        identity.publisher_eku = Some(PROFILE_EKU.into());
        assert!(SignerPins::configured(&identity).is_err());
        identity.publisher_eku = None;
        assert!(!SignerPins::configured(&identity).unwrap().is_empty());
        assert!(pins(None, None, None).is_empty());
    }

    #[test]
    fn an_unsigned_image_satisfies_no_pin() {
        let copy = Copy::new("unsigned");
        assert!(copy.verify(&pins(None, None, None)).is_err());
        assert!(
            copy.verify(&pins(Some(&"0".repeat(64)), None, None))
                .is_err()
        );
        assert!(
            copy.verify(&pins(None, Some("Contoso Ltd"), Some(PROFILE_EKU)))
                .is_err()
        );
    }

    /// The `WinVerifyTrust`-integrated path with the host-trusted development
    /// signer (`rust/scripts/windows-dev-identity.ps1`, whose thumbprint CI
    /// exports as `ARKDECK_DEV_SIGNER_THUMBPRINT`): its certificate pin is
    /// accepted exactly as before, and a publisher identity is not satisfied
    /// by a trusted chain that does not end at the Artifact Signing root.
    #[test]
    fn the_development_signer_keeps_its_certificate_pin() {
        let Some(thumbprint) = std::env::var_os("ARKDECK_DEV_SIGNER_THUMBPRINT") else {
            eprintln!("ARKDECK_DEV_SIGNER_THUMBPRINT is not set; the signed path is not exercised");
            return;
        };
        let copy = Copy::new("signed");
        let script = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../scripts/windows-dev-identity.ps1");
        // PowerShell 7 from PATH, else its App Execution Alias (as
        // check-readonly.py finds it).
        let alias = std::env::var_os("LOCALAPPDATA")
            .map(|local| PathBuf::from(local).join("Microsoft\\WindowsApps\\pwsh.exe"))
            .filter(|alias| alias.exists());
        let pwsh = std::env::var_os("PATH")
            .and_then(|paths| {
                std::env::split_paths(&paths)
                    .map(|directory| directory.join("pwsh.exe"))
                    .find(|candidate| candidate.is_file())
            })
            .or(alias)
            .expect("PowerShell 7 signs the development daemon copy");
        let output = std::process::Command::new(pwsh)
            .args(["-NoProfile", "-NonInteractive", "-File"])
            .arg(&script)
            .arg("sign")
            .arg("-Thumbprint")
            .arg(&thumbprint)
            .arg("-Path")
            .arg(&copy.0)
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        let stdout = String::from_utf8(output.stdout).unwrap();
        let pin = stdout
            .split('"')
            .skip_while(|part| *part != "pin")
            .nth(2)
            .expect("the signing script prints the pin")
            .to_owned();
        assert_eq!(pin.len(), 64, "{stdout}");

        copy.verify(&pins(Some(&pin), None, None)).unwrap();
        assert!(
            copy.verify(&pins(Some(&"0".repeat(64)), None, None))
                .is_err()
        );
        // Uppercase or otherwise malformed pins are refused, as before.
        assert!(
            copy.verify(&pins(Some(&pin.to_uppercase()), None, None))
                .is_err()
        );
        // The development chain is trusted, but it is not the Artifact
        // Signing root, so no publisher identity matches it ...
        assert!(
            copy.verify(&pins(
                None,
                Some("ArkDeck Development Daemon (host-trusted only)"),
                Some(PROFILE_EKU)
            ))
            .is_err()
        );
        // ... and configuring one beside the certificate pin changes nothing
        // for the development signer.
        copy.verify(&pins(Some(&pin), Some("Contoso Ltd"), Some(PROFILE_EKU)))
            .unwrap();
    }

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

    /// The `WinVerifyTrust`-integrated publisher path against a real Artifact
    /// Signing Public Trust signature, when the host has one:
    /// `ARKDECK_PUBLISHER_SAMPLE` names a signed executable and
    /// `ARKDECK_PUBLISHER_SAMPLE_ORGANIZATION` / `_EKU` its publisher (for
    /// example the GitHub CLI's `gh.exe`, `GitHub, Inc.`). The file is only
    /// opened and verified, never run.
    #[test]
    fn a_real_artifact_signing_publisher_is_matched_through_winverifytrust() {
        let (Some(sample), Some(organization), Some(eku)) = (
            std::env::var_os("ARKDECK_PUBLISHER_SAMPLE"),
            std::env::var("ARKDECK_PUBLISHER_SAMPLE_ORGANIZATION").ok(),
            std::env::var("ARKDECK_PUBLISHER_SAMPLE_EKU").ok(),
        ) else {
            eprintln!("ARKDECK_PUBLISHER_SAMPLE is not set; no real publisher is exercised");
            return;
        };
        let path = PathBuf::from(sample);
        let verify = |pins: &SignerPins| {
            let file = File::open(&path)?;
            verify_signature(&file, &path, pins)
        };
        verify(&pins(None, Some(&organization), Some(&eku))).unwrap();
        assert!(verify(&pins(None, Some("Contoso Ltd"), Some(&eku))).is_err());
        assert!(verify(&pins(None, Some(&organization), Some(PROFILE_EKU))).is_err());
        // Its leaf is short-lived: a certificate pin on it is exactly what
        // ruling 17 retires, and a wrong one fails.
        assert!(verify(&pins(Some(&"0".repeat(64)), None, None)).is_err());
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
