//! The Runtime soak: bounded cycles over the production serving path, gated
//! on the process's own resource growth.
//!
//! * macOS (`owners`): the simulated-provider workload through production Rust
//!   owners. No child, shell, live device transport, capability administration
//!   or unknown-outcome replay. Each owner generation serves the existing
//!   control protocol on a private Unix socket.
//! * Windows (`pipe_cycle`): the same serving generations over a private named
//!   pipe, each drained before the next binds, with the production client's
//!   identity checks on every connection. The Job workload stays macOS-only
//!   until the Job store reaches Windows (G01); the Windows run records that it
//!   is the transport workload, and never counts Jobs it did not run.
//!
//! Both gate the same growth bounds (T1) on each platform's own counters; see
//! `arkdeck_platform::SelfResources` for the Windows counterparts.
#![cfg(any(target_os = "macos", windows))]

use arkdeck_platform::HostDirectory;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[cfg(target_os = "macos")]
mod owners;
#[cfg(target_os = "macos")]
pub use owners::{artifact_bench, recovery, run, verify_state};
#[cfg(windows)]
mod pipe_cycle;
#[cfg(windows)]
pub use pipe_cycle::{SIGNER_VARIABLE, WORKLOAD, run};

pub type Result<T> = std::result::Result<T, String>;
fn error(value: impl std::fmt::Debug) -> String {
    format!("{value:?}")
}
/// Growth of the resident-set high-water mark (macOS `ru_maxrss`, Windows
/// peak working set) over the first cycle's reading.
const MAX_RSS_GROWTH: i128 = 32 * 1024 * 1024;
/// Growth of open descriptors (macOS) or open handles (Windows) over the
/// first cycle's reading.
const MAX_FD_GROWTH: i128 = 16;

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
/// On Windows `maxResidentSetBytes` is the peak working set and the
/// descriptor fields count open handles; the optional fields below appear
/// only in a Windows document, so a macOS document is unchanged.
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
    /// Which workload produced this document when it is not the Job
    /// workload: `windows-pipe-transport/v1`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workload: Option<String>,
    /// Windows: the live working set at this reading.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_set_bytes: Option<u64>,
    /// Windows: private (committed, unshared) bytes at this reading.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub private_bytes: Option<u64>,
    /// Windows: authenticated client exchanges this cycle completed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transport_exchanges_this_cycle: Option<u64>,
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

/// Injectable continuous elapsed clock. UTC is used only for audit fields;
/// this fixture records no active-work latency or throughput sample.
trait SoakClock {
    fn elapsed(&self) -> Result<Duration>;
    fn sleep(&self, duration: Duration);
}
struct SystemClock(arkdeck_platform::ContinuousInstant);
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
