//! The system tools a Windows Runtime trusts for workspace operations
//! (TASK-XPA-011, maintainer ruling 69): `tar` is `System32\tar.exe`, the
//! Microsoft-signed bsdtar, and `git` is Git for Windows'
//! `Git\mingw64\bin\git.exe` under the Program Files Known Folder (the real
//! git, not the `cmd\git.exe` launcher, which would start a second image no
//! pin covers). Each is trusted by its registered absolute path and its
//! Authenticode publisher, never through `PATH` or an environment variable.
//!
//! [`trusted_system_tool`] measures a tool once, through one handle:
//!
//! * the path is the code-registered one, its root spelled as the system
//!   reports the Known Folder (or system directory) it names; the root, each
//!   directory below it and the file are opened without following a reparse
//!   point and must be named by the system with exactly that spelling (no
//!   link, junction, short name or other case);
//! * the root, each directory and the file are owned by a trusted principal
//!   (`SYSTEM`, `Administrators`, `TrustedInstaller`), not by the caller, and
//!   nobody else — the caller included — may change them, so a per-user
//!   installation or a planted DLL beside the image is refused;
//! * the file is held with writes and deletion denied, is a PE image the
//!   caller may execute, and `WinVerifyTrust` (generic Authenticode policy,
//!   whole-chain revocation from cache only) accepts it — by its embedded
//!   signature, or, for an image with none (`tar.exe`), by the system
//!   catalog that lists the Authenticode hash computed from the same handle;
//! * the verified signer is the tool's pinned publisher: the leaf's single
//!   subject `O=` and `CN=` and, for `tar`, the chain's root;
//! * the SHA-256 is read from that same held handle, which must not have
//!   moved while it was read.
//!
//! The answer is the path and that SHA-256. A launch opens the tool by both
//! (`VerifiedTool::open`), so what runs is the image that was verified;
//! anything else — another signer, another path, an unsigned or altered
//! copy — fails closed here or there.
use super::host_fs::{self, Access, Stat};
use super::identity::{authenticode_chain, catalog_chain};
use super::pinned_file::may_execute;
use super::publisher::subject_organizations_and_names;
use crate::denied;
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::os::windows::ffi::OsStringExt;
use std::os::windows::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use windows_sys::Win32::Foundation::TRUST_E_NOSIGNATURE;
use windows_sys::Win32::Storage::FileSystem::{
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_READ_ATTRIBUTES, READ_CONTROL,
    SYNCHRONIZE,
};
use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;
use windows_sys::Win32::UI::Shell::FOLDERID_ProgramFiles;

/// The largest system tool image measured (Git for Windows' `git.exe` is
/// about 4 MiB).
const MAXIMUM_TOOL_BYTES: u64 = 256 * 1024 * 1024;

/// SHA-256 of the DER of "Microsoft Root Certificate Authority 2010"
/// (valid until 2035), the root the Windows production signer
/// (`CN=Microsoft Windows`, via "Microsoft Windows Production PCA 2011")
/// chains to: the signer of the system catalog that lists `tar.exe`.
const MICROSOFT_ROOT_2010_SHA256: &str =
    "df545bf919a2439c36983b54cdfc903dfa4f37d3996d8d84b4c31eec6f3c163e";

/// SHA-256 of the DER of "Microsoft Root Certificate Authority 2011"
/// (valid until 2036), the root the signer of the third-party components
/// Windows ships (`CN=Microsoft Windows Third Party Application Component`,
/// via "Microsoft Windows Third Party Component CA 2013") chains to: the
/// embedded signature of `tar.exe`, which is bsdtar.
const MICROSOFT_ROOT_2011_SHA256: &str =
    "847df6a78497943f27fc72eb93f9a637320a02b561d0a91b09e87a7807ed7c61";

/// A code-owned system tool (maintainer ruling 69).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SystemTool {
    /// `System32\tar.exe`, the Microsoft-signed bsdtar.
    Tar,
    /// Git for Windows' `Git\mingw64\bin\git.exe` under Program Files.
    Git,
}

impl SystemTool {
    /// The tool's name in a refusal.
    pub fn name(self) -> &'static str {
        match self {
            Self::Tar => "tar",
            Self::Git => "git",
        }
    }
}

/// A system tool as measured: its registered absolute path and the SHA-256
/// of the image whose signature was verified.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrustedSystemTool {
    pub path: PathBuf,
    pub sha256: String,
}

/// Who must have signed a system tool: the leaf's single subject `O=`, and
/// one of the publisher's signers.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Publisher {
    organization: &'static str,
    signers: &'static [Signer],
}

