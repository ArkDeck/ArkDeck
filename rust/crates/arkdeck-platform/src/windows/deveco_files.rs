//! No-follow, read-only access to the current DevEco child roles of a
//! Windows DevEco Studio installation (TASK-XPA-011, gate G15): the Windows
//! counterpart of `host_deveco_files.rs`, deliberately not a whole-SDK
//! inventory, a launcher or a mutable root owner.
//!
//! The Windows installation is a plain directory (the default is
//! `%ProgramFiles%\Huawei\DevEco Studio`), not a signed `.app` bundle, so the
//! macOS layout maps as follows; anything else fails closed:
//!
//! | Role | macOS (`<X>.app/Contents/…`) | Windows (`<root>\…`) |
//! | --- | --- | --- |
//! | product manifest | `Resources/product-info.json` | `product-info.json` |
//! | SDK manifest | `sdk/default/sdk-pkg.json` | `sdk\default\sdk-pkg.json` |
//! | Node | `tools/node/bin/node` | `tools\node\node.exe` |
//! | Hvigor | `tools/hvigor/bin/hvigorw.js` | `tools\hvigor\bin\hvigorw.js` |
//! | signed resource envelope | `_CodeSignature/CodeResources` | none: Windows binds no manifest to a publisher signature |
//!
//! The root must hold the Windows launcher `bin\devecostudio64.exe` (the
//! `launcherPath` of the manifest's `Windows`/`amd64` launch entry), so a
//! macOS tree copied onto a Windows disk is refused as an unknown layout.
//! Ownership and write rights are read from each level's owner and DACL:
//! every directory from the drive root down and every child must be owned
//! by the token user or a trusted principal (`SYSTEM`, `Administrators`,
//! `TrustedInstaller`, the places of Unix root) and grant nobody else a
//! right to change it; the drive root alone may let others add entries (as
//! `/Applications` and the sticky `/private/tmp` do on macOS).
use super::host_fs::{self, Access, DIRECTORY, Kind, READ, Stat, segment};
use super::host_store::HostFileIdentity;
use super::pinned_file::{may_execute, standard_local_path};
use std::fs::File;
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf, Prefix};
use windows_sys::Wdk::Storage::FileSystem::FILE_OPEN;

/// The closed set of DevEco child roles read on Windows. The macOS
/// `SignedResourceEnvelope` has no Windows counterpart and is absent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DevEcoRole {
    ProductManifest,
    SdkManifest,
    Node,
    Hvigor,
}

impl DevEcoRole {
    pub const ALL: [Self; 4] = [
        Self::ProductManifest,
        Self::SdkManifest,
        Self::Node,
        Self::Hvigor,
    ];
    pub fn name(self) -> &'static str {
        match self {
            Self::ProductManifest => "productManifest",
            Self::SdkManifest => "sdkManifest",
            Self::Node => "node",
            Self::Hvigor => "hvigor",
        }
    }
    /// The role's path relative to the root, `/`-separated as on macOS.
    pub fn path(self) -> &'static str {
        match self {
            Self::ProductManifest => "product-info.json",
            Self::SdkManifest => "sdk/default/sdk-pkg.json",
            Self::Node => "tools/node/node.exe",
            Self::Hvigor => "tools/hvigor/bin/hvigorw.js",
        }
    }
    fn maximum(self) -> usize {
        match self {
            Self::ProductManifest | Self::SdkManifest => 64 * 1024,
            Self::Node => 256 * 1024 * 1024,
            Self::Hvigor => 8 * 1024 * 1024,
        }
    }
}

/// The Windows launcher whose presence marks the Windows layout.
const WINDOWS_LAUNCHER: [&str; 2] = ["bin", "devecostudio64.exe"];

/// One child's pinned facts: the host store's file identity (volume serial,
/// `FileIdInfo` file id, size, last-write and change times) where macOS
/// records `dev`/`ino`/size/`mtime`/`ctime`, the link count, and whether the
/// caller may execute it where macOS reads the mode's execute bits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DevEcoFileFacts {
    pub identity: HostFileIdentity,
    pub links: u32,
    pub executable: bool,
}

pub struct DevEcoFileRead {
    pub facts: DevEcoFileFacts,
    pub bytes: Vec<u8>,
}

