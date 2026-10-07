//! The separately recorded CHG-2026-081 Native oracle. Its old Swift source
//! stays immutable; current responses and all persisted bytes are recorded
//! from actual task-owned Rust owners, never inferred by dropping fields.
use super::{Owners, assert_conforms};
use crate::support::{debug_hap, document, fixed_now, native_observation, oracle_fake};
use arkdeck_contract::{CATALOG_DIGEST, sha256_hex};
use arkdeck_hoststore::{ArtifactReadStore, ImportUploadStore};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;

pub const NAME: &str = "deploy-native-library-observed-v1";
const PREFIX: &str = "case \"$*\" in\n\"list targets -v\")\n  printf '%s\\t\\tUSB\\tConnected\\tlocalhost\\n' \"$key\"; exit 0 ;;\n\"-t $key shell param get const.product.name\")\n  printf 'OpenHarmony Reference Device\\n'; exit 0 ;;\n\"-t $key shell param get const.ohos.fullname\")\n  printf 'OpenHarmony-4.1-release\\n'; exit 0 ;;\nesac\n";

/// Only the answer fragment changes; the pinned driver image remains exact.
pub fn install_answers(root: &Path, historical: &Path) {
    let original = fs::read_to_string(historical.join("hdc-answers.sh")).unwrap();
    assert_eq!(original.matches("case \"$*\" in\n").count(), 1);
    fs::write(
        root.join("hdc-answers.sh"),
        original.replacen("case \"$*\" in\n", &format!("{PREFIX}case \"$*\" in\n"), 1),
    )
    .unwrap();
}

/// A genuine typed, structural import with no relation to the five jobs.
/// Both consumers create it anew through the same public store methods.
pub fn prepare_import(root: &Path) -> Value {
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let imports = ImportUploadStore::open(&root.join("artifacts")).unwrap();
    debug_hap::import_package(
        &imports,
        &artifacts,
        "native-current-census",
        "TGT-ISOLATED-IMPORT",
        1,
        &"a".repeat(64),
        &fixed_now().unwrap(),
    )
}

