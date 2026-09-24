//! ArkForge's half of Swift's dual-source Loader observation
//! (`ProductArkForgeLoaderObserver.confirmLoader`) and the join it rests on
//! (`ArkForgeObservationSelection`): once the host's own USB census has named
//! the bound Loader and its port, ArkForge's independently enumerated
//! `discoverDevices` must hold exactly one observation at that port, and it
//! must be a settled DAYU200 RockUSB Loader. Neither source alone is enough:
//! the census alone would lose the provider's mode observation, ArkForge alone
//! the Runtime's bound identity.
//!
//! Read-only: one public session per confirmation, no execution surface.

use crate::device_access::discover;
use arkdeck_contract::sha256_hex;
use arkforge_client::DeviceObservationView;
use std::path::Path;
use std::time::Duration;

/// Swift's bound on the public session a confirmation opens.
pub const LOADER_OBSERVATION_TIMEOUT: Duration = Duration::from_secs(15);

/// The domain prefix of `arkforge-transport::UsbDeviceRecord::topology_digest`,
/// its trailing NUL included.
const DEVICE_FACTS_DOMAIN: &[u8] = b"arkforge/v1/device-facts\0";

/// Foundation's `CharacterSet.whitespaces`: the space separators and the tab.
fn swift_whitespace(character: char) -> bool {
    character == '\t'
        || (character.is_whitespace()
            && !matches!(
                character,
                '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
            ))
}

/// Swift `ArkForgeObservationSelection.topologyDigest`: the digest the daemon
/// derives for a USB location id, `SHA-256(domain || locationID_be32)`; `None`
/// when the topology is not a number that fits one.
pub fn topology_digest(usb_topology: &str) -> Option<String> {
    let location: u32 = usb_topology.trim_matches(swift_whitespace).parse().ok()?;
    let mut preimage = DEVICE_FACTS_DOMAIN.to_vec();
    preimage.extend_from_slice(&location.to_be_bytes());
    Some(sha256_hex(&preimage))
}

/// Swift `ArkForgeObservationSelection.SelectionFailure`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SelectionFailure {
    UnusableTopology(String),
    NoObservationForBoundDevice {
        topology: String,
        observed: Vec<String>,
    },
    Ambiguous {
        topology: String,
        matches: Vec<String>,
    },
}

impl std::fmt::Display for SelectionFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnusableTopology(raw) => write!(
                f,
                "the bound device's usbTopology {}, which is not a USB location id; without it \
                 there is no way to tell the daemon which board this job is about",
                if raw.is_empty() {
                    "is empty".to_owned()
                } else {
                    format!("is {raw}")
                }
            ),
            Self::NoObservationForBoundDevice { topology, observed } => write!(
                f,
                "the daemon sees no device at the port this job is bound to ({topology}); it \
                 observed {}. Nothing was materialized — a plan built against a device the \
                 daemon cannot see is a plan for some other board",
                if observed.is_empty() {
                    "nothing".to_owned()
                } else {
                    observed.join(", ")
                }
            ),
            Self::Ambiguous { topology, matches } => write!(
                f,
                "{} observations claim port {topology}: {}. Refusing rather than picking one, \
                 because the tie is between candidates for a destructive write",
                matches.len(),
                matches.join(", ")
            ),
        }
    }
}

/// Swift `ArkForgeObservationSelection.select`: exactly one observation at the
/// bound port, never "the first".
pub fn select<'a>(
    observations: &'a [DeviceObservationView],
    usb_topology: &str,
) -> Result<&'a DeviceObservationView, SelectionFailure> {
    let Some(wanted) = topology_digest(usb_topology) else {
        return Err(SelectionFailure::UnusableTopology(usb_topology.to_owned()));
    };
    let matches: Vec<&DeviceObservationView> = observations
        .iter()
        .filter(|observation| observation.topology_sha256.to_lowercase() == wanted)
        .collect();
    match matches.as_slice() {
        [single] => Ok(single),
        [] => Err(SelectionFailure::NoObservationForBoundDevice {
            topology: usb_topology.to_owned(),
            observed: observations
                .iter()
                .map(|observation| observation.observation_id.clone())
                .collect(),
        }),
        _ => Err(SelectionFailure::Ambiguous {
            topology: usb_topology.to_owned(),
            matches: matches
                .iter()
                .map(|observation| observation.observation_id.clone())
                .collect(),
        }),
    }
}

/// Swift's checks of the selected observation: a settled DAYU200 RockUSB
/// Loader, identified by serial and topology, with a well-formed descriptor.
pub fn usable_loader(observation: &DeviceObservationView) -> Result<(), String> {
    let refuse = |detail: String| {
        Err(format!(
            "arkforged returned an unusable Loader observation: {detail}"
        ))
    };
    if observation.mode != "rockusb-loader" {
        return refuse(format!(
            "mode is {}, expected rockusb-loader",
            observation.mode
        ));
    }
    if observation.identity_strength != "serialAndTopology" {
        return refuse(format!(
            "identity strength is {}, expected serialAndTopology",
            observation.identity_strength
        ));
    }
    if observation.malformed_descriptor {
        return refuse("the USB descriptor is marked malformed".to_owned());
    }
    // Swift reads the identity pairs into a dictionary: the last one wins.
    let identity = observation
        .protocol_identity
        .iter()
        .rev()
        .find(|pair| pair.key == "usb.identity")
        .map(|pair| pair.value.as_str());
    if identity != Some("0x2207:0x350a") {
        return refuse("USB class is not the registered DAYU200 Loader".to_owned());
    }
    Ok(())
}

