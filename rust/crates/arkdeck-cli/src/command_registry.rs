//! `arkdeck commands`: the machine discovery entry (CLI spec §10), answered as
//! Swift's `CLIRegistryProjection` answers it, for the leaves this CLI serves.
//!
//! `command_registry.json` is Swift's projection of its whole registry — the
//! `commands` of the published `openspec/contracts/cli-command-registry.yaml`
//! — and `CLIRustCommandRegistryCopyContractTests` holds it to that
//! projection. A leaf is listed exactly when this parser serves its path, so
//! the answer never names a command this CLI would refuse as unknown, and each
//! listed entry is Swift's own entry for that leaf, in the registry's order.
use crate::parse;
use serde_json::{Value, json};

const REGISTRY: &str = include_str!("command_registry.json");

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
