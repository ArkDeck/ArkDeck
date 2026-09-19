//! Replays the capability stores the five M2 oracles leave behind
//! (`rust/tests/fixtures/{pointer-input,port-forward,debug-hap,
//! deploy-native-library,screen-sequence}/store/capabilities`, recorded by Swift's oracle
//! contract tests) through the Rust store's writes, and checks the store's
//! refusals over synthetic capabilities in temporary stores.
//!
//! A replay installs every capability, and consumes and settles every use, in
//! an order Swift's engine could have taken them: the capabilities before the
//! last one and the uses the checkpoint holds, then the last capability, whose
//! install wrote that checkpoint, then every event of the ledger in its order.
//! The checkpoint and the ledger must then be Swift's byte for byte, and the
//! store's entries exactly Swift's, as private as Swift left them.
#![cfg(target_os = "macos")]

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

use arkdeck_hoststore::{
    CapabilityQuery, CapabilityStore, CapabilityStoreError, CapabilityUseOutcome,
    RuntimeCapability, WorkflowEffect,
};
use serde_json::{Value, json};

const CHECKPOINT: &str = "runtime-capabilities.json";
const LEDGER: &str = "runtime-capabilities.ledger";
const LOCK: &str = ".runtime-capabilities.lock";

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures")
}

/// A private scratch root under the canonical temporary directory, as a host
/// store requires its path to be.
fn scratch(label: &str) -> PathBuf {
    let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
        "arkdeck-capability-write-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
    root
}

fn text(value: &Value) -> &str {
    value.as_str().unwrap()
}

/// The query a recorded use was taken with. A use is authorized only when its
/// inputs and Artifact facts are its capability's exact ones, so those are
/// what every use of these Runtime-issued capabilities carried.
fn query(capability: &Value, use_: &Value) -> CapabilityQuery {
    let reference = text(&use_["operationReference"]);
    let (operation_id, operation_version) = match reference.split_once('@') {
        Some((id, version)) => (id, Some(version.parse().unwrap())),
        None => (reference, None),
    };
    CapabilityQuery {
        operation_id: operation_id.to_owned(),
        operation_version,
        effect: WorkflowEffect::parse(text(&use_["effect"])).unwrap(),
        target_stable_identity_sha256: use_["targetStableIdentitySHA256"]
            .as_str()
            .map(str::to_owned),
        target_binding_revision: use_["bindingRevision"].as_i64(),
        plan_digest: use_["materializedPlanDigest"].as_str().map(str::to_owned),
        inputs: capability["exactInputs"]
            .as_object()
            .cloned()
            .unwrap_or_default(),
        artifact_facts: capability["exactArtifactFacts"]
            .as_object()
            .map(|facts| {
                facts
                    .iter()
                    .map(|(name, fact)| (name.clone(), text(fact).to_owned()))
                    .collect()
            })
            .unwrap_or_default(),
        workspace_identity_sha256: None,
        workspace_revision: None,
        workspace_file_scopes_digest: None,
    }
}

/// Consumes a use as Swift recorded it, and checks the receipt against it.
fn take(store: &CapabilityStore, capability: &Value, use_: &Value) {
    let id = text(&capability["capabilityID"]);
    let receipt = store
        .consume(
            id,
            text(&use_["reservationID"]),
            Some(text(&use_["jobID"])),
            &query(capability, use_),
            text(&use_["consumedAtUTC"]),
        )
        .unwrap_or_else(|error| panic!("{id} use {}: {}", use_["ordinal"], error.swift()));
    assert_eq!(
        json!({
            "ordinal": receipt.ordinal,
            "reservationID": receipt.reservation_id,
            "jobID": receipt.job_id,
            "consumedAtUTC": receipt.consumed_at_utc,
            "operationReference": receipt.operation_reference,
            "queryFingerprintSHA256": receipt.query_fingerprint_sha256,
            "remainingUsesAfter": receipt.remaining_uses_after,
            "previousLineageSHA256": receipt.previous_lineage_sha256,
            "receiptSHA256": receipt.receipt_sha256,
        }),
        json!({
            "ordinal": use_["ordinal"],
            "reservationID": use_["reservationID"],
            "jobID": use_["jobID"],
            "consumedAtUTC": use_["consumedAtUTC"],
            "operationReference": use_["operationReference"],
            "queryFingerprintSHA256": use_["queryFingerprintSHA256"],
            "remainingUsesAfter": use_["remainingUsesAfter"],
            "previousLineageSHA256": use_.get("previousLineageSHA256").cloned().unwrap_or(Value::Null),
            "receiptSHA256": use_["receiptSHA256"],
        }),
        "{id} use {}",
        use_["ordinal"]
    );
}

