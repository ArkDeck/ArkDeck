//! Swift `ProductRockchipLoaderBindingCoordinator.bindCurrentLoader`
//! (`RockchipBootloaderStatus.swift`), the owner of
//! `flash.bind-current-loader`: the caller names only an adopted Target and
//! the revision it saw; every identity and port is read afresh from the
//! Runtime's USB census and, for a Loader, confirmed by ArkForge's own
//! enumeration; the manual USB rebind policy is applied; and then exactly one
//! of the owner's writes happens:
//!
//! - an adopted revision-1 Target of another board takes the singleton
//!   binding over (`activate_selected_initial_target`);
//! - an advanced Target displaced from it is reactivated, only with the
//!   Runtime's own records proving its retained HDC route
//!   (`activate_selected_target`);
//! - or the Target's binding moves along its HDC-to-Loader lineage
//!   (`replace`), and the Target advances to the published edge.
//!
//! A retry of any of these answers the committed edge without writing. Every
//! refusal is Swift's error as its daemon interpolates it. Nothing here
//! reaches a device: the census reads the host's I/O Registry, and ArkForge's
//! half is a read of its public socket.
use crate::job_owner::JobStore;
use crate::rockchip_binding::{
    BindingEvidence, BindingSnapshot, BoundTarget, RockchipBindingStore, canonical_sha256,
};
use crate::rockchip_reactivation::ReactivationProofSource;
use crate::strict_json::swift_quoted;
use crate::target_owner::TargetStore;
use arkdeck_contract::{WireError, sha256_hex};
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use arkdeck_provider_hdc::{LoaderObserver, is_dayu200_loader, registered_dayu200_devices};
use serde_json::{Value, json};
use std::path::Path;

/// Swift `hdcNormalReadbackEvidence`: the readback of a board seen in its
/// hdc-normal personality.
const HDC_NORMAL_READBACK: &str = "product:e0-iokit-single-dayu200-readback";
/// The readback of a board seen in its Loader personality.
const LOADER_READBACK: &str = "product:e0-iokit-single-loader-readback";
/// Swift `"usb:vendor=\(RockchipProbeEvidence.rockUSBVendorID),…"`: the
/// RockUSB vendor `0x2207`, which Swift interpolates as a decimal `UInt16`.
const CROSS_MODE_USB: &str = "usb:vendor=8711,profile=dayu200-cross-mode";

/// The owner over one Application Support root: its binding, the Runtime's
/// records below it, the census and ArkForge's Loader observation.
pub struct LoaderBinding {
    store: RockchipBindingStore,
    census: Box<crate::flash_alias_reconcile::UsbCensus>,
    observer: Box<dyn LoaderObserver + Send + Sync>,
    proofs: ReactivationProofSource,
}

/// Swift `RockchipLoaderBindingReceipt`.
struct Receipt {
    previous: i64,
    current: i64,
    updated: bool,
    selection: String,
}

/// One durable Target record, as the coordinator compares it.
#[derive(Clone)]
struct Target {
    id: String,
    identity: String,
    revision: i64,
    connect_key: String,
}

impl Target {
    fn bound(&self) -> BoundTarget<'_> {
        BoundTarget {
            target_id: &self.id,
            identity_sha256: &self.identity,
            binding_revision: self.revision,
            connect_key: &self.connect_key,
        }
    }
}

fn admission(detail: &str) -> String {
    format!("admissionRejected({})", swift_quoted(detail))
}

fn configuration(detail: &str) -> String {
    format!(
        "productionConfigurationUnavailable({})",
        swift_quoted(detail)
    )
}

fn swift(error: crate::rockchip_binding::BindingError) -> String {
    error.swift()
}

/// Swift `selectionDigest`: the Runtime's record of what was selected.
fn selection_digest(
    target_id: &str,
    previous_revision: i64,
    current_revision: i64,
    previous_identity: &str,
    current_identity: &str,
    current_topology: &str,
) -> String {
    sha256_hex(
        [
            "rockchip-loader-user-selection",
            target_id,
            &previous_revision.to_string(),
            &current_revision.to_string(),
            previous_identity,
            current_identity,
            current_topology,
        ]
        .join("\n")
        .as_bytes(),
    )
}

