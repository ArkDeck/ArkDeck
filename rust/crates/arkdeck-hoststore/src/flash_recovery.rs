//! DEC-016 for the ArkForge Flash operations, as Swift decides it
//! (`RuntimeRecoveryService.completeOverwriteAdmission`,
//! `RuntimeJobEngine.establishSupersedingRecoveryEpoch`,
//! `recoveryEpochIndexes`), over the Job owner's state root:
//!
//! - an unresolved destructive intent on a Target binding — an outstanding or
//!   unknown `flash-partitions` intent in a Job's journal, or a destructive
//!   capability use whose outcome is not settled and which no journal names —
//!   blocks every later Flash of that binding until a complete overwrite
//!   supersedes it;
//! - a complete, verified later recovery Flash already in history is
//!   recognized and its epoch appended, with nothing dispatched;
//! - otherwise only the exact reviewed operation and profile, every covered
//!   partition and full verification may be admitted as a distinct recovery,
//!   within the shared four-hour budget (or an operator-named hardware
//!   acceptance campaign) and sixteen epochs;
//! - a distinct recovery that confirmed its write and every verification step
//!   establishes the epoch that covers the unknown intents; their own
//!   outcomes stay unknown.
//!
//! Nothing here dispatches, admits or consumes. A refusal is Swift's
//! `RuntimeCompleteOverwriteRecoveryError.blocked(reason)`, which the caller
//! answers as a non-overridable recovery blocker; anything else that fails is
//! a store that cannot be read.
use super::JobStore;
use crate::capability_store::{CapabilityStore, UseOutcome};
use crate::job_record::JobRecord;
use crate::recovery_epoch::{
    RecoveryEpoch, RecoveryEpochDraft, RecoverySource, SupersededIntent, append_recovery_epoch,
};
use crate::strict_json::swift_quoted;
use arkdeck_contract::{CATALOG_CANONICAL_JSON, sha256_hex};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::Path;
use std::sync::OnceLock;

/// Swift `ArkForgeFlashOperation.canonicalReference`.
const CANONICAL: &str = "flash.full-restore@1";
/// Swift `ArkForgeFlashOperation.containsDurableRecordReference`.
const DURABLE_REFERENCES: [&str; 3] = ["flash.full-restore@1", "flash.dayu200", "flash.dayu200@1"];
/// Swift `RockchipFlashProfile.dayu200.catalogReference`, the one profile a
/// canonical full restore resolves.
const DAYU200: &str = "dayu200";
/// Swift `arkForgePlanCompletionSemanticCode`.
const PLAN_COMPLETION_CODE: &str = "arkForgePlanCompletion";
/// The shared unattended budget: four hours and sixteen epochs.
const FOUR_HOURS: f64 = 4.0 * 60.0 * 60.0;
const EPOCH_BUDGET: usize = 16;

/// Swift `RuntimeCompleteOverwriteRecoveryContext`: what a distinct recovery
/// covers, as its admission classified it and its evidence keeps it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RecoveryContext {
    pub(crate) covered_intents: Vec<SupersededIntent>,
    pub(crate) uncertain_effect_set_sha256: String,
    pub(crate) coverage_contract_version: String,
    pub(crate) covered_effect_set_sha256: String,
    pub(crate) profile_reference: String,
    pub(crate) destructive_epoch_ordinal: i64,
}

fn intent_value(intent: &SupersededIntent) -> Value {
    json!({
        "jobID": intent.job_id,
        "intentEventID": intent.intent_event_id,
        "operationReference": intent.operation_reference,
        "profileReference": intent.profile_reference,
        "observedAtUTC": intent.observed_at_utc,
        "possibleEffects": intent.possible_effects,
    })
}

fn intent_from(value: &Value) -> Option<SupersededIntent> {
    let text = |key: &str| value[key].as_str().map(str::to_owned);
    Some(SupersededIntent {
        job_id: text("jobID")?,
        intent_event_id: text("intentEventID")?,
        operation_reference: text("operationReference")?,
        profile_reference: text("profileReference")?,
        observed_at_utc: text("observedAtUTC")?,
        possible_effects: value["possibleEffects"]
            .as_array()?
            .iter()
            .map(|effect| effect.as_str().map(str::to_owned))
            .collect::<Option<_>>()?,
    })
}

impl RecoveryContext {
    /// The context as the admission evidence keeps it (Swift's synthesized
    /// encoding).
    pub(crate) fn value(&self) -> Value {
        json!({
            "coveredIntents": self.covered_intents.iter().map(intent_value).collect::<Vec<_>>(),
            "uncertainEffectSetSHA256": self.uncertain_effect_set_sha256,
            "coverageContractVersion": self.coverage_contract_version,
            "coveredEffectSetSHA256": self.covered_effect_set_sha256,
            "profileReference": self.profile_reference,
            "destructiveEpochOrdinal": self.destructive_epoch_ordinal,
        })
    }

    /// The context an admission evidence carries, if it carries one.
    pub(crate) fn from_evidence(evidence: &Value) -> Option<Self> {
        let value = evidence.get("completeOverwriteRecovery")?;
        let text = |key: &str| value[key].as_str().map(str::to_owned);
        Some(Self {
            covered_intents: value["coveredIntents"]
                .as_array()?
                .iter()
                .map(intent_from)
                .collect::<Option<_>>()?,
            uncertain_effect_set_sha256: text("uncertainEffectSetSHA256")?,
            coverage_contract_version: text("coverageContractVersion")?,
            covered_effect_set_sha256: text("coveredEffectSetSHA256")?,
            profile_reference: text("profileReference")?,
            destructive_epoch_ordinal: value["destructiveEpochOrdinal"].as_i64()?,
        })
    }

