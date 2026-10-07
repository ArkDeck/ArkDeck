//! A separately recorded, published-c6 software response to the original
//! Native reconcile requests. No provider is executed and no old byte is edited.
use super::{catalog_lineage, debug_hap, document, reconcile::Daemon};
use arkdeck_contract::{CATALOG_DIGEST, sha256_hex};
use arkdeck_hoststore::OperationRequest;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;

pub const NAME: &str = "device-mutation-reconcile-native-published-c6-v4";
const SOURCE: &str = "device-mutation-reconcile/nativeLibrary";
const CASES_SHA: &str = "b26bda6e6f6ee57e1890d492cb8c409e6a005acfa02e13d5049019e179767e5e";
const PROVENANCE_SHA: &str = "736dd3012a56d74b6bb83b0bb4f9767dcc36b711ebc4921b064417176e520413";
const CAPSULE_SHA: &str = "06e3ce9a79c7826f850f6d0a194ff1e443edcaa6b0a2ddb8c841e1a70b3cdc3b";
const POLICY_SHA: &str = "2d892e3777e750efd5ffa02044296ea83c4308dd6a80f696525133453f268041";
const CANONICAL_ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const INPUT_PATH: &str =
    "root/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397";
const INPUT_NAME: &str = "ART-469c10579b3c5461ab4d0a891c316397";
const INPUT_SHA: &str = "f8cd1ccd46071323e6b3b8e1a6b2246b7b4ea5d5f71d6ea9990e33ec722f5b53";
const INPUT_SIZE: u64 = 588;
const HOST_FILES: [&str; 3] = ["hdc-answers.sh", "hdc-invocations.log", "hdc-mode"];
const STEPS: [&str; 7] = [
    "published.run",
    "restart",
    "reconcilePublished",
    "published.resume",
    "unpublished.run",
    "secondRestart",
    "reconcileUnpublished",
];

fn write_new(path: &Path, bytes: &[u8]) {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .unwrap();
    file.write_all(bytes).unwrap();
    file.sync_all().unwrap();
}

fn json_bytes(value: &Value) -> Vec<u8> {
    arkdeck_contract::foundation_json::pretty(value, true).unwrap()
}

fn source() -> (Value, Value) {
    assert_eq!(
        CATALOG_DIGEST,
        catalog_lineage::OLD,
        "only the published c6 input view"
    );
    let fixture = super::fixture(SOURCE);
    assert_eq!(
        sha256_hex(&fs::read(fixture.join("cases.json")).unwrap()),
        CASES_SHA
    );
    assert_eq!(
        sha256_hex(&fs::read(fixture.join("provenance.json")).unwrap()),
        PROVENANCE_SHA
    );
    let provenance = document(&fixture, "provenance.json");
    let pins = provenance["files"].as_object().unwrap();
    assert_eq!(pins.len(), 88);
    let actual = debug_hap::tree_bytes(&fixture);
    assert_eq!(actual.len(), 89);
    for (path, bytes) in actual {
        let name = path
            .components()
            .map(|part| part.as_os_str().to_str().unwrap())
            .collect::<Vec<_>>()
            .join("/");
        if name != "provenance.json" {
            assert_eq!(
                pins[&name],
                sha256_hex(&bytes),
                "whole original source {name}"
            );
        }
    }
    let cases = document(&fixture, "cases.json");
    assert_eq!(cases["exchanges"].as_array().unwrap().len(), 22);
    assert_eq!(cases["steps"], json!(STEPS));
    (cases, provenance)
}

/// Every real file and directory, plus the full logical SQLite schema/rows.
/// SQLite's physical page/WAL spelling is not an oracle document; no logical
/// index column or any other file is excluded.
fn snapshot(daemon: &Daemon) -> Value {
    let mut files = BTreeMap::new();
    let mut tree = Vec::new();
    super::walk(&daemon.root, "root", &mut files, &mut tree);
    for name in [
        "root/store/runtime-jobs.sqlite3",
        "root/store/runtime-jobs.sqlite3-wal",
        "root/store/runtime-jobs.sqlite3-shm",
    ] {
        files.remove(name);
        tree.retain(|(path, _, _)| path != name);
    }
    let files: BTreeMap<_, _> = files
        .into_keys()
        .map(|path| {
            // Keep original host bytes until their seal and index are verified.
            let bytes = fs::read(daemon.root.join(path.strip_prefix("root/").unwrap())).unwrap();
            (path, json!({"sha256": sha256_hex(&bytes), "bytes": bytes}))
        })
        .collect();
    // The generic Windows tree reader proves owner read/write, so it refuses
    // a correctly sealed read-only input. Retain that original observation;
    // this independent full-byte/private/single-link/sealed proof is the only
    // reason the one exact input role may project to Unix mode 0400.
    let directory = arkdeck_platform::HostDirectory::open(
        &daemon.root.join("artifacts/job-input-native-library"),
    )
    .unwrap();
    assert!(
        directory
            .verify_cached_payload(INPUT_NAME, INPUT_SIZE, INPUT_SHA, None)
            .unwrap()
            .is_some(),
        "the original copied Native input must really be sealed"
    );
    json!({"index": super::index(&daemon.default_root), "files": files, "tree": tree,
        "sealedPayload": {"path": INPUT_PATH, "byteCount": INPUT_SIZE, "sha256": INPUT_SHA, "verified": true}})
}

fn answer(daemon: &mut Daemon, exchange: &Value) -> Value {
    if exchange["method"] == "recoverActiveJobs" {
        return json!(daemon.restart().statuses);
    }
    if exchange["method"] == "job.run" {
        for state in exchange["cleared"].as_array().into_iter().flatten() {
            let path = state.as_str().unwrap();
            assert!(Path::new(path).components().count() == 1);
            let _ = fs::remove_file(daemon.root.join(path));
        }
    }
    // Its default mutation_identity_current is false. Missing preflight
    // must refuse before identity checking, consumption or any HDC call.
    daemon.answer(&debug_hap::NoDispatch, exchange)
}

