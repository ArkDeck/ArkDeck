//! What Swift's daemon does with the Rockchip state before its engine starts
//! (`main.swift`, after the Target store opens), in its order:
//!
//! - In the production layout, a state directory `Agentd` below `ArkDeck`,
//!   the adopted Target is carried along the adjacent lineage edge its Loader
//!   binding records (`RuntimeTargetStore.advanceBindingLineage`), and the
//!   binding's Loader recovery proof is kept for the engine. A binding whose
//!   lineage cannot be followed is reported as needing Loader onboarding; one
//!   that cannot be read stops the start.
//! - In every layout, Swift `ProductRockchipTargetAliasReconciler` proves,
//!   from terminal Flash history alone, that an HDC address adopted as a
//!   second Target is the post-flash face of the Loader-bound one, and
//!   appends that relation to the Target document. Any partial or
//!   contradictory proof leaves the alias gate closed and is reported.
//!
//! Nothing here observes or dispatches to a device, and no Job is changed.
use crate::flash_facts::{TargetRecord, alias_covers, post_flash, target_records};
use crate::job_journal::JournalEvent;
use crate::job_journal_replay::{ReplayFacts, ReplayState};
use crate::job_owner::JobStore;
use crate::job_record::JobRecord;
use crate::post_flash_alias::PostFlashBinding;
use crate::post_flash_alias_store::PostFlashAliasStore;
use crate::rockchip_binding::{BindingSnapshot, RecoveryProof, RockchipBindingStore};
use crate::strict_json::swift_quoted;
use crate::target_document::{AliasResolutionDraft, AliasResolutionName};
use crate::target_owner::TargetStore;
use serde_json::Value;
use std::collections::BTreeSet;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

/// The six steps a Flash must have confirmed before it can prove an alias
/// (Swift `requiredConfirmedStepIDs`), with the effect each one's intent
/// declares (`hasRequiredEffects`).
const REQUIRED_STEPS: [(&str, &str); 6] = [
    ("enter-loader-mode", "deviceMutation"),
    ("flash-partitions", "destructive"),
    ("verify-flash-readback", "readOnly"),
    ("reboot-device", "deviceMutation"),
    ("wait-for-hdc", "readOnly"),
    ("rebind-and-verify-build", "readOnly"),
];
/// Swift `ArkForgeFlashOperation.canonicalReference`.
const CANONICAL_FLASH: &str = "flash.full-restore@1";

/// What the start-up reconciliation left.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RockchipStartup {
    /// The lines Swift's daemon prints, in its order.
    pub lines: Vec<String>,
    /// The Target the binding's lineage names and the binding's Loader
    /// recovery proof, which Swift's engine uses to settle an enter-Loader
    /// transition left awaiting that binding.
    pub recovery: Option<(String, RecoveryProof)>,
}

impl RockchipStartup {
    /// Swift's engine once its Jobs are recovered (`main.swift` 1342–1356):
    /// the DAYU200 Flash Job whose enter-Loader transition awaits the binding
    /// this start carried its Target to. Swift settles that Job without
    /// replay; this Runtime does not settle it yet, so the line answered
    /// names it, and its intent stays unresolved for a Runtime that can. Two
    /// or more stop the start, as Swift's engine refuses them. Jobs this
    /// owner cannot read are reported, not settled either.
    pub fn awaiting_transition(&self, jobs: &JobStore) -> Result<Option<String>, String> {
        let Some((target, proof)) = &self.recovery else {
            return Ok(None);
        };
        let awaiting = match jobs
            .loader_transitions_awaiting_binding(target, proof.previous_revision)
        {
            Ok(awaiting) => awaiting,
            Err(error) => {
                return Ok(Some(format!(
                    "Loader transitions awaiting Rockchip binding revision {} cannot be read: {}",
                    proof.current_revision, error.message
                )));
            }
        };
        match awaiting.as_slice() {
            [] => Ok(None),
            [job] => Ok(Some(format!(
                "Loader transition {job} awaits settlement at Rockchip binding revision {}, \
                 which this Runtime does not settle yet; its outcome stays unknown",
                proof.current_revision
            ))),
            _ => Err(format!(
                "jobNotRunnable({})",
                swift_quoted(&format!(
                    "multiple unresolved Loader transitions cover target {target}"
                ))
            )),
        }
    }
}

