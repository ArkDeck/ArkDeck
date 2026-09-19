//! Artifact RPC routing. Job existence always comes from the Runtime Job owner,
//! never from a payload directory or a caller-provided inventory.
use crate::snapshot_pager::SnapshotPager;
use crate::{
    ArtifactExportRequest, ArtifactInspectRequest, ArtifactReadRequest, ArtifactReadStore,
};
use arkdeck_contract::WireError;
use serde_json::{Map, Value, json};
use std::io;
use std::path::Path;

pub(crate) fn failure(code: &str, message: &str) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([
            ("phase".into(), json!("artifactOwner")),
            ("newDispatchCount".into(), json!(0)),
        ])),
    }
}
pub(crate) fn map_error(error: io::Error) -> WireError {
    match error.kind() {
        io::ErrorKind::InvalidInput => failure(
            "invalidInput",
            "Artifact requires one exact owner and bounded typed options",
        ),
        io::ErrorKind::Unsupported => failure(
            "operationUnavailable",
            "Import Artifact owner is not configured",
        ),
        io::ErrorKind::NotFound => {
            failure("resourceNotFound", "Artifact does not exist for this owner")
        }
        io::ErrorKind::PermissionDenied
            if error.to_string() == "Sensitive Artifact requires explicit opt-in" =>
        {
            failure(
                "sensitiveAccessDenied",
                "Sensitive Artifact content requires explicit permission",
            )
        }
        io::ErrorKind::InvalidData => failure(
            "artifactIntegrityFailed",
            "Artifact metadata or immutable content is inconsistent",
        ),
        _ => failure("recordUnreadable", "Artifact resource is unreadable"),
    }
}
enum ResourceRequest {
    Inspect(ArtifactInspectRequest),
    Read(ArtifactReadRequest),
    Export(ArtifactExportRequest),
}
impl ResourceRequest {
    fn reference(&self) -> &ArtifactInspectRequest {
        match self {
            Self::Inspect(reference) => reference,
            Self::Read(request) => request.reference(),
            Self::Export(request) => request.reference(),
        }
    }
}
impl ArtifactReadStore {
    /// `require_job` must capture the actual Job owner's validated persisted or
    /// current record. It is deliberately mandatory even for inspect, and is
    /// evaluated before accessing any Artifact metadata or payload.
    pub fn handle_resource(
        &self,
        method: &str,
        params: &Map<String, Value>,
        require_job: impl FnOnce(&str) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        if params.get("owner").and_then(|v| v.get("kind")) == Some(&json!("import")) {
            return Err(failure(
                "operationUnavailable",
                "Import Artifact ownership requires its Import owner",
            ));
        }
        self.handle_owned_resource(method, params, require_job)
    }

    pub(crate) fn handle_owned_resource(
        &self,
        method: &str,
        params: &Map<String, Value>,
        require_job: impl FnOnce(&str) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        let request = match method {
            "artifact.inspect" => ResourceRequest::Inspect(
                ArtifactInspectRequest::from_params(params).map_err(map_error)?,
            ),
            "artifact.read" => {
                ResourceRequest::Read(ArtifactReadRequest::from_params(params).map_err(map_error)?)
            }
            "artifact.export" => ResourceRequest::Export(
                ArtifactExportRequest::from_params(params).map_err(map_error)?,
            ),
            _ => {
                return Err(failure(
                    "unknownMethod",
                    "Artifact resource method is not published",
                ));
            }
        };
        require_job(request.reference().job_id()).map_err(owner_failure)?;
        match request {
            ResourceRequest::Read(request) => self.read_wire(&request).map_err(map_error),
            ResourceRequest::Inspect(reference) => self.inspect_wire(&reference).map_err(map_error),
            ResourceRequest::Export(request) => self.export_wire(&request),
        }
    }

    /// Swift `RuntimeArtifactResourceHandler`'s `artifact.list` of a Job
    /// owner, in its order: closed parameters with one tagged owner, the
    /// Job's existence from the Job owner, the cursor, the page size, then a
    /// page of the snapshot `snapshots` keeps of every Artifact the Job's
    /// index verifies, each the projection `artifact.inspect` answers, newest
    /// first and then by Artifact identity.
    pub fn handle_list(
        &self,
        params: &Map<String, Value>,
        snapshots: &Path,
        require_job: impl FnOnce(&str) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        if params.get("owner").and_then(|v| v.get("kind")) == Some(&json!("import")) {
            return Err(failure(
                "operationUnavailable",
                "Import Artifact ownership requires its Import owner",
            ));
        }
        self.handle_owned_list(params, snapshots, require_job)
    }

    pub(crate) fn handle_owned_list(
        &self,
        params: &Map<String, Value>,
        snapshots: &Path,
        require_job: impl FnOnce(&str) -> Result<(), WireError>,
    ) -> Result<Value, WireError> {
        if !params
            .keys()
            .all(|key| ["owner", "pageSize", "cursor"].contains(&key.as_str()))
            || !params.contains_key("owner")
        {
            return Err(failure(
                "invalidInput",
                "Artifact parameters require one tagged owner and closed options",
            ));
        }
        let job = crate::artifact_projection::job_owner(params).map_err(map_error)?;
        require_job(&job).map_err(owner_failure)?;
        let cursor = match params.get("cursor") {
            None => None,
            Some(Value::String(text)) if !text.is_empty() && text.len() <= 2048 => {
                Some(text.as_str())
            }
            Some(_) => return Err(failure("invalidCursor", "Artifact cursor is malformed")),
        };
        let page_size = match params.get("pageSize") {
            None => 100,
            Some(value) => value
                .as_u64()
                .filter(|size| (1..=1000).contains(size))
                .and_then(|size| usize::try_from(size).ok())
                .ok_or_else(|| {
                    failure(
                        "invalidInput",
                        "Artifact integer option is outside its published bound",
                    )
                })?,
        };
        let pager = SnapshotPager::open(snapshots)
            .map_err(|_| failure("recordUnreadable", "Artifact resource is unreadable"))?;
        pager
            .page_filtered(
                "artifact.list",
                &json!({"owner": params["owner"]}),
                "createdAtDescArtifactIdAsc",
                page_size,
                cursor,
                || {
                    self.listed_rows(&job)
                        .map_err(map_error)?
                        .iter()
                        .map(|row| {
                            let artifact = row["artifactID"].as_str().unwrap_or_default();
                            let request = ArtifactInspectRequest::from_params(&Map::from_iter([
                                ("owner".into(), params["owner"].clone()),
                                ("artifactId".into(), json!(artifact)),
                            ]))
                            .map_err(map_error)?;
                            crate::artifact_projection::inspect_result(row, &request)
                                .map_err(map_error)
                        })
                        .collect()
                },
            )
            .map_err(|mut error| {
                // The pager is shared with other owners; its refusals here
                // are the Artifact owner's.
                if let Some(details) = error.details.as_mut() {
                    details.insert("phase".into(), json!("artifactOwner"));
                }
                error
            })
    }
}

/// Only Job-owner existence and availability classifications cross this
/// boundary; all corruption/refusal details remain local.
fn owner_failure(error: WireError) -> WireError {
    match error.code.as_str() {
        "notFound" | "resourceNotFound" => {
            failure("resourceNotFound", "Artifact Job owner does not exist")
        }
        "operationUnavailable" => {
            failure("operationUnavailable", "Artifact Job owner is unavailable")
        }
        _ => failure("recordUnreadable", "Artifact Job owner is unreadable"),
    }
}
