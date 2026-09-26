//! Swift `FoundationRockchipRuntimeActionExecutor`
//! (`RockchipRuntimeActionHost.swift`): what performs each typed Rockchip
//! action once the durable host has made its intent durable. That covers the
//! Loader transition and the waits around it, the bound reconnect and the
//! exact build readback after a flash, and the post-flash HiLog capture, over
//! the descriptor-bound HDC, the Runtime's USB census and ArkForge's Loader
//! observation.
//!
//! The arms themselves are `arkdeck-provider-hdc`'s
//! (`RockchipLoaderTransition`, `RockchipHdcObserver`). What is the
//! executor's own lives here:
//!
//! - the descriptor-bound HDC, resolved for each action;
//! - the short-lived reuse of one exact Loader observation across the actions
//!   of one managed-control attempt, and of one bound HDC route between the
//!   bound reconnect and the build readback;
//! - the publication of the post-flash alias;
//! - each arm's receipt summary;
//! - the retired direct reset.
use crate::flash_facts::post_flash;
use crate::post_flash_alias::{PostFlashBinding, SCHEMA_VERSION};
use crate::post_flash_alias_store::PostFlashAliasStore;
use crate::rockchip_action::{Expectation, RockchipAction};
use crate::rockchip_records::{ExecutionResult, RockchipActionExecutor};
use crate::session_graphemes::graphemes;
use arkdeck_provider_arkforge::{HostAction, LaneFailure};
use arkdeck_provider_hdc::{
    Clock, DispatchFailure, HdcDispatch, HdcIdentity, LoaderIdentity, LoaderObserver,
    LoaderTransitionFailure, ProcessPlan, ReadbackBudget, Receipt, ReconnectExpectation,
    RockchipHdcFailure, RockchipHdcObserver, RockchipLoaderTransition, TransitionRequest, UsbProbe,
    WaitBudget, bound_reconnect_summary, hdc_normal_usb_summary, hdc_state_summary, loader_summary,
};
use std::cell::OnceCell;
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Swift `RuntimeExecutableResolving.resolveExecutable(providerID: "hdc")`:
/// the descriptor-bound HDC, or the error as Swift interpolates it.
pub type HdcResolver = dyn Fn() -> Result<Arc<dyn HdcDispatch + Send + Sync>, String> + Send + Sync;

/// Swift `RockchipRuntimeObservationReuseCache.maximumAgeNanoseconds`.
const REUSE_MAXIMUM_AGE: Duration = Duration::from_secs(120);

/// Swift `FoundationRockchipRuntimeActionExecutor`.
pub struct RockchipExecutor {
    hdc: Box<HdcResolver>,
    usb: Box<dyn UsbProbe + Send + Sync>,
    loader: Box<dyn LoaderObserver + Send + Sync>,
    clock: Box<dyn Clock + Send + Sync>,
    aliases: Option<PostFlashAliasStore>,
    now_utc: Box<dyn Fn() -> String + Send + Sync>,
    enter_loader_readback: ReadbackBudget,
    reuse: Mutex<ReuseCache>,
}

impl RockchipExecutor {
    /// Swift `init(hdcResolver:runner:usbProbe:loaderObserver:…)` with its
    /// defaults: the 45-second Loader readback after the transition command,
    /// no post-flash alias store (so a build verification refuses), and the
    /// current instant as durable records spell it.
    pub fn new(
        hdc: Box<HdcResolver>,
        usb: Box<dyn UsbProbe + Send + Sync>,
        loader: Box<dyn LoaderObserver + Send + Sync>,
        clock: Box<dyn Clock + Send + Sync>,
    ) -> Self {
        Self {
            hdc,
            usb,
            loader,
            clock,
            aliases: None,
            now_utc: Box::new(|| crate::format_time::utc_now().unwrap_or_default()),
            enter_loader_readback: ReadbackBudget::DEFAULT,
            reuse: Mutex::new(ReuseCache::default()),
        }
    }

    /// Swift `postFlashHDCBindingStore`: where a verified build publishes
    /// the post-flash alias, and the clock of its `establishedAtUTC`.
    pub fn with_post_flash_aliases(
        mut self,
        store: PostFlashAliasStore,
        now_utc: impl Fn() -> String + Send + Sync + 'static,
    ) -> Self {
        self.aliases = Some(store);
        self.now_utc = Box::new(now_utc);
        self
    }

