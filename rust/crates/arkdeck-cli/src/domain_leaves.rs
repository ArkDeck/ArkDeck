//! The domain leaves (`arkdeck <domain> <verb>`, CLI spec §6.2): Swift's
//! `RuntimeCLI.runDomainOperation`, `agentExecutionRequest` and
//! `emitAgentOutcome`. Each leaf names one published Catalog operation in the
//! registry; the leaf builds the typed request from the caller's options and
//! hands it to the client-side executor (`domain_executor`), which composes
//! the Runtime requests. A leaf never reaches a device any other way.
//!
//! `--capability` names a Runtime capability the Runtime already holds; it is
//! forwarded as the reference and never built here.
use crate::domain_executor::{
    ClientFailure, ExecutionRequest, Executor, ExecutorError, Outcome, Runtime,
};
use crate::{CliError, Invocation, command_registry};
use arkdeck_client::Client;
use arkdeck_platform::{LocalConnection, LocalEndpoint, ServerIdentity};
use serde_json::{Map, Number, Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The domain leaves this CLI serves: every leaf Swift routes through
/// `runDomainOperation` without a capture preset, each over the registry's
/// `catalogOperation`.
pub const SERVED: &[&str] = &[
    "workspace.status",
    "workspace.diff",
    "workspace.inspect",
    "workspace.read",
    "analyze.trace",
    "analyze.trace-summary",
    "analyze.hilog-summary",
    "analyze.crash-signature",
    "target.observe",
    "input.tap",
    "input.long-press",
    "input.swipe",
    "port-forward.create",
    "port-forward.remove",
    "screen.record",
    "diagnostics.capture",
    "workspace.isolate",
    "workspace.checkpoint",
    "workspace.patch",
    "workspace.revert",
    "workspace.build",
    "workspace.test",
    "workspace.sign",
    "workspace.symbolize",
    "workspace.sweep",
    "debug.hap",
    "debug.template.run",
    "debug.native.deploy",
];

/// Whether `command` is a served domain leaf.
pub fn serves(command: &str) -> bool {
    SERVED.contains(&command)
}

/// The Catalog operation the registry declares for the leaf.
fn operation(command: &str) -> Option<&'static str> {
    command_registry::projection()["commands"]
        .as_array()?
        .iter()
        .find(|entry| entry["command"] == command)?["catalogOperation"]
        .as_str()
}

/// A failure Swift's handler throws as its plain `CLIError`, or that escapes
/// it as another error: a diagnostic on stderr and the exit status, never a
/// document, in any output mode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plain {
    pub exit_code: u8,
    pub message: String,
}

/// How one domain leaf ends, as `emitAgentOutcome` and Swift's `dispatch`
/// render it.
#[derive(Debug)]
pub enum Answer {
    /// The receipt of a completed run.
    Completed(Value),
    /// A terminal failed run: its receipt is still the machine answer (§8.2),
    /// then `reason` on stderr and exit 1. The human rendering emits no
    /// document.
    Failed {
        reason: String,
        receipt: Value,
    },
    /// A refusal with Swift's code and details (`session.fail`,
    /// `session.stamped`): the failure envelope. A person's pause is one,
    /// with `humanActionRequired`, and `progress` is what the human rendering
    /// writes to stderr before it.
    Refused {
        error: CliError,
        progress: Option<String>,
    },
    Plain(Plain),
}

