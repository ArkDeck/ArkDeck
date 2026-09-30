//! The Windows `VerifiedSource` and the private entries of the signing layer
//! (TASK-XPA-011): a verified source is bound to its length and SHA-256 and,
//! while held, its canonical path keeps naming exactly that file — the file
//! cannot be written, renamed or deleted, and no ancestor directory can be
//! renamed or deleted; a new private directory or file is owned by the user
//! and granted to nobody else, whatever its parent grants.
#![cfg(windows)]

use arkdeck_platform::{
    VerifiedSource, application_support_directory, create_private_directory, create_private_file,
    measure_host_file, random_bytes,
};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};

/// A scratch directory under the account's local application data, in its
/// plain `X:\…` spelling; removed on drop.
struct Scratch(PathBuf);
impl Scratch {
    fn new(label: &str) -> Self {
        let base = application_support_directory()
            .unwrap()
            .canonicalize()
            .unwrap();
        let base = base.to_str().unwrap();
        let path = PathBuf::from(base.strip_prefix(r"\\?\").unwrap_or(base)).join(format!(
            "arkdeck-test-{label}-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        create_private_directory(&path).unwrap();
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// A directory junction (a mount-point reparse point, which needs no
/// privilege) at `link`, naming `target`.
fn junction(link: &Path, target: &Path) {
    use std::os::windows::fs::OpenOptionsExt;
    use windows_sys::Win32::Storage::FileSystem::*;
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
    assert_ne!(set, 0, "{}", std::io::Error::last_os_error());
}

#[test]
fn a_held_source_keeps_its_path_naming_the_verified_file() {
    let scratch = Scratch::new("verified-source");
    let directory = scratch.0.join("lib");
    create_private_directory(&directory).unwrap();
    let path = directory.join("hap-sign-tool.jar");
    let bytes = b"fixture jar bytes";
    create_private_file(&path)
        .unwrap()
        .write_all(bytes)
        .unwrap();

    let source = VerifiedSource::open(&path, &digest(bytes), bytes.len() as u64).unwrap();
    assert_eq!(source.inode_path(), path.to_str().unwrap());
    assert_eq!(source.path(), path);
    // Another reader reads it by that path.
    assert_eq!(std::fs::read(source.inode_path()).unwrap(), bytes);
    // Nobody writes, renames or deletes it, or renames or deletes a level
    // above it, while it is held.
    assert!(std::fs::OpenOptions::new().write(true).open(&path).is_err());
    assert!(std::fs::remove_file(&path).is_err());
    assert!(std::fs::rename(&path, directory.join("moved.jar")).is_err());
    assert!(std::fs::rename(&directory, scratch.0.join("moved")).is_err());
    assert!(std::fs::rename(&scratch.0, scratch.0.with_extension("moved")).is_err());
    // Adding an entry beside it is not a change to it.
    create_private_file(&directory.join("beside")).unwrap();
    drop(source);
    std::fs::rename(&directory, scratch.0.join("moved")).unwrap();
    std::fs::rename(scratch.0.join("moved"), &directory).unwrap();
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn a_source_that_is_not_as_pinned_or_not_canonical_is_refused() {
    let scratch = Scratch::new("verified-source-refusals");
    let path = scratch.0.join("Source.jar");
    let bytes = b"fixture jar bytes";
    create_private_file(&path)
        .unwrap()
        .write_all(bytes)
        .unwrap();
    let sha = digest(bytes);
    let length = bytes.len() as u64;
    assert!(VerifiedSource::open(&path, &sha, length).is_ok());
    // Another length, another digest, no pin at all.
    assert!(VerifiedSource::open(&path, &sha, length + 1).is_err());
    assert!(VerifiedSource::open(&path, &digest(b"other"), length).is_err());
    assert!(VerifiedSource::open(&path, &sha, 0).is_err());
    assert!(VerifiedSource::open(&path, "", length).is_err());
    // Not the spelling on disk, verbatim, relative, a dot component.
    let text = path.to_str().unwrap();
    for spelling in [
        text.replace("Source.jar", "source.jar"),
        format!(r"\\?\{text}"),
        "Source.jar".to_owned(),
        text.replace(r"\Source.jar", r"\.\Source.jar"),
    ] {
        assert!(
            VerifiedSource::open(Path::new(&spelling), &sha, length).is_err(),
            "{spelling}"
        );
    }
    // A directory, and a path through a junction.
    assert!(VerifiedSource::open(&scratch.0, &sha, length).is_err());
    junction(&scratch.0.join("via"), &scratch.0);
    assert!(VerifiedSource::open(&scratch.0.join("via").join("Source.jar"), &sha, length).is_err());
    std::fs::remove_dir(scratch.0.join("via")).unwrap();
}

#[test]
fn private_entries_are_owned_by_the_user_and_granted_to_nobody_else() {
    let scratch = Scratch::new("private-entries");
    // A parent that grants everyone full control, inherited by children.
    let open = scratch.0.join("open");
    std::fs::create_dir(&open).unwrap();
    let status = std::process::Command::new("icacls")
        .arg(&open)
        .args(["/grant", "*S-1-1-0:(OI)(CI)F"])
        .stdout(std::process::Stdio::null())
        .status()
        .unwrap();
    assert!(status.success());
    let inherited = open.join("inherited");
    std::fs::write(&inherited, b"x").unwrap();
    let measured = measure_host_file(&inherited, 16).unwrap();
    assert!(!measured.owner_private && !measured.trusted_write_only);

    let directory = open.join("private");
    create_private_directory(&directory).unwrap();
    assert_eq!(
        create_private_directory(&directory).unwrap_err().kind(),
        std::io::ErrorKind::AlreadyExists
    );
    let file = directory.join("file");
    create_private_file(&file).unwrap().write_all(b"x").unwrap();
    assert_eq!(
        create_private_file(&file).unwrap_err().kind(),
        std::io::ErrorKind::AlreadyExists
    );
    let direct = open.join("direct");
    create_private_file(&direct)
        .unwrap()
        .write_all(b"x")
        .unwrap();
    // Created in the private directory by anyone else's code: inherited
    // owner-only access.
    let child = directory.join("child");
    std::fs::write(&child, b"x").unwrap();
    for path in [&file, &direct, &child] {
        let measured = measure_host_file(path, 16).unwrap();
        assert!(measured.owner_is_user, "{}", path.display());
        assert!(measured.owner_private, "{}", path.display());
        assert!(measured.trusted_write_only, "{}", path.display());
    }
}
