//! Swift `RuntimeArtifactStore.totalBytesUsed()` for `artifact.quota`: the
//! Artifact root walked as a Swift store that has not yet cached its total
//! walks it, answering the quota, the bytes its published Artifacts hold and
//! what remains, or Swift's rendering of the store error that stopped the walk.
//!
//! Every root entry is classified first, in directory order: the Import owner's
//! directory and a regular cleanup ledger are skipped, any other directory is
//! a Job, and anything else refuses the walk. Each Job's index is then read as
//! Swift reads it (an absent index has no rows; a linked, empty, oversized or
//! changing one refuses), decoded as Swift's synthesized `Codable` decodes it
//! (a member the model lacks is ignored), and its rows checked in order: each
//! identity (the Job's own, safe, unique ID and name), and each published
//! payload at once, opened without following a link, its type and size, and
//! the digest of the bytes read.
//!
//! Unlike Swift, a read here writes nothing: no payload is resealed to 0400,
//! no payload-verification cache is read or written (Swift's cache only spares
//! a hash), and no total is kept between reads.

use std::collections::HashSet;
use std::fs::{self, File, Metadata};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::strict_json::swift_quoted;
use crate::swift_decoding::{Decoding, Keyed, Step, characters, text_key};

const INDEX_BOUND: u64 = 16 * 1024 * 1024;

/// Swift `RuntimeArtifactError`: the cases the walk can meet.
enum StoreError {
    /// `ioFailure`
    Io(String),
    /// `indexCorrupted`
    Corrupted(String),
}

impl StoreError {
    fn swift(&self) -> String {
        match self {
            Self::Io(detail) => format!("ioFailure({})", swift_quoted(detail)),
            Self::Corrupted(detail) => format!("indexCorrupted({})", swift_quoted(detail)),
        }
    }
}

fn corrupted(detail: impl Into<String>) -> StoreError {
    StoreError::Corrupted(detail.into())
}

/// The daemon's `artifact.quota` over `root`, composed with `quota` bytes.
pub(crate) fn answer(root: &Path, quota: u64) -> Result<Value, String> {
    let used = used_bytes(root).map_err(|error| error.swift())?;
    let total = i64::try_from(quota).map_err(|_| "the Artifact quota exceeds Int".to_owned())?;
    Ok(json!({
        "totalBytes": total,
        "usedBytes": used,
        "remainingBytes": total.saturating_sub(used).max(0),
    }))
}

/// Swift `totalBytesUsed()` without its cache.
fn used_bytes(root: &Path) -> Result<i64, StoreError> {
    // Swift `jobDirectories()`: the whole root is classified first.
    let mut jobs = Vec::new();
    for entry in fs::read_dir(root).map_err(|error| StoreError::Io(error.to_string()))? {
        let entry = entry.map_err(|error| StoreError::Io(error.to_string()))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let kind = fs::symlink_metadata(entry.path())
            .map_err(|error| StoreError::Io(error.to_string()))?
            .file_type();
        if kind.is_dir() {
            if name != ".imports-v1" {
                jobs.push(name);
            }
        } else if !(kind.is_file() && name == "cleanup-debt.json") {
            return Err(corrupted(format!(
                "artifact root contains an unexpected or linked entry {name}"
            )));
        }
    }
    let mut total = 0_i64;
    for job in jobs {
        for row in load_index(root, &job)? {
            if row.published {
                // Swift's sum is a plain `Int` addition, which traps.
                total = total
                    .checked_add(row.byte_count)
                    .ok_or_else(|| corrupted("artifact inventory exceeds Int"))?;
            }
        }
    }
    Ok(total)
}

/// What the walk reads of one index row.
struct Row {
    artifact_id: String,
    job_id: String,
    name: String,
    byte_count: i64,
    sha256: String,
    published: bool,
}

/// Swift `loadIndex(jobID:)`.
fn load_index(root: &Path, job: &str) -> Result<Vec<Row>, StoreError> {
    // Swift `directory(for:)`, which every index read goes through.
    if job.is_empty()
        || characters(job) > 128
        || !job
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(StoreError::Io("malformed job identifier".into()));
    }
    let directory = root.join(job);
    let index = directory.join("index.json");
    // `fileExists` follows a link: an absent index, or a dangling link, is an
    // empty one.
    if !index.exists() {
        return Ok(Vec::new());
    }
    if !fs::symlink_metadata(&index).is_ok_and(|metadata| metadata.is_file()) {
        return Err(corrupted("artifact index must be a real regular file"));
    }
    let bytes = bounded_index(&index)?;
    let document: Value = serde_json::from_slice(&bytes)
        .map_err(|error| corrupted(format!("undecodable artifact index: {error}")))?;
    let (schema_version, rows) = decode_index(&document)
        .map_err(|error| corrupted(format!("undecodable artifact index: {}", error.describe())))?;
    if schema_version != "1.0.0" {
        return Err(corrupted(format!(
            "unsupported index schema {schema_version}"
        )));
    }
    let mut identities = HashSet::new();
    let mut names = HashSet::new();
    for row in &rows {
        if text_key(&row.job_id) != text_key(job)
            || !safe_artifact_id(&row.artifact_id)
            || !identities.insert(text_key(&row.artifact_id))
            || !names.insert(text_key(&row.name))
        {
            return Err(corrupted(
                "artifact index contains a foreign, unsafe or duplicate identity",
            ));
        }
        if row.published {
            validate_payload(&directory.join(&row.artifact_id), row)?;
        }
    }
    Ok(rows)
}