    /// Swift `enterLoaderReadbackTimeoutSeconds`.
    pub fn with_enter_loader_readback(mut self, budget: ReadbackBudget) -> Self {
        self.enter_loader_readback = budget;
        self
    }

    /// Swift `rememberLoaderObservation(_:descriptor:actionIndex:)`.
    fn remember_loader(&self, descriptor: &HostAction, index: usize, identity: &LoaderIdentity) {
        if let Some(key) = loader_reuse_key(descriptor, index)
            && let Ok(mut reuse) = self.reuse.lock()
        {
            let now = self.clock.now();
            reuse.purge(now);
            reuse.loaders.insert(key, (identity.clone(), now));
        }
    }

    /// Swift `reusedLoaderObservation(descriptor:actionIndex:consume:)`.
    fn reused_loader(
        &self,
        descriptor: &HostAction,
        index: usize,
        consume: bool,
    ) -> Option<LoaderIdentity> {
        let key = loader_reuse_key(descriptor, index)?;
        let mut reuse = self.reuse.lock().ok()?;
        reuse.purge(self.clock.now());
        if consume {
            reuse.loaders.remove(&key).map(|(identity, _)| identity)
        } else {
            reuse
                .loaders
                .get(&key)
                .map(|(identity, _)| identity.clone())
        }
    }

    /// Swift `rememberBoundHDC(_:for:)`.
    fn remember_bound(&self, key: BoundHdcKey, identity: &HdcIdentity) {
        if let Ok(mut reuse) = self.reuse.lock() {
            let now = self.clock.now();
            reuse.purge(now);
            reuse.bound.insert(key, (identity.clone(), now));
        }
    }

    /// Swift `takeBoundHDC(for:)`: a cached route is used at most once.
    fn take_bound(&self, key: &BoundHdcKey) -> Option<HdcIdentity> {
        let mut reuse = self.reuse.lock().ok()?;
        reuse.purge(self.clock.now());
        reuse.bound.remove(key).map(|(identity, _)| identity)
    }
}

impl RockchipActionExecutor for RockchipExecutor {
    /// Swift `unavailableReason()`.
    fn unavailable_reason(&self) -> Option<String> {
        (self.hdc)().err().map(|error| {
            format!("descriptor-bound HDC executable is unavailable to the Rockchip host: {error}")
        })
    }