/// One signing certificate of a publisher.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Signer {
    /// The leaf's single subject `CN=`.
    common_name: &'static str,
    /// The DER SHA-256 of the chain's root, when the publisher's root is
    /// stable enough to pin (Git for Windows' Sectigo chain is cross-signed
    /// to more than one root, so it pins no root).
    root_sha256: Option<&'static str>,
}

/// Microsoft as the publisher of the tools Windows ships. `tar.exe` carries
/// two signatures that each verify: its embedded one, by the third-party
/// component signer (bsdtar is not Microsoft's own code), and the system
/// catalog's, by the Windows production signer. Either is accepted.
pub(crate) const MICROSOFT_WINDOWS: Publisher = Publisher {
    organization: "Microsoft Corporation",
    signers: &[
        Signer {
            common_name: "Microsoft Windows Third Party Application Component",
            root_sha256: Some(MICROSOFT_ROOT_2011_SHA256),
        },
        Signer {
            common_name: "Microsoft Windows",
            root_sha256: Some(MICROSOFT_ROOT_2010_SHA256),
        },
    ],
};

/// Git for Windows' release signer.
pub(crate) const GIT_FOR_WINDOWS: Publisher = Publisher {
    organization: "Johannes Schindelin",
    signers: &[Signer {
        common_name: "Johannes Schindelin",
        root_sha256: None,
    }],
};

/// The registered path and publisher of `tool`, measured (module docs).
pub fn trusted_system_tool(tool: SystemTool) -> io::Result<TrustedSystemTool> {
    match tool {
        SystemTool::Tar => trusted_at(&system_directory()?, &["tar.exe"], &MICROSOFT_WINDOWS),
        SystemTool::Git => trusted_at(
            &program_files()?,
            &["Git", "mingw64", "bin", "git.exe"],
            &GIT_FOR_WINDOWS,
        ),
    }
}

/// `GetSystemDirectoryW`: the system directory, never `%SystemRoot%`.
fn system_directory() -> io::Result<PathBuf> {
    let mut buffer = vec![0u16; 1024];
    // SAFETY: a writable buffer of the stated length.
    let length = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
    if length == 0 || length >= buffer.len() {
        return Err(io::Error::last_os_error());
    }
    Ok(PathBuf::from(OsString::from_wide(&buffer[..length])))
}

/// The Program Files Known Folder of this (64-bit) process, never
/// `%ProgramFiles%`.
fn program_files() -> io::Result<PathBuf> {
    super::account::known_folder(&FOLDERID_ProgramFiles)
        .ok_or_else(|| denied("the Program Files known folder is unavailable"))
}

/// Open a directory without following a reparse point, able to read its
/// security descriptor.
fn open_directory(path: &Path) -> io::Result<File> {
    std::fs::OpenOptions::new()
        .access_mode(READ_CONTROL | FILE_READ_ATTRIBUTES | SYNCHRONIZE)
        .share_mode(host_fs::SHARE_ALL)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
}

/// A directory of a system tool's path: a directory, not a reparse point,
/// that only the trusted principals may change.
fn system_directory_entry(directory: &File) -> io::Result<()> {
    if !Stat::of(directory)?.directory() {
        return Err(denied(
            "a system tool directory is a reparse point or not a directory",
        ));
    }
    if !Access::of(directory)?.system_write_only() {
        return Err(denied(
            "a system tool directory may be changed by someone other than the system",
        ));
    }
    Ok(())
}

