//! Xcode's `xcode-select` tool shims, as Swift's `XcodeToolShim` tells and
//! resolves them.
//!
//! `/usr/bin/git`, `clang`, `make`, `python3` and the other developer tools
//! in `/usr/bin` are one file, hard-linked under every name. It picks the
//! tool it runs by the path the kernel reports for the process, never by
//! `argv[0]`. Started from its retained inode (`/.vol/<device>/<inode>`) it
//! reports whichever of its names the file was last looked up by, so a
//! pinned `/usr/bin/git` can run clang, or `make -C <root> stash create` in
//! a project's root, and the digest pinned for it covers no tool at all: the
//! tool it would start lives in the developer directory.
//!
//! A shim is told by the identifier its code signature carries
//! (`com.apple.dt.xcode_select.tool-shim-public` today), never by its name or
//! its link count: `/usr/bin/grep` is linked three times and is no shim.
//! Such a file is never launched from its inode; the tool it names is pinned
//! instead, as `xcrun --find` resolves it with a cleared environment, and
//! that must be a regular Mach-O file that is not a shim itself.
#[cfg(target_os = "macos")]
use std::io;

/// What every `xcode-select` tool shim's signing identifier starts with.
pub const XCODE_TOOL_SHIM_IDENTIFIER: &str = "com.apple.dt.xcode_select.tool-shim";

const FAT_MAGIC: u32 = 0xcafe_babe;
const FAT_MAGIC_64: u32 = 0xcafe_babf;
const MH_MAGIC: u32 = 0xfeed_face;
const MH_MAGIC_64: u32 = 0xfeed_facf;
const MH_CIGAM: u32 = 0xcefa_edfe;
const MH_CIGAM_64: u32 = 0xcffa_edfe;
const LC_CODE_SIGNATURE: u32 = 0x1d;
const CSMAGIC_EMBEDDED_SIGNATURE: u32 = 0xfade_0cc0;
const CSMAGIC_CODEDIRECTORY: u32 = 0xfade_0c02;
const CSSLOT_CODEDIRECTORY: u32 = 0;
const MAXIMUM_ARCHITECTURES: usize = 64;
const MAXIMUM_LOAD_COMMAND_BYTES: u64 = 16 << 20;
const MAXIMUM_SIGNATURE_SLOTS: u64 = 1_024;
const MAXIMUM_IDENTIFIER_BYTES: u64 = 1_024;

/// Bounded reads of a file's bytes, by offset.
trait Bytes {
    fn length(&self) -> u64;
    fn read(&self, offset: u64, length: u64) -> Option<Vec<u8>>;
}

impl Bytes for [u8] {
    fn length(&self) -> u64 {
        self.len() as u64
    }

    fn read(&self, offset: u64, length: u64) -> Option<Vec<u8>> {
        let end = offset.checked_add(length)?;
        let (start, end) = (usize::try_from(offset).ok()?, usize::try_from(end).ok()?);
        self.get(start..end).map(<[u8]>::to_vec)
    }
}

#[cfg(target_os = "macos")]
struct Descriptor<'a> {
    file: &'a std::fs::File,
    length: u64,
}

#[cfg(target_os = "macos")]
impl Bytes for Descriptor<'_> {
    fn length(&self) -> u64 {
        self.length
    }

    fn read(&self, offset: u64, length: u64) -> Option<Vec<u8>> {
        use std::os::unix::fs::FileExt;
        if offset.checked_add(length)? > self.length {
            return None;
        }
        let mut bytes = vec![0; usize::try_from(length).ok()?];
        self.file.read_exact_at(&mut bytes, offset).ok()?;
        Some(bytes)
    }
}

