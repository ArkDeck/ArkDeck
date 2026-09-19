//! Swift `RuntimeArtifactStore.publish` and `recordMissing` for a Job step's
//! declared product, over the Artifact root the read owner opened: the
//! default redaction, the content-derived identity, a quota that refuses a new
//! product and never evicts an old one, the payload written and sealed owner
//! read-only before the index names it, and the index rewritten whole in
//! Swift's pretty spelling. Publication takes the lock of the read owner's
//! Trace retention guard, never its census. A refusal is the
//! `RuntimeArtifactError` Swift throws, spelled as Swift interpolates it,
//! because the Job timeline and a missing product's reason carry that
//! spelling.
//!
//! Unlike Swift, whose census is cached per process, every publication
//! recounts the published bytes of every Job index; other Jobs' payloads are
//! not rehashed for that count.
use crate::artifact_read_owner::{ArtifactPublicationFault, ArtifactReadStore, swift_string};
use crate::artifact_usage::decode_index;
use arkdeck_contract::sha256_hex;
use arkdeck_platform::{DocumentPublishError, HostDirectory, HostEntryKind, PayloadCheck};
use serde_json::{Value, json};
use std::io;

#[path = "artifact_retention.rs"]
mod retention;
pub(crate) use retention::RetentionKeep;
pub use retention::collect_expired_artifacts;

const MAX_INDEX: usize = 16 * 1024 * 1024;
const MAX_PAYLOAD: usize = 512 * 1024 * 1024;
const DEFAULT_LIFETIME: u64 = 7 * 24 * 60 * 60;
const SHORT_LIFETIME: u64 = 24 * 60 * 60;
const IMPORT_NAMESPACE: &str = ".imports-v1";
const CLEANUP_DEBT: &str = "cleanup-debt.json";

/// One declared product of a Job step.
pub(crate) struct Product<'a> {
    pub job_id: &'a str,
    pub session_id: &'a str,
    pub step_id: &'a str,
    pub name: &'a str,
    pub media_type: &'a str,
    pub privacy: &'a str,
    pub retention_class: &'a str,
    pub source_operation: &'a str,
    pub provider_id: &'a str,
    /// `ArtifactBindingSnapshot`, absent members omitted as Swift encodes it.
    pub binding: Value,
    pub observation_window: Option<(String, String)>,
}

pub(crate) struct ArtifactPublisher<'a> {
    pub store: &'a ArtifactReadStore,
    pub quota: u64,
    /// Swift `NSHomeDirectory()`, which redaction replaces.
    pub home: &'a str,
    pub now: fn() -> Option<String>,
}

fn artifact_error(case: &str, detail: &str) -> String {
    format!("{case}({})", swift_string(detail))
}
fn corrupted(detail: &str) -> String {
    artifact_error("indexCorrupted", detail)
}
fn io_failure(detail: &str) -> String {
    artifact_error("ioFailure", detail)
}

