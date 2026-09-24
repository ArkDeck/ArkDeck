//! Replays the submissions of the Swift debug-hap oracle
//! (`rust/tests/fixtures/debug-hap`, recorded by `DebugHapOracleContractTests`
//! over the shared fake HDC) through the real `JobPlanner` and `JobAdmitter`,
//! with the Runtime's own `MutationAuthority` at the oracle's fixed root, where
//! each plan names the packages where Swift's did. Each HAP is admitted under
//! the Runtime capability Swift issues for it, named by its exact inputs and by
//! the entry package's owner-validated facts. Nothing runs:
//! - every plan and submission is answered as Swift answered it; the two
//!   capabilities are installed as Swift issued them and no use is consumed;
//!   each Job's request, original submission, admission row and journal are
//!   Swift's; an agent execution admits the HAP it will run, and a cancelled
//!   one closes at `preflight` with no use spent (the runs themselves are
//!   `debug_hap_run.rs`'s);
//! - with the use each Swift run took written between the submissions, through
//!   the store's own writes and as Swift recorded it, the admissions leave
//!   Swift's capability store byte for byte, and after the last use's unknown
//!   outcome no HAP is admitted on the Target binding, whatever its inputs;
//! - a capability the caller names is used as named, as Swift's standing
//!   capability policy does, and one that does not exist is denied;
//! - a HAP of imported packages is admitted, and the admitted Job keeps both
//!   Imports from release.
//!
//! Fixture data is isolated host evidence, never a device acceptance result.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    AdmissionRefusal, AgentEngine, AgentExecutionStore, ArtifactReadStore, CapabilityQuery,
    CapabilityStore, CapabilityUseOutcome, DeviceHolds, HdcComposition, ImportUploadStore,
    JobAdmitter, JobCanceller, JobPlanner, JobStore, MutationAuthority, TargetStore,
    WorkflowEffect,
};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use support::debug_hap::{self, NoDispatch};
use support::{fixed_now, fixed_precise_now};

const CHECKPOINT: &str = "runtime-capabilities.json";
const LEDGER: &str = "runtime-capabilities.ledger";

/// The owners one replay admits with, over the rebuilt fixed root. The Job
/// state is `store`, as the oracle records it. The capability store is made
/// beside it once the Job owner holds it, as the daemon makes it: a new Job
/// repository takes only an empty directory.
struct Owners {
    root: PathBuf,
    store: PathBuf,
    targets: TargetStore,
    artifacts: ArtifactReadStore,
    jobs: JobStore,
    capabilities: CapabilityStore,
    holds: DeviceHolds,
    digest: String,
}

impl Owners {
    fn open(fixture: &Path) -> Self {
        let root = debug_hap::rebuild(fixture);
        let store = root.join("store");
        let jobs = JobStore::open_owner(&store).unwrap();
        let capabilities = CapabilityStore::open(&store.join("capabilities")).unwrap();
        Self {
            targets: TargetStore::open(&root.join("targets-state")).unwrap(),
            artifacts: ArtifactReadStore::open(&root.join("artifacts")).unwrap(),
            jobs,
            capabilities,
            holds: DeviceHolds::default(),
            digest: sha256_hex(&fs::read(fixture.join("hdc")).unwrap()),
            store,
            root,
        }
    }

    fn hdc(&self) -> HdcComposition<'_> {
        HdcComposition {
            targets: &self.targets,
            dispatch: &NoDispatch,
            receive_root: None,
            tool_sha256: &self.digest,
            now: fixed_now,
            code_sign_helper: None,
        }
    }

    fn planner<'a>(&'a self, hdc: &'a HdcComposition<'a>) -> JobPlanner<'a> {
        JobPlanner {
            imports: None,
            artifacts: Some(&self.artifacts),
            analyzer: None,
            state_root: &self.root,
            hdc: Some(hdc),
            workspace: None,
        }
    }

    /// The Runtime-owned authority over this root's own Job state, which the
    /// mutation state check requires, and no Session owner.
    fn authority(&self) -> MutationAuthority<'_> {
        MutationAuthority {
            default_root: &self.store,
            sessions: None,
            capabilities: &self.capabilities,
            holds: &self.holds,
        }
    }

    fn admitter<'a>(&'a self, hdc: &'a HdcComposition<'a>) -> JobAdmitter<'a> {
        JobAdmitter {
            planner: self.planner(hdc),
            jobs: &self.jobs,
            now: fixed_now,
            authority: Some(self.authority()),
        }
    }

    fn capability_file(&self, name: &str) -> PathBuf {
        self.store.join("capabilities").join(name)
    }
}

