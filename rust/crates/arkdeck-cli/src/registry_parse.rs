//! Swift `CLIArgumentParser`'s registry pass, over the registry copy
//! (`command_registry.json`): what Swift's parser refuses before any handler
//! runs, refused here with its code, its words, its `details` and the leaf it
//! names (`CLIRegistryError.command`).
//!
//! The pass reads the argv as Swift's parser does:
//!
//! 1. the global options ahead of the command path (`--help`, `-h`,
//!    `--version`, `--output`);
//! 2. the command path, walked down the registry's nodes to a leaf;
//! 3. the leaf's own options, the trailing global region and its positionals;
//! 4. the output mode against the leaf's `outputModes`, then `validate`: each
//!    option's requirement and grammar in declaration order, the mutual
//!    exclusions, the exactly-one-of groups and the positionals.
//!
//! What it accepts is the parser's to read, which judges what the values mean
//! as Swift's handlers do. Help, `--version` and a node path are left to it.
//!
//! The CLI spec (§5.1) lets a global option stand ahead of the command path
//! or after the leaf's arguments, and this CLI reads `--control-request-id`,
//! `--timeout` and `--socket` in either place. Swift's parser reads only the
//! four above ahead of the path, so the pass judges one of these three, with
//! its value, where Swift reads it: just after the path, as the leaf's own.
//!
//! One Swift check is left out: its parser refuses `--socket` on
//! `runtime tool register` unless the kind is DevEco, which this CLI declares
//! a divergence (it registers every kind through the Runtime).
use crate::{CliError, valid_correlation};
use serde_json::{Map, Value, json};
use std::sync::OnceLock;

const HELP: [&str; 2] = ["--help", "-h"];
const VERSION: &str = "--version";
const OUTPUT: &str = "--output";
/// The CLI spec's global options (§5.2) this CLI also reads ahead of the path.
const LEADING_GLOBALS: [&str; 3] = ["--control-request-id", "--timeout", "--socket"];

fn leaves() -> &'static [Value] {
    static REGISTRY: OnceLock<Value> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        serde_json::from_str(include_str!("command_registry.json"))
            .expect("the checked-in command registry")
    })["commands"]
        .as_array()
        .expect("the registry's commands")
}

fn path_of(leaf: &Value) -> Vec<&str> {
    leaf["path"]
        .as_array()
        .map(|tokens| tokens.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default()
}

/// The leaf whose path is exactly `path`.
fn leaf_at(path: &[&str]) -> Option<&'static Value> {
    leaves().iter().find(|leaf| path_of(leaf) == path)
}

/// Whether `path` is a node: some leaf lies below it.
fn is_node(path: &[&str]) -> bool {
    leaves().iter().any(|leaf| {
        let tokens = path_of(leaf);
        tokens.len() > path.len() && tokens.starts_with(path)
    })
}

/// Swift `CLINodeSpec.childTokens`: the node's own leaves, then its groups,
/// each in the registry's order.
fn children(path: &[&str]) -> String {
    let mut leaves_here: Vec<&str> = Vec::new();
    let mut groups: Vec<&str> = Vec::new();
    for leaf in leaves() {
        let tokens = path_of(leaf);
        if tokens.len() <= path.len() || !tokens.starts_with(path) {
            continue;
        }
        let token = tokens[path.len()];
        let list = if tokens.len() == path.len() + 1 {
            &mut leaves_here
        } else {
            &mut groups
        };
        if !token.is_empty() && !list.contains(&token) {
            list.push(token);
        }
    }
    leaves_here.extend(groups);
    leaves_here.join("|")
}

fn refusal(
    code: &'static str,
    message: String,
    details: Value,
    command: Option<&'static str>,
) -> CliError {
    let mut error = CliError::new(code, message);
    if let Value::Object(details) = details {
        error.details = details;
    }
    error.command = command;
    error
}

fn duplicate(token: &str, command: Option<&'static str>) -> CliError {
    refusal(
        "invalidOption",
        format!("{token} was given more than once"),
        json!({"option": token}),
        command,
    )
}

