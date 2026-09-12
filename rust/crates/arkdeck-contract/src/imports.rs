//! Current Import metadata and projections shared by owner and CLI. These are
//! values only: a caller's target reference never becomes a Runtime binding.
use crate::{ContractError, canonical_json, sha256_hex};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

pub const IMPORT_MAX_CHUNK_BYTES: u64 = 2 * 1024 * 1024;
pub const IMPORT_MAX_RECORDS: usize = 4096;
pub const IMPORT_MAX_CHUNKS: usize = 16_384;
pub const IMPORT_STAGING_QUOTA: u64 = 8 * 1024 * 1024 * 1024;
pub const IMPORT_MAX_RECORD_BYTES: usize = 4 * 1024 * 1024;

pub fn import_identifier(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.as_bytes()[0].is_ascii_alphanumeric()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
}
pub fn import_id(value: &str) -> bool {
    let Some(s) = value.strip_prefix("imp-") else {
        return false;
    };
    s.len() == 36
        && s.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_digit() || (b'a'..=b'f').contains(&b)
            }
        })
}
pub fn import_decimal(value: &Value) -> Option<u64> {
    let text = value.as_str()?;
    let number = text.parse::<u64>().ok()?;
    (number <= i64::MAX as u64 && number.to_string() == text).then_some(number)
}
pub fn import_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn exact(fields: &Map<String, Value>, names: &[&str]) -> bool {
    fields.len() == names.len() && names.iter().all(|key| fields.contains_key(*key))
}
fn invalid() -> ContractError {
    ContractError::Malformed
}

/// The Codable field names are the frozen Runtime Import durable format.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImportIntent {
    #[serde(rename = "importRequestID")]
    pub request_id: String,
    pub kind: String,
    #[serde(rename = "targetID")]
    pub target_id: String,
    #[serde(rename = "bindingRevision")]
    pub binding_revision: u64,
    #[serde(rename = "deviceProfile", skip_serializing_if = "Option::is_none")]
    pub device_profile: Option<String>,
    pub name: String,
    #[serde(rename = "byteCount")]
    pub byte_count: u64,
    pub sha256: String,
}
impl ImportIntent {
    pub fn from_wire(fields: &Map<String, Value>) -> Result<Self, ContractError> {
        if !exact(
            fields,
            &[
                "schemaVersion",
                "importRequestId",
                "kind",
                "targetId",
                "bindingRevision",
                "deviceProfile",
                "name",
                "byteCount",
                "sha256",
            ],
        ) || fields["schemaVersion"] != "arkdeck.import-intent/1"
        {
            return Err(invalid());
        }
        let text = |key| {
            fields
                .get(key)
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(invalid)
        };
        let value = Self {
            request_id: text("importRequestId")?,
            kind: text("kind")?,
            target_id: text("targetId")?,
            binding_revision: import_decimal(&fields["bindingRevision"]).ok_or_else(invalid)?,
            device_profile: if fields["deviceProfile"].is_null() {
                None
            } else {
                Some(text("deviceProfile")?)
            },
            name: text("name")?,
            byte_count: import_decimal(&fields["byteCount"]).ok_or_else(invalid)?,
            sha256: text("sha256")?,
        };
        value.validate()?;
        Ok(value)
    }
    pub fn validate(&self) -> Result<(), ContractError> {
        if !import_identifier(&self.request_id)
            || !import_identifier(&self.target_id)
            || self.binding_revision == 0
            || self.binding_revision > i64::MAX as u64
            || self.name.is_empty()
            || self.name.len() > 128
            || !self
                .name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
            || self.byte_count == 0
            || !import_digest(&self.sha256)
        {
            return Err(invalid());
        }
        let ordinary = self.name.as_bytes()[0].is_ascii_alphanumeric();
        let valid = match self.kind.as_str() {
            "hap" => {
                ordinary
                    && (self.name.ends_with(".hap") || self.name.ends_with(".hsp"))
                    && self.byte_count <= 64 * 1024 * 1024
                    && self.device_profile.is_none()
            }
            "workspace-patch" => {
                ordinary
                    && (self.name.ends_with(".patch") || self.name.ends_with(".diff"))
                    && self.byte_count <= 512 * 1024
                    && self.device_profile.is_none()
            }
            "native-library" => {
                self.name.starts_with("lib")
                    && self.name.ends_with(".so")
                    && self.name.len() > 6
                    && (64..=64 * 1024 * 1024).contains(&self.byte_count)
                    && self.device_profile.is_none()
            }
            "flash-bundle" => {
                self.name == "images.tar.gz"
                    && self.byte_count <= IMPORT_STAGING_QUOTA
                    && self.device_profile.as_deref() == Some("dayu200")
            }
            _ => false,
        };
        if !valid {
            return Err(invalid());
        }
        Ok(())
    }
    pub fn projection(&self) -> Value {
        json!({"schemaVersion":"arkdeck.import-intent/1","importRequestId":self.request_id,"kind":self.kind,
            "targetId":self.target_id,"bindingRevision":self.binding_revision.to_string(),"deviceProfile":self.device_profile,
            "name":self.name,"byteCount":self.byte_count.to_string(),"sha256":self.sha256})
    }
    pub fn fingerprint(&self) -> Result<String, ContractError> {
        self.validate()?;
        Ok(sha256_hex(&canonical_json(&self.projection())?))
    }
    pub fn media_type(&self) -> &'static str {
        match self.kind.as_str() {
            "hap" if self.name.ends_with(".hsp") => "application/vnd.openharmony.hsp",
            "hap" => "application/vnd.openharmony.hap",
            "workspace-patch" => "text/x-diff",
            "native-library" => "application/x-elf",
            _ => "application/gzip",
        }
    }
    pub fn privacy(&self) -> &'static str {
        if self.kind == "workspace-patch" {
            "sensitive"
        } else {
            "standard"
        }
    }
}