fn proof() -> Value {
    json!({"newDispatchCount": 0, "phase": "preAdmission"})
}

/// The control plane's answer: a refusal before the admission point proves
/// zero dispatch.
fn answer(outcome: Result<Value, AdmissionRefusal>) -> Value {
    match outcome {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(refusal) => json!({"ok": false, "error": {
            "code": refusal.code,
            "message": refusal.message,
            "details": if refusal.proven { proof() } else { json!({}) },
        }}),
    }
}

fn read(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn exchange<'a>(cases: &'a Value, name: &str) -> &'a Value {
    cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|exchange| exchange["name"] == name)
        .unwrap()
}

/// The request a case's recorded submission sent.
fn recorded_request(cases: &Value, case: &str) -> Value {
    serde_json::from_str(
        exchange(cases, &format!("{case}.submit"))["params"]["requestJson"]
            .as_str()
            .unwrap(),
    )
    .unwrap()
}

/// The same request under a new idempotency key.
fn resubmitted(cases: &Value, case: &str, key: &str) -> Value {
    let mut request = recorded_request(cases, case);
    request["idempotencyKey"] = json!(key);
    request["requestId"] = json!(format!("req-{key}"));
    request
}

fn bytes(request: &Value) -> Vec<u8> {
    serde_json::to_vec(request).unwrap()
}

/// The capabilities a checkpoint holds, in install order.
fn envelopes(checkpoint: &Value) -> Vec<Value> {
    checkpoint["records"]
        .as_array()
        .unwrap()
        .iter()
        .map(|record| record["capability"].clone())
        .collect()
}

/// How many uses the store below `store` holds: the ones its checkpoint
/// folded and the ones its ledger appended since.
fn uses(store: &Path) -> usize {
    let directory = store.join("capabilities");
    let folded = fs::read(directory.join(CHECKPOINT)).map_or(0, |bytes| {
        let checkpoint: Value = serde_json::from_slice(&bytes).unwrap();
        checkpoint["records"]
            .as_array()
            .unwrap()
            .iter()
            .map(|record| record["consumptions"].as_array().unwrap().len())
            .sum()
    });
    let appended = fs::read_to_string(directory.join(LEDGER))
        .unwrap_or_default()
        .lines()
        .filter(|line| serde_json::from_str::<Value>(line).unwrap()["kind"] == "consumed")
        .count();
    folded + appended
}

