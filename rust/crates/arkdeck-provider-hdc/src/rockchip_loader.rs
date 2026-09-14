//! The Loader side of Swift's Rockchip flash executor
//! (`FoundationRockchipRuntimeActionExecutor`'s `enterLoader`, `waitForLoader`
//! and `rebindLoader` arms, `RockchipRuntimeActionHost.swift`): the one HDC
//! command of the flash flow that mutates the device — `hdc -t <key> shell
//! reboot loader` — believed only by an exact Loader readback that ArkForge
//! confirms; the readback alone when the device is already there; and the
//! evidence clause every failed transition carries, so that the actual cause
//! (a non-zero exit, a killed child, an stderr line) survives somewhere other
//! than a macOS crash report.
//!
//! The observation-reuse cache keyed by the managed-control step id, through
//! which the disconnect, Loader and rebind arms reuse one transition
//! observation, is the executor's and is consulted before calling in here.
use crate::live_mode::{LoaderIdentity, LoaderObserver, UsbProbe, sha256_hex};
use crate::rockchip_hdc::Clock;
use crate::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use std::collections::BTreeMap;
use std::fmt;
use std::time::Duration;

/// `enterLoader`'s HDC command has 20 s…
pub const ENTER_LOADER_TIMEOUT: Duration = Duration::from_secs(20);
/// …and a 64 KiB capture.
const ENTER_LOADER_CAPTURE_BYTES: usize = 64 * 1024;
/// Swift `maximumEvidenceStderrBytes`.
const MAXIMUM_EVIDENCE_STDERR_BYTES: usize = 200;

/// Swift `RockchipHDCIntegrationProfile.enterLoaderArguments(connectKey:)`:
/// the device-side reboot reaches RockUSB Loader in about four seconds where
/// HDC's generic `target boot loader` takes about seventeen on the same RK3568
/// board. Every token after `shell` is fixed here — neither a request nor a
/// profile can inject command text — and `-t` keeps the exact connect-key
/// selection when another target is present.
pub fn enter_loader_plan(connect_key: &str) -> ProcessPlan {
    ProcessPlan {
        arguments: ["-t", connect_key, "shell", "reboot", "loader"]
            .iter()
            .map(|value| (*value).to_owned())
            .collect(),
        timeout: ENTER_LOADER_TIMEOUT,
        capture_bytes: ENTER_LOADER_CAPTURE_BYTES,
    }
}

/// How long a Loader readback may take: Swift's
/// `enterLoaderReadbackTimeoutSeconds` (45 s by default) after the command,
/// and `waitForLoader`'s 45 s, one readback a second.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ReadbackBudget {
    pub deadline: Duration,
    pub poll: Duration,
}

impl ReadbackBudget {
    pub const DEFAULT: Self = Self {
        deadline: Duration::from_secs(45),
        poll: Duration::from_secs(1),
    };
}

/// Swift `RockchipFlashRuntimeDiagnostic`: the closed, non-sensitive
/// diagnoses of a transition that cannot be proven, safe to show an operator
/// through a job timeline.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FlashRuntimeDiagnostic {
    EnterLoaderHdcNoCleanReceipt,
    EnterLoaderCommandCleanLoaderNotObserved,
}

impl FlashRuntimeDiagnostic {
    /// The diagnostic as Swift spells it.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::EnterLoaderHdcNoCleanReceipt => "enterLoaderHDCNoCleanReceipt",
            Self::EnterLoaderCommandCleanLoaderNotObserved => {
                "enterLoaderCommandCleanLoaderNotObserved"
            }
        }
    }
}

/// Swift `RuntimeDispatchFailure` as the transition raises it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LoaderTransitionFailure {
    /// `.failed`: nothing happened to the device — a refused dispatch, an
    /// identity that is not the adopted target's, an ArkForge confirmation
    /// that refused, a readback deadline.
    Failed(String),
    /// `.outcomeUnknown`: the command may have run and neither surface
    /// settled it; the Job parks and is never replayed.
    OutcomeUnknown(String),
    /// `.confirmedNotExecutedWithDiagnostic`: the exact HDC-normal readback
    /// proved the transition did not complete. A failed step, with a closed
    /// diagnostic the timeline may show.
    ConfirmedNotExecuted {
        detail: String,
        diagnostic: FlashRuntimeDiagnostic,
    },
}

impl LoaderTransitionFailure {
    pub fn detail(&self) -> &str {
        match self {
            Self::Failed(detail)
            | Self::OutcomeUnknown(detail)
            | Self::ConfirmedNotExecuted { detail, .. } => detail,
        }
    }
}

impl fmt::Display for LoaderTransitionFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.detail())
    }
}

impl std::error::Error for LoaderTransitionFailure {}