fn proof(daemon: &Daemon, answers: &[Value]) -> Value {
    assert!(daemon.calls().is_empty(), "zero transport dispatch");
    let cases = document(&daemon.fixture, "cases.json");
    let mut proofs = Vec::new();
    for prefix in ["published", "unpublished"] {
        let accepted = answers
            .iter()
            .find(|row| row["name"] == format!("{prefix}.submit"))
            .unwrap();
        assert_eq!(accepted["answer"]["ok"], true);
        assert_eq!(accepted["answer"]["result"]["deduplicated"], false);
        assert_eq!(accepted["answer"]["result"]["newDispatchCount"], 0);
        let id = accepted["answer"]["result"]["jobId"].as_str().unwrap();
        let record = document(&daemon.default_root, &format!("jobs/{id}/job-record.json"));
        let request = cases["exchanges"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["name"] == format!("{prefix}.submit"))
            .unwrap()["params"]["requestJson"]
            .as_str()
            .unwrap();
        assert_eq!(
            record["originalSubmissionRequest"],
            OperationRequest::decode(request.as_bytes())
                .unwrap()
                .canonical_value()
        );
        assert_eq!(record["catalogDigest"], catalog_lineage::OLD);
        assert_eq!(record["state"], "failed");
        assert_eq!(record["outcomeUnknown"], false);
        assert!(record.get("evidenceObservation").is_none_or(Value::is_null));
        assert!(record.get("runtimeCapability").is_none_or(Value::is_null));
        assert!(
            record
                .get("outstandingResidueCount")
                .is_none_or(|count| count == 0)
        );
        assert!(record["timeline"].as_array().unwrap().iter().any(|line| line == "reason: evidenceIncomplete: three-step typed preflight is incomplete before send-to-staging"));
        let marker = &record["sessionPublicationRecord"];
        assert_eq!(marker["phase"], "catalogPublished");
        let manifest = fs::read(
            daemon
                .root
                .join("Sessions")
                .join(marker["relativeSessionPath"].as_str().unwrap())
                .join("manifest.json"),
        )
        .unwrap();
        assert_eq!(sha256_hex(&manifest), marker["receipt"]["manifestSHA256"]);
        let manifest: Value = serde_json::from_slice(&manifest).unwrap();
        assert_eq!(manifest["jobId"], id);
        assert_eq!(manifest["sessionId"], marker["sessionID"]);
        assert_eq!(manifest["status"], "failed");
        assert!(manifest.get("runtimeAuthority").is_none());
        assert!(manifest.get("device").is_none());
        let journal: Vec<Value> = fs::read_to_string(
            daemon
                .default_root
                .join("jobs")
                .join(id)
                .join("journal.jsonl"),
        )
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
        assert!(journal.iter().all(|row| row["jobId"] == id));
        assert_eq!(
            journal
                .iter()
                .filter(|row| row["kind"] == "finalized")
                .count(),
            1
        );
        assert!(
            journal
                .iter()
                .all(|row| row["kind"] != "runtimeCapabilityConsumed"
                    && row["kind"] != "compensationIntent"
                    && (row["kind"] != "stepIntent"
                        || !matches!(
                            row["payload"]["step"]["effect"].as_str(),
                            Some("deviceMutation" | "destructive")
                        )))
        );
        let shown = daemon
            .stores()
            .sessions
            .handle_resource(
                "session.show",
                json!({"sessionId": marker["sessionID"]})
                    .as_object()
                    .unwrap(),
            )
            .unwrap();
        super::hdc_oracle::assert_conforms("session.show", &json!({"ok": true, "result": shown}));
        assert_eq!(shown["sessionId"], marker["sessionID"]);
        let catalog = document(&daemon.root, "Sessions/.arkdeck-retention-catalog.json");
        assert_eq!(
            shown["generation"],
            catalog["generation"].as_u64().unwrap().to_string()
        );
        assert!(
            marker["receipt"]["catalogGeneration"]
                .as_str()
                .unwrap()
                .parse::<u64>()
                .unwrap()
                <= catalog["generation"].as_u64().unwrap()
        );
        let session_files = debug_hap::tree_bytes(
            &daemon
                .root
                .join("Sessions")
                .join(marker["relativeSessionPath"].as_str().unwrap()),
        );
        let total: usize = session_files.values().map(Vec::len).sum();
        assert_eq!(shown["sizeBytes"], total.to_string());
        proofs.push(json!({"jobId": id, "state": record["state"], "manifest": manifest, "journal": journal,
            "sessionShow": shown, "manifestSha256": marker["receipt"]["manifestSHA256"],
            "manifestByteCount": session_files[Path::new("manifest.json")].len(), "sessionFileCount": session_files.len(), "sessionByteCount": total}));
    }
    let capabilities = document(
        &daemon.default_root,
        "capabilities/runtime-capabilities.json",
    );
    // Full documents are retained below, not replaced by this count.
    let records = capabilities["records"].as_array().unwrap();
    assert_eq!(records.len(), 1);
    assert!(
        records
            .iter()
            .all(|record| record["consumptions"].as_array().unwrap().is_empty())
    );
    let fresh_id = records[0]["capability"]["capabilityID"].as_str().unwrap();
    let fresh_inspection = daemon
        .stores()
        .capabilities
        .handle(
            "capability.inspect",
            json!({"capabilityId": fresh_id}).as_object().unwrap(),
        )
        .unwrap();
    json!({"jobs": proofs, "transportCalls": 0, "consumptions": 0,
        "capabilityCheckpoint": capabilities, "freshCapabilityInspection": fresh_inspection})
}

/// Only this current oracle's freshly rebuilt copies use deterministic private
/// modes. Shared legacy creators and every original fixture stay untouched.
fn prepare_current_host_files(daemon: &Daemon) {
    assert_eq!(
        fs::read(daemon.root.join("hdc-invocations.log")).unwrap(),
        b""
    );
    write_new(&daemon.root.join("hdc-mode"), b"normal\n");
    let original = fs::read(daemon.fixture.join("hdc-answers.sh")).unwrap();
    assert_eq!(
        sha256_hex(&original),
        daemon.provenance["files"]["hdc-answers.sh"]
    );
    for name in HOST_FILES {
        let path = daemon.root.join(name);
        assert!(fs::symlink_metadata(&path).unwrap().file_type().is_file());
        super::fixture_fs::owner_only(&path);
        assert_eq!(super::oracle_mode(&path, false), "600");
    }
    assert_eq!(
        fs::read(daemon.root.join("hdc-answers.sh")).unwrap(),
        original
    );
}

fn execute(output: Option<&Path>) -> Value {
    let (source_cases, provenance) = source();
    let mut daemon = Daemon::open(SOURCE);
    prepare_current_host_files(&daemon);
    let mut answers = Vec::new();
    let mut snapshots = BTreeMap::new();
    for exchange in source_cases["exchanges"].as_array().unwrap() {
        let actual = answer(&mut daemon, exchange);
        let name = exchange["name"].as_str().unwrap();
        answers.push(json!({"name": name, "method": exchange["method"], "params": exchange.get("params"), "answer": actual}));
        if let Some(output) = output {
            write_new(
                &output.join(format!("answer-{:02}.json", answers.len())),
                &json_bytes(answers.last().unwrap()),
            );
        }
        if STEPS.contains(&name) {
            assert!(
                snapshots
                    .insert(name.to_owned(), snapshot(&daemon))
                    .is_none()
            );
            if let Some(output) = output {
                write_new(
                    &output.join(format!("snapshot-{name}.json")),
                    &json_bytes(&snapshots[name]),
                );
            }
        }
    }
    assert_eq!(snapshots.len(), 7);
    let safety = proof(&daemon, &answers);
    daemon.close();
    let final_store = snapshot(&daemon);
    json!({"schemaVersion": "arkdeck.native-reconcile-software-oracle/1", "catalogDigest": CATALOG_DIGEST,
        "sourceCasesSha256": CASES_SHA, "sourceProvenanceSha256": PROVENANCE_SHA,
        "sourceFiles": provenance["files"], "sourceCases": source_cases,
        "sourceRoot": daemon.root.to_str().unwrap(), "platformProfile": if cfg!(windows) {"PLATFORM-WINDOWS@0.2.0"} else {"PLATFORM-MACOS@0.2.0"}, "hardwareEvidence": false,
        "answers": answers, "snapshots": snapshots, "finalStore": final_store, "safety": safety})
}