    /// Swift `execute(action:descriptor:providerExecutable:actionDirectory:)`.
    fn execute(
        &self,
        action: &RockchipAction,
        descriptor: &HostAction,
        _action_directory: &Path,
    ) -> Result<ExecutionResult, LaneFailure> {
        let hdc = ResolvedHdc {
            resolver: &*self.hdc,
            resolved: OnceCell::new(),
        };
        let transition =
            RockchipLoaderTransition::new(&hdc, &*self.usb, &*self.loader, &*self.clock);
        let observer = RockchipHdcObserver::new(&hdc, &*self.usb, &*self.clock);
        let request_id =
            |suffix: &str| format!("{}-{}-{suffix}", descriptor.job_id, descriptor.step_id);
        match action {
            RockchipAction::EnterLoader(connect_key) => {
                let proven = transition
                    .enter_loader(
                        &TransitionRequest {
                            connect_key,
                            stable_identity_sha256: &descriptor.expected_identity_sha256,
                            job_id: &descriptor.job_id,
                            step_id: &descriptor.step_id,
                        },
                        &self.enter_loader_readback,
                    )
                    .map_err(transition_failure)?;
                self.remember_loader(descriptor, 1, &proven.loader);
                Ok(result(proven.summary(), proven.receipts))
            }
            // The probe's own refusal, not a dispatch failure, as Swift
            // rethrows it.
            RockchipAction::ObserveHdcNormalUsb(connect_key) => {
                let identity = observer
                    .observe_hdc_normal_usb(connect_key)
                    .map_err(LaneFailure::Other)?;
                Ok(result(hdc_normal_usb_summary(&identity), Vec::new()))
            }
            RockchipAction::WaitForHdcDisconnect(connect_key) => {
                if let Some(loader) = self.reused_loader(descriptor, 2, false) {
                    return Ok(result(
                        summary([
                            ("hdcState", "disconnected"),
                            ("transitionEvidence", "exact-bound-loader-readback"),
                            ("loaderIdentitySha256", &loader.serial_digest_sha256),
                            ("usbTopology", &loader.topology),
                        ]),
                        Vec::new(),
                    ));
                }
                let receipts = observer
                    .wait_for_hdc(connect_key, false, &WaitBudget::DISCONNECT)
                    .map_err(hdc_failure)?;
                Ok(result(hdc_state_summary(false), receipts))
            }
            RockchipAction::WaitForLoader(identity) => {
                if let Some(loader) = self
                    .reused_loader(descriptor, 3, false)
                    .filter(|loader| loader.serial_digest_sha256 == *identity)
                {
                    let mut reused = loader_summary(&loader);
                    reused.insert(
                        "observationReuse".into(),
                        "enter-loader-postcondition".into(),
                    );
                    return Ok(result(reused, Vec::new()));
                }
                let loader = transition
                    .wait_for_loader(
                        identity,
                        &request_id("wait-loader"),
                        &ReadbackBudget::DEFAULT,
                    )
                    .map_err(transition_failure)?;
                self.remember_loader(descriptor, 3, &loader);
                Ok(result(loader_summary(&loader), Vec::new()))
            }
            // The one arm that consumes the reused observation: it is the
            // attempt's last.
            RockchipAction::RebindLoader(identity) => {
                let reused = self
                    .reused_loader(descriptor, 4, true)
                    .filter(|loader| loader.serial_digest_sha256 == *identity);
                let loader = match &reused {
                    Some(loader) => loader.clone(),
                    None => transition
                        .rebind_loader(identity, &request_id("rebind-loader"))
                        .map_err(transition_failure)?,
                };
                let mut rebound = loader_summary(&loader);
                rebound.insert(
                    "bindingRevision".into(),
                    descriptor.binding_revision.to_string(),
                );
                if reused.is_some() {
                    rebound.insert(
                        "observationReuse".into(),
                        "exact-bound-loader-readback".into(),
                    );
                }
                Ok(result(rebound, Vec::new()))
            }
            // Native ArkForge owns the write, the verification and the reset
            // as one delegated plan. This action stays decodable for old
            // journals, but never runs.
            RockchipAction::RebootToNormal(_) => Err(LaneFailure::Failed(
                "legacy direct Rockchip reset is retired; native ArkForge owns device reset".into(),
            )),
            RockchipAction::WaitForHdcReconnect(connect_key) => {
                let receipts = observer
                    .wait_for_hdc(connect_key, true, &WaitBudget::RECONNECT)
                    .map_err(hdc_failure)?;
                Ok(result(hdc_state_summary(true), receipts))
            }
            RockchipAction::WaitForBoundHdcReconnect(expectation) => {
                let expectation = reconnect_expectation(expectation);
                let (identity, receipts) = observer
                    .wait_for_bound_hdc(&expectation, &WaitBudget::BOUND_RECONNECT)
                    .map_err(hdc_failure)?;
                self.remember_bound(bound_key(descriptor, &expectation), &identity);
                Ok(result(bound_reconnect_summary(&identity), receipts))
            }
            RockchipAction::VerifyBoundBuild {
                expectation,
                product_model,
                build_version,
            } => {
                let Some(aliases) = self
                    .aliases
                    .as_ref()
                    .filter(|_| !product_model.is_empty() && !build_version.is_empty())
                else {
                    return Err(LaneFailure::Failed(
                        "post-flash binding verification is not fully configured".into(),
                    ));
                };
                let expectation = reconnect_expectation(expectation);
                let cached = self.take_bound(&bound_key(descriptor, &expectation));
                let verified = observer
                    .verify_bound_build(
                        &expectation,
                        cached.as_ref(),
                        product_model,
                        build_version,
                        &WaitBudget::BOUND_RECONNECT,
                    )
                    .map_err(hdc_failure)?;
                let binding = PostFlashBinding {
                    schema_version: SCHEMA_VERSION.to_owned(),
                    target_id: descriptor.target_id.clone(),
                    binding_revision: descriptor.binding_revision,
                    stable_loader_identity_sha256: descriptor.expected_identity_sha256.clone(),
                    previous_hdc_identity_sha256: expectation.previous_identity_sha256.clone(),
                    hdc_identity_sha256: verified.identity.serial_digest_sha256.clone(),
                    hdc_connect_key: verified.identity.connect_key.clone(),
                    usb_topology: verified.identity.topology.clone(),
                    product_model: verified.readback.product_model.clone(),
                    build_version: verified.readback.build_version.clone(),
                    job_id: descriptor.job_id.clone(),
                    established_at_utc: (self.now_utc)(),
                };
                aliases
                    .publish(&binding, &expectation.previous_identity_sha256)
                    .map_err(|error| {
                        LaneFailure::Failed(format!(
                            "verified post-flash HDC binding could not be persisted: {}",
                            post_flash(error)
                        ))
                    })?;
                Ok(result(verified.summary(), verified.receipts))
            }
            RockchipAction::CapturePostFlashDiagnostics {
                connect_key,
                request,
            } => {
                let receipt = observer
                    .capture_post_flash_hilog(
                        connect_key,
                        &request.filters,
                        Duration::from_secs(u64::try_from(request.duration_seconds).unwrap_or(0)),
                        usize::try_from(request.byte_budget).unwrap_or(0),
                    )
                    .map_err(hdc_failure)?;
                Ok(ExecutionResult {
                    summary: summary([
                        ("byteCount", &receipt.stdout.len().to_string()),
                        ("debugRuntime", "ready"),
                        ("verification", "full"),
                    ]),
                    stdout: receipt.stdout,
                    stderr: receipt.stderr,
                    stdout_truncated: receipt.truncated,
                    subprocess_count: 1,
                })
            }
        }
    }
}

