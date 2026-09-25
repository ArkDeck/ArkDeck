//! `arkdeck diagnostics inspect|preview`: Swift's
//! `RuntimeCLI.runDiagnosticsResource` over the shared offline parser
//! (`DiagnosticSessionOfflineInspector`, `DiagnosticSessionReading`,
//! `DiagnosticArtifactTextPreview`).
//!
//! Both read what one `capture.diagnostics@1` Job already published — its
//! Artifact inventory, and the exact bytes of the documents they need — and
//! derive locally; nothing reaches a device and nothing is written. Every
//! derived answer says it is `offlineDerived` and names the parser and the
//! Artifacts it read, so it is never taken for new device evidence. A
//! sensitive Artifact is previewed only on the caller's explicit
//! `--allow-sensitive`.
use crate::CliError;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use unicode_segmentation::UnicodeSegmentation;

const OPERATION: &str = "capture.diagnostics@1";
const PARSER: &str = "arkdeck.diagnostics-session-parser";
const PARSER_VERSION: &str = "1.0.0";
const INDEX: &str = "artifact-index.json";
const SUMMARY: &str = "capture-summary.json";
const MARKERS: &str = "markers.json";
const INVENTORY_MAXIMUM: usize = 64_000;
const MAXIMUM_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
const DOCUMENT_MAXIMUM_BYTES: u64 = 1024 * 1024;
const PREVIEW_MAXIMUM_BYTES: u64 = 2 * 1024 * 1024;
const PREVIEW_MAXIMUM_CHARACTERS: i64 = 120_000;
/// Swift `ArtifactReadProjection.maximumBytes`: one read's bound.
const READ_MAXIMUM_BYTES: u64 = 4_194_304;

fn fail(code: &'static str, message: impl Into<String>) -> CliError {
    CliError::new(code, message)
}

/// Swift `DiagnosticSessionOfflineInspectorError`, mapped as the CLI maps it:
/// integrity to `artifactIntegrityFailed`, size to `inputTooLarge`, sensitive
/// content to `sensitiveAccessDenied`, everything else `recordUnreadable`,
/// each with the error's reason.
fn inspector_error(code: &'static str, reason: &str) -> CliError {
    fail(code, reason)
}

fn invalid(reason: &str) -> CliError {
    inspector_error("recordUnreadable", reason)
}

/// Swift `DiagnosticOfflineArtifactMetadata`.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Metadata {
    id: String,
    name: String,
    media_type: String,
    privacy: String,
    status: String,
    source: String,
    byte_count: u64,
    sha256: Option<String>,
}