/// Swift's start-up steps over the Target store and the state directory
/// holding the Jobs, whose parent is the Application Support root. `Err` is
/// what stops Swift's start: a production binding that cannot be read.
pub fn reconcile_rockchip_startup(
    targets: &TargetStore,
    state_directory: &Path,
) -> Result<RockchipStartup, String> {
    let mut startup = RockchipStartup::default();
    let Some(root) = state_directory.parent() else {
        return Ok(startup);
    };
    // Custom state directories never consult the account's production
    // binding.
    let production = state_directory
        .file_name()
        .is_some_and(|name| name == "Agentd")
        && root.file_name().is_some_and(|name| name == "ArkDeck");
    if production
        && let Some(binding) = RockchipBindingStore::new(root)
            .load_if_present()
            .map_err(|error| error.swift())?
        && let Err(error) = advance(targets, &binding, &mut startup)
    {
        startup.lines.push(format!(
            "Rockchip binding requires Runtime Loader onboarding: {error}"
        ));
    }
    match reconcile_alias(targets, root, state_directory) {
        Ok(Some(name)) => startup.lines.push(format!(
            "resolved historical target alias {} to {} via {}",
            name.alias, name.canonical, name.resolution_id
        )),
        Ok(None) => {}
        Err(error) => startup.lines.push(format!(
            "Rockchip target alias remains fail-closed: {error}"
        )),
    }
    Ok(startup)
}

/// The adjacent edge carried into the Target store, then the recovery proof
/// kept, then the line when the Target moved.
fn advance(
    targets: &TargetStore,
    binding: &BindingSnapshot,
    startup: &mut RockchipStartup,
) -> Result<(), String> {
    let Some(edge) = binding
        .runtime_target_lineage_advance()
        .map_err(|error| error.swift())?
    else {
        return Ok(());
    };
    let advanced = targets.advance_binding_lineage(&edge)?;
    if let Some(proof) = binding
        .loader_binding_recovery_proof()
        .map_err(|error| error.swift())?
    {
        startup.recovery = Some((advanced.target_id.clone(), proof));
    }
    if advanced.updated {
        startup.lines.push(format!(
            "advanced runtime target {} to Rockchip binding revision {}",
            advanced.target_id, advanced.binding_revision
        ));
    }
    Ok(())
}

fn store_failure(detail: &str) -> String {
    format!("storeFailure({})", swift_quoted(detail))
}

/// Swift `ISO8601Timestamps.parse`, as seconds.
fn date(text: &str) -> Option<f64> {
    crate::format_time::format_timestamp_seconds(text)
}

fn lowercase_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Swift `isJobID`: `job-` and 32 lowercase hexadecimal digits.
fn job_id(value: &str) -> bool {
    value
        .strip_prefix("job-")
        .is_some_and(|rest| lowercase_hex(rest, 32))
}

fn string<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// Swift `RuntimeJobRecord.load(from:)`. Swift prints Foundation's own
/// description of a failure, which carries object addresses; the reason
/// here is this Runtime's.
fn job_record(directory: &Path) -> Result<JobRecord, String> {
    let path = directory.join("job-record.json");
    let bytes = std::fs::read(&path)
        .map_err(|error| format!("{} cannot be read: {error}", path.display()))?;
    JobRecord::decode(&bytes).map_err(|error| format!("{}: {}", path.display(), error.message))
}

