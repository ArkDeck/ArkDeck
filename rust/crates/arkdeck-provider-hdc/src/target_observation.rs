//! The physical side of a target observation, as Swift's
//! `TargetObservationCoordinator` proves it: every device list is bracketed
//! by two independent reads of the USB relations the Runtime observes on its
//! own — a serial that is the connect key, a decimal location, a live
//! attachment identity and the registered vendor and product — and a
//! candidate carries a proved relation only when exactly one usable relation
//! names its serial in both reads, unchanged, and no other row shares its
//! connect key. Neither a connect key nor a hash of it can construct that
//! proof, and a candidate without one can never be adopted.
//!
//! The candidate list, the tool version and the identity readback are Swift's
//! `ProviderBootstrapObservation` over an [`HdcDispatch`]: `list targets -v`,
//! `-v` and the exact-row confirmation, judged by the observation parsers, so
//! that the fixture's shell fake can drive them (the registered-digest gate of
//! [`crate::HdcReadOnlyProvider`] stays for production tools). Who reads the
//! relations is a [`UsbRelations`] port. The Runtime's own reader is
//! [`UsbRegistryRelations`], Swift's `TargetUSBRelation.registeredDAYU200()`
//! over `arkdeck-platform`'s read-only I/O Registry census, the source Swift's
//! daemon reads (the maintainer's decision Q1=B of 2026-09-24; r11's design
//! table had the ArkForge lane's `arkforged discoverDevices` serve it, which is
//! re-evaluated after M4). [`NoUsbRelations`] answers no relations at all
//! wherever no registered HDC is composed — fail closed, every candidate
//! unproved. Stamping observation identities and generations over a reading
//! is the Target owner's.
use crate::{
    Action, DeviceCandidate, DispatchFailure, Expected, HdcDispatch, Outcome, ParseError,
    ProcessPlan, parse_target_list,
};
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fmt;
use std::time::Duration;

/// Swift `RockchipProbeEvidence.rockUSBVendorID`.
pub const ROCKUSB_VENDOR_ID: u16 = 0x2207;
/// Swift `RockchipHDCIntegrationProfile.dayu200NormalProductID`.
pub const DAYU200_NORMAL_PRODUCT_ID: u16 = 0x5000;
/// Swift `RockchipProbeEvidence.dayu200LoaderProductID`: the RockUSB Loader
/// personality of the board.
pub const DAYU200_LOADER_PRODUCT_ID: u16 = 0x350a;
/// Swift `TargetObservationCoordinator.stamp`'s bounds on a reading.
const MAXIMUM_CANDIDATES: usize = 1000;
const MAXIMUM_CONNECT_KEY_BYTES: usize = 1024;
/// The highest registered HDC version, which Swift's candidate list is parsed
/// with (`profile.registeredVersions.sorted().last`).
const HIGHEST_REGISTERED_VERSION: &str = "3.2.0f";
/// Swift `HDCObservationProviderAdapter.lower` for the observe actions.
const OBSERVE_TIMEOUT: Duration = Duration::from_secs(15);
const CAPTURE_BYTES: usize = 8 * 1024 * 1024;

/// Swift `TargetUSBRelation`: a live USB relation independently observed by
/// the Runtime, with the attachment identity of one IOKit lifetime — not a
/// durable device identity, which is what makes a reconnect a new
/// observation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UsbRelation {
    pub serial: String,
    pub location: String,
    pub attachment_id: u64,
    pub vendor_id: u16,
    pub product_id: u16,
}

impl UsbRelation {
    /// Swift `isUsable`: a printable ASCII serial of 1 to 1024 bytes holding
    /// no `:`, a location that is a decimal number spelled canonically, a
    /// non-zero attachment, and the registered DAYU200 vendor and product.
    pub fn is_usable(&self) -> bool {
        let serial = self.serial.as_bytes();
        (1..=1024).contains(&serial.len())
            && serial.iter().all(|byte| (33..=126).contains(byte))
            && !self.serial.contains(':')
            && self
                .location
                .parse::<u64>()
                .is_ok_and(|value| value.to_string() == self.location)
            && self.attachment_id != 0
            && self.vendor_id == ROCKUSB_VENDOR_ID
            && self.product_id == DAYU200_NORMAL_PRODUCT_ID
    }

