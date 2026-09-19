//! Replays the plans and submissions of the Swift native-library oracle
//! (`rust/tests/fixtures/deploy-native-library`, recorded by
//! `NativeLibraryOracleContractTests` over the shared fake HDC) through the
//! Rust planner and admitter, with the Runtime's own `MutationAuthority` at
//! the oracle's fixed root, which holds the library the oracle published.
//! Nothing runs, so the replay covers what admission alone decides:
//! - every plan and all five submissions, answered as Swift answered them;
//! - the one capability, installed exactly as Swift issued it. It is named by
//!   the exact inputs and by the library, whose identity, digest and size are
//!   among the facts it is authorized by, and no use of it is consumed;
//! - each Job's request, original submission and materialization, its
//!   admission row and the start of its journal, as Swift persisted them.
//!
//! An agent execution admits the deployment it will run, as `job.submit`
//! does; the runs themselves are `native_library_run.rs`'s.
//!
//! A library GJ-3 hands the Runtime as an Import is planned and admitted from
//! the Import's lease, which must be bound to the Target, and the Job keeps
//! the Import from release.
//!
//! Fixture data is isolated host evidence, never a device acceptance result.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_hoststore::{
    AdmissionRefusal, AgentEngine, AgentExecutionStore, ImportUploadStore, JobAdmitter, JobPlanner,
};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use support::debug_hap::{self, NoDispatch};
use support::hdc_oracle::{Owners, exchange};
use support::native_library::{self, FIXTURE, answer};
use support::{fixed_now, fixed_precise_now};

const CHECKPOINT: &str = "runtime-capabilities.json";
const LEDGER: &str = "runtime-capabilities.ledger";