    /// Swift `automaticCapabilityPolicyFingerprint`'s recovery lines: a
    /// recovery's capability is its own policy identity.
    pub(crate) fn policy_lines(&self) -> String {
        format!(
            "{}\n{}\n{}\n{}",
            self.uncertain_effect_set_sha256,
            self.coverage_contract_version,
            self.covered_effect_set_sha256,
            self.destructive_epoch_ordinal
        )
    }

    /// The Jobs whose unknown intents this recovery covers.
    pub(crate) fn covered_jobs(&self) -> impl Iterator<Item = &str> {
        self.covered_intents
            .iter()
            .map(|intent| intent.job_id.as_str())
    }
}

/// Swift `RuntimeCompleteOverwriteAdmissionResult`.
pub(crate) enum OverwriteAdmission {
    /// Nothing on the binding is unresolved: an ordinary Flash.
    Ordinary,
    /// A distinct recovery, and the campaign that stood in for the shared
    /// four-hour budget, if one did.
    Recovery {
        context: RecoveryContext,
        campaign: Option<String>,
    },
    /// A complete later recovery Flash already in history, whose epoch is now
    /// appended; nothing is dispatched for it.
    Recognized(Box<RecoveryEpoch>),
}

/// Why a complete-overwrite admission refused.
pub(crate) enum OverwriteRefusal {
    /// Swift `RuntimeCompleteOverwriteRecoveryError.blocked(reason)`.
    Blocked(String),
    /// A store or journal this admission could not read, which Swift throws
    /// as it is.
    Failed(String),
}

impl OverwriteRefusal {
    fn blocked(reason: &str) -> Self {
        Self::Blocked(reason.to_owned())
    }

    /// Swift's `"\(error)"` of the blocker: `blocked("reason")`.
    pub(crate) fn blocker(reason: &str) -> String {
        format!("blocked({})", swift_quoted(reason))
    }
}

/// Swift `CatalogCompleteOverwriteRecoveryDescriptor` of one operation.
struct Contract {
    version: String,
    overwrite_step: String,
    verification_steps: Vec<String>,
    /// Each profile's reference and covered effects, in catalog order.
    profiles: Vec<(String, Vec<String>)>,
}

impl Contract {
    /// The published contract of the catalog operation `reference` names.
    fn of(reference: &str) -> Option<Self> {
        static CATALOG: OnceLock<Vec<Value>> = OnceLock::new();
        let catalog = CATALOG
            .get_or_init(|| serde_json::from_str(CATALOG_CANONICAL_JSON).unwrap_or_default());
        let (id, version) = match reference.rsplit_once('@') {
            Some((id, version)) => (id, Some(version.parse::<i64>().ok()?)),
            None => (reference, None),
        };
        let operation = catalog
            .iter()
            .find(|operation| operation["id"] == id && operation["version"].as_i64() == version)?;
        let contract = &operation["completeOverwriteRecovery"];
        let strings = |value: &Value| -> Option<Vec<String>> {
            value
                .as_array()?
                .iter()
                .map(|item| item.as_str().map(str::to_owned))
                .collect()
        };
        Some(Self {
            version: contract["contractVersion"].as_str()?.to_owned(),
            overwrite_step: contract["overwriteStepID"].as_str()?.to_owned(),
            verification_steps: strings(&contract["verificationStepIDs"])?,
            profiles: contract["profiles"]
                .as_array()?
                .iter()
                .map(|profile| {
                    Some((
                        profile["reference"].as_str()?.to_owned(),
                        strings(&profile["coveredEffects"])?,
                    ))
                })
                .collect::<Option<_>>()?,
        })
    }

    fn covered_effects(&self, profile: &str) -> Option<&[String]> {
        self.profiles
            .iter()
            .find(|(reference, _)| reference == profile)
            .map(|(_, effects)| effects.as_slice())
    }

    /// The write, then every verification step (Swift `requiredSteps`).
    fn required_steps(&self) -> Vec<String> {
        std::iter::once(self.overwrite_step.clone())
            .chain(self.verification_steps.iter().cloned())
            .collect()
    }
}

/// Swift `ArkForgeFlashOperation.canonicalReference(for:)`.
fn canonical(reference: &str) -> Option<&'static str> {
    matches!(reference, CANONICAL | "flash.dayu200").then_some(CANONICAL)
}

/// Swift `ArkForgeFlashRequest.profileReference`.
fn flash_profile<'a>(operation: &str, inputs: &'a Value) -> Option<&'a str> {
    let key = if operation == CANONICAL {
        "deviceProfileRef"
    } else {
        "deviceProfile"
    };
    inputs[key].as_str().filter(|profile| !profile.is_empty())
}

/// Swift `flashPartitions`: a canonical full restore writes its profile's
/// mapped partitions; any other Flash names its own.
fn flash_partitions(operation: &str, inputs: &Value) -> Option<Vec<String>> {
    if operation == CANONICAL {
        if inputs["intent"] != "fullRestore" || flash_profile(operation, inputs) != Some(DAYU200) {
            return None;
        }
        return Some(
            crate::job_plan::DAYU200_PARTITIONS
                .iter()
                .map(|partition| (*partition).to_owned())
                .collect(),
        );
    }
    inputs["partitionPlan"]
        .as_array()?
        .iter()
        .map(|partition| partition.as_str().map(str::to_owned))
        .collect()
}

