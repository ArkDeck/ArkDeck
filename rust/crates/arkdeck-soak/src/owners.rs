//! The macOS workload: a bounded simulation over production Rust owners. No
//! child, shell, live device transport, capability administration or
//! unknown-outcome replay. Each owner generation serves the existing control
//! protocol on a private Unix socket.
use crate::{
    Configuration, Metrics, Result, SoakClock, SystemClock, error, pause, persist, resource_gate,
};
use arkdeck_hoststore::{
    ArtifactReadStore, HdcComposition, JobAdmitter, JobCanceller, JobPlanner, JobResultReader,
    JobRunner, JobStore, ObservationReference, SessionPublisher, SessionStore, Sources,
    StorageClaims, SystemStorageProbe, TargetObservations, TargetStore, inspect_journal,
    runtime_now, runtime_precise_now,
};
use arkdeck_platform::{ContinuousInstant, HostDirectory, SelfResources, self_resources};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt, UsbRelation};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
// The modules beside this file that compose the same owners.
#[path = "socket_cycle.rs"]
mod socket_cycle;
use std::time::Duration;

#[path = "artifact_bench.rs"]
pub mod artifact_bench;
#[path = "recovery.rs"]
pub mod recovery;

fn now() -> Result<String> {
    runtime_now().ok_or_else(|| "Runtime clock unavailable".into())
}
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const DIGEST: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const OWNER_MARKER: &[u8] = b"arkdeck-rust-soak/simulated-only/v1";
#[cfg(test)]
static DISPATCH_ATTEMPTS: AtomicU64 = AtomicU64::new(0);

/// This fake handles only the exact production observation plans. It never
/// executes arguments: each accepted sequence maps to bounded in-memory bytes.
#[derive(Default)]
struct SimulatedHdc(AtomicU64);
impl HdcDispatch for SimulatedHdc {
    fn dispatch(&self, plan: &ProcessPlan) -> std::result::Result<Receipt, DispatchFailure> {
        #[cfg(test)]
        DISPATCH_ATTEMPTS.fetch_add(1, Ordering::Relaxed);
        let arguments: Vec<&str> = plan.arguments.iter().map(String::as_str).collect();
        let answer = match arguments.as_slice() {
            ["-v"] => "Ver: 3.2.0f\n".to_owned(),
            ["checkserver"] => {
                "Client version:Ver: 3.2.0f, server version:Ver: 3.2.0f\n".to_owned()
            }
            ["list", "targets", "-v"] => format!("{KEY}\t\tUSB\tConnected\tlocalhost\n"),
            ["-t", key, "shell", "param", "get", "const.product.name"] if *key == KEY => {
                "OpenHarmony Reference Device\n".into()
            }
            ["-t", key, "shell", "param", "get", "const.ohos.fullname"] if *key == KEY => {
                "OpenHarmony-4.1-release\n".into()
            }
            _ => {
                return Err(DispatchFailure::Refused(
                    "unscripted action in Runtime soak fixture".into(),
                ));
            }
        };
        if answer.len() > plan.capture_bytes {
            return Err(DispatchFailure::Refused(
                "fixture capture bound exceeded".into(),
            ));
        }
        self.0.fetch_add(1, Ordering::Relaxed);
        Ok(Receipt {
            exit_status: 0,
            stdout: answer.into_bytes(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::from_millis(10),
        })
    }
}

struct Owners {
    jobs: JobStore,
    artifacts: ArtifactReadStore,
    sessions: SessionStore,
    targets: TargetStore,
}
impl Owners {
    fn open(root: &Path) -> Result<Self> {
        let directory = HostDirectory::open(root).map_err(error)?;
        for name in [
            "jobs-state",
            "artifacts",
            "session-state",
            "sessions",
            "targets-state",
        ] {
            directory.private_child(name).map_err(error)?;
        }
        Ok(Self {
            jobs: JobStore::open_owner(&root.join("jobs-state")).map_err(error)?,
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).map_err(error)?,
            sessions: SessionStore::open(&root.join("session-state"), &root.join("sessions"))
                .map_err(error)?
                .isolated(
                    root,
                    vec![
                        root.join("jobs-state"),
                        root.join("artifacts"),
                        root.join("targets-state"),
                    ],
                )
                .map_err(error)?,
            targets: TargetStore::open(&root.join("targets-state")).map_err(error)?,
        })
    }
}

