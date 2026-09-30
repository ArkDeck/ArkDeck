//! The Windows soak: serving generations of the production control path
//! (`arkdeck_agentd::serve_control`) over a private named pipe, each one
//! drained before the next binds the same name, with the production client
//! (`arkdeck_client::Client`) connecting to every one as the CLI connects to
//! an installed daemon.
//!
//! What it exercises is the transport and its resources, not the Job owners:
//! those are macOS-only until the Job store reaches Windows (G01), so the
//! composed host has no Job owner and every exchange is a verified health
//! handshake followed by a `job.list` the host refuses (`rejected`). Its
//! document says so (`workload`), counts the exchanges it made, and reports no
//! Job it did not run.
//!
//! The client pins the pipe server by image path and Authenticode signer; the
//! server is this very executable, so the soak runs only as a copy signed with
//! a certificate this host trusts (`rust/scripts/windows-dev-identity.ps1
//! sign`), whose pin it reads from [`SIGNER_VARIABLE`]. There is no switch that
//! skips the check, exactly as there is none for the CLI.
use crate::{
    Configuration, Metrics, Result, SoakClock, SystemClock, error, pause, persist, resource_gate,
};
use arkdeck_client::{Client, ClientError};
use arkdeck_contract::{DeviceObservationsResult, WireError};
use arkdeck_control::{Control, HdcStatus, HostServices};
use arkdeck_platform::{
    ContinuousInstant, HostDirectory, Latch, LocalEndpoint, LocalListener, SelfResources,
    ServerIdentity, self_memory, self_resources,
};
use serde_json::{Map, json};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The `workload` a Windows soak document names.
pub const WORKLOAD: &str = "windows-pipe-transport/v1";
/// The SHA-256 pin of the certificate this executable is signed with.
pub const SIGNER_VARIABLE: &str = "ARKDECK_SOAK_SIGNER_SHA256";
/// Distinct from the macOS marker: neither workload continues the other's state.
const OWNER_MARKER: &[u8] = b"arkdeck-rust-soak/windows-pipe-transport/v1";

/// No owner is composed: health, and a refusal for everything else.
struct Host;
impl HostServices for Host {
    fn observed_at(&self) -> String {
        utc_now()
    }
    fn hdc_status(&self, deep: bool) -> HdcStatus {
        HdcStatus::unavailable(deep, "simulatedProvider")
    }
    fn observations(&self) -> std::result::Result<DeviceObservationsResult, WireError> {
        Err(WireError {
            code: "operationUnavailable".into(),
            message: "the Windows transport soak composes no observation owner".into(),
            details: None,
        })
    }
}

/// The existing UTC seconds spelling, for audit fields only.
fn utc_now() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let days = (seconds / 86_400) as i64 + 719_468;
    let era = days / 146_097;
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = month_index + if month_index < 10 { 3 } else { -9 };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    let time = seconds % 86_400;
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        time / 3600,
        time / 60 % 60,
        time % 60
    )
}

fn valid_pin(pin: &str) -> bool {
    pin.len() == 64 && pin.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}
fn signer_pin() -> Result<String> {
    let pin = std::env::var(SIGNER_VARIABLE).unwrap_or_default();
    if !valid_pin(&pin) {
        return Err(format!(
            "{SIGNER_VARIABLE} must name the lowercase SHA-256 pin of the certificate this \
             executable is signed with; the soak's client verifies its pipe server as the CLI \
             verifies an installed daemon (sign a copy with rust/scripts/windows-dev-identity.ps1)"
        ));
    }
    Ok(pin)
}

/// Sets the generation's stop latch however the client side ends, so the
/// serving loop never outlives its clients.
struct StopOnExit(Arc<Latch>);
impl Drop for StopOnExit {
    fn drop(&mut self) {
        self.0.set();
    }
}