fn big(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

fn big_wide(bytes: &[u8], at: usize) -> Option<u64> {
    Some(u64::from_be_bytes(bytes.get(at..at + 8)?.try_into().ok()?))
}

/// The signing identifier of every architecture a Mach-O file holds, in the
/// order the file lists them, `None` for one that carries no code
/// directory; `None` altogether when the bytes are not a well-formed Mach-O
/// file.
pub fn signing_identifiers(bytes: &[u8]) -> Option<Vec<Option<String>>> {
    identifiers(bytes)
}

/// Whether any architecture is signed as an `xcode-select` tool shim.
pub fn is_tool_shim(identifiers: &[Option<String>]) -> bool {
    identifiers
        .iter()
        .flatten()
        .any(|identifier| identifier.starts_with(XCODE_TOOL_SHIM_IDENTIFIER))
}

/// Whether `bytes` are an `xcode-select` tool shim.
pub fn bytes_are_tool_shim(bytes: &[u8]) -> bool {
    signing_identifiers(bytes).is_some_and(|identifiers| is_tool_shim(&identifiers))
}

/// Whether the file behind a retained descriptor is an `xcode-select` tool
/// shim, read through that descriptor.
#[cfg(target_os = "macos")]
pub(crate) fn file_is_tool_shim(file: &std::fs::File) -> io::Result<bool> {
    let length = file.metadata()?.len();
    Ok(identifiers(&Descriptor { file, length })
        .is_some_and(|identifiers| is_tool_shim(&identifiers)))
}

fn identifiers(bytes: &(impl Bytes + ?Sized)) -> Option<Vec<Option<String>>> {
    let head = bytes.read(0, 8)?;
    let magic = big(&head, 0)?;
    if magic != FAT_MAGIC && magic != FAT_MAGIC_64 {
        return Some(vec![architecture(bytes, 0, bytes.length())?]);
    }
    let count = usize::try_from(big(&head, 4)?).ok()?;
    if count == 0 || count > MAXIMUM_ARCHITECTURES {
        return None;
    }
    let entry = if magic == FAT_MAGIC { 20 } else { 32 };
    let table = bytes.read(8, (count * entry) as u64)?;
    (0..count)
        .map(|index| {
            let at = index * entry;
            let (offset, size) = if magic == FAT_MAGIC {
                (
                    u64::from(big(&table, at + 8)?),
                    u64::from(big(&table, at + 12)?),
                )
            } else {
                (big_wide(&table, at + 8)?, big_wide(&table, at + 16)?)
            };
            if offset.checked_add(size)? > bytes.length() {
                return None;
            }
            architecture(bytes, offset, size)
        })
        .collect()
}

/// One thin Mach-O image at `base`: its code directory's identifier, or
/// `Some(None)` when it is not signed.
fn architecture(bytes: &(impl Bytes + ?Sized), base: u64, size: u64) -> Option<Option<String>> {
    let header = bytes.read(base, 28)?;
    let magic = u32::from_le_bytes(header.get(0..4)?.try_into().ok()?);
    let (little, header_size) = match magic {
        MH_MAGIC => (true, 28),
        MH_MAGIC_64 => (true, 32),
        MH_CIGAM => (false, 28),
        MH_CIGAM_64 => (false, 32),
        _ => return None,
    };
    let word = |bytes: &[u8], at: usize| -> Option<u32> {
        let raw: [u8; 4] = bytes.get(at..at + 4)?.try_into().ok()?;
        Some(if little {
            u32::from_le_bytes(raw)
        } else {
            u32::from_be_bytes(raw)
        })
    };
    let (count, commands_size) = (word(&header, 16)?, u64::from(word(&header, 20)?));
    if commands_size > MAXIMUM_LOAD_COMMAND_BYTES || header_size + commands_size > size {
        return None;
    }
    let commands = bytes.read(base + header_size, commands_size)?;
    let mut at = 0_usize;
    let mut signature = None;
    for _ in 0..count {
        let (command, command_size) = (word(&commands, at)?, word(&commands, at + 4)? as usize);
        if command_size < 8 || at.checked_add(command_size)? > commands.len() {
            return None;
        }
        if command == LC_CODE_SIGNATURE {
            if command_size < 16 {
                return None;
            }
            signature = Some((
                u64::from(word(&commands, at + 8)?),
                u64::from(word(&commands, at + 12)?),
            ));
        }
        at += command_size;
    }
    let Some((offset, length)) = signature else {
        return Some(None);
    };
    if length < 12 || offset.checked_add(length)? > size {
        return None;
    }
    let start = base + offset;
    let superblob = bytes.read(start, 12)?;
    if big(&superblob, 0)? != CSMAGIC_EMBEDDED_SIGNATURE {
        return None;
    }
    let slots = u64::from(big(&superblob, 8)?);
    if slots > MAXIMUM_SIGNATURE_SLOTS || 12 + slots * 8 > length {
        return None;
    }
    let index = bytes.read(start + 12, slots * 8)?;
    for slot in 0..slots as usize {
        if big(&index, slot * 8)? != CSSLOT_CODEDIRECTORY {
            continue;
        }
        let directory_offset = u64::from(big(&index, slot * 8 + 4)?);
        if directory_offset.checked_add(24)? > length {
            return None;
        }
        let directory = bytes.read(start + directory_offset, 24)?;
        let directory_length = u64::from(big(&directory, 4)?);
        let identifier_offset = u64::from(big(&directory, 20)?);
        if big(&directory, 0)? != CSMAGIC_CODEDIRECTORY
            || directory_offset.checked_add(directory_length)? > length
            || identifier_offset >= directory_length
        {
            return None;
        }
        let available = (directory_length - identifier_offset).min(MAXIMUM_IDENTIFIER_BYTES);
        let text = bytes.read(start + directory_offset + identifier_offset, available)?;
        let end = text.iter().position(|&byte| byte == 0)?;
        return String::from_utf8(text[..end].to_vec()).ok().map(Some);
    }
    Some(None)
}

/// Swift `XcodeToolShim.resolve(tool:)`: the tool an `xcode-select` shim
/// named `tool` runs, as `/usr/bin/xcrun --find` resolves it with a cleared
/// environment — the developer directory `xcode-select` chose, which is what
/// the shim itself uses for a child that is given no `DEVELOPER_DIR`. The
/// answer is its physical path, a regular Mach-O file that is not a shim.
#[cfg(target_os = "macos")]
pub fn resolve(tool: &str) -> io::Result<std::path::PathBuf> {
    use std::io::Read;
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};
    const XCRUN: &str = "/usr/bin/xcrun";
    if tool.is_empty() || tool.len() > 255 || tool.starts_with('-') || tool.contains(['/', '\0']) {
        return Err(crate::invalid("a tool name is one path component"));
    }
    // The resolver is Xcode's own, never a shim or another tool.
    let resolver = std::fs::read(XCRUN)?;
    if signing_identifiers(&resolver).is_none_or(|identifiers| {
        identifiers
            .iter()
            .any(|identifier| identifier.as_deref() != Some("com.apple.xcrun"))
    }) {
        return Err(crate::denied("/usr/bin/xcrun is not Xcode's tool resolver"));
    }
    let mut child = Command::new(XCRUN)
        .args(["--find", tool])
        .env_clear()
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "xcrun did not resolve the tool in time",
            ));
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    let mut output = Vec::new();
    child
        .stdout
        .take()
        .ok_or_else(|| crate::invalid("xcrun output unavailable"))?
        .take(4_097)
        .read_to_end(&mut output)?;
    let refused = |message: String| io::Error::new(io::ErrorKind::PermissionDenied, message);
    let unresolved = || refused(format!("xcrun resolved no tool named {tool}"));
    let line = std::str::from_utf8(&output)
        .ok()
        .and_then(|text| text.strip_suffix('\n'))
        .filter(|line| status.success() && line.starts_with('/') && !line.contains('\n'))
        .ok_or_else(unresolved)?;
    let physical = std::path::Path::new(line).canonicalize()?;
    let regular = std::fs::symlink_metadata(&physical)?.file_type().is_file();
    let bytes = std::fs::read(&physical)?;
    match signing_identifiers(&bytes) {
        Some(identifiers) if regular && !is_tool_shim(&identifiers) => Ok(physical),
        _ => Err(refused(format!(
            "xcrun resolved {tool} to {}, which is not a regular Mach-O tool",
            physical.display()
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A thin 64-bit little-endian image whose only load command names a code
    /// signature holding a code directory for `identifier`.
    fn signed(identifier: Option<&str>) -> Vec<u8> {
        let mut image = Vec::new();
        image.extend(MH_MAGIC_64.to_le_bytes());
        image.extend([0_u8; 12]);
        image.extend(1_u32.to_le_bytes());
        image.extend(16_u32.to_le_bytes());
        image.extend([0_u8; 8]);
        let signature_offset = 64_u32;
        let mut blob = Vec::new();
        if let Some(identifier) = identifier {
            let mut directory = Vec::new();
            directory.extend(CSMAGIC_CODEDIRECTORY.to_be_bytes());
            let directory_length = 48 + identifier.len() as u32 + 1;
            directory.extend(directory_length.to_be_bytes());
            directory.extend([0_u8; 12]);
            directory.extend(48_u32.to_be_bytes());
            directory.extend([0_u8; 24]);
            directory.extend(identifier.as_bytes());
            directory.push(0);
            blob.extend(CSMAGIC_EMBEDDED_SIGNATURE.to_be_bytes());
            blob.extend((20 + directory.len() as u32).to_be_bytes());
            blob.extend(1_u32.to_be_bytes());
            blob.extend(CSSLOT_CODEDIRECTORY.to_be_bytes());
            blob.extend(20_u32.to_be_bytes());
            blob.extend(directory);
        } else {
            blob.extend(CSMAGIC_EMBEDDED_SIGNATURE.to_be_bytes());
            blob.extend(12_u32.to_be_bytes());
            blob.extend(0_u32.to_be_bytes());
        }
        image.extend(LC_CODE_SIGNATURE.to_le_bytes());
        image.extend(16_u32.to_le_bytes());
        image.extend(signature_offset.to_le_bytes());
        image.extend((blob.len() as u32).to_le_bytes());
        image.resize(signature_offset as usize, 0);
        image.extend(blob);
        image
    }

    fn universal(images: &[Vec<u8>]) -> Vec<u8> {
        let mut file = Vec::new();
        file.extend(FAT_MAGIC.to_be_bytes());
        file.extend((images.len() as u32).to_be_bytes());
        let mut offset = 4_096_u32;
        for image in images {
            file.extend([0_u8; 8]);
            file.extend(offset.to_be_bytes());
            file.extend((image.len() as u32).to_be_bytes());
            file.extend(12_u32.to_be_bytes());
            offset += (image.len() as u32).next_multiple_of(4_096);
        }
        for image in images {
            file.resize(file.len().next_multiple_of(4_096), 0);
            file.extend(image);
        }
        file
    }

    #[test]
    fn a_code_directory_names_the_image() {
        let shim = signed(Some("com.apple.dt.xcode_select.tool-shim-public"));
        assert_eq!(
            signing_identifiers(&shim),
            Some(vec![Some(
                "com.apple.dt.xcode_select.tool-shim-public".into()
            )])
        );
        assert!(bytes_are_tool_shim(&shim));
        let git = signed(Some("com.apple.git"));
        assert!(!bytes_are_tool_shim(&git));
        assert_eq!(signing_identifiers(&signed(None)), Some(vec![None]));
        assert!(!bytes_are_tool_shim(&signed(None)));
        // One shim architecture makes the whole file a shim.
        let mixed = universal(&[git.clone(), shim]);
        assert_eq!(signing_identifiers(&mixed).map(|ids| ids.len()), Some(2));
        assert!(bytes_are_tool_shim(&mixed));
        assert!(!bytes_are_tool_shim(&universal(&[git.clone(), git])));
    }

    #[test]
    fn what_is_not_a_well_formed_mach_o_file_is_nothing() {
        assert_eq!(signing_identifiers(b"#!/bin/sh\nexec git \"$@\"\n"), None);
        assert_eq!(signing_identifiers(&[]), None);
        let shim = signed(Some("com.apple.dt.xcode_select.tool-shim-public"));
        for cut in [4, 20, 40, 70, shim.len() - 1] {
            assert_eq!(signing_identifiers(&shim[..cut]), None, "{cut}");
        }
        let mut wrong = shim.clone();
        wrong[64] ^= 0xff;
        assert_eq!(signing_identifiers(&wrong), None);
        assert!(!bytes_are_tool_shim(&wrong));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_host_tools_are_told_by_their_signature_not_their_links() {
        use std::os::unix::fs::MetadataExt;
        let identifier = |path: &str| signing_identifiers(&std::fs::read(path).unwrap()).unwrap();
        // One file under 78 names, and no tool at all.
        assert!(std::fs::metadata("/usr/bin/git").unwrap().nlink() > 1);
        assert!(is_tool_shim(&identifier("/usr/bin/git")));
        let file = std::fs::File::open("/usr/bin/git").unwrap();
        assert!(file_is_tool_shim(&file).unwrap());
        // Linked three times, and a tool of its own.
        assert!(std::fs::metadata("/usr/bin/grep").unwrap().nlink() > 1);
        assert!(!is_tool_shim(&identifier("/usr/bin/grep")));
        for tool in ["/usr/bin/sed", "/usr/bin/patch", "/usr/bin/bsdtar"] {
            assert!(!is_tool_shim(&identifier(tool)), "{tool}");
        }
        assert!(
            identifier("/usr/bin/xcrun")
                .iter()
                .all(|id| id.as_deref() == Some("com.apple.xcrun"))
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_shim_resolves_to_the_tool_it_names() {
        let git = resolve("git").unwrap();
        assert!(git.is_absolute() && git.canonicalize().unwrap() == git);
        let identifiers = signing_identifiers(&std::fs::read(&git).unwrap()).unwrap();
        assert!(!is_tool_shim(&identifiers));
        assert!(
            identifiers
                .iter()
                .all(|id| id.as_deref() == Some("com.apple.git"))
        );
        for refused in ["", "-v", "a/b", "git\0"] {
            assert!(resolve(refused).is_err(), "{refused:?}");
        }
        assert!(resolve("arkdeck-no-such-developer-tool").is_err());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_shim_is_never_opened_for_a_launch() {
        use sha2::{Digest, Sha256};
        let digest =
            |path: &std::path::Path| format!("{:x}", Sha256::digest(std::fs::read(path).unwrap()));
        let shim = std::path::Path::new("/usr/bin/git");
        let refused = crate::VerifiedTool::open(shim, &digest(shim))
            .err()
            .unwrap();
        assert_eq!(refused.kind(), io::ErrorKind::PermissionDenied);
        let tool = resolve("git").unwrap();
        assert!(crate::VerifiedTool::open(&tool, &digest(&tool)).is_ok());
    }
}
