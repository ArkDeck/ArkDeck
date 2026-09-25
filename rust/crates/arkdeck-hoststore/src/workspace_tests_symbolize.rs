//! Swift `WorkspaceOperationsProvider` for `workspace.run-tests@1` and
//! `workspace.symbolize-crash@1` (TASK-XPA-015, M3): the typed actions — a
//! preset's resolved invocation, persisted as Swift's `runTests` and
//! `symbolizeCrash` cases — their journal arguments, and the verdicts the
//! provider's `verify` gives a finished child.
//!
//! A test run is the test preset's pinned executable (a registered DevEco
//! toolchain's Node running its pinned `hvigorw.js`) with the preset's own
//! closed argv, in the project root: a device mutation under a standing
//! capability, which the Runtime issues only for its own isolated copies. A
//! symbolization is the symbol preset's pinned executable (the daemon in its
//! one-shot `--symbolize-crash <map>` mode) with the crash dump's path
//! appended — a device-bound `crash-log.txt` that `capture.diagnostics@1`
//! collected from another target — run host-only in the project root.
use crate::workspace_composition::PatchVerdict;
use crate::workspace_patch::{Invocation, ToolReceipt, failed_detail, output_summary};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

pub(crate) const TESTS: &str = "workspace.run-tests@1";
pub(crate) const TESTS_STEP: &str = "run-tests";
pub(crate) const TESTS_KIND: &str = "runWorkspaceTests";
pub(crate) const TESTS_PRODUCT: &str = "test-output.log";
pub(crate) const SYMBOLIZE: &str = "workspace.symbolize-crash@1";
pub(crate) const SYMBOLIZE_STEP: &str = "symbolize-crash";
pub(crate) const SYMBOLIZE_KIND: &str = "symbolizeWorkspaceCrash";
pub(crate) const SYMBOLIZE_PRODUCT: &str = "symbolized-crash.txt";

/// Swift `WorkspaceProviderAction`'s `runTests` and `symbolizeCrash` cases.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum PresetAction {
    Tests(Invocation),
    Symbolize(Invocation),
}

impl PresetAction {
    pub(crate) fn invocation(&self) -> &Invocation {
        match self {
            Self::Tests(invocation) | Self::Symbolize(invocation) => invocation,
        }
    }

    /// Swift's synthesized encoding of the action enum.
    fn value(&self) -> Value {
        match self {
            Self::Tests(invocation) => json!({"runTests": {"_0": invocation.value()}}),
            Self::Symbolize(invocation) => json!({"symbolizeCrash": {"_0": invocation.value()}}),
        }
    }

    /// Swift `PersistedTypedProviderAction` of the typed action: the
    /// workspace action's canonical JSON, base64.
    pub(crate) fn persisted(&self) -> Result<Value, ()> {
        let bytes = crate::session_json::encode(&self.value()).map_err(|_| ())?;
        Ok(json!({"kind": "workspace.action",
            "arguments": {"payload": crate::agent_execution::base64(&bytes)}}))
    }

    /// Swift `PersistedTypedProviderAction.materialize()` for either case:
    /// the exact typed action a record persisted, or why it cannot be one.
    pub(crate) fn materialize(persisted: &Value) -> Result<Self, String> {
        let kind = persisted["kind"].as_str().unwrap_or_default();
        if kind != "workspace.action" {
            return Err(format!(
                "persisted typed provider action kind {kind} is unknown"
            ));
        }
        let payload = persisted["arguments"]["payload"]
            .as_str()
            .and_then(crate::agent_execution::unbase64)
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .ok_or("persisted workspace.action payload is unreadable")?;
        let action = if let Some(tests) = payload.get("runTests") {
            Invocation::decode(&tests["_0"]).map(Self::Tests)
        } else if let Some(symbolize) = payload.get("symbolizeCrash") {
            Invocation::decode(&symbolize["_0"]).map(Self::Symbolize)
        } else {
            None
        };
        action.ok_or_else(|| "persisted workspace.action is not a test or symbol action".into())
    }

    /// Swift `journalStep`'s arguments: the request's project and preset,
    /// and for a symbolization the dump's identity as the lease resolved it.
    pub(crate) fn journal_arguments(
        &self,
        inputs: &Map<String, Value>,
        dump: Option<(&str, &str)>,
    ) -> Value {
        match (self, dump) {
            (Self::Tests(_), _) => json!({
                "projectRef": inputs.get("projectRef"),
                "testPresetRef": inputs.get("testPresetRef"),
            }),
            (Self::Symbolize(_), dump) => json!({
                "projectRef": inputs.get("projectRef"),
                "dumpArtifactId": dump.map(|(id, _)| id),
                "dumpSha256": dump.map(|(_, sha256)| sha256),
                "symbolPresetRef": inputs.get("symbolPresetRef"),
            }),
        }
    }

