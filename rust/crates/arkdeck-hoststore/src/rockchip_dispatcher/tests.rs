//! The dispatcher against Swift's `RockchipRuntimeCompositionContractTests`:
//! a configured `arkforged` measured from a real file, and a host whose
//! executor records what it was asked to run.
use super::*;
use crate::rockchip_records::ExecutionResult;
use arkdeck_contract::sha256_hex;
use std::collections::BTreeMap;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-rockchip-dispatcher-{}-{}",
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

    /// A configured `arkforged`: an executable file and its digest.
    fn arkforged(&self) -> (NativeRockUsbIdentity, String) {
        let path = self.0.join("arkforged");
        std::fs::write(&path, b"#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        let digest = sha256_hex(&std::fs::read(&path).unwrap());
        (
            NativeRockUsbIdentity::configured(
                Some(path.to_string_lossy().into_owned()),
                Some(digest.clone()),
            ),
            digest,
        )
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Swift's `SuccessfulActionExecutor`: every action verified, and logged.
#[derive(Clone, Default)]
struct Executor(Arc<Mutex<Vec<RockchipAction>>>);

impl RockchipActionExecutor for Executor {
    fn unavailable_reason(&self) -> Option<String> {
        None
    }

    fn execute(
        &self,
        action: &RockchipAction,
        _descriptor: &HostAction,
        _action_directory: &Path,
    ) -> Result<ExecutionResult, LaneFailure> {
        self.0.lock().unwrap().push(action.clone());
        Ok(ExecutionResult {
            summary: BTreeMap::from([("semantic".to_owned(), "verified".to_owned())]),
            stdout: b"done".to_vec(),
            ..ExecutionResult::default()
        })
    }
}

fn enter_loader(job: &str, provider: &str) -> HostAction {
    RockchipAction::EnterLoader("device-1".into()).descriptor(
        job,
        "enter-loader",
        "TGT-1",
        1,
        "device-1",
        &"a".repeat(64),
        provider,
    )
}

/// Swift `testProductionRockchipRouteUsesReviewedSignedIdentityAndRejectsLegacyPlan`:
/// an action materialized against the configured `arkforged` runs once and
/// names its durable record; one materialized against another executable is
/// refused before the host.
#[test]
fn only_the_configured_arkforged_authorizes_an_action() {
    let root = Root::new();
    let (identity, digest) = root.arkforged();
    let executor = Executor::default();
    let dispatcher = NativeRockchipDispatcher::durable(identity, executor.clone(), &root.0);
    assert_eq!(dispatcher.unavailable_reason(), None);

    let receipt = dispatcher
        .dispatch(&enter_loader("job-signed", &digest))
        .unwrap();
    let record = "rockchip-runtime/job-signed/enter-loader/receipt.json";
    assert_eq!(
        receipt,
        HostReceipt {
            exit_status: Some(0),
            stdout: b"done".to_vec(),
            stderr: Vec::new(),
            stdout_truncated: false,
            duration_seconds: 0.0,
            record_id: Some(record.into()),
            summary: BTreeMap::from([
                ("recordID".to_owned(), record.to_owned()),
                ("semantic".to_owned(), "verified".to_owned()),
            ]),
        }
    );
    assert!(root.0.join(record).is_file());
    assert_eq!(executor.0.lock().unwrap().len(), 1);

    assert_eq!(
        dispatcher.dispatch(&enter_loader("job-mismatch", &"0".repeat(64))),
        Err(LaneFailure::Failed(
            "ArkForge native RockUSB identity changed after availability materialization".into()
        ))
    );
    assert_eq!(executor.0.lock().unwrap().len(), 1);
}

/// Swift `testRockchipDispatcherRefusalNamesTheToolRuntimeCause`: a detail
/// extends the refusal and does not replace it; a dispatch refuses with it.
#[test]
fn a_refusing_dispatcher_names_its_cause() {
    let root = Root::new();
    let (identity, digest) = root.arkforged();
    let detail = "Rockchip tool runtime directory cannot be created";
    let named = NativeRockchipDispatcher::refusing(identity.clone(), Some(detail));
    let generic = NativeRockchipDispatcher::refusing(identity, None);
    assert_eq!(
        generic.unavailable_reason().as_deref(),
        Some(REFUSING_REASON)
    );
    let reason = format!("{REFUSING_REASON}: {detail}");
    assert_eq!(named.unavailable_reason(), Some(reason.clone()));
    assert_eq!(
        named.dispatch(&enter_loader("job-1", &digest)),
        Err(LaneFailure::Failed(reason))
    );
}

/// An `arkforged` that is not configured, or no longer measures as
/// declared, comes first.
#[test]
fn the_native_identity_is_measured_before_the_host() {
    let root = Root::new();
    let unconfigured = NativeRockchipDispatcher::durable(
        NativeRockUsbIdentity::unconfigured(),
        Executor::default(),
        &root.0,
    );
    let refusal = "ArkForge native RockUSB identity is unavailable: failed(\"ArkForge native \
                   RockUSB lane is not configured\")";
    assert_eq!(unconfigured.unavailable_reason().as_deref(), Some(refusal));
    assert_eq!(
        unconfigured.dispatch(&enter_loader("job-1", &"c".repeat(64))),
        Err(LaneFailure::Failed(refusal.into()))
    );

    let (identity, digest) = root.arkforged();
    let executor = Executor::default();
    let dispatcher = NativeRockchipDispatcher::durable(identity, executor.clone(), &root.0);
    std::fs::write(root.0.join("arkforged"), b"#!/bin/sh\nexit 1\n").unwrap();
    assert_eq!(
        dispatcher.dispatch(&enter_loader("job-1", &digest)),
        Err(LaneFailure::Failed(
            "ArkForge native RockUSB identity is unavailable: failed(\"arkforged executable \
             digest changed after LaunchAgent installation\")"
                .into()
        ))
    );
    assert!(executor.0.lock().unwrap().is_empty());
}

/// Only a Rockchip action reaches the host, and a persisted one decodes as
/// Swift's `materialize()` decodes it: a legacy write intent is refused by
/// name.
#[test]
fn only_a_rockchip_action_is_dispatched() {
    let root = Root::new();
    let (identity, digest) = root.arkforged();
    let executor = Executor::default();
    let dispatcher = NativeRockchipDispatcher::durable(identity, executor.clone(), &root.0);
    let non_rockchip = LaneFailure::Failed(
        "ArkForge native RockUSB dispatcher received a non-Rockchip action".into(),
    );
    for (action, refusal) in [
        (
            r#"{"arguments":{"connectKey":"device-1"},"kind":"hdc.captureHilog"}"#,
            non_rockchip.clone(),
        ),
        ("not json", non_rockchip),
        (
            r#"{"arguments":{},"kind":"rockchip.flashPartitions"}"#,
            LaneFailure::Failed(
                "rockchip.flashPartitions is a legacy in-process Rockchip write intent, removed \
                 in CHG-2026-059. The record is intact; the intent is not replayable and cannot \
                 be re-derived, so this job's outcome is unknown until a person reconciles the \
                 device."
                    .into(),
            ),
        ),
    ] {
        let descriptor = HostAction {
            action: action.into(),
            ..enter_loader("job-1", &digest)
        };
        assert_eq!(dispatcher.dispatch(&descriptor), Err(refusal), "{action}");
    }
    assert!(executor.0.lock().unwrap().is_empty());
}

/// A host result that names no durable record is an unknown outcome.
#[test]
fn a_result_without_its_record_is_unknown() {
    struct Recordless;

    impl RockchipActionHosting for Recordless {
        fn unavailable_reason(&self) -> Option<String> {
            None
        }

        fn execute(
            &self,
            _action: &RockchipAction,
            _descriptor: &HostAction,
            _provider_executable_sha256: &str,
        ) -> Result<ExecutionResult, LaneFailure> {
            Ok(ExecutionResult {
                summary: BTreeMap::from([("recordID".to_owned(), String::new())]),
                ..ExecutionResult::default()
            })
        }
    }

    let root = Root::new();
    let (identity, digest) = root.arkforged();
    let host: Arc<dyn RockchipActionHosting> = Arc::new(Recordless);
    let dispatcher = NativeRockchipDispatcher::new(identity, Arc::clone(&host));
    assert!(Arc::ptr_eq(&dispatcher.action_host(), &host));
    assert_eq!(
        dispatcher.dispatch(&enter_loader("job-1", &digest)),
        Err(LaneFailure::OutcomeUnknown(
            "Rockchip host returned no durable job/step receipt".into()
        ))
    );
}

/// Swift `testDurableHostIsUnavailableBeforeAdmissionWhenRecordRootCannotMaterialize`.
#[test]
fn a_record_root_that_cannot_materialize_makes_the_host_unavailable() {
    let root = Root::new();
    let (identity, digest) = root.arkforged();
    std::fs::write(root.0.join("rockchip-runtime"), b"not-a-directory").unwrap();
    let executor = Executor::default();
    let dispatcher = NativeRockchipDispatcher::durable(identity, executor.clone(), &root.0);
    let reason = dispatcher.unavailable_reason().unwrap();
    assert!(
        reason.starts_with("durable Rockchip host record root is unavailable: "),
        "{reason}"
    );
    assert_eq!(
        dispatcher.dispatch(&enter_loader("job-1", &digest)),
        Err(LaneFailure::Failed(reason))
    );
    assert!(executor.0.lock().unwrap().is_empty());
}
