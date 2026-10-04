//! Maintenance-only DevEco profile inputs. Parsing follows Swift's closed
//! field patterns (including JSON5 spelling), not a general JSON5 evaluator.
//!
//! On Windows (TASK-XPA-011) the same closed patterns read the build profile
//! DevEco writes there. The file is read through one handle that follows no
//! reparse point, in its spelling on disk, as the same file the platform
//! measured trusted-write-only (the Unix `mode & 0o022 == 0`). Its
//! `storeFile` is a JSON string whose only escapes are `\\` (the drive
//! path's separators, as DevEco writes them) and `\/`.
use crate::CliError;
use arkdeck_platform::Secret;
#[cfg(target_os = "macos")]
use arkdeck_provider_workspace::foundation_resolved_path;
use std::path::{Path, PathBuf};
#[cfg(target_os = "macos")]
use std::{fs, io::Read, os::unix::fs::MetadataExt};

pub struct DevEcoSigningMaterial {
    pub keystore: Secret,
    pub key: Secret,
    pub store_file: PathBuf,
}

/// Swift's optional quoted field name, whitespace, colon, quoted value.
/// Matches remain unanchored as NSRegularExpression's matches are; comments
/// or duplicated configurations never silently select one password.
fn fields<'a>(document: &'a str, name: &str) -> Vec<&'a str> {
    let mut matches = Vec::new();
    for (at, _) in document.match_indices(name) {
        let mut tail = &document[at + name.len()..];
        if tail.starts_with(['\'', '"']) {
            tail = &tail[1..];
        }
        tail = tail.trim_start_matches(char::is_whitespace);
        let Some(rest) = tail.strip_prefix(':') else {
            continue;
        };
        tail = rest.trim_start_matches(char::is_whitespace);
        if !tail.starts_with(['\'', '"']) {
            continue;
        }
        tail = &tail[1..];
        let Some(end) = tail.find(['\'', '"']) else {
            continue;
        };
        matches.push(&tail[..end]);
    }
    matches
}

fn unsafe_profile() -> CliError {
    CliError::plain_usage("DevEco build-profile is absent, mutable by another user, or unbounded")
}

fn profile_drift() -> CliError {
    CliError::plain_usage("DevEco build-profile identity drifted")
}

/// The build profile's bytes, read as Swift's CLI reads them.
#[cfg(target_os = "macos")]
fn read_profile_bytes(path: &Path) -> Result<Secret, CliError> {
    let name = path.to_str().ok_or_else(unsafe_profile)?;
    let before = fs::symlink_metadata(path).map_err(|_| unsafe_profile())?;
    if !before.is_file()
        || before.mode() & 0o022 != 0
        || before.len() == 0
        || before.len() > 1_048_576
        || foundation_resolved_path(name).as_deref() != Some(name)
    {
        return Err(unsafe_profile());
    }
    let mut bytes = Vec::with_capacity(1_048_577);
    let read_result = fs::File::open(path)
        .map_err(|_| unsafe_profile())?
        .take(1_048_577)
        .read_to_end(&mut bytes);
    let bytes = Secret::new(bytes);
    read_result.map_err(|_| unsafe_profile())?;
    let after = fs::symlink_metadata(path).map_err(|_| unsafe_profile())?;
    if bytes.len() as u64 != before.len()
        || before.ino() != after.ino()
        || before.len() != after.len()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
    {
        return Err(profile_drift());
    }
    Ok(bytes)
}

/// The build profile's bytes on Windows: a bounded regular file in its
/// spelling on disk, trusted-write-only, read as the file it measured.
#[cfg(windows)]
fn read_profile_bytes(path: &Path) -> Result<Secret, CliError> {
    use sha2::{Digest, Sha256};
    let measure =
        arkdeck_platform::measure_host_file(path, 1_048_576).map_err(|_| unsafe_profile())?;
    if !measure.trusted_write_only {
        return Err(unsafe_profile());
    }
    let bytes = Secret::new(
        arkdeck_platform::read_host_file(path, 1_048_576).map_err(|_| unsafe_profile())?,
    );
    if <[u8; 32]>::from(Sha256::digest(bytes.as_bytes())) != measure.sha256 {
        return Err(profile_drift());
    }
    Ok(bytes)
}

