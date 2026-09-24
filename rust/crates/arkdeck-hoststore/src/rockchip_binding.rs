//! Swift `RockchipProductBindingStore` and `RockchipProductBindingSnapshot`
//! (`RockchipDeviceBinding.swift`), read side: the owner-only cross-mode
//! binding of a DAYU200, `rockchip-binding.json` in the Application Support
//! root (the parent of the daemon state directory), and the rules that decide
//! from its evidence whether it covers a Runtime Target or a live USB
//! personality.
//!
//! The binding is written by the Loader binding owner (M4-4); nothing here
//! writes it. A read prepares the root as Swift's does — created owner-only
//! when absent and made owner-only whether or not it existed — and every
//! refusal is Swift's `productionConfigurationUnavailable` detail.
use crate::strict_json::swift_quoted;
use arkdeck_contract::sha256_hex;
use arkdeck_platform::{HostDirectory, OwnerOnlyReadFailure, UsbHostDevice};
use arkdeck_provider_hdc::{is_dayu200_hdc_normal, is_dayu200_loader};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// Swift `RockchipFlashExecutionError.productionConfigurationUnavailable`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BindingError(&'static str);

impl BindingError {
    pub fn detail(&self) -> &'static str {
        self.0
    }

    /// The error as Swift's daemon interpolates it.
    pub fn swift(&self) -> String {
        format!(
            "productionConfigurationUnavailable({})",
            swift_quoted(self.0)
        )
    }
}

fn refuse(detail: &'static str) -> BindingError {
    BindingError(detail)
}

/// The store at one root.
pub struct RockchipBindingStore {
    root: PathBuf,
}

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

/// Swift `RockchipProductBindingSnapshot`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BindingSnapshot {
    pub revision: i64,
    pub serial: String,
    pub usb_topology: String,
    pub evidence: Vec<String>,
}

impl RockchipBindingStore {
    /// Swift `bindingFileName`.
    pub const FILE_NAME: &'static str = "rockchip-binding.json";
    /// Swift `maximumDocumentBytes`.
    pub const MAXIMUM_BYTES: usize = 64 * 1_024;

    pub fn new(root: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
        }
    }

    /// Swift `loadIfPresent()`: the root prepared, then the document read
    /// without a lock — `None` when absent.
    pub fn load_if_present(&self) -> Result<Option<BindingSnapshot>, BindingError> {
        let root = self.prepare_root()?;
        let Some(bytes) = root
            .read_owner_only_detailed(Self::FILE_NAME, Self::MAXIMUM_BYTES)
            .map_err(|refused| {
                refuse(match refused {
                    OwnerOnlyReadFailure::Open(_) => "durable binding cannot be opened",
                    OwnerOnlyReadFailure::Identity => {
                        "durable binding must be an owner-only regular file"
                    }
                    OwnerOnlyReadFailure::Size => "durable binding size is invalid",
                    OwnerOnlyReadFailure::Truncated => "durable binding was truncated",
                })
            })?
        else {
            return Ok(None);
        };
        let snapshot = decode(&bytes)?;
        snapshot.validate()?;
        Ok(Some(snapshot))
    }

    /// Swift `prepareRoot()`: an absolute root that is no link, created
    /// owner-only when absent and made owner-only.
    fn prepare_root(&self) -> Result<HostDirectory, BindingError> {
        if !self.root.is_absolute() {
            return Err(refuse("binding root must be an absolute file URL"));
        }
        if std::fs::symlink_metadata(&self.root).is_ok_and(|metadata| metadata.is_symlink()) {
            return Err(refuse("binding root cannot be a symbolic link"));
        }
        HostDirectory::open_or_create_private(&self.root)
            .map_err(|_| refuse("binding root cannot be opened"))
    }
}

/// Swift `load(rootDescriptor:)` after the read: the top level must be an
/// object with exactly the four members, then `JSONDecoder` reads them.
fn decode(bytes: &[u8]) -> Result<BindingSnapshot, BindingError> {
    // Swift's `JSONSerialization` failure escapes unwrapped as Foundation's
    // own error; a document that is not JSON is refused as undecodable here.
    let value: Value =
        serde_json::from_slice(bytes).map_err(|_| refuse("durable binding cannot be decoded"))?;
    let schema = || refuse("durable binding schema is invalid");
    let object = value.as_object().ok_or_else(schema)?;
    let mut keys: Vec<&str> = object.keys().map(String::as_str).collect();
    keys.sort_unstable();
    if keys != ["evidence", "revision", "serial", "usbTopology"] {
        return Err(schema());
    }
    let undecodable = || refuse("durable binding cannot be decoded");
    let text = |key: &str| {
        object[key]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(undecodable)
    };
    Ok(BindingSnapshot {
        revision: object["revision"]
            .as_number()
            .and_then(crate::swift_decoding::swift_integer)
            .ok_or_else(undecodable)?,
        serial: text("serial")?,
        usb_topology: text("usbTopology")?,
        evidence: object["evidence"]
            .as_array()
            .ok_or_else(undecodable)?
            .iter()
            .map(|entry| entry.as_str().map(str::to_owned).ok_or_else(undecodable))
            .collect::<Result<_, _>>()?,
    })
}