/// A Job's journal replayed as Swift `DurableJournalRecovery.inspect(url:)`
/// reads it: opened through no link, a regular file, every completed record
/// decoded, then replayed; its facts and its events, in order. A refusal is
/// Swift's `DurableFileError` as the daemon prints it, a replay violation
/// with this Runtime's fixed reason.
pub(crate) fn journal(directory: &Path) -> Result<(ReplayFacts, Vec<Value>), String> {
    let path = directory.join("journal.jsonl");
    let open_failed = |error: std::io::Error| {
        format!(
            "openFailed(path: {}, errno: {})",
            swift_quoted(&path.to_string_lossy()),
            error.raw_os_error().unwrap_or(libc::EIO)
        )
    };
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(&path)
        .map_err(open_failed)?;
    let Some(before) = file.metadata().ok().filter(std::fs::Metadata::is_file) else {
        return Err(
            "sequenceViolation(\"journal snapshot must be a bounded regular file\")".into(),
        );
    };
    let mut bytes = Vec::new();
    (&file).read_to_end(&mut bytes).map_err(open_failed)?;
    // Swift's `sameJournalSnapshot`, but for the generation number, which
    // only the superuser reads.
    let snapshot = |metadata: &std::fs::Metadata| {
        (
            metadata.dev(),
            metadata.ino(),
            metadata.size(),
            (metadata.mtime(), metadata.mtime_nsec()),
            (metadata.ctime(), metadata.ctime_nsec()),
        )
    };
    if file.metadata().ok().as_ref().map(snapshot) != Some(snapshot(&before)) {
        return Err(
            "sequenceViolation(\"journal changed while its snapshot was replayed\")".into(),
        );
    }
    let mut events = Vec::new();
    if let Some(completed) = bytes.iter().rposition(|b| *b == b'\n') {
        for (offset, line) in bytes[..completed].split(|b| *b == b'\n').enumerate() {
            let event = JournalEvent::decode(line)
                .ok()
                .filter(|_| !line.is_empty())
                .ok_or_else(|| format!("malformedCompletedRecord(line: {})", offset + 1))?;
            events.push(event.value().clone());
        }
    }
    let replay = ReplayState::replay(&bytes)
        .map_err(|violation| format!("sequenceViolation({})", swift_quoted(violation)))?;
    Ok((replay.state.facts(replay.torn), events))
}

/// Swift `ArkForgeFlashRequest.profileReference(submittedReference:inputs:)`.
fn profile_reference<'a>(operation: &str, inputs: &'a Value) -> Option<&'a str> {
    let name = if operation == CANONICAL_FLASH {
        "deviceProfileRef"
    } else {
        "deviceProfile"
    };
    string(inputs, name).filter(|reference| !reference.is_empty())
}

/// Swift `verification(record:)`: the requested post-flash verification,
/// `full` when none is named.
fn verification<'a>(operation: &str, inputs: &'a Value) -> &'a str {
    let key = if operation == CANONICAL_FLASH {
        "verification"
    } else {
        "postFlashVerification"
    };
    string(inputs, key).unwrap_or("full")
}

/// Swift `publishedPartitionPlan()`: the partitions the canonical Flash
/// operation's DAYU200 recovery profile covers, in its order.
fn published_partition_plan() -> Option<Vec<String>> {
    let catalog: Value = serde_json::from_str(arkdeck_contract::CATALOG_CANONICAL_JSON).ok()?;
    let operation = catalog
        .as_array()?
        .iter()
        .find(|operation| operation["id"] == "flash.full-restore" && operation["version"] == 1)?;
    let profile = operation["completeOverwriteRecovery"]["profiles"]
        .as_array()?
        .iter()
        .find(|profile| profile["reference"] == "dayu200")?;
    Some(
        profile["coveredEffects"]
            .as_array()?
            .iter()
            .filter_map(|effect| effect.as_str()?.strip_prefix("partition:"))
            .map(str::to_owned)
            .collect(),
    )
}

