//! The durable Rockchip host over temporary record roots and a scripted
//! executor: Swift's write-ahead discipline, replay and refusals, and the
//! bytes of the records Swift writes.
use super::*;
use crate::rockchip_action::Expectation;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

const KEY: &str = "1501ffff00000000000000000000cafe";
const PROVIDER: &str = "7777777777777777777777777777777777777777777777777777777777777777";

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-rockchip-records-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .unwrap();
        Self(path)
    }

    fn records(&self) -> PathBuf {
        self.0.join("rockchip-runtime")
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Swift's stub executor: every call recorded, one scripted answer, and an
/// optional effect on the action's directory.
struct Executor {
    answer: Result<ExecutionResult, LaneFailure>,
    calls: Mutex<Vec<String>>,
    unavailable: Option<String>,
    effect: Option<fn(&Path)>,
}

impl Executor {
    fn answering(answer: Result<ExecutionResult, LaneFailure>) -> Self {
        Self {
            answer,
            calls: Mutex::new(Vec::new()),
            unavailable: None,
            effect: None,
        }
    }

    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

impl RockchipActionExecutor for Executor {
    fn unavailable_reason(&self) -> Option<String> {
        self.unavailable.clone()
    }

    fn execute(
        &self,
        action: &RockchipAction,
        descriptor: &HostAction,
        action_directory: &Path,
    ) -> Result<ExecutionResult, LaneFailure> {
        assert!(action_directory.ends_with(&descriptor.step_id));
        assert!(
            action_directory.join("intent.json").is_file(),
            "intent first"
        );
        self.calls
            .lock()
            .unwrap()
            .push(format!("{} {}", action.identifier(), descriptor.step_id));
        if let Some(effect) = self.effect {
            effect(action_directory);
        }
        self.answer.clone()
    }
}

fn observed() -> ExecutionResult {
    ExecutionResult {
        summary: BTreeMap::from([
            (
                "hdcNormalIdentitySha256".to_owned(),
                sha256_hex(KEY.as_bytes()),
            ),
            ("usbState".to_owned(), "hdc-normal".to_owned()),
            ("usbTopology".to_owned(), "18874368".to_owned()),
        ]),
        stdout: b"observed".to_vec(),
        stderr: Vec::new(),
        stdout_truncated: false,
        subprocess_count: 1,
    }
}

fn observe() -> RockchipAction {
    RockchipAction::ObserveHdcNormalUsb(KEY.into())
}

fn enter_loader() -> RockchipAction {
    RockchipAction::EnterLoader(KEY.into())
}

fn descriptor(action: &RockchipAction, step: &str) -> HostAction {
    action.descriptor(
        "job-1",
        step,
        "TGT-1",
        2,
        KEY,
        &sha256_hex(KEY.as_bytes()),
        PROVIDER,
    )
}

fn host(root: &Root, executor: Executor) -> DurableRockchipHost<Executor> {
    DurableRockchipHost::new(executor, RockchipRecordStore::new(&root.records()))
}

fn mode(path: &Path) -> u32 {
    std::fs::symlink_metadata(path)
        .unwrap()
        .permissions()
        .mode()
        & 0o777
}

// MARK: write-ahead and replay

/// A new step: the intent is durable before the action runs, the receipt
/// after it, both owner-only in owner-only directories, and the summary
/// names the receipt. Asked again, the host replays the receipt and runs
/// nothing.
#[test]
fn a_step_runs_once_behind_its_intent_and_replays_its_receipt() {
    let root = Root::new();
    let host = host(&root, Executor::answering(Ok(observed())));
    let action = observe();
    let descriptor = descriptor(&action, "reconcile-enter-loader-mode-1");
    let first = host.execute(&action, &descriptor, PROVIDER).unwrap();
    assert_eq!(
        first.summary.get("recordID").map(String::as_str),
        Some("rockchip-runtime/job-1/reconcile-enter-loader-mode-1/receipt.json")
    );
    assert_eq!(first.stdout, b"observed");
    let directory = root.records().join("job-1/reconcile-enter-loader-mode-1");
    for path in [
        root.records(),
        root.records().join("job-1"),
        directory.clone(),
    ] {
        assert_eq!(mode(&path), 0o700, "{}", path.display());
    }
    for name in ["intent.json", "receipt.json"] {
        assert_eq!(mode(&directory.join(name)), 0o600, "{name}");
    }
    // Only the two records are left: no temporary file survives.
    let mut names: Vec<String> = std::fs::read_dir(&directory)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names, ["intent.json", "receipt.json"]);

    let replayed = host.execute(&action, &descriptor, PROVIDER).unwrap();
    assert_eq!(host.executor.calls().len(), 1, "the receipt is replayed");
    assert_eq!(replayed.summary, first.summary);
    assert!(replayed.stdout.is_empty() && replayed.stderr.is_empty());
    assert_eq!(replayed.subprocess_count, 0);
}

/// The records' bytes are the ones Swift writes: canonical JSON, keys in
/// order — Swift's own records of the same step in the Loader binding
/// oracle.
#[test]
fn the_records_are_the_bytes_swift_writes() {
    let fixture = |name: &str| {
        let bytes = std::fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/loader-binding/inputs")
                .join(name),
        )
        .unwrap();
        bytes.strip_suffix(b"\n").unwrap_or(&bytes).to_vec()
    };
    let identity = "2122a724df1a871e05fabfcb5562ad01edcf8108ab201003b3afbc64f8f3f89c";
    let root = Root::new();
    let host = host(
        &root,
        Executor::answering(Ok(ExecutionResult {
            summary: BTreeMap::from([
                ("hdcNormalIdentitySha256".to_owned(), identity.to_owned()),
                ("usbState".to_owned(), "hdc-normal".to_owned()),
                ("usbTopology".to_owned(), "18874368".to_owned()),
            ]),
            subprocess_count: 1,
            ..ExecutionResult::default()
        })),
    );
    let action = observe();
    let descriptor = HostAction {
        job_id: "job-reactivation-1".into(),
        target_id: "TGT-BOARD-A".into(),
        binding_revision: 1,
        expected_identity_sha256: identity.into(),
        ..descriptor(&action, "reconcile-enter-loader-mode-1")
    };
    host.execute(&action, &descriptor, PROVIDER).unwrap();
    let directory = root
        .records()
        .join("job-reactivation-1/reconcile-enter-loader-mode-1");
    for name in ["intent", "receipt"] {
        assert_eq!(
            std::fs::read(directory.join(format!("{name}.json"))).unwrap(),
            fixture(&format!("record-reconcile-{name}.json")),
            "{name}"
        );
    }
}