/// Every Job's identity and state: all the soak reads from Job history. A page
/// is dropped once these are copied out, so the soak itself does not hold
/// every history row while the owner serves the next page.
fn rows(jobs: &JobStore) -> Result<Vec<(String, String)>> {
    let mut rows = Vec::new();
    let mut params = Map::from_iter([("pageSize".into(), json!(250))]);
    loop {
        let page = jobs.handle_resource("job.list", &params).map_err(error)?;
        for row in page["items"].as_array().ok_or("invalid Job list")? {
            rows.push((
                field(row, "jobId")?.to_owned(),
                field(row, "state")?.to_owned(),
            ));
        }
        match page["nextCursor"].as_str() {
            Some(cursor) => {
                params.insert("cursor".into(), json!(cursor));
            }
            None => return Ok(rows),
        }
    }
}
fn field<'a>(value: &'a Value, name: &str) -> Result<&'a str> {
    value[name]
        .as_str()
        .ok_or_else(|| format!("missing {name}"))
}
fn job_params(id: &str) -> Map<String, Value> {
    Map::from_iter([("jobId".into(), json!(id))])
}
fn terminal(state: &str) -> bool {
    matches!(state, "succeeded" | "cancelled" | "failed" | "interrupted")
}

fn execute_cycle(root: &Path, run_id: &str, cycle: u64, count: u64) -> Result<(u64, u64)> {
    let owners = Arc::new(Owners::open(root)?);
    let fake = Arc::new(SimulatedHdc::default());
    let hdc = HdcComposition {
        targets: &owners.targets,
        dispatch: fake.as_ref(),
        receive_root: None,
        tool_sha256: DIGEST,
        now: runtime_now,
        code_sign_helper: None,
    };
    let claims = StorageClaims::default();
    let probe = SystemStorageProbe;
    let publisher = SessionPublisher {
        sessions: &owners.sessions,
        claims: &claims,
        probe: &probe,
    };
    let home = std::env::var("HOME").map_err(error)?;
    let runner = JobRunner {
        imports: None,
        mutation: None,
        jobs: &owners.jobs,
        artifacts: &owners.artifacts,
        analyzer: None,
        quota: 8 * 1024 * 1024 * 1024,
        home: &home,
        now: runtime_now,
        precise_now: runtime_precise_now,
        sessions: Some(&publisher),
        cancellation: None,
        after_commit: None,
        hdc: Some(&hdc),
        workspace: None,
    };
    let mut socket = socket_cycle::Cycle::start(root, Arc::clone(&owners), Arc::clone(&fake))?;
    let mut recovered = 0;
    for (id, state) in rows(&owners.jobs)? {
        if terminal(&state) {
            continue;
        }
        // This is the Swift fixture's clean preflight restart leg, never a
        // running/unknown intent recovery. The runner also validates the journal.
        if state != "preflight" {
            return Err(format!("unsupported restart state {state}"));
        }
        let result = runner.handle(&job_params(&id)).map_err(error)?;
        if result["state"] != "succeeded" {
            return Err("reopened Job did not succeed".into());
        }
        recovered += 1;
    }
    if count > 0 {
        let observations = TargetObservations::default();
        let relations = || {
            Ok(vec![UsbRelation {
                serial: KEY.into(),
                location: "1".into(),
                attachment_id: 1,
                vendor_id: 0x2207,
                product_id: 0x5000,
            }])
        };
        let observed_at = now()?;
        let clock = || observed_at.clone();
        let sources = Sources {
            dispatch: fake.as_ref(),
            relations: &relations,
            targets: &owners.targets,
            now: &clock,
        };
        let snapshot = observations.snapshot(&sources, None).map_err(error)?;
        let first = snapshot
            .observations
            .first()
            .ok_or("fixture produced no observation")?;
        let adopted = observations
            .adopt(
                &sources,
                &ObservationReference {
                    candidate: first.candidate.connect_key.clone(),
                    observation_id: first.observation_id.clone(),
                    generation: snapshot.generation,
                },
            )
            .map_err(error)?;
        for offset in 0..count {
            let identity = format!("soak-{run_id}-{cycle}-{offset}");
            let request = json!({"documentType":"runtime-operation-request", "schemaVersion":"1.0.0",
                "requestId":identity,"idempotencyKey":identity,
                "target":{"targetId":adopted.target_id,"expectedBindingRevision":adopted.binding_revision},
                "operation":{"id":"observe.device","version":1}});
            let submitted = socket.request(
                "job.submit",
                Map::from_iter([(
                    "requestJson".into(),
                    Value::String(serde_json::to_string(&request).map_err(error)?),
                )]),
            )?;
            let params = job_params(field(&submitted, "jobId")?);
            if offset.is_multiple_of(11) {
                socket.request("job.cancel", params.clone())?;
                if socket.request("job.status", params.clone())?["state"] != "cancelled" {
                    return Err("never-started cancellation did not persist".into());
                }
            } else if !offset.is_multiple_of(7)
                && socket.request("job.run", params.clone())?["state"] != "succeeded"
            {
                return Err("observation did not succeed".into());
            }
        }
    }
    socket.finish()?;
    Ok((recovered, fake.0.load(Ordering::Relaxed)))
}

