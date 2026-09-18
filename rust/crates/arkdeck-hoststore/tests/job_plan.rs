//! Replays the Swift `job.plan` oracle (`rust/tests/fixtures/job-plan-analyzer`,
//! produced by `JobPlanAnalyzerOracleContractTests`) against the Rust planner.
//! The materialized plan digest covers the source Artifact's absolute path, so
//! the recorded store is rebuilt at the oracle's fixed root, under the lock the
//! Swift producer also takes.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{AnalyzerProfile, ArtifactReadStore, JobPlanner};
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const ROOT: &str = "/private/tmp/arkdeck-job-plan-oracle";
const LOCK: &str = "/private/tmp/arkdeck-job-plan-oracle.lock";
const SOURCE_JOB: &str = "job-oracle-source";

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/job-plan-analyzer")
}

fn chmod(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

/// Serializes every user of the fixed root, Swift producer included.
fn exclusive() -> File {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    lock
}

/// The recorded store at the fixed root, with the modes Swift publication
/// leaves: private directories, a private index and sealed payloads.
fn rebuild() -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    fs::create_dir(&root).unwrap();
    chmod(&root, 0o700);
    fs::copy(fixture().join("analyzer"), root.join("analyzer")).unwrap();
    chmod(&root.join("analyzer"), 0o700);
    let artifacts = root.join("artifacts");
    fs::create_dir(&artifacts).unwrap();
    chmod(&artifacts, 0o700);
    for job in fs::read_dir(fixture().join("artifacts")).unwrap() {
        let job = job.unwrap().path();
        let destination = artifacts.join(job.file_name().unwrap());
        fs::create_dir(&destination).unwrap();
        chmod(&destination, 0o700);
        for file in fs::read_dir(&job).unwrap() {
            let file = file.unwrap().path();
            let name = file.file_name().unwrap();
            fs::copy(&file, destination.join(name)).unwrap();
            chmod(
                &destination.join(name),
                if name == "index.json" { 0o600 } else { 0o400 },
            );
        }
    }
    root
}