impl Metadata {
    fn value(&self) -> Value {
        json!({"artifactId": self.id, "name": self.name, "mediaType": self.media_type,
            "privacy": self.privacy, "status": self.status, "statusDetail": null,
            "sourceOperation": self.source, "byteCount": self.byte_count,
            "artifactDigest": self.sha256})
    }
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Swift `DiagnosticOfflineArtifactMetadata.init`'s checks.
fn metadata_of(row: &Value) -> Result<Metadata, CliError> {
    let malformed = || {
        fail(
            "recordUnreadable",
            "diagnostic Artifact metadata is malformed",
        )
    };
    let text = |key: &str| row[key].as_str().map(str::to_owned).ok_or_else(malformed);
    let byte_count = row["byteCount"]
        .as_u64()
        .filter(|count| i64::try_from(*count).is_ok())
        .ok_or_else(malformed)?;
    let metadata = Metadata {
        id: text("artifactId")?,
        name: text("name")?,
        media_type: text("mediaType")?,
        privacy: text("privacy")?,
        status: text("status")?,
        source: text("sourceOperation")?,
        byte_count,
        sha256: row["artifactDigest"].as_str().map(str::to_owned),
    };
    let valid = !metadata.id.is_empty()
        && metadata.id.len() <= 512
        && !metadata.id.chars().any(char::is_control)
        && !metadata.name.is_empty()
        && metadata.name.len() <= 1024
        && !metadata.media_type.is_empty()
        && metadata.media_type.len() <= 256
        && ["standard", "sensitive"].contains(&metadata.privacy.as_str())
        && ["published", "missing", "truncated"].contains(&metadata.status.as_str())
        && !metadata.source.is_empty()
        && metadata.source.len() <= 256
        && metadata.byte_count <= MAXIMUM_SAFE_INTEGER
        && if metadata.status == "published" {
            metadata.sha256.as_deref().is_some_and(lowercase_sha256)
        } else {
            metadata.sha256.is_none()
        };
    if valid {
        Ok(metadata)
    } else {
        Err(invalid("diagnostics_invalid_artifact_metadata"))
    }
}

/// Swift `DiagnosticOfflineArtifact`: metadata-bound bytes.
struct Document {
    metadata: Metadata,
    bytes: Vec<u8>,
}

fn bound(metadata: &Metadata, bytes: Vec<u8>) -> Result<Document, CliError> {
    if metadata.status != "published" || metadata.byte_count != bytes.len() as u64 {
        return Err(inspector_error(
            "artifactIntegrityFailed",
            "diagnostics_artifact_byte_count_mismatch",
        ));
    }
    if metadata.sha256.as_deref() != Some(arkdeck_contract::sha256_hex(&bytes).as_str()) {
        return Err(inspector_error(
            "artifactIntegrityFailed",
            "diagnostics_artifact_integrity_mismatch",
        ));
    }
    Ok(Document {
        metadata: metadata.clone(),
        bytes,
    })
}

/// The leaf's whole-session bound: `--timeout` (Swift's default 30s). The
/// registry pass judges its grammar and the required options, and its refusal
/// is the one reported for an argv this refuses.
pub(crate) fn configure(
    command: &str,
    fields: &mut Map<String, Value>,
    help: bool,
) -> Result<Option<u64>, CliError> {
    let verb = match command {
        _ if help => return Ok(None),
        "diagnostics.inspect" => "inspect",
        "diagnostics.preview" => "preview",
        _ => return Ok(None),
    };
    if !fields.contains_key("jobId") || (verb == "preview" && !fields.contains_key("artifactId")) {
        return Err(fail(
            "invalidOption",
            format!("diagnostics {verb} requires its --job and --artifact options"),
        ));
    }
    let timeout = fields.remove("timeout");
    crate::read_only_resources::duration(timeout.as_ref().and_then(Value::as_str).unwrap_or("30s"))
        .map(Some)
        .ok_or_else(|| {
            fail(
                "invalidInput",
                "diagnostics timeout must be a bounded duration",
            )
        })
}

/// One request to the Runtime, as the leaf's session sends it.
pub type Request<'a> = dyn FnMut(&str, Map<String, Value>) -> Result<Value, CliError> + 'a;

/// Swift `diagnosticsInventory`: every page of the Job's Artifacts, one
/// snapshot, bounded.
fn inventory(owner: &Value, job: &str, request: &mut Request) -> Result<Vec<Metadata>, CliError> {
    let mut rows: Vec<Value> = Vec::new();
    let mut cursor: Option<String> = None;
    let mut revision: Option<String> = None;
    let mut seen = BTreeSet::new();
    loop {
        let mut params = Map::from_iter([
            ("owner".to_owned(), owner.clone()),
            ("pageSize".to_owned(), json!(1000)),
        ]);
        if let Some(cursor) = &cursor {
            params.insert("cursor".into(), json!(cursor));
        }
        let page = request("artifact.list", params)?;
        crate::validate_artifact_page(&page, owner, 1000)?;
        let (Some(items), Some(snapshot), Some(more)) = (
            page["items"].as_array(),
            page["snapshotRevision"].as_str(),
            page["hasMore"].as_bool(),
        ) else {
            return Err(fail(
                "recordUnreadable",
                "diagnostic Artifact inventory is malformed",
            ));
        };
        if revision.as_deref().is_some_and(|before| before != snapshot) {
            return Err(fail(
                "factsDrifted",
                "diagnostic Artifact snapshot changed while paging",
            ));
        }
        revision = Some(snapshot.to_owned());
        rows.extend(items.iter().cloned());
        if rows.len() > INVENTORY_MAXIMUM {
            return Err(fail(
                "inputTooLarge",
                "diagnostic Artifact inventory exceeds its bound",
            ));
        }
        if !more {
            break;
        }
        match page["nextCursor"].as_str() {
            Some(next) if seen.insert(next.to_owned()) => cursor = Some(next.to_owned()),
            _ => {
                return Err(fail(
                    "recordUnreadable",
                    "diagnostic Artifact pagination stopped advancing",
                ));
            }
        }
    }
    if rows.is_empty() {
        return Err(fail(
            "resourceNotFound",
            format!("diagnostic Job {job} published no Artifacts"),
        ));
    }
    rows.iter().map(metadata_of).collect()
}

/// Swift `ArtifactReadProjection(_:)`: one bounded, digest-bound range of an
/// Artifact, exactly the members Swift's projection has.
pub(crate) struct ArtifactRange {
    pub id: String,
    pub digest: String,
    pub offset: u64,
    pub next: u64,
    pub total: u64,
    pub bytes: Vec<u8>,
}

pub(crate) fn artifact_range(value: &Value) -> Result<ArtifactRange, CliError> {
    let invalid = || {
        fail(
            "recordUnreadable",
            "Artifact range identity, bounds or bytes are malformed",
        )
    };
    let count = |key: &str| {
        value[key]
            .as_u64()
            .filter(|count| *count <= MAXIMUM_SAFE_INTEGER)
    };
    let keys: BTreeSet<&str> = value
        .as_object()
        .ok_or_else(invalid)?
        .keys()
        .map(String::as_str)
        .collect();
    let expected = BTreeSet::from([
        "artifactId",
        "artifactDigest",
        "offset",
        "nextOffset",
        "totalByteCount",
        "eof",
        "byteCount",
        "base64",
    ]);
    let (Some(id), Some(digest), Some(offset), Some(next), Some(total), Some(bytes)) = (
        value["artifactId"]
            .as_str()
            .filter(|id| crate::read_only_resources::identifier(id)),
        value["artifactDigest"]
            .as_str()
            .filter(|digest| lowercase_sha256(digest)),
        count("offset"),
        count("nextOffset"),
        count("totalByteCount"),
        count("byteCount"),
    ) else {
        return Err(invalid());
    };
    if keys != expected
        || offset > total
        || next < offset
        || next > total
        || bytes != next - offset
        || bytes > READ_MAXIMUM_BYTES
        || value["eof"] != (next == total)
        || (bytes == 0 && next != total)
    {
        return Err(invalid());
    }
    let decoded = crate::artifact_bytes(value).map_err(|_| invalid())?;
    Ok(ArtifactRange {
        id: id.to_owned(),
        digest: digest.to_owned(),
        offset,
        next,
        total,
        bytes: decoded,
    })
}

/// Swift `diagnosticsReadWholeArtifact`: every range of one published
/// Artifact, bound to its immutable metadata.
fn read_whole(
    owner: &Value,
    metadata: &Metadata,
    maximum: u64,
    allow_sensitive: bool,
    request: &mut Request,
) -> Result<Vec<u8>, CliError> {
    let Some(digest) = metadata
        .sha256
        .as_deref()
        .filter(|_| metadata.status == "published" && metadata.byte_count <= maximum)
    else {
        return Err(fail(
            "inputTooLarge",
            "diagnostic Artifact exceeds the bounded read or is unpublished",
        ));
    };
    let mut bytes = Vec::new();
    let mut offset = 0_u64;
    loop {
        let value = request(
            "artifact.read",
            Map::from_iter([
                ("owner".to_owned(), owner.clone()),
                ("artifactId".to_owned(), json!(metadata.id)),
                ("offset".to_owned(), json!(offset)),
                ("maxBytes".to_owned(), json!(READ_MAXIMUM_BYTES)),
                ("allowSensitive".to_owned(), json!(allow_sensitive)),
            ]),
        )?;
        let page = artifact_range(&value)?;
        if page.id != metadata.id
            || page.digest != digest
            || page.total != metadata.byte_count
            || page.offset != offset
        {
            return Err(fail(
                "recordUnreadable",
                "diagnostic Artifact range changed identity",
            ));
        }
        let (next, total) = (page.next, page.total);
        bytes.extend_from_slice(&page.bytes);
        if next == total {
            break;
        }
        if next <= offset {
            return Err(fail(
                "recordUnreadable",
                "diagnostic Artifact read stopped advancing",
            ));
        }
        offset = next;
    }
    if bytes.len() as u64 != metadata.byte_count || arkdeck_contract::sha256_hex(&bytes) != digest {
        return Err(fail(
            "artifactIntegrityFailed",
            "diagnostic Artifact bytes do not match immutable metadata",
        ));
    }
    Ok(bytes)
}

/// Swift `diagnosticsJobRequest`: the Job's own typed request, which must be
/// the exact diagnostics capture its status names. Answers the request's typed
/// inputs (Swift decodes an absent or null `inputs` as none).
fn job_request(job: &str, request: &mut Request) -> Result<Map<String, Value>, CliError> {
    let show = request(
        "job.show",
        Map::from_iter([("jobId".to_owned(), json!(job))]),
    )?;
    crate::job_resources::validate_show(&show, job)?;
    let status = &show["job"];
    let (Some(target), Some(typed)) = (
        status["targetId"].as_str(),
        show.get("request").and_then(Value::as_object),
    ) else {
        return Err(fail(
            "recordUnreadable",
            "Job is not an exact diagnostics capture",
        ));
    };
    if status["jobId"] != job || status["operation"] != OPERATION {
        return Err(fail(
            "recordUnreadable",
            "Job is not an exact diagnostics capture",
        ));
    }
    let (reference, requested, inputs) = decode_request(typed).ok_or_else(|| {
        fail(
            "recordUnreadable",
            "diagnostic session could not be decoded",
        )
    })?;
    if reference != OPERATION || requested != target {
        return Err(fail(
            "recordUnreadable",
            "diagnostic Job request does not match its status",
        ));
    }
    Ok(inputs)
}

/// The part of Swift's `RuntimeOperationRequest` decoding this leaf reads:
/// the closed envelope, its operation reference, its target and its typed
/// inputs. The Runtime decoded the whole request when it admitted the Job.
fn decode_request(typed: &Map<String, Value>) -> Option<(String, String, Map<String, Value>)> {
    const KEYS: [&str; 11] = [
        "documentType",
        "schemaVersion",
        "requestId",
        "idempotencyKey",
        "target",
        "operation",
        "inputs",
        "requestedOutputs",
        "authorization",
        "clientContext",
        "reviewedPlanDigest",
    ];
    let closed = |value: &Value, allowed: &[&str]| {
        value
            .as_object()
            .is_some_and(|fields| fields.keys().all(|key| allowed.contains(&key.as_str())))
    };
    if typed.get("schemaVersion") != Some(&json!("1.0.0"))
        || typed
            .get("documentType")
            .is_some_and(|kind| kind != "runtime-operation-request")
        || !typed.keys().all(|key| KEYS.contains(&key.as_str()))
        || !typed["requestId"].is_string()
        || !typed["idempotencyKey"].is_string()
        || !closed(&typed["target"], &["targetId", "expectedBindingRevision"])
        || !closed(&typed["operation"], &["id", "version"])
    {
        return None;
    }
    let operation = &typed["operation"];
    let id = operation["id"].as_str()?;
    let reference = match operation.get("version") {
        None | Some(Value::Null) => id.to_owned(),
        Some(version) => format!("{id}@{}", version.as_i64()?),
    };
    let target = typed["target"]["targetId"].as_str()?.to_owned();
    let inputs = match typed.get("inputs") {
        None | Some(Value::Null) => Map::new(),
        Some(Value::Object(inputs)) => inputs.clone(),
        Some(_) => return None,
    };
    Some((reference, target, inputs))
}

/// Swift `requestedProducts`: what the capture's typed inputs asked for.
fn requested_products(inputs: &Map<String, Value>) -> Result<BTreeSet<String>, CliError> {
    let parameters = || invalid("diagnostics_invalid_capture_parameters");
    let enabled = |name: &str, default: bool| -> Result<bool, CliError> {
        match inputs.get(name) {
            None => Ok(default),
            Some(Value::Bool(flag)) => Ok(*flag),
            Some(_) => Err(parameters()),
        }
    };
    let mut names = BTreeSet::new();
    if enabled("captureHilog", true)? {
        names.insert("hilog.txt".to_owned());
    }
    if enabled("uiDump", true)? {
        names.insert("ui-dump.json".to_owned());
    }
    if enabled("advancedDump", false)? {
        names.insert("advanced-dump.txt".to_owned());
    }
    if enabled("uiComponentTree", false)? {
        names.insert("ui-tree.json".to_owned());
    }
    if enabled("uiScreenshot", false)? {
        let image = match inputs.get("screenshotImageType") {
            None => "png",
            Some(Value::String(kind)) if kind == "png" || kind == "jpeg" => kind.as_str(),
            Some(_) => return Err(parameters()),
        };
        names.insert(format!("screenshot.{image}"));
    }
    if enabled("crashLogs", false)? {
        names.insert("crash-index.txt".to_owned());
    }
    for (field, product) in [
        ("crashLogName", "crash-log.txt"),
        ("bundleName", "application-liveness.json"),
    ] {
        if let Some(value) = inputs.get(field) {
            if !value.as_str().is_some_and(|text| !text.is_empty()) {
                return Err(parameters());
            }
            names.insert(product.to_owned());
        }
    }
    if let Some(value) = inputs.get("traceCategories") {
        let tags = value.as_array().ok_or_else(parameters)?;
        if !tags
            .iter()
            .all(|tag| tag.as_str().is_some_and(|text| !text.is_empty()))
        {
            return Err(parameters());
        }
        if !tags.is_empty() {
            names.insert("trace.htrace".to_owned());
        }
    }
    Ok(names)
}

/// Swift's decoded `Index` product.
#[derive(Clone, Debug, PartialEq)]
struct Product {
    status: String,
    required: bool,
    artifact_id: Option<String>,
    byte_count: Option<i64>,
    sha256: Option<String>,
    detail: Option<String>,
}

/// Swift's decoded `Index`.
struct Index {
    job_id: String,
    operation: String,
    artifacts: BTreeMap<String, Product>,
    completeness: Option<String>,
    missing_required: Option<Vec<String>>,
}

/// Swift `JSONDecoder().decode(Index.self, from:)`: the members it names, of
/// their exact types; others are ignored.
fn decode_index(bytes: &[u8]) -> Result<Index, CliError> {
    let unreadable = || invalid("diagnostics_unreadable_session_document");
    let value: Value = serde_json::from_slice(bytes).map_err(|_| unreadable())?;
    let optional_text = |value: &Value, key: &str| -> Result<Option<String>, CliError> {
        match value.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(text)) => Ok(Some(text.clone())),
            Some(_) => Err(unreadable()),
        }
    };
    let mut artifacts = BTreeMap::new();
    for (name, product) in value["artifacts"].as_object().ok_or_else(unreadable)? {
        let byte_count = match product.get("byteCount") {
            None | Some(Value::Null) => None,
            Some(count) => Some(count.as_i64().ok_or_else(unreadable)?),
        };
        artifacts.insert(
            name.clone(),
            Product {
                status: product["status"]
                    .as_str()
                    .ok_or_else(unreadable)?
                    .to_owned(),
                required: product["required"].as_bool().ok_or_else(unreadable)?,
                artifact_id: optional_text(product, "artifactId")?,
                byte_count,
                sha256: optional_text(product, "sha256")?,
                detail: optional_text(product, "detail")?,
            },
        );
    }
    let missing_required = match value.get("missingRequired") {
        None | Some(Value::Null) => None,
        Some(Value::Array(names)) => Some(
            names
                .iter()
                .map(|name| name.as_str().map(str::to_owned).ok_or_else(unreadable))
                .collect::<Result<_, _>>()?,
        ),
        Some(_) => return Err(unreadable()),
    };
    Ok(Index {
        job_id: value["jobId"].as_str().ok_or_else(unreadable)?.to_owned(),
        operation: value["operation"]
            .as_str()
            .ok_or_else(unreadable)?
            .to_owned(),
        artifacts,
        completeness: optional_text(&value, "completeness")?,
        missing_required,
    })
}