fn bytes(value: &Value) -> Vec<u8> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|byte| u8::try_from(byte.as_u64().unwrap()).unwrap())
        .collect()
}

fn compact(value: &Value) -> Vec<u8> {
    catalog_lineage::plan_bytes(value).unwrap()
}

/// Preserve the exact actual encoder, not just decoded JSON equality.
fn encoded_like(value: &Value, original: &[u8]) -> Vec<u8> {
    let before: Value = serde_json::from_slice(original).unwrap();
    if *value == before {
        return original.to_vec();
    }
    if compact(&before) == original {
        return compact(value);
    }
    for slash in [true, false] {
        if arkdeck_contract::foundation_json::pretty(&before, slash).unwrap() == original {
            return arkdeck_contract::foundation_json::pretty(value, slash).unwrap();
        }
    }
    if let Some(body) = original.strip_suffix(b"\n") {
        if compact(&before) == body {
            return compact(value).into_iter().chain(*b"\n").collect();
        }
        for slash in [true, false] {
            if arkdeck_contract::foundation_json::pretty(&before, slash).unwrap() == body {
                return arkdeck_contract::foundation_json::pretty(value, slash)
                    .unwrap()
                    .into_iter()
                    .chain(*b"\n")
                    .collect();
            }
        }
    }
    panic!("unreviewed oracle document encoding");
}

struct Projection {
    root: String,
    platform: String,
    hashes: BTreeMap<String, String>,
    names: BTreeMap<String, String>,
    host_plan: String,
}

impl Projection {
    fn new(root: &str, platform: &str) -> Self {
        assert!(["PLATFORM-MACOS@0.2.0", "PLATFORM-WINDOWS@0.2.0"].contains(&platform));
        let separator = if platform == "PLATFORM-WINDOWS@0.2.0" {
            '\\'
        } else {
            '/'
        };
        if separator == '\\' {
            assert!(
                root.as_bytes().first().is_some_and(u8::is_ascii_alphabetic)
                    && root.as_bytes().get(1..3) == Some(b":\\")
            );
        } else {
            assert!(root.starts_with('/'));
        }
        assert!(!root.ends_with(separator));
        assert!(
            root.split(separator)
                .all(|component| component != "." && component != "..")
        );
        let path = super::fixture("catalog-lineage-c6-e4/native-reconcile-c6-plan.json");
        let raw = fs::read(path).unwrap();
        assert_eq!(sha256_hex(&raw), CAPSULE_SHA);
        let packet: Value = serde_json::from_slice(&raw).unwrap();
        assert_eq!(packet.as_object().unwrap().len(), 10);
        assert_eq!(
            packet["schemaVersion"],
            "arkdeck.test-native-reconcile-plan/1"
        );
        assert_eq!(packet["catalogDigest"], catalog_lineage::OLD);
        assert_eq!(packet["sourceCasesSha256"], CASES_SHA);
        assert_eq!(packet["sourceProvenanceSha256"], PROVENANCE_SHA);
        assert_eq!(packet["sourceRoot"], CANONICAL_ROOT);
        let cases = document(&super::fixture(SOURCE), "cases.json");
        assert_eq!(packet["rows"].as_array().unwrap().len(), 3);
        for row in packet["rows"].as_array().unwrap() {
            let exchange = cases["exchanges"]
                .as_array()
                .unwrap()
                .iter()
                .find(|exchange| exchange["name"] == row["case"])
                .unwrap();
            assert_eq!(row["requestJson"], exchange["params"]["requestJson"]);
            let request =
                OperationRequest::decode(row["requestJson"].as_str().unwrap().as_bytes()).unwrap();
            assert_eq!(
                packet["completePlan"]["inputs"],
                request.canonical_value()["inputs"]
            );
            assert_eq!(packet["completePlan"]["targetID"], request.target_id);
        }
        let canonical = sha256_hex(&compact(&packet["completePlan"]));
        assert_eq!(canonical, packet["planSha256"]);
        assert_eq!(
            canonical,
            "b60595abb20fc9f86c2e570f31bbf16803b3a95dea1996c037abbd4ad6a6aab3"
        );
        assert_eq!(
            packet["originalNativeCasesSha256"],
            sha256_hex(&fs::read(super::fixture("deploy-native-library/cases.json")).unwrap())
        );
        assert_eq!(
            packet["catalogLineagePacketSha256"],
            sha256_hex(&fs::read(super::fixture("catalog-lineage-c6-e4/catalogs.json")).unwrap())
        );
        fn host_plan(value: &Value, root: &str, separator: char) -> Value {
            match value {
                Value::String(text) if text.starts_with(&format!("{CANONICAL_ROOT}/")) => {
                    let suffix = &text[CANONICAL_ROOT.len() + 1..];
                    assert!(suffix.split('/').all(|part| !part.is_empty()
                        && part != "."
                        && part != ".."
                        && !part.contains(['\\', ':'])));
                    json!(format!(
                        "{root}{separator}{}",
                        suffix.replace('/', &separator.to_string())
                    ))
                }
                Value::Array(values) => Value::Array(
                    values
                        .iter()
                        .map(|value| host_plan(value, root, separator))
                        .collect(),
                ),
                Value::Object(fields) => Value::Object(
                    fields
                        .iter()
                        .map(|(key, value)| (key.clone(), host_plan(value, root, separator)))
                        .collect(),
                ),
                _ => value.clone(),
            }
        }
        let host = host_plan(&packet["completePlan"], root, separator);
        let host_plan = sha256_hex(&compact(&host));
        let raw = fs::read(super::fixture(
            "catalog-lineage-c6-e4/native-reconcile-c6-policy.json",
        ))
        .unwrap();
        assert_eq!(sha256_hex(&raw), POLICY_SHA);
        let policy: Value = serde_json::from_slice(&raw).unwrap();
        assert_eq!(policy["sourceCasesSha256"], CASES_SHA);
        assert_eq!(policy["sourceProvenanceSha256"], PROVENANCE_SHA);
        assert_eq!(
            policy["schemaVersion"],
            "arkdeck.test-native-reconcile-policy/1"
        );
        assert_eq!(policy["sessionScoped"], false);
        assert_eq!(policy["recovery"], Value::Null);
        assert_eq!(policy["query"].as_object().unwrap().len(), 11);
        let query = &policy["query"];
        assert_eq!(query["inputs"], packet["completePlan"]["inputs"]);
        assert_eq!(query["planDigest"], canonical);
        assert_eq!(
            query["targetStableIdentitySha256"],
            packet["completePlan"]["stableTargetIdentitySHA256"]
        );
        assert_eq!(
            query["targetBindingRevision"],
            packet["completePlan"]["bindingRevision"]
        );
        assert_eq!(query["effect"], "deviceMutation");
        assert_eq!(query["operationId"], "deploy.native-library.app-owned");
        assert_eq!(query["operationVersion"], 1);
        for key in [
            "workspaceFileScopesDigest",
            "workspaceIdentitySha256",
            "workspaceRevision",
        ] {
            assert_eq!(query[key], Value::Null);
        }
        let source_artifact = super::fixture(
            "device-mutation-reconcile/nativeLibrary/artifacts/job-input-native-library/ART-469c10579b3c5461ab4d0a891c316397",
        );
        let artifact_bytes = fs::read(source_artifact).unwrap();
        assert_eq!(
            query["artifactFacts"],
            json!({"artifactByteCount": artifact_bytes.len().to_string(), "artifactId": "ART-469c10579b3c5461ab4d0a891c316397", "artifactSha256": sha256_hex(&artifact_bytes)})
        );
        let scope = |plan: &str| {
            let mut lines = vec![
                format!(
                    "operation={}@{}",
                    query["operationId"].as_str().unwrap(),
                    query["operationVersion"]
                ),
                format!("effect={}", query["effect"].as_str().unwrap()),
                format!(
                    "target={}",
                    query["targetStableIdentitySha256"].as_str().unwrap()
                ),
                format!("bindingRevision={}", query["targetBindingRevision"]),
                format!("planDigest={plan}"),
                format!(
                    "inputs={}",
                    String::from_utf8(compact(&query["inputs"])).unwrap()
                ),
            ];
            lines.extend(
                query["artifactFacts"]
                    .as_object()
                    .unwrap()
                    .iter()
                    .map(|(key, value)| format!("artifact.{key}={}", value.as_str().unwrap())),
            );
            lines.join("\n")
        };
        assert_eq!(policy["scopeMaterial"], scope(&canonical));
        let material = |plan: &str| {
            format!(
                "{}\n{}\nordinary",
                catalog_lineage::OLD,
                sha256_hex(scope(plan).as_bytes())
            )
        };
        assert_eq!(policy["policyMaterial"], material(&canonical));
        let fingerprint = sha256_hex(material(&canonical).as_bytes()).to_uppercase();
        assert_eq!(policy["policyFingerprint"], fingerprint);
        let canonical_id = format!("CAP-RT-POLICY-{}-G1", &fingerprint[..40]);
        assert_eq!(policy["capabilityId"], canonical_id);
        let host_id = format!(
            "CAP-RT-POLICY-{}-G1",
            &sha256_hex(material(&host_plan).as_bytes()).to_uppercase()[..40]
        );
        Self {
            root: root.into(),
            platform: platform.into(),
            hashes: BTreeMap::from([(host_plan.clone(), canonical)]),
            names: BTreeMap::from([(host_id, canonical_id)]),
            host_plan,
        }
    }

