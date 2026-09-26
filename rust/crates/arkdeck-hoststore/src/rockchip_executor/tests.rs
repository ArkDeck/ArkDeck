//! The executor against Swift's `RockchipRuntimeCompositionContractTests`:
//! scripted HDC, USB and ArkForge observations, and a clock that only moves
//! when a wait pauses or a test advances it.
use super::*;
use crate::rockchip_action::CaptureRequest;
use arkdeck_contract::sha256_hex;
use std::collections::VecDeque;
use std::os::unix::fs::DirBuilderExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

const KEY: &str = "device-1";
const NEXT_KEY: &str = "device-2";
const PROVIDER: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

fn identity() -> String {
    "a".repeat(64)
}

/// Swift's `ProbeCommandRunner`: one scripted answer per command, every plan
/// recorded.
#[derive(Default)]
struct Hdc {
    answers: Mutex<VecDeque<Result<Receipt, DispatchFailure>>>,
    plans: Mutex<Vec<ProcessPlan>>,
}

impl Hdc {
    fn answering(answers: Vec<Result<Receipt, DispatchFailure>>) -> Arc<Self> {
        Arc::new(Self {
            answers: Mutex::new(answers.into()),
            plans: Mutex::default(),
        })
    }

    fn arguments(&self) -> Vec<Vec<String>> {
        self.plans
            .lock()
            .unwrap()
            .iter()
            .map(|plan| plan.arguments.clone())
            .collect()
    }
}

impl HdcDispatch for Hdc {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        self.plans.lock().unwrap().push(plan.clone());
        self.answers
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| panic!("no scripted answer for {:?}", plan.arguments))
    }
}

fn out(stdout: &str) -> Result<Receipt, DispatchFailure> {
    Ok(Receipt {
        exit_status: 0,
        stdout: stdout.as_bytes().to_vec(),
        stderr: Vec::new(),
        truncated: false,
        duration: Duration::from_millis(250),
    })
}

fn targets(connect_key: &str) -> Result<Receipt, DispatchFailure> {
    out(&format!("{connect_key}\t\tUSB\tConnected\tlocalhost\n"))
}

/// A USB census: a Loader that appears after some misses, an HDC-normal
/// device by its digest, and HDC-normal devices by topology.
#[derive(Default)]
struct Usb {
    loader: Option<LoaderIdentity>,
    loader_misses: AtomicUsize,
    loader_reads: AtomicUsize,
    normal: Option<LoaderIdentity>,
    at: BTreeMap<String, HdcIdentity>,
}

impl Usb {
    fn loader(identity: &str, misses: usize) -> Self {
        Self {
            loader: Some(LoaderIdentity {
                serial_digest_sha256: identity.to_owned(),
                topology: "42".to_owned(),
            }),
            loader_misses: AtomicUsize::new(misses),
            ..Self::default()
        }
    }

    fn normal(connect_key: &str) -> Self {
        Self {
            normal: Some(LoaderIdentity {
                serial_digest_sha256: sha256_hex(connect_key.as_bytes()),
                topology: "42".to_owned(),
            }),
            ..Self::default()
        }
    }

    /// Swift's `TopologyBoundUSBProbe`: the post-flash HDC personality at
    /// `topology`, reporting `reported` as its own.
    fn bound(connect_key: &str, topology: &str, reported: &str) -> Self {
        Self {
            at: BTreeMap::from([(
                topology.to_owned(),
                HdcIdentity {
                    connect_key: connect_key.to_owned(),
                    serial_digest_sha256: sha256_hex(connect_key.as_bytes()),
                    topology: reported.to_owned(),
                },
            )]),
            ..Self::default()
        }
    }
}

fn unavailable() -> String {
    "admissionRejected(\"DAYU200 target unavailable\")".to_owned()
}