/// Swift `agentExecutionRequest(reference:rest:)` for the leaf's declared
/// operation and the caller's options.
pub fn execution_request(invocation: &Invocation) -> Result<ExecutionRequest, Plain> {
    let usage = |message: String| Plain {
        exit_code: 64,
        message,
    };
    let reference = operation(invocation.command).ok_or_else(|| Plain {
        exit_code: CliError::new("blockedByProductDefect", "").exit_code(),
        message: format!(
            "`{}` declares no Catalog operation; use `arkdeck agent run --operation <reference>` \
             until it does",
            invocation.command.replace('.', " ")
        ),
    })?;
    let (operation_id, version) = match reference.split_once('@') {
        Some((id, version)) => (
            id,
            Some(
                version
                    .parse::<i64>()
                    .ok()
                    .filter(|version| *version > 0)
                    .ok_or_else(|| usage("invalid operation version".into()))?,
            ),
        ),
        None => (reference, None),
    };
    let empty = Map::new();
    let options = invocation.params.as_ref().unwrap_or(&empty);
    let text = |key: &str| options.get(key).and_then(Value::as_str).map(str::to_owned);
    let inputs = match text("inputsFile") {
        None => Map::new(),
        Some(path) => typed_inputs(Path::new(&path))
            .ok_or_else(|| usage(format!("cannot read typed inputs from {}", shown(&path))))?,
    };
    let execution_id = match text("executionId") {
        Some(id) => id,
        None => crate::job_plan::uuid().map_err(|error| Plain {
            exit_code: 1,
            message: error.message,
        })?,
    };
    Ok(ExecutionRequest {
        operation_id: operation_id.to_owned(),
        operation_version: version,
        inputs,
        capability: text("capabilityId"),
        target: text("targetId"),
        // Swift `RuntimeAgentExecutionRequest`'s default.
        maximum_wait_seconds: 900,
        execution_id,
    })
}

/// The path as Swift's `URL(filePath:).path` prints it: a relative path
/// against the working directory.
fn shown(path: &str) -> String {
    let path = Path::new(path);
    if path.is_absolute() {
        return path.display().to_string();
    }
    std::env::current_dir()
        .map(|directory| directory.join(path).display().to_string())
        .unwrap_or_else(|_| path.display().to_string())
}

/// Swift `JSONDecoder().decode([String: JSONValue].self, from:)`: one JSON
/// object, each number read as Swift's `JSONValue` reads it.
fn typed_inputs(path: &Path) -> Option<Map<String, Value>> {
    let bytes = std::fs::read(path).ok()?;
    match serde_json::from_slice::<Value>(&bytes).ok()? {
        Value::Object(fields) => Some(
            fields
                .into_iter()
                .map(|(key, value)| (key, swift_value(value)))
                .collect(),
        ),
        _ => None,
    }
}

/// Swift `JSONValue(from:)` tries `Int64`, then `UInt64`, then `Double`, so a
/// number with an exact integral value is an integer whatever its spelling
/// (`1.0`, `1e2`), and it is re-encoded as one.
fn swift_value(value: Value) -> Value {
    match value {
        Value::Number(number) if number.is_f64() => {
            let float = number.as_f64().unwrap_or(f64::NAN);
            if float.fract() == 0.0 && float >= -(2f64.powi(63)) && float < 2f64.powi(63) {
                Value::Number(Number::from(float as i64))
            } else if float.fract() == 0.0 && float >= 0.0 && float < 2f64.powi(64) {
                Value::Number(Number::from(float as u64))
            } else {
                Value::Number(number)
            }
        }
        Value::Array(values) => Value::Array(values.into_iter().map(swift_value).collect()),
        Value::Object(fields) => Value::Object(
            fields
                .into_iter()
                .map(|(key, value)| (key, swift_value(value)))
                .collect(),
        ),
        other => other,
    }
}

/// The local Runtime, one authenticated connection per request, as Swift's
/// `AgentClient` opens one per exchange.
pub struct LocalRuntime<'a> {
    pub endpoint: &'a LocalEndpoint,
    pub identity: &'a ServerIdentity,
}

impl Runtime for LocalRuntime<'_> {
    type Stream = LocalConnection;

    fn connect(&mut self, remaining: Duration) -> Result<Client<LocalConnection>, ClientFailure> {
        Client::connect(self.endpoint, self.identity, remaining).map_err(ClientFailure::connect)
    }
}

/// Swift `AgentRuntimeExecutor`'s default state directory: `agent-runtime`
/// beside the Runtime's socket, where a paused run's pending record is kept.
pub fn state_directory(endpoint: &LocalEndpoint) -> PathBuf {
    endpoint
        .as_path()
        .parent()
        .unwrap_or_else(|| Path::new(""))
        .join("agent-runtime")
}