impl ArtifactPublisher<'_> {
    /// Swift `publish`: the stored metadata, or Swift's refusal.
    pub(crate) fn publish(&self, product: &Product<'_>, contents: &[u8]) -> Result<Value, String> {
        self.store
            .with_retention_lock(|| self.publish_guarded(product, contents))
            .map_err(|error| io_failure(&format!("cannot inspect artifact retention: {error}")))?
    }

    /// Swift `recordMissing`: the declared product stays in the index with
    /// the reason it could not be published.
    pub(crate) fn record_missing(
        &self,
        product: &Product<'_>,
        reason: &str,
    ) -> Result<Value, String> {
        self.store
            .with_retention_lock(|| {
                let identity =
                    sha256_hex(format!("{}\0{}\0missing", product.job_id, product.name).as_bytes());
                let created = self.clock()?;
                let mut metadata = self.metadata(
                    product,
                    &format!("ART-MISSING-{}", &identity[..32]),
                    0,
                    "",
                    &created,
                    json!({"missing": {"reason": reason}}),
                    false,
                )?;
                metadata
                    .as_object_mut()
                    .expect("metadata is an object")
                    .remove("observationWindow");
                let job = self.job_directory(product.job_id)?;
                self.upsert(&job, product.job_id, metadata.clone())?;
                Ok(metadata)
            })
            .map_err(|error| io_failure(&format!("cannot inspect artifact retention: {error}")))?
    }

    /// Swift `preflightAdditionalBytes`: whether the store still has room for
    /// this many more published bytes, before anything is collected.
    pub(crate) fn preflight_additional_bytes(&self, requested: i64) -> Result<(), String> {
        let Ok(requested) = u64::try_from(requested) else {
            return Err(io_failure(
                "artifact preflight byte count must be nonnegative",
            ));
        };
        let used = self.used_bytes()?;
        if requested > self.quota - used.min(self.quota) {
            return Err(format!(
                "quotaExceeded(requestedBytes: {requested}, remainingBytes: {})",
                self.quota.saturating_sub(used)
            ));
        }
        Ok(())
    }

    /// Swift `list(jobID:)`: the Job's index rows in file order, every
    /// published payload checked; an absent index is empty.
    pub(crate) fn list(&self, job_id: &str) -> Result<Vec<Value>, String> {
        let job = self.job_directory(job_id)?;
        self.load_index(&job, job_id)
    }

    /// The bytes a Job's published products already hold, which a capture's
    /// job byte budget bounds.
    pub(crate) fn published_bytes(&self, job_id: &str) -> Result<u64, String> {
        Ok(self
            .list(job_id)?
            .iter()
            .filter(|row| published(row))
            .map(|row| row["byteCount"].as_u64().unwrap_or(0))
            .sum())
    }

    fn publish_guarded(&self, product: &Product<'_>, contents: &[u8]) -> Result<Value, String> {
        let (payload, redacted) = redact(contents, product.media_type, self.home);
        let digest = sha256_hex(&payload);
        let identity =
            sha256_hex(format!("{}\0{}\0{digest}", product.job_id, product.name).as_bytes());
        let artifact_id = format!("ART-{}", &identity[..32]);
        let created = self.clock()?;
        let metadata = self.metadata(
            product,
            &artifact_id,
            payload.len() as u64,
            &digest,
            &created,
            json!({"published": {}}),
            redacted,
        )?;
        let job = self.job_directory(product.job_id)?;
        let index = self.load_index(&job, product.job_id)?;
        if let Some(existing) = index.iter().find(|row| row["name"] == product.name)
            && published(existing)
        {
            if existing["artifactID"] == artifact_id.as_str()
                && same_immutable_publication(existing, &metadata)
            {
                return Ok(existing.clone());
            }
            return Err(artifact_error(
                "artifactConflict",
                &format!(
                    "artifact name {} is already bound to immutable metadata or bytes",
                    product.name
                ),
            ));
        }
        // Recover only an exact payload left between the payload write and
        // the index write; anything else at the derived name is poison. A
        // publication stopped before its seal left the payload owner-writable:
        // as Swift's `validateStoredPayload` does after its full hash, it is
        // sealed before any index names it.
        let exists = match job.document_metadata(&artifact_id) {
            Ok(_) => {
                self.validate_payload(&job, &artifact_id, payload.len() as u64, &digest)?;
                job.seal_document(&artifact_id)
                    .map_err(|error| io_failure(&format!("cannot seal artifact bytes: {error}")))?;
                true
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => false,
            Err(_) => {
                return Err(corrupted(
                    "artifact payload is missing, linked or unreadable (errno 0)",
                ));
            }
        };
        let additional = if exists { 0 } else { payload.len() as u64 };
        let used = self.used_bytes()?;
        if used.saturating_add(additional) > self.quota {
            return Err(format!(
                "quotaExceeded(requestedBytes: {additional}, remainingBytes: {})",
                self.quota.saturating_sub(used)
            ));
        }
        let fault = |point| {
            self.store
                .publication_fault(point)
                .map_err(|error| io_failure(&error.to_string()))
        };
        if !exists {
            job.publish_document(&artifact_id, &payload, MAX_PAYLOAD)
                .map_err(|error| {
                    let error = match error {
                        DocumentPublishError::BeforePublication(error)
                        | DocumentPublishError::OutcomeUnknown(error) => error,
                    };
                    io_failure(&format!("cannot persist artifact bytes: {error}"))
                })?;
            fault(ArtifactPublicationFault::AfterPayload)?;
            self.validate_payload(&job, &artifact_id, payload.len() as u64, &digest)?;
            job.seal_document(&artifact_id)
                .map_err(|error| io_failure(&format!("cannot seal artifact bytes: {error}")))?;
        }
        fault(ArtifactPublicationFault::AfterSeal)?;
        self.upsert(&job, product.job_id, metadata.clone())?;
        fault(ArtifactPublicationFault::AfterIndex)?;
        Ok(metadata)
    }

    /// Import bytes are already attested by their registered format validator.
    /// No redaction or caller-provided publication descriptor is involved.
    pub(crate) fn publish_import(
        &self,
        product: &Product<'_>,
        source: &arkdeck_platform::HostUploadFile,
        expected: u64,
        digest: &str,
        created: &str,
        after_payload: impl FnOnce() -> Result<(), String>,
    ) -> Result<Value, String> {
        self.store
            .with_retention_lock(|| {
                let identity = sha256_hex(
                    format!("{}\0{}\0{digest}", product.job_id, product.name).as_bytes(),
                );
                let artifact = format!("ART-{}", &identity[..32]);
                let metadata = self.metadata(
                    product,
                    &artifact,
                    expected,
                    digest,
                    created,
                    json!({"published": {}}),
                    false,
                )?;
                let directory = self.job_directory(product.job_id)?;
                if let Some(existing) = self
                    .load_index(&directory, product.job_id)?
                    .iter()
                    .find(|row| row["name"] == product.name && published(row))
                {
                    if existing["artifactID"] != artifact
                        || !same_immutable_publication(existing, &metadata)
                    {
                        return Err(artifact_error(
                            "artifactConflict",
                            "Import name already has different immutable content",
                        ));
                    }
                    return Ok(existing.clone());
                }
                let exists = match directory.document_metadata(&artifact) {
                    Ok(_) => {
                        self.validate_payload(&directory, &artifact, expected, digest)?;
                        true
                    }
                    Err(error) if error.kind() == io::ErrorKind::NotFound => false,
                    Err(error) => return Err(io_failure(&error.to_string())),
                };
                let used = self.used_bytes()?;
                if used.saturating_add(expected) > self.quota {
                    return Err(format!(
                        "quotaExceeded(requestedBytes: {expected}, remainingBytes: {})",
                        self.quota.saturating_sub(used)
                    ));
                }
                if !exists {
                    source
                        .publish_immutable(&directory, &artifact, expected, digest)
                        .map_err(|e| io_failure(&e.to_string()))?;
                }
                after_payload()?;
                self.upsert(&directory, product.job_id, metadata.clone())?;
                Ok(metadata)
            })
            .map_err(|e| io_failure(&e.to_string()))?
    }

    fn clock(&self) -> Result<String, String> {
        (self.now)().ok_or_else(|| io_failure("the Runtime clock is unavailable"))
    }

    #[allow(clippy::too_many_arguments)]
    fn metadata(
        &self,
        product: &Product<'_>,
        artifact_id: &str,
        byte_count: u64,
        digest: &str,
        created: &str,
        status: Value,
        redacted: bool,
    ) -> Result<Value, String> {
        let mut metadata = json!({
            "artifactID": artifact_id,
            "jobID": product.job_id,
            "sessionID": product.session_id,
            "stepID": product.step_id,
            "name": product.name,
            "mediaType": product.media_type,
            "byteCount": byte_count,
            "sha256": digest,
            "createdAtUTC": created,
            "providerID": product.provider_id,
            "sourceOperation": product.source_operation,
            "bindingSnapshot": product.binding,
            "privacy": product.privacy,
            "retention": retention(product.retention_class, created)?,
            "status": status,
            "redactionApplied": redacted,
        });
        if let Some((start, end)) = &product.observation_window {
            metadata["observationWindow"] = json!({"startUTC": start, "endUTC": end});
        }
        Ok(metadata)
    }

    /// Swift `directory(for:)`: the Job's private Artifact directory.
    fn job_directory(&self, job_id: &str) -> Result<HostDirectory, String> {
        self.store
            .job_directory(job_id)
            .map_err(|error| io_failure(&format!("cannot create artifact directory: {error}")))
    }

    /// Called with Import lifetime ownership. The release receipt is already
    /// durable; only its original bounded retention may replace the pin.
    pub(crate) fn finish_import_unpin(
        &self,
        id: &str,
        expected: &Value,
        retention: &Value,
    ) -> Result<(), String> {
        self.store
            .with_retention_lock(|| {
                let directory = match self.store.root().child(id) {
                    Ok(directory) => directory,
                    Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
                    Err(error) => return Err(io_failure(&error.to_string())),
                };
                let rows = self.load_index(&directory, id)?;
                let Some(mut row) = rows
                    .into_iter()
                    .find(|row| row["artifactID"] == expected["artifactID"])
                else {
                    return Ok(());
                };
                if !published(&row) {
                    return Err(corrupted("released Import publication status drifted"));
                }
                for key in [
                    "jobID",
                    "artifactID",
                    "name",
                    "sessionID",
                    "stepID",
                    "sourceOperation",
                    "providerID",
                    "sha256",
                    "byteCount",
                    "bindingSnapshot",
                    "privacy",
                    "mediaType",
                    "redactionApplied",
                ] {
                    if row[key] != expected[key] {
                        return Err(corrupted("released Import identity drifted"));
                    }
                }
                if row["retention"] == *retention {
                    return Ok(());
                }
                if row["retention"]
                    != json!({"retentionClass":"pinnedUntilVerified", "pinned":true})
                {
                    return Err(corrupted("released Import retention drifted"));
                }
                row["retention"] = retention.clone();
                self.upsert(&directory, id, row)
            })
            .map_err(|error| io_failure(&error.to_string()))?
    }

    /// Swift `loadIndex`: an absent index is empty; every row belongs to this
    /// Job under a unique identity and name; every published payload holds
    /// exactly its bytes.
    fn load_index(&self, job: &HostDirectory, job_id: &str) -> Result<Vec<Value>, String> {
        let bytes = match job.read("index.json", MAX_INDEX) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(_) => return Err(corrupted("artifact index cannot be opened")),
        };
        let rows = decode_index(&bytes, job_id).map_err(|_| {
            corrupted("artifact index contains a foreign, unsafe or duplicate identity")
        })?;
        for row in rows.iter().filter(|row| published(row)) {
            let (Some(id), Some(length), Some(digest)) = (
                row["artifactID"].as_str(),
                row["byteCount"].as_u64(),
                row["sha256"].as_str(),
            ) else {
                return Err(corrupted("artifact payload type or size drifted"));
            };
            self.validate_payload(job, id, length, digest)?;
        }
        Ok(rows)
    }

    fn validate_payload(
        &self,
        job: &HostDirectory,
        artifact_id: &str,
        length: u64,
        digest: &str,
    ) -> Result<(), String> {
        match job.check_payload(artifact_id, length, digest) {
            Ok(PayloadCheck::Verified) => Ok(()),
            Ok(PayloadCheck::Unopenable(errno)) => Err(corrupted(&format!(
                "artifact payload is missing, linked or unreadable (errno {errno})"
            ))),
            Ok(PayloadCheck::TypeOrSize) => Err(corrupted("artifact payload type or size drifted")),
            Ok(PayloadCheck::DigestOrIdentity) | Err(_) => {
                Err(corrupted("artifact payload digest or identity drifted"))
            }
        }
    }

    /// Swift `totalBytesUsed`: the published bytes every Job index names.
    fn used_bytes(&self) -> Result<u64, String> {
        let root = self.store.root();
        let names = root
            .names(100_000)
            .map_err(|_| corrupted("artifact root cannot be listed"))?;
        let mut total = 0_u64;
        for name in names {
            let kind = root
                .owned_kind_and_size(&name)
                .map_err(|_| {
                    corrupted(&format!(
                        "artifact root contains an unexpected or linked entry {name}"
                    ))
                })?
                .0;
            match kind {
                HostEntryKind::Directory if name == IMPORT_NAMESPACE => {}
                HostEntryKind::Directory => {
                    let job = root
                        .child(&name)
                        .map_err(|_| corrupted("artifact job directory cannot be opened"))?;
                    let bytes = match job.read("index.json", MAX_INDEX) {
                        Ok(bytes) => bytes,
                        Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                        Err(_) => return Err(corrupted("artifact index cannot be opened")),
                    };
                    let rows = decode_index(&bytes, &name).map_err(|_| {
                        corrupted("artifact index contains a foreign, unsafe or duplicate identity")
                    })?;
                    for row in rows.iter().filter(|row| published(row)) {
                        total = total.saturating_add(row["byteCount"].as_u64().unwrap_or(0));
                    }
                }
                HostEntryKind::Regular if name == CLEANUP_DEBT => {}
                _ => {
                    return Err(corrupted(&format!(
                        "artifact root contains an unexpected or linked entry {name}"
                    )));
                }
            }
        }
        Ok(total)
    }

    /// Swift `upsert` then `persistIndex`.
    fn upsert(&self, job: &HostDirectory, job_id: &str, metadata: Value) -> Result<(), String> {
        let mut rows = self.load_index(job, job_id)?;
        if let Some(existing) = rows.iter().find(|row| row["name"] == metadata["name"])
            && existing["artifactID"] != metadata["artifactID"]
            && published(existing)
        {
            return Err(artifact_error(
                "artifactConflict",
                &format!(
                    "artifact name {} is already bound to immutable bytes",
                    metadata["name"].as_str().unwrap_or_default()
                ),
            ));
        }
        rows.retain(|row| {
            row["artifactID"] != metadata["artifactID"] && row["name"] != metadata["name"]
        });
        rows.push(metadata);
        Self::persist_index(job, rows)
    }

    /// Swift `persistIndex`: the whole index, in Swift's pretty spelling,
    /// published in place of the old one.
    fn persist_index(job: &HostDirectory, rows: Vec<Value>) -> Result<(), String> {
        let document = json!({"schemaVersion": "1.0.0", "artifacts": rows});
        let bytes = crate::session_json::encode_pretty(&document)
            .map_err(|_| io_failure("cannot encode artifact index"))?;
        job.publish_document("index.json", &bytes, MAX_INDEX)
            .map_err(|error| {
                let error = match error {
                    DocumentPublishError::BeforePublication(error)
                    | DocumentPublishError::OutcomeUnknown(error) => error,
                };
                io_failure(&format!("cannot persist artifact bytes: {error}"))
            })
    }
}

