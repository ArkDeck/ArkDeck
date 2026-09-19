//! The tool-selection store against Swift's own files
//! (`rust/tests/fixtures/tool-selection-store`, recorded by
//! `ToolSelectionStoreOracleContractTests` from the production
//! `RuntimeToolSelectionControlActionStore`): every record reads as its own
//! canonical bytes and projects as Swift projected it, the store lists the
//! directory in Swift's order, and every timeline played again with Swift's
//! instants and identities leaves Swift's bytes. Then what the oracle cannot
//! show: a member more or less refused at every level, Swift's replacement
//! rules and transition refusals, and a directory Rust writes, checked in at
//! `rust/tests/fixtures/tool-selection-store-rust` for Swift to read back
//! (`ToolSelectionStoreRustReadbackContractTests`).
use super::*;
use arkdeck_contract::{canonical_json, strict_json};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::PathBuf;

/// 2026-09-01T00:00:00Z, the oracle's clock; its n-th timeline starts
/// n × 1000 s later.
const START: u64 = 1_788_220_800_000;
/// The console challenge the oracle answered.
const CHALLENGE: &str = "ARKDECK-A1B2C3D4E";

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../tests/fixtures/{name}"))
}

fn object(value: &Value) -> Map<String, Value> {
    value.as_object().expect("an object").clone()
}

fn read(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

/// One recorded request: its file, state, generation and transitions.
struct Case {
    request: String,
    file: String,
    state: String,
    generation: String,
    steps: Vec<String>,
}

fn cases() -> Vec<Case> {
    let cases = read(&fixture("tool-selection-store/cases.json"));
    cases
        .as_object()
        .unwrap()
        .iter()
        .map(|(request, case)| Case {
            request: request.clone(),
            file: case["file"].as_str().unwrap().to_owned(),
            state: case["state"].as_str().unwrap().to_owned(),
            generation: case["generation"].as_str().unwrap().to_owned(),
            steps: case["steps"]
                .as_array()
                .unwrap()
                .iter()
                .map(|step| step.as_str().unwrap().to_owned())
                .collect(),
        })
        .collect()
}

fn parse(bytes: &[u8]) -> Result<ToolSelectionRecord, WireError> {
    let Ok(Value::Object(fields)) = strict_json(bytes) else {
        panic!("not a strict JSON object");
    };
    ToolSelectionRecord::parse(fields)
}

fn code<T: std::fmt::Debug>(result: Result<T, WireError>) -> String {
    result.unwrap_err().code
}

/// A private state directory with the owner's `records`, removed on drop.
struct Directory(PathBuf);

impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "tool-selection-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        fs::DirBuilder::new()
            .mode(0o700)
            .create(path.join("records"))
            .unwrap();
        Self(path)
    }

    fn records(&self) -> PathBuf {
        self.0.join("records")
    }

    /// The records directory as the owner keeps it, from `source`.
    fn copied(source: &Path) -> Self {
        let directory = Self::new();
        for entry in fs::read_dir(source).unwrap() {
            let entry = entry.unwrap();
            let target = directory.records().join(entry.file_name());
            fs::copy(entry.path(), &target).unwrap();
            fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        }
        directory
    }

    fn store(&self) -> ToolSelectionRecords {
        ToolSelectionRecords::open(&self.records()).unwrap()
    }
}

impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn every_swift_record_is_read_as_its_own_canonical_bytes() {
    let cases = cases();
    assert_eq!(cases.len(), 17);
    let mut states: Vec<_> = cases.iter().map(|case| case.state.as_str()).collect();
    states.sort_unstable();
    states.dedup();
    assert_eq!(states.len(), STATES.len(), "{states:?}");
    for case in &cases {
        let bytes = fs::read(fixture("tool-selection-store").join(&case.file)).unwrap();
        let record = parse(&bytes).unwrap_or_else(|error| panic!("{}: {error:?}", case.request));
        assert_eq!(
            canonical_json(&Value::Object(record.value().clone())).unwrap(),
            bytes,
            "{}",
            case.request
        );
        assert_eq!(record.intent().request(), case.request);
        assert_eq!(record.state(), case.state, "{}", case.request);
        assert_eq!(record.generation().to_string(), case.generation);
    }
}