    /// The relation as the Swift oracles record it
    /// (`{"attachmentId","location","productId","serial","vendorId"}`).
    pub fn from_value(value: &Value) -> Option<Self> {
        Some(Self {
            serial: value.get("serial")?.as_str()?.to_owned(),
            location: value.get("location")?.as_str()?.to_owned(),
            attachment_id: value.get("attachmentId")?.as_u64()?,
            vendor_id: u16::try_from(value.get("vendorId")?.as_u64()?).ok()?,
            product_id: u16::try_from(value.get("productId")?.as_u64()?).ok()?,
        })
    }

    pub fn to_value(&self) -> Value {
        json!({
            "attachmentId": self.attachment_id,
            "location": self.location,
            "productId": self.product_id,
            "serial": self.serial,
            "vendorId": self.vendor_id,
        })
    }
}

/// Who reads the live USB relations. A read that fails is an error the
/// observation propagates (Swift's `usbRelations()` throwing breaks the
/// observation's continuity); a read that answers nothing leaves every
/// candidate unproved.
pub trait UsbRelations {
    fn relations(&self) -> Result<Vec<UsbRelation>, String>;
}

impl<F: Fn() -> Result<Vec<UsbRelation>, String>> UsbRelations for F {
    fn relations(&self) -> Result<Vec<UsbRelation>, String> {
        self()
    }
}

/// No relation reader: beside a fixture HDC, and wherever no registered HDC
/// is composed. No relation is ever observed, so no candidate is ever proved
/// and no adoption can pass. It never fails the observation itself — the
/// device list stays readable.
pub struct NoUsbRelations;

impl UsbRelations for NoUsbRelations {
    fn relations(&self) -> Result<Vec<UsbRelation>, String> {
        Ok(Vec::new())
    }
}

/// Swift `RockchipProductUSBIdentity.isHDCNormal`'s product name, which the
/// board reports between quotes.
const HDC_NORMAL_PRODUCT_NAME: &str = "HDC Device";

/// Swift's answer when its registry census throws: the reading fails, and
/// the daemon's catch-all describes the error it caught,
/// `RockchipFlashExecutionError.admissionRejected("USB registry unavailable")`.
pub const REGISTRY_UNAVAILABLE: &str = "admissionRejected(\"USB registry unavailable\")";

/// Swift `RockchipProductUSBIdentity.isHDCNormal`: the registered vendor, the
/// DAYU200's normal-mode product, and a product name that is exactly
/// `HDC Device` once quotes and spaces are trimmed from both ends. The Loader
/// personality and every other device are not.
pub fn is_dayu200_hdc_normal(device: &UsbHostDevice) -> bool {
    device.vendor_id == ROCKUSB_VENDOR_ID
        && device.product_id == DAYU200_NORMAL_PRODUCT_ID
        && device
            .product_name
            .as_deref()
            .is_some_and(|name| name.trim_matches(['"', ' ']) == HDC_NORMAL_PRODUCT_NAME)
}

/// Swift `RockchipProductUSBIdentity.isLoader`: the registered vendor and the
/// DAYU200's Loader product, whatever name it reports.
pub fn is_dayu200_loader(device: &UsbHostDevice) -> bool {
    device.vendor_id == ROCKUSB_VENDOR_ID && device.product_id == DAYU200_LOADER_PRODUCT_ID
}

/// Swift `RockchipProductUSBProbe.registeredDAYU200Identities()` over one
/// census: every device in a registered DAYU200 personality, Loader or
/// HDC-normal, in census order and without deduplication; a registry entry ID
/// is not required.
pub fn registered_dayu200_devices(devices: Vec<UsbHostDevice>) -> Vec<UsbHostDevice> {
    devices
        .into_iter()
        .filter(|device| is_dayu200_loader(device) || is_dayu200_hdc_normal(device))
        .collect()
}

/// Swift `TargetUSBRelation.registeredDAYU200()` over one census: every
/// HDC-normal DAYU200 with a registry entry ID, in census order and without
/// deduplication, as a relation whose location is its topology and whose
/// attachment is that ID. Nothing else is judged here: whether a relation is
/// usable, unique and unchanged is the reading's rule ([`Reading::rows`]).
pub fn registered_dayu200_relations(devices: &[UsbHostDevice]) -> Vec<UsbRelation> {
    devices
        .iter()
        .filter(|device| is_dayu200_hdc_normal(device))
        .filter_map(|device| {
            Some(UsbRelation {
                serial: device.serial.clone(),
                location: device.topology.clone(),
                attachment_id: device.registry_entry_id?,
                vendor_id: device.vendor_id,
                product_id: device.product_id,
            })
        })
        .collect()
}