/// How the device came to be in Loader.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Transition {
    /// The exact bound Loader was already there: the command was not sent.
    AlreadyLoader,
    /// The command ran and the exact bound Loader appeared afterwards.
    NormalToLoader,
}

impl Transition {
    /// The `transition` fact as Swift spells it.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AlreadyLoader => "already-loader",
            Self::NormalToLoader => "normal-to-loader",
        }
    }
}

/// A proven transition: how, the confirmed Loader, and the HDC receipt when
/// a command ran and returned (a command that timed out leaves none).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LoaderTransition {
    pub transition: Transition,
    pub loader: LoaderIdentity,
    pub receipts: Vec<Receipt>,
}

impl LoaderTransition {
    /// `enterLoader`'s receipt summary.
    pub fn summary(&self) -> BTreeMap<String, String> {
        summary([
            ("transition", self.transition.as_str()),
            ("transitionEvidence", "exact-bound-loader-readback"),
            (
                "loaderIdentitySha256",
                self.loader.serial_digest_sha256.as_str(),
            ),
            ("usbTopology", self.loader.topology.as_str()),
        ])
    }
}

/// `waitForLoader`'s receipt summary.
pub fn loader_summary(identity: &LoaderIdentity) -> BTreeMap<String, String> {
    summary([
        (
            "loaderIdentitySha256",
            identity.serial_digest_sha256.as_str(),
        ),
        ("usbTopology", identity.topology.as_str()),
    ])
}

/// `rebindLoader`'s receipt summary.
pub fn rebind_summary(
    identity: &LoaderIdentity,
    binding_revision: u64,
) -> BTreeMap<String, String> {
    let mut map = loader_summary(identity);
    map.insert("bindingRevision".to_owned(), binding_revision.to_string());
    map
}

/// The identifiers a transition runs under, as the executor's descriptor
/// carries them. ArkForge sees the request ids `<jobID>-<stepID>-already-loader`
/// and `<jobID>-<stepID>-post-transition`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TransitionRequest<'a> {
    pub connect_key: &'a str,
    pub stable_identity_sha256: &'a str,
    pub job_id: &'a str,
    pub step_id: &'a str,
}

/// The Loader arms of the executor, over one dispatch, one USB port, one
/// ArkForge Loader observer and one clock.
pub struct RockchipLoaderTransition<'a> {
    hdc: &'a dyn HdcDispatch,
    usb: &'a dyn UsbProbe,
    loader: &'a dyn LoaderObserver,
    clock: &'a dyn Clock,
}

impl<'a> RockchipLoaderTransition<'a> {
    pub fn new(
        hdc: &'a dyn HdcDispatch,
        usb: &'a dyn UsbProbe,
        loader: &'a dyn LoaderObserver,
        clock: &'a dyn Clock,
    ) -> Self {
        Self {
            hdc,
            usb,
            loader,
            clock,
        }
    }

    /// Swift `enterLoader`. A fresh exact Loader readback is already the
    /// step's postcondition, so a target demonstrably no longer on HDC is not
    /// sent the command (it cannot add evidence, and a missing HDC receipt
    /// would park an already-flashable device as outcome-unknown); USB
    /// identity alone is not enough, so ArkForge's independent observation
    /// confirms it. Otherwise the command runs, and only the exact bound
    /// Loader afterwards proves it — even exit 0 is not the semantic boundary
    /// of a command whose success disconnects its own transport. When the
    /// Loader does not appear: the exact HDC-normal readback proves the
    /// transition did not complete (a failed step with a closed diagnostic),
    /// else a command that did not return cleanly stays as it was, else the
    /// mutation is unknown. Both failure exits carry the command's evidence.
    pub fn enter_loader(
        &self,
        request: &TransitionRequest<'_>,
        budget: &ReadbackBudget,
    ) -> Result<LoaderTransition, LoaderTransitionFailure> {
        if let Ok(loader) = self.exact_loader_identity(request.stable_identity_sha256) {
            let confirmed = self.confirm_loader(
                &loader,
                request.stable_identity_sha256,
                Some(&loader.topology),
                &format!("{}-{}-already-loader", request.job_id, request.step_id),
            )?;
            return Ok(LoaderTransition {
                transition: Transition::AlreadyLoader,
                loader: confirmed,
                receipts: Vec::new(),
            });
        }

        let mut hdc_receipt = None;
        let mut unresolved = None;
        match self.hdc.dispatch(&enter_loader_plan(request.connect_key)) {
            Ok(receipt) => {
                let clean =
                    receipt.exit_status == 0 && !receipt.truncated && receipt.stderr.is_empty();
                if !clean {
                    unresolved = Some(LoaderTransitionFailure::OutcomeUnknown(
                        "HDC reboot-loader returned no clean semantic receipt".to_owned(),
                    ));
                }
                hdc_receipt = Some(receipt);
            }
            // A refused dispatch is pre-spawn and has zero device effect.
            Err(DispatchFailure::Refused(detail)) => {
                return Err(LoaderTransitionFailure::Failed(detail));
            }
            // Everything else is unresolved until the exact Loader readback
            // settles it.
            Err(DispatchFailure::Unobservable(detail)) => {
                unresolved = Some(LoaderTransitionFailure::OutcomeUnknown(detail));
            }
        }

        let post_transition = format!("{}-{}-post-transition", request.job_id, request.step_id);
        if let Ok(loader) =
            self.wait_for_loader(request.stable_identity_sha256, &post_transition, budget)
        {
            return Ok(LoaderTransition {
                transition: Transition::NormalToLoader,
                loader,
                receipts: hdc_receipt.into_iter().collect(),
            });
        }
        let evidence = transition_evidence_summary(hdc_receipt.as_ref(), unresolved.as_ref());
        if let Ok(normal) = self.exact_hdc_normal_identity(request.connect_key) {
            let diagnostic = if unresolved.is_none() {
                FlashRuntimeDiagnostic::EnterLoaderCommandCleanLoaderNotObserved
            } else {
                FlashRuntimeDiagnostic::EnterLoaderHdcNoCleanReceipt
            };
            return Err(LoaderTransitionFailure::ConfirmedNotExecuted {
                detail: format!(
                    "exact bound HDC-normal USB readback proves the Loader transition did not \
                     complete at topology {} {evidence}",
                    normal.topology
                ),
                diagnostic,
            });
        }
        if let Some(unresolved) = unresolved {
            return Err(unresolved);
        }
        Err(LoaderTransitionFailure::OutcomeUnknown(format!(
            "HDC reboot-loader exited but the exact bound Loader was not observed {evidence}"
        )))
    }