/// Swift `ISO8601Timestamps.parse`: an ISO 8601 instant, with or without
/// fractional seconds, `Z` or a numeric offset.
fn instant(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() < 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
    {
        return false;
    }
    let digits = |range: std::ops::Range<usize>| value[range].bytes().all(|b| b.is_ascii_digit());
    if !(digits(0..4)
        && digits(5..7)
        && digits(8..10)
        && digits(11..13)
        && digits(14..16)
        && digits(17..19))
    {
        return false;
    }
    let mut rest = &value[19..];
    if let Some(fraction) = rest.strip_prefix('.') {
        let count = fraction.bytes().take_while(u8::is_ascii_digit).count();
        if count == 0 {
            return false;
        }
        rest = &fraction[count..];
    }
    let zone = rest == "Z"
        || (rest.len() == 6
            && (rest.starts_with('+') || rest.starts_with('-'))
            && rest.as_bytes()[3] == b':'
            && rest[1..3].bytes().all(|b| b.is_ascii_digit())
            && rest[4..6].bytes().all(|b| b.is_ascii_digit()));
    let number = |range: std::ops::Range<usize>| value[range].parse::<u32>().unwrap_or(99);
    zone && (1..=12).contains(&number(5..7))
        && (1..=31).contains(&number(8..10))
        && number(11..13) < 24
        && number(14..16) < 60
        && number(17..19) < 61
}

