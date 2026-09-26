//! Swift `ArkForgeNativeRockchipControlDispatcher`
//! (`RockchipRuntimeComposition.swift`): the one route by which the Runtime
//! dispatches a host-managed Rockchip action. It is installed even while
//! unavailable, so that the Flash operations name their concrete blocker. It
//! never falls back to another tool, another dispatcher or another host.
//!
//! The configured `arkforged` is measured again at every dispatch, and must
//! still be the executable the plan's descriptor was materialized against.
//! The action then runs through the one Rockchip action host, which is shared
//! with the ArkForge lane's managed control, so that the device has exactly
//! one HDC owner on this side. The receipt names the host's durable record.
use crate::flash_facts::NativeRockUsbIdentity;
use crate::rockchip_action::RockchipAction;
use crate::rockchip_records::{
    DurableRockchipHost, RefusingRockchipHost, RockchipActionExecutor, RockchipActionHosting,
    RockchipRecordStore,
};
use arkdeck_provider_arkforge::{HostAction, HostReceipt, LaneFailure, RockchipHost};
use serde_json::Value;
use std::path::Path;
use std::sync::Arc;

/// Swift's refusal of a dispatcher composed without a descriptor-bound HDC
/// or a product state directory.
const REFUSING_REASON: &str =
    "the per-action RockUSB host requires descriptor-bound HDC and a product state directory";

/// Swift `ArkForgeNativeRockchipControlDispatcher`.
pub struct NativeRockchipDispatcher {
    identity: NativeRockUsbIdentity,
    host: Arc<dyn RockchipActionHosting>,
}

impl NativeRockchipDispatcher {
    /// Swift `init(resolver:unavailableDetail:)`: every action refused. The
    /// detail extends the refusal, and does not replace it, when the concrete
    /// missing piece is known.
    pub fn refusing(identity: NativeRockUsbIdentity, unavailable_detail: Option<&str>) -> Self {
        let reason = std::iter::once(REFUSING_REASON)
            .chain(unavailable_detail)
            .collect::<Vec<_>>()
            .join(": ");
        Self::new(identity, Arc::new(RefusingRockchipHost(reason)))
    }

    /// Swift `init(resolver:hdcResolver:stateDirectory:…)`: the durable host
    /// over `executor`, with its records under `<state>/rockchip-runtime`.
    pub fn durable(
        identity: NativeRockUsbIdentity,
        executor: impl RockchipActionExecutor + 'static,
        state_directory: &Path,
    ) -> Self {
        let records = RockchipRecordStore::new(&state_directory.join("rockchip-runtime"));
        Self::new(
            identity,
            Arc::new(DurableRockchipHost::new(executor, records)),
        )
    }

    /// Swift `init(resolver:host:)`.
    pub fn new(identity: NativeRockUsbIdentity, host: Arc<dyn RockchipActionHosting>) -> Self {
        Self { identity, host }
    }

    /// Swift `actionHost`: the same host this dispatcher runs actions
    /// through, for the ArkForge lane to perform managed control on. A second
    /// host would be a second HDC owner.
    pub fn action_host(&self) -> Arc<dyn RockchipActionHosting> {
        Arc::clone(&self.host)
    }

    /// Swift `unavailableReason(providerID:)` for the ArkForge provider: the
    /// configured `arkforged`'s identity first, then the host's reason.
    pub fn unavailable_reason(&self) -> Option<String> {
        if let Err(error) = self.identity.resolve() {
            return Some(format!(
                "ArkForge native RockUSB identity is unavailable: {error}"
            ));
        }
        self.host.unavailable_reason()
    }
}

impl RockchipHost for NativeRockchipDispatcher {
    /// Swift `dispatch(_:progress:)`.
    fn dispatch(&self, action: &HostAction) -> Result<HostReceipt, LaneFailure> {
        let typed = typed_action(action)?;
        if let Some(reason) = self.unavailable_reason() {
            return Err(LaneFailure::Failed(reason));
        }
        let executable = self.identity.resolve().map_err(|error| {
            LaneFailure::Failed(format!(
                "ArkForge native RockUSB identity is unavailable: {error}"
            ))
        })?;
        if action.provider_executable_sha256 != executable {
            return Err(LaneFailure::Failed(
                "ArkForge native RockUSB identity changed after availability materialization"
                    .into(),
            ));
        }
        let result = self.host.execute(&typed, action, &executable)?;
        let Some(record_id) = result
            .summary
            .get("recordID")
            .filter(|record| !record.is_empty())
            .cloned()
        else {
            return Err(LaneFailure::OutcomeUnknown(
                "Rockchip host returned no durable job/step receipt".into(),
            ));
        };
        Ok(HostReceipt {
            exit_status: Some(0),
            stdout: result.stdout,
            stderr: result.stderr,
            stdout_truncated: result.stdout_truncated,
            // The sum of the subprocesses' durations, which Swift's Rockchip
            // runner always reports as 0.
            duration_seconds: 0.0,
            record_id: Some(record_id),
            summary: result.summary,
        })
    }
}

/// Swift's typed plan carries the Rockchip action itself. The lane's host
/// action carries its persisted form, which decodes back as Swift
/// `materialize()` decodes it; anything that is not a Rockchip action is
/// refused with Swift's words.
fn typed_action(action: &HostAction) -> Result<RockchipAction, LaneFailure> {
    let persisted = serde_json::from_str::<Value>(&action.action)
        .ok()
        .filter(|persisted| {
            persisted
                .get("kind")
                .and_then(Value::as_str)
                .is_some_and(|kind| kind.starts_with("rockchip."))
        })
        .ok_or_else(|| {
            LaneFailure::Failed(
                "ArkForge native RockUSB dispatcher received a non-Rockchip action".into(),
            )
        })?;
    RockchipAction::from_persisted(&persisted).map_err(LaneFailure::Failed)
}

#[cfg(test)]
mod tests;
