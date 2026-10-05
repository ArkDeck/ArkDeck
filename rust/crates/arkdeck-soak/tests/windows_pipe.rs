//! The Windows owner soak as an executable. The unsigned refusal runs
//! everywhere; the signed run needs the certificate this host trusts
//! (`rust/scripts/windows-dev-identity.ps1`), so it is ignored unless asked
//! for with `--ignored` and `ARKDECK_DEV_SIGNER_THUMBPRINT` set.
#![cfg(windows)]
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Root(PathBuf);
impl Root {
    fn new(label: &str) -> Self {
        let suffix: String = arkdeck_platform::random_bytes::<12>()
            .unwrap()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        Self(
            arkdeck_platform::host_resolved_path(&std::env::temp_dir())
                .unwrap()
                .join(format!("adksoak-{label}-{suffix}")),
        )
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn soak(executable: &Path, state: &Path, pin: Option<&str>) -> std::process::Output {
    let mut command = Command::new(executable);
    command
        .args(["--state-directory"])
        .arg(state)
        .args([
            "--duration-seconds",
            "3",
            "--restart-interval-seconds",
            "1",
            "--jobs-per-cycle",
            "8",
        ])
        .env_remove(arkdeck_soak::SIGNER_VARIABLE);
    if let Some(pin) = pin {
        command.env(arkdeck_soak::SIGNER_VARIABLE, pin);
    }
    command.output().unwrap()
}

/// PowerShell 7, as `check-readonly.py` finds it: on PATH, or the App
/// Execution Alias of its Store installation.
fn pwsh() -> PathBuf {
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .map(|directory| directory.join("pwsh.exe"))
        .find(|candidate| candidate.is_file())
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("LOCALAPPDATA").expect("LOCALAPPDATA"))
                .join(r"Microsoft\WindowsApps\pwsh.exe")
        })
}

#[test]
fn an_unsigned_run_is_refused_before_any_state_is_created() {
    let root = Root::new("unsigned");
    let output = soak(Path::new(env!("CARGO_BIN_EXE_arkdeck-soak")), &root.0, None);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains(arkdeck_soak::SIGNER_VARIABLE), "{stderr}");
    assert!(!root.0.exists());
    for flag in [
        "--measure-journal",
        "--seed-recovery",
        "--seed-artifact-bench",
    ] {
        let refused = Command::new(env!("CARGO_BIN_EXE_arkdeck-soak"))
            .arg(flag)
            .arg(&root.0)
            .output()
            .unwrap();
        assert!(!refused.status.success(), "{flag}");
        assert!(!String::from_utf8_lossy(&refused.stderr).contains("G01"));
    }
    assert!(!root.0.exists());
}