/// The marks, what was never derived, and the ring's held anchor.
type Reading = (Vec<Value>, Vec<String>, Option<bool>);

/// Swift `MarkerDocument.decode`, then `DiagnosticSessionReading.make` with no
/// screenshots: every mark, and what the capture never looked for.
fn markers(bytes: &[u8], job: &str) -> Result<Reading, CliError> {
    let malformed = || invalid("diagnostics_invalid_markers_document");
    let document: Value = serde_json::from_slice(bytes).map_err(|_| malformed())?;
    let marks = document["markers"].as_array().ok_or_else(malformed)?;
    let not_derived = document["notDerived"].as_array().ok_or_else(malformed)?;
    if document["documentType"] != "arkdeck-diagnostic-markers"
        || document["schemaVersion"] != "1.0.0"
        || document["jobId"] != job
        || marks.len() > 1024
        || !marks.iter().all(Value::is_object)
        || !not_derived.iter().all(|entry| {
            entry.is_object() && entry["kind"].is_string() && entry["reason"].is_string()
        })
    {
        return Err(malformed());
    }
    for mark in marks {
        match mark["kind"].as_str() {
            Some("manual") => {
                if !mark["atHostUTC"].as_str().is_some_and(instant) {
                    return Err(invalid("diagnostics_invalid_marker_timestamp"));
                }
            }
            Some("auto") => {
                if !mark["trigger"]
                    .as_str()
                    .is_some_and(|trigger| !trigger.is_empty())
                {
                    return Err(invalid("diagnostics_invalid_automatic_marker"));
                }
                if let Some(at) = mark.get("atHostUTC")
                    && !at.as_str().is_some_and(instant)
                {
                    return Err(invalid("diagnostics_invalid_marker_timestamp"));
                }
            }
            _ => return Err(invalid("diagnostics_unknown_marker_kind")),
        }
    }
    let reading = marks
        .iter()
        .enumerate()
        .map(|(index, mark)| {
            json!({"ordinal": index + 1,
                "kind": if mark["kind"] == "auto" { "automatic" } else { "manual" },
                "atHostUtc": mark["atHostUTC"].as_str().unwrap_or_default(),
                "label": mark["label"].as_str(), "trigger": mark["trigger"].as_str(),
                "screenshot": null,
                "screenshotAbsence": {"kind": "notCaptured", "milliseconds": null, "reason": null}})
        })
        .collect();
    let not_derived = not_derived
        .iter()
        .filter_map(|entry| entry["kind"].as_str().map(str::to_owned))
        .collect();
    // Foundation bridges a JSON boolean, and a number that is exactly 0 or 1,
    // to `Bool`.
    let anchor = match &document["coverage"]["ringHeldAnchor"] {
        Value::Bool(flag) => Some(*flag),
        Value::Number(number) if number.as_f64() == Some(1.0) => Some(true),
        Value::Number(number) if number.as_f64() == Some(0.0) => Some(false),
        _ => None,
    };
    Ok((reading, not_derived, anchor))
}

