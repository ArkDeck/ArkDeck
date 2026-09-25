//! Swift `ArkForgeRuntimeJobState`: the ArkForge-only sidecar of one Runtime
//! Job, `jobs/<jobID>/arkforge-runtime-state.json`, beside its record rather
//! than inside it. It keeps the cross-process join and the daemon's terminal
//! receipt in the record's own order: the join before the step intent, the
//! receipt before the step outcome.
//!
//! An absent file is the state before any daemon job was prepared. Bytes
//! that are not the current durable shape, exactly, fail closed (Swift
//! `CurrentDurableJSON`): the exact correlation is never discarded or
//! guessed.
use super::{DocumentPublishError, JobStore, JobWriteError, guard_unavailable};
use crate::job_repository::identifier;
use crate::session_json;
use arkdeck_provider_arkforge::{ActionReceipt, Execution};
use serde_json::{Map, Value, json};
use std::io;

const SCHEMA_VERSION: &str = "arkdeck-arkforge-runtime-state/v1";
const FILE: &str = "arkforge-runtime-state.json";
const BOUND: usize = 1024 * 1024;

/// One Job's ArkForge state: the correlated daemon job once it was prepared,
/// and the completed plan's terminal receipt once it was accepted.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ArkForgeJobState {
    pub(crate) execution: Option<Execution>,
    pub(crate) completion: Option<ActionReceipt>,
}

fn execution_value(execution: &Execution) -> Value {
    json!({
        "arkDeckJobID": execution.arkdeck_job_id,
        "daemonJobID": execution.daemon_job_id,
        "planID": execution.plan_id,
        "planSHA256": execution.plan_sha256,
        "executionPurpose": execution.execution_purpose,
        "artifactSHA256": execution.artifact_sha256,
        "artifactProfileID": execution.artifact_profile_id,
        "targetID": execution.target_id,
        "bindingRevision": execution.binding_revision,
        "stableIdentitySHA256": execution.stable_identity_sha256,
        "usbTopology": execution.usb_topology,
        "observationMode": execution.observation_mode,
        "toolchainSHA256": execution.toolchain_sha256,
    })
}

/// Swift `RuntimeArkForgePlanCompletionReceipt`'s coding.
pub(crate) fn receipt_value(receipt: &ActionReceipt) -> Value {
    json!({
        "jobID": receipt.job_id,
        "planID": receipt.plan_id,
        "stepID": receipt.step_id,
        "actionID": receipt.action_id,
        "attemptID": receipt.attempt_id,
        "permitID": receipt.permit_id,
        "disposition": receipt.disposition,
        "evidenceSHA256": receipt.evidence_sha256,
        "verificationOutcome": receipt.verification_outcome,
        "verificationStrength": receipt.verification_strength,
        "verifiedRangeStart": receipt.verified_range_start,
        "verifiedRangeLength": receipt.verified_range_length,
        "typedSkipReason": receipt.typed_skip_reason,
        "failureClassification": receipt.failure_classification,
        "facts": receipt.facts.iter().map(|(key, value)| json!({"key": key, "value": value}))
            .collect::<Vec<_>>(),
    })
}

fn text(fields: &Map<String, Value>, key: &str) -> Option<String> {
    fields.get(key)?.as_str().map(str::to_owned)
}

fn execution_from(value: &Value) -> Option<Execution> {
    let fields = value.as_object()?;
    Some(Execution {
        arkdeck_job_id: text(fields, "arkDeckJobID")?,
        daemon_job_id: text(fields, "daemonJobID")?,
        plan_id: text(fields, "planID")?,
        plan_sha256: text(fields, "planSHA256")?,
        execution_purpose: text(fields, "executionPurpose")?,
        artifact_sha256: text(fields, "artifactSHA256")?,
        artifact_profile_id: text(fields, "artifactProfileID")?,
        target_id: text(fields, "targetID")?,
        binding_revision: fields.get("bindingRevision")?.as_i64()?,
        stable_identity_sha256: text(fields, "stableIdentitySHA256")?,
        usb_topology: text(fields, "usbTopology")?,
        observation_mode: text(fields, "observationMode")?,
        toolchain_sha256: text(fields, "toolchainSHA256")?,
    })
}

fn receipt_from(value: &Value) -> Option<ActionReceipt> {
    let fields = value.as_object()?;
    Some(ActionReceipt {
        job_id: text(fields, "jobID")?,
        plan_id: text(fields, "planID")?,
        step_id: text(fields, "stepID")?,
        action_id: text(fields, "actionID")?,
        attempt_id: text(fields, "attemptID")?,
        permit_id: text(fields, "permitID")?,
        disposition: text(fields, "disposition")?,
        evidence_sha256: fields
            .get("evidenceSHA256")?
            .as_array()?
            .iter()
            .map(|byte| u8::try_from(byte.as_u64()?).ok())
            .collect::<Option<_>>()?,
        verification_outcome: text(fields, "verificationOutcome")?,
        verification_strength: text(fields, "verificationStrength")?,
        verified_range_start: fields.get("verifiedRangeStart")?.as_u64()?,
        verified_range_length: fields.get("verifiedRangeLength")?.as_u64()?,
        typed_skip_reason: text(fields, "typedSkipReason")?,
        failure_classification: text(fields, "failureClassification")?,
        facts: fields
            .get("facts")?
            .as_array()?
            .iter()
            .map(|fact| {
                let fact = fact.as_object()?;
                Some((text(fact, "key")?, text(fact, "value")?))
            })
            .collect::<Option<_>>()?,
    })
}