/// Swift `authorizeSelectedTarget`: Core's manual USB rebind policy over the
/// one fresh candidate, confirmed by the user's selection. For this one
/// candidate, disconnected, explicitly added and in its expected mode
/// transition, the only refusal is a candidate without a USB port to name.
fn authorize(identity: &UsbHostDevice) -> Result<(), String> {
    if identity.topology.is_empty() {
        return Err("emptyField(\"candidateID/connectKey\")".into());
    }
    Ok(())
}

impl LoaderBinding {
    /// Swift `init(targetStore:applicationSupportRoot:)`, with the census and
    /// the observation the daemon composes: nothing is touched until a call.
    /// The records are the root's `Agentd/rockchip-runtime`.
    pub fn new(
        application_support_root: &Path,
        census: impl Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable> + Send + Sync + 'static,
        observer: impl LoaderObserver + Send + Sync + 'static,
    ) -> Self {
        Self {
            store: RockchipBindingStore::new(application_support_root),
            census: Box::new(census),
            observer: Box::new(observer),
            proofs: ReactivationProofSource::new(
                &application_support_root.join("Agentd/rockchip-runtime"),
            ),
        }
    }

    /// `flash.bind-current-loader` once its parameters were read: the
    /// receipt, or `rejected` with the error Swift's daemon interpolates.
    ///
    /// Swift's handler first asks its engine for a DAYU200 flash Job whose
    /// enter-Loader transition awaits this binding, and settles that Job
    /// after the bind. This Runtime does not settle it yet, so a Job awaiting
    /// the binding refuses it before anything is written, and the Job's
    /// intent stays unresolved for a Runtime that can; with none,
    /// `settledJobId` is null, as Swift's.
    pub fn bind(
        &self,
        targets: &TargetStore,
        jobs: Option<&JobStore>,
        target_id: &str,
        expected_binding_revision: i64,
    ) -> Result<Value, WireError> {
        if let Some(jobs) = jobs {
            let awaiting =
                jobs.loader_transitions_awaiting_binding(target_id, expected_binding_revision)?;
            let not_runnable =
                |detail: &str| refusal(format!("jobNotRunnable({})", swift_quoted(detail)));
            match awaiting.as_slice() {
                [] => {}
                [job] => {
                    return Err(not_runnable(&format!(
                        "Job {job} awaits this Loader binding to settle its enter-Loader \
                         transition, which this Runtime does not settle yet; nothing was written"
                    )));
                }
                _ => {
                    return Err(not_runnable(&format!(
                        "multiple unresolved Loader transitions cover target {target_id}"
                    )));
                }
            }
        }
        let receipt = self
            .receipt(targets, target_id, expected_binding_revision)
            .map_err(refusal)?;
        Ok(json!({
            "targetId": target_id,
            "previousBindingRevision": receipt.previous,
            "bindingRevision": receipt.current,
            "updated": receipt.updated,
            "selectionEvidenceSha256": receipt.selection,
            "settledJobId": null,
        }))
    }