/// Swift `flashVerification`: `full` unless a verification is named.
fn flash_verification<'a>(operation: &str, inputs: &'a Value) -> &'a str {
    let key = if operation == CANONICAL {
        "verification"
    } else {
        "postFlashVerification"
    };
    inputs[key].as_str().unwrap_or("full")
}

/// Swift `effectDigest`: the distinct effects, sorted, one per line.
fn effect_digest(effects: &[String]) -> String {
    let distinct: BTreeSet<&str> = effects.iter().map(String::as_str).collect();
    sha256_hex(
        distinct
            .into_iter()
            .collect::<Vec<_>>()
            .join("\n")
            .as_bytes(),
    )
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn date(text: &str) -> Option<f64> {
    crate::format_time::format_timestamp_seconds(text)
}

/// Swift `RuntimeJobRecord.state(in:)`, as the scan reads it.
enum Recorded {
    Absent,
    Readable(Box<JobRecord>),
    Unreadable(String),
}

fn recorded(directory: &Path) -> Recorded {
    match std::fs::read(directory.join("job-record.json")) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Recorded::Absent,
        Err(error) => Recorded::Unreadable(format!("job record cannot be read: {error}")),
        Ok(bytes) => match JobRecord::decode(&bytes) {
            Ok(record) => Recorded::Readable(Box::new(record)),
            Err(error) => Recorded::Unreadable(format!(
                "job record was written in a shape this build cannot read: {}",
                error.message
            )),
        },
    }
}

/// Swift `RuntimeJobRecord.load(from:)`, which a failed read or decode
/// answers with nothing.
fn loaded(directory: &Path) -> Option<JobRecord> {
    match recorded(directory) {
        Recorded::Readable(record) => Some(*record),
        _ => None,
    }
}

/// The visible entries of the Job directory, sorted by name (Swift
/// `contentsOfDirectory(options: .skipsHiddenFiles)`), or none when it
/// cannot be listed.
fn job_directories(jobs: &Path) -> Option<Vec<String>> {
    let mut names: Vec<String> = std::fs::read_dir(jobs)
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| !name.starts_with('.'))
        .collect();
    names.sort();
    Some(names)
}

/// Each confirmed, succeeded step outcome whose intent is in the journal:
/// its step once, in journal order, and, for each step of `required`, its
/// intent (the last such outcome's) — Swift's `confirmedStepIDs` and
/// `confirmedIntentByStep`, only outcomes carrying the plan-completion code
/// counting for the latter when `completion_only`.
fn confirmed(
    events: &[Value],
    required: &[String],
    completion_only: bool,
) -> (Vec<String>, BTreeMap<String, String>) {
    let mut steps = Vec::new();
    let mut intents = BTreeMap::new();
    for outcome in events.iter().filter(|event| event["kind"] == "stepOutcome") {
        let (Some(step), Some(intent)) = (
            outcome["stepId"].as_str(),
            outcome["payload"]["correlatesToIntentEventId"].as_str(),
        ) else {
            continue;
        };
        if outcome["payload"]["result"] != "succeeded"
            || outcome["payload"]["outcomeCertainty"] != "confirmed"
            || !events.iter().any(|event| {
                event["kind"] == "stepIntent"
                    && event["eventId"] == intent
                    && event["stepId"] == step
            })
        {
            continue;
        }
        if !steps.iter().any(|seen| seen == step) {
            steps.push(step.to_owned());
        }
        if required.iter().any(|needed| needed == step)
            && (!completion_only || outcome["payload"]["semanticCode"] == PLAN_COMPLETION_CODE)
        {
            intents.insert(step.to_owned(), intent.to_owned());
        }
    }
    (steps, intents)
}

/// Swift `resultingTargetEpochSHA256`.
fn resulting_epoch(
    identity: &str,
    binding: i64,
    job: &str,
    plan: &str,
    artifact: &str,
    required: &[String],
) -> String {
    sha256_hex(
        [
            identity,
            &binding.to_string(),
            job,
            plan,
            artifact,
            &required.join(","),
        ]
        .join("\n")
        .as_bytes(),
    )
}

/// Swift `recoveryEpochIndexes`: for each Job, the epoch that superseded its
/// unknown intents and the epoch it established as the recovery.
#[derive(Default)]
pub(crate) struct EpochIndexes {
    superseded_by: BTreeMap<String, String>,
    established: BTreeMap<String, String>,
}

impl EpochIndexes {
    /// A Job's status with the epochs that name it.
    pub(crate) fn project(&self, job_id: &str, status: &mut Value) {
        if let Some(epoch) = self.superseded_by.get(job_id) {
            status["supersededByRecoveryEpochId"] = json!(epoch);
        }
        if let Some(epoch) = self.established.get(job_id) {
            status["recoveryEpochId"] = json!(epoch);
        }
    }

    /// A Job's history summary with the epochs that name it: an unknown
    /// outcome an epoch superseded no longer keeps a terminal Job current
    /// (Swift `isCurrentJob`).
    pub(crate) fn project_history(&self, record: &JobRecord, summary: &mut Value) {
        self.project(&record.job_id, summary);
        if self.superseded_by.contains_key(&record.job_id) {
            summary["current"] = json!(
                !crate::job_record::terminal(&record.state) || record.residues().unwrap_or(0) > 0
            );
        }
    }
}

