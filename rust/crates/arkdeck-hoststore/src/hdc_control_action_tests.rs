//! Swift `HDCControlActionContractTests`' owner cases, ported: the intent and
//! its fingerprint, the canonical impact, the preview digest, the blocker
//! order, the store's CAS and lock, and the coordinator's preview, reconcile
//! and age refresh over a source and a clock the test holds.
use super::*;
use std::collections::VecDeque;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// 2026-09-01T00:00:00.000Z, the instant the committed frames name.
const NOW: u64 = 1_788_220_800_000;
const CATALOG: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn reference(endpoint: &str) -> String {
    format!("hdc-endpoint:{}", sha256_hex(endpoint.as_bytes()))
}

fn object(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

fn intent(request: &str, generation: &str) -> Map<String, Value> {
    object(json!({
        "action": "restart", "actionRequestId": request,
        "serverEndpointRef": reference("127.0.0.1:8710"),
        "expectedServerGeneration": generation,
    }))
}

/// Swift's fixture impact: a healthy server of the expected generation,
/// nothing affected, the gate clear.
fn impact_fields() -> Map<String, Value> {
    object(json!({
        "serverEndpointRef": reference("127.0.0.1:8710"), "endpoint": "127.0.0.1:8710",
        "serverOwnership": "unknown", "serverGeneration": "100000023",
        "serverHealth": "healthy", "serverVersion": "3.2.0d",
        "tool": {"reference": null, "executablePath": "/fixture/hdc",
            "source": "runtimeConfiguration", "sha256": "b".repeat(64), "signature": null,
            "version": "3.2.0d", "trust": "unknown"},
        "affectedTargetIds": [], "affectedJobIds": [], "detectedOtherClientIds": [],
        "otherClientsMayExist": true, "affectedDeviceObservations": [],
        "criticalJobGate": {"state": "clear", "blocking": [], "reasonCode": null},
        "interruption": {"kind": "hdcEndpointUnavailable", "affectsAllParticipants": true},
        "recovery": {"kind": "statusThenReconcile", "replayAllowed": false},
    }))
}

fn impact(changes: Value) -> Result<Impact, WireError> {
    let mut fields = impact_fields();
    for (key, value) in object(changes) {
        fields.insert(key, value);
    }
    Impact::new(fields)
}

fn reading(changes: Value) -> ImpactReading {
    ImpactReading {
        impact: impact(changes).unwrap(),
        relations: Vec::new(),
        blocker: None,
    }
}

fn code(result: Result<impl std::fmt::Debug, WireError>) -> String {
    result.unwrap_err().code
}

struct Directory(PathBuf);

impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "hdc-control-action-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .unwrap();
        Self(path)
    }

    fn records(&self) -> PathBuf {
        self.0.join("records")
    }

    fn names(&self) -> Vec<String> {
        let mut names: Vec<_> = std::fs::read_dir(self.records())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        names
    }
}

impl Drop for Directory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A source the test answers: a reading or an unavailable impact, counted.
struct Source {
    reference: String,
    reading: Mutex<Result<ImpactReading, String>>,
    reads: AtomicUsize,
}

impl Source {
    fn new(reading: Result<ImpactReading, String>) -> Self {
        Self {
            reference: reference("127.0.0.1:8710"),
            reading: Mutex::new(reading),
            reads: AtomicUsize::new(0),
        }
    }

    fn set(&self, reading: Result<ImpactReading, String>) {
        *self.reading.lock().unwrap() = reading;
    }

    fn reads(&self) -> usize {
        self.reads.load(Ordering::SeqCst)
    }
}

impl ImpactSource for Source {
    fn endpoint_reference(&self) -> String {
        self.reference.clone()
    }

    fn read_impact(&self) -> Result<ImpactReading, String> {
        self.reads.fetch_add(1, Ordering::SeqCst);
        self.reading.lock().unwrap().clone()
    }
}

