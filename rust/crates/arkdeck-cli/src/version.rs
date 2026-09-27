//! Local build identity and pinned contract versions (Swift CLI §12).
use crate::{
    CLI_VERSION, CliError, Invocation, command_registry, error_registry,
    machine_contracts as contracts,
    registry_parse::{self, Accepted},
};
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{self, Read},
};

pub fn is_root_request(argv: &[String]) -> bool {
    argv.iter().any(|token| token == "--version") && registry_parse::leaf(argv).is_none()
}

pub(crate) fn answer(argv: &[String]) -> Option<Result<Invocation, CliError>> {
    if !argv.iter().any(|token| token == "--version") {
        return None;
    }
    // Existing leaf routes keep their accepted leading connection options and
    // their own refusal ordering. A leaf-owned --version value (feed prepare)
    // is Dispatch, never the global version entry.
    let names_leaf = registry_parse::leaf(argv).is_some();
    let checked = if names_leaf {
        registry_parse::check(argv)
    } else {
        registry_parse::check_exact(argv)
    };
    match checked {
        Ok(Some(Accepted::Version(mode))) => Some(Ok(invocation("version", mode == "json", false))),
        Ok(Some(Accepted::LeafHelp(command))) => Some(Ok(invocation(command, false, true))),
        Err(error) if !names_leaf => Some(Err(error)),
        _ => None,
    }
}

fn invocation(command: &'static str, json: bool, help: bool) -> Invocation {
    Invocation {
        command,
        method: "",
        params: None,
        json,
        jsonl: false,
        raw: false,
        legacy_json: false,
        help,
        require_healthy: false,
        control_request_id: None,
        socket: None,
        timeout_ms: None,
    }
}

/// Hash the executable being run, including its signature, with bounded memory.
/// As in Swift, an unreadable executable has no build identity.
fn build_identity() -> io::Result<String> {
    let mut file = File::open(std::env::current_exe()?)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; 1 << 20];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("sha256:{:x}", hasher.finalize()))
}

const COMPONENTS: [(&str, &str); 6] = [
    ("resultSchemaVersion", contracts::RESULT_SCHEMA_VERSION),
    ("pageSchemaVersion", contracts::PAGE_SCHEMA_VERSION),
    ("eventSchemaVersion", contracts::EVENT_SCHEMA_VERSION),
    (
        "nextActionSchemaVersion",
        contracts::NEXT_ACTION_SCHEMA_VERSION,
    ),
    ("errorRegistryVersion", error_registry::VERSION),
    ("canonicalJsonVersion", contracts::CANONICAL_JSON_VERSION),
];

pub fn result() -> Value {
    let mut result = json!({
        "cliProductVersion": CLI_VERSION,
        "commandRegistrySchemaVersion": command_registry::projection()["commandRegistrySchemaVersion"],
        "controlProtocolVersion": PROTOCOL_VERSION,
        "controlContractIdentity": CONTRACT_IDENTITY,
        "machineContractVersion": contracts::BUNDLE_VERSION,
        "buildIdentity": build_identity().ok(),
    });
    for (key, value) in COMPONENTS {
        result[key] = json!(value);
    }
    result
}

pub fn human(result: &Value) -> String {
    let mut lines = vec![format!("arkdeck {CLI_VERSION}")];
    for (label, key) in [
        ("  command registry schema", "commandRegistrySchemaVersion"),
        ("  control protocol", "controlProtocolVersion"),
        ("  control contract identity", "controlContractIdentity"),
        ("  machine contract", "machineContractVersion"),
    ] {
        lines.push(format!(
            "{label:<34}{}",
            result[key].as_str().unwrap_or_default()
        ));
    }
    for (key, value) in COMPONENTS {
        lines.push(format!("{:<34}{value}", format!("    {key}")));
    }
    lines.push(format!(
        "{:<34}{}",
        "  build identity",
        result["buildIdentity"].as_str().unwrap_or("unavailable")
    ));
    lines.join("\n")
}
