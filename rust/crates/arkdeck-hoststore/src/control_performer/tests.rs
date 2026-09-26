//! The performer against Swift's `ArkForgeControlPerformerContractTests`: the
//! real durable host, with its validation and its record store, and a stub
//! only beneath them. The seam asserted is the one the Swift suite exists
//! for: every action the performer sends must be one the validating host
//! accepts.
use super::*;
use crate::rockchip_records::{DurableRockchipHost, RockchipActionExecutor, RockchipRecordStore};
use arkdeck_provider_arkforge::managed_control::{KeyValue, receipt};
use arkdeck_provider_arkforge::{HostAction, canonical_facts_digest};
use arkdeck_provider_hdc::LoaderIdentity;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

const IDENTITY: &str = "a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4";
const TOPOLOGY: &str = "17956864";
const CONNECT_KEY: &str = "7001005458323933328a25a89c9c214d";
const PROVIDER: &str = "5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c";

/// What Swift's own `"\(error)"` prints for these failures: the output of
/// the declarations `RuntimeDispatchFailure` and
/// `RockchipFlashRuntimeDiagnostic` as `ArkDeckWorkflows` declares them,
/// compiled by swiftc 6.4 (swiftlang-6.4.0.34.1).
const SWIFT_RENDERED: [&str; 5] = [
    "confirmedNotExecutedWithDiagnostic(\"exact bound HDC-normal USB readback proves the Loader \
     transition did not complete at topology 42 [hdcExitStatus=1 hdcStderr=\\\"[Fail]Not match \
     target and connect key retry later\\\" hdcFailure=HDC reboot-loader returned no clean \
     semantic receipt]\", diagnostic: \
     ArkDeckWorkflows.RockchipFlashRuntimeDiagnostic.enterLoaderHDCNoCleanReceipt)",
    "confirmedNotExecutedWithDiagnostic(\"x\", diagnostic: \
     ArkDeckWorkflows.RockchipFlashRuntimeDiagnostic.enterLoaderCommandCleanLoaderNotObserved)",
    "failed(\"a \\\"quoted\\\" \\\\ back\\nline\\tt\")",
    "outcomeUnknown(\"process timed out before completion\")",
    "confirmedNotExecuted(\"x\")",
];

/// Swift's `RecordingExecutor`: every action recorded with its descriptor;
/// the rebind answers the Loader, the verification the build, every other
/// action an observation. A scripted failure answers one action index.
#[derive(Default)]
struct Recording {
    executed: Mutex<Vec<(RockchipAction, HostAction)>>,
    failure: Option<(usize, LaneFailure)>,
}

impl RockchipActionExecutor for Arc<Recording> {
    fn unavailable_reason(&self) -> Option<String> {
        None
    }

    fn execute(
        &self,
        action: &RockchipAction,
        descriptor: &HostAction,
        _action_directory: &Path,
    ) -> Result<ExecutionResult, LaneFailure> {
        self.executed
            .lock()
            .unwrap()
            .push((action.clone(), descriptor.clone()));
        if let Some((index, failure)) = &self.failure
            && descriptor.step_id.ends_with(&format!("-a{index}"))
        {
            return Err(failure.clone());
        }
        let summary: &[(&str, &str)] = match action {
            RockchipAction::RebindLoader(_) => &[
                ("loaderIdentitySha256", IDENTITY),
                ("usbTopology", TOPOLOGY),
                ("bindingRevision", "4"),
            ],
            RockchipAction::VerifyBoundBuild { .. } => &[
                ("model", "rk3568"),
                ("firmware", "OpenHarmony-7.0.0.37"),
                ("hdcIdentitySha256", IDENTITY),
                ("usbTopology", TOPOLOGY),
                ("verification", "exact-published-profile-and-bound-hdc"),
            ],
            RockchipAction::WaitForBoundHdcReconnect(_) => &[
                ("hdcState", "connected"),
                ("hdcIdentitySha256", IDENTITY),
                ("usbTopology", TOPOLOGY),
            ],
            _ => &[("usbState", "observed")],
        };
        Ok(ExecutionResult {
            summary: summary
                .iter()
                .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
                .collect(),
            ..ExecutionResult::default()
        })
    }
}

impl Recording {
    fn identifiers(&self) -> Vec<String> {
        self.executed
            .lock()
            .unwrap()
            .iter()
            .map(|(_, descriptor)| descriptor.identifier.clone())
            .collect()
    }