    fn value(&self, value: &Value) -> Value {
        match value {
            Value::String(text) => {
                if let Some(hash) = self.hashes.get(text) {
                    return json!(hash);
                }
                if let Some(name) = self.names.get(text) {
                    return json!(name);
                }
                if text == &self.platform {
                    return json!("PLATFORM-MACOS@0.2.0");
                }
                if text == &self.root {
                    return json!(CANONICAL_ROOT);
                }
                let separator = if self.root.contains('\\') { '\\' } else { '/' };
                let foundation = self
                    .root
                    .strip_prefix("/private/")
                    .map(|rest| format!("/{rest}/Sessions"));
                if foundation.as_ref() == Some(text)
                    || text == &format!("{}{separator}Sessions", self.root)
                {
                    return json!("/tmp/arkdeck-hdc-oracle/Sessions");
                }
                if let Some(suffix) = text.strip_prefix(&format!("{}{separator}", self.root)) {
                    let components: Vec<_> = suffix.split(separator).collect();
                    assert!(
                        components
                            .iter()
                            .all(|part| !part.is_empty() && *part != "." && *part != "..")
                    );
                    return json!(format!("{CANONICAL_ROOT}/{}", components.join("/")));
                }
                value.clone()
            }
            Value::Array(values) => {
                Value::Array(values.iter().map(|value| self.value(value)).collect())
            }
            Value::Object(fields) => Value::Object(
                fields
                    .iter()
                    .map(|(key, value)| (key.clone(), self.value(value)))
                    .collect(),
            ),
            _ => value.clone(),
        }
    }

    fn file(&self, original: &[u8]) -> Vec<u8> {
        if original.is_empty() {
            return Vec::new();
        }
        if let Ok(value) = serde_json::from_slice::<Value>(original) {
            return encoded_like(&self.value(&value), original);
        }
        if original.last() == Some(&b'\n') {
            let lines: Option<Vec<Value>> = original[..original.len() - 1]
                .split(|byte| *byte == b'\n')
                .map(|line| serde_json::from_slice(line).ok())
                .collect();
            if let Some(lines) = lines {
                return lines
                    .iter()
                    .flat_map(|line| compact(&self.value(line)).into_iter().chain(*b"\n"))
                    .collect();
            }
        }
        original.to_vec()
    }
}