    /// Swift `waitForLoader`: the exact bound Loader, confirmed by ArkForge
    /// at the topology it was just seen at, before the deadline.
    pub fn wait_for_loader(
        &self,
        stable_identity_sha256: &str,
        request_id: &str,
        budget: &ReadbackBudget,
    ) -> Result<LoaderIdentity, LoaderTransitionFailure> {
        let deadline = self.clock.now() + budget.deadline;
        while self.clock.now() < deadline {
            if let Ok(identity) = self.exact_loader_identity(stable_identity_sha256)
                && let Ok(confirmed) = self.confirm_loader(
                    &identity,
                    stable_identity_sha256,
                    Some(&identity.topology),
                    request_id,
                )
            {
                return Ok(confirmed);
            }
            self.clock.sleep(budget.poll);
        }
        Err(LoaderTransitionFailure::Failed(
            "the bound DAYU200 did not appear as one exact Loader target".to_owned(),
        ))
    }

    /// Swift `rebindLoader` without its reuse: the exact bound Loader, now,
    /// confirmed by ArkForge at its topology.
    pub fn rebind_loader(
        &self,
        stable_identity_sha256: &str,
        request_id: &str,
    ) -> Result<LoaderIdentity, LoaderTransitionFailure> {
        let identity = self.exact_loader_identity(stable_identity_sha256)?;
        self.confirm_loader(
            &identity,
            stable_identity_sha256,
            Some(&identity.topology),
            request_id,
        )
    }

    /// Swift `exactLoaderIdentity`: exactly one Loader whose serial digest is
    /// the adopted identity.
    fn exact_loader_identity(
        &self,
        stable_identity_sha256: &str,
    ) -> Result<LoaderIdentity, LoaderTransitionFailure> {
        match self.usb.single_loader(stable_identity_sha256) {
            Err(error) => Err(LoaderTransitionFailure::Failed(format!(
                "bound Loader USB identity is unavailable or ambiguous: {error}"
            ))),
            Ok(identity) if identity.serial_digest_sha256 != stable_identity_sha256 => {
                Err(LoaderTransitionFailure::Failed(
                    "Loader USB serial does not match the adopted target identity".to_owned(),
                ))
            }
            Ok(identity) => Ok(identity),
        }
    }

    /// Swift `confirmLoader`: ArkForge's independent observation of the
    /// Loader the port just reported.
    fn confirm_loader(
        &self,
        identity: &LoaderIdentity,
        stable_identity_sha256: &str,
        expected_usb_topology: Option<&str>,
        request_id: &str,
    ) -> Result<LoaderIdentity, LoaderTransitionFailure> {
        self.loader
            .confirm_loader(
                identity,
                stable_identity_sha256,
                expected_usb_topology,
                request_id,
            )
            .map_err(|error| {
                LoaderTransitionFailure::Failed(format!(
                    "ArkForge dual-source Loader observation failed: {error}"
                ))
            })
    }

