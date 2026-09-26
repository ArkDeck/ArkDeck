//! Registered host-input validation and exact immutable Import publication.
//! A durable committing record certifies the original format/binding checks;
//! restart finishes only that same publication, never a device operation.
use super::*;
use crate::ArtifactReadStore;
use crate::artifact_publication::{ArtifactPublisher, Product};

fn content_invalid() -> WireError {
    failure(
        "invalidInput",
        "Import content failed its registered format validator",
    )
}
fn validate_content(
    file: &HostUploadFile,
    intent: &ImportIntent,
) -> Result<Map<String, Value>, WireError> {
    let value = match intent.kind.as_str() {
        "hap" => {
            if file.validator_bytes(4, true).map_err(unreadable)? != b"PK\x03\x04" {
                return Err(failure(
                    "invalidInput",
                    "Import is not a ZIP-based HAP/HSP container",
                ));
            }
            json!({"kind":"hap","container":"zip"})
        }
        "native-library" => {
            let bytes = file
                .validator_bytes(64 * 1024 * 1024, false)
                .map_err(unreadable)?;
            let facts = arkdeck_provider_hdc::validate_elf(&bytes, None, true)
                .map_err(|_| content_invalid())?;
            json!({"kind":"native-library","abi":facts.abi.raw(),"elfClassBits":facts.elf_class_bits,"machine":facts.machine,"buildId":facts.build_id})
        }
        "workspace-patch" => {
            let bytes = file
                .validator_bytes(512 * 1024, false)
                .map_err(unreadable)?;
            json!({"kind":"workspace-patch","touchedFiles":patch_paths(&bytes)?})
        }
        // Swift's production policy registers the one DAYU200 profile and
        // judges the archive by reading it.
        "flash-bundle" => {
            if intent.device_profile.as_deref() != Some("dayu200") {
                return Err(failure(
                    "invalidInput",
                    "Import flash profile is not registered",
                ));
            }
            let (byte_count, sha256) =
                crate::flash_archive::import_validation(&mut file.validator_reader(), &intent.name)
                    .map_err(|_| content_invalid())?;
            if u64::try_from(byte_count).ok() != Some(intent.byte_count) || sha256 != intent.sha256
            {
                return Err(failure(
                    "artifactIntegrityFailed",
                    "validated archive does not match Import metadata",
                ));
            }
            json!({"kind":"flash-bundle","deviceProfile":"dayu200"})
        }
        _ => {
            return Err(failure(
                "operationUnavailable",
                "This Import kind's publication validator is not configured",
            ));
        }
    };
    Ok(value.as_object().expect("validation object").clone())
}
fn patch_path(text: &str, prefix: &str) -> Option<String> {
    let path = text.strip_prefix(prefix)?;
    if path.is_empty()
        || path.starts_with('/')
        || path.contains('\\')
        || path == ".git"
        || path.starts_with(".git/")
        || path.split('/').any(|part| matches!(part, "" | "." | ".."))
    {
        return None;
    }
    Some(path.into())
}
fn patch_paths(bytes: &[u8]) -> Result<Vec<String>, WireError> {
    let text = std::str::from_utf8(bytes).map_err(|_| content_invalid())?;
    if text.contains('\0') {
        return Err(content_invalid());
    }
    let mut paths = BTreeSet::new();
    for line in text.split('\n') {
        if [
            "GIT binary patch",
            "Binary files ",
            "rename from ",
            "rename to ",
            "copy from ",
            "copy to ",
        ]
        .iter()
        .any(|prefix| line.starts_with(prefix))
        {
            return Err(content_invalid());
        }
        if line.starts_with("diff --git ") {
            let fields: Vec<_> = line.split(' ').filter(|v| !v.is_empty()).collect();
            if fields.len() != 4 {
                return Err(content_invalid());
            }
            paths.insert(patch_path(fields[2], "a/").ok_or_else(content_invalid)?);
            paths.insert(patch_path(fields[3], "b/").ok_or_else(content_invalid)?);
        } else if line.starts_with("--- ") || line.starts_with("+++ ") {
            let raw = line[4..]
                .split('\t')
                .find(|part| !part.is_empty())
                .unwrap_or("");
            if raw != "/dev/null" {
                paths.insert(
                    patch_path(raw, if line.starts_with("--- ") { "a/" } else { "b/" })
                        .ok_or_else(content_invalid)?,
                );
            }
        }
    }
    if paths.is_empty() || paths.len() > 128 {
        return Err(content_invalid());
    }
    Ok(paths.into_iter().collect())
}

