//! Job-owned Artifact inspect/read wire results, backed by the actual read store.
//! The daemon must first perform its existing engine.jobReadSnapshot check. These
//! types validate references, not Runtime ownership/admission facts. Import
//! receipts/leases and transport error mapping remain with their separate owners.
use crate::{ArtifactReadRange, ArtifactReadStore, MAX_ARTIFACT_READ_BYTES};
use serde_json::{Map, Value, json};
use std::io;

const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
const DEFAULT_READ_BYTES: usize = 1_048_576;
const MAX_RESULT_BYTES: usize = 8 * 1024 * 1024 - 4096;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArtifactInspectRequest {
    job_id: String,
    artifact_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArtifactReadRequest {
    reference: ArtifactInspectRequest,
    offset: u64,
    maximum_bytes: usize,
    allow_sensitive: bool,
}

fn invalid() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "Artifact parameters require an exact Job reference and bounded typed options",
    )
}
fn corrupt() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "Artifact metadata or range is outside its published wire contract",
    )
}
fn identifier(text: &str) -> bool {
    (1..=128).contains(&text.len())
        && text.as_bytes()[0].is_ascii_alphanumeric()
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}
fn digest(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn closed(fields: &Map<String, Value>, allowed: &[&str]) -> io::Result<()> {
    if fields.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(invalid());
    }
    Ok(())
}
fn reference(fields: &Map<String, Value>) -> io::Result<ArtifactInspectRequest> {
    let owner = fields
        .get("owner")
        .and_then(Value::as_object)
        .ok_or_else(invalid)?;
    closed(owner, &["kind", "id"])?;
    let kind = owner
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    let job = owner
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    if kind == "import" {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "Import Artifact ownership requires its Import owner",
        ));
    }
    if kind != "job" {
        return Err(invalid());
    }
    let artifact = fields
        .get("artifactId")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    ArtifactInspectRequest::new(job, artifact)
}
impl ArtifactInspectRequest {
    /// Identifiers only, never a path. A syntactically valid Job ID still needs
    /// the daemon's real engine existence/ownership check before use.
    pub fn new(job_id: &str, artifact_id: &str) -> io::Result<Self> {
        if !identifier(job_id) || job_id.starts_with("imp-") || !identifier(artifact_id) {
            return Err(invalid());
        }
        Ok(Self {
            job_id: job_id.into(),
            artifact_id: artifact_id.into(),
        })
    }
    pub fn from_params(fields: &Map<String, Value>) -> io::Result<Self> {
        closed(fields, &["owner", "artifactId"])?;
        reference(fields)
    }
    pub fn job_id(&self) -> &str {
        &self.job_id
    }
    pub fn artifact_id(&self) -> &str {
        &self.artifact_id
    }
}
impl ArtifactReadRequest {
    pub fn new(
        reference: ArtifactInspectRequest,
        offset: u64,
        maximum_bytes: usize,
        allow_sensitive: bool,
    ) -> io::Result<Self> {
        if offset > MAX_SAFE_INTEGER || !(1..=MAX_ARTIFACT_READ_BYTES).contains(&maximum_bytes) {
            return Err(invalid());
        }
        Ok(Self {
            reference,
            offset,
            maximum_bytes,
            allow_sensitive,
        })
    }
    pub fn from_params(fields: &Map<String, Value>) -> io::Result<Self> {
        closed(
            fields,
            &[
                "owner",
                "artifactId",
                "offset",
                "maxBytes",
                "allowSensitive",
            ],
        )?;
        let reference = reference(fields)?;
        let offset = match fields.get("offset") {
            Some(v) => v.as_u64().ok_or_else(invalid)?,
            None => 0,
        };
        let maximum = match fields.get("maxBytes") {
            Some(v) => usize::try_from(v.as_u64().ok_or_else(invalid)?).map_err(|_| invalid())?,
            None => DEFAULT_READ_BYTES,
        };
        let sensitive = match fields.get("allowSensitive") {
            Some(v) => v.as_bool().ok_or_else(invalid)?,
            None => false,
        };
        Self::new(reference, offset, maximum, sensitive)
    }
    pub fn reference(&self) -> &ArtifactInspectRequest {
        &self.reference
    }
}

fn count(value: &Value) -> bool {
    value.as_u64().is_some_and(|n| n <= MAX_SAFE_INTEGER)
}
fn text(value: &Value, maximum: usize) -> bool {
    value
        .as_str()
        .is_some_and(|s| !s.is_empty() && s.len() <= maximum)
}
fn date(value: &Value) -> Option<f64> {
    crate::format_time::format_timestamp_seconds(value.as_str()?)
}