/// Settles a use as Swift recorded its outcome.
fn settle(store: &CapabilityStore, id: &str, reservation: &str, outcome: &Value) {
    store
        .record_outcome(
            id,
            reservation,
            text(&outcome["jobID"]),
            CapabilityUseOutcome::parse(text(&outcome["outcome"])).unwrap(),
            text(&outcome["terminalState"]),
            text(&outcome["recordedAtUTC"]),
        )
        .unwrap_or_else(|error| panic!("{id} {reservation}: {}", error.swift()));
}

/// Replays one oracle's store and answers how many writes that took.
fn replay(oracle: &str) -> usize {
    let source = fixtures().join(oracle).join("store/capabilities");
    let checkpoint: Value =
        serde_json::from_slice(&fs::read(source.join(CHECKPOINT)).unwrap()).unwrap();
    let ledger = fs::read_to_string(source.join(LEDGER)).unwrap_or_default();
    let records = checkpoint["records"].as_array().unwrap();
    let capabilities: HashMap<&str, &Value> = records
        .iter()
        .map(|record| {
            (
                text(&record["capability"]["capabilityID"]),
                &record["capability"],
            )
        })
        .collect();
    let root = scratch(oracle);
    let directory = root.join("capabilities");
    let store = CapabilityStore::open(&directory).unwrap();
    let install = |record: &Value| {
        let capability = RuntimeCapability::from_value(&record["capability"]).unwrap();
        store.install(&capability).unwrap();
    };
    let (last, earlier) = records.split_last().unwrap();
    let mut writes = records.len();
    earlier.iter().for_each(install);
    for record in earlier {
        let id = text(&record["capability"]["capabilityID"]);
        for use_ in record["consumptions"].as_array().unwrap() {
            take(&store, &record["capability"], use_);
            let outcomes = use_["outcomes"].as_array().unwrap();
            // A second outcome may only resolve an unknown first one.
            assert!(
                outcomes.len() <= 1 || outcomes[0]["outcome"] == "outcomeUnknown",
                "{oracle}: {id} use settled twice"
            );
            for outcome in outcomes {
                settle(&store, id, text(&use_["reservationID"]), outcome);
            }
            writes += 1 + outcomes.len();
        }
    }
    assert!(
        last["consumptions"].as_array().unwrap().is_empty(),
        "{oracle}: the last install is the one that wrote the checkpoint"
    );
    install(last);
    for line in ledger.lines() {
        let event: Value = serde_json::from_str(line).unwrap();
        let id = text(&event["capabilityID"]);
        match text(&event["kind"]) {
            "consumed" => take(&store, capabilities[id], &event["consumption"]),
            "outcome" => settle(&store, id, text(&event["reservationID"]), &event["outcome"]),
            other => panic!("{oracle}: unexpected ledger event {other}"),
        }
        writes += 1;
    }

    let mut differences = Vec::new();
    for name in [CHECKPOINT, LEDGER] {
        if fs::read(directory.join(name)).ok() != fs::read(source.join(name)).ok() {
            differences.push(format!("{name} differs"));
        }
    }
    let tree: Value =
        serde_json::from_slice(&fs::read(fixtures().join(oracle).join("tree.json")).unwrap())
            .unwrap();
    let mut expected: Vec<(String, String)> = tree
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|entry| {
            let name = text(&entry["path"]).strip_prefix("store/capabilities/")?;
            Some((name.to_owned(), text(&entry["mode"]).to_owned()))
        })
        .collect();
    expected.sort();
    let mut actual: Vec<(String, String)> = fs::read_dir(&directory)
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
    actual.sort();
    if actual != expected {
        differences.push(format!("entries {actual:?}, Swift {expected:?}"));
    }
    if fs::metadata(directory.join(LOCK)).unwrap().len() != 0 {
        differences.push("the lock is not empty".into());
    }
    let _ = fs::remove_dir_all(&root);
    assert!(
        differences.is_empty(),
        "{oracle}: {}",
        differences.join("; ")
    );
    writes
}

#[test]
fn rust_writes_reproduce_the_m2_oracles_capability_stores() {
    let writes: usize = [
        "pointer-input",
        "port-forward",
        "debug-hap",
        "deploy-native-library",
        "screen-sequence",
        "capability-resolve",
    ]
    .into_iter()
    .map(replay)
    .sum();
    assert!(writes >= 60, "{writes} writes replayed");
}

