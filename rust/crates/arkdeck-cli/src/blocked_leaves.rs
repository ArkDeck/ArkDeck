//! Registry leaves whose subsystem the Rust CLI has not ported yet, answered
//! by name: `runtime update *`, and `maintainer update-feed assemble` with its
//! deprecated `update-feed assemble` spelling (a declared difference,
//! TASK-XPA-018; the coordinator's ruling of 2026-09-26; `prepare` is ported
//! in `update_feed`).
//!
//! The registry publishes them as executable, so they are not tombstones
//! (CLI spec §12:1462 reserves `commandRemoved` for leaves the registry marks
//! removed), and the registry knows them, so they are not unknown commands
//! either (`invalidCommand`). Swift's registry pass judges the argv as for any
//! leaf: a refusal is its refusal, help is the leaf's help. An argv Swift
//! would dispatch is answered `blockedByProductDefect` (CLI spec §8.4: the
//! typed product surface the spec requires is missing), exit 69, before
//! anything is read, written or connected.
use crate::registry_parse::{self, Accepted};
use crate::{CliError, Invocation};
use serde_json::{Map, json};

/// The leaves answered by name, and the subsystem each one is missing.
const BLOCKED: &[(&str, &str)] = &[
    ("runtime.update.check", "the macOS update subsystem"),
    ("runtime.update.download", "the macOS update subsystem"),
    ("runtime.update.handoff", "the macOS update subsystem"),
    ("runtime.update.status", "the macOS update subsystem"),
    ("runtime.update.cancel", "the macOS update subsystem"),
    ("runtime.update.cleanup", "the macOS update subsystem"),
    (
        "maintainer.update-feed.assemble",
        "the update feed maintainer tools",
    ),
    ("update-feed.assemble", "the update feed maintainer tools"),
];

/// Whether `command` is answered by name as not yet provided.
pub fn blocks(command: &str) -> bool {
    BLOCKED.iter().any(|(leaf, _)| *leaf == command)
}

/// `argv` answered, when it names a blocked leaf: Swift's registry pass
/// first, then this CLI's answer. `None` for any other argv.
pub(crate) fn answer(argv: &[String]) -> Option<Result<Invocation, CliError>> {
    let command = registry_parse::leaf(argv).filter(|command| blocks(command))?;
    Some(match registry_parse::check(argv) {
        Err(error) => Err(error),
        Ok(Some(Accepted::LeafHelp(_))) => Ok(invocation(command, argv, true)),
        Ok(Some(Accepted::Dispatch { .. })) => Ok(invocation(command, argv, false)),
        // The registry pass accepts a leaf's argv only as its help or its
        // dispatch; anything else would be a defect of this module's list.
        Ok(_) => Err(CliError::new(
            "internalError",
            format!("`{}` resolved to no answer", command.replace('.', " ")),
        )),
    })
}

/// The invocation Swift's parser would dispatch, with the output mode and the
/// correlation identity the registry pass accepted.
fn invocation(command: &'static str, argv: &[String], help: bool) -> Invocation {
    let value = |flag: &str| {
        argv.iter()
            .position(|token| token == flag)
            .and_then(|index| argv.get(index + 1))
            .cloned()
    };
    let mode = value("--output");
    Invocation {
        command,
        method: command,
        params: None,
        json: mode.as_deref() == Some("json"),
        jsonl: mode.as_deref() == Some("jsonl"),
        raw: false,
        legacy_json: argv.iter().any(|token| token == "--json"),
        help,
        require_healthy: false,
        control_request_id: value("--control-request-id"),
        socket: None,
        timeout_ms: None,
    }
}

/// The answer for a blocked leaf: nothing was dispatched.
pub fn refusal(command: &'static str) -> CliError {
    let subsystem = BLOCKED
        .iter()
        .find(|(leaf, _)| *leaf == command)
        .map_or("this subsystem", |(_, subsystem)| subsystem);
    let mut error = CliError::new(
        "blockedByProductDefect",
        format!(
            "`{}` is not provided by the Rust CLI yet ({subsystem}: not ported; declared \
             difference, TASK-XPA-018); nothing was dispatched",
            command.replace('.', " ")
        ),
    );
    error.details = Map::from_iter([
        ("command".to_owned(), json!(command)),
        ("newDispatchCount".to_owned(), json!(0)),
    ]);
    error.command = Some(command);
    error
}