/// An owner over `directory` with the test's epoch, catalog and clock, and
/// identities taken from `ids` (then random ones).
fn owner(
    directory: &Directory,
    epoch: &str,
    catalog: &str,
    clock: &Arc<AtomicU64>,
    ids: &[&str],
) -> HdcControlActions {
    let clock = Arc::clone(clock);
    let ids = Mutex::new(
        ids.iter()
            .map(|id| (*id).to_owned())
            .collect::<VecDeque<_>>(),
    );
    HdcControlActions::open(
        &directory.0,
        OwnerContext {
            epoch: epoch.into(),
            catalog: catalog.into(),
            clock: Box::new(move || Some(clock.load(Ordering::SeqCst))),
            uuid: Box::new(move || match ids.lock().unwrap().pop_front() {
                Some(id) => Ok(id),
                None => crate::snapshot_pager::uuid(),
            }),
        },
    )
    .unwrap()
}

#[test]
fn an_intent_is_exact_and_its_fingerprint_covers_the_intent_only() {
    let a = Intent::parse(&intent("request-one", "100000023")).unwrap();
    let b = Intent::parse(&intent("lost-receipt-retry", "100000023")).unwrap();
    assert_eq!(a.fingerprint().unwrap(), b.fingerprint().unwrap());
    assert_eq!(
        a.fingerprint().unwrap(),
        "32df6c7f4db9ccefb1eba90a7cc9154e7dca50e737022bc5d0b2cda14ddd17bb"
    );
    let c = Intent::parse(&intent("request-one", "100000024")).unwrap();
    assert_ne!(a.fingerprint().unwrap(), c.fingerprint().unwrap());
    let refused = |fields: Map<String, Value>| {
        let error = Intent::parse(&fields).unwrap_err();
        assert_eq!(
            (error.code.as_str(), error.message.as_str()),
            (
                "invalidInput",
                "an exact restart intent and request identity are required"
            ),
            "{fields:?}"
        );
    };
    for (key, value) in [
        ("generation", json!("7")),
        ("executablePath", json!("/usr/bin/false")),
        ("confirmation", json!(true)),
    ] {
        let mut fields = intent("request-one", "100000023");
        fields.insert(key.into(), value);
        refused(fields);
    }
    for text in [
        "0",
        "01",
        "+1",
        "-1",
        "18446744073709551615",
        "9223372036854775808",
    ] {
        refused(intent("request-one", text));
    }
    let mut stop = intent("request-one", "100000023");
    stop.insert("action".into(), json!("stop"));
    refused(stop);
    refused(intent("request one", "100000023"));
    let mut other = intent("request-one", "100000023");
    other.insert("serverEndpointRef".into(), json!("hdc-endpoint:ABC"));
    refused(other);
    let mut missing = intent("request-one", "100000023");
    missing.remove("expectedServerGeneration");
    refused(missing);
    assert_eq!(
        Intent::parse(&intent("request-one", "9223372036854775807"))
            .unwrap()
            .generation,
        i64::MAX as u64
    );
}