/// Swift `partitionPlan(record:)`: the canonical operation's full restore is
/// the published plan; the retired one names its partitions.
fn partition_plan(operation: &str, inputs: &Value) -> Option<Vec<String>> {
    if operation == CANONICAL_FLASH {
        if inputs["intent"] != "fullRestore" {
            return None;
        }
        return published_partition_plan();
    }
    inputs["partitionPlan"]
        .as_array()?
        .iter()
        .map(|partition| partition.as_str().map(str::to_owned))
        .collect()
}

/// Swift `confirmedStepIDs(_:)`: each step with a succeeded, confirmed
/// outcome correlated to an intent of that step, once, in journal order.
fn confirmed_steps(events: &[Value]) -> Vec<String> {
    let mut steps = Vec::new();
    let mut seen = BTreeSet::new();
    for outcome in events.iter().filter(|event| event["kind"] == "stepOutcome") {
        let (Some(step), Some(intent)) = (
            string(outcome, "stepId"),
            string(&outcome["payload"], "correlatesToIntentEventId"),
        ) else {
            continue;
        };
        if outcome["payload"]["result"] != "succeeded"
            || outcome["payload"]["outcomeCertainty"] != "confirmed"
            || !events.iter().any(|event| {
                event["kind"] == "stepIntent"
                    && string(event, "eventId") == Some(intent)
                    && string(event, "stepId") == Some(step)
            })
            || !seen.insert(step)
        {
            continue;
        }
        steps.push(step.to_owned());
    }
    steps
}

/// Swift `hasRequiredEffects(_:)`: an intent of every required step
/// declared the effect a complete Flash's does. A decoded intent's step is
/// a valid workflow step, so its effect is Swift's `stepEffect`.
fn has_required_effects(events: &[Value]) -> bool {
    REQUIRED_STEPS.iter().all(|(step, effect)| {
        events.iter().any(|event| {
            event["kind"] == "stepIntent"
                && string(event, "stepId") == Some(step)
                && event["payload"]["step"]["effect"] == *effect
        })
    })
}