fn canonical(raw: &Value) -> Value {
    assert_fixed_policy_read(raw);
    let mut projection = Projection::new(
        raw["sourceRoot"].as_str().unwrap(),
        raw["platformProfile"].as_str().unwrap(),
    );
    let mut result = raw.clone();
    for snapshot in result["snapshots"].as_object_mut().unwrap().values_mut() {
        *snapshot = project_snapshot(snapshot, &mut projection);
    }
    result["finalStore"] = project_snapshot(&result["finalStore"], &mut projection);
    result["answers"] = projection.value(&result["answers"]);
    result["safety"] = projection.value(&result["safety"]);
    let normalized_store = result["finalStore"].clone();
    for (raw_job, job) in raw["safety"]["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .zip(result["safety"]["jobs"].as_array_mut().unwrap())
    {
        let id = raw_job["jobId"].as_str().unwrap();
        let record_path = format!("root/store/jobs/{id}/job-record.json");
        let record: Value =
            serde_json::from_slice(&bytes(&raw["finalStore"]["files"][&record_path]["bytes"]))
                .unwrap();
        let prefix = format!(
            "root/Sessions/{}/",
            record["sessionPublicationRecord"]["relativeSessionPath"]
                .as_str()
                .unwrap()
        );
        let originals = raw["finalStore"]["files"]
            .as_object()
            .unwrap()
            .iter()
            .filter(|(path, _)| path.starts_with(&prefix))
            .collect::<Vec<_>>();
        let normalized = normalized_store["files"]
            .as_object()
            .unwrap()
            .iter()
            .filter(|(path, _)| path.starts_with(&prefix))
            .collect::<Vec<_>>();
        assert_eq!(originals.len(), normalized.len());
        assert_eq!(raw_job["sessionFileCount"], originals.len());
        let original_count: usize = originals
            .iter()
            .map(|(_, file)| bytes(&file["bytes"]).len())
            .sum();
        let count: usize = normalized
            .iter()
            .map(|(_, file)| bytes(&file["bytes"]).len())
            .sum();
        assert_eq!(raw_job["sessionByteCount"], original_count);
        assert_eq!(
            raw_job["sessionShow"]["sizeBytes"],
            original_count.to_string()
        );
        let manifest_path = format!("{prefix}manifest.json");
        let original_manifest = bytes(&raw["finalStore"]["files"][&manifest_path]["bytes"]);
        assert_eq!(raw_job["manifestSha256"], sha256_hex(&original_manifest));
        assert_eq!(raw_job["manifestByteCount"], original_manifest.len());
        assert_eq!(
            raw_job["manifest"],
            serde_json::from_slice::<Value>(&original_manifest).unwrap()
        );
        let manifest = bytes(&normalized_store["files"][&manifest_path]["bytes"]);
        job["manifestSha256"] = json!(sha256_hex(&manifest));
        job["manifestByteCount"] = json!(manifest.len());
        job["sessionByteCount"] = json!(count);
        job["sessionShow"]["sizeBytes"] = json!(count.to_string());
    }
    result["sourceRoot"] = json!(CANONICAL_ROOT);
    result["platformProfile"] = json!("PLATFORM-MACOS@0.2.0");
    result
}

/// The original #22 address is immutable. A Windows host-path-derived policy
/// may not have that address; its real refusal is kept, never relabeled success.
fn assert_fixed_policy_read(raw: &Value) {
    let projection = Projection::new(
        raw["sourceRoot"].as_str().unwrap(),
        raw["platformProfile"].as_str().unwrap(),
    );
    let checkpoint = &raw["safety"]["capabilityCheckpoint"];
    let final_checkpoint: Value = serde_json::from_slice(&bytes(
        &raw["finalStore"]["files"]["root/store/capabilities/runtime-capabilities.json"]["bytes"],
    ))
    .unwrap();
    assert_eq!(*checkpoint, final_checkpoint);
    let records = checkpoint["records"].as_array().unwrap();
    assert_eq!(records.len(), 1);
    let record = &records[0];
    assert!(record["consumptions"].as_array().unwrap().is_empty());
    let id = record["capability"]["capabilityID"].as_str().unwrap();
    assert_eq!(
        projection.names.keys().next().unwrap(),
        id,
        "entire capsule-derived fresh policy identity"
    );
    let status = json!({"capability": record["capability"], "remainingUses": record["remainingUses"], "consumptionCount": 0, "lineageAllowsNewExecution": true, "lineage": []});
    assert_eq!(raw["safety"]["freshCapabilityInspection"], status);
    let rows = raw["answers"].as_array().unwrap();
    assert_eq!(rows.len(), 22);
    let last = &rows[21];
    let source = document(&super::fixture(SOURCE), "cases.json");
    let original = &source["exchanges"][21];
    assert_eq!(last["name"], "capabilities.inspect0");
    assert_eq!(last["method"], original["method"]);
    assert_eq!(last["params"], original["params"]);
    let requested = last["params"]["capabilityId"].as_str().unwrap();
    assert_eq!(
        projection.names.values().next().unwrap(),
        requested,
        "fixed original c6 policy address"
    );
    if requested == id {
        assert_eq!(last["answer"], json!({"ok": true, "result": status}));
    } else {
        // CapabilityStore::handle uses notFound here; the complete daemon
        // answer contains no fabricated dispatch field or error details.
        assert_eq!(
            last["answer"],
            json!({"ok": false, "error": {"code": "notFound", "message": "unknown capability"}})
        );
    }
    assert_eq!(raw["safety"]["transportCalls"], 0);
}

fn comparison(raw: &Value) -> Value {
    let mut result = canonical(raw);
    // This one known, independently proved address-dependent branch is checked
    // above in full, beside the other 21 whole-envelope equality assertions.
    // Both raw and canonical recordings retain its complete actual answer.
    result["answers"][21]["answer"] =
        json!({"checkedFixedPolicyLookup": "source-bound-c6-native-policy"});
    result
}

fn project_snapshot(snapshot: &Value, projection: &mut Projection) -> Value {
    let files = snapshot["files"].as_object().unwrap();
    let mut originals = BTreeMap::new();
    for (path, entry) in files {
        let content = bytes(&entry["bytes"]);
        assert_eq!(
            sha256_hex(&content),
            entry["sha256"],
            "complete raw file {path}"
        );
        originals.insert(path.clone(), content);
    }
    let mut projected = BTreeMap::new();
    let cap_path = "root/store/capabilities/runtime-capabilities.json";
    if let Some(content) = originals.get(cap_path) {
        let capabilities: Value = serde_json::from_slice(content).unwrap();
        for record in capabilities["records"].as_array().unwrap() {
            assert!(
                projection
                    .names
                    .contains_key(record["capability"]["capabilityID"].as_str().unwrap()),
                "complete fresh policy must match its material capsule"
            );
            assert!(record["consumptions"].as_array().unwrap().is_empty());
        }
    }
    for (path, content) in &originals {
        if path.ends_with("/manifest.json") && path.starts_with("root/Sessions/") {
            let manifest: Value = serde_json::from_slice(content).unwrap();
            assert_eq!(manifest["platformProfile"], projection.platform);
            let canonical = projection.file(content);
            projection
                .hashes
                .insert(sha256_hex(content), sha256_hex(&canonical));
        }
    }
    let mut index = snapshot["index"].clone();
    for row in index["rows"].as_array_mut().unwrap() {
        let id = row["jobId"].as_str().unwrap();
        let path = format!("root/store/jobs/{id}/job-record.json");
        let content = &originals[&path];
        assert_eq!(
            row["recordSHA256"],
            sha256_hex(&super::machine_independent(content)),
            "complete actual replay-index record {id}"
        );
        let record: Value = serde_json::from_slice(content).unwrap();
        arkdeck_hoststore::JobRecord::decode(content).unwrap();
        assert_eq!(record["jobID"], id);
        assert_eq!(row["state"], record["state"]);
        assert_eq!(row["createdAtUTC"], record["createdAtUTC"]);
        assert_eq!(record["catalogDigest"], catalog_lineage::OLD);
        assert_eq!(record["outcomeUnknown"], false);
        let journal = &originals[&format!("root/store/jobs/{id}/journal.jsonl")];
        assert!(journal.ends_with(b"\n"));
        for (sequence, line) in journal[..journal.len() - 1]
            .split(|byte| *byte == b'\n')
            .enumerate()
        {
            let event: Value = serde_json::from_slice(line).unwrap();
            assert_eq!(event["jobId"], id);
            assert_eq!(event["sessionId"], format!("session-{id}"));
            assert_eq!(event["sequence"], sequence);
            assert_ne!(event["kind"], "runtimeCapabilityConsumed");
            assert_ne!(event["kind"], "compensationIntent");
            assert!(
                event["kind"] != "stepIntent"
                    || !matches!(
                        event["payload"]["step"]["effect"].as_str(),
                        Some("deviceMutation" | "destructive")
                    )
            );
        }
        assert_eq!(
            record["materializedPlanDigest"], projection.host_plan,
            "full host plan must match the encoder capsule"
        );
        let canonical_record = project_record(&record, &originals, projection);
        let canonical_bytes = encoded_like(&canonical_record, content);
        row["recordSHA256"] = json!(sha256_hex(&super::machine_independent(&canonical_bytes)));
        projected.insert(path, super::machine_independent(&canonical_bytes));
    }
    for (path, content) in &originals {
        projected
            .entry(path.clone())
            .or_insert_with(|| projection.file(content));
    }
    let mut result = snapshot.clone();
    result["index"] = index;
    result["files"] = json!(
        projected
            .into_iter()
            .map(|(path, content)| (
                path,
                json!({"sha256": sha256_hex(&content), "bytes": content})
            ))
            .collect::<BTreeMap<_, _>>()
    );
    assert_eq!(
        snapshot["sealedPayload"],
        json!({"path": INPUT_PATH, "byteCount": INPUT_SIZE, "sha256": INPUT_SHA, "verified": true}),
        "closed measured seal proof"
    );
    assert_eq!(originals[INPUT_PATH].len() as u64, INPUT_SIZE);
    assert_eq!(sha256_hex(&originals[INPUT_PATH]), INPUT_SHA);
    let windows = projection.platform == "PLATFORM-WINDOWS@0.2.0";
    assert!(windows || projection.platform == "PLATFORM-MACOS@0.2.0");
    let mut roles = [0_u8; 5];
    for entry in result["tree"].as_array_mut().unwrap() {
        let name = entry[0].as_str().unwrap().to_owned();
        if let Some(role) = HOST_FILES
            .iter()
            .position(|leaf| name == format!("root/{leaf}"))
        {
            roles[role + 2] += 1;
            assert_eq!(entry[1], "file");
            assert_eq!(entry[2], "600", "current-only private host file {name}");
            let content = &originals[&name];
            match role {
                0 => assert_eq!(
                    sha256_hex(content),
                    document(&super::fixture(SOURCE), "provenance.json")["files"]["hdc-answers.sh"],
                    "complete original synthetic answers"
                ),
                1 => assert_eq!(content.as_slice(), b"", "zero transport calls"),
                2 => assert_eq!(content.as_slice(), b"normal\n", "actual reset fake mode"),
                _ => unreachable!(),
            }
        }
        if name == "root/hdc" {
            roles[0] += 1;
            assert_eq!(entry[1], "file");
            assert_eq!(entry[2], if windows { "600" } else { "700" });
            assert_eq!(
                sha256_hex(&originals[&name]),
                document(&super::fixture(SOURCE), "provenance.json")["hdcSHA256"]
            );
            entry[2] = json!("700");
        }
        if name == INPUT_PATH {
            roles[1] += 1;
            assert_eq!(entry[1], "file");
            assert_eq!(
                entry[2],
                if windows {
                    "not owner-only: host snapshot refused"
                } else {
                    "400"
                }
            );
            entry[2] = json!("400");
        }
    }
    assert_eq!(roles, [1, 1, 1, 1, 1], "each exact source role occurs once");
    result
}

fn project_record(
    record: &Value,
    originals: &BTreeMap<String, Vec<u8>>,
    projection: &Projection,
) -> Value {
    let mut normalized = projection.value(record);
    let Some(marker) = record.get("sessionPublicationRecord") else {
        return normalized;
    };
    assert_eq!(marker["phase"], "catalogPublished");
    let original_root = marker["root"]["path"].as_str().unwrap();
    let separator = if projection.platform == "PLATFORM-WINDOWS@0.2.0" {
        '\\'
    } else {
        '/'
    };
    let exact_root = format!("{}{separator}Sessions", projection.root);
    let private_alias = (projection.platform == "PLATFORM-MACOS@0.2.0")
        .then(|| {
            projection
                .root
                .strip_prefix("/private/")
                .map(|rest| format!("/{rest}/Sessions"))
        })
        .flatten();
    assert!(
        original_root == exact_root || private_alias.as_deref() == Some(original_root),
        "the original marker must name exactly this source root or its publisher-proven private alias"
    );
    assert_eq!(
        projection.value(&marker["root"]["path"]),
        "/tmp/arkdeck-hdc-oracle/Sessions"
    );
    let id = record["jobID"].as_str().unwrap();
    let session = format!(
        "root/Sessions/{}",
        marker["relativeSessionPath"].as_str().unwrap()
    );
    let manifest = &originals[&format!("{session}/manifest.json")];
    assert_eq!(sha256_hex(manifest), marker["receipt"]["manifestSHA256"]);
    assert_eq!(
        marker["proposal"]["manifestSHA256"],
        marker["receipt"]["manifestSHA256"]
    );
    assert_eq!(
        marker["proposal"]["manifestByteCount"],
        manifest.len().to_string()
    );
    let journal = &originals[&format!("root/store/jobs/{id}/journal.jsonl")];
    assert_eq!(journal, &originals[&format!("{session}/journal.jsonl")]);
    assert_eq!(sha256_hex(journal), marker["journalSeal"]["sha256"]);
    assert_eq!(
        marker["journalSeal"]["byteCount"],
        journal.len().to_string()
    );
    let last_start = journal[..journal.len() - 1]
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |index| index + 1);
    let last: Value = serde_json::from_slice(&journal[last_start..]).unwrap();
    assert_eq!(last["kind"], "finalized");
    assert_eq!(
        last["payload"]["manifestSha256"],
        marker["receipt"]["manifestSHA256"]
    );
    assert_eq!(last["sequence"], marker["journalSeal"]["lastSequence"]);
    let mut checkpoint = record.clone();
    checkpoint
        .as_object_mut()
        .unwrap()
        .remove("sessionPublicationRecord");
    assert_eq!(
        sha256_hex(&json_bytes(&checkpoint)),
        marker["checkpointSeal"]["sha256"]
    );
    assert_eq!(
        marker["checkpointSeal"]["byteCount"],
        last_start.to_string()
    );
    assert_eq!(
        marker["checkpointSeal"]["lastSequence"].as_u64().unwrap() + 1,
        last["sequence"].as_u64().unwrap()
    );
    let canonical_journal = projection.file(journal);
    let canonical_prefix = projection.file(&journal[..last_start]);
    let canonical_manifest = projection.file(manifest);
    let projected_checkpoint = projection.value(&checkpoint);
    let normalized_marker = normalized["sessionPublicationRecord"]
        .as_object_mut()
        .unwrap();
    normalized_marker["checkpointSeal"]["sha256"] =
        json!(sha256_hex(&json_bytes(&projected_checkpoint)));
    normalized_marker["checkpointSeal"]["byteCount"] = json!(canonical_prefix.len().to_string());
    normalized_marker["journalSeal"]["sha256"] = json!(sha256_hex(&canonical_journal));
    normalized_marker["journalSeal"]["byteCount"] = json!(canonical_journal.len().to_string());
    normalized_marker["proposal"]["manifestByteCount"] =
        json!(canonical_manifest.len().to_string());
    let claims = normalized_marker["claims"].as_array_mut().unwrap();
    assert_eq!(claims.len(), 1);
    assert_eq!(
        claims[0]["metadataHeadroomBytes"],
        (last_start.max(1) + 65536).to_string()
    );
    claims[0]["metadataHeadroomBytes"] = json!((canonical_prefix.len().max(1) + 65536).to_string());
    normalized
}