#[derive(Default)]
struct Usage {
    files: u64,
    bytes: u64,
    journals: u64,
    journal_bytes: u64,
}
fn inspect_tree(root: &Path, verify_journals: bool) -> Result<Usage> {
    let mut usage = Usage::default();
    for entry in fs::read_dir(root).map_err(error)? {
        let entry = entry.map_err(error)?;
        if entry.file_name().as_encoded_bytes().starts_with(b".") {
            continue;
        }
        let kind = entry.file_type().map_err(error)?;
        if kind.is_dir() {
            let nested = inspect_tree(&entry.path(), verify_journals)?;
            usage.files += nested.files;
            usage.bytes += nested.bytes;
            usage.journals += nested.journals;
            usage.journal_bytes += nested.journal_bytes;
        } else if kind.is_file() {
            let bytes = entry.metadata().map_err(error)?.len();
            usage.files += 1;
            usage.bytes += bytes;
            if entry.file_name() == "journal.jsonl" {
                usage.journals += 1;
                usage.journal_bytes += bytes;
                if verify_journals {
                    let facts = inspect_journal(root).map_err(error)?;
                    if facts.has_torn_tail
                        || !facts.outstanding_intents.is_empty()
                        || !facts.unknown_outcomes.is_empty()
                    {
                        return Err("journal has torn tail or unresolved intent".into());
                    }
                }
            }
        } else {
            return Err("non-regular entry in isolated soak state".into());
        }
    }
    Ok(usage)
}