/// Full public projections beside the complete on-disk Manifest and Journal.
/// A missing/duplicate finalized event or unpublished source refuses here.
pub fn proof(
    root: &Path,
    job: &str,
    shown: Value,
    inspection: Value,
    receipt: &Value,
    digest: &str,
) -> Value {
    let jobs = if root.join("store").exists() {
        root.join("store")
    } else {
        root.join("jobs-state")
    };
    let sessions = if root.join("Sessions").exists() {
        root.join("Sessions")
    } else {
        root.join("sessions")
    };
    let record: Value = serde_json::from_slice(
        &fs::read(jobs.join("jobs").join(job).join("job-record.json")).unwrap(),
    )
    .unwrap();
    native_observation::assert_observation(&record, digest);
    super::native_readback::timeline_proofs(record["timeline"].as_array().unwrap());
    let marker = &record["sessionPublicationRecord"];
    assert_eq!(marker["phase"], "catalogPublished");
    assert_eq!(record["catalogDigest"], CATALOG_DIGEST);
    assert_eq!(record["outcomeUnknown"], false);
    let manifest_path = sessions
        .join(marker["relativeSessionPath"].as_str().unwrap())
        .join("manifest.json");
    let bytes = fs::read(manifest_path).unwrap();
    assert_eq!(sha256_hex(&bytes), marker["receipt"]["manifestSHA256"]);
    let manifest: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(manifest["jobId"], job);
    assert_eq!(manifest["sessionId"], marker["sessionID"]);
    assert_eq!(manifest["status"], record["state"]);
    assert_eq!(manifest["workflow"]["profileVersion"], CATALOG_DIGEST);
    assert_eq!(manifest["runtimeAuthority"]["kind"], "runtimeCapability");
    assert_eq!(
        manifest["runtimeAuthority"]["planDigest"],
        record["materializedPlanDigest"]
    );
    assert_eq!(shown["sessionId"], marker["sessionID"]);
    assert_eq!(shown["generation"], marker["receipt"]["catalogGeneration"]);
    assert_eq!(inspection["import"]["importId"], receipt["importId"]);
    assert_eq!(inspection["import"], *receipt);
    assert_eq!(inspection["references"]["state"], "clear");
    assert!(
        inspection["references"]["activeJobIds"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        inspection["references"]["outcomeUnknownJobIds"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(inspection["references"]["activeMaterializationCount"], "0");
    let journal: Vec<Value> = fs::read_to_string(jobs.join("jobs").join(job).join("journal.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert!(journal.iter().all(|row| row["jobId"] == job));
    let finalized: Vec<_> = journal
        .iter()
        .filter(|row| row["kind"] == "finalized")
        .collect();
    assert_eq!(finalized.len(), 1);
    let original = document(
        &crate::support::fixture("deploy-native-library"),
        "cases.json",
    );
    let case = original["jobs"]
        .as_object()
        .unwrap()
        .iter()
        .find(|(_, id)| *id == job)
        .unwrap()
        .0;
    let status = if case == "cleanupFailure" {
        "failed"
    } else {
        super::exchange(&original, &format!("{case}.run"))["answer"]["result"]["state"]
            .as_str()
            .unwrap()
    };
    assert_eq!(record["state"], status);
    if case == "cleanupFailure" {
        assert_eq!(record["outstandingResidueCount"], 1);
        let failed: Vec<_> = journal
            .iter()
            .filter(|row| {
                row["kind"] == "stepOutcome" && row["stepId"] == "cleanup-staging-and-backup"
            })
            .collect();
        assert_eq!(failed.len(), 1);
        assert_eq!(failed[0]["payload"]["result"], "failed");
        assert_eq!(failed[0]["payload"]["outcomeCertainty"], "confirmed");
        assert!(
            root.join("device-published").exists(),
            "final housekeeping must retain replacement"
        );
        assert!(!record["timeline"].as_array().unwrap().iter().any(|line| {
            line.as_str().is_some_and(|line| {
                line.starts_with("skipped cleanup-staging")
                    || line.contains("native deployment failure restored")
            })
        }));
    }
    json!({"jobId":job,"sessionShow":shown,"importInspection":inspection,"importReceipt":receipt,"manifestSHA256":sha256_hex(&bytes),"manifestByteCount":bytes.len().to_string(),"finalized":finalized[0]})
}

pub fn publication_proof(owners: &Owners, receipt: &Value, job: &str) -> Value {
    let record = owners.record(job);
    let shown = owners
        .sessions
        .handle_resource(
            "session.show",
            json!({"sessionId":record["sessionPublicationRecord"]["sessionID"]})
                .as_object()
                .unwrap(),
        )
        .unwrap();
    let imports = ImportUploadStore::open(&owners.root.join("artifacts")).unwrap();
    let inspection = imports
        .lifecycle_resource(
            &owners.artifacts,
            &owners.jobs,
            "artifact.import.inspection",
            json!({"importId":receipt["importId"]}).as_object().unwrap(),
            &fixed_now().unwrap(),
        )
        .unwrap();
    assert_conforms("session.show", &json!({"ok":true,"result":shown}));
    assert_conforms(
        "artifact.import.inspection",
        &json!({"ok":true,"result":inspection}),
    );
    proof(
        &owners.root,
        job,
        shown,
        inspection,
        receipt,
        &owners.digest,
    )
}

/// Every old call remains in its exact position relative to every other old
/// call. Only the five ordered, exact three-read prefixes may be additional.
pub fn assert_original_calls(log: &str, root: &Path) {
    let log = oracle_fake::oracle_spelling(log, root);
    assert_eq!(log.lines().count(), 240);
    assert_eq!(
        log,
        expected_calls(),
        "all original calls plus only the exact prefix before each first mutation"
    );
}

pub fn expected_calls() -> String {
    let fixture = crate::support::fixture("deploy-native-library");
    let cases = document(&fixture, "cases.json");
    let historical = fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap();
    assert_eq!(historical.lines().count(), 225);
    let reads = [
        "list\u{1f}targets\u{1f}-v\u{1f}",
        "-t\u{1f}aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\u{1f}shell\u{1f}param\u{1f}get\u{1f}const.product.name\u{1f}",
        "-t\u{1f}aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\u{1f}shell\u{1f}param\u{1f}get\u{1f}const.ohos.fullname\u{1f}",
    ];
    let starts: Vec<_> = [
        "deployed",
        "loaderFailure",
        "targetAbsent",
        "unattested",
        "cleanupFailure",
    ]
    .iter()
    .map(|case| {
        historical
            .lines()
            .position(|line| line.contains(cases["jobs"][*case].as_str().unwrap()))
            .unwrap()
    })
    .collect();
    let mut expected = String::new();
    for (index, line) in historical.lines().enumerate() {
        if starts.contains(&index) {
            for read in &reads {
                expected.push_str(read);
                expected.push('\n');
            }
        }
        expected.push_str(line);
        expected.push('\n');
    }
    assert_eq!(expected.lines().count(), 240);
    expected
}

pub fn publication_answers(
    fixture: &Path,
    actual: &[Value],
    spelled: &impl Fn(&[u8]) -> Vec<u8>,
) -> Vec<(Value, Value, Value)> {
    let expected = document(fixture, "publication-proofs.json");
    let actual: Value =
        serde_json::from_slice(&spelled(&serde_json::to_vec(actual).unwrap())).unwrap();
    assert_eq!(actual.as_array().unwrap().len(), 5);
    assert_eq!(expected.as_array().unwrap().len(), 5);
    actual
        .as_array()
        .unwrap()
        .iter()
        .zip(expected.as_array().unwrap())
        .map(|(actual, expected)| {
            (
                json!(format!("publication.{}", actual["jobId"].as_str().unwrap())),
                actual.clone(),
                expected.clone(),
            )
        })
        .collect()
}

fn write_new(root: &Path, path: &str, bytes: &[u8]) {
    let path = root.join(path);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .unwrap();
    file.write_all(bytes).unwrap();
    file.sync_all().unwrap();
}

pub fn record(
    output: &Path,
    historical: &Path,
    owners: &Owners,
    cases: &Value,
    proofs: &[Value],
    spelled: impl Fn(&[u8]) -> Vec<u8>,
) {
    assert!(!output.exists(), "recording must use a new output tree");
    assert_eq!(
        output.file_name().and_then(|name| name.to_str()),
        Some(NAME)
    );
    let original = debug_hap::tree_bytes(historical);
    assert_eq!(original.len(), 43, "the complete original source fixture");
    fs::create_dir(output).unwrap();
    let mut files = BTreeMap::new();
    for name in ["hdc", "hdc-answers.sh", "targets-state/targets.json"] {
        files.insert(name.to_owned(), fs::read(owners.root.join(name)).unwrap());
    }
    files.insert(
        "cases.json".into(),
        serde_json::to_vec_pretty(cases).unwrap(),
    );
    files.insert(
        "publication-proofs.json".into(),
        spelled(&serde_json::to_vec_pretty(proofs).unwrap()),
    );
    files.insert(
        "hdc-invocations.log".into(),
        spelled(owners.calls().as_bytes()),
    );
    let index = crate::support::index_normalized(&owners.default_root, &spelled);
    files.insert(
        "store/index.json".into(),
        serde_json::to_vec_pretty(&index).unwrap(),
    );
    let mut tree = Vec::new();
    for (base, prefix) in [
        (owners.default_root.join("jobs"), "store/jobs"),
        (
            owners.default_root.join("capabilities"),
            "store/capabilities",
        ),
        (owners.root.join("Sessions"), "sessions"),
        (owners.root.join("session-owner"), "session-owner"),
    ] {
        let mut bytes = BTreeMap::new();
        crate::support::walk(&base, prefix, &mut bytes, &mut tree);
        files.extend(
            bytes
                .into_iter()
                .map(|(name, bytes)| (name, spelled(&bytes))),
        );
    }
    files.extend(
        crate::support::artifacts(&owners.root.join("artifacts"))
            .into_iter()
            .map(|(name, bytes)| (name, spelled(&bytes))),
    );
    let mut import_files = BTreeMap::new();
    let mut import_tree = Vec::new();
    crate::support::walk(
        &owners.root.join("artifacts/.imports-v1"),
        "imports",
        &mut import_files,
        &mut import_tree,
    );
    files.extend(
        import_files
            .into_iter()
            .map(|(name, bytes)| (name, spelled(&bytes))),
    );
    files.insert(
        "import-tree.json".into(),
        serde_json::to_vec_pretty(
            &import_tree
                .iter()
                .map(|(path, kind, mode)| json!({"path":path,"kind":kind,"mode":mode}))
                .collect::<Vec<_>>(),
        )
        .unwrap(),
    );
    files.insert(
        "tree.json".into(),
        serde_json::to_vec_pretty(
            &tree
                .iter()
                .map(|(path, kind, mode)| json!({"path":path,"kind":kind,"mode":mode}))
                .collect::<Vec<_>>(),
        )
        .unwrap(),
    );
    let mut provenance = owners.provenance.clone();
    provenance["producer"] = json!(
        "Rust native_library_current_oracle::record_current_native_oracle (task-owned synthetic dispatch; not hardware evidence)"
    );
    provenance["catalogDigest"] = json!(CATALOG_DIGEST);
    provenance
        .as_object_mut()
        .unwrap()
        .remove("catalogRegeneration");
    provenance["scopedDelta"] = json!("CHG-2026-081");
    provenance["hardwareEvidence"] = json!(false);
    provenance["originalFixture"] = json!("../deploy-native-library");
    provenance["originalFiles"] = json!(
        original
            .iter()
            .map(|(path, bytes)| (path.to_string_lossy().replace('\\', "/"), sha256_hex(bytes)))
            .collect::<BTreeMap<_, _>>()
    );
    provenance["files"] = json!(
        files
            .iter()
            .map(|(name, bytes)| (name.clone(), sha256_hex(bytes)))
            .collect::<BTreeMap<_, _>>()
    );
    for (name, bytes) in files {
        write_new(output, &name, &bytes);
    }
    write_new(
        output,
        "provenance.json",
        &serde_json::to_vec_pretty(&provenance).unwrap(),
    );
    assert_eq!(
        debug_hap::tree_bytes(historical),
        original,
        "historical bytes were not changed"
    );
}

pub fn assert_source(fixture: &Path) {
    let provenance = document(fixture, "provenance.json");
    assert_eq!(provenance["hardwareEvidence"], false);
    assert_eq!(provenance["catalogDigest"], CATALOG_DIGEST);
    let old = crate::support::fixture("deploy-native-library");
    let bytes = debug_hap::tree_bytes(&old);
    assert_eq!(bytes.len(), 43);
    let hashes = bytes
        .iter()
        .map(|(path, bytes)| (path.to_string_lossy().replace('\\', "/"), sha256_hex(bytes)))
        .collect::<BTreeMap<_, _>>();
    assert_eq!(json!(hashes), provenance["originalFiles"]);
    let source = document(&old, "cases.json");
    let current = document(fixture, "cases.json");
    assert_eq!(source["jobs"], current["jobs"]);
    let old = source["exchanges"].as_array().unwrap();
    let new = current["exchanges"].as_array().unwrap();
    assert_eq!(old.len(), 40);
    assert_eq!(new.len(), 40);
    for (old, new) in old.iter().zip(new) {
        for field in ["name", "method", "mode"] {
            assert_eq!(old[field], new[field]);
        }
        if old["method"] != "capability.inspect" {
            assert_eq!(old["params"], new["params"]);
        } else {
            assert_eq!(new["params"].as_object().unwrap().len(), 1);
            let capability = new["params"]["capabilityId"].as_str().unwrap();
            assert!(capability.starts_with("CAP-"));
            let listed = &super::exchange(&current, "capabilities.list")["answer"]["result"];
            assert!(
                serde_json::to_string(listed).unwrap().contains(capability),
                "actual current lineage reference"
            );
        }
    }
    for (name, digest) in provenance["files"].as_object().unwrap() {
        assert_eq!(
            sha256_hex(&fs::read(fixture.join(name)).unwrap()),
            digest.as_str().unwrap()
        );
    }
}

/// Random import identities are labels only after the complete typed receipt,
/// imported payload and each snapshot's fixed query have been proved. No field
/// is removed; the same bijection applies to paths and every stored document.
pub fn learn_import_labels(
    fixture: &Path,
    root: &Path,
    answers: &[(Value, Value, Value)],
    labels: &mut debug_hap::HostLabels,
    spelled: &impl Fn(&[u8]) -> Vec<u8>,
) {
    let proofs: Vec<_> = answers
        .iter()
        .filter(|(name, _, _)| {
            name.as_str()
                .is_some_and(|name| name.starts_with("publication."))
        })
        .collect();
    assert_eq!(proofs.len(), 5);
    let (_, first, expected) = proofs[0];
    let actual = &first["importReceipt"];
    let expected = &expected["importReceipt"];
    learn_receipt_labels(actual, expected, labels);
    let id = actual["importId"].as_str().unwrap();
    let artifact = &actual["receipt"];
    assert_eq!(artifact["importId"], id);
    assert_eq!(artifact["owner"], json!({"id":id,"kind":"import"}));
    let artifact_id = artifact["artifactId"].as_str().unwrap();
    assert!(id.starts_with("imp-"));
    assert!(artifact_id.starts_with("ART-"));
    assert_eq!(artifact["lease"], format!("lease-v1:{id}:{artifact_id}"));
    for (_, actual, _) in &proofs {
        assert_eq!(&actual["importReceipt"], &first["importReceipt"]);
    }
    let bytes = fs::read(root.join("artifacts").join(id).join(artifact_id)).unwrap();
    assert_eq!(bytes, b"PK\x03\x04isolated-native-current-census");
    assert_eq!(sha256_hex(&bytes), artifact["artifactDigest"]);
    assert_eq!(bytes.len().to_string(), artifact["byteCount"]);
    let actual_index: Value = serde_json::from_slice(
        &fs::read(root.join("artifacts").join(id).join("index.json")).unwrap(),
    )
    .unwrap();
    let expected_id = expected["importId"].as_str().unwrap();
    let expected_index = document(fixture, &format!("artifacts/{expected_id}/index.json"));
    let actual_session = format!("import-{id}");
    let expected_session = format!("import-{expected_id}");
    assert_eq!(actual_index["artifacts"].as_array().unwrap().len(), 1);
    assert_eq!(expected_index["artifacts"].as_array().unwrap().len(), 1);
    assert_eq!(actual_index["artifacts"][0]["sessionID"], actual_session);
    assert_eq!(
        expected_index["artifacts"][0]["sessionID"],
        expected_session
    );
    labels.learn_value(&actual_session, &expected_session);
    assert_eq!(
        labels.swift(&actual_index),
        expected_index,
        "complete imported index"
    );
    let snapshots = |base: &Path| -> BTreeMap<String, (String, Value)> {
        let mut snapshots = BTreeMap::new();
        for file in fs::read_dir(base).unwrap() {
            let file = file.unwrap();
            let name = file.file_name().to_str().unwrap().to_owned();
            if name == ".snapshots.lock" {
                continue;
            }
            let value: Value =
                serde_json::from_slice(&spelled(&fs::read(file.path()).unwrap())).unwrap();
            assert_eq!(value["schemaVersion"], "arkdeck.runtime-snapshot/1");
            let revision = value["revision"].as_str().unwrap();
            assert_eq!(name, format!("snapshot-{revision}.json"));
            let tokens = value["tokens"].as_array().unwrap();
            assert_eq!(tokens.len(), 1);
            assert!(
                tokens[0]
                    .as_str()
                    .unwrap()
                    .starts_with(&format!("{revision}."))
            );
            let query = value["queryDigest"].as_str().unwrap().to_owned();
            assert!(snapshots.insert(query, (name, value)).is_none());
        }
        assert_eq!(snapshots.len(), 5);
        snapshots
    };
    let actual = snapshots(&root.join("artifacts/.imports-v1/artifact-snapshots"));
    let expected = snapshots(&fixture.join("imports/artifact-snapshots"));
    assert_eq!(
        actual.keys().collect::<Vec<_>>(),
        expected.keys().collect::<Vec<_>>()
    );
    for (query, (name, value)) in actual {
        let (expected_name, expected) = &expected[&query];
        labels.learn_value(&name, expected_name);
        labels.learn(&value, expected, "/revision");
        labels.learn(&value, expected, "/tokens/0");
        assert_eq!(labels.swift(&value), *expected, "complete snapshot {query}");
    }
}

pub fn learn_receipt_labels(actual: &Value, expected: &Value, labels: &mut debug_hap::HostLabels) {
    for receipt in [actual, expected] {
        let id = receipt["importId"].as_str().unwrap();
        let artifact = &receipt["receipt"];
        let artifact_id = artifact["artifactId"].as_str().unwrap();
        assert!(id.starts_with("imp-"));
        assert!(artifact_id.starts_with("ART-"));
        assert_eq!(artifact["importId"], id);
        assert_eq!(artifact["owner"], json!({"id":id,"kind":"import"}));
        assert_eq!(artifact["lease"], format!("lease-v1:{id}:{artifact_id}"));
    }
    for pointer in ["/importId", "/receipt/artifactId", "/receipt/lease"] {
        labels.learn(actual, expected, pointer);
    }
    assert_eq!(
        labels.swift(actual),
        *expected,
        "all import metadata is fixed"
    );
}

fn labelled_path(path: &str, labels: &debug_hap::HostLabels) -> String {
    path.split('/')
        .map(|part| {
            let mapped = labels.swift(&json!(part));
            let mapped = mapped.as_str().unwrap();
            if mapped != part {
                return mapped.to_owned();
            }
            if let Some(stem) = part.strip_suffix(".json") {
                return format!("{}.json", labels.swift(&json!(stem)).as_str().unwrap());
            }
            part.to_owned()
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn compare_files(
    fixture: &Path,
    files: BTreeMap<String, Vec<u8>>,
    prefixes: &[&str],
    labels: &debug_hap::HostLabels,
    spelled: &impl Fn(&[u8]) -> Vec<u8>,
) {
    let mut actual = BTreeMap::new();
    for (path, bytes) in files {
        assert!(
            actual
                .insert(
                    labelled_path(&path, labels),
                    labels.swift_bytes(&spelled(&bytes))
                )
                .is_none()
        );
    }
    let expected: BTreeMap<_, _> = document(fixture, "provenance.json")["files"]
        .as_object()
        .unwrap()
        .keys()
        .filter(|path| prefixes.iter().any(|prefix| path.starts_with(prefix)))
        .map(|path| (path.clone(), fs::read(fixture.join(path)).unwrap()))
        .collect();
    assert_eq!(
        actual.keys().collect::<Vec<_>>(),
        expected.keys().collect::<Vec<_>>()
    );
    for (path, bytes) in actual {
        assert_eq!(bytes, expected[&path], "{path}");
    }
}

/// The current oracle compares its complete store, including the unrelated
/// import Artifact owner. Historical oracle comparison stays untouched.
pub fn assert_leftovers(
    fixture: &Path,
    root: &Path,
    jobs: &Path,
    index: Value,
    labels: &debug_hap::HostLabels,
    spelled: &impl Fn(&[u8]) -> Vec<u8>,
) {
    let index: Value =
        serde_json::from_slice(&labels.swift_bytes(&spelled(&serde_json::to_vec(&index).unwrap())))
            .unwrap();
    assert_eq!(index, document(fixture, "store/index.json"));
    let mut files = BTreeMap::new();
    let mut tree = Vec::new();
    for (base, prefix) in [
        (jobs.join("jobs"), "store/jobs"),
        (jobs.join("capabilities"), "store/capabilities"),
        (root.join("Sessions"), "sessions"),
        (root.join("session-owner"), "session-owner"),
    ] {
        crate::support::walk(&base, prefix, &mut files, &mut tree);
    }
    files.extend(crate::support::artifacts(&root.join("artifacts")));
    assert_eq!(
        json!(
            tree.iter()
                .map(|(path, kind, mode)| json!({"path":path,"kind":kind,"mode":mode}))
                .collect::<Vec<_>>()
        ),
        document(fixture, "tree.json")
    );
    compare_files(
        fixture,
        files,
        &[
            "store/jobs/",
            "store/capabilities/",
            "sessions/",
            "session-owner/",
            "artifacts/",
        ],
        labels,
        spelled,
    );
}

/// The complete upload owner is compared too, not only its public receipt.
pub fn assert_import_snapshot(
    fixture: &Path,
    root: &Path,
    labels: &debug_hap::HostLabels,
    spelled: &impl Fn(&[u8]) -> Vec<u8>,
) {
    let mut files = BTreeMap::new();
    let mut tree = Vec::new();
    crate::support::walk(
        &root.join("artifacts/.imports-v1"),
        "imports",
        &mut files,
        &mut tree,
    );
    let mut tree: Vec<Value> = tree.iter().map(|(path, kind, mode)| json!({"path":labelled_path(path, labels),"kind":kind,"mode":mode})).collect();
    tree.sort_by(|a, b| a["path"].as_str().unwrap().cmp(b["path"].as_str().unwrap()));
    assert_eq!(json!(tree), document(fixture, "import-tree.json"));
    compare_files(fixture, files, &["imports/"], labels, spelled);
}
