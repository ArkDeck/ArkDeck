//! The publication-only retry interlock over committed hostOnly analyzer
//! sources and actual task-private workspace build/test admission and runs.
//! The workspace tool port is counted and creates only fixture outputs; no
//! external child, installed Runtime, HDC or device is launched.
#![cfg(any(target_os = "macos", windows))]

mod support;
#[cfg(windows)]
#[path = "support/workspace_publication_retry.rs"]
mod workspace;

use arkdeck_contract::WireError;
use arkdeck_hoststore::{
    AdmissionVerdict, ArtifactReadStore, CapabilityStore, ImportUploadStore, JobReconciler,
    JobRecord, JobStore, JournalWriter, OperationRequest, SessionPublisher, SessionStore,
    StorageClaims,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Barrier;
use support::{OracleProbe, fixed_now};

const JOBS: [&str; 2] = [
    "job-255bf1eecfad2c543fbc2682a6ad565c",
    "job-694e2d635c9fbaa2c85da51afdac73fa",
];

struct Owners {
    root: PathBuf,
    jobs: Option<JobStore>,
    artifacts: ArtifactReadStore,
    imports: ImportUploadStore,
    capabilities: CapabilityStore,
    sessions: SessionStore,
    claims: StorageClaims,
    probe: OracleProbe,
    imported: Value,
}

impl Owners {
    fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("arkdeck-terminal-publication-{nonce:032x}"));
        #[cfg(windows)]
        let root = {
            arkdeck_platform::create_private_directory(&root).unwrap();
            arkdeck_platform::host_resolved_path(&root).unwrap()
        };
        #[cfg(target_os = "macos")]
        {
            fs::create_dir(&root).unwrap();
            support::chmod(&root, 0o700);
        }
        for name in ["state", "artifacts", "session-owner", "Sessions"] {
            arkdeck_platform::HostDirectory::open_or_create_private(&root.join(name)).unwrap();
        }
        let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
        let imports = ImportUploadStore::open(&root.join("artifacts")).unwrap();
        let imported = support::debug_hap::import_package(
            &imports,
            &artifacts,
            "terminal-publication",
            "TGT-ISOLATED-IMPORT",
            1,
            &"a".repeat(64),
            &fixed_now().unwrap(),
        );
        let owners = Self {
            jobs: Some(JobStore::open_owner(&root.join("state")).unwrap()),
            capabilities: CapabilityStore::open(&root.join("state/capabilities")).unwrap(),
            sessions: SessionStore::open(&root.join("session-owner"), &root.join("Sessions"))
                .unwrap(),
            artifacts,
            imports,
            claims: StorageClaims::default(),
            probe: OracleProbe::new(&json!({"availableBytes": 8_u64 * 1024 * 1024 * 1024})),
            imported,
            root,
        };
        for job in JOBS {
            owners.retain(job);
        }
        owners
    }

    fn retain(&self, job: &str) {
        let corpus = support::fixture("job-run-analyzer")
            .join("store/jobs")
            .join(job);
        let mut value: Value =
            serde_json::from_slice(&fs::read(corpus.join("job-record.json")).unwrap()).unwrap();
        assert_eq!(value["state"], "succeeded");
        assert_eq!(value["actualEffect"], "hostOnly");
        value["sessionPublicationRecord"] = json!({
            "sessionID": format!("session-{job}"), "catalogDigest": value["catalogDigest"],
            "policyGeneration": "0", "root": {"path": "", "device": "0", "inode": "0", "volumeIdentity": ""},
            "relativeSessionPath": "", "claims": [], "phase": "awaitingStorage",
            "failure": {"code": "sourceIntegrityFailed", "certainty": "confirmed", "detail": "isolated retry fixture"},
        });
        let fingerprint = OperationRequest::decode(
            &serde_json::to_vec(&value["originalSubmissionRequest"]).unwrap(),
        )
        .unwrap()
        .fingerprint();
        let record = JobRecord::decode(&serde_json::to_vec(&value).unwrap()).unwrap();
        assert_eq!(
            self.jobs().admit(&record, &fingerprint).unwrap(),
            AdmissionVerdict::Admitted
        );
        self.jobs().persist(&record, &fixed_now().unwrap()).unwrap();
        let mut journal = JournalWriter::open(&self.directory(job), true).unwrap();
        let bytes = fs::read(corpus.join("journal.jsonl")).unwrap();
        for line in bytes
            .split(|byte| *byte == b'\n')
            .filter(|line| !line.is_empty())
        {
            let event: Value = serde_json::from_slice(line).unwrap();
            if event["kind"] != "finalized" {
                journal.append(&event).unwrap();
            }
        }
        assert!(!journal.facts().finalized);
    }

    fn directory(&self, job: &str) -> PathBuf {
        self.root.join("state/jobs").join(job)
    }

    fn jobs(&self) -> &JobStore {
        self.jobs.as_ref().unwrap()
    }

    fn reconcile(&self, job: &str) -> Result<Value, WireError> {
        let publisher = SessionPublisher {
            sessions: &self.sessions,
            claims: &self.claims,
            probe: &self.probe,
        };
        // No provider runner or transport port exists in this fixture.
        JobReconciler {
            jobs: self.jobs(),
            artifacts: &self.artifacts,
            imports: Some(&self.imports),
            now: fixed_now,
            sessions: Some(&publisher),
            hdc: None,
            capabilities: Some(&self.capabilities),
            runner: None,
        }
        .handle(json!({"jobId": job}).as_object().unwrap())
    }

    fn inspection(&self) -> Result<Value, WireError> {
        self.imports.lifecycle_resource(
            &self.artifacts,
            self.jobs(),
            "artifact.import.inspection",
            json!({"importId": self.imported["importId"]})
                .as_object()
                .unwrap(),
            &fixed_now().unwrap(),
        )
    }

    fn record(&self, job: &str) -> Value {
        serde_json::from_slice(&fs::read(self.directory(job).join("job-record.json")).unwrap())
            .unwrap()
    }

    fn reopen(&mut self) {
        drop(self.jobs.take());
        self.jobs = Some(JobStore::open_owner(&self.root.join("state")).unwrap());
    }
}