impl UsbProbe for Usb {
    fn single_loader(&self, stable_identity_sha256: &str) -> Result<LoaderIdentity, String> {
        self.loader_reads.fetch_add(1, Ordering::SeqCst);
        if self
            .loader_misses
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |misses| {
                misses.checked_sub(1)
            })
            .is_ok()
        {
            return Err(unavailable());
        }
        self.loader
            .clone()
            .filter(|loader| loader.serial_digest_sha256 == stable_identity_sha256)
            .ok_or_else(unavailable)
    }

    fn single_hdc_normal(&self, stable_identity_sha256: &str) -> Result<LoaderIdentity, String> {
        self.normal
            .clone()
            .filter(|normal| normal.serial_digest_sha256 == stable_identity_sha256)
            .ok_or_else(unavailable)
    }

    fn single_hdc_normal_at(&self, usb_topology: &str) -> Result<HdcIdentity, String> {
        self.at.get(usb_topology).cloned().ok_or_else(unavailable)
    }
}

/// Swift's `FixedArkForgeLoaderObserver`: ArkForge confirms what the census
/// reports; `None` is Swift's default refusing observer.
struct Loader(Option<LoaderIdentity>);

impl LoaderObserver for Loader {
    fn observe_loader(
        &self,
        stable_identity_sha256: &str,
        _expected_usb_topology: Option<&str>,
        _request_id: &str,
    ) -> Result<LoaderIdentity, String> {
        self.0
            .clone()
            .filter(|loader| loader.serial_digest_sha256 == stable_identity_sha256)
            .ok_or_else(|| "no ArkForge Loader observation source was composed".to_owned())
    }
}

/// A clock a wait's pause advances, and a test can advance.
struct TestClock(Mutex<Instant>);

impl TestClock {
    fn new() -> Arc<Self> {
        Arc::new(Self(Mutex::new(Instant::now())))
    }

    fn advance(&self, by: Duration) {
        *self.0.lock().unwrap() += by;
    }
}

/// The executor's handle on a test's clock.
struct SharedClock(Arc<TestClock>);

impl Clock for SharedClock {
    fn now(&self) -> Instant {
        *self.0.0.lock().unwrap()
    }

    fn sleep(&self, duration: Duration) {
        self.0.advance(duration);
    }
}

struct Fixture {
    hdc: Arc<Hdc>,
    usb: Arc<Usb>,
    clock: Arc<TestClock>,
    executor: RockchipExecutor,
}

/// The executor's handle on a test's census.
struct SharedUsb(Arc<Usb>);

impl UsbProbe for SharedUsb {
    fn single_loader(&self, stable_identity_sha256: &str) -> Result<LoaderIdentity, String> {
        self.0.single_loader(stable_identity_sha256)
    }

    fn single_hdc_normal(&self, stable_identity_sha256: &str) -> Result<LoaderIdentity, String> {
        self.0.single_hdc_normal(stable_identity_sha256)
    }

    fn single_hdc_normal_at(&self, usb_topology: &str) -> Result<HdcIdentity, String> {
        self.0.single_hdc_normal_at(usb_topology)
    }
}

fn fixture(hdc: Arc<Hdc>, usb: Usb, loader: Option<&str>) -> Fixture {
    let usb = Arc::new(usb);
    let clock = TestClock::new();
    let resolver: Box<HdcResolver> = {
        let hdc = Arc::clone(&hdc);
        Box::new(move || Ok(Arc::clone(&hdc) as Arc<dyn HdcDispatch + Send + Sync>))
    };
    let executor = RockchipExecutor::new(
        resolver,
        Box::new(SharedUsb(Arc::clone(&usb))),
        Box::new(Loader(loader.map(|identity| LoaderIdentity {
            serial_digest_sha256: identity.to_owned(),
            topology: "42".to_owned(),
        }))),
        Box::new(SharedClock(Arc::clone(&clock))),
    );
    Fixture {
        hdc,
        usb,
        clock,
        executor,
    }
}

/// Swift's `rockchipPlan`: the Job, Target and revision of the lowering
/// context, the descriptor the catalog materializes.
fn descriptor(action: &RockchipAction, step: &str) -> HostAction {
    action.descriptor("job-host", step, "TGT-HOST", 7, KEY, &identity(), PROVIDER)
}