fn missing_value(token: &str, command: Option<&'static str>) -> CliError {
    refusal(
        "invalidOption",
        format!("{token} requires a value"),
        json!({"option": token}),
        command,
    )
}

#[derive(Default)]
struct State {
    help: bool,
    version: bool,
    output: Option<String>,
}

enum Global {
    Consumed,
    NotGlobal,
}

/// Swift `consumeGlobal`: `--help`, `-h`, `--version` and `--output`.
fn consume_global(
    argv: &[String],
    index: &mut usize,
    state: &mut State,
) -> Result<Global, CliError> {
    let token = argv[*index].as_str();
    if HELP.contains(&token) {
        if state.help {
            return Err(duplicate(token, None));
        }
        state.help = true;
        *index += 1;
        return Ok(Global::Consumed);
    }
    if token == VERSION {
        if state.version {
            return Err(duplicate(token, None));
        }
        state.version = true;
        *index += 1;
        return Ok(Global::Consumed);
    }
    if token == OUTPUT {
        if state.output.is_some() {
            return Err(duplicate(token, None));
        }
        let Some(value) = argv.get(*index + 1) else {
            return Err(missing_value(token, None));
        };
        state.output = Some(value.clone());
        *index += 2;
        return Ok(Global::Consumed);
    }
    Ok(Global::NotGlobal)
}

/// Swift `helpIsNotMachineReadable`: help asked for with an output mode.
fn help(state: &State) -> Result<(), CliError> {
    match state.output {
        None => Ok(()),
        Some(_) => Err(refusal(
            "invalidOption",
            "help renders human text only; use `arkdeck commands --output json` for the \
             machine projection of the command surface"
                .into(),
            Value::Null,
            None,
        )),
    }
}

/// `argv` as Swift's parser would be given it: each of [`LEADING_GLOBALS`]
/// this CLI read ahead of the path moves, with its value, to just after the
/// leaf's path. Ahead of the path, the pass stops at the first option Swift's
/// parser does not read there either. Without a leaf to move them to, the
/// moved options are left out: Swift refuses that option, or the path, before
/// it would read any leaf option.
fn as_swift_reads(argv: &[String]) -> Vec<String> {
    let mut kept = Vec::new();
    let mut moved = Vec::new();
    let mut index = 0;
    while index < argv.len() && argv[index].starts_with('-') {
        let token = argv[index].as_str();
        let width = if HELP.contains(&token) || token == VERSION {
            1
        } else if token == OUTPUT || LEADING_GLOBALS.contains(&token) {
            2
        } else {
            break;
        };
        let Some(option) = argv.get(index..index + width) else {
            break;
        };
        if LEADING_GLOBALS.contains(&token) {
            moved.extend_from_slice(option);
        } else {
            kept.extend_from_slice(option);
        }
        index += width;
    }
    if moved.is_empty() {
        return argv.to_vec();
    }
    let mut path: Vec<&str> = Vec::new();
    let mut end = index;
    while let Some(token) = argv.get(end).filter(|token| !token.starts_with('-')) {
        path.push(token.as_str());
        end += 1;
        if leaf_at(&path).is_some() {
            kept.extend_from_slice(&argv[index..end]);
            kept.extend(moved);
            kept.extend_from_slice(&argv[end..]);
            return kept;
        }
        if !is_node(&path) {
            break;
        }
    }
    kept.extend_from_slice(&argv[index..]);
    kept
}

/// The leaf `argv` names by Swift's path resolution, if it names one.
pub(crate) fn leaf(argv: &[String]) -> Option<&'static str> {
    let argv = &as_swift_reads(argv);
    let mut index = 0;
    let mut state = State::default();
    while index < argv.len() && argv[index].starts_with('-') {
        match consume_global(argv, &mut index, &mut state) {
            Ok(Global::Consumed) => {}
            _ => return None,
        }
    }
    let mut path: Vec<&str> = Vec::new();
    while index < argv.len() && !argv[index].starts_with('-') {
        path.push(argv[index].as_str());
        index += 1;
        if let Some(leaf) = leaf_at(&path) {
            return leaf["command"].as_str();
        }
        if !is_node(&path) {
            return None;
        }
    }
    None
}