fn published(row: &Value) -> bool {
    row["status"].get("published").is_some()
}

/// Swift `ArtifactRetentionPolicy.retention`: a week by default, a day when
/// short-lived, and no deadline when pinned until verified.
pub(crate) fn retention(class: &str, created: &str) -> Result<Value, String> {
    if class == "pinnedUntilVerified" {
        return Ok(json!({"retentionClass": class, "pinned": true}));
    }
    let seconds = crate::format_time::plain_utc_seconds(created).ok_or_else(|| {
        io_failure(&format!(
            "cannot derive retention from invalid UTC timestamp {created}"
        ))
    })?;
    let lifetime = if class == "shortLived" {
        SHORT_LIFETIME
    } else {
        DEFAULT_LIFETIME
    };
    Ok(json!({
        "retentionClass": class,
        "deadlineUTC": crate::format_time::utc_timestamp(seconds + lifetime),
        "pinned": false,
    }))
}

/// Swift `sameImmutablePublication`.
fn same_immutable_publication(existing: &Value, proposed: &Value) -> bool {
    [
        "jobID",
        "sessionID",
        "stepID",
        "name",
        "mediaType",
        "byteCount",
        "sha256",
        "providerID",
        "sourceOperation",
        "bindingSnapshot",
        "privacy",
        "status",
        "redactionApplied",
        "derivation",
    ]
    .iter()
    .all(|key| existing.get(*key) == proposed.get(*key))
        && existing["retention"]["retentionClass"] == proposed["retention"]["retentionClass"]
        && existing["retention"]["pinned"] == proposed["retention"]["pinned"]
}