/// The Runtime's own USB relations: Swift's daemon composes its coordinator
/// with `TargetUSBRelation.registeredDAYU200()`, a fresh census of the host's
/// I/O Registry on every read, and so does this with its census —
/// [`UsbRegistryRelations::system`] reads the host's, a test hands it one. A
/// census that cannot be taken fails the read with Swift's words, which fails
/// the observation and breaks its continuity: it is never read as no devices.
pub struct UsbRegistryRelations<C> {
    census: C,
}

impl<C> UsbRegistryRelations<C>
where
    C: Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable>,
{
    pub fn new(census: C) -> Self {
        Self { census }
    }
}

#[cfg(target_os = "macos")]
impl UsbRegistryRelations<fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable>> {
    /// The host's I/O Registry (`arkdeck_platform::usb_host_devices`).
    pub fn system() -> Self {
        Self::new(arkdeck_platform::usb_host_devices)
    }
}

impl<C> UsbRelations for UsbRegistryRelations<C>
where
    C: Fn() -> Result<Vec<UsbHostDevice>, RegistryUnavailable>,
{
    fn relations(&self) -> Result<Vec<UsbRelation>, String> {
        (self.census)()
            .map(|devices| registered_dayu200_relations(&devices))
            .map_err(|_| REGISTRY_UNAVAILABLE.to_owned())
    }
}

/// Swift `BootstrapError.observationFailed`: why an observation could not
/// be verified, in the words Swift's bootstrap port uses.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BootstrapFailure(pub String);

impl fmt::Display for BootstrapFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "observationFailed(\"{}\")", self.0)
    }
}

impl std::error::Error for BootstrapFailure {}

impl From<DispatchFailure> for BootstrapFailure {
    fn from(failure: DispatchFailure) -> Self {
        match failure {
            DispatchFailure::Refused(detail) | DispatchFailure::Unobservable(detail) => {
                Self(detail)
            }
        }
    }
}

/// Swift `targetSummary`: a failed verdict as `code: detail`, an unknown one
/// as its reason, an unsupported one as the caller's fixed message.
fn summary(
    outcome: Outcome,
    unsupported: &str,
) -> Result<BTreeMap<String, String>, BootstrapFailure> {
    match outcome {
        Outcome::Verified(summary) => Ok(summary),
        Outcome::Failed { code, detail } => Err(BootstrapFailure(format!("{code}: {detail}"))),
        Outcome::Unknown(reason) => Err(BootstrapFailure(reason)),
        Outcome::Unsupported(_) => Err(BootstrapFailure(unsupported.to_owned())),
    }
}

/// Swift `observeToolVersion`: `-v`, judged by the client-version parser.
pub fn observe_tool_version(dispatch: &dyn HdcDispatch) -> Result<String, BootstrapFailure> {
    let action = Action::ObserveTool;
    let plan = action.lower("observe", None).map_err(BootstrapFailure)?;
    let receipt = dispatch.dispatch(&plan)?;
    match action.verify(&receipt, Expected::default()) {
        Outcome::Verified(summary) => summary
            .get("toolVersion")
            .cloned()
            .ok_or_else(|| BootstrapFailure("tool version could not be verified".into())),
        _ => Err(BootstrapFailure(
            "tool version could not be verified".into(),
        )),
    }
}

/// Swift `listCandidates`: `list targets -v` parsed with the highest
/// registered version, every row as it was read. The client's exit status
/// is not read, as Swift's verdict does not read it.
pub fn list_candidates(
    dispatch: &dyn HdcDispatch,
) -> Result<Vec<DeviceCandidate>, BootstrapFailure> {
    let receipt = dispatch.dispatch(&ProcessPlan {
        arguments: ["list", "targets", "-v"].map(str::to_owned).to_vec(),
        timeout: OBSERVE_TIMEOUT,
        capture_bytes: CAPTURE_BYTES,
    })?;
    parse_target_list(
        &receipt.stdout,
        HIGHEST_REGISTERED_VERSION,
        receipt.truncated,
    )
    .map_err(|error| match error {
        ParseError::UnsupportedVersion(_) => {
            BootstrapFailure("candidate list could not be verified".into())
        }
        ParseError::InvalidEncoding => {
            BootstrapFailure("invalidEncoding: stdout is not valid UTF-8".into())
        }
        ParseError::Truncated => {
            BootstrapFailure("truncated: stdout exceeded its byte budget".into())
        }
        ParseError::Empty => BootstrapFailure("empty observation output".into()),
        ParseError::Malformed(reason) => BootstrapFailure(reason.into()),
    })
}

