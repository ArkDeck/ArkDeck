//! Swift `OpenHarmonySigningPresetStore.measure`: a pinned signing file is a
//! bounded regular file at its own canonical absolute path, not writable by
//! group or others, optionally private to this user or executable by it, and
//! its identity is its path, SHA-256 and length. A receipt re-measures every
//! pinned file before it is used and refuses any drift.
//!
//! On Windows (TASK-XPA-011) the same rules read the file's owner and DACL
//! through one no-follow handle ([`arkdeck_platform::measure_host_file`]):
//! the path is a canonical drive path (`X:\…`, the spelling on disk, no link
//! or junction in any component); "not writable by group or others" is "owned
//! by this user or a trusted principal (`SYSTEM`, `Administrators`,
//! `TrustedInstaller`) and nobody else may change it"; "owned by this user and
//! private" is "owned by this user and nobody but the user and the trusted
//! principals is granted anything"; "executable" is a `.exe` the kernel
//! grants this caller `FILE_EXECUTE` on. The file is hashed from the handle
//! its identity (`FileIdInfo`, size, times) was read on, and refused if that
//! identity moved or the path names another file afterwards.
use crate::SigningError;
use crate::signing_preset::SigningFileIdentity;
use sha2::{Digest, Sha256};
use std::io::Read;
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::path::Path;

const MAX_SIGNING_FILE_BYTES: u64 = 512 * 1024 * 1024;

/// A standard absolute path of this host: `/a/b` on Unix (the signing
/// action's rule), `X:\a\b` on Windows — no empty, `.` or `..` component, no
/// trailing separator and, on Windows, no `/`, stream or device syntax.
#[cfg(unix)]
pub(crate) fn is_standard_host_path(path: &str) -> bool {
    crate::signing_action::is_standard_path(path)
}

/// A standard absolute path of this host: `/a/b` on Unix (the signing
/// action's rule), `X:\a\b` on Windows — no empty, `.` or `..` component, no
/// trailing separator and, on Windows, no `/`, stream or device syntax.
#[cfg(windows)]
pub(crate) fn is_standard_host_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.len() > 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && bytes[2] == b'\\'
        && path[3..].split('\\').all(|component| {
            !component.is_empty()
                && component != "."
                && component != ".."
                && !component.ends_with(['.', ' '])
                && !component
                    .chars()
                    .any(|c| c < ' ' || matches!(c, '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|'))
        })
}

/// Foundation `URL(filePath:).resolvingSymlinksInPath().path`: the physical
/// path with every symbolic link resolved, and — as Foundation documents it —
/// a leading `/private` removed when what remains names an existing file, so
/// `/private/tmp/x` resolves to `/tmp/x` and so does `/tmp/x`. `None` when the
/// path cannot be resolved.
#[cfg(unix)]
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

/// Foundation `URL(filePath:).resolvingSymlinksInPath().path` on Windows:
/// the path the system reports for what `path` opens, every link and
/// junction followed, in the spelling on disk, as a plain `X:\…` path.
/// `None` when the path cannot be resolved or resolves off a local drive.
#[cfg(windows)]
pub fn foundation_resolved_path(path: &str) -> Option<String> {
    arkdeck_platform::host_resolved_path(Path::new(path))?
        .to_str()
        .map(str::to_owned)
}

/// Swift `measure(_:role:mustBeExecutable:ownerPrivate:)` on Windows, with
/// the same checks in the same order and the same refusals.
#[cfg(windows)]
pub fn measure(
    path: &str,
    role: &str,
    must_be_executable: bool,
    owner_private: bool,
) -> Result<SigningFileIdentity, SigningError> {
    use arkdeck_platform::HostFileMeasureError;
    if !is_standard_host_path(path) {
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
    let measured = arkdeck_platform::measure_host_file(Path::new(path), MAX_SIGNING_FILE_BYTES)
        .map_err(|error| match error {
            HostFileMeasureError::Unreadable => bounded(),
            HostFileMeasureError::Changed => {
                SigningError::unsafe_file(format!("{role} changed while hashing"))
            }
        })?;
    if !measured.trusted_write_only {
        return Err(SigningError::unsafe_file(format!(
            "{role} is group/world writable"
        )));
    }
    if owner_private && !measured.owner_private {
        return Err(SigningError::unsafe_file(format!(
            "{role} must be owned by this user and private"
        )));
    }
    if must_be_executable && !measured.executable {
        return Err(SigningError::unsafe_file(format!(
            "{role} is not executable"
        )));
    }
    Ok(SigningFileIdentity {
        path: path.to_owned(),
        sha256: hex(&measured.sha256),
        byte_count: measured.identity.size,
    })
}

/// Swift `measure(_:role:mustBeExecutable:ownerPrivate:)`.
#[cfg(unix)]
pub fn measure(
    path: &str,
    role: &str,
    must_be_executable: bool,
    owner_private: bool,
) -> Result<SigningFileIdentity, SigningError> {
    if !is_standard_host_path(path) {
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
