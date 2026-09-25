//! Swift's sweep of the Runtime-owned isolated copies (TASK-XPA-015, M3):
//! `WorkspaceSweepIntent`, `RuntimeOwnedWorkspaceDispatcher.dispatchSweep`
//! and the provider's verification of what it returns.
//!
//! The sweep takes no project: its subject is the whole isolation store. Its
//! testimony is composed at dispatch exclusively from two stores the Runtime
//! owns — the isolation manager's inventory of its copies, each vouched for
//! as adoption vouches (manifest, scopes, base-or-lineage revision), and the
//! Job store's durable rows (which Jobs made or named each copy, and whether
//! all of them are terminal). A copy nobody vouches for, or no Job names, is
//! not attested and is never touched. The retention clock is the intent's
//! creation instant, so a replay reasons about the moment the journal
//! recorded. What the sweep found — every `evo-` entry of the store, sorted —
//! is one canonical document whose digest the receipt pins, and which is
//! published as the product.
use crate::workspace_composition::WorkspaceComposition;
use crate::workspace_isolation::{Disposition, GcReference};
use crate::workspace_support as support;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

pub(crate) const SWEEP: &str = "workspace.sweep-isolated-copies@1";
pub(crate) const SWEEP_STEP: &str = "sweep-isolated-copies";
pub(crate) const SWEEP_KIND: &str = "sweepWorkspaceIsolation";
pub(crate) const SWEEP_PRODUCT: &str = "sweep-findings.json";
/// Swift `HostWorkspaceProcessDescriptor.identifier` for the sweep.
pub(crate) const SWEEP_DESCRIPTOR: &str = "workspace.sweep-isolated-copies/v1";

/// Swift `WorkspaceSweepIntent`: the retention the request chose, the Job
/// that owns the sweep and the instant its retention is judged at.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SweepIntent {
    pub(crate) runtime_owner_id: String,
    pub(crate) retain_latest_count: i64,
    pub(crate) minimum_quiescent_seconds: i64,
    pub(crate) dry_run: bool,
    pub(crate) created_at_utc: String,
}

impl SweepIntent {
    /// Swift's synthesized encoding of the intent.
    fn value(&self) -> Value {
        json!({
            "runtimeOwnerID": self.runtime_owner_id,
            "retainLatestCount": self.retain_latest_count,
            "minimumQuiescentSeconds": self.minimum_quiescent_seconds,
            "dryRun": self.dry_run,
            "createdAtUTC": self.created_at_utc,
        })
    }

    fn decode(value: &Value) -> Option<Self> {
        let fields = value.as_object()?;
        Some(Self {
            runtime_owner_id: fields.get("runtimeOwnerID")?.as_str()?.to_owned(),
            retain_latest_count: fields.get("retainLatestCount")?.as_i64()?,
            minimum_quiescent_seconds: fields.get("minimumQuiescentSeconds")?.as_i64()?,
            dry_run: fields.get("dryRun")?.as_bool()?,
            created_at_utc: fields.get("createdAtUTC")?.as_str()?.to_owned(),
        })
    }

    /// Swift `actionSHA256`: the digest of the intent's canonical JSON, the
    /// pin between the materialized plan and the descriptor dispatched.
    pub(crate) fn action_sha256(&self) -> Result<String, ()> {
        let bytes = crate::session_json::encode(&self.value()).map_err(|_| ())?;
        Ok(support::sha256(&bytes))
    }

    /// Swift `PersistedTypedProviderAction` of the typed action: the
    /// workspace action's canonical JSON, base64.
    pub(crate) fn persisted(&self) -> Result<Value, ()> {
        let action = json!({"sweepIsolatedCopies": {"_0": self.value()}});
        let bytes = crate::session_json::encode(&action).map_err(|_| ())?;
        Ok(json!({"kind": "workspace.action",
            "arguments": {"payload": crate::agent_execution::base64(&bytes)}}))
    }

    /// Swift `PersistedTypedProviderAction.materialize()` for a sweep: the
    /// exact typed action a record persisted, or why it cannot be one.
    pub(crate) fn materialize(persisted: &Value) -> Result<Self, String> {
        let kind = persisted["kind"].as_str().unwrap_or_default();
        if kind != "workspace.action" {
            return Err(format!(
                "persisted typed provider action kind {kind} is unknown"
            ));
        }
        persisted["arguments"]["payload"]
            .as_str()
            .and_then(crate::agent_execution::unbase64)
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .ok_or_else(|| "persisted workspace.action payload is unreadable".to_owned())?
            .get("sweepIsolatedCopies")
            .and_then(|sweep| Self::decode(&sweep["_0"]))
            .ok_or_else(|| "persisted workspace.action is not a sweep action".to_owned())
    }

    /// Swift `journalStep`'s arguments for `sweepWorkspaceIsolation`; the
    /// dry-run flag is journaled as its spelling.
    pub(crate) fn journal_arguments(&self) -> Value {
        json!({
            "retainLatestCount": self.retain_latest_count,
            "minimumQuiescentSeconds": self.minimum_quiescent_seconds,
            "dryRun": self.dry_run.to_string(),
            "artifactId": SWEEP_PRODUCT,
        })
    }
}