    fn count(&self) -> usize {
        self.executed.lock().unwrap().len()
    }
}

/// Swift's `FixedLoaderObserver`, or its default refusing one.
struct Loader(Option<LoaderIdentity>);

impl LoaderObserver for Loader {
    fn observe_loader(
        &self,
        stable_identity_sha256: &str,
        expected_usb_topology: Option<&str>,
        _request_id: &str,
    ) -> Result<LoaderIdentity, String> {
        self.0
            .clone()
            .filter(|identity| {
                identity.serial_digest_sha256 == stable_identity_sha256
                    && expected_usb_topology.is_none_or(|topology| topology == identity.topology)
            })
            .ok_or_else(|| "fixture starts in HDC-normal".to_owned())
    }
}

struct Store(PathBuf);

impl Store {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-control-performer-{}-{}",
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
}

impl Drop for Store {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn performer(
    store: &Store,
    executor: &Arc<Recording>,
    loader: Option<LoaderIdentity>,
) -> ArkForgeControlPerformer {
    ArkForgeControlPerformer::new(
        ControlBinding {
            job_id: "job-affe0011".into(),
            target_id: "TGT-1".into(),
            binding_revision: 4,
            connect_key: CONNECT_KEY.into(),
            stable_identity_sha256: IDENTITY.into(),
            usb_topology: TOPOLOGY.into(),
            provider_executable_sha256: PROVIDER.into(),
        },
        Arc::new(DurableRockchipHost::new(
            Arc::clone(executor),
            RockchipRecordStore::new(&store.0.join("rockchip-runtime")),
        )),
        Box::new(Loader(loader)),
    )
}

fn request(id: &str, action: ManagedControlAction) -> ManagedControlRequest {
    ManagedControlRequest {
        job_id: "JOB-1".into(),
        step_id: "STEP-001".into(),
        request_id: id.into(),
        action,
        permit_id: "PERMIT-1".into(),
        expected_facts: Vec::new(),
        deadline_epoch_ms: 2_000_000,
    }
}

fn facts(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
        .collect()
}

/// Swift `testEnterUpdaterRunsAllFiveActionsThroughTheValidatingHost`: the
/// five actions in the port's order, each under its own identifier and its
/// own action's digest, all accepted by the validating host.
#[test]
fn enter_updater_runs_all_five_actions_through_the_validating_host() {
    let store = Store::new();
    let executor = Arc::new(Recording::default());
    let observation = performer(&store, &executor, None)
        .perform(&request(
            "REQ-1-control",
            ManagedControlAction::EnterUpdater,
        ))
        .unwrap();
    assert_eq!(
        observation,
        Observation {
            accepted: true,
            facts: facts(&[
                ("mode", "Loader"),
                ("stableIdentitySHA256", IDENTITY),
                ("usbTopology", TOPOLOGY),
            ]),
            evidence_sha256: Vec::new(),
            failure_reason: String::new(),
            observed_disconnect: true,
            observed_unique_loader_rebind: true,
        }
    );
    assert_eq!(
        executor.identifiers(),
        [
            "rockchip.iokit.observe-hdc-normal.v1",
            "rockchip.hdc.enter-loader.v1",
            "rockchip.hdc.wait-disconnect.v1",
            "rockchip.rockusb.wait-loader.v1",
            "rockchip.rockusb.rebind-loader.v1",
        ]
    );
    let attempt = &sha256_hex(b"REQ-1-control")[..12];
    for (index, (action, descriptor)) in executor.executed.lock().unwrap().iter().enumerate() {
        assert_eq!(descriptor.action_sha256, action.sha256());
        assert_eq!(
            descriptor.step_id,
            format!("STEP-001-mc-{attempt}-a{index}")
        );
        assert_eq!(descriptor.job_id, "job-affe0011");
        assert_eq!(descriptor.provider_executable_sha256, PROVIDER);
    }
}

/// Swift `testAlreadyLoaderFastPathUsesDualSourceObservationWithoutRunningHDC`.
#[test]
fn an_exact_loader_already_there_runs_nothing() {
    let store = Store::new();
    let executor = Arc::new(Recording::default());
    let observation = performer(
        &store,
        &executor,
        Some(LoaderIdentity {
            serial_digest_sha256: IDENTITY.into(),
            topology: TOPOLOGY.into(),
        }),
    )
    .perform(&request(
        "REQ-already-loader",
        ManagedControlAction::EnterUpdater,
    ))
    .unwrap();
    assert!(observation.accepted);
    assert!(observation.observed_disconnect && observation.observed_unique_loader_rebind);
    assert_eq!(
        observation.facts,
        facts(&[
            ("mode", "Loader"),
            ("stableIdentitySHA256", IDENTITY),
            ("usbTopology", TOPOLOGY),
        ])
    );
    assert_eq!(executor.count(), 0);
}

/// Swift `testARepeatedRequestReplaysItsRecordsAndAFreshRequestDoesNot`.
#[test]
fn a_repeated_request_replays_and_a_fresh_one_does_not() {
    let store = Store::new();
    let executor = Arc::new(Recording::default());
    let mut performer = performer(&store, &executor, None);
    performer
        .perform(&request(
            "REQ-1-control",
            ManagedControlAction::EnterUpdater,
        ))
        .unwrap();
    assert_eq!(executor.count(), 5);
    let replayed = performer
        .perform(&request(
            "REQ-1-control",
            ManagedControlAction::EnterUpdater,
        ))
        .unwrap();
    assert_eq!(executor.count(), 5, "a repeat of the same attempt replays");
    assert!(replayed.accepted);
    performer
        .perform(&request(
            "REQ-2-control",
            ManagedControlAction::EnterUpdater,
        ))
        .unwrap();
    assert_eq!(executor.count(), 10);
}

/// Swift `testTheAcceptedObservationBecomesAReceiptTheDaemonWillTake`.
#[test]
fn the_accepted_observation_becomes_a_receipt_the_daemon_will_take() {
    let store = Store::new();
    let executor = Arc::new(Recording::default());
    let observation = performer(&store, &executor, None)
        .perform(&request(
            "REQ-1-control",
            ManagedControlAction::EnterUpdater,
        ))
        .unwrap();
    let pairs: Vec<(String, String)> = observation
        .facts
        .iter()
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    let receipt = receipt(
        "JOB-1",
        "REQ-1-control",
        ManagedControlAction::EnterUpdater,
        &observation,
    )
    .unwrap();
    assert!(receipt.accepted);
    assert_eq!(
        Some(receipt.evidence_sha256.clone()),
        canonical_facts_digest(&pairs)
    );
    assert_eq!(receipt.evidence_sha256.len(), 32);
}

/// A failure is an observation of what was seen before it, its reason as
/// Swift's `"\(error)"` prints it: nothing after the disconnect wait fails
/// before the disconnect is observed, and nothing is accepted without the
/// rebind.
#[test]
fn a_failed_action_reports_what_was_observed_before_it() {
    for (index, disconnect) in [(1, false), (2, false), (3, true), (4, true)] {
        let store = Store::new();
        let executor = Arc::new(Recording {
            failure: Some((
                index,
                LaneFailure::Failed("a \"quoted\" \\ back\nline\tt".into()),
            )),
            ..Recording::default()
        });
        let observation = performer(&store, &executor, None)
            .perform(&request(
                "REQ-1-control",
                ManagedControlAction::EnterUpdater,
            ))
            .unwrap();
        assert_eq!(
            observation,
            Observation {
                failure_reason: SWIFT_RENDERED[2].into(),
                observed_disconnect: disconnect,
                ..Observation::default()
            },
            "failure at a{index}"
        );
        assert_eq!(executor.count(), index + 1);
    }
}

/// The failure reason is Swift's own text for every kind of failure; the
/// Loader transition's diagnostic is qualified as Swift qualifies it.
#[test]
fn a_failure_reason_is_swifts_text() {
    let failures = [
        LaneFailure::ConfirmedNotExecutedWithDiagnostic {
            reason: "exact bound HDC-normal USB readback proves the Loader transition did not \
                     complete at topology 42 [hdcExitStatus=1 hdcStderr=\"[Fail]Not match target \
                     and connect key retry later\" hdcFailure=HDC reboot-loader returned no clean \
                     semantic receipt]"
                .into(),
            diagnostic: "enterLoaderHDCNoCleanReceipt".into(),
        },
        LaneFailure::ConfirmedNotExecutedWithDiagnostic {
            reason: "x".into(),
            diagnostic: "enterLoaderCommandCleanLoaderNotObserved".into(),
        },
        LaneFailure::Failed("a \"quoted\" \\ back\nline\tt".into()),
        LaneFailure::OutcomeUnknown("process timed out before completion".into()),
        LaneFailure::ConfirmedNotExecuted("x".into()),
    ];
    for (failure, rendered) in failures.into_iter().zip(SWIFT_RENDERED) {
        let store = Store::new();
        let executor = Arc::new(Recording {
            failure: Some((1, failure)),
            ..Recording::default()
        });
        let observation = performer(&store, &executor, None)
            .perform(&request(
                "REQ-1-control",
                ManagedControlAction::EnterUpdater,
            ))
            .unwrap();
        assert_eq!(observation.failure_reason, rendered);
    }
    // A failure that is not a dispatch failure is its own description.
    let store = Store::new();
    let executor = Arc::new(Recording {
        failure: Some((
            0,
            LaneFailure::Other("admissionRejected(\"DAYU200 target unavailable\")".into()),
        )),
        ..Recording::default()
    });
    let observation = performer(&store, &executor, None)
        .perform(&request(
            "REQ-1-control",
            ManagedControlAction::EnterUpdater,
        ))
        .unwrap();
    assert_eq!(
        observation.failure_reason,
        "admissionRejected(\"DAYU200 target unavailable\")"
    );
}

/// The reboot waits for the bound reconnect in the HDC alias namespace. Its
/// summary carries none of the mode facts the port requires, so its receipt
/// is refused, as Swift's is.
#[test]
fn the_reboot_waits_for_the_bound_reconnect_by_the_connect_keys_alias() {
    let store = Store::new();
    let executor = Arc::new(Recording::default());
    let observation = performer(&store, &executor, None)
        .perform(&request("REQ-reboot", ManagedControlAction::RebootToNormal))
        .unwrap();
    assert_eq!(
        observation,
        Observation {
            accepted: true,
            facts: facts(&[("usbTopology", TOPOLOGY)]),
            ..Observation::default()
        }
    );
    let executed = executor.executed.lock().unwrap().clone();
    assert_eq!(
        executed[0].0,
        RockchipAction::WaitForBoundHdcReconnect(Expectation {
            previous_connect_key: CONNECT_KEY.into(),
            previous_identity_sha256: sha256_hex(CONNECT_KEY.as_bytes()),
            usb_topology: TOPOLOGY.into(),
        })
    );
    assert!(executed[0].1.step_id.ends_with("-a0"));
    assert!(
        receipt(
            "JOB-1",
            "REQ-reboot",
            ManagedControlAction::RebootToNormal,
            &observation
        )
        .is_err()
    );
}

/// A read verifies the build the daemon's request expects, the first value
/// of a repeated key, and answers in the device's property names.
#[test]
fn a_read_verifies_what_the_daemon_expects() {
    let store = Store::new();
    let executor = Arc::new(Recording::default());
    let mut read = request("REQ-read", ManagedControlAction::ReadBuildFacts);
    read.expected_facts = [
        ("const.ohos.fullname", "OpenHarmony-7.0.0.37"),
        ("const.product.model", "rk3568"),
        ("const.product.model", "other"),
    ]
    .iter()
    .map(|(key, value)| KeyValue {
        key: (*key).into(),
        value: (*value).into(),
    })
    .collect();
    let observation = performer(&store, &executor, None).perform(&read).unwrap();
    assert_eq!(
        observation.facts,
        facts(&[
            ("const.ohos.fullname", "OpenHarmony-7.0.0.37"),
            ("const.product.model", "rk3568"),
            ("usbTopology", TOPOLOGY),
        ])
    );
    let executed = executor.executed.lock().unwrap().clone();
    assert_eq!(
        executed[0].0,
        RockchipAction::VerifyBoundBuild {
            expectation: Expectation {
                previous_connect_key: CONNECT_KEY.into(),
                previous_identity_sha256: sha256_hex(CONNECT_KEY.as_bytes()),
                usb_topology: TOPOLOGY.into(),
            },
            product_model: "rk3568".into(),
            build_version: "OpenHarmony-7.0.0.37".into(),
        }
    );
    assert!(
        receipt(
            "JOB-1",
            "REQ-read",
            ManagedControlAction::ReadBuildFacts,
            &observation
        )
        .unwrap()
        .accepted
    );
}