impl ImportUploadStore {
    /// The daemon alone supplies the Artifact owner, quota and fresh Target
    /// resolver; the wire accepts only one Import identity and generation.
    #[allow(clippy::too_many_arguments)]
    pub fn commit(
        &self,
        fields: &Map<String, Value>,
        now: &str,
        app_owned: bool,
        artifacts: &ArtifactReadStore,
        quota: u64,
        resolve_binding: impl FnOnce(&ImportIntent) -> Result<ImportBinding, WireError>,
    ) -> Result<Value, WireError> {
        // Swift's handler: the names, the identity, then the generation; the
        // owner's lookup then judges the identity's form.
        if fields.len() != 2
            || !fields.contains_key("importId")
            || !fields.contains_key("generation")
        {
            return Err(closed());
        }
        let id = identity(fields, "importId")?;
        let generation = positive_generation(fields)?;
        if import_timestamp(now).is_none() {
            return Err(failure(
                "operationUnavailable",
                "Runtime Import clock is unavailable",
            ));
        }
        if artifacts.path != self.artifact_path {
            return Err(unreadable("different Artifact root"));
        }
        let mut cache = self.verified.lock().map_err(unreadable)?;
        let loaded = self.by_id(id, &mut cache)?;
        let mut record = loaded.record;
        if app_owned
            && (record.app_owned != Some(true)
                || !matches!(
                    record.intent.kind.as_str(),
                    "hap" | "native-library" | "flash-bundle"
                ))
        {
            return Err(failure(
                "admissionDenied",
                "Import is outside this App upload scope",
            ));
        }
        if record.state == "committed"
            && (generation == record.generation || generation == record.generation - 1)
        {
            return Ok(record.projection());
        }
        // Swift `RuntimeArtifactStore.commitImport`'s own text for an upload
        // that is incomplete, of another generation, or no longer uploadable.
        if record.generation != generation
            || !matches!(record.state.as_str(), "inProgress" | "committing")
            || record.next_offset != record.intent.byte_count
            || generation == i64::MAX as u64
        {
            return Err(failure(
                "resourceConflict",
                "Import is incomplete or no longer uploadable",
            ));
        }
        if !matches!(
            record.intent.kind.as_str(),
            "hap" | "native-library" | "workspace-patch" | "flash-bundle"
        ) {
            return Err(failure(
                "operationUnavailable",
                "This Import kind's publication validator is not configured",
            ));
        }
        let file = HostUploadFile::open(&self.payloads, &format!("{id}.stage"), false)
            .map_err(unreadable)?;
        if file
            .complete_digest(record.intent.byte_count)
            .map_err(unreadable)?
            != record.intent.sha256
        {
            return Err(failure(
                "artifactIntegrityFailed",
                "Import source digest does not match its metadata",
            ));
        }
        let before = file.checkpoint_identity().map_err(unreadable)?;
        let facts = if let Some(facts) = &record.validation {
            facts.clone()
        } else {
            // Swift's commit validator: the Target owner's refusal as it
            // answers it, then a binding other than the upload began under.
            if resolve_binding(&record.intent)? != record.binding {
                return Err(failure(
                    "resourceConflict",
                    "target binding changed during Import",
                ));
            }
            validate_content(&file, &record.intent)?
        };
        if file.checkpoint_identity().map_err(unreadable)? != before {
            return Err(unreadable("validation raced"));
        }
        if record.state != "committing" {
            record.state = "committing".into();
            record.validation = Some(facts.clone());
            record.updated_at = now.into();
            self.save(&record, Some(&loaded.bytes))?;
        }
        (self.fault)(ImportUploadFault::AfterCommitIntent).map_err(unreadable)?;
        let prior = self.load(&record.name())?.bytes;
        let session = format!("import-{id}");
        let step = format!("import-{}", record.intent.kind);
        let operation = format!("artifact.import-{}", record.intent.kind);
        let metadata = ArtifactPublisher {
            store: artifacts,
            quota,
            home: "",
            now: || None,
        }
        .publish_import(
            &Product {
                job_id: id,
                session_id: &session,
                step_id: &step,
                name: &record.intent.name,
                media_type: record.intent.media_type(),
                privacy: record.intent.privacy(),
                retention_class: "pinnedUntilVerified",
                source_operation: &operation,
                provider_id: "host",
                binding: serde_json::to_value(&record.binding).map_err(unreadable)?,
                observation_window: None,
            },
            &file,
            record.intent.byte_count,
            &record.intent.sha256,
            now,
            || (self.fault)(ImportUploadFault::AfterPayloadPublication).map_err(|e| e.to_string()),
        )
        .map_err(|e| {
            if e.starts_with("quotaExceeded(") {
                failure(
                    "quotaExceeded",
                    "Artifact capacity is exhausted; the Import remains discoverable",
                )
            } else {
                unreadable(e)
            }
        })?;
        (self.fault)(ImportUploadFault::AfterPublication).map_err(unreadable)?;
        let artifact = metadata["artifactID"]
            .as_str()
            .ok_or_else(|| unreadable("metadata"))?;
        record.receipt = Some(
            json!({"schemaVersion":"arkdeck.import-receipt/1", "importId":id,
            "importRequestId":record.intent.request_id, "owner":{"kind":"import","id":id},
            "artifactId":artifact,"artifactDigest":record.intent.sha256,"byteCount":record.intent.byte_count.to_string(),
            "name":record.intent.name,"mediaType":record.intent.media_type(),"privacy":record.intent.privacy(),
            "targetId":record.intent.target_id,"bindingRevision":record.intent.binding_revision.to_string(),
            "lease":format!("lease-v1:{id}:{artifact}"),"generation":(record.generation+1).to_string(),"validation":facts}),
        );
        record.state = "committed".into();
        record.generation += 1;
        record.updated_at = now.into();
        self.save(&record, Some(&prior))?;
        (self.fault)(ImportUploadFault::AfterReceiptCheckpoint).map_err(unreadable)?;
        cache.remove(id);
        self.remove_staging(&record)?;
        Ok(record.projection())
    }
}