/// An explicit new software recording; uncertain or partial output is retained.
pub fn record(output: &Path) {
    let _lock = debug_hap::exclusive();
    fs::create_dir(output).unwrap();
    let actual = execute(Some(output));
    write_new(&output.join("raw-oracle.json"), &json_bytes(&actual));
    write_new(
        &output.join("oracle.json"),
        &json_bytes(&canonical(&actual)),
    );
    let files: BTreeMap<_, _> = debug_hap::tree_bytes(output)
        .into_iter()
        .map(|(path, bytes)| (path.to_str().unwrap().to_owned(), sha256_hex(&bytes)))
        .collect();
    assert_eq!(files.len(), 31);
    write_new(
        &output.join("provenance.json"),
        &json_bytes(&json!({
            "schemaVersion": "arkdeck.native-reconcile-recording/1", "hardwareEvidence": false,
            "catalogDigest": CATALOG_DIGEST, "sourceCasesSha256": CASES_SHA,
            "sourceProvenanceSha256": PROVENANCE_SHA, "sourceFileCount": 88,
            "planCapsuleSha256": CAPSULE_SHA,
            "policyCapsuleSha256": POLICY_SHA,
            "files": files
        })),
    );
}

pub fn assert_replays() {
    let _lock = debug_hap::exclusive();
    let fixture = super::fixture(NAME);
    let provenance = document(&fixture, "provenance.json");
    assert_eq!(provenance["hardwareEvidence"], false);
    assert_eq!(provenance["catalogDigest"], catalog_lineage::OLD);
    assert_eq!(provenance["sourceCasesSha256"], CASES_SHA);
    assert_eq!(provenance["sourceProvenanceSha256"], PROVENANCE_SHA);
    assert_eq!(provenance["sourceFileCount"], 88);
    let actual_files = debug_hap::tree_bytes(&fixture);
    assert_eq!(actual_files.len(), 32);
    assert_eq!(provenance["files"].as_object().unwrap().len(), 31);
    for (path, bytes) in actual_files {
        if path != Path::new("provenance.json") {
            assert_eq!(
                provenance["files"][path.to_str().unwrap()],
                sha256_hex(&bytes)
            );
        }
    }
    let bytes = fs::read(fixture.join("oracle.json")).unwrap();
    assert_eq!(sha256_hex(&bytes), provenance["files"]["oracle.json"]);
    let expected: Value = serde_json::from_slice(&bytes).unwrap();
    let raw = fs::read(fixture.join("raw-oracle.json")).unwrap();
    assert_eq!(sha256_hex(&raw), provenance["files"]["raw-oracle.json"]);
    assert_eq!(provenance["planCapsuleSha256"], CAPSULE_SHA);
    assert_eq!(provenance["policyCapsuleSha256"], POLICY_SHA);
    let raw_value: Value = serde_json::from_slice(&raw).unwrap();
    for (index, answer) in raw_value["answers"].as_array().unwrap().iter().enumerate() {
        assert_eq!(
            document(&fixture, &format!("answer-{:02}.json", index + 1)),
            *answer
        );
    }
    for (name, snapshot) in raw_value["snapshots"].as_object().unwrap() {
        assert_eq!(
            document(&fixture, &format!("snapshot-{name}.json")),
            *snapshot
        );
    }
    assert_eq!(
        canonical(&raw_value),
        expected,
        "recorded raw-host complete proof"
    );
    let actual = execute(None);
    assert_eq!(
        comparison(&actual),
        comparison(&raw_value),
        "21 complete actual answers, exact fixed-policy read branch, all seven owner snapshots and final tree"
    );
}