fn provenance(sources: &[&Metadata]) -> Value {
    let mut sources: Vec<&Metadata> = sources.to_vec();
    sources.sort_by(|left, right| (&left.name, &left.id).cmp(&(&right.name, &right.id)));
    json!({"kind": "offlineDerived", "parser": PARSER, "parserVersion": PARSER_VERSION,
        "sources": sources.iter().map(|metadata| metadata.value()).collect::<Vec<_>>()})
}

/// Swift `DiagnosticSessionOfflineInspector.inspect`, encoded as
/// `diagnosticsInspectionValue`.
fn inspect_session(
    job: &str,
    typed: &Map<String, Value>,
    inventory: &[Metadata],
    documents: &BTreeMap<&str, Document>,
) -> Result<Value, CliError> {
    let ids: BTreeSet<&str> = inventory.iter().map(|item| item.id.as_str()).collect();
    let names: BTreeSet<&str> = inventory.iter().map(|item| item.name.as_str()).collect();
    if job.is_empty() || job.len() > 512 {
        return Err(invalid("diagnostics_unsupported_operation"));
    }
    if ids.len() != inventory.len()
        || names.len() != inventory.len()
        || inventory.len() > INVENTORY_MAXIMUM
        || !inventory.iter().all(|item| item.source == OPERATION)
    {
        return Err(invalid("diagnostics_ambiguous_artifact_inventory"));
    }
    let document = |name: &str| -> Result<&Document, CliError> {
        documents
            .get(name)
            .filter(|document| {
                document.metadata.name == name
                    && document.metadata.media_type == "application/json"
                    && document.metadata.privacy == "standard"
                    && document.metadata.status == "published"
                    && !document.bytes.is_empty()
                    && document.bytes.len() as u64 <= DOCUMENT_MAXIMUM_BYTES
                    && inventory.contains(&document.metadata)
            })
            .ok_or_else(|| invalid(&format!("diagnostics_missing_or_unreadable_{name}")))
    };
    let index = decode_index(&document(INDEX)?.bytes)?;
    let summary = decode_index(&document(SUMMARY)?.bytes)?;
    let required_missing: BTreeSet<&str> = summary
        .artifacts
        .iter()
        .filter(|(_, product)| product.required && product.status != "published")
        .map(|(name, _)| name.as_str())
        .collect();
    let consistent = index.job_id == job
        && summary.job_id == job
        && index.operation == OPERATION
        && summary.operation == OPERATION
        && index.artifacts == summary.artifacts
        && summary.missing_required.as_ref().is_some_and(|missing| {
            let set: BTreeSet<&str> = missing.iter().map(String::as_str).collect();
            set.len() == missing.len()
                && set == required_missing
                && summary.completeness.as_deref()
                    == Some(if missing.is_empty() {
                        "complete"
                    } else {
                        "incomplete"
                    })
        });
    if !consistent {
        return Err(invalid("diagnostics_index_summary_mismatch"));
    }
    let missing_required = summary.missing_required.clone().unwrap_or_default();
    for (name, item) in &index.artifacts {
        if !["published", "missing", "truncated"].contains(&item.status.as_str()) {
            return Err(invalid("diagnostics_unknown_artifact_status"));
        }
        let published = inventory
            .iter()
            .find(|metadata| &metadata.name == name && metadata.status == "published");
        let matches = if item.status == "published" {
            published.is_some_and(|metadata| {
                item.artifact_id.as_deref() == Some(metadata.id.as_str())
                    && item.byte_count == i64::try_from(metadata.byte_count).ok()
                    && item.sha256 == metadata.sha256
            })
        } else {
            published.is_none()
        };
        if !matches {
            return Err(invalid("diagnostics_index_metadata_mismatch"));
        }
    }
    let is_published = |name: &str| {
        inventory
            .iter()
            .any(|metadata| metadata.name == name && metadata.status == "published")
    };
    let mut missing: Vec<Value> = Vec::new();
    let mut requested = requested_products(typed)?;
    if requested.contains("screenshot.png") && is_published("screenshot.jpeg") {
        requested.remove("screenshot.png");
        requested.insert("screenshot.jpeg".into());
    }
    requested.extend(missing_required.iter().cloned());
    for name in requested {
        if !is_published(&name) {
            let reason = index
                .artifacts
                .get(&name)
                .map(|item| item.detail.clone().unwrap_or_else(|| item.status.clone()))
                .unwrap_or_else(|| "not published".to_owned());
            missing.push(json!({"name": name, "reason": reason}));
        }
    }
    let (marks, not_derived, anchor) = if is_published(MARKERS) {
        markers(&document(MARKERS)?.bytes, job)?
    } else {
        missing.push(json!({"name": MARKERS, "reason": "marker document was not published"}));
        (Vec::new(), Vec::new(), None)
    };
    let sources: Vec<&Metadata> = documents
        .values()
        .map(|document| &document.metadata)
        .collect();
    let mut sorted: Vec<&Metadata> = inventory.iter().collect();
    sorted.sort_by(|left, right| (&left.name, &left.id).cmp(&(&right.name, &right.id)));
    Ok(
        json!({"schemaVersion": "arkdeck.diagnostics-inspection/1", "jobId": job,
        "operationReference": OPERATION, "derivation": provenance(&sources),
        "partial": !missing.is_empty(),
        "alignment": {"kind": "cannotAlign", "toleranceMs": null,
            "reason": "capture artifacts contain no host-to-device calibration"},
        "markers": marks, "missingProducts": missing, "notDerived": not_derived,
        "ringHeldAnchor": anchor,
        "artifacts": sorted.iter().map(|metadata| metadata.value()).collect::<Vec<_>>()}),
    )
}