/// The descriptor-bound HDC of one action: Swift's `resolveHDC()`, resolved
/// at the action's first command and kept for the rest of the action. Every
/// spawn still checks the executable's identity, as Swift's identity-bound
/// runner does. A resolution that fails refuses before anything runs, in
/// Swift's words.
struct ResolvedHdc<'a> {
    resolver: &'a HdcResolver,
    resolved: OnceCell<Result<Arc<dyn HdcDispatch + Send + Sync>, String>>,
}

impl ResolvedHdc<'_> {
    fn resolved(&self) -> &Result<Arc<dyn HdcDispatch + Send + Sync>, String> {
        self.resolved.get_or_init(|| (self.resolver)())
    }
}

impl HdcDispatch for ResolvedHdc<'_> {
    fn mutation_identity_current(&self) -> bool {
        self.resolved()
            .as_ref()
            .is_ok_and(|hdc| hdc.mutation_identity_current())
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        match self.resolved() {
            Ok(hdc) => hdc.dispatch(plan),
            Err(error) => Err(DispatchFailure::Refused(format!(
                "descriptor-bound HDC executable is unavailable: {error}"
            ))),
        }
    }
}

/// Swift `RockchipRuntimeObservationReuseCache.LoaderKey`: one
/// managed-control attempt of one Job, Target, revision and identity.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct LoaderKey {
    job_id: String,
    target_id: String,
    binding_revision: i64,
    stable_identity_sha256: String,
    control_attempt: String,
}

/// Swift `RockchipRuntimeObservationReuseCache.BoundHDCKey`.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct BoundHdcKey {
    job_id: String,
    target_id: String,
    binding_revision: i64,
    stable_identity_sha256: String,
    previous_identity_sha256: String,
    usb_topology: String,
}

/// Swift `RockchipRuntimeObservationReuseCache`: observations shared only
/// between adjacent receipts of one sequence, for 120 s. The record store
/// still records every action separately; this only keeps them from asking
/// the device the same question again once a stronger postcondition has
/// answered it.
#[derive(Default)]
struct ReuseCache {
    loaders: BTreeMap<LoaderKey, (LoaderIdentity, Instant)>,
    bound: BTreeMap<BoundHdcKey, (HdcIdentity, Instant)>,
}

impl ReuseCache {
    /// Swift `purgeExpired()`.
    fn purge(&mut self, now: Instant) {
        let fresh = |recorded: &Instant| {
            now.checked_duration_since(*recorded)
                .is_some_and(|age| age <= REUSE_MAXIMUM_AGE)
        };
        self.loaders.retain(|_, (_, recorded)| fresh(recorded));
        self.bound.retain(|_, (_, recorded)| fresh(recorded));
    }
}

