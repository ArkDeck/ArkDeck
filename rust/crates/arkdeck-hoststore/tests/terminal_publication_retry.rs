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
    AdmissionVerdict, AnalyzerProfile, ArtifactReadStore, CapabilityStore, ImportUploadStore,
    JobAdmitter, JobCanceller, JobPlanner, JobReconciler, JobRecord, JobStore, JournalWriter,
    OperationRequest, SessionPublisher, SessionStore, StorageClaims,
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
        let owners = Self::empty();
        for job in JOBS {
            owners.retain(job);
        }
        owners
    }

    fn empty() -> Self {
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
        Self {
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
        }
    }

    fn retain(&self, job: &str) {
        self.retain_source("job-run-analyzer", job, |_| {});
    }

    fn retain_source(&self, fixture: &str, job: &str, change: impl FnOnce(&mut Value)) {
        let corpus = support::fixture(fixture).join("store/jobs").join(job);
        let mut value: Value =
            serde_json::from_slice(&fs::read(corpus.join("job-record.json")).unwrap()).unwrap();
        assert_eq!(value["state"], "succeeded");
        change(&mut value);
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
        self.lifecycle("inspection", &self.imported)
    }

    fn lifecycle(&self, leaf: &str, imported: &Value) -> Result<Value, WireError> {
        let fields = if leaf == "release" {
            json!({"importId": imported["importId"], "generation": "2"})
        } else {
            json!({"importId": imported["importId"]})
        };
        self.imports.lifecycle_resource(
            &self.artifacts,
            self.jobs(),
            &format!("artifact.import.{leaf}"),
            fields.as_object().unwrap(),
            &fixed_now().unwrap(),
        )
    }

    fn cancelled_import_consumer(&self, publish: bool) -> String {
        // Real local admission and cancellation, without a runner or any
        // analyzer launch. No Session publisher means no finalized event.
        let analyzer = AnalyzerProfile::crash_signature(&std::env::current_exe().unwrap()).unwrap();
        let request = json!({
            "documentType": "runtime-operation-request", "schemaVersion": "1.0.0",
            "requestId": "req-unsettled-import", "idempotencyKey": "idem-unsettled-import",
            "target": {"targetId": "TGT-ISOLATED-IMPORT"},
            "operation": {"id": "analyzer.extract-crash-signature", "version": 1},
            "inputs": {"sourceArtifactRef": self.imported["receipt"]["lease"]}
        });
        let accepted = JobAdmitter {
            authority: None,
            planner: JobPlanner {
                imports: Some(&self.imports),
                artifacts: Some(&self.artifacts),
                analyzer: Some(&analyzer),
                state_root: &self.root,
                hdc: None,
                workspace: None,
            },
            jobs: self.jobs(),
            now: fixed_now,
        }
        .submit(&serde_json::to_vec(&request).unwrap())
        .unwrap();
        let job = accepted["jobId"].as_str().unwrap().to_owned();
        let publisher = SessionPublisher {
            sessions: &self.sessions,
            claims: &self.claims,
            probe: &self.probe,
        };
        JobCanceller {
            jobs: self.jobs(),
            now: fixed_now,
            sessions: publish.then_some(&publisher),
        }
        .handle(json!({"jobId": job}).as_object().unwrap())
        .unwrap();
        assert_eq!(self.record(&job)["state"], "cancelled");
        assert_eq!(self.record(&job)["outcomeUnknown"], false);
        assert!(self.record(&job)["admissionEvidence"].is_object());
        assert_eq!(
            JournalWriter::open(&self.directory(&job), false)
                .unwrap()
                .facts()
                .finalized,
            publish
        );
        job
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
fn unrelated_import_inspection_does_not_require_either_sources_publication() {
    let owners = Owners::new();
    let capabilities = tree(&owners.root.join("state/capabilities"));
    assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
    for job in JOBS {
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
        assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
    }
    assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
    assert_eq!(tree(&owners.root.join("state/capabilities")), capabilities);
}

#[test]
fn an_unfinalized_terminal_input_stays_pinned_while_an_unrelated_import_can_be_released() {
    let mut owners = Owners::new();
    let job = owners.cancelled_import_consumer(false);
    let unrelated = support::debug_hap::import_package(
        &owners.imports,
        &owners.artifacts,
        "census-unrelated",
        "TGT-ISOLATED-IMPORT",
        1,
        &"a".repeat(64),
        &fixed_now().unwrap(),
    );
    let jobs = tree(&owners.root.join("state/jobs"));
    let capabilities = tree(&owners.root.join("state/capabilities"));
    let input = owners
        .root
        .join("artifacts")
        .join(owners.imported["importId"].as_str().unwrap());
    let input_bytes = tree(&input);
    let record = owners.record(&job);
    for restarted in [false, true] {
        if restarted {
            owners.reopen();
        }
        for leaf in ["inspection", "release"] {
            assert_eq!(
                owners.lifecycle(leaf, &owners.imported).unwrap_err().code,
                "recordUnreadable"
            );
        }
        assert_eq!(
            owners.lifecycle("inspection", &unrelated).unwrap()["references"]["state"],
            "clear"
        );
        assert_eq!(
            owners.lifecycle("release", &unrelated).unwrap()["state"],
            "released"
        );
        assert_eq!(tree(&owners.root.join("state/jobs")), jobs);
        assert_eq!(tree(&owners.root.join("state/capabilities")), capabilities);
        assert_eq!(tree(&input), input_bytes);
        assert_eq!(owners.record(&job), record);
    }
    // The independent retention census also keeps these unfinalized Jobs.
    // A sweep cannot use unrelated Import release to reclaim their sources.
    arkdeck_hoststore::collect_expired_artifacts(
        owners.jobs(),
        &owners.artifacts,
        "2026-11-01T00:00:00Z",
    )
    .unwrap();
    assert_eq!(tree(&input), input_bytes);
    assert_eq!(tree(&owners.root.join("state/jobs")), jobs);
    assert_eq!(tree(&owners.root.join("state/capabilities")), capabilities);
    assert_eq!(owners.inspection().unwrap_err().code, "recordUnreadable");
}

#[test]
fn a_published_marker_without_its_finalized_journal_cannot_release_the_original_input() {
    let owners = Owners::new();
    let job = owners.cancelled_import_consumer(true);
    let directory = owners.directory(&job);
    let record = owners.record(&job);
    assert!(record["sessionPublicationRecord"]["receipt"].is_object());
    let journal = fs::read_to_string(directory.join("journal.jsonl")).unwrap();
    let mut original = Vec::new();
    let mut finalized = 0;
    for line in journal.lines() {
        let event: Value = serde_json::from_str(line).unwrap();
        if event["kind"] == "finalized" {
            finalized += 1;
        } else {
            original.extend_from_slice(line.as_bytes());
            original.push(b'\n');
        }
    }
    assert_eq!(finalized, 1);
    fs::write(directory.join("journal.jsonl"), original).unwrap();
    let jobs = tree(&owners.root.join("state/jobs"));
    let capabilities = tree(&owners.root.join("state/capabilities"));
    let input = tree(
        &owners
            .root
            .join("artifacts")
            .join(owners.imported["importId"].as_str().unwrap()),
    );
    for leaf in ["inspection", "release"] {
        assert_eq!(
            owners.lifecycle(leaf, &owners.imported).unwrap_err().code,
            "recordUnreadable"
        );
    }
    assert_eq!(tree(&owners.root.join("state/jobs")), jobs);
    assert_eq!(tree(&owners.root.join("state/capabilities")), capabilities);
    assert_eq!(
        tree(
            &owners
                .root
                .join("artifacts")
                .join(owners.imported["importId"].as_str().unwrap())
        ),
        input
    );
    assert_eq!(owners.record(&job), record);
}

#[test]
fn an_unfinalized_census_still_refuses_other_source_defects_before_any_release() {
    for scenario in [
        "torn",
        "foreignJob",
        "foreignSession",
        "stateMismatch",
        "outstanding",
        "unknown",
        "missingCreated",
        "missingJournal",
        "missingDirectory",
        "orphan",
        "fingerprint",
    ] {
        let owners = Owners::new();
        let directory = owners.directory(JOBS[0]);
        let journal_path = directory.join("journal.jsonl");
        let mut events: Vec<Value> = fs::read_to_string(&journal_path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        match scenario {
            "torn" => {
                fs::OpenOptions::new()
                    .append(true)
                    .open(&journal_path)
                    .unwrap()
                    .write_all(b"{\"torn\":")
                    .unwrap();
            }
            "foreignJob" => {
                for event in &mut events {
                    event["jobId"] = json!("job-foreign");
                }
            }
            "foreignSession" => {
                for event in &mut events {
                    event["sessionId"] = json!("session-job-foreign");
                }
            }
            "stateMismatch" => {
                events.last_mut().unwrap()["payload"]["to"] = json!("failed");
            }
            "outstanding" => {
                events.retain(|event| event["kind"] != "stepOutcome");
            }
            "unknown" => {
                for event in &mut events {
                    if event["kind"] == "stepOutcome" {
                        event["payload"]["outcomeCertainty"] = json!("outcomeUnknown");
                    }
                }
            }
            "missingCreated" => {
                events.remove(0);
            }
            "missingJournal" => {
                fs::remove_file(&journal_path).unwrap();
            }
            "missingDirectory" => {
                fs::remove_dir_all(&directory).unwrap();
            }
            "orphan" => {
                arkdeck_platform::HostDirectory::open_or_create_private(
                    &owners.root.join("state/jobs/job-orphan"),
                )
                .unwrap();
            }
            "fingerprint" => {
                let mut record = owners.record(JOBS[0]);
                record["request"]["requestId"] = json!("changed-request");
                record["originalSubmissionRequest"]["requestId"] = json!("changed-request");
                owners
                    .jobs()
                    .persist(
                        &JobRecord::decode(&serde_json::to_vec(&record).unwrap()).unwrap(),
                        &fixed_now().unwrap(),
                    )
                    .unwrap();
            }
            _ => unreachable!(),
        }
        if matches!(
            scenario,
            "foreignJob"
                | "foreignSession"
                | "stateMismatch"
                | "outstanding"
                | "unknown"
                | "missingCreated"
        ) {
            let mut bytes = Vec::new();
            for (sequence, event) in events.iter_mut().enumerate() {
                event["sequence"] = json!(sequence);
                bytes.extend(serde_json::to_vec(event).unwrap());
                bytes.push(b'\n');
            }
            fs::write(&journal_path, bytes).unwrap();
        }
        let jobs = tree(&owners.root.join("state/jobs"));
        let capabilities = tree(&owners.root.join("state/capabilities"));
        let imports = tree(&owners.root.join("artifacts"));
        for leaf in ["inspection", "release"] {
            assert_eq!(
                owners.lifecycle(leaf, &owners.imported).unwrap_err().code,
                "recordUnreadable",
                "{scenario}"
            );
        }
        assert_eq!(tree(&owners.root.join("state/jobs")), jobs, "{scenario}");
        assert_eq!(
            tree(&owners.root.join("state/capabilities")),
            capabilities,
            "{scenario}"
        );
        assert_eq!(tree(&owners.root.join("artifacts")), imports, "{scenario}");
    }
}

#[test]
fn historical_input_compatibility_requires_all_32_complete_frozen_schemas() {
    // This frozen packet proves complete Catalog bytes, including the exact
    // three Native step additions. The production exception concerns only
    // input parsing; it is not a plan/admission or capability adapter.
    support::catalog_lineage::Lineage::frozen().unwrap();
    let packet: Value = serde_json::from_slice(include_bytes!(
        "../../../tests/fixtures/catalog-lineage-c6-e4/catalogs.json"
    ))
    .unwrap();
    let old = packet["historicalOperations"].as_array().unwrap();
    let current = packet["currentOperations"].as_array().unwrap();
    let compiled: Vec<Value> =
        serde_json::from_str(arkdeck_contract::CATALOG_CANONICAL_JSON).unwrap();
    let by_reference = |rows: &[Value]| -> BTreeMap<String, Value> {
        rows.iter()
            .map(|row| {
                (
                    format!("{}@{}", row["id"].as_str().unwrap(), row["version"]),
                    row.clone(),
                )
            })
            .collect()
    };
    let old = by_reference(old);
    let current = by_reference(current);
    assert_eq!(old.len(), 32);
    assert_eq!(current.len(), 32);
    assert!(old.keys().eq(current.keys()));
    for (reference, descriptor) in &old {
        assert_eq!(
            descriptor["inputs"], current[reference]["inputs"],
            "{reference}"
        );
    }
    let expected = match arkdeck_contract::CATALOG_DIGEST {
        support::catalog_lineage::OLD => &old,
        support::catalog_lineage::CURRENT => &current,
        _ => panic!("a future Catalog needs an explicit input compatibility review"),
    };
    assert_eq!(&by_reference(&compiled), expected);
}

#[test]
fn a_complete_original_c6_native_source_only_retains_its_declared_inputs() {
    const JOB: &str = "job-186c8faffebe3b9cb8b0150ef9a645b2";
    let owners = Owners::empty();
    let original = fs::read(
        support::fixture("deploy-native-library")
            .join("store/jobs")
            .join(JOB)
            .join("job-record.json"),
    )
    .unwrap();
    assert_eq!(
        arkdeck_contract::sha256_hex(&original),
        "42c059b0a329383c93d00f74751e52856b62736a3db9b28a1314ba13d18444c8"
    );
    owners.retain_source("deploy-native-library", JOB, |_| {});
    let before = owners.record(JOB);
    assert_eq!(before["catalogDigest"], support::catalog_lineage::OLD);
    assert_eq!(
        before["request"]["inputs"],
        serde_json::from_slice::<Value>(&original).unwrap()["request"]["inputs"]
    );
    let jobs = tree(&owners.root.join("state/jobs"));
    let capabilities = tree(&owners.root.join("state/capabilities"));
    assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
    assert_eq!(tree(&owners.root.join("state/jobs")), jobs);
    assert_eq!(tree(&owners.root.join("state/capabilities")), capabilities);
    assert_eq!(owners.record(JOB), before);
}

#[test]
fn an_unfinalized_source_with_unknown_or_malformed_inputs_cannot_clear_any_import() {
    for scenario in [
        "hiddenObject",
        "malformedLease",
        "unknownOperation",
        "unknownDigest",
        "unknownField",
        "wrongEnum",
        "wrongType",
    ] {
        let owners = Owners::empty();
        let (fixture, job) = if matches!(scenario, "wrongEnum" | "wrongType") {
            (
                "deploy-native-library",
                "job-186c8faffebe3b9cb8b0150ef9a645b2",
            )
        } else {
            ("job-run-analyzer", JOBS[0])
        };
        owners.retain_source(fixture, job, |record| {
            let lease = owners.imported["receipt"]["lease"].clone();
            for key in ["request", "originalSubmissionRequest"] {
                match scenario {
                    "hiddenObject" => {
                        record[key]["inputs"]["sourceArtifactRef"] = json!({"hidden": lease});
                    }
                    "malformedLease" => {
                        record[key]["inputs"]["sourceArtifactRef"] =
                            json!("lease-v1:imp-broken:ART-broken");
                    }
                    "unknownOperation" => {
                        record[key]["operation"]["id"] = json!("unknown.operation")
                    }
                    "unknownDigest" => (),
                    "unknownField" => record[key]["inputs"]["unregistered"] = lease.clone(),
                    "wrongEnum" | "wrongType" => {
                        let descriptor =
                            arkdeck_contract::operation_catalog::CatalogOperation::lookup(
                                "deploy.native-library.app-owned",
                                Some(1),
                            )
                            .unwrap();
                        descriptor
                            .validate_inputs(record[key]["inputs"].as_object().unwrap())
                            .unwrap();
                        record[key]["inputs"]["expectedABI"] = if scenario == "wrongType" {
                            json!(1)
                        } else {
                            json!("unknown-abi")
                        };
                    }
                    _ => unreachable!(),
                }
            }
            if scenario == "unknownOperation" {
                record["operationReference"] = json!("unknown.operation@1");
            }
            if scenario == "unknownDigest" {
                record["catalogDigest"] = json!("b".repeat(64));
            }
        });
        let jobs = tree(&owners.root.join("state/jobs"));
        let capabilities = tree(&owners.root.join("state/capabilities"));
        let imports = tree(&owners.root.join("artifacts"));
        for leaf in ["inspection", "release"] {
            assert_eq!(
                owners.lifecycle(leaf, &owners.imported).unwrap_err().code,
                "recordUnreadable",
                "{scenario}"
            );
        }
        assert_eq!(tree(&owners.root.join("state/jobs")), jobs, "{scenario}");
        assert_eq!(
            tree(&owners.root.join("state/capabilities")),
            capabilities,
            "{scenario}"
        );
        assert_eq!(tree(&owners.root.join("artifacts")), imports, "{scenario}");
    }
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
        if scenario == "proposal" {
            // The unverified proposal still blocks publication; both known
            // original requests nevertheless name no part of this Import.
            assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
        } else {
            assert_eq!(owners.inspection().unwrap_err().code, "recordUnreadable");
        }
    }
}

#[cfg(windows)]
#[test]
fn both_consumed_workspace_jobs_publish_without_blocking_an_unrelated_import() {
    let owners = workspace::Owners::new();
    let capabilities = tree(&owners.root.join("state/capabilities"));
    assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
    for job in &owners.job_ids {
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
        assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
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
    assert_eq!(owners.inspection().unwrap()["references"]["state"], "clear");
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