/// `runDomainOperation` after the request is built: the executor's run and
/// how Swift renders its end.
pub fn run<R: Runtime>(request: &ExecutionRequest, runtime: R, state_directory: PathBuf) -> Answer {
    let mut executor = Executor::new(runtime, crate::utc_now, state_directory);
    match executor.run(request) {
        Ok(Outcome::Completed(receipt)) => Answer::Completed(receipt),
        Ok(Outcome::Failed { reason, receipt }) => Answer::Failed { reason, receipt },
        Ok(Outcome::Paused { action, receipt }) => paused(&action, &receipt),
        // Swift maps every client error the executor throws as `job.submit`'s.
        Err(ExecutorError::Client(failure)) => Answer::Refused {
            error: failure.cli_error(),
            progress: None,
        },
        // Anything else escapes the handler: Swift's `dispatch` prints it and
        // exits 1.
        Err(error) => Answer::Plain(Plain {
            exit_code: 1,
            message: error.description(),
        }),
    }
}

/// Swift `emitAgentOutcome`'s pause: `humanActionRequired` with the action's
/// kind, prompt, resume token, selection options and Job in its details, and
/// in the human rendering the action and how to resume it.
fn paused(action: &Value, receipt: &Value) -> Answer {
    let text = |key: &str| action[key].as_str().unwrap_or_default().to_owned();
    let mut error = CliError::new("humanActionRequired", "paused for physical assistance");
    error.details = Map::from_iter([
        ("kind".to_owned(), json!(text("kind"))),
        ("prompt".to_owned(), json!(text("prompt"))),
        ("resumeToken".to_owned(), json!(text("resumeToken"))),
    ]);
    let options: Option<Vec<&str>> = action["selectionOptions"]
        .as_array()
        .map(|options| options.iter().filter_map(Value::as_str).collect());
    if let Some(options) = &options {
        error
            .details
            .insert("selectionOptions".into(), json!(options));
    }
    if let Some(job) = receipt["jobID"].as_str() {
        error.details.insert("jobId".into(), json!(job));
    }
    let progress = format!(
        "human action required ({}): {}\n{}resume with: arkdeck agent resume --resume-token {}",
        text("kind"),
        text("prompt"),
        options
            .map(|options| format!("selection options: {}\n", options.join(", ")))
            .unwrap_or_default(),
        text("resumeToken")
    );
    Answer::Refused {
        error,
        progress: Some(progress),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_are_read_as_swifts_json_value_reads_them() {
        let value: Value =
            serde_json::from_str(r#"{"a":1.0,"b":1e2,"c":1.5,"d":-0.0,"e":[-2.0,{"f":3.25}]}"#)
                .unwrap();
        assert_eq!(
            serde_json::to_string(&swift_value(value)).unwrap(),
            r#"{"a":1,"b":100,"c":1.5,"d":0,"e":[-2,{"f":3.25}]}"#
        );
    }

    /// A pause names its Job when it has one, and its selection options when
    /// the action offers a choice.
    #[test]
    fn a_pause_carries_its_action_and_job_in_its_details() {
        let action = json!({"kind": "selectTarget", "prompt": "Pick one.",
            "resumeToken": "resume-1", "selectionOptions": ["A", "B"],
            "raisedAtUTC": "2026-09-26T00:00:00Z"});
        let Answer::Refused { error, progress } = paused(
            &action,
            &json!({"jobID": "job-1", "terminalState": "awaitingHumanAction"}),
        ) else {
            panic!("a pause is a refusal");
        };
        assert_eq!((error.code, error.exit_code()), ("humanActionRequired", 75));
        assert_eq!(
            Value::Object(error.details),
            json!({"kind": "selectTarget", "prompt": "Pick one.", "resumeToken": "resume-1",
                "selectionOptions": ["A", "B"], "jobId": "job-1"})
        );
        assert_eq!(
            progress.unwrap(),
            "human action required (selectTarget): Pick one.\nselection options: A, B\n\
             resume with: arkdeck agent resume --resume-token resume-1"
        );
    }

    #[test]
    fn every_served_leaf_names_its_catalog_operation() {
        for command in SERVED {
            assert!(operation(command).is_some(), "{command}");
        }
    }
}