impl JobStore {
    fn jobs_path(&self) -> std::path::PathBuf {
        self.path.join("jobs")
    }

    /// Swift `recoveryEpochIndexes`. An absent or unreadable epoch document
    /// indexes nothing. Swift's read would also create the store's lock and
    /// an empty Target store below the state root, which this read does not
    /// create.
    pub(crate) fn epoch_indexes(&self) -> EpochIndexes {
        let mut indexes = EpochIndexes::default();
        if self
            .root
            .document_metadata(crate::RECOVERY_EPOCH_DOCUMENT)
            .is_err()
        {
            return indexes;
        }
        for epoch in self.recovery_epochs().unwrap_or_default() {
            indexes
                .established
                .insert(epoch.draft.recovery_job_id.clone(), epoch.epoch_id.clone());
            for intent in &epoch.draft.covered_intents {
                indexes
                    .superseded_by
                    .insert(intent.job_id.clone(), epoch.epoch_id.clone());
            }
        }
        indexes
    }

    /// A Job's status as Swift's readers project it, with the recovery
    /// epochs that name it.
    pub(crate) fn indexed_status(&self, record: &JobRecord) -> Value {
        let mut status = record.status();
        self.epoch_indexes().project(&record.job_id, &mut status);
        status
    }

    /// The Jobs an epoch on this binding covers, whose unresolved uses no
    /// longer block its lineage (Swift `validateNoUnresolvedMutationLineage`,
    /// which lists the epochs again for every check).
    pub(crate) fn superseded_jobs(
        &self,
        identity: &str,
        binding: i64,
    ) -> Result<BTreeSet<String>, crate::RecoveryEpochError> {
        Ok(self
            .recovery_epochs()?
            .into_iter()
            .filter(|epoch| {
                epoch.draft.stable_target_identity_sha256 == identity
                    && epoch.draft.binding_revision == binding
            })
            .flat_map(|epoch| {
                epoch
                    .draft
                    .covered_intents
                    .into_iter()
                    .map(|intent| intent.job_id)
            })
            .collect())
    }