/// Swift `RockchipDigestValidation.isCanonicalSHA256`.
fn canonical_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Swift's check of a topology: ASCII digits, and no leading zero but `0`.
fn canonical_topology(value: &str) -> bool {
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
}

impl BindingSnapshot {
    /// Swift `validate(_:)`.
    fn validate(&self) -> Result<(), BindingError> {
        let valid = self.revision > 0
            && !self.serial.is_empty()
            && !self.usb_topology.is_empty()
            && self.usb_topology.bytes().all(|byte| byte.is_ascii_digit())
            && !self.evidence.is_empty()
            && self
                .evidence
                .iter()
                .all(|entry| !entry.is_empty() && !entry.contains(self.serial.as_str()));
        if valid {
            Ok(())
        } else {
            Err(refuse("durable binding snapshot is invalid"))
        }
    }

    /// Swift `values(prefix:)`: every entry's text after the prefix, in order.
    fn values(&self, prefix: &str) -> Vec<&str> {
        self.evidence
            .iter()
            .filter_map(|entry| entry.strip_prefix(prefix))
            .collect()
    }

    fn identity(&self) -> String {
        sha256_hex(self.serial.as_bytes())
    }

    /// Swift `runtimeTargetLineageAdvance()`: the one adjacent edge this
    /// binding's rebind evidence proves, none for revision 1 or a same-revision
    /// reactivation; incomplete or invented lineage refuses.
    pub fn runtime_target_lineage_advance(&self) -> Result<Option<LineageAdvance>, BindingError> {
        let current = self.identity();
        if self.values("identity:serial-sha256=") != [current.as_str()] {
            return Err(refuse(
                "durable binding current identity evidence is missing or ambiguous",
            ));
        }
        if self.reactivation()?.is_some() || self.revision == 1 {
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

    /// Swift `reactivationEvidence()`: the complete same-revision activation
    /// proof of one exact Target, or none when no marker of it is present;
    /// any partial marker refuses.
    fn reactivation(&self) -> Result<Option<Reactivation>, BindingError> {
        let target_ids = self.values("binding:reactivated-target-id=");
        let intents = self.values("binding:reactivation-current-intent-sha256=");
        let receipts = self.values("binding:reactivation-route-receipt-sha256=");
        if target_ids.len() + intents.len() + receipts.len() == 0 {
            return Ok(None);
        }
        let invalid = || refuse("durable binding reactivation evidence is invalid or ambiguous");
        let replaced_revisions = self.values("binding:replaced-active-revision=");
        let replaced_identities = self.values("identity:replaced-active-serial-sha256=");
        let selections = self.values("rebind:user-selection-sha256=");
        let aliases = self.values("identity:hdc-normal-alias-sha256=");
        let alias_topologies = self.values("binding:hdc-normal-alias-usb-topology=");
        if self.revision <= 1
            || !self
                .evidence
                .iter()
                .any(|entry| entry == "product:e0-iokit-single-loader-readback")
            || !self.values("identity:previous-serial-sha256=").is_empty()
            || !self.values("binding:previous-revision=").is_empty()
            || !self.values("binding:previous-usb-topology=").is_empty()
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
        let current = self.identity();
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
                &self.revision.to_string(),
                replaced_identity,
                &current,
                &self.usb_topology,
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
        }))
    }

    /// Swift `confirmedHDCNormalAlias()`: the one HDC-normal personality this
    /// binding's confirmed lineage accepts besides its current identity, as
    /// its identity digest and topology.
    pub fn confirmed_hdc_normal_alias(&self) -> Result<Option<(String, String)>, BindingError> {
        if !self
            .evidence
            .iter()
            .any(|entry| entry == "product:e0-iokit-single-loader-readback")
        {
            return Ok(None);
        }
        let adjacent = self.runtime_target_lineage_advance()?.is_some();
        let reactivated = self.reactivation()?.is_some();
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

    /// Swift `coversRuntimeTarget(_:)`: this binding names the Target's exact
    /// stable identity at the revision its lineage expects, and the Target's
    /// connect key is that identity or the one confirmed HDC-normal alias.
    pub fn covers_runtime_target(&self, target: &BoundTarget<'_>) -> Result<bool, BindingError> {
        let advance = self.runtime_target_lineage_advance()?;
        let current = self.identity();
        let expected_revision = advance.map_or(self.revision, |edge| edge.current_revision);
        if target.identity_sha256 != current || target.binding_revision != expected_revision {
            return Ok(false);
        }
        if let Some(reactivation) = self.reactivation()?
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

    /// Swift `matchesConfirmedLiveIdentity(_:)`: a registered DAYU200 whose
    /// serial and topology are this binding's, or, in its HDC-normal
    /// personality, the confirmed alias's.
    pub fn matches_confirmed_live_identity(
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