/// These are complete-record mutations with matching raw file/index hashes,
/// so a shallow checksum failure cannot masquerade as proof validation.
pub fn assert_rejects_drift() {
    assert_seed_seal_refuses_unsealed_or_linked_bytes();
    let raw = document(&super::fixture(NAME), "raw-oracle.json");
    let baseline = comparison(&raw);
    for leaf in HOST_FILES {
        let name = format!("root/{leaf}");
        let mut wrong_mode = raw.clone();
        let entry = wrong_mode["finalStore"]["tree"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|entry| entry[0] == name)
            .unwrap();
        entry[2] = json!("644");
        assert!(
            std::panic::catch_unwind(|| comparison(&wrong_mode)).is_err(),
            "current host role rejects broader mode: {name}"
        );
        let mut wrong_bytes = raw.clone();
        let file = &mut wrong_bytes["finalStore"]["files"][&name];
        let mut content = bytes(&file["bytes"]);
        if let Some(first) = content.first_mut() {
            *first ^= 1;
        } else {
            content.push(b'x');
        }
        *file = json!({"sha256": sha256_hex(&content), "bytes": content});
        assert!(
            std::panic::catch_unwind(|| comparison(&wrong_bytes)).is_err(),
            "current host role rejects changed bytes with a matching raw hash: {name}"
        );
    }
    fn changed_record(raw: &mut Value, change: impl FnOnce(&mut Value)) {
        let id = raw["safety"]["jobs"][0]["jobId"]
            .as_str()
            .unwrap()
            .to_owned();
        let files = raw["finalStore"]["files"].as_object_mut().unwrap();
        let name = format!("root/store/jobs/{id}/job-record.json");
        let mut record: Value = serde_json::from_slice(&bytes(&files[&name]["bytes"])).unwrap();
        assert_eq!(
            record["sessionPublicationRecord"]["phase"],
            "catalogPublished"
        );
        change(&mut record);
        let content = json_bytes(&record);
        files.insert(
            name,
            json!({"sha256": sha256_hex(&content), "bytes": content}),
        );
        let row = raw["finalStore"]["index"]["rows"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|row| row["jobId"] == record["jobID"])
            .unwrap();
        row["recordSHA256"] = json!(sha256_hex(&super::machine_independent(&content)));
    }
    let mut wrong_plan = raw.clone();
    changed_record(&mut wrong_plan, |record| {
        record["materializedPlanDigest"] = json!("0".repeat(64))
    });
    let mut wrong_checkpoint = raw.clone();
    changed_record(&mut wrong_checkpoint, |record| {
        record["sessionPublicationRecord"]["checkpointSeal"]["sha256"] = json!("0".repeat(64))
    });
    let mut unknown_record_field = raw.clone();
    changed_record(&mut unknown_record_field, |record| {
        record["unreviewedField"] = json!(true)
    });
    let mut wrong_root = raw.clone();
    changed_record(&mut wrong_root, |record| {
        record["sessionPublicationRecord"]["root"]["path"] = json!("/unrelated-owner/Sessions")
    });
    let mut wrong_index = raw.clone();
    wrong_index["finalStore"]["index"]["rows"][0]["recordSHA256"] = json!("0".repeat(64));
    let mut false_lookup = raw.clone();
    false_lookup["answers"][21]["answer"]["unreviewedField"] = json!(true);
    let mut wrong_aggregate = raw.clone();
    wrong_aggregate["safety"]["jobs"][0]["sessionByteCount"] = json!(1);
    let mut wrong_mode = raw.clone();
    let entry = wrong_mode["finalStore"]["tree"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|entry| entry[0] == INPUT_PATH)
        .unwrap();
    entry[2] = json!("600");
    let mut missing_seal = raw.clone();
    missing_seal["finalStore"]
        .as_object_mut()
        .unwrap()
        .remove("sealedPayload");
    let mut false_seal = raw.clone();
    false_seal["finalStore"]["sealedPayload"]["verified"] = json!(false);
    for (name, changed) in [
        ("complete host plan", wrong_plan),
        ("checkpoint seal", wrong_checkpoint),
        ("unknown durable field", unknown_record_field),
        ("raw index correlation", wrong_index),
        ("source-bound Session root", wrong_root),
        ("fixed-address lookup envelope", false_lookup),
        ("whole Session aggregate", wrong_aggregate),
        ("platform-specific sealed mode", wrong_mode),
        ("missing independent seal proof", missing_seal),
        ("false independent seal proof", false_seal),
    ] {
        assert!(
            std::panic::catch_unwind(|| comparison(&changed)).is_err(),
            "{name}"
        );
    }
    if raw["platformProfile"] == "PLATFORM-WINDOWS@0.2.0" {
        let mut foreign_canonical_root = raw.clone();
        changed_record(&mut foreign_canonical_root, |record| {
            record["sessionPublicationRecord"]["root"]["path"] =
                json!("/tmp/arkdeck-hdc-oracle/Sessions")
        });
        assert!(
            std::panic::catch_unwind(|| comparison(&foreign_canonical_root)).is_err(),
            "canonical path is not a Windows source-root relation"
        );
    }
    let mut drift = raw.clone();
    drift["answers"][0]["answer"]["result"]["newDispatchCount"] = json!(1);
    assert!(
        std::panic::catch_unwind(|| assert_eq!(comparison(&drift), baseline)).is_err(),
        "unrelated whole-answer drift"
    );
    let mut extra = raw.clone();
    extra["finalStore"]["files"]["root/unreviewed-extra"] =
        json!({"sha256": sha256_hex(b"extra"), "bytes": b"extra"});
    assert!(
        std::panic::catch_unwind(|| assert_eq!(comparison(&extra), baseline)).is_err(),
        "unknown complete-tree member"
    );
}