/// Swift's registry pass over `argv`; see the module.
pub(crate) fn check(argv: &[String]) -> Result<(), CliError> {
    if argv.is_empty() {
        return Ok(());
    }
    let argv = &as_swift_reads(argv);
    let mut state = State::default();
    let mut index = 0;
    // Phase 1: the global options ahead of the command path.
    while index < argv.len() && argv[index].starts_with('-') {
        if let Global::NotGlobal = consume_global(argv, &mut index, &mut state)? {
            return Err(refusal(
                "invalidOption",
                format!(
                    "unknown option {} before the command path; run `arkdeck commands` to \
                     list the published surface",
                    argv[index]
                ),
                json!({"option": argv[index]}),
                None,
            ));
        }
    }
    // A bare `--version` or `--help` is a complete request.
    if index == argv.len() {
        return Ok(());
    }
    // Phase 2: the command path.
    let first = argv[index].as_str();
    index += 1;
    let mut path = vec![first];
    let leaf = loop {
        if let Some(leaf) = leaf_at(&path) {
            break leaf;
        }
        if !is_node(&path) {
            let (parent, token) = path.split_at(path.len() - 1);
            return Err(if parent.is_empty() {
                refusal(
                    "invalidCommand",
                    format!(
                        "unknown command `{first}`; run `arkdeck commands` to list the published surface"
                    ),
                    json!({"command": first}),
                    None,
                )
            } else {
                refusal(
                    "invalidCommand",
                    format!(
                        "unknown `{}` subcommand `{}`: {}",
                        parent.join(" "),
                        token[0],
                        children(parent)
                    ),
                    json!({"command": parent.join("."), "subcommand": token[0]}),
                    None,
                )
            });
        }
        let Some(next) = argv.get(index) else {
            // An incomplete path: a request for the node's help, or a
            // command that needs its subcommand.
            if state.help {
                return help(&state);
            }
            return Err(refusal(
                "invalidCommand",
                format!(
                    "`{}` needs a subcommand: {}",
                    path.join(" "),
                    children(&path)
                ),
                json!({"command": path.join(".")}),
                None,
            ));
        };
        if next.starts_with('-') {
            if HELP.contains(&next.as_str()) {
                if state.help {
                    return Err(duplicate(next, None));
                }
                state.help = true;
                return help(&state);
            }
            return Err(refusal(
                "invalidOption",
                format!(
                    "`{}` needs a subcommand before any option: {}",
                    path.join(" "),
                    children(&path)
                ),
                json!({"command": path.join("."), "option": next}),
                None,
            ));
        }
        index += 1;
        path.push(next.as_str());
    };
    check_leaf(argv, index, &path, leaf, state)
}

