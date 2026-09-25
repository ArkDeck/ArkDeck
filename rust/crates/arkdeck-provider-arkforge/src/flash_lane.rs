//! The seam between the Runtime's Flash execution and the ArkForge lane that
//! performs its delegated steps: Swift `RuntimeJobEngine.ArkForgeLane`, the
//! values it carries and the receipts it returns.
//!
//! The Runtime owns admission, the destructive capability, the write-ahead
//! journal and the Job's terminal state. The lane only makes the archive
//! available to `arkforged`, creates the correlated daemon job and drives it
//! under the permits the Runtime's authority signs. A lane never invents a
//! receipt: what it returns is the daemon's, and the Runtime validates it
//! again (`validate_completion`) before it confirms anything.

use arkdeck_contract::sha256_hex;
use std::path::PathBuf;

/// Swift `ArkForgeLaneArtifact`: the archive a delegated step writes, as the
/// Runtime already resolved and measured it, and the exact `id@version` of
/// the DeviceProfile `arkforged` loaded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaneArtifact {
    pub path: PathBuf,
    pub sha256: String,
    pub profile_id: String,
}

/// Swift `ArkForgeLaneArtifactPrewarmReceipt`: what the lane learned while
/// making an admitted Job's archive ready. It has no device binding and no
/// authority, so it cannot start an execution.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrewarmReceipt {
    pub artifact_sha256: String,
    pub profile_id: String,
    pub imported: bool,
    pub duration_milliseconds: u64,
}

/// Swift `ArkForgeLaneDeviceBinding`: the device a delegated step was
/// admitted against, carried rather than resolved again by the lane.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceBinding {
    pub connect_key: String,
    pub stable_identity_sha256: String,
    pub target_id: String,
    pub binding_revision: i64,
    pub usb_topology: String,
}

/// Swift `RuntimeArkForgeLaneExecution`: the durable join between one
/// Runtime attempt and the daemon job that owns its external effects. It is
/// persisted before the Runtime writes its own step intent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Execution {
    pub arkdeck_job_id: String,
    pub daemon_job_id: String,
    pub plan_id: String,
    pub plan_sha256: String,
    pub execution_purpose: String,
    pub artifact_sha256: String,
    pub artifact_profile_id: String,
    pub target_id: String,
    pub binding_revision: i64,
    pub stable_identity_sha256: String,
    pub usb_topology: String,
    pub observation_mode: String,
    pub toolchain_sha256: String,
}

/// Swift `ArkForgeActionReceiptSummary`, the daemon's semantic receipt of
/// one action; its facts keep the daemon's order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActionReceipt {
    pub job_id: String,
    pub plan_id: String,
    pub step_id: String,
    pub action_id: String,
    pub attempt_id: String,
    pub permit_id: String,
    pub disposition: String,
    pub evidence_sha256: Vec<u8>,
    pub verification_outcome: String,
    pub verification_strength: String,
    pub verified_range_start: u64,
    pub verified_range_length: u64,
    pub typed_skip_reason: String,
    pub failure_classification: String,
    pub facts: Vec<(String, String)>,
}

/// Why a lane call did not complete, in the terms the Runtime classifies an
/// external effect by: Swift `RuntimeDispatchFailure`'s cases, each with its
/// reason, and any other error by its description.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LaneFailure {
    /// The daemon confirmed the action failed; the device state is known.
    Failed(String),
    /// The daemon confirmed nothing was executed.
    ConfirmedNotExecuted(String),
    /// Nobody can say what happened; never replayed.
    OutcomeUnknown(String),
    /// Anything else, as its description reads.
    Other(String),
}

/// Swift `ArkForgeFlashSession.Outcome`: an existing daemon job's terminal,
/// read passively.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Terminal {
    Completed(Vec<ActionReceipt>),
    ConfirmedFailed(String),
    CancelledSafe,
    OutcomeUnknown(String),
}

/// Swift `RuntimeJobEngine.ArkForgeLane`.
pub trait FlashLane: Send + Sync {
    /// The exact backend digest the lane was composed against, which every
    /// StepPermit binds.
    fn toolchain_sha256(&self) -> &str;