// MARK: - Refusals, over synthetic capabilities

const ID: &str = "CAP-RT-SYNTHETIC-G1";
const TARGET: &str = "3ba3f5f43b92602683c19aee62a20342b084dd5971ddd33808d81a328879a547";
const NOW: &str = "2026-09-14T00:00:00Z";

/// A Runtime-issued tap capability of `maximum_uses` uses for one hour, on one
/// device at binding revision 1, pinned to one display width.
fn synthetic(id: &str, maximum_uses: i64) -> Value {
    json!({
        "capabilityID": id,
        "targetScope": {"kind": "stablePhysicalIdentity", "sha256": TARGET},
        "operationScope": [{"operationID": "input.tap", "version": 1}],
        "effectCeiling": "deviceMutation",
        "inputConstraints": {
            "displayWidth": {"kind": "integerRange", "minimum": 1280, "maximum": 1280},
        },
        "exactInputs": {"displayWidth": 1280},
        "issuedAtUTC": "2026-09-14T00:00:00Z",
        "expiresAtUTC": "2026-09-14T01:00:00Z",
        "maximumUses": maximum_uses,
        "issuer": {"kind": "runtimeDefaultPolicy", "reference": "catalog:synthetic:input.tap@1"},
        "exactBindingRevision": 1,
        "revocation": {"state": "active"},
    })
}

fn install(store: &CapabilityStore, capability: &Value) {
    store
        .install(&RuntimeCapability::from_value(capability).unwrap())
        .unwrap();
}

/// A tap at `width` on the synthetic capability's device.
fn tap(width: i64) -> CapabilityQuery {
    CapabilityQuery {
        operation_id: "input.tap".into(),
        operation_version: Some(1),
        effect: WorkflowEffect::DeviceMutation,
        target_stable_identity_sha256: Some(TARGET.into()),
        target_binding_revision: Some(1),
        plan_digest: Some("ab".repeat(32)),
        inputs: json!({"displayWidth": width}).as_object().unwrap().clone(),
        artifact_facts: BTreeMap::new(),
        workspace_identity_sha256: None,
        workspace_revision: None,
        workspace_file_scopes_digest: None,
    }
}

#[track_caller]
fn refused<T: std::fmt::Debug>(result: Result<T, CapabilityStoreError>, expected: &str) {
    match result {
        Err(error) => assert_eq!(error.swift(), expected),
        Ok(value) => panic!("expected {expected}, answered {value:?}"),
    }
}

#[track_caller]
fn denied<T: std::fmt::Debug>(result: Result<T, CapabilityStoreError>, reason: &str, detail: &str) {
    match result {
        Err(CapabilityStoreError::Denied(denial)) => {
            assert_eq!((denial.reason, denial.detail.as_str()), (reason, detail));
        }
        other => panic!("expected {reason}: {detail}, answered {other:?}"),
    }
}

fn inspect(store: &CapabilityStore, id: &str) -> Value {
    store
        .handle(
            "capability.inspect",
            json!({"capabilityId": id}).as_object().unwrap(),
        )
        .unwrap()
}