/// Bounded ISO-8601 timestamps used by current Import projections. Parsed
/// instants, rather than textual timezone spellings, compare release deadlines.
pub fn import_timestamp(s: &str) -> Option<f64> {
    let b = s.as_bytes();
    if b.len() < 20
        || b.len() > 128
        || !b.is_ascii()
        || !b[..19].iter().enumerate().all(|(i, c)| match i {
            4 | 7 => *c == b'-',
            10 => *c == b'T',
            13 | 16 => *c == b':',
            _ => c.is_ascii_digit(),
        })
    {
        return None;
    }
    let n = |a, b| s[a..b].parse::<i64>().ok();
    let (year, month, day) = (n(0, 4)?, n(5, 7)?, n(8, 10)?);
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => 0,
    };
    let (hour, minute, second) = (n(11, 13)?, n(14, 16)?, n(17, 19)?);
    if year == 0 || day == 0 || day > days || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let mut tail = &s[19..];
    let mut fraction = 0.0;
    if let Some(suffix) = tail.strip_prefix('.') {
        let length = suffix.bytes().take_while(u8::is_ascii_digit).count();
        if length == 0 {
            return None;
        }
        fraction = tail[..length + 1].parse::<f64>().ok()?;
        tail = &suffix[length..];
    }
    let zone = if tail == "Z" {
        0
    } else {
        let bytes = tail.as_bytes();
        if bytes.len() != 6
            || !matches!(bytes[0], b'+' | b'-')
            || bytes[3] != b':'
            || !bytes[1..3].iter().all(u8::is_ascii_digit)
            || !bytes[4..6].iter().all(u8::is_ascii_digit)
        {
            return None;
        }
        let hour = tail[1..3].parse::<i64>().ok()?;
        let minute = tail[4..6].parse::<i64>().ok()?;
        if hour > 23 || minute > 59 {
            return None;
        }
        (hour * 3600 + minute * 60) * if bytes[0] == b'-' { -1 } else { 1 }
    };
    let y = year - 1;
    let prior_month = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334][(month - 1) as usize];
    let days =
        365 * y + y / 4 - y / 100 + y / 400 + prior_month + i64::from(leap && month > 2) + day - 1;
    Some(((days - 730485) * 86400 + hour * 3600 + minute * 60 + second - zone) as f64 + fraction)
}

