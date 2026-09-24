//! A DAYU200 flash bundle (`images.tar.gz`) read as Swift's production
//! Import policy reads it (`FlashBundleImportPolicy.production`):
//!
//! - Swift `GzipTarArchiveReader.summarize` streams the archive once. It
//!   hashes the archive and every regular member, keeps the partition table
//!   (`parameter.txt`), and scans the system image for the runtime build
//!   version.
//! - `RockchipImageArchiveIntrospection.describe` parses that table.
//! - `RockchipFlashProfile.forBuild` judges the build structurally against
//!   the board.
//!
//! Nothing in the archive is extracted, written out or run. Every refusal is
//! the error as Swift interpolates it.
use crate::strict_json::swift_quoted;
use arkdeck_platform::{INFLATE_WINDOW_BYTES, InflateError, RawInflate};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use unicode_segmentation::UnicodeSegmentation;

/// Swift `GzipTarArchiveReader.maximumGzipHeaderBytes`.
const MAXIMUM_GZIP_HEADER_BYTES: usize = 1 << 16;
/// Swift `RockchipFlashProfile.partitionTableMemberName`.
const PARTITION_TABLE: &str = "parameter.txt";
/// Swift `RockchipFlashProfile.loaderMemberName`.
const LOADER: &str = "MiniLoaderAll.bin";
/// Swift `runtimeVersionPartitionName`.
const RUNTIME_VERSION_PARTITION: &str = "system";
/// Swift `RockchipImageArchiveIntrospection.runtimeVersionKey`.
const RUNTIME_VERSION_KEY: &str = "const.ohos.fullname=";
/// Swift `GzipTarDerivationRequest.captureByteLimit` as the board asks it.
const CAPTURE_BYTE_LIMIT: usize = 1 << 20;
/// Swift `RockchipFlashProfile.dayu200.mappedPartitions`, in write order:
/// each partition and the member that fills it.
const MAPPED: [(&str, &str); 9] = [
    ("uboot", "uboot.img"),
    ("resource", "resource.img"),
    ("boot_linux", "boot_linux.img"),
    ("ramdisk", "ramdisk.img"),
    ("system", "system.img"),
    ("vendor", "vendor.img"),
    ("updater", "updater.img"),
    ("chip_ckm", "chip_ckm.img"),
    ("userdata", "userdata.img"),
];
/// Swift `membershiplessPartitionsWriteForbidden`.
const WRITE_FORBIDDEN: [&str; 6] = [
    "misc",
    "bootctrl",
    "sys-prod",
    "chip-prod",
    "eng_system",
    "eng_chipset",
];

/// Swift `GzipTarArchiveReaderError`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ArchiveError {
    UnreadableFile(String),
    NotGzip,
    UnsupportedCompressionMethod,
    CorruptGzipHeader,
    DecompressionFailed,
    TruncatedArchive,
    CorruptTarHeader(String),
}

impl ArchiveError {
    /// The error as Swift interpolates it.
    pub(crate) fn swift(&self) -> String {
        match self {
            Self::UnreadableFile(path) => format!("unreadableFile({})", swift_quoted(path)),
            Self::NotGzip => "notGzip".into(),
            Self::UnsupportedCompressionMethod => "unsupportedCompressionMethod".into(),
            Self::CorruptGzipHeader => "corruptGzipHeader".into(),
            Self::DecompressionFailed => "decompressionFailed".into(),
            Self::TruncatedArchive => "truncatedArchive".into(),
            Self::CorruptTarHeader(detail) => format!("corruptTarHeader({})", swift_quoted(detail)),
        }
    }
}

fn corrupt(detail: &str) -> ArchiveError {
    ArchiveError::CorruptTarHeader(detail.into())
}

/// Swift `GzipTarMemberSummary`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Member {
    pub(crate) name: String,
    pub(crate) size: i64,
    pub(crate) sha256: String,
}

/// Swift `GzipTarArchiveSummary`, as the board's derivation fills it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Summary {
    pub(crate) archive_size: i64,
    pub(crate) archive_sha256: String,
    pub(crate) members: Vec<Member>,
    pub(crate) captured: BTreeMap<String, Vec<u8>>,
    pub(crate) scanned: Option<String>,
}

