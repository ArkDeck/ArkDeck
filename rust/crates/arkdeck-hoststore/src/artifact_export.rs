//! Explicit host export of a verified Job Artifact. The source owner remains
//! read-only; only the requested external destination can be published.
use crate::artifact_resources::{failure, map_error};
use crate::{ArtifactInspectRequest, ArtifactReadStore};
use arkdeck_contract::WireError;
use arkdeck_platform::{ExportPublishError, FileExportStaging, host_control_character};
use serde_json::{Map, Value, json};
use std::{
    io,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArtifactExportRequest {
    reference: ArtifactInspectRequest,
    destination: PathBuf,
    overwrite: bool,
    allow_sensitive: bool,
}
fn invalid() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "Artifact export requires one owner and an explicit bounded destination",
    )
}
impl ArtifactExportRequest {
    pub fn from_params(params: &Map<String, Value>) -> io::Result<Self> {
        if params.keys().any(|key| {
            ![
                "owner",
                "artifactId",
                "destinationDirectory",
                "overwrite",
                "allowSensitive",
            ]
            .contains(&key.as_str())
        }) {
            return Err(invalid());
        }
        let fields = Map::from_iter([
            (
                "owner".into(),
                params.get("owner").cloned().ok_or_else(invalid)?,
            ),
            (
                "artifactId".into(),
                params.get("artifactId").cloned().ok_or_else(invalid)?,
            ),
        ]);
        let reference = ArtifactInspectRequest::from_params(&fields)?;
        let path = params
            .get("destinationDirectory")
            .and_then(Value::as_str)
            .ok_or_else(invalid)?;
        if !path.starts_with('/') || path.len() > 4096 || path.chars().any(host_control_character) {
            return Err(invalid());
        }
        let flag = |key| match params.get(key) {
            None => Ok(false),
            Some(value) => value.as_bool().ok_or_else(invalid),
        };
        let destination =
            crate::session_export_destination::physical(Path::new(path)).map_err(|_| invalid())?;
        Ok(Self {
            reference,
            destination,
            overwrite: flag("overwrite")?,
            allow_sensitive: flag("allowSensitive")?,
        })
    }
    pub fn reference(&self) -> &ArtifactInspectRequest {
        &self.reference
    }
}
fn export_error(error: io::Error) -> WireError {
    match error.kind() {
        io::ErrorKind::InvalidInput => failure(
            "invalidInput",
            "Export destination must be an owned physical directory outside Artifact storage",
        ),
        io::ErrorKind::AlreadyExists => failure(
            "resourceConflict",
            "Export destination exists or changed; explicit overwrite requires its original identity",
        ),
        io::ErrorKind::InvalidData => failure(
            "artifactIntegrityFailed",
            "Artifact or export staging content is inconsistent",
        ),
        _ => failure(
            "operationFailed",
            "Artifact export did not publish a destination file",
        ),
    }
}
impl ArtifactReadStore {
    pub fn export_wire(&self, request: &ArtifactExportRequest) -> Result<Value, WireError> {
        // Preserve the synchronous Swift Artifact actor's single export turn.
        // This never grants device authority or changes source store contents.
        let _export = self.export_lock.lock().map_err(|_| {
            failure(
                "operationUnavailable",
                "Artifact export owner is unavailable",
            )
        })?;
        let reference = request.reference();
        let (job, index, rows) = self.index(reference.job_id()).map_err(map_error)?;
        let metadata = rows
            .iter()
            .find(|row| row["artifactID"] == reference.artifact_id())
            .ok_or_else(|| failure("resourceNotFound", "Artifact does not exist for this owner"))?;
        let projection =
            crate::artifact_projection::inspect_result(metadata, reference).map_err(map_error)?;
        if projection["status"] != "published" {
            return Err(failure(
                "resourceNotFound",
                "Artifact has no published content",
            ));
        }
        if projection["privacy"] == "sensitive" && !request.allow_sensitive {
            return Err(failure(
                "sensitiveAccessDenied",
                "Sensitive Artifact content requires explicit permission",
            ));
        }
        // Keep inspect/read's fail-closed inventory semantics before creating
        // any host staging file, then hold this exact index until publication.
        for row in &rows {
            if row["status"].get("published").is_some() {
                job.verify_payload(
                    row["artifactID"].as_str().expect("decoded identity"),
                    row["byteCount"].as_u64().expect("decoded length"),
                    row["sha256"].as_str().expect("decoded digest"),
                )
                .map_err(|_| {
                    failure(
                        "artifactIntegrityFailed",
                        "Artifact metadata or immutable content is inconsistent",
                    )
                })?;
            }
        }
        self.unchanged(reference.job_id(), &job, &index)
            .map_err(map_error)?;
        let protected = crate::session_export_destination::physical(&self.path)
            .map_err(|_| failure("recordUnreadable", "Artifact root is unreadable"))?;
        if request.destination.starts_with(protected) {
            return Err(failure(
                "invalidInput",
                "Export destination must be outside Artifact storage",
            ));
        }
        let name = projection["name"]
            .as_str()
            .expect("validated name")
            .replace('/', "_")
            .replace("..", "_");
        let filename = format!("{}-{name}", reference.artifact_id());
        if filename.len() > 255 || filename.chars().any(host_control_character) {
            return Err(failure(
                "invalidInput",
                "Artifact export filename exceeds the host filename bound",
            ));
        }
        let mut stage =
            FileExportStaging::create(&request.destination, &filename, request.overwrite)
                .map_err(export_error)?;
        stage
            .copy_verified(
                &job,
                reference.artifact_id(),
                projection["byteCount"].as_u64().expect("validated size"),
                projection["artifactDigest"]
                    .as_str()
                    .expect("validated digest"),
            )
            .map_err(export_error)?;
        let (path,overwritten)=stage.publish(||self.unchanged(reference.job_id(),&job,&index))
            .map_err(|error|match error {
                ExportPublishError::BeforePublication(error)=>export_error(error),
                ExportPublishError::OutcomeUnknown(_)=>failure("outcomeUnknown","Artifact export may have completed; inspect the exact destination before retrying"),
            })?;
        Ok(
            json!({"schemaVersion":"arkdeck.artifact-export/1","owner":projection["owner"],
            "artifactId":projection["artifactId"],"artifactDigest":projection["artifactDigest"],
            "byteCount":projection["byteCount"],"privacy":projection["privacy"],"exportedPath":path,"overwritten":overwritten}),
        )
    }
}