/// Swift `WorkspaceReferenceLedgerFacts`: what the Job store's durable rows
/// say about the Jobs referencing one copy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ReferenceFacts {
    pub(crate) referencing_job_count: usize,
    pub(crate) all_terminal: bool,
    pub(crate) newest_transition_utc: Option<String>,
}

/// What Swift's dispatcher returns for a sweep: the typed action's digest as
/// the record, the findings document as stdout, and its summary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SweepReceipt {
    pub(crate) record_id: String,
    pub(crate) stdout: Vec<u8>,
    pub(crate) summary: BTreeMap<String, String>,
}

impl WorkspaceComposition {
    /// Swift `WorkspaceOperationsProvider.action` for the sweep, routed
    /// before the per-project preamble: the provider's own profile must be a
    /// primary one with an isolation manager beside it, and the retention
    /// the request chose must lie inside its bounds. A refusal is the detail
    /// Swift's provider error describes itself by.
    pub(crate) fn sweep_action(
        &self,
        inputs: &Map<String, Value>,
        job_id: &str,
        now: &str,
    ) -> Result<SweepIntent, String> {
        if !self.provides_isolation() {
            return Err("workspace.isolationManagerUnavailable".into());
        }
        let integer = |key: &str| {
            inputs
                .get(key)
                .and_then(Value::as_i64)
                .ok_or_else(|| format!("workspace input {key} is missing"))
        };
        let retain_latest_count = integer("retainLatestCount")?;
        let minimum_quiescent_seconds = integer("minimumQuiescentSeconds")?;
        if !(0..=64).contains(&retain_latest_count)
            || !(0..=7_776_000).contains(&minimum_quiescent_seconds)
        {
            return Err("workspace.sweepInputsOutOfBounds".into());
        }
        let Some(dry_run) = inputs.get("dryRun").and_then(Value::as_bool) else {
            return Err("workspace.sweepInputsIncomplete:dryRun".into());
        };
        Ok(SweepIntent {
            runtime_owner_id: format!("runtime-{job_id}"),
            retain_latest_count,
            minimum_quiescent_seconds,
            dry_run,
            created_at_utc: now.into(),
        })
    }

    /// Swift `lower(action:context:)` for the sweep: a host action owned by
    /// this Job, pinned by the digest of its typed intent.
    pub(crate) fn lower_sweep(&self, intent: &SweepIntent, job_id: &str) -> Result<String, String> {
        if !self.provides_isolation() || intent.runtime_owner_id != format!("runtime-{job_id}") {
            return Err("workspace sweep action is not owned by this Job".into());
        }
        let action = intent
            .action_sha256()
            .map_err(|_| "workspace sweep action cannot be encoded".to_owned())?;
        Ok(format!("{SWEEP_DESCRIPTOR}#action-sha256:{action}"))
    }

    /// Swift `RuntimeOwnedWorkspaceDispatcher.dispatchSweep`: the testimony
    /// composed from the vouched inventory and the Job store (`ledger`), the
    /// terminal copies swept under the intent's retention, and the findings
    /// as one canonical document. A refusal is Swift's receipt failure.
    pub(crate) fn dispatch_sweep(
        &self,
        intent: &SweepIntent,
        job_id: &str,
        ledger: &dyn Fn(&str, &str) -> Result<ReferenceFacts, String>,
    ) -> Result<SweepReceipt, String> {
        if intent.runtime_owner_id != format!("runtime-{job_id}") {
            return Err("workspace sweep plan drifted from its typed action".into());
        }
        let record_id = intent
            .action_sha256()
            .map_err(|_| "workspace sweep plan drifted from its typed action".to_owned())?;
        if self.isolation.is_none() {
            return Err("workspace sweep refused: no isolation store in this composition".into());
        }
        fn refused<T>(_: T) -> String {
            "workspace sweep refused".to_owned()
        }
        let mut references = Vec::new();
        let mut attested: BTreeMap<String, ReferenceFacts> = BTreeMap::new();
        for entry in self
            .runtime_workspace_inventory()
            .into_iter()
            .filter(|entry| entry.vouched)
        {
            let facts =
                ledger(&entry.runtime_owner_id, &entry.derived_project_ref).map_err(refused)?;
            if facts.referencing_job_count == 0 {
                continue;
            }
            references.push(GcReference {
                workspace_id: entry.workspace_id.clone(),
                htask_id: entry.runtime_owner_id.clone(),
                lifecycle: if facts.all_terminal {
                    "quiescent"
                } else {
                    "activeJob"
                },
                is_terminal: facts.all_terminal,
                updated_at_utc: facts
                    .newest_transition_utc
                    .clone()
                    .unwrap_or_else(|| entry.created_at_utc.clone()),
            });
            attested.insert(entry.workspace_id, facts);
        }
        let findings = self
            .sweep_terminal_workspaces(
                &references,
                intent.minimum_quiescent_seconds,
                intent.retain_latest_count,
                intent.dry_run,
                &intent.created_at_utc,
            )
            .map_err(refused)?;
        let mut entries = Vec::new();
        let mut destroyed = 0_usize;
        for finding in &findings {
            if finding.disposition == Disposition::Destroyed {
                destroyed += 1;
            }
            let mut fields = json!({
                "workspaceId": finding.workspace_id,
                "disposition": finding.disposition.raw(),
                "reclaimedBytes": finding.reclaimed_bytes,
            });
            if let Some(facts) = attested.get(&finding.workspace_id) {
                fields["referencingJobs"] = json!(facts.referencing_job_count);
                fields["allReferencesTerminal"] = json!(facts.all_terminal);
                if let Some(newest) = &facts.newest_transition_utc {
                    fields["newestReferenceTransitionUtc"] = json!(newest);
                }
            }
            entries.push(fields);
        }
        let document = json!({
            "documentType": "arkdeck-workspace-sweep",
            "schemaVersion": "1.0.0",
            "dryRun": intent.dry_run,
            "retainLatestCount": intent.retain_latest_count,
            "minimumQuiescentSeconds": intent.minimum_quiescent_seconds,
            "sweptAtUtc": intent.created_at_utc,
            "findings": entries,
        });
        let stdout = crate::session_json::encode_canonical_pretty(&document).map_err(refused)?;
        let summary = BTreeMap::from([
            ("destroyed".to_owned(), destroyed.to_string()),
            (
                "retained".to_owned(),
                (findings.len() - destroyed).to_string(),
            ),
            ("dryRun".to_owned(), intent.dry_run.to_string()),
            ("findingsSha256".to_owned(), support::sha256(&stdout)),
        ]);
        Ok(SweepReceipt {
            record_id,
            stdout,
            summary,
        })
    }
}