/// Swift `observeDeviceIdentity`: the exact candidate row confirmed by the
/// provider (one `Connected` row with the connect key, its identity matching
/// the adopted one when given) before the serial can be used by the
/// bracketed adoption path; the fact is the connect key itself.
pub fn observe_device_identity(
    dispatch: &dyn HdcDispatch,
    connect_key: &str,
    expected: Expected<'_>,
) -> Result<BTreeMap<String, String>, BootstrapFailure> {
    let action = Action::ObserveDevice;
    let plan = action
        .lower("observe", Some(connect_key))
        .map_err(BootstrapFailure)?;
    let receipt = dispatch.dispatch(&plan)?;
    let expected = Expected {
        connect_key: Some(connect_key),
        ..expected
    };
    summary(
        action.verify(&receipt, expected),
        "device observation could not be verified",
    )?;
    Ok(BTreeMap::from([(
        "serial".to_owned(),
        connect_key.to_owned(),
    )]))
}

/// Swift `TargetObservationCoordinator.Reading`: the candidates, bracketed
/// by the relations read before and after them.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Reading {
    pub candidates: Vec<DeviceCandidate>,
    pub before: Vec<UsbRelation>,
    pub after: Vec<UsbRelation>,
}

/// One candidate of a reading with the relation it proved, if any (Swift
/// `TargetDeviceObservation` before the owner stamps its identity).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ObservedCandidate {
    pub candidate: DeviceCandidate,
    pub relation: Option<UsbRelation>,
}

impl ObservedCandidate {
    /// Swift `continuity`.
    pub fn continuity(&self) -> &'static str {
        if self.relation.is_some() {
            "relationProven"
        } else {
            "generationScoped"
        }
    }
}

impl Reading {
    /// Swift `snapshot`'s reading: the relations, the candidates, the
    /// relations again — in that order, each failure ending the reading.
    pub fn take(
        dispatch: &dyn HdcDispatch,
        relations: &dyn UsbRelations,
    ) -> Result<Self, BootstrapFailure> {
        let before = relations.relations().map_err(BootstrapFailure)?;
        let candidates = list_candidates(dispatch)?;
        let after = relations.relations().map_err(BootstrapFailure)?;
        Ok(Self {
            candidates,
            before,
            after,
        })
    }

    /// Swift `stamp`'s bounds: at most 1000 candidates, each connect key 1 to
    /// 1024 bytes.
    pub fn validate(&self) -> Result<(), BootstrapFailure> {
        if self.candidates.len() > MAXIMUM_CANDIDATES
            || !self.candidates.iter().all(|candidate| {
                (1..=MAXIMUM_CONNECT_KEY_BYTES).contains(&candidate.connect_key.len())
            })
        {
            return Err(BootstrapFailure(
                "device snapshot exceeds its bounds".into(),
            ));
        }
        Ok(())
    }

    /// Swift `stamp`'s rows: the candidates ordered by connect key and then
    /// state (byte order), each with its relation — exactly one usable
    /// relation naming its serial before, the same after, and no other row
    /// sharing its connect key; otherwise none.
    pub fn rows(&self) -> Vec<ObservedCandidate> {
        let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
        for candidate in &self.candidates {
            *counts.entry(candidate.connect_key.as_str()).or_default() += 1;
        }
        let mut ordered: Vec<&DeviceCandidate> = self.candidates.iter().collect();
        ordered.sort_by(|left, right| {
            left.connect_key
                .as_bytes()
                .cmp(right.connect_key.as_bytes())
                .then_with(|| left.state.as_bytes().cmp(right.state.as_bytes()))
        });
        ordered
            .into_iter()
            .map(|candidate| {
                let before = usable_relations(&self.before, &candidate.connect_key);
                let after = usable_relations(&self.after, &candidate.connect_key);
                let relation = (counts[candidate.connect_key.as_str()] == 1
                    && before.len() == 1
                    && before == after)
                    .then(|| before[0].clone());
                ObservedCandidate {
                    candidate: candidate.clone(),
                    relation,
                }
            })
            .collect()
    }
}

/// Swift's `filter { $0.isUsable && $0.serial == serial }`.
pub fn usable_relations(relations: &[UsbRelation], serial: &str) -> Vec<UsbRelation> {
    relations
        .iter()
        .filter(|relation| relation.is_usable() && relation.serial == serial)
        .cloned()
        .collect()
}