/// Swift `boundedIndexData(_:)`.
fn bounded_index(index: &Path) -> Result<Vec<u8>, StoreError> {
    let mut file =
        open_unlinked(index).map_err(|_| corrupted("artifact index cannot be opened"))?;
    let before = file
        .metadata()
        .ok()
        .filter(|metadata| {
            metadata.is_file() && metadata.len() > 0 && metadata.len() <= INDEX_BOUND
        })
        .ok_or_else(|| corrupted("artifact index exceeds its read bound"))?;
    let mut data = Vec::new();
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let count = match file.read(&mut buffer) {
            Ok(count) => count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return Err(corrupted("artifact index read failed")),
        };
        if data.len() as u64 > INDEX_BOUND - count as u64 {
            return Err(corrupted("artifact index read failed"));
        }
        if count == 0 {
            break;
        }
        data.extend_from_slice(&buffer[..count]);
    }
    if !file
        .metadata()
        .is_ok_and(|after| same_identity_and_content(&before, &after))
        || data.len() as u64 != before.len()
    {
        return Err(corrupted("artifact index changed during read"));
    }
    Ok(data)
}

/// Swift `validateStoredPayload(_:at:)`, without its verification cache and
/// without resealing.
fn validate_payload(path: &Path, row: &Row) -> Result<(), StoreError> {
    let mut file = open_unlinked(path).map_err(|error| {
        corrupted(format!(
            "artifact payload is missing, linked or unreadable (errno {})",
            error.raw_os_error().unwrap_or(0)
        ))
    })?;
    let before = file
        .metadata()
        .ok()
        .filter(|metadata| {
            metadata.is_file() && i64::try_from(metadata.len()) == Ok(row.byte_count)
        })
        .ok_or_else(|| corrupted("artifact payload type or size drifted"))?;
    let mut hash = Sha256::new();
    let mut hashed = 0_i64;
    let mut buffer = vec![0_u8; 1 << 20];
    loop {
        let count = match file.read(&mut buffer) {
            Ok(count) => count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => {
                return Err(StoreError::Io(format!(
                    "cannot hash artifact payload (errno {})",
                    error.raw_os_error().unwrap_or(0)
                )));
            }
        };
        if count == 0 {
            break;
        }
        hashed = hashed.saturating_add(count as i64);
        hash.update(&buffer[..count]);
    }
    let digest: String = hash
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    if !file
        .metadata()
        .is_ok_and(|after| same_identity_and_content(&before, &after))
        || hashed != row.byte_count
        || digest != row.sha256
    {
        return Err(corrupted("artifact payload digest or identity drifted"));
    }
    Ok(())
}

/// `open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)`.
fn open_unlinked(path: &Path) -> std::io::Result<File> {
    fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(path)
}

/// Swift `sameFileIdentityAndContent(_:_:)`.
fn same_identity_and_content(before: &Metadata, after: &Metadata) -> bool {
    before.dev() == after.dev()
        && before.ino() == after.ino()
        && before.mode() == after.mode()
        && before.size() == after.size()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec()
}

/// Swift `isSafeArtifactID(_:)`: `^ART-(?:MISSING-)?[0-9a-f]{32}$`. The
/// oracle records that the match takes no line terminator after the digits.
fn safe_artifact_id(body: &str) -> bool {
    let hex = |text: &str| {
        text.len() == 32
            && text
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    };
    body.strip_prefix("ART-MISSING-").is_some_and(hex) || body.strip_prefix("ART-").is_some_and(hex)
}

// MARK: - Swift's synthesized decoding of `ArtifactIndexDocument`

/// `ArtifactIndexDocument`: its schema version and rows, members the model
/// lacks ignored.
fn decode_index(document: &Value) -> Result<(String, Vec<Row>), Decoding> {
    let keyed = Keyed::of(document, Vec::new())?;
    let schema_version = keyed.string("schemaVersion")?;
    let rows = keyed
        .array("artifacts")?
        .into_iter()
        .map(|(row, path)| decode_row(row, path))
        .collect::<Result<_, _>>()?;
    Ok((schema_version, rows))
}