    /// Makes the archive available to the daemon after admission. It may
    /// touch only ArkForge's content-addressed host store.
    fn prewarm(&self, job_id: &str, artifact: &LaneArtifact)
    -> Result<PrewarmReceipt, LaneFailure>;

    /// Releases the lane's per-Job preparation bookkeeping.
    fn finish_prewarm(&self, job_id: &str);

    /// Materializes and creates the daemon job without watching it or
    /// signing a permit; the Runtime persists the join before it goes on.
    fn prepare(
        &self,
        job_id: &str,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
        purpose: &str,
    ) -> Result<Execution, LaneFailure>;

    /// Drives one already-correlated delegated step and returns the daemon's
    /// terminal receipt.
    fn perform(
        &self,
        step_id: &str,
        execution: &Execution,
        artifact: &LaneArtifact,
        binding: &DeviceBinding,
    ) -> Result<ActionReceipt, LaneFailure>;

    /// Passively reads the correlated daemon job: never admits, never
    /// submits a control receipt, never creates a replacement job. `Err` is
    /// the error's description.
    fn observe_terminal(&self, execution: &Execution) -> Result<Option<Terminal>, String>;

    /// The terminal receipt of this Job's completed lane run, if it ran; a
    /// safe cancellation or an unknown terminal is not one.
    fn completed_plan_receipt(&self, job_id: &str) -> Option<ActionReceipt>;

    /// The operator-named hardware acceptance campaign the lane is bound to;
    /// none while the lane is hardware-gated (DEC-014, DEC-016).
    fn hardware_acceptance_campaign(&self) -> Option<String> {
        None
    }
}

/// Swift `ArkForgeManagedControlPort.canonicalFactsDigest`: every fact as
/// `key=value` and a newline, in the byte order of the keys, hashed. `None`
/// when a key repeats, which a dictionary could not hold.
pub fn canonical_facts_digest(facts: &[(String, String)]) -> Option<Vec<u8>> {
    let mut ordered: Vec<&(String, String)> = facts.iter().collect();
    ordered.sort_by(|left, right| left.0.as_bytes().cmp(right.0.as_bytes()));
    if ordered.windows(2).any(|pair| pair[0].0 == pair[1].0) {
        return None;
    }
    let mut bytes = Vec::new();
    for (key, value) in ordered {
        bytes.extend_from_slice(key.as_bytes());
        bytes.push(b'=');
        bytes.extend_from_slice(value.as_bytes());
        bytes.push(b'\n');
    }
    hex_bytes(&sha256_hex(&bytes))
}

fn hex_bytes(hex: &str) -> Option<Vec<u8>> {
    (0..hex.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(hex.get(index..index + 2)?, 16).ok())
        .collect()
}

