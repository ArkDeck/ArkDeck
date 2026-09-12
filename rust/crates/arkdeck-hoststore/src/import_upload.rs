//! Single owner of the existing Import upload lifetime. Begin/append/abort and
//! rediscovery never dispatch a device operation or mint a target binding.
use arkdeck_contract::{
    IMPORT_MAX_CHUNKS, IMPORT_MAX_RECORD_BYTES, IMPORT_MAX_RECORDS, IMPORT_STAGING_QUOTA,
    ImportIntent, ImportProjection, WireError, decode_import_chunk, import_decimal, import_digest,
    import_id, import_identifier, import_timestamp, sha256_hex, strict_json,
    validate_import_release,
};
use arkdeck_platform::{
    DocumentPublishError, HostDirectory, HostReadLock, HostUploadFile, UploadChunkCheckpoint,
    UploadWritePoint,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    io,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([
            ("phase".into(), json!("importOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}
fn unreadable(_: impl std::fmt::Display) -> WireError {
    failure(
        "recordUnreadable",
        "Import durable state or committed payload is unreadable",
    )
}
fn invalid() -> WireError {
    failure(
        "invalidInput",
        "Import requires exact typed metadata, identity and upload bounds",
    )
}
fn conflict() -> WireError {
    failure(
        "resourceConflict",
        "Import generation, committed offset or lifetime state changed",
    )
}
fn absent() -> WireError {
    failure("resourceNotFound", "Import does not exist")
}
fn publication(error: DocumentPublishError) -> WireError {
    // Preserve the Swift Import owner's existing recordUnreadable classification;
    // phase=importOwner never claims a failed checkpoint made no host changes.
    match error {
        DocumentPublishError::BeforePublication(error) => unreadable(error),
        DocumentPublishError::OutcomeUnknown(_) => failure(
            "recordUnreadable",
            "Import checkpoint may have changed; inspect the same request identity before continuing",
        ),
    }
}

/// Supplied by the composition root's actual Target owner after resolution.
/// Wire callers supply an ImportIntent, never these binding/provenance facts.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImportBinding {
    #[serde(rename = "targetID")]
    pub target_id: String,
    #[serde(rename = "bindingRevision", skip_serializing_if = "Option::is_none")]
    pub binding_revision: Option<u64>,
    #[serde(
        rename = "stableIdentitySHA256",
        skip_serializing_if = "Option::is_none"
    )]
    pub stable_identity_sha256: Option<String>,
}
impl ImportBinding {
    fn valid(&self, intent: &ImportIntent) -> bool {
        self.target_id == intent.target_id
            && self
                .binding_revision
                .is_none_or(|n| n > 0 && n <= i64::MAX as u64)
            && self
                .stable_identity_sha256
                .as_ref()
                .is_none_or(|s| import_digest(s))
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Chunk {
    offset: u64,
    #[serde(rename = "byteCount")]
    byte_count: u64,
    sha256: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    #[serde(rename = "schemaVersion")]
    schema_version: String,
    #[serde(rename = "importID")]
    id: String,
    intent: ImportIntent,
    #[serde(rename = "intentFingerprint")]
    fingerprint: String,
    binding: ImportBinding,
    #[serde(rename = "appOwned", skip_serializing_if = "Option::is_none")]
    app_owned: Option<bool>,
    #[serde(rename = "createdAtUTC")]
    created_at: String,
    #[serde(rename = "updatedAtUTC")]
    updated_at: String,
    generation: u64,
    state: String,
    #[serde(rename = "nextOffset")]
    next_offset: u64,
    chunks: Vec<Chunk>,
    #[serde(skip_serializing_if = "Option::is_none")]
    receipt: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    validation: Option<Map<String, Value>>,
    #[serde(rename = "releaseReceipt", skip_serializing_if = "Option::is_none")]
    release_receipt: Option<Value>,
}
struct Loaded {
    record: Record,
    bytes: Vec<u8>,
}
impl Record {
    fn name(&self) -> String {
        format!("{}.json", sha256_hex(self.intent.request_id.as_bytes()))
    }
    fn projection(&self) -> Value {
        json!({"schemaVersion":"arkdeck.import/1","importId":self.id,
        "importRequestId":self.intent.request_id,"metadata":self.intent.projection(),"metadataFingerprint":self.fingerprint,
        "generation":self.generation.to_string(),"state":self.state,"nextOffset":self.next_offset.to_string(),
        "maximumChunkBytes":"2097152","createdAtUtc":self.created_at,"updatedAtUtc":self.updated_at,"receipt":self.receipt})
    }
    fn validate(&self, name: &str) -> Result<(), WireError> {
        self.intent.validate().map_err(unreadable)?;
        let projection = ImportProjection::parse(&self.projection()).map_err(unreadable)?;
        if self.schema_version != "arkdeck.runtime-import/1"
            || name != self.name()
            || !self.binding.valid(&self.intent)
            || self.fingerprint != self.intent.fingerprint().map_err(unreadable)?
            || self.chunks.len() > IMPORT_MAX_CHUNKS
            || ["committing", "committed", "released"].contains(&self.state.as_str())
                != self.validation.is_some()
            || (self.state == "released") != self.release_receipt.is_some()
            || self
                .validation
                .as_ref()
                .is_some_and(|v| v.get("kind") != Some(&json!(self.intent.kind)))
        {
            return Err(unreadable("record"));
        }
        let mut offset = 0;
        for chunk in &self.chunks {
            if chunk.offset != offset
                || !(1..=2 * 1024 * 1024).contains(&chunk.byte_count)
                || chunk.byte_count > self.intent.byte_count - offset
                || !import_digest(&chunk.sha256)
            {
                return Err(unreadable("chunk"));
            }
            offset += chunk.byte_count;
        }
        if offset != self.next_offset
            || (["committing", "committed", "released"].contains(&self.state.as_str())
                && offset != self.intent.byte_count)
        {
            return Err(unreadable("checkpoint"));
        }
        if let Some(release) = &self.release_receipt {
            validate_import_release(release, &projection).map_err(unreadable)?;
        }
        Ok(())
    }
    fn checkpoints(&self) -> Vec<UploadChunkCheckpoint> {
        self.chunks
            .iter()
            .map(|c| UploadChunkCheckpoint {
                offset: c.offset,
                byte_count: c.byte_count,
                sha256: c.sha256.clone(),
            })
            .collect()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ImportUploadFault {
    AfterBeginCheckpoint,
    AfterPartialChunk,
    AfterChunkSync,
    AfterAppendCheckpoint,
    AfterAbortCheckpoint,
}
type Fault = Arc<dyn Fn(ImportUploadFault) -> io::Result<()> + Send + Sync>;

pub struct ImportUploadStore {
    artifact_root: HostDirectory,
    artifact_path: PathBuf,
    root: HostDirectory,
    records: HostDirectory,
    identities: HostDirectory,
    payloads: HostDirectory,
    lock: HostReadLock,
    // The synchronous Swift Artifact actor serialized upload lifetime changes.
    // The stable file lock additionally excludes another Rust process owner.
    verified: Mutex<BTreeMap<String, String>>,
    fault: Fault,
}
impl ImportUploadStore {
    pub fn open(artifact_path: &Path) -> io::Result<Self> {
        Self::open_with_fault(artifact_path, Arc::new(|_| Ok(())))
    }
    /// Bounded host fault injection for crash/restart tests, never a wire field.
    pub fn open_with_fault(artifact_path: &Path, fault: Fault) -> io::Result<Self> {
        let artifact_root = HostDirectory::open(artifact_path)?;
        let root = artifact_root.private_child(".imports-v1")?;
        let lock = root.lock_document(".owner.lock")?;
        let records = root.private_child("records")?;
        let identities = root.private_child("identities")?;
        let payloads = root.private_child("payloads")?;
        let value = Self {
            artifact_root,
            artifact_path: artifact_path.into(),
            root,
            records,
            identities,
            payloads,
            lock,
            verified: Mutex::new(BTreeMap::new()),
            fault,
        };
        value.validate().map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "Import owner identity is unreadable",
            )
        })?;
        Ok(value)
    }
    fn validate(&self) -> Result<(), WireError> {
        self.artifact_root
            .validate_path(&self.artifact_path)
            .map_err(unreadable)?;
        let root = self.artifact_path.join(".imports-v1");
        self.root.validate_path(&root).map_err(unreadable)?;
        self.lock
            .validate_link(&self.root, ".owner.lock")
            .map_err(unreadable)?;
        self.records
            .validate_path(&root.join("records"))
            .map_err(unreadable)?;
        self.identities
            .validate_path(&root.join("identities"))
            .map_err(unreadable)?;
        self.payloads
            .validate_path(&root.join("payloads"))
            .map_err(unreadable)?;
        Ok(())
    }
    fn load(&self, name: &str) -> Result<Loaded, WireError> {
        let bytes = self
            .records
            .read(name, IMPORT_MAX_RECORD_BYTES)
            .map_err(unreadable)?;
        let value = strict_json(&bytes).map_err(unreadable)?;
        let record: Record = serde_json::from_value(value.clone()).map_err(unreadable)?;
        // The Swift owner emits omitted optional fields, never synthetic nulls.
        if serde_json::to_value(&record).map_err(unreadable)? != value {
            return Err(unreadable("shape"));
        }
        record.validate(name)?;
        self.validate()?;
        Ok(Loaded { record, bytes })
    }
    fn save(&self, record: &Record, prior: Option<&[u8]>) -> Result<Vec<u8>, WireError> {
        self.validate()?;
        record.validate(&record.name())?;
        let bytes = serde_json::to_vec(record).map_err(unreadable)?;
        if bytes.len() > IMPORT_MAX_RECORD_BYTES {
            return Err(failure(
                "inputTooLarge",
                "Import checkpoint exceeds its metadata bound",
            ));
        }
        // Foundation .sortedKeys and serde_json's object ordering share these
        // ASCII keys; encode through Value so struct declaration order is irrelevant.
        let value = serde_json::to_value(record).map_err(unreadable)?;
        let bytes = serde_json::to_vec(&value).map_err(unreadable)?;
        self.records
            .publish_import_checkpoint(&record.name(), prior, &bytes, IMPORT_MAX_RECORD_BYTES)
            .map_err(publication)?;
        self.validate()?;
        Ok(bytes)
    }
    fn index(&self, record: &Record) -> Result<(), WireError> {
        let name = format!("{}.json", record.id);
        let expected = serde_json::to_vec(&json!({"importRequestId":record.intent.request_id}))
            .map_err(unreadable)?;
        match self.identities.read(&name, 1024) {
            Ok(bytes) if bytes == expected => Ok(()),
            Ok(_) => Err(unreadable("identity")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                self.validate()?;
                self.identities
                    .publish_import_checkpoint(&name, None, &expected, 1024)
                    .map_err(publication)?;
                self.validate()
            }
            Err(error) => Err(unreadable(error)),
        }
    }
    fn visit(
        &self,
        mut body: impl FnMut(Loaded) -> Result<(), WireError>,
    ) -> Result<(), WireError> {
        self.validate()?;
        let names = self
            .records
            .names(IMPORT_MAX_RECORDS * 4)
            .map_err(unreadable)?;
        let mut count = 0;
        let mut ids = BTreeSet::new();
        for name in names {
            if name.starts_with('.') && name.ends_with(".tmp") {
                let metadata = self.records.document_metadata(&name).map_err(unreadable)?;
                self.records
                    .remove_document(&name, &metadata)
                    .map_err(unreadable)?;
                continue;
            }
            if count == IMPORT_MAX_RECORDS {
                return Err(unreadable("record bound"));
            }
            let loaded = self.load(&name)?;
            if !ids.insert(loaded.record.id.clone()) {
                return Err(unreadable("duplicate owner"));
            }
            count += 1;
            body(loaded)?;
        }
        self.validate()
    }
    fn remove_staging(&self, record: &Record) -> Result<(), WireError> {
        self.validate()?;
        let name = format!("{}.stage", record.id);
        match self.payloads.document_metadata(&name) {
            Ok(expected) => self
                .payloads
                .remove_document(&name, &expected)
                .map_err(unreadable)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(unreadable(error)),
        }
        self.validate()
    }
    fn cache_key(&self, record: &Record, file: &HostUploadFile) -> Result<String, WireError> {
        let chunks = serde_json::to_value(&record.chunks).map_err(unreadable)?;
        let bytes = serde_json::to_vec(&chunks).map_err(unreadable)?;
        Ok(format!(
            "{}:{}",
            file.checkpoint_identity().map_err(unreadable)?,
            sha256_hex(&bytes)
        ))
    }
    fn recover(
        &self,
        record: &Record,
        cache: &mut BTreeMap<String, String>,
    ) -> Result<(), WireError> {
        // Released lifetimes can require an Artifact unpin. That coordination
        // is intentionally unavailable until the publication/release owner joins.
        if record.state == "released" {
            return Err(failure(
                "operationUnavailable",
                "Import release reconciliation owner is not configured",
            ));
        }
        if ["committed", "aborted"].contains(&record.state.as_str()) {
            self.remove_staging(record)?;
            cache.remove(&record.id);
            return Ok(());
        }
        self.validate()?;
        let mut file = HostUploadFile::open(
            &self.payloads,
            &format!("{}.stage", record.id),
            record.next_offset == 0,
        )
        .map_err(unreadable)?;
        let key = self.cache_key(record, &file)?;
        if cache.get(&record.id) != Some(&key)
            || file.byte_count().map_err(unreadable)? != record.next_offset
        {
            file.recover(&record.checkpoints(), record.next_offset)
                .map_err(unreadable)?;
            cache.insert(record.id.clone(), self.cache_key(record, &file)?);
        }
        self.validate()
    }
    fn by_request(
        &self,
        request: &str,
        cache: &mut BTreeMap<String, String>,
    ) -> Result<Option<Loaded>, WireError> {
        if !import_identifier(request) {
            return Err(invalid());
        }
        self.validate()?;
        let name = format!("{}.json", sha256_hex(request.as_bytes()));
        match self.records.document_metadata(&name) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(unreadable(error)),
            Ok(_) => {}
        }
        let loaded = self.load(&name)?;
        self.index(&loaded.record)?;
        self.recover(&loaded.record, cache)?;
        Ok(Some(loaded))
    }
    fn by_id(&self, id: &str, cache: &mut BTreeMap<String, String>) -> Result<Loaded, WireError> {
        if !import_id(id) {
            return Err(invalid());
        }
        self.validate()?;
        match self.identities.read(&format!("{id}.json"), 1024) {
            Ok(bytes) => {
                let fields = strict_json(&bytes).map_err(unreadable)?;
                let map = fields.as_object().ok_or_else(|| unreadable("identity"))?;
                if map.len() != 1 {
                    return Err(unreadable("identity"));
                }
                let request = map
                    .get("importRequestId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| unreadable("identity"))?;
                if !import_identifier(request) {
                    return Err(unreadable("identity"));
                }
                let loaded = self.load(&format!("{}.json", sha256_hex(request.as_bytes())))?;
                if loaded.record.id != id {
                    return Err(unreadable("identity"));
                }
                self.index(&loaded.record)?;
                self.recover(&loaded.record, cache)?;
                Ok(loaded)
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let mut found = None;
                self.visit(|loaded| {
                    if loaded.record.id == id {
                        found = Some(loaded);
                    }
                    Ok(())
                })?;
                let loaded = found.ok_or_else(absent)?;
                self.index(&loaded.record)?;
                self.recover(&loaded.record, cache)?;
                Ok(loaded)
            }
            Err(error) => Err(unreadable(error)),
        }
    }
    fn begin(
        &self,
        intent: ImportIntent,
        app_owned: bool,
        now: &str,
        cache: &mut BTreeMap<String, String>,
        resolve: impl FnOnce(&ImportIntent) -> Result<ImportBinding, WireError>,
    ) -> Result<Value, WireError> {
        if let Some(loaded) = self.by_request(&intent.request_id, cache)? {
            if app_owned && loaded.record.app_owned != Some(true) {
                return Err(failure(
                    "admissionDenied",
                    "Import was not created by the App transport",
                ));
            }
            if loaded.record.intent != intent {
                return Err(failure(
                    "idempotencyConflict",
                    "Import request identity already names different metadata",
                ));
            }
            return Ok(loaded.record.projection());
        }
        let binding = resolve(&intent).map_err(|error| match error.code.as_str() {
            "operationUnavailable" => failure(
                "operationUnavailable",
                "Import requires the configured Target binding owner",
            ),
            "resourceConflict" | "resourceNotFound" => failure(
                "resourceConflict",
                "Import target binding is no longer current",
            ),
            _ => unreadable("binding"),
        })?;
        if !binding.valid(&intent) {
            return Err(unreadable("binding"));
        }
        // Keep the frozen optional-field decoder for existing snapshots, but
        // never publish a new lifetime without an exact owner-resolved binding.
        let complete = if intent.kind == "workspace-patch" {
            binding.binding_revision.is_none() && binding.stable_identity_sha256.is_none()
        } else {
            binding.binding_revision == Some(intent.binding_revision)
                && binding.stable_identity_sha256.is_some()
        };
        if !complete {
            return Err(failure(
                "resourceConflict",
                "Import requires the exact current Target binding and stable identity",
            ));
        }
        let mut count = 0;
        let mut staged = 0u64;
        self.visit(|item| {
            count += 1;
            if ["inProgress", "committing"].contains(&item.record.state.as_str()) {
                staged = staged
                    .checked_add(item.record.intent.byte_count)
                    .ok_or_else(|| unreadable("quota"))?;
            }
            Ok(())
        })?;
        if count >= IMPORT_MAX_RECORDS || staged > IMPORT_STAGING_QUOTA - intent.byte_count {
            return Err(failure(
                "quotaExceeded",
                "Import staging capacity is exhausted",
            ));
        }
        let bytes = arkdeck_platform::random_bytes::<16>().map_err(unreadable)?;
        let mut uuid = bytes;
        uuid[6] = (uuid[6] & 0x0f) | 0x40;
        uuid[8] = (uuid[8] & 0x3f) | 0x80;
        let hex: String = uuid.iter().map(|b| format!("{b:02x}")).collect();
        let id = format!(
            "imp-{}-{}-{}-{}-{}",
            &hex[..8],
            &hex[8..12],
            &hex[12..16],
            &hex[16..20],
            &hex[20..]
        );
        let record = Record {
            schema_version: "arkdeck.runtime-import/1".into(),
            id,
            fingerprint: intent.fingerprint().map_err(unreadable)?,
            intent,
            binding,
            app_owned: Some(app_owned),
            created_at: now.into(),
            updated_at: now.into(),
            generation: 1,
            state: "inProgress".into(),
            next_offset: 0,
            chunks: Vec::new(),
            receipt: None,
            validation: None,
            release_receipt: None,
        };
        self.save(&record, None)?;
        (self.fault)(ImportUploadFault::AfterBeginCheckpoint).map_err(unreadable)?;
        self.index(&record)?;
        self.recover(&record, cache)?;
        Ok(record.projection())
    }
    fn append(
        &self,
        fields: &Map<String, Value>,
        now: &str,
        cache: &mut BTreeMap<String, String>,
        app_owned: bool,
    ) -> Result<Value, WireError> {
        let id = fields["importId"].as_str().ok_or_else(invalid)?;
        let generation = import_decimal(&fields["generation"])
            .filter(|n| *n > 0)
            .ok_or_else(invalid)?;
        let offset = import_decimal(&fields["offset"]).ok_or_else(invalid)?;
        let count = import_decimal(&fields["byteCount"]).ok_or_else(invalid)?;
        let digest = fields["sha256"]
            .as_str()
            .filter(|s| import_digest(s))
            .ok_or_else(invalid)?;
        let encoded = fields["base64"].as_str().ok_or_else(invalid)?;
        let bytes = decode_import_chunk(encoded, count).map_err(|_| invalid())?;
        let loaded = self.by_id(id, cache)?;
        let mut record = loaded.record;
        if app_owned
            && (record.app_owned != Some(true)
                || !["hap", "native-library", "flash-bundle"]
                    .contains(&record.intent.kind.as_str()))
        {
            return Err(failure(
                "admissionDenied",
                "Import is outside this App upload scope",
            ));
        }
        if generation != record.generation || record.state != "inProgress" {
            return Err(conflict());
        }
        if sha256_hex(&bytes) != digest {
            return Err(failure(
                "artifactIntegrityFailed",
                "Import chunk digest does not match its bytes",
            ));
        }
        if offset < record.next_offset {
            if record
                .chunks
                .iter()
                .any(|c| c.offset == offset && c.byte_count == count && c.sha256 == digest)
            {
                return Ok(record.projection());
            }
            return Err(conflict());
        }
        if offset != record.next_offset || count > record.intent.byte_count - offset {
            return Err(conflict());
        }
        if record.chunks.len() >= IMPORT_MAX_CHUNKS {
            return Err(failure(
                "quotaExceeded",
                "Import upload exceeds its chunk metadata quota",
            ));
        }
        self.validate()?;
        let mut file = HostUploadFile::open(
            &self.payloads,
            &format!("{}.stage", record.id),
            record.next_offset == 0,
        )
        .map_err(unreadable)?;
        if cache.get(id) != Some(&self.cache_key(&record, &file)?) {
            file.recover(&record.checkpoints(), record.next_offset)
                .map_err(unreadable)?;
        }
        let fault = &self.fault;
        file.append_with_checkpoint(offset, &bytes, digest, |point| {
            fault(match point {
                UploadWritePoint::AfterPartialChunk => ImportUploadFault::AfterPartialChunk,
                UploadWritePoint::AfterChunkSync => ImportUploadFault::AfterChunkSync,
            })
        })
        .map_err(unreadable)?;
        record.chunks.push(Chunk {
            offset,
            byte_count: count,
            sha256: digest.into(),
        });
        record.next_offset += count;
        record.updated_at = now.into();
        let key = self.cache_key(&record, &file)?;
        self.save(&record, Some(&loaded.bytes))?;
        (self.fault)(ImportUploadFault::AfterAppendCheckpoint).map_err(unreadable)?;
        cache.insert(id.into(), key);
        Ok(record.projection())
    }
    fn abort(
        &self,
        request: &str,
        generation: u64,
        now: &str,
        cache: &mut BTreeMap<String, String>,
        app_owned: bool,
    ) -> Result<Value, WireError> {
        let loaded = self.by_request(request, cache)?.ok_or_else(absent)?;
        let mut record = loaded.record;
        if app_owned
            && (record.app_owned != Some(true)
                || !["hap", "native-library", "flash-bundle"]
                    .contains(&record.intent.kind.as_str()))
        {
            return Err(failure(
                "admissionDenied",
                "Import is outside this App upload scope",
            ));
        }
        if record.state == "aborted" && generation == record.generation - 1 {
            self.remove_staging(&record)?;
            return Ok(record.projection());
        }
        if record.state != "inProgress"
            || record.generation != generation
            || generation == i64::MAX as u64
        {
            return Err(conflict());
        }
        record.state = "aborted".into();
        record.generation += 1;
        record.updated_at = now.into();
        self.save(&record, Some(&loaded.bytes))?;
        (self.fault)(ImportUploadFault::AfterAbortCheckpoint).map_err(unreadable)?;
        cache.remove(&record.id);
        self.remove_staging(&record)?;
        Ok(record.projection())
    }
    pub fn handle_resource(
        &self,
        method: &str,
        fields: &Map<String, Value>,
        now: &str,
        app_owned: bool,
        resolve_binding: impl FnOnce(&ImportIntent) -> Result<ImportBinding, WireError>,
    ) -> Result<Value, WireError> {
        let exact = |keys: &[&str]| {
            fields.len() == keys.len() && keys.iter().all(|key| fields.contains_key(*key))
        };
        match method {
            "artifact.import.begin" => {
                ImportIntent::from_wire(fields).map_err(|_| invalid())?;
            }
            "artifact.import.append"
                if exact(&[
                    "importId",
                    "generation",
                    "offset",
                    "byteCount",
                    "sha256",
                    "base64",
                ]) => {}
            "artifact.import.abort" if exact(&["importRequestId", "generation"]) => {}
            "artifact.import.inspect" if exact(&["importId"]) || exact(&["importRequestId"]) => {}
            "artifact.import.append" | "artifact.import.abort" | "artifact.import.inspect" => {
                return Err(invalid());
            }
            _ => {
                return Err(failure(
                    "operationUnavailable",
                    "Import commit, release and Job-reference owners are not configured",
                ));
            }
        }
        if app_owned
            && (method == "artifact.import.inspect"
                || (method == "artifact.import.begin"
                    && !matches!(
                        fields["kind"].as_str(),
                        Some("hap" | "native-library" | "flash-bundle")
                    )))
        {
            return Err(failure(
                "admissionDenied",
                "Import is outside this App upload scope",
            ));
        }
        if method != "artifact.import.inspect" && import_timestamp(now).is_none() {
            return Err(failure(
                "operationUnavailable",
                "Runtime Import clock is unavailable",
            ));
        }
        let mut cache = self
            .verified
            .lock()
            .map_err(|_| failure("operationUnavailable", "Import upload owner is unavailable"))?;
        self.validate()?;
        let result = match method {
            "artifact.import.begin" => self.begin(
                ImportIntent::from_wire(fields).map_err(|_| invalid())?,
                app_owned,
                now,
                &mut cache,
                resolve_binding,
            ),
            "artifact.import.append" => self.append(fields, now, &mut cache, app_owned),
            "artifact.import.abort" => self.abort(
                fields["importRequestId"].as_str().ok_or_else(invalid)?,
                import_decimal(&fields["generation"])
                    .filter(|n| *n > 0)
                    .ok_or_else(invalid)?,
                now,
                &mut cache,
                app_owned,
            ),
            "artifact.import.inspect" => {
                let loaded = if let Some(id) = fields.get("importId") {
                    self.by_id(id.as_str().ok_or_else(invalid)?, &mut cache)?
                } else {
                    self.by_request(
                        fields["importRequestId"].as_str().ok_or_else(invalid)?,
                        &mut cache,
                    )?
                    .ok_or_else(absent)?
                };
                Ok(loaded.record.projection())
            }
            _ => unreachable!(),
        }?;
        self.validate()?;
        ImportProjection::parse(&result).map_err(unreadable)?;
        Ok(result)
    }
}