/// A `storeFile` value as the path it names: on macOS the text itself; on
/// Windows the JSON string with its `\\` and `\/` escapes read (any other
/// escape is refused).
fn store_path(value: &str) -> Option<String> {
    if !cfg!(windows) {
        return Some(value.to_owned());
    }
    let mut path = String::with_capacity(value.len());
    let mut characters = value.chars();
    while let Some(character) = characters.next() {
        if character == '\\' {
            match characters.next() {
                Some('\\') => path.push('\\'),
                Some('/') => path.push('/'),
                _ => return None,
            }
        } else {
            path.push(character);
        }
    }
    Some(path)
}

/// A canonical absolute keystore path: on macOS `/` and no empty, `.` or
/// `..` component; on Windows a drive, `\` separators and the same rule.
fn canonical_store(store: &str) -> bool {
    if store.contains('\0') {
        return false;
    }
    if cfg!(windows) {
        let bytes = store.as_bytes();
        bytes.len() > 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && bytes[2] == b'\\'
            && !store.contains('/')
            && store[3..]
                .split('\\')
                .all(|part| !part.is_empty() && part != "." && part != "..")
    } else {
        store.starts_with('/')
            && store
                .split('/')
                .skip(1)
                .all(|part| !part.is_empty() && part != "." && part != "..")
    }
}

pub fn read_deveco_profile(path: &Path) -> Result<DevEcoSigningMaterial, CliError> {
    let bytes = read_profile_bytes(path)?;
    let document = std::str::from_utf8(bytes.as_bytes()).map_err(|_| profile_drift())?;
    let stores: Vec<_> = fields(document, "storeFile")
        .into_iter()
        .filter(|s| !s.is_empty() && s.chars().count() <= 4096 && !s.contains(['\r', '\n']))
        .collect();
    if stores.len() != 1 {
        return Err(CliError::plain_usage(
            "DevEco build-profile must contain exactly one storeFile path",
        ));
    }
    let store = store_path(stores[0])
        .filter(|store| canonical_store(store))
        .ok_or_else(|| {
            CliError::plain_usage(
                "DevEco build-profile storeFile must be a canonical absolute path",
            )
        })?;
    let hex = |name: &str| {
        let values: Vec<_> = fields(document, name)
            .into_iter()
            .filter(|s| (32..=2048).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_hexdigit()))
            .collect();
        if values.len() != 1 {
            return Err(CliError::plain_usage(format!(
                "DevEco build-profile must contain exactly one {name} ciphertext"
            )));
        }
        if !values[0].len().is_multiple_of(2) {
            return Err(CliError::plain_usage(format!(
                "DevEco {name} ciphertext is malformed"
            )));
        }
        Ok(Secret::from_slice(values[0].as_bytes()))
    };
    Ok(DevEcoSigningMaterial {
        keystore: hex("storePassword")?,
        key: hex("keyPassword")?,
        store_file: PathBuf::from(store),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_store_file_is_read_as_the_path_it_names() {
        if cfg!(windows) {
            assert_eq!(
                store_path(r"C:\\Users\\me\\.ohos\\config\\default_a=.p12").as_deref(),
                Some(r"C:\Users\me\.ohos\config\default_a=.p12")
            );
            assert_eq!(store_path(r"C:\\a\/b").as_deref(), Some(r"C:\a/b"));
            for refused in [r"C:\\a\nb", r"C:\\a\", r"C:\\a\u0041"] {
                assert_eq!(store_path(refused), None, "{refused}");
            }
            assert!(canonical_store(r"C:\Users\me\x.p12"));
            for refused in [
                r"C:\Users\..\x.p12",
                r"C:\Users\\x.p12",
                r"C:/Users/x.p12",
                r"\\server\share\x.p12",
                "relative.p12",
                "/Users/me/x.p12",
            ] {
                assert!(!canonical_store(refused), "{refused}");
            }
        } else {
            assert_eq!(store_path(r"/a\b").as_deref(), Some(r"/a\b"));
            assert!(canonical_store("/Users/me/x.p12"));
            assert!(!canonical_store("/Users/../x.p12"));
            assert!(!canonical_store(r"C:\x.p12"));
        }
    }
}