pub struct DevEcoRoot {
    held: File,
    path: PathBuf,
    pub identity: HostFileIdentity,
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

/// A local absolute path as its drive root (`X:\`) and its components.
fn components(path: &Path) -> io::Result<(PathBuf, Vec<&str>)> {
    if !standard_local_path(path) {
        return Err(invalid());
    }
    let mut parts = path.components();
    let drive = match parts.next() {
        Some(Component::Prefix(prefix)) => match prefix.kind() {
            Prefix::Disk(letter) | Prefix::VerbatimDisk(letter) if letter.is_ascii_alphabetic() => {
                PathBuf::from(format!("{}:\\", letter as char))
            }
            _ => return Err(invalid()),
        },
        _ => return Err(invalid()),
    };
    if parts.next() != Some(Component::RootDir) {
        return Err(invalid());
    }
    let mut names = Vec::new();
    for part in parts {
        match part {
            Component::Normal(name) => names.push(name.to_str().ok_or_else(invalid)?),
            _ => return Err(invalid()),
        }
    }
    Ok((drive, names))
}

fn child(parent: &File, name: &str, kind: Kind) -> io::Result<File> {
    let access = if kind == Kind::Directory {
        DIRECTORY
    } else {
        READ
    };
    host_fs::open_relative(parent, &segment(name)?, access, FILE_OPEN, kind, None)
        .map_err(|_| invalid())
}

fn safe_directory(file: &File) -> io::Result<()> {
    if Stat::of(file)?.directory() && Access::of(file)?.trusted_write_only() {
        Ok(())
    } else {
        Err(denied())
    }
}

/// Walk from the drive root, one no-follow relative open per component.
fn open_root(path: &Path) -> io::Result<File> {
    let (drive, names) = components(path)?;
    let mut current = host_fs::open_directory_path(&drive, DIRECTORY).map_err(|_| invalid())?;
    let access = Access::of(&current)?;
    if !Stat::of(&current)?.directory() || !access.trusted_write_only_but_add() {
        return Err(denied());
    }
    for name in names {
        current = child(&current, name, Kind::Directory)?;
        safe_directory(&current)?;
    }
    Ok(current)
}

impl DevEcoRoot {
    pub fn open(path: &Path) -> io::Result<Self> {
        let held = open_root(path)?;
        // The spelling on disk: no short name, no other case, no link.
        host_fs::canonical(path, &held).map_err(|_| invalid())?;
        let bin = child(&held, WINDOWS_LAUNCHER[0], Kind::Directory)?;
        safe_directory(&bin)?;
        let launcher = child(&bin, WINDOWS_LAUNCHER[1], Kind::NonDirectory)?;
        if !Stat::of(&launcher)?.regular() {
            return Err(invalid());
        }
        let identity = HostFileIdentity::of(&Stat::of(&held)?)?;
        Ok(Self {
            held,
            path: path.to_path_buf(),
            identity,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn require_linked(&self) -> io::Result<()> {
        let linked = Stat::of(&open_root(&self.path)?)?;
        if !linked.same_file(&Stat::of(&self.held)?) {
            Err(invalid())
        } else {
            Ok(())
        }
    }

    pub fn verify_sdk_directory(&self) -> io::Result<()> {
        let mut directory = self.held.try_clone()?;
        for component in ["sdk", "default", "openharmony"] {
            directory = child(&directory, component, Kind::Directory)?;
            safe_directory(&directory)?;
        }
        Ok(())
    }

    pub fn read_role(&self, role: DevEcoRole) -> io::Result<DevEcoFileRead> {
        let parts: Vec<_> = role.path().split('/').collect();
        let mut parent = self.held.try_clone()?;
        for component in &parts[..parts.len() - 1] {
            parent = child(&parent, component, Kind::Directory)?;
            safe_directory(&parent)?;
        }
        let name = parts[parts.len() - 1];
        let file = child(&parent, name, Kind::NonDirectory)?;
        let before = Stat::of(&file)?;
        let executable = may_execute(&file, name);
        if !before.regular()
            || before.links != 1
            || before.size == 0
            || before.size > role.maximum() as u64
            || !Access::of(&file)?.trusted_write_only()
            || (matches!(role, DevEcoRole::Node) && !executable)
        {
            return Err(denied());
        }
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
        let after = Stat::of(&file)?;
        let linked = Stat::of(&host_fs::inspect_relative(&parent, &segment(name)?)?)?;
        if bytes.len() as u64 != before.size
            || !(before.same_file(&after) && before.same_content(&after))
            || !(before.same_file(&linked) && before.same_content(&linked))
        {
            return Err(invalid());
        }
        Ok(DevEcoFileRead {
            facts: DevEcoFileFacts {
                identity: HostFileIdentity::of(&before)?,
                links: before.links,
                executable,
            },
            bytes,
        })
    }
}