/// Quiescent verification. Does not repair journals or run jobs; Job listing
/// may create the production owner's pagination snapshots.
pub fn verify_state(root: &Path) -> Result<u64> {
    let root = canonical_root(root)?;
    let directory = HostDirectory::open(&root).map_err(error)?;
    require_marker(&directory)?;
    let _lock = directory
        .lock_document(".runtime-soak.lock")
        .map_err(error)?;
    require_marker(&directory)?;
    verify_owned_state(&root)
}
fn verify_owned_state(root: &Path) -> Result<u64> {
    // Inspect before opening any writer: a torn preflight tail must not be
    // silently repaired into a successful soak result.
    inspect_tree(root, true)?;
    // These directories must already exist. Verification never initializes a
    // missing owner or creates a Job database in a caller-selected directory.
    let directory = HostDirectory::open(root).map_err(error)?;
    directory
        .child("jobs-state")
        .map_err(error)?
        .child("cli-job-snapshots")
        .map_err(error)?;
    let jobs = JobStore::open(&root.join("jobs-state")).map_err(error)?;
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).map_err(error)?;
    let reader = JobResultReader {
        jobs: &jobs,
        artifacts: &artifacts,
    };
    if !reader.outstanding_cleanup_debt().map_err(error)?.is_empty() {
        return Err("outstanding cleanup debt".into());
    }
    let all_rows = rows(&jobs)?;
    if all_rows.is_empty() {
        return Err("empty state is not a soak workload".into());
    }
    let mut verified = 0;
    for (id, state) in all_rows {
        if !matches!(state.as_str(), "succeeded" | "cancelled") {
            return Err(format!("unexpected final state {state}"));
        }
        let journal = inspect_journal(&root.join("jobs-state/jobs").join(&id)).map_err(error)?;
        if !journal.finalized || journal.current_state.as_deref() != Some(state.as_str()) {
            return Err("terminal Job and journal disagree".into());
        }
        if state == "succeeded" {
            let evidence = reader
                .handle("job.evidence", &job_params(&id))
                .map_err(error)?;
            let artifacts = evidence["artifacts"]
                .as_array()
                .ok_or("missing evidence artifacts")?;
            if evidence["status"] != "verified"
                || artifacts.is_empty()
                || artifacts
                    .iter()
                    .any(|artifact| artifact["bytesVerified"] != true)
            {
                return Err("successful Job has no verified Artifact evidence".into());
            }
            verified += 1;
        }
    }
    Ok(verified)
}

struct CycleSample {
    cycle: u64,
    elapsed: Duration,
    activity: (u64, u64),
    baseline: Option<SelfResources>,
    verified: Option<u64>,
}
fn collect(
    config: &Configuration,
    root: &Path,
    run_id: &str,
    sample: CycleSample,
) -> Result<Metrics> {
    let CycleSample {
        cycle,
        elapsed,
        activity,
        baseline,
        verified,
    } = sample;
    let owners = Owners::open(root)?;
    let reader = JobResultReader {
        jobs: &owners.jobs,
        artifacts: &owners.artifacts,
    };
    let mut states = BTreeMap::new();
    for (_, state) in rows(&owners.jobs)? {
        *states.entry(state).or_insert(0) += 1;
    }
    let active = states
        .iter()
        .filter(|(state, _)| !terminal(state))
        .map(|(_, count)| count)
        .sum();
    let total: u64 = states.values().sum();
    let usage = inspect_tree(root, false)?;
    let artifacts = inspect_tree(&root.join("artifacts"), false)?;
    let resources = self_resources().map_err(error)?;
    let baseline = baseline.unwrap_or(resources);
    Ok(Metrics {
        schema_version: "arkdeck-runtime-soak/v1".into(),
        run_id: run_id.into(),
        phase: if verified.is_some() {
            "completed"
        } else {
            "running"
        }
        .into(),
        cycle,
        generated_at_utc: now()?,
        elapsed_seconds: elapsed.as_secs(),
        configured_duration_seconds: config.duration_seconds,
        jobs_per_cycle: config.jobs_per_cycle,
        recovered_this_cycle: activity.0,
        fake_provider_commands_this_cycle: activity.1,
        fake_provider_child_process_count: 0,
        process_id: std::process::id(),
        open_file_descriptor_count: resources.open_file_descriptor_count,
        max_resident_set_bytes: resources.max_resident_set_bytes,
        baseline_open_file_descriptor_count: baseline.open_file_descriptor_count,
        open_file_descriptor_growth: resources.open_file_descriptor_count as i128
            - baseline.open_file_descriptor_count as i128,
        baseline_resident_set_bytes: baseline.max_resident_set_bytes,
        resident_set_growth_bytes: resources.max_resident_set_bytes as i128
            - baseline.max_resident_set_bytes as i128,
        job_states: states,
        active_job_count: active,
        terminal_job_count: total - active,
        state_file_count: usage.files,
        state_byte_count: usage.bytes,
        journal_count: usage.journals,
        journal_byte_count: usage.journal_bytes,
        artifact_file_count: artifacts.files,
        artifact_byte_count: artifacts.bytes,
        outstanding_cleanup_debt_count: reader.outstanding_cleanup_debt().map_err(error)?.len()
            as u64,
        verified_artifact_evidence_job_count: verified,
        workload: None,
        working_set_bytes: None,
        private_bytes: None,
        transport_exchanges_this_cycle: None,
    })
}
fn canonical_root(path: &Path) -> Result<PathBuf> {
    if !path.is_absolute() {
        return Err("state root must be absolute".into());
    }
    let root = path.canonicalize().map_err(error)?;
    // Accept normal macOS /tmp aliases while all store APIs receive the
    // resolved path. A caller-owned final symlink is never a state root.
    if fs::symlink_metadata(path)
        .map_err(error)?
        .file_type()
        .is_symlink()
    {
        return Err("soak state root must not be a symlink".into());
    }
    if let Some(home) = std::env::var_os("HOME")
        && root.starts_with(PathBuf::from(home).join("Library/Application Support/ArkDeck"))
    {
        return Err("soak must not use installed Runtime state".into());
    }
    Ok(root)
}
fn require_marker(directory: &HostDirectory) -> Result<()> {
    if directory.read("runtime-soak-owner", 1024).map_err(error)? != OWNER_MARKER {
        return Err("state belongs to another owner".into());
    }
    Ok(())
}

