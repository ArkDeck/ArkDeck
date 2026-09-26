//! Swift `RuntimeSupersedingRecoveryStore` (`RecoveryCoordination.swift`): the
//! append-only, hash-chained relation proving that a later complete overwrite
//! established a known target epoch. Covered intents stay `outcomeUnknown` in
//! their own journals; a reader consults this relation instead of rewriting or
//! guessing their result.
//!
//! This is a carrier of ADR-0009 decision 4 in the CHG-2026-074 decision
//! package (`evidence/adr-0009-decision-package-20260914.md` §1c and §2), which
//! the maintainer ruled on 2026-09-19 is ported unchanged:
//! - one document, `superseding-recovery-epochs.json`, beside the Job store,
//!   rewritten whole on every append (`canonicalPretty`, atomically), and read
//!   and written only under `.superseding-recovery-epochs.lock`;
//! - an epoch's digest is the SHA-256 of its compact canonical encoding without
//!   the digest, and names the preceding epoch's, so a changed, reordered or
//!   removed epoch breaks the chain;
//! - an epoch's identity is derived from its content, so a chain continues
//!   after its last epoch and no counter restarts;
//! - the same relation again is the stored epoch, a drifted one is refused.
//!
//! The document is decoded as Swift's plain `JSONDecoder` decodes it: a member
//! neither type names is ignored (and is not part of the digest), and the next
//! append rewrites the document without it.
//!
//! Nothing here establishes an epoch on its own: the writers are DEC-016's
//! complete-overwrite admission and a distinct recovery execution, both on the
//! M4 flash path.
use crate::session_json;
use crate::swift_decoding::{same_text, swift_integer, text_key};
use arkdeck_contract::sha256_hex;
use arkdeck_platform::HostDirectory;
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::io;

/// The document's name in the daemon's state directory.
pub const RECOVERY_EPOCH_DOCUMENT: &str = "superseding-recovery-epochs.json";
/// The lock every read and append holds.
pub const RECOVERY_EPOCH_LOCK: &str = ".superseding-recovery-epochs.lock";
const MAXIMUM_DOCUMENT_BYTES: usize = 1_048_576;
const SCHEMA_VERSION: &str = "1.0.0";

/// Swift `SupersedingRecoverySource`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoverySource {
    /// A complete later Job was already in immutable Runtime history.
    HistoricalRecognition,
    /// Protected Runtime admitted and executed a new, distinct overwrite Job.
    DistinctRecoveryExecution,
}

impl RecoverySource {
    fn word(self) -> &'static str {
        match self {
            Self::HistoricalRecognition => "historicalRecognition",
            Self::DistinctRecoveryExecution => "distinctRecoveryExecution",
        }
    }

    fn parse(word: &str) -> Option<Self> {
        match word {
            "historicalRecognition" => Some(Self::HistoricalRecognition),
            "distinctRecoveryExecution" => Some(Self::DistinctRecoveryExecution),
            _ => None,
        }
    }
}

/// Swift `SupersededRecoveryIntent`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SupersededIntent {
    pub job_id: String,
    pub intent_event_id: String,
    pub operation_reference: String,
    pub profile_reference: String,
    pub observed_at_utc: String,
    pub possible_effects: Vec<String>,
}

/// Swift `SupersedingRecoveryEpochDraft`: an epoch before the store names it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveryEpochDraft {
    pub source: RecoverySource,
    pub stable_target_identity_sha256: String,
    pub binding_revision: i64,
    pub covered_intents: Vec<SupersededIntent>,
    pub uncertain_effect_set_sha256: String,
    pub coverage_contract_version: String,
    pub covered_effect_set_sha256: String,
    pub recovery_job_id: String,
    pub recovery_intent_event_id: String,
    pub operation_reference: String,
    pub profile_reference: String,
    pub materialized_plan_digest_sha256: String,
    pub artifact_sha256: String,
    pub provider_executable_sha256: String,
    pub confirmed_step_ids: Vec<String>,
    pub resulting_target_epoch_sha256: String,
    pub established_at_utc: String,
}