/// Swift `GzipTarArchiveReader.summarize(fileAt:derivation:)` with the board's
/// `derivationRequest`, over the archive's bytes. A read that fails ends the
/// input, as Swift's `try? fileHandle.read(upToCount:)` does; `path` names
/// the archive in `unreadableFile`.
pub(crate) fn summarize(input: &mut dyn Read, path: &str) -> Result<Summary, ArchiveError> {
    let mut archive = Sha256::new();
    let mut archive_size: i64 = 0;
    let mut pending: Vec<u8> = Vec::new();
    let mut header_consumed = false;
    let mut inflate = RawInflate::new().ok_or(ArchiveError::DecompressionFailed)?;
    let mut tar = TarSummarizer::default();
    let mut chunk = vec![0; INFLATE_WINDOW_BYTES];
    loop {
        let count = fill(input, &mut chunk);
        if count == 0 {
            break;
        }
        let chunk = &chunk[..count];
        archive.update(chunk);
        archive_size += count as i64;
        let payload: Vec<u8> = if header_consumed {
            chunk.to_vec()
        } else {
            pending.extend_from_slice(chunk);
            let Some(length) = gzip_header_length(&pending)? else {
                if pending.len() > MAXIMUM_GZIP_HEADER_BYTES {
                    return Err(ArchiveError::CorruptGzipHeader);
                }
                continue;
            };
            header_consumed = true;
            let payload = pending[length..].to_vec();
            pending.clear();
            payload
        };
        feed(&mut inflate, &payload, false, &mut tar)?;
    }
    if !header_consumed {
        return Err(if pending.is_empty() {
            ArchiveError::UnreadableFile(path.into())
        } else {
            ArchiveError::CorruptGzipHeader
        });
    }
    feed(&mut inflate, &[], true, &mut tar)?;
    let members = tar.finish()?;
    Ok(Summary {
        archive_size,
        archive_sha256: hex(&archive.finalize()),
        members,
        captured: tar.captured,
        scanned: tar.scanned,
    })
}