    /// Swift `completeOverwriteAdmission`: whether a destructive Flash of
    /// `reference` with `inputs` on this binding is ordinary, a distinct
    /// complete-overwrite recovery, or recognized in history. `now` is the
    /// Runtime clock's reading and `campaign` the hardware acceptance
    /// campaign the lane is bound to.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn complete_overwrite_admission(
        &self,
        capabilities: &CapabilityStore,
        reference: &str,
        inputs: &Value,
        identity: &str,
        binding: i64,
        now: &str,
        campaign: Option<&str>,
    ) -> Result<OverwriteAdmission, OverwriteRefusal> {
        if identity.is_empty() || binding <= 0 {
            return Err(OverwriteRefusal::blocked(
                "completeOverwriteRecovery.identityOrBindingMissing",
            ));
        }
        let epochs = self
            .recovery_epochs()
            .map_err(|error| OverwriteRefusal::Failed(format!("{error:?}")))?;
        let unresolved =
            self.unresolved_destructive_intents(capabilities, identity, binding, &epochs)?;
        if unresolved.is_empty() {
            return Ok(OverwriteAdmission::Ordinary);
        }
        let unavailable =
            || OverwriteRefusal::blocked("completeOverwriteRecovery.providerContractUnavailable");
        let contract = Contract::of(reference).ok_or_else(unavailable)?;
        let profile = flash_profile(reference, inputs).ok_or_else(unavailable)?;
        let covered = contract.covered_effects(profile).ok_or_else(unavailable)?;
        let expected: Vec<String> = covered
            .iter()
            .map(|effect| {
                effect
                    .strip_prefix("partition:")
                    .unwrap_or(effect)
                    .to_owned()
            })
            .collect();
        if flash_partitions(reference, inputs).as_ref() != Some(&expected)
            || flash_verification(reference, inputs) != "full"
        {
            return Err(OverwriteRefusal::blocked(
                "completeOverwriteRecovery.incompleteRequestedCoverage",
            ));
        }
        let effects: BTreeSet<&str> = covered.iter().map(String::as_str).collect();
        if !unresolved.iter().all(|intent| {
            canonical(&intent.operation_reference) == canonical(reference)
                && intent.profile_reference == profile
                && intent
                    .possible_effects
                    .iter()
                    .all(|effect| effects.contains(effect.as_str()))
        }) {
            return Err(OverwriteRefusal::blocked(
                "completeOverwriteRecovery.unboundedOrUnsupportedEffect",
            ));
        }
        let observed: Option<Vec<f64>> = unresolved
            .iter()
            .map(|intent| date(&intent.observed_at_utc))
            .collect();
        let Some((started, latest)) = observed.and_then(|observed| {
            let started = observed.iter().copied().reduce(f64::min)?;
            let latest = observed.iter().copied().reduce(f64::max)?;
            Some((started, latest))
        }) else {
            return Err(OverwriteRefusal::blocked(
                "completeOverwriteRecovery.invalidHistoricalTimestamp",
            ));
        };
        if let Some(historical) = self.historical_recovery(
            &unresolved,
            latest,
            reference,
            &contract,
            profile,
            &expected,
            identity,
            binding,
        )? {
            let epoch = append_recovery_epoch(&self.root, &historical)
                .map_err(|error| OverwriteRefusal::Failed(format!("{error:?}")))?;
            return Ok(OverwriteAdmission::Recognized(Box::new(epoch)));
        }
        let expired =
            || OverwriteRefusal::blocked("completeOverwriteRecovery.sharedFourHourBudgetExpired");
        let now = date(now).ok_or_else(expired)?;
        // An operator-named hardware acceptance campaign owns its window; an
        // unattended invocation stays within the shared four hours.
        let mut beyond_budget = None;
        if now - started >= FOUR_HOURS {
            beyond_budget = Some(campaign.ok_or_else(expired)?.to_owned());
        }
        let prior = epochs
            .iter()
            .filter(|epoch| {
                epoch.draft.stable_target_identity_sha256 == identity
                    && epoch.draft.binding_revision == binding
                    && date(&epoch.draft.established_at_utc)
                        .is_some_and(|established| now - established < FOUR_HOURS)
            })
            .count();
        let ordinal = unresolved.len() + prior + 1;
        if ordinal > EPOCH_BUDGET {
            return Err(OverwriteRefusal::blocked(
                "completeOverwriteRecovery.sharedEpochBudgetExhausted",
            ));
        }
        let uncertain: Vec<String> = unresolved
            .iter()
            .flat_map(|intent| intent.possible_effects.iter().cloned())
            .collect();
        Ok(OverwriteAdmission::Recovery {
            context: RecoveryContext {
                uncertain_effect_set_sha256: effect_digest(&uncertain),
                covered_intents: unresolved,
                coverage_contract_version: contract.version.clone(),
                covered_effect_set_sha256: effect_digest(covered),
                profile_reference: profile.to_owned(),
                destructive_epoch_ordinal: ordinal as i64,
            },
            campaign: beyond_budget,
        })
    }

    /// Swift `unresolvedDestructiveIntents`: every outstanding or unknown
    /// destructive intent of a Job materialized on this binding, then every
    /// destructive capability use on it whose outcome is not settled and no
    /// such Job names, each as the Flash that took it could have affected
    /// it; none an epoch already covers. What cannot be bound to a Flash's
    /// typed partitions refuses.
    fn unresolved_destructive_intents(
        &self,
        capabilities: &CapabilityStore,
        identity: &str,
        binding: i64,
        epochs: &[RecoveryEpoch],
    ) -> Result<Vec<SupersededIntent>, OverwriteRefusal> {
        let jobs = self.jobs_path();
        let mut unresolved = Vec::new();
        let mut journaled: BTreeSet<String> = BTreeSet::new();
        for name in job_directories(&jobs).unwrap_or_default() {
            let directory = jobs.join(&name);
            // A record the scan cannot read is one it cannot clear.
            let record = match recorded(&directory) {
                Recorded::Unreadable(reason) => {
                    return Err(OverwriteRefusal::Blocked(format!(
                        "completeOverwriteRecovery.unreadableHistoricalRecord: {name}: {reason}"
                    )));
                }
                Recorded::Absent => continue,
                Recorded::Readable(record) => record,
            };
            if record.materialized_identity() != Some(identity)
                || record.materialized_binding() != Some(binding)
            {
                continue;
            }
            let (facts, events) =
                crate::rockchip_startup::journal(&directory).map_err(OverwriteRefusal::Failed)?;
            if facts.has_torn_tail {
                return Err(OverwriteRefusal::blocked(
                    "completeOverwriteRecovery.tornHistoricalJournal",
                ));
            }
            let inputs = &record.request["inputs"];
            let profile = flash_profile(record.operation(), inputs).unwrap_or_default();
            let partitions = flash_partitions(record.operation(), inputs);
            let destructive: Vec<(&str, &str)> = facts
                .outstanding_intents
                .iter()
                .filter(|intent| intent.effect == "destructive")
                .map(|intent| (intent.event_id.as_str(), intent.step_id.as_str()))
                .chain(
                    facts
                        .unknown_outcomes
                        .iter()
                        .filter(|unknown| unknown.effect == "destructive")
                        .map(|unknown| {
                            (
                                unknown.correlated_intent_event_id.as_str(),
                                unknown.step_id.as_str(),
                            )
                        }),
                )
                .collect();
            if destructive.is_empty() {
                continue;
            }
            journaled.insert(record.job_id.clone());
            if events.iter().any(|event| {
                event["kind"] == "stateTransition"
                    && matches!(
                        event["payload"]["to"].as_str(),
                        Some("cancelRequested" | "userAbandonRequested")
                    )
                    && event["payload"]["from"].as_str().is_some()
            }) {
                return Err(OverwriteRefusal::blocked(
                    "completeOverwriteRecovery.explicitCancellationPending",
                ));
            }
            let mut seen = BTreeSet::new();
            for (intent, step) in destructive {
                if !seen.insert(intent) {
                    continue;
                }
                if epochs
                    .iter()
                    .any(|epoch| epoch.covers(&record.job_id, intent, identity, binding))
                {
                    continue;
                }
                let bounded = DURABLE_REFERENCES.contains(&record.operation())
                    && step == "flash-partitions"
                    && !profile.is_empty()
                    && partitions
                        .as_ref()
                        .is_some_and(|partitions| !partitions.is_empty())
                    && events.iter().any(|event| {
                        event["kind"] == "stepIntent"
                            && event["eventId"] == intent
                            && event["stepId"] == step
                            && event["payload"]["step"]["effect"] == "destructive"
                    });
                let Some(partitions) = partitions.as_ref().filter(|_| bounded) else {
                    return Err(OverwriteRefusal::blocked(
                        "completeOverwriteRecovery.unboundedHistoricalIntent",
                    ));
                };
                unresolved.push(SupersededIntent {
                    job_id: record.job_id.clone(),
                    intent_event_id: intent.to_owned(),
                    operation_reference: record.operation().to_owned(),
                    profile_reference: profile.to_owned(),
                    observed_at_utc: observed_at(&record),
                    possible_effects: partitions
                        .iter()
                        .map(|partition| format!("partition:{partition}"))
                        .collect(),
                });
            }
        }
        // A use consumed before a crash may have no journal intent: its
        // absence proves nothing, so the whole typed partition plan is what
        // it may have written.
        let lineage = capabilities.lineage().map_err(|_| {
            OverwriteRefusal::blocked("completeOverwriteRecovery.capabilityLineageUnavailable")
        })?;
        for entry in lineage {
            if entry.target.as_deref() != Some(identity)
                || entry.binding_revision != Some(binding)
                || entry.effect != "destructive"
                || matches!(
                    entry.outcome,
                    UseOutcome::Confirmed | UseOutcome::SafeToReflash
                )
            {
                continue;
            }
            if journaled.contains(&entry.job)
                || epochs.iter().any(|epoch| {
                    epoch.draft.stable_target_identity_sha256 == identity
                        && epoch.draft.binding_revision == binding
                        && epoch
                            .draft
                            .covered_intents
                            .iter()
                            .any(|intent| intent.job_id == entry.job)
                })
            {
                continue;
            }
            let bound = loaded(&jobs.join(&entry.job)).and_then(|record| {
                if record.materialized_identity() != Some(identity)
                    || record.materialized_binding() != Some(binding)
                    || record.operation() != entry.operation_reference
                    || record.actual_effect() != Some("destructive")
                {
                    return None;
                }
                let inputs = &record.request["inputs"];
                let profile = flash_profile(record.operation(), inputs)?.to_owned();
                let partitions = flash_partitions(record.operation(), inputs)
                    .filter(|partitions| !partitions.is_empty())?;
                Some((record, profile, partitions))
            });
            let Some((record, profile, partitions)) = bound else {
                return Err(OverwriteRefusal::blocked(
                    "completeOverwriteRecovery.unboundedCapabilityLineage",
                ));
            };
            unresolved.push(SupersededIntent {
                job_id: entry.job.clone(),
                intent_event_id: format!("capability-{}-use-{}", entry.capability, entry.ordinal),
                operation_reference: record.operation().to_owned(),
                profile_reference: profile,
                observed_at_utc: observed_at(&record),
                possible_effects: partitions
                    .iter()
                    .map(|partition| format!("partition:{partition}"))
                    .collect(),
            });
        }
        unresolved.sort_by(|left, right| {
            (&left.observed_at_utc, &left.job_id, &left.intent_event_id).cmp(&(
                &right.observed_at_utc,
                &right.job_id,
                &right.intent_event_id,
            ))
        });
        Ok(unresolved)
    }

    /// Swift `historicalRecovery`: the earliest recovery Flash that finished
    /// after the latest unknown intent, succeeded cleanly on this binding
    /// with this profile, every covered partition and full verification, and
    /// whose journal confirms the write and every verification step from the
    /// lane's completed plan — as the epoch it established.
    #[allow(clippy::too_many_arguments)]
    fn historical_recovery(
        &self,
        unresolved: &[SupersededIntent],
        latest: f64,
        reference: &str,
        contract: &Contract,
        profile: &str,
        expected: &[String],
        identity: &str,
        binding: i64,
    ) -> Result<Option<RecoveryEpochDraft>, OverwriteRefusal> {
        let jobs = self.jobs_path();
        let Some(names) = job_directories(&jobs) else {
            return Ok(None);
        };
        let required = contract.required_steps();
        let mut candidates: Vec<(std::path::PathBuf, JobRecord, f64)> = names
            .iter()
            .filter_map(|name| {
                let directory = jobs.join(name);
                let record = loaded(&directory)?;
                let finished = date(record.finished_at()?)?;
                let inputs = &record.request["inputs"];
                let clean = finished > latest
                    && record.state == "succeeded"
                    && !record.outcome_unknown()
                    && canonical(record.operation()).is_some()
                    && canonical(record.operation()) == canonical(reference)
                    && record.materialized_identity() == Some(identity)
                    && record.materialized_binding() == Some(binding)
                    && flash_profile(record.operation(), inputs) == Some(profile)
                    && flash_partitions(record.operation(), inputs).as_deref() == Some(expected)
                    && flash_verification(record.operation(), inputs) == "full"
                    && record.materialized_plan().is_some_and(lowercase_sha256);
                clean.then_some((directory, record, finished))
            })
            .collect();
        candidates.sort_by(|left, right| left.2.total_cmp(&right.2));
        for (directory, record, _) in candidates {
            let (facts, events) =
                crate::rockchip_startup::journal(&directory).map_err(OverwriteRefusal::Failed)?;
            if facts.has_torn_tail
                || !facts.outstanding_intents.is_empty()
                || !facts.unknown_outcomes.is_empty()
                || facts.current_state.as_deref() != Some("succeeded")
            {
                continue;
            }
            let (confirmed_steps, intents) = confirmed(&events, &required, false);
            let (Some(recovery_intent), true) = (
                intents.get(&contract.overwrite_step),
                required.iter().all(|step| intents.contains_key(step)),
            ) else {
                continue;
            };
            let Some((artifact, executable)) = host_proof(&record, &events, &required, expected)
            else {
                continue;
            };
            let plan = record.materialized_plan().unwrap_or_default().to_owned();
            let uncertain: Vec<String> = unresolved
                .iter()
                .flat_map(|intent| intent.possible_effects.iter().cloned())
                .collect();
            let covered = contract.covered_effects(profile).unwrap_or_default();
            return Ok(Some(RecoveryEpochDraft {
                source: RecoverySource::HistoricalRecognition,
                stable_target_identity_sha256: identity.to_owned(),
                binding_revision: binding,
                covered_intents: unresolved.to_vec(),
                uncertain_effect_set_sha256: effect_digest(&uncertain),
                coverage_contract_version: contract.version.clone(),
                covered_effect_set_sha256: effect_digest(covered),
                recovery_job_id: record.job_id.clone(),
                recovery_intent_event_id: recovery_intent.clone(),
                operation_reference: record.operation().to_owned(),
                profile_reference: profile.to_owned(),
                resulting_target_epoch_sha256: resulting_epoch(
                    identity,
                    binding,
                    &record.job_id,
                    &plan,
                    &artifact,
                    &required,
                ),
                materialized_plan_digest_sha256: plan,
                artifact_sha256: artifact,
                provider_executable_sha256: executable,
                confirmed_step_ids: confirmed_steps,
                established_at_utc: record.finished_at().unwrap_or_default().to_owned(),
            }));
        }
        Ok(None)
    }

    /// Swift `establishSupersedingRecoveryEpoch`: the epoch a distinct
    /// recovery establishes once its journal is clean and confirms the write
    /// and every verification step from the lane's completed plan, appended
    /// at `now`. `reference` is the operation the recovery ran.
    pub(crate) fn establish_recovery_epoch(
        &self,
        record: &JobRecord,
        reference: &str,
        now: &str,
    ) -> Result<RecoveryEpoch, String> {
        let lacking = || {
            "complete-overwrite terminal lacks immutable coverage, target, Artifact or tool facts"
                .to_owned()
        };
        let evidence = record.admission_evidence().ok_or_else(lacking)?;
        let recovery = RecoveryContext::from_evidence(evidence).ok_or_else(lacking)?;
        let contract = Contract::of(reference)
            .filter(|contract| contract.version == recovery.coverage_contract_version)
            .ok_or_else(lacking)?;
        if contract
            .covered_effects(&recovery.profile_reference)
            .is_none_or(|covered| effect_digest(covered) != recovery.covered_effect_set_sha256)
        {
            return Err(lacking());
        }
        let (Some(identity), Some(binding), Some(plan), Some(artifact), Some(provider)) = (
            record.materialized_identity(),
            record.materialized_binding(),
            record.materialized_plan(),
            evidence["runtimeCapabilityCorrelation"]["artifactSHA256"]
                .as_str()
                .filter(|artifact| lowercase_sha256(artifact)),
            evidence["recoveryProviderExecutableSHA256"]
                .as_str()
                .filter(|provider| lowercase_sha256(provider)),
        ) else {
            return Err(lacking());
        };
        let (facts, events) =
            crate::rockchip_startup::journal(&self.jobs_path().join(&record.job_id))?;
        if facts.has_torn_tail
            || !facts.outstanding_intents.is_empty()
            || !facts.unknown_outcomes.is_empty()
        {
            return Err("complete-overwrite terminal has unresolved recovery intent".into());
        }
        let required = contract.required_steps();
        let (confirmed_steps, intents) = confirmed(&events, &required, true);
        let (Some(recovery_intent), true) = (
            intents.get(&contract.overwrite_step),
            required.iter().all(|step| intents.contains_key(step)),
        ) else {
            return Err(
                "complete-overwrite terminal lacks all write/readback/postflight outcomes".into(),
            );
        };
        let draft = RecoveryEpochDraft {
            source: RecoverySource::DistinctRecoveryExecution,
            stable_target_identity_sha256: identity.to_owned(),
            binding_revision: binding,
            covered_intents: recovery.covered_intents.clone(),
            uncertain_effect_set_sha256: recovery.uncertain_effect_set_sha256.clone(),
            coverage_contract_version: recovery.coverage_contract_version.clone(),
            covered_effect_set_sha256: recovery.covered_effect_set_sha256.clone(),
            recovery_job_id: record.job_id.clone(),
            recovery_intent_event_id: recovery_intent.clone(),
            operation_reference: record.operation().to_owned(),
            profile_reference: recovery.profile_reference.clone(),
            materialized_plan_digest_sha256: plan.to_owned(),
            artifact_sha256: artifact.to_owned(),
            provider_executable_sha256: provider.to_owned(),
            confirmed_step_ids: confirmed_steps,
            resulting_target_epoch_sha256: resulting_epoch(
                identity,
                binding,
                &record.job_id,
                plan,
                artifact,
                &required,
            ),
            established_at_utc: now.to_owned(),
        };
        append_recovery_epoch(&self.root, &draft).map_err(|error| format!("{error:?}"))
    }
}