/// Swift `SupersedingRecoveryEpoch`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveryEpoch {
    pub epoch_id: String,
    pub draft: RecoveryEpochDraft,
    pub previous_epoch_sha256: Option<String>,
    pub epoch_sha256: String,
}

impl RecoveryEpoch {
    /// The epoch as `job.evidence` and `job.result` project it (Swift
    /// `AgentDaemon.encodeEvidence`'s `recoveryEpoch`).
    pub(crate) fn evidence(&self) -> Value {
        let draft = &self.draft;
        let intents: Vec<Value> = draft
            .covered_intents
            .iter()
            .map(|intent| {
                json!({
                    "jobId": intent.job_id,
                    "intentEventId": intent.intent_event_id,
                    "operationReference": intent.operation_reference,
                    "profileReference": intent.profile_reference,
                    "observedAtUtc": intent.observed_at_utc,
                    "possibleEffects": intent.possible_effects,
                })
            })
            .collect();
        json!({
            "epochId": self.epoch_id,
            "source": draft.source.word(),
            "stableTargetIdentitySha256": draft.stable_target_identity_sha256,
            "bindingRevision": draft.binding_revision,
            "coveredIntents": intents,
            "uncertainEffectSetSha256": draft.uncertain_effect_set_sha256,
            "coverageContractVersion": draft.coverage_contract_version,
            "coveredEffectSetSha256": draft.covered_effect_set_sha256,
            "recoveryJobId": draft.recovery_job_id,
            "recoveryIntentEventId": draft.recovery_intent_event_id,
            "operationReference": draft.operation_reference,
            "profileReference": draft.profile_reference,
            "materializedPlanDigestSha256": draft.materialized_plan_digest_sha256,
            "artifactSha256": draft.artifact_sha256,
            "providerExecutableSha256": draft.provider_executable_sha256,
            "confirmedStepIds": draft.confirmed_step_ids,
            "resultingTargetEpochSha256": draft.resulting_target_epoch_sha256,
            "establishedAtUtc": draft.established_at_utc,
            "epochSha256": self.epoch_sha256,
        })
    }

    /// Swift `covers(jobID:intentEventID:stableIdentitySHA256:bindingRevision:)`.
    pub fn covers(
        &self,
        job_id: &str,
        intent_event_id: &str,
        stable_identity_sha256: &str,
        binding_revision: i64,
    ) -> bool {
        same_text(
            &self.draft.stable_target_identity_sha256,
            stable_identity_sha256,
        ) && self.draft.binding_revision == binding_revision
            && self.draft.covered_intents.iter().any(|intent| {
                same_text(&intent.job_id, job_id)
                    && same_text(&intent.intent_event_id, intent_event_id)
            })
    }

    /// The epoch as Swift's synthesized encoder spells it; without its digest
    /// it is the material the digest covers.
    fn value(&self, with_digest: bool) -> Value {
        let draft = &self.draft;
        let mut value = json!({
            "epochID": self.epoch_id,
            "source": draft.source.word(),
            "stableTargetIdentitySHA256": draft.stable_target_identity_sha256,
            "bindingRevision": draft.binding_revision,
            "coveredIntents": draft.covered_intents.iter().map(|intent| json!({
                "jobID": intent.job_id,
                "intentEventID": intent.intent_event_id,
                "operationReference": intent.operation_reference,
                "profileReference": intent.profile_reference,
                "observedAtUTC": intent.observed_at_utc,
                "possibleEffects": intent.possible_effects,
            })).collect::<Vec<_>>(),
            "uncertainEffectSetSHA256": draft.uncertain_effect_set_sha256,
            "coverageContractVersion": draft.coverage_contract_version,
            "coveredEffectSetSHA256": draft.covered_effect_set_sha256,
            "recoveryJobID": draft.recovery_job_id,
            "recoveryIntentEventID": draft.recovery_intent_event_id,
            "operationReference": draft.operation_reference,
            "profileReference": draft.profile_reference,
            "materializedPlanDigestSHA256": draft.materialized_plan_digest_sha256,
            "artifactSHA256": draft.artifact_sha256,
            "providerExecutableSHA256": draft.provider_executable_sha256,
            "confirmedStepIDs": draft.confirmed_step_ids,
            "resultingTargetEpochSHA256": draft.resulting_target_epoch_sha256,
            "establishedAtUTC": draft.established_at_utc,
        });
        let fields = value.as_object_mut().expect("an epoch is an object");
        if let Some(previous) = &self.previous_epoch_sha256 {
            fields.insert("previousEpochSHA256".into(), previous.clone().into());
        }
        if with_digest {
            fields.insert("epochSHA256".into(), self.epoch_sha256.clone().into());
        }
        value
    }