/// Swift `loaderReuseKey(descriptor:actionIndex:)`: only the step id shape
/// the control performer emits, `<step>-mc-<12 lowercase hexadecimal
/// Characters>-a<index>`, so that a similarly named plan action or a later
/// control request cannot inherit an observation because its Job and Target
/// happen to match.
fn loader_reuse_key(descriptor: &HostAction, index: usize) -> Option<LoaderKey> {
    let control_attempt = descriptor.step_id.strip_suffix(&format!("-a{index}"))?;
    let marker = control_attempt.rfind("-mc-")?;
    let step = &control_attempt[..marker];
    let digest = &control_attempt[marker + "-mc-".len()..];
    (!step.is_empty() && swift_lowercase_hex(digest, 12)).then(|| LoaderKey {
        job_id: descriptor.job_id.clone(),
        target_id: descriptor.target_id.clone(),
        binding_revision: descriptor.binding_revision,
        stable_identity_sha256: descriptor.expected_identity_sha256.clone(),
        control_attempt: control_attempt.to_owned(),
    })
}

/// Swift `boundHDCReuseKey(descriptor:expectation:)`.
fn bound_key(descriptor: &HostAction, expectation: &ReconnectExpectation) -> BoundHdcKey {
    BoundHdcKey {
        job_id: descriptor.job_id.clone(),
        target_id: descriptor.target_id.clone(),
        binding_revision: descriptor.binding_revision,
        stable_identity_sha256: descriptor.expected_identity_sha256.clone(),
        previous_identity_sha256: expectation.previous_identity_sha256.clone(),
        usb_topology: expectation.usb_topology.clone(),
    }
}

/// `count` Characters, each a hexadecimal digit that is not uppercase, as
/// Swift's `Character.isHexDigit && !isUppercase` admits them, fullwidth
/// digits included.
fn swift_lowercase_hex(value: &str, count: usize) -> bool {
    let characters: Vec<&str> = graphemes(value).collect();
    characters.len() == count
        && characters.iter().all(|character| {
            let mut scalars = character.chars();
            matches!(
                (scalars.next(), scalars.next()),
                (
                    Some('0'..='9' | 'a'..='f' | '\u{FF10}'..='\u{FF19}' | '\u{FF41}'..='\u{FF46}'),
                    None,
                )
            )
        })
}

fn reconnect_expectation(expectation: &Expectation) -> ReconnectExpectation {
    ReconnectExpectation {
        previous_connect_key: expectation.previous_connect_key.clone(),
        previous_identity_sha256: expectation.previous_identity_sha256.clone(),
        usb_topology: expectation.usb_topology.clone(),
    }
}

/// Swift `result(summary:receipts:)`: the receipts' streams in order,
/// truncated when any was.
fn result(summary: BTreeMap<String, String>, receipts: Vec<Receipt>) -> ExecutionResult {
    ExecutionResult {
        summary,
        stdout: receipts
            .iter()
            .flat_map(|receipt| receipt.stdout.clone())
            .collect(),
        stderr: receipts
            .iter()
            .flat_map(|receipt| receipt.stderr.clone())
            .collect(),
        stdout_truncated: receipts.iter().any(|receipt| receipt.truncated),
        subprocess_count: receipts.len(),
    }
}

fn summary<const N: usize>(pairs: [(&str, &str); N]) -> BTreeMap<String, String> {
    pairs
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value.to_owned()))
        .collect()
}

/// Swift `RuntimeDispatchFailure` as the Loader arms raise it. The
/// diagnostic keeps Swift's raw value.
fn transition_failure(failure: LoaderTransitionFailure) -> LaneFailure {
    match failure {
        LoaderTransitionFailure::Failed(detail) => LaneFailure::Failed(detail),
        LoaderTransitionFailure::OutcomeUnknown(detail) => LaneFailure::OutcomeUnknown(detail),
        LoaderTransitionFailure::ConfirmedNotExecuted { detail, diagnostic } => {
            LaneFailure::ConfirmedNotExecutedWithDiagnostic {
                reason: detail,
                diagnostic: diagnostic.as_str().to_owned(),
            }
        }
    }
}

/// Swift `RuntimeDispatchFailure` as the HDC arms raise it.
fn hdc_failure(failure: RockchipHdcFailure) -> LaneFailure {
    match failure {
        RockchipHdcFailure::Failed(detail) => LaneFailure::Failed(detail),
        RockchipHdcFailure::OutcomeUnknown(detail) => LaneFailure::OutcomeUnknown(detail),
    }
}

#[cfg(test)]
mod tests;
