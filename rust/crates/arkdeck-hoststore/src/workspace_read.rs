//! The four read-only workspace operations for the Rust workspace provider
//! (TASK-XPA-015, M3), as Swift serves them:
//!
//! - `workspace.inspect-source@1` through Swift `WorkspaceProvider`
//!   (CHG-2026-054 TASK-HTP-007): the inspector a host configured
//!   (`ARKDECK_WORKSPACE_INSPECTOR`), run over the root a registered project
//!   pinned, with `-r -n --include <scope> -- <symbol> <root>`;
//! - `workspace.read-source-range@1`, `workspace.inspect-git-status@1` and
//!   `workspace.inspect-diff@1` through the read-only arms of
//!   `WorkspaceOperationsProvider` (CHG-2026-055 TASK-HFA-008): the profile's
//!   pinned source reader (`sed`) or source-control tool (`git`), run in the
//!   profile's root with the argv the provider builds.
//!
//! A caller names a project and bounded typed inputs, never a path or an
//! option: every input is screened as Swift screens it (a scope, a symbol, a
//! line range, a repository-relative path inside the profile's scope, a
//! revision expression, a pathspec), the argv is built here in full, and the
//! dispatch runs exactly that array, with no shell. A read writes nothing,
//! so a read whose receipt was lost is reconciled as not executed.
//!
//! A refusal is the detail Swift's provider error describes itself by.
use crate::strict_json::swift_quoted;
use crate::workspace_patch::{Invocation, ToolReceipt, failed_detail, output_summary};
use crate::workspace_support::{self as support, foundation_resolved, matches};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use unicode_segmentation::UnicodeSegmentation;

pub(crate) const INSPECT: &str = "workspace.inspect-source@1";
pub(crate) const RANGE: &str = "workspace.read-source-range@1";
pub(crate) const STATUS: &str = "workspace.inspect-git-status@1";
pub(crate) const DIFF: &str = "workspace.inspect-diff@1";
/// The read-only operations, which admission leaves to the default
/// read-only policy and which a reconcile confirms not executed.
pub(crate) const READS: [&str; 4] = [INSPECT, RANGE, STATUS, DIFF];
/// Swift `WorkspaceProvider`'s fixed inspection budget.
const INSPECTION_TIMEOUT_SECONDS: i64 = 120;

/// One read operation's step and the product it publishes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ReadStep {
    pub(crate) operation: &'static str,
    pub(crate) step: &'static str,
    pub(crate) kind: &'static str,
    pub(crate) product: &'static str,
}

/// The catalog step and product of `operation`, when it is a read.
pub(crate) fn read_step(operation: &str) -> Option<ReadStep> {
    let (operation, step, kind, product) = match operation {
        INSPECT => (
            INSPECT,
            "inspect-workspace-source",
            "inspectWorkspaceSource",
            "source-inspection.txt",
        ),
        RANGE => (
            RANGE,
            "read-source-range",
            "readWorkspaceSourceRange",
            "source-range.txt",
        ),
        STATUS => (
            STATUS,
            "inspect-git-status",
            "inspectWorkspaceGitStatus",
            "git-status.txt",
        ),
        DIFF => (
            DIFF,
            "inspect-diff",
            "inspectWorkspaceDiff",
            "diff-summary.txt",
        ),
        _ => return None,
    };
    Some(ReadStep {
        operation,
        step,
        kind,
        product,
    })
}

/// Swift `WorkspaceInspectorTool`: the inspector a host configured, pinned by
/// the digest of its bytes when the Runtime composed it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Inspector {
    pub(crate) path: String,
    pub(crate) sha256: String,
}

impl Inspector {
    /// Swift `FixedExecutableResolver.hashing(path:providerID:)`: an
    /// explicit absolute path, resolved as Foundation resolves it, naming a
    /// regular executable file, pinned by the digest of its bytes.
    pub fn hashing(path: &str) -> Result<Self, String> {
        if !path.starts_with('/') {
            return Err("provider executable path must be explicit and absolute".into());
        }
        let executable = foundation_resolved(path);
        let metadata =
            fs::metadata(&executable).map_err(|error| format!("{executable}: {error}"))?;
        if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
            return Err(format!(
                "provider executable must be a regular executable file: {executable}"
            ));
        }
        let bytes = fs::read(&executable).map_err(|error| format!("{executable}: {error}"))?;
        Ok(Self {
            path: executable,
            sha256: support::sha256(&bytes),
        })
    }
}