    /// Swift `exactHDCNormalIdentity`: the HDC-normal device whose serial
    /// digest is this connect key's exact bytes.
    fn exact_hdc_normal_identity(&self, connect_key: &str) -> Result<LoaderIdentity, String> {
        self.usb
            .single_hdc_normal(&sha256_hex(connect_key.as_bytes()))
    }
}

/// Swift `transitionEvidenceSummary`: what the transition command actually
/// did, in one bounded clause — the exit status, a truncated stderr prefix
/// and the runner failure (which names a terminating signal when there was
/// one). Device identity stays out of it. Rust's receipt always knows the
/// exit status, so Swift's `hdcExitStatus=unknown` never occurs here.
pub fn transition_evidence_summary(
    receipt: Option<&Receipt>,
    failure: Option<&LoaderTransitionFailure>,
) -> String {
    let mut parts = Vec::new();
    match receipt {
        Some(receipt) => {
            parts.push(format!("hdcExitStatus={}", receipt.exit_status));
            if receipt.truncated {
                parts.push("hdcOutputTruncated=true".to_owned());
            }
            if !receipt.stderr.is_empty() {
                parts.push(format!("hdcStderr=\"{}\"", evidence_text(&receipt.stderr)));
            }
        }
        None => parts.push("hdcExitStatus=none".to_owned()),
    }
    if let Some(failure) = failure {
        parts.push(format!("hdcFailure={}", failure.detail()));
    }
    format!("[{}]", parts.join(" "))
}

/// Swift `evidenceText`: the first 200 bytes of stderr as one line — control
/// characters and quotes as spaces, runs squeezed, an ellipsis when there was
/// more. (Swift's `controlCharacters` also covers format characters; here
/// only the control category is mapped.)
fn evidence_text(data: &[u8]) -> String {
    let prefix = &data[..data.len().min(MAXIMUM_EVIDENCE_STDERR_BYTES)];
    let Ok(text) = std::str::from_utf8(prefix) else {
        return format!("<{} non-UTF-8 bytes>", data.len());
    };
    let collapsed: String = text
        .chars()
        .map(|character| {
            if character.is_control() || character == '"' {
                ' '
            } else {
                character
            }
        })
        .collect();
    let squeezed = collapsed
        .split(' ')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if data.len() > MAXIMUM_EVIDENCE_STDERR_BYTES {
        format!("{squeezed}…")
    } else {
        squeezed
    }
}