/// As many bytes as fit, up to the end of the input.
fn fill(input: &mut dyn Read, buffer: &mut [u8]) -> usize {
    let mut filled = 0;
    while filled < buffer.len() {
        match input.read(&mut buffer[filled..]) {
            Ok(0) => break,
            Ok(count) => filled += count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    filled
}

fn feed(
    inflate: &mut RawInflate,
    payload: &[u8],
    finalize: bool,
    tar: &mut TarSummarizer,
) -> Result<(), ArchiveError> {
    inflate
        .feed(payload, finalize, |window| tar.consume(window))
        .map_err(|error| match error {
            InflateError::DecompressionFailed => ArchiveError::DecompressionFailed,
            InflateError::Truncated => ArchiveError::TruncatedArchive,
            InflateError::Sink(error) => error,
        })
}

fn hex(digest: &[u8]) -> String {
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Swift `gzipHeaderLength(of:)`: the RFC 1952 header's length once enough
/// of it is buffered, `None` while more is needed.
fn gzip_header_length(data: &[u8]) -> Result<Option<usize>, ArchiveError> {
    let bytes = &data[..data.len().min(MAXIMUM_GZIP_HEADER_BYTES)];
    if bytes.len() < 10 {
        return Ok(None);
    }
    if bytes[0] != 0x1f || bytes[1] != 0x8b {
        return Err(ArchiveError::NotGzip);
    }
    if bytes[2] != 8 {
        return Err(ArchiveError::UnsupportedCompressionMethod);
    }
    let flags = bytes[3];
    if flags & 0xe0 != 0 {
        return Err(ArchiveError::CorruptGzipHeader);
    }
    let mut index = 10;
    if flags & 0x04 != 0 {
        if bytes.len() < index + 2 {
            return Ok(None);
        }
        let extra = usize::from(bytes[index]) | usize::from(bytes[index + 1]) << 8;
        index += 2 + extra;
        if bytes.len() < index {
            return Ok(None);
        }
    }
    for terminated in [flags & 0x08 != 0, flags & 0x10 != 0] {
        if !terminated {
            continue;
        }
        let Some(terminator) = bytes[index..].iter().position(|byte| *byte == 0) else {
            return Ok(None);
        };
        index += terminator + 1;
    }
    if flags & 0x02 != 0 {
        index += 2;
        if bytes.len() < index {
            return Ok(None);
        }
    }
    Ok(Some(index))
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum TarState {
    #[default]
    Header,
    MemberContent,
    SkipContent,
    Finished,
}

/// Swift `TarStreamSummarizer`, with the board's derivation.
#[derive(Default)]
struct TarSummarizer {
    state: TarState,
    header: Vec<u8>,
    member_name: String,
    member_size: i64,
    remaining: i64,
    padding_after_content: i64,
    member: Sha256,
    members: Vec<Member>,
    zero_blocks: u32,
    capturing: Option<Vec<u8>>,
    capturing_overflowed: bool,
    scanner: Option<ValueScanner>,
    captured: BTreeMap<String, Vec<u8>>,
    scanned: Option<String>,
}

impl TarSummarizer {
    fn consume(&mut self, input: &[u8]) -> Result<(), ArchiveError> {
        let mut offset = 0;
        while offset < input.len() {
            match self.state {
                TarState::Finished => return Ok(()),
                TarState::Header => {
                    let take = (512 - self.header.len()).min(input.len() - offset);
                    self.header.extend_from_slice(&input[offset..offset + take]);
                    offset += take;
                    if self.header.len() == 512 {
                        let block = std::mem::take(&mut self.header);
                        self.parse_header_block(&block)?;
                    }
                }
                TarState::MemberContent | TarState::SkipContent => {
                    let take = self.remaining.min((input.len() - offset) as i64) as usize;
                    if self.state == TarState::MemberContent && take > 0 {
                        let slice = &input[offset..offset + take];
                        self.member.update(slice);
                        if let Some(capturing) = &mut self.capturing {
                            if capturing.len() + take <= CAPTURE_BYTE_LIMIT {
                                capturing.extend_from_slice(slice);
                            } else {
                                self.capturing_overflowed = true;
                            }
                        }
                        if self.scanned.is_none()
                            && let Some(scanner) = &mut self.scanner
                        {
                            self.scanned = scanner.consume(slice);
                        }
                    }
                    offset += take;
                    self.remaining -= take as i64;
                    if self.remaining == 0 {
                        if self.state == TarState::MemberContent {
                            self.finish_member();
                            // The alignment padding after the content is not
                            // part of the member's digest.
                            self.remaining = self.padding_after_content;
                            self.padding_after_content = 0;
                            self.state = if self.remaining == 0 {
                                TarState::Header
                            } else {
                                TarState::SkipContent
                            };
                        } else {
                            self.state = TarState::Header;
                        }
                    }
                }
            }
        }
        Ok(())
    }

    fn finish(&self) -> Result<Vec<Member>, ArchiveError> {
        match self.state {
            TarState::Finished => Ok(self.members.clone()),
            // Tolerates archives whose trailing zero blocks were trimmed.
            TarState::Header if self.header.is_empty() => Ok(self.members.clone()),
            _ => Err(ArchiveError::TruncatedArchive),
        }
    }

    fn parse_header_block(&mut self, block: &[u8]) -> Result<(), ArchiveError> {
        if block.iter().all(|byte| *byte == 0) {
            self.zero_blocks += 1;
            if self.zero_blocks >= 2 {
                self.state = TarState::Finished;
            }
            return Ok(());
        }
        self.zero_blocks = 0;
        let stored = numeric_field(&block[148..156], "checksum")?;
        let computed: i64 = block
            .iter()
            .enumerate()
            .map(|(index, byte)| {
                if (148..156).contains(&index) {
                    0x20
                } else {
                    i64::from(*byte)
                }
            })
            .sum();
        if stored != computed {
            return Err(corrupt("header checksum mismatch"));
        }
        let mut name = nul_terminated(&block[0..100]);
        let posix = &block[257..262] == b"ustar" && block[262] == 0 && &block[263..265] == b"00";
        if posix {
            let prefix = nul_terminated(&block[345..500]);
            if !prefix.is_empty() {
                name = format!("{prefix}/{name}");
            }
        }
        if name.is_empty() {
            return Err(corrupt("empty member name"));
        }
        let size = numeric_field(&block[124..136], "size")?;
        // A size within one alignment block of the largest integer describes
        // no real member, and the padding below would overflow on it.
        if size > i64::MAX - 511 {
            return Err(corrupt(
                "member size does not leave room for its 512-byte alignment",
            ));
        }
        let padding = (512 - size % 512) % 512;
        // Regular files only: every other record, extension headers
        // included, is skipped as opaque content.
        if block[156] == b'0' || block[156] == 0 {
            self.member_name = name;
            self.member_size = size;
            self.member = Sha256::new();
            self.begin_derivation();
            self.remaining = size;
            self.padding_after_content = padding;
            if self.remaining == 0 {
                self.finish_member();
                self.remaining = self.padding_after_content;
                self.padding_after_content = 0;
                self.state = if self.remaining == 0 {
                    TarState::Header
                } else {
                    TarState::SkipContent
                };
            } else {
                self.state = TarState::MemberContent;
            }
        } else {
            self.remaining = size + padding;
            self.state = if self.remaining == 0 {
                TarState::Header
            } else {
                TarState::SkipContent
            };
        }
        Ok(())
    }

    fn finish_member(&mut self) {
        let digest = std::mem::take(&mut self.member).finalize();
        self.members.push(Member {
            name: self.member_name.clone(),
            size: self.member_size,
            sha256: hex(&digest),
        });
        // A member that overran the capture bound is not kept at all: half a
        // partition table would parse into half a plan.
        if let Some(captured) = self.capturing.take()
            && !self.capturing_overflowed
        {
            self.captured.insert(self.member_name.clone(), captured);
        }
        self.capturing_overflowed = false;
        self.scanner = None;
    }

    /// Swift `beginDerivation(for:)` with the board's request: the partition
    /// table is kept and the system image scanned.
    fn begin_derivation(&mut self) {
        if self.member_name == PARTITION_TABLE {
            self.capturing = Some(Vec::new());
        }
        if self.member_name == system_image() {
            self.scanner = Some(ValueScanner::default());
        }
    }
}

/// The system partition's image, which carries the runtime build version.
fn system_image() -> &'static str {
    MAPPED
        .iter()
        .find(|(partition, _)| *partition == RUNTIME_VERSION_PARTITION)
        .map(|(_, image)| *image)
        .expect("the board maps its system partition")
}

/// Swift `String(decoding:as: UTF8.self)` of the bytes before the first NUL.
fn nul_terminated(bytes: &[u8]) -> String {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

/// Swift `parseNumericField(_:field:)`: GNU base-256 when the first byte's
/// high bit is set, octal otherwise.
fn numeric_field(bytes: &[u8], field: &str) -> Result<i64, ArchiveError> {
    let Some(first) = bytes.first() else {
        return Err(corrupt(&format!("empty numeric field {field}")));
    };
    if first & 0x80 != 0 {
        let mut value = i64::from(first & 0x7f);
        for byte in &bytes[1..] {
            if value > i64::MAX >> 8 {
                return Err(corrupt(&format!("numeric overflow in {field}")));
            }
            value = value << 8 | i64::from(*byte);
        }
        return Ok(value);
    }
    let mut value: i64 = 0;
    let mut seen_digit = false;
    for byte in bytes {
        if *byte == 0x20 || *byte == 0 {
            if seen_digit {
                break;
            }
            continue;
        }
        if !(0x30..=0x37).contains(byte) {
            return Err(corrupt(&format!("invalid octal digit in {field}")));
        }
        if value > (i64::MAX - 7) / 8 {
            return Err(corrupt(&format!("numeric overflow in {field}")));
        }
        seen_digit = true;
        value = value * 8 + i64::from(byte - 0x30);
    }
    Ok(value)
}

/// Swift `StreamingValueScanner` for the runtime version key: the first run
/// of value bytes after the key, found across any chunk boundary.
#[derive(Default)]
struct ValueScanner {
    matched: usize,
    value: Vec<u8>,
    collecting: bool,
}

impl ValueScanner {
    fn consume(&mut self, bytes: &[u8]) -> Option<String> {
        let key = RUNTIME_VERSION_KEY.as_bytes();
        for byte in bytes {
            if self.collecting {
                if value_byte(*byte) {
                    self.value.push(*byte);
                    // A value this long is not a version string: the run is
                    // noise, not a value.
                    if self.value.len() > 256 {
                        self.collecting = false;
                        self.value.clear();
                        self.matched = 0;
                    }
                    continue;
                }
                self.collecting = false;
                if !self.value.is_empty() {
                    return Some(String::from_utf8_lossy(&self.value).into_owned());
                }
                self.matched = 0;
                continue;
            }
            if *byte == key[self.matched] {
                self.matched += 1;
                if self.matched == key.len() {
                    self.collecting = true;
                    self.value.clear();
                    self.matched = 0;
                }
            } else {
                // Restart, the mismatched byte allowed to open a new match.
                self.matched = usize::from(*byte == key[0]);
            }
        }
        None
    }
}

/// Swift `isValueByte`: letters, digits, dot, dash, underscore.
fn value_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_')
}

/// Swift `RockchipArchiveMemberClassification`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Classification {
    MappedPartitionImage,
    OrphanImageWriteForbidden,
    PartitionTable,
    LoaderMaskromBranchOnly,
    NonPartitionMetadata,
}

impl Classification {
    #[cfg(test)]
    pub(crate) fn raw(self) -> &'static str {
        match self {
            Self::MappedPartitionImage => "mappedPartitionImage",
            Self::OrphanImageWriteForbidden => "orphanImageWriteForbidden",
            Self::PartitionTable => "partitionTable",
            Self::LoaderMaskromBranchOnly => "loaderMaskromBranchOnly",
            Self::NonPartitionMetadata => "nonPartitionMetadata",
        }
    }
}

/// Swift `RockchipFlashProfile.classification(ofMemberNamed:)`: a rule over
/// the board's facts and the member's name alone.
pub(crate) fn classification(name: &str) -> Classification {
    if name == PARTITION_TABLE {
        return Classification::PartitionTable;
    }
    if name == LOADER {
        return Classification::LoaderMaskromBranchOnly;
    }
    if MAPPED.iter().any(|(_, image)| *image == name) {
        return Classification::MappedPartitionImage;
    }
    let characters: Vec<&str> = name.graphemes(true).collect();
    if characters.ends_with(&[".", "i", "m", "g"]) {
        // `chip_prod.img` names the `chip-prod` partition.
        let partition: String = characters[..characters.len() - 4]
            .iter()
            .map(|character| if *character == "_" { "-" } else { character })
            .collect();
        if WRITE_FORBIDDEN.contains(&partition.as_str()) {
            return Classification::OrphanImageWriteForbidden;
        }
    }
    Classification::NonPartitionMetadata
}

/// Swift `RockchipArchiveIntrospectionFailure`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum IntrospectionFailure {
    PartitionTableMissing,
    PartitionTableUnparsable(String),
    SystemImageMissing(String),
    RuntimeBuildVersionUnreadable,
}