    /// The epoch as Swift's `CanonicalJSONEncoders.canonical()` spells it.
    pub fn to_value(&self) -> Value {
        self.value(true)
    }

    fn material_digest(&self) -> String {
        let bytes = session_json::encode(&self.value(false))
            .expect("an epoch holds only integers and strings");
        sha256_hex(&bytes)
    }
}

/// Swift `SupersedingRecoveryStoreError`, by kind. The message of a corrupt
/// store is Swift's reason, which callers do not match on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecoveryEpochError {
    Corrupt(String),
    InvalidEpoch,
    ConflictingEpoch(String),
}

impl RecoveryEpochError {
    /// The spelling of the shared oracle's `refused`.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Corrupt(_) => "corrupt",
            Self::InvalidEpoch => "invalidEpoch",
            Self::ConflictingEpoch(_) => "conflictingEpoch",
        }
    }
}

type Result<T> = std::result::Result<T, RecoveryEpochError>;

fn corrupt(reason: &str) -> RecoveryEpochError {
    RecoveryEpochError::Corrupt(reason.to_owned())
}

/// Swift `isSHA256`: 64 lowercase hexadecimal digits.
fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// How many distinct values Swift's `Set` of these strings holds.
fn distinct<'a>(values: impl IntoIterator<Item = &'a str>) -> (usize, usize) {
    let mut count = 0;
    let keys: BTreeSet<String> = values
        .into_iter()
        .inspect(|_| count += 1)
        .map(text_key)
        .collect();
    (keys.len(), count)
}

/// Swift `effectDigest`: the SHA-256 of the distinct effects, sorted and
/// joined by newlines.
fn effect_digest(effects: &[String]) -> String {
    let mut kept: Vec<(String, &str)> = Vec::new();
    for effect in effects {
        let key = text_key(effect);
        if !kept.iter().any(|(existing, _)| *existing == key) {
            kept.push((key, effect));
        }
    }
    kept.sort();
    let joined = kept
        .iter()
        .map(|(_, effect)| *effect)
        .collect::<Vec<_>>()
        .join("\n");
    sha256_hex(joined.as_bytes())
}

fn intent_key(intent: &SupersededIntent) -> String {
    text_key(&format!("{}\n{}", intent.job_id, intent.intent_event_id))
}

/// Swift `validate(_:)`: closed identity, effect, Artifact and postflight facts.
fn validate(draft: &RecoveryEpochDraft) -> Result<()> {
    let hashes = [
        &draft.stable_target_identity_sha256,
        &draft.uncertain_effect_set_sha256,
        &draft.covered_effect_set_sha256,
        &draft.materialized_plan_digest_sha256,
        &draft.artifact_sha256,
        &draft.provider_executable_sha256,
        &draft.resulting_target_epoch_sha256,
    ];
    let keys: BTreeSet<String> = draft.covered_intents.iter().map(intent_key).collect();
    let effects: Vec<String> = draft
        .covered_intents
        .iter()
        .flat_map(|intent| intent.possible_effects.iter().cloned())
        .collect();
    let (distinct_steps, steps) = distinct(draft.confirmed_step_ids.iter().map(String::as_str));
    let valid = hashes.iter().all(|hash| is_sha256(hash))
        && draft.binding_revision > 0
        && !draft.covered_intents.is_empty()
        && keys.len() == draft.covered_intents.len()
        && draft.uncertain_effect_set_sha256 == effect_digest(&effects)
        && steps > 0
        && distinct_steps == steps
        && draft.covered_intents.iter().all(|intent| {
            let (distinct_effects, effects) =
                distinct(intent.possible_effects.iter().map(String::as_str));
            !intent.job_id.is_empty()
                && !intent.intent_event_id.is_empty()
                && effects > 0
                && distinct_effects == effects
        });
    if valid {
        Ok(())
    } else {
        Err(RecoveryEpochError::InvalidEpoch)
    }
}

