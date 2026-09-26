//! The Runtime storage requests the App's Settings page sends
//! (`SettingsApplicationFacade`): exactly the shapes Swift's App transport
//! admits, and no other. Generation CAS, quota relationships and the new
//! root's filesystem admission stay with the storage owner.
use super::canonical_decimal;
use arkdeck_contract::Request;
use serde_json::Value;

pub(super) const METHODS: [&str; 3] = [
    "runtime.storage.status",
    "runtime.storage.policy",
    "runtime.storage.root",
];

/// Swift `AgentXPCEndpoint.admission` (`AgentXPCListener.swift:184–191`)
/// and `runtimeStorageParamsAreClosed` (`:248–279`). Anything else is
/// refused at the door.
pub(super) fn admitted(request: &Request) -> bool {
    let Some(fields) = request.params.as_ref() else {
        // `:184–186`: the status alone takes no parameters; the other two
        // have none to close (`:251`).
        return request.method == "runtime.storage.status";
    };
    let exactly = |keys: &[&str]| {
        fields.len() == keys.len() && keys.iter().all(|key| fields.contains_key(*key))
    };
    // `:252–258`: a decimal string of at least 1 within Int64, without a
    // sign or a leading zero.
    let positive = |key: &str| canonical_decimal(fields.get(key), 1);
    match request.method.as_str() {
        "runtime.storage.status" => fields.is_empty(),
        // `:260–265`
        "runtime.storage.policy" => {
            let keys = [
                "expectedGeneration",
                "totalQuotaBytes",
                "safetyMarginBytes",
                "retentionDays",
            ];
            exactly(&keys) && keys.iter().all(|key| positive(key))
        }
        // `:266–275`: an absolute path of at most 4 KiB of UTF-8 with no
        // white space or newline at either end, or the default again.
        "runtime.storage.root" => {
            if !positive("expectedGeneration") {
                false
            } else if exactly(&["expectedGeneration", "rootPath"]) {
                fields["rootPath"].as_str().is_some_and(|path| {
                    !path.is_empty()
                        && path.len() <= 4 * 1024
                        && path.trim() == path
                        && path.starts_with('/')
                })
            } else {
                exactly(&["expectedGeneration", "resetToDefault"])
                    && fields["resetToDefault"] == Value::Bool(true)
            }
        }
        _ => false,
    }
}