fn summary<const N: usize>(pairs: [(&str, &str); N]) -> BTreeMap<String, String> {
    pairs
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value.to_owned()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host_diagnostics::signal_death;
    use crate::live_mode::HdcIdentity;
    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;
    use std::time::Instant;

    const KEY: &str = "device-1";
    const STABLE: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn request() -> TransitionRequest<'static> {
        TransitionRequest {
            connect_key: KEY,
            stable_identity_sha256: STABLE,
            job_id: "job-1",
            step_id: "enter-loader-mode",
        }
    }

    fn loader(topology: &str) -> LoaderIdentity {
        LoaderIdentity {
            serial_digest_sha256: STABLE.to_owned(),
            topology: topology.to_owned(),
        }
    }

    fn budget(polls: u64) -> ReadbackBudget {
        ReadbackBudget {
            deadline: Duration::from_secs(polls),
            poll: Duration::from_secs(1),
        }
    }

    enum Answer {
        Exit(i32),
        Receipt(Receipt),
        Fail(DispatchFailure),
    }

    struct Scripted {
        answers: RefCell<VecDeque<Answer>>,
        plans: RefCell<Vec<ProcessPlan>>,
    }

    impl Scripted {
        fn new(answers: Vec<Answer>) -> Self {
            Self {
                answers: RefCell::new(answers.into()),
                plans: RefCell::new(Vec::new()),
            }
        }

        fn plans(&self) -> Vec<ProcessPlan> {
            self.plans.borrow().clone()
        }
    }

    impl HdcDispatch for Scripted {
        fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
            self.plans.borrow_mut().push(plan.clone());
            match self
                .answers
                .borrow_mut()
                .pop_front()
                .expect("no scripted answer remains")
            {
                Answer::Exit(exit_status) => Ok(Receipt {
                    exit_status,
                    stdout: Vec::new(),
                    stderr: Vec::new(),
                    truncated: false,
                    duration: Duration::ZERO,
                }),
                Answer::Receipt(receipt) => Ok(receipt),
                Answer::Fail(failure) => Err(failure),
            }
        }
    }

    fn receipt(exit_status: i32, stderr: &[u8], truncated: bool) -> Receipt {
        Receipt {
            exit_status,
            stdout: Vec::new(),
            stderr: stderr.to_vec(),
            truncated,
            duration: Duration::ZERO,
        }
    }

    /// A USB port with at most one Loader (refusing its first `refuse_loader`
    /// lookups, as a board still rebooting does) and at most one HDC-normal
    /// device.
    #[derive(Default)]
    struct UsbScript {
        loader: Option<LoaderIdentity>,
        refuse_loader: Cell<usize>,
        loader_lookups: Cell<usize>,
        hdc_normal: Option<LoaderIdentity>,
    }

    impl UsbScript {
        fn loader(mut self, identity: LoaderIdentity) -> Self {
            self.loader = Some(identity);
            self
        }

        fn loader_after(self, refusals: usize) -> Self {
            self.refuse_loader.set(refusals);
            self
        }

        fn hdc_normal(mut self, connect_key: &str, topology: &str) -> Self {
            self.hdc_normal = Some(LoaderIdentity {
                serial_digest_sha256: sha256_hex(connect_key.as_bytes()),
                topology: topology.to_owned(),
            });
            self
        }
    }

    impl UsbProbe for UsbScript {
        fn single_loader(&self, _: &str) -> Result<LoaderIdentity, String> {
            self.loader_lookups.set(self.loader_lookups.get() + 1);
            let refusals = self.refuse_loader.get();
            if refusals > 0 {
                self.refuse_loader.set(refusals - 1);
                return Err("DAYU200 target unavailable".to_owned());
            }
            self.loader
                .clone()
                .ok_or_else(|| "DAYU200 target ambiguous".to_owned())
        }

        fn single_hdc_normal(
            &self,
            stable_identity_sha256: &str,
        ) -> Result<LoaderIdentity, String> {
            match &self.hdc_normal {
                Some(identity) if identity.serial_digest_sha256 == stable_identity_sha256 => {
                    Ok(identity.clone())
                }
                _ => Err("DAYU200 target unavailable".to_owned()),
            }
        }

        fn single_hdc_normal_at(&self, _: &str) -> Result<HdcIdentity, String> {
            Err("topology-bound HDC observation is unavailable".to_owned())
        }
    }

    /// ArkForge's confirmation, recording what it was asked.
    #[derive(Default)]
    struct LoaderScript {
        refuse: Option<&'static str>,
        confirmations: RefCell<Vec<(LoaderIdentity, Option<String>, String)>>,
    }

    impl LoaderObserver for LoaderScript {
        fn observe_loader(
            &self,
            _: &str,
            _: Option<&str>,
            _: &str,
        ) -> Result<LoaderIdentity, String> {
            Err("the transition confirms, it does not observe".to_owned())
        }

        fn confirm_loader(
            &self,
            identity: &LoaderIdentity,
            _: &str,
            expected_usb_topology: Option<&str>,
            request_id: &str,
        ) -> Result<LoaderIdentity, String> {
            self.confirmations.borrow_mut().push((
                identity.clone(),
                expected_usb_topology.map(str::to_owned),
                request_id.to_owned(),
            ));
            match self.refuse {
                Some(reason) => Err(reason.to_owned()),
                None => Ok(identity.clone()),
            }
        }
    }

    struct FakeClock {
        now: Cell<Instant>,
        pauses: Cell<usize>,
    }

    impl FakeClock {
        fn new() -> Self {
            Self {
                now: Cell::new(Instant::now()),
                pauses: Cell::new(0),
            }
        }
    }

    impl Clock for FakeClock {
        fn now(&self) -> Instant {
            self.now.get()
        }

        fn sleep(&self, duration: Duration) {
            self.now.set(self.now.get() + duration);
            self.pauses.set(self.pauses.get() + 1);
        }
    }

    #[test]
    fn an_exact_loader_already_there_skips_the_command() {
        let hdc = Scripted::new(Vec::new());
        let usb = UsbScript::default().loader(loader("42"));
        let arkforge = LoaderScript::default();
        let clock = FakeClock::new();
        let transition = RockchipLoaderTransition::new(&hdc, &usb, &arkforge, &clock)
            .enter_loader(&request(), &ReadbackBudget::DEFAULT)
            .unwrap();
        assert_eq!(
            transition,
            LoaderTransition {
                transition: Transition::AlreadyLoader,
                loader: loader("42"),
                receipts: Vec::new(),
            }
        );
        assert!(hdc.plans().is_empty());
        assert_eq!(
            transition.summary(),
            summary([
                ("transition", "already-loader"),
                ("transitionEvidence", "exact-bound-loader-readback"),
                ("loaderIdentitySha256", STABLE),
                ("usbTopology", "42"),
            ])
        );
        assert_eq!(
            arkforge.confirmations.borrow().as_slice(),
            [(
                loader("42"),
                Some("42".to_owned()),
                "job-1-enter-loader-mode-already-loader".to_owned()
            )]
        );
        assert_eq!(clock.pauses.get(), 0);
    }

    #[test]
    fn a_clean_command_is_believed_only_by_the_exact_loader_readback() {
        let hdc = Scripted::new(vec![Answer::Exit(0)]);
        // Not in Loader before the command; in Loader on the second readback.
        let usb = UsbScript::default().loader(loader("42")).loader_after(2);
        let arkforge = LoaderScript::default();
        let clock = FakeClock::new();
        let transition = RockchipLoaderTransition::new(&hdc, &usb, &arkforge, &clock)
            .enter_loader(&request(), &ReadbackBudget::DEFAULT)
            .unwrap();
        assert_eq!(transition.transition, Transition::NormalToLoader);
        assert_eq!(transition.loader, loader("42"));
        assert_eq!(transition.receipts, [receipt(0, b"", false)]);
        assert_eq!(transition.summary()["transition"], "normal-to-loader");
        let plans = hdc.plans();
        assert_eq!(plans.len(), 1);
        assert_eq!(
            plans[0].arguments,
            ["-t", "device-1", "shell", "reboot", "loader"]
        );
        assert_eq!(plans[0].timeout, Duration::from_secs(20));
        assert_eq!(plans[0].capture_bytes, 64 * 1024);
        assert_eq!(clock.pauses.get(), 1);
        assert_eq!(usb.loader_lookups.get(), 3);
        assert_eq!(
            arkforge.confirmations.borrow()[0].2,
            "job-1-enter-loader-mode-post-transition"
        );
    }

    #[test]
    fn a_timed_out_command_is_settled_by_the_exact_loader_readback() {
        let hdc = Scripted::new(vec![Answer::Fail(DispatchFailure::Unobservable(
            "process timed out before completion".to_owned(),
        ))]);
        let usb = UsbScript::default().loader(loader("42")).loader_after(1);
        let arkforge = LoaderScript::default();
        let clock = FakeClock::new();
        let transition = RockchipLoaderTransition::new(&hdc, &usb, &arkforge, &clock)
            .enter_loader(&request(), &ReadbackBudget::DEFAULT)
            .unwrap();
        assert_eq!(transition.transition, Transition::NormalToLoader);
        // The timed-out command left no receipt.
        assert!(transition.receipts.is_empty());
        assert_eq!(
            transition.summary()["transitionEvidence"],
            "exact-bound-loader-readback"
        );
    }

    #[test]
    fn a_failed_command_with_the_normal_device_still_there_is_confirmed_not_executed() {
        let hdc = Scripted::new(vec![Answer::Receipt(receipt(
            1,
            b"[Fail]Not match target and connect key\nretry later",
            false,
        ))]);
        let usb = UsbScript::default().hdc_normal(KEY, "42");
        let arkforge = LoaderScript::default();
        let clock = FakeClock::new();
        let failure = RockchipLoaderTransition::new(&hdc, &usb, &arkforge, &clock)
            .enter_loader(&request(), &budget(0))
            .unwrap_err();
        assert_eq!(
            failure,
            LoaderTransitionFailure::ConfirmedNotExecuted {
                detail: "exact bound HDC-normal USB readback proves the Loader transition did \
                         not complete at topology 42 [hdcExitStatus=1 hdcStderr=\"[Fail]Not \
                         match target and connect key retry later\" hdcFailure=HDC \
                         reboot-loader returned no clean semantic receipt]"
                    .to_owned(),
                diagnostic: FlashRuntimeDiagnostic::EnterLoaderHdcNoCleanReceipt,
            }
        );
        assert!(!failure.detail().contains('\n'));
        assert_eq!(
            FlashRuntimeDiagnostic::EnterLoaderHdcNoCleanReceipt.as_str(),
            "enterLoaderHDCNoCleanReceipt"
        );
    }

    #[test]
    fn a_clean_command_without_a_loader_is_confirmed_not_executed_by_the_normal_readback() {
        let hdc = Scripted::new(vec![Answer::Exit(0)]);
        let usb = UsbScript::default().hdc_normal(KEY, "42");
        let arkforge = LoaderScript::default();
        let clock = FakeClock::new();
        let failure = RockchipLoaderTransition::new(&hdc, &usb, &arkforge, &clock)
            .enter_loader(&request(), &budget(2))
            .unwrap_err();
        assert_eq!(
            failure,
            LoaderTransitionFailure::ConfirmedNotExecuted {
                detail: "exact bound HDC-normal USB readback proves the Loader transition did \
                         not complete at topology 42 [hdcExitStatus=0]"
                    .to_owned(),
                diagnostic: FlashRuntimeDiagnostic::EnterLoaderCommandCleanLoaderNotObserved,
            }
        );
        assert_eq!(clock.pauses.get(), 2);
        assert_eq!(
            FlashRuntimeDiagnostic::EnterLoaderCommandCleanLoaderNotObserved.as_str(),
            "enterLoaderCommandCleanLoaderNotObserved"
        );
    }

    #[test]
    fn a_signalled_command_names_the_signal_and_its_crash_report() {
        let signalled = || {
            Scripted::new(vec![Answer::Fail(DispatchFailure::Unobservable(
                signal_death(6),
            ))])
        };
        let arkforge = LoaderScript::default();
        let clock = FakeClock::new();

        let hdc = signalled();
        let normal = UsbScript::default().hdc_normal(KEY, "42");
        let failure = RockchipLoaderTransition::new(&hdc, &normal, &arkforge, &clock)
            .enter_loader(&request(), &budget(0))
            .unwrap_err();
        let LoaderTransitionFailure::ConfirmedNotExecuted { detail, diagnostic } = &failure else {
            panic!("{failure:?}");
        };
        assert!(detail.contains("died on signal 6"), "{detail}");
        assert!(detail.contains("DiagnosticReports"), "{detail}");
        assert!(detail.starts_with(
            "exact bound HDC-normal USB readback proves the Loader transition did not complete \
             at topology 42 [hdcExitStatus=none hdcFailure=process died on signal 6;"
        ));
        assert_eq!(
            *diagnostic,
            FlashRuntimeDiagnostic::EnterLoaderHdcNoCleanReceipt
        );
        assert_eq!(crate::host_diagnostics::signal_number(detail), Some(6));

        // Without the normal readback, the unresolved failure is rethrown as
        // it was, evidence-free.
        let hdc = signalled();
        let nothing = UsbScript::default();
        assert_eq!(
            RockchipLoaderTransition::new(&hdc, &nothing, &arkforge, &clock)
                .enter_loader(&request(), &budget(0))
                .unwrap_err(),
            LoaderTransitionFailure::OutcomeUnknown(signal_death(6))
        );
    }

    #[test]
    fn a_timed_out_command_stays_unknown_without_either_readback() {
        let hdc = Scripted::new(vec![Answer::Fail(DispatchFailure::Unobservable(
            "process timed out before completion".to_owned(),
        ))]);
        let usb = UsbScript::default();
        let arkforge = LoaderScript::default();
        let clock = FakeClock::new();
        assert_eq!(
            RockchipLoaderTransition::new(&hdc, &usb, &arkforge, &clock)
                .enter_loader(&request(), &budget(1))
                .unwrap_err(),
            LoaderTransitionFailure::OutcomeUnknown("process timed out before completion".into())
        );
    }

    #[test]
    fn a_clean_command_with_nothing_observed_is_unknown_with_its_evidence() {
        let hdc = Scripted::new(vec![Answer::Exit(0)]);
        let usb = UsbScript::default();
        let arkforge = LoaderScript::default();
        let clock = FakeClock::new();
        let failure = RockchipLoaderTransition::new(&hdc, &usb, &arkforge, &clock)
            .enter_loader(&request(), &budget(1))
            .unwrap_err();
        assert_eq!(
            failure,
            LoaderTransitionFailure::OutcomeUnknown(
                "HDC reboot-loader exited but the exact bound Loader was not observed \
                 [hdcExitStatus=0]"
                    .into()
            )
        );
        assert_eq!(failure.to_string(), failure.detail());
    }

    #[test]
    fn a_refused_dispatch_is_a_failed_step_before_any_effect() {
        let hdc = Scripted::new(vec![Answer::Fail(DispatchFailure::Refused(
            "dispatch refused: budget".to_owned(),
        ))]);
        let usb = UsbScript::default().loader(loader("42")).loader_after(9);
        let arkforge = LoaderScript::default();
        let clock = FakeClock::new();
        assert_eq!(
            RockchipLoaderTransition::new(&hdc, &usb, &arkforge, &clock)
                .enter_loader(&request(), &ReadbackBudget::DEFAULT)
                .unwrap_err(),
            LoaderTransitionFailure::Failed("dispatch refused: budget".into())
        );
        // Only the already-loader check looked at the port; no readback ran.
        assert_eq!(usb.loader_lookups.get(), 1);
        assert_eq!(clock.pauses.get(), 0);
    }

    #[test]
    fn the_evidence_clause_is_bounded_and_single_line() {
        let long = receipt(2, &[b'e'; 4_000], true);
        let clause = transition_evidence_summary(Some(&long), None);
        assert!(clause.starts_with("[hdcExitStatus=2 hdcOutputTruncated=true hdcStderr=\"eeee"));
        assert!(clause.ends_with("…\"]"), "{clause}");
        assert!(clause.len() < 400, "{}", clause.len());
        assert!(!clause.contains('\n'));

        let quoted = receipt(0, b"say \"hi\"\n\ttwice  \x07", false);
        assert_eq!(
            transition_evidence_summary(Some(&quoted), None),
            "[hdcExitStatus=0 hdcStderr=\"say hi twice\"]"
        );

        let binary = receipt(0, &[0xff, 0xfe, b'x'], false);
        assert_eq!(
            transition_evidence_summary(Some(&binary), None),
            "[hdcExitStatus=0 hdcStderr=\"<3 non-UTF-8 bytes>\"]"
        );

        let cut = receipt(
            0,
            &[b"a".repeat(199).as_slice(), "é".as_bytes()].concat(),
            false,
        );
        assert_eq!(
            transition_evidence_summary(Some(&cut), None),
            "[hdcExitStatus=0 hdcStderr=\"<201 non-UTF-8 bytes>\"]"
        );

        assert_eq!(
            transition_evidence_summary(
                None,
                Some(&LoaderTransitionFailure::OutcomeUnknown("x".into()))
            ),
            "[hdcExitStatus=none hdcFailure=x]"
        );
        assert_eq!(
            transition_evidence_summary(None, None),
            "[hdcExitStatus=none]"
        );
    }

    #[test]
    fn wait_for_loader_gives_up_at_the_deadline() {
        let hdc = Scripted::new(Vec::new());
        let usb = UsbScript::default();
        let arkforge = LoaderScript::default();
        let clock = FakeClock::new();
        let transition = RockchipLoaderTransition::new(&hdc, &usb, &arkforge, &clock);
        assert_eq!(
            transition
                .wait_for_loader(STABLE, "job-1-wait-loader-mode-wait-loader", &budget(3))
                .unwrap_err(),
            LoaderTransitionFailure::Failed(
                "the bound DAYU200 did not appear as one exact Loader target".into()
            )
        );
        assert_eq!(usb.loader_lookups.get(), 3);
        assert_eq!(clock.pauses.get(), 3);
        assert!(arkforge.confirmations.borrow().is_empty());

        transition
            .wait_for_loader(STABLE, "x", &budget(0))
            .unwrap_err();
        assert_eq!(usb.loader_lookups.get(), 3);
    }

    #[test]
    fn the_loader_must_be_the_adopted_identity_and_confirmed_by_arkforge() {
        let hdc = Scripted::new(Vec::new());
        let clock = FakeClock::new();
        let arkforge = LoaderScript::default();

        let other = UsbScript::default().loader(LoaderIdentity {
            serial_digest_sha256: sha256_hex(b"another-board"),
            topology: "42".to_owned(),
        });
        assert_eq!(
            RockchipLoaderTransition::new(&hdc, &other, &arkforge, &clock)
                .rebind_loader(STABLE, "job-1-rebind-a4")
                .unwrap_err(),
            LoaderTransitionFailure::Failed(
                "Loader USB serial does not match the adopted target identity".into()
            )
        );

        let ambiguous = UsbScript::default();
        assert_eq!(
            RockchipLoaderTransition::new(&hdc, &ambiguous, &arkforge, &clock)
                .rebind_loader(STABLE, "job-1-rebind-a4")
                .unwrap_err(),
            LoaderTransitionFailure::Failed(
                "bound Loader USB identity is unavailable or ambiguous: DAYU200 target ambiguous"
                    .into()
            )
        );

        let usb = UsbScript::default().loader(loader("42"));
        let refusing = LoaderScript {
            refuse: Some("arkforged observed an ambiguous Loader set"),
            ..LoaderScript::default()
        };
        assert_eq!(
            RockchipLoaderTransition::new(&hdc, &usb, &refusing, &clock)
                .rebind_loader(STABLE, "job-1-rebind-a4")
                .unwrap_err(),
            LoaderTransitionFailure::Failed(
                "ArkForge dual-source Loader observation failed: arkforged observed an \
                 ambiguous Loader set"
                    .into()
            )
        );

        let confirmed = RockchipLoaderTransition::new(&hdc, &usb, &arkforge, &clock)
            .rebind_loader(STABLE, "job-1-rebind-a4")
            .unwrap();
        assert_eq!(confirmed, loader("42"));
        assert_eq!(
            arkforge.confirmations.borrow().last().unwrap().2,
            "job-1-rebind-a4"
        );
        assert_eq!(
            loader_summary(&confirmed),
            summary([("loaderIdentitySha256", STABLE), ("usbTopology", "42")])
        );
        assert_eq!(
            rebind_summary(&confirmed, 4),
            summary([
                ("loaderIdentitySha256", STABLE),
                ("usbTopology", "42"),
                ("bindingRevision", "4"),
            ])
        );
        assert!(hdc.plans().is_empty());
    }
}