#[test]
fn impact_collections_collapse_equal_values_and_sort_in_byte_order() {
    let row = json!({"observationId": "obs-1", "generation": "2",
        "authorization": "authorized", "health": "connected"});
    let a = impact(json!({"affectedTargetIds": ["z", "A", "z"],
        "affectedDeviceObservations": [row.clone(), row.clone()]}))
    .unwrap();
    assert_eq!(a.value()["affectedTargetIds"], json!(["A", "z"]));
    assert_eq!(
        a.value()["affectedDeviceObservations"],
        json!([row.clone()])
    );
    let mut other = row.clone();
    other["generation"] = json!("3");
    assert_eq!(
        impact(json!({"affectedDeviceObservations": [row.clone(), other]}))
            .unwrap_err()
            .message,
        "the same impact identity carries conflicting facts"
    );
    let blocker = json!({"jobId": "job-1", "stepId": "step-2", "state": "running",
        "safeBoundary": "blocked", "recovery": "waitForJob"});
    let mut changed = blocker.clone();
    changed["recovery"] = json!("reconcileJob");
    assert_eq!(
        code(impact(
            json!({"affectedJobIds": ["job-1"], "criticalJobGate": {
            "state": "blocked", "reasonCode": "job.running",
            "blocking": [blocker.clone(), changed]}})
        )),
        "factsDrifted"
    );
    // Blockers sort by job, then step; an absent step sorts first.
    let early = json!({"jobId": "job-1", "stepId": null, "state": "running",
        "safeBoundary": "blocked", "recovery": "waitForJob"});
    let gate = impact(json!({"affectedJobIds": ["job-2", "job-1"], "criticalJobGate": {
        "state": "blocked", "reasonCode": "hdc.currentJobs",
        "blocking": [blocker.clone(), early.clone(), {"jobId": "job-2", "stepId": null, "state": "queued",
            "safeBoundary": "unknown", "recovery": "inspectJob"}]}}))
    .unwrap();
    let ordered: Vec<_> = gate.value()["criticalJobGate"]["blocking"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| (row["jobId"].clone(), row["stepId"].clone()))
        .collect();
    assert_eq!(
        ordered,
        [
            (json!("job-1"), Value::Null),
            (json!("job-1"), json!("step-2")),
            (json!("job-2"), Value::Null)
        ]
    );
    assert_eq!(gate.value()["affectedJobIds"], json!(["job-1", "job-2"]));
    for (changes, message) in [
        (
            json!({"otherClientsMayExist": false}),
            "impact facts do not match the closed lifecycle schema",
        ),
        (
            json!({"endpoint": "127.0.0.1:8711"}),
            "impact facts do not match the closed lifecycle schema",
        ),
        (
            json!({"serverGeneration": "0"}),
            "impact facts do not match the closed lifecycle schema",
        ),
        (
            json!({"tool": {"reference": null}}),
            "selected tool facts are incomplete",
        ),
        (
            json!({"tool": {"reference": null, "executablePath": "/fixture/hdc",
                "source": "runtimeConfiguration", "sha256": null,
                "signature": {"state": "adHoc", "identifier": "hdc", "teamIdentifier": null,
                    "platformTrust": "verified", "executionAssessment": "notPerformed"},
                "version": null, "trust": "unverified"}}),
            "selected signature facts are incomplete",
        ),
        (
            json!({"affectedTargetIds": ["a b"]}),
            "impact collection has an invalid identity",
        ),
        (
            json!({"affectedTargetIds": "a"}),
            "impact ID collection is unavailable or too large",
        ),
        (
            json!({"affectedDeviceObservations": [1]}),
            "impact row is not an object",
        ),
        (
            json!({"criticalJobGate": {"state": "clear", "blocking": []}}),
            "critical Job gate is incomplete",
        ),
        (
            json!({"criticalJobGate": {"state": "clear", "blocking": [], "reasonCode": "x"}}),
            "critical Job gate contradicts its blockers",
        ),
        (
            json!({"criticalJobGate": {"state": "unknown", "blocking": [], "reasonCode": null}}),
            "critical Job gate contradicts its blockers",
        ),
        (
            json!({"criticalJobGate": {"state": "blocked", "blocking": [],
                "reasonCode": "hdc.currentJobs"}}),
            "critical Job gate contradicts its blockers",
        ),
        (
            json!({"criticalJobGate": {"state": "blocked", "reasonCode": "hdc.currentJobs",
                "blocking": [early.clone()]}}),
            "a critical Job is absent from the impact inventory",
        ),
    ] {
        let error = impact(changes.clone()).unwrap_err();
        assert_eq!(
            (error.code.as_str(), error.message.as_str()),
            ("factsDrifted", message),
            "{changes}"
        );
    }
    // The canonical bytes are bounded.
    let many: Vec<String> = (0..4096).map(|index| format!("{index:0>128}")).collect();
    assert_eq!(
        code(impact(json!({"affectedTargetIds": many}))),
        "inputTooLarge"
    );
}

