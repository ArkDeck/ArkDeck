//! Local update lifecycle shared with the Swift App through its existing
//! container, record format and flock leases. Device Runtime is uninvolved.
mod model;
pub use model::*;
#[cfg(target_os = "macos")]
mod store;
#[cfg(target_os = "macos")]
pub use store::{Store, StoreError};
#[cfg(target_os = "macos")]
mod cache;
#[cfg(target_os = "macos")]
mod owner;
#[cfg(target_os = "macos")]
pub use cache::Cache;
#[cfg(target_os = "macos")]
pub use owner::Owner;

use crate::{
    CliError, Invocation,
    registry_parse::{self, Accepted},
};
use serde_json::Value;
#[cfg(target_os = "macos")]
use serde_json::json;

pub fn serves(command: &str) -> bool {
    matches!(
        command,
        "runtime.update.status" | "runtime.update.cancel" | "runtime.update.cleanup"
    )
}

/// The durable snapshot keeps UInt64 generations, while Swift's machine
/// envelope refuses integers beyond its exact-number contract. Preserve that
/// refusal rather than truncating the record or silently emitting no stdout.
pub fn render_document(value: &Value) -> Vec<u8> {
    fn wide_integer(value: &Value) -> Option<u64> {
        match value {
            Value::Number(number) => number.as_u64().filter(|n| *n > 9_007_199_254_740_991),
            Value::Object(fields) => fields.values().find_map(wide_integer),
            Value::Array(items) => items.iter().find_map(wide_integer),
            _ => None,
        }
    }
    crate::render(value).unwrap_or_else(|_| {
        let reason = wide_integer(value).map_or_else(
            || "the result could not be encoded".to_owned(),
            |number| format!("the result carries {number}, which no JSON number can hold exactly"),
        );
        let reason = serde_json::to_string(&reason).expect("string is JSON encodable");
        format!("{{\"schemaVersion\":\"arkdeck.cli.result/1\",\"command\":\"registry.parse\",\"ok\":false,\"error\":{{\"code\":\"internalError\",\"message\":{reason}}}}}\n").into_bytes()
    })
}

pub(crate) fn answer(argv: &[String]) -> Option<Result<Invocation, CliError>> {
    let command = registry_parse::leaf(argv).filter(|command| serves(command))?;
    let help = match registry_parse::check(argv) {
        Err(error) => return Some(Err(error)),
        Ok(Some(Accepted::LeafHelp(_))) => true,
        Ok(Some(Accepted::Dispatch { .. })) => false,
        _ => {
            return Some(Err(CliError::new(
                "internalError",
                "update leaf resolved to no answer",
            )));
        }
    };
    let value = |flag| {
        argv.iter()
            .position(|token| token == flag)
            .and_then(|index| argv.get(index + 1))
            .cloned()
    };
    let mode = value("--output");
    Some(Ok(Invocation {
        command,
        method: command,
        params: None,
        json: mode.as_deref() == Some("json"),
        jsonl: mode.as_deref() == Some("jsonl"),
        legacy_json: argv.iter().any(|token| token == "--json"),
        raw: false,
        help,
        require_healthy: false,
        control_request_id: value("--control-request-id"),
        socket: None,
        timeout_ms: None,
    }))
}

pub fn run(invocation: &Invocation) -> Result<Value, CliError> {
    #[cfg(not(target_os = "macos"))]
    {
        let _ = invocation;
        Err(CliError::new(
            "unsupportedOnPlatform",
            "the update subsystem is macOS-only",
        ))
    }
    #[cfg(target_os = "macos")]
    {
        let phase = invocation.command.rsplit('.').next().unwrap_or("update");
        let home = arkdeck_platform::runtime_home()
            .ok_or_else(|| failure(StoreError::UnsafeDirectory, phase))?;
        let library =
            std::path::Path::new(&home).join("Library/Containers/com.arkdeck.desktop/Data/Library");
        let owner = Owner {
            store: Store::new(library.join("Application Support/ArkDeck/AutoUpdateLifecycle")),
            cache: Cache::new(library.join("Caches/ArkDeck-Updates")),
        };
        let now = crate::utc_now();
        let result = match phase {
            "status" => owner.status(&now).map(|snapshot| snapshot.projection()),
            "cancel" => owner.cancel(&now).map(|snapshot| snapshot.projection()),
            "cleanup" => owner.cleanup(&now).map(|(snapshot, removed)| {
                json!({
                "schemaVersion":"arkdeck.runtime-update-cleanup/1",
                "removedVerifiedArtifactCount":removed,"status":snapshot.projection()})
            }),
            _ => {
                return Err(CliError::new(
                    "internalError",
                    "update leaf resolved to no handler",
                ));
            }
        };
        result.map_err(|error| failure(error, phase))
    }
}

#[cfg(target_os = "macos")]
fn failure(error: StoreError, phase: &str) -> CliError {
    let (code, message) = match error {
        StoreError::CacheUnavailable => ("ioFailure", "the owner-only update cache is unavailable"),
        StoreError::OperationInProgress => (
            "resourceConflict",
            "another process owns the active update operation",
        ),
        StoreError::ResourceConflict => (
            "resourceConflict",
            "the durable update lifecycle changed during this request",
        ),
        StoreError::RecordUnreadable => (
            "recordUnreadable",
            "the durable update lifecycle record is not trustworthy",
        ),
        StoreError::UnsafeDirectory | StoreError::WriteFailed => (
            "ioFailure",
            "the owner-only update lifecycle store is unavailable",
        ),
    };
    let mut error = CliError::new(code, message);
    error.details.insert("phase".into(), json!(phase));
    error
}
