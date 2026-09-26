//! Swift `ArkForgeControlPerformer` (`ArkForgeControlPerformer.swift`): the
//! semantic control actions `arkforged` asks for, performed with the HDC
//! actions ArkDeck kept.
//!
//! ArkForge names what it needs, such as "put this device in Loader". It never
//! receives a connect key, an endpoint, an argv or a server lifecycle; it gets
//! back only what was observed. Each action runs through the one Rockchip
//! action host (the dispatcher's `action_host`), under a descriptor
//! materialized for that action alone and a record step id unique to its
//! control attempt. A crash-and-repeat of the same attempt therefore replays
//! its records, and a fresh attempt asks the device again.
//!
//! `enterUpdater` is not one command. It is a command and the observations
//! that prove it, and the observation reports which of them were made. The
//! managed-control port refuses the receipt when one is missing; the
//! performer does not decide on its own that the device moved.
use crate::rockchip_action::{Expectation, RockchipAction};
use crate::rockchip_records::{ExecutionResult, RockchipActionHosting, described};
use arkdeck_contract::sha256_hex;
use arkdeck_provider_arkforge::LaneFailure;
use arkdeck_provider_arkforge::flash_session::ControlPerformer;
use arkdeck_provider_arkforge::managed_control::{
    ManagedControlAction, ManagedControlRequest, Observation,
};
use arkdeck_provider_hdc::LoaderObserver;
use std::collections::BTreeMap;
use std::sync::Arc;

/// Swift `ArkForgeControlPerformer.Binding`: what names the device the
/// actions act on. These are descriptor ingredients, not a descriptor. The
/// host validates each action against a descriptor that pins that action's
/// own identifier and digest, so each action gets its own.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ControlBinding {
    pub job_id: String,
    pub target_id: String,
    pub binding_revision: i64,
    pub connect_key: String,
    pub stable_identity_sha256: String,
    pub usb_topology: String,
    /// The measured `arkforged` every descriptor names.
    pub provider_executable_sha256: String,
}

/// Swift `ArkForgeControlPerformer`.
pub struct ArkForgeControlPerformer {
    binding: ControlBinding,
    host: Arc<dyn RockchipActionHosting>,
    loader: Box<dyn LoaderObserver + Send + Sync>,
}

impl ArkForgeControlPerformer {
    /// Swift `init(binding:host:loaderObserver:)`.
    pub fn new(
        binding: ControlBinding,
        host: Arc<dyn RockchipActionHosting>,
        loader: Box<dyn LoaderObserver + Send + Sync>,
    ) -> Self {
        Self {
            binding,
            host,
            loader,
        }
    }

    /// Swift `reconnectExpectation()`: the bound device's route in the HDC
    /// alias namespace, whose identity is the digest of the admitted connect
    /// key, not the Loader identity.
    fn reconnect_expectation(&self) -> Expectation {
        Expectation {
            previous_connect_key: self.binding.connect_key.clone(),
            previous_identity_sha256: sha256_hex(self.binding.connect_key.as_bytes()),
            usb_topology: self.binding.usb_topology.clone(),
        }
    }

    /// Swift `enterUpdater(request:)`. The board may already be at the
    /// requested postcondition; both independent read-only sources confirm
    /// that before HDC is touched. Otherwise the five actions run in order,
    /// and a failure is a failed observation, not an error. A mode change may
    /// have taken effect before the step that failed, and the daemon records
    /// the rest as unknown.
    fn enter_updater(&self, request: &ManagedControlRequest) -> Observation {
        if let Ok(identity) = self.loader.observe_loader(
            &self.binding.stable_identity_sha256,
            Some(&self.binding.usb_topology),
            &format!("{}-already-loader", request.request_id),
        ) {
            return Observation {
                accepted: true,
                facts: BTreeMap::from([
                    ("mode".to_owned(), "Loader".to_owned()),
                    (
                        "stableIdentitySHA256".to_owned(),
                        identity.serial_digest_sha256,
                    ),
                    ("usbTopology".to_owned(), identity.topology),
                ]),
                observed_disconnect: true,
                observed_unique_loader_rebind: true,
                ..Observation::default()
            };
        }
        let mut observed_disconnect = false;
        let (facts, observed_rebind, failure) =
            match self.loader_sequence(request, &mut observed_disconnect) {
                Ok(rebound) => (receipt_facts(&rebound), true, String::new()),
                Err(failure) => (BTreeMap::new(), false, described(&failure)),
            };
        Observation {
            accepted: observed_disconnect && observed_rebind,
            facts,
            evidence_sha256: Vec::new(),
            failure_reason: failure,
            observed_disconnect,
            observed_unique_loader_rebind: observed_rebind,
        }
    }