/// ArkForge's half of Swift `ProductArkForgeLoaderObserver.confirmLoader`,
/// once the census has named the bound Loader at `usb_topology`: one public
/// session to the lane daemon in `runtime_directory`, the one observation at
/// that port, and its checks. The refusals are Swift's words.
pub fn confirm_loader(
    runtime_directory: &Path,
    timeout: Duration,
    usb_topology: &str,
) -> Result<(), String> {
    let observations = discover(runtime_directory, timeout)
        .map_err(|error| format!("arkforged discoverDevices is unavailable: {error}"))?;
    let observation = select(&observations, usb_topology).map_err(|failure| {
        format!("arkforged did not uniquely observe the bound Loader: {failure}")
    })?;
    usable_loader(observation)
}

#[cfg(test)]
mod tests {
    use super::*;
    use arkforge_ipc::messages::KeyValue;

    fn observation(id: &str, topology: &str) -> DeviceObservationView {
        DeviceObservationView {
            observation_id: id.into(),
            mode: "rockusb-loader".into(),
            topology_sha256: topology_digest(topology).unwrap(),
            identity_strength: "serialAndTopology".into(),
            protocol_identity: vec![KeyValue {
                key: "usb.identity".into(),
                value: "0x2207:0x350a".into(),
            }],
            ..DeviceObservationView::default()
        }
    }

    /// The published rule, checked against its own statement: the domain
    /// with its NUL, then the location id big-endian — and Swift's reading of
    /// the topology text around it.
    #[test]
    fn the_topology_digest_is_the_daemons_rule() {
        let mut preimage = b"arkforge/v1/device-facts\0".to_vec();
        preimage.extend_from_slice(&[0x01, 0x20, 0x00, 0x00]);
        assert_eq!(topology_digest("18874368"), Some(sha256_hex(&preimage)));
        assert_eq!(topology_digest(" 18874368\t"), topology_digest("18874368"));
        for unusable in ["", "loader", "4294967296", "-1", "18874368\n", "0x01200000"] {
            assert_eq!(topology_digest(unusable), None, "{unusable:?}");
        }
    }

    #[test]
    fn exactly_one_observation_at_the_bound_port_is_selected() {
        let loader = observation("USB-2207-350A-01200000", "18874368");
        let other = observation("USB-2207-5000-01300000", "19922944");
        let observations = [other.clone(), loader.clone()];
        assert_eq!(select(&observations, "18874368"), Ok(&loader));
        assert_eq!(
            select(&observations, "20000000").unwrap_err().to_string(),
            "the daemon sees no device at the port this job is bound to (20000000); it \
             observed USB-2207-5000-01300000, USB-2207-350A-01200000. Nothing was \
             materialized — a plan built against a device the daemon cannot see is a plan \
             for some other board"
        );
        assert_eq!(
            select(&[], "20000000").unwrap_err().to_string(),
            "the daemon sees no device at the port this job is bound to (20000000); it \
             observed nothing. Nothing was materialized — a plan built against a device the \
             daemon cannot see is a plan for some other board"
        );
        let twice = [loader.clone(), loader.clone()];
        assert_eq!(
            select(&twice, "18874368").unwrap_err(),
            SelectionFailure::Ambiguous {
                topology: "18874368".into(),
                matches: vec![loader.observation_id.clone(), loader.observation_id.clone()],
            }
        );
        assert_eq!(
            select(&observations, "").unwrap_err().to_string(),
            "the bound device's usbTopology is empty, which is not a USB location id; \
             without it there is no way to tell the daemon which board this job is about"
        );
        // The daemon's digest is compared without regard to its case.
        let mut upper = loader.clone();
        upper.topology_sha256 = upper.topology_sha256.to_uppercase();
        assert_eq!(select(std::slice::from_ref(&upper), "18874368"), Ok(&upper));
    }

    #[test]
    fn only_a_settled_dayu200_loader_is_usable() {
        let loader = observation("USB-2207-350A-01200000", "18874368");
        assert_eq!(usable_loader(&loader), Ok(()));
        let refused = |change: fn(&mut DeviceObservationView)| {
            let mut observation = loader.clone();
            change(&mut observation);
            usable_loader(&observation).unwrap_err()
        };
        assert_eq!(
            refused(|o| o.mode = "hdc-normal".into()),
            "arkforged returned an unusable Loader observation: mode is hdc-normal, expected \
             rockusb-loader"
        );
        assert_eq!(
            refused(|o| o.identity_strength = "topologyOnly".into()),
            "arkforged returned an unusable Loader observation: identity strength is \
             topologyOnly, expected serialAndTopology"
        );
        assert_eq!(
            refused(|o| o.malformed_descriptor = true),
            "arkforged returned an unusable Loader observation: the USB descriptor is marked \
             malformed"
        );
        assert_eq!(
            refused(|o| o.protocol_identity.clear()),
            "arkforged returned an unusable Loader observation: USB class is not the \
             registered DAYU200 Loader"
        );
        // The last pair of a key is the one read, as Swift's dictionary keeps it.
        assert!(
            refused(|o| o.protocol_identity.push(KeyValue {
                key: "usb.identity".into(),
                value: "0x2207:0x5000".into(),
            }))
            .ends_with("USB class is not the registered DAYU200 Loader")
        );
    }
}