/// Swift `WorkspaceOperationsProvider.verify` for the sweep: the receipt
/// must be the typed action's — its record, its dry-run flag — and its
/// findings digest the stdout's; its summary is then the verified facts.
pub(crate) fn verify_sweep(
    intent: &SweepIntent,
    receipt: &SweepReceipt,
) -> Result<BTreeMap<String, String>, (&'static str, &'static str)> {
    let count = |key: &str| {
        receipt
            .summary
            .get(key)
            .and_then(|value| value.parse::<i64>().ok())
            .filter(|count| *count >= 0)
    };
    let action = intent.action_sha256().ok();
    if action.as_deref() != Some(receipt.record_id.as_str())
        || receipt.summary.get("findingsSha256") != Some(&support::sha256(&receipt.stdout))
        || receipt.summary.get("dryRun") != Some(&intent.dry_run.to_string())
        || count("destroyed").is_none()
        || count("retained").is_none()
    {
        return Err((
            "workspace.sweepReceiptInvalid",
            "sweep receipt is absent or disagrees with the typed action",
        ));
    }
    Ok(receipt.summary.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn intent() -> SweepIntent {
        SweepIntent {
            runtime_owner_id: "runtime-job-1".into(),
            retain_latest_count: 1,
            minimum_quiescent_seconds: 3_600,
            dry_run: true,
            created_at_utc: "2026-09-25T00:00:00Z".into(),
        }
    }

    #[test]
    fn the_persisted_sweep_is_the_sweep() {
        let intent = intent();
        assert_eq!(
            SweepIntent::materialize(&intent.persisted().unwrap()).unwrap(),
            intent
        );
        assert_eq!(intent.journal_arguments()["dryRun"], "true");
        // Swift's canonical encoding: sorted keys, no whitespace.
        assert_eq!(
            crate::session_json::encode(&intent.value()).unwrap(),
            b"{\"createdAtUTC\":\"2026-09-25T00:00:00Z\",\"dryRun\":true,\
              \"minimumQuiescentSeconds\":3600,\"retainLatestCount\":1,\
              \"runtimeOwnerID\":\"runtime-job-1\"}"
                .to_vec()
        );
    }

    #[test]
    fn a_receipt_must_be_the_actions_own() {
        let intent = intent();
        let stdout = b"{}".to_vec();
        let receipt = SweepReceipt {
            record_id: intent.action_sha256().unwrap(),
            summary: BTreeMap::from([
                ("destroyed".to_owned(), "0".to_owned()),
                ("retained".to_owned(), "2".to_owned()),
                ("dryRun".to_owned(), "true".to_owned()),
                ("findingsSha256".to_owned(), support::sha256(&stdout)),
            ]),
            stdout,
        };
        assert!(verify_sweep(&intent, &receipt).is_ok());
        for drift in [
            SweepReceipt {
                record_id: "0".repeat(64),
                ..receipt.clone()
            },
            SweepReceipt {
                stdout: b"{ }".to_vec(),
                ..receipt.clone()
            },
        ] {
            assert_eq!(
                verify_sweep(&intent, &drift).unwrap_err().0,
                "workspace.sweepReceiptInvalid"
            );
        }
        let mut wet = receipt.clone();
        wet.summary.insert("dryRun".into(), "false".into());
        assert!(verify_sweep(&intent, &wet).is_err());
        let mut negative = receipt;
        negative.summary.insert("destroyed".into(), "-1".into());
        assert!(verify_sweep(&intent, &negative).is_err());
    }
}