fn run(
    fixture: &Fixture,
    action: &RockchipAction,
    step: &str,
) -> Result<ExecutionResult, LaneFailure> {
    fixture
        .executor
        .execute(action, &descriptor(action, step), Path::new("/unused"))
}

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
        .collect()
}

fn reboot_loader() -> Vec<String> {
    ["-t", KEY, "shell", "reboot", "loader"]
        .iter()
        .map(|value| (*value).to_owned())
        .collect()
}

// MARK: the Loader transition

/// Swift `testEnterLoaderAlreadyInExactLoaderSkipsHDCAndRecordsReadback`.
#[test]
fn an_exact_loader_already_there_skips_hdc() {
    let fixture = fixture(
        Hdc::answering(Vec::new()),
        Usb::loader(&identity(), 0),
        Some(&identity()),
    );
    let entered = run(
        &fixture,
        &RockchipAction::EnterLoader(KEY.into()),
        "enter-loader",
    )
    .unwrap();
    assert_eq!(
        entered,
        ExecutionResult {
            summary: map(&[
                ("transition", "already-loader"),
                ("transitionEvidence", "exact-bound-loader-readback"),
                ("loaderIdentitySha256", &identity()),
                ("usbTopology", "42"),
            ]),
            ..ExecutionResult::default()
        }
    );
    assert!(fixture.hdc.arguments().is_empty());
}

/// Swift `testManagedControlLoaderReceiptsReuseOneExactTransitionObservation`:
/// one miss before the command and one exact readback after it cover the
/// whole receipt chain, and only the command itself spawns HDC.
#[test]
fn one_managed_control_attempt_reuses_one_transition_observation() {
    let fixture = fixture(
        Hdc::answering(vec![out("")]),
        Usb::loader(&identity(), 1),
        Some(&identity()),
    );
    let step = |index: usize| format!("enter-loader-mode-mc-deadbeefcafe-a{index}");
    let entered = run(&fixture, &RockchipAction::EnterLoader(KEY.into()), &step(1)).unwrap();
    let disconnected = run(
        &fixture,
        &RockchipAction::WaitForHdcDisconnect(KEY.into()),
        &step(2),
    )
    .unwrap();
    let appeared = run(
        &fixture,
        &RockchipAction::WaitForLoader(identity()),
        &step(3),
    )
    .unwrap();
    let rebound = run(
        &fixture,
        &RockchipAction::RebindLoader(identity()),
        &step(4),
    )
    .unwrap();

    assert_eq!(entered.summary["transition"], "normal-to-loader");
    assert_eq!(entered.subprocess_count, 1);
    assert_eq!(
        disconnected.summary,
        map(&[
            ("hdcState", "disconnected"),
            ("transitionEvidence", "exact-bound-loader-readback"),
            ("loaderIdentitySha256", &identity()),
            ("usbTopology", "42"),
        ])
    );
    assert_eq!(
        appeared.summary,
        map(&[
            ("loaderIdentitySha256", &identity()),
            ("usbTopology", "42"),
            ("observationReuse", "enter-loader-postcondition"),
        ])
    );
    assert_eq!(
        rebound.summary,
        map(&[
            ("loaderIdentitySha256", &identity()),
            ("usbTopology", "42"),
            ("bindingRevision", "7"),
            ("observationReuse", "exact-bound-loader-readback"),
        ])
    );
    assert_eq!(fixture.usb.loader_reads.load(Ordering::SeqCst), 2);
    assert_eq!(fixture.hdc.arguments(), [reboot_loader()]);

    // The rebind consumed the observation: a repeat reads the Loader afresh.
    let again = run(
        &fixture,
        &RockchipAction::RebindLoader(identity()),
        &step(4),
    )
    .unwrap();
    assert_eq!(again.summary.get("observationReuse"), None);
    assert_eq!(fixture.usb.loader_reads.load(Ordering::SeqCst), 3);
}