#[test]
fn rust_admits_the_swift_hap_submissions_under_the_capabilities_swift_issued() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc();
    let admitter = owners.admitter(&hdc);
    let (mut plans, mut submissions, mut differences) = (0, 0, Vec::new());
    for exchange in cases["exchanges"].as_array().unwrap() {
        let params = exchange["params"].as_object().unwrap();
        let actual = match exchange["method"].as_str().unwrap() {
            "job.plan" => {
                plans += 1;
                answer(
                    owners
                        .planner(&hdc)
                        .handle(params)
                        .map_err(AdmissionRefusal::from),
                )
            }
            "job.submit" => {
                submissions += 1;
                answer(admitter.handle(params))
            }
            _ => continue,
        };
        let actual = support::legacy_plan_answer(actual);
        if actual != exchange["answer"] {
            differences.push(format!(
                "{}:\n  swift {}\n  rust  {actual}",
                exchange["name"], exchange["answer"]
            ));
        }
    }
    assert_eq!((plans, submissions), (15, 8), "every plan and submission");

    // The capabilities Swift issued at those submissions, in install order.
    // Admission consumes no use: each keeps its whole budget and no ledger
    // is written; the uses came with the runs this replay does not make.
    let swift = read(&fixture.join("store/capabilities").join(CHECKPOINT));
    let issued = read(&owners.capability_file(CHECKPOINT));
    if envelopes(&issued) != envelopes(&swift) {
        differences.push(format!(
            "capabilities:\n  swift {}\n  rust  {}",
            json!(envelopes(&swift)),
            json!(envelopes(&issued))
        ));
    }
    for record in issued["records"].as_array().unwrap() {
        assert_eq!(
            record["consumptions"],
            json!([]),
            "admission consumes no use"
        );
        assert_eq!(record["remainingUses"], record["capability"]["maximumUses"]);
    }
    assert!(!owners.capability_file(LEDGER).exists());

    // Each Job runs the request naming its capability; the caller's own is
    // its original submission. What admission wrote is Swift's: these
    // members, which no later step changes, and the journal's first two
    // events, byte for byte.
    for (case, job) in cases["jobs"].as_object().unwrap() {
        let job = job.as_str().unwrap();
        let directory = owners.store.join("jobs").join(job);
        let recorded = fixture.join("store/jobs").join(job);
        let ours = read(&directory.join("job-record.json"));
        let theirs = read(&recorded.join("job-record.json"));
        for member in [
            "jobID",
            "request",
            "originalSubmissionRequest",
            "operationReference",
            "catalogDigest",
            "providerID",
            "createdAtUTC",
            "actualEffect",
            "materializedPlanDigest",
            "materializedStableTargetIdentitySHA256",
            "materializedBindingRevision",
        ] {
            if ours[member] != theirs[member] {
                differences.push(format!(
                    "{case} {member}:\n  swift {}\n  rust  {}",
                    theirs[member], ours[member]
                ));
            }
        }
        assert_eq!(ours["state"], "preflight", "{case}");
        assert_eq!(
            ours["timeline"],
            json!(["jobCreated", "queued->preflight"]),
            "{case}"
        );
        assert!(
            ours.get("admissionEvidence").is_none(),
            "{case}: no use is consumed at admission"
        );
        let swift_journal = fs::read(recorded.join("journal.jsonl")).unwrap();
        let admitted: Vec<u8> = swift_journal
            .split_inclusive(|byte| *byte == b'\n')
            .take(2)
            .collect::<Vec<_>>()
            .concat();
        if fs::read(directory.join("journal.jsonl")).unwrap() != admitted {
            differences.push(format!("{case}: the admission journal differs"));
        }
    }

    // The admission rows are Swift's: identity, request hash, sequence and
    // creation. Their state, version and record come with the runs. The index
    // is read once the Job owner is closed.
    let store = owners.store.clone();
    drop(owners);
    let index = support::index(&store);
    let recorded = support::document(&fixture, "store/index.json");
    let admission = |index: &Value| -> Vec<Value> {
        index["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| {
                json!({"jobId": row["jobId"], "idempotencyKey": row["idempotencyKey"],
                    "requestHash": row["requestHash"], "admissionSequence": row["admissionSequence"],
                    "createdAtUTC": row["createdAtUTC"], "createdAtOrderKey": row["createdAtOrderKey"]})
            })
            .collect()
    };
    for member in ["userVersion", "journalMode", "schema"] {
        assert_eq!(index[member], recorded[member], "index {member}");
    }
    if admission(&index) != admission(&recorded) {
        differences.push(format!(
            "admission rows:\n  swift {}\n  rust  {}",
            json!(admission(&recorded)),
            json!(admission(&index))
        ));
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
}

/// A use Swift's run of one Job took, as its store recorded it: the
/// capability it was taken from, the use, and the outcomes that settled it.
struct RecordedUse {
    capability: Value,
    consumption: Value,
    outcomes: Vec<Value>,
}