#[test]
fn the_store_lists_swifts_directory_with_swifts_projections() {
    let directory = Directory::copied(&fixture("tool-selection-store/records"));
    let store = directory.store();
    let records = store.list().unwrap();
    let projections: Vec<Value> = records
        .iter()
        .map(ToolSelectionRecord::projection)
        .collect();
    assert_eq!(
        Value::Array(projections),
        read(&fixture("tool-selection-store/projections.json"))
    );
    // Looked up by identity and by request, as the owner does.
    let first = &records[0];
    assert_eq!(store.load(first.id()).unwrap().as_ref(), Some(first));
    assert_eq!(
        store
            .load_request(first.intent().request())
            .unwrap()
            .as_ref(),
        Some(first)
    );
    assert_eq!(store.load("control-action-none").unwrap(), None);
    assert_eq!(code(store.load("control action")), "invalidInput");
}

/// The instant of `key` in `fields`.
fn at(fields: &Map<String, Value>, key: &str) -> u64 {
    time(fields[key].as_str().unwrap()).unwrap()
}

/// The part of `text` after `prefix`: an identity Swift drew.
fn drawn<'a>(fields: &'a Map<String, Value>, key: &str, prefix: &str) -> &'a str {
    fields[key].as_str().unwrap().strip_prefix(prefix).unwrap()
}

