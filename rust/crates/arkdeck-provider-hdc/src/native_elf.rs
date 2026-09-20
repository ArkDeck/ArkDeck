//! Swift `NativeLibraryArtifactValidator`: the host-side verifier of a leased
//! native library. It parses only the closed ELF fields ArkDeck needs for
//! admission — the class, the encoding, the machine and its ABI, the GNU
//! build id, and the OpenHarmony V1 ELF code-sign block appended to the file
//! — and never invokes a build tool or accepts caller-supplied metadata. And
//! Swift `HDCNativeCodeSignHelperArtifact.isStaticExecutable`: the shape the
//! bundled code-sign helper must have.
use sha2::{Digest, Sha256};
use std::fmt;

/// Swift `NativeLibraryArtifactValidator.maximumBytes`.
pub const MAXIMUM_LIBRARY_BYTES: usize = 64 * 1024 * 1024;

/// Swift `HDCNativeLibraryABI`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeAbi {
    Arm64,
    Arm32,
    X86_64,
}

impl NativeAbi {
    pub fn raw(self) -> &'static str {
        match self {
            Self::Arm64 => "arm64-v8a",
            Self::Arm32 => "armeabi-v7a",
            Self::X86_64 => "x86_64",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "arm64-v8a" => Some(Self::Arm64),
            "armeabi-v7a" => Some(Self::Arm32),
            "x86_64" => Some(Self::X86_64),
            _ => None,
        }
    }
}

/// Swift `HDCNativeLibraryCodeSignFacts`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CodeSignFacts {
    pub format_version: i64,
    pub code_sign_version: i64,
    pub signed_data_byte_count: i64,
    pub signature_byte_count: i64,
}

/// Swift `HDCNativeLibraryArtifactFacts`: what the validator proved about
/// the bytes, never what a caller said about them.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NativeLibraryFacts {
    pub abi: NativeAbi,
    pub elf_class_bits: i64,
    pub machine: u16,
    pub build_id: String,
    pub sha256: String,
    pub byte_count: i64,
    pub code_sign: Option<CodeSignFacts>,
}

/// Swift `NativeLibraryArtifactValidationError`, with its descriptions.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ValidationError {
    InvalidElf,
    UnsupportedEncoding,
    UnsupportedMachine(u16),
    ClassMachineMismatch,
    AbiMismatch {
        expected: NativeAbi,
        actual: NativeAbi,
    },
    MissingBuildId,
    MissingOpenHarmonyCodeSignBlock,
    InvalidOpenHarmonyCodeSignBlock,
}

impl fmt::Display for ValidationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidElf => formatter
                .write_str("native library is not a bounded, structurally valid ELF object"),
            Self::UnsupportedEncoding => {
                formatter.write_str("native library must use little-endian ELF encoding")
            }
            Self::UnsupportedMachine(machine) => {
                write!(
                    formatter,
                    "native library ELF machine {machine} is unsupported"
                )
            }
            Self::ClassMachineMismatch => {
                formatter.write_str("native library ELF class does not match its machine")
            }
            Self::AbiMismatch { expected, actual } => write!(
                formatter,
                "native library ABI {} does not match expected {}",
                actual.raw(),
                expected.raw()
            ),
            Self::MissingBuildId => formatter.write_str("native library has no GNU ELF build ID"),
            Self::MissingOpenHarmonyCodeSignBlock => {
                formatter.write_str("native library has no OpenHarmony V1 ELF code-sign block")
            }
            Self::InvalidOpenHarmonyCodeSignBlock => formatter
                .write_str("native library has a malformed OpenHarmony V1 ELF code-sign block"),
        }
    }
}

impl std::error::Error for ValidationError {}

fn read_u16(data: &[u8], offset: usize) -> Option<u16> {
    let bytes = data.get(offset..offset.checked_add(2)?)?;
    Some(u16::from_le_bytes([bytes[0], bytes[1]]))
}

