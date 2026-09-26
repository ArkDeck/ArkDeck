//! What the Runtime reads in the DAYU200's cross-mode binding (Swift
//! `RockchipProductBindingSnapshot`'s rules over its evidence): whether it
//! covers a Runtime Target or a live USB personality, the adjacent lineage
//! edge a Loader rebind drew, a same-revision reactivation and its HDC-normal
//! alias; and the one write that needs them, the Loader binding owner's
//! switch to an advanced Target.
//!
//! The binding's document, lock and every other write are
//! `arkdeck-rockchip-binding`'s, shared with the CLI's `flash install-binding`
//! (协调会话 2026-09-26: the CLI links no Runtime store).
use arkdeck_contract::sha256_hex;
use arkdeck_platform::UsbHostDevice;
pub(crate) use arkdeck_rockchip_binding::refuse;
pub use arkdeck_rockchip_binding::{
    BindingError, BindingInstallation, BindingSnapshot, RockchipBindingStore,
    install_current_target,
};
use arkdeck_rockchip_binding::{is_dayu200_hdc_normal, is_dayu200_loader};

/// The adjacent edge a rebind advances a Runtime Target along.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LineageAdvance {
    pub previous_identity_sha256: String,
    pub previous_revision: i64,
    pub current_identity_sha256: String,
    pub current_revision: i64,
}

/// The Runtime Target facts a binding is compared with (Swift
/// `RuntimeTargetRecord`).
#[derive(Clone, Copy, Debug)]
pub struct BoundTarget<'a> {
    pub target_id: &'a str,
    pub identity_sha256: &'a str,
    pub binding_revision: i64,
    pub connect_key: &'a str,
}

/// Swift `activateSelectedTarget(expectedRevision:expectedSerialSHA256:
/// with:)`: the singleton binding switched to an advanced Target, at its
/// own revision, only with the complete same-revision reactivation
/// evidence and a confirmed HDC-normal alias.
pub(crate) fn activate_selected_target(
    store: &RockchipBindingStore,
    expected_revision: i64,
    expected_serial_sha256: &str,
    candidate: &BindingSnapshot,
) -> Result<BindingSnapshot, BindingError> {
    let invalid = || refuse("selected advanced target binding is invalid");
    if candidate.revision <= 1 || candidate.identity() == expected_serial_sha256 {
        return Err(invalid());
    }
    if candidate.runtime_target_lineage_advance()?.is_some()
        || candidate.confirmed_hdc_normal_alias()?.is_none()
    {
        return Err(invalid());
    }
    let Some(target_id) = candidate.reactivated_target_id()? else {
        return Err(invalid());
    };
    if candidate
        .reactivation_selection_evidence(&target_id)?
        .is_none()
    {
        return Err(invalid());
    }
    store.compare_and_swap(
        expected_revision,
        expected_serial_sha256,
        candidate.revision,
        candidate,
        "durable binding changed before selected target reactivation",
    )
}

/// Swift `RockchipDigestValidation.isCanonicalSHA256`.
pub(crate) fn canonical_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Swift's check of a topology: ASCII digits, and no leading zero but `0`.
pub(crate) fn canonical_topology(value: &str) -> bool {
    !value.is_empty()
        && value.bytes().all(|byte| byte.is_ascii_digit())
        && (value == "0" || !value.starts_with('0'))
}

/// Swift `Int(String)`: an optional sign and decimal digits within `Int`.
fn swift_int(text: &str) -> Option<i64> {
    text.parse::<i64>().ok()
}

/// Swift's `TGT-` identity of a reactivated Target:
/// `^TGT-[A-Za-z0-9][A-Za-z0-9._-]{0,123}$`.
fn reactivated_target_identity(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("TGT-") else {
        return false;
    };
    let bytes = rest.as_bytes();
    (1..=124).contains(&bytes.len())
        && bytes[0].is_ascii_alphanumeric()
        && bytes[1..]
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(byte))
}

/// Swift `ReactivationEvidence`.
struct Reactivation {
    target_id: String,
    selection: String,
}