impl IntrospectionFailure {
    pub(crate) fn swift(&self) -> String {
        match self {
            Self::PartitionTableMissing => "partitionTableMissing".into(),
            Self::PartitionTableUnparsable(detail) => {
                format!("partitionTableUnparsable({})", swift_quoted(detail))
            }
            Self::SystemImageMissing(partition) => {
                format!("systemImageMissing({})", swift_quoted(partition))
            }
            Self::RuntimeBuildVersionUnreadable => "runtimeBuildVersionUnreadable".into(),
        }
    }
}

/// Swift `RockchipDeclaredPartition`: sizes and offsets in sectors, the grow
/// marker `-` as −1.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DeclaredPartition {
    pub(crate) name: String,
    pub(crate) size_sectors: i64,
    pub(crate) offset_sectors: i64,
}

/// Swift `RockchipImageBuildDescriptor`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Build {
    pub(crate) archive_size: i64,
    pub(crate) archive_sha256: String,
    pub(crate) members: Vec<(Member, Classification)>,
    pub(crate) declared: Vec<DeclaredPartition>,
    pub(crate) runtime_build_version: String,
}

/// Swift `RockchipImageArchiveIntrospection.describe(summary:board:)`.
pub(crate) fn describe(summary: &Summary) -> Result<Build, IntrospectionFailure> {
    let members: Vec<(Member, Classification)> = summary
        .members
        .iter()
        .map(|member| (member.clone(), classification(&member.name)))
        .collect();
    let table = summary
        .captured
        .get(PARTITION_TABLE)
        .ok_or(IntrospectionFailure::PartitionTableMissing)?;
    let declared = partitions(table)?;
    if !members
        .iter()
        .any(|(member, _)| member.name == system_image())
    {
        return Err(IntrospectionFailure::SystemImageMissing(
            RUNTIME_VERSION_PARTITION.into(),
        ));
    }
    let version = summary
        .scanned
        .clone()
        .filter(|version| !version.is_empty())
        .ok_or(IntrospectionFailure::RuntimeBuildVersionUnreadable)?;
    Ok(Build {
        archive_size: summary.archive_size,
        archive_sha256: summary.archive_sha256.to_lowercase(),
        members,
        declared,
        runtime_build_version: version,
    })
}