/// The published `crash-log.txt` payload every planned case leases.
fn source_payload(root: &Path) -> PathBuf {
    let directory = root.join("artifacts").join(SOURCE_JOB);
    let index: Value =
        serde_json::from_slice(&fs::read(directory.join("index.json")).unwrap()).unwrap();
    let row = index["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["name"] == "crash-log.txt")
        .unwrap();
    directory.join(row["artifactID"].as_str().unwrap())
}

/// Rewrites a sealed payload in place with bytes of the same length, keeping
/// its mode, as the Swift producer does.
fn overwrite(path: &Path, bytes: &[u8]) {
    let mode = fs::metadata(path).unwrap().permissions().mode() & 0o7777;
    chmod(path, 0o600);
    OpenOptions::new()
        .write(true)
        .open(path)
        .unwrap()
        .write_all(bytes)
        .unwrap();
    chmod(path, mode);
}

/// Applies the on-disk change a case names and returns what undoes it.
fn mutate(mutation: Option<&str>, root: &Path, payload: &Path) -> Box<dyn FnOnce()> {
    match mutation {
        None => Box::new(|| ()),
        Some("analyzerDrift") => {
            let analyzer = root.join("analyzer");
            let length = fs::metadata(&analyzer).unwrap().len();
            OpenOptions::new()
                .append(true)
                .open(&analyzer)
                .unwrap()
                .write_all(b"\n")
                .unwrap();
            Box::new(move || {
                OpenOptions::new()
                    .write(true)
                    .open(&analyzer)
                    .unwrap()
                    .set_len(length)
                    .unwrap();
            })
        }
        Some("payloadTampered") => {
            let original = fs::read(payload).unwrap();
            let mut tampered = original.clone();
            tampered[0] ^= 0x20;
            overwrite(payload, &tampered);
            let payload = payload.to_owned();
            Box::new(move || overwrite(&payload, &original))
        }
        Some("payloadMissing") => {
            let mut moved = payload.as_os_str().to_owned();
            moved.push(".moved");
            let moved = PathBuf::from(moved);
            fs::rename(payload, &moved).unwrap();
            let payload = payload.to_owned();
            Box::new(move || fs::rename(&moved, &payload).unwrap())
        }
        Some(other) => panic!("unknown oracle mutation {other}"),
    }
}

fn planned_request(lease: &str, idempotency_key: &str) -> Map<String, Value> {
    let document = json!({
        "schemaVersion": "1.0.0",
        "requestId": "req-rust-divergence",
        "idempotencyKey": idempotency_key,
        "target": {"targetId": "TGT-ORACLE"},
        "operation": {"id": "analyzer.extract-crash-signature", "version": 1},
        "inputs": {"sourceArtifactRef": lease},
    });
    Map::from_iter([("requestJson".into(), json!(document.to_string()))])
}

#[test]
fn rust_plans_reproduce_the_swift_oracle() {
    let _lock = exclusive();
    let root = rebuild();
    let cases: Vec<Value> =
        serde_json::from_slice(&fs::read(fixture().join("cases.json")).unwrap()).unwrap();
    let store = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let profile = AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap();
    let payload = source_payload(&root);
    let mut planned = 0;
    let mut differences = Vec::new();
    for case in &cases {
        let name = case["name"].as_str().unwrap();
        let params = match &case["params"] {
            Value::Object(params) => params.clone(),
            _ => Map::from_iter([(
                "requestJson".into(),
                json!(" ".repeat(case["requestJsonSpaces"].as_u64().unwrap() as usize)),
            )]),
        };
        let restore = mutate(case["mutation"].as_str(), &root, &payload);
        let outcome = JobPlanner {
            imports: None,
            artifacts: Some(&store),
            analyzer: (case["engine"] != "unconfigured").then_some(&profile),
            state_root: &root,
            hdc: None,
        }
        .handle(&params);
        restore();
        let expected = &case["response"];
        let actual = match outcome {
            Ok(result) => {
                planned += 1;
                json!({"ok": true, "result": result})
            }
            Err(refusal) => json!({"ok": false, "error": {"code": refusal.code,
                "message": refusal.message}}),
        };
        let mut recorded = expected.clone();
        if let Some(error) = recorded.get_mut("error").and_then(Value::as_object_mut) {
            // Zero-dispatch details are the control layer's; the agentd
            // harness compares them over the socket.
            error.remove("details");
        }
        if actual != recorded {
            differences.push(format!("{name}:\n  swift {recorded}\n  rust  {actual}"));
        }
    }
    assert!(differences.is_empty(), "{}", differences.join("\n"));
    assert_eq!(planned, 4, "the oracle plans four requests");
    assert!(cases.len() >= 70, "the oracle covers every refusal class");
    fs::remove_dir_all(&root).unwrap();
}

/// Swift refuses a `requestJson` that is not text exactly as an empty one. The
/// oracle leaves it out so recording it does not widen the published request
/// schema beyond a string parameter.
#[test]
fn a_request_json_that_is_not_text_is_refused_as_an_empty_one() {
    let planner = JobPlanner {
        imports: None,
        artifacts: None,
        analyzer: None,
        state_root: Path::new(ROOT),
        hdc: None,
    };
    for value in [json!(7), json!(null), json!(["{}"]), json!("")] {
        let refusal = planner
            .handle(&Map::from_iter([("requestJson".into(), value)]))
            .unwrap_err();
        assert_eq!(
            (refusal.code, refusal.message.as_str()),
            (
                "invalidInput",
                "requestJson must be a non-empty typed request document"
            )
        );
    }
}

/// What Swift would plan but this Runtime refuses before materializing, each
/// with zero dispatch: operations it does not materialize, Import leases it
/// does not resolve and Runtime debug permits it does not read.
#[test]
fn rust_refuses_plans_it_cannot_materialize_yet() {
    let _lock = exclusive();
    let root = rebuild();
    let store = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let profile = AnalyzerProfile::crash_signature(&root.join("analyzer")).unwrap();
    let planner = JobPlanner {
        imports: None,
        artifacts: Some(&store),
        analyzer: Some(&profile),
        state_root: &root,
        hdc: None,
    };
    let device_request = |operation: &str, key: &str| {
        let request = json!({
            "schemaVersion": "1.0.0",
            "requestId": "req-rust-device",
            "idempotencyKey": key,
            "target": {"targetId": "TGT-ORACLE", "expectedBindingRevision": 3},
            "operation": {"id": operation, "version": 1},
        });
        Map::from_iter([("requestJson".into(), json!(request.to_string()))])
    };
    let refusal = planner
        .handle(&device_request("debug.hap", "idem-rust-debug-0001"))
        .unwrap_err();
    assert_eq!(
        (refusal.code, refusal.message.as_str()),
        (
            "rejected",
            "debug.hap@1 is not materialized by the Rust Runtime yet"
        )
    );
    // Swift's daemon without an HDC registration: no provider plans it.
    let refusal = planner
        .handle(&device_request("observe.device", "idem-rust-observe-0001"))
        .unwrap_err();
    assert_eq!(
        (refusal.code, refusal.message.as_str()),
        ("invalidInput", "provider hdc is not registered")
    );
    let import = format!(
        "lease-v1:imp-{}:ART-{}",
        "0123abcd-4567-89ef-0123-456789abcdef",
        "0".repeat(32)
    );
    let refusal = planner
        .handle(&planned_request(&import, "idem-rust-import-0001"))
        .unwrap_err();
    assert_eq!(
        (refusal.code, refusal.message.as_str()),
        (
            "invalidInput",
            "Import input owner is unavailable"
        )
    );
    let index: Value = serde_json::from_slice(
        &fs::read(root.join("artifacts").join(SOURCE_JOB).join("index.json")).unwrap(),
    )
    .unwrap();
    let artifact = index["artifacts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["name"] == "crash-log.txt")
        .unwrap()["artifactID"]
        .as_str()
        .unwrap()
        .to_owned();
    let lease = format!("lease-v1:{SOURCE_JOB}:{artifact}");
    assert!(
        planner
            .handle(&planned_request(&lease, "idem-rust-permit-0001"))
            .is_ok()
    );
    let permits = root.join("runtime-debug-attempts");
    fs::create_dir(&permits).unwrap();
    fs::write(permits.join("idem-rust-permit-0001.json"), b"{}").unwrap();
    let refusal = planner
        .handle(&planned_request(&lease, "idem-rust-permit-0001"))
        .unwrap_err();
    assert_eq!(
        (refusal.code, refusal.message.as_str()),
        (
            "rejected",
            "a Runtime debug attempt permit is not read by the Rust Runtime yet"
        )
    );
    fs::remove_dir_all(&root).unwrap();
}