/// Every use in the store the oracle left, by the Job that took it: those
/// its checkpoint folded, then those its ledger appended.
fn recorded_uses(fixture: &Path) -> BTreeMap<String, RecordedUse> {
    let directory = fixture.join("store/capabilities");
    let mut capabilities = BTreeMap::new();
    let mut uses = BTreeMap::new();
    for record in read(&directory.join(CHECKPOINT))["records"]
        .as_array()
        .unwrap()
    {
        let capability = &record["capability"];
        let id = capability["capabilityID"].as_str().unwrap().to_owned();
        capabilities.insert(id, capability.clone());
        for consumption in record["consumptions"].as_array().unwrap() {
            uses.insert(
                consumption["jobID"].as_str().unwrap().to_owned(),
                RecordedUse {
                    capability: capability.clone(),
                    consumption: consumption.clone(),
                    outcomes: consumption["outcomes"].as_array().unwrap().clone(),
                },
            );
        }
    }
    for line in fs::read_to_string(directory.join(LEDGER)).unwrap().lines() {
        let event: Value = serde_json::from_str(line).unwrap();
        match event["kind"].as_str().unwrap() {
            "consumed" => {
                let consumption = event["consumption"].clone();
                uses.insert(
                    consumption["jobID"].as_str().unwrap().to_owned(),
                    RecordedUse {
                        capability: capabilities[event["capabilityID"].as_str().unwrap()].clone(),
                        consumption,
                        outcomes: Vec::new(),
                    },
                );
            }
            "outcome" => uses
                .get_mut(event["outcome"]["jobID"].as_str().unwrap())
                .unwrap()
                .outcomes
                .push(event["outcome"].clone()),
            other => panic!("unexpected ledger event {other}"),
        }
    }
    uses
}

