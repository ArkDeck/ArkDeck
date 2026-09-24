//! Swift `ProductRockchipPostFlashAliasReconciler.reconcileReissuedAlias`
//! (`RockchipBootloaderStatus.swift`), the owner of `flash.reconcile-alias`:
//! the one repair of a post-flash alias whose revision counter was reissued
//! because the daemon state directory, and with it the Target store's
//! counter, was retired while the alias one level up in the Application
//! Support root was not.
//!
//! The caller's view of the Target is compared first (a compare-and-swap on
//! its binding revision), then exactly one registered DAYU200 must be attached
//! in its HDC-normal personality, read from the Runtime's own USB census,
//! and only then does the store (`PostFlashAliasStore::
//! reconcile_reissued_lineage`) archive the stored epoch and republish it at
//! the live revision, under its lock. Anything short of a complete agreement
//! writes nothing and refuses. Nothing here reaches a device: the census
//! reads the host's I/O Registry, never an HDC or RockUSB command.
use crate::post_flash_alias::{LiveTarget, ObservedHdc};
use crate::post_flash_alias_store::PostFlashAliasStore;
use crate::strict_json::swift_quoted;
use crate::target_owner::TargetStore;
use arkdeck_contract::{WireError, sha256_hex};
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use arkdeck_provider_hdc::{is_dayu200_loader, registered_dayu200_devices};
use serde_json::{Value, json};
use std::path::Path;

/// The host's USB devices, as the Runtime's census reads them.
pub type UsbCensus = dyn Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable> + Send + Sync;

const STALE: &str = "selected target or binding revision is stale";
const ONE_HDC_NORMAL: &str =
    "exactly one registered DAYU200 in hdc-normal mode is required to reconcile its alias";
const NOT_REISSUED: &str = "the stored post-flash alias is not a reissued lineage of the \
                            attached device; its target, Loader identity, HDC identity, connect \
                            key and USB topology must all match fresh facts and its revision \
                            must be ahead of the live target";

/// The owner, over the post-flash alias store of one Application Support
/// root, the census it reads the attached board from and the clock that
/// stamps a republished alias.
pub struct FlashAliasReconciler {
    store: PostFlashAliasStore,
    census: Box<UsbCensus>,
    now: Box<dyn Fn() -> String + Send + Sync>,
}

impl FlashAliasReconciler {
    /// Swift `init(targetStore:applicationSupportRoot:nowUTC:)`: nothing is
    /// touched until a call. The Target store is the daemon's, handed to each
    /// call; `now` spells UTC seconds as Swift's `ISO8601DateFormatter`
    /// (`.withInternetDateTime`) does.
    pub fn new(
        application_support_root: &Path,
        census: impl Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable> + Send + Sync + 'static,
        now: impl Fn() -> String + Send + Sync + 'static,
    ) -> Self {
        Self {
            store: PostFlashAliasStore::new(application_support_root),
            census: Box::new(census),
            now: Box::new(now),
        }
    }

    /// Swift `reconcileReissuedAlias(targetID:expectedBindingRevision:)`,
    /// answered as the daemon answers it: the receipt, or `rejected` with the
    /// error Swift interpolates.
    pub fn reconcile(
        &self,
        targets: &TargetStore,
        target_id: &str,
        expected_binding_revision: i64,
    ) -> Result<Value, WireError> {
        self.receipt(targets, target_id, expected_binding_revision)
            .map_err(|error| WireError {
                code: "rejected".into(),
                message: format!("post-flash alias reconciliation was refused: {error}"),
                details: None,
            })
    }

    fn receipt(
        &self,
        targets: &TargetStore,
        target_id: &str,
        expected: i64,
    ) -> Result<Value, String> {
        let stale = || admission(STALE);
        if target_id.is_empty() || expected <= 0 {
            return Err(stale());
        }
        // Swift `RuntimeTargetStore.find(targetID:)`: the first record with
        // this identity, aliases included. A store it cannot read is Swift's
        // `storeFailure`, whose inner description is Foundation's own.
        let records = targets.records().map_err(|error| {
            format!(
                "storeFailure({})",
                swift_quoted(&format!("undecodable target store: {}", error.message))
            )
        })?;
        let record = records
            .iter()
            .find(|record| record["targetID"] == target_id)
            .ok_or_else(stale)?;
        let (Some(identity), Some(revision)) = (
            record["stablePhysicalIdentitySHA256"].as_str(),
            record["bindingRevision"].as_i64(),
        ) else {
            return Err(stale());
        };
        if revision != expected {
            return Err(stale());
        }
        // The board has to be here, in its HDC-normal personality, and be the
        // only registered DAYU200 attached.
        let devices = (self.census)().map_err(|_| admission("USB registry unavailable"))?;
        let registered = registered_dayu200_devices(devices);
        let [device] = registered.as_slice() else {
            return Err(admission(ONE_HDC_NORMAL));
        };
        if is_dayu200_loader(device) {
            return Err(admission(ONE_HDC_NORMAL));
        }
        let observed_identity = sha256_hex(device.serial.as_bytes());
        let outcome = self
            .store
            .reconcile_reissued_lineage(
                &LiveTarget {
                    target_id,
                    stable_identity_sha256: identity,
                    binding_revision: revision,
                },
                &ObservedHdc {
                    identity_sha256: &observed_identity,
                    connect_key: &device.serial,
                    usb_topology: &device.topology,
                },
                &(self.now)(),
            )
            .map_err(|error| {
                format!(
                    "productionConfigurationUnavailable({})",
                    swift_quoted(error.detail())
                )
            })?
            .ok_or_else(|| admission(NOT_REISSUED))?;
        Ok(json!({
            "targetId": outcome.target_id,
            "reconciled": true,
            "archivedBindingRevision": outcome.archived_revision,
            "bindingRevision": outcome.published_revision,
            "hdcIdentitySha256": outcome.hdc_identity_sha256,
        }))
    }
}

/// Swift `RockchipFlashExecutionError.admissionRejected(detail)` as the
/// daemon interpolates it.
fn admission(detail: &str) -> String {
    format!("admissionRejected({})", swift_quoted(detail))
}
