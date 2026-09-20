//! `arkdeck commands`: the machine discovery entry (CLI spec §10), answered as
//! Swift's `CLIRegistryProjection` answers it, for the leaves this CLI serves.
//!
//! `command_registry.json` is Swift's projection of its whole registry — the
//! `commands` of the published `openspec/contracts/cli-command-registry.yaml`
//! — and `CLIRustCommandRegistryCopyContractTests` holds it to that
//! projection. A leaf is listed exactly when this parser serves its path, so
//! the answer never names a command this CLI would refuse as unknown, and each
//! listed entry is Swift's own entry for that leaf, in the registry's order.
use crate::{CliError, Invocation, parse};
use serde_json::{Map, Value, json};

const REGISTRY: &str = include_str!("command_registry.json");

/// The registry's leaves that are not executable — Swift's tombstones and
/// refused stubs — by path. The parser answers them by name.
pub(crate) const NOT_EXECUTABLE: &[(&[&str], &str)] = &[
    (&["agent", "chat"], "agent.chat"),
    (&["capability", "draft"], "capability.draft"),
    (&["capability", "install"], "capability.install"),
    (&["capability", "revoke"], "capability.revoke"),
    (&["flash", "plan"], "flash.plan"),
    (&["flash", "preview"], "flash.preview"),
    (&["flash", "execute"], "flash.execute"),
    (&["flash", "continue"], "flash.continue"),
    (&["flash", "postflight"], "flash.postflight"),
];

/// Swift `CLIArgumentParser.parseLeaf` for a leaf that is not executable: it
/// answers by name before any of its flags is judged, so a caller typing a
/// retired command with its retired flags learns the command is gone rather
/// than which flag is unknown. Help is still the leaf's own, and help in a
/// machine mode is refused. `None` when `argv` names no such leaf.
pub(crate) fn answer_by_name(argv: &[String]) -> Option<Result<Invocation, CliError>> {
    let mut tokens = Vec::new();
    let mut index = 0;
    while index < argv.len() {
        let token = argv[index].as_str();
        if matches!(
            token,
            "--output" | "--control-request-id" | "--socket" | "--endpoint"
        ) {
            index += 2;
            continue;
        }
        if !token.starts_with('-') {
            tokens.push(token);
        }
        index += 1;
    }
    let &(_, command) = NOT_EXECUTABLE
        .iter()
        .find(|(path, _)| tokens.starts_with(path))?;
    if argv.iter().any(|token| token == "--help" || token == "-h") {
        if argv.iter().any(|token| token == "--output") {
            return Some(Err(CliError::new(
                "invalidOption",
                "help renders human text only",
            )));
        }
        return Some(Ok(Invocation {
            command,
            method: command,
            params: None,
            json: false,
            raw: false,
            help: true,
            require_healthy: false,
            control_request_id: None,
            socket: None,
            timeout_ms: None,
        }));
    }
    Some(Err(refusal(command)))
}

/// Swift's refusal of a leaf that is not executable, from its registry entry:
/// a tombstone is `commandRemoved` with its lifecycle facts (`removedError`),
/// a refused stub `invalidCommand`; either names the leaf.
fn refusal(command: &'static str) -> CliError {
    let registry: Value = serde_json::from_str(REGISTRY).expect("the checked-in command registry");
    let entry = registry["commands"]
        .as_array()
        .and_then(|entries| entries.iter().find(|entry| entry["command"] == command))
        .expect("every leaf that is not executable is a registry entry");
    let path = entry["path"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>()
        .join(" ");
    let mut error = if entry["kind"] == "tombstone" {
        let replacement = entry["replacementArgvPattern"].as_str();
        let mut details = Map::from_iter([
            ("command".to_owned(), json!(command)),
            ("lifecycleStatus".to_owned(), json!("removed")),
            ("replacementArgvPattern".to_owned(), json!(replacement)),
            ("removalVersion".to_owned(), entry["removalVersion"].clone()),
        ]);
        let sentence = match replacement {
            Some(pattern) => format!("use `{pattern}`"),
            None => {
                let reason = entry["replacementReason"]
                    .as_str()
                    .unwrap_or("nothing replaces it");
                details.insert("reason".to_owned(), json!(reason));
                reason.to_owned()
            }
        };
        let mut error = CliError::new("commandRemoved", format!("`{path}` is retired: {sentence}"));
        error.details = details;
        error
    } else {
        let reason = entry["refusalReason"].as_str().unwrap_or_default();
        let mut error = CliError::new(
            "invalidCommand",
            format!("`{path}` is not caller-facing: {reason}"),
        );
        error.details = Map::from_iter([("command".to_owned(), json!(command))]);
        error
    };
    error.command = Some(command);
    error
}

/// A registry entry's leaf is served when its path, asking for help, parses
/// as that leaf.
fn serves(entry: &Value) -> bool {
    let Some(path) = entry["path"].as_array() else {
        return false;
    };
    let mut argv: Vec<String> = path
        .iter()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    argv.push("--help".into());
    parse(&argv).is_ok_and(|invocation| entry["command"] == invocation.command)
}

/// `{commandRegistrySchemaVersion, commands}` over the served leaves.
pub fn command_registry() -> Value {
    let registry: Value = serde_json::from_str(REGISTRY).expect("the checked-in command registry");
    let commands: Vec<Value> = registry["commands"]
        .as_array()
        .expect("the registry's commands")
        .iter()
        .filter(|entry| serves(entry))
        .cloned()
        .collect();
    json!({
        "commandRegistrySchemaVersion": registry["commandRegistrySchemaVersion"],
        "commands": commands,
    })
}

/// Swift's human projection: one line per leaf, its path.
pub fn command_registry_human(registry: &Value) -> String {
    registry["commands"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|entry| {
            entry["path"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect::<Vec<_>>()
        .join("\n")
}