#[derive(Clone, Debug)]
pub struct ImportProjection {
    pub value: Value,
    pub intent: ImportIntent,
    pub id: String,
    pub generation: u64,
    pub state: String,
    pub next_offset: u64,
    pub maximum_chunk_bytes: u64,
}
impl ImportProjection {
    pub fn parse(value: &Value) -> Result<Self, ContractError> {
        let fields = value.as_object().ok_or_else(invalid)?;
        if !exact(
            fields,
            &[
                "schemaVersion",
                "importId",
                "importRequestId",
                "metadata",
                "metadataFingerprint",
                "generation",
                "state",
                "nextOffset",
                "maximumChunkBytes",
                "createdAtUtc",
                "updatedAtUtc",
                "receipt",
            ],
        ) || fields["schemaVersion"] != "arkdeck.import/1"
        {
            return Err(invalid());
        }
        let id = fields["importId"]
            .as_str()
            .filter(|s| import_id(s))
            .ok_or_else(invalid)?;
        let intent = ImportIntent::from_wire(fields["metadata"].as_object().ok_or_else(invalid)?)?;
        let generation = import_decimal(&fields["generation"])
            .filter(|n| *n > 0)
            .ok_or_else(invalid)?;
        let next_offset = import_decimal(&fields["nextOffset"]).ok_or_else(invalid)?;
        let maximum_chunk_bytes = import_decimal(&fields["maximumChunkBytes"])
            .filter(|n| (1..=IMPORT_MAX_CHUNK_BYTES).contains(n))
            .ok_or_else(invalid)?;
        let state = fields["state"].as_str().ok_or_else(invalid)?;
        let expected_generation = match state {
            "inProgress" | "committing" => 1,
            "committed" | "aborted" => 2,
            "released" => 3,
            _ => return Err(invalid()),
        };
        if generation != expected_generation
            || next_offset > intent.byte_count
            || fields["importRequestId"] != intent.request_id
            || fields["metadataFingerprint"] != intent.fingerprint()?
            || !["createdAtUtc", "updatedAtUtc"]
                .iter()
                .all(|key| fields[*key].as_str().and_then(import_timestamp).is_some())
            || (state == "committing" && next_offset != intent.byte_count)
        {
            return Err(invalid());
        }
        if ["committed", "released"].contains(&state) {
            let receipt = fields["receipt"].as_object().ok_or_else(invalid)?;
            if !exact(
                receipt,
                &[
                    "schemaVersion",
                    "importId",
                    "importRequestId",
                    "owner",
                    "artifactId",
                    "artifactDigest",
                    "byteCount",
                    "name",
                    "mediaType",
                    "privacy",
                    "targetId",
                    "bindingRevision",
                    "lease",
                    "generation",
                    "validation",
                ],
            ) || next_offset != intent.byte_count
                || receipt["schemaVersion"] != "arkdeck.import-receipt/1"
                || receipt["importId"] != id
                || receipt["importRequestId"] != intent.request_id
                || receipt["owner"] != json!({"kind":"import","id":id})
                || !receipt["artifactId"]
                    .as_str()
                    .is_some_and(import_identifier)
                || receipt["lease"]
                    != format!(
                        "lease-v1:{id}:{}",
                        receipt["artifactId"].as_str().unwrap_or_default()
                    )
                || receipt["artifactDigest"] != intent.sha256
                || import_decimal(&receipt["byteCount"]) != Some(intent.byte_count)
                || receipt["name"] != intent.name
                || receipt["targetId"] != intent.target_id
                || import_decimal(&receipt["bindingRevision"]) != Some(intent.binding_revision)
                || receipt["generation"] != "2"
                || !receipt["validation"].is_object()
                || receipt["validation"]["kind"] != intent.kind
                || receipt["mediaType"] != intent.media_type()
                || receipt["privacy"] != intent.privacy()
            {
                return Err(invalid());
            }
        } else if !fields["receipt"].is_null() {
            return Err(invalid());
        }
        Ok(Self {
            value: value.clone(),
            intent,
            id: id.into(),
            generation,
            state: state.into(),
            next_offset,
            maximum_chunk_bytes,
        })
    }
}

/// Validate an existing release record without releasing a lease or examining
/// Job references. The upload owner never invents either piece of authority.
pub fn validate_import_release(
    value: &Value,
    imported: &ImportProjection,
) -> Result<(), ContractError> {
    let fields = value.as_object().ok_or_else(invalid)?;
    let retention = fields
        .get("retention")
        .and_then(Value::as_object)
        .ok_or_else(invalid)?;
    if !exact(
        fields,
        &[
            "schemaVersion",
            "importId",
            "importRequestId",
            "owner",
            "artifactId",
            "lease",
            "releasedGeneration",
            "generation",
            "state",
            "releasedAtUtc",
            "retention",
        ],
    ) || !exact(retention, &["class", "pinned", "deadlineUtc"])
        || fields["schemaVersion"] != "arkdeck.import-release/1"
        || fields["state"] != "released"
        || fields["importId"] != imported.id
        || fields["importRequestId"] != imported.intent.request_id
        || fields["owner"] != json!({"kind":"import","id":imported.id})
        || fields["artifactId"] != imported.value["receipt"]["artifactId"]
        || fields["lease"] != imported.value["receipt"]["lease"]
        || fields["releasedGeneration"] != "2"
        || fields["generation"] != "3"
        || retention["class"] != "default"
        || retention["pinned"] != false
        || fields["releasedAtUtc"] != imported.value["updatedAtUtc"]
    {
        return Err(invalid());
    }
    let released = fields["releasedAtUtc"]
        .as_str()
        .and_then(import_timestamp)
        .ok_or_else(invalid)?;
    let deadline = retention["deadlineUtc"]
        .as_str()
        .and_then(import_timestamp)
        .ok_or_else(invalid)?;
    if deadline <= released {
        return Err(invalid());
    }
    Ok(())
}