/// Measure the tool at `root\relative…` signed by `publisher` (module docs).
pub(crate) fn trusted_at(
    root: &Path,
    relative: &[&str],
    publisher: &Publisher,
) -> io::Result<TrustedSystemTool> {
    // The root as the system spells what it names; it may not itself be a
    // reparse point.
    let root_directory = open_directory(root)?;
    system_directory_entry(&root_directory)?;
    let reported = host_fs::final_path(&root_directory, false)?;
    let spelled = reported
        .to_str()
        .and_then(|text| text.strip_prefix(r"\\?\"))
        .map(PathBuf::from)
        .ok_or_else(|| denied("a system tool root is not on a local drive"))?;
    let (name, directories) = relative
        .split_last()
        .ok_or_else(|| denied("a system tool has no file name"))?;
    let mut path = spelled;
    let mut held = vec![root_directory];
    for directory in directories {
        path.push(directory);
        let opened = open_directory(&path)?;
        host_fs::canonical(&path, &opened)
            .map_err(|_| denied("a system tool directory is not its registered spelling"))?;
        system_directory_entry(&opened)?;
        held.push(opened);
    }
    path.push(name);
    let file = crate::process::open_locked_file(&path)?;
    host_fs::canonical(&path, &file)
        .map_err(|_| denied("a system tool is not at its registered path"))?;
    let before = Stat::of(&file)?;
    if !before.regular() || before.size == 0 || before.size > MAXIMUM_TOOL_BYTES {
        return Err(denied(
            "a system tool is not a regular file of bounded size",
        ));
    }
    if !Access::of(&file)?.system_write_only() {
        return Err(denied(
            "a system tool may be changed by someone other than the system",
        ));
    }
    if !may_execute(&file, name) {
        return Err(denied("a system tool is not an image the caller may run"));
    }
    signed_by(&file, &path, publisher)?;
    let mut hasher = Sha256::new();
    let mut reader = &file;
    reader.seek(SeekFrom::Start(0))?;
    let mut buffer = vec![0u8; 64 * 1024];
    let mut total = 0u64;
    let mut bounded = reader.take(MAXIMUM_TOOL_BYTES + 1);
    loop {
        let count = bounded.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        total += count as u64;
        hasher.update(&buffer[..count]);
    }
    let after = Stat::of(&file)?;
    if total != before.size || !before.same_file(&after) || !before.same_content(&after) {
        return Err(denied("a system tool changed while it was measured"));
    }
    drop(held);
    Ok(TrustedSystemTool {
        path,
        sha256: format!("{:x}", hasher.finalize()),
    })
}

/// Whether `WinVerifyTrust` accepts the held image and its verified chain
/// is `publisher`'s: by its embedded signature, or else by the system
/// catalog that lists the image's Authenticode hash.
pub(crate) fn signed_by(file: &File, path: &Path, publisher: &Publisher) -> io::Result<()> {
    let embedded = authenticode_chain(file, path)?;
    if embedded
        .as_ref()
        .is_ok_and(|chain| chain_is(chain, publisher))
    {
        return Ok(());
    }
    // An image the catalog database cannot hash (it is not a well-formed
    // PE) is listed by no catalog.
    let catalog = catalog_chain(file, path).unwrap_or(Err(TRUST_E_NOSIGNATURE));
    if catalog
        .as_ref()
        .is_ok_and(|chain| chain_is(chain, publisher))
    {
        return Ok(());
    }
    if embedded.is_ok() || catalog.is_ok() {
        return Err(denied("a system tool is not signed by its publisher"));
    }
    Err(denied(
        "a system tool carries no signature that verifies under the trust policy",
    ))
}

/// Whether a chain `WinVerifyTrust` verified (leaf first, root last) is
/// `publisher`'s: the leaf has exactly one subject `O=`, the publisher's,
/// and exactly one `CN=`, one of its signers', whose pinned root (if any)
/// is the chain's root.
fn chain_is(chain: &[Vec<u8>], publisher: &Publisher) -> bool {
    let (Some(leaf), Some(root)) = (chain.first(), chain.last()) else {
        return false;
    };
    if chain.len() < 2 {
        return false;
    }
    let Ok((organizations, names)) = subject_organizations_and_names(leaf) else {
        return false;
    };
    let root = format!("{:x}", Sha256::digest(root));
    organizations.as_slice() == [publisher.organization]
        && publisher.signers.iter().any(|signer| {
            names.as_slice() == [signer.common_name]
                && signer.root_sha256.is_none_or(|pin| root == pin)
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn digest(path: &Path) -> String {
        format!("{:x}", Sha256::digest(std::fs::read(path).unwrap()))
    }

    /// A scratch directory under the account's local application data,
    /// removed on drop.
    struct Scratch(PathBuf);
    impl Scratch {
        fn new(label: &str) -> Self {
            let base = super::super::account::application_support_directory().unwrap();
            let path = base.join(format!(
                "arkdeck-system-tool-{label}-{:032x}",
                u128::from_le_bytes(crate::random_bytes().unwrap())
            ));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn open(path: &Path) -> File {
        crate::process::open_locked_file(path).unwrap()
    }

    /// A directory junction (a mount-point reparse point, which needs no
    /// privilege) at `link`, naming `target`.
    fn junction(link: &Path, target: &Path) {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Storage::FileSystem::{FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA};
        use windows_sys::Win32::System::IO::DeviceIoControl;
        const FSCTL_SET_REPARSE_POINT: u32 = 0x0009_00A4;
        const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA000_0003;
        std::fs::create_dir(link).unwrap();
        let target = target.to_str().unwrap();
        let substitute: Vec<u16> = format!(r"\??\{target}").encode_utf16().collect();
        let substitute_bytes = (substitute.len() * 2) as u16;
        let mut path_buffer = substitute.clone();
        path_buffer.extend([0, 0]);
        let data_length = 8 + path_buffer.len() * 2;
        let mut buffer = Vec::with_capacity(8 + data_length);
        buffer.extend(IO_REPARSE_TAG_MOUNT_POINT.to_le_bytes());
        buffer.extend((data_length as u16).to_le_bytes());
        buffer.extend(0u16.to_le_bytes());
        buffer.extend(0u16.to_le_bytes()); // substitute name offset
        buffer.extend(substitute_bytes.to_le_bytes());
        buffer.extend((substitute_bytes + 2).to_le_bytes()); // print name offset
        buffer.extend(0u16.to_le_bytes()); // empty print name
        for unit in path_buffer {
            buffer.extend(unit.to_le_bytes());
        }
        let directory = std::fs::OpenOptions::new()
            .access_mode(FILE_WRITE_ATTRIBUTES | FILE_WRITE_DATA)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(link)
            .unwrap();
        let mut returned = 0;
        // SAFETY: a live directory handle and a complete mount-point buffer.
        let set = unsafe {
            DeviceIoControl(
                directory.as_raw_handle(),
                FSCTL_SET_REPARSE_POINT,
                buffer.as_ptr().cast(),
                buffer.len() as u32,
                std::ptr::null_mut(),
                0,
                &mut returned,
                std::ptr::null_mut(),
            )
        };
        assert_ne!(set, 0, "{}", io::Error::last_os_error());
    }

    #[test]
    fn tar_is_the_signed_system_bsdtar() {
        let tar = trusted_system_tool(SystemTool::Tar).unwrap();
        let expected = system_directory().unwrap().join("tar.exe");
        assert!(
            tar.path
                .as_os_str()
                .eq_ignore_ascii_case(expected.as_os_str())
        );
        assert_eq!(tar.sha256, digest(&tar.path));
        // Both of tar.exe's signatures verify, and each is Microsoft's.
        let embedded = authenticode_chain(&open(&tar.path), &tar.path)
            .unwrap()
            .unwrap();
        assert!(chain_is(&embedded, &MICROSOFT_WINDOWS));
        let catalog = catalog_chain(&open(&tar.path), &tar.path).unwrap().unwrap();
        assert!(chain_is(&catalog, &MICROSOFT_WINDOWS));
        assert_ne!(embedded[0], catalog[0]);
    }

    #[test]
    fn git_is_git_for_windows_itself_not_its_launcher() {
        let git = trusted_system_tool(SystemTool::Git).unwrap();
        let expected = program_files().unwrap().join(r"Git\mingw64\bin\git.exe");
        assert!(
            git.path
                .as_os_str()
                .eq_ignore_ascii_case(expected.as_os_str())
        );
        assert_eq!(git.sha256, digest(&git.path));
        let launcher = program_files().unwrap().join(r"Git\cmd\git.exe");
        assert_ne!(git.sha256, digest(&launcher));
    }

    #[test]
    fn each_tool_is_refused_under_the_other_publisher() {
        let system = system_directory().unwrap();
        let tar = trusted_at(&system, &["tar.exe"], &GIT_FOR_WINDOWS).unwrap_err();
        assert_eq!(tar.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(
            tar.to_string(),
            "a system tool is not signed by its publisher"
        );
        let git = trusted_at(
            &program_files().unwrap(),
            &["Git", "mingw64", "bin", "git.exe"],
            &MICROSOFT_WINDOWS,
        )
        .unwrap_err();
        assert_eq!(
            git.to_string(),
            "a system tool is not signed by its publisher"
        );
        // The publisher pin alone does not name tar — another System32 image
        // is signed by the same publisher — which is why the path is
        // registered rather than searched.
        assert!(trusted_at(&system, &["whoami.exe"], &MICROSOFT_WINDOWS).is_ok());
    }

    #[test]
    fn another_spelling_of_the_registered_path_is_refused() {
        let system = system_directory().unwrap();
        let error = trusted_at(&system, &["TAR.EXE"], &MICROSOFT_WINDOWS).unwrap_err();
        assert_eq!(
            error.to_string(),
            "a system tool is not at its registered path"
        );
        let error = trusted_at(
            &program_files().unwrap(),
            &["GIT", "mingw64", "bin", "git.exe"],
            &GIT_FOR_WINDOWS,
        )
        .unwrap_err();
        assert_eq!(
            error.to_string(),
            "a system tool directory is not its registered spelling"
        );
    }

    #[test]
    fn a_copy_outside_the_registered_path_is_refused() {
        let scratch = Scratch::new("copy");
        let system = system_directory().unwrap();
        std::fs::copy(system.join("tar.exe"), scratch.0.join("tar.exe")).unwrap();
        let git = program_files().unwrap().join(r"Git\mingw64\bin\git.exe");
        std::fs::copy(&git, scratch.0.join("git.exe")).unwrap();
        // The copies are still signed (the catalog lists tar.exe's hash, and
        // git.exe's signature is embedded) ...
        let tar_copy = scratch.0.join("tar.exe");
        signed_by(&open(&tar_copy), &tar_copy, &MICROSOFT_WINDOWS).unwrap();
        let git_copy = scratch.0.join("git.exe");
        signed_by(&open(&git_copy), &git_copy, &GIT_FOR_WINDOWS).unwrap();
        // ... but the caller may change them where they are.
        for (name, publisher) in [("tar.exe", MICROSOFT_WINDOWS), ("git.exe", GIT_FOR_WINDOWS)] {
            let error = trusted_at(&scratch.0, &[name], &publisher).unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::PermissionDenied, "{name}");
            assert_eq!(
                error.to_string(),
                "a system tool directory may be changed by someone other than the system",
                "{name}"
            );
        }
    }

    #[test]
    fn an_altered_or_unsigned_image_is_refused() {
        let scratch = Scratch::new("altered");
        let system = system_directory().unwrap();
        let altered = scratch.0.join("tar.exe");
        let mut bytes = std::fs::read(system.join("tar.exe")).unwrap();
        bytes.extend_from_slice(&[0; 8]);
        std::fs::write(&altered, &bytes).unwrap();
        let error = signed_by(&open(&altered), &altered, &MICROSOFT_WINDOWS).unwrap_err();
        assert_eq!(
            error.to_string(),
            "a system tool carries no signature that verifies under the trust policy"
        );
        let mut git =
            std::fs::read(program_files().unwrap().join(r"Git\mingw64\bin\git.exe")).unwrap();
        let middle = git.len() / 2;
        git[middle] ^= 0xff;
        let tampered = scratch.0.join("git.exe");
        std::fs::write(&tampered, &git).unwrap();
        assert!(signed_by(&open(&tampered), &tampered, &GIT_FOR_WINDOWS).is_err());
        // This test binary is not signed at all.
        let unsigned = scratch.0.join("unsigned.exe");
        std::fs::copy(std::env::current_exe().unwrap(), &unsigned).unwrap();
        for publisher in [MICROSOFT_WINDOWS, GIT_FOR_WINDOWS] {
            assert_eq!(
                signed_by(&open(&unsigned), &unsigned, &publisher)
                    .unwrap_err()
                    .to_string(),
                "a system tool carries no signature that verifies under the trust policy"
            );
        }
    }

    #[test]
    fn a_junction_to_the_system_directory_is_refused() {
        let scratch = Scratch::new("junction");
        let link = scratch.0.join("system");
        junction(&link, &system_directory().unwrap());
        let error = trusted_at(&link, &["tar.exe"], &MICROSOFT_WINDOWS).unwrap_err();
        assert_eq!(
            error.to_string(),
            "a system tool directory is a reparse point or not a directory"
        );
    }

    #[test]
    fn the_publisher_pin_needs_one_organisation_one_name_and_its_root() {
        let system = system_directory().unwrap();
        let tar = system.join("tar.exe");
        let catalog = catalog_chain(&open(&tar), &tar).unwrap().unwrap();
        let embedded = authenticode_chain(&open(&tar), &tar).unwrap().unwrap();
        for chain in [&catalog, &embedded] {
            assert!(chain_is(chain, &MICROSOFT_WINDOWS));
            assert!(!chain_is(chain, &GIT_FOR_WINDOWS));
            // A leaf alone is no chain.
            assert!(!chain_is(&chain[..1], &MICROSOFT_WINDOWS));
        }
        assert!(!chain_is(&[], &MICROSOFT_WINDOWS));
        // Each signer is held to its own root: the catalog signer's name
        // under the third-party signer's root is refused, and the reverse.
        let swapped = Publisher {
            organization: "Microsoft Corporation",
            signers: &[
                Signer {
                    common_name: "Microsoft Windows",
                    root_sha256: Some(MICROSOFT_ROOT_2011_SHA256),
                },
                Signer {
                    common_name: "Microsoft Windows Third Party Application Component",
                    root_sha256: Some(MICROSOFT_ROOT_2010_SHA256),
                },
            ],
        };
        assert!(!chain_is(&catalog, &swapped));
        assert!(!chain_is(&embedded, &swapped));
        let other_organization = Publisher {
            organization: "Microsoft Corporation.",
            ..MICROSOFT_WINDOWS
        };
        assert!(!chain_is(&catalog, &other_organization));
    }
}