/// One serving generation on the run's pipe name, served on this thread (a
/// Windows listener stays on the thread that bound it, as in the daemon)
/// while a client thread makes the cycle's exchanges and then stops it.
/// Binding the name with `FILE_FLAG_FIRST_PIPE_INSTANCE` is itself the check
/// that the previous generation released every instance.
fn execute_cycle(
    endpoint: &LocalEndpoint,
    identity: &ServerIdentity,
    run_id: &str,
    cycle: u64,
    count: u64,
) -> Result<u64> {
    let control = Arc::new(Control::new(Host).map_err(error)?);
    let listener = LocalListener::bind(endpoint).map_err(error)?;
    let stop = Arc::new(Latch::new().map_err(error)?);
    let clients = {
        let stop = StopOnExit(Arc::clone(&stop));
        let (endpoint, identity) = (endpoint.clone(), identity.clone());
        let prefix = format!("soak-{run_id}-{cycle}");
        std::thread::spawn(move || -> Result<u64> {
            let _stop = stop;
            let mut exchanges = 0;
            for offset in 0..count {
                // One connection per business request, health verified on it
                // first, no replay of a lost reply: the CLI's exchange.
                let mut client =
                    Client::connect_bounded(&endpoint, &identity, Duration::from_secs(5))
                        .map_err(error)?;
                let params = Map::from_iter([("pageSize".to_owned(), json!(50))]);
                match client.request(&format!("{prefix}-{offset}"), "job.list", Some(params)) {
                    Err(ClientError::Remote(refusal)) if refusal.code == "rejected" => {
                        exchanges += 1;
                    }
                    other => {
                        return Err(format!(
                            "job.list on a host without a Job owner answered {other:?}"
                        ));
                    }
                }
            }
            Ok(exchanges)
        })
    };
    let served = arkdeck_agentd::serve_control(
        listener,
        control,
        |listener| listener.accept_until_latch(&stop),
        Duration::from_secs(5),
        Duration::from_secs(5),
    );
    // The client side ends first in every case: it stops the generation.
    let exchanges = clients
        .join()
        .map_err(|_| "soak client thread panicked".to_owned())??;
    if !served.map_err(error)?.complete {
        return Err("soak control generation did not drain before its deadline".into());
    }
    Ok(exchanges)
}

#[derive(Default)]
struct Usage {
    files: u64,
    bytes: u64,
}
fn inspect_tree(root: &Path) -> Result<Usage> {
    let mut usage = Usage::default();
    for entry in fs::read_dir(root).map_err(error)? {
        let entry = entry.map_err(error)?;
        if entry.file_name().as_encoded_bytes().starts_with(b".") {
            continue;
        }
        let kind = entry.file_type().map_err(error)?;
        if kind.is_dir() {
            let nested = inspect_tree(&entry.path())?;
            usage.files += nested.files;
            usage.bytes += nested.bytes;
        } else if kind.is_file() {
            usage.files += 1;
            usage.bytes += entry.metadata().map_err(error)?.len();
        } else {
            return Err("non-regular entry in isolated soak state".into());
        }
    }
    Ok(usage)
}

struct Sample {
    cycle: u64,
    elapsed: Duration,
    exchanges: u64,
    baseline: Option<SelfResources>,
    completed: bool,
}
fn collect(config: &Configuration, root: &Path, run_id: &str, sample: Sample) -> Result<Metrics> {
    let usage = inspect_tree(root)?;
    let memory = self_memory().map_err(error)?;
    let resources = self_resources().map_err(error)?;
    let baseline = sample.baseline.unwrap_or(resources);
    Ok(Metrics {
        schema_version: "arkdeck-runtime-soak/v1".into(),
        run_id: run_id.into(),
        phase: if sample.completed {
            "completed"
        } else {
            "running"
        }
        .into(),
        cycle: sample.cycle,
        generated_at_utc: utc_now(),
        elapsed_seconds: sample.elapsed.as_secs(),
        configured_duration_seconds: config.duration_seconds,
        jobs_per_cycle: config.jobs_per_cycle,
        recovered_this_cycle: 0,
        fake_provider_commands_this_cycle: 0,
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
        job_states: BTreeMap::new(),
        active_job_count: 0,
        terminal_job_count: 0,
        state_file_count: usage.files,
        state_byte_count: usage.bytes,
        journal_count: 0,
        journal_byte_count: 0,
        artifact_file_count: 0,
        artifact_byte_count: 0,
        outstanding_cleanup_debt_count: 0,
        verified_artifact_evidence_job_count: None,
        workload: Some(WORKLOAD.into()),
        working_set_bytes: Some(memory.working_set_bytes),
        private_bytes: Some(memory.private_bytes),
        transport_exchanges_this_cycle: Some(sample.exchanges),
    })
}

/// The state root, created owner-only when absent. An existing directory is
/// opened as it is (a foreign one is refused below without being changed).
fn open_root(configuration: &Configuration) -> Result<(PathBuf, HostDirectory)> {
    let path = &configuration.state_directory;
    if let Some(installed) = arkdeck_platform::arkdeck_application_support_root()
        && path.starts_with(&installed)
    {
        return Err("soak must not use installed Runtime state".into());
    }
    if !path.exists() {
        HostDirectory::open_or_create_private(path).map_err(error)?;
    }
    if fs::symlink_metadata(path)
        .map_err(error)?
        .file_type()
        .is_symlink()
    {
        return Err("soak state root must not be a symlink".into());
    }
    let root = path.canonicalize().map_err(error)?;
    let directory = HostDirectory::open(&root).map_err(error)?;
    Ok((root, directory))
}