/// A string as Swift sees it: its extended grapheme clusters, its
/// `Character`s.
fn characters(text: &str) -> Vec<&str> {
    text.graphemes(true).collect()
}

/// Swift `split(separator:)` of `Character`s, empty pieces omitted.
fn split<'a>(characters: &[&'a str], separator: &str) -> Vec<Vec<&'a str>> {
    characters
        .split(|character| *character == separator)
        .filter(|piece| !piece.is_empty())
        .map(<[&str]>::to_vec)
        .collect()
}

fn joined(characters: &[&str]) -> String {
    characters.concat()
}

/// Foundation's `CharacterSet.whitespaces`: space separators and tab.
fn whitespace(scalar: char) -> bool {
    matches!(
        scalar,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

/// Swift `partitions(inTable:)`: the `CMDLINE` line's `mtdparts` list, each
/// `size@offset(name[:attribute])` in hexadecimal sectors.
fn partitions(bytes: &[u8]) -> Result<Vec<DeclaredPartition>, IntrospectionFailure> {
    let unparsable = |detail: &str| IntrospectionFailure::PartitionTableUnparsable(detail.into());
    let text = std::str::from_utf8(bytes).map_err(|_| unparsable("not UTF-8"))?;
    let text = characters(text);
    let command_line = split(&text, "\n")
        .into_iter()
        .find(|line| line.starts_with(&["C", "M", "D", "L", "I", "N", "E"]))
        .ok_or_else(|| unparsable("no mtdparts"))?;
    let needle = ["m", "t", "d", "p", "a", "r", "t", "s", "="];
    let start = command_line
        .windows(needle.len())
        .position(|window| window == needle)
        .ok_or_else(|| unparsable("no mtdparts"))?;
    let list = &command_line[start + needle.len()..];
    let colon = list
        .iter()
        .position(|character| *character == ":")
        .ok_or_else(|| unparsable("no device prefix"))?;
    let mut declared = Vec::new();
    for entry in split(&list[colon + 1..], ",") {
        let trimmed = joined(&entry).trim_matches(whitespace).to_owned();
        let entry = characters(&trimmed);
        let open = entry.iter().position(|character| *character == "(");
        let Some(open) = open.filter(|_| entry.last() == Some(&")")) else {
            return Err(unparsable(&trimmed));
        };
        let geometry = &entry[..open];
        let raw_name = &entry[open + 1..entry.len() - 1];
        let name = split(raw_name, ":")
            .first()
            .map_or_else(|| joined(raw_name), |first| joined(first));
        let Some(at) = geometry.iter().position(|character| *character == "@") else {
            return Err(unparsable(&trimmed));
        };
        let Some(offset) = hex_sectors(&geometry[at + 1..]) else {
            return Err(unparsable(&trimmed));
        };
        // `-` is the grow marker: the partition runs to the end of the
        // device.
        let size = if geometry[..at] == ["-"] {
            Some(-1)
        } else {
            hex_sectors(&geometry[..at])
        };
        let Some(size) = size else {
            return Err(unparsable(&trimmed));
        };
        if name.is_empty() {
            return Err(unparsable(&trimmed));
        }
        declared.push(DeclaredPartition {
            name,
            size_sectors: size,
            offset_sectors: offset,
        });
    }
    if declared.is_empty() {
        return Err(unparsable("empty list"));
    }
    Ok(declared)
}

/// Swift `hexSectors(_:)`: an optional `0x`, then at most 16 characters that
/// `Int64(_:radix: 16)` reads, its optional sign included.
fn hex_sectors(text: &[&str]) -> Option<i64> {
    let body = if text.starts_with(&["0", "x"]) || text.starts_with(&["0", "X"]) {
        &text[2..]
    } else {
        text
    };
    if body.is_empty() || body.len() > 16 {
        return None;
    }
    let body = joined(body);
    let (negative, digits) = match body.as_bytes().first() {
        Some(b'-') => (true, &body[1..]),
        Some(b'+') => (false, &body[1..]),
        _ => (false, body.as_str()),
    };
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    let magnitude = i128::from_str_radix(digits, 16).ok()?;
    i64::try_from(if negative { -magnitude } else { magnitude }).ok()
}

/// The board carrying one archive's facts: Swift `RockchipFlashProfile` as
/// `withArchiveBuild` makes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BoardBuild {
    pub(crate) archive_size: i64,
    pub(crate) archive_sha256: String,
    pub(crate) firmware_version: String,
    pub(crate) runtime_build_version: String,
    pub(crate) write_forbidden_members: Vec<String>,
}

/// Swift `RockchipFlashProfile.conformance(of:)`: every mapped partition has
/// an image, and the archive's table declares only partitions the board
/// knows and every one it maps.
fn conformance(build: &Build) -> Vec<String> {
    let members: BTreeSet<&str> = build
        .members
        .iter()
        .map(|(member, _)| member.name.as_str())
        .collect();
    let declared: BTreeSet<&str> = build
        .declared
        .iter()
        .map(|partition| partition.name.as_str())
        .collect();
    let known: BTreeSet<&str> = MAPPED
        .iter()
        .map(|(partition, _)| *partition)
        .chain(WRITE_FORBIDDEN)
        .collect();
    let mut violations = Vec::new();
    for (partition, image) in MAPPED {
        if !members.contains(image) {
            violations.push(format!("mappedPartitionImageMissing:{partition}"));
        }
    }
    for undeclared in declared.difference(&known) {
        violations.push(format!("undeclaredPartitionInTable:{undeclared}"));
    }
    for (partition, _) in MAPPED {
        if !declared.contains(partition) {
            violations.push(format!("mappedPartitionAbsentFromTable:{partition}"));
        }
    }
    if build.runtime_build_version.is_empty() {
        violations.push("runtimeBuildVersionUnreadable".into());
    }
    violations
}

/// Swift `RockchipFlashProfile.forBuild(_:)`: the board carrying the build's
/// facts, or the reason naming every way the build does not fit it; then the
/// profile's own checks. Swift compares member names by canonical
/// equivalence; with no normalization tables here, a name that is not ASCII
/// is refused rather than compared by its bytes (declared, fail-closed).
pub(crate) fn for_build(build: &Build) -> Result<BoardBuild, String> {
    let violations = conformance(build);
    // `DeviceProviderError.unsupportedAction` describes itself as its reason.
    if !violations.is_empty() {
        return Err(format!(
            "flash bundle does not fit dayu200: {}",
            violations.join("; ")
        ));
    }
    let names: BTreeSet<&str> = build
        .members
        .iter()
        .map(|(member, _)| member.name.as_str())
        .collect();
    if names.len() != build.members.len() {
        return Err("invalidProfileDefinition(\"duplicate archive member name\")".into());
    }
    if !names.iter().all(|name| name.is_ascii()) {
        return Err(
            "invalidProfileDefinition(\"archive member names that are not ASCII \
                    cannot be compared as Swift compares them\")"
                .into(),
        );
    }
    Ok(BoardBuild {
        archive_size: build.archive_size,
        archive_sha256: build.archive_sha256.to_lowercase(),
        firmware_version: build.runtime_build_version.clone(),
        runtime_build_version: build.runtime_build_version.clone(),
        write_forbidden_members: build
            .members
            .iter()
            .filter(|(_, classification)| {
                *classification == Classification::OrphanImageWriteForbidden
            })
            .map(|(member, _)| member.name.clone())
            .collect(),
    })
}

/// Swift `FlashBundleImportPolicy.production`'s one candidate: the archive
/// read, described and fitted to the board, answering its byte count and
/// digest; any failure is `invalidBundle`, as its description reads.
pub(crate) fn import_validation(input: &mut dyn Read, path: &str) -> Result<(i64, String), String> {
    let invalid =
        |error: String| format!("flash bundle is not a usable DAYU200 images archive: {error}");
    let summary = summarize(input, path).map_err(|error| invalid(error.swift()))?;
    let build = describe(&summary).map_err(|error| invalid(error.swift()))?;
    for_build(&build).map_err(invalid)?;
    Ok((summary.archive_size, summary.archive_sha256))
}

#[cfg(test)]
mod tests {
    //! The Swift oracle (`rust/tests/fixtures/flash-archive/oracle`, recorded
    //! by `FlashBundleArchiveOracleContractTests` over the archives
    //! `make-archives.py` wrote) replayed: every step's answer for every
    //! archive, and the Import policy's, must be Swift's.
    use super::*;
    use serde_json::{Value, json};
    use std::path::PathBuf;

    fn fixtures() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/flash-archive")
            .canonicalize()
            .unwrap()
    }

    fn failure(error: &str, archives: &str) -> Value {
        json!({"error": error.replace(archives, "<archives>")})
    }

    fn summary_value(summary: &Summary) -> Value {
        json!({
            "archiveSizeBytes": summary.archive_size,
            "archiveSha256": summary.archive_sha256,
            "members": summary.members.iter().map(|member| json!({
                "name": member.name, "sizeBytes": member.size, "sha256": member.sha256,
            })).collect::<Vec<_>>(),
            "captured": summary.captured.iter().map(|(name, bytes)| (
                name.clone(),
                json!({"byteCount": bytes.len(), "sha256": hex(&Sha256::digest(bytes))}),
            )).collect::<serde_json::Map<_, _>>(),
            "scannedValue": summary.scanned,
        })
    }

    fn build_value(build: &Build) -> Value {
        json!({
            "archiveSizeBytes": build.archive_size,
            "archiveSha256": build.archive_sha256,
            "runtimeBuildVersion": build.runtime_build_version,
            "declaredPartitions": build.declared.iter().map(|partition| json!({
                "name": partition.name, "sizeSectors": partition.size_sectors,
                "offsetSectors": partition.offset_sectors,
            })).collect::<Vec<_>>(),
            "members": build.members.iter().map(|(member, classification)| json!({
                "name": member.name, "classification": classification.raw(),
            })).collect::<Vec<_>>(),
        })
    }

    #[test]
    fn every_archive_reads_as_swift_reads_it() {
        let fixtures = fixtures();
        let archives = fixtures.join("archives");
        let archives_path = archives.to_str().unwrap();
        let oracle: Value =
            serde_json::from_slice(&std::fs::read(fixtures.join("oracle/cases.json")).unwrap())
                .unwrap();
        let cases = oracle["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 41);
        for case in cases {
            let name = case["archive"].as_str().unwrap();
            let path = archives.join(name);
            let path_text = path.to_str().unwrap();
            let open = || std::fs::File::open(&path).unwrap();
            let summary = summarize(&mut open(), path_text);
            let summary_answer = match &summary {
                Ok(summary) => summary_value(summary),
                Err(error) => failure(&error.swift(), archives_path),
            };
            assert_eq!(summary_answer, case["summary"], "{name} summary");
            let build = summary.as_ref().ok().map(describe);
            let build_answer = match &build {
                None => Value::Null,
                Some(Ok(build)) => build_value(build),
                Some(Err(error)) => failure(&error.swift(), archives_path),
            };
            assert_eq!(build_answer, case["build"], "{name} build");
            let profile_answer = match build.as_ref().and_then(|build| build.as_ref().ok()) {
                None => Value::Null,
                Some(build) => match for_build(build) {
                    Ok(profile) => json!({
                        "archiveSizeBytes": profile.archive_size,
                        "archiveSha256": profile.archive_sha256,
                        "firmwareVersion": profile.firmware_version,
                        "runtimeBuildVersion": profile.runtime_build_version,
                        "writeForbiddenMemberNames": profile.write_forbidden_members,
                    }),
                    Err(error) => failure(&error, archives_path),
                },
            };
            assert_eq!(profile_answer, case["profile"], "{name} profile");
            let policy_answer = match import_validation(&mut open(), path_text) {
                Ok((byte_count, sha256)) => json!({"byteCount": byte_count, "sha256": sha256}),
                Err(error) => failure(&error, archives_path),
            };
            assert_eq!(policy_answer, case["importPolicy"], "{name} import policy");
        }
    }
}
