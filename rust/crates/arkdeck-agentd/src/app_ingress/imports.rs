//! The Import upload requests the App sends (ClientKit
//! `RuntimeAppArtifactUpload`): their exact closed shapes, and the two kinds
//! the Debug workspace uploads. Identity, bounds, Target binding, generation
//! and App ownership stay with the Import owner, which only App frames reach
//! as App-owned (`Control::handle_app_frame`).
use super::canonical_decimal;
use arkdeck_contract::{ImportIntent, Request, validate_method_value};
use serde_json::{Map, Value};

pub(super) const METHODS: [&str; 4] = [
    "artifact.import.begin",
    "artifact.import.append",
    "artifact.import.abort",
    "artifact.import.commit",
];

pub(super) fn closed(method: &str, params: &Map<String, Value>) -> bool {
    let exact = |keys: &[&str]| {
        params.len() == keys.len() && keys.iter().all(|key| params.contains_key(*key))
    };
    let strings = |keys: &[&str]| {
        keys.iter()
            .all(|key| params.get(*key).is_some_and(Value::is_string))
    };
    let count = |key: &str, minimum: i64| canonical_decimal(params.get(key), minimum);
    let shape = match method {
        "artifact.import.begin" => {
            exact(&[
                "schemaVersion",
                "importRequestId",
                "kind",
                "targetId",
                "bindingRevision",
                "deviceProfile",
                "name",
                "byteCount",
                "sha256",
            ]) && strings(&[
                "schemaVersion",
                "importRequestId",
                "kind",
                "targetId",
                "name",
                "sha256",
            ]) && (params["deviceProfile"].is_null() || params["deviceProfile"].is_string())
                && count("bindingRevision", 1)
                && count("byteCount", 1)
        }
        "artifact.import.append" => {
            exact(&[
                "importId",
                "generation",
                "offset",
                "byteCount",
                "sha256",
                "base64",
            ]) && strings(&["importId", "sha256", "base64"])
                && count("generation", 1)
                && count("offset", 0)
                && count("byteCount", 1)
        }
        "artifact.import.abort" => {
            exact(&["importRequestId", "generation"])
                && strings(&["importRequestId"])
                && count("generation", 1)
        }
        "artifact.import.commit" => {
            exact(&["importId", "generation"]) && strings(&["importId"]) && count("generation", 1)
        }
        _ => false,
    };
    shape && validate_method_value(method, "request", &Value::Object(params.clone())).is_ok()
}

/// Swift's App transport (`AgentXPCListener.admission`): a begin is admitted
/// only when its metadata is a complete, valid Import intent of one of the
/// App's uploads, a HAP, a native library or a Flash bundle. Any other is
/// refused at the door, before the owner.
pub(super) fn admitted_begin(request: &Request) -> bool {
    let Some(params) = request.params.as_ref() else {
        return false;
    };
    ImportIntent::from_wire(params).is_ok_and(|intent| {
        matches!(
            intent.kind.as_str(),
            "hap" | "native-library" | "flash-bundle"
        )
    })
}