/// The entry package's facts, as the admission and each run query carry them.
fn entry_facts(fixture: &Path) -> BTreeMap<String, String> {
    let index = read(&fixture.join("artifacts/job-input-hap/index.json"));
    let row = index["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["name"] == "entry.hap")
        .unwrap();
    BTreeMap::from([
        (
            "artifactId".into(),
            row["artifactID"].as_str().unwrap().into(),
        ),
        (
            "artifactSha256".into(),
            row["sha256"].as_str().unwrap().into(),
        ),
        ("artifactByteCount".into(), row["byteCount"].to_string()),
    ])
}

/// Writes a use a Swift run took through the store's own consume and outcome
/// writes, with the query that run carried: the capability's exact inputs,
/// the materialized plan and the entry package's facts. Nothing runs.
fn write_use(store: &CapabilityStore, recorded: &RecordedUse, facts: &BTreeMap<String, String>) {
    let text = |value: &Value| value.as_str().unwrap().to_owned();
    let (capability, consumption) = (&recorded.capability, &recorded.consumption);
    let id = text(&capability["capabilityID"]);
    let reference = text(&consumption["operationReference"]);
    let (operation, version) = reference.split_once('@').unwrap();
    let query = CapabilityQuery {
        operation_id: operation.into(),
        operation_version: Some(version.parse().unwrap()),
        effect: WorkflowEffect::parse(consumption["effect"].as_str().unwrap()).unwrap(),
        target_stable_identity_sha256: Some(text(&consumption["targetStableIdentitySHA256"])),
        target_binding_revision: consumption["bindingRevision"].as_i64(),
        plan_digest: Some(text(&consumption["materializedPlanDigest"])),
        inputs: capability["exactInputs"].as_object().unwrap().clone(),
        artifact_facts: facts.clone(),
        workspace_identity_sha256: None,
        workspace_revision: None,
        workspace_file_scopes_digest: None,
    };
    let reservation = text(&consumption["reservationID"]);
    let receipt = store
        .consume(
            &id,
            &reservation,
            Some(&text(&consumption["jobID"])),
            &query,
            &text(&consumption["consumedAtUTC"]),
        )
        .unwrap_or_else(|error| panic!("{id} {reservation}: {}", error.swift()));
    assert_eq!(receipt.receipt_sha256, text(&consumption["receiptSHA256"]));
    for outcome in &recorded.outcomes {
        store
            .record_outcome(
                &id,
                &reservation,
                &text(&outcome["jobID"]),
                CapabilityUseOutcome::parse(outcome["outcome"].as_str().unwrap()).unwrap(),
                &text(&outcome["terminalState"]),
                &text(&outcome["recordedAtUTC"]),
            )
            .unwrap_or_else(|error| panic!("{id} {reservation}: {}", error.swift()));
    }
}

#[test]
fn between_swifts_uses_the_admissions_leave_swifts_store_and_an_unknown_use_blocks_the_next_hap() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let recorded = recorded_uses(&fixture);
    let facts = entry_facts(&fixture);
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc();
    let admitter = owners.admitter(&hdc);
    let mut written = 0;
    for exchange in cases["exchanges"].as_array().unwrap() {
        let name = exchange["name"].as_str().unwrap();
        match exchange["method"].as_str().unwrap() {
            "job.submit" => {
                let before = uses(&owners.store);
                assert_eq!(
                    answer(admitter.handle(exchange["params"].as_object().unwrap())),
                    exchange["answer"],
                    "{name}"
                );
                assert_eq!(uses(&owners.store), before, "{name} consumed a use");
            }
            // In place of each run, the use it took, as Swift recorded it.
            "job.run" => {
                let Some(job) = name
                    .strip_suffix(".run")
                    .and_then(|case| cases["jobs"][case].as_str())
                else {
                    continue;
                };
                write_use(&owners.capabilities, &recorded[job], &facts);
                written += 1;
            }
            _ => (),
        }
    }
    assert_eq!(written, recorded.len(), "one use for each run");

    // The packages set's install wrote the checkpoint over the installed
    // run's use, and every later admission reused the first capability: the
    // store is Swift's, byte for byte, and as private as Swift left it.
    let swift = fixture.join("store/capabilities");
    for name in [CHECKPOINT, LEDGER] {
        assert_eq!(
            String::from_utf8(fs::read(owners.capability_file(name)).unwrap()).unwrap(),
            String::from_utf8(fs::read(swift.join(name)).unwrap()).unwrap(),
            "{name}"
        );
    }
    let mut entries: Vec<(String, String)> = fs::read_dir(owners.store.join("capabilities"))
        .unwrap()
        .map(|entry| {
            let entry = entry.unwrap();
            let mode = entry.metadata().unwrap().permissions().mode() & 0o7777;
            (
                entry.file_name().into_string().unwrap(),
                format!("{mode:o}"),
            )
        })
        .collect();
    entries.sort();
    let mut expected: Vec<(String, String)> = support::document(&fixture, "tree.json")
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|entry| {
            let name = entry["path"]
                .as_str()?
                .strip_prefix("store/capabilities/")?;
            Some((name.to_owned(), entry["mode"].as_str()?.to_owned()))
        })
        .collect();
    expected.sort();
    assert_eq!(entries, expected);

    // The last run's use ended with an unknown outcome. Until recovery
    // settles it, no HAP is admitted on this Target binding, whatever its
    // inputs: the entry package alone, or with its feature package under
    // another capability.
    let (capability, ordinal) = recorded
        .values()
        .find(|recorded| {
            recorded
                .outcomes
                .iter()
                .any(|outcome| outcome["outcome"] == "outcomeUnknown")
        })
        .map(|recorded| {
            (
                recorded.capability["capabilityID"].as_str().unwrap(),
                &recorded.consumption["ordinal"],
            )
        })
        .unwrap();
    let blocked = json!({"ok": false, "error": {
        "code": "admissionDenied",
        "message": format!(
            "automatic Runtime target lineage is blocked: lineageBlocked(\"target binding \
             has unresolved capability {capability} use {ordinal} outcome outcomeUnknown\")"
        ),
        "details": proof(),
    }});
    let jobs_before = debug_hap::tree_bytes(&owners.store.join("jobs"));
    let capabilities_before = debug_hap::tree_bytes(&owners.store.join("capabilities"));
    for (case, key) in [
        ("installed", "idem-hap-after-unknown"),
        ("packageSet", "idem-hap-set-after-unknown"),
    ] {
        let request = resubmitted(&cases, case, key);
        assert_eq!(answer(admitter.submit(&bytes(&request))), blocked, "{case}");
    }
    assert_eq!(
        debug_hap::tree_bytes(&owners.store.join("jobs")),
        jobs_before
    );
    assert_eq!(
        debug_hap::tree_bytes(&owners.store.join("capabilities")),
        capabilities_before
    );
    assert!(debug_hap::invocations(&owners.root).is_empty());
}