impl ImportUploadStore {
    /// Serialize receipt verification with publication for the entire read or
    /// export. A directory/index alone never establishes Import ownership.
    pub fn artifact_resource(
        &self,
        artifacts: &ArtifactReadStore,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, WireError> {
        self.artifact_resource_inner(artifacts, method, params)
            .map_err(|mut error| {
                if let Some(details) = error.details.as_mut() {
                    details.insert("phase".into(), json!("artifactOwner"));
                }
                error
            })
    }

    fn artifact_resource_inner(
        &self,
        artifacts: &ArtifactReadStore,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, WireError> {
        let owner = params
            .get("owner")
            .and_then(Value::as_object)
            .ok_or_else(invalid)?;
        if owner.len() != 2 || owner.get("kind") != Some(&json!("import")) {
            return Err(invalid());
        }
        let id = owner
            .get("id")
            .and_then(Value::as_str)
            .filter(|v| import_id(v))
            .ok_or_else(invalid)?;
        if artifacts.path != self.artifact_path {
            return Err(unreadable("different Artifact root"));
        }
        let mut cache = self.verified.lock().map_err(unreadable)?;
        let record = self.by_id(id, &mut cache)?.record;
        self.finish_release(artifacts, &record)?;
        let rows = artifacts.listed_rows(id).map_err(unreadable)?;
        for row in &rows {
            if !["committed", "released"].contains(&record.state.as_str()) {
                return Err(unreadable("uncommitted publication"));
            }
            record.verifies_metadata(row)?;
        }
        let require_owner = |requested: &str| {
            if requested == id {
                Ok(())
            } else {
                Err(invalid())
            }
        };
        let mut value = if method == "artifact.list" {
            artifacts.handle_owned_list(params, require_owner)?
        } else {
            artifacts.handle_owned_resource(method, params, require_owner)?
        };
        if record.state == "released"
            && let Some(object) = value.as_object_mut()
        {
            if object.contains_key("lease") {
                object.insert("lease".into(), Value::Null);
            }
            if let Some(Value::Array(items)) = object.get_mut("items") {
                for item in items {
                    if let Some(row) = item.as_object_mut() {
                        row.insert("lease".into(), Value::Null);
                    }
                }
            }
        }
        Ok(value)
    }
}

impl ImportUploadStore {
    pub fn list(&self, fields: &Map<String, Value>) -> Result<Value, WireError> {
        self.list_inner(fields, None)
    }
    pub fn list_with_artifacts(
        &self,
        fields: &Map<String, Value>,
        artifacts: &ArtifactReadStore,
    ) -> Result<Value, WireError> {
        if artifacts.path != self.artifact_path {
            return Err(unreadable("different Artifact owner"));
        }
        self.list_inner(fields, Some(artifacts))
    }
    fn list_inner(
        &self,
        fields: &Map<String, Value>,
        artifacts: Option<&ArtifactReadStore>,
    ) -> Result<Value, WireError> {
        // Swift `RuntimeArtifactStore.listImports`'s refusals, in its order.
        if fields
            .keys()
            .any(|k| !["target", "state", "pageSize", "cursor"].contains(&k.as_str()))
        {
            return Err(failure("invalidInput", "Import list options are closed"));
        }
        let filter_invalid = || failure("invalidInput", "Import filter is invalid");
        let mut filters = Map::new();
        for key in ["target", "state"] {
            if let Some(value) = fields.get(key) {
                let text = value
                    .as_str()
                    .filter(|v| import_identifier(v))
                    .ok_or_else(filter_invalid)?;
                if key == "state"
                    && ![
                        "inProgress",
                        "committing",
                        "committed",
                        "aborted",
                        "released",
                    ]
                    .contains(&text)
                {
                    return Err(filter_invalid());
                }
                filters.insert(key.into(), value.clone());
            }
        }
        let size = fields.get("pageSize").map_or(Ok(100), |v| {
            v.as_u64()
                .filter(|n| (1..=1000).contains(n))
                .map(|n| n as usize)
                .ok_or_else(|| failure("invalidInput", "invalid pageSize"))
        })?;
        let cursor = fields
            .get("cursor")
            .map(|v| {
                v.as_str()
                    .filter(|v| !v.is_empty() && v.len() <= 2048)
                    .ok_or_else(|| failure("invalidCursor", "invalid Import cursor"))
            })
            .transpose()?;
        let mut cache = self.verified.lock().map_err(unreadable)?;
        self.validate()?;
        self.root.private_child("snapshots").map_err(unreadable)?;
        let pager = crate::snapshot_pager::SnapshotPager::open(
            &self.artifact_path.join(".imports-v1/snapshots"),
        )
        .map_err(unreadable)?;
        pager
            .page_filtered(
                "artifact.import.list",
                &Value::Object(filters.clone()),
                "createdAtDescImportIdAsc",
                size,
                cursor,
                || {
                    let mut captured = Vec::new();
                    let mut total = 0;
                    self.visit(|loaded| {
                        let record = loaded.record;
                        if filters
                            .get("target")
                            .is_some_and(|v| v != &record.intent.target_id)
                            || filters.get("state").is_some_and(|v| v != &record.state)
                        {
                            return Ok(());
                        }
                        self.recover(&record, &mut cache)?;
                        if let Some(artifacts) = artifacts {
                            self.finish_release(artifacts, &record)?;
                        }
                        // Swift bounds the snapshot by its projections'
                        // canonical bytes, before the pager stores it.
                        total += canonical_json(&record.projection())
                            .map_err(unreadable)?
                            .len();
                        if total > 16 * 1024 * 1024 {
                            return Err(failure(
                                "operationUnavailable",
                                "Import snapshot exceeds its storage bound; narrow the query",
                            ));
                        }
                        captured.push((
                            import_timestamp(&record.created_at)
                                .ok_or_else(|| unreadable("timestamp"))?,
                            record.id.clone(),
                            record.projection(),
                        ));
                        Ok(())
                    })?;
                    captured.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
                    Ok(captured.into_iter().map(|v| v.2).collect())
                },
            )
            .map_err(|mut error| {
                if let Some(details) = error.details.as_mut() {
                    details.insert("phase".into(), json!("importOwner"));
                }
                error
            })
    }
}

#[cfg(test)]
mod tests {
    use super::patch_paths;
    #[test]
    fn patch_validator_refuses_unsafe_paths_and_unsupported_changes() {
        for path in [
            "/absolute",
            "back\\slash",
            ".git/config",
            ".git",
            "a//b",
            "a/./b",
            "a/../b",
            "",
        ] {
            assert!(
                patch_paths(format!("diff --git a/{path} b/{path}\n").as_bytes()).is_err(),
                "{path}"
            );
        }
        for suffix in [
            "GIT binary patch",
            "Binary files a/a and b/a differ",
            "rename from a",
            "rename to b",
            "copy from a",
            "copy to b",
            "\0",
        ] {
            assert!(patch_paths(format!("diff --git a/a b/a\n{suffix}\n").as_bytes()).is_err());
        }
        assert!(patch_paths(&[0xff]).is_err());
        let maximum = (0..128)
            .map(|i| format!("diff --git a/{i} b/{i}\n"))
            .collect::<String>();
        assert_eq!(patch_paths(maximum.as_bytes()).unwrap().len(), 128);
        assert!(
            patch_paths(format!("{maximum}diff --git a/overflow b/overflow\n").as_bytes()).is_err()
        );
        assert_eq!(
            patch_paths(b"--- /dev/null\n+++ b/new\n+text\n").unwrap(),
            vec!["new"]
        );
    }
}
