//! The HDC side of Swift's Rockchip flash executor
//! (`FoundationRockchipRuntimeActionExecutor`, `RockchipRuntimeActionHost.swift`):
//! the waits for the bound target to leave and re-join HDC around a Loader
//! transition, the bound reconnect after a complete overwrite, and the one
//! exact build/model readback that alone may publish a post-flash alias.
//!
//! This is the observation half. It proves the device and reads it, and hands
//! the proof to whoever owns the durable alias store (`verifyBoundBuild`'s
//! `publish`), the Target lineage advance and the executor's observation-reuse
//! cache — none of which live here. Every HDC read runs through an
//! [`HdcDispatch`] and is judged as Swift's `requireSemanticSuccess` judges
//! it; the USB identities come through the [`UsbProbe`] port, which the
//! ArkForge lane serves over `arkforged discoverDevices`.
use crate::live_mode::{HdcIdentity, LoaderIdentity, UsbProbe, sha256_hex};
use crate::{
    DispatchFailure, HdcDispatch, ParseError, ProcessPlan, Property, Receipt, parse_target_list,
    property_value,
};
use std::collections::BTreeMap;
use std::fmt;
use std::time::{Duration, Instant};
use unicode_segmentation::UnicodeSegmentation;

/// Swift `HDCAllowlistedProperty.productModel`, the second read of the
/// post-flash command. (`Property` names only the reads `observe.device@1`
/// dispatches on its own.)
const PRODUCT_MODEL_KEY: &str = "const.product.model";
/// Swift `RockchipHDCIntegrationProfile.postFlashBuildPropertiesCommand`: the
/// one argv token of this surface that carries a shell metacharacter. It is
/// fixed here and never built from a caller's input.
pub const POST_FLASH_BUILD_PROPERTIES_COMMAND: &str =
    "param get const.ohos.fullname; param get const.product.model";
/// The registered tool version Swift parses every wait's target list with.
const TARGET_LIST_VERSION: &str = "3.2.0f";
/// Every read of this surface captures 64 KiB.
const READ_CAPTURE_BYTES: usize = 64 * 1024;
/// `verifyBoundBuild`'s property read: 15 s once the device is present.
const PROPERTIES_READ_TIMEOUT: Duration = Duration::from_secs(15);
/// Swift `properties(_:orderedKeys:)`: a longer value is not a fact.
const MAXIMUM_PROPERTY_CHARACTERS: usize = 400;
/// Swift `outputExcerpt`'s default limit.
const EXCERPT_LIMIT: usize = 200;

/// Swift `RockchipHDCReconnectExpectation`: what the bound target looked like
/// on HDC before the flash — its connect key, that key's alias digest, and
/// the USB topology it occupied.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReconnectExpectation {
    pub previous_connect_key: String,
    pub previous_identity_sha256: String,
    pub usb_topology: String,
}

/// How long a wait may take: the deadline of the whole wait, the budget of
/// each `list targets -v`, and the pause between reads. Swift hardcodes the
/// three; the callers pass one of the named budgets.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WaitBudget {
    pub deadline: Duration,
    pub command_timeout: Duration,
    pub poll: Duration,
}

impl WaitBudget {
    /// `waitForHDCDisconnect`: 15 s, each read 15 s, every second.
    pub const DISCONNECT: Self = Self::seconds(15, 15);
    /// `waitForHDCReconnect`: 120 s.
    pub const RECONNECT: Self = Self::seconds(120, 15);
    /// `waitForBoundHDCReconnect` and `verifyBoundBuild`: 600 s — the first
    /// boot after a complete overwrite initialises a freshly erased userdata
    /// before hdcd comes up; 120 s and 300 s both closed mid-first-boot while
    /// the board answered on its known key minutes later (measured
    /// 2026-08-18). Ten minutes bounds a hung boot without calling this
    /// board's real first boot missing.
    pub const BOUND_RECONNECT: Self = Self::seconds(600, 15);

    const fn seconds(deadline: u64, command_timeout: u64) -> Self {
        Self {
            deadline: Duration::from_secs(deadline),
            command_timeout: Duration::from_secs(command_timeout),
            poll: Duration::from_secs(1),
        }
    }
}

/// The wall clock a wait measures its deadline on and pauses with. Swift
/// hardcodes `ContinuousClock` and `Task.sleep`; a test clock lets a
/// ten-minute wait be exercised in no time.
pub trait Clock {
    fn now(&self) -> Instant;
    fn sleep(&self, duration: Duration);
}

/// The process's monotonic clock and a blocking sleep.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }

    fn sleep(&self, duration: Duration) {
        std::thread::sleep(duration);
    }
}

/// Swift `RuntimeDispatchFailure` as these arms raise it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RockchipHdcFailure {
    /// `.failed`: the step fails and nothing about the device is unknown — a
    /// read without a clean receipt, a refused dispatch, a list the parser
    /// cannot read, a deadline, a readback that does not match.
    Failed(String),
    /// `.outcomeUnknown`: the read itself could not be observed to its end (a
    /// timeout, a signal), so the Job parks.
    OutcomeUnknown(String),
}

impl RockchipHdcFailure {
    pub fn detail(&self) -> &str {
        match self {
            Self::Failed(detail) | Self::OutcomeUnknown(detail) => detail,
        }
    }
}

impl fmt::Display for RockchipHdcFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.detail())
    }
}

impl std::error::Error for RockchipHdcFailure {}

/// The two values `verifyBoundBuild` reads in one command, in that order.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BuildReadback {
    /// `const.ohos.fullname`.
    pub build_version: String,
    /// `const.product.model`.
    pub product_model: String,
}

/// What `verifyBoundBuild` proved before Swift publishes the alias: the
/// bound HDC identity, the exact readback, and the receipts of the reads that
/// proved them (the bound wait's target lists, then the property read).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedBuild {
    pub identity: HdcIdentity,
    pub readback: BuildReadback,
    pub receipts: Vec<Receipt>,
}

impl VerifiedBuild {
    /// The `rebind-and-verify-build` receipt summary. `flashPostflightObservation`
    /// reads `model`, `firmware`, `verification`, `usbTopology` and
    /// `hdcIdentitySha256` back from the durable receipt.
    pub fn summary(&self) -> BTreeMap<String, String> {
        summary([
            ("model", self.readback.product_model.as_str()),
            ("firmware", self.readback.build_version.as_str()),
            (
                "hdcIdentitySha256",
                self.identity.serial_digest_sha256.as_str(),
            ),
            ("usbTopology", self.identity.topology.as_str()),
            ("verification", "exact-published-profile-and-bound-hdc"),
        ])
    }
}