#[test]
fn the_preview_digest_is_the_committed_frames_digest() {
    let impact = Impact::new(impact_fields()).unwrap();
    let preview = Preview::build(
        "control-action-accf9f29-7fc0-4a6a-b18c-9105d6cefbaa",
        "preview-76cea92c-d4e2-483c-bdce-8c22e429d66e",
        "2026-09-01T00:00:00.000Z",
        "2026-09-01T00:05:00.000Z",
        &impact,
    )
    .unwrap();
    assert_eq!(
        preview.value["previewDigest"],
        "93018d9ea5cc752d60ecc03f3aced1b3cc1538dde27c9025a222b0122392beee"
    );
    // Every value is covered: a changed one no longer reads.
    for (key, value) in [
        ("serverOwnership", json!("arkDeckManaged")),
        ("serverGeneration", json!("100000024")),
        ("affectedJobIds", json!(["new-job"])),
        ("otherClientsMayExist", json!(false)),
        ("expiresAt", json!("2026-09-01T00:05:00.001Z")),
    ] {
        let mut changed = preview.value.clone();
        changed.insert(key.into(), value);
        assert_eq!(code(Preview::parse(changed)), "recordUnreadable", "{key}");
    }
    // An unsorted collection with its own digest is not canonical.
    let mut unsorted = preview.value.clone();
    unsorted.insert("affectedTargetIds".into(), json!(["z", "a"]));
    unsorted.remove("previewDigest");
    let digest = hash(&Value::Object(unsorted.clone())).unwrap();
    unsorted.insert("previewDigest".into(), json!(digest));
    assert_eq!(
        Preview::parse(unsorted).unwrap_err().message,
        "stored impact collections are not canonical"
    );
    assert_ne!(
        preview.value["previewDigest"],
        json!(
            Intent::parse(&intent("request-one", "100000023"))
                .unwrap()
                .fingerprint()
                .unwrap()
        )
    );
}

#[test]
fn blockers_come_in_swift_order() {
    let intent = Intent::parse(&intent("request-one", "100000023")).unwrap();
    let unknown_gate = json!({"state": "unknown", "blocking": [],
        "reasonCode": "hdc.participantInventoryUnproven"});
    for (changes, own, expected) in [
        // No proved identity comes first, whatever else holds.
        (
            json!({"serverGeneration": null, "criticalJobGate": unknown_gate.clone(),
                "serverHealth": "unknown", "serverVersion": null}),
            None,
            Some("hdc.serverIdentityUnproven"),
        ),
        (
            json!({"serverGeneration": "100000024", "criticalJobGate": unknown_gate.clone()}),
            None,
            Some("hdc.serverGenerationChanged"),
        ),
        (
            json!({"criticalJobGate": unknown_gate.clone(), "serverHealth": "unknown"}),
            None,
            Some("hdc.criticalJobsUnresolved"),
        ),
        (
            json!({"serverHealth": "unknown", "serverVersion": null}),
            Some("hdc.serverHealthUnproven"),
            Some("hdc.serverHealthUnproven"),
        ),
        (
            json!({}),
            Some("hdc.serverFactsDrifted"),
            Some("hdc.serverFactsDrifted"),
        ),
        (json!({}), None, None),
    ] {
        let mut reading = reading(changes.clone());
        reading.blocker = own.map(str::to_owned);
        assert_eq!(blocker(&reading, &intent).as_deref(), expected, "{changes}");
    }
    // Another endpoint than the intent's is another server.
    let mut elsewhere = impact_fields();
    elsewhere.insert("endpoint".into(), json!("127.0.0.1:8711"));
    elsewhere.insert(
        "serverEndpointRef".into(),
        json!(reference("127.0.0.1:8711")),
    );
    let reading = ImpactReading {
        impact: Impact::new(elsewhere).unwrap(),
        relations: Vec::new(),
        blocker: None,
    };
    assert_eq!(
        blocker(&reading, &intent).as_deref(),
        Some("hdc.serverGenerationChanged")
    );
}