/// What the host writes is what the Loader binding reads back: a previous
/// revision's HDC-normal reconciliation and the current revision's
/// `wait-for-hdc` intent are the reactivation proof, over the digests of the
/// very bytes written.
#[test]
fn the_reactivation_reader_reads_back_what_the_host_writes() {
    let root = Root::new();
    // Swift's reader wants the root as Foundation standardizes it.
    let records = arkdeck_contract::foundation_path::standardized(&root.0).join("rockchip-runtime");
    let host = DurableRockchipHost::new(
        Executor::answering(Ok(observed())),
        RockchipRecordStore::new(&records),
    );
    let loader = "a".repeat(64);
    for (action, step, revision) in [
        (observe(), "reconcile-enter-loader-mode-1", 1),
        (
            RockchipAction::WaitForHdcReconnect(KEY.into()),
            "wait-for-hdc",
            2,
        ),
    ] {
        let descriptor = HostAction {
            binding_revision: revision,
            expected_identity_sha256: loader.clone(),
            ..descriptor(&action, step)
        };
        host.execute(&action, &descriptor, PROVIDER).unwrap();
    }
    let digest = |step: &str, name: &str| {
        sha256_hex(&std::fs::read(records.join("job-1").join(step).join(name)).unwrap())
    };
    let proof = crate::rockchip_reactivation::ReactivationProofSource::new(&records)
        .proof(&crate::rockchip_binding::BoundTarget {
            target_id: "TGT-1",
            identity_sha256: &loader,
            binding_revision: 2,
            connect_key: KEY,
        })
        .unwrap();
    assert_eq!(
        proof,
        Some(crate::rockchip_reactivation::ReactivationProof {
            target_id: "TGT-1".into(),
            binding_revision: 2,
            stable_loader_identity_sha256: loader.clone(),
            hdc_connect_key: KEY.into(),
            hdc_identity_sha256: sha256_hex(KEY.as_bytes()),
            hdc_usb_topology: "18874368".into(),
            current_binding_intent_sha256: digest("wait-for-hdc", "intent.json"),
            hdc_route_receipt_sha256: digest("reconcile-enter-loader-mode-1", "receipt.json"),
        })
    );
}