/// The impact a record's preview was published with.
fn published_impact(preview: &Map<String, Value>) -> SelectionImpact {
    let hdc: Map<String, Value> = preview
        .iter()
        .filter(|(key, _)| {
            !PREVIEW_METADATA.contains(&key.as_str())
                && !["oldTool", "newTool", "expectedActiveGeneration"].contains(&key.as_str())
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    SelectionImpact::new(
        Impact::new(hdc).unwrap(),
        ToolFacts::parse(object(&preview["oldTool"])).unwrap(),
        ToolFacts::parse(object(&preview["newTool"])).unwrap(),
        generation(preview["expectedActiveGeneration"].as_str().unwrap()).unwrap(),
    )
    .unwrap()
}

/// Plays one recorded timeline through `store` with the instants and
/// identities its final record holds, and returns that record.
fn play(
    store: &ToolSelectionRecords,
    case: &Case,
    last: &ToolSelectionRecord,
) -> ToolSelectionRecord {
    let value = last.value();
    let created = at(value, "createdAt");
    let seconds = |offset: u64| created + offset * 1000;
    let preview = value["preview"].as_object();
    let approval = value["humanAction"].as_object();
    let audit = value["selectionAudit"].as_array().unwrap();
    let intent = ToolSelectionIntent::parse(value["intent"].as_object().unwrap()).unwrap();
    let mut record = store
        .begin(
            &intent,
            value["catalogDigest"].as_str().unwrap(),
            value["runtimeEpoch"].as_str().unwrap(),
            created,
            drawn(value, "controlActionId", "control-action-"),
        )
        .unwrap();
    let mut rows = audit.iter().map(object);
    for step in &case.steps[1..] {
        let (name, argument) = match step.split_once('(') {
            Some((name, rest)) => (name, rest.strip_suffix(')')),
            None => (step.as_str(), None),
        };
        let next = match name {
            "publishing" => {
                let preview = preview.unwrap();
                record.publishing(
                    &published_impact(preview),
                    value["observationRelations"].as_array().unwrap(),
                    (argument == Some("blocked")).then_some("hdc.criticalJobsUnresolved"),
                    at(preview, "createdAt"),
                    drawn(preview, "previewId", "preview-"),
                )
            }
            "requestingImpactApproval" => {
                let approval = approval.unwrap();
                record.requesting_impact_approval(
                    at(approval, "createdAt"),
                    drawn(approval, "actionId", "har-"),
                    drawn(approval, "resumeReference", "resume-"),
                )
            }
            // A challenge a later invalidation withdrew left no identity.
            "issuingInteractiveChallenge" => match value["interactionChallenge"].as_object() {
                Some(challenge) => record.issuing_interactive_challenge(
                    CHALLENGE,
                    at(challenge, "issuedAt"),
                    drawn(challenge, "challengeId", "challenge-"),
                ),
                None => record.issuing_interactive_challenge(
                    CHALLENGE,
                    seconds(3),
                    "00000000-0000-4000-8000-000000000000",
                ),
            },
            "recordingInteractiveApproval" => {
                let receipt = value["interactionReceipt"].as_object().unwrap();
                record.recording_interactive_approval(
                    CHALLENGE,
                    at(receipt, "confirmedAt"),
                    drawn(receipt, "receiptId", "interaction-"),
                )
            }
            "prepared" => record.prepared(at(&rows.next().unwrap(), "recordedAt")),
            "appendingLifecycleAudit" => {
                let row = rows.next().unwrap();
                assert_eq!(row["kind"].as_str(), argument);
                record.appending_lifecycle_audit(
                    argument.unwrap(),
                    row["auditId"].as_str().unwrap(),
                    object(&row["payload"]),
                    at(&row, "recordedAt"),
                )
            }
            "failedBeforeLaunch" => {
                let row = rows.next().unwrap();
                record.failed_before_launch(argument.unwrap(), at(&row, "recordedAt"))
            }
            "settled" => {
                let row = rows.next().unwrap();
                record.settled(
                    row["result"].as_str().unwrap(),
                    row["activeToolRef"].as_str().unwrap(),
                    generation(row["activeGeneration"].as_str().unwrap()).unwrap(),
                    row["reasonCode"].as_str(),
                    at(&row, "recordedAt"),
                )
            }
            "invalidated" => {
                let reason = argument.unwrap();
                record.invalidated(
                    reason,
                    reason == "controlAction.expired",
                    at(value, "lastObservedAt"),
                )
            }
            other => panic!("unknown step {other}"),
        }
        .unwrap_or_else(|error| panic!("{} {step}: {error:?}", case.request));
        store.replace(&next, record.generation()).unwrap();
        record = next;
    }
    assert!(rows.next().is_none(), "{} leaves audit rows", case.request);
    record
}

#[test]
fn every_swift_timeline_plays_again_byte_for_byte() {
    let directory = Directory::new();
    let store = directory.store();
    let mut played = 0;
    for case in cases() {
        // Its audit rows come from the lifecycle Supervisor, not a step here.
        if case.request == "oracle-lifecycle" {
            continue;
        }
        let bytes = fs::read(fixture("tool-selection-store").join(&case.file)).unwrap();
        let recorded = parse(&bytes).unwrap();
        let record = play(&store, &case, &recorded);
        assert_eq!(record, recorded, "{}", case.request);
        // The store's own file holds Swift's bytes.
        let name = case.file.strip_prefix("records/").unwrap();
        assert_eq!(
            fs::read(directory.records().join(name)).unwrap(),
            bytes,
            "{}",
            case.request
        );
        played += 1;
    }
    assert_eq!(played, 16);
    let mut names: Vec<_> = fs::read_dir(directory.records())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    assert_eq!(names.len(), 17, "16 records and the lock: {names:?}");
    assert_eq!(fs::read(directory.records().join(".lock")).unwrap(), b"");
}

/// Swift's record with every nested member: its approval resolved, the
/// challenge it answered and the receipt of that answer.
fn approved() -> Map<String, Value> {
    let case = cases()
        .into_iter()
        .find(|case| case.request == "oracle-approved")
        .unwrap();
    let Ok(Value::Object(fields)) =
        strict_json(&fs::read(fixture("tool-selection-store").join(case.file)).unwrap())
    else {
        panic!("not an object");
    };
    fields
}

#[test]
fn a_member_more_or_less_is_refused_at_every_level() {
    let record = approved();
    assert!(ToolSelectionRecord::parse(record.clone()).is_ok());
    // Each nested object, by its path from the record.
    let paths: [&[&str]; 9] = [
        &[],
        &["intent"],
        &["preview"],
        &["preview", "oldTool"],
        &["preview", "oldTool", "signature"],
        &["preview", "newTool", "trust"],
        &["humanAction"],
        &["interactionChallenge"],
        &["interactionReceipt"],
    ];
    for path in paths {
        let target = |fields: &mut Map<String, Value>| -> Map<String, Value> {
            let mut current = &mut *fields;
            for key in path {
                current = current.get_mut(*key).unwrap().as_object_mut().unwrap();
            }
            current.clone()
        };
        let edit = |change: &dyn Fn(&mut Map<String, Value>)| {
            let mut fields = record.clone();
            let mut current = &mut fields;
            for key in path {
                current = current.get_mut(*key).unwrap().as_object_mut().unwrap();
            }
            change(current);
            fields
        };
        let first = target(&mut record.clone()).keys().next().unwrap().clone();
        for changed in [
            edit(&|fields| {
                fields.insert("unexpected".into(), json!(true));
            }),
            edit(&|fields| {
                fields.remove(&first);
            }),
        ] {
            assert_eq!(
                code(ToolSelectionRecord::parse(changed)),
                "recordUnreadable",
                "{path:?}"
            );
        }
    }
    // Each nested type refuses on its own too.
    let preview = object(&record["preview"]);
    for (value, parse) in [
        (
            object(&preview["oldTool"]),
            (|fields| ToolFacts::parse(fields).map(|_| ()))
                as fn(Map<String, Value>) -> Result<(), WireError>,
        ),
        (object(&record["humanAction"]), |fields| {
            ImpactApproval::parse(fields).map(|_| ())
        }),
        (object(&record["interactionChallenge"]), |fields| {
            InteractionChallenge::parse(fields).map(|_| ())
        }),
        (object(&record["interactionReceipt"]), |fields| {
            InteractionReceipt::parse(fields).map(|_| ())
        }),
    ] {
        assert!(parse(value.clone()).is_ok());
        let mut extra = value.clone();
        extra.insert("unexpected".into(), Value::Null);
        assert_eq!(code(parse(extra)), "recordUnreadable");
        let mut missing = value.clone();
        let key = missing.keys().next_back().unwrap().clone();
        missing.remove(&key);
        assert_eq!(code(parse(missing)), "recordUnreadable");
    }
    // A preview whose impact is not canonical, re-signed so only that fails.
    let mut unsorted = record.clone();
    let preview = unsorted["preview"].as_object_mut().unwrap();
    preview.insert("affectedTargetIds".into(), json!(["target-b", "target-a"]));
    preview.remove("previewDigest");
    let signed = hash(&Value::Object(preview.clone())).unwrap();
    preview.insert("previewDigest".into(), json!(signed));
    assert_eq!(
        ToolSelectionRecord::parse(unsorted).unwrap_err().message,
        "stored tool-selection impact is not canonical"
    );
}

#[test]
fn the_bindings_between_state_and_nested_records_are_swifts() {
    let record = approved();
    for (key, value) in [
        // An approved record without its receipt, or with a dispatch.
        ("interactionReceipt", Value::Null),
        ("dispatchCount", json!(1)),
        ("state", json!("previewReady")),
        ("state", json!("awaitingImpactApproval")),
    ] {
        let mut changed = record.clone();
        changed.insert(key.into(), value.clone());
        assert_eq!(
            ToolSelectionRecord::parse(changed).unwrap_err().message,
            "tool-selection owner bindings contradict its state",
            "{key} {value}"
        );
    }
    // Another action's approval.
    let mut foreign = record.clone();
    foreign["humanAction"]
        .as_object_mut()
        .unwrap()
        .insert("controlActionId".into(), json!("control-action-other"));
    assert_eq!(
        code(ToolSelectionRecord::parse(foreign)),
        "recordUnreadable"
    );
    for (key, value) in [
        ("dispatchCount", json!(2)),
        ("dispatchCount", json!(0.0)),
        ("generation", json!("01")),
        ("expiresAt", json!("2026-09-01T03:25:40.000Z")),
        ("requestFingerprint", json!("0".repeat(64))),
        ("selectionAudit", json!([1])),
        ("observationRelations", Value::Array(vec![json!(null); 257])),
    ] {
        let mut changed = record.clone();
        changed.insert(key.into(), value.clone());
        assert_eq!(
            ToolSelectionRecord::parse(changed).unwrap_err().message,
            "tool-selection control action is malformed",
            "{key} {value}"
        );
    }
}

/// A fresh `observing` record in `store` for `request`, at `now`.
fn begun(store: &ToolSelectionRecords, request: &str, now: u64) -> ToolSelectionRecord {
    let intent = ToolSelectionIntent::parse(&object(&json!({
        "actionRequestId": request, "tool": format!("tool:sha256:{}", "b".repeat(64)),
        "expectedActiveGeneration": "1",
    })))
    .unwrap();
    store
        .begin(
            &intent,
            &"c".repeat(64),
            "epoch",
            now,
            "00000000-0000-4000-8000-000000000001",
        )
        .unwrap()
}

/// The oracle's ready preview impact.
fn ready_impact() -> SelectionImpact {
    let case = cases()
        .into_iter()
        .find(|case| case.request == "oracle-preview-ready")
        .unwrap();
    let record = read(&fixture("tool-selection-store").join(case.file));
    published_impact(record["preview"].as_object().unwrap())
}

#[test]
fn the_store_replaces_only_what_swift_replaces() {
    let directory = Directory::new();
    let store = directory.store();
    let observing = begun(&store, "rules", START);
    // The same request and intent is the same record; another intent is not.
    assert_eq!(begun(&store, "rules", START + 1), observing);
    let other = ToolSelectionIntent::parse(&object(&json!({
        "actionRequestId": "rules", "tool": format!("tool:sha256:{}", "e".repeat(64)),
        "expectedActiveGeneration": "1",
    })))
    .unwrap();
    assert_eq!(
        code(store.begin(&other, &"c".repeat(64), "epoch", START, "x")),
        "idempotencyConflict"
    );
    let impact = ready_impact();
    let ready = observing
        .publishing(
            &impact,
            &[],
            None,
            START + 1000,
            "00000000-0000-4000-8000-000000000002",
        )
        .unwrap();
    // Only the exact next generation.
    assert_eq!(code(store.replace(&ready, 2)), "resourceConflict");
    store.replace(&ready, 1).unwrap();
    assert_eq!(code(store.replace(&ready, 1)), "resourceConflict");
    // A published preview is never replaced.
    let mut other_preview = ready.value().clone();
    other_preview.insert("generation".into(), json!("3"));
    other_preview["preview"]
        .as_object_mut()
        .unwrap()
        .insert("previewId".into(), json!("preview-other"));
    assert!(ToolSelectionRecord::parse(other_preview).is_err());
    let awaiting = ready
        .requesting_impact_approval(
            START + 2000,
            "00000000-0000-4000-8000-000000000003",
            "00000000-0000-4000-8000-000000000004",
        )
        .unwrap();
    store.replace(&awaiting, 2).unwrap();
    let challenged = awaiting
        .issuing_interactive_challenge(
            CHALLENGE,
            START + 3000,
            "00000000-0000-4000-8000-000000000005",
        )
        .unwrap();
    store.replace(&challenged, 3).unwrap();
    let approved = challenged
        .recording_interactive_approval(
            CHALLENGE,
            START + 4000,
            "00000000-0000-4000-8000-000000000006",
        )
        .unwrap();
    store.replace(&approved, 4).unwrap();
    // The store admits `failed` only once dispatch was prepared, although
    // the record's own transition accepts an approval too (as Swift's).
    let early = approved
        .failed_before_launch("tool.lifecycleFailedBeforeLaunch", START + 5000)
        .unwrap();
    assert_eq!(code(store.replace(&early, 5)), "resourceConflict");
    let prepared = approved.prepared(START + 5000).unwrap();
    store.replace(&prepared, 5).unwrap();
    // The audit grows by one row at a time and never loses one.
    let one = prepared
        .appending_lifecycle_audit(
            "impactPreview",
            "00000000-0000-4000-8000-000000000007",
            Map::new(),
            START + 6000,
        )
        .unwrap();
    let two = one
        .appending_lifecycle_audit(
            "confirmation",
            "00000000-0000-4000-8000-000000000008",
            Map::new(),
            START + 7000,
        )
        .unwrap();
    let mut skipped = two.value().clone();
    skipped.insert("generation".into(), json!("7"));
    assert_eq!(
        code(store.replace(&ToolSelectionRecord::parse(skipped).unwrap(), 6)),
        "resourceConflict"
    );
    store.replace(&one, 6).unwrap();
    let mut dropped = one.value().clone();
    dropped.insert("generation".into(), json!("8"));
    dropped.insert("selectionAudit".into(), json!([]));
    assert_eq!(
        code(store.replace(&ToolSelectionRecord::parse(dropped).unwrap(), 7)),
        "resourceConflict"
    );
    // The resolved approval never waits again.
    let mut waiting = one.value().clone();
    waiting.insert("generation".into(), json!("8"));
    waiting["humanAction"]
        .as_object_mut()
        .unwrap()
        .insert("status".into(), json!("waiting"));
    assert_eq!(
        code(store.replace(&ToolSelectionRecord::parse(waiting).unwrap(), 7)),
        "resourceConflict"
    );
    // Its clock never runs back.
    assert_eq!(
        code(one.appending_lifecycle_audit("intent", "a", Map::new(), START)),
        "orchestrationClockUntrusted"
    );
    // A second holder of the transaction lock is refused, nothing written.
    let holder = arkdeck_platform::HostDirectory::open(&directory.records()).unwrap();
    let _held = holder.lock_document(".lock").unwrap();
    assert_eq!(code(store.list()), "resourceConflict");
}

#[test]
fn transitions_refuse_as_swift_does() {
    let directory = Directory::new();
    let store = directory.store();
    let observing = begun(&store, "refusals", START);
    let identity = "00000000-0000-4000-8000-000000000009";
    assert_eq!(
        code(observing.requesting_impact_approval(START + 1000, identity, identity)),
        "admissionDenied"
    );
    assert_eq!(
        code(observing.issuing_interactive_challenge(CHALLENGE, START + 1000, identity)),
        "humanActionExpired"
    );
    assert_eq!(
        code(observing.recording_interactive_approval(CHALLENGE, START + 1000, identity)),
        "impactApprovalChallengeExpired"
    );
    assert_eq!(code(observing.prepared(START + 1000)), "recordUnreadable");
    // Publishing twice keeps the first preview.
    let impact = ready_impact();
    let ready = observing
        .publishing(&impact, &[], None, START + 1000, identity)
        .unwrap();
    assert_eq!(
        ready
            .publishing(
                &impact,
                &[],
                Some("hdc.serverHealthUnproven"),
                START + 2000,
                "b"
            )
            .unwrap(),
        ready
    );
    let awaiting = ready
        .requesting_impact_approval(START + 2000, identity, identity)
        .unwrap();
    let challenged = awaiting
        .issuing_interactive_challenge(CHALLENGE, START + 3000, identity)
        .unwrap();
    // One challenge only; the wrong text, or the right one too late, is refused.
    assert_eq!(
        code(challenged.issuing_interactive_challenge(CHALLENGE, START + 4000, identity)),
        "humanActionExpired"
    );
    assert_eq!(
        code(challenged.recording_interactive_approval(
            "ARKDECK-000000000",
            START + 4000,
            identity
        )),
        "impactApprovalChallengeMismatch"
    );
    assert_eq!(
        code(challenged.recording_interactive_approval(CHALLENGE, START + 123_000, identity)),
        "impactApprovalChallengeExpired"
    );
    // A launch window is entered once, and only while prepared.
    let prepared = challenged
        .recording_interactive_approval(CHALLENGE, START + 4000, identity)
        .unwrap()
        .prepared(START + 5000)
        .unwrap();
    let launched = prepared
        .appending_lifecycle_audit("launchWindowEntered", identity, Map::new(), START + 6000)
        .unwrap();
    assert_eq!(
        (launched.state(), launched.value()["dispatchCount"].clone()),
        ("outcomeUnknown", json!(1))
    );
    assert_eq!(
        launched
            .appending_lifecycle_audit("launchWindowEntered", identity, Map::new(), START + 7000)
            .unwrap_err()
            .message,
        "tool-selection launch window was already entered"
    );
    assert_eq!(
        code(launched.appending_lifecycle_audit("restart", identity, Map::new(), START + 7000)),
        "recordUnreadable"
    );
    assert_eq!(
        code(launched.settled("unknown", "tool:sha256:x", 1, None, START + 7000)),
        "recordUnreadable"
    );
    // The projection names what comes next.
    assert_eq!(challenged.projection()["nextAction"]["kind"], "humanAction");
    assert_eq!(
        launched.projection()["nextAction"]["reasonCode"],
        "tool.selectionRecomposePending"
    );
}

// --- records Rust writes, for Swift to read back ---------------------------

/// `next` in place of `record`, as its exact next generation.
fn advance(
    store: &ToolSelectionRecords,
    record: &mut ToolSelectionRecord,
    next: ToolSelectionRecord,
) {
    store.replace(&next, record.generation()).unwrap();
    *record = next;
}

/// Rust's own timelines, with identities and instants it chooses: one
/// record of each kind of nested member Swift reads.
fn write_rust_records(store: &ToolSelectionRecords) {
    // 2026-09-02T00:00:00Z.
    let base = START + 86_400_000;
    let impact = ready_impact();
    let uuid = |n: u64| format!("00000000-0000-4000-8000-{n:012}");
    let intent = |request: &str| {
        ToolSelectionIntent::parse(&object(&json!({
            "actionRequestId": request, "tool": format!("tool:sha256:{}", "b".repeat(64)),
            "expectedActiveGeneration": "1",
        })))
        .unwrap()
    };
    let challenge = "ARKDECK-RUST00001";
    for (index, request) in [
        "rust-observing",
        "rust-challenged",
        "rust-approved",
        "rust-succeeded",
        "rust-expired",
    ]
    .into_iter()
    .enumerate()
    {
        let index = index as u64;
        let now = |seconds: u64| base + index * 1_000_000 + seconds * 1000;
        let id = |n: u64| uuid(index * 100 + n);
        let mut record = store
            .begin(
                &intent(request),
                &"c".repeat(64),
                "epoch-rust",
                now(0),
                &id(1),
            )
            .unwrap();
        if request == "rust-observing" {
            continue;
        }
        let next = record
            .publishing(&impact, &[], None, now(1), &id(2))
            .unwrap();
        advance(store, &mut record, next);
        let next = record
            .requesting_impact_approval(now(2), &id(3), &id(4))
            .unwrap();
        advance(store, &mut record, next);
        if request == "rust-expired" {
            let next = record
                .invalidated("controlAction.expired", true, now(301))
                .unwrap();
            advance(store, &mut record, next);
            continue;
        }
        let next = record
            .issuing_interactive_challenge(challenge, now(3), &id(5))
            .unwrap();
        advance(store, &mut record, next);
        if request == "rust-challenged" {
            continue;
        }
        let next = record
            .recording_interactive_approval(challenge, now(4), &id(6))
            .unwrap();
        advance(store, &mut record, next);
        if request == "rust-approved" {
            continue;
        }
        let next = record.prepared(now(5)).unwrap();
        advance(store, &mut record, next);
        for (offset, kind) in [
            "impactPreview",
            "confirmation",
            "intent",
            "actualCommand",
            "launchWindowEntered",
            "outcome",
            "reconciliation",
        ]
        .into_iter()
        .enumerate()
        {
            let payload = object(&json!({
                "writer": "arkdeck-hoststore", "kind": kind, "offset": offset,
                "fraction": 1.5, "text": "é \u{1} /", "absent": null,
            }));
            let next = record
                .appending_lifecycle_audit(
                    kind,
                    &id(10 + offset as u64),
                    payload,
                    now(6 + offset as u64),
                )
                .unwrap();
            advance(store, &mut record, next);
        }
        let next = record
            .settled(
                "succeeded",
                &format!("tool:sha256:{}", "b".repeat(64)),
                2,
                None,
                now(13),
            )
            .unwrap();
        advance(store, &mut record, next);
    }
}

#[test]
fn rust_written_records_are_the_checked_in_ones() {
    let directory = Directory::new();
    let store = directory.store();
    write_rust_records(&store);
    let records = store.list().unwrap();
    let mut files = BTreeMap::new();
    for entry in fs::read_dir(directory.records()).unwrap() {
        let entry = entry.unwrap();
        files.insert(
            format!("records/{}", entry.file_name().into_string().unwrap()),
            fs::read(entry.path()).unwrap(),
        );
    }
    let projections: Vec<Value> = records
        .iter()
        .map(ToolSelectionRecord::projection)
        .collect();
    let mut pretty = serde_json::to_vec_pretty(&Value::Array(projections)).unwrap();
    pretty.push(b'\n');
    files.insert("projections.json".into(), pretty);
    let states: BTreeMap<_, _> = records
        .iter()
        .map(|record| {
            (
                record.intent().request().to_owned(),
                record.state().to_owned(),
            )
        })
        .collect();
    assert_eq!(
        states.values().map(String::as_str).collect::<Vec<_>>(),
        [
            "approvalRecorded",
            "awaitingImpactApproval",
            "expired",
            "observing",
            "succeeded"
        ]
    );
    if let Some(output) = std::env::var_os("ARKDECK_TOOL_SELECTION_RUST_RECORD") {
        let output = PathBuf::from(output);
        assert!(output.starts_with("/private/tmp/") && !output.exists());
        for (path, bytes) in &files {
            let target = output.join(path);
            fs::create_dir_all(target.parent().unwrap()).unwrap();
            fs::write(target, bytes).unwrap();
        }
        return;
    }
    let checked_in = fixture("tool-selection-store-rust");
    let mut expected = BTreeMap::new();
    for directory in [checked_in.clone(), checked_in.join("records")] {
        for entry in fs::read_dir(&directory).unwrap() {
            let entry = entry.unwrap();
            if entry.file_type().unwrap().is_file() {
                let relative = entry.path().strip_prefix(&checked_in).unwrap().to_owned();
                expected.insert(
                    relative.to_string_lossy().into_owned(),
                    fs::read(entry.path()).unwrap(),
                );
            }
        }
    }
    assert_eq!(
        files.keys().collect::<Vec<_>>(),
        expected.keys().collect::<Vec<_>>()
    );
    for (path, bytes) in &files {
        assert_eq!(bytes, &expected[path], "{path}");
    }
}