#[test]
fn the_store_keeps_one_record_per_request_and_replaces_it_by_generation_only() {
    let directory = Directory::new();
    let clock = Arc::new(AtomicU64::new(NOW));
    let _owner = owner(&directory, "epoch", CATALOG, &clock, &[]);
    let a = Store::open(&directory.records()).unwrap();
    let b = Store::open(&directory.records()).unwrap();
    let request = Intent::parse(&intent("request-one", "100000023")).unwrap();
    let initial = a.begin(&request, CATALOG, "epoch-1", NOW, "first").unwrap();
    assert_eq!(initial.id, "control-action-first");
    assert_eq!(initial.state, "observing");
    // A lost receipt finds the same action, whatever else changed.
    assert_eq!(
        b.begin(&request, &"c".repeat(64), "epoch-2", NOW + 20_000, "second")
            .unwrap(),
        initial
    );
    let other = Intent::parse(&intent("request-one", "2")).unwrap();
    assert_eq!(
        b.begin(&other, CATALOG, "epoch-1", NOW, "third")
            .unwrap_err()
            .code,
        "idempotencyConflict"
    );
    let published = initial
        .publishing(&reading(json!({})), None, NOW + 1_000, "preview-one")
        .unwrap();
    assert_eq!(published.state, "previewReady");
    a.replace(&published, 1).unwrap();
    assert_eq!(
        b.replace(&published, 1).unwrap_err().code,
        "resourceConflict"
    );
    assert_eq!(b.load(&initial.id).unwrap(), Some(published.clone()));
    assert_eq!(b.list().unwrap(), std::slice::from_ref(&published));
    assert_eq!(b.list().unwrap(), std::slice::from_ref(&published));
    // A second preview never replaces the first.
    let mut replaced = initial
        .publishing(
            &reading(json!({"serverOwnership": "external"})),
            None,
            NOW + 2_000,
            "preview-two",
        )
        .unwrap()
        .value;
    replaced.insert("generation".into(), json!("3"));
    let replaced = Record::parse(replaced).unwrap();
    assert_eq!(
        b.replace(&replaced, 2).unwrap_err().code,
        "resourceConflict"
    );
    let stopped = published
        .invalidated("hdc.previewDrifted", false, NOW + 3_000)
        .unwrap();
    b.replace(&stopped, 2).unwrap();
    assert_eq!(
        Store::open(&directory.records())
            .unwrap()
            .load_request("request-one")
            .unwrap(),
        Some(stopped.clone())
    );
    assert_eq!(stopped.preview, published.preview);
    // An invalidated record is final: invalidating it again is itself.
    assert_eq!(
        stopped
            .invalidated("controlAction.expired", true, NOW + 4_000)
            .unwrap(),
        stopped
    );
    // One owner-only record named by its request identity, beside the lock.
    let name = format!("action-{}.json", sha256_hex(b"request-one"));
    assert_eq!(directory.names(), [".lock".to_owned(), name.clone()]);
    let mode = std::fs::metadata(directory.records().join(&name))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600);
    // The record is its canonical bytes.
    let bytes = std::fs::read(directory.records().join(&name)).unwrap();
    assert_eq!(
        bytes,
        canonical_json(&Value::Object(stopped.value.clone())).unwrap()
    );
}

#[test]
fn another_holder_of_the_transaction_lock_is_refused_before_anything_is_written() {
    let directory = Directory::new();
    let clock = Arc::new(AtomicU64::new(NOW));
    let _owner = owner(&directory, "epoch", CATALOG, &clock, &[]);
    let store = Store::open(&directory.records()).unwrap();
    // Another open description of the same lock, as another process holds it.
    let holder = HostDirectory::open(&directory.records()).unwrap();
    let held = holder.lock_document(".lock").unwrap();
    let request = Intent::parse(&intent("request-one", "100000023")).unwrap();
    let error = store
        .begin(&request, CATALOG, "epoch", NOW, "first")
        .unwrap_err();
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        (
            "resourceConflict",
            "another Runtime owner holds the control-action transaction"
        )
    );
    assert_eq!(directory.names(), [".lock"]);
    drop(held);
    assert_eq!(
        store
            .begin(&request, CATALOG, "epoch", NOW, "first")
            .unwrap()
            .generation,
        1
    );
}

