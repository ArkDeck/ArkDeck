#![cfg(target_os = "macos")]
use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{ArtifactReadStore, ArtifactUsage, MAX_ARTIFACT_READ_BYTES};
use serde_json::{Value, json};
use std::{
    fs,
    io::ErrorKind,
    os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    path::PathBuf,
};

struct Fixture {
    root: PathBuf,
    rows: Vec<Value>,
}
impl Fixture {
    fn new() -> Self {
        let nonce = arkdeck_platform::random_bytes::<16>().unwrap();
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "artifact-read-owner-{:x}",
            u128::from_ne_bytes(nonce)
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.join("JOB-1"))
            .unwrap();
        Self { root, rows: vec![] }
    }
    fn add(&mut self, name: &str, bytes: &[u8]) -> String {
        let digest = sha256_hex(bytes);
        let id = format!(
            "ART-{}",
            &sha256_hex(format!("JOB-1\0{name}\0{digest}").as_bytes())[..32]
        );
        fs::write(self.root.join("JOB-1").join(&id), bytes).unwrap();
        fs::set_permissions(
            self.root.join("JOB-1").join(&id),
            fs::Permissions::from_mode(0o400),
        )
        .unwrap();
        self.rows.push(json!({"artifactID":id,"jobID":"JOB-1","sessionID":"SESSION-1","stepID":"step",
            "name":name,"mediaType":"application/octet-stream","sha256":digest,"createdAtUTC":"2026-09-11T00:00:00.000Z",
            "providerID":"fixture","sourceOperation":"fixture.read","privacy":"standard","byteCount":bytes.len(),
            "bindingSnapshot":{"targetID":"fixture-target"},"retention":{"retentionClass":"default","pinned":false},
            "status":{"published":{}},"redactionApplied":false}));
        self.save();
        id
    }
    fn save(&self) {
        self.write_index(
            serde_json::to_vec(&json!({"schemaVersion":"1.0.0","artifacts":self.rows})).unwrap(),
        );
    }
    fn write_index(&self, bytes: Vec<u8>) {
        let path = self.root.join("JOB-1/index.json");
        fs::write(&path, bytes).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
    }
    fn store(&self) -> ArtifactReadStore {
        ArtifactReadStore::open(&self.root).unwrap()
    }
}
// Fixtures are newly generated local test input and deliberately retained.
// No existing Artifact roots or cleanup/deletion API is involved.
#[test]
fn range_crosses_stream_chunk_and_eof_without_changing_durable_bytes() {
    let mut f = Fixture::new();
    let bytes: Vec<u8> = (0..200_000).map(|i| (i % 251) as u8).collect();
    let id = f.add("payload", &bytes);
    let index_before = fs::read(f.root.join("JOB-1/index.json")).unwrap();
    let store = f.store();
    let read = store.read("JOB-1", &id, 65_530, 20, false).unwrap();
    assert_eq!(read.bytes, bytes[65_530..65_550]);
    assert_eq!(read.next_offset, 65_550);
    assert!(!read.eof);
    let tail = store.read("JOB-1", &id, 199_999, 20, false).unwrap();
    assert_eq!(tail.bytes, bytes[199_999..]);
    assert!(tail.eof);
    let end = store.read("JOB-1", &id, 200_000, 1, false).unwrap();
    assert!(end.bytes.is_empty());
    assert!(end.eof);
    assert_eq!(store.inspect("JOB-1", &id).unwrap(), f.rows[0]);
    assert_eq!(
        ArtifactUsage::open(&f.root, 1_000_000)
            .unwrap()
            .status()
            .unwrap()["usedBytes"],
        "200000"
    );
    assert_eq!(
        fs::read(f.root.join("JOB-1/index.json")).unwrap(),
        index_before
    );
    assert_eq!(fs::read(f.root.join("JOB-1").join(&id)).unwrap(), bytes);
}
#[test]
fn snapshot_pagination_is_stable_after_index_changes_and_has_bounded_arguments() {
    let mut f = Fixture::new();
    let a = f.add("a", b"a");
    let b = f.add("b", b"b");
    let snapshot = f.store().list("JOB-1").unwrap();
    f.add("c", b"c");
    let mut expected = [a, b];
    expected.sort();
    assert_eq!(snapshot.len(), 2);
    let first = snapshot.page(0, 1).unwrap();
    assert_eq!(first.items[0]["artifactID"], expected[0]);
    assert_eq!(first.next_offset, Some(1));
    let last = snapshot.page(first.next_offset.unwrap(), 1).unwrap();
    assert_eq!(last.items[0]["artifactID"], expected[1]);
    assert_eq!(last.next_offset, None);
    assert!(snapshot.page(2, 10).unwrap().items.is_empty());
    for (offset, size) in [(3, 1), (0, 0), (0, 1001), (usize::MAX, 1)] {
        assert!(snapshot.page(offset, size).is_err());
    }
    assert_eq!(f.store().list("JOB-1").unwrap().len(), 3);
}
#[test]
fn sensitive_opt_in_and_invalid_ranges_fail_before_content_return() {
    let mut f = Fixture::new();
    let id = f.add("secret", b"sensitive fixture");
    f.rows[0]["privacy"] = json!("sensitive");
    f.save();
    let store = f.store();
    assert_eq!(
        store.read("JOB-1", &id, 0, 2, false).unwrap_err().kind(),
        ErrorKind::PermissionDenied
    );
    assert_eq!(store.read("JOB-1", &id, 0, 2, true).unwrap().bytes, b"se");
    for (offset, maximum) in [(0, 0), (0, MAX_ARTIFACT_READ_BYTES + 1), (u64::MAX, 1)] {
        assert_eq!(
            store
                .read("JOB-1", &id, offset, maximum, true)
                .unwrap_err()
                .kind(),
            ErrorKind::InvalidInput
        );
    }
    for job in ["../JOB-1", "", ".imports-v1", "/JOB-1", "imp-fixture"] {
        assert!(store.list(job).is_err());
    }
}
#[test]
fn missing_and_truncated_remain_inspectable_without_claiming_readable_content() {
    for status in [
        json!({"missing":{"reason":"fixture interruption"}}),
        json!({"truncated":{"atBytes":2}}),
    ] {
        let mut f = Fixture::new();
        let id = f.add("incomplete", b"data");
        f.rows[0]["status"] = status.clone();
        f.save();
        assert_eq!(f.store().inspect("JOB-1", &id).unwrap()["status"], status);
        assert_eq!(
            f.store()
                .read("JOB-1", &id, 0, 2, false)
                .unwrap_err()
                .kind(),
            ErrorKind::NotFound
        );
    }
}
#[test]
fn strict_index_refuses_extra_keys_foreign_identity_duplicates_and_malformed_json() {
    let mut f = Fixture::new();
    f.add("a", b"a");
    let original = f.rows.clone();
    for field in ["extra", "derivation"] {
        f.rows = original.clone();
        f.rows[0][field] = json!({"extra":true});
        f.save();
        assert!(f.store().list("JOB-1").is_err());
    }
    for (key, value) in [
        ("jobID", json!("JOB-2")),
        ("artifactID", json!("../payload")),
        ("byteCount", json!(-1)),
    ] {
        f.rows = original.clone();
        f.rows[0][key] = value;
        f.save();
        assert!(f.store().list("JOB-1").is_err());
    }
    f.rows = vec![original[0].clone(), original[0].clone()];
    f.save();
    assert!(f.store().list("JOB-1").is_err());
    for bytes in [
        b"".to_vec(),
        b"{".to_vec(),
        br#"{"schemaVersion":"1.0.0","schemaVersion":"1.0.0","artifacts":[]}"#.to_vec(),
        br#"{"schemaVersion":"1.0.0","artifacts":[],"extra":1}"#.to_vec(),
    ] {
        f.write_index(bytes);
        assert!(f.store().list("JOB-1").is_err());
    }
}
#[test]
fn digest_corruption_outside_requested_range_and_linked_payloads_are_refused() {
    let mut f = Fixture::new();
    let id = f.add("a", b"abcdef");
    let payload = f.root.join("JOB-1").join(&id);
    fs::set_permissions(&payload, fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(&payload, b"abcdeX").unwrap();
    assert!(f.store().read("JOB-1", &id, 0, 1, false).is_err());
    assert!(f.store().list("JOB-1").is_err());
    let original = f.root.join("retained-original");
    fs::rename(&payload, &original).unwrap();
    symlink(&original, &payload).unwrap();
    assert!(f.store().read("JOB-1", &id, 0, 1, false).is_err());
    assert_eq!(fs::read(&original).unwrap(), b"abcdeX");
}
#[test]
fn unicode_equivalent_names_and_corrupt_unselected_rows_fail_closed() {
    let mut f = Fixture::new();
    let id = f.add("é", b"a");
    f.add("e\u{301}", b"b");
    assert!(f.store().list("JOB-1").is_err());
    assert!(f.store().read("JOB-1", &id, 0, 1, false).is_err());
    f.rows[1]["name"] = json!("different");
    f.rows[1]["sha256"] = json!("0".repeat(64));
    f.save();
    assert!(f.store().read("JOB-1", &id, 0, 1, false).is_err());
}

#[test]
fn frozen_derived_provenance_is_preserved_and_extra_nested_fields_are_refused() {
    let mut f = Fixture::new();
    let id = f.add("derived", b"derived fixture");
    let mut derivation = serde_json::Map::new();
    for key in [
        "analyzerRef",
        "analyzerVersion",
        "sourceArtifactID",
        "sourceSHA256",
        "toolSHA256",
        "parserSHA256",
        "parserVersion",
        "parserUpstreamRevision",
        "parserBuildRecipeVersion",
        "parserAdapterVersion",
        "schemaAdapterVersion",
    ] {
        derivation.insert(key.into(), json!("fixture-value"));
    }
    for key in [
        "sourceByteCount",
        "indexSchemaVersion",
        "timeoutMs",
        "maxRows",
        "maxEvents",
        "maxOutputBytes",
    ] {
        derivation.insert(key.into(), json!(1));
    }
    derivation.insert("requestKind".into(), json!("fixture"));
    derivation.insert(
        "requestTimestampNs".into(),
        json!(9_223_372_036_854_775_807_i64),
    );
    f.rows[0]["derivation"] = Value::Object(derivation);
    f.rows[0]["observationWindow"] =
        json!({"startUTC":"2026-09-11T00:00:00.000Z","endUTC":"2026-09-11T00:00:01.000Z"});
    f.save();
    let original = f.rows.clone();
    assert_eq!(f.store().inspect("JOB-1", &id).unwrap(), original[0]);
    for field in [
        "derivation",
        "observationWindow",
        "bindingSnapshot",
        "retention",
        "status",
    ] {
        f.rows = original.clone();
        f.rows[0][field]["extra"] = json!(true);
        f.save();
        assert!(
            f.store().inspect("JOB-1", &id).is_err(),
            "extra {field} field must be rejected"
        );
    }
}

#[test]
fn absent_index_is_empty_but_payload_length_and_hard_link_identity_are_checked() {
    let mut f = Fixture::new();
    assert!(f.store().list("JOB-1").unwrap().is_empty());
    let id = f.add("a", b"abc");
    f.rows[0]["byteCount"] = json!(4);
    f.save();
    assert!(f.store().read("JOB-1", &id, 0, 1, false).is_err());
    f.rows[0]["byteCount"] = json!(3);
    f.save();
    fs::hard_link(
        f.root.join("JOB-1").join(&id),
        f.root.join("retained-hard-link"),
    )
    .unwrap();
    assert!(f.store().read("JOB-1", &id, 0, 1, false).is_err());
}

#[test]
fn pagination_orders_instants_across_timezones_and_fractional_spellings() {
    let mut f = Fixture::new();
    let cases = [
        ("old-offset", "2026-09-11T01:00:00+02:00"),
        ("whole", "2026-09-11T00:00:00Z"),
        ("fraction-low", "2026-09-11T00:00:00.09Z"),
        ("equal-a", "2026-09-11T00:00:00.1Z"),
        ("equal-b", "2026-09-11T08:00:00.100000000+08:00"),
        ("equal-c", "2026-09-10T19:00:00.100-05:00"),
        ("fraction-high", "2026-09-11T00:00:00.11Z"),
        ("new-offset", "2026-09-10T23:30:00-01:00"),
    ];
    let mut ids = Vec::new();
    for (name, date) in cases {
        ids.push(f.add(name, name.as_bytes()));
        f.rows.last_mut().unwrap()["createdAtUTC"] = json!(date);
    }
    f.save();
    let mut ties = ids[3..6].to_vec();
    ties.sort();
    let mut expected = vec![ids[7].clone(), ids[6].clone()];
    expected.extend(ties);
    expected.extend([ids[2].clone(), ids[1].clone(), ids[0].clone()]);
    let snapshot = f.store().list("JOB-1").unwrap();
    let mut actual = Vec::new();
    let mut offset = 0;
    loop {
        let page = snapshot.page(offset, 2).unwrap();
        actual.extend(
            page.items
                .iter()
                .map(|row| row["artifactID"].as_str().unwrap().to_owned()),
        );
        let Some(next) = page.next_offset else { break };
        offset = next;
    }
    assert_eq!(actual, expected);
    // Dates retain their frozen spelling; sorting does not rewrite records.
    for row in snapshot.page(0, 1000).unwrap().items {
        assert!(f.rows.contains(&row));
    }
}

#[test]
fn invalid_creation_time_cannot_be_published_as_a_sorted_snapshot() {
    let mut f = Fixture::new();
    f.add("a", b"a");
    f.rows[0]["createdAtUTC"] = json!("not-a-date");
    f.save();
    assert!(f.store().list("JOB-1").is_err());
}

use arkdeck_hoststore::{ArtifactInspectRequest, ArtifactReadRequest};

fn swift_artifact_corpus(method: &str) -> Vec<Value> {
    let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap();
    fs::read_to_string(repo.join(format!(
        "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    )))
    .unwrap()
    .lines()
    .map(|line| arkdeck_contract::strict_json(line.as_bytes()).unwrap())
    .collect()
}
fn metadata_from_inspect_projection(value: &Value) -> Value {
    let mut metadata = json!({"artifactID":value["artifactId"],"jobID":value["owner"]["id"],"sessionID":"fixture-session","stepID":"fixture-step",
        "name":value["name"],"mediaType":value["mediaType"],"sha256":value["artifactDigest"],"createdAtUTC":value["createdAtUtc"],
        "providerID":value["providerId"],"sourceOperation":value["sourceOperation"],"privacy":value["privacy"],"byteCount":value["byteCount"],
        "bindingSnapshot":{"targetID":value["binding"]["targetId"],"bindingRevision":value["binding"]["bindingRevision"],"stableIdentitySHA256":value["binding"]["stableIdentitySha256"]},
        "retention":{"retentionClass":value["retention"]["class"],"pinned":value["retention"]["pinned"],"deadlineUTC":value["retention"]["deadlineUtc"]},
        "status":{"published":{}},"redactionApplied":value["redactionApplied"]});
    if value["status"] == "missing" {
        metadata["sha256"] = json!("");
        metadata["status"] = json!({"missing":{"reason":"fixture product unavailable"}});
    }
    if value["observationWindow"].is_object() {
        metadata["observationWindow"] = json!({
            "startUTC":value["observationWindow"]["startUtc"],
            "endUTC":value["observationWindow"]["endUtc"]});
    }
    metadata
}
fn install_corpus_publication(fixture: &Fixture, metadata: Value, bytes: &[u8]) {
    let published = metadata["status"].get("published").is_some();
    if published {
        assert_eq!(metadata["sha256"], sha256_hex(bytes));
        assert_eq!(metadata["byteCount"], bytes.len());
    }
    let job = fixture.root.join(metadata["jobID"].as_str().unwrap());
    fs::DirBuilder::new().mode(0o700).create(&job).unwrap();
    let payload = job.join(metadata["artifactID"].as_str().unwrap());
    if published {
        fs::write(&payload, bytes).unwrap();
        fs::set_permissions(payload, fs::Permissions::from_mode(0o400)).unwrap();
    }
    let index = job.join("index.json");
    fs::write(
        &index,
        serde_json::to_vec(&json!({"schemaVersion":"1.0.0","artifacts":[metadata]})).unwrap(),
    )
    .unwrap();
    fs::set_permissions(index, fs::Permissions::from_mode(0o600)).unwrap();
}

#[test]
fn actual_swift_inspect_recording_is_reproduced_from_verified_fixture_content() {
    let mut consumed = 0;
    for row in swift_artifact_corpus("artifact.inspect") {
        if row["ok"] != true || row["params"]["owner"]["kind"] != "job" {
            continue;
        }
        let fixture = Fixture::new();
        // Each successful native producer owns its exact payload. Adding a
        // new digest requires its source fixture bytes, never a replacement hash.
        let bytes: &[u8] = if row["result"]["status"] == "missing" {
            b""
        } else {
            [
                b"fixture-content".as_slice(),
                b"native fixture bytes\n".as_slice(),
            ]
            .into_iter()
            .find(|bytes| row["result"]["artifactDigest"] == sha256_hex(bytes))
            .expect("a native inspect producer's complete fixture bytes are required")
        };
        install_corpus_publication(
            &fixture,
            metadata_from_inspect_projection(&row["result"]),
            bytes,
        );
        let request =
            ArtifactInspectRequest::from_params(row["params"].as_object().unwrap()).unwrap();
        let actual = fixture.store().inspect_wire(&request).unwrap();
        assert_eq!(actual, row["result"]);
        arkdeck_contract::validate_method_value("artifact.inspect", "result", &actual).unwrap();
        consumed += 1;
    }
    assert!(
        consumed > 0,
        "must consume committed successful Swift Job inspect frames"
    );
}

#[test]
fn actual_swift_read_recording_is_reproduced_and_sensitive_opt_in_is_preserved() {
    let mut consumed = 0;
    for row in swift_artifact_corpus("artifact.read") {
        if row["ok"] != true || row["params"]["owner"]["kind"] != "job" {
            continue;
        }
        let mut fixture = Fixture::new();
        // Exact producer fixture bytes, bound by the recorded whole-artifact digest.
        let sensitive = row["params"]["owner"]["id"] != "job-window-wire";
        let bytes: &[u8] = if sensitive {
            b"private fixture content"
        } else {
            b"fixture-content"
        };
        fixture.add("private", bytes);
        let mut metadata = fixture.rows[0].clone();
        metadata["artifactID"] = row["result"]["artifactId"].clone();
        metadata["jobID"] = row["params"]["owner"]["id"].clone();
        metadata["privacy"] = json!(if sensitive { "sensitive" } else { "standard" });
        install_corpus_publication(&fixture, metadata, bytes);
        let request = ArtifactReadRequest::from_params(row["params"].as_object().unwrap()).unwrap();
        let actual = fixture.store().read_wire(&request).unwrap();
        assert_eq!(actual, row["result"]);
        arkdeck_contract::validate_method_value("artifact.read", "result", &actual).unwrap();
        if sensitive {
            let mut denied = row["params"].as_object().unwrap().clone();
            denied.insert("allowSensitive".into(), json!(false));
            assert_eq!(
                fixture
                    .store()
                    .read_wire(&ArtifactReadRequest::from_params(&denied).unwrap())
                    .unwrap_err()
                    .kind(),
                ErrorKind::PermissionDenied
            );
        }
        consumed += 1;
    }
    assert!(
        consumed > 0,
        "must consume committed successful Swift Job read frames"
    );
}

#[test]
fn wire_request_inputs_are_closed_typed_and_never_accept_paths_or_import_owners() {
    let params = json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":"ART-1"});
    let inspect = ArtifactInspectRequest::from_params(params.as_object().unwrap()).unwrap();
    assert_eq!(inspect.job_id(), "JOB-1");
    assert_eq!(inspect.artifact_id(), "ART-1");
    assert!(ArtifactReadRequest::from_params(params.as_object().unwrap()).is_ok());
    for (key, value) in [
        ("offset", json!("0")),
        ("offset", json!(null)),
        ("offset", json!(0.0)),
        ("offset", json!(-1)),
        ("offset", json!(9_007_199_254_740_992_u64)),
        ("maxBytes", json!(0)),
        ("maxBytes", json!(4_194_305)),
        ("maxBytes", json!(true)),
        ("allowSensitive", json!(1)),
        ("allowSensitive", json!(null)),
        ("path", json!("/private/tmp/payload")),
    ] {
        let mut bad = params.clone();
        bad[key] = value;
        assert!(
            ArtifactReadRequest::from_params(bad.as_object().unwrap()).is_err(),
            "{bad}"
        );
    }
    for bad in [
        json!({}),
        json!({"owner":{"kind":"job","id":"JOB-1","path":"/x"},"artifactId":"ART-1"}),
        json!({"owner":{"kind":"job","id":"../JOB-1"},"artifactId":"ART-1"}),
        json!({"owner":{"kind":"job","id":"imp-abc"},"artifactId":"ART-1"}),
        json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":"/tmp/payload"}),
        json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":1}),
    ] {
        assert!(ArtifactInspectRequest::from_params(bad.as_object().unwrap()).is_err());
        assert!(ArtifactReadRequest::from_params(bad.as_object().unwrap()).is_err());
    }
    let mut extra = params.clone();
    extra["offset"] = json!(0);
    assert!(ArtifactInspectRequest::from_params(extra.as_object().unwrap()).is_err());
    let mut imported = params;
    imported["owner"]["kind"] = json!("import");
    assert_eq!(
        ArtifactInspectRequest::from_params(imported.as_object().unwrap())
            .unwrap_err()
            .kind(),
        ErrorKind::Unsupported
    );
}

#[test]
fn read_wire_uses_standard_base64_and_exact_offset_tail_and_eof() {
    for (bytes, encoded) in [
        (b"".as_slice(), ""),
        (b"f", "Zg=="),
        (b"fo", "Zm8="),
        (b"foo", "Zm9v"),
        (b"foob", "Zm9vYg=="),
        (b"fooba", "Zm9vYmE="),
        (b"foobar", "Zm9vYmFy"),
        (&[255], "/w=="),
    ] {
        let mut fixture = Fixture::new();
        let id = fixture.add("payload", bytes);
        let reference = ArtifactInspectRequest::new("JOB-1", &id).unwrap();
        let wire = fixture
            .store()
            .read_wire(&ArtifactReadRequest::new(reference, 0, 100, false).unwrap())
            .unwrap();
        assert_eq!(wire["base64"], encoded);
        assert_eq!(wire["byteCount"], bytes.len());
        assert_eq!(wire["offset"], 0);
        assert_eq!(wire["nextOffset"], bytes.len());
        assert_eq!(wire["eof"], true);
    }
    let mut fixture = Fixture::new();
    let id = fixture.add("payload", b"foobar");
    let reference = ArtifactInspectRequest::new("JOB-1", &id).unwrap();
    let store = fixture.store();
    let middle = store
        .read_wire(&ArtifactReadRequest::new(reference.clone(), 2, 3, false).unwrap())
        .unwrap();
    assert_eq!(middle["base64"], "b2Jh");
    assert_eq!(middle["offset"], 2);
    assert_eq!(middle["nextOffset"], 5);
    assert_eq!(middle["eof"], false);
    let tail = store
        .read_wire(&ArtifactReadRequest::new(reference.clone(), 5, 3, false).unwrap())
        .unwrap();
    assert_eq!(tail["base64"], "cg==");
    assert_eq!(tail["byteCount"], 1);
    assert_eq!(tail["nextOffset"], 6);
    assert_eq!(tail["eof"], true);
    let eof = store
        .read_wire(&ArtifactReadRequest::new(reference, 6, 3, false).unwrap())
        .unwrap();
    assert_eq!(eof["base64"], "");
    assert_eq!(eof["byteCount"], 0);
    assert_eq!(eof["eof"], true);
}

#[test]
fn four_mib_slash_heavy_read_stays_inside_current_response_bound() {
    let mut fixture = Fixture::new();
    let bytes = vec![255; MAX_ARTIFACT_READ_BYTES];
    let id = fixture.add("payload", &bytes);
    let request = ArtifactReadRequest::new(
        ArtifactInspectRequest::new("JOB-1", &id).unwrap(),
        0,
        MAX_ARTIFACT_READ_BYTES,
        false,
    )
    .unwrap();
    let result = fixture.store().read_wire(&request).unwrap();
    assert_eq!(
        result["base64"],
        format!("{}/w==", "/".repeat((bytes.len() / 3) * 4))
    );
    assert_eq!(result["byteCount"], MAX_ARTIFACT_READ_BYTES);
    assert_eq!(result["eof"], true);
    assert!(arkdeck_contract::canonical_json(&result).unwrap().len() < 8 * 1024 * 1024 - 4096);
    arkdeck_contract::validate_method_value("artifact.read", "result", &result).unwrap();
}

#[test]
fn production_projection_preserves_nulls_and_observation_without_inventing_fields() {
    let mut fixture = Fixture::new();
    let id = fixture.add("missing", b"fixture");
    fixture.rows[0]["status"] = json!({"missing":{"reason":"fixture interruption"}});
    fixture.rows[0]["byteCount"] = json!(0);
    fixture.rows[0]["sha256"] = json!("");
    fixture.rows[0]["observationWindow"] =
        json!({"startUTC":"2026-09-11T08:00:00+08:00","endUTC":"2026-09-11T00:00:00.1Z"});
    fixture.save();
    let result = fixture
        .store()
        .inspect_wire(&ArtifactInspectRequest::new("JOB-1", &id).unwrap())
        .unwrap();
    assert_eq!(result.as_object().unwrap().len(), 17);
    assert_eq!(result["status"], "missing");
    assert!(result["artifactDigest"].is_null());
    assert!(result["lease"].is_null());
    assert!(result["binding"]["bindingRevision"].is_null());
    assert!(result["binding"]["stableIdentitySha256"].is_null());
    assert!(result["retention"]["deadlineUtc"].is_null());
    assert_eq!(
        result["observationWindow"],
        json!({"startUtc":"2026-09-11T08:00:00+08:00","endUtc":"2026-09-11T00:00:00.1Z"})
    );
    assert!(result.get("jobID").is_none());
    assert!(result.get("derivation").is_none());
    // These production shapes are not claimed as covered by the current
    // sample-derived method schema. No recording/schema is changed here.
}

#[test]
fn malformed_projection_metadata_never_returns_inspect_or_read_wire_bytes() {
    let mut fixture = Fixture::new();
    let id = fixture.add("payload", b"payload");
    let original = fixture.rows.clone();
    let reference = ArtifactInspectRequest::new("JOB-1", &id).unwrap();
    for (key, value) in [
        ("name", json!("x".repeat(1025))),
        ("mediaType", json!("")),
        ("providerID", json!("x".repeat(129))),
        ("sourceOperation", json!("x".repeat(257))),
        ("bindingSnapshot", json!({"targetID":"../bad"})),
        (
            "bindingSnapshot",
            json!({"targetID":"TGT-fixture","bindingRevision":0}),
        ),
        (
            "bindingSnapshot",
            json!({"targetID":"TGT-fixture","stableIdentitySHA256":"bad"}),
        ),
        (
            "retention",
            json!({"retentionClass":"default","pinned":false,"deadlineUTC":"bad"}),
        ),
        (
            "observationWindow",
            json!({"startUTC":"2026-09-11T00:00:01Z","endUTC":"2026-09-11T00:00:00Z"}),
        ),
    ] {
        fixture.rows = original.clone();
        fixture.rows[0][key] = value;
        fixture.save();
        assert!(
            fixture.store().inspect_wire(&reference).is_err(),
            "invalid {key}"
        );
        assert!(
            fixture
                .store()
                .read_wire(&ArtifactReadRequest::new(reference.clone(), 0, 1, false).unwrap())
                .is_err(),
            "invalid {key}"
        );
    }
    fixture.rows = original;
    fixture.rows[0]["status"] = json!({"missing":{"reason":"fixture"}});
    fixture.rows[0]["byteCount"] = json!(9_007_199_254_740_992_u64);
    fixture.save();
    assert!(fixture.store().inspect_wire(&reference).is_err());
}

#[test]
fn read_wire_defaults_to_one_mib_and_inspect_response_has_a_total_byte_bound() {
    let mut fixture = Fixture::new();
    let id = fixture.add("payload", &vec![0; 1_048_579]);
    let params = json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":id});
    let read = fixture
        .store()
        .read_wire(&ArtifactReadRequest::from_params(params.as_object().unwrap()).unwrap())
        .unwrap();
    assert_eq!(read["offset"], 0);
    assert_eq!(read["byteCount"], 1_048_576);
    assert_eq!(read["nextOffset"], 1_048_576);
    assert_eq!(read["eof"], false);
    // The production date parser accepts trailing text. Per-field validation
    // alone therefore cannot replace the handler's canonical response bound.
    fixture.rows[0]["createdAtUTC"] = json!(format!(
        "2026-09-11T00:00:00Z{}",
        "x".repeat(8 * 1024 * 1024)
    ));
    fixture.save();
    assert!(
        fixture
            .store()
            .inspect_wire(&ArtifactInspectRequest::new("JOB-1", &id).unwrap())
            .is_err()
    );
}

#[test]
fn inspect_and_read_validate_selected_projection_without_applying_list_sort_to_other_rows() {
    let mut fixture = Fixture::new();
    let id = fixture.add("selected", b"selected");
    fixture.add("other", b"other");
    fixture.rows[1]["createdAtUTC"] = json!("invalid-date");
    fixture.save();
    let reference = ArtifactInspectRequest::new("JOB-1", &id).unwrap();
    let store = fixture.store();
    assert_eq!(store.inspect_wire(&reference).unwrap()["artifactId"], id);
    assert_eq!(
        store
            .read_wire(&ArtifactReadRequest::new(reference, 0, 1, false).unwrap())
            .unwrap()["base64"],
        "cw=="
    );
    assert!(store.list("JOB-1").is_err());
}

#[test]
fn rpc_requires_the_job_owner_before_inspecting_or_reading_payloads() {
    use arkdeck_contract::WireError;
    use std::cell::Cell;
    let mut fixture = Fixture::new();
    let id = fixture.add("rpc", b"bounded-rpc");
    let store = fixture.store();
    let params = json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":id});
    let calls = Cell::new(0);
    let existing = |job: &str| {
        assert_eq!(job, "JOB-1");
        calls.set(calls.get() + 1);
        Ok(())
    };
    assert_eq!(
        store
            .handle_resource("artifact.inspect", params.as_object().unwrap(), existing)
            .unwrap()["artifactId"],
        id
    );
    assert_eq!(
        store
            .handle_resource("artifact.read", params.as_object().unwrap(), existing)
            .unwrap()["totalByteCount"],
        11
    );
    assert_eq!(calls.get(), 2);
    let denied = store
        .handle_resource("artifact.read", params.as_object().unwrap(), |_| {
            Err(WireError {
                code: "resourceNotFound".into(),
                message: "missing Job".into(),
                details: None,
            })
        })
        .unwrap_err();
    assert_eq!(denied.code, "resourceNotFound");
    assert_eq!(denied.details.unwrap()["phase"], "artifactOwner");
    for code in ["recordUnreadable", "internalError", "outcomeUnknown"] {
        assert_eq!(
            store
                .handle_resource("artifact.inspect", params.as_object().unwrap(), |_| Err(
                    WireError {
                        code: code.into(),
                        message: "unreadable Job".into(),
                        details: None,
                    }
                ))
                .unwrap_err()
                .code,
            "recordUnreadable"
        );
    }
    // Even a corrupt payload must not substitute for Job ownership discovery.
    fs::set_permissions(
        fixture.root.join("JOB-1").join(&id),
        fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    fs::write(fixture.root.join("JOB-1").join(&id), b"changed-rpc").unwrap();
    fs::set_permissions(
        fixture.root.join("JOB-1").join(&id),
        fs::Permissions::from_mode(0o400),
    )
    .unwrap();
    assert_eq!(
        store
            .handle_resource("artifact.inspect", params.as_object().unwrap(), existing)
            .unwrap_err()
            .code,
        "artifactIntegrityFailed"
    );
}

#[test]
fn rpc_refusals_preserve_the_artifact_owner_error_contract() {
    let mut fixture = Fixture::new();
    let id = fixture.add("sensitive-rpc", b"sensitive");
    fixture.rows[0]["privacy"] = json!("sensitive");
    fixture.save();
    let store = fixture.store();
    for (method, params, code) in [
        (
            "artifact.read",
            json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":id}),
            "sensitiveAccessDenied",
        ),
        (
            "artifact.read",
            json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":"missing"}),
            "resourceNotFound",
        ),
        (
            "artifact.read",
            json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":id,"maxBytes":0}),
            "invalidInput",
        ),
        (
            "artifact.inspect",
            json!({"owner":{"kind":"import","id":"imp-00000000-0000-0000-0000-000000000000"},"artifactId":id}),
            "operationUnavailable",
        ),
        (
            "artifact.inspect",
            json!({"owner":{"kind":"job","id":"../JOB-1"},"artifactId":id}),
            "invalidInput",
        ),
    ] {
        let error = store
            .handle_resource(method, params.as_object().unwrap(), |_| Ok(()))
            .unwrap_err();
        assert_eq!(error.code, code);
        assert_eq!(error.details.unwrap()["newDispatchCount"], 0);
    }
    for params in [
        json!({}),
        json!({"owner":{"kind":"job","id":"JOB-1"},"artifactId":id,"path":"/tmp"}),
    ] {
        assert_eq!(
            store
                .handle_resource("artifact.inspect", params.as_object().unwrap(), |_| panic!(
                    "malformed request entered Job owner"
                ))
                .unwrap_err()
                .code,
            "invalidInput"
        );
    }
}
