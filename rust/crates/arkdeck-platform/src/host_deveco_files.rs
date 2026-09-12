//! No-follow, read-only access to the five current DevEco child roles. This is
//! deliberately not a whole-SDK inventory, a launcher or a mutable root owner.
use std::{
    ffi::CString,
    fs::{File, Metadata, OpenOptions},
    io::{self, Read},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
        },
    },
    path::{Path, PathBuf},
};
#[derive(Debug, Clone, Copy)]
pub enum DevEcoRole {
    ProductManifest,
    SdkManifest,
    Node,
    Hvigor,
    SignedResourceEnvelope,
}
impl DevEcoRole {
    pub fn name(self) -> &'static str {
        match self {
            Self::ProductManifest => "productManifest",
            Self::SdkManifest => "sdkManifest",
            Self::Node => "node",
            Self::Hvigor => "hvigor",
            Self::SignedResourceEnvelope => "signedResourceEnvelope",
        }
    }
    pub fn path(self) -> &'static str {
        match self {
            Self::ProductManifest => "Resources/product-info.json",
            Self::SdkManifest => "sdk/default/sdk-pkg.json",
            Self::Node => "tools/node/bin/node",
            Self::Hvigor => "tools/hvigor/bin/hvigorw.js",
            Self::SignedResourceEnvelope => "_CodeSignature/CodeResources",
        }
    }
    fn maximum(self) -> usize {
        match self {
            Self::ProductManifest | Self::SdkManifest => 64 * 1024,
            Self::Node => 256 * 1024 * 1024,
            Self::Hvigor => 8 * 1024 * 1024,
            Self::SignedResourceEnvelope => 32 * 1024 * 1024,
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DevEcoFileFacts {
    pub device: u64,
    pub inode: u64,
    pub byte_count: u64,
    pub modified_seconds: i64,
    pub modified_nanos: i64,
    pub changed_seconds: i64,
    pub changed_nanos: i64,
    pub mode: u32,
    pub uid: u32,
    pub links: u64,
}
impl From<Metadata> for DevEcoFileFacts {
    fn from(m: Metadata) -> Self {
        Self {
            device: m.dev(),
            inode: m.ino(),
            byte_count: m.len(),
            modified_seconds: m.mtime(),
            modified_nanos: m.mtime_nsec(),
            changed_seconds: m.ctime(),
            changed_nanos: m.ctime_nsec(),
            mode: m.mode(),
            uid: m.uid(),
            links: m.nlink(),
        }
    }
}
pub struct DevEcoFileRead {
    pub facts: DevEcoFileFacts,
    pub bytes: Vec<u8>,
}
pub struct DevEcoRoot {
    held: File,
    path: PathBuf,
    pub identity: DevEcoFileFacts,
}
#[derive(Debug)]
pub struct DevEcoIdentityChanged;
impl std::fmt::Display for DevEcoIdentityChanged {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DevEco root or child identity changed or is unreadable")
    }
}
impl std::error::Error for DevEcoIdentityChanged {}
#[derive(Debug)]
pub struct DevEcoInputTooLarge;
impl std::fmt::Display for DevEcoInputTooLarge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DevEco file exceeds its size bound")
    }
}
impl std::error::Error for DevEcoInputTooLarge {}
fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, DevEcoIdentityChanged)
}
fn denied() -> io::Error {
    io::Error::new(
        io::ErrorKind::PermissionDenied,
        "DevEco root or child permissions are unsafe",
    )
}
fn current_uid() -> u32 {
    unsafe { libc::geteuid() }
}
fn child(parent: &File, name: &str, directory: bool) -> io::Result<File> {
    let name = CString::new(name).map_err(|_| invalid())?;
    // SAFETY: parent and component are live, successful fd is transferred once.
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY
                | libc::O_NONBLOCK
                | libc::O_CLOEXEC
                | libc::O_NOFOLLOW
                | if directory { libc::O_DIRECTORY } else { 0 },
        )
    };
    if fd < 0 {
        return Err(invalid());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn safe_directory(file: &File) -> io::Result<()> {
    let m = file.metadata()?;
    if !m.is_dir() || (m.uid() != current_uid() && m.uid() != 0) || m.mode() & 0o022 != 0 {
        Err(denied())
    } else {
        Ok(())
    }
}
fn physical(path: &Path) -> io::Result<PathBuf> {
    let text = path.to_str().ok_or_else(invalid)?;
    if !text.starts_with('/')
        || text.len() > 16 * 1024
        || text.as_bytes().contains(&0)
        || text.split('/').any(|p| matches!(p, "." | ".."))
    {
        return Err(invalid());
    }
    for prefix in ["/tmp", "/var", "/etc"] {
        if text == prefix || text.starts_with(&format!("{prefix}/")) {
            return Ok(PathBuf::from(format!("/private{text}")));
        }
    }
    Ok(path.to_path_buf())
}
fn open_root(path: &Path) -> io::Result<File> {
    let mut current = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open("/")?;
    let mut traversed = String::new();
    for component in path
        .as_os_str()
        .as_bytes()
        .split(|b| *b == b'/')
        .filter(|p| !p.is_empty())
    {
        let name = std::str::from_utf8(component).map_err(|_| invalid())?;
        current = child(&current, name, true)?;
        traversed.push('/');
        traversed.push_str(name);
        let m = current.metadata()?;
        let applications =
            traversed == "/Applications" && m.uid() == 0 && m.gid() == 80 && m.mode() & 0o002 == 0;
        let temporary =
            traversed == "/private/tmp" && m.uid() == 0 && m.gid() == 0 && m.mode() & 0o1000 != 0;
        if !m.is_dir()
            || (m.uid() != current_uid() && m.uid() != 0)
            || (m.mode() & 0o022 != 0 && !applications && !temporary)
        {
            return Err(denied());
        }
    }
    Ok(current)
}
impl DevEcoRoot {
    pub fn open(path: &Path) -> io::Result<Self> {
        let path = physical(path)?;
        if path.file_name().is_none_or(|name| name != "Contents")
            || path
                .parent()
                .and_then(Path::extension)
                .is_none_or(|ext| ext != "app")
        {
            return Err(invalid());
        }
        let held = open_root(&path)?;
        let identity = held.metadata()?.into();
        Ok(Self {
            held,
            path,
            identity,
        })
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn require_linked(&self) -> io::Result<()> {
        let linked = open_root(&self.path)?.metadata()?;
        let held = self.held.metadata()?;
        if linked.dev() != held.dev() || linked.ino() != held.ino() {
            Err(invalid())
        } else {
            Ok(())
        }
    }
    pub fn verify_sdk_directory(&self) -> io::Result<()> {
        let mut directory = self.held.try_clone()?;
        for component in ["sdk", "default", "openharmony"] {
            directory = child(&directory, component, true)?;
            safe_directory(&directory)?;
        }
        Ok(())
    }
    pub fn read_role(&self, role: DevEcoRole) -> io::Result<DevEcoFileRead> {
        let parts: Vec<_> = role.path().split('/').collect();
        let mut parent = self.held.try_clone()?;
        for component in &parts[..parts.len() - 1] {
            parent = child(&parent, component, true)?;
            safe_directory(&parent)?;
        }
        let name = parts[parts.len() - 1];
        let file = child(&parent, name, false)?;
        let m = file.metadata()?;
        if !m.is_file()
            || m.nlink() != 1
            || m.len() == 0
            || m.len() > role.maximum() as u64
            || (m.uid() != current_uid() && m.uid() != 0)
            || m.mode() & 0o022 != 0
            || (matches!(role, DevEcoRole::Node) && m.mode() & 0o111 == 0)
        {
            return Err(denied());
        }
        let facts = DevEcoFileFacts::from(m);
        let mut bytes = Vec::new();
        (&file)
            .take(role.maximum() as u64 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > role.maximum() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                DevEcoInputTooLarge,
            ));
        }
        if bytes.len() as u64 != facts.byte_count
            || DevEcoFileFacts::from(file.metadata()?) != facts
            || DevEcoFileFacts::from(child(&parent, name, false)?.metadata()?) != facts
        {
            return Err(invalid());
        }
        Ok(DevEcoFileRead { facts, bytes })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    };
    #[test]
    fn closed_roles_refuse_links_unsafe_modes_and_replaced_root_without_execution() {
        let nonce = u128::from_ne_bytes(crate::random_bytes::<16>().unwrap());
        let base = PathBuf::from(format!("/private/tmp/deveco-files-{nonce:032x}.app"));
        fs::DirBuilder::new().mode(0o700).create(&base).unwrap();
        let root = base.join("Contents");
        fs::create_dir(&root).unwrap();
        fs::create_dir(root.join("Resources")).unwrap();
        let manifest = root.join(DevEcoRole::ProductManifest.path());
        fs::write(&manifest, b"{}").unwrap();
        fs::set_permissions(&manifest, fs::Permissions::from_mode(0o600)).unwrap();
        let held = DevEcoRoot::open(&root).unwrap();
        assert_eq!(
            held.read_role(DevEcoRole::ProductManifest).unwrap().bytes,
            b"{}"
        );
        fs::set_permissions(&manifest, fs::Permissions::from_mode(0o666)).unwrap();
        assert!(held.read_role(DevEcoRole::ProductManifest).is_err());
        fs::remove_file(&manifest).unwrap();
        symlink("/usr/bin/true", &manifest).unwrap();
        assert!(held.read_role(DevEcoRole::ProductManifest).is_err());
        fs::rename(&root, base.join("old")).unwrap();
        fs::create_dir(&root).unwrap();
        assert!(held.require_linked().is_err());
        fs::remove_dir_all(base).unwrap();
    }
}
