//! Maintenance-only DevEco profile inputs. Parsing follows Swift's closed
//! field patterns (including JSON5 spelling), not a general JSON5 evaluator.
use crate::CliError;
use arkdeck_platform::Secret;
use arkdeck_provider_workspace::foundation_resolved_path;
use std::{
    fs,
    io::Read,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

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

pub fn read_deveco_profile(path: &Path) -> Result<DevEcoSigningMaterial, CliError> {
    let unsafe_file = || {
        CliError::plain_usage(
            "DevEco build-profile is absent, mutable by another user, or unbounded",
        )
    };
    let name = path.to_str().ok_or_else(unsafe_file)?;
    let before = fs::symlink_metadata(path).map_err(|_| unsafe_file())?;
    if !before.is_file()
        || before.mode() & 0o022 != 0
        || before.len() == 0
        || before.len() > 1_048_576
        || foundation_resolved_path(name).as_deref() != Some(name)
    {
        return Err(unsafe_file());
    }
    let mut bytes = Vec::with_capacity(1_048_577);
    let read_result = fs::File::open(path)
        .map_err(|_| unsafe_file())?
        .take(1_048_577)
        .read_to_end(&mut bytes);
    let bytes = Secret::new(bytes);
    read_result.map_err(|_| unsafe_file())?;
    let after = fs::symlink_metadata(path).map_err(|_| unsafe_file())?;
    let drift = || CliError::plain_usage("DevEco build-profile identity drifted");
    if bytes.len() as u64 != before.len()
        || before.ino() != after.ino()
        || before.len() != after.len()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
    {
        return Err(drift());
    }
    let document = std::str::from_utf8(bytes.as_bytes()).map_err(|_| drift())?;
    let stores: Vec<_> = fields(document, "storeFile")
        .into_iter()
        .filter(|s| !s.is_empty() && s.chars().count() <= 4096 && !s.contains(['\r', '\n']))
        .collect();
    if stores.len() != 1 {
        return Err(CliError::plain_usage(
            "DevEco build-profile must contain exactly one storeFile path",
        ));
    }
    let store = stores[0];
    if !store.starts_with('/')
        || store.contains('\0')
        || store
            .split('/')
            .skip(1)
            .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err(CliError::plain_usage(
            "DevEco build-profile storeFile must be a canonical absolute path",
        ));
    }
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
