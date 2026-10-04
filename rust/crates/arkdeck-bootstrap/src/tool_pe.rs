//! Bounded, read-only PE inspection for Bootstrap tools on Windows: the
//! counterpart of `tool_macho.rs` for the Windows HDC layout, `hdc.exe` with
//! an optional sibling `libusb_shared.dll`.
//!
//! It reads the COFF header, the PE32+ optional header's import directory
//! and the import descriptors' DLL names, nothing else. A PE import names a
//! DLL, never a path; the loader looks for it in the image's own directory
//! first, so the sibling layout is relocatable by construction, and the only
//! check left is that `hdc.exe` imports the sibling exactly when it is there.
//! It is not a loader or a signature check; the caller owns file identity
//! and the open handle.
use std::{fmt, fs::File, io, os::windows::fs::FileExt};

pub const USB: &str = "libusb_shared.dll";
const MAX_HEADER_BYTES: usize = 64 * 1024;
const MAX_IMPORTS: usize = 256;
const MAX_NAME_BYTES: usize = 256;
const MACHINE_AMD64: u16 = 0x8664;
const IMAGE_FILE_EXECUTABLE_IMAGE: u16 = 0x0002;
const IMAGE_FILE_DLL: u16 = 0x2000;
const PE32_PLUS: u16 = 0x20b;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Image {
    /// A DLL (`IMAGE_FILE_DLL`) rather than a program.
    pub dll: bool,
    /// The imported DLL names, in import-directory order.
    pub imports: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InspectionError {
    pub code: &'static str,
    pub message: &'static str,
}
impl fmt::Display for InspectionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for InspectionError {}
fn invalid() -> InspectionError {
    InspectionError {
        code: "invalidInput",
        message: "host tool is not a bounded x64 PE image",
    }
}
type Result<T> = std::result::Result<T, InspectionError>;

struct Reader<'a> {
    file: &'a File,
    size: u64,
}
impl Reader<'_> {
    fn read(&self, offset: u64, count: usize) -> Result<Vec<u8>> {
        if count > MAX_HEADER_BYTES || offset > self.size || count as u64 > self.size - offset {
            return Err(invalid());
        }
        let mut bytes = vec![0; count];
        let mut consumed = 0;
        while consumed < count {
            match self
                .file
                .seek_read(&mut bytes[consumed..], offset + consumed as u64)
            {
                Ok(0) => return Err(invalid()),
                Ok(n) => consumed += n,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return Err(invalid()),
            }
        }
        Ok(bytes)
    }
    fn u16(&self, offset: u64) -> Result<u16> {
        let bytes = self.read(offset, 2)?;
        Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
    }
    fn u32(&self, offset: u64) -> Result<u32> {
        let bytes = self.read(offset, 4)?;
        Ok(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }
    /// A NUL-terminated ASCII name at `offset`, bounded.
    fn name(&self, offset: u64) -> Result<String> {
        let available =
            usize::try_from((self.size - offset.min(self.size)).min(MAX_NAME_BYTES as u64))
                .map_err(|_| invalid())?;
        let bytes = self.read(offset, available)?;
        let end = bytes.iter().position(|b| *b == 0).ok_or_else(invalid)?;
        let name = &bytes[..end];
        if name.is_empty() || !name.iter().all(|b| b.is_ascii_graphic()) {
            return Err(invalid());
        }
        String::from_utf8(name.to_vec()).map_err(|_| invalid())
    }
}

struct Section {
    virtual_address: u32,
    virtual_size: u32,
    raw_pointer: u32,
    raw_size: u32,
}

/// The file offset of the relative virtual address `rva`, through the
/// section that holds it.
fn file_offset(sections: &[Section], rva: u32) -> Result<u64> {
    for section in sections {
        let span = section.virtual_size.max(section.raw_size);
        if rva >= section.virtual_address && rva - section.virtual_address < span {
            let within = rva - section.virtual_address;
            if within >= section.raw_size {
                return Err(invalid());
            }
            return Ok(u64::from(section.raw_pointer) + u64::from(within));
        }
    }
    Err(invalid())
}