/// Swift `validateArkForgePlanCompletionReceipt`: the terminal
/// managed-control receipt that stands for a completed plan's ordered
/// postflight. The evidence digest is recomputed over the exact facts, and
/// the facts a postflight must carry are required, so a write receipt, a
/// typed skip or an arbitrary success cannot pass as completion. When the
/// Runtime holds the correlated execution, the receipt must name its daemon
/// job, its plan and its USB topology.
pub fn validate_completion(receipt: &ActionReceipt, execution: Option<&Execution>) -> bool {
    let fact = |key: &str| {
        receipt
            .facts
            .iter()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value.as_str())
    };
    let Some(digest) = canonical_facts_digest(&receipt.facts) else {
        return false;
    };
    let matches_execution = execution.is_none_or(|correlated| {
        receipt.job_id == correlated.daemon_job_id
            && receipt.plan_id == correlated.plan_id
            && fact("usbTopology") == Some(correlated.usb_topology.as_str())
    });
    receipt.job_id.starts_with("JOB-")
        && receipt.plan_id.starts_with("PLAN-")
        && receipt.step_id.starts_with("STEP-")
        && !receipt.permit_id.is_empty()
        && receipt.disposition == "semanticSuccess"
        && receipt.evidence_sha256.len() == 32
        && receipt.evidence_sha256 == digest
        && fact("const.product.model").is_some_and(|value| !value.is_empty())
        && fact("const.ohos.fullname").is_some_and(|value| !value.is_empty())
        && fact("usbTopology").is_some_and(|value| !value.is_empty())
        && matches_execution
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts() -> Vec<(String, String)> {
        vec![
            ("const.product.model".into(), "DAYU200".into()),
            ("const.ohos.fullname".into(), "OpenHarmony-7.0.0.36".into()),
            ("usbTopology".into(), "42".into()),
        ]
    }

    fn receipt(facts: Vec<(String, String)>) -> ActionReceipt {
        ActionReceipt {
            job_id: "JOB-FLASH-1".into(),
            plan_id: "PLAN-FLASH-1".into(),
            step_id: "STEP-023".into(),
            action_id: String::new(),
            attempt_id: String::new(),
            permit_id: "PERMIT-FLASH-1".into(),
            disposition: "semanticSuccess".into(),
            evidence_sha256: canonical_facts_digest(&facts).unwrap(),
            verification_outcome: String::new(),
            verification_strength: String::new(),
            verified_range_start: 0,
            verified_range_length: 0,
            typed_skip_reason: String::new(),
            failure_classification: String::new(),
            facts,
        }
    }

    /// The digest Swift computes for these facts: sorted by key bytes, each
    /// `key=value\n`.
    #[test]
    fn the_facts_digest_is_swifts() {
        let expected = sha256_hex(
            b"const.ohos.fullname=OpenHarmony-7.0.0.36\nconst.product.model=DAYU200\nusbTopology=42\n",
        );
        let digest = canonical_facts_digest(&facts()).unwrap();
        assert_eq!(
            digest
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>(),
            expected
        );
        let mut reversed = facts();
        reversed.reverse();
        assert_eq!(canonical_facts_digest(&reversed).unwrap(), digest);
        let mut repeated = facts();
        repeated.push(("usbTopology".into(), "43".into()));
        assert_eq!(canonical_facts_digest(&repeated), None);
    }

    #[test]
    fn only_a_canonical_postflight_receipt_completes_a_plan() {
        let execution = Execution {
            arkdeck_job_id: "job-1".into(),
            daemon_job_id: "JOB-FLASH-1".into(),
            plan_id: "PLAN-FLASH-1".into(),
            plan_sha256: "7".repeat(64),
            execution_purpose: "primaryFlash".into(),
            artifact_sha256: "a".repeat(64),
            artifact_profile_id: "org.openharmony.dayu200@1.0.0".into(),
            target_id: "TGT-1".into(),
            binding_revision: 1,
            stable_identity_sha256: "9".repeat(64),
            usb_topology: "42".into(),
            observation_mode: "loader".into(),
            toolchain_sha256: "c".repeat(64),
        };
        let good = receipt(facts());
        assert!(validate_completion(&good, Some(&execution)));
        assert!(validate_completion(&good, None));

        let mut wrong_digest = good.clone();
        wrong_digest.evidence_sha256 = vec![0; 32];
        assert!(!validate_completion(&wrong_digest, None));

        let mut other_job = good.clone();
        other_job.job_id = "JOB-FLASH-2".into();
        assert!(validate_completion(&other_job, None));
        assert!(!validate_completion(&other_job, Some(&execution)));

        let mut other_port = execution.clone();
        other_port.usb_topology = "43".into();
        assert!(!validate_completion(&good, Some(&other_port)));

        let mut skipped = good.clone();
        skipped.disposition = "typedSkip".into();
        assert!(!validate_completion(&skipped, None));

        let without_build = receipt(vec![
            ("const.product.model".into(), "DAYU200".into()),
            ("usbTopology".into(), "42".into()),
        ]);
        assert!(!validate_completion(&without_build, None));

        let mut unpermitted = good;
        unpermitted.permit_id.clear();
        assert!(!validate_completion(&unpermitted, None));
    }
}
