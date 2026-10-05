//! Fixed PE FileVersion from the already retained, SHA-pinned executable.
//! No pathname version API, MUI lookup or child process selects other bytes.
use crate::VerifiedTool;
use std::collections::BTreeSet;
use std::fs::File;
use std::io;
use std::os::windows::fs::FileExt;

const MAX_RESOURCE_BYTES: usize = 1024 * 1024;
const MAX_RESOURCE_ENTRIES: usize = 256;
const MAX_VERSION_LEAVES: usize = 64;

fn malformed() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "executable PE FileVersion is absent, malformed or ambiguous",
    )
}

fn bytes(data: &[u8], offset: usize, count: usize) -> io::Result<&[u8]> {
    data.get(offset..offset.checked_add(count).ok_or_else(malformed)?)
        .ok_or_else(malformed)
}

fn word(data: &[u8], offset: usize) -> io::Result<u16> {
    let value = bytes(data, offset, 2)?;
    Ok(u16::from_le_bytes([value[0], value[1]]))
}

fn dword(data: &[u8], offset: usize) -> io::Result<u32> {
    let value = bytes(data, offset, 4)?;
    Ok(u32::from_le_bytes([value[0], value[1], value[2], value[3]]))
}

fn retained_bytes(file: &File, offset: u64, count: usize) -> io::Result<Vec<u8>> {
    let mut result = vec![0; count];
    let mut consumed = 0;
    while consumed < count {
        match file.seek_read(&mut result[consumed..], offset + consumed as u64) {
            Ok(0) => return Err(malformed()),
            Ok(size) => consumed += size,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    Ok(result)
}

impl VerifiedTool {
    /// The four fixed numeric FileVersion components embedded in this exact
    /// retained PE image. Every resource language/name must agree. Strings,
    /// external MUI files and `--version` output do not supply this value.
    pub fn file_version(&self) -> io::Result<String> {
        self.revalidate()?;
        let length = self.file.metadata()?.len();
        let result = image_version(length, |offset, count| {
            retained_bytes(&self.file, offset, count)
        });
        self.revalidate()?;
        result
    }
}

fn image_version(
    length: u64,
    mut read: impl FnMut(u64, usize) -> io::Result<Vec<u8>>,
) -> io::Result<String> {
    // VerifiedTool already has a 512 MiB image bound; retain it here too for
    // synthetic/standalone parser inputs. Only bounded headers/resources are
    // allocated; the pre/post revalidations hash the whole retained image.
    if length == 0 || length > 512 * 1024 * 1024 {
        return Err(malformed());
    }
    let mut block = |offset: u64, count: usize| {
        if count > MAX_RESOURCE_BYTES
            || offset
                .checked_add(count as u64)
                .is_none_or(|end| end > length)
        {
            return Err(malformed());
        }
        let value = read(offset, count)?;
        if value.len() != count {
            return Err(malformed());
        }
        Ok(value)
    };
    let dos = block(0, 64)?;
    if bytes(&dos, 0, 2)? != b"MZ" {
        return Err(malformed());
    }
    let pe_offset = u64::from(dword(&dos, 60)?);
    let coff = block(pe_offset, 24)?;
    if bytes(&coff, 0, 4)? != b"PE\0\0" {
        return Err(malformed());
    }
    let sections = usize::from(word(&coff, 6)?);
    let optional_size = usize::from(word(&coff, 20)?);
    if !(1..=96).contains(&sections) || !(1..=4096).contains(&optional_size) {
        return Err(malformed());
    }
    let optional = block(pe_offset + 24, optional_size)?;
    let directory_start = match word(&optional, 0)? {
        0x10b => 96,  // PE32
        0x20b => 112, // PE32+
        _ => return Err(malformed()),
    };
    let directories =
        usize::try_from(dword(&optional, directory_start - 4)?).map_err(|_| malformed())?;
    if directories < 3 || directories > (optional_size.saturating_sub(directory_start) / 8) {
        return Err(malformed());
    }
    let resource_rva = dword(&optional, directory_start + 16)?;
    let resource_size =
        usize::try_from(dword(&optional, directory_start + 20)?).map_err(|_| malformed())?;
    if resource_rva == 0 || !(16..=MAX_RESOURCE_BYTES).contains(&resource_size) {
        return Err(malformed());
    }
    let table = block(pe_offset + 24 + optional_size as u64, sections * 40)?;
    let mut resource_offset = None;
    for section in table.as_chunks::<40>().0 {
        let virtual_start = u64::from(dword(section, 12)?);
        let virtual_size = u64::from(dword(section, 8)?);
        let raw_size = u64::from(dword(section, 16)?);
        let raw_start = u64::from(dword(section, 20)?);
        let resource_start = u64::from(resource_rva);
        let resource_end = resource_start + resource_size as u64;
        if resource_start >= virtual_start + virtual_size.max(raw_size)
            || virtual_start >= resource_end
        {
            continue;
        }
        let Some(relative) = u64::from(resource_rva).checked_sub(virtual_start) else {
            return Err(malformed());
        };
        if relative + resource_size as u64 > raw_size {
            return Err(malformed());
        }
        let offset = raw_start + relative;
        if offset + resource_size as u64 > length || resource_offset.replace(offset).is_some() {
            return Err(malformed());
        }
    }
    let resource = block(resource_offset.ok_or_else(malformed)?, resource_size)?;
    resource_version(&resource, resource_rva)
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
enum ResourceKey {
    Id(u32),
    Name(String),
}

fn directory(resource: &[u8], offset: usize) -> io::Result<Vec<(ResourceKey, u32)>> {
    let header = bytes(resource, offset, 16)?;
    let named = usize::from(word(header, 12)?);
    let count = named + usize::from(word(header, 14)?);
    if count == 0 || count > MAX_RESOURCE_ENTRIES {
        return Err(malformed());
    }
    let entries = bytes(resource, offset + 16, count * 8)?;
    let mut seen = BTreeSet::new();
    let mut result = Vec::with_capacity(count);
    for (index, entry) in entries.as_chunks::<8>().0.iter().enumerate() {
        let value = dword(entry, 0)?;
        let is_named = value & 0x8000_0000 != 0;
        if is_named != (index < named) {
            return Err(malformed());
        }
        let key = if is_named {
            let start = (value & 0x7fff_ffff) as usize;
            let characters = usize::from(word(resource, start)?);
            if characters == 0 || characters > 256 {
                return Err(malformed());
            }
            let utf16 = bytes(resource, start + 2, characters * 2)?
                .as_chunks::<2>()
                .0
                .iter()
                .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
                .collect::<Vec<_>>();
            ResourceKey::Name(String::from_utf16(&utf16).map_err(|_| malformed())?)
        } else {
            if value > u32::from(u16::MAX) {
                return Err(malformed());
            }
            ResourceKey::Id(value)
        };
        if !seen.insert(key.clone()) {
            return Err(malformed());
        }
        result.push((key, dword(entry, 4)?));
    }
    Ok(result)
}

fn subtree(target: u32) -> io::Result<usize> {
    if target & 0x8000_0000 == 0 {
        return Err(malformed());
    }
    Ok((target & 0x7fff_ffff) as usize)
}

fn resource_version(resource: &[u8], resource_rva: u32) -> io::Result<String> {
    let root = directory(resource, 0)?;
    let target = root
        .iter()
        .find(|(key, _)| *key == ResourceKey::Id(16))
        .ok_or_else(malformed)?
        .1;
    let names = directory(resource, subtree(target)?)?;
    if names.len() > MAX_VERSION_LEAVES {
        return Err(malformed());
    }
    let mut version = None;
    let mut leaves = 0;
    for (_, target) in names {
        for (language, target) in directory(resource, subtree(target)?)? {
            leaves += 1;
            if leaves > MAX_VERSION_LEAVES
                || !matches!(language, ResourceKey::Id(_))
                || target & 0x8000_0000 != 0
            {
                return Err(malformed());
            }
            let data = bytes(resource, target as usize, 16)?;
            let offset = dword(data, 0)?
                .checked_sub(resource_rva)
                .ok_or_else(malformed)? as usize;
            let count = dword(data, 4)? as usize;
            if dword(data, 12)? != 0 {
                return Err(malformed());
            }
            let observed = fixed_version(bytes(resource, offset, count)?)?;
            if version
                .as_ref()
                .is_some_and(|expected| *expected != observed)
            {
                return Err(malformed());
            }
            version = Some(observed);
        }
    }
    version.ok_or_else(malformed)
}

fn fixed_version(data: &[u8]) -> io::Result<String> {
    let length = usize::from(word(data, 0)?);
    if !(92..=data.len()).contains(&length)
        || data.len() - length > 3
        || bytes(data, length, data.len() - length)?
            .iter()
            .any(|byte| *byte != 0)
        || word(data, 2)? != 52
        || word(data, 4)? != 0
    {
        return Err(malformed());
    }
    for (index, expected) in "VS_VERSION_INFO\0".encode_utf16().enumerate() {
        if word(data, 6 + index * 2)? != expected {
            return Err(malformed());
        }
    }
    if bytes(data, 38, 2)? != [0, 0]
        || dword(data, 40)? != 0xfeef_04bd
        || dword(data, 44)? != 0x0001_0000
        // VS_FF_INFOINFERRED is dynamically synthesized, never an on-disk
        // resource's authoritative FileVersion.
        || dword(data, 68)? & 0x10 != 0
    {
        return Err(malformed());
    }
    let major_minor = dword(data, 48)?;
    let build_revision = dword(data, 52)?;
    Ok(format!(
        "{}.{}.{}.{}",
        major_minor >> 16,
        major_minor & 0xffff,
        build_revision >> 16,
        build_revision & 0xffff
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    use std::io::Write;
    use std::path::PathBuf;

    fn put_word(image: &mut [u8], offset: usize, value: u16) {
        image[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
    }

    fn put_dword(image: &mut [u8], offset: usize, value: u32) {
        image[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    }

    fn section_offset(pe64: bool) -> usize {
        0x80 + 24 + if pe64 { 240 } else { 224 }
    }

    fn fixture(pe64: bool) -> Vec<u8> {
        let mut image = vec![0; 0x300];
        image[..2].copy_from_slice(b"MZ");
        put_dword(&mut image, 60, 0x80);
        image[0x80..0x84].copy_from_slice(b"PE\0\0");
        put_word(&mut image, 0x86, 1);
        put_word(&mut image, 0x94, if pe64 { 240 } else { 224 });
        let optional = 0x98;
        put_word(&mut image, optional, if pe64 { 0x20b } else { 0x10b });
        let directory = optional + if pe64 { 112 } else { 96 };
        put_dword(&mut image, directory - 4, 16);
        put_dword(&mut image, directory + 16, 0x1000);
        put_dword(&mut image, directory + 20, 256);
        let section = section_offset(pe64);
        image[section..section + 5].copy_from_slice(b".rsrc");
        put_dword(&mut image, section + 8, 256);
        put_dword(&mut image, section + 12, 0x1000);
        put_dword(&mut image, section + 16, 256);
        put_dword(&mut image, section + 20, 0x200);
        let resource = &mut image[0x200..];
        // RT_VERSION -> resource name 1 -> language 1033 -> same-image data.
        put_word(resource, 14, 1);
        put_dword(resource, 16, 16);
        put_dword(resource, 20, 0x8000_0020);
        put_word(resource, 32 + 14, 1);
        put_dword(resource, 48, 1);
        put_dword(resource, 52, 0x8000_0040);
        put_word(resource, 64 + 14, 1);
        put_dword(resource, 80, 1033);
        put_dword(resource, 84, 96);
        put_dword(resource, 96, 0x1080);
        put_dword(resource, 100, 92);
        let fixed = &mut resource[128..220];
        put_word(fixed, 0, 92);
        put_word(fixed, 2, 52);
        for (index, character) in "VS_VERSION_INFO\0".encode_utf16().enumerate() {
            put_word(fixed, 6 + index * 2, character);
        }
        put_dword(fixed, 40, 0xfeef_04bd);
        put_dword(fixed, 44, 0x0001_0000);
        put_dword(fixed, 48, (1 << 16) | 2);
        put_dword(fixed, 52, (3 << 16) | 4);
        image
    }

    fn parse(image: &[u8]) -> io::Result<String> {
        image_version(image.len() as u64, |offset, count| {
            Ok(bytes(image, offset as usize, count)?.to_vec())
        })
    }

    #[test]
    fn fixed_file_version_comes_from_pe32_and_pe64_values() {
        for pe64 in [false, true] {
            let mut image = fixture(pe64);
            assert_eq!(parse(&image).unwrap(), "1.2.3.4");
            put_dword(&mut image, 0x200 + 128 + 48, 0xffff_fffe);
            put_dword(&mut image, 0x200 + 128 + 52, 0xfffd_fffc);
            assert_eq!(parse(&image).unwrap(), "65535.65534.65533.65532");
        }
    }

    #[test]
    fn every_truncated_prefix_is_refused_without_panicking() {
        let image = fixture(true);
        for size in 0..image.len() {
            assert!(parse(&image[..size]).is_err(), "prefix size {size}");
        }
    }

    #[test]
    fn malformed_or_missing_pe_and_resource_fields_are_refused() {
        let edits: &[(usize, u32)] = &[
            (0, 0),
            (60, u32::MAX),
            (0x80, 0),
            (0x86, 0),
            (0x86, 97),
            (0x94, 0),
            (0x94, 4097),
            (0x98, 0),
            (0x98 + 108, 2),
            (0x98 + 108, 17),
            (0x98 + 128, 0),
            (0x98 + 132, 0),
            (0x98 + 132, 1024 * 1024 + 1),
            (0x188 + 12, 0x2000),
            (0x188 + 16, 255),
            (0x188 + 20, u32::MAX),
            (0x200 + 12, 257 << 16),
            (0x200 + 16, 15),
            (0x200 + 20, 32),
            (0x200 + 20, 0x8000_0000),
            (0x200 + 52, 0x800f_ffff),
            (0x200 + 84, 0x8000_0060),
            (0x200 + 96, 0x0fff),
            (0x200 + 100, 257),
            (0x200 + 108, 1),
            (0x200 + 128, 0),
            (0x200 + 128 + 2, 51),
            (0x200 + 128 + 4, 1),
            (0x200 + 128 + 6, 0),
            (0x200 + 128 + 40, 0),
            (0x200 + 128 + 44, 0),
            (0x200 + 128 + 68, 0x10),
        ];
        for (offset, value) in edits {
            let mut image = fixture(true);
            put_dword(&mut image, *offset, *value);
            assert!(
                parse(&image).is_err(),
                "offset {offset:#x}, value {value:#x}"
            );
        }
    }

    #[test]
    fn overlapping_sections_and_duplicate_resource_keys_are_ambiguous() {
        let mut image = fixture(true);
        let section = section_offset(true);
        let duplicate = image[section..section + 40].to_vec();
        put_word(&mut image, 0x86, 2);
        image[section + 40..section + 80].copy_from_slice(&duplicate);
        assert!(parse(&image).is_err());
        // A second section covering only some version bytes is ambiguous too.
        put_dword(&mut image, section + 40 + 12, 0x1080);
        put_dword(&mut image, section + 40 + 8, 128);
        put_dword(&mut image, section + 40 + 16, 128);
        assert!(parse(&image).is_err());
        let mut image = fixture(true);
        let duplicate = image[0x210..0x218].to_vec();
        put_word(&mut image, 0x200 + 14, 2);
        image[0x218..0x220].copy_from_slice(&duplicate);
        assert!(parse(&image).is_err());
    }

    #[test]
    fn resource_languages_must_agree_on_the_same_fixed_version() {
        let mut image = fixture(true);
        image.resize(0x400, 0);
        put_dword(&mut image, 0x98 + 132, 512);
        put_dword(&mut image, section_offset(true) + 16, 512);
        let fixed = image[0x280..0x2dc].to_vec();
        let resource = &mut image[0x200..];
        put_word(resource, 64 + 14, 2);
        put_dword(resource, 88, 1031);
        put_dword(resource, 92, 112);
        put_dword(resource, 112, 0x10e0);
        put_dword(resource, 116, 92);
        resource[224..316].copy_from_slice(&fixed);
        assert_eq!(parse(&image).unwrap(), "1.2.3.4");
        put_dword(&mut image, 0x200 + 224 + 48, (2 << 16) | 2);
        assert!(parse(&image).is_err());
    }

    #[test]
    fn reads_are_bounded_to_headers_and_embedded_resources() {
        let image = fixture(true);
        let mut reads = Vec::new();
        assert_eq!(
            image_version(512 * 1024 * 1024, |offset, count| {
                reads.push((offset, count));
                Ok(bytes(&image, offset as usize, count)?.to_vec())
            })
            .unwrap(),
            "1.2.3.4"
        );
        assert!(reads.iter().all(|(_, count)| *count <= MAX_RESOURCE_BYTES));
        assert!(reads.iter().map(|(_, count)| count).sum::<usize>() < 1024);
        assert!(
            image_version(512 * 1024 * 1024 + 1, |_, _| panic!(
                "oversize input must not read"
            ))
            .is_err()
        );
    }

    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = PathBuf::from(crate::windows::runtime_home().unwrap()).join(format!(
                "ArkDeck-tool-version-test-{}-{stamp}",
                std::process::id()
            ));
            crate::windows::create_private_directory(&path).unwrap();
            Self(crate::windows::host_resolved_path(&path).unwrap())
        }

        fn tool(&self, name: &str, data: &[u8]) -> VerifiedTool {
            let path = self.0.join(name);
            let mut file = crate::windows::create_private_file(&path).unwrap();
            file.write_all(data).unwrap();
            file.sync_all().unwrap();
            drop(file);
            VerifiedTool::open(&path, &format!("{:x}", Sha256::digest(data))).unwrap()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            for name in ["version.exe", "absent.exe", "replaced.exe"] {
                let _ = std::fs::remove_file(self.0.join(name));
            }
            let _ = std::fs::remove_dir(&self.0);
        }
    }

    #[test]
    fn retained_file_version_preserves_pin_and_denies_writes_or_replacement() {
        let scratch = Scratch::new();
        let image = fixture(true);
        let tool = scratch.tool("version.exe", &image);
        assert_eq!(tool.file_version().unwrap(), "1.2.3.4");
        assert!(VerifiedTool::open(tool.path(), &"0".repeat(64)).is_err());
        assert!(
            std::fs::OpenOptions::new()
                .write(true)
                .open(tool.path())
                .is_err()
        );
        assert!(std::fs::rename(tool.path(), scratch.0.join("replaced.exe")).is_err());
        assert_eq!(tool.file_version().unwrap(), "1.2.3.4");
        drop(tool);
        let absent = scratch.tool(
            "absent.exe",
            b"an exact pinned file without PE version metadata",
        );
        assert!(absent.file_version().is_err());
    }
}