    fn receipt(
        &self,
        targets: &TargetStore,
        target_id: &str,
        expected: i64,
    ) -> Result<Receipt, String> {
        let stale = || admission("selected target or binding revision is stale");
        if target_id.is_empty() || expected <= 0 {
            return Err(stale());
        }
        let records = list(targets)?;
        let target = records
            .iter()
            .find(|record| record.id == target_id)
            .cloned()
            .ok_or_else(stale)?;
        if target.revision != expected && Some(target.revision) != expected.checked_add(1) {
            return Err(stale());
        }
        let devices = (self.census)().map_err(|_| admission("USB registry unavailable"))?;
        let registered = registered_dayu200_devices(devices);
        let [identity] = registered.as_slice() else {
            return Err(admission(
                "exactly one registered DAYU200 USB identity is required for binding",
            ));
        };
        let current = sha256_hex(identity.serial.as_bytes());
        let loader = is_dayu200_loader(identity);
        if loader {
            let request = format!("bind-current-loader-{target_id}-r{expected}");
            let confirmed = self
                .observer
                .observe_loader(&current, Some(&identity.topology), &request)
                .and_then(|confirmed| {
                    if confirmed.serial_digest_sha256 == current
                        && confirmed.topology == identity.topology
                    {
                        Ok(())
                    } else {
                        // Swift `ArkForgeLoaderObservationFailure.identityMismatch`.
                        Err("IOKit Loader identity does not match the bound target".to_owned())
                    }
                });
            if let Err(error) = confirmed {
                return Err(admission(&format!(
                    "ArkForge dual-source Loader observation is required for binding: {error}"
                )));
            }
        }
        let existing = self.store.load_existing().map_err(swift)?;
        let existing_identity = existing.identity();
        let bound = target.bound();

        // A newly adopted board beside an older board's singleton binding:
        // selecting its exact revision-1 Target switches the binding to it.
        if target.revision == expected
            && target.revision == 1
            && current != existing_identity
            && current == target.identity
        {
            let connect_identity = sha256_hex(target.connect_key.as_bytes());
            if connect_identity != current || !unique(&records, target_id, 1, &current) {
                return Err(admission(
                    "selected target does not uniquely match the current DAYU200 identity",
                ));
            }
            authorize(identity)?;
            let selection = selection_digest(
                target_id,
                existing.revision,
                target.revision,
                &existing_identity,
                &current,
                &identity.topology,
            );
            let next = BindingSnapshot {
                revision: target.revision,
                serial: identity.serial.clone(),
                usb_topology: identity.topology.clone(),
                evidence: vec![
                    HDC_NORMAL_READBACK.into(),
                    CROSS_MODE_USB.into(),
                    format!("identity:serial-sha256={current}"),
                    format!("binding:selected-target-id={target_id}"),
                    format!("binding:replaced-active-revision={}", existing.revision),
                    format!("identity:replaced-active-serial-sha256={existing_identity}"),
                    format!("rebind:user-selection-sha256={selection}"),
                ],
            };
            let stored = self
                .store
                .activate_selected_initial_target(existing.revision, &existing_identity, &next)
                .map_err(swift)?;
            if !stored.covers_runtime_target(&bound).map_err(swift)?
                || !stored
                    .matches_confirmed_live_identity(identity)
                    .map_err(swift)?
            {
                return Err(configuration(
                    "selected target activation did not cover the fresh DAYU200 identity",
                ));
            }
            return Ok(Receipt {
                previous: target.revision,
                current: target.revision,
                updated: true,
                selection,
            });
        }

        // The binding already names this Target at this revision: a retry
        // answers the attestation it carries, and nothing else is proof.
        if target.revision == expected
            && existing.revision == expected
            && existing_identity == target.identity
            && current == existing_identity
            && identity.topology == existing.usb_topology
        {
            let already_covered = existing.covers_runtime_target(&bound) == Ok(true)
                && existing.matches_confirmed_live_identity(identity) == Ok(true);
            let selections: Vec<&str> = existing
                .evidence
                .iter()
                .filter_map(|entry| entry.strip_prefix("rebind:user-selection-sha256="))
                .collect();
            let selected = format!("binding:selected-target-id={target_id}");
            if already_covered
                && existing.revision == 1
                && existing.evidence.contains(&selected)
                && let [selection] = selections.as_slice()
                && canonical_sha256(selection)
            {
                return Ok(Receipt {
                    previous: expected,
                    current: expected,
                    updated: false,
                    selection: (*selection).to_owned(),
                });
            }
            if already_covered
                && let Some(proof) = existing.loader_binding_recovery_proof().map_err(swift)?
                && proof.current_revision == expected
            {
                return Ok(Receipt {
                    previous: expected,
                    current: expected,
                    updated: false,
                    selection: proof.selection_evidence_sha256,
                });
            }
            if already_covered
                && let Some(selection) = existing
                    .reactivation_selection_evidence(target_id)
                    .map_err(swift)?
            {
                return Ok(Receipt {
                    previous: expected,
                    current: expected,
                    updated: false,
                    selection,
                });
            }
            return Err(admission(
                "selected Loader binding does not carry current Runtime attestation",
            ));
        }

        if !loader {
            return Err(admission(
                "the selected HDC-normal target has no active cross-mode binding",
            ));
        }

        // An advanced Target displaced from the singleton binding comes back
        // only with the Runtime's own proof of its retained HDC route; the
        // old binding bytes are gone and never guessed.
        if target.revision == expected
            && target.revision > 1
            && current != existing_identity
            && current == target.identity
        {
            existing.runtime_target_lineage_advance().map_err(swift)?;
            let proof = if unique(&records, target_id, target.revision, &current) {
                self.proofs.proof(&bound).map_err(swift)?
            } else {
                None
            };
            let Some(proof) = proof else {
                return Err(admission(
                    "selected historical target has no complete Runtime reactivation proof",
                ));
            };
            let connect_identity = sha256_hex(target.connect_key.as_bytes());
            if proof.target_id != target_id
                || proof.binding_revision != target.revision
                || proof.stable_loader_identity_sha256 != current
                || proof.hdc_connect_key != target.connect_key
                || proof.hdc_identity_sha256 != connect_identity
                || !canonical_sha256(&proof.current_binding_intent_sha256)
                || !canonical_sha256(&proof.hdc_route_receipt_sha256)
                || proof.hdc_usb_topology.is_empty()
                || !proof
                    .hdc_usb_topology
                    .bytes()
                    .all(|byte| byte.is_ascii_digit())
            {
                return Err(admission(
                    "selected historical target Runtime proof does not match its current binding",
                ));
            }
            authorize(identity)?;
            let selection = selection_digest(
                target_id,
                existing.revision,
                target.revision,
                &existing_identity,
                &current,
                &identity.topology,
            );
            let next = BindingSnapshot {
                revision: target.revision,
                serial: identity.serial.clone(),
                usb_topology: identity.topology.clone(),
                evidence: vec![
                    LOADER_READBACK.into(),
                    CROSS_MODE_USB.into(),
                    format!("identity:serial-sha256={current}"),
                    format!(
                        "identity:hdc-normal-alias-sha256={}",
                        proof.hdc_identity_sha256
                    ),
                    format!(
                        "binding:hdc-normal-alias-usb-topology={}",
                        proof.hdc_usb_topology
                    ),
                    format!("binding:reactivated-target-id={target_id}"),
                    format!(
                        "binding:reactivation-current-intent-sha256={}",
                        proof.current_binding_intent_sha256
                    ),
                    format!(
                        "binding:reactivation-route-receipt-sha256={}",
                        proof.hdc_route_receipt_sha256
                    ),
                    format!("binding:replaced-active-revision={}", existing.revision),
                    format!("identity:replaced-active-serial-sha256={existing_identity}"),
                    format!("rebind:user-selection-sha256={selection}"),
                ],
            };
            let stored = crate::rockchip_binding::activate_selected_target(
                &self.store,
                existing.revision,
                &existing_identity,
                &next,
            )
            .map_err(swift)?;
            if !stored.covers_runtime_target(&bound).map_err(swift)?
                || !stored
                    .matches_confirmed_live_identity(identity)
                    .map_err(swift)?
                || stored
                    .confirmed_hdc_normal_alias()
                    .map_err(swift)?
                    .map(|(alias, _)| alias)
                    != Some(connect_identity)
            {
                return Err(configuration(
                    "reactivated target binding did not cover its fresh Loader and durable HDC route",
                ));
            }
            return Ok(Receipt {
                previous: target.revision,
                current: target.revision,
                updated: true,
                selection,
            });
        }

        // The Target already advanced to this binding's edge: a retry of the
        // bind that drew it.
        if Some(target.revision) == expected.checked_add(1)
            && existing.revision == target.revision
            && current == target.identity
            && existing.covers_runtime_target(&bound).map_err(swift)?
            && existing
                .matches_confirmed_live_identity(identity)
                .map_err(swift)?
            && let Some(lineage) = existing.runtime_target_lineage_advance().map_err(swift)?
        {
            return Ok(Receipt {
                previous: expected,
                current: target.revision,
                updated: false,
                selection: selection_digest(
                    target_id,
                    expected,
                    target.revision,
                    &lineage.previous_identity_sha256,
                    &current,
                    &identity.topology,
                ),
            });
        }

        // The HDC-normal alias the new binding carries: the replaced
        // binding's own confirmed one, or, on a first cross-mode bind, the
        // Target's connect key at the port the replaced binding saw the board
        // at in hdc-normal — never the Loader's port.
        let prior_alias = existing.confirmed_hdc_normal_alias().map_err(swift)?;
        let hdc_alias = match &prior_alias {
            Some(alias) => {
                if target.revision != expected
                    || existing.revision != expected
                    || existing_identity != target.identity
                    || current == existing_identity
                {
                    return Err(admission(
                        "selected target has no migratable HDC-to-Loader binding lineage",
                    ));
                }
                alias.clone()
            }
            None => {
                if target.revision != expected
                    || target.connect_key.is_empty()
                    || !existing
                        .evidence
                        .iter()
                        .any(|entry| entry == HDC_NORMAL_READBACK)
                    || existing.usb_topology.is_empty()
                    || !existing
                        .usb_topology
                        .bytes()
                        .all(|byte| byte.is_ascii_digit())
                {
                    return Err(admission(
                        "first cross-mode binding needs a matching binding revision and an \
                         hdc-normal port observed under this binding",
                    ));
                }
                (
                    sha256_hex(target.connect_key.as_bytes()),
                    existing.usb_topology.clone(),
                )
            }
        };
        if sha256_hex(target.connect_key.as_bytes()) != hdc_alias.0 {
            return Err(admission(
                "selected target connect key does not match its durable HDC-normal alias",
            ));
        }
        // On a migration the edge starts at the binding's own identity; on a
        // first cross-mode bind, at the Target's.
        let lineage_identity = if prior_alias.is_none() {
            &target.identity
        } else {
            &existing_identity
        };
        if !unique(&records, target_id, expected, lineage_identity) {
            return Err(admission(
                "selected target binding lineage is missing or ambiguous",
            ));
        }
        authorize(identity)?;
        // The binding advances from the document it replaces, the Target from
        // its own revision; on a first cross-mode bind the two differ, and the
        // Target's edge is recorded separately.
        let replaced = existing.revision;
        let next_revision = replaced + 1;
        let target_current = target.revision + 1;
        let selection = selection_digest(
            target_id,
            replaced,
            next_revision,
            &existing_identity,
            &current,
            &identity.topology,
        );
        let next = BindingSnapshot {
            revision: next_revision,
            serial: identity.serial.clone(),
            usb_topology: identity.topology.clone(),
            evidence: vec![
                LOADER_READBACK.into(),
                CROSS_MODE_USB.into(),
                format!("identity:serial-sha256={current}"),
                format!("identity:previous-serial-sha256={lineage_identity}"),
                format!("binding:previous-revision={replaced}"),
                format!("binding:target-previous-revision={}", target.revision),
                format!("binding:target-current-revision={target_current}"),
                format!("binding:previous-usb-topology={}", existing.usb_topology),
                format!("identity:hdc-normal-alias-sha256={}", hdc_alias.0),
                format!("binding:hdc-normal-alias-usb-topology={}", hdc_alias.1),
                format!("rebind:user-selection-sha256={selection}"),
            ],
        };
        let stored = self
            .store
            .replace(replaced, &existing_identity, &next)
            .map_err(swift)?;
        let Some(advance) = stored.runtime_target_lineage_advance().map_err(swift)? else {
            return Err(configuration(
                "persisted Loader binding did not produce an adjacent target advance",
            ));
        };
        let advanced = targets.advance_binding_lineage(&advance)?;
        if advanced.target_id != target_id
            || i64::try_from(advanced.binding_revision).ok() != Some(target_current)
            || advanced.identity_sha256 != current
        {
            return Err(configuration(
                "Runtime target did not advance to the persisted Loader binding",
            ));
        }
        Ok(Receipt {
            previous: expected,
            current: next_revision,
            updated: true,
            selection,
        })
    }
}