impl ArkForgeJobState {
    /// Swift's synthesized coding: an absent part is left out, never null.
    pub(crate) fn value(&self) -> Value {
        let mut fields = Map::new();
        fields.insert("schemaVersion".into(), json!(SCHEMA_VERSION));
        if let Some(execution) = &self.execution {
            fields.insert("execution".into(), execution_value(execution));
        }
        if let Some(receipt) = &self.completion {
            fields.insert("planCompletionReceipt".into(), receipt_value(receipt));
        }
        Value::Object(fields)
    }

    /// Swift `CurrentDurableJSON.decode` of the state: the current schema,
    /// and a document that encodes back to itself exactly.
    pub(crate) fn from_value(value: &Value) -> Option<Self> {
        let fields = value.as_object()?;
        if fields.get("schemaVersion")? != SCHEMA_VERSION {
            return None;
        }
        let state = Self {
            execution: match fields.get("execution") {
                Some(execution) => Some(execution_from(execution)?),
                None => None,
            },
            completion: match fields.get("planCompletionReceipt") {
                Some(receipt) => Some(receipt_from(receipt)?),
                None => None,
            },
        };
        (state.value() == *value).then_some(state)
    }
}

impl JobStore {
    /// The Job's ArkForge state, read through no link; an absent file is the
    /// empty state, and bytes that are not its current shape are an error.
    pub(crate) fn arkforge_state(&self, job_id: &str) -> io::Result<ArkForgeJobState> {
        if !identifier(job_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "The Job identity is not a Runtime identifier",
            ));
        }
        let bytes = match self.root.child("jobs")?.child(job_id)?.read(FILE, BOUND) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(ArkForgeJobState::default());
            }
            other => other?,
        };
        session_json::parse_foundation(&bytes)
            .ok()
            .as_ref()
            .and_then(ArkForgeJobState::from_value)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "the Job's ArkForge state is not its current durable shape",
                )
            })
    }

    /// Swift `ArkForgeRuntimeJobState.persist(into:)`: the whole state,
    /// replaced atomically in the Job's directory, as its JSONEncoder
    /// (`[.sortedKeys, .prettyPrinted]`) spells it.
    pub(crate) fn persist_arkforge_state(
        &self,
        job_id: &str,
        state: &ArkForgeJobState,
    ) -> Result<(), JobWriteError> {
        let bytes = session_json::encode_pretty(&state.value())
            .map_err(|_| JobWriteError::Invalid("the Job's ArkForge state could not be encoded"))?;
        let _guard = self.activity.lock().map_err(|_| guard_unavailable())?;
        self.root
            .validate_path(&self.path)
            .map_err(JobWriteError::Refused)?;
        self.root
            .private_child("jobs")
            .and_then(|jobs| jobs.private_child(job_id))
            .map_err(JobWriteError::Refused)?
            .publish_document(FILE, &bytes, BOUND)
            .map_err(|error| match error {
                DocumentPublishError::BeforePublication(error) => JobWriteError::Refused(error),
                DocumentPublishError::OutcomeUnknown(error) => JobWriteError::OutcomeUnknown(error),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> ArkForgeJobState {
        let facts = vec![
            ("const.product.model".to_owned(), "DAYU200".to_owned()),
            ("usbTopology".to_owned(), "42".to_owned()),
        ];
        ArkForgeJobState {
            execution: Some(Execution {
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
            }),
            completion: Some(ActionReceipt {
                job_id: "JOB-FLASH-1".into(),
                plan_id: "PLAN-FLASH-1".into(),
                step_id: "STEP-023".into(),
                action_id: String::new(),
                attempt_id: String::new(),
                permit_id: "PERMIT-FLASH-1".into(),
                disposition: "semanticSuccess".into(),
                evidence_sha256: arkdeck_provider_arkforge::canonical_facts_digest(&facts).unwrap(),
                verification_outcome: String::new(),
                verification_strength: String::new(),
                verified_range_start: 0,
                verified_range_length: 0,
                typed_skip_reason: String::new(),
                failure_classification: String::new(),
                facts,
            }),
        }
    }

    #[test]
    fn a_state_reads_back_only_in_its_current_shape() {
        let full = state();
        assert_eq!(
            ArkForgeJobState::from_value(&full.value()),
            Some(full.clone())
        );
        let prepared = ArkForgeJobState {
            completion: None,
            ..full.clone()
        };
        assert_eq!(
            ArkForgeJobState::from_value(&prepared.value()),
            Some(prepared.clone())
        );
        assert!(prepared.value().get("planCompletionReceipt").is_none());

        let mut future = full.value();
        future["schemaVersion"] = json!("arkdeck-arkforge-runtime-state/v2");
        assert_eq!(ArkForgeJobState::from_value(&future), None);
        let mut extra = full.value();
        extra["execution"]["note"] = json!("x");
        assert_eq!(ArkForgeJobState::from_value(&extra), None);
        let mut null = prepared.value();
        null["planCompletionReceipt"] = Value::Null;
        assert_eq!(ArkForgeJobState::from_value(&null), None);
        let mut widened = full.value();
        widened["planCompletionReceipt"]["evidenceSHA256"][0] = json!(256);
        assert_eq!(ArkForgeJobState::from_value(&widened), None);
        let mut fractional = full.value();
        fractional["execution"]["bindingRevision"] = json!(1.0);
        assert_eq!(ArkForgeJobState::from_value(&fractional), None);
    }

    /// Foundation's `[.sortedKeys, .prettyPrinted]` spelling of the state.
    #[test]
    fn a_state_is_spelled_as_swifts_encoder_spells_it() {
        let text = String::from_utf8(
            session_json::encode_pretty(&ArkForgeJobState::default().value()).unwrap(),
        )
        .unwrap();
        assert_eq!(
            text,
            "{\n  \"schemaVersion\" : \"arkdeck-arkforge-runtime-state\\/v1\"\n}"
        );
    }
}