/// Only the performer's step id shape reuses an observation, and only for
/// 120 s.
#[test]
fn reuse_is_bound_to_the_attempts_step_ids_and_expires() {
    let reused = |step: &str| {
        let descriptor = descriptor(&RockchipAction::WaitForHdcDisconnect(KEY.into()), step);
        loader_reuse_key(&descriptor, 2).is_some()
    };
    assert!(reused("enter-loader-mode-mc-deadbeefcafe-a2"));
    // Fullwidth digits are hexadecimal digits to Swift's Character.
    assert!(reused("enter-loader-mode-mc-deadbeefcaf\u{FF45}-a2"));
    for step in [
        "enter-loader-mode-a2",
        "enter-loader-mode-mc-deadbeefcafe-a3",
        "enter-loader-mode-mc-deadbeefcaf-a2",
        "enter-loader-mode-mc-DEADBEEFCAFE-a2",
        "-mc-deadbeefcafe-a2",
    ] {
        assert!(!reused(step), "{step}");
    }

    let fixture = fixture(
        Hdc::answering(vec![out("")]),
        Usb::loader(&identity(), 1),
        Some(&identity()),
    );
    let step = |index: usize| format!("enter-loader-mode-mc-0123456789ab-a{index}");
    run(&fixture, &RockchipAction::EnterLoader(KEY.into()), &step(1)).unwrap();
    fixture.clock.advance(REUSE_MAXIMUM_AGE);
    let appeared = run(
        &fixture,
        &RockchipAction::WaitForLoader(identity()),
        &step(3),
    )
    .unwrap();
    assert_eq!(
        appeared.summary["observationReuse"],
        "enter-loader-postcondition"
    );
    fixture.clock.advance(Duration::from_secs(1));
    let rebound = run(
        &fixture,
        &RockchipAction::RebindLoader(identity()),
        &step(4),
    )
    .unwrap();
    assert_eq!(rebound.summary.get("observationReuse"), None, "expired");
}

/// Swift `testEnterLoaderConfirmedNotExecutedCarriesTheHDCReceiptSummary`
/// and `…SettlesTimedOutHDCAsConfirmedNotExecutedWhenExactNormalUSBRemains`:
/// the exact HDC-normal readback proves the transition did not complete, and
/// the failure carries the command's evidence and Swift's diagnostic.
#[test]
fn a_transition_the_normal_readback_disproves_carries_its_diagnostic() {
    let stderr = Ok(Receipt {
        exit_status: 1,
        stdout: Vec::new(),
        stderr: b"[Fail]Not match target and connect key\nretry later".to_vec(),
        truncated: false,
        duration: Duration::ZERO,
    });
    let timed_out = Err(DispatchFailure::Unobservable(
        "process timed out before completion".to_owned(),
    ));
    for (answer, evidence) in [
        (stderr, "hdcExitStatus=1"),
        (timed_out, "hdcFailure=process timed out before completion"),
    ] {
        let fixture = fixture(Hdc::answering(vec![answer]), Usb::normal(KEY), None);
        let executor = fixture.executor.with_enter_loader_readback(ReadbackBudget {
            deadline: Duration::ZERO,
            poll: Duration::from_secs(1),
        });
        let action = RockchipAction::EnterLoader(KEY.into());
        let failure = executor
            .execute(
                &action,
                &descriptor(&action, "enter-loader"),
                Path::new("/unused"),
            )
            .unwrap_err();
        let LaneFailure::ConfirmedNotExecutedWithDiagnostic { reason, diagnostic } = failure else {
            panic!("expected a confirmed-not-executed failure, got {failure:?}");
        };
        assert!(
            reason.contains("did not complete at topology 42"),
            "{reason}"
        );
        assert!(reason.contains(evidence), "{reason}");
        assert!(!reason.contains('\n'), "{reason}");
        assert_eq!(diagnostic, "enterLoaderHDCNoCleanReceipt");
    }
}

/// Swift `testEnterLoaderKeepsTimedOutHDCUnknownWithoutExactLoader`.
#[test]
fn a_timed_out_transition_without_either_readback_stays_unknown() {
    let fixture = fixture(
        Hdc::answering(vec![Err(DispatchFailure::Unobservable(
            "process timed out before completion".to_owned(),
        ))]),
        Usb::default(),
        None,
    );
    let executor = fixture.executor.with_enter_loader_readback(ReadbackBudget {
        deadline: Duration::ZERO,
        poll: Duration::from_secs(1),
    });
    let action = RockchipAction::EnterLoader(KEY.into());
    assert_eq!(
        executor.execute(
            &action,
            &descriptor(&action, "enter-loader"),
            Path::new("/unused")
        ),
        Err(LaneFailure::OutcomeUnknown(
            "process timed out before completion".into()
        ))
    );
}