/// Swift's synthesized `==` of two drafts: every member, strings by canonical
/// equivalence, arrays in order.
fn same_draft(left: &RecoveryEpochDraft, right: &RecoveryEpochDraft) -> bool {
    let texts = |a: &[String], b: &[String]| {
        a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same_text(a, b))
    };
    left.source == right.source
        && same_text(
            &left.stable_target_identity_sha256,
            &right.stable_target_identity_sha256,
        )
        && left.binding_revision == right.binding_revision
        && left.covered_intents.len() == right.covered_intents.len()
        && left
            .covered_intents
            .iter()
            .zip(&right.covered_intents)
            .all(|(a, b)| {
                same_text(&a.job_id, &b.job_id)
                    && same_text(&a.intent_event_id, &b.intent_event_id)
                    && same_text(&a.operation_reference, &b.operation_reference)
                    && same_text(&a.profile_reference, &b.profile_reference)
                    && same_text(&a.observed_at_utc, &b.observed_at_utc)
                    && texts(&a.possible_effects, &b.possible_effects)
            })
        && [
            (
                &left.uncertain_effect_set_sha256,
                &right.uncertain_effect_set_sha256,
            ),
            (
                &left.coverage_contract_version,
                &right.coverage_contract_version,
            ),
            (
                &left.covered_effect_set_sha256,
                &right.covered_effect_set_sha256,
            ),
            (&left.recovery_job_id, &right.recovery_job_id),
            (
                &left.recovery_intent_event_id,
                &right.recovery_intent_event_id,
            ),
            (&left.operation_reference, &right.operation_reference),
            (&left.profile_reference, &right.profile_reference),
            (
                &left.materialized_plan_digest_sha256,
                &right.materialized_plan_digest_sha256,
            ),
            (&left.artifact_sha256, &right.artifact_sha256),
            (
                &left.provider_executable_sha256,
                &right.provider_executable_sha256,
            ),
            (
                &left.resulting_target_epoch_sha256,
                &right.resulting_target_epoch_sha256,
            ),
            (&left.established_at_utc, &right.established_at_utc),
        ]
        .iter()
        .all(|(a, b)| same_text(a, b))
        && texts(&left.confirmed_step_ids, &right.confirmed_step_ids)
}

fn text(fields: &Map<String, Value>, key: &str) -> Option<String> {
    fields.get(key)?.as_str().map(str::to_owned)
}

fn texts(fields: &Map<String, Value>, key: &str) -> Option<Vec<String>> {
    fields
        .get(key)?
        .as_array()?
        .iter()
        .map(|value| value.as_str().map(str::to_owned))
        .collect()
}