/// `waitForHDCDisconnect` / `waitForHDCReconnect`'s receipt summary.
pub fn hdc_state_summary(connected: bool) -> BTreeMap<String, String> {
    summary([(
        "hdcState",
        if connected {
            "connected"
        } else {
            "disconnected"
        },
    )])
}

/// `waitForBoundHDCReconnect`'s receipt summary.
pub fn bound_reconnect_summary(identity: &HdcIdentity) -> BTreeMap<String, String> {
    summary([
        ("hdcState", "connected"),
        ("hdcIdentitySha256", identity.serial_digest_sha256.as_str()),
        ("usbTopology", identity.topology.as_str()),
    ])
}

/// `observeHDCNormalUSB`'s receipt summary, which the binding reactivation
/// proof reads back (`usbState`, `hdcNormalIdentitySha256`, `usbTopology`).
pub fn hdc_normal_usb_summary(identity: &LoaderIdentity) -> BTreeMap<String, String> {
    summary([
        (
            "hdcNormalIdentitySha256",
            identity.serial_digest_sha256.as_str(),
        ),
        ("usbState", "hdc-normal"),
        ("usbTopology", identity.topology.as_str()),
    ])
}

/// The HDC observation arms of the executor, over one dispatch, one USB port
/// and one clock.
pub struct RockchipHdcObserver<'a> {
    hdc: &'a dyn HdcDispatch,
    usb: &'a dyn UsbProbe,
    clock: &'a dyn Clock,
}

impl<'a> RockchipHdcObserver<'a> {
    pub fn new(hdc: &'a dyn HdcDispatch, usb: &'a dyn UsbProbe, clock: &'a dyn Clock) -> Self {
        Self { hdc, usb, clock }
    }

    /// Swift `observeHDCNormalUSB`: exactly one HDC-normal USB device whose
    /// serial digest is the digest of this connect key's exact bytes. No
    /// process runs; the probe's refusal is passed through as it is.
    pub fn observe_hdc_normal_usb(&self, connect_key: &str) -> Result<LoaderIdentity, String> {
        self.usb
            .single_hdc_normal(&sha256_hex(connect_key.as_bytes()))
    }

    /// Swift `waitForHDC`: read `list targets -v` until exactly one
    /// `Connected` row names the key (`expected_connected`) or no such row
    /// remains, returning every receipt read. An empty list is not a verdict
    /// and neither is one malformed read: a DAYU200 crossing a reboot passes
    /// through USB states in which the server briefly prints a line outside
    /// the registered family (2026-08-04), so only a deadline's worth of them
    /// is a verdict, and the deadline names the last one.
    pub fn wait_for_hdc(
        &self,
        connect_key: &str,
        expected_connected: bool,
        budget: &WaitBudget,
    ) -> Result<Vec<Receipt>, RockchipHdcFailure> {
        let deadline = self.clock.now() + budget.deadline;
        let mut receipts = Vec::new();
        let mut last_malformed = None;
        while self.clock.now() < deadline {
            let receipt = self.read(target_list_plan(budget.command_timeout))?;
            receipts.push(receipt.clone());
            match parse_target_list(&receipt.stdout, TARGET_LIST_VERSION, receipt.truncated) {
                Ok(rows) => {
                    let matches = connected_rows(&rows, connect_key);
                    if if expected_connected {
                        matches == 1
                    } else {
                        matches == 0
                    } {
                        return Ok(receipts);
                    }
                }
                Err(error) => keep_polling_or_fail(error, &mut last_malformed)?,
            }
            self.clock.sleep(budget.poll);
        }
        Err(failed(format!(
            "{}{}",
            if expected_connected {
                "descriptor-bound HDC target did not reconnect before the deadline"
            } else {
                "descriptor-bound HDC target did not disconnect before the deadline"
            },
            malformed_suffix(last_malformed)
        )))
    }

    /// Swift `waitForBoundHDC`: the normal-mode personality of the bound
    /// device after a flash, which may legitimately have a new serial. Two
    /// routes prove the same board, either sufficing when there is exactly
    /// one candidate: the exact HDC-normal device at the recorded topology,
    /// or — the measured board re-enumerates its location across the first
    /// boot (17956864 → 18087936 on 2026-08-18) — the device whose serial
    /// digest is the previous alias, at its current topology. A candidate
    /// whose digest is not its own key's, or that drifted on both axes at
    /// once (a replugged or swapped board: a rebind, not a reconnect), is a
    /// refusal; a candidate without exactly one matching `Connected` row is
    /// not yet a reconnect.
    pub fn wait_for_bound_hdc(
        &self,
        expectation: &ReconnectExpectation,
        budget: &WaitBudget,
    ) -> Result<(HdcIdentity, Vec<Receipt>), RockchipHdcFailure> {
        validate_expectation(expectation, true)?;
        let deadline = self.clock.now() + budget.deadline;
        let mut receipts = Vec::new();
        let mut last_malformed = None;
        while self.clock.now() < deadline {
            let receipt = self.read(target_list_plan(budget.command_timeout))?;
            receipts.push(receipt.clone());
            match parse_target_list(&receipt.stdout, TARGET_LIST_VERSION, receipt.truncated) {
                Ok(rows) => {
                    let by_topology = self
                        .usb
                        .single_hdc_normal_at(&expectation.usb_topology)
                        .ok();
                    let by_known_alias = if by_topology.is_some() {
                        None
                    } else {
                        self.usb
                            .single_hdc_normal(&expectation.previous_identity_sha256)
                            .ok()
                            .and_then(|alias| self.usb.single_hdc_normal_at(&alias.topology).ok())
                    };
                    if let Some(identity) = by_topology.or(by_known_alias) {
                        let observed_digest = sha256_hex(identity.connect_key.as_bytes());
                        if identity.serial_digest_sha256 != observed_digest
                            || !(identity.topology == expectation.usb_topology
                                || identity.serial_digest_sha256
                                    == expectation.previous_identity_sha256)
                        {
                            return Err(failed(
                                "topology-bound HDC USB identity is internally inconsistent",
                            ));
                        }
                        if connected_rows(&rows, &identity.connect_key) == 1 {
                            return Ok((identity, receipts));
                        }
                    }
                }
                Err(error) => keep_polling_or_fail(error, &mut last_malformed)?,
            }
            self.clock.sleep(budget.poll);
        }
        Err(failed(format!(
            "topology-bound HDC target did not reconnect before the deadline{}",
            malformed_suffix(last_malformed)
        )))
    }