/// Swift `WorkspaceSourceInspection`: what one inspection reads. The root
/// stays in the Runtime; the durable record names the project only.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SourceInspection {
    pub(crate) project_ref: String,
    pub(crate) project_root: String,
    pub(crate) symbol: String,
    pub(crate) file_scope: String,
}

/// Swift `WorkspaceProviderError.unknownProject`, as the engine interpolates
/// it.
pub(crate) fn unknown_project(project_ref: &str) -> String {
    format!("unknownProject({})", swift_quoted(project_ref))
}

/// Swift `WorkspaceProviderError.malformedScope`, as the engine interpolates
/// it.
fn malformed_scope(value: &str) -> String {
    format!("malformedScope({})", swift_quoted(value))
}

/// Swift `Character`s: extended grapheme clusters.
fn characters(text: &str) -> Vec<&str> {
    text.graphemes(true).collect()
}

/// Swift `String.contains(_:)` of a one-character string: whether one
/// `Character` is exactly it (a carriage return before a line feed makes
/// another `Character`).
fn contains_character(text: &str, character: &str) -> bool {
    characters(text).contains(&character)
}

/// Swift `String.contains(_:)` of a longer string: its `Character`s, in
/// order, somewhere in the text's.
fn contains_characters(text: &str, needle: &str) -> bool {
    let haystack = characters(text);
    let needle = characters(needle);
    haystack
        .windows(needle.len())
        .any(|window| window == needle.as_slice())
}

/// Swift `String.hasPrefix(_:)` of one `Character`.
fn has_prefix_character(text: &str, character: &str) -> bool {
    characters(text).first() == Some(&character)
}

/// Whether every `Character` is one ASCII letter, digit or one of `extra`,
/// as Swift's `allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber ||
/// extra.contains($0)) }` decides it for text made of ASCII.
fn ascii_only(text: &str, extra: &str) -> bool {
    text.bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || extra.as_bytes().contains(&byte))
}

/// Swift `WorkspaceProvider.validateScope`: a glob, never a path — no
/// separator, no parent traversal, no option.
pub(crate) fn validate_scope(scope: &str) -> Result<(), String> {
    let valid = !scope.is_empty()
        && ascii_only(scope, "*?.-_[]")
        && scope.len() <= 120
        && !scope.contains("..")
        && !scope.starts_with('-');
    valid.then_some(()).ok_or_else(|| malformed_scope(scope))
}

/// Swift `WorkspaceProvider.validateSymbol`: 1...200 characters, no NUL, no
/// line feed of its own.
pub(crate) fn validate_symbol(symbol: &str) -> Result<(), String> {
    let count = characters(symbol).len();
    let valid = count > 0
        && count <= 200
        && !contains_character(symbol, "\0")
        && !contains_character(symbol, "\n");
    valid.then_some(()).ok_or_else(|| malformed_scope(symbol))
}

/// Swift `WorkspaceProviderSupport.resolvedReadablePath`: a
/// repository-relative path the profile already declares readable, refused
/// rather than normalised, joined to the root as `URL.appending(path:)`
/// joins it (every trailing separator dropped, nothing else rewritten).
pub(crate) fn resolved_readable_path(
    relative: &str,
    root: &str,
    profile_globs: &[String],
) -> Result<String, String> {
    let count = characters(relative).len();
    if count == 0
        || count > 240
        || has_prefix_character(relative, "-")
        || has_prefix_character(relative, "/")
        || contains_characters(relative, "..")
        || contains_character(relative, "\0")
    {
        return Err("workspace.malformedFilePath".into());
    }
    if !profile_globs.iter().any(|glob| matches(relative, glob)) {
        return Err("workspace.pathOutsideProfileScope".into());
    }
    let joined = format!("{}/{relative}", root.trim_end_matches('/'));
    let trimmed = joined.trim_end_matches('/');
    Ok(if trimmed.is_empty() {
        "/".into()
    } else {
        trimmed.into()
    })
}

