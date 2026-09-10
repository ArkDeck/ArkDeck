//! Read-only Trace inventory over fixed descriptor-relative cache roots.
//! Mirrors ArkTrace maintenance's conservative treatment of unaccounted entries.
use arkdeck_platform::{HostDirectory, HostEntryKind};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{io, path::Path};

#[derive(Deserialize)]
#[allow(dead_code)]
struct Parser {
    name: String,
    #[serde(rename = "reportedVersion")]
    reported_version: String,
    #[serde(rename = "binarySHA256")]
    binary_sha256: String,
    #[serde(rename = "upstreamRepository")]
    upstream_repository: String,
    #[serde(rename = "upstreamRevision")]
    upstream_revision: String,
    architecture: String,
    #[serde(rename = "adapterVersion")]
    adapter_version: String,
    #[serde(rename = "buildRecipeVersion")]
    build_recipe_version: String,
}
#[derive(Deserialize)]
#[allow(dead_code)]
struct Key {
    #[serde(rename = "traceSHA256")]
    trace_sha256: String,
    #[serde(rename = "parserBinarySHA256")]
    parser_binary_sha256: String,
    #[serde(rename = "upstreamRevision")]
    upstream_revision: String,
    #[serde(rename = "schemaAdapterVersion")]
    schema_adapter_version: String,
    #[serde(rename = "indexSchemaVersion")]
    index_schema_version: i64,
    #[serde(rename = "parserKey")]
    parser_key: String,
}
#[derive(Deserialize)]
#[allow(dead_code)]
struct Preparation {
    #[serde(rename = "schemaAdapterVersion")]
    schema_adapter_version: String,
    #[serde(rename = "schemaFingerprint")]
    schema_fingerprint: String,
    #[serde(rename = "indexVersion")]
    index_version: i64,
    #[serde(rename = "upstreamDatabaseSHA256")]
    upstream_database_sha256: String,
    #[serde(rename = "upstreamDatabaseByteCount")]
    upstream_database_byte_count: i64,
}
#[derive(Deserialize)]
#[allow(dead_code)]
struct Metadata {
    #[serde(rename = "formatVersion")]
    format_version: i64,
    #[serde(rename = "cacheKey")]
    key: Key,
    parser: Parser,
    #[serde(rename = "traceSHA256")]
    trace_sha256: String,
    #[serde(rename = "sourceSHA256")]
    source_sha256: String,
    #[serde(rename = "sourceByteCount")]
    source_byte_count: i64,
    #[serde(rename = "schemaFingerprint")]
    schema_fingerprint: String,
    #[serde(rename = "schemaAdapterVersion")]
    schema_adapter_version: String,
    #[serde(rename = "indexSchemaVersion")]
    index_schema_version: i64,
    #[serde(rename = "databasePreparation")]
    preparation: Preparation,
    #[serde(rename = "databaseByteCount")]
    database_byte_count: i64,
    #[serde(rename = "createdAt")]
    created_at: String,
    #[serde(rename = "lastAccessedAt")]
    last_accessed_at: String,
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "trace snapshot refused")
}
fn hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

// The pinned writer emits UTC ISO8601 seconds. Additional accepted Foundation
// spellings remain differential vectors before this candidate can own a store.
fn timestamp(text: &str) -> bool {
    let bytes = text.as_bytes();
    if bytes.len() != 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || bytes[19] != b'Z'
    {
        return false;
    }
    let number = |range: std::ops::Range<usize>| -> Option<u32> {
        let part = bytes.get(range)?;
        if !part.iter().all(u8::is_ascii_digit) {
            return None;
        }
        Some(part.iter().fold(0, |n, b| n * 10 + u32::from(b - b'0')))
    };
    let (Some(year), Some(month), Some(day), Some(hour), Some(minute), Some(second)) = (
        number(0..4),
        number(5..7),
        number(8..10),
        number(11..13),
        number(14..16),
        number(17..19),
    ) else {
        return false;
    };
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => 0,
    };
    (1..=days).contains(&day) && hour < 24 && minute < 60 && second < 60
}

fn available(
    root: &HostDirectory,
    name: &str,
    filename: &str,
) -> io::Result<Option<arkdeck_platform::HostReadLock>> {
    let directory = match root.child(name) {
        Ok(directory) => directory,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    directory.try_lock_existing(filename)
}

pub fn trace_inventory(path: &Path) -> io::Result<Value> {
    let root = HostDirectory::open(path)?;
    let mut count = 0usize;
    let mut total = 0i64;
    let mut active = 0usize;
    for trace in root.names(4096)? {
        if !hex(&trace) || root.kind_and_size(&trace)?.0 != HostEntryKind::Directory {
            continue;
        }
        let trace_root = root.child(&trace)?;
        let remaining = 4096usize
            .checked_sub(count)
            .filter(|n| *n > 0)
            .ok_or_else(invalid)?;
        for parser in trace_root.names(remaining)? {
            if !hex(&parser) || trace_root.kind_and_size(&parser)?.0 != HostEntryKind::Directory {
                continue;
            }
            let entry = trace_root.child(&parser)?;
            for name in entry.names(16)? {
                let (kind, size) = entry.kind_and_size(&name)?;
                if kind != HostEntryKind::Regular || size < 0 {
                    return Err(invalid());
                }
                total = total.checked_add(size).ok_or_else(invalid)?;
            }
            count += 1;
            let metadata = entry
                .read("metadata.json", 16_384)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Metadata>(&bytes).ok());
            let Some(metadata) = metadata.filter(|m| {
                m.key.trace_sha256 == trace
                    && m.key.parser_key == parser
                    && timestamp(&m.created_at)
                    && timestamp(&m.last_accessed_at)
                    && entry
                        .kind_and_size("database.sqlite")
                        .is_ok_and(|(kind, size)| {
                            kind == HostEntryKind::Regular && size == m.database_byte_count
                        })
            }) else {
                active += 1;
                continue;
            };
            let id = arkdeck_contract::sha256_hex(
                format!("{}:{}", metadata.key.trace_sha256, metadata.key.parser_key).as_bytes(),
            );
            let Some(_key_lock) = available(&root, ".locks", &format!("{id}.lock"))? else {
                active += 1;
                continue;
            };
            let Some(_lease) = available(&root, ".leases", &format!("{id}.lease"))? else {
                active += 1;
                continue;
            };
        }
    }
    Ok(
        json!({"schemaVersion": "arkdeck.trace-cache-status/1", "entryCount": count,
        "totalByteCount": total.to_string(), "activeEntryCount": active,
        "inactiveEntryCount": count - active, "purgeScope": "inactiveDerivedDatabases"}),
    )
}