pub fn run(configuration: &Configuration) -> Result<Metrics> {
    configuration.validate()?;
    if let Some(home) = std::env::var_os("HOME")
        && configuration
            .state_directory
            .starts_with(PathBuf::from(home).join("Library/Application Support/ArkDeck"))
    {
        return Err("soak must not use installed Runtime state".into());
    }
    if !configuration.state_directory.exists() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&configuration.state_directory)
            .map_err(error)?;
    }
    let root = canonical_root(&configuration.state_directory)?;
    socket_cycle::validate_root(&root)?;
    let directory = HostDirectory::open(&root).map_err(error)?;
    let _lock = directory
        .lock_document(".runtime-soak.lock")
        .map_err(error)?;
    let marker = OWNER_MARKER;
    match directory.read("runtime-soak-owner", 1024) {
        Ok(bytes) if bytes == marker => {}
        Ok(_) => return Err("state belongs to another owner".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            if fs::read_dir(&root)
                .map_err(error)?
                .collect::<std::io::Result<Vec<_>>>()
                .map_err(error)?
                .iter()
                .any(|e| e.file_name() != ".runtime-soak.lock")
            {
                return Err("soak requires an empty root or its own marked state".into());
            }
            directory
                .publish_document("runtime-soak-owner", marker, 1024)
                .map_err(error)?;
        }
        Err(e) => return Err(error(e)),
    }
    let run_id: String = arkdeck_platform::random_bytes::<16>()
        .map_err(error)?
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let clock = SystemClock(ContinuousInstant::now().map_err(error)?);
    run_workload(configuration, &root, &run_id, &clock)
}