// MARK: reads without a command

/// Swift `testNormalUSBReadbackUsesExactConnectKeyIdentityWithoutHDCProcess`;
/// a device that is not there is the census's own refusal.
#[test]
fn the_normal_usb_readback_runs_no_hdc() {
    let fixture = fixture(Hdc::answering(Vec::new()), Usb::normal(KEY), None);
    let observed = run(
        &fixture,
        &RockchipAction::ObserveHdcNormalUsb(KEY.into()),
        "observe",
    )
    .unwrap();
    assert_eq!(
        observed.summary,
        map(&[
            ("hdcNormalIdentitySha256", &sha256_hex(KEY.as_bytes())),
            ("usbState", "hdc-normal"),
            ("usbTopology", "42"),
        ])
    );
    assert_eq!(observed.subprocess_count, 0);
    assert!(fixture.hdc.arguments().is_empty());
    assert_eq!(
        run(
            &fixture,
            &RockchipAction::ObserveHdcNormalUsb(NEXT_KEY.into()),
            "observe-2"
        ),
        Err(LaneFailure::Other(unavailable()))
    );
}

#[test]
fn the_retired_direct_reset_never_runs() {
    let fixture = fixture(Hdc::answering(Vec::new()), Usb::default(), None);
    assert_eq!(
        run(
            &fixture,
            &RockchipAction::RebootToNormal(identity()),
            "reboot-device"
        ),
        Err(LaneFailure::Failed(
            "legacy direct Rockchip reset is retired; native ArkForge owns device reset".into()
        ))
    );
    assert!(fixture.hdc.arguments().is_empty());
}

// MARK: the HDC waits

/// The reconnect wait returns every list it read, its streams in order.
#[test]
fn the_reconnect_wait_returns_the_lists_it_read() {
    let fixture = fixture(
        Hdc::answering(vec![out(""), targets(KEY)]),
        Usb::default(),
        None,
    );
    let connected = run(
        &fixture,
        &RockchipAction::WaitForHdcReconnect(KEY.into()),
        "wait",
    )
    .unwrap();
    assert_eq!(connected.summary, map(&[("hdcState", "connected")]));
    assert_eq!(connected.subprocess_count, 2);
    assert_eq!(
        connected.stdout,
        format!("{KEY}\t\tUSB\tConnected\tlocalhost\n").into_bytes()
    );
    assert_eq!(
        fixture.hdc.arguments(),
        [["list", "targets", "-v"], ["list", "targets", "-v"]]
    );
}

// MARK: the post-flash route

fn expectation() -> Expectation {
    Expectation {
        previous_connect_key: KEY.into(),
        previous_identity_sha256: sha256_hex(KEY.as_bytes()),
        usb_topology: "42".into(),
    }
}