/// Swift `RockchipLoaderBindingRecoveryProof`: the adjacent Target revisions
/// a published Loader binding drew and the Runtime selection it recorded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveryProof {
    pub previous_revision: i64,
    pub current_revision: i64,
    pub selection_evidence_sha256: String,
}

/// The readback of a Loader seen in its hdc-normal personality, which every
/// cross-mode lineage records.
const LOADER_READBACK: &str = "product:e0-iokit-single-loader-readback";

/// Swift `RockchipProductBindingSnapshot`'s readings of its evidence, as the
/// Runtime makes them.
pub trait BindingEvidence {
    /// Swift `reactivationSelectionEvidence(targetID:)`: the selection of a
    /// complete same-revision reactivation of exactly this Target.
    fn reactivation_selection_evidence(
        &self,
        target_id: &str,
    ) -> Result<Option<String>, BindingError>;

    /// Swift `reactivatedTargetID()`.
    fn reactivated_target_id(&self) -> Result<Option<String>, BindingError>;

    /// Swift `loaderBindingRecoveryProof()`: the adjacent revisions and the
    /// selection of a published Loader binding, enough to finish settling
    /// the enter-Loader intent it answered; none unless the binding is a
    /// complete confirmed lineage with one Runtime selection.
    fn loader_binding_recovery_proof(&self) -> Result<Option<RecoveryProof>, BindingError>;

    /// Swift `runtimeTargetLineageAdvance()`: the one adjacent edge this
    /// binding's rebind evidence proves, none for revision 1 or a same-revision
    /// reactivation; incomplete or invented lineage refuses.
    fn runtime_target_lineage_advance(&self) -> Result<Option<LineageAdvance>, BindingError>;

    /// Swift `confirmedHDCNormalAlias()`: the one HDC-normal personality this
    /// binding's confirmed lineage accepts besides its current identity, as
    /// its identity digest and topology.
    fn confirmed_hdc_normal_alias(&self) -> Result<Option<(String, String)>, BindingError>;

    /// Swift `coversRuntimeTarget(_:)`: this binding names the Target's exact
    /// stable identity at the revision its lineage expects, and the Target's
    /// connect key is that identity or the one confirmed HDC-normal alias.
    fn covers_runtime_target(&self, target: &BoundTarget<'_>) -> Result<bool, BindingError>;

    /// Swift `matchesConfirmedLiveIdentity(_:)`: a registered DAYU200 whose
    /// serial and topology are this binding's, or, in its HDC-normal
    /// personality, the confirmed alias's.
    fn matches_confirmed_live_identity(&self, device: &UsbHostDevice)
    -> Result<bool, BindingError>;
}

impl BindingEvidence for BindingSnapshot {
    fn reactivation_selection_evidence(
        &self,
        target_id: &str,
    ) -> Result<Option<String>, BindingError> {
        Ok(reactivation(self)?
            .filter(|reactivation| reactivation.target_id == target_id)
            .map(|reactivation| reactivation.selection))
    }

    fn reactivated_target_id(&self) -> Result<Option<String>, BindingError> {
        Ok(reactivation(self)?.map(|reactivation| reactivation.target_id))
    }

    fn loader_binding_recovery_proof(&self) -> Result<Option<RecoveryProof>, BindingError> {
        if !self.evidence.iter().any(|entry| entry == LOADER_READBACK)
            || self
                .evidence
                .iter()
                .filter(|entry| entry.starts_with("rebind:"))
                .count()
                != 1
        {
            return Ok(None);
        }
        let Some(advance) = self.runtime_target_lineage_advance()? else {
            return Ok(None);
        };
        if self.confirmed_hdc_normal_alias()?.is_none() {
            return Ok(None);
        }
        match self.values("rebind:user-selection-sha256=").as_slice() {
            [selection] if canonical_sha256(selection) => Ok(Some(RecoveryProof {
                previous_revision: advance.previous_revision,
                current_revision: advance.current_revision,
                selection_evidence_sha256: (*selection).to_owned(),
            })),
            _ => Err(refuse(
                "durable Loader binding selection evidence is invalid or ambiguous",
            )),
        }
    }

