//! The durable Job census a workspace project or preset mutation consults, as
//! Swift `RuntimeAdmissionService.requireNoActiveWorkspaceProjectReference` and
//! `requireNoActiveWorkspacePresetReference` do: a workspace Job that is not
//! terminal, or whose outcome is unknown, and names the project or preset
//! refuses its mutation. The census is read-only; it grants nothing and
//! repairs nothing, and a record it cannot verify refuses the mutation rather
//! than being skipped.
use super::*;
use crate::operation_catalog::CatalogOperation;
use crate::operation_request::OperationRequest;

/// Swift `workspacePresetInputNames`, in the sorted order Swift reads a Job
/// admitted under another Catalog digest.
const PRESET_INPUTS: [&str; 4] = [
    "buildPresetRef",
    "signingPresetRef",
    "symbolPresetRef",
    "testPresetRef",
];

fn workspace_failure(phase: &str, code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([
            ("phase".into(), json!(phase)),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}

impl JobStore {
    /// Every verified active or uncertain workspace Job, with its inputs and
    /// its descriptor in this build's Catalog, when it was admitted under this
    /// exact digest.
    fn for_each_active_workspace_job(
        &self,
        phase: &str,
        mut visit: impl FnMut(
            Option<&Map<String, Value>>,
            Option<&'static CatalogOperation>,
        ) -> Result<(), WireError>,
    ) -> Result<(), WireError> {
        let unverifiable = || {
            workspace_failure(
                phase,
                "recordUnreadable",
                "workspace Job references cannot be verified",
            )
        };
        let _guard = self.activity.lock().map_err(|_| unverifiable())?;
        self.root
            .validate_path(&self.path)
            .map_err(|_| unverifiable())?;
        let rows = self.repository.rows(None).map_err(|_| unverifiable())?;
        for row in &rows {
            let record = JobRecord::from_row(row).map_err(|_| unverifiable())?;
            if !record.verifies_submission(&row.request_hash) {
                return Err(unverifiable());
            }
            if !record.outcome_unknown() && crate::job_record::terminal(&record.state) {
                continue;
            }
            // The provider is a durable identity fact of the record: a Job
            // another provider owns cannot reference a workspace resource.
            if record.provider() != "workspace" {
                continue;
            }
            let inputs = record.request.get("inputs").and_then(Value::as_object);
            let descriptor = if record.catalog_digest() == arkdeck_contract::CATALOG_DIGEST {
                let request = OperationRequest::decode(
                    &serde_json::to_vec(&record.request).map_err(|_| unverifiable())?,
                )
                .map_err(|_| unverifiable())?;
                let reference = format!(
                    "{}@{}",
                    request.operation_id,
                    request.operation_version.unwrap_or(1)
                );
                (reference == record.operation())
                    .then(|| {
                        CatalogOperation::lookup(&request.operation_id, request.operation_version)
                    })
                    .flatten()
            } else {
                None
            };
            visit(inputs, descriptor)?;
        }
        Ok(())
    }

    /// Refuses when an active or uncertain workspace Job references
    /// `project_ref`. A Runtime-owned isolated copy is named by its derived
    /// reference, but its registration belongs to the project it was copied
    /// from: `registration` maps a copy to that project — through the
    /// provider's own profiles and, for a copy this Runtime could not adopt
    /// (a patched tree its lineage no longer vouches for, a Job parked on
    /// it), through the copy's manifest — so a copy's uncertain Job keeps its
    /// source from changing. Only a reference nothing maps is compared
    /// literally (Swift `resolveRegistrationProjectRef`).
    pub fn require_no_active_workspace_project_reference(
        &self,
        project_ref: &str,
        registration: &dyn Fn(&str) -> Option<String>,
    ) -> Result<(), WireError> {
        let phase = "workspaceProjectOwner";
        self.for_each_active_workspace_job(phase, |inputs, descriptor| {
            let referenced = match descriptor {
                Some(descriptor) => {
                    if !descriptor
                        .inputs
                        .iter()
                        .any(|field| field.name == "projectRef")
                    {
                        return Ok(());
                    }
                    inputs
                        .and_then(|inputs| inputs.get("projectRef"))
                        .and_then(Value::as_str)
                        .ok_or_else(|| {
                            workspace_failure(
                                phase,
                                "recordUnreadable",
                                "active workspace Job has no typed project reference",
                            )
                        })?
                }
                // A Job admitted under another Catalog digest has no
                // descriptor here; its durable reference is read by its closed
                // name, which can only over-report a reference.
                None => inputs
                    .and_then(|inputs| inputs.get("projectRef"))
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        workspace_failure(
                            phase,
                            "recordUnreadable",
                            "active workspace Job has no verifiable project reference",
                        )
                    })?,
            };
            if registration(referenced).as_deref().unwrap_or(referenced) == project_ref {
                return Err(workspace_failure(
                    phase,
                    "resourceConflict",
                    "workspace project is referenced by an active or uncertain Job",
                ));
            }
            Ok(())
        })
    }

    /// Refuses when an active or uncertain workspace Job names `preset_ref`
    /// in one of its preset inputs: the descriptor's own preset inputs for a
    /// Job of this Catalog, every closed preset input name for another.
    pub fn require_no_active_workspace_preset_reference(
        &self,
        preset_ref: &str,
    ) -> Result<(), WireError> {
        let phase = "workspacePresetOwner";
        self.for_each_active_workspace_job(phase, |inputs, descriptor| {
            let names: Vec<&str> = match descriptor {
                Some(descriptor) => descriptor
                    .inputs
                    .iter()
                    .map(|field| field.name.as_ref())
                    .filter(|name| PRESET_INPUTS.contains(name))
                    .collect(),
                None => PRESET_INPUTS.to_vec(),
            };
            if names.into_iter().any(|name| {
                inputs
                    .and_then(|inputs| inputs.get(name))
                    .and_then(Value::as_str)
                    == Some(preset_ref)
            }) {
                return Err(workspace_failure(
                    phase,
                    "resourceConflict",
                    "workspace preset is referenced by an active or uncertain Job",
                ));
            }
            Ok(())
        })
    }
}