#[test]
fn installs_uses_and_outcomes_are_refused_as_swift_refuses_them() {
    use CapabilityUseOutcome::{Confirmed, OutcomeUnknown, Pending};
    let root = scratch("refusals");
    let directory = root.join("capabilities");
    let store = CapabilityStore::open(&directory).unwrap();
    install(&store, &synthetic(ID, 2));

    // The same capability again changes nothing; another under its identity
    // is refused.
    let checkpoint = fs::read(directory.join(CHECKPOINT)).unwrap();
    install(&store, &synthetic(ID, 2));
    assert_eq!(fs::read(directory.join(CHECKPOINT)).unwrap(), checkpoint);
    refused(
        store.install(&RuntimeCapability::from_value(&synthetic(ID, 3)).unwrap()),
        &format!("capabilityAlreadyInstalled(\"{ID}\")"),
    );

    // A malformed reservation or Job, and an unknown capability.
    refused(
        store.consume(ID, "", None, &tap(1280), NOW),
        "reservationConflict(\"malformed reservation ID\")",
    );
    refused(
        store.consume(ID, &"r".repeat(129), None, &tap(1280), NOW),
        "reservationConflict(\"malformed reservation ID\")",
    );
    refused(
        store.consume(ID, "r1", Some(&"j".repeat(161)), &tap(1280), NOW),
        "reservationConflict(\"malformed Job ID\")",
    );
    refused(
        store.consume("CAP-RT-UNKNOWN", "r1", None, &tap(1280), NOW),
        "capabilityNotFound(\"CAP-RT-UNKNOWN\")",
    );

    // Use 1, its retry, which writes nothing, and a drifted retry.
    let first = store
        .consume(ID, "r1", Some("job-1"), &tap(1280), NOW)
        .unwrap();
    assert_eq!(
        (
            first.ordinal,
            first.remaining_uses_after,
            first.previous_lineage_sha256.clone()
        ),
        (1, 1, None)
    );
    let ledger = fs::read(directory.join(LEDGER)).unwrap();
    assert_eq!(
        store
            .consume(ID, "r1", Some("job-1"), &tap(1280), "2026-09-14T00:00:01Z")
            .unwrap(),
        first
    );
    assert_eq!(fs::read(directory.join(LEDGER)).unwrap(), ledger);
    refused(
        store.consume(ID, "r1", Some("job-2"), &tap(1280), NOW),
        "reservationConflict(\"reservation retry fields drifted for r1\")",
    );
    refused(
        store.consume(ID, "r1", Some("job-1"), &tap(1281), NOW),
        "reservationConflict(\"reservation retry fields drifted for r1\")",
    );

    // A second use waits for the first's outcome.
    refused(
        store.consume(ID, "r2", Some("job-2"), &tap(1280), NOW),
        "lineageBlocked(\"previous use 1 is pending; new mutation dispatch is forbidden\")",
    );

    // Outcomes: what may be recorded, for which reservation and by whom.
    refused(
        store.record_outcome(ID, "r1", "job-1", Pending, "succeeded", NOW),
        "outcomeConflict(\"only confirmed, safeToReflash or outcomeUnknown may be recorded\")",
    );
    refused(
        store.record_outcome(ID, "r1", "", Confirmed, "succeeded", NOW),
        "outcomeConflict(\"malformed outcome Job ID\")",
    );
    refused(
        store.record_outcome(ID, "r1", "job-1", Confirmed, &"s".repeat(81), NOW),
        "outcomeConflict(\"malformed terminal state\")",
    );
    refused(
        store.record_outcome(ID, "r9", "job-1", Confirmed, "succeeded", NOW),
        "outcomeConflict(\"reservation r9 has no durable consumption\")",
    );
    refused(
        store.record_outcome(ID, "r1", "job-2", Confirmed, "succeeded", NOW),
        "outcomeConflict(\"outcome Job job-2 does not own reservation r1\")",
    );
    store
        .record_outcome(ID, "r1", "job-1", Confirmed, "succeeded", NOW)
        .unwrap();
    // The same outcome again, whatever its time, writes nothing.
    let ledger = fs::read(directory.join(LEDGER)).unwrap();
    store
        .record_outcome(
            ID,
            "r1",
            "job-1",
            Confirmed,
            "succeeded",
            "2026-09-14T00:00:01Z",
        )
        .unwrap();
    assert_eq!(fs::read(directory.join(LEDGER)).unwrap(), ledger);
    refused(
        store.record_outcome(ID, "r1", "job-1", OutcomeUnknown, "waitingForRecovery", NOW),
        "outcomeConflict(\"cannot change confirmed to outcomeUnknown\")",
    );

    // A use whose scope drifted from use 1's; then use 2, linked to use 1's
    // outcome and left unknown, which blocks every later use until a
    // readback resolves it.
    refused(
        store.consume(ID, "r2", Some("job-2"), &tap(1281), NOW),
        "lineageBlocked(\"operation, effect, target, binding or typed inputs drifted from authorization lineage use 1\")",
    );
    let second = store
        .consume(ID, "r2", Some("job-2"), &tap(1280), NOW)
        .unwrap();
    assert_eq!(
        second.previous_lineage_sha256.as_deref(),
        inspect(&store, ID)["lineage"][0]["outcomeHistory"][0]["recordSHA256"].as_str()
    );
    assert_eq!((second.ordinal, second.remaining_uses_after), (2, 0));
    store
        .record_outcome(ID, "r2", "job-2", OutcomeUnknown, "waitingForRecovery", NOW)
        .unwrap();
    refused(
        store.consume(ID, "r3", Some("job-3"), &tap(1280), NOW),
        "lineageBlocked(\"previous use 2 is outcomeUnknown; new mutation dispatch is forbidden\")",
    );
    assert_eq!(
        inspect(&store, ID)["lineageBlocker"],
        "use 2 is outcomeUnknown"
    );
    // A readback resolves it (Swift `resolvesUnknown`): appended after the
    // unknown outcome, which then cannot come back.
    store
        .record_outcome(ID, "r2", "job-2", Confirmed, "failed", NOW)
        .unwrap();
    let history: Vec<Value> = inspect(&store, ID)["lineage"][1]["outcomeHistory"]
        .as_array()
        .unwrap()
        .iter()
        .map(|outcome| outcome["outcome"].clone())
        .collect();
    assert_eq!(history, [json!("outcomeUnknown"), json!("confirmed")]);
    assert_ne!(
        inspect(&store, ID)["lineageBlocker"],
        "use 2 is outcomeUnknown"
    );
    refused(
        store.record_outcome(ID, "r2", "job-2", OutcomeUnknown, "waitingForRecovery", NOW),
        "outcomeConflict(\"cannot change confirmed to outcomeUnknown\")",
    );
    let _ = fs::remove_dir_all(&root);
}