/// One epoch as Swift's `JSONDecoder` decodes it: every member the type
/// names, of its type; any other member ignored.
fn decode_epoch(value: &Value) -> Option<RecoveryEpoch> {
    let fields = value.as_object()?;
    let intents = fields
        .get("coveredIntents")?
        .as_array()?
        .iter()
        .map(|intent| {
            let intent = intent.as_object()?;
            Some(SupersededIntent {
                job_id: text(intent, "jobID")?,
                intent_event_id: text(intent, "intentEventID")?,
                operation_reference: text(intent, "operationReference")?,
                profile_reference: text(intent, "profileReference")?,
                observed_at_utc: text(intent, "observedAtUTC")?,
                possible_effects: texts(intent, "possibleEffects")?,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    let previous = match fields.get("previousEpochSHA256") {
        None | Some(Value::Null) => None,
        Some(Value::String(previous)) => Some(previous.clone()),
        Some(_) => return None,
    };
    Some(RecoveryEpoch {
        epoch_id: text(fields, "epochID")?,
        draft: RecoveryEpochDraft {
            source: RecoverySource::parse(fields.get("source")?.as_str()?)?,
            stable_target_identity_sha256: text(fields, "stableTargetIdentitySHA256")?,
            binding_revision: swift_integer(fields.get("bindingRevision")?.as_number()?)?,
            covered_intents: intents,
            uncertain_effect_set_sha256: text(fields, "uncertainEffectSetSHA256")?,
            coverage_contract_version: text(fields, "coverageContractVersion")?,
            covered_effect_set_sha256: text(fields, "coveredEffectSetSHA256")?,
            recovery_job_id: text(fields, "recoveryJobID")?,
            recovery_intent_event_id: text(fields, "recoveryIntentEventID")?,
            operation_reference: text(fields, "operationReference")?,
            profile_reference: text(fields, "profileReference")?,
            materialized_plan_digest_sha256: text(fields, "materializedPlanDigestSHA256")?,
            artifact_sha256: text(fields, "artifactSHA256")?,
            provider_executable_sha256: text(fields, "providerExecutableSHA256")?,
            confirmed_step_ids: texts(fields, "confirmedStepIDs")?,
            resulting_target_epoch_sha256: text(fields, "resultingTargetEpochSHA256")?,
            established_at_utc: text(fields, "establishedAtUTC")?,
        },
        previous_epoch_sha256: previous,
        epoch_sha256: text(fields, "epochSHA256")?,
    })
}

/// Swift `load()`, under the lock: absent is empty; otherwise the bounded
/// owner-only document, decoded, every epoch validated and its chain checked.
fn load(root: &HostDirectory) -> Result<Vec<RecoveryEpoch>> {
    let bytes = match root.read(RECOVERY_EPOCH_DOCUMENT, MAXIMUM_DOCUMENT_BYTES) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(_) => {
            return Err(corrupt(
                "recovery epoch document is not a bounded owner-only regular file",
            ));
        }
    };
    let decoded: Option<(String, Vec<RecoveryEpoch>)> = serde_json::from_slice::<Value>(&bytes)
        .ok()
        .and_then(|document| {
            let fields = document.as_object()?;
            let version = text(fields, "schemaVersion")?;
            let epochs = fields
                .get("epochs")?
                .as_array()?
                .iter()
                .map(decode_epoch)
                .collect::<Option<Vec<_>>>()?;
            Some((version, epochs))
        });
    let (version, epochs) = decoded.ok_or_else(|| corrupt("cannot decode recovery epochs"))?;
    if version != SCHEMA_VERSION {
        return Err(corrupt("unsupported recovery epoch schema"));
    }
    let mut previous: Option<&str> = None;
    for epoch in &epochs {
        validate(&epoch.draft)?;
        if epoch.previous_epoch_sha256.as_deref() != previous
            || epoch.epoch_sha256 != epoch.material_digest()
        {
            return Err(RecoveryEpochError::Corrupt(format!(
                "recovery epoch hash chain is invalid at {}",
                epoch.epoch_id
            )));
        }
        previous = Some(&epoch.epoch_sha256);
    }
    Ok(epochs)
}

fn locked<T>(root: &HostDirectory, body: impl FnOnce() -> Result<T>) -> Result<T> {
    let _lock = root
        .wait_lock(RECOVERY_EPOCH_LOCK, false)
        .map_err(|_| corrupt("recovery epoch lock is not owner-only"))?;
    body()
}

/// Swift `RuntimeSupersedingRecoveryStore.list()`.
pub fn list_recovery_epochs(root: &HostDirectory) -> Result<Vec<RecoveryEpoch>> {
    locked(root, || load(root))
}

/// Swift `RuntimeSupersedingRecoveryStore.append(_:)`: the stored epoch for
/// the same relation, a refusal for a drifted one, or a new epoch chained to
/// the last, written whole and atomically.
pub fn append_recovery_epoch(
    root: &HostDirectory,
    draft: &RecoveryEpochDraft,
) -> Result<RecoveryEpoch> {
    validate(draft)?;
    locked(root, || {
        let mut epochs = load(root)?;
        let keys: BTreeSet<String> = draft.covered_intents.iter().map(intent_key).collect();
        if let Some(existing) = epochs.iter().find(|epoch| {
            same_text(&epoch.draft.recovery_job_id, &draft.recovery_job_id)
                && same_text(
                    &epoch.draft.recovery_intent_event_id,
                    &draft.recovery_intent_event_id,
                )
                && epoch
                    .draft
                    .covered_intents
                    .iter()
                    .map(intent_key)
                    .collect::<BTreeSet<_>>()
                    == keys
        }) {
            if !same_draft(&existing.draft, draft) {
                return Err(RecoveryEpochError::ConflictingEpoch(
                    existing.epoch_id.clone(),
                ));
            }
            return Ok(existing.clone());
        }
        let seed = sha256_hex(
            format!(
                "{}\n{}\n{}\n{}",
                draft.stable_target_identity_sha256,
                draft.recovery_job_id,
                draft.recovery_intent_event_id,
                draft.uncertain_effect_set_sha256
            )
            .as_bytes(),
        );
        let epoch_id = format!("recovery-epoch-{}", &seed[..32]);
        if epochs
            .iter()
            .any(|epoch| same_text(&epoch.epoch_id, &epoch_id))
        {
            return Err(RecoveryEpochError::ConflictingEpoch(epoch_id));
        }
        let mut epoch = RecoveryEpoch {
            epoch_id,
            draft: draft.clone(),
            previous_epoch_sha256: epochs.last().map(|last| last.epoch_sha256.clone()),
            epoch_sha256: String::new(),
        };
        epoch.epoch_sha256 = epoch.material_digest();
        epochs.push(epoch.clone());
        let document = json!({
            "schemaVersion": SCHEMA_VERSION,
            "epochs": epochs.iter().map(RecoveryEpoch::to_value).collect::<Vec<_>>(),
        });
        let bytes = session_json::encode_canonical_pretty(&document)
            .map_err(|_| corrupt("recovery epoch document must encode"))?;
        root.replace_document(RECOVERY_EPOCH_DOCUMENT, &bytes, usize::MAX)
            .map_err(|_| corrupt("cannot write recovery epoch document"))?;
        Ok(epoch)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};

    fn two_epoch_document() -> Vec<u8> {
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/recovery-epoch/steps/17-list-two")
            .join(RECOVERY_EPOCH_DOCUMENT);
        std::fs::read(fixture).unwrap()
    }

    struct Root(PathBuf);

    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// The Job owner's read for a Job's evidence: an absent document names no
    /// Job, a readable one names its recovery Jobs (not the Jobs it covers),
    /// and an unreadable one is an error, which degrades the evidence.
    #[test]
    fn the_job_store_reads_which_job_an_epoch_names_as_its_recovery() {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let root = Root(
            std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("recovery-epoch-owner-{nonce:x}")),
        );
        std::fs::create_dir(&root.0).unwrap();
        std::fs::set_permissions(&root.0, std::fs::Permissions::from_mode(0o700)).unwrap();
        let jobs = crate::JobStore::open_owner(&root.0).unwrap();
        assert_eq!(
            jobs.recovery_epoch_of("job-recovery")
                .map(|epoch| epoch.is_some()),
            Ok(false)
        );
        assert!(!root.0.join(RECOVERY_EPOCH_LOCK).exists());

        let document = root.0.join(RECOVERY_EPOCH_DOCUMENT);
        std::fs::write(&document, two_epoch_document()).unwrap();
        std::fs::set_permissions(&document, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            jobs.recovery_epoch_of("job-recovery")
                .map(|epoch| epoch.is_some()),
            Ok(true)
        );
        assert_eq!(
            jobs.recovery_epoch_of("job-recovery-2")
                .map(|epoch| epoch.is_some()),
            Ok(true)
        );
        assert_eq!(
            jobs.recovery_epoch_of("job-old-a")
                .map(|epoch| epoch.is_some()),
            Ok(false)
        );

        std::fs::set_permissions(&document, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(
            jobs.recovery_epoch_of("job-recovery")
                .map(|epoch| epoch.is_some())
                .map_err(|error| error.kind()),
            Err("corrupt")
        );
    }
}