#[test]
#[ignore = "needs the host-trusted development signer: ARKDECK_DEV_SIGNER_THUMBPRINT"]
fn a_signed_run_drains_every_generation_within_the_growth_bounds() {
    let thumbprint = std::env::var("ARKDECK_DEV_SIGNER_THUMBPRINT")
        .expect("ARKDECK_DEV_SIGNER_THUMBPRINT names the development certificate");
    let bin = Root::new("bin");
    std::fs::create_dir(&bin.0).unwrap();
    let signed = bin.0.join("arkdeck-soak.exe");
    std::fs::copy(env!("CARGO_BIN_EXE_arkdeck-soak"), &signed).unwrap();
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/windows-dev-identity.ps1");
    let signing = Command::new(pwsh())
        .args(["-NoProfile", "-NonInteractive", "-File"])
        .arg(&script)
        .args(["sign", "-Thumbprint", &thumbprint, "-Path"])
        .arg(&signed)
        .output()
        .unwrap();
    assert!(
        signing.status.success(),
        "{}",
        String::from_utf8_lossy(&signing.stderr)
    );
    let pin = serde_json::from_slice::<Value>(&signing.stdout).unwrap()["pin"]
        .as_str()
        .unwrap()
        .to_owned();

    let root = Root::new("signed");
    arkdeck_platform::HostDirectory::open_or_create_private(&root.0).unwrap();
    let output = soak(&signed, &root.0, Some(&pin));
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "{stdout}{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        stdout.contains("workload=windows-owner-workload/v1"),
        "{stdout}"
    );
    let metrics: Value =
        serde_json::from_slice(&std::fs::read(root.0.join("runtime-soak-metrics.json")).unwrap())
            .unwrap();
    assert_eq!(metrics["schemaVersion"], "arkdeck-runtime-soak/v1");
    assert_eq!(metrics["phase"], "completed");
    assert_eq!(metrics["workload"], arkdeck_soak::WORKLOAD);
    assert!(metrics["transportExchangesThisCycle"].is_null());
    assert!(metrics["cycle"].as_u64().unwrap() >= 1, "{metrics}");
    assert!(metrics["terminalJobCount"].as_u64().unwrap() >= 8);
    assert_eq!(metrics["activeJobCount"], 0);
    assert!(metrics["jobStates"]["succeeded"].as_u64().unwrap() > 0);
    assert!(metrics["jobStates"]["cancelled"].as_u64().unwrap() > 0);
    assert!(
        metrics["verifiedArtifactEvidenceJobCount"]
            .as_u64()
            .unwrap()
            > 0
    );
    assert!(metrics["journalCount"].as_u64().unwrap() > 0);
    assert!(metrics["artifactByteCount"].as_u64().unwrap() > 0);
    assert_eq!(metrics["outstandingCleanupDebtCount"], 0);
    assert_eq!(metrics["fakeProviderChildProcessCount"], 0);
    assert_eq!(
        arkdeck_soak::verify_state(&root.0).unwrap(),
        metrics["verifiedArtifactEvidenceJobCount"]
            .as_u64()
            .unwrap()
    );
    assert!(metrics["residentSetGrowthBytes"].as_i64().unwrap() <= 32 * 1024 * 1024);
    assert!(metrics["openFileDescriptorGrowth"].as_i64().unwrap() <= 16);
    assert!(metrics["privateBytes"].as_u64().unwrap() > 0);

    // A second run continues its own marked state; a foreign root is refused.
    let again = soak(&signed, &root.0, Some(&pin));
    assert!(
        again.status.success(),
        "{}",
        String::from_utf8_lossy(&again.stderr)
    );
    let continued: Value =
        serde_json::from_slice(&std::fs::read(root.0.join("runtime-soak-metrics.json")).unwrap())
            .unwrap();
    assert!(
        continued["terminalJobCount"].as_u64().unwrap()
            > metrics["terminalJobCount"].as_u64().unwrap()
    );
    let foreign = Root::new("foreign");
    std::fs::create_dir(&foreign.0).unwrap();
    std::fs::write(foreign.0.join("unrelated"), b"retain").unwrap();
    let refused = soak(&signed, &foreign.0, Some(&pin));
    assert!(!refused.status.success());
    assert_eq!(
        std::fs::read(foreign.0.join("unrelated")).unwrap(),
        b"retain"
    );
    assert!(!foreign.0.join("runtime-soak-owner").exists());

    // Unknown intent is still refused before any new owner dispatch or repair.
    // The isolated fixture journal and completed metrics must remain exact.
    let directory = arkdeck_platform::HostDirectory::open(&root.0).unwrap();
    let journal = directory.private_child("unknown-fixture").unwrap();
    let bytes = std::fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/journal-writer/unknown.jsonl"),
    )
    .unwrap();
    journal
        .publish_document("journal.jsonl", &bytes, 1024 * 1024)
        .unwrap();
    let metrics_before = std::fs::read(root.0.join("runtime-soak-metrics.json")).unwrap();
    let refused = soak(&signed, &root.0, Some(&pin));
    assert!(!refused.status.success());
    assert!(String::from_utf8_lossy(&refused.stderr).contains("unresolved intent"));
    assert_eq!(journal.read("journal.jsonl", 1024 * 1024).unwrap(), bytes);
    assert_eq!(
        std::fs::read(root.0.join("runtime-soak-metrics.json")).unwrap(),
        metrics_before
    );
}

#[test]
fn windows_recovery_seed_uses_the_production_job_and_journal_owners() {
    for workload in ["journal", "history"] {
        let root = Root::new(workload);
        arkdeck_platform::HostDirectory::open_or_create_private(&root.0).unwrap();
        let seeded = Command::new(env!("CARGO_BIN_EXE_arkdeck-soak"))
            .args(["--seed-recovery", workload, "20"])
            .arg(&root.0)
            .output()
            .unwrap();
        assert!(
            seeded.status.success(),
            "{}",
            String::from_utf8_lossy(&seeded.stderr)
        );
        let manifest: Value = serde_json::from_slice(&seeded.stdout).unwrap();
        assert_eq!(manifest["providerDispatchCount"], 0);
        assert_eq!(
            manifest["jobCount"],
            if workload == "journal" { 1 } else { 20 }
        );
        let jobs = arkdeck_hoststore::JobStore::open_owner(&root.0.join("jobs-state")).unwrap();
        let recovery =
            arkdeck_hoststore::recover_active_jobs(&jobs, None, arkdeck_hoststore::runtime_now)
                .unwrap();
        assert!(recovery.quarantined.is_empty());
        assert!(recovery.refused.is_empty());
        let record = jobs.read_snapshot("job-recovery-00000").unwrap();
        assert_eq!(
            record.state,
            if workload == "journal" {
                "preflight"
            } else {
                "succeeded"
            }
        );
        if workload == "journal" {
            assert_eq!(record.timeline, ["recovered: journal clean"]);
            assert_eq!(recovery.statuses.len(), 1);
            let facts = arkdeck_hoststore::inspect_journal(
                &root.0.join("jobs-state/jobs/job-recovery-00000"),
            )
            .unwrap();
            assert_eq!(facts.event_count, 20);
            assert!(!facts.has_torn_tail);
            assert!(facts.outstanding_intents.is_empty());
        } else {
            assert!(record.timeline.is_empty());
            assert!(recovery.statuses.is_empty());
        }
        let repeat = Command::new(env!("CARGO_BIN_EXE_arkdeck-soak"))
            .args(["--seed-recovery", workload, "20"])
            .arg(&root.0)
            .output()
            .unwrap();
        assert!(!repeat.status.success());
        assert!(String::from_utf8_lossy(&repeat.stderr).contains("empty root"));
    }
}
