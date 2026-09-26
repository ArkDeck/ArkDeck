//! Import input holds and durable lease closure. Holds bridge materialization
//! to the Job's durable reference; they grant no capability or device authority.
use super::*;
use crate::JobStore;
use crate::artifact_publication::{ArtifactPublisher, retention};
use crate::artifact_read_owner::{ArtifactReadStore, LeasedArtifact};
use crate::job_owner::import_references::ImportReference;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_USE: AtomicU64 = AtomicU64::new(1);
/// Swift `RuntimeImportControlHandler.response` answers every refusal of an
/// Import request with the owner's zero-dispatch evidence, those of the Job
/// reference scan (`activeImportReferenceJobs`) too; the scan's own refusals
/// carry none.
fn with_owner_evidence(mut error: WireError) -> WireError {
    if error.details.is_none() {
        error.details = failure(&error.code, &error.message).details;
    }
    error
}
fn released() -> WireError {
    failure(
        "invalidInput",
        "Import input is released, missing or unreadable; use a valid committed import before submitting a new Job",
    )
}
pub(crate) struct ImportUse<'a> {
    owner: &'a ImportUploadStore,
    token: String,
}
impl Drop for ImportUse<'_> {
    fn drop(&mut self) {
        // A poisoned registry stays poisoned and prevents future release.
        if let Ok(mut uses) = self.owner.uses.lock() {
            uses.remove(&self.token);
        }
    }
}
impl Record {
    pub(super) fn expected_metadata(&self) -> Result<Value, WireError> {
        let receipt = self.receipt.as_ref().ok_or_else(invalid)?;
        Ok(json!({"artifactID":receipt["artifactId"],"jobID":self.id,
            "name":self.intent.name,"sha256":self.intent.sha256,"byteCount":self.intent.byte_count,
            "mediaType":self.intent.media_type(),"privacy":self.intent.privacy(),"redactionApplied":false,
            "providerID":"host","sessionID":format!("import-{}",self.id),"stepID":format!("import-{}",self.intent.kind),"sourceOperation":format!("artifact.import-{}",self.intent.kind),
            "bindingSnapshot":self.binding}))
    }
    pub(super) fn verifies_metadata(&self, row: &Value) -> Result<(), WireError> {
        if row["status"].get("published").is_none() {
            return Err(unreadable("Import publication status drifted"));
        }
        let expected = self.expected_metadata()?;
        if expected
            .as_object()
            .unwrap()
            .iter()
            .any(|(key, value)| row.get(key) != Some(value))
        {
            return Err(unreadable("Import immutable identity mismatch"));
        }
        let expected_retention = if self.state == "released" {
            json!({"retentionClass":"default","pinned":false,"deadlineUTC":self.release_receipt.as_ref().ok_or_else(invalid)?["retention"]["deadlineUtc"]})
        } else {
            json!({"retentionClass":"pinnedUntilVerified","pinned":true})
        };
        if row["retention"] != expected_retention {
            return Err(unreadable("Import retention mismatch"));
        }
        Ok(())
    }
}
impl ImportUploadStore {
    pub(crate) fn acquire_inputs<'a>(
        &'a self,
        artifacts: &ArtifactReadStore,
        references: &[ImportReference],
    ) -> Result<Option<ImportUse<'a>>, WireError> {
        if references.is_empty() {
            return Ok(None);
        }
        let mut cache = self.verified.lock().map_err(unreadable)?;
        let mut uses = self.uses.lock().map_err(unreadable)?;
        if uses.len() >= 1024 {
            return Err(failure(
                "resourceConflict",
                "too many active input materializations",
            ));
        }
        for reference in references {
            // Swift `requireUsableImportInputs`: whatever keeps a lease from
            // resolving, an unknown Import included, refuses alike before
            // admission.
            self.resolve_guarded(artifacts, reference, &mut cache)
                .map_err(|_| released())?;
        }
        let token = NEXT_USE
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |v| v.checked_add(1))
            .map_err(unreadable)?
            .to_string();
        uses.insert(token.clone(), references.to_vec());
        let guard = ImportUse { owner: self, token };
        drop(uses);
        drop(cache);
        (self.fault)(ImportUploadFault::AfterInputHold).map_err(unreadable)?;
        Ok(Some(guard))
    }
    fn resolve_guarded(
        &self,
        artifacts: &ArtifactReadStore,
        reference: &ImportReference,
        cache: &mut BTreeMap<String, String>,
    ) -> Result<LeasedArtifact, WireError> {
        if artifacts.path != self.artifact_path {
            return Err(unreadable("different Artifact owner"));
        }
        let record = self.by_id(&reference.import_id, cache)?.record;
        if record.state != "committed"
            || record.receipt.as_ref().is_none_or(|receipt| {
                receipt["artifactId"] != reference.artifact_id
                    || receipt["lease"] != reference.value
            })
        {
            return Err(released());
        }
        let leased = artifacts
            .owned_lease(&reference.import_id, &reference.artifact_id)
            .map_err(unreadable)?;
        record.verifies_metadata(&leased.row)?;
        Ok(leased)
    }
    pub(crate) fn resolve_input(
        &self,
        artifacts: &ArtifactReadStore,
        reference: &ImportReference,
    ) -> Result<LeasedArtifact, WireError> {
        let mut cache = self.verified.lock().map_err(unreadable)?;
        self.resolve_guarded(artifacts, reference, &mut cache)
    }
    pub(super) fn finish_release(
        &self,
        artifacts: &ArtifactReadStore,
        record: &Record,
    ) -> Result<(), WireError> {
        if record.state != "released" {
            return Ok(());
        }
        if artifacts.path != self.artifact_path {
            return Err(unreadable("different Artifact owner"));
        }
        let receipt = record.release_receipt.as_ref().ok_or_else(invalid)?;
        let retention = json!({"retentionClass":"default", "pinned":false, "deadlineUTC":receipt["retention"]["deadlineUtc"]});
        ArtifactPublisher {
            store: artifacts,
            quota: u64::MAX,
            home: "",
            now: || None,
        }
        .finish_import_unpin(&record.id, &record.expected_metadata()?, &retention)
        .map_err(unreadable)?;
        (self.fault)(ImportUploadFault::AfterReleaseUnpin).map_err(unreadable)
    }
    pub fn lifecycle_resource(
        &self,
        artifacts: &ArtifactReadStore,
        jobs: &JobStore,
        method: &str,
        fields: &Map<String, Value>,
        now: &str,
    ) -> Result<Value, WireError> {
        if artifacts.path != self.artifact_path {
            return Err(unreadable("different Artifact owner"));
        }
        let release = method == "artifact.import.release";
        // Swift's handler judges the names, the identity and then a release's
        // generation, all before the owner reads a record.
        let generation = if release {
            if fields.len() != 2
                || !fields.contains_key("importId")
                || !fields.contains_key("generation")
            {
                return Err(closed());
            }
            identity(fields, "importId")?;
            positive_generation(fields)?
        } else {
            if method != "artifact.import.inspection" && method != "artifact.import.inspect"
                || fields.len() != 1
                || !(fields.contains_key("importId") || fields.contains_key("importRequestId"))
            {
                return Err(selector_required());
            }
            0
        };
        let selected = if fields.contains_key("importId") {
            Ok(identity(fields, "importId")?)
        } else {
            Err(identity(fields, "importRequestId")?)
        };
        let mut cache = self.verified.lock().map_err(unreadable)?;
        let loaded = match selected {
            Ok(id) => self.by_id(id, &mut cache)?,
            Err(request) => self.by_request(request, &mut cache)?.ok_or_else(absent)?,
        };
        let mut record = loaded.record;
        self.finish_release(artifacts, &record)?;
        if method == "artifact.import.inspect" {
            return Ok(record.projection());
        }
        let uses = self.uses.lock().map_err(unreadable)?;
        let holds = uses
            .values()
            .filter(|refs| {
                refs.iter()
                    .any(|reference| reference.import_id == record.id)
            })
            .count();
        if !release {
            return jobs.with_import_references(&record.id, |active| {
                let value=json!({"schemaVersion":"arkdeck.import-inspection/1","import":record.projection(),"references":{
                    "state":if active.is_empty() && holds==0 {"clear"} else {"referenced"},
                    "activeJobIds":active.iter().map(|(id,_)|id).collect::<Vec<_>>(),
                    "outcomeUnknownJobIds":active.iter().filter(|(_,unknown)|*unknown).map(|(id,_)|id).collect::<Vec<_>>(),
                    "activeMaterializationCount":holds.to_string()}});
                arkdeck_contract::validate_import_inspection(&value).map_err(unreadable)?; Ok(value)
            }).map_err(with_owner_evidence);
        }
        if record.state == "released" && generation == 2 {
            return record.release_receipt.ok_or_else(invalid);
        }
        // Swift `RuntimeArtifactStore.releaseImport`'s refusals, in its order.
        if record.state != "committed"
            || generation != record.generation
            || record
                .receipt
                .as_ref()
                .and_then(|receipt| receipt["artifactId"].as_str())
                .is_none()
        {
            return Err(failure(
                "resourceConflict",
                "release requires the exact committed Import generation",
            ));
        }
        if holds != 0 {
            return Err(failure(
                "resourceConflict",
                "Import is still used by an active materialization",
            ));
        }
        if import_timestamp(now).is_none() {
            return Err(invalid());
        }
        let id = record.id.clone();
        jobs.with_import_references(&id, |active| {
            if !active.is_empty() {
                return Err(failure("resourceConflict", "Import is still referenced by an active or uncertain Job"));
            }
            let receipt=record.receipt.as_ref().ok_or_else(invalid)?;
            let reference=ImportReference::parse(receipt["lease"].as_str().ok_or_else(invalid)?)?.ok_or_else(invalid)?;
            self.resolve_guarded(artifacts,&reference,&mut cache)?;
            let policy=retention("default",now).map_err(unreadable)?;
            let release=json!({"schemaVersion":"arkdeck.import-release/1","importId":record.id,"importRequestId":record.intent.request_id,
                "owner":{"kind":"import","id":record.id},"artifactId":receipt["artifactId"],"lease":receipt["lease"],
                "releasedGeneration":"2","generation":"3","state":"released","releasedAtUtc":now,
                "retention":{"class":"default","pinned":false,"deadlineUtc":policy["deadlineUTC"]}});
            record.state="released".into();record.generation=3;record.updated_at=now.into();record.release_receipt=Some(release.clone());
            self.save(&record,Some(&loaded.bytes))?;
            (self.fault)(ImportUploadFault::AfterReleaseCheckpoint).map_err(unreadable)?;
            self.finish_release(artifacts,&record)?;
            Ok(release)
        })
        .map_err(with_owner_evidence)
    }
}
