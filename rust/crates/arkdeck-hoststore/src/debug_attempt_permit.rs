//! Swift `RuntimeDebugAttemptPermitStore` (`RuntimeDebugInvocation.swift`):
//! the durable, per-attempt provenance the protected Flash recovery broker
//! writes before it hands the Runtime the exact request of one destructive
//! attempt, and the planner reads back while it materializes that request.
//!
//! The record is not an authority. It cannot mint a capability or bypass
//! admission: the request is admitted, its capability issued, reserved and
//! consumed by the ordinary Job path. What it does is pin the broker's
//! candidate action into the authorized plan (`runtimeDebugInvocationID`,
//! `runtimeDebugCandidateActionSHA256`), and refuse a plan for a request
//! whose record exists but no longer matches it, or whose invocation no longer
//! holds an active, in-budget dispatch permit for it.
//!
//! One record per attempt, `<state>/runtime-debug-attempts/<idempotencyKey>.json`,
//! in the one current layout (`schemaVersion` `1.0.0`), canonical JSON.
use crate::operation_request::OperationRequest;
use serde_json::{Value, json};
use std::path::Path;

const DIRECTORY: &str = "runtime-debug-attempts";
const SCHEMA_VERSION: &str = "1.0.0";
const KEYS: [&str; 5] = [
    "schemaVersion",
    "invocationID",
    "idempotencyKey",
    "requestFingerprintSHA256",
    "candidateActionSHA256",
];
const MAXIMUM_RECORD_BYTES: usize = 64 * 1_024;

/// Swift `RuntimeDebugAttemptPermitRecord`, the two members a plan pins.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AttemptPermit {
    pub(crate) invocation_id: String,
    pub(crate) candidate_action_sha256: String,
}

/// The request as the record fingerprints it: Swift rebuilds it from its
/// request id, idempotency key, target, operation, inputs and requested
/// outputs, so a capability the Runtime minted on admission, caller
/// provenance or a reviewed plan digest never reach the comparison.
fn unsigned(request: &OperationRequest) -> OperationRequest {
    let mut unsigned = request.clone();
    unsigned.capability_id = None;
    unsigned.client_context = None;
    unsigned.reviewed_plan_digest = None;
    unsigned
}

/// Swift `persist(stateDirectory:invocationID:request:candidateActionSHA256:)`:
/// the record created or atomically replaced in the private attempt directory.
pub(crate) fn persist(
    state: &Path,
    invocation_id: &str,
    request: &OperationRequest,
    candidate_action_sha256: &str,
) -> Result<(), String> {
    let record = json!({
        "schemaVersion": SCHEMA_VERSION,
        "invocationID": invocation_id,
        "idempotencyKey": request.idempotency_key,
        "requestFingerprintSHA256": unsigned(request).fingerprint(),
        "candidateActionSHA256": candidate_action_sha256,
    });
    let bytes = crate::session_json::encode(&record)
        .map_err(|_| "the attempt permit has no canonical encoding".to_owned())?;
    let directory = arkdeck_platform::HostDirectory::open_or_create_private(&state.join(DIRECTORY))
        .map_err(|error| format!("the attempt permit directory cannot be opened: {error}"))?;
    directory
        .replace_document(
            &format!("{}.json", request.idempotency_key),
            &bytes,
            MAXIMUM_RECORD_BYTES,
        )
        .map_err(|error| match error {
            arkdeck_platform::DocumentPublishError::BeforePublication(error)
            | arkdeck_platform::DocumentPublishError::OutcomeUnknown(error) => {
                format!("the attempt permit could not be written: {error}")
            }
        })
}

