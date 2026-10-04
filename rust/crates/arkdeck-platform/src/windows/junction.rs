//! Directory junctions (mount-point reparse points) for the workspace
//! provider's isolated copy (TASK-XPA-011): read the target a junction
//! names, and create one. A junction needs no privilege, unlike a symbolic
//! link. Nothing here follows a link: the reader opens the reparse point
//! itself, and the writer sets one on a directory it has just created.
use std::fs::File;
use std::io;
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_READ_ATTRIBUTES,
    FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA,
};
use windows_sys::Win32::System::IO::DeviceIoControl;

const FSCTL_GET_REPARSE_POINT: u32 = 0x0009_00A8;
const FSCTL_SET_REPARSE_POINT: u32 = 0x0009_00A4;
const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA000_0003;
/// `MAXIMUM_REPARSE_DATA_BUFFER_SIZE`.
const MAXIMUM_REPARSE_DATA: usize = 16 * 1024;

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

/// `X:\…`: a drive-letter path, never UNC, a volume GUID or a device.
fn drive_path(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && &bytes[1..3] == b":\\"
        && !text.contains('/')
}

/// The target the directory junction at `path` names, as `X:\…`; `None`
/// when `path` is a reparse point of another kind (a symbolic link, a cloud
/// placeholder, …). A junction naming anything but a drive-letter path (a
/// volume mount point `\??\Volume{…}\`, a UNC or device path) is refused.
pub fn junction_target(path: &Path) -> io::Result<Option<PathBuf>> {
    let link = std::fs::OpenOptions::new()
        .access_mode(FILE_READ_ATTRIBUTES)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    let mut buffer = vec![0u8; MAXIMUM_REPARSE_DATA];
    let mut returned = 0u32;
    // SAFETY: a live handle and an output buffer of the stated length.
    let read = unsafe {
        DeviceIoControl(
            link.as_raw_handle(),
            FSCTL_GET_REPARSE_POINT,
            std::ptr::null(),
            0,
            buffer.as_mut_ptr().cast(),
            buffer.len() as u32,
            &mut returned,
            std::ptr::null_mut(),
        )
    };
    if read == 0 {
        return Err(io::Error::last_os_error());
    }
    let data = &buffer[..returned as usize];
    if data.len() < 16 {
        return Err(invalid("reparse data is truncated"));
    }
    let field = |at: usize| u16::from_le_bytes([data[at], data[at + 1]]) as usize;
    if u32::from_le_bytes([data[0], data[1], data[2], data[3]]) != IO_REPARSE_TAG_MOUNT_POINT {
        return Ok(None);
    }
    let (offset, length) = (field(8), field(10));
    let names = &data[16..];
    if length % 2 != 0 || offset % 2 != 0 || offset + length > names.len() {
        return Err(invalid("junction substitute name is malformed"));
    }
    let units: Vec<u16> = names[offset..offset + length]
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| u16::from_le_bytes(*pair))
        .collect();
    let substitute =
        String::from_utf16(&units).map_err(|_| invalid("junction target is not text"))?;
    let target = substitute
        .strip_prefix(r"\??\")
        .filter(|target| drive_path(target))
        .ok_or_else(|| invalid("junction names no drive-letter directory"))?;
    Ok(Some(PathBuf::from(target)))
}

/// A directory junction at `link` (which must not exist) naming `target`, a
/// drive-letter path (`X:\…`) that need not exist yet. A link left half
/// made is removed.
pub fn create_junction(link: &Path, target: &Path) -> io::Result<()> {
    let target = target
        .to_str()
        .filter(|target| drive_path(target) && !target.contains('\0'))
        .ok_or_else(|| invalid("a junction names a drive-letter directory"))?;
    let substitute: Vec<u16> = format!(r"\??\{target}").encode_utf16().collect();
    let print: Vec<u16> = target.encode_utf16().collect();
    let substitute_bytes = substitute.len() * 2;
    let print_bytes = print.len() * 2;
    // Two NUL-terminated names after the eight bytes of offsets and lengths.
    let data_length = 8 + substitute_bytes + 2 + print_bytes + 2;
    if 8 + data_length > MAXIMUM_REPARSE_DATA {
        return Err(invalid("junction target is too long"));
    }
    let mut buffer = Vec::with_capacity(8 + data_length);
    buffer.extend(IO_REPARSE_TAG_MOUNT_POINT.to_le_bytes());
    buffer.extend((data_length as u16).to_le_bytes());
    buffer.extend(0u16.to_le_bytes());
    buffer.extend(0u16.to_le_bytes());
    buffer.extend((substitute_bytes as u16).to_le_bytes());
    buffer.extend(((substitute_bytes + 2) as u16).to_le_bytes());
    buffer.extend((print_bytes as u16).to_le_bytes());
    for unit in substitute
        .iter()
        .chain([&0])
        .chain(print.iter())
        .chain([&0])
    {
        buffer.extend(unit.to_le_bytes());
    }
    std::fs::create_dir(link)?;
    let set = (|| -> io::Result<()> {
        let directory: File = std::fs::OpenOptions::new()
            .access_mode(FILE_WRITE_ATTRIBUTES | FILE_WRITE_DATA)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(link)?;
        let mut returned = 0u32;
        // SAFETY: a live handle on the new, empty directory and a complete
        // mount-point buffer of the stated length.
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
        if set == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    })();
    if let Err(error) = set {
        let _ = std::fs::remove_dir(link);
        return Err(error);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{create_junction, junction_target};
    use std::path::PathBuf;

    #[test]
    fn a_created_junction_reads_back_its_target_and_resolves_there() {
        let root = std::env::temp_dir().canonicalize().unwrap();
        let root = PathBuf::from(root.to_str().unwrap().trim_start_matches(r"\\?\")).join(format!(
            "arkdeck-junction-{:032x}",
            u128::from_le_bytes(crate::random_bytes().unwrap())
        ));
        std::fs::create_dir_all(root.join("target dir")).unwrap();
        std::fs::write(root.join("target dir").join("file"), b"inside").unwrap();
        let link = root.join("link");
        create_junction(&link, &root.join("target dir")).unwrap();
        assert_eq!(
            junction_target(&link).unwrap(),
            Some(root.join("target dir"))
        );
        assert_eq!(std::fs::read(link.join("file")).unwrap(), b"inside");
        assert!(
            std::fs::symlink_metadata(&link)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        // An ordinary directory is no reparse point at all.
        assert!(junction_target(&root.join("target dir")).is_err());
        // Never a UNC, volume or relative target.
        for refused in [r"\\server\share", r"\\?\Volume{0}\x", "relative"] {
            assert!(create_junction(&root.join("other"), &PathBuf::from(refused)).is_err());
            assert!(!root.join("other").exists());
        }
        let _ = std::fs::remove_dir(&link);
        let _ = std::fs::remove_dir_all(&root);
    }
}