/// Swift `ProductRockchipTargetAliasReconciler.reconcileIfProven()`: `None`
/// when there is no duplicate alias; the appended (or reused) relation when
/// the establishing Flash proves it; any partial proof refuses.
fn reconcile_alias(
    targets: &TargetStore,
    root: &Path,
    state_directory: &Path,
) -> Result<Option<AliasResolutionName>, String> {
    let Some(route) = PostFlashAliasStore::new(root)
        .load_if_present()
        .map_err(post_flash)?
    else {
        return Ok(None);
    };
    let Some(binding) = RockchipBindingStore::new(root)
        .load_if_present()
        .map_err(|error| error.swift())?
    else {
        return Ok(None);
    };
    let records = target_records(targets)?;
    let Some(canonical) = records.iter().find(|t| t.target_id == route.target_id) else {
        return Ok(None);
    };
    if !alias_covers(&route, canonical, &binding)? {
        return Ok(None);
    }
    let aliases: Vec<&TargetRecord> = records
        .iter()
        .filter(|t| {
            t.target_id != canonical.target_id
                && t.connect_key == route.hdc_connect_key
                && t.identity == route.hdc_identity_sha256
        })
        .collect();
    let alias = match aliases.as_slice() {
        [] => return Ok(None),
        [alias]
            if alias.binding_revision == 1
                && canonical.binding_revision > alias.binding_revision
                && job_id(&route.job_id) =>
        {
            *alias
        }
        _ => {
            return Err(store_failure(
                "post-flash HDC alias has ambiguous or advanced durable ownership",
            ));
        }
    };
    let revision = |revision: i64| u64::try_from(revision).unwrap_or_default();
    let mut draft = AliasResolutionDraft {
        alias: alias.target_id.clone(),
        alias_identity: alias.identity.clone(),
        alias_revision: revision(alias.binding_revision),
        canonical: canonical.target_id.clone(),
        canonical_identity: canonical.identity.clone(),
        canonical_revision: revision(canonical.binding_revision),
        routed_identity: route.hdc_identity_sha256.clone(),
        topology: route.usb_topology.clone(),
        job: String::new(),
        plan: String::new(),
        steps: Vec::new(),
        intents: Vec::new(),
        established_at: String::new(),
    };
    // The relation is about exact durable identities, not one Flash: a later
    // Flash republishing the same route reuses it, and any drift goes
    // through the full proof.
    if let Some(existing) = targets.matching_alias_resolution(&draft)? {
        return Ok(Some(existing));
    }
    let directory = state_directory.join("jobs").join(&route.job_id);
    let flash = job_record(&directory)?;
    let (facts, events) = journal(&directory)?;
    let (plan, finished) = establishing_flash(&flash, &facts, &route, canonical)?;
    let steps = confirmed_steps(&events);
    let confirmed: BTreeSet<&str> = steps.iter().map(String::as_str).collect();
    if !REQUIRED_STEPS
        .iter()
        .all(|(step, _)| confirmed.contains(step))
        || !has_required_effects(&events)
    {
        return Err(store_failure(
            "post-flash HDC alias establishing Flash lacks write/readback/postflight proof",
        ));
    }
    let started = date(flash.started_at().unwrap_or(flash.created()));
    let (Some(started), Some(adopted)) = (started, date(&alias.adopted_at)) else {
        return Err(store_failure(
            "post-flash HDC alias chronology is missing or reversed",
        ));
    };
    if adopted >= started {
        return Err(store_failure(
            "post-flash HDC alias chronology is missing or reversed",
        ));
    }
    draft.intents = covered_unknown_mode_intents(alias, state_directory, started)?;
    draft.job = flash.job_id.clone();
    draft.plan = plan;
    draft.steps = steps;
    draft.established_at = finished;
    targets.append_alias_resolution(&draft).map(Some)
}

/// The establishing Flash's operation, target, capability and terminal
/// journal facts, each missing one refused in Swift's words; its plan digest
/// and when it finished.
fn establishing_flash(
    record: &JobRecord,
    facts: &ReplayFacts,
    route: &PostFlashBinding,
    canonical: &TargetRecord,
) -> Result<(String, String), String> {
    let request = &record.request;
    let operation = record.operation();
    let inputs = &request["inputs"];
    if record.job_id != route.job_id
        || !record.dayu200_flash()
        || !["arkforge", "rockchip"].contains(&record.provider())
        || request["target"]["targetId"].as_str() != Some(canonical.target_id.as_str())
        || request["target"]["expectedBindingRevision"].as_i64() != Some(canonical.binding_revision)
        || record.materialized_identity() != Some(canonical.identity.as_str())
        || record.materialized_binding() != Some(canonical.binding_revision)
        || profile_reference(operation, inputs) != Some("dayu200")
        || verification(operation, inputs) != "full"
        || partition_plan(operation, inputs) != published_partition_plan()
    {
        return Err(store_failure(
            "post-flash HDC alias establishing Flash has mismatched operation or target facts",
        ));
    }
    let capability = record
        .admission_evidence()
        .filter(|evidence| evidence["kind"] == "runtimeCapability")
        .and_then(|evidence| evidence.get("runtimeCapabilityCorrelation"));
    let proven = |plan: &str, capability: &Value| {
        lowercase_hex(plan, 64)
            && string(capability, "planDigestSHA256") == Some(plan)
            && string(capability, "stepSetDigestSHA256").is_some_and(|d| lowercase_hex(d, 64))
            && string(capability, "targetBindingDigestSHA256").is_some_and(|d| lowercase_hex(d, 64))
            && string(capability, "artifactSHA256").is_some_and(|d| lowercase_hex(d, 64))
    };
    let plan = match (record.materialized_plan(), capability) {
        (Some(plan), Some(capability)) if proven(plan, capability) => plan.to_owned(),
        _ => {
            return Err(store_failure(
                "post-flash HDC alias establishing Flash lacks immutable capability facts",
            ));
        }
    };
    let finished = record.finished_at().filter(|finished| {
        record.state == "succeeded"
            && !record.outcome_unknown()
            && date(finished)
                .zip(date(&route.established_at_utc))
                .is_some_and(|(finished, established)| established <= finished)
            && !facts.has_torn_tail
            && facts.outstanding_intents.is_empty()
            && facts.unknown_outcomes.is_empty()
            && facts.current_state.as_deref() == Some("succeeded")
    });
    let Some(finished) = finished else {
        return Err(store_failure(
            "post-flash HDC alias establishing Flash lacks clean terminal journal proof",
        ));
    };
    Ok((plan, finished.to_owned()))
}