#[test]
fn a_hap_naming_a_capability_is_admitted_under_it_or_denied_as_swift_does() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc();
    let admitter = owners.admitter(&hdc);
    let installed = exchange(&cases, "installed.submit");
    assert_eq!(
        answer(admitter.handle(installed["params"].as_object().unwrap())),
        installed["answer"]
    );
    let issued = read(&owners.capability_file(CHECKPOINT));
    let capability = envelopes(&issued)[0]["capabilityID"].clone();

    // Swift's standing policy uses a named capability as named, once the
    // store validates this execution against it; nothing else is issued.
    let mut named = resubmitted(&cases, "installed", "idem-hap-named");
    named["authorization"] = json!({"capabilityId": capability});
    let accepted = admitter.submit(&bytes(&named)).unwrap();
    let record = read(
        &owners
            .store
            .join("jobs")
            .join(accepted["jobId"].as_str().unwrap())
            .join("job-record.json"),
    );
    assert_eq!(
        record["request"]["authorization"]["capabilityId"],
        capability
    );
    assert_eq!(record["request"], record["originalSubmissionRequest"]);
    assert_eq!(read(&owners.capability_file(CHECKPOINT)), issued);

    // A capability the store does not hold is denied before admission.
    let unknown = format!("CAP-RT-POLICY-{}-G1", "0".repeat(40));
    let mut denied = resubmitted(&cases, "installed", "idem-hap-unknown-capability");
    denied["authorization"] = json!({"capabilityId": unknown});
    let jobs_before = debug_hap::tree_bytes(&owners.store.join("jobs"));
    assert_eq!(
        answer(admitter.submit(&bytes(&denied))),
        json!({"ok": false, "error": {
            "code": "admissionDenied",
            "message": format!(
                "capability denied [denial:capabilityNotFound]: capabilityNotFound(\"{unknown}\")"
            ),
            "details": proof(),
        }})
    );
    assert_eq!(
        debug_hap::tree_bytes(&owners.store.join("jobs")),
        jobs_before
    );
    assert_eq!(read(&owners.capability_file(CHECKPOINT)), issued);
    assert!(!owners.capability_file(LEDGER).exists());
    assert!(debug_hap::invocations(&owners.root).is_empty());
}

#[test]
fn an_admitted_hap_keeps_its_imported_packages_from_release() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let imports = ImportUploadStore::open(&owners.root.join("artifacts")).unwrap();
    let target =
        support::document(&fixture.join("targets-state"), "targets.json")["targets"][0].clone();
    let now = fixed_now().unwrap();
    let receipts: Vec<Value> = ["entry", "feature"]
        .into_iter()
        .map(|name| {
            debug_hap::import_package(
                &imports,
                &owners.artifacts,
                name,
                target["targetID"].as_str().unwrap(),
                1,
                target["stablePhysicalIdentitySHA256"].as_str().unwrap(),
                &now,
            )
        })
        .collect();
    let mut request = resubmitted(&cases, "packageSet", "idem-hap-imported");
    request["inputs"]["hapArtifactLease"] = receipts[0]["receipt"]["lease"].clone();
    request["inputs"]["additionalHapArtifactLeases"] = json!([receipts[1]["receipt"]["lease"]]);
    let hdc = owners.hdc();
    let admitter = JobAdmitter {
        planner: JobPlanner {
            imports: Some(&imports),
            ..owners.planner(&hdc)
        },
        ..owners.admitter(&hdc)
    };
    let job = admitter.submit(&bytes(&request)).unwrap()["jobId"].clone();
    // The Runtime issued the packages' capability for these exact inputs.
    let issued = read(&owners.capability_file(CHECKPOINT));
    assert_eq!(envelopes(&issued).len(), 1);
    assert_eq!(envelopes(&issued)[0]["exactInputs"], request["inputs"]);
    // Admission let go of its materialization holds, but the Job it admitted
    // references both packages, so neither Import is released under it.
    let lifecycle = |verb: &str, fields: Value| {
        imports.lifecycle_resource(
            &owners.artifacts,
            &owners.jobs,
            &format!("artifact.import.{verb}"),
            fields.as_object().unwrap(),
            &now,
        )
    };
    for receipt in &receipts {
        let id = &receipt["importId"];
        let references =
            lifecycle("inspection", json!({"importId": id})).unwrap()["references"].clone();
        assert_eq!(
            references,
            json!({"state": "referenced", "activeJobIds": [job], "outcomeUnknownJobIds": [],
                "activeMaterializationCount": "0"})
        );
        assert_eq!(
            lifecycle("release", json!({"importId": id, "generation": "2"}))
                .unwrap_err()
                .code,
            "resourceConflict"
        );
    }
    assert_eq!(uses(&owners.store), 0);
    assert!(debug_hap::invocations(&owners.root).is_empty());
}