#[test]
fn interrupted_publications_are_removed_and_other_content_is_refused() {
    let directory = Directory::new();
    let clock = Arc::new(AtomicU64::new(NOW));
    let _owner = owner(&directory, "epoch", CATALOG, &clock, &[]);
    let store = Store::open(&directory.records()).unwrap();
    let request = Intent::parse(&intent("request-one", "100000023")).unwrap();
    store
        .begin(&request, CATALOG, "epoch", NOW, "first")
        .unwrap();
    let hex = sha256_hex(b"request-one");
    for name in [
        format!(".action-{hex}.json.{}.part", "a".repeat(32)),
        format!(".action-{hex}.json.00000000-0000-4000-8000-000000000000.tmp"),
    ] {
        let path = directory.records().join(&name);
        std::fs::write(&path, b"{").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(store.list().unwrap().len(), 1);
        assert!(!path.exists(), "{name} was not removed");
    }
    let stray = directory.records().join("notes.txt");
    std::fs::write(&stray, b"x").unwrap();
    std::fs::set_permissions(&stray, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(
        store.list().unwrap_err().message,
        "unexpected content in control-action directory"
    );
    std::fs::remove_file(&stray).unwrap();
    // A record whose name is not its request identity's.
    let name = format!("action-{hex}.json");
    std::fs::rename(
        directory.records().join(&name),
        directory
            .records()
            .join(format!("action-{}.json", "0".repeat(64))),
    )
    .unwrap();
    assert_eq!(
        store.list().unwrap_err().message,
        "control-action record name or identity is inconsistent"
    );
}

#[test]
fn records_this_owner_does_not_hold_or_that_contradict_themselves_are_refused() {
    let request = Intent::parse(&intent("request-one", "100000023")).unwrap();
    let record = Record::new(&request, CATALOG, "epoch", NOW, "first").unwrap();
    let with = |key: &str, value: Value| {
        let mut fields = record.value.clone();
        fields.insert(key.into(), value);
        Record::parse(fields)
    };
    // An approval, a challenge, a receipt or an audit is not read here.
    for key in ["humanAction", "interactionChallenge", "interactionReceipt"] {
        let error = with(key, json!({"actionId": "har-1"})).unwrap_err();
        assert_eq!(
            (error.code.as_str(), error.message.as_str()),
            (
                "recordUnreadable",
                "control-action state cannot be read or persisted"
            ),
            "{key}"
        );
    }
    assert_eq!(
        code(with("lifecycleAudit", json!([{"kind": "impactPreview"}]))),
        "recordUnreadable"
    );
    for (key, value, message) in [
        (
            "requestFingerprint",
            json!("0".repeat(64)),
            "control-action intent fingerprint is invalid",
        ),
        (
            "expiresAt",
            json!("2026-09-01T00:05:00.001Z"),
            "control-action record has invalid identity or state",
        ),
        (
            "state",
            json!("running"),
            "control-action record has invalid identity or state",
        ),
        (
            "state",
            json!("previewReady"),
            "ready control action has no preview",
        ),
        (
            "state",
            json!("blocked"),
            "blocked control action has no reason",
        ),
        (
            "blockerReasonCode",
            json!("hdc.serverIdentityUnproven"),
            "unobserved action has resolved facts",
        ),
        (
            "preview",
            json!("preview"),
            "control-action preview is malformed",
        ),
    ] {
        let error = with(key, value.clone()).unwrap_err();
        assert_eq!(
            (error.code.as_str(), error.message.as_str()),
            ("recordUnreadable", message),
            "{key} {value}"
        );
    }
    // A stored request that is no exact intent refuses as the intent does.
    assert_eq!(
        code(with("request", json!({"action": "restart"}))),
        "invalidInput"
    );
    // A ready preview needs its whole gate: a blocked impact is not ready.
    let blocked = record
        .publishing(
            &reading(json!({"serverHealth": "unknown", "serverVersion": null})),
            Some("hdc.serverHealthUnproven"),
            NOW,
            "preview-one",
        )
        .unwrap();
    let mut forged = blocked.value.clone();
    forged.insert("state".into(), json!("previewReady"));
    forged.insert("blockerReasonCode".into(), Value::Null);
    assert_eq!(
        Record::parse(forged).unwrap_err().message,
        "ready preview lacks its complete gate"
    );
    let mut awaiting = blocked.value.clone();
    awaiting.insert("state".into(), json!("awaitingImpactApproval"));
    assert_eq!(code(Record::parse(awaiting)), "recordUnreadable");
}

#[test]
fn a_preview_is_observed_once_read_back_and_invalidated_by_a_drifted_reconciliation() {
    let directory = Directory::new();
    let clock = Arc::new(AtomicU64::new(NOW));
    let owner = owner(
        &directory,
        "epoch",
        CATALOG,
        &clock,
        &["one", "preview-one"],
    );
    let source = Source::new(Ok(reading(json!({}))));
    let first = owner
        .preview(&intent("request-one", "100000023"), &source)
        .unwrap();
    assert_eq!(first["state"], "previewReady");
    assert_eq!(first["controlActionId"], "control-action-one");
    assert_eq!(first["preview"]["previewId"], "preview-preview-one");
    assert_eq!(first["generation"], "2");
    assert_eq!(first["dispatchCount"], 0);
    assert_eq!(
        first["nextAction"],
        json!({"kind": "inspectControlAction",
            "owner": {"kind": "controlAction", "id": "control-action-one"},
            "resource": {"kind": "controlAction", "id": "control-action-one"},
            "reasonCode": "controlAction.previewAvailable"})
    );
    let again = owner
        .preview(&intent("request-one", "100000023"), &source)
        .unwrap();
    assert_eq!(again, first);
    assert_eq!(source.reads(), 1);
    assert_eq!(owner.show("control-action-one").unwrap(), first);
    assert_eq!(
        owner
            .list_records()
            .unwrap()
            .iter()
            .map(Record::projection)
            .collect::<Vec<_>>(),
        std::slice::from_ref(&first)
    );
    // The same impact again changes nothing.
    assert_eq!(
        owner.reconcile("control-action-one", &source).unwrap(),
        first
    );
    assert_eq!(source.reads(), 2);
    source.set(Ok(reading(
        json!({"detectedOtherClientIds": ["another-client"]}),
    )));
    let changed = owner.reconcile("control-action-one", &source).unwrap();
    assert_eq!(changed["state"], "previewDrifted");
    assert_eq!(changed["blockerReasonCode"], "hdc.previewDrifted");
    assert_eq!(changed["preview"], first["preview"]);
    assert_eq!(changed["generation"], "3");
    assert_eq!(changed["dispatchCount"], 0);
    assert_eq!(
        owner
            .preview(&intent("request-one", "100000023"), &source)
            .unwrap(),
        changed
    );
    assert_eq!(
        owner.show("control-action-none").unwrap_err().message,
        "control action does not exist"
    );
    assert_eq!(
        code(owner.preview(&intent("request-one", "100000024"), &source)),
        "idempotencyConflict"
    );
}

#[test]
fn an_unavailable_or_unproved_impact_never_makes_a_ready_preview() {
    let directory = Directory::new();
    let clock = Arc::new(AtomicU64::new(NOW));
    let owner = owner(&directory, "epoch", CATALOG, &clock, &[]);
    let source = Source::new(Err("empty observation output".into()));
    let unobserved = owner
        .preview(&intent("request-one", "100000023"), &source)
        .unwrap();
    assert_eq!(unobserved["state"], "previewDrifted");
    assert_eq!(
        unobserved["blockerReasonCode"],
        "hdc.impactObservationUnavailable"
    );
    assert_eq!(unobserved["preview"], Value::Null);
    assert_eq!(unobserved["generation"], "2");
    assert_eq!(unobserved["nextAction"]["kind"], "reconcile");
    // A final state is only read: reconciling does not observe.
    let id = unobserved["controlActionId"].as_str().unwrap();
    assert_eq!(owner.reconcile(id, &source).unwrap(), unobserved);
    assert_eq!(source.reads(), 1);
    for (request, changes, blocker) in [
        (
            "unproved-identity",
            json!({"serverGeneration": null, "serverHealth": "unknown", "serverVersion": null}),
            "hdc.serverIdentityUnproven",
        ),
        (
            "unresolved-jobs",
            json!({"criticalJobGate": {"state": "unknown", "blocking": [],
                "reasonCode": "job.inventoryUnreadable"}}),
            "hdc.criticalJobsUnresolved",
        ),
        (
            "unproved-health",
            json!({"serverHealth": "unknown", "serverVersion": null}),
            "hdc.serverHealthUnproven",
        ),
    ] {
        source.set(Ok(reading(changes)));
        let blocked = owner
            .preview(&intent(request, "100000023"), &source)
            .unwrap();
        assert_eq!(blocked["state"], "blocked", "{request}");
        assert_eq!(blocked["blockerReasonCode"], blocker, "{request}");
        assert_eq!(blocked["humanAction"], Value::Null);
        assert_eq!(blocked["nextAction"]["reasonCode"], blocker);
        // A blocked preview is reconciled against a fresh reading; an
        // unavailable one invalidates it.
        let id = blocked["controlActionId"].as_str().unwrap().to_owned();
        assert_eq!(owner.reconcile(&id, &source).unwrap(), blocked);
        source.set(Err("device list unavailable".into()));
        let invalid = owner.reconcile(&id, &source).unwrap();
        assert_eq!(invalid["state"], "previewDrifted");
        assert_eq!(
            invalid["blockerReasonCode"],
            "hdc.impactObservationUnavailable"
        );
        assert_eq!(invalid["preview"], blocked["preview"]);
    }
    // Another endpoint than the source's persists nothing.
    let mut elsewhere = intent("elsewhere", "100000023");
    elsewhere.insert(
        "serverEndpointRef".into(),
        json!(reference("127.0.0.1:8711")),
    );
    let error = owner.preview(&elsewhere, &source).unwrap_err();
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        (
            "resourceNotFound",
            "the exact HDC endpoint reference is not configured"
        )
    );
    assert_eq!(owner.list_records().unwrap().len(), 4);
}