/// Swift `WorkspaceProviderSupport.validateRevisionExpression`: a revision,
/// never a path or an option.
pub(crate) fn validate_revision_expression(value: &str) -> Result<(), String> {
    let valid = !value.is_empty()
        && ascii_only(value, "._-^~@{}")
        && value.len() <= 120
        && !value.starts_with('-')
        && !value.contains("..")
        && !value.contains('/');
    valid
        .then_some(())
        .ok_or_else(|| "workspace.malformedRevision".into())
}

/// Swift `WorkspaceProviderSupport.validatePathScope`: a pathspec relative to
/// the resolved root — no parent traversal, no absolute path, no option.
pub(crate) fn validate_path_scope(value: &str) -> Result<(), String> {
    let valid = !value.is_empty()
        && ascii_only(value, "*?.-_[]/")
        && value.len() <= 120
        && !value.starts_with('-')
        && !value.starts_with('/')
        && !value.contains("..");
    valid
        .then_some(())
        .ok_or_else(|| "workspace.malformedPathScope".into())
}

/// Swift `WorkspaceProviderAction`'s four read cases.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ReadAction {
    InspectSource(SourceInspection),
    GitStatus(Invocation),
    Diff(Invocation),
    SourceRange(Invocation),
}

/// How a read runs: the executable its plan pinned, the argv it spawns, and
/// where. Swift's inspection names no working directory, so its child runs
/// where the Runtime does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ReadLowering {
    pub(crate) executable_path: String,
    pub(crate) executable_sha256: String,
    pub(crate) argument_zero: Option<String>,
    pub(crate) arguments: Vec<String>,
    pub(crate) working_directory: Option<String>,
    pub(crate) timeout_seconds: i64,
}

impl ReadLowering {
    /// Swift `WorkspaceProvider.lower` for an inspection: the inspector with
    /// `-r -n --include <scope> -- <symbol> <root>`. `--` ends the options so
    /// a symbol that begins with a dash never becomes one, and the root is
    /// last so the search cannot leave it.
    pub(crate) fn inspection(inspection: &SourceInspection, inspector: &Inspector) -> Self {
        Self {
            executable_path: inspector.path.clone(),
            executable_sha256: inspector.sha256.clone(),
            argument_zero: None,
            arguments: [
                "-r",
                "-n",
                "--include",
                &inspection.file_scope,
                "--",
                &inspection.symbol,
                &inspection.project_root,
            ]
            .map(str::to_owned)
            .to_vec(),
            working_directory: None,
            timeout_seconds: INSPECTION_TIMEOUT_SECONDS,
        }
    }

    /// Swift `WorkspaceOperationsProvider.lower` for a preset command: its
    /// pinned executable and argv, in the profile's root.
    pub(crate) fn invocation(invocation: &Invocation) -> Self {
        Self {
            executable_path: invocation.executable_path.clone(),
            executable_sha256: invocation.executable_sha256.clone(),
            argument_zero: invocation.argument_zero.clone(),
            arguments: invocation.arguments.clone(),
            working_directory: Some(invocation.project_root.clone()),
            timeout_seconds: invocation.timeout_seconds,
        }
    }

    /// The step of a materialized plan, as Swift's `MaterializedPlanStep`
    /// encodes a process plan: absent members are left out.
    pub(crate) fn plan_step(&self, journal: Value) -> Value {
        let mut process = json!({
            "journalArguments": journal,
            "processKind": "process",
            "executableSHA256": self.executable_sha256,
            "argumentSummary": self.arguments,
            "timeoutSeconds": self.timeout_seconds,
        });
        if let Some(zero) = &self.argument_zero {
            process["argumentZero"] = json!(zero);
        }
        if let Some(directory) = &self.working_directory {
            process["workingDirectory"] = json!(directory);
        }
        process
    }
}

/// How a read's receipt was judged: Swift's `.verified` summary or its
/// `.failed` code and detail.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ReadVerdict {
    Verified(BTreeMap<String, String>),
    Failed(String, String),
}

impl ReadAction {
    /// The catalog step this action is.
    pub(crate) fn step(&self) -> ReadStep {
        let operation = match self {
            Self::InspectSource(_) => INSPECT,
            Self::SourceRange(_) => RANGE,
            Self::GitStatus(_) => STATUS,
            Self::Diff(_) => DIFF,
        };
        read_step(operation).expect("every read action names a read step")
    }