fn run_workload(
    configuration: &Configuration,
    root: &Path,
    run_id: &str,
    clock: &dyn SoakClock,
) -> Result<Metrics> {
    let budget = Duration::from_secs(configuration.duration_seconds);
    let mut cycle = 0;
    let mut baseline = None;
    while clock.elapsed()? < budget {
        cycle += 1;
        inspect_tree(root, true)?;
        let activity = execute_cycle(root, run_id, cycle, configuration.jobs_per_cycle)?;
        let metrics = collect(
            configuration,
            root,
            run_id,
            CycleSample {
                cycle,
                elapsed: clock.elapsed()?,
                activity,
                baseline,
                verified: None,
            },
        )?;
        persist(root, &metrics)?;
        resource_gate(&metrics)?;
        baseline = Some(SelfResources {
            max_resident_set_bytes: metrics.baseline_resident_set_bytes,
            open_file_descriptor_count: metrics.baseline_open_file_descriptor_count,
        });
        // The Swift fixture prints its resident set per cycle; without it a
        // failed resource gate reports one number at the end and no series, so
        // a reader cannot tell a leak from a peak that grows with the store.
        // The growth, descriptors and state size travel with it for the same
        // reason: they are what the gate compares and what it scales against.
        println!(
            "Rust soak cycle={cycle} jobs={} active={} recovered={} rssBytes={} \
rssGrowthBytes={} fdCount={} stateBytes={} simulatedProvider=true",
            metrics.terminal_job_count + metrics.active_job_count,
            metrics.active_job_count,
            metrics.recovered_this_cycle,
            metrics.max_resident_set_bytes,
            metrics.resident_set_growth_bytes,
            metrics.open_file_descriptor_count,
            metrics.state_byte_count
        );
        pause(
            clock,
            budget,
            Duration::from_secs(configuration.restart_interval_seconds),
        )?;
    }
    inspect_tree(root, true)?;
    let drained = execute_cycle(root, run_id, cycle + 1, 0)?;
    let verified = verify_owned_state(root)?;
    let metrics = collect(
        configuration,
        root,
        run_id,
        CycleSample {
            cycle,
            elapsed: clock.elapsed()?,
            activity: drained,
            baseline,
            verified: Some(verified),
        },
    )?;
    resource_gate(&metrics)?;
    persist(root, &metrics)?;
    Ok(metrics)
}

#[cfg(test)]
mod recovery_refusal_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn complete_outstanding_intent_and_unknown_outcome_refuse_without_dispatch_or_repair() {
        let fixture = fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/journal-writer/unknown.jsonl"),
        )
        .unwrap();
        let outstanding: Vec<u8> = fixture
            .split_inclusive(|b| *b == b'\n')
            .take(4)
            .flatten()
            .copied()
            .collect();
        for (label, bytes) in [("intent", outstanding), ("unknown", fixture)] {
            let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
            let root = PathBuf::from("/private/tmp").join(format!("soak-refuse-{nonce:x}"));
            fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
            let directory = HostDirectory::open(&root).unwrap();
            directory
                .publish_document("runtime-soak-owner", OWNER_MARKER, 1024)
                .unwrap();
            directory.private_child("fixture-journal").unwrap();
            let journal_root = root.join("fixture-journal");
            let journal = journal_root.join("journal.jsonl");
            fs::write(&journal, &bytes).unwrap();
            fs::set_permissions(&journal, fs::Permissions::from_mode(0o600)).unwrap();
            let facts = inspect_journal(&journal_root).unwrap();
            assert!(!facts.has_torn_tail);
            if label == "intent" {
                assert!(!facts.outstanding_intents.is_empty());
            } else {
                assert!(!facts.unknown_outcomes.is_empty());
            }
            let before = DISPATCH_ATTEMPTS.load(Ordering::Relaxed);
            let failure = run(&Configuration {
                state_directory: root.clone(),
                duration_seconds: 1,
                restart_interval_seconds: 1,
                jobs_per_cycle: 10,
            })
            .unwrap_err();
            assert!(failure.contains("unresolved intent"));
            assert_eq!(DISPATCH_ATTEMPTS.load(Ordering::Relaxed), before);
            assert_eq!(fs::read(&journal).unwrap(), bytes);
            assert!(!root.join("jobs-state").exists());
            assert!(!root.join("runtime-soak-metrics.json").exists());
            fs::remove_dir_all(root).unwrap();
        }
    }
}