/// Swift `coveredUnknownModeIntents(alias:before:)`: every unresolved
/// device-affecting intent of a Job on the alias Target, which the later
/// complete Flash covers only when it is a DAYU200 Flash's enter-Loader mode
/// change observed before that Flash started.
fn covered_unknown_mode_intents(
    alias: &TargetRecord,
    state_directory: &Path,
    recovery_started: f64,
) -> Result<Vec<(String, String, String, String)>, String> {
    let jobs = state_directory.join("jobs");
    let listing = |error: std::io::Error| format!("{} cannot be listed: {error}", jobs.display());
    let mut names = Vec::new();
    for entry in std::fs::read_dir(&jobs).map_err(listing)? {
        let entry = entry.map_err(listing)?;
        let name = entry.file_name().to_string_lossy().into_owned();
        // Swift keeps the Job directories among the visible entries; a Job
        // name is never hidden, and a link is not a directory.
        if job_id(&name) && entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            names.push(name);
        }
    }
    names.sort();
    let mut covered = Vec::new();
    let mut seen = BTreeSet::new();
    for name in names {
        let directory = jobs.join(&name);
        let record = job_record(&directory)
            .map_err(|_| store_failure("target alias history contains an unreadable Job record"))?;
        if record.request["target"]["targetId"].as_str() != Some(alias.target_id.as_str())
            || record.materialized_identity() != Some(alias.identity.as_str())
            || record.materialized_binding() != Some(alias.binding_revision)
        {
            continue;
        }
        let (facts, events) = journal(&directory)?;
        if facts.has_torn_tail {
            return Err(store_failure("target alias history has a torn journal"));
        }
        let unresolved = facts
            .outstanding_intents
            .iter()
            .map(|i| (&i.event_id, &i.event_id, &i.step_id, &i.effect))
            .chain(facts.unknown_outcomes.iter().map(|u| {
                (
                    &u.correlated_intent_event_id,
                    &u.event_id,
                    &u.step_id,
                    &u.effect,
                )
            }));
        for (intent, uncertainty, step, effect) in unresolved {
            // Swift's `effect >= .deviceMutation`.
            if !matches!(effect.as_str(), "deviceMutation" | "destructive") {
                continue;
            }
            let observed = events
                .iter()
                .find(|event| string(event, "eventId") == Some(uncertainty))
                .and_then(|event| string(event, "timestamp"))
                .and_then(date);
            if !record.dayu200_flash()
                || step != "enter-loader-mode"
                || effect != "deviceMutation"
                || !observed.is_some_and(|observed| observed < recovery_started)
            {
                return Err(store_failure(
                    "target alias carries an effect not covered by later normal-mode postflight",
                ));
            }
            if seen.insert((record.job_id.clone(), intent.clone())) {
                covered.push((
                    record.job_id.clone(),
                    intent.clone(),
                    step.clone(),
                    effect.clone(),
                ));
            }
        }
    }
    covered.sort_by(|left, right| (&left.0, &left.1).cmp(&(&right.0, &right.1)));
    Ok(covered)
}