/// This exercises the real portable permission reader in task-private files,
/// independently of any recorded Boolean or tree spelling. A writable copy
/// never produces a sealed proof; a linked payload is refused before any
/// proof can escape. Windows correctly prevents linking the sealed specimen.
fn assert_seed_seal_refuses_unsealed_or_linked_bytes() {
    let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
    let root =
        super::fixture_fs::temporary_root().join(format!("native-reconcile-seal-{nonce:032x}"));
    super::fixture_fs::private_dir(&root);
    let source =
        fs::read(super::fixture(SOURCE).join(INPUT_PATH.strip_prefix("root/").unwrap())).unwrap();
    assert_eq!(source.len() as u64, INPUT_SIZE);
    assert_eq!(sha256_hex(&source), INPUT_SHA);
    fs::write(root.join(INPUT_NAME), &source).unwrap();
    super::fixture_fs::owner_only(&root.join(INPUT_NAME));
    let directory = arkdeck_platform::HostDirectory::open(&root).unwrap();
    assert!(
        directory
            .verify_cached_payload(INPUT_NAME, INPUT_SIZE, INPUT_SHA, None)
            .unwrap()
            .is_none(),
        "owner-writable bytes are not sealed"
    );
    directory.seal_document(INPUT_NAME).unwrap();
    assert!(
        directory
            .verify_cached_payload(INPUT_NAME, INPUT_SIZE, INPUT_SHA, None)
            .unwrap()
            .is_some()
    );
    // Keep the sealed positive intact. A second owner-writable specimen is
    // readable before linking, so the later refusal isolates its link count.
    fs::write(root.join("linked-input"), &source).unwrap();
    super::fixture_fs::owner_only(&root.join("linked-input"));
    assert!(
        directory
            .verify_cached_payload("linked-input", INPUT_SIZE, INPUT_SHA, None)
            .unwrap()
            .is_none()
    );
    fs::hard_link(root.join("linked-input"), root.join("linked-alias")).unwrap();
    assert!(
        directory
            .verify_cached_payload("linked-input", INPUT_SIZE, INPUT_SHA, None)
            .is_err(),
        "payload bytes must have one name"
    );
    drop(directory);
    fs::remove_dir_all(root).unwrap();
}