/// A read-only step whose receipt never became durable runs again; a device
/// mutation's never does: its outcome is unknown.
#[test]
fn an_intent_without_its_receipt_reruns_a_read_but_never_a_mutation() {
    let root = Root::new();
    let action = observe();
    let read = descriptor(&action, "observe");
    let host_a = host(&root, Executor::answering(Ok(observed())));
    host_a.execute(&action, &read, PROVIDER).unwrap();
    std::fs::remove_file(root.records().join("job-1/observe/receipt.json")).unwrap();
    host_a.execute(&action, &read, PROVIDER).unwrap();
    assert_eq!(host_a.executor.calls().len(), 2, "the read ran again");

    let mutation = enter_loader();
    let write = descriptor(&mutation, "enter-loader-mode");
    let host_b = host(&root, Executor::answering(Ok(observed())));
    host_b.execute(&mutation, &write, PROVIDER).unwrap();
    std::fs::remove_file(root.records().join("job-1/enter-loader-mode/receipt.json")).unwrap();
    assert_eq!(
        host_b.execute(&mutation, &write, PROVIDER),
        Err(LaneFailure::OutcomeUnknown(
            "durable Rockchip mutation intent has no receipt; original not resent".into()
        ))
    );
    assert_eq!(
        host_b.executor.calls().len(),
        1,
        "the mutation was not resent"
    );
}

/// An intent whose identity drifted is never answered: failed for a read,
/// unknown for a mutation.
#[test]
fn a_drifted_intent_refuses() {
    let root = Root::new();
    for (action, step, refusal) in [
        (
            observe(),
            "observe",
            LaneFailure::Failed("durable Rockchip read-only intent identity drifted".into()),
        ),
        (
            enter_loader(),
            "enter-loader-mode",
            LaneFailure::OutcomeUnknown(
                "durable Rockchip mutation intent identity drifted; original not resent".into(),
            ),
        ),
    ] {
        let host = host(&root, Executor::answering(Ok(observed())));
        let original = descriptor(&action, step);
        host.execute(&action, &original, PROVIDER).unwrap();
        let moved = HostAction {
            target_id: "TGT-2".into(),
            ..original
        };
        assert_eq!(host.execute(&action, &moved, PROVIDER), Err(refusal));
        assert_eq!(host.executor.calls().len(), 1);
    }
}

/// A receipt that is not this step's, or not well formed, refuses.
#[test]
fn an_invalid_receipt_refuses() {
    let root = Root::new();
    for (action, step, refusal) in [
        (
            observe(),
            "observe",
            LaneFailure::Failed("durable Rockchip read-only receipt is invalid".into()),
        ),
        (
            enter_loader(),
            "enter-loader-mode",
            LaneFailure::OutcomeUnknown(
                "durable Rockchip mutation receipt is invalid; original not resent".into(),
            ),
        ),
    ] {
        let host = host(&root, Executor::answering(Ok(observed())));
        let descriptor = descriptor(&action, step);
        host.execute(&action, &descriptor, PROVIDER).unwrap();
        let path = root.records().join("job-1").join(step).join("receipt.json");
        let original: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        // Another step's receipt, an ill-formed one.
        for (key, value) in [
            ("targetID", json!("TGT-2")),
            ("actionSHA256", json!("0".repeat(64))),
            ("stderrByteCount", json!(-1)),
            ("summary", json!({})),
        ] {
            let mut receipt = original.clone();
            receipt[key] = value;
            std::fs::write(&path, crate::session_json::encode(&receipt).unwrap()).unwrap();
            assert_eq!(
                host.execute(&action, &descriptor, PROVIDER),
                Err(refusal.clone()),
                "{key}"
            );
        }
        assert_eq!(host.executor.calls().len(), 1);
    }
}

