//! Bounded, read-only Mach-O load-command inspection for Bootstrap tools.
//!
//! This mirrors `BootstrapToolMachO.swift`: only the HDC sibling libusb layout
//! is eligible for relocation. It is not a general dyld resolver or a signature
//! check. The caller owns file identity/stability checks and the open handle.
use std::{fmt, fs::File, io, ops::Range, os::unix::fs::FileExt};

pub const USB: &str = "libusb_shared.dylib";
pub const USB_LOAD_NAME: &str = "@rpath/libusb_shared.dylib";
const MAX_COMMAND_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Slice {
    pub file_type: u64,
    pub libraries: Vec<String>,
    pub rpaths: Vec<String>,
    pub has_environment: bool,
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
        message: "host tool has malformed or unbounded Mach-O load commands",
    }
}
type Result<T> = std::result::Result<T, InspectionError>;

struct Reader<'a> {
    file: &'a File,
    size: u64,
}
impl Reader<'_> {
    fn read(&self, offset: u64, count: usize) -> Result<Vec<u8>> {
        if count > MAX_COMMAND_BYTES || offset > self.size || count as u64 > self.size - offset {
            return Err(invalid());
        }
        let mut bytes = vec![0; count];
        let mut consumed = 0;
        while consumed < count {
            match self
                .file
                .read_at(&mut bytes[consumed..], offset + consumed as u64)
            {
                Ok(0) => return Err(invalid()),
                Ok(n) => consumed += n,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return Err(invalid()),
            }
        }
        Ok(bytes)
    }

    fn slice(&self, offset: u64, length: u64) -> Result<Slice> {
        if length < 28 {
            return Err(invalid());
        }
        let header = self.read(offset, 28)?;
        let magic = &header[..4];
        let little = matches!(magic, [0xcf, 0xfa, 0xed, 0xfe] | [0xce, 0xfa, 0xed, 0xfe]);
        let wide = matches!(magic, [0xcf, 0xfa, 0xed, 0xfe] | [0xfe, 0xed, 0xfa, 0xcf]);
        if !little && !matches!(magic, [0xfe, 0xed, 0xfa, 0xcf] | [0xfe, 0xed, 0xfa, 0xce]) {
            return Err(invalid());
        }
        let header_size = if wide { 32 } else { 28 };
        let count = number(&header, 16, 4, little);
        let command_bytes = number(&header, 20, 4, little);
        if count == 0
            || count > 4096
            || command_bytes > MAX_COMMAND_BYTES as u64
            || length < header_size
            || command_bytes > length - header_size
        {
            return Err(invalid());
        }
        let commands = self.read(offset + header_size, command_bytes as usize)?;
        let mut cursor = 0;
        let mut libraries = Vec::new();
        let mut rpaths = Vec::new();
        let mut has_environment = false;
        for _ in 0..count {
            if commands.len() - cursor < 8 {
                return Err(invalid());
            }
            let kind = number(&commands, cursor, 4, little);
            let length = number(&commands, cursor + 4, 4, little) as usize;
            if length < 8
                || !length.is_multiple_of(if wide { 8 } else { 4 })
                || length > commands.len() - cursor
            {
                return Err(invalid());
            }
            // LC_LOAD_DYLIB, WEAK, REEXPORT, LAZY and UPWARD affect closure.
            let library = matches!(kind, 0xc | 0x80000018 | 0x8000001f | 0x20 | 0x80000023);
            let rpath = kind == 0x8000001c;
            if library || rpath {
                let minimum = if library { 24 } else { 12 };
                if length < minimum {
                    return Err(invalid());
                }
                let start = number(&commands, cursor + 8, 4, little) as usize;
                if start < minimum || start >= length {
                    return Err(invalid());
                }
                let text = &commands[cursor + start..cursor + length];
                let end = text
                    .iter()
                    .position(|byte| *byte == 0)
                    .ok_or_else(invalid)?;
                if end == 0
                    || end > 4096
                    || !text[..end].iter().all(|byte| *byte >= 32 && *byte != 127)
                {
                    return Err(invalid());
                }
                let value = std::str::from_utf8(&text[..end])
                    .map_err(|_| invalid())?
                    .to_owned();
                if library {
                    libraries.push(value);
                } else {
                    rpaths.push(value);
                }
            }
            if kind == 0x27 {
                has_environment = true;
            }
            cursor += length;
        }
        if cursor != commands.len() {
            return Err(invalid());
        }
        Ok(Slice {
            file_type: number(&header, 12, 4, little),
            libraries,
            rpaths,
            has_environment,
        })
    }
}