/// Swift `ArtifactRedactionPolicy.redact`: text and JSON products, read as
/// UTF-8, lose the home directory and the values after secret-looking keys.
pub(crate) fn redact(data: &[u8], media_type: &str, home: &str) -> (Vec<u8>, bool) {
    if !(media_type.starts_with("text/") || media_type == "application/json") {
        return (data.to_vec(), false);
    }
    let Ok(text) = std::str::from_utf8(data) else {
        return (data.to_vec(), false);
    };
    let homeless = if home.is_empty() {
        text.to_owned()
    } else {
        text.replace(home, "<HOME>")
    };
    let redacted = redact_secrets(&homeless);
    let applied = redacted != text;
    (redacted.into_bytes(), applied)
}

/// `(?i)(token|secret|password|passwd|api[_-]?key|authorization)(["'\s:=]+)([^\s"',}]{6,})`
/// replaced by `$1$2<REDACTED>`, with ICU's greedy matching and its `\s`.
fn redact_secrets(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut output = String::with_capacity(text.len());
    let mut at = 0;
    while at < chars.len() {
        if let Some((kept, end)) = secret_at(&chars, at) {
            output.extend(&chars[at..kept]);
            output.push_str("<REDACTED>");
            at = end;
        } else {
            output.push(chars[at]);
            at += 1;
        }
    }
    output
}

