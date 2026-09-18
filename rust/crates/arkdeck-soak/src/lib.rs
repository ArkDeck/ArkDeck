//! Bounded simulation over production Rust owners. No child, shell, live
//! device transport, capability administration or unknown-outcome replay.
//! This initial slice exercises owner lifecycle, not socket IPC.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    ArtifactReadStore, HdcComposition, JobAdmitter, JobCanceller, JobPlanner, JobResultReader,
    JobRunner, JobStore, ObservationReference, SessionPublisher, SessionStore, Sources,
    StorageClaims, SystemStorageProbe, TargetObservations, TargetStore, inspect_journal,
    runtime_now, runtime_precise_now,
};
use arkdeck_platform::{ContinuousInstant, HostDirectory, SelfResources, self_resources};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt, UsbRelation};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

pub type Result<T> = std::result::Result<T, String>;
fn error(value: impl std::fmt::Debug) -> String {
    format!("{value:?}")
}
fn now() -> Result<String> {
    runtime_now().ok_or_else(|| "Runtime clock unavailable".into())
}
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const DIGEST: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const MAX_RSS_GROWTH: i128 = 32 * 1024 * 1024;
const MAX_FD_GROWTH: i128 = 16;
const OWNER_MARKER: &[u8] = b"arkdeck-rust-soak/simulated-only/v1";
#[cfg(test)]
static DISPATCH_ATTEMPTS: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug)]
pub struct Configuration {
    pub state_directory: PathBuf,
    pub duration_seconds: u64,
    pub restart_interval_seconds: u64,
    pub jobs_per_cycle: u64,
}
impl Configuration {
    pub fn parse(arguments: impl IntoIterator<Item = String>) -> Result<Self> {
        let mut args = arguments.into_iter();
        let mut state_directory = None;
        let (mut duration_seconds, mut restart_interval_seconds, mut jobs_per_cycle) =
            (86400, 300, 10);
        while let Some(flag) = args.next() {
            let value = args
                .next()
                .ok_or_else(|| format!("missing value for {flag}"))?;
            if flag == "--state-directory" {
                state_directory = Some(PathBuf::from(value));
                continue;
            }
            let integer: u64 = value
                .parse()
                .map_err(|_| format!("{flag} requires a positive integer"))?;
            if integer == 0 {
                return Err(format!("{flag} requires a positive integer"));
            }
            match flag.as_str() {
                "--duration-seconds" => duration_seconds = integer,
                "--restart-interval-seconds" => restart_interval_seconds = integer,
                "--jobs-per-cycle" => jobs_per_cycle = integer,
                _ => return Err(format!("unknown option {flag}")),
            }
        }
        let result = Self {
            state_directory: state_directory.ok_or("--state-directory is required")?,
            duration_seconds,
            restart_interval_seconds,
            jobs_per_cycle,
        };
        result.validate()?;
        Ok(result)
    }
    fn validate(&self) -> Result<()> {
        if !self.state_directory.is_absolute()
            || self.duration_seconds == 0
            || self.restart_interval_seconds == 0
            || self.jobs_per_cycle == 0
        {
            return Err(
                "an absolute state directory and positive workload values are required".into(),
            );
        }
        Ok(())
    }
}

/// Exact Swift arkdeck-runtime-soak/v1 field spelling. RSS is a lifetime
/// high-water mark; the benchmark harness separately samples live daemon RSS.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Metrics {
    pub schema_version: String,
    #[serde(rename = "runID")]
    pub run_id: String,
    pub phase: String,
    pub cycle: u64,
    #[serde(rename = "generatedAtUTC")]
    pub generated_at_utc: String,
    pub elapsed_seconds: u64,
    pub configured_duration_seconds: u64,
    pub jobs_per_cycle: u64,
    pub recovered_this_cycle: u64,
    pub fake_provider_commands_this_cycle: u64,
    pub fake_provider_child_process_count: u64,
    #[serde(rename = "processID")]
    pub process_id: u32,
    pub open_file_descriptor_count: u64,
    pub max_resident_set_bytes: u64,
    pub baseline_open_file_descriptor_count: u64,
    pub open_file_descriptor_growth: i128,
    pub baseline_resident_set_bytes: u64,
    pub resident_set_growth_bytes: i128,
    pub job_states: BTreeMap<String, u64>,
    pub active_job_count: u64,
    pub terminal_job_count: u64,
    pub state_file_count: u64,
    pub state_byte_count: u64,
    pub journal_count: u64,
    pub journal_byte_count: u64,
    pub artifact_file_count: u64,
    pub artifact_byte_count: u64,
    pub outstanding_cleanup_debt_count: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verified_artifact_evidence_job_count: Option<u64>,
}

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