    fn runtime_target_lineage_advance(&self) -> Result<Option<LineageAdvance>, BindingError> {
        let current = self.identity();
        if self.values("identity:serial-sha256=") != [current.as_str()] {
            return Err(refuse(
                "durable binding current identity evidence is missing or ambiguous",
            ));
        }
        if reactivation(self)?.is_some() || self.revision == 1 {
            return Ok(None);
        }
        let previous_identities = self.values("identity:previous-serial-sha256=");
        let edge_previous = self.values("binding:target-previous-revision=");
        let edge_current = self.values("binding:target-current-revision=");
        let previous_revisions = self.values("binding:previous-revision=");
        let previous_topologies = self.values("binding:previous-usb-topology=");
        let confirmations = self.values("rebind:user-selection-sha256=");
        let lineage =
            || refuse("durable binding previous identity lineage is invalid or ambiguous");
        let ([previous_identity], [previous_revision], [previous_topology], [confirmation]) = (
            previous_identities.as_slice(),
            previous_revisions.as_slice(),
            previous_topologies.as_slice(),
            confirmations.as_slice(),
        ) else {
            return Err(lineage());
        };
        let previous_revision = swift_int(previous_revision).ok_or_else(lineage)?;
        if !canonical_sha256(previous_identity)
            || !canonical_sha256(confirmation)
            || *previous_identity == current
            || previous_revision <= 0
            || previous_revision.checked_add(1) != Some(self.revision)
            || !canonical_topology(previous_topology)
        {
            return Err(lineage());
        }
        let edge_previous = match edge_previous.as_slice() {
            [text] => swift_int(text).unwrap_or(previous_revision),
            _ => previous_revision,
        };
        let edge_current = match edge_current.as_slice() {
            [text] => swift_int(text).unwrap_or(self.revision),
            _ => self.revision,
        };
        if edge_previous <= 0 || edge_previous.checked_add(1) != Some(edge_current) {
            return Err(refuse("durable binding target lineage edge is invalid"));
        }
        Ok(Some(LineageAdvance {
            previous_identity_sha256: (*previous_identity).to_owned(),
            previous_revision: edge_previous,
            current_identity_sha256: current,
            current_revision: edge_current,
        }))
    }

    fn confirmed_hdc_normal_alias(&self) -> Result<Option<(String, String)>, BindingError> {
        if !self.evidence.iter().any(|entry| entry == LOADER_READBACK) {
            return Ok(None);
        }
        let adjacent = self.runtime_target_lineage_advance()?.is_some();
        let reactivated = reactivation(self)?.is_some();
        if adjacent == reactivated {
            if !adjacent {
                return Ok(None);
            }
            return Err(refuse(
                "durable binding carries ambiguous HDC alias authority",
            ));
        }
        let identities = self.values("identity:hdc-normal-alias-sha256=");
        let topologies = self.values("binding:hdc-normal-alias-usb-topology=");
        match (identities.as_slice(), topologies.as_slice()) {
            ([identity], [topology])
                if canonical_sha256(identity) && canonical_topology(topology) =>
            {
                Ok(Some(((*identity).to_owned(), (*topology).to_owned())))
            }
            _ => Err(refuse(
                "durable binding HDC-normal alias is invalid or ambiguous",
            )),
        }
    }

    fn covers_runtime_target(&self, target: &BoundTarget<'_>) -> Result<bool, BindingError> {
        let advance = self.runtime_target_lineage_advance()?;
        let current = self.identity();
        let expected_revision = advance.map_or(self.revision, |edge| edge.current_revision);
        if target.identity_sha256 != current || target.binding_revision != expected_revision {
            return Ok(false);
        }
        if let Some(reactivation) = reactivation(self)?
            && reactivation.target_id != target.target_id
        {
            return Ok(false);
        }
        let connect = sha256_hex(target.connect_key.as_bytes());
        if connect == current {
            return Ok(true);
        }
        Ok(self
            .confirmed_hdc_normal_alias()?
            .is_some_and(|(identity, _)| identity == connect))
    }