/// Every change Swift refused after the resolutions of the `capability-resolve`
/// oracle is refused here with Swift's rendering, and writes nothing.
#[test]
fn a_resolved_outcome_refuses_every_further_change_as_swift_does() {
    let oracle = fixtures().join("capability-resolve");
    let source = oracle.join("store/capabilities");
    let root = scratch("resolved");
    let directory = root.join("capabilities");
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&directory)
        .unwrap();
    for name in [CHECKPOINT, LEDGER, LOCK] {
        fs::copy(source.join(name), directory.join(name)).unwrap();
        fs::set_permissions(directory.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
    let store = CapabilityStore::open(&directory).unwrap();
    let before = (
        fs::read(directory.join(CHECKPOINT)).unwrap(),
        fs::read(directory.join(LEDGER)).unwrap(),
    );
    let cases: Value =
        serde_json::from_slice(&fs::read(oracle.join("cases.json")).unwrap()).unwrap();
    let cases = cases.as_array().unwrap();
    assert!(cases.len() >= 6, "{} cases", cases.len());
    for case in cases {
        refused(
            store.record_outcome(
                text(&case["capabilityID"]),
                text(&case["reservationID"]),
                text(&case["jobID"]),
                CapabilityUseOutcome::parse(text(&case["outcome"])).unwrap(),
                text(&case["terminalState"]),
                text(&case["recordedAtUTC"]),
            ),
            text(&case["refused"]),
        );
    }
    // The same resolution again, at another time, writes nothing either.
    store
        .record_outcome(
            "CAP-RT-RESOLVE-SAFE",
            "res-s1",
            "job-s1",
            CapabilityUseOutcome::SafeToReflash,
            "failed",
            "2026-07-18T00:00:00Z",
        )
        .unwrap();
    assert_eq!(
        (
            fs::read(directory.join(CHECKPOINT)).unwrap(),
            fs::read(directory.join(LEDGER)).unwrap(),
        ),
        before
    );
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn a_new_execution_is_denied_as_swift_denies_it() {
    use CapabilityUseOutcome::Confirmed;
    let root = scratch("denials");
    let directory = root.join("capabilities");
    let store = CapabilityStore::open(&directory).unwrap();
    install(&store, &synthetic(ID, 5));
    let mut revoked = synthetic("CAP-RT-SYNTHETIC-REVOKED", 5);
    revoked["revocation"] =
        json!({"state": "revoked", "atUTC": "2026-09-14T00:00:00Z", "reason": "synthetic"});
    install(&store, &revoked);
    let checkpoint = fs::read(directory.join(CHECKPOINT)).unwrap();
    let consume = |query: &CapabilityQuery, now: &str| store.consume(ID, "r1", None, query, now);

    let mut unbound = tap(1280);
    unbound.target_binding_revision = None;
    denied(
        consume(&unbound, NOW),
        "targetIdentityRequired",
        "a device (stable identity + binding revision) or workspace (identity + revision + scope digest) subject is required",
    );
    let mut unplanned = tap(1280);
    unplanned.plan_digest = None;
    denied(
        consume(&unplanned, NOW),
        "planDigestRequired",
        "a complete materialized plan digest is required",
    );
    denied(
        store.consume("CAP-RT-SYNTHETIC-REVOKED", "r1", None, &tap(1280), NOW),
        "revoked",
        "revoked at 2026-09-14T00:00:00Z: synthetic",
    );
    denied(
        consume(&tap(1280), "2026-09-14 00:00:00"),
        "expired",
        "unverifiable clock value 2026-09-14 00:00:00",
    );
    denied(
        consume(&tap(1280), "2026-09-13T23:59:59Z"),
        "notYetValid",
        "issued at 2026-09-14T00:00:00Z",
    );
    denied(
        consume(&tap(1280), "2026-09-14T01:00:00Z"),
        "expired",
        "expired at 2026-09-14T01:00:00Z",
    );
    let mut destructive = tap(1280);
    destructive.effect = WorkflowEffect::Destructive;
    denied(
        consume(&destructive, NOW),
        "effectAboveCeiling",
        "requested destructive above ceiling deviceMutation",
    );
    let mut swipe = tap(1280);
    swipe.operation_id = "input.swipe".into();
    denied(
        consume(&swipe, NOW),
        "operationScopeMismatch",
        "input.swipe@1 not in scope",
    );
    let mut elsewhere = tap(1280);
    elsewhere.target_stable_identity_sha256 = Some("cd".repeat(32));
    denied(
        consume(&elsewhere, NOW),
        "targetScopeMismatch",
        "stable identity does not match scope",
    );
    let mut rebound = tap(1280);
    rebound.target_binding_revision = Some(2);
    denied(
        consume(&rebound, NOW),
        "targetScopeMismatch",
        "target binding revision differs",
    );
    denied(
        consume(&tap(1281), NOW),
        "inputConstraintViolated",
        "typed inputs differ from the runtime-issued envelope",
    );
    // None of these wrote anything.
    assert_eq!(fs::read(directory.join(CHECKPOINT)).unwrap(), checkpoint);
    assert!(!directory.join(LEDGER).exists());

    // An exhausted budget, once its last use is settled.
    install(&store, &synthetic("CAP-RT-SYNTHETIC-ONCE", 1));
    store
        .consume("CAP-RT-SYNTHETIC-ONCE", "r1", None, &tap(1280), NOW)
        .unwrap();
    store
        .record_outcome(
            "CAP-RT-SYNTHETIC-ONCE",
            "r1",
            "r1",
            Confirmed,
            "succeeded",
            NOW,
        )
        .unwrap();
    denied(
        store.consume("CAP-RT-SYNTHETIC-ONCE", "r2", None, &tap(1280), NOW),
        "exhausted",
        "maximumUses 1 consumed",
    );
    denied(
        store.validate_new_execution("CAP-RT-SYNTHETIC-ONCE", &tap(1280), NOW),
        "exhausted",
        "maximumUses 1 consumed",
    );
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn the_event_after_128_appended_is_folded_into_a_new_checkpoint() {
    use CapabilityUseOutcome::Confirmed;
    let root = scratch("fold");
    let directory = root.join("capabilities");
    let store = CapabilityStore::open(&directory).unwrap();
    install(&store, &synthetic(ID, 10_000));
    for use_ in 1..=64 {
        let reservation = format!("r{use_}");
        store
            .consume(ID, &reservation, None, &tap(1280), NOW)
            .unwrap();
        store
            .record_outcome(ID, &reservation, &reservation, Confirmed, "succeeded", NOW)
            .unwrap();
    }
    let lines = |directory: &Path| {
        fs::read_to_string(directory.join(LEDGER))
            .unwrap()
            .lines()
            .count()
    };
    assert_eq!(lines(&directory), 128);
    let before = fs::read(directory.join(CHECKPOINT)).unwrap();
    store.consume(ID, "r65", None, &tap(1280), NOW).unwrap();
    // The checkpoint now holds all 65 uses, and the ledger is empty.
    assert_eq!(fs::metadata(directory.join(LEDGER)).unwrap().len(), 0);
    assert_ne!(fs::read(directory.join(CHECKPOINT)).unwrap(), before);
    let checkpoint: Value =
        serde_json::from_slice(&fs::read(directory.join(CHECKPOINT)).unwrap()).unwrap();
    assert_eq!(
        checkpoint["records"][0]["consumptions"]
            .as_array()
            .unwrap()
            .len(),
        65
    );
    store
        .record_outcome(ID, "r65", "r65", Confirmed, "succeeded", NOW)
        .unwrap();
    assert_eq!(lines(&directory), 1);
    assert_eq!(inspect(&store, ID)["consumptionCount"], 65);
    let _ = fs::remove_dir_all(&root);
}