/// A receipt is checked in Swift's Characters: fullwidth hexadecimal digits
/// are digits, and a summary key is bounded by what it reads as, not by its
/// scalars.
#[test]
fn a_receipt_is_bounded_in_swifts_characters() {
    let root = Root::new();
    let action = observe();
    let descriptor = descriptor(&action, "observe");
    let host = host(&root, Executor::answering(Ok(observed())));
    host.execute(&action, &descriptor, PROVIDER).unwrap();
    let path = root.records().join("job-1/observe/receipt.json");
    let original: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let rewrite = |key_characters: usize| {
        let mut receipt = original.clone();
        receipt["stdoutSHA256"] = json!("\u{FF41}".repeat(64));
        receipt["summary"] = json!({"e\u{301}".repeat(key_characters): "value"});
        std::fs::write(&path, crate::session_json::encode(&receipt).unwrap()).unwrap();
    };
    rewrite(128);
    let replayed = host.execute(&action, &descriptor, PROVIDER).unwrap();
    assert_eq!(replayed.summary.len(), 2, "the key and the recordID");
    rewrite(129);
    assert_eq!(
        host.execute(&action, &descriptor, PROVIDER),
        Err(LaneFailure::Failed(
            "durable Rockchip read-only receipt is invalid".into()
        ))
    );
    assert_eq!(host.executor.calls().len(), 1);
}

/// A record that is not a bounded owner-only regular file cannot be
/// recovered, in the store's own words.
#[test]
fn an_unreadable_record_cannot_be_recovered() {
    let root = Root::new();
    let action = enter_loader();
    let descriptor = descriptor(&action, "enter-loader-mode");
    let host = host(&root, Executor::answering(Ok(observed())));
    host.execute(&action, &descriptor, PROVIDER).unwrap();
    let intent = root.records().join("job-1/enter-loader-mode/intent.json");
    std::fs::set_permissions(&intent, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(
        host.execute(&action, &descriptor, PROVIDER),
        Err(LaneFailure::OutcomeUnknown(
            "durable Rockchip mutation intent cannot be recovered: failed(\"Rockchip record is \
             not a bounded owner-only regular file\")"
                .into()
        ))
    );
    std::fs::set_permissions(&intent, std::fs::Permissions::from_mode(0o600)).unwrap();
    std::fs::write(&intent, b"{\"schemaVersion\":1}").unwrap();
    assert_eq!(
        host.execute(&action, &descriptor, PROVIDER),
        Err(LaneFailure::OutcomeUnknown(
            "durable Rockchip mutation intent cannot be recovered: failed(\"the Rockchip record \
             does not decode\")"
                .into()
        ))
    );
}

/// A receipt that cannot be made durable after the action ran: a mutation's
/// effect happened, so its outcome is unknown; a read failed.
#[test]
fn a_receipt_that_cannot_be_persisted_is_unknown_for_a_mutation() {
    let root = Root::new();
    for (action, step, prefix, unknown) in [
        (
            enter_loader(),
            "enter-loader-mode",
            "external effect completed but its durable host receipt could not be persisted: ",
            true,
        ),
        (
            observe(),
            "observe",
            "read-only host receipt could not be persisted: ",
            false,
        ),
    ] {
        let mut executor = Executor::answering(Ok(observed()));
        executor.effect = Some(|directory| {
            std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o500)).unwrap()
        });
        let host = host(&root, executor);
        let outcome = host.execute(&action, &descriptor(&action, step), PROVIDER);
        let directory = root.records().join("job-1").join(step);
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let detail = format!(
            "{prefix}failed(\"cannot create owner-only Rockchip record (errno {})\")",
            libc::EACCES
        );
        assert_eq!(
            outcome,
            Err(if unknown {
                LaneFailure::OutcomeUnknown(detail)
            } else {
                LaneFailure::Failed(detail)
            })
        );
        assert!(!directory.join("receipt.json").exists());
    }
}