pub fn encode_import_chunk(bytes: &[u8]) -> Result<String, ContractError> {
    if bytes.is_empty() || bytes.len() as u64 > IMPORT_MAX_CHUNK_BYTES {
        return Err(invalid());
    }
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut result = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        result.push(ALPHABET[(n >> 18) as usize] as char);
        result.push(ALPHABET[((n >> 12) & 63) as usize] as char);
        result.push(if chunk.len() > 1 {
            ALPHABET[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        result.push(if chunk.len() > 2 {
            ALPHABET[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    Ok(result)
}

pub fn decode_import_chunk(encoded: &str, byte_count: u64) -> Result<Vec<u8>, ContractError> {
    if !(1..=IMPORT_MAX_CHUNK_BYTES).contains(&byte_count) {
        return Err(invalid());
    }
    let encoded = encoded.as_bytes();
    let expected = byte_count as usize;
    if encoded.len() != expected.div_ceil(3) * 4 {
        return Err(invalid());
    }
    let sextet = |b| match b {
        b'A'..=b'Z' => Some(b - b'A'),
        b'a'..=b'z' => Some(b - b'a' + 26),
        b'0'..=b'9' => Some(b - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    };
    let mut bytes = Vec::with_capacity(expected);
    for (i, chunk) in encoded.as_chunks::<4>().0.iter().enumerate() {
        let a = sextet(chunk[0]).ok_or_else(invalid)?;
        let b = sextet(chunk[1]).ok_or_else(invalid)?;
        let last = (i + 1) * 4 == encoded.len();
        let remaining = expected - bytes.len();
        bytes.push(a << 2 | b >> 4);
        if last && remaining == 1 {
            if chunk[2] != b'=' || chunk[3] != b'=' || b & 15 != 0 {
                return Err(invalid());
            }
            continue;
        }
        let c = sextet(chunk[2]).ok_or_else(invalid)?;
        bytes.push(b << 4 | c >> 2);
        if last && remaining == 2 {
            if chunk[3] != b'=' || c & 3 != 0 {
                return Err(invalid());
            }
            continue;
        }
        let d = sextet(chunk[3]).ok_or_else(invalid)?;
        bytes.push(c << 6 | d);
    }
    if bytes.len() != expected {
        return Err(invalid());
    }
    Ok(bytes)
}

/// Validates the current reference observation. A clear projection grants no
/// lease or release authority; only the Runtime Job-reference owner can act.
pub fn validate_import_inspection(value: &Value) -> Result<ImportProjection, ContractError> {
    let fields = value.as_object().ok_or_else(invalid)?;
    let references = fields
        .get("references")
        .and_then(Value::as_object)
        .ok_or_else(invalid)?;
    if !exact(fields, &["schemaVersion", "import", "references"])
        || fields["schemaVersion"] != "arkdeck.import-inspection/1"
        || !exact(
            references,
            &[
                "state",
                "activeJobIds",
                "outcomeUnknownJobIds",
                "activeMaterializationCount",
            ],
        )
    {
        return Err(invalid());
    }
    let count = import_decimal(&references["activeMaterializationCount"])
        .filter(|n| *n <= 1024)
        .ok_or_else(invalid)?;
    let identities = |key| -> Result<Vec<&str>, ContractError> {
        let items = references
            .get(key)
            .and_then(Value::as_array)
            .filter(|v| v.len() <= 1000)
            .ok_or_else(invalid)?;
        let ids = items
            .iter()
            .map(|v| {
                v.as_str()
                    .filter(|s| import_identifier(s) && !s.starts_with("imp-"))
                    .ok_or_else(invalid)
            })
            .collect::<Result<Vec<_>, _>>()?;
        if ids.windows(2).any(|w| w[0] >= w[1]) {
            return Err(invalid());
        }
        Ok(ids)
    };
    let active = identities("activeJobIds")?;
    let unknown = identities("outcomeUnknownJobIds")?;
    if unknown.iter().any(|id| active.binary_search(id).is_err())
        || references["state"]
            != if active.is_empty() && count == 0 {
                "clear"
            } else {
                "referenced"
            }
    {
        return Err(invalid());
    }
    ImportProjection::parse(&fields["import"])
}