fn verify() -> RockchipAction {
    RockchipAction::VerifyBoundBuild {
        expectation: expectation(),
        product_model: "rk3568".into(),
        build_version: "OpenHarmony-7.0.0.37".into(),
    }
}

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-rockchip-executor-{}-{}",
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

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Swift `testPostFlashHDCSerialRotationUsesBoundTopologyAndPublishesOnlyAfterExactBuild`:
/// the bound reconnect finds the rotated serial at the recorded topology and
/// publishes nothing; the verification reuses that route after a fresh
/// census readback, reads both properties in one command, and only then
/// publishes the alias.
#[test]
fn the_bound_reconnect_route_is_reused_by_the_build_verification_that_publishes_it() {
    let root = Root::new();
    let store = root.0.join("binding");
    let fixture = fixture(
        Hdc::answering(vec![
            targets(NEXT_KEY),
            out("OpenHarmony-7.0.0.37\nrk3568\n"),
        ]),
        Usb::bound(NEXT_KEY, "42", "42"),
        None,
    );
    let executor = fixture
        .executor
        .with_post_flash_aliases(PostFlashAliasStore::new(&store), || {
            "2026-08-08T01:02:03Z".to_owned()
        });
    let execute = |action: &RockchipAction, step: &str| {
        executor.execute(action, &descriptor(action, step), Path::new("/unused"))
    };
    let next = sha256_hex(NEXT_KEY.as_bytes());
    let reconnected = execute(
        &RockchipAction::WaitForBoundHdcReconnect(expectation()),
        "wait-for-hdc",
    )
    .unwrap();
    assert_eq!(
        reconnected.summary,
        map(&[
            ("hdcState", "connected"),
            ("hdcIdentitySha256", &next),
            ("usbTopology", "42"),
        ])
    );
    assert_eq!(
        PostFlashAliasStore::new(&store).load_if_present().unwrap(),
        None,
        "a reconnect alone must not rotate a trusted route"
    );

    let verified = execute(&verify(), "rebind-and-verify-build").unwrap();
    assert_eq!(
        verified.summary,
        map(&[
            ("model", "rk3568"),
            ("firmware", "OpenHarmony-7.0.0.37"),
            ("hdcIdentitySha256", &next),
            ("usbTopology", "42"),
            ("verification", "exact-published-profile-and-bound-hdc"),
        ])
    );
    assert_eq!(verified.subprocess_count, 1, "the properties read alone");
    assert_eq!(
        fixture.hdc.arguments(),
        [
            vec!["list".to_owned(), "targets".into(), "-v".into()],
            vec![
                "-t".to_owned(),
                NEXT_KEY.into(),
                "shell".into(),
                arkdeck_provider_hdc::POST_FLASH_BUILD_PROPERTIES_COMMAND.into()
            ],
        ]
    );
    let binding = PostFlashAliasStore::new(&store)
        .load_if_present()
        .unwrap()
        .unwrap();
    assert_eq!(
        binding,
        PostFlashBinding {
            schema_version: SCHEMA_VERSION.into(),
            target_id: "TGT-HOST".into(),
            binding_revision: 7,
            stable_loader_identity_sha256: identity(),
            previous_hdc_identity_sha256: sha256_hex(KEY.as_bytes()),
            hdc_identity_sha256: next,
            hdc_connect_key: NEXT_KEY.into(),
            usb_topology: "42".into(),
            product_model: "rk3568".into(),
            build_version: "OpenHarmony-7.0.0.37".into(),
            job_id: "job-host".into(),
            established_at_utc: "2026-08-08T01:02:03Z".into(),
        }
    );
}

/// Swift `testPostFlashHDCBindingRejectsInexactBuildAndInconsistentTopology`:
/// neither a build that is not the profile's nor a route whose census
/// disagrees with itself publishes anything.
#[test]
fn an_inexact_build_or_an_inconsistent_route_publishes_nothing() {
    let root = Root::new();
    for (usb, answers, refusal) in [
        (
            Usb::bound(NEXT_KEY, "42", "42"),
            vec![targets(NEXT_KEY), out("OpenHarmony-7.0.0.34\nrk3568\n")],
            "post-flash build readback does not match the published profile",
        ),
        (
            Usb::bound(NEXT_KEY, "42", "43"),
            vec![targets(NEXT_KEY)],
            "topology-bound HDC USB identity is internally inconsistent",
        ),
    ] {
        let store = root.0.join(refusal.replace(' ', "-"));
        let fixture = fixture(Hdc::answering(answers), usb, None);
        let executor = fixture
            .executor
            .with_post_flash_aliases(PostFlashAliasStore::new(&store), || {
                "2026-08-08T01:02:03Z".to_owned()
            });
        let action = verify();
        assert_eq!(
            executor.execute(
                &action,
                &descriptor(&action, "rebind-and-verify-build"),
                Path::new("/unused")
            ),
            Err(LaneFailure::Failed(refusal.into()))
        );
        assert_eq!(
            PostFlashAliasStore::new(&store).load_if_present().unwrap(),
            None
        );
    }
}