/// Swift `loadExact(stateDirectory:request:nowUTC:)`: `None` when the request
/// has no record; the record when it matches the request exactly and, with
/// `now`, its invocation still holds the active, in-budget dispatch permit it
/// was written for. `Err` is the `persistenceFailure` detail Swift throws,
/// which the planner reports as a typed preflight failure.
pub(crate) fn load_exact(
    state: &Path,
    request: &OperationRequest,
    now: Option<&str>,
) -> Result<Option<AttemptPermit>, &'static str> {
    let location = state
        .join(DIRECTORY)
        .join(format!("{}.json", request.idempotency_key));
    // Swift `FileManager.fileExists(atPath:)`, which follows a link.
    if std::fs::metadata(&location).is_err() {
        return Ok(None);
    }
    const NOT_CURRENT: &str = "Runtime debug attempt provenance is not the current permit record";
    let bytes = std::fs::read(&location).map_err(|_| NOT_CURRENT)?;
    let record = decode(&bytes).ok_or(NOT_CURRENT)?;
    if request.client_context.is_some() {
        return Err("Runtime debug attempt cannot gain campaign or client provenance");
    }
    if record["schemaVersion"] != SCHEMA_VERSION
        || record["idempotencyKey"] != request.idempotency_key.as_str()
        || record["requestFingerprintSHA256"] != unsigned(request).fingerprint().as_str()
    {
        return Err("Runtime debug attempt provenance does not match the typed request");
    }
    let permit = AttemptPermit {
        invocation_id: record["invocationID"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
        candidate_action_sha256: record["candidateActionSHA256"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
    };
    if let Some(now) = now {
        crate::flash_invocations::dispatch_permitted(
            state,
            &permit.invocation_id,
            &request.idempotency_key,
            &permit.candidate_action_sha256,
            now,
        )?;
    }
    Ok(Some(permit))
}

/// Swift `CurrentDurableJSON.decode(RuntimeDebugAttemptPermitRecord.self, …)`:
/// one object without a duplicate member, holding exactly the record's five
/// members, each a string.
fn decode(bytes: &[u8]) -> Option<Value> {
    crate::strict_json::validate(bytes).ok()?;
    let value: Value = serde_json::from_slice(bytes).ok()?;
    let object = value.as_object()?;
    (object.len() == KEYS.len()
        && KEYS
            .iter()
            .all(|key| object.get(*key).is_some_and(Value::is_string)))
    .then_some(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(idempotency_key: &str) -> OperationRequest {
        OperationRequest::decode(
            json!({
                "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
                "requestId": "debug-000000000001-e1", "idempotencyKey": idempotency_key,
                "target": {"targetId": "TGT-1", "expectedBindingRevision": 1},
                "operation": {"id": "flash.full-restore", "version": 1},
                "inputs": {"artifactLease": "lease", "deviceProfileRef": "dayu200",
                    "intent": "fullRestore", "verification": "full"},
                "requestedOutputs": ["derivedArtifacts"],
            })
            .to_string()
            .as_bytes(),
        )
        .unwrap()
    }

    fn state() -> std::path::PathBuf {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-debug-attempt-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::create_dir(&root).unwrap();
        root
    }

    #[test]
    fn a_request_without_a_record_has_no_permit() {
        let state = state();
        assert_eq!(
            load_exact(&state, &request("runtime-debug-a"), None),
            Ok(None)
        );
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn a_persisted_record_is_read_back_for_its_exact_request_only() {
        let state = state();
        let exact = request("runtime-debug-000000000001-e1-abcdefabcdef");
        persist(&state, "debug-invocation-1", &exact, &"a".repeat(64)).unwrap();
        let bytes = std::fs::read(
            state
                .join(DIRECTORY)
                .join("runtime-debug-000000000001-e1-abcdefabcdef.json"),
        )
        .unwrap();
        // Canonical: sorted members, no whitespace.
        assert!(
            bytes.starts_with(b"{\"candidateActionSHA256\":\""),
            "{bytes:?}"
        );
        let permit = AttemptPermit {
            invocation_id: "debug-invocation-1".into(),
            candidate_action_sha256: "a".repeat(64),
        };
        assert_eq!(load_exact(&state, &exact, None), Ok(Some(permit.clone())));
        // The capability the admission minted is not part of the comparison.
        let mut admitted = exact.clone();
        admitted.capability_id = Some("cap-1".into());
        assert_eq!(load_exact(&state, &admitted, None), Ok(Some(permit)));
        // Any candidate-controlled field is.
        let mut other = exact.clone();
        other.inputs.insert("verification".into(), json!("basic"));
        assert_eq!(
            load_exact(&state, &other, None),
            Err("Runtime debug attempt provenance does not match the typed request")
        );
        // Without an invocation still permitting the dispatch, a timed read
        // refuses.
        assert_eq!(
            load_exact(&state, &exact, Some("2026-09-28T00:00:00Z")),
            Err("Runtime debug attempt names an invocation that is not the current document")
        );
        std::fs::remove_dir_all(state).unwrap();
    }

    #[test]
    fn a_record_of_another_shape_is_refused() {
        let state = state();
        let exact = request("runtime-debug-shape");
        persist(&state, "debug-invocation-1", &exact, &"a".repeat(64)).unwrap();
        let path = state.join(DIRECTORY).join("runtime-debug-shape.json");
        let mut record: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        record["extra"] = json!("member");
        std::fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
        assert_eq!(
            load_exact(&state, &exact, None),
            Err("Runtime debug attempt provenance is not the current permit record")
        );
        std::fs::remove_dir_all(state).unwrap();
    }
}