    /// Swift `revalidateBoundHDC`: re-prove a just-observed post-flash route
    /// through the USB port before reusing it for the property read, so the
    /// read does not pay a second slow target list without turning a
    /// historical connect key into current evidence. Only the identical
    /// identity, freshly observed at its own topology (or, failing that,
    /// re-resolved through its digest), self-consistent and still at the
    /// recorded topology or the previous alias, passes.
    pub fn revalidate_bound_hdc(
        &self,
        cached: &HdcIdentity,
        expectation: &ReconnectExpectation,
    ) -> Result<HdcIdentity, RockchipHdcFailure> {
        validate_expectation(expectation, false)?;
        let by_topology = self.usb.single_hdc_normal_at(&cached.topology).ok();
        let by_identity = if by_topology.is_some() {
            None
        } else {
            self.usb
                .single_hdc_normal(&cached.serial_digest_sha256)
                .ok()
                .and_then(|alias| self.usb.single_hdc_normal_at(&alias.topology).ok())
        };
        match by_topology.or(by_identity) {
            Some(observed)
                if observed == *cached
                    && observed.serial_digest_sha256
                        == sha256_hex(observed.connect_key.as_bytes())
                    && (observed.topology == expectation.usb_topology
                        || observed.serial_digest_sha256
                            == expectation.previous_identity_sha256) =>
            {
                Ok(observed)
            }
            _ => Err(failed(
                "cached post-flash HDC route did not pass a fresh exact IOKit readback",
            )),
        }
    }

    /// Swift `verifyBoundBuild` up to — not including — the alias
    /// publication: prove the device first (a route cached from the bound
    /// reconnect, revalidated, or a fresh bound wait), then read it once, then
    /// require the model and the build to equal the published profile
    /// exactly. What comes back is the proof the alias-store owner publishes.
    pub fn verify_bound_build(
        &self,
        expectation: &ReconnectExpectation,
        cached: Option<&HdcIdentity>,
        expected_product_model: &str,
        expected_build_version: &str,
        budget: &WaitBudget,
    ) -> Result<VerifiedBuild, RockchipHdcFailure> {
        if expected_product_model.is_empty() || expected_build_version.is_empty() {
            return Err(failed(
                "post-flash binding verification is not fully configured",
            ));
        }
        let (identity, mut receipts) =
            match cached.and_then(|cached| self.revalidate_bound_hdc(cached, expectation).ok()) {
                Some(identity) => (identity, Vec::new()),
                None => self.wait_for_bound_hdc(expectation, budget)?,
            };
        let properties = self.read(build_properties_plan(&identity.connect_key))?;
        let readback = parse_build_properties(&properties.stdout)?;
        if readback.product_model != expected_product_model {
            return Err(failed(
                "post-flash model readback does not match the published profile",
            ));
        }
        if readback.build_version != expected_build_version {
            return Err(failed(
                "post-flash build readback does not match the published profile",
            ));
        }
        receipts.push(properties);
        Ok(VerifiedBuild {
            identity,
            readback,
            receipts,
        })
    }

    /// Swift `run(executable:arguments:timeoutSeconds:budget:)` for a read
    /// without an effect: dispatched, then judged by `requireSemanticSuccess`.
    fn read(&self, plan: ProcessPlan) -> Result<Receipt, RockchipHdcFailure> {
        let receipt = self.hdc.dispatch(&plan).map_err(|failure| match failure {
            DispatchFailure::Refused(detail) => RockchipHdcFailure::Failed(detail),
            DispatchFailure::Unobservable(detail) => RockchipHdcFailure::OutcomeUnknown(detail),
        })?;
        require_semantic_success(&receipt)?;
        Ok(receipt)
    }
}

/// Swift `properties(_:orderedKeys:)` for the post-flash command: exactly two
/// non-empty lines, each either a bare value or the value echoed behind its
/// own key in the command's order, each at most 400 characters.
pub fn parse_build_properties(stdout: &[u8]) -> Result<BuildReadback, RockchipHdcFailure> {
    let text = std::str::from_utf8(stdout)
        .map_err(|_| failed("post-flash property readback is not UTF-8"))?;
    let keys = [Property::FullBuildVersion.key(), PRODUCT_MODEL_KEY];
    let lines: Vec<&str> = text
        .split(is_newline)
        .filter(|line| !line.is_empty())
        .map(str::trim)
        .collect();
    if lines.len() != keys.len() {
        return Err(failed(format!(
            "post-flash property readback did not return exactly {} values",
            keys.len()
        )));
    }
    let mut values = Vec::with_capacity(keys.len());
    for (key, line) in keys.iter().zip(&lines) {
        // An echoed property name must match this fixed command's order. Bare
        // values remain supported, including values that contain an equals
        // sign, as the single-property parser supports them.
        let echoed = keys.iter().find(|candidate| line.starts_with(*candidate));
        if echoed.is_some_and(|echoed| echoed != key) {
            return Err(failed("post-flash property readback order or key drifted"));
        }
        let value = property_value(line, key);
        if value.is_empty() || value.graphemes(true).count() > MAXIMUM_PROPERTY_CHARACTERS {
            return Err(failed(format!(
                "post-flash property {key} is empty or oversized"
            )));
        }
        values.push(value.to_owned());
    }
    let product_model = values.pop().unwrap_or_default();
    let build_version = values.pop().unwrap_or_default();
    Ok(BuildReadback {
        build_version,
        product_model,
    })
}