#[test]
fn age_invalidates_an_open_action_when_it_is_read() {
    let directory = Directory::new();
    let clock = Arc::new(AtomicU64::new(NOW));
    let source = Source::new(Ok(reading(json!({}))));
    let a = owner(&directory, "epoch-a", CATALOG, &clock, &[]);
    let first = a
        .preview(&intent("request-one", "100000023"), &source)
        .unwrap();
    let id = first["controlActionId"].as_str().unwrap().to_owned();
    // Another Runtime start.
    clock.fetch_add(60_000, Ordering::SeqCst);
    let b = owner(&directory, "epoch-b", CATALOG, &clock, &[]);
    let restarted = b.show(&id).unwrap();
    assert_eq!(restarted["state"], "previewDrifted");
    assert_eq!(
        restarted["blockerReasonCode"],
        "controlAction.runtimeRestarted"
    );
    assert_eq!(restarted["preview"], first["preview"]);
    assert_eq!(restarted["lastObservedAt"], "2026-09-01T00:01:00.000Z");
    assert_eq!(source.reads(), 1);
    // 300 s after its creation.
    let second = b
        .preview(&intent("request-two", "100000023"), &source)
        .unwrap();
    let second_id = second["controlActionId"].as_str().unwrap().to_owned();
    clock.fetch_add(299_999, Ordering::SeqCst);
    assert_eq!(b.show(&second_id).unwrap(), second);
    clock.fetch_add(1, Ordering::SeqCst);
    let expired = b.show(&second_id).unwrap();
    assert_eq!(expired["state"], "expired");
    assert_eq!(expired["blockerReasonCode"], "controlAction.expired");
    assert_eq!(expired["generation"], "3");
    // Another catalog.
    let c = owner(&directory, "epoch-b", &"c".repeat(64), &clock, &[]);
    let third = b
        .preview(&intent("request-three", "100000023"), &source)
        .unwrap();
    let changed = c.show(third["controlActionId"].as_str().unwrap()).unwrap();
    assert_eq!(changed["blockerReasonCode"], "controlAction.catalogChanged");
    assert_eq!(source.reads(), 3);
    // A clock behind the last observation is not trusted.
    let fourth = c
        .preview(&intent("request-four", "100000023"), &source)
        .unwrap();
    clock.fetch_sub(1, Ordering::SeqCst);
    let error = c
        .show(fourth["controlActionId"].as_str().unwrap())
        .unwrap_err();
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        (
            "orchestrationClockUntrusted",
            "control-action clock moved backwards"
        )
    );
}