/// Swift `adopt`'s final check before the store write: the live relations
/// for the serial are exactly the proved one, and the identity readback
/// names its serial. (That the snapshot still holds the same relation is
/// the owner's check over its own rows.)
pub fn adoption_holds(
    relation: &UsbRelation,
    live: &[UsbRelation],
    readback: &BTreeMap<String, String>,
) -> bool {
    usable_relations(live, &relation.serial) == [relation.clone()]
        && readback.get("serial").map(String::as_str) == Some(relation.serial.as_str())
}

/// Swift `DeviceBootstrapMachine.stableIdentitySHA256(serial:)`: the stable
/// physical identity hashes only the normalized serial — trimmed of
/// whitespace and newlines, lowercased.
pub fn stable_identity_sha256_for_serial(serial: &str) -> String {
    let normalized = serial.trim().to_lowercase();
    Sha256::digest(normalized.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Receipt;
    use std::cell::RefCell;

    const KEY: &str = "150100424a544e4600";

    fn relation(id: u64, location: &str) -> UsbRelation {
        UsbRelation {
            serial: KEY.into(),
            location: location.into(),
            attachment_id: id,
            vendor_id: ROCKUSB_VENDOR_ID,
            product_id: DAYU200_NORMAL_PRODUCT_ID,
        }
    }

    fn candidate(key: &str, state: &str) -> DeviceCandidate {
        DeviceCandidate {
            connect_key: key.into(),
            // The parser keeps the transport lowercased, as Swift's does.
            transport: "usb".into(),
            state: state.into(),
        }
    }

    /// A dispatch answering `-v` and `list targets -v` with fixed bytes.
    struct Scripted {
        version: &'static str,
        list: Vec<u8>,
        calls: RefCell<Vec<Vec<String>>>,
    }

    impl HdcDispatch for Scripted {
        fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
            self.calls.borrow_mut().push(plan.arguments.clone());
            let stdout = if plan.arguments == ["-v"] {
                format!("Ver: {}\n", self.version).into_bytes()
            } else {
                self.list.clone()
            };
            Ok(Receipt {
                exit_status: 0,
                stdout,
                stderr: Vec::new(),
                truncated: false,
                duration: Duration::from_millis(5),
            })
        }
    }

    #[test]
    fn a_usable_relation_is_swift_s_usable_relation() {
        assert!(relation(17, "100").is_usable());
        assert!(!relation(0, "100").is_usable(), "a zero attachment");
        assert!(
            !relation(17, "0100").is_usable(),
            "a location not spelled canonically"
        );
        assert!(!relation(17, "").is_usable());
        assert!(!relation(17, "-1").is_usable());
        let mut other = relation(17, "100");
        other.vendor_id = 0x18D1;
        assert!(!other.is_usable());
        other = relation(17, "100");
        other.product_id = 0x0006;
        assert!(!other.is_usable());
        other = relation(17, "100");
        other.serial = "127.0.0.1:5555".into();
        assert!(!other.is_usable(), "a network key");
        other.serial = "a b".into();
        assert!(!other.is_usable(), "a space");
        other.serial = String::new();
        assert!(!other.is_usable());
        other.serial = "x".repeat(1025);
        assert!(!other.is_usable());
        other.serial = "x".repeat(1024);
        assert!(other.is_usable());
    }

    #[test]
    fn a_relation_round_trips_through_the_oracle_s_shape() {
        let value = json!({"attachmentId": 18, "location": "100", "productId": 20480,
            "serial": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "vendorId": 8711});
        let relation = UsbRelation::from_value(&value).unwrap();
        assert_eq!(relation.attachment_id, 18);
        assert_eq!(relation.vendor_id, ROCKUSB_VENDOR_ID);
        assert_eq!(relation.product_id, DAYU200_NORMAL_PRODUCT_ID);
        assert!(relation.is_usable());
        assert_eq!(relation.to_value(), value);
        assert_eq!(UsbRelation::from_value(&json!({"serial": "x"})), None);
        assert_eq!(
            UsbRelation::from_value(&json!({"attachmentId": 1, "location": "1",
            "productId": 70000, "serial": "x", "vendorId": 1})),
            None
        );
    }

    /// The bracket rule: one usable relation naming the serial in both reads,
    /// unchanged, for a connect key no other row shares.
    #[test]
    fn a_candidate_is_proved_only_by_one_unchanged_usable_relation_in_both_reads() {
        let proved = Reading {
            candidates: vec![candidate(KEY, "Connected")],
            before: vec![relation(17, "100")],
            after: vec![relation(17, "100")],
        };
        let rows = proved.rows();
        assert_eq!(rows[0].relation, Some(relation(17, "100")));
        assert_eq!(rows[0].continuity(), "relationProven");
        let reconnected = Reading {
            after: vec![relation(18, "100")],
            ..proved.clone()
        };
        assert_eq!(
            reconnected.rows()[0].relation,
            None,
            "a new attachment between the reads"
        );
        assert_eq!(reconnected.rows()[0].continuity(), "generationScoped");
        let none = Reading {
            before: Vec::new(),
            after: Vec::new(),
            ..proved.clone()
        };
        assert_eq!(none.rows()[0].relation, None);
        let duplicate = Reading {
            candidates: vec![candidate(KEY, "Connected"), candidate(KEY, "Connected")],
            ..proved.clone()
        };
        assert!(duplicate.rows().iter().all(|row| row.relation.is_none()));
        let two = Reading {
            before: vec![relation(17, "100"), relation(18, "101")],
            after: vec![relation(17, "100"), relation(18, "101")],
            ..proved.clone()
        };
        assert_eq!(
            two.rows()[0].relation,
            None,
            "two usable relations for one serial"
        );
        let unusable = Reading {
            before: vec![relation(0, "100")],
            after: vec![relation(0, "100")],
            ..proved.clone()
        };
        assert_eq!(unusable.rows()[0].relation, None);
        let mut foreign = relation(21, "100");
        foreign.serial = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".into();
        let others = Reading {
            before: vec![foreign.clone(), relation(17, "100")],
            after: vec![relation(17, "100"), foreign],
            ..proved.clone()
        };
        assert_eq!(
            others.rows()[0].relation,
            Some(relation(17, "100")),
            "other serials do not matter"
        );
        let unauthorized = Reading {
            candidates: vec![candidate(KEY, "Unauthorized")],
            ..proved
        };
        assert_eq!(
            unauthorized.rows()[0].relation,
            Some(relation(17, "100")),
            "the state is not the proof"
        );
    }

    #[test]
    fn rows_are_ordered_by_connect_key_and_state_and_bounded() {
        let reading = Reading {
            candidates: vec![
                candidate("b", "Offline"),
                candidate("a", "Unauthorized"),
                candidate("a", "Connected"),
            ],
            before: Vec::new(),
            after: Vec::new(),
        };
        let rows: Vec<(String, String)> = reading
            .rows()
            .into_iter()
            .map(|row| (row.candidate.connect_key, row.candidate.state))
            .collect();
        assert_eq!(
            rows,
            vec![
                ("a".to_owned(), "Connected".to_owned()),
                ("a".to_owned(), "Unauthorized".to_owned()),
                ("b".to_owned(), "Offline".to_owned()),
            ]
        );
        assert!(reading.validate().is_ok());
        let long = Reading {
            candidates: vec![candidate(&"k".repeat(1025), "Connected")],
            before: Vec::new(),
            after: Vec::new(),
        };
        assert_eq!(
            long.validate().unwrap_err().0,
            "device snapshot exceeds its bounds"
        );
        let empty_key = Reading {
            candidates: vec![candidate("", "Connected")],
            before: Vec::new(),
            after: Vec::new(),
        };
        assert!(empty_key.validate().is_err());
        let many = Reading {
            candidates: (0..1001)
                .map(|index| candidate(&index.to_string(), "Connected"))
                .collect(),
            before: Vec::new(),
            after: Vec::new(),
        };
        assert!(many.validate().is_err());
    }

    #[test]
    fn adoption_holds_only_for_the_exact_live_relation_and_its_readback() {
        let proved = relation(17, "100");
        let readback = BTreeMap::from([("serial".to_owned(), KEY.to_owned())]);
        assert!(adoption_holds(
            &proved,
            std::slice::from_ref(&proved),
            &readback
        ));
        assert!(
            !adoption_holds(&proved, &[relation(19, "100")], &readback),
            "replaced in flight"
        );
        assert!(!adoption_holds(&proved, &[], &readback));
        assert!(!adoption_holds(
            &proved,
            &[proved.clone(), relation(18, "101")],
            &readback
        ));
        let mut other = readback.clone();
        other.insert("serial".into(), "bbbb".into());
        assert!(!adoption_holds(
            &proved,
            std::slice::from_ref(&proved),
            &other
        ));
        assert!(!adoption_holds(
            &proved,
            std::slice::from_ref(&proved),
            &BTreeMap::new()
        ));
        assert_eq!(
            stable_identity_sha256_for_serial("  150100424A544E4600\n"),
            stable_identity_sha256_for_serial("150100424a544e4600")
        );
        assert_eq!(
            stable_identity_sha256_for_serial("150100424a544e4600"),
            "83405c84ff74eab0b5652d35a03b094891b08e27d9d24164f57f95e1a4937ea1"
        );
    }

    /// The observation port over a scripted dispatch: the version, the list
    /// with the stand-in relations, the identity readback and its refusals.
    #[test]
    fn the_bootstrap_port_reads_the_tool_the_list_and_the_identity_through_the_dispatch() {
        let dispatch = Scripted {
            version: "3.2.0f",
            list: format!("{KEY}\t\tUSB\tConnected\tlocalhost\n").into_bytes(),
            calls: RefCell::new(Vec::new()),
        };
        assert_eq!(observe_tool_version(&dispatch).unwrap(), "3.2.0f");
        let reading = Reading::take(&dispatch, &NoUsbRelations).unwrap();
        assert_eq!(reading.candidates, vec![candidate(KEY, "Connected")]);
        assert!(reading.before.is_empty() && reading.after.is_empty());
        assert_eq!(
            reading.rows()[0].relation,
            None,
            "the stand-in proves nothing"
        );
        let live = || Ok(vec![relation(17, "100")]);
        let reading = Reading::take(&dispatch, &live).unwrap();
        assert_eq!(reading.rows()[0].relation, Some(relation(17, "100")));
        let failing = || Err("USB registry unavailable".to_owned());
        assert_eq!(
            Reading::take(&dispatch, &failing).unwrap_err().0,
            "USB registry unavailable"
        );
        let identity = observe_device_identity(&dispatch, KEY, Expected::default()).unwrap();
        assert_eq!(
            identity,
            BTreeMap::from([("serial".to_owned(), KEY.to_owned())])
        );
        assert_eq!(
            observe_device_identity(&dispatch, "other-key", Expected::default())
                .unwrap_err()
                .0,
            "targetConfirmationMismatch: expected exactly one matching target row, saw 0"
        );
        assert_eq!(
            *dispatch.calls.borrow().last().unwrap(),
            ["list", "targets", "-v"]
        );
        let empty = Scripted {
            version: "3.2.0f",
            list: b"[Empty]\r\n".to_vec(),
            calls: RefCell::new(Vec::new()),
        };
        assert_eq!(
            list_candidates(&empty).unwrap(),
            Vec::<DeviceCandidate>::new()
        );
        let nothing = Scripted {
            version: "3.2.0f",
            list: Vec::new(),
            calls: RefCell::new(Vec::new()),
        };
        assert_eq!(
            list_candidates(&nothing).unwrap_err().0,
            "empty observation output"
        );
        let garbage = Scripted {
            version: "9.9.9",
            list: vec![0xFF],
            calls: RefCell::new(Vec::new()),
        };
        assert_eq!(
            observe_tool_version(&garbage).unwrap_err().0,
            "tool version could not be verified"
        );
        assert_eq!(
            list_candidates(&garbage).unwrap_err().0,
            "invalidEncoding: stdout is not valid UTF-8"
        );
    }

    /// A census entry as the platform reads one: the DAYU200 in its
    /// HDC-normal personality, with the product name it reports.
    fn board(serial: &str, entry: u64) -> UsbHostDevice {
        UsbHostDevice {
            serial: serial.into(),
            vendor_id: ROCKUSB_VENDOR_ID,
            product_id: DAYU200_NORMAL_PRODUCT_ID,
            topology: "100".into(),
            product_name: Some("\"HDC Device\"".into()),
            registry_entry_id: Some(entry),
        }
    }

    #[test]
    fn only_the_hdc_normal_dayu200_with_an_attachment_is_a_registered_relation() {
        let named = |name: Option<&str>| UsbHostDevice {
            product_name: name.map(str::to_owned),
            ..board(KEY, 17)
        };
        for name in [
            "\"HDC Device\"",
            "HDC Device",
            " \"HDC Device\" ",
            "\"\" HDC Device \"\"",
        ] {
            assert!(is_dayu200_hdc_normal(&named(Some(name))), "{name:?}");
        }
        // Swift trims only quotes and spaces, and compares exactly.
        for name in [
            None,
            Some(""),
            Some("hdc device"),
            Some("HDC Device2"),
            Some("HDC  Device"),
            Some("'HDC Device'"),
            Some("\tHDC Device"),
        ] {
            assert!(!is_dayu200_hdc_normal(&named(name)), "{name:?}");
        }
        let loader = UsbHostDevice {
            product_id: 0x350a,
            ..board(KEY, 20)
        };
        let other = UsbHostDevice {
            vendor_id: 0x18d1,
            ..board(KEY, 21)
        };
        let detached = UsbHostDevice {
            registry_entry_id: None,
            ..board(KEY, 22)
        };
        assert!(!is_dayu200_hdc_normal(&loader));
        assert!(!is_dayu200_hdc_normal(&other));
        let foreign = UsbRelation {
            serial: "bbbb".into(),
            ..relation(18, "100")
        };
        assert_eq!(
            registered_dayu200_relations(&[
                loader,
                board("bbbb", 18),
                other,
                detached,
                named(None),
                board(KEY, 17),
                board(KEY, 17),
            ]),
            vec![foreign, relation(17, "100"), relation(17, "100")],
            "in census order; nothing is deduplicated or judged usable here"
        );
        assert_eq!(registered_dayu200_relations(&[]), Vec::<UsbRelation>::new());
    }

    /// The registry reader through the reading's bracket: what one census
    /// holds unchanged in both reads proves the candidate; a replug, a second
    /// board with the serial, a board gone or never usable proves nothing;
    /// and a census that cannot be taken fails the reading in Swift's words.
    #[test]
    fn the_registry_reader_proves_only_an_unchanged_unique_board_and_fails_closed() {
        use std::cell::Cell;
        let dispatch = Scripted {
            version: "3.2.0f",
            list: format!("{KEY}\t\tUSB\tConnected\tlocalhost\n").into_bytes(),
            calls: RefCell::new(Vec::new()),
        };
        let proved = |census: &dyn UsbRelations| {
            Reading::take(&dispatch, census).unwrap().rows()[0]
                .relation
                .clone()
        };
        assert_eq!(
            proved(&UsbRegistryRelations::new(|| Ok(vec![board(KEY, 17)]))),
            Some(relation(17, "100"))
        );
        let reads = Cell::new(0_u64);
        let read = || {
            reads.set(reads.get() + 1);
            reads.get()
        };
        assert_eq!(
            proved(&UsbRegistryRelations::new(|| Ok(vec![board(
                KEY,
                16 + read()
            )]))),
            None,
            "a new attachment between the reads"
        );
        reads.set(0);
        assert_eq!(
            proved(&UsbRegistryRelations::new(|| {
                Ok(if read() == 1 {
                    vec![board(KEY, 17)]
                } else {
                    Vec::new()
                })
            })),
            None,
            "gone before the second read"
        );
        for census in [
            vec![board(KEY, 17), board(KEY, 18)],
            vec![UsbHostDevice {
                registry_entry_id: None,
                ..board(KEY, 17)
            }],
            vec![UsbHostDevice {
                product_id: 0x350a,
                ..board(KEY, 17)
            }],
            vec![UsbHostDevice {
                topology: "0100".into(),
                ..board(KEY, 17)
            }],
            vec![board("bbbb", 17)],
            Vec::new(),
        ] {
            let reader = UsbRegistryRelations::new(|| Ok(census.clone()));
            assert_eq!(proved(&reader), None, "{census:?}");
        }
        for cause in [
            RegistryUnavailable::Matching,
            RegistryUnavailable::Services(-536_870_212),
            RegistryUnavailable::Invalidated,
        ] {
            let failing = UsbRegistryRelations::new(move || Err(cause));
            assert_eq!(
                Reading::take(&dispatch, &failing).unwrap_err().0,
                "admissionRejected(\"USB registry unavailable\")",
                "{cause:?}"
            );
            reads.set(0);
            let second = UsbRegistryRelations::new(|| {
                if read() == 1 {
                    Ok(vec![board(KEY, 17)])
                } else {
                    Err(cause)
                }
            });
            assert_eq!(
                Reading::take(&dispatch, &second).unwrap_err().0,
                "admissionRejected(\"USB registry unavailable\")",
                "the second read of {cause:?}"
            );
        }
        // The adoption's final check reads the same census.
        let live = UsbRegistryRelations::new(|| Ok(vec![board(KEY, 17)]))
            .relations()
            .unwrap();
        let readback = BTreeMap::from([("serial".to_owned(), KEY.to_owned())]);
        assert!(adoption_holds(&relation(17, "100"), &live, &readback));
        assert!(!adoption_holds(&relation(18, "100"), &live, &readback));
    }
}