/// Swift `RockchipRuntimeActionHost.outputExcerpt`: the last captured output
/// reduced to one printable line — the tail of the capture (four times the
/// limit in bytes), every non-ASCII or line-ending character a space, runs
/// of spaces collapsed, and the newest `limit` characters kept behind an
/// ellipsis when longer.
pub fn output_excerpt(data: &[u8], limit: usize) -> String {
    let tail = &data[data.len().saturating_sub(4 * limit)..];
    let text = String::from_utf8_lossy(tail);
    let printable: String = text
        .graphemes(true)
        .map(|grapheme| {
            if grapheme.len() == 1
                && grapheme.is_ascii()
                && !matches!(grapheme, "\n" | "\r" | "\u{0B}" | "\u{0C}")
            {
                grapheme
            } else {
                " "
            }
        })
        .collect();
    let collapsed = printable
        .split(' ')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let count = collapsed.graphemes(true).count();
    if count <= limit {
        collapsed
    } else {
        let kept: String = collapsed.graphemes(true).skip(count - limit).collect();
        format!("…{kept}")
    }
}

/// Swift `requireSemanticSuccess` for a read without an effect: a receipt
/// that is not clean and complete names each reason and the newest output,
/// never the output itself, and fails the step.
fn require_semantic_success(receipt: &Receipt) -> Result<(), RockchipHdcFailure> {
    let clean = receipt.exit_status == 0 && !receipt.truncated && receipt.stderr.is_empty();
    if clean {
        return Ok(());
    }
    let mut reasons = Vec::new();
    if receipt.exit_status != 0 {
        reasons.push(format!("exitStatus={}", receipt.exit_status));
    }
    if receipt.truncated {
        reasons.push("stdoutTruncated".to_owned());
    }
    if !receipt.stderr.is_empty() {
        reasons.push(format!("stderrByteCount={}", receipt.stderr.len()));
    }
    reasons.push(format!("stdoutCapturedBytes={}", receipt.stdout.len()));
    Err(failed(format!(
        "typed command lacked a clean, complete semantic receipt ({}); last output: {}",
        reasons.join(", "),
        output_excerpt(&receipt.stdout, EXCERPT_LIMIT)
    )))
}

fn target_list_plan(command_timeout: Duration) -> ProcessPlan {
    ProcessPlan {
        arguments: ["list", "targets", "-v"]
            .iter()
            .map(|value| (*value).to_owned())
            .collect(),
        timeout: command_timeout,
        capture_bytes: READ_CAPTURE_BYTES,
    }
}

fn build_properties_plan(connect_key: &str) -> ProcessPlan {
    ProcessPlan {
        arguments: [
            "-t",
            connect_key,
            "shell",
            POST_FLASH_BUILD_PROPERTIES_COMMAND,
        ]
        .iter()
        .map(|value| (*value).to_owned())
        .collect(),
        timeout: PROPERTIES_READ_TIMEOUT,
        capture_bytes: READ_CAPTURE_BYTES,
    }
}

/// The precondition of both bound routines: the expectation's digest is its
/// key's; for the wait, also a non-empty all-digit topology.
fn validate_expectation(
    expectation: &ReconnectExpectation,
    with_topology: bool,
) -> Result<(), RockchipHdcFailure> {
    let digest_matches = sha256_hex(expectation.previous_connect_key.as_bytes())
        == expectation.previous_identity_sha256;
    let topology_valid = !with_topology
        || (!expectation.usb_topology.is_empty()
            && expectation
                .usb_topology
                .bytes()
                .all(|byte| byte.is_ascii_digit()));
    if digest_matches && topology_valid {
        Ok(())
    } else {
        Err(failed("post-flash HDC binding expectation is malformed"))
    }
}

fn connected_rows(rows: &[crate::DeviceCandidate], connect_key: &str) -> usize {
    rows.iter()
        .filter(|row| row.connect_key == connect_key && row.state == "Connected")
        .count()
}

/// The parser outcomes a wait tolerates (an empty list, a malformed read,
/// remembered) and the ones that end it.
fn keep_polling_or_fail(
    error: ParseError,
    last_malformed: &mut Option<&'static str>,
) -> Result<(), RockchipHdcFailure> {
    match error {
        ParseError::Empty => Ok(()),
        ParseError::Malformed(reason) => {
            *last_malformed = Some(reason);
            Ok(())
        }
        ParseError::UnsupportedVersion(version) => Err(failed(format!(
            "HDC target parser does not support {version}"
        ))),
        ParseError::InvalidEncoding => Err(failed("HDC target list is not UTF-8")),
        ParseError::Truncated => Err(failed("HDC target list exceeded its byte budget")),
    }
}

fn malformed_suffix(last_malformed: Option<&'static str>) -> String {
    last_malformed
        .map(|reason| format!("; last malformed target list read: {reason}"))
        .unwrap_or_default()
}