pub fn run(configuration: &Configuration) -> Result<Metrics> {
    configuration.validate()?;
    // Before anything is created: without its identity the client could not
    // verify a single connection.
    let identity = ServerIdentity {
        executable: std::env::current_exe().map_err(error)?,
        authenticode_sha256: Some(signer_pin()?),
        package_family: None,
    };
    let (root, directory) = open_root(configuration)?;
    let _lock = directory
        .lock_document(".runtime-soak.lock")
        .map_err(error)?;
    match directory.read("runtime-soak-owner", 1024) {
        Ok(bytes) if bytes == OWNER_MARKER => {}
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
                .publish_document("runtime-soak-owner", OWNER_MARKER, 1024)
                .map_err(error)?;
        }
        Err(e) => return Err(error(e)),
    }
    let run_id: String = arkdeck_platform::random_bytes::<16>()
        .map_err(error)?
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let endpoint = LocalEndpoint::new(format!(r"\\.\pipe\arkdeck-soak-{run_id}"));
    let clock = SystemClock(ContinuousInstant::now().map_err(error)?);
    run_workload(configuration, &root, &run_id, &endpoint, &identity, &clock)
}

fn run_workload(
    configuration: &Configuration,
    root: &Path,
    run_id: &str,
    endpoint: &LocalEndpoint,
    identity: &ServerIdentity,
    clock: &dyn SoakClock,
) -> Result<Metrics> {
    let budget = Duration::from_secs(configuration.duration_seconds);
    let mut cycle = 0;
    let mut baseline = None;
    let mut exchanges = 0;
    while clock.elapsed()? < budget {
        cycle += 1;
        exchanges = execute_cycle(
            endpoint,
            identity,
            run_id,
            cycle,
            configuration.jobs_per_cycle,
        )?;
        let metrics = collect(
            configuration,
            root,
            run_id,
            Sample {
                cycle,
                elapsed: clock.elapsed()?,
                exchanges,
                baseline,
                completed: false,
            },
        )?;
        persist(root, &metrics)?;
        resource_gate(&metrics)?;
        baseline = Some(SelfResources {
            max_resident_set_bytes: metrics.baseline_resident_set_bytes,
            open_file_descriptor_count: metrics.baseline_open_file_descriptor_count,
        });
        println!(
            "Rust soak cycle={cycle} workload={WORKLOAD} exchanges={exchanges} \
peakWorkingSetBytes={} peakWorkingSetGrowthBytes={} workingSetBytes={} privateBytes={} \
handleCount={} handleGrowth={} stateBytes={}",
            metrics.max_resident_set_bytes,
            metrics.resident_set_growth_bytes,
            metrics.working_set_bytes.unwrap_or_default(),
            metrics.private_bytes.unwrap_or_default(),
            metrics.open_file_descriptor_count,
            metrics.open_file_descriptor_growth,
            metrics.state_byte_count
        );
        pause(
            clock,
            budget,
            Duration::from_secs(configuration.restart_interval_seconds),
        )?;
    }
    let metrics = collect(
        configuration,
        root,
        run_id,
        Sample {
            cycle,
            elapsed: clock.elapsed()?,
            exchanges,
            baseline,
            completed: true,
        },
    )?;
    resource_gate(&metrics)?;
    persist(root, &metrics)?;
    Ok(metrics)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_audit_clock_keeps_the_utc_seconds_spelling() {
        let now = utc_now();
        assert_eq!(now.len(), 20, "{now}");
        assert!(now.ends_with('Z') && now.as_bytes()[10] == b'T', "{now}");
    }

    #[test]
    fn a_missing_or_malformed_signer_pin_refuses_before_any_state() {
        for pin in ["", "abc", &"A".repeat(64), &"g".repeat(64), &"a".repeat(65)] {
            assert!(!valid_pin(pin), "{pin}");
        }
        assert!(valid_pin(&"0a".repeat(32)));
        // The variable is read, never written, by this test binary.
        if std::env::var_os(SIGNER_VARIABLE).is_none() {
            let root = std::env::temp_dir().join(format!(
                "adksoak-unsigned-{}",
                u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
            ));
            let failure = run(&Configuration {
                state_directory: root.clone(),
                duration_seconds: 1,
                restart_interval_seconds: 1,
                jobs_per_cycle: 1,
            })
            .unwrap_err();
            assert!(failure.contains(SIGNER_VARIABLE), "{failure}");
            assert!(!root.exists(), "nothing is created without the identity");
        }
    }
}