/// Swift `DiagnosticArtifactTextPreview(bytes:mediaType:maximumCharacters:)`:
/// strict UTF-8 for JSON, lossy (and disclosed) for plain text, clipped to
/// `maximum` characters (grapheme clusters).
fn text_preview(bytes: &[u8], media_type: &str, maximum: i64) -> Option<(String, bool, bool)> {
    if bytes.len() as u64 > PREVIEW_MAXIMUM_BYTES
        || !(1..=PREVIEW_MAXIMUM_CHARACTERS).contains(&maximum)
        || !(media_type == "text/plain" || media_type == "application/json")
    {
        return None;
    }
    let strict = std::str::from_utf8(bytes).ok();
    if strict.is_none() && media_type != "text/plain" {
        return None;
    }
    let decoded = strict.map_or_else(
        || String::from_utf8_lossy(bytes).into_owned(),
        str::to_owned,
    );
    let maximum = maximum as usize;
    let characters: Vec<&str> = decoded.graphemes(true).collect();
    let clipped = characters.len() > maximum;
    let text: String = characters.into_iter().take(maximum).collect();
    Some((text, strict.is_none(), clipped))
}

/// `diagnostics inspect|preview`, given the leaf's options (`jobId`,
/// `artifactId`, `maxCharacters`, `allowSensitive`) and its session.
pub fn run(
    verb: &str,
    options: &Map<String, Value>,
    request: &mut Request,
) -> Result<Value, CliError> {
    let job = options
        .get("jobId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            fail(
                "invalidInput",
                format!("diagnostics {verb} requires --job <id>"),
            )
        })?;
    let owner = json!({"kind": "job", "id": job});
    if !crate::artifact_resources::owner(&owner) {
        return Err(fail("invalidInput", "Artifact owner identity is malformed"));
    }
    let inventory = inventory(&owner, job, request)?;
    match verb {
        "inspect" => {
            let typed = job_request(job, request)?;
            let mut documents = BTreeMap::new();
            for name in [INDEX, SUMMARY, MARKERS] {
                let Some(metadata) = inventory
                    .iter()
                    .find(|item| item.name == name && item.status == "published")
                else {
                    if name == MARKERS {
                        continue;
                    }
                    return Err(fail(
                        "resourceNotFound",
                        format!("diagnostic Job {job} did not publish {name}"),
                    ));
                };
                if metadata.media_type != "application/json"
                    || metadata.privacy != "standard"
                    || metadata.byte_count == 0
                    || metadata.byte_count > DOCUMENT_MAXIMUM_BYTES
                {
                    return Err(fail(
                        "recordUnreadable",
                        format!("diagnostic document {name} has unsafe metadata"),
                    ));
                }
                let bytes = read_whole(&owner, metadata, DOCUMENT_MAXIMUM_BYTES, false, request)?;
                documents.insert(name, bound(metadata, bytes)?);
            }
            inspect_session(job, &typed, &inventory, &documents)
        }
        "preview" => {
            let metadata = options
                .get("artifactId")
                .and_then(Value::as_str)
                .and_then(|id| inventory.iter().find(|item| item.id == id))
                .ok_or_else(|| {
                    fail(
                        "resourceNotFound",
                        format!("diagnostic Job {job} has no selected Artifact"),
                    )
                })?;
            let maximum = options
                .get("maxCharacters")
                .and_then(Value::as_str)
                .and_then(|text| text.parse::<i64>().ok())
                .unwrap_or(PREVIEW_MAXIMUM_CHARACTERS);
            let explicit = options.get("allowSensitive") == Some(&json!(true));
            if metadata.privacy == "sensitive" && !explicit {
                return Err(fail(
                    "sensitiveAccessDenied",
                    "sensitive diagnostics preview requires --allow-sensitive",
                ));
            }
            let bytes = read_whole(&owner, metadata, PREVIEW_MAXIMUM_BYTES, explicit, request)?;
            let document = bound(metadata, bytes)?;
            if document.metadata.source != OPERATION
                || !(document.metadata.media_type == "text/plain"
                    || document.metadata.media_type == "application/json")
            {
                return Err(invalid("diagnostics_artifact_is_not_previewable_text"));
            }
            if document.bytes.len() as u64 > PREVIEW_MAXIMUM_BYTES {
                return Err(inspector_error(
                    "inputTooLarge",
                    "diagnostics_artifact_exceeds_preview_limit",
                ));
            }
            let (text, replaced, clipped) =
                text_preview(&document.bytes, &document.metadata.media_type, maximum)
                    .ok_or_else(|| invalid("diagnostics_invalid_structured_text"))?;
            Ok(json!({"schemaVersion": "arkdeck.diagnostics-preview/1",
                "derivation": provenance(&[&document.metadata]), "text": text,
                "replacedInvalidUtf8": replaced, "clipped": clipped}))
        }
        _ => Err(fail("invalidCommand", "unsupported diagnostics subcommand")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_preview_clips_characters_and_discloses_replaced_bytes() {
        assert_eq!(
            text_preview("e\u{301}abc".as_bytes(), "text/plain", 2),
            Some(("e\u{301}a".to_owned(), false, true))
        );
        assert_eq!(
            text_preview(&[b'a', 0xFF], "text/plain", 10),
            Some(("a\u{FFFD}".to_owned(), true, false))
        );
        assert_eq!(text_preview(&[b'a', 0xFF], "application/json", 10), None);
        assert_eq!(text_preview(b"a", "text/plain", 0), None);
        assert_eq!(text_preview(b"a", "text/plain", 120_001), None);
    }

    #[test]
    fn an_instant_is_iso8601() {
        for good in [
            "2026-09-10T00:00:01Z",
            "2026-09-10T00:00:02.500Z",
            "2026-09-10T08:00:00+08:00",
        ] {
            assert!(instant(good), "{good}");
        }
        for bad in [
            "2026-09-10",
            "2026-09-10T00:00:01",
            "2026-13-10T00:00:01Z",
            "x",
        ] {
            assert!(!instant(bad), "{bad}");
        }
    }
}