// Only consumes metadata obtained by this store; not a public testimony-to-trust
// converter. The durable decoder has already checked its exact nested key sets.
pub(crate) fn inspect_result(
    metadata: &Value,
    request: &ArtifactInspectRequest,
) -> io::Result<Value> {
    let binding = &metadata["bindingSnapshot"];
    let retention = &metadata["retention"];
    let status = if metadata["status"].get("published").is_some() {
        "published"
    } else if metadata["status"].get("missing").is_some() {
        "missing"
    } else if metadata["status"].get("truncated").is_some() {
        "truncated"
    } else {
        return Err(corrupt());
    };
    let hash = metadata["sha256"].as_str().ok_or_else(corrupt)?;
    if metadata["jobID"] != request.job_id
        || metadata["artifactID"] != request.artifact_id
        || !text(&metadata["name"], 1024)
        || !text(&metadata["mediaType"], 256)
        || !count(&metadata["byteCount"])
        || date(&metadata["createdAtUTC"]).is_none()
        || !text(&metadata["sourceOperation"], 256)
        || !text(&metadata["providerID"], 128)
        || !binding["targetID"].as_str().is_some_and(identifier)
        || (!binding["bindingRevision"].is_null()
            && (!count(&binding["bindingRevision"]) || binding["bindingRevision"] == 0))
        || (!binding["stableIdentitySHA256"].is_null()
            && !binding["stableIdentitySHA256"].as_str().is_some_and(digest))
        || (!retention["deadlineUTC"].is_null() && date(&retention["deadlineUTC"]).is_none())
        || !(digest(hash) || (hash.is_empty() && status != "published"))
    {
        return Err(corrupt());
    }
    let window = &metadata["observationWindow"];
    let observation = if window.is_null() {
        Value::Null
    } else {
        let start = date(&window["startUTC"]).ok_or_else(corrupt)?;
        let end = date(&window["endUTC"]).ok_or_else(corrupt)?;
        if end < start {
            return Err(corrupt());
        }
        json!({"startUtc":window["startUTC"],"endUtc":window["endUTC"]})
    };
    Ok(
        json!({"schemaVersion":"arkdeck.artifact/1","owner":{"kind":"job","id":request.job_id},
        "artifactId":request.artifact_id,"name":metadata["name"],"mediaType":metadata["mediaType"],
        "privacy":metadata["privacy"],"byteCount":metadata["byteCount"],
        "artifactDigest":if hash.is_empty(){Value::Null}else{json!(hash)},"status":status,
        "lease":if status == "published" {json!(format!("lease-v1:{}:{}",request.job_id,request.artifact_id))}else{Value::Null},
        "createdAtUtc":metadata["createdAtUTC"],"sourceOperation":metadata["sourceOperation"],"providerId":metadata["providerID"],
        "redactionApplied":metadata["redactionApplied"],
        "binding":{"targetId":binding["targetID"],"bindingRevision":binding["bindingRevision"],"stableIdentitySha256":binding["stableIdentitySHA256"]},
        "retention":{"class":retention["retentionClass"],"pinned":retention["pinned"],"deadlineUtc":retention["deadlineUTC"]},
        "observationWindow":observation}),
    )
}
fn base64(bytes: &[u8]) -> String {
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
    result
}
fn read_result(range: ArtifactReadRange) -> io::Result<Value> {
    if !identifier(&range.artifact_id)
        || !digest(&range.sha256)
        || range.total_byte_count > MAX_SAFE_INTEGER
        || range.offset > range.next_offset
        || range.next_offset > range.total_byte_count
        || range.next_offset - range.offset != range.bytes.len() as u64
        || range.bytes.len() > MAX_ARTIFACT_READ_BYTES
        || range.eof != (range.next_offset == range.total_byte_count)
        || (range.bytes.is_empty() && !range.eof)
    {
        return Err(corrupt());
    }
    Ok(
        json!({"artifactId":range.artifact_id,"artifactDigest":range.sha256,
        "offset":range.offset,"nextOffset":range.next_offset,"totalByteCount":range.total_byte_count,
        "eof":range.eof,"byteCount":range.bytes.len(),"base64":base64(&range.bytes)}),
    )
}
fn bounded(result: Value) -> io::Result<Value> {
    if arkdeck_contract::canonical_json(&result)
        .map_err(|_| corrupt())?
        .len()
        > MAX_RESULT_BYTES
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Artifact projection exceeds its bounded response size",
        ));
    }
    Ok(result)
}
impl ArtifactReadStore {
    pub fn inspect_wire(&self, request: &ArtifactInspectRequest) -> io::Result<Value> {
        bounded(inspect_result(
            &self.inspect(request.job_id(), request.artifact_id())?,
            request,
        )?)
    }
    pub fn read_wire(&self, request: &ArtifactReadRequest) -> io::Result<Value> {
        let (metadata, range) = self.read_with_metadata(
            request.reference.job_id(),
            request.reference.artifact_id(),
            request.offset,
            request.maximum_bytes,
            request.allow_sensitive,
        )?;
        // Validate the exact metadata used for this descriptor read, without a
        // second lookup that could race an index replacement or privacy change.
        inspect_result(&metadata, &request.reference)?;
        bounded(read_result(range)?)
    }
}