fn read(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
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

#[test]
fn rust_admits_the_swift_native_library_submissions_under_the_capability_swift_issued() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture(FIXTURE);
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc(&NoDispatch);
    let admitter = owners.admitter(&hdc, &owners.default_root);
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
        if actual != exchange["answer"] {
            differences.push(format!(
                "{}:\n  swift {}\n  rust  {actual}",
                exchange["name"], exchange["answer"]
            ));
        }
    }
    assert_eq!((plans, submissions), (9, 5), "every plan and submission");

    // The capability Swift issued at the first submission, which every later
    // one reused. Admission consumes no use: it keeps its whole budget and no
    // ledger is written; its uses came with the runs this replay does not
    // make. Swift's runs appended theirs to its ledger and never rewrote the
    // checkpoint its install wrote, so the checkpoint here is Swift's, byte
    // for byte.
    let checkpoint = |store: &Path| fs::read(store.join("capabilities").join(CHECKPOINT)).unwrap();
    let (swift_bytes, issued_bytes) = (
        checkpoint(&fixture.join("store")),
        checkpoint(&owners.default_root),
    );
    let swift: Value = serde_json::from_slice(&swift_bytes).unwrap();
    let issued: Value = serde_json::from_slice(&issued_bytes).unwrap();
    assert_eq!(envelopes(&swift).len(), 1, "one capability");
    if issued_bytes != swift_bytes {
        differences.push(format!(
            "capabilities:\n  swift {}\n  rust  {}",
            String::from_utf8_lossy(&swift_bytes),
            String::from_utf8_lossy(&issued_bytes)
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
    assert!(
        !owners
            .default_root
            .join("capabilities")
            .join(LEDGER)
            .exists()
    );

    // Each Job runs the request naming its capability; the caller's own is
    // its original submission. What admission wrote is Swift's: these
    // members, which no later step changes, and the journal's first two
    // events, byte for byte.
    for (case, job) in cases["jobs"].as_object().unwrap() {
        let job = job.as_str().unwrap();
        let directory = owners.default_root.join("jobs").join(job);
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

    assert!(
        debug_hap::invocations(&owners.root).is_empty(),
        "admission dispatches nothing"
    );

    // The admission rows are Swift's: identity, request hash, sequence and
    // creation. Their state, version and record come with the runs. The index
    // is read once the Job owner is closed.
    let store = owners.default_root.clone();
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

/// GJ-3 hands the Runtime its library as an Import. A deployment of one bound
/// to the Target is planned and admitted from the Import's lease, under the
/// capability the Runtime issues for these exact inputs, and the admitted Job
/// keeps the Import from release. One bound to another identity is refused
/// before admission. Nothing is dispatched and no use is consumed.
#[test]
fn a_deployment_of_an_imported_library_is_admitted_and_keeps_its_import_from_release() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture(FIXTURE);
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let imports = ImportUploadStore::open(&owners.root.join("artifacts")).unwrap();
    let target =
        support::document(&fixture.join("targets-state"), "targets.json")["targets"][0].clone();
    let now = fixed_now().unwrap();
    let recorded = |key: &str| -> Value {
        let mut request: Value = serde_json::from_str(
            exchange(&cases, "deployed.submit")["params"]["requestJson"]
                .as_str()
                .unwrap(),
        )
        .unwrap();
        request["idempotencyKey"] = json!(key);
        request["requestId"] = json!(format!("req-{key}"));
        request
    };
    let hdc = owners.hdc(&NoDispatch);
    let planner = || JobPlanner {
        imports: Some(&imports),
        ..owners.planner(&hdc)
    };

    // Bound to another identity: refused as Swift refuses an unbound lease.
    let mut elsewhere = target.clone();
    elsewhere["stablePhysicalIdentitySHA256"] = json!("b".repeat(64));
    let stray = native_library::import_library(
        &imports,
        &owners.artifacts,
        &fixture,
        "native-import-stray",
        &elsewhere,
        &now,
    );
    let mut request = recorded("idem-native-import-stray");
    request["inputs"]["libraryArtifactLease"] = stray["receipt"]["lease"].clone();
    let refusal = planner()
        .plan(&serde_json::to_vec(&request).unwrap())
        .unwrap_err();
    assert_eq!(refusal.code, "invalidInput");
    assert!(
        refusal
            .message
            .starts_with("native library Artifact lease is not resolvable: ")
            && refusal.message.contains(
                "Artifact lease target/binding/identity does not match the materialized request"
            ),
        "{}",
        refusal.message
    );

    let receipt = native_library::import_library(
        &imports,
        &owners.artifacts,
        &fixture,
        "native-import-library",
        &target,
        &now,
    );
    let mut request = recorded("idem-native-imported");
    request["inputs"]["libraryArtifactLease"] = receipt["receipt"]["lease"].clone();
    let plan = planner()
        .plan(&serde_json::to_vec(&request).unwrap())
        .unwrap();
    assert_eq!(
        (&plan["jobAdmitted"], &plan["dispatchDisposition"]),
        (&json!(false), &json!("notDispatched"))
    );
    let admitter = JobAdmitter {
        planner: planner(),
        ..owners.admitter(&hdc, &owners.default_root)
    };
    let job = admitter
        .submit(&serde_json::to_vec(&request).unwrap())
        .unwrap()["jobId"]
        .clone();
    // The Runtime issued the library's capability for these exact inputs.
    let issued = read(&owners.default_root.join("capabilities").join(CHECKPOINT));
    assert_eq!(envelopes(&issued).len(), 1);
    assert_eq!(envelopes(&issued)[0]["exactInputs"], request["inputs"]);
    assert_eq!(issued["records"][0]["consumptions"], json!([]));
    // Admission let go of its materialization hold, but the Job it admitted
    // references the library, so its Import is not released under it.
    let lifecycle = |verb: &str, fields: Value| {
        imports.lifecycle_resource(
            &owners.artifacts,
            &owners.jobs,
            &format!("artifact.import.{verb}"),
            fields.as_object().unwrap(),
            &now,
        )
    };
    let id = &receipt["importId"];
    assert_eq!(
        lifecycle("inspection", json!({"importId": id})).unwrap()["references"],
        json!({"state": "referenced", "activeJobIds": [job], "outcomeUnknownJobIds": [],
            "activeMaterializationCount": "0"})
    );
    assert_eq!(
        lifecycle("release", json!({"importId": id, "generation": "2"}))
            .unwrap_err()
            .code,
        "resourceConflict"
    );
    assert!(debug_hap::invocations(&owners.root).is_empty());
}

/// An agent execution starts the Job it comes to own at once, and this
/// Runtime now runs a native deployment: `agent.run` admits it under the
/// capability Swift issues, as `job.submit` does, and hands the Job to its
/// caller to start. Admission dispatches nothing and consumes no use.
#[test]
fn an_agent_run_admits_the_deployment_it_will_run() {
    let _lock = debug_hap::exclusive();
    let fixture = support::fixture(FIXTURE);
    let cases = support::document(&fixture, "cases.json");
    let owners = Owners::open(&fixture);
    let hdc = owners.hdc(&NoDispatch);
    let admitter = owners.admitter(&hdc, &owners.default_root);
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
    let deployed: Value = serde_json::from_str(
        exchange(&cases, "deployed.submit")["params"]["requestJson"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    let run = json!({
        "schemaVersion": "arkdeck.agent-execution-request/1", "executionId": "native-agent",
        "operation": "deploy.native-library.app-owned@1", "inputs": deployed["inputs"],
        "maximumWaitMilliseconds": "300000",
        "target": {"targetId": deployed["target"]["targetId"]},
    });
    let answer = agents
        .advance("agent.run", run.as_object().unwrap(), &engine)
        .unwrap_or_else(|refusal| panic!("{}: {}", refusal.code, refusal.message));
    let start = answer
        .start
        .expect("the execution owns the Job it will run");
    assert_eq!(start.execution, "native-agent");
    let record = read(
        &owners
            .default_root
            .join("jobs")
            .join(&start.job)
            .join("job-record.json"),
    );
    assert_eq!(
        (&record["state"], &record["operationReference"]),
        (
            &json!("preflight"),
            &json!("deploy.native-library.app-owned@1")
        )
    );
    assert!(record.get("admissionEvidence").is_none());
    // The capability Swift issues for these exact inputs and this library,
    // with its whole budget.
    let issued = read(&owners.default_root.join("capabilities").join(CHECKPOINT));
    let swift = read(&fixture.join("store/capabilities").join(CHECKPOINT));
    assert_eq!(envelopes(&issued), envelopes(&swift));
    assert_eq!(
        record["request"]["authorization"]["capabilityId"],
        envelopes(&issued)[0]["capabilityID"]
    );
    assert_eq!(issued["records"][0]["consumptions"], json!([]));
    assert!(debug_hap::invocations(&owners.root).is_empty());
}