fn read_u32(data: &[u8], offset: usize) -> Option<u32> {
    let bytes = data.get(offset..offset.checked_add(4)?)?;
    Some(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn read_u64(data: &[u8], offset: usize) -> Option<u64> {
    let low = read_u32(data, offset)?;
    let high = read_u32(data, offset.checked_add(4)?)?;
    Some(u64::from(low) | (u64::from(high) << 32))
}

/// Swift `NativeLibraryArtifactValidator.validate`.
pub fn validate_elf(
    data: &[u8],
    expected_abi: Option<NativeAbi>,
    require_open_harmony_code_signature: bool,
) -> Result<NativeLibraryFacts, ValidationError> {
    if !(64..=MAXIMUM_LIBRARY_BYTES).contains(&data.len()) || data[..4] != [0x7f, 0x45, 0x4c, 0x46]
    {
        return Err(ValidationError::InvalidElf);
    }
    let elf_class = data[4];
    if elf_class != 1 && elf_class != 2 {
        return Err(ValidationError::InvalidElf);
    }
    if data[5] != 1 {
        return Err(ValidationError::UnsupportedEncoding);
    }
    let machine = read_u16(data, 18).ok_or(ValidationError::InvalidElf)?;
    let abi = match machine {
        183 => {
            if elf_class != 2 {
                return Err(ValidationError::ClassMachineMismatch);
            }
            NativeAbi::Arm64
        }
        40 => {
            if elf_class != 1 {
                return Err(ValidationError::ClassMachineMismatch);
            }
            NativeAbi::Arm32
        }
        62 => {
            if elf_class != 2 {
                return Err(ValidationError::ClassMachineMismatch);
            }
            NativeAbi::X86_64
        }
        other => return Err(ValidationError::UnsupportedMachine(other)),
    };
    if let Some(expected) = expected_abi
        && expected != abi
    {
        return Err(ValidationError::AbiMismatch {
            expected,
            actual: abi,
        });
    }
    let build_id = build_id(data, elf_class).ok_or(ValidationError::MissingBuildId)?;
    let code_sign = open_harmony_code_sign_facts(data, require_open_harmony_code_signature)?;
    Ok(NativeLibraryFacts {
        abi,
        elf_class_bits: if elf_class == 2 { 64 } else { 32 },
        machine,
        build_id,
        sha256: hex(&Sha256::digest(data)),
        byte_count: data.len() as i64,
        code_sign,
    })
}

/// Swift `HDCNativeCodeSignHelperArtifact.isStaticExecutable`: an ELF
/// executable (`ET_EXEC`) with at least one loadable segment and no
/// interpreter, which is what the bundled code-sign helper must be to run on
/// a device that has no loader for it.
pub fn static_executable(data: &[u8]) -> bool {
    const EXECUTABLE: u16 = 2;
    const LOAD: u32 = 1;
    const INTERPRETER: u32 = 3;
    if read_u16(data, 16) != Some(EXECUTABLE) {
        return false;
    }
    let (Some(offset), Some(entry_size), Some(count)) = (
        read_u64(data, 32).and_then(|value| usize::try_from(value).ok()),
        read_u16(data, 54).map(usize::from),
        read_u16(data, 56).map(usize::from),
    ) else {
        return false;
    };
    if entry_size < 56 || count == 0 || offset > data.len() {
        return false;
    }
    if count > (data.len() - offset) / entry_size {
        return false;
    }
    let mut loadable = false;
    for index in 0..count {
        let Some(kind) = read_u32(data, offset + index * entry_size) else {
            return false;
        };
        if kind == INTERPRETER {
            return false;
        }
        loadable |= kind == LOAD;
    }
    loadable
}

/// Swift `openHarmonyCodeSignFacts(in:required:)`: the V1 sign block that
/// OpenHarmony appends to a code-signed ELF — a 32-byte trailer naming the
/// block, one or two 12-byte block descriptors, the Merkle tree block and
/// the signing info whose signed data must be exactly the bytes before the
/// block.
fn open_harmony_code_sign_facts(
    data: &[u8],
    required: bool,
) -> Result<Option<CodeSignFacts>, ValidationError> {
    const HEADER_SIZE: usize = 32;
    const SIGN_MAGIC: &[u8; 16] = b"elf sign block  ";
    const VERSION: &[u8; 4] = b"1000";
    const INFO_PREFIX_SIZE: usize = 264;
    let invalid = ValidationError::InvalidOpenHarmonyCodeSignBlock;
    if data.len() < HEADER_SIZE {
        return if required {
            Err(ValidationError::MissingOpenHarmonyCodeSignBlock)
        } else {
            Ok(None)
        };
    }
    let header_offset = data.len() - HEADER_SIZE;
    if &data[header_offset..header_offset + 16] != SIGN_MAGIC {
        return if required {
            Err(ValidationError::MissingOpenHarmonyCodeSignBlock)
        } else {
            Ok(None)
        };
    }
    if &data[header_offset + 16..header_offset + 20] != VERSION {
        return Err(invalid);
    }
    let block_size = read_u32(data, header_offset + 20).ok_or(invalid.clone())? as usize;
    let block_count = read_u32(data, header_offset + 24).ok_or(invalid.clone())? as usize;
    if !(1..=2).contains(&block_count)
        || block_size < block_count * 12
        || block_size > 16 * 1024 * 1024
        || block_size > header_offset
    {
        return Err(invalid);
    }
    let block_offset = header_offset - block_size;
    let mut sign_info_offset = None;
    for index in 0..block_count {
        let offset = block_offset + index * 12;
        let kind = read_u16(data, offset).ok_or(invalid.clone())?;
        let candidate = read_u32(data, offset + 8).ok_or(invalid.clone())?;
        if kind == 3 {
            sign_info_offset = Some(candidate as usize);
            break;
        }
    }
    let Some(merkle_relative) =
        sign_info_offset.filter(|offset| *offset > 0 && *offset <= block_size - 8)
    else {
        return Err(invalid);
    };
    let merkle_offset = block_offset + merkle_relative;
    if read_u32(data, merkle_offset) != Some(2) {
        return Err(invalid);
    }
    let merkle_length = read_u32(data, merkle_offset + 4).ok_or(invalid.clone())? as usize;
    if merkle_length > block_size - merkle_relative - 8 {
        return Err(invalid);
    }
    let info_relative = merkle_relative + 8 + merkle_length;
    if info_relative > block_size || block_size - info_relative < INFO_PREFIX_SIZE {
        return Err(invalid);
    }
    let info_offset = block_offset + info_relative;
    if read_u32(data, info_offset) != Some(1) {
        return Err(invalid);
    }
    let length = read_u32(data, info_offset + 4).ok_or(invalid.clone())? as usize;
    if data[info_offset + 8] != 1
        || data[info_offset + 9] != 1
        || data[info_offset + 10] != 12
        || data[info_offset + 11] > 32
    {
        return Err(invalid);
    }
    let signature_size = read_u32(data, info_offset + 12).ok_or(invalid.clone())? as usize;
    let signed_data_size = read_u64(data, info_offset + 16).ok_or(invalid.clone())?;
    if signature_size == 0
        || signature_size > 4 * 1024 * 1024
        || length > block_size - info_relative - 8
        || INFO_PREFIX_SIZE + signature_size > 8 + length
        || signed_data_size != block_offset as u64
        || data[info_offset + 263] != 1
    {
        return Err(invalid);
    }
    Ok(Some(CodeSignFacts {
        format_version: 1,
        code_sign_version: 1,
        signed_data_byte_count: signed_data_size as i64,
        signature_byte_count: signature_size as i64,
    }))
}

/// Swift `buildID(in:elfClass:)`: the GNU build id from the first `SHT_NOTE`
/// section that carries one, as lowercase hex.
fn build_id(data: &[u8], elf_class: u8) -> Option<String> {
    let (section_offset, entry_size_offset, count_offset) = if elf_class == 2 {
        let raw = read_u64(data, 40)?;
        (usize::try_from(raw).ok()?, 58, 60)
    } else {
        (read_u32(data, 32)? as usize, 46, 48)
    };
    let entry_size = read_u16(data, entry_size_offset)? as usize;
    let count = read_u16(data, count_offset)? as usize;
    let minimum_entry_size = if elf_class == 2 { 64 } else { 40 };
    if section_offset == 0
        || entry_size < minimum_entry_size
        || count == 0
        || count > 65_535
        || section_offset > data.len()
        || entry_size > data.len()
        || count > (data.len() - section_offset) / entry_size
    {
        return None;
    }
    for index in 0..count {
        let header = section_offset + index * entry_size;
        if read_u32(data, header + 4) != Some(7) {
            continue;
        }
        let (note_offset, note_size) = if elf_class == 2 {
            match (read_u64(data, header + 24), read_u64(data, header + 32)) {
                (Some(offset), Some(size)) => {
                    match (usize::try_from(offset), usize::try_from(size)) {
                        (Ok(offset), Ok(size)) => (offset, size),
                        _ => continue,
                    }
                }
                _ => continue,
            }
        } else {
            match (read_u32(data, header + 16), read_u32(data, header + 20)) {
                (Some(offset), Some(size)) => (offset as usize, size as usize),
                _ => continue,
            }
        };
        if note_offset > data.len() || note_size > data.len() - note_offset {
            continue;
        }
        if let Some(build_id) = parse_build_id_notes(data, note_offset, note_offset + note_size) {
            return Some(build_id);
        }
    }
    None
}

/// Swift `parseBuildIDNotes`: the notes of one section walked with 4-byte
/// alignment; the first `NT_GNU_BUILD_ID` (type 3, name `GNU`) with a
/// non-empty descriptor is the build id.
fn parse_build_id_notes(data: &[u8], lower: usize, upper: usize) -> Option<String> {
    let mut cursor = lower;
    while cursor + 12 <= upper {
        let name_size = read_u32(data, cursor)? as usize;
        let description_size = read_u32(data, cursor + 4)? as usize;
        let kind = read_u32(data, cursor + 8)?;
        let name_start = cursor + 12;
        let padded_name = aligned4(name_size)?;
        if name_start > upper || padded_name > upper - name_start {
            return None;
        }
        let description_start = name_start + padded_name;
        let padded_description = aligned4(description_size)?;
        if description_start > upper || padded_description > upper - description_start {
            return None;
        }
        if kind == 3
            && name_size >= 3
            && &data[name_start..name_start + 3] == b"GNU"
            && description_size > 0
        {
            return Some(hex(
                &data[description_start..description_start + description_size]
            ));
        }
        cursor = description_start + padded_description;
    }
    None
}

fn aligned4(value: usize) -> Option<usize> {
    value.checked_add(3).map(|padded| padded & !3)
}

/// Swift `HDCNativeCodeSignHelperArtifact.isStaticExecutable`: an ELF
/// executable (`e_type` 2) with a `PT_LOAD` segment and no `PT_INTERP`.
pub fn is_static_executable(data: &[u8]) -> bool {
    const ELF_EXECUTABLE: u16 = 2;
    const PROGRAM_LOAD: u32 = 1;
    const PROGRAM_INTERPRETER: u32 = 3;
    if read_u16(data, 16) != Some(ELF_EXECUTABLE) {
        return false;
    }
    let (Some(offset), Some(entry_size), Some(count)) =
        (read_u64(data, 32), read_u16(data, 54), read_u16(data, 56))
    else {
        return false;
    };
    let Ok(offset) = usize::try_from(offset) else {
        return false;
    };
    let (entry_size, count) = (entry_size as usize, count as usize);
    if entry_size < 56
        || count == 0
        || offset > data.len()
        || count > (data.len() - offset) / entry_size
    {
        return false;
    }
    let mut has_load = false;
    for index in 0..count {
        let Some(kind) = read_u32(data, offset + index * entry_size) else {
            return false;
        };
        if kind == PROGRAM_INTERPRETER {
            return false;
        }
        has_load = has_load || kind == PROGRAM_LOAD;
    }
    has_load
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// The oracle's synthetic arm64 library: a code-signed ELF with a GNU
    /// build id, checked in with the deploy-native-library fixture.
    fn fixture() -> Vec<u8> {
        std::fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR")).join(
                "../../tests/fixtures/deploy-native-library/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397",
            ),
        )
        .unwrap()
    }

    #[test]
    fn the_fixture_library_validates_as_swift_recorded_it() {
        let bytes = fixture();
        let facts = validate_elf(&bytes, Some(NativeAbi::Arm64), true).unwrap();
        assert_eq!(facts.abi, NativeAbi::Arm64);
        assert_eq!(facts.elf_class_bits, 64);
        assert_eq!(facts.machine, 183);
        assert_eq!(facts.build_id, "00112233445566778899aabbccddeeff10213243");
        assert_eq!(
            facts.sha256,
            "f8cd1ccd46071323e6b3b8e1a6b2246b7b4ea5d5f71d6ea9990e33ec722f5b53"
        );
        assert_eq!(facts.byte_count, 588);
        let code_sign = facts.code_sign.unwrap();
        assert_eq!(
            (code_sign.format_version, code_sign.code_sign_version),
            (1, 1)
        );
        assert!(code_sign.signature_byte_count > 0);
        assert_eq!(
            validate_elf(&bytes, None, false).unwrap().abi,
            NativeAbi::Arm64
        );
        assert_eq!(
            validate_elf(&bytes, Some(NativeAbi::X86_64), false)
                .unwrap_err()
                .to_string(),
            "native library ABI arm64-v8a does not match expected x86_64"
        );
    }

    /// Every refusal of the validator, on the fixture's bytes disturbed one
    /// field at a time.
    #[test]
    fn the_validator_refuses_what_swift_refuses() {
        let bytes = fixture();
        assert_eq!(
            validate_elf(&bytes[..63], None, false),
            Err(ValidationError::InvalidElf)
        );
        let mut magic = bytes.clone();
        magic[1] = b'X';
        assert_eq!(
            validate_elf(&magic, None, false),
            Err(ValidationError::InvalidElf)
        );
        let mut class = bytes.clone();
        class[4] = 3;
        assert_eq!(
            validate_elf(&class, None, false),
            Err(ValidationError::InvalidElf)
        );
        let mut big_endian = bytes.clone();
        big_endian[5] = 2;
        assert_eq!(
            validate_elf(&big_endian, None, false),
            Err(ValidationError::UnsupportedEncoding)
        );
        let mut arm32_in_class64 = bytes.clone();
        arm32_in_class64[18..20].copy_from_slice(&40u16.to_le_bytes());
        assert_eq!(
            validate_elf(&arm32_in_class64, None, false),
            Err(ValidationError::ClassMachineMismatch)
        );
        let mut x86 = bytes.clone();
        x86[18..20].copy_from_slice(&62u16.to_le_bytes());
        assert_eq!(
            validate_elf(&x86, None, false).unwrap().abi,
            NativeAbi::X86_64
        );
        let mut unknown = bytes.clone();
        unknown[18..20].copy_from_slice(&1u16.to_le_bytes());
        assert_eq!(
            validate_elf(&unknown, None, false),
            Err(ValidationError::UnsupportedMachine(1))
        );
        assert_eq!(
            ValidationError::UnsupportedMachine(1).to_string(),
            "native library ELF machine 1 is unsupported"
        );
        let mut no_sections = bytes.clone();
        no_sections[60..62].copy_from_slice(&0u16.to_le_bytes());
        assert_eq!(
            validate_elf(&no_sections, None, false),
            Err(ValidationError::MissingBuildId)
        );
        // The trailer's magic taken away: no block, which only a required
        // signature refuses.
        let mut unsigned = bytes.clone();
        let header = unsigned.len() - 32;
        unsigned[header] = b'x';
        assert_eq!(
            validate_elf(&unsigned, None, true),
            Err(ValidationError::MissingOpenHarmonyCodeSignBlock)
        );
        assert_eq!(
            validate_elf(&unsigned, None, false).unwrap().code_sign,
            None
        );
        let mut version = bytes.clone();
        version[header + 16] = b'2';
        assert_eq!(
            validate_elf(&version, None, false),
            Err(ValidationError::InvalidOpenHarmonyCodeSignBlock)
        );
        let mut oversized = bytes.clone();
        oversized[header + 20..header + 24].copy_from_slice(&u32::MAX.to_le_bytes());
        assert_eq!(
            validate_elf(&oversized, None, true),
            Err(ValidationError::InvalidOpenHarmonyCodeSignBlock)
        );
        assert_eq!(
            ValidationError::InvalidOpenHarmonyCodeSignBlock.to_string(),
            "native library has a malformed OpenHarmony V1 ELF code-sign block"
        );
    }

    /// The helper's shape: an ELF executable with a load segment and no
    /// interpreter; a shared object (the fixture library) is not one.
    #[test]
    fn a_static_executable_has_a_load_segment_and_no_interpreter() {
        assert!(!is_static_executable(&fixture()));
        let mut executable = vec![0u8; 64 + 56 * 2];
        executable[..4].copy_from_slice(&[0x7f, 0x45, 0x4c, 0x46]);
        executable[16..18].copy_from_slice(&2u16.to_le_bytes());
        executable[32..40].copy_from_slice(&64u64.to_le_bytes());
        executable[54..56].copy_from_slice(&56u16.to_le_bytes());
        executable[56..58].copy_from_slice(&1u16.to_le_bytes());
        executable[64..68].copy_from_slice(&1u32.to_le_bytes());
        assert!(is_static_executable(&executable));
        executable[56..58].copy_from_slice(&2u16.to_le_bytes());
        executable[120..124].copy_from_slice(&3u32.to_le_bytes());
        assert!(!is_static_executable(&executable), "an interpreter");
        executable[120..124].copy_from_slice(&2u32.to_le_bytes());
        assert!(is_static_executable(&executable));
        executable[64..68].copy_from_slice(&2u32.to_le_bytes());
        assert!(!is_static_executable(&executable), "no load segment");
        executable[16..18].copy_from_slice(&3u16.to_le_bytes());
        assert!(!is_static_executable(&executable), "a shared object");
    }
}