impl JobStore {
    /// Swift `matchingDurableRecoveryEpoch`: for a complete-overwrite recovery
    /// a restart found `finalizing` with a clean journal, the distinct
    /// recovery epoch it already established — its coverage, target,
    /// Artifact, tool and every confirmed step exactly the Job's — if the
    /// crash came after the epoch and before the terminal transition. A Job
    /// that is no such recovery, or whose proof is incomplete, matches none.
    pub(crate) fn matching_recovery_epoch(
        &self,
        record: &JobRecord,
        events: &[Value],
    ) -> Result<Option<RecoveryEpoch>, crate::RecoveryEpochError> {
        let Some(evidence) = record.admission_evidence() else {
            return Ok(None);
        };
        if evidence.get("completeOverwriteRecovery").is_none() {
            return Ok(None);
        }
        let epochs = self.recovery_epochs()?;
        let Some(recovery) = RecoveryContext::from_evidence(evidence) else {
            return Ok(None);
        };
        let Some(contract) = Contract::of(record.operation())
            .filter(|contract| contract.version == recovery.coverage_contract_version)
        else {
            return Ok(None);
        };
        let (Some(identity), Some(binding), Some(plan), Some(artifact), Some(provider)) = (
            record
                .materialized_identity()
                .filter(|identity| lowercase_sha256(identity)),
            record.materialized_binding().filter(|binding| *binding > 0),
            record
                .materialized_plan()
                .filter(|plan| lowercase_sha256(plan)),
            evidence["runtimeCapabilityCorrelation"]["artifactSHA256"]
                .as_str()
                .filter(|artifact| lowercase_sha256(artifact)),
            evidence["recoveryProviderExecutableSHA256"]
                .as_str()
                .filter(|provider| lowercase_sha256(provider)),
        ) else {
            return Ok(None);
        };
        if contract
            .covered_effects(&recovery.profile_reference)
            .is_none_or(|covered| effect_digest(covered) != recovery.covered_effect_set_sha256)
        {
            return Ok(None);
        }
        let required = contract.required_steps();
        let (confirmed_steps, intents) = confirmed(events, &required, true);
        let (Some(overwrite), true) = (
            intents.get(&contract.overwrite_step),
            required.iter().all(|step| intents.contains_key(step)),
        ) else {
            return Ok(None);
        };
        let resulting =
            resulting_epoch(identity, binding, &record.job_id, plan, artifact, &required);
        Ok(epochs.into_iter().rev().find(|epoch| {
            let draft = &epoch.draft;
            draft.source == RecoverySource::DistinctRecoveryExecution
                && draft.recovery_job_id == record.job_id
                && &draft.recovery_intent_event_id == overwrite
                && draft.stable_target_identity_sha256 == identity
                && draft.binding_revision == binding
                && draft.covered_intents == recovery.covered_intents
                && draft.uncertain_effect_set_sha256 == recovery.uncertain_effect_set_sha256
                && draft.coverage_contract_version == recovery.coverage_contract_version
                && draft.covered_effect_set_sha256 == recovery.covered_effect_set_sha256
                && draft.operation_reference == record.operation()
                && draft.profile_reference == recovery.profile_reference
                && draft.materialized_plan_digest_sha256 == plan
                && draft.artifact_sha256 == artifact
                && draft.provider_executable_sha256 == provider
                && draft.confirmed_step_ids == confirmed_steps
                && draft.resulting_target_epoch_sha256 == resulting
        }))
    }
}