fn secret_at(chars: &[char], at: usize) -> Option<(usize, usize)> {
    let separators = at + keyword_at(chars, at)?;
    let longest = chars[separators..]
        .iter()
        .take_while(|c| separator(**c))
        .count();
    for length in (1..=longest).rev() {
        let value = separators + length;
        let run = chars[value..]
            .iter()
            .take_while(|c| value_char(**c))
            .count();
        if run >= 6 {
            return Some((value, value + run));
        }
    }
    None
}

/// The input characters a keyword consumes at `at`, matched as ICU's `(?i)`
/// matches a literal: ASCII case-insensitively, `ſ` as `s`, the Kelvin sign
/// as `k`, and `ß` or `ẞ` as the `ss` of `password` and `passwd`.
fn keyword_at(chars: &[char], at: usize) -> Option<usize> {
    fn fold(c: char) -> char {
        match c {
            '\u{017F}' => 's',
            '\u{212A}' => 'k',
            other => other.to_ascii_lowercase(),
        }
    }
    let word = |text: &str, from: usize| -> Option<usize> {
        let letters = text.as_bytes();
        let (mut input, mut letter) = (from, 0);
        while letter < letters.len() {
            let c = *chars.get(input)?;
            if letters[letter..].starts_with(b"ss") && matches!(c, '\u{DF}' | '\u{1E9E}') {
                letter += 2;
            } else if fold(c) == char::from(letters[letter]) {
                letter += 1;
            } else {
                return None;
            }
            input += 1;
        }
        Some(input - from)
    };
    for keyword in ["token", "secret", "password", "passwd"] {
        if let Some(length) = word(keyword, at) {
            return Some(length);
        }
    }
    if let Some(api) = word("api", at) {
        let after = at + api;
        if chars.get(after).is_some_and(|c| matches!(c, '_' | '-'))
            && let Some(key) = word("key", after + 1)
        {
            return Some(api + 1 + key);
        }
        if let Some(key) = word("key", after) {
            return Some(api + key);
        }
    }
    word("authorization", at)
}