    /// Swift `journalStep`'s arguments: the declared inputs and the product
    /// they land in, never the resolved root.
    pub(crate) fn journal_arguments(&self, inputs: &Map<String, Value>) -> Value {
        let input = |key: &str| inputs.get(key).cloned().unwrap_or(Value::Null);
        let product = self.step().product;
        match self {
            Self::InspectSource(inspection) => json!({
                "projectRef": inspection.project_ref,
                "symbol": inspection.symbol,
                "fileScope": inspection.file_scope,
                "artifactId": product,
            }),
            Self::GitStatus(_) => json!({
                "projectRef": input("projectRef"),
                "artifactId": product,
            }),
            Self::Diff(_) => json!({
                "projectRef": input("projectRef"),
                "baseRevision": input("baseRevision"),
                "pathScope": input("pathScope"),
                "artifactId": product,
            }),
            Self::SourceRange(_) => json!({
                "projectRef": input("projectRef"),
                "filePath": input("filePath"),
                "lineStart": input("lineStart"),
                "lineEnd": input("lineEnd"),
                "artifactId": product,
            }),
        }
    }

    /// Swift `PersistedTypedProviderAction`: an inspection by what it read,
    /// never where (`workspace.inspectSource`); any other read as the
    /// workspace action's canonical JSON, base64 (`workspace.action`).
    pub(crate) fn persisted(&self) -> Result<Value, ()> {
        let (case, invocation) = match self {
            Self::InspectSource(inspection) => {
                return Ok(json!({"kind": "workspace.inspectSource", "arguments": {
                    "projectRef": inspection.project_ref,
                    "symbol": inspection.symbol,
                    "fileScope": inspection.file_scope,
                }}));
            }
            Self::GitStatus(invocation) => ("inspectGitStatus", invocation),
            Self::Diff(invocation) => ("inspectDiff", invocation),
            Self::SourceRange(invocation) => ("readSourceRange", invocation),
        };
        let value = Value::Object(Map::from_iter([(
            case.to_owned(),
            json!({"_0": invocation.value()}),
        )]));
        let bytes = crate::session_json::encode(&value).map_err(|_| ())?;
        Ok(json!({"kind": "workspace.action",
            "arguments": {"payload": crate::agent_execution::base64(&bytes)}}))
    }

    /// Swift `PersistedTypedProviderAction.materialize()` for a read: the
    /// exact typed action a record persisted, or why it cannot be one. An
    /// inspection comes back without its root, which it no longer needs.
    pub(crate) fn materialize(persisted: &Value) -> Result<Self, String> {
        let arguments = &persisted["arguments"];
        match persisted["kind"].as_str().unwrap_or_default() {
            "workspace.inspectSource" => {
                let text = |key: &str| {
                    arguments[key].as_str().map(str::to_owned).ok_or_else(|| {
                        format!("persisted workspace.inspectSource is missing {key}")
                    })
                };
                Ok(Self::InspectSource(SourceInspection {
                    project_ref: text("projectRef")?,
                    project_root: String::new(),
                    symbol: text("symbol")?,
                    file_scope: text("fileScope")?,
                }))
            }
            "workspace.action" => {
                let payload = arguments["payload"]
                    .as_str()
                    .and_then(crate::agent_execution::unbase64)
                    .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                    .ok_or("persisted workspace.action payload is unreadable")?;
                let invocation = |case: &str| {
                    payload
                        .get(case)
                        .and_then(|value| Invocation::decode(&value["_0"]))
                };
                if let Some(invocation) = invocation("inspectGitStatus") {
                    Ok(Self::GitStatus(invocation))
                } else if let Some(invocation) = invocation("inspectDiff") {
                    Ok(Self::Diff(invocation))
                } else if let Some(invocation) = invocation("readSourceRange") {
                    Ok(Self::SourceRange(invocation))
                } else {
                    Err("persisted workspace.action is not a read action".into())
                }
            }
            kind => Err(format!(
                "persisted typed provider action kind {kind} is unknown"
            )),
        }
    }