    /// Swift `WorkspaceOperationsProvider.verify`: a truncated output is no
    /// verdict; tests pass on a zero exit; a symbolization needs a zero exit
    /// and a report.
    pub(crate) fn verify(&self, receipt: &ToolReceipt) -> PatchVerdict {
        if receipt.truncated {
            return PatchVerdict::Failed(
                "workspace.outputTruncated",
                "bounded output was truncated; semantic result is incomplete".into(),
            );
        }
        let passed = match self {
            Self::Tests(_) => receipt.exit_status == 0,
            Self::Symbolize(_) => receipt.exit_status == 0 && !receipt.stdout.is_empty(),
        };
        if !passed {
            let code = match self {
                Self::Tests(_) => "workspace.testsFailed",
                Self::Symbolize(_) => "workspace.symbolizationFailed",
            };
            return PatchVerdict::Failed(code, failed_detail(receipt));
        }
        let summary: BTreeMap<String, String> = output_summary(receipt)
            .into_iter()
            .filter_map(|(key, value)| Some((key, value.as_str()?.to_owned())))
            .collect();
        PatchVerdict::Verified(summary)
    }
}

/// Swift `validateResolvedInputArtifact` for `workspace.symbolize-crash@1`:
/// the request is scoped to the project whose symbols are used, while its
/// input was captured from a device — so the dump must be exactly the
/// device-bound `crash-log.txt` `capture.diagnostics@1` published through
/// the HDC provider, with a complete binding, and from a target other than
/// the one the request names (the error Swift interpolates otherwise).
pub(crate) fn dump_refusal(
    row: &Value,
    request_target: &str,
    request_binding_revision: Option<i64>,
) -> Option<String> {
    let binding = &row["bindingSnapshot"];
    let lowercase_sha256 = |value: &str| {
        value.len() == 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    };
    let admitted = row["name"] == "crash-log.txt"
        && row["sourceOperation"] == "capture.diagnostics@1"
        && row["providerID"] == "hdc"
        && request_binding_revision.is_none()
        && binding["targetID"] != request_target
        && binding["bindingRevision"]
            .as_i64()
            .is_some_and(|revision| revision > 0)
        && binding["stableIdentitySHA256"]
            .as_str()
            .is_some_and(lowercase_sha256);
    (!admitted).then(|| {
        format!(
            "rejected(ArkDeckCore.RuntimeOperationErrorCode.invalidInput, {})",
            crate::artifact_read_owner::swift_string(
                "workspace crash dump lease is not a device-bound capture.diagnostics crash-log.txt"
            )
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn invocation() -> Invocation {
        Invocation {
            operation: TESTS.into(),
            project_ref: "Project".into(),
            project_root: "/tmp/project".into(),
            preset_id: "tests".into(),
            executable_path: "/tmp/node".into(),
            executable_sha256: "0".repeat(64),
            argument_zero: None,
            arguments: vec!["hvigorw.js".into(), "test".into()],
            timeout_seconds: 60,
        }
    }

    fn receipt(exit_status: i32, stdout: &[u8]) -> ToolReceipt {
        ToolReceipt {
            exit_status,
            stdout: stdout.to_vec(),
            stderr: Vec::new(),
            truncated: false,
        }
    }

    #[test]
    fn the_verdicts_are_swifts() {
        let tests = PresetAction::Tests(invocation());
        assert!(matches!(
            tests.verify(&receipt(0, b"")),
            PatchVerdict::Verified(_)
        ));
        assert!(matches!(
            tests.verify(&receipt(1, b"x")),
            PatchVerdict::Failed("workspace.testsFailed", _)
        ));
        let symbolize = PresetAction::Symbolize(invocation());
        assert!(matches!(
            symbolize.verify(&receipt(0, b"")),
            PatchVerdict::Failed("workspace.symbolizationFailed", _)
        ));
        assert!(matches!(
            symbolize.verify(&receipt(0, b"report")),
            PatchVerdict::Verified(_)
        ));
        for action in [tests, symbolize] {
            assert_eq!(
                PresetAction::materialize(&action.persisted().unwrap()).unwrap(),
                action
            );
        }
    }

    #[test]
    fn only_a_device_bound_crash_log_is_a_dump() {
        let row = json!({"name": "crash-log.txt", "sourceOperation": "capture.diagnostics@1",
            "providerID": "hdc", "bindingSnapshot": {"targetID": "device",
            "bindingRevision": 3, "stableIdentitySHA256": "ab".repeat(32)}});
        assert_eq!(dump_refusal(&row, "workspace-host", None), None);
        assert!(dump_refusal(&row, "device", None).is_some());
        assert!(dump_refusal(&row, "workspace-host", Some(1)).is_some());
        for (field, value) in [
            ("name", json!("crash-index.txt")),
            ("sourceOperation", json!("capture.screenshot@1")),
            ("providerID", json!("host")),
        ] {
            let mut other = row.clone();
            other[field] = value;
            assert!(
                dump_refusal(&other, "workspace-host", None).is_some(),
                "{field}"
            );
        }
        for binding in [
            json!({"targetID": "device", "bindingRevision": 0, "stableIdentitySHA256": "ab".repeat(32)}),
            json!({"targetID": "device", "bindingRevision": 3, "stableIdentitySHA256": "AB".repeat(32)}),
            json!({"targetID": "device", "bindingRevision": 3}),
        ] {
            let mut other = row.clone();
            other["bindingSnapshot"] = binding;
            assert!(dump_refusal(&other, "workspace-host", None).is_some());
        }
    }
}