/// Without a store, or without the profile's model and build, a
/// verification refuses before it looks at the device.
#[test]
fn a_verification_that_is_not_configured_refuses_first() {
    let root = Root::new();
    let unconfigured =
        LaneFailure::Failed("post-flash binding verification is not fully configured".into());
    let storeless = fixture(Hdc::answering(Vec::new()), Usb::default(), None);
    assert_eq!(
        run(&storeless, &verify(), "rebind-and-verify-build"),
        Err(unconfigured.clone())
    );
    let fixture = fixture(Hdc::answering(Vec::new()), Usb::default(), None);
    let executor = fixture
        .executor
        .with_post_flash_aliases(PostFlashAliasStore::new(&root.0.join("binding")), || {
            "2026-08-08T01:02:03Z".to_owned()
        });
    let action = RockchipAction::VerifyBoundBuild {
        expectation: expectation(),
        product_model: String::new(),
        build_version: "OpenHarmony-7.0.0.37".into(),
    };
    assert_eq!(
        executor.execute(
            &action,
            &descriptor(&action, "verify"),
            Path::new("/unused")
        ),
        Err(unconfigured)
    );
    assert!(fixture.hdc.arguments().is_empty());
}

// MARK: the capture

#[test]
fn the_capture_reads_hilog_for_its_duration_within_its_budget() {
    let fixture = fixture(Hdc::answering(vec![out("line\n")]), Usb::default(), None);
    let action = RockchipAction::CapturePostFlashDiagnostics {
        connect_key: KEY.into(),
        request: CaptureRequest::new(30, vec!["arkdeck:*".into()], 16 * 1024 * 1024).unwrap(),
    };
    let captured = run(&fixture, &action, "capture-post-flash-diagnostics").unwrap();
    assert_eq!(
        captured,
        ExecutionResult {
            summary: map(&[
                ("byteCount", "5"),
                ("debugRuntime", "ready"),
                ("verification", "full"),
            ]),
            stdout: b"line\n".to_vec(),
            stderr: Vec::new(),
            stdout_truncated: false,
            subprocess_count: 1,
        }
    );
    let plans = fixture.hdc.plans.lock().unwrap().clone();
    assert_eq!(
        plans,
        [ProcessPlan {
            arguments: ["-t", KEY, "shell", "hilog", "-x", "arkdeck:*"]
                .iter()
                .map(|value| (*value).to_owned())
                .collect(),
            timeout: Duration::from_secs(45),
            capture_bytes: 16 * 1024 * 1024,
        }]
    );
}

// MARK: the descriptor-bound HDC

/// An HDC that cannot be resolved makes the executor unavailable, and every
/// action that needs it refuses in Swift's words; the exact-Loader fast path
/// needs none.
#[test]
fn an_unresolvable_hdc_refuses_only_what_needs_it() {
    let executor = RockchipExecutor::new(
        Box::new(|| Err("failed(\"hdc is not configured\")".to_owned())),
        Box::new(SharedUsb(Arc::new(Usb::loader(&identity(), 0)))),
        Box::new(Loader(Some(LoaderIdentity {
            serial_digest_sha256: identity(),
            topology: "42".into(),
        }))),
        Box::new(SharedClock(TestClock::new())),
    );
    assert_eq!(
        executor.unavailable_reason().as_deref(),
        Some(
            "descriptor-bound HDC executable is unavailable to the Rockchip host: failed(\"hdc \
             is not configured\")"
        )
    );
    let reconnect = RockchipAction::WaitForHdcReconnect(KEY.into());
    assert_eq!(
        executor.execute(
            &reconnect,
            &descriptor(&reconnect, "wait"),
            Path::new("/unused")
        ),
        Err(LaneFailure::Failed(
            "descriptor-bound HDC executable is unavailable: failed(\"hdc is not configured\")"
                .into()
        ))
    );
    let enter = RockchipAction::EnterLoader(KEY.into());
    let entered = executor
        .execute(
            &enter,
            &descriptor(&enter, "enter-loader"),
            Path::new("/unused"),
        )
        .unwrap();
    assert_eq!(entered.summary["transition"], "already-loader");
}