fn rows(jobs: &JobStore) -> Result<Vec<Value>> {
    let mut rows = Vec::new();
    let mut params = Map::from_iter([("pageSize".into(), json!(250))]);
    loop {
        let page = jobs.handle_resource("job.list", &params).map_err(error)?;
        rows.extend(
            page["items"]
                .as_array()
                .ok_or("invalid Job list")?
                .iter()
                .cloned(),
        );
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
    let owners = Owners::open(root)?;
    let fake = SimulatedHdc::default();
    let hdc = HdcComposition {
        targets: &owners.targets,
        dispatch: &fake,
        tool_sha256: DIGEST,
        now: runtime_now,
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
    };
    let mut recovered = 0;
    for row in rows(&owners.jobs)? {
        let state = field(&row, "state")?;
        if terminal(state) {
            continue;
        }
        // This is the Swift fixture's clean preflight restart leg, never a
        // running/unknown intent recovery. The runner also validates the journal.
        if state != "preflight" {
            return Err(format!("unsupported restart state {state}"));
        }
        let result = runner
            .handle(&job_params(field(&row, "jobId")?))
            .map_err(error)?;
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
            dispatch: &fake,
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
        let admitter = JobAdmitter {
            planner: JobPlanner {
                artifacts: Some(&owners.artifacts),
                analyzer: None,
                state_root: root,
                hdc: Some(&hdc),
            },
            jobs: &owners.jobs,
            now: runtime_now,
            authority: None,
        };
        let canceller = JobCanceller {
            jobs: &owners.jobs,
            now: runtime_now,
            sessions: Some(&publisher),
        };
        for offset in 0..count {
            let identity = format!("soak-{run_id}-{cycle}-{offset}");
            let request = json!({"documentType":"runtime-operation-request", "schemaVersion":"1.0.0",
                "requestId":identity,"idempotencyKey":identity,
                "target":{"targetId":adopted.target_id,"expectedBindingRevision":adopted.binding_revision},
                "operation":{"id":"observe.device","version":1}});
            let submitted = admitter
                .submit(&serde_json::to_vec(&request).map_err(error)?)
                .map_err(error)?;
            let params = job_params(field(&submitted, "jobId")?);
            if offset.is_multiple_of(11) {
                canceller.handle(&params).map_err(error)?;
                if owners
                    .jobs
                    .handle_resource("job.status", &params)
                    .map_err(error)?["state"]
                    != "cancelled"
                {
                    return Err("never-started cancellation did not persist".into());
                }
            } else if !offset.is_multiple_of(7)
                && runner.handle(&params).map_err(error)?["state"] != "succeeded"
            {
                return Err("observation did not succeed".into());
            }
        }
    }
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
    for row in all_rows {
        let state = field(&row, "state")?;
        if !matches!(state, "succeeded" | "cancelled") {
            return Err(format!("unexpected final state {state}"));
        }
        let id = field(&row, "jobId")?;
        let journal = inspect_journal(&root.join("jobs-state/jobs").join(id)).map_err(error)?;
        if !journal.finalized || journal.current_state.as_deref() != Some(state) {
            return Err("terminal Job and journal disagree".into());
        }
        if state == "succeeded" {
            let evidence = reader
                .handle("job.evidence", &job_params(field(&row, "jobId")?))
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
    for row in rows(&owners.jobs)? {
        *states.entry(field(&row, "state")?.to_owned()).or_insert(0) += 1;
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
    })
}
fn persist(root: &Path, metrics: &Metrics) -> Result<()> {
    HostDirectory::open(root)
        .map_err(error)?
        .publish_document(
            "runtime-soak-metrics.json",
            &serde_json::to_vec_pretty(metrics).map_err(error)?,
            1024 * 1024,
        )
        .map_err(error)
}
fn resource_gate(metrics: &Metrics) -> Result<()> {
    if metrics.resident_set_growth_bytes > MAX_RSS_GROWTH
        || metrics.open_file_descriptor_growth > MAX_FD_GROWTH
    {
        Err(format!(
            "soak resource growth exceeded: RSS {} / {}, descriptors {} / {}",
            metrics.resident_set_growth_bytes,
            MAX_RSS_GROWTH,
            metrics.open_file_descriptor_growth,
            MAX_FD_GROWTH
        ))
    } else {
        Ok(())
    }
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

/// Injectable continuous elapsed clock. UTC is used only for audit fields;
/// this fixture records no active-work latency or throughput sample.
trait SoakClock {
    fn elapsed(&self) -> Result<Duration>;
    fn sleep(&self, duration: Duration);
}
struct SystemClock(ContinuousInstant);
impl SoakClock for SystemClock {
    fn elapsed(&self) -> Result<Duration> {
        self.0.elapsed().map_err(error)
    }
    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}
fn pause(clock: &dyn SoakClock, budget: Duration, interval: Duration) -> Result<()> {
    let resume_at = clock
        .elapsed()?
        .checked_add(interval)
        .ok_or("interval is too large")?
        .min(budget);
    loop {
        let remaining = resume_at.saturating_sub(clock.elapsed()?);
        if remaining.is_zero() {
            return Ok(());
        }
        // std::thread::sleep has no cross-platform suspend guarantee. Re-read
        // the explicit continuous clock in bounded slices, including on wake.
        clock.sleep(remaining.min(Duration::from_secs(1)));
    }
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
        println!(
            "Rust soak cycle={cycle} jobs={} active={} recovered={} simulatedProvider=true",
            metrics.terminal_job_count + metrics.active_job_count,
            metrics.active_job_count,
            metrics.recovered_this_cycle
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
mod clock_tests {
    use super::*;
    use std::cell::Cell;
    struct Suspended {
        elapsed: Cell<Duration>,
        sleeps: Cell<usize>,
    }
    impl SoakClock for Suspended {
        fn elapsed(&self) -> Result<Duration> {
            Ok(self.elapsed.get())
        }
        fn sleep(&self, _: Duration) {
            self.sleeps.set(self.sleeps.get() + 1);
            self.elapsed.set(Duration::from_secs(3600)); // simulated system sleep
        }
    }
    #[test]
    fn suspend_jump_expires_overall_budget_without_remaining_awake_wait() {
        let clock = Suspended {
            elapsed: Cell::new(Duration::ZERO),
            sleeps: Cell::new(0),
        };
        pause(&clock, Duration::from_secs(60), Duration::from_secs(30)).unwrap();
        assert_eq!(clock.sleeps.get(), 1);
        assert!(clock.elapsed().unwrap() >= Duration::from_secs(60));
    }
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
            let root = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("soak-refuse-{nonce:x}"));
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
