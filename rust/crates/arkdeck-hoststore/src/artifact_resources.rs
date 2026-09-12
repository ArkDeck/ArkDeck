//! Artifact RPC routing. Job existence always comes from the Runtime Job owner,
//! never from a payload directory or a caller-provided inventory.
use crate::{
    ArtifactExportRequest, ArtifactInspectRequest, ArtifactReadRequest, ArtifactReadStore,
};
use arkdeck_contract::WireError;
use serde_json::{Map, Value, json};
use std::io;

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
        require_job(request.reference().job_id()).map_err(|error| {
            // Only Job-owner existence and availability classifications cross
            // this boundary; all corruption/refusal details remain local.
            match error.code.as_str() {
                "notFound" | "resourceNotFound" => {
                    failure("resourceNotFound", "Artifact Job owner does not exist")
                }
                "operationUnavailable" => {
                    failure("operationUnavailable", "Artifact Job owner is unavailable")
                }
                _ => failure("recordUnreadable", "Artifact Job owner is unreadable"),
            }
        })?;
        match request {
            ResourceRequest::Read(request) => self.read_wire(&request).map_err(map_error),
            ResourceRequest::Inspect(reference) => self.inspect_wire(&reference).map_err(map_error),
            ResourceRequest::Export(request) => self.export_wire(&request),
        }
    }
}