// MARK: the descriptor must hold before anything is written

#[test]
fn a_descriptor_that_does_not_hold_writes_nothing() {
    let action = observe();
    let good = descriptor(&action, "observe");
    let cases: [(HostAction, &str, &str); 6] = [
        (
            HostAction {
                binding_revision: 0,
                ..good.clone()
            },
            PROVIDER,
            "host-managed target/binding/executable correlation is incomplete or drifted",
        ),
        (
            HostAction {
                expected_identity_sha256: "A".repeat(64),
                ..good.clone()
            },
            PROVIDER,
            "host-managed target/binding/executable correlation is incomplete or drifted",
        ),
        (
            good.clone(),
            &"8".repeat(64),
            "host-managed target/binding/executable correlation is incomplete or drifted",
        ),
        (
            HostAction {
                action_sha256: "0".repeat(64),
                ..good.clone()
            },
            PROVIDER,
            "host-managed typed action digest drifted after materialization",
        ),
        (
            HostAction {
                connect_key: "another-key".into(),
                ..good.clone()
            },
            PROVIDER,
            "host-managed typed action does not match its target/descriptor",
        ),
        (
            HostAction {
                job_id: "../escape".into(),
                ..good
            },
            PROVIDER,
            "jobID is not a bounded path component",
        ),
    ];
    for (descriptor, provider, refusal) in cases {
        let root = Root::new();
        let host = host(&root, Executor::answering(Ok(observed())));
        assert_eq!(
            host.execute(&action, &descriptor, provider),
            Err(LaneFailure::Failed(refusal.into())),
            "{refusal}"
        );
        assert!(host.executor.calls().is_empty());
        assert!(
            std::fs::read_dir(root.records())
                .map(|entries| entries.count() == 0)
                .unwrap_or(true),
            "nothing written for {refusal}"
        );
    }
}

/// An executor's failure is the host's, and leaves the intent without a
/// receipt.
#[test]
fn an_executor_failure_is_returned_as_it_is() {
    let root = Root::new();
    let action = RockchipAction::WaitForBoundHdcReconnect(Expectation {
        previous_connect_key: KEY.into(),
        previous_identity_sha256: sha256_hex(KEY.as_bytes()),
        usb_topology: "18874368".into(),
    });
    let failure = LaneFailure::OutcomeUnknown("process timed out before completion".into());
    let host = host(&root, Executor::answering(Err(failure.clone())));
    assert_eq!(
        host.execute(&action, &descriptor(&action, "wait-for-hdc"), PROVIDER),
        Err(failure)
    );
    let directory = root.records().join("job-1/wait-for-hdc");
    assert!(directory.join("intent.json").is_file());
    assert!(!directory.join("receipt.json").exists());
}

#[test]
fn the_executor_is_unavailable_before_the_records_are() {
    let root = Root::new();
    let mut executor = Executor::answering(Ok(observed()));
    executor.unavailable = Some("descriptor-bound HDC executable is unavailable".into());
    let host = host(&root, executor);
    assert_eq!(
        host.unavailable_reason().as_deref(),
        Some("descriptor-bound HDC executable is unavailable")
    );
    let host = DurableRockchipHost::new(
        Executor::answering(Ok(observed())),
        RockchipRecordStore::new(Path::new("relative/rockchip-runtime")),
    );
    assert_eq!(
        host.unavailable_reason().as_deref(),
        Some(
            "durable Rockchip host record root is unavailable: failed(\"Rockchip record path is \
             not canonical\")"
        )
    );
    let host = self::host(&root, Executor::answering(Ok(observed())));
    assert_eq!(host.unavailable_reason(), None);
}