    /// Swift `verify` for a read: an inspection by `WorkspaceProvider` (an
    /// exit of 1 is an honest "no occurrences"), any other read by
    /// `WorkspaceOperationsProvider` (bounded output, a zero exit, and what
    /// the output says about the tree).
    pub(crate) fn verify(&self, receipt: &ToolReceipt) -> ReadVerdict {
        if let Self::InspectSource(inspection) = self {
            let truncated = if receipt.truncated { "true" } else { "false" };
            let summary = |matches: &str| {
                BTreeMap::from([
                    ("projectRef".to_owned(), inspection.project_ref.clone()),
                    ("fileScope".to_owned(), inspection.file_scope.clone()),
                    ("matches".to_owned(), matches.to_owned()),
                    ("truncated".to_owned(), truncated.to_owned()),
                ])
            };
            return match receipt.exit_status {
                0 => ReadVerdict::Verified(summary(if receipt.stdout.is_empty() {
                    "0"
                } else {
                    "1+"
                })),
                1 => ReadVerdict::Verified(summary("0")),
                status => ReadVerdict::Failed(
                    format!("inspectorExit{status}"),
                    format!("workspace inspector failed for {}", inspection.project_ref),
                ),
            };
        }
        if receipt.truncated {
            return ReadVerdict::Failed(
                "workspace.outputTruncated".into(),
                "bounded output was truncated; semantic result is incomplete".into(),
            );
        }
        let (code, fact, empty, nonempty) = match self {
            Self::GitStatus(_) => ("workspace.gitStatusFailed", "dirty", "false", "true"),
            Self::Diff(_) => ("workspace.diffFailed", "changed", "false", "true"),
            Self::SourceRange(_) => ("workspace.sourceRangeFailed", "empty", "true", "false"),
            Self::InspectSource(_) => unreachable!("an inspection returned above"),
        };
        if receipt.exit_status != 0 {
            return ReadVerdict::Failed(code.into(), failed_detail(receipt));
        }
        let mut summary: BTreeMap<String, String> = output_summary(receipt)
            .into_iter()
            .filter_map(|(key, value)| Some((key, value.as_str()?.to_owned())))
            .collect();
        summary.insert(
            fact.into(),
            if receipt.stdout.is_empty() {
                empty
            } else {
                nonempty
            }
            .into(),
        );
        ReadVerdict::Verified(summary)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn receipt(status: i32, stdout: &[u8], truncated: bool) -> ToolReceipt {
        ToolReceipt {
            exit_status: status,
            stdout: stdout.to_vec(),
            stderr: b"diagnostic".to_vec(),
            truncated,
        }
    }

    #[test]
    fn inputs_are_screened_as_swift_screens_them() {
        assert!(validate_scope("*.ets").is_ok());
        assert!(validate_scope("[a-z]?.ts").is_ok());
        for scope in [
            "",
            "pages/*.ets",
            "..ets",
            "-x",
            "é",
            "a b",
            &"a".repeat(121),
        ] {
            assert_eq!(
                validate_scope(scope).unwrap_err(),
                format!("malformedScope({})", swift_quoted(scope)),
                "{scope:?}"
            );
        }
        assert!(validate_scope(&"a".repeat(120)).is_ok());
        assert!(validate_symbol("-v").is_ok());
        // A carriage return and its line feed are one Character, which is
        // not a line feed.
        assert!(validate_symbol("a\r\nb").is_ok());
        assert!(validate_symbol(&"e\u{301}".repeat(200)).is_ok());
        for symbol in ["", "a\nb", "a\0b", &"x".repeat(201)] {
            assert!(validate_symbol(symbol).is_err(), "{symbol:?}");
        }
        assert_eq!(
            validate_symbol("two\nlines").unwrap_err(),
            "malformedScope(\"two\\nlines\")"
        );
        assert!(validate_revision_expression("HEAD~1").is_ok());
        assert!(validate_revision_expression("main@{1}").is_ok());
        for revision in ["", "-x", "a..b", "a/b", "a b", &"a".repeat(121)] {
            assert_eq!(
                validate_revision_expression(revision).unwrap_err(),
                "workspace.malformedRevision"
            );
        }
        assert!(validate_path_scope("entry/src/*.ets").is_ok());
        for scope in ["", "-x", "/etc", "a/../b", "a b"] {
            assert_eq!(
                validate_path_scope(scope).unwrap_err(),
                "workspace.malformedPathScope"
            );
        }
    }

    #[test]
    fn a_readable_path_is_joined_as_foundation_joins_it() {
        let globs = vec!["entry/src/main/ets/**".to_owned()];
        assert_eq!(
            resolved_readable_path("entry/src/main/ets/a.ets", "/r", &globs).unwrap(),
            "/r/entry/src/main/ets/a.ets"
        );
        // Every trailing separator is dropped; nothing else is rewritten.
        assert_eq!(
            resolved_readable_path("entry/src/main/ets/pages//", "/r", &globs).unwrap(),
            "/r/entry/src/main/ets/pages"
        );
        assert_eq!(
            resolved_readable_path("entry/src/main/ets/./a", "/r", &globs).unwrap(),
            "/r/entry/src/main/ets/./a"
        );
        for path in ["", "-x", "/abs", "entry/../x", "a\0b"] {
            assert_eq!(
                resolved_readable_path(path, "/r", &globs).unwrap_err(),
                "workspace.malformedFilePath",
                "{path:?}"
            );
        }
        // A dot a combining mark follows is another Character, as is a dash.
        assert_eq!(
            resolved_readable_path("entry/src/main/ets/.\u{301}./x", "/r", &globs).unwrap(),
            "/r/entry/src/main/ets/.\u{301}./x"
        );
        assert_eq!(
            resolved_readable_path("build-profile.json5", "/r", &globs).unwrap_err(),
            "workspace.pathOutsideProfileScope"
        );
    }

    #[test]
    fn a_read_is_judged_as_swift_judges_it() {
        let inspection = ReadAction::InspectSource(SourceInspection {
            project_ref: "P".into(),
            project_root: "/r".into(),
            symbol: "s".into(),
            file_scope: "*.ets".into(),
        });
        let verified = |verdict: ReadVerdict| match verdict {
            ReadVerdict::Verified(summary) => summary,
            ReadVerdict::Failed(code, _) => panic!("failed {code}"),
        };
        assert_eq!(
            verified(inspection.verify(&receipt(0, b"x", false)))["matches"],
            "1+"
        );
        assert_eq!(
            verified(inspection.verify(&receipt(1, b"", true)))["truncated"],
            "true"
        );
        assert_eq!(
            inspection.verify(&receipt(2, b"", false)),
            ReadVerdict::Failed(
                "inspectorExit2".into(),
                "workspace inspector failed for P".into()
            )
        );
        let invocation = Invocation {
            operation: STATUS.into(),
            project_ref: "P".into(),
            project_root: "/r".into(),
            preset_id: "git".into(),
            executable_path: "/usr/bin/git".into(),
            executable_sha256: "0".repeat(64),
            argument_zero: None,
            arguments: vec!["status".into()],
            timeout_seconds: 120,
        };
        let status = ReadAction::GitStatus(invocation.clone());
        assert_eq!(
            verified(status.verify(&receipt(0, b"", false)))["dirty"],
            "false"
        );
        assert_eq!(
            status.verify(&receipt(0, b"x", true)),
            ReadVerdict::Failed(
                "workspace.outputTruncated".into(),
                "bounded output was truncated; semantic result is incomplete".into()
            )
        );
        let range = ReadAction::SourceRange(invocation.clone());
        assert_eq!(
            verified(range.verify(&receipt(0, b"", false)))["empty"],
            "true"
        );
        let diff = ReadAction::Diff(invocation);
        assert_eq!(
            diff.verify(&receipt(128, b"", false)),
            ReadVerdict::Failed(
                "workspace.diffFailed".into(),
                "real process exit=128 stdoutBytes=0 stderrBytes=10".into()
            )
        );
        for action in [status, range, diff, inspection] {
            let restored = ReadAction::materialize(&action.persisted().unwrap()).unwrap();
            match (&action, &restored) {
                (ReadAction::InspectSource(original), ReadAction::InspectSource(back)) => {
                    assert_eq!(back.project_root, "");
                    assert_eq!(back.symbol, original.symbol);
                }
                _ => assert_eq!(restored, action),
            }
        }
    }
}