    fn matches_confirmed_live_identity(
        &self,
        device: &UsbHostDevice,
    ) -> Result<bool, BindingError> {
        let hdc_normal = is_dayu200_hdc_normal(device);
        if !(is_dayu200_loader(device) || hdc_normal) {
            return Ok(false);
        }
        let live = sha256_hex(device.serial.as_bytes());
        self.runtime_target_lineage_advance()?;
        if live == self.identity() && device.topology == self.usb_topology {
            return Ok(true);
        }
        if !hdc_normal {
            return Ok(false);
        }
        Ok(self
            .confirmed_hdc_normal_alias()?
            .is_some_and(|(identity, topology)| live == identity && device.topology == topology))
    }
}

/// Swift `reactivationEvidence()`: the complete same-revision activation
/// proof of one exact Target, or none when no marker of it is present;
/// any partial marker refuses.
fn reactivation(snapshot: &BindingSnapshot) -> Result<Option<Reactivation>, BindingError> {
    let target_ids = snapshot.values("binding:reactivated-target-id=");
    let intents = snapshot.values("binding:reactivation-current-intent-sha256=");
    let receipts = snapshot.values("binding:reactivation-route-receipt-sha256=");
    if target_ids.len() + intents.len() + receipts.len() == 0 {
        return Ok(None);
    }
    let invalid = || refuse("durable binding reactivation evidence is invalid or ambiguous");
    let replaced_revisions = snapshot.values("binding:replaced-active-revision=");
    let replaced_identities = snapshot.values("identity:replaced-active-serial-sha256=");
    let selections = snapshot.values("rebind:user-selection-sha256=");
    let aliases = snapshot.values("identity:hdc-normal-alias-sha256=");
    let alias_topologies = snapshot.values("binding:hdc-normal-alias-usb-topology=");
    if snapshot.revision <= 1
        || !snapshot
            .evidence
            .iter()
            .any(|entry| entry == LOADER_READBACK)
        || !snapshot
            .values("identity:previous-serial-sha256=")
            .is_empty()
        || !snapshot.values("binding:previous-revision=").is_empty()
        || !snapshot.values("binding:previous-usb-topology=").is_empty()
    {
        return Err(invalid());
    }
    let (
        [target_id],
        [intent],
        [receipt],
        [replaced_revision],
        [replaced_identity],
        [selection],
        [alias],
        [alias_topology],
    ) = (
        target_ids.as_slice(),
        intents.as_slice(),
        receipts.as_slice(),
        replaced_revisions.as_slice(),
        replaced_identities.as_slice(),
        selections.as_slice(),
        aliases.as_slice(),
        alias_topologies.as_slice(),
    )
    else {
        return Err(invalid());
    };
    let replaced_revision = swift_int(replaced_revision).ok_or_else(invalid)?;
    let current = snapshot.identity();
    if !reactivated_target_identity(target_id)
        || replaced_revision <= 0
        || !canonical_sha256(intent)
        || !canonical_sha256(receipt)
        || intent == receipt
        || !canonical_sha256(replaced_identity)
        || *replaced_identity == current
        || !canonical_sha256(selection)
        || !canonical_sha256(alias)
        || !canonical_topology(alias_topology)
    {
        return Err(invalid());
    }
    let expected = sha256_hex(
        [
            "rockchip-loader-user-selection",
            target_id,
            &replaced_revision.to_string(),
            &snapshot.revision.to_string(),
            replaced_identity,
            &current,
            &snapshot.usb_topology,
        ]
        .join("\n")
        .as_bytes(),
    );
    if *selection != expected {
        return Err(refuse(
            "durable binding reactivation selection digest does not match its exact facts",
        ));
    }
    Ok(Some(Reactivation {
        target_id: (*target_id).to_owned(),
        selection: (*selection).to_owned(),
    }))
}