/// Inspect the x64 PE image `file` (its length at open): whether it is a DLL
/// and which DLLs it imports.
pub fn inspect(file: &File) -> Result<Image> {
    let size = file.metadata().map_err(|_| invalid())?.len();
    let reader = Reader { file, size };
    if reader.read(0, 2)? != b"MZ" {
        return Err(invalid());
    }
    let header = u64::from(reader.u32(0x3c)?);
    if reader.read(header, 4)? != b"PE\0\0" {
        return Err(invalid());
    }
    let coff = header + 4;
    let machine = reader.u16(coff)?;
    let section_count = usize::from(reader.u16(coff + 2)?);
    let optional_size = u64::from(reader.u16(coff + 16)?);
    let characteristics = reader.u16(coff + 18)?;
    if machine != MACHINE_AMD64
        || characteristics & IMAGE_FILE_EXECUTABLE_IMAGE == 0
        || section_count == 0
        || section_count > 96
    {
        return Err(invalid());
    }
    let optional = coff + 20;
    if reader.u16(optional)? != PE32_PLUS || optional_size < 112 + 16 {
        return Err(invalid());
    }
    let directory_count = reader.u32(optional + 108)?;
    let sections_at = optional + optional_size;
    let mut sections = Vec::with_capacity(section_count);
    for index in 0..section_count as u64 {
        let at = sections_at + index * 40;
        sections.push(Section {
            virtual_size: reader.u32(at + 8)?,
            virtual_address: reader.u32(at + 12)?,
            raw_size: reader.u32(at + 16)?,
            raw_pointer: reader.u32(at + 20)?,
        });
    }
    let mut imports = Vec::new();
    // Data directory 1 is the import table.
    if directory_count > 1 && optional_size >= 112 + 16 {
        let rva = reader.u32(optional + 112 + 8)?;
        let length = reader.u32(optional + 112 + 12)?;
        if rva != 0 && length != 0 {
            let mut at = file_offset(&sections, rva)?;
            loop {
                if imports.len() > MAX_IMPORTS {
                    return Err(invalid());
                }
                let descriptor = reader.read(at, 20)?;
                if descriptor.iter().all(|b| *b == 0) {
                    break;
                }
                let name_rva = u32::from_le_bytes([
                    descriptor[12],
                    descriptor[13],
                    descriptor[14],
                    descriptor[15],
                ]);
                imports.push(reader.name(file_offset(&sections, name_rva)?)?);
                at += 20;
            }
        }
    }
    Ok(Image {
        dll: characteristics & IMAGE_FILE_DLL != 0,
        imports,
    })
}

/// Whether `hdc.exe`'s imports name the sibling libusb.
pub fn needs_usb(image: &Image) -> bool {
    image
        .imports
        .iter()
        .any(|name| name.eq_ignore_ascii_case(USB))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn system(name: &str) -> File {
        File::open(
            std::path::PathBuf::from(std::env::var_os("SystemRoot").unwrap())
                .join("System32")
                .join(name),
        )
        .unwrap()
    }

    #[test]
    fn a_program_and_a_dll_are_told_apart_with_their_imports() {
        let program = inspect(&system("whoami.exe")).unwrap();
        assert!(!program.dll);
        assert!(
            program
                .imports
                .iter()
                .any(|name| name.eq_ignore_ascii_case("KERNEL32.dll")),
            "{program:?}"
        );
        assert!(!needs_usb(&program));
        let library = inspect(&system("version.dll")).unwrap();
        assert!(library.dll);
    }

    #[test]
    fn anything_else_is_refused() {
        let directory = std::env::temp_dir().join(format!(
            "arkdeck-pe-{:016x}",
            u64::from_le_bytes(arkdeck_platform::random_bytes().unwrap())
        ));
        std::fs::create_dir(&directory).unwrap();
        for (name, bytes) in [
            ("empty", Vec::new()),
            ("text", b"not a program".to_vec()),
            ("mz", b"MZ\0\0\0\0".to_vec()),
        ] {
            let path = directory.join(name);
            std::fs::write(&path, &bytes).unwrap();
            assert_eq!(
                inspect(&File::open(&path).unwrap()).unwrap_err(),
                invalid(),
                "{name}"
            );
        }
        let _ = std::fs::remove_dir_all(&directory);
    }
}