// Callers establish bounds before decoding fixed-width words. All current
// headers/tables have widths of four or eight bytes, independent of host endian.
fn number(bytes: &[u8], start: usize, width: usize, little: bool) -> u64 {
    let range = &bytes[start..start + width];
    if little {
        range
            .iter()
            .rev()
            .fold(0, |n, byte| (n << 8) | u64::from(*byte))
    } else {
        range.iter().fold(0, |n, byte| (n << 8) | u64::from(*byte))
    }
}

/// Inspect all slices of an already opened file without changing its offset.
/// No path is opened, no candidate is launched and no file bytes are changed.
pub fn inspect(file: &File) -> Result<Vec<Slice>> {
    let size = file
        .metadata()
        .map_err(|_| InspectionError {
            code: "ioFailure",
            message: "cannot read file identity",
        })?
        .len();
    if size < 4 {
        return Err(invalid());
    }
    let reader = Reader { file, size };
    let magic = reader.read(0, 4)?;
    let fat_little = matches!(
        magic.as_slice(),
        [0xbe, 0xba, 0xfe, 0xca] | [0xbf, 0xba, 0xfe, 0xca]
    );
    let fat_wide = matches!(
        magic.as_slice(),
        [0xca, 0xfe, 0xba, 0xbf] | [0xbf, 0xba, 0xfe, 0xca]
    );
    if fat_little || fat_wide || magic == [0xca, 0xfe, 0xba, 0xbe] {
        let count = number(&reader.read(4, 4)?, 0, 4, fat_little);
        if count == 0 || count > 16 {
            return Err(invalid());
        }
        let stride = if fat_wide { 32 } else { 20 };
        let table = reader.read(8, count as usize * stride)?;
        let mut ranges: Vec<Range<u64>> = Vec::new();
        let mut slices = Vec::new();
        for i in 0..count as usize {
            let width = if fat_wide { 8 } else { 4 };
            let start = number(&table, i * stride + 8, width, fat_little);
            let length = number(
                &table,
                i * stride + if fat_wide { 16 } else { 12 },
                width,
                fat_little,
            );
            if start < 8 + table.len() as u64
                || start > size
                || length == 0
                || length > size - start
            {
                return Err(invalid());
            }
            let range = start..start + length;
            if ranges
                .iter()
                .any(|prior| prior.start < range.end && range.start < prior.end)
            {
                return Err(invalid());
            }
            ranges.push(range);
            slices.push(reader.slice(start, length)?);
        }
        return Ok(slices);
    }
    Ok(vec![reader.slice(0, size)?])
}

pub fn needs_usb(slices: &[Slice]) -> bool {
    slices
        .iter()
        .any(|slice| slice.libraries.iter().any(|path| path == USB_LOAD_NAME))
}

pub fn relocatable(slices: &[Slice], library: bool) -> bool {
    !slices.is_empty()
        && slices.iter().all(|slice| {
            slice.file_type == if library { 6 } else { 2 }
                && !slice.has_environment
                && slice
                    .libraries
                    .iter()
                    .all(|path| system_library(path) || (!library && path == USB_LOAD_NAME))
                && (library
                    || !slice.libraries.iter().any(|path| path == USB_LOAD_NAME)
                    || slice
                        .rpaths
                        .first()
                        .is_some_and(|path| path == "@loader_path/."))
        })
}
fn system_library(path: &str) -> bool {
    (path.starts_with("/usr/lib/") || path.starts_with("/System/Library/Frameworks/"))
        && !path.split('/').any(|part| matches!(part, "." | ".."))
}