/// The daemon's catch-all around the binding: `rejected`, with the error.
fn refusal(error: String) -> WireError {
    WireError {
        code: "rejected".into(),
        message: format!("Rockchip Loader binding was refused: {error}"),
        details: None,
    }
}

/// Swift `RuntimeTargetStore.list()`, as the coordinator compares its
/// records. A store it cannot read is Swift's `storeFailure`, whose inner
/// description is Foundation's own.
fn list(targets: &TargetStore) -> Result<Vec<Target>, String> {
    let records = targets.records().map_err(|error| {
        format!(
            "storeFailure({})",
            swift_quoted(&format!("undecodable target store: {}", error.message))
        )
    })?;
    Ok(records
        .iter()
        .filter_map(|record| {
            Some(Target {
                id: record["targetID"].as_str()?.to_owned(),
                identity: record["stablePhysicalIdentitySHA256"].as_str()?.to_owned(),
                revision: record["bindingRevision"].as_i64()?,
                connect_key: record["connectKey"].as_str()?.to_owned(),
            })
        })
        .collect())
}

/// Whether exactly this Target, and no other, sits at `revision` with
/// `identity`.
fn unique(records: &[Target], target_id: &str, revision: i64, identity: &str) -> bool {
    let matching: Vec<&str> = records
        .iter()
        .filter(|record| record.revision == revision && record.identity == identity)
        .map(|record| record.id.as_str())
        .collect();
    matching == [target_id]
}