/// ICU `\s`, the White_Space property, as the Swift probe observed it.
fn space(c: char) -> bool {
    matches!(
        c,
        '\u{09}'..='\u{0D}'
            | ' '
            | '\u{85}'
            | '\u{A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
    )
}
fn separator(c: char) -> bool {
    matches!(c, '"' | '\'' | ':' | '=') || space(c)
}
fn value_char(c: char) -> bool {
    !(space(c) || matches!(c, '"' | '\'' | ',' | '}'))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};

    /// A publication stopped at each step, then retried by a fresh owner:
    /// before its index write the product is never named, and the retry
    /// recovers the exact payload, sealing it owner read-only first, as
    /// Swift's `validateStoredPayload` does, so no index ever names a
    /// writable payload.
    #[test]
    fn a_publication_stopped_at_any_step_recovers_one_sealed_indexed_payload() {
        use std::os::unix::fs::MetadataExt;
        for stop in [
            ArtifactPublicationFault::AfterPayload,
            ArtifactPublicationFault::AfterSeal,
            ArtifactPublicationFault::AfterIndex,
        ] {
            let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "artifact-publication-stop-{:032x}",
                u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&root)
                .unwrap();
            let product = Product {
                job_id: "job-stopped",
                session_id: "session-job-stopped",
                step_id: "analyze",
                name: "crash-signature.json",
                media_type: "application/octet-stream",
                privacy: "standard",
                retention_class: "default",
                source_operation: "analyzer.extract-crash-signature@1",
                provider_id: "analyzer",
                binding: json!({"targetID": "TGT-fixture"}),
                observation_window: None,
            };
            fn publisher(store: &ArtifactReadStore) -> ArtifactPublisher<'_> {
                ArtifactPublisher {
                    store,
                    quota: u64::MAX,
                    home: "/Users/nobody",
                    now: || Some("2026-09-14T00:00:00Z".into()),
                }
            }
            let stopped = ArtifactReadStore::open_with_fault(
                &root,
                std::sync::Arc::new(move |point| {
                    if point == stop {
                        Err(io::Error::other("stopped"))
                    } else {
                        Ok(())
                    }
                }),
            )
            .unwrap();
            assert!(publisher(&stopped).publish(&product, b"signature").is_err());
            let directory = root.join("job-stopped");
            let payloads: Vec<_> = std::fs::read_dir(&directory)
                .unwrap()
                .map(|entry| entry.unwrap())
                .filter(|entry| entry.file_name().to_string_lossy().starts_with("ART-"))
                .collect();
            assert_eq!(payloads.len(), 1, "{stop:?}");
            let payload = payloads[0].path();
            let mode = std::fs::metadata(&payload).unwrap().mode() & 0o777;
            let indexed = || {
                std::fs::read(directory.join("index.json"))
                    .map(|bytes| {
                        serde_json::from_slice::<Value>(&bytes).unwrap()["artifacts"].clone()
                    })
                    .unwrap_or(json!([]))
            };
            match stop {
                ArtifactPublicationFault::AfterPayload => {
                    assert_eq!(mode, 0o600);
                    assert_eq!(indexed(), json!([]));
                }
                ArtifactPublicationFault::AfterSeal => {
                    assert_eq!(mode, 0o400);
                    assert_eq!(indexed(), json!([]));
                }
                ArtifactPublicationFault::AfterIndex => {
                    assert_eq!(mode, 0o400);
                    assert_eq!(indexed().as_array().unwrap().len(), 1);
                }
            }
            drop(stopped);
            let store = ArtifactReadStore::open(&root).unwrap();
            let metadata = publisher(&store).publish(&product, b"signature").unwrap();
            assert_eq!(
                payload.file_name().unwrap().to_str(),
                metadata["artifactID"].as_str(),
                "{stop:?}"
            );
            assert_eq!(indexed(), json!([metadata]), "{stop:?}");
            assert_eq!(std::fs::metadata(&payload).unwrap().mode() & 0o777, 0o400);
            // The recovered product reads back as any other.
            assert_eq!(store.list("job-stopped").unwrap().len(), 1);
            std::fs::set_permissions(&payload, std::fs::Permissions::from_mode(0o600)).unwrap();
            std::fs::remove_dir_all(&root).unwrap();
        }
    }

    /// Every expected spelling is Swift's own: `replacingOccurrences` with the
    /// policy pattern, probed on the pinned macOS toolchain.
    #[test]
    fn redaction_matches_the_swift_policy() {
        let (bytes, applied) = redact(
            br#"{"a":"password=hunter2hunter2","b":"/Users/me/x","c":"api_key: abcdef1234","d":"token=short","e":"tokenizer","f":"Authorization: Bearer abcdefgh","g":"secret::::::"}"#,
            "application/json",
            "/Users/me",
        );
        assert!(applied);
        assert_eq!(
            String::from_utf8(bytes).unwrap(),
            r#"{"a":"password=<REDACTED>","b":"<HOME>/x","c":"api_key: <REDACTED>","d":"token=short","e":"tokenizer","f":"Authorization: <REDACTED> abcdefgh","g":"secret::::::"}"#
        );
        for (input, expected) in [
            ("secret:::::::", "secret:<REDACTED>"),
            ("APIKEY=abcdefgh", "APIKEY=<REDACTED>"),
            ("Api-Key==:=abcdef", "Api-Key==:=<REDACTED>"),
            ("passwd\u{A0}abcdefg", "passwd\u{A0}<REDACTED>"),
            ("token\u{0B}abcdefgh", "token\u{0B}<REDACTED>"),
            ("token\u{85}abcdefgh", "token\u{85}<REDACTED>"),
            ("token\u{1C}abcdefgh", "token\u{1C}abcdefgh"),
            ("token=abc\u{200B}defgh", "token=<REDACTED>"),
            ("password=abc,defghi", "password=abc,defghi"),
            ("tokentoken=abcdefgh", "tokentoken=<REDACTED>"),
            ("password:\"abcdefgh\"", "password:\"<REDACTED>\""),
            ("\u{17F}ecret=abcdefgh", "\u{17F}ecret=<REDACTED>"),
            ("to\u{212A}en=abcdefgh", "to\u{212A}en=<REDACTED>"),
            ("pa\u{DF}word=abcdefgh", "pa\u{DF}word=<REDACTED>"),
            ("pa\u{1E9E}word=abcdefgh", "pa\u{1E9E}word=<REDACTED>"),
            ("PA\u{DF}WD=abcdefgh", "PA\u{DF}WD=<REDACTED>"),
            ("\u{130}pikey=abcdefgh", "\u{130}pikey=abcdefgh"),
            ("ap\u{131}key=abcdefgh", "ap\u{131}key=abcdefgh"),
            (
                "\u{FF34}\u{FF2F}\u{FF2B}\u{FF25}\u{FF2E}=abcdefgh",
                "\u{FF34}\u{FF2F}\u{FF2B}\u{FF25}\u{FF2E}=abcdefgh",
            ),
            ("token=ab\u{1F600}cdef", "token=<REDACTED>"),
        ] {
            let (bytes, _) = redact(input.as_bytes(), "text/plain", "/Users/me");
            assert_eq!(String::from_utf8(bytes).unwrap(), expected, "{input:?}");
        }
        assert_eq!(
            redact(b"password=hunter2hunter2", "application/octet-stream", ""),
            (b"password=hunter2hunter2".to_vec(), false)
        );
        assert_eq!(
            redact(b"plain", "text/plain", "/Users/me"),
            (b"plain".to_vec(), false)
        );
    }
}