    /// The five actions of `enterUpdater`, as the port publishes them; the
    /// rebind's result on success.
    fn loader_sequence(
        &self,
        request: &ManagedControlRequest,
        observed_disconnect: &mut bool,
    ) -> Result<ExecutionResult, LaneFailure> {
        let key = &self.binding.connect_key;
        let identity = &self.binding.stable_identity_sha256;
        self.execute(
            &RockchipAction::ObserveHdcNormalUsb(key.clone()),
            request,
            0,
        )?;
        self.execute(&RockchipAction::EnterLoader(key.clone()), request, 1)?;
        self.execute(
            &RockchipAction::WaitForHdcDisconnect(key.clone()),
            request,
            2,
        )?;
        *observed_disconnect = true;
        self.execute(&RockchipAction::WaitForLoader(identity.clone()), request, 3)?;
        self.execute(&RockchipAction::RebindLoader(identity.clone()), request, 4)
    }

    /// Swift `run(_:request:index:)`: one action as an observation. A
    /// failure is not "nothing happened": the action may have taken effect
    /// before it was seen, which the daemon records as unknown.
    fn run(
        &self,
        action: RockchipAction,
        request: &ManagedControlRequest,
        index: usize,
    ) -> Observation {
        match self.execute(&action, request, index) {
            Ok(result) => Observation {
                accepted: true,
                facts: receipt_facts(&result),
                ..Observation::default()
            },
            Err(failure) => Observation {
                failure_reason: described(&failure),
                ..Observation::default()
            },
        }
    }

    /// Swift `execute(_:request:index:)`: a fresh descriptor for this action,
    /// through the same catalog materialization uses, and the host.
    fn execute(
        &self,
        action: &RockchipAction,
        request: &ManagedControlRequest,
        index: usize,
    ) -> Result<ExecutionResult, LaneFailure> {
        let binding = &self.binding;
        let descriptor = action.descriptor(
            &binding.job_id,
            &record_step_id(request, index),
            &binding.target_id,
            binding.binding_revision,
            &binding.connect_key,
            &binding.stable_identity_sha256,
            &binding.provider_executable_sha256,
        );
        self.host
            .execute(action, &descriptor, &binding.provider_executable_sha256)
    }
}

impl ControlPerformer for ArkForgeControlPerformer {
    /// Swift `perform(_:)`. A read's expectation comes from the daemon's
    /// request, never from here: one this side invented is one the device is
    /// guaranteed to meet. ArkForge's own action enum has no unknown case to
    /// refuse; an action this build does not know fails to decode upstream.
    fn perform(&mut self, request: &ManagedControlRequest) -> Result<Observation, String> {
        Ok(match request.action {
            ManagedControlAction::EnterUpdater => self.enter_updater(request),
            ManagedControlAction::RebootToNormal => self.run(
                RockchipAction::WaitForBoundHdcReconnect(self.reconnect_expectation()),
                request,
                0,
            ),
            ManagedControlAction::ReadProductFacts | ManagedControlAction::ReadBuildFacts => {
                // Swift's dictionary keeps the first value of a repeated key.
                let expected = |key: &str| {
                    request
                        .expected_facts
                        .iter()
                        .find(|fact| fact.key == key)
                        .map(|fact| fact.value.clone())
                        .unwrap_or_default()
                };
                self.run(
                    RockchipAction::VerifyBoundBuild {
                        expectation: self.reconnect_expectation(),
                        product_model: expected("const.product.model"),
                        build_version: expected("const.ohos.fullname"),
                    },
                    request,
                    0,
                )
            }
        })
    }
}

/// Swift `recordStepID(for:index:)`: the record store keys actions by
/// `job/step` and refuses a second, different intent under one key. The
/// daemon's request id is unique per control attempt, so its digest gives
/// every attempt fresh records, while a repeat of the same attempt replays.
/// It is digested, not embedded, so that the id stays a bounded path
/// component whatever the daemon put in it.
fn record_step_id(request: &ManagedControlRequest, index: usize) -> String {
    let attempt = sha256_hex(request.request_id.as_bytes());
    format!("{}-mc-{}-a{index}", request.step_id, &attempt[..12])
}

/// Swift `receiptFacts(from:)`: only the facts the published table declares,
/// selected rather than filtered, so that a key nobody reviewed cannot travel
/// by being added to the host's summary. The host's own spellings are mapped
/// onto the published keys: the Loader identity, the Loader mode it implies,
/// and the verification's `model` and `firmware`.
fn receipt_facts(result: &ExecutionResult) -> BTreeMap<String, String> {
    let summary = &result.summary;
    let mut facts: BTreeMap<String, String> = ["mode", "stableIdentitySHA256", "usbTopology"]
        .into_iter()
        .filter_map(|key| Some((key.to_owned(), summary.get(key)?.clone())))
        .collect();
    if let Some(identity) = summary.get("loaderIdentitySha256") {
        facts
            .entry("stableIdentitySHA256".to_owned())
            .or_insert_with(|| identity.clone());
        facts
            .entry("mode".to_owned())
            .or_insert_with(|| "Loader".to_owned());
    }
    if let Some(model) = summary.get("model") {
        facts.insert("const.product.model".to_owned(), model.clone());
    }
    if let Some(firmware) = summary.get("firmware") {
        facts.insert("const.ohos.fullname".to_owned(), firmware.clone());
    }
    facts
}

#[cfg(test)]
mod tests;