impl Drop for Owners {
    fn drop(&mut self) {
        drop(self.jobs.take());
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn tree(path: &Path) -> BTreeMap<PathBuf, Option<Vec<u8>>> {
    fn visit(root: &Path, path: &Path, found: &mut BTreeMap<PathBuf, Option<Vec<u8>>>) {
        for entry in fs::read_dir(path).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            let key = path.strip_prefix(root).unwrap().to_owned();
            if entry.file_type().unwrap().is_dir() {
                found.insert(key, None);
                visit(root, &path, found);
            } else {
                found.insert(key, Some(fs::read(path).unwrap()));
            }
        }
    }
    let mut found = BTreeMap::new();
    visit(path, path, &mut found);
    found
}

#[test]
fn the_whole_census_clears_only_after_both_original_sources_are_finalized() {
    let owners = Owners::new();
    let capabilities = tree(&owners.root.join("state/capabilities"));
    assert_eq!(owners.inspection().unwrap_err().code, "recordUnreadable");
    for (index, job) in JOBS.into_iter().enumerate() {
        let before = owners.record(job);
        let journal = fs::read(owners.directory(job).join("journal.jsonl")).unwrap();
        let status = owners.reconcile(job).unwrap();
        assert_eq!(status["state"], "succeeded");
        assert_eq!(
            status["sessionPublication"]["state"], "published",
            "{status}"
        );
        let after = owners.record(job);
        for key in [
            "request",
            "originalSubmissionRequest",
            "admissionEvidence",
            "outcomeUnknown",
            "timeline",
            "state",
        ] {
            assert_eq!(after[key], before[key], "{key}");
        }
        let bytes = fs::read(owners.directory(job).join("journal.jsonl")).unwrap();
        assert!(bytes.starts_with(&journal));
        let appended: Value = serde_json::from_slice(&bytes[journal.len()..]).unwrap();
        assert_eq!(appended["kind"], "finalized");
        assert_eq!(appended["payload"]["terminalStatus"], "succeeded");
        if index == 0 {
            assert_eq!(owners.inspection().unwrap_err().code, "recordUnreadable");
        }
    }
    assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
    assert_eq!(tree(&owners.root.join("state/capabilities")), capabilities);
}

#[test]
fn concurrent_duplicate_and_reopened_reads_keep_the_one_receipt() {
    let mut owners = Owners::new();
    let capabilities = tree(&owners.root.join("state/capabilities"));
    let barrier = Barrier::new(2);
    let (first, second) = std::thread::scope(|scope| {
        let run = || {
            barrier.wait();
            owners.reconcile(JOBS[0]).unwrap()
        };
        let first = scope.spawn(run);
        let second = scope.spawn(run);
        (first.join().unwrap(), second.join().unwrap())
    });
    assert_eq!(first, second);
    assert_eq!(first["sessionPublication"]["state"], "published", "{first}");
    let source = tree(&owners.directory(JOBS[0]));
    let sessions = tree(&owners.root.join("Sessions"));
    assert_eq!(owners.reconcile(JOBS[0]).unwrap(), first);
    assert_eq!(tree(&owners.directory(JOBS[0])), source);
    assert_eq!(tree(&owners.root.join("Sessions")), sessions);
    owners.reopen();
    assert_eq!(owners.reconcile(JOBS[0]).unwrap(), first);
    assert_eq!(tree(&owners.directory(JOBS[0])), source);
    assert_eq!(tree(&owners.root.join("Sessions")), sessions);
    assert_eq!(tree(&owners.root.join("state/capabilities")), capabilities);
}

#[test]
fn changed_owners_proposals_and_torn_or_foreign_journals_are_never_repaired() {
    for scenario in ["diskDrift", "proposal", "torn", "foreign"] {
        let owners = Owners::new();
        let directory = owners.directory(JOBS[0]);
        match scenario {
            "diskDrift" => {
                let mut record = owners.record(JOBS[0]);
                record["finishedAtUTC"] = json!("2026-09-14T00:00:01Z");
                fs::write(
                    directory.join("job-record.json"),
                    serde_json::to_vec(&record).unwrap(),
                )
                .unwrap();
            }
            "proposal" => fs::write(
                directory.join("session-manifest.proposal.json"),
                b"retained unverified proposal",
            )
            .unwrap(),
            "torn" => {
                fs::OpenOptions::new()
                    .append(true)
                    .open(directory.join("journal.jsonl"))
                    .unwrap()
                    .write_all(b"{\"torn\":")
                    .unwrap();
            }
            "foreign" => {
                let bytes = fs::read_to_string(directory.join("journal.jsonl"))
                    .unwrap()
                    .replace(JOBS[0], "job-foreign-owner");
                fs::write(directory.join("journal.jsonl"), bytes).unwrap();
            }
            _ => unreachable!(),
        }
        let source = tree(&directory);
        let sessions = tree(&owners.root.join("Sessions"));
        let capabilities = tree(&owners.root.join("state/capabilities"));
        let answer = owners.reconcile(JOBS[0]);
        if scenario == "proposal" {
            assert_eq!(answer.unwrap()["sessionPublication"]["state"], "failed");
        } else {
            assert!(answer.is_err(), "{scenario}: {answer:?}");
        }
        assert_eq!(tree(&directory), source, "{scenario}");
        assert_eq!(tree(&owners.root.join("Sessions")), sessions, "{scenario}");
        assert_eq!(
            tree(&owners.root.join("state/capabilities")),
            capabilities,
            "{scenario}"
        );
        assert_eq!(owners.inspection().unwrap_err().code, "recordUnreadable");
    }
}

#[cfg(windows)]
#[test]
fn both_consumed_workspace_jobs_must_publish_before_the_census_clears() {
    let owners = workspace::Owners::new();
    let capabilities = tree(&owners.root.join("state/capabilities"));
    assert_eq!(owners.inspection().unwrap_err().code, "recordUnreadable");
    for (index, job) in owners.job_ids.iter().enumerate() {
        let before = owners.record(job);
        let journal = fs::read(owners.directory(job).join("journal.jsonl")).unwrap();
        let original: Vec<Value> = journal
            .split(|byte| *byte == b'\n')
            .filter(|line| !line.is_empty())
            .map(|line| serde_json::from_slice(line).unwrap())
            .collect();
        assert_eq!(original.len(), 7);
        assert!(original.iter().all(|event| matches!(
            event["kind"].as_str(),
            Some("jobCreated" | "stateTransition" | "stepIntent" | "stepOutcome")
        )));
        assert_eq!(before["admissionEvidence"]["kind"], "runtimeCapability");
        let status = owners.reconcile(job).unwrap();
        assert_eq!(status["state"], "succeeded", "{status}");
        assert_eq!(
            status["sessionPublication"]["state"], "published",
            "{status}"
        );
        let mut after = owners.record(job);
        after["sessionPublicationRecord"] = before["sessionPublicationRecord"].clone();
        assert_eq!(after, before, "only the publication marker may change");
        let bytes = fs::read(owners.directory(job).join("journal.jsonl")).unwrap();
        assert!(bytes.starts_with(&journal));
        let appended: Value = serde_json::from_slice(&bytes[journal.len()..]).unwrap();
        assert_eq!(appended["kind"], "finalized");
        assert_eq!(appended["payload"]["terminalStatus"], "succeeded");
        if index == 0 {
            assert_eq!(owners.inspection().unwrap_err().code, "recordUnreadable");
        }
    }
    assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
    assert_eq!(owners.calls.load(std::sync::atomic::Ordering::SeqCst), 2);
    assert_eq!(tree(&owners.root.join("state/capabilities")), capabilities);
}

#[cfg(windows)]
#[test]
fn consumed_workspace_retry_keeps_one_receipt_across_duplicates_and_restart() {
    let mut owners = workspace::Owners::new();
    let job = owners.job_ids[0].clone();
    let capabilities = tree(&owners.root.join("state/capabilities"));
    let barrier = Barrier::new(2);
    let (first, second) = std::thread::scope(|scope| {
        let run = || {
            barrier.wait();
            owners.reconcile(&job).unwrap()
        };
        let first = scope.spawn(run);
        let second = scope.spawn(run);
        (first.join().unwrap(), second.join().unwrap())
    });
    assert_eq!(first, second);
    assert_eq!(first["sessionPublication"]["state"], "published", "{first}");
    let source = tree(&owners.directory(&job));
    let sessions = tree(&owners.root.join("Sessions"));
    assert_eq!(owners.reconcile(&job).unwrap(), first);
    assert_eq!(tree(&owners.directory(&job)), source);
    assert_eq!(tree(&owners.root.join("Sessions")), sessions);
    owners.reopen();
    assert_eq!(owners.reconcile(&job).unwrap(), first);
    assert_eq!(tree(&owners.directory(&job)), source);
    assert_eq!(tree(&owners.root.join("Sessions")), sessions);
    assert_eq!(owners.calls.load(std::sync::atomic::Ordering::SeqCst), 2);
    assert_eq!(tree(&owners.root.join("state/capabilities")), capabilities);
}

#[cfg(windows)]
#[test]
fn consumed_workspace_without_original_tool_context_stays_unpublished() {
    let owners = workspace::Owners::new();
    let job = &owners.job_ids[0];
    let before = owners.record(job);
    let journal = fs::read(owners.directory(job).join("journal.jsonl")).unwrap();
    let capabilities = tree(&owners.root.join("state/capabilities"));
    let answer = owners.reconcile_with_context(job, false).unwrap();
    assert_eq!(answer["state"], "succeeded");
    assert_eq!(answer["sessionPublication"]["state"], "failed", "{answer}");
    assert_eq!(
        answer["sessionPublication"]["reasonCode"], "sourceIntegrityFailed",
        "{answer}"
    );
    let mut after = owners.record(job);
    after["sessionPublicationRecord"] = before["sessionPublicationRecord"].clone();
    assert_eq!(after, before);
    assert_eq!(
        fs::read(owners.directory(job).join("journal.jsonl")).unwrap(),
        journal
    );
    assert_eq!(owners.inspection().unwrap_err().code, "recordUnreadable");
    assert_eq!(owners.calls.load(std::sync::atomic::Ordering::SeqCst), 2);
    assert_eq!(tree(&owners.root.join("state/capabilities")), capabilities);
}

#[cfg(windows)]
#[test]
fn actual_patch_runner_publishes_its_consumed_pre_write_plan_after_revision_changes() {
    let owners = workspace::Owners::new();
    for job in &owners.job_ids {
        assert_eq!(
            owners.reconcile(job).unwrap()["sessionPublication"]["state"],
            "published"
        );
    }
    assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
    let (job, status, plan) = owners.run_patch();
    assert_eq!(status["state"], "succeeded", "{status}");
    assert_eq!(status["outcomeUnknown"], false);
    assert_eq!(
        status["sessionPublication"]["state"], "published",
        "{status}"
    );
    assert_eq!(owners.calls.load(std::sync::atomic::Ordering::SeqCst), 3);
    assert_eq!(
        fs::read(owners.isolated_index()).unwrap(),
        workspace::PATCHED_INDEX
    );

    let source = owners.patch_source();
    let terminal = owners.record(&job);
    assert_eq!(terminal["request"], source["request"]);
    assert_eq!(terminal["admissionEvidence"], source["admissionEvidence"]);
    assert_eq!(
        terminal["materializedPlanDigest"],
        plan["materializedPlanDigest"]
    );
    assert_eq!(
        source["materializedPlanDigest"],
        plan["materializedPlanDigest"]
    );
    let (code, reason) = owners.plan_job(&job).unwrap_err();
    assert_eq!(code, "invalidInput");
    assert!(reason.contains("workspace.revisionConflict:"), "{reason}");

    let manifest = owners.manifest(&job);
    let admission = &source["admissionEvidence"];
    let correlation = &admission["runtimeCapabilityCorrelation"];
    assert_eq!(
        manifest["runtimeAuthority"],
        json!({
            "kind": "runtimeCapability", "reference": admission["reference"],
            "admittedAtUtc": admission["admittedAtUTC"], "validUntilUtc": admission["validUntilUTC"],
            "consumptionFingerprintSha256": admission["consumptionFingerprintSHA256"],
            "reservationId": correlation["reservationID"], "useOrdinal": correlation["useOrdinal"],
            "planDigest": correlation["planDigestSHA256"], "stepSetDigest": correlation["stepSetDigestSHA256"],
            "targetBindingDigest": correlation["targetBindingDigestSHA256"], "artifactDigest": correlation["artifactSHA256"],
        })
    );
    assert_eq!(
        manifest["runtimeAuthority"]["artifactDigest"],
        arkdeck_contract::sha256_hex(workspace::PATCH)
    );
    assert_eq!(manifest["toolchain"]["kind"], "hostTool");
    assert_eq!(
        manifest["toolchain"]["reportedVersion"],
        env!("CARGO_PKG_VERSION")
    );
    assert_eq!(manifest["originalTarget"]["kind"], "host");
    assert_eq!(manifest["bindingHistory"], json!([]));
    assert_eq!(manifest["steps"].as_array().unwrap().len(), 1);
    assert_eq!(manifest["steps"][0]["effect"], "deviceMutation");
    assert_eq!(manifest["steps"][0]["bindingRequirement"], "none");
    assert!(manifest["compensations"].as_array().unwrap().is_empty());

    let result = owners.result(&job);
    let artifact = result["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["name"] == "applied-patch.json")
        .unwrap()["artifactId"]
        .as_str()
        .unwrap();
    let report: Value = serde_json::from_slice(
        &fs::read(owners.root.join("artifacts").join(&job).join(artifact)).unwrap(),
    )
    .unwrap();
    assert_eq!(
        report["previousWorkspaceRevision"],
        source["request"]["inputs"]["expectedWorkspaceRevision"]
    );
    assert_ne!(
        report["workspaceRevision"],
        report["previousWorkspaceRevision"]
    );
    assert_eq!(report["exitStatus"], "0");
    let journal = fs::read_to_string(owners.directory(&job).join("journal.jsonl")).unwrap();
    let events: Vec<Value> = journal
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(
        events
            .iter()
            .filter(|event| event["kind"] == "stepIntent")
            .count(),
        1
    );
    assert_eq!(
        events
            .iter()
            .filter(|event| event["kind"] == "stepOutcome")
            .count(),
        1
    );
    assert_eq!(
        events
            .iter()
            .filter(|event| event["kind"] == "finalized")
            .count(),
        1
    );
    assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
}