fn is_newline(character: char) -> bool {
    matches!(
        character,
        '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

fn failed(detail: impl Into<String>) -> RockchipHdcFailure {
    RockchipHdcFailure::Failed(detail.into())
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
    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;

    const KEY: &str = "device-1";
    const PREVIOUS_KEY: &str = "device-0";

    fn expectation(topology: &str) -> ReconnectExpectation {
        ReconnectExpectation {
            previous_connect_key: PREVIOUS_KEY.to_owned(),
            previous_identity_sha256: sha256_hex(PREVIOUS_KEY.as_bytes()),
            usb_topology: topology.to_owned(),
        }
    }

    fn identity(connect_key: &str, topology: &str) -> HdcIdentity {
        HdcIdentity {
            connect_key: connect_key.to_owned(),
            serial_digest_sha256: sha256_hex(connect_key.as_bytes()),
            topology: topology.to_owned(),
        }
    }

    fn row(connect_key: &str) -> String {
        format!("{connect_key}\t\tUSB\tConnected\tlocalhost\n")
    }

    /// A deadline of `polls` seconds with a one-second pause: exactly `polls`
    /// reads before the deadline.
    fn budget(polls: u64) -> WaitBudget {
        WaitBudget {
            deadline: Duration::from_secs(polls),
            command_timeout: Duration::from_secs(15),
            poll: Duration::from_secs(1),
        }
    }

    enum Answer {
        Out(String),
        Bytes(Vec<u8>),
        Exit(i32),
        Stderr(&'static str, &'static str),
        Truncated(String),
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

        fn reads(&self) -> usize {
            self.plans.borrow().len()
        }
    }

    impl HdcDispatch for Scripted {
        fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
            self.plans.borrow_mut().push(plan.clone());
            let answer = self
                .answers
                .borrow_mut()
                .pop_front()
                .expect("no scripted answer remains");
            let receipt = |exit_status: i32, stdout: Vec<u8>, stderr: Vec<u8>, truncated| Receipt {
                exit_status,
                stdout,
                stderr,
                truncated,
                duration: Duration::ZERO,
            };
            match answer {
                Answer::Out(stdout) => Ok(receipt(0, stdout.into(), Vec::new(), false)),
                Answer::Bytes(stdout) => Ok(receipt(0, stdout, Vec::new(), false)),
                Answer::Exit(status) => Ok(receipt(status, Vec::new(), Vec::new(), false)),
                Answer::Stderr(stdout, stderr) => {
                    Ok(receipt(0, stdout.into(), stderr.into(), false))
                }
                Answer::Truncated(stdout) => Ok(receipt(0, stdout.into(), Vec::new(), true)),
                Answer::Fail(failure) => Err(failure),
            }
        }
    }

    /// A USB port scripted by topology and by serial digest.
    #[derive(Default)]
    struct UsbScript {
        at: BTreeMap<String, HdcIdentity>,
        by_digest: BTreeMap<String, LoaderIdentity>,
        /// Refuse the first `n` topology lookups (an enumeration that has not
        /// settled yet).
        refuse_first: Cell<usize>,
    }

    impl UsbScript {
        fn at(mut self, identity: HdcIdentity) -> Self {
            self.at.insert(identity.topology.clone(), identity);
            self
        }

        fn digest(mut self, connect_key: &str, topology: &str) -> Self {
            let digest = sha256_hex(connect_key.as_bytes());
            self.by_digest.insert(
                digest.clone(),
                LoaderIdentity {
                    serial_digest_sha256: digest,
                    topology: topology.to_owned(),
                },
            );
            self
        }
    }

    impl UsbProbe for UsbScript {
        fn single_loader(&self, _: &str) -> Result<LoaderIdentity, String> {
            Err("DAYU200 target unavailable".to_owned())
        }

        fn single_hdc_normal(
            &self,
            stable_identity_sha256: &str,
        ) -> Result<LoaderIdentity, String> {
            self.by_digest
                .get(stable_identity_sha256)
                .cloned()
                .ok_or_else(|| "DAYU200 target unavailable".to_owned())
        }

        fn single_hdc_normal_at(&self, usb_topology: &str) -> Result<HdcIdentity, String> {
            let refused = self.refuse_first.get();
            if refused > 0 {
                self.refuse_first.set(refused - 1);
                return Err("DAYU200 target unavailable".to_owned());
            }
            self.at
                .get(usb_topology)
                .cloned()
                .ok_or_else(|| "DAYU200 target unavailable".to_owned())
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

    fn detail<T: fmt::Debug>(result: Result<T, RockchipHdcFailure>) -> String {
        match result {
            Err(RockchipHdcFailure::Failed(detail)) => detail,
            other => panic!("expected a failed step, got {other:?}"),
        }
    }

    #[test]
    fn a_reconnect_wait_survives_a_transient_malformed_list() {
        let hdc = Scripted::new(vec![
            Answer::Out("device-1\tUSB\tConnected\n".into()),
            Answer::Out(row(KEY)),
        ]);
        let usb = UsbScript::default();
        let clock = FakeClock::new();
        let receipts = RockchipHdcObserver::new(&hdc, &usb, &clock)
            .wait_for_hdc(KEY, true, &budget(10))
            .unwrap();
        assert_eq!(receipts.len(), 2);
        assert_eq!(clock.pauses.get(), 1);
        for plan in hdc.plans() {
            assert_eq!(plan.arguments, ["list", "targets", "-v"]);
            assert_eq!(plan.timeout, Duration::from_secs(15));
            assert_eq!(plan.capture_bytes, 64 * 1024);
        }
        assert_eq!(
            hdc_state_summary(true),
            summary([("hdcState", "connected")])
        );
    }

    #[test]
    fn a_disconnect_wait_is_proved_by_the_empty_sentinel_not_by_silence() {
        let hdc = Scripted::new(vec![
            Answer::Out(String::new()),
            Answer::Out("[Empty]\n".into()),
        ]);
        let usb = UsbScript::default();
        let clock = FakeClock::new();
        let receipts = RockchipHdcObserver::new(&hdc, &usb, &clock)
            .wait_for_hdc(KEY, false, &budget(10))
            .unwrap();
        assert_eq!(receipts.len(), 2);
        assert_eq!(
            hdc_state_summary(false),
            summary([("hdcState", "disconnected")])
        );

        let silent = Scripted::new(vec![
            Answer::Out(String::new()),
            Answer::Out(String::new()),
            Answer::Out(String::new()),
        ]);
        let clock = FakeClock::new();
        assert_eq!(
            detail(
                RockchipHdcObserver::new(&silent, &usb, &clock).wait_for_hdc(
                    KEY,
                    false,
                    &budget(3)
                )
            ),
            "descriptor-bound HDC target did not disconnect before the deadline"
        );
        assert_eq!(silent.reads(), 3);
    }

    #[test]
    fn a_deadline_names_the_last_malformed_read_and_a_zero_deadline_reads_nothing() {
        let hdc = Scripted::new(vec![
            Answer::Out("device-1\tUSB\tConnected\n".into()),
            Answer::Out("device-1\t\tUSB\tConnected\tlocalhost\textra\n".into()),
        ]);
        let usb = UsbScript::default();
        let clock = FakeClock::new();
        assert_eq!(
            detail(RockchipHdcObserver::new(&hdc, &usb, &clock).wait_for_hdc(
                KEY,
                true,
                &budget(2)
            )),
            "descriptor-bound HDC target did not reconnect before the deadline; last malformed \
             target list read: target line is not the registered 5-column family"
        );
        assert_eq!(hdc.reads(), 2);

        let untouched = Scripted::new(Vec::new());
        assert_eq!(
            detail(
                RockchipHdcObserver::new(&untouched, &usb, &clock).wait_for_hdc(
                    KEY,
                    true,
                    &budget(0)
                )
            ),
            "descriptor-bound HDC target did not reconnect before the deadline"
        );
        assert_eq!(untouched.reads(), 0);
    }

    #[test]
    fn a_list_read_without_a_clean_receipt_fails_with_swift_s_reasons() {
        let usb = UsbScript::default();
        let clock = FakeClock::new();
        let cases: Vec<(Answer, RockchipHdcFailure)> = vec![
            (
                Answer::Exit(1),
                failed(
                    "typed command lacked a clean, complete semantic receipt (exitStatus=1, \
                     stdoutCapturedBytes=0); last output: ",
                ),
            ),
            (
                Answer::Stderr("abc", "err"),
                failed(
                    "typed command lacked a clean, complete semantic receipt (stderrByteCount=3, \
                     stdoutCapturedBytes=3); last output: abc",
                ),
            ),
            (
                Answer::Truncated(row(KEY)),
                failed(
                    "typed command lacked a clean, complete semantic receipt (stdoutTruncated, \
                     stdoutCapturedBytes=34); last output: device-1\t\tUSB\tConnected\tlocalhost",
                ),
            ),
            (
                Answer::Fail(DispatchFailure::Unobservable(
                    "process timed out before completion".into(),
                )),
                RockchipHdcFailure::OutcomeUnknown("process timed out before completion".into()),
            ),
            (
                Answer::Fail(DispatchFailure::Refused("dispatch refused: budget".into())),
                failed("dispatch refused: budget"),
            ),
            (
                Answer::Bytes(vec![0xff, b'\n']),
                failed("HDC target list is not UTF-8"),
            ),
        ];
        for (answer, expected) in cases {
            let hdc = Scripted::new(vec![answer]);
            let error = RockchipHdcObserver::new(&hdc, &usb, &clock)
                .wait_for_hdc(KEY, true, &budget(10))
                .unwrap_err();
            assert_eq!(error, expected);
            assert_eq!(error.to_string(), expected.detail());
            assert_eq!(hdc.reads(), 1);
        }
    }

    #[test]
    fn output_excerpt_keeps_the_tail_as_one_printable_line() {
        assert_eq!(output_excerpt(b"a\r\nb  c\t\xd0\xb4\n", 200), "a b c\t");
        assert_eq!(output_excerpt(b"", 200), "");
        let long = "x".repeat(1_000);
        let excerpt = output_excerpt(long.as_bytes(), 200);
        assert_eq!(excerpt, format!("…{}", "x".repeat(200)));
        // Only the last four limits of bytes are looked at.
        let mixed = format!("{}{}", "y".repeat(100), "z".repeat(800));
        assert_eq!(
            output_excerpt(mixed.as_bytes(), 200),
            format!("…{}", "z".repeat(200))
        );
        let short = format!("{}{}", "y".repeat(50), "z".repeat(100));
        assert_eq!(output_excerpt(short.as_bytes(), 200), short);
    }

    #[test]
    fn the_bound_reconnect_takes_the_recorded_topology_first() {
        let hdc = Scripted::new(vec![Answer::Out(row("device-2"))]);
        let usb = UsbScript::default().at(identity("device-2", "42"));
        let clock = FakeClock::new();
        let (found, receipts) = RockchipHdcObserver::new(&hdc, &usb, &clock)
            .wait_for_bound_hdc(&expectation("42"), &budget(10))
            .unwrap();
        assert_eq!(found, identity("device-2", "42"));
        assert_eq!(receipts.len(), 1);
        assert_eq!(
            bound_reconnect_summary(&found),
            summary([
                ("hdcState", "connected"),
                ("hdcIdentitySha256", &sha256_hex(b"device-2")),
                ("usbTopology", "42"),
            ])
        );
    }

    #[test]
    fn the_bound_reconnect_falls_back_to_the_known_alias_at_its_new_port() {
        let hdc = Scripted::new(vec![Answer::Out(row(PREVIOUS_KEY))]);
        let usb = UsbScript::default()
            .digest(PREVIOUS_KEY, "43")
            .at(identity(PREVIOUS_KEY, "43"));
        let clock = FakeClock::new();
        let (found, receipts) = RockchipHdcObserver::new(&hdc, &usb, &clock)
            .wait_for_bound_hdc(&expectation("42"), &budget(10))
            .unwrap();
        assert_eq!(found, identity(PREVIOUS_KEY, "43"));
        assert_eq!(receipts.len(), 1);

        // Neither route: the board is not there yet, until the deadline.
        let hdc = Scripted::new(vec![
            Answer::Out(row(PREVIOUS_KEY)),
            Answer::Out(row(PREVIOUS_KEY)),
        ]);
        let absent = UsbScript::default();
        let clock = FakeClock::new();
        assert_eq!(
            detail(
                RockchipHdcObserver::new(&hdc, &absent, &clock)
                    .wait_for_bound_hdc(&expectation("42"), &budget(2))
            ),
            "topology-bound HDC target did not reconnect before the deadline"
        );
        assert_eq!(hdc.reads(), 2);
    }

    #[test]
    fn a_route_that_drifted_on_both_axes_is_a_rebind_not_a_reconnect() {
        let clock = FakeClock::new();
        // The previous alias's digest resolves to a port now held by another
        // serial: a different device at a different port, a replugged or
        // swapped board.
        let hdc = Scripted::new(vec![Answer::Out(row("device-9"))]);
        let swapped = UsbScript::default()
            .digest(PREVIOUS_KEY, "43")
            .at(identity("device-9", "43"));
        assert_eq!(
            detail(
                RockchipHdcObserver::new(&hdc, &swapped, &clock)
                    .wait_for_bound_hdc(&expectation("41"), &budget(10))
            ),
            "topology-bound HDC USB identity is internally inconsistent"
        );
        assert_eq!(hdc.reads(), 1);

        // A digest that is not its own key's.
        let hdc = Scripted::new(vec![Answer::Out(row("device-2"))]);
        let inconsistent = UsbScript::default().at(HdcIdentity {
            serial_digest_sha256: sha256_hex(b"device-3"),
            ..identity("device-2", "42")
        });
        assert_eq!(
            detail(
                RockchipHdcObserver::new(&hdc, &inconsistent, &clock)
                    .wait_for_bound_hdc(&expectation("42"), &budget(10))
            ),
            "topology-bound HDC USB identity is internally inconsistent"
        );
    }

    #[test]
    fn a_bound_route_without_its_connected_row_keeps_polling() {
        let hdc = Scripted::new(vec![
            Answer::Out(row(KEY)),
            Answer::Out("device-2\t\tUSB\tOffline\tlocalhost\n".to_owned()),
            Answer::Out(format!("{}{}", row("device-2"), row("device-2"))),
        ]);
        let usb = UsbScript::default().at(identity("device-2", "42"));
        let clock = FakeClock::new();
        assert_eq!(
            detail(
                RockchipHdcObserver::new(&hdc, &usb, &clock)
                    .wait_for_bound_hdc(&expectation("42"), &budget(3))
            ),
            "topology-bound HDC target did not reconnect before the deadline"
        );
        assert_eq!(hdc.reads(), 3);
    }

    #[test]
    fn a_malformed_expectation_reads_nothing() {
        let usb = UsbScript::default().at(identity("device-2", "42"));
        let clock = FakeClock::new();
        let malformed = [
            ReconnectExpectation {
                previous_identity_sha256: sha256_hex(b"someone-else"),
                ..expectation("42")
            },
            expectation(""),
            expectation("4a"),
        ];
        for expectation in &malformed {
            let hdc = Scripted::new(Vec::new());
            assert_eq!(
                detail(
                    RockchipHdcObserver::new(&hdc, &usb, &clock)
                        .wait_for_bound_hdc(expectation, &budget(10))
                ),
                "post-flash HDC binding expectation is malformed"
            );
            assert_eq!(hdc.reads(), 0);
        }
        // Revalidation checks the digest only: the previous alias at a new
        // port revalidates under a topology the wait would refuse.
        let hdc = Scripted::new(Vec::new());
        let ports = UsbScript::default()
            .at(identity("device-2", "42"))
            .at(identity(PREVIOUS_KEY, "43"));
        let observer = RockchipHdcObserver::new(&hdc, &ports, &clock);
        assert_eq!(
            detail(observer.revalidate_bound_hdc(&identity("device-2", "42"), &malformed[0])),
            "post-flash HDC binding expectation is malformed"
        );
        assert_eq!(
            observer
                .revalidate_bound_hdc(&identity(PREVIOUS_KEY, "43"), &malformed[2])
                .unwrap(),
            identity(PREVIOUS_KEY, "43")
        );
        assert_eq!(hdc.reads(), 0);
    }

    #[test]
    fn revalidation_accepts_only_the_same_route_freshly_observed() {
        let hdc = Scripted::new(Vec::new());
        let clock = FakeClock::new();
        let cached = identity("device-2", "42");

        let same = UsbScript::default().at(cached.clone());
        assert_eq!(
            RockchipHdcObserver::new(&hdc, &same, &clock)
                .revalidate_bound_hdc(&cached, &expectation("42"))
                .unwrap(),
            cached
        );

        let another = UsbScript::default().at(identity("device-3", "42"));
        assert_eq!(
            detail(
                RockchipHdcObserver::new(&hdc, &another, &clock)
                    .revalidate_bound_hdc(&cached, &expectation("42"))
            ),
            "cached post-flash HDC route did not pass a fresh exact IOKit readback"
        );

        // The route by digest is a second look at the same port, not a new
        // route: an enumeration that has not settled passes on the retry…
        let unsettled = UsbScript::default()
            .at(cached.clone())
            .digest("device-2", "42");
        unsettled.refuse_first.set(1);
        assert_eq!(
            RockchipHdcObserver::new(&hdc, &unsettled, &clock)
                .revalidate_bound_hdc(&cached, &expectation("42"))
                .unwrap(),
            cached
        );
        // …while a device that moved is no longer the cached route.
        let moved = UsbScript::default()
            .at(identity("device-2", "43"))
            .digest("device-2", "43");
        assert_eq!(
            detail(
                RockchipHdcObserver::new(&hdc, &moved, &clock)
                    .revalidate_bound_hdc(&cached, &expectation("42"))
            ),
            "cached post-flash HDC route did not pass a fresh exact IOKit readback"
        );

        // The previous alias at a new port is still the bound device.
        let alias = identity(PREVIOUS_KEY, "43");
        let at_new_port = UsbScript::default().at(alias.clone());
        assert_eq!(
            RockchipHdcObserver::new(&hdc, &at_new_port, &clock)
                .revalidate_bound_hdc(&alias, &expectation("42"))
                .unwrap(),
            alias
        );
        assert_eq!(hdc.reads(), 0);
    }

    #[test]
    fn build_properties_are_two_ordered_values() {
        let readback = |stdout: &str| parse_build_properties(stdout.as_bytes());
        let expected = BuildReadback {
            build_version: "OpenHarmony-7.0.0.37".to_owned(),
            product_model: "ohos".to_owned(),
        };
        assert_eq!(
            readback("const.ohos.fullname = OpenHarmony-7.0.0.37\nconst.product.model = ohos\n")
                .unwrap(),
            expected
        );
        assert_eq!(
            readback("OpenHarmony-7.0.0.37\r\nohos\r\n").unwrap(),
            expected
        );
        assert_eq!(
            readback("\n  const.ohos.fullname=OpenHarmony-7.0.0.37  \n\nohos\n").unwrap(),
            expected
        );
        assert_eq!(readback("a=b=c\nohos\n").unwrap().build_version, "a=b=c");
        assert_eq!(
            detail(readback("OpenHarmony-7.0.0.37\n")),
            "post-flash property readback did not return exactly 2 values"
        );
        assert_eq!(
            detail(readback("a\nb\nc\n")),
            "post-flash property readback did not return exactly 2 values"
        );
        assert_eq!(
            detail(readback(
                "const.product.model = ohos\nconst.ohos.fullname = OpenHarmony-7.0.0.37\n"
            )),
            "post-flash property readback order or key drifted"
        );
        assert_eq!(
            detail(readback("OpenHarmony-7.0.0.37\nconst.product.model =   \n")),
            "post-flash property const.product.model is empty or oversized"
        );
        assert_eq!(
            detail(readback(&format!("{}\nohos\n", "v".repeat(401)))),
            "post-flash property const.ohos.fullname is empty or oversized"
        );
        assert_eq!(
            readback(&format!("{}\nohos\n", "v".repeat(400)))
                .unwrap()
                .build_version
                .len(),
            400
        );
        assert_eq!(
            detail(parse_build_properties(&[0xff, b'\n', b'o', b'\n'])),
            "post-flash property readback is not UTF-8"
        );
    }

    #[test]
    fn verify_bound_build_proves_the_device_then_the_model_then_the_build_and_publishes_nothing() {
        let properties = "const.ohos.fullname = OpenHarmony-7.0.0.37\nconst.product.model = ohos\n";
        let usb = UsbScript::default().at(identity("device-2", "42"));
        let clock = FakeClock::new();

        let hdc = Scripted::new(vec![
            Answer::Out(row("device-2")),
            Answer::Out(properties.into()),
        ]);
        let verified = RockchipHdcObserver::new(&hdc, &usb, &clock)
            .verify_bound_build(
                &expectation("42"),
                None,
                "ohos",
                "OpenHarmony-7.0.0.37",
                &budget(10),
            )
            .unwrap();
        assert_eq!(verified.identity, identity("device-2", "42"));
        assert_eq!(
            verified.readback,
            BuildReadback {
                build_version: "OpenHarmony-7.0.0.37".to_owned(),
                product_model: "ohos".to_owned(),
            }
        );
        assert_eq!(verified.receipts.len(), 2);
        assert_eq!(
            hdc.plans()[1].arguments,
            [
                "-t",
                "device-2",
                "shell",
                POST_FLASH_BUILD_PROPERTIES_COMMAND
            ]
        );
        assert_eq!(hdc.plans()[1].timeout, Duration::from_secs(15));
        assert_eq!(hdc.plans()[1].capture_bytes, 64 * 1024);
        assert_eq!(
            verified.summary(),
            summary([
                ("model", "ohos"),
                ("firmware", "OpenHarmony-7.0.0.37"),
                ("hdcIdentitySha256", &sha256_hex(b"device-2")),
                ("usbTopology", "42"),
                ("verification", "exact-published-profile-and-bound-hdc"),
            ])
        );

        // The model is judged before the build.
        let hdc = Scripted::new(vec![
            Answer::Out(row("device-2")),
            Answer::Out(properties.into()),
        ]);
        assert_eq!(
            detail(
                RockchipHdcObserver::new(&hdc, &usb, &clock).verify_bound_build(
                    &expectation("42"),
                    None,
                    "rk3568",
                    "OpenHarmony-7.0.0.36",
                    &budget(10)
                )
            ),
            "post-flash model readback does not match the published profile"
        );
        let hdc = Scripted::new(vec![
            Answer::Out(row("device-2")),
            Answer::Out(properties.into()),
        ]);
        assert_eq!(
            detail(
                RockchipHdcObserver::new(&hdc, &usb, &clock).verify_bound_build(
                    &expectation("42"),
                    None,
                    "ohos",
                    "OpenHarmony-7.0.0.36",
                    &budget(10)
                )
            ),
            "post-flash build readback does not match the published profile"
        );

        // Nothing is read for an unconfigured verification.
        let hdc = Scripted::new(Vec::new());
        assert_eq!(
            detail(
                RockchipHdcObserver::new(&hdc, &usb, &clock).verify_bound_build(
                    &expectation("42"),
                    None,
                    "",
                    "OpenHarmony-7.0.0.37",
                    &budget(10)
                )
            ),
            "post-flash binding verification is not fully configured"
        );
        assert_eq!(hdc.reads(), 0);

        // A route cached from the bound reconnect and revalidated skips the
        // target list: one read, one receipt.
        let hdc = Scripted::new(vec![Answer::Out(properties.into())]);
        let cached = identity("device-2", "42");
        let verified = RockchipHdcObserver::new(&hdc, &usb, &clock)
            .verify_bound_build(
                &expectation("42"),
                Some(&cached),
                "ohos",
                "OpenHarmony-7.0.0.37",
                &budget(10),
            )
            .unwrap();
        assert_eq!(verified.receipts.len(), 1);
        assert_eq!(hdc.reads(), 1);

        // A cached route that no longer revalidates falls back to the wait.
        let hdc = Scripted::new(vec![
            Answer::Out(row("device-2")),
            Answer::Out(properties.into()),
        ]);
        let stale = identity("device-3", "42");
        let verified = RockchipHdcObserver::new(&hdc, &usb, &clock)
            .verify_bound_build(
                &expectation("42"),
                Some(&stale),
                "ohos",
                "OpenHarmony-7.0.0.37",
                &budget(10),
            )
            .unwrap();
        assert_eq!(verified.identity, identity("device-2", "42"));
        assert_eq!(hdc.reads(), 2);
    }

    #[test]
    fn the_hdc_normal_usb_observation_uses_the_exact_connect_key_digest() {
        let hdc = Scripted::new(Vec::new());
        let usb = UsbScript::default().digest("Device-1", "42");
        let clock = FakeClock::new();
        let observer = RockchipHdcObserver::new(&hdc, &usb, &clock);
        let observed = observer.observe_hdc_normal_usb("Device-1").unwrap();
        assert_eq!(observed.topology, "42");
        assert_eq!(
            hdc_normal_usb_summary(&observed),
            summary([
                ("hdcNormalIdentitySha256", &sha256_hex(b"Device-1")),
                ("usbState", "hdc-normal"),
                ("usbTopology", "42"),
            ])
        );
        assert_eq!(
            observer.observe_hdc_normal_usb("device-1").unwrap_err(),
            "DAYU200 target unavailable"
        );
        assert_eq!(hdc.reads(), 0);
    }

    #[test]
    fn the_properties_command_is_the_two_allowlisted_reads_joined() {
        assert_eq!(
            POST_FLASH_BUILD_PROPERTIES_COMMAND,
            format!(
                "param get {}; param get {}",
                Property::FullBuildVersion.key(),
                PRODUCT_MODEL_KEY
            )
        );
        assert_eq!(WaitBudget::DISCONNECT.deadline, Duration::from_secs(15));
        assert_eq!(WaitBudget::RECONNECT.deadline, Duration::from_secs(120));
        assert_eq!(
            WaitBudget::BOUND_RECONNECT.deadline,
            Duration::from_secs(600)
        );
        for budget in [
            WaitBudget::DISCONNECT,
            WaitBudget::RECONNECT,
            WaitBudget::BOUND_RECONNECT,
        ] {
            assert_eq!(budget.command_timeout, Duration::from_secs(15));
            assert_eq!(budget.poll, Duration::from_secs(1));
        }
    }
}