/// Swift `parseLeaf` for an executable leaf, from the token after its path.
fn check_leaf(
    argv: &[String],
    mut index: usize,
    path: &[&str],
    leaf: &'static Value,
    mut state: State,
) -> Result<(), CliError> {
    // Leaves that are not executable are answered by name before this pass
    // (`command_registry::answer_by_name`).
    if leaf["kind"] != "executable" {
        return Ok(());
    }
    let command = leaf["command"]
        .as_str()
        .expect("a leaf's canonical command");
    let options = leaf["options"].as_array().map_or(&[][..], Vec::as_slice);
    let option = |token: &str| options.iter().find(|option| option["name"] == token);
    let name = path.join(" ");
    let mut provided: Map<String, Value> = Map::new();
    let mut positionals: Vec<&str> = Vec::new();
    while index < argv.len() {
        let token = argv[index].as_str();
        if token.starts_with('-') && token != "-" {
            if let Some(spec) = option(token) {
                if provided.contains_key(token) {
                    return Err(duplicate(token, Some(command)));
                }
                if spec["form"] == "value" {
                    let Some(value) = argv.get(index + 1) else {
                        return Err(missing_value(token, Some(command)));
                    };
                    provided.insert(token.into(), json!(value));
                    index += 2;
                } else {
                    provided.insert(token.into(), Value::Null);
                    index += 1;
                }
                continue;
            }
            // Not a leaf option: the trailing global region.
            if let Global::NotGlobal = consume_global(argv, &mut index, &mut state)? {
                return Err(refusal(
                    "invalidOption",
                    format!(
                        "`{name}` does not accept {token}; run `arkdeck help {name}` for its options"
                    ),
                    json!({"command": command, "option": token}),
                    Some(command),
                ));
            }
            continue;
        }
        positionals.push(token);
        index += 1;
    }
    if state.help {
        return help(&state);
    }
    if state.version {
        return Ok(());
    }
    // `--output` is position-global but leaf-scoped: given in both regions it
    // is still one option given twice.
    if let Some(output) = provided.get(OUTPUT).and_then(Value::as_str) {
        if state.output.is_some() {
            return Err(duplicate(OUTPUT, Some(command)));
        }
        state.output = Some(output.to_owned());
    }
    if let Some(raw) = &state.output {
        if option(OUTPUT).is_none() {
            return Err(refusal(
                "invalidOption",
                format!(
                    "`{name}` does not accept --output in this release; {}",
                    if option("--json").is_some() {
                        "use --json"
                    } else {
                        "it renders one human summary"
                    }
                ),
                json!({"command": command}),
                Some(command),
            ));
        }
        let modes: Vec<&str> = leaf["outputModes"]
            .as_array()
            .map(|modes| modes.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        if !modes.contains(&raw.as_str()) {
            return Err(refusal(
                "invalidOption",
                format!("--output must be one of {}", modes.join("|")),
                json!({"command": command, "value": raw}),
                Some(command),
            ));
        }
    }
    validate(leaf, command, &name, options, &provided, &positionals)
}

/// Swift `validate(leaf:path:provided:positionals:)`.
fn validate(
    leaf: &Value,
    command: &'static str,
    name: &str,
    options: &[Value],
    provided: &Map<String, Value>,
    positionals: &[&str],
) -> Result<(), CliError> {
    for option in options {
        let label = option["name"].as_str().unwrap_or_default();
        match provided.get(label) {
            None if option["required"] == true => {
                let placeholder = option["placeholder"]
                    .as_str()
                    .filter(|_| option["form"] == "value")
                    .map_or(String::new(), |placeholder| format!("<{placeholder}>"));
                return Err(refusal(
                    "invalidOption",
                    format!("`{name}` requires {label} {placeholder}"),
                    json!({"command": command, "option": label}),
                    Some(command),
                ));
            }
            Some(Value::String(value)) => {
                grammar(&option["grammar"], value, label, command, name)?;
            }
            _ => {}
        }
    }
    let groups = |key: &str| -> Vec<Vec<&str>> {
        leaf[key]
            .as_array()
            .map(|groups| {
                groups
                    .iter()
                    .filter_map(Value::as_array)
                    .map(|group| group.iter().filter_map(Value::as_str).collect())
                    .collect()
            })
            .unwrap_or_default()
    };
    for group in groups("mutuallyExclusive") {
        let mut present: Vec<&str> = group
            .iter()
            .copied()
            .filter(|option| provided.contains_key(*option))
            .collect();
        if present.len() > 1 {
            present.sort_unstable();
            return Err(refusal(
                "invalidOption",
                format!("`{name}` accepts only one of {}", present.join(", ")),
                json!({"command": command, "options": present}),
                Some(command),
            ));
        }
    }
    for group in groups("requiresExactlyOneOf") {
        let present = group
            .iter()
            .filter(|option| provided.contains_key(**option))
            .count();
        if present != 1 {
            return Err(refusal(
                "invalidOption",
                format!("`{name}` requires exactly one of {}", group.join(", ")),
                json!({"command": command, "options": group}),
                Some(command),
            ));
        }
    }
    let mut remaining: &[&str] = positionals;
    for spec in leaf["positionals"]
        .as_array()
        .map_or(&[][..], Vec::as_slice)
    {
        if spec["variadic"] == true {
            remaining = &[];
            continue;
        }
        let Some((value, rest)) = remaining.split_first() else {
            if spec["required"] == true {
                return Err(refusal(
                    "invalidOption",
                    format!(
                        "`{name}` requires a {} argument ({})",
                        spec["name"].as_str().unwrap_or_default(),
                        spec["summary"].as_str().unwrap_or_default()
                    ),
                    json!({"command": command}),
                    Some(command),
                ));
            }
            continue;
        };
        grammar(
            &spec["grammar"],
            value,
            spec["name"].as_str().unwrap_or_default(),
            command,
            name,
        )?;
        remaining = rest;
    }
    if let Some(extra) = remaining.first() {
        return Err(refusal(
            "invalidOption",
            format!("`{name}` does not take the argument `{extra}`"),
            json!({"command": command}),
            Some(command),
        ));
    }
    Ok(())
}

/// Swift `check(_:value:label:leaf:name:)` for one grammar of the registry.
fn grammar(
    grammar: &Value,
    value: &str,
    label: &str,
    command: &'static str,
    name: &str,
) -> Result<(), CliError> {
    let named = |message: String| {
        refusal(
            "invalidOption",
            format!("`{name}` {label} {message}"),
            json!({"command": command, "option": label}),
            Some(command),
        )
    };
    match grammar["kind"].as_str().unwrap_or("opaque") {
        "nonNegativeInteger" | "positiveInteger" => {
            let minimum = grammar["minimum"].as_i64().unwrap_or(0);
            let maximum = grammar["maximum"].as_i64().unwrap_or(i64::MAX);
            let within = if value == "0" {
                minimum == 0
            } else {
                !value.is_empty()
                    && value.bytes().all(|byte| byte.is_ascii_digit())
                    && !value.starts_with('0')
                    && value
                        .parse::<i64>()
                        .is_ok_and(|number| (minimum..=maximum).contains(&number))
            };
            if within {
                return Ok(());
            }
            let bound = if maximum == i64::MAX {
                format!("{minimum} or greater")
            } else {
                format!("{minimum}...{maximum}")
            };
            let mut error = named(format!("must be {bound}"));
            error.details.insert("value".into(), json!(value));
            Err(error)
        }
        // Swift projects its control-request identity grammar as this pattern.
        "pattern" if !valid_correlation(value) => Err(named(format!(
            "must match {}",
            grammar["pattern"].as_str().unwrap_or_default()
        ))),
        "hexDigest" => {
            let length = grammar["length"].as_u64().unwrap_or(64);
            // Swift `Character.isHexDigit && !isUppercase`: ASCII or fullwidth,
            // never an uppercase letter.
            let lowercase_hex = |character: char| matches!(character, '0'..='9' | 'a'..='f' | '\u{FF10}'..='\u{FF19}' | '\u{FF41}'..='\u{FF46}');
            if value.chars().count() as u64 == length && value.chars().all(lowercase_hex) {
                return Ok(());
            }
            Err(named(format!("must be {length} lowercase hex digits")))
        }
        "duration" => {
            let maximum = grammar["maximumMilliseconds"]
                .as_u64()
                .unwrap_or(86_400_000);
            if duration(value, maximum) {
                return Ok(());
            }
            Err(named(format!(
                "must be a duration like `30s` (digits then ms|s|m|h, no larger than {maximum}ms)"
            )))
        }
        "enumeration" => {
            let values: Vec<&str> = grammar["values"]
                .as_array()
                .map(|values| values.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            if values.contains(&value) {
                return Ok(());
            }
            let mut error = named(format!("must be one of {}", values.join("|")));
            error.details.insert("value".into(), json!(value));
            Err(error)
        }
        _ => Ok(()),
    }
}

/// Swift `CLIDuration.parse`: digits without a leading zero, then one of
/// `ms`, `s`, `m`, `h`, no larger than `maximum` milliseconds.
fn duration(value: &str, maximum: u64) -> bool {
    for (suffix, scale) in [("ms", 1), ("s", 1_000), ("m", 60_000), ("h", 3_600_000)] {
        if let Some(digits) = value.strip_suffix(suffix) {
            return !digits.is_empty()
                && !digits.starts_with('0')
                && digits.bytes().all(|byte| byte.is_ascii_digit())
                && digits
                    .parse::<u64>()
                    .ok()
                    .and_then(|number| number.checked_mul(scale))
                    .is_some_and(|milliseconds| milliseconds <= maximum);
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(tokens: &[&str]) -> Vec<String> {
        tokens.iter().map(|token| (*token).to_owned()).collect()
    }

    fn refused(tokens: &[&str]) -> CliError {
        check(&argv(tokens)).expect_err("Swift's parser refuses it")
    }

    #[test]
    fn a_refusal_names_the_leaf_and_carries_swifts_details() {
        let error = refused(&["job", "wait"]);
        assert_eq!(error.message, "`job wait` requires --job <job-id>");
        assert_eq!(error.command, Some("job.wait"));
        assert_eq!(
            Value::Object(error.details),
            json!({"command": "job.wait", "option": "--job"})
        );
        let error = refused(&["job", "status", "--job", "a", "--job", "b"]);
        assert_eq!(error.message, "--job was given more than once");
        assert_eq!(Value::Object(error.details), json!({"option": "--job"}));
        assert_eq!(error.command, Some("job.status"));
        let error = refused(&["job", "status", "--job"]);
        assert_eq!(error.message, "--job requires a value");
        let error = refused(&["job", "status", "--job", "a", "--bogus"]);
        assert_eq!(
            error.message,
            "`job status` does not accept --bogus; run `arkdeck help job status` for its options"
        );
        assert_eq!(
            Value::Object(error.details),
            json!({"command": "job.status", "option": "--bogus"})
        );
        let error = refused(&["job", "status", "--job", "a", "--output", "jsonl"]);
        assert_eq!(error.message, "--output must be one of human|json");
        assert_eq!(
            Value::Object(error.details),
            json!({"command": "job.status", "value": "jsonl"})
        );
    }

    #[test]
    fn the_path_is_walked_as_swifts_nodes_walk_it() {
        let error = refused(&["nope"]);
        assert_eq!(
            (error.code, error.message.as_str(), error.command),
            (
                "invalidCommand",
                "unknown command `nope`; run `arkdeck commands` to list the published surface",
                None
            )
        );
        let error = refused(&["job"]);
        assert_eq!(error.code, "invalidCommand");
        assert!(error.message.starts_with("`job` needs a subcommand: "));
        assert_eq!(Value::Object(error.details), json!({"command": "job"}));
        let error = refused(&["job", "--job", "x"]);
        assert!(
            error
                .message
                .starts_with("`job` needs a subcommand before any option: ")
        );
        let error = refused(&["job", "nope"]);
        assert!(
            error
                .message
                .starts_with("unknown `job` subcommand `nope`: ")
        );
        assert_eq!(
            Value::Object(error.details),
            json!({"command": "job", "subcommand": "nope"})
        );
        let error = refused(&["--bogus", "doctor"]);
        assert_eq!(
            error.message,
            "unknown option --bogus before the command path; run `arkdeck commands` to list the published surface"
        );
        // Help is the parser's, anywhere Swift answers it; in a machine mode
        // given ahead of the path it is refused.
        for tokens in [
            &["job", "--help"][..],
            &["job", "status", "--help"],
            &["--help"],
        ] {
            assert!(check(&argv(tokens)).is_ok(), "{tokens:?}");
        }
        assert_eq!(
            refused(&["--output", "json", "job", "--help"]).code,
            "invalidOption"
        );
        assert_eq!(
            leaf(&argv(&["job", "status", "--job", "x"])),
            Some("job.status")
        );
        assert_eq!(leaf(&argv(&["--output", "json", "doctor"])), Some("doctor"));
        assert_eq!(leaf(&argv(&["job", "nope"])), None);
    }

    #[test]
    fn a_global_option_ahead_of_the_path_is_judged_where_swift_reads_it() {
        // The read-only host check's argv: the unknown subcommand is refused,
        // not the correlation option ahead of the path.
        let error = refused(&[
            "--output",
            "json",
            "--control-request-id",
            "ctl-unknown-command",
            "job",
            "no-such-command",
        ]);
        assert_eq!(error.code, "invalidCommand");
        assert!(
            error
                .message
                .starts_with("unknown `job` subcommand `no-such-command`: ")
        );
        assert_eq!(
            Value::Object(error.details),
            json!({"command": "job", "subcommand": "no-such-command"})
        );
        let error = refused(&[
            "--output",
            "json",
            "--control-request-id",
            "ctl-bad-option",
            "doctor",
            "--shell",
            "x",
        ]);
        assert_eq!(
            (error.message.as_str(), error.command),
            (
                "`doctor` does not accept --shell; run `arkdeck help doctor` for its options",
                Some("doctor")
            )
        );
        // Judged as the leaf's own: required options, applicability, a second
        // one after the leaf's arguments, and its grammar.
        let error = refused(&["--control-request-id", "c1", "job", "status"]);
        assert_eq!(
            (error.message.as_str(), error.command),
            ("`job status` requires --job <job-id>", Some("job.status"))
        );
        assert_eq!(
            leaf(&argv(&["--socket", "/s", "job", "status"])),
            Some("job.status")
        );
        let error = refused(&["--timeout", "5s", "doctor"]);
        assert_eq!(
            error.message,
            "`doctor` does not accept --timeout; run `arkdeck help doctor` for its options"
        );
        let error = refused(&[
            "--control-request-id",
            "a",
            "job",
            "status",
            "--job",
            "j",
            "--control-request-id",
            "b",
        ]);
        assert_eq!(
            error.message,
            "--control-request-id was given more than once"
        );
        let error = refused(&["--control-request-id", "-x", "job", "status", "--job", "j"]);
        assert_eq!(
            error.message,
            "`job status` --control-request-id must match ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"
        );
        assert!(check(&argv(&["--timeout", "5s", "job", "status", "--job", "j"])).is_ok());
        // Nothing is moved past an option Swift refuses ahead of the path, or
        // into a path that names no leaf.
        let error = refused(&["--control-request-id", "c1", "--bogus", "job", "status"]);
        assert_eq!(
            error.message,
            "unknown option --bogus before the command path; run `arkdeck commands` to list the published surface"
        );
        let error = refused(&["--control-request-id", "c1", "job"]);
        assert!(error.message.starts_with("`job` needs a subcommand: "));
        let error = refused(&["--control-request-id"]);
        assert!(
            error
                .message
                .starts_with("unknown option --control-request-id before")
        );
    }

    #[test]
    fn each_grammar_refuses_as_swifts_check_does() {
        let error = refused(&["job", "wait", "--job", "j", "--page-size", "0"]);
        assert_eq!(error.message, "`job wait` --page-size must be 1...1000");
        assert_eq!(error.details["value"], "0");
        let error = refused(&["job", "wait", "--job", "j", "--timeout", "0s"]);
        assert_eq!(
            error.message,
            "`job wait` --timeout must be a duration like `30s` (digits then ms|s|m|h, no larger than 86400000ms)"
        );
        let error = refused(&["job", "status", "--job", "j", "--control-request-id", "-x"]);
        assert_eq!(
            error.message,
            "`job status` --control-request-id must match ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"
        );
        let error = refused(&["completion", "tcsh"]);
        assert_eq!(
            error.message,
            "`completion` shell must be one of bash|zsh|fish|powershell"
        );
        assert_eq!(error.details["value"], "tcsh");
        assert!(duration("30s", 86_400_000) && duration("24h", 86_400_000));
        assert!(!duration("25h", 86_400_000) && !duration("030s", 86_400_000));
        assert!(!duration("11m", 600_000) && duration("10m", 600_000));
    }
}
