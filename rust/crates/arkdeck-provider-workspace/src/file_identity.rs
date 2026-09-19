//! Swift `OpenHarmonySigningPresetStore.measure`: a pinned signing file is a
//! bounded regular file at its own canonical absolute path, not writable by
//! group or others, optionally private to this user or executable by it, and
//! its identity is its path, SHA-256 and length. A receipt re-measures every
//! pinned file before it is used and refuses any drift.
use crate::SigningError;
use crate::signing_preset::SigningFileIdentity;
use sha2::{Digest, Sha256};
use std::io::Read;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

const MAX_SIGNING_FILE_BYTES: u64 = 512 * 1024 * 1024;

/// Foundation `URL(filePath:).resolvingSymlinksInPath().path`: the physical
/// path with every symbolic link resolved, and — as Foundation documents it —
/// a leading `/private` removed when what remains names an existing file, so
/// `/private/tmp/x` resolves to `/tmp/x` and so does `/tmp/x`. `None` when the
/// path cannot be resolved.
pub fn foundation_resolved_path(path: &str) -> Option<String> {
    let resolved = std::fs::canonicalize(path).ok()?;
    let resolved = resolved.to_str()?.to_owned();
    if let Some(rest) = resolved.strip_prefix("/private")
        && rest.starts_with('/')
        && Path::new(rest).exists()
    {
        return Some(rest.to_owned());
    }
    Some(resolved)
}

/// Swift `measure(_:role:mustBeExecutable:ownerPrivate:)`.
pub fn measure(
    path: &str,
    role: &str,
    must_be_executable: bool,
    owner_private: bool,
) -> Result<SigningFileIdentity, SigningError> {
    if !crate::signing_action::is_standard_path(path) {
        return Err(SigningError::unsafe_file(format!(
            "{role} path is not canonical absolute"
        )));
    }
    let bounded = || SigningError::unsafe_file(format!("{role} is not a bounded regular file"));
    let resolved = foundation_resolved_path(path).ok_or_else(bounded)?;
    if resolved != path {
        return Err(SigningError::unsafe_file(format!(
            "{role} path is not canonical absolute"
        )));
    }
    let metadata = std::fs::symlink_metadata(path).map_err(|_| bounded())?;
    if !metadata.file_type().is_file()
        || metadata.len() == 0
        || metadata.len() > MAX_SIGNING_FILE_BYTES
    {
        return Err(bounded());
    }
    if metadata.mode() & 0o022 != 0 {
        return Err(SigningError::unsafe_file(format!(
            "{role} is group/world writable"
        )));
    }
    if owner_private
        && (metadata.uid() != arkdeck_platform::effective_user_id() || metadata.mode() & 0o077 != 0)
    {
        return Err(SigningError::unsafe_file(format!(
            "{role} must be owned by this user and private"
        )));
    }
    if must_be_executable && !arkdeck_platform::executable_by_caller(Path::new(path)) {
        return Err(SigningError::unsafe_file(format!(
            "{role} is not executable"
        )));
    }
    let (sha256, byte_count) = hash_file(path)
        .map_err(|_| SigningError::unsafe_file(format!("{role} changed while hashing")))?;
    if byte_count != metadata.len() {
        return Err(SigningError::unsafe_file(format!(
            "{role} changed while hashing"
        )));
    }
    Ok(SigningFileIdentity {
        path: path.to_owned(),
        sha256,
        byte_count,
    })
}

/// Swift `remeasure(_:role:mustBeExecutable:ownerPrivate:)`: the file must
/// still measure exactly as recorded.
pub fn remeasure(
    expected: &SigningFileIdentity,
    role: &str,
    must_be_executable: bool,
    owner_private: bool,
) -> Result<(), SigningError> {
    let actual = measure(&expected.path, role, must_be_executable, owner_private)?;
    if &actual != expected {
        return Err(SigningError::drift(role));
    }
    Ok(())
}

pub(crate) fn hash_file(path: &str) -> std::io::Result<(String, u64)> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 64 * 1024];
    let mut total = 0u64;
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        total += count as u64;
        hasher.update(&buffer[..count]);
    }
    Ok((hex(&hasher.finalize()), total))
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
