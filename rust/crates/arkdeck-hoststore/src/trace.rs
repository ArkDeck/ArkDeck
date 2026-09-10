//! Read-only Trace inventory over fixed descriptor-relative cache roots.
//! Mirrors ArkTrace maintenance's conservative treatment of unaccounted entries.
use arkdeck_platform::{HostDirectory, HostEntryKind};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{io, path::Path};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
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
#[serde(deny_unknown_fields)]
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
    #[serde(deserialize_with = "decode_integer")]
    index_schema_version: i64,
    #[serde(rename = "parserKey")]
    parser_key: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
#[allow(dead_code)]
struct Preparation {
    #[serde(rename = "schemaAdapterVersion")]
    schema_adapter_version: String,
    #[serde(rename = "schemaFingerprint")]
    schema_fingerprint: String,
    #[serde(rename = "indexVersion")]
    #[serde(deserialize_with = "decode_integer")]
    index_version: i64,
    #[serde(rename = "upstreamDatabaseSHA256")]
    upstream_database_sha256: String,
    #[serde(rename = "upstreamDatabaseByteCount")]
    #[serde(deserialize_with = "decode_integer")]
    upstream_database_byte_count: i64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
#[allow(dead_code)]
struct Metadata {
    #[serde(rename = "formatVersion")]
    #[serde(deserialize_with = "decode_integer")]
    format_version: i64,
    #[serde(rename = "cacheKey")]
    key: Key,
    parser: Parser,
    #[serde(rename = "traceSHA256")]
    trace_sha256: String,
    #[serde(rename = "sourceSHA256")]
    source_sha256: String,
    #[serde(rename = "sourceByteCount")]
    #[serde(deserialize_with = "decode_integer")]
    source_byte_count: i64,
    #[serde(rename = "schemaFingerprint")]
    schema_fingerprint: String,
    #[serde(rename = "schemaAdapterVersion")]
    schema_adapter_version: String,
    #[serde(rename = "indexSchemaVersion")]
    #[serde(deserialize_with = "decode_integer")]
    index_schema_version: i64,
    #[serde(rename = "databasePreparation")]
    preparation: Preparation,
    #[serde(rename = "databaseByteCount")]
    #[serde(deserialize_with = "decode_integer")]
    database_byte_count: i64,
    #[serde(rename = "createdAt")]
    created_at: String,
    #[serde(rename = "lastAccessedAt")]
    last_accessed_at: String,
}

// Decode dictionary members in Foundation's first-key-wins order while
// retaining the original numeric tokens for the integer compatibility path.
struct FirstFields(std::collections::BTreeMap<String, Box<serde_json::value::RawValue>>);
impl<'de> Deserialize<'de> for FirstFields {
    fn deserialize<D: serde::Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        struct FieldsVisitor;
        impl<'de> serde::de::Visitor<'de> for FieldsVisitor {
            type Value = FirstFields;
            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a Trace metadata object")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(
                self,
                mut map: M,
            ) -> Result<Self::Value, M::Error> {
                let mut fields = std::collections::BTreeMap::new();
                while let Some((key, value)) =
                    map.next_entry::<String, Box<serde_json::value::RawValue>>()?
                {
                    fields.entry(key).or_insert(value);
                }
                Ok(FirstFields(fields))
            }
        }
        decoder.deserialize_map(FieldsVisitor)
    }
}

fn metadata_snapshot(bytes: &[u8]) -> Option<Metadata> {
    let text = json_text(bytes)?;
    let mut fields = serde_json::from_str::<FirstFields>(&text).ok()?.0;
    for name in ["cacheKey", "parser", "databasePreparation"] {
        let nested = serde_json::from_str::<FirstFields>(fields.get(name)?.get())
            .ok()?
            .0;
        fields.insert(
            name.to_owned(),
            serde_json::value::to_raw_value(&nested).ok()?,
        );
    }
    serde_json::from_slice(&serde_json::to_vec(&fields).ok()?).ok()
}

fn json_text(bytes: &[u8]) -> Option<String> {
    // JSONDecoder recognizes UTF-8, UTF-16 and UTF-32 from a BOM or the
    // leading ASCII JSON code unit. Conversion changes only this read snapshot.
    let (width, big_endian, skip) = if bytes.starts_with(&[0, 0, 0xfe, 0xff]) {
        (4, true, 4)
    } else if bytes.starts_with(&[0xfe, 0xff, 0, 0]) {
        // Preserve the published Swift 6.2 prefix table, including this
        // swapped UTF-32LE marker. A conventional FF FE 00 00 marker
        // follows its UTF-16LE branch and fails metadata decoding.
        (4, false, 4)
    } else if bytes.starts_with(&[0xfe, 0xff]) {
        (2, true, 2)
    } else if bytes.starts_with(&[0xff, 0xfe]) {
        (2, false, 2)
    } else if bytes.starts_with(&[0xef, 0xbb, 0xbf]) {
        (1, false, 3)
    } else if bytes.len() >= 4 && bytes[..3] == [0, 0, 0] && bytes[3] != 0 {
        (4, true, 0)
    } else if bytes.len() >= 4 && bytes[1..4] == [0, 0, 0] && bytes[0] != 0 {
        (4, false, 0)
    } else if bytes.len() >= 4 && bytes[0] == 0 && bytes[2] == 0 && bytes[1] != 0 && bytes[3] != 0 {
        (2, true, 0)
    } else if bytes.len() >= 4 && bytes[1] == 0 && bytes[3] == 0 && bytes[0] != 0 && bytes[2] != 0 {
        (2, false, 0)
    } else {
        (1, false, 0)
    };
    let bytes = &bytes[skip..];
    match width {
        1 => String::from_utf8(bytes.to_vec()).ok(),
        2 if bytes.len().is_multiple_of(2) => {
            let units: Vec<u16> = bytes
                .as_chunks::<2>()
                .0
                .iter()
                .map(|pair| {
                    if big_endian {
                        u16::from_be_bytes([pair[0], pair[1]])
                    } else {
                        u16::from_le_bytes([pair[0], pair[1]])
                    }
                })
                .collect();
            String::from_utf16(&units).ok()
        }
        4 if bytes.len().is_multiple_of(4) => bytes
            .as_chunks::<4>()
            .0
            .iter()
            .map(|unit| {
                let unit = [unit[0], unit[1], unit[2], unit[3]];
                char::from_u32(if big_endian {
                    u32::from_be_bytes(unit)
                } else {
                    u32::from_le_bytes(unit)
                })
            })
            .collect(),
        _ => None,
    }
}