/// When a Job's unknown intent was last observed: when it finished, or when
/// it was admitted.
fn observed_at(record: &JobRecord) -> String {
    record
        .finished_at()
        .unwrap_or_else(|| record.created())
        .to_owned()
}

/// Swift `historicalHostProof`: the exact Artifact and daemon tool a
/// recovery's capability evidence retains, and each required step's
/// confirmed plan-completion outcome, correlated to its intent, carrying the
/// lane's plan and evidence digest.
fn host_proof(
    record: &JobRecord,
    events: &[Value],
    required: &[String],
    expected: &[String],
) -> Option<(String, String)> {
    let distinct: BTreeSet<&String> = expected.iter().collect();
    if expected.is_empty() || distinct.len() != expected.len() {
        return None;
    }
    let evidence = record.admission_evidence()?;
    if evidence["kind"] != "runtimeCapability" {
        return None;
    }
    let artifact = evidence["runtimeCapabilityCorrelation"]["artifactSHA256"]
        .as_str()
        .filter(|artifact| lowercase_sha256(artifact))?;
    let executable = evidence["recoveryProviderExecutableSHA256"]
        .as_str()
        .filter(|executable| lowercase_sha256(executable))?;
    for step in required {
        let outcome = events.iter().find(|event| {
            event["kind"] == "stepOutcome"
                && event["stepId"] == step.as_str()
                && event["payload"]["result"] == "succeeded"
                && event["payload"]["outcomeCertainty"] == "confirmed"
                && event["payload"]["semanticCode"] == PLAN_COMPLETION_CODE
        })?;
        let intent = outcome["payload"]["correlatesToIntentEventId"].as_str()?;
        let summary = outcome["payload"]["summary"].as_str()?;
        if !events.iter().any(|event| {
            event["kind"] == "stepIntent"
                && event["eventId"] == intent
                && event["stepId"] == step.as_str()
        }) || !summary.contains("arkforge-plan=")
            || !summary.contains("evidence-sha256=")
        {
            return None;
        }
    }
    Some((artifact.to_owned(), executable.to_owned()))
}