/// `RuntimeArtifactMetadata`, in its members' order.
fn decode_row(value: &Value, path: Vec<Step>) -> Result<Row, Decoding> {
    let keyed = Keyed::of(value, path)?;
    let artifact_id = keyed.string("artifactID")?;
    let job_id = keyed.string("jobID")?;
    keyed.string("sessionID")?;
    keyed.string("stepID")?;
    let name = keyed.string("name")?;
    keyed.string("mediaType")?;
    let byte_count = keyed.int("byteCount")?;
    let sha256 = keyed.string("sha256")?;
    keyed.string("createdAtUTC")?;
    keyed.string("providerID")?;
    keyed.string("sourceOperation")?;
    let binding = keyed.keyed("bindingSnapshot")?;
    binding.string("targetID")?;
    binding.optional_int("bindingRevision")?;
    binding.optional_string("stableIdentitySHA256")?;
    keyed.raw("privacy", "CatalogArtifactPrivacy", |raw| {
        ["standard", "sensitive"].contains(&raw).then_some(())
    })?;
    let retention = keyed.keyed("retention")?;
    retention.raw("retentionClass", "CatalogArtifactRetentionClass", |raw| {
        ["default", "pinnedUntilVerified", "shortLived"]
            .contains(&raw)
            .then_some(())
    })?;
    retention.optional_string("deadlineUTC")?;
    retention.bool("pinned")?;
    let published = decode_status(&keyed.keyed("status")?)?;
    keyed.bool("redactionApplied")?;
    if let Some(derivation) = keyed.optional("derivation") {
        decode_derivation(&Keyed::of(derivation, keyed.path("derivation"))?)?;
    }
    if let Some(window) = keyed.optional("observationWindow") {
        let window = Keyed::of(window, keyed.path("observationWindow"))?;
        window.string("startUTC")?;
        window.string("endUTC")?;
    }
    Ok(Row {
        artifact_id,
        job_id,
        name,
        byte_count,
        sha256,
        published,
    })
}

/// `ArtifactStatus`'s synthesized decoding: exactly one of its cases' keys,
/// other members ignored. Whether the row is published.
fn decode_status(status: &Keyed<'_>) -> Result<bool, Decoding> {
    let cases: Vec<&str> = ["published", "missing", "truncated"]
        .into_iter()
        .filter(|case| status.members.contains_key(*case))
        .collect();
    let [case] = cases.as_slice() else {
        return Err(Decoding::TypeMismatchDescribed {
            expected: "ArtifactStatus",
            description: "Invalid number of keys found, expected one.".into(),
            path: status.path.clone(),
        });
    };
    let nested = status.keyed(case)?;
    match *case {
        "missing" => {
            nested.string("reason")?;
        }
        "truncated" => {
            nested.int("atBytes")?;
        }
        _ => {}
    }
    Ok(*case == "published")
}

/// `RuntimeArtifactDerivation`, in its members' order.
fn decode_derivation(keyed: &Keyed<'_>) -> Result<(), Decoding> {
    for key in [
        "analyzerRef",
        "analyzerVersion",
        "sourceArtifactID",
        "sourceSHA256",
    ] {
        keyed.string(key)?;
    }
    keyed.int("sourceByteCount")?;
    for key in [
        "toolSHA256",
        "parserSHA256",
        "parserVersion",
        "parserUpstreamRevision",
        "parserBuildRecipeVersion",
        "parserAdapterVersion",
        "schemaAdapterVersion",
    ] {
        keyed.string(key)?;
    }
    for key in [
        "indexSchemaVersion",
        "timeoutMs",
        "maxRows",
        "maxEvents",
        "maxOutputBytes",
    ] {
        keyed.int(key)?;
    }
    keyed.optional_string("requestCommand")?;
    keyed.optional_string("requestKind")?;
    for key in [
        "requestTimestampNs",
        "requestStartNs",
        "requestEndNs",
        "requestProcessKey",
        "requestPID",
        "requestThreadKey",
        "requestTID",
        "requestThresholdNs",
    ] {
        keyed.optional_int64(key)?;
    }
    keyed.optional_int("requestLimit")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_identities_are_the_ones_swift_matches() {
        let hex = "0123456789abcdef0123456789abcdef";
        for accepted in [format!("ART-{hex}"), format!("ART-MISSING-{hex}")] {
            assert!(safe_artifact_id(&accepted), "{accepted:?}");
        }
        for refused in [
            format!("ART-{}", hex.to_uppercase()),
            format!("ART-{hex}0"),
            format!("ART-{hex}\n"),
            format!("ART-{hex}\r\n"),
            "ART-NOT-SAFE".to_owned(),
            format!("art-{hex}"),
        ] {
            assert!(!safe_artifact_id(&refused), "{refused:?}");
        }
    }
}
