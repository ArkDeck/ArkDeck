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
            jsonl: false,
            raw: false,
            legacy_json: false,
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

/// The leaves this CLI serves, with their paths, in the registry's order.
fn served() -> Vec<Value> {
    command_registry()["commands"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn path_of(entry: &Value) -> Vec<&str> {
    entry["path"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect()
}

fn pad(text: &str, width: usize) -> String {
    format!(
        "{text:width$} ",
        width = width.saturating_sub(1).max(text.len())
    )
}

/// A leaf's lifecycle when the registry publishes it as a compatibility
/// surface, legacy or deprecated: its status and the argv pattern that
/// replaces it, if one does. A removed leaf answers by name with its own
/// lifecycle details instead (`answer_by_name`).
pub(crate) fn lifecycle(command: &str) -> Option<(String, Option<String>)> {
    let registry: Value = serde_json::from_str(REGISTRY).expect("the checked-in command registry");
    let entry = registry["commands"]
        .as_array()?
        .iter()
        .find(|entry| entry["command"] == command)?;
    let status = entry["lifecycleStatus"].as_str()?;
    matches!(status, "legacy" | "deprecated").then(|| {
        (
            status.to_owned(),
            entry["replacementArgvPattern"].as_str().map(str::to_owned),
        )
    })
}

/// Whether the registry declares `option` for the leaf `command`.
pub(crate) fn declares(command: &str, option: &str) -> bool {
    let registry: Value = serde_json::from_str(REGISTRY).expect("the checked-in command registry");
    registry["commands"]
        .as_array()
        .expect("the registry's commands")
        .iter()
        .find(|entry| entry["command"] == command)
        .and_then(|entry| entry["options"].as_array())
        .is_some_and(|options| options.iter().any(|entry| entry["name"] == option))
}

/// The output modes one leaf publishes, as the registry declares them. A leaf
/// the registry does not name takes the two every Runtime leaf takes.
pub fn output_modes(command: &str) -> Vec<String> {
    let registry: Value = serde_json::from_str(REGISTRY).expect("the checked-in command registry");
    registry["commands"]
        .as_array()
        .expect("the registry's commands")
        .iter()
        .find(|entry| entry["command"] == command)
        .and_then(|entry| entry["outputModes"].as_array())
        .map(|modes| {
            modes
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_else(|| vec!["human".to_owned(), "json".to_owned()])
}

/// Whether `path` names a node of the registry: some leaf's path begins with
/// it, but none is it. Read from the registry itself and not from the leaves
/// this CLI serves, because the served set is what `parse` is deciding when it
/// asks. Whether the node has anything to show is `help_text`'s answer.
pub fn is_node(path: &[&str]) -> bool {
    let registry: Value = serde_json::from_str(REGISTRY).expect("the checked-in command registry");
    let entries: Vec<Vec<&str>> = registry["commands"]
        .as_array()
        .expect("the registry's commands")
        .iter()
        .map(path_of)
        .collect();
    !entries.iter().any(|tokens| tokens == path)
        && entries
            .iter()
            .any(|tokens| tokens.len() > path.len() && tokens.starts_with(path))
}

/// Help for one command path, rendered from the registry as Swift's
/// `CLIHelpRenderer` renders it: the root, a node's subcommands, or a leaf's
/// usage, options and positionals. Unknown paths are refused by name.
pub fn help_text(path: &[String]) -> Result<String, CliError> {
    let entries = served();
    let path: Vec<&str> = path.iter().map(String::as_str).collect();
    if let Some(entry) = entries.iter().find(|entry| path_of(entry) == path) {
        return Ok(leaf_help(entry));
    }
    let children: Vec<&Value> = entries
        .iter()
        .filter(|entry| {
            let tokens = path_of(entry);
            tokens.len() > path.len() && tokens.starts_with(&path)
        })
        .collect();
    if children.is_empty() {
        return Err(CliError::new(
            "invalidCommand",
            format!("`arkdeck {}` is no command of this CLI", path.join(" ")),
        ));
    }
    let mut lines = Vec::new();
    if path.is_empty() {
        lines.push(format!(
            "arkdeck {} — headless product face of the Device Agent Runtime.",
            crate::CLI_VERSION
        ));
        lines.push("Decisions come from your own agent; ArkDeck executes.".into());
        lines.push(String::new());
        lines.push("usage: arkdeck <command> [subcommand] [options]".into());
        lines.push(String::new());
        lines.push("commands:".into());
    } else {
        lines.push(format!("arkdeck {} — its subcommands:", path.join(" ")));
        lines.push(String::new());
    }
    let mut seen = Vec::new();
    for entry in &children {
        let tokens = path_of(entry);
        let token = tokens[path.len()];
        if seen.contains(&token) {
            continue;
        }
        seen.push(token);
        let summary = if tokens.len() == path.len() + 1 {
            entry["summary"].as_str().unwrap_or_default().to_owned()
        } else {
            "…".to_owned()
        };
        lines.push(format!("  {}{summary}", pad(token, 26)));
    }
    lines.push(String::new());
    lines.push(format!(
        "`arkdeck help {}<subcommand>` describes one of them; `arkdeck commands --output json`",
        if path.is_empty() {
            String::new()
        } else {
            format!("{} ", path.join(" "))
        }
    ));
    lines.push("is the machine projection of this surface.".into());
    Ok(lines.join("\n"))
}

fn leaf_help(entry: &Value) -> String {
    let name = path_of(entry).join(" ");
    let mut lines = vec![format!(
        "arkdeck {name} — {}",
        entry["summary"].as_str().unwrap_or_default()
    )];
    if entry["kind"] == "tombstone" {
        lines.push(String::new());
        match entry["replacementArgvPattern"].as_str() {
            Some(pattern) => lines.push(format!("retired. use `{pattern}`.")),
            None => lines.push(format!(
                "retired. {}.",
                entry["replacementReason"]
                    .as_str()
                    .unwrap_or("nothing replaces it")
            )),
        }
        if let Some(version) = entry["removalVersion"].as_str() {
            lines.push(format!("removed in {version}."));
        }
        lines.push(
            "recognised so the old spelling gets a stable answer; it cannot dispatch.".into(),
        );
        return lines.join("\n");
    }
    if entry["kind"] == "refused" {
        lines.push(String::new());
        lines.push(format!(
            "not caller-facing: {}.",
            entry["refusalReason"].as_str().unwrap_or_default()
        ));
        return lines.join("\n");
    }
    let options: Vec<&Value> = entry["options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|option| option["published"] == true)
        .collect();
    let mut usage = format!("arkdeck {name}");
    for option in &options {
        let head = option["name"].as_str().unwrap_or_default().to_owned()
            + &option["placeholder"]
                .as_str()
                .map(|value| format!(" <{value}>"))
                .unwrap_or_default();
        usage += &if option["required"] == true {
            format!(" {head}")
        } else {
            format!(" [{head}]")
        };
    }
    for positional in entry["positionals"].as_array().into_iter().flatten() {
        usage += &format!(" <{}>", positional["name"].as_str().unwrap_or_default());
    }
    lines.push(String::new());
    lines.push(format!("usage: {usage}"));
    if !options.is_empty() {
        lines.push(String::new());
        lines.push("options:".into());
        for option in &options {
            let head = option["name"].as_str().unwrap_or_default().to_owned()
                + &option["placeholder"]
                    .as_str()
                    .map(|value| format!(" {value}"))
                    .unwrap_or_default();
            lines.push(format!(
                "  {}{}{}",
                pad(&head, 34),
                option["summary"].as_str().unwrap_or_default(),
                if option["required"] == true {
                    " (required)"
                } else {
                    ""
                }
            ));
        }
    }
    for positional in entry["positionals"].as_array().into_iter().flatten() {
        lines.push(String::new());
        lines.push(format!(
            "  {}{}",
            pad(
                &format!("<{}>", positional["name"].as_str().unwrap_or_default()),
                34
            ),
            positional["summary"].as_str().unwrap_or_default()
        ));
    }
    for group in ["requiresExactlyOneOf", "mutuallyExclusive"] {
        for row in entry[group].as_array().into_iter().flatten() {
            let names: Vec<&str> = row
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect();
            lines.push(String::new());
            lines.push(format!(
                "{}: {}",
                if group == "requiresExactlyOneOf" {
                    "exactly one of"
                } else {
                    "at most one of"
                },
                names.join(", ")
            ));
        }
    }
    let modes: Vec<&str> = entry["outputModes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    if !modes.is_empty() {
        lines.push(String::new());
        lines.push(format!("output modes: {}", modes.join(", ")));
    }
    if entry["connectsToRuntime"] == true {
        lines.push(String::new());
        lines.push("connects to the local Runtime; it verifies health before the request.".into());
    }
    if let Some(operation) = entry["catalogOperation"].as_str() {
        lines.push(format!(
            "submits `{operation}`; `arkdeck operation describe --operation {operation}` is the fact source for its inputs."
        ));
    }
    lines.join("\n")
}

/// What may follow one command prefix: the completion table Swift's
/// `CLICompletionScripts` builds from the same registry. Identities are never
/// completed (CLI spec §10); a leaf completes to its published options, its
/// enumerated positionals and `--help`.
fn completion_rows() -> Vec<(String, Vec<String>)> {
    let entries = served();
    let mut rows: Vec<(String, Vec<String>)> = Vec::new();
    let mut push = |key: String, token: String| match rows.iter_mut().find(|row| row.0 == key) {
        Some(row) => {
            if !row.1.contains(&token) {
                row.1.push(token);
            }
        }
        None => rows.push((key, vec![token])),
    };
    for entry in &entries {
        let tokens = path_of(entry);
        for index in 0..tokens.len() {
            push(tokens[..index].join(" "), tokens[index].to_owned());
        }
    }
    for entry in &entries {
        let mut next: Vec<String> = Vec::new();
        for positional in entry["positionals"].as_array().into_iter().flatten() {
            for value in positional["grammar"]["values"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
            {
                next.push(value.to_owned());
            }
        }
        for option in entry["options"].as_array().into_iter().flatten() {
            if option["published"] == true
                && let Some(name) = option["name"].as_str()
            {
                next.push(name.to_owned());
            }
        }
        next.push("--help".to_owned());
        rows.push((path_of(entry).join(" "), next));
    }
    rows
}

/// The completion script for one shell, or `None` for a shell the registry
/// does not publish.
pub fn completion_script(shell: &str) -> Option<String> {
    let rows = completion_rows();
    let version = "arkdeck.cli.command-registry/1";
    let mut lines: Vec<String> = Vec::new();
    match shell {
        "bash" => {
            lines.push(format!(
                "# arkdeck bash completion — generated from {version}"
            ));
            lines.push("# Identities are never completed: see the CLI product spec §10.".into());
            lines.push("_arkdeck() {".into());
            lines.push("  local cur prefix i".into());
            lines.push("  cur=\"${COMP_WORDS[COMP_CWORD]}\"".into());
            lines.push("  prefix=\"\"".into());
            lines.push("  for ((i=1; i<COMP_CWORD; i++)); do".into());
            lines.push("    case \"${COMP_WORDS[i]}\" in".into());
            lines.push("      -*) ;;".into());
            lines.push("      *) if [ -z \"$prefix\" ]; then prefix=\"${COMP_WORDS[i]}\";".into());
            lines.push("         else prefix=\"$prefix ${COMP_WORDS[i]}\"; fi ;;".into());
            lines.push("    esac".into());
            lines.push("  done".into());
            lines.push("  case \"$prefix\" in".into());
            for (key, next) in &rows {
                lines.push(format!("    \"{key}\")"));
                lines.push(format!(
                    "      COMPREPLY=( $(compgen -W \"{}\" -- \"$cur\") ) ;;",
                    next.join(" ")
                ));
            }
            lines.push("    *) COMPREPLY=() ;;".into());
            lines.push("  esac".into());
            lines.push("  return 0".into());
            lines.push("}".into());
            lines.push("complete -F _arkdeck arkdeck".into());
        }
        "zsh" => {
            lines.push("#compdef arkdeck".into());
            lines.push(format!(
                "# generated from {version}; identities are never completed."
            ));
            lines.push("_arkdeck() {".into());
            lines.push("  local prefix word".into());
            lines.push("  prefix=\"\"".into());
            lines.push("  for word in \"${words[@]:1:$((CURRENT - 2))}\"; do".into());
            lines.push("    case \"$word\" in".into());
            lines.push("      -*) ;;".into());
            lines.push(
                "      *) if [[ -z \"$prefix\" ]]; then prefix=\"$word\"; else prefix=\"$prefix $word\"; fi ;;"
                    .into(),
            );
            lines.push("    esac".into());
            lines.push("  done".into());
            lines.push("  local -a candidates".into());
            lines.push("  case \"$prefix\" in".into());
            for (key, next) in &rows {
                lines.push(format!("    \"{key}\")"));
                lines.push(format!(
                    "      candidates=({}) ;;",
                    next.iter()
                        .map(|token| format!("'{token}'"))
                        .collect::<Vec<_>>()
                        .join(" ")
                ));
            }
            lines.push("    *) candidates=() ;;".into());
            lines.push("  esac".into());
            lines.push("  (( ${#candidates} )) && _describe 'arkdeck' candidates".into());
            lines.push("}".into());
            lines.push("_arkdeck \"$@\"".into());
        }
        "fish" => {
            lines.push(format!(
                "# arkdeck fish completion — generated from {version}"
            ));
            lines.push("# Identities are never completed: see the CLI product spec §10.".into());
            lines.push("complete -c arkdeck -f".into());
            lines.push("function __arkdeck_prefix".into());
            lines.push("  set -l tokens (commandline -poc)".into());
            lines.push("  set -l parts".into());
            lines.push("  for token in $tokens[2..-1]".into());
            lines.push("    if not string match -q -- '-*' $token".into());
            lines.push("      set parts $parts $token".into());
            lines.push("    end".into());
            lines.push("  end".into());
            lines.push("  string join ' ' $parts".into());
            lines.push("end".into());
            for (key, next) in &rows {
                let condition = if key.is_empty() {
                    "test -z (__arkdeck_prefix)".to_owned()
                } else {
                    format!("test (__arkdeck_prefix) = '{key}'")
                };
                for token in next {
                    lines.push(format!(
                        "complete -c arkdeck -n \"{condition}\" -a '{token}'"
                    ));
                }
            }
        }
        "powershell" => {
            lines.push(format!(
                "# arkdeck PowerShell completion — generated from {version}"
            ));
            lines.push("# Identities are never completed: see the CLI product spec §10.".into());
            lines.push(
                "Register-ArgumentCompleter -Native -CommandName arkdeck -ScriptBlock {".into(),
            );
            lines.push("  param($wordToComplete, $commandAst, $cursorPosition)".into());
            lines.push("  $next = @{".into());
            for (key, next) in &rows {
                lines.push(format!(
                    "    '{key}' = @({})",
                    next.iter()
                        .map(|token| format!("'{token}'"))
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
            }
            lines.push("  }".into());
            lines.push(
                "  $tokens = @($commandAst.CommandElements | ForEach-Object { $_.ToString() })"
                    .into(),
            );
            lines.push("  $parts = @()".into());
            lines.push("  if ($tokens.Count -gt 1) {".into());
            lines.push("    foreach ($token in $tokens[1..($tokens.Count - 1)]) {".into());
            lines.push("      if ($token -eq $wordToComplete) { continue }".into());
            lines.push("      if ($token -notlike '-*') { $parts += $token }".into());
            lines.push("    }".into());
            lines.push("  }".into());
            lines.push("  $candidates = $next[($parts -join ' ')]".into());
            lines.push("  if ($null -eq $candidates) { return }".into());
            lines.push("  $candidates | Where-Object { $_ -like \"$wordToComplete*\" } |".into());
            lines.push(
                "    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }"
                    .into(),
            );
            lines.push("}".into());
        }
        _ => return None,
    }
    Some(lines.join("\n") + "\n")
}