/// An agent execution starts the Job it comes to own at once, and this
/// Runtime now runs a HAP: `agent.run` admits it under the capability the
/// Runtime issues, as `job.submit` does, and hands the Job to its caller to
/// start. Admission dispatches nothing and consumes no use.
#[test]
fn an_agent_run_admits_the_hap_it_will_run() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc();
    let admitter = owners.admitter(&hdc);
    let executions = owners.root.join("agent-executions");
    fs::create_dir(&executions).unwrap();
    fs::set_permissions(&executions, fs::Permissions::from_mode(0o700)).unwrap();
    let agents = AgentExecutionStore::open(&executions).unwrap();
    let engine = AgentEngine {
        targets: &owners.targets,
        jobs: &owners.jobs,
        admitter: &admitter,
        now: fixed_precise_now,
        observations: None,
    };
    let installed = recorded_request(&cases, "installed");
    let run = json!({
        "schemaVersion": "arkdeck.agent-execution-request/1", "executionId": "hap-agent",
        "operation": "debug.hap@1", "inputs": installed["inputs"],
        "maximumWaitMilliseconds": "300000",
        "target": {"targetId": installed["target"]["targetId"]},
    });
    let answer = agents
        .advance("agent.run", run.as_object().unwrap(), &engine)
        .unwrap_or_else(|refusal| panic!("{}: {}", refusal.code, refusal.message));
    let start = answer
        .start
        .expect("the execution owns the Job it will run");
    assert_eq!(start.execution, "hap-agent");
    let record = read(
        &owners
            .store
            .join("jobs")
            .join(&start.job)
            .join("job-record.json"),
    );
    assert_eq!(
        (&record["state"], &record["operationReference"]),
        (&json!("preflight"), &json!("debug.hap@1"))
    );
    assert!(record.get("admissionEvidence").is_none());
    // The capability the Runtime issued for these exact inputs, with its
    // whole budget.
    let issued = read(&owners.capability_file(CHECKPOINT));
    assert_eq!(envelopes(&issued).len(), 1);
    assert_eq!(
        record["request"]["authorization"]["capabilityId"],
        envelopes(&issued)[0]["capabilityID"]
    );
    assert_eq!(uses(&owners.store), 0);
    assert!(debug_hap::invocations(&owners.root).is_empty());
}

#[test]
fn an_admitted_hap_is_cancelled_at_preflight_with_no_use_spent() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture("debug-hap");
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc();
    let installed = exchange(&cases, "installed.submit");
    let accepted = owners
        .admitter(&hdc)
        .handle(installed["params"].as_object().unwrap())
        .unwrap();
    let capabilities = debug_hap::tree_bytes(&owners.store.join("capabilities"));
    // Swift closes a Job no run holds with zero dispatch; consumption comes
    // only before a first mutation, so there is no use to settle.
    JobCanceller {
        jobs: &owners.jobs,
        now: fixed_now,
        sessions: None,
    }
    .handle(&Map::from_iter([(
        "jobId".into(),
        accepted["jobId"].clone(),
    )]))
    .unwrap();
    let record = read(
        &owners
            .store
            .join("jobs")
            .join(accepted["jobId"].as_str().unwrap())
            .join("job-record.json"),
    );
    assert_eq!(record["state"], "cancelled");
    assert!(record.get("admissionEvidence").is_none());
    assert_eq!(
        debug_hap::tree_bytes(&owners.store.join("capabilities")),
        capabilities
    );
    assert_eq!(uses(&owners.store), 0);
    assert!(debug_hap::invocations(&owners.root).is_empty());
}