// Preserve the numeric token: serde's binary64 intermediate would erase the
// Decimal fallback used by the pinned Foundation JSONDecoder above 2^53.
fn decode_integer<'de, D: serde::Deserializer<'de>>(decoder: D) -> Result<i64, D::Error> {
    let raw = Box::<serde_json::value::RawValue>::deserialize(decoder)?;
    foundation_integer(raw.get()).ok_or_else(|| serde::de::Error::custom("trace integer refused"))
}

fn foundation_integer(token: &str) -> Option<i64> {
    if let Ok(value) = token.parse::<i64>() {
        return Some(value);
    }
    // RawValue has already checked JSON syntax, but strings and other JSON
    // values must never enter the numeric conversion path.
    if !matches!(token.as_bytes().first(), Some(b'-' | b'0'..=b'9')) {
        return None;
    }
    let number = token.parse::<f64>().ok()?;
    if !number.is_finite()
        || number.fract() != 0.0
        || !(-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&number)
    {
        return None;
    }
    if number.abs() < 9_007_199_254_740_992.0 {
        // The preceding checks prove this cast is integral and in range.
        #[allow(clippy::cast_possible_truncation)]
        return Some(number as i64);
    }
    decimal_integer(token)
}

fn decimal_integer(token: &str) -> Option<i64> {
    // Foundation's Decimal parser accumulates a 128-bit mantissa, drops digits
    // after overflow, then compacts trailing zeros. Its integer conversion first
    // requires the compact mantissa to fit UInt64, before applying the exponent.
    let negative = token.starts_with('-');
    let token = token.strip_prefix('-').unwrap_or(token);
    let (significand, explicit) = token.split_once(['e', 'E']).unwrap_or((token, "0"));
    let explicit = explicit.parse::<i32>().ok()?;
    if !(-254..=254).contains(&explicit) {
        return None;
    }
    let (whole, fraction) = significand.split_once('.').unwrap_or((significand, ""));
    let mut mantissa = 0u128;
    let mut exponent = 0i32;
    let mut overflow = false;
    for digit in whole.bytes() {
        let next = mantissa
            .checked_mul(10)
            .and_then(|n| n.checked_add(u128::from(digit - b'0')));
        if overflow || next.is_none() {
            overflow = true;
            exponent += 1;
            if exponent > 127 {
                return None;
            }
        } else {
            mantissa = next?;
        }
    }
    for digit in fraction.bytes() {
        if overflow {
            continue;
        }
        let Some(next) = mantissa
            .checked_mul(10)
            .and_then(|n| n.checked_add(u128::from(digit - b'0')))
        else {
            overflow = true;
            continue;
        };
        mantissa = next;
        exponent -= 1;
        if exponent < -128 {
            return None;
        }
    }
    exponent += explicit;
    if !(-128..=127).contains(&exponent) {
        return None;
    }
    while mantissa != 0 && mantissa.is_multiple_of(10) && exponent < 127 {
        mantissa /= 10;
        exponent += 1;
    }
    let mut value = u64::try_from(mantissa).ok()?;
    for _ in 0..exponent.abs() {
        value = if exponent < 0 {
            value / 10
        } else {
            value.checked_mul(10)?
        };
    }
    let value = i64::try_from(value).ok()?;
    Some(if negative { -value } else { value })
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

fn available(
    root: &HostDirectory,
    name: &str,
    filename: &str,
    maximum: Option<u64>,
) -> io::Result<Option<arkdeck_platform::HostReadLock>> {
    let directory = match root.child(name) {
        Ok(directory) => directory,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    directory.try_trace_lock_existing(filename, maximum)
}

pub fn trace_inventory(path: &Path) -> io::Result<Value> {
    let root = HostDirectory::open_trace_inventory(path)?;
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
                .and_then(|bytes| metadata_snapshot(&bytes));
            let Some(metadata) = metadata.filter(|m| {
                m.key.trace_sha256 == trace
                    && m.key.parser_key == parser
                    && crate::format_time::valid_format_timestamp(&m.created_at)
                    && crate::format_time::valid_format_timestamp(&m.last_accessed_at)
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
            let Some(_key_lock) = available(&root, ".locks", &format!("{id}.lock"), Some(4096))?
            else {
                active += 1;
                continue;
            };
            let Some(_lease) = available(&root, ".leases", &format!("{id}.lease"), None)? else {
                active += 1;
                continue;
            };
        }
    }
    root.validate_path(path)?;
    Ok(
        json!({"schemaVersion": "arkdeck.trace-cache-status/1", "entryCount": count,
        "totalByteCount": total.to_string(), "activeEntryCount": active,
        "inactiveEntryCount": count - active, "purgeScope": "inactiveDerivedDatabases"}),
    )
}
