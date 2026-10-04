//! The Runtime's own read-only USB device census on Windows, from the
//! Plug and Play device tree: the counterpart of the macOS I/O Registry census
//! ([`crate::usb_registry`]), producing the same [`UsbHostDevice`] shape, from
//! which the HDC provider's `UsbRegistryRelations` proves a target
//! observation's USB relation (TASK-XPA-004).
//!
//! A census asks SetupAPI for the present device nodes of the `USB`
//! enumerator (`SetupDiGetClassDevsW` with `DIGCF_PRESENT | DIGCF_ALLCLASSES`)
//! and reads each node's instance ID (`CM_Get_Device_IDW`) and a few of its
//! device properties (`SetupDiGetDevicePropertyW`). It opens no device or
//! interface, sends no USB request, installs or changes no driver, needs no
//! elevation, and writes nothing. The device information set is destroyed on
//! every path.
//!
//! [`UsbHostDevice::from_device_node`] is the per-node rule, failing closed as
//! macOS's per-entry rule does: a node that is not present, or without both
//! numbers, a topology and a serial, is no identity and is passed over; a
//! property of an unexpected type counts as absent; the product name is
//! optional; the attachment is absent when the node answers none or zero.
//!
//! # The confirmed property choice
//!
//! Which Windows property carries which census field is the mapping of
//! CHG-2026-078 design §4 (TASK-WHR-003, the Windows profile's USB census
//! row), confirmed by the maintainer's DAYU200 USB-properties sample of
//! 2026-10-04
//! (`evidence/runs/TASK-XPA-004/dayu200-usb-properties-20261004-run.md`) and
//! maintainer ruling 2026-10-04, items 4 and 5. It is written down once, in
//! [`CENSUS_MAPPING`], and the rule implementing it is
//! [`UsbHostDevice::from_device_node`] together with [`NodeProperty`].
//! [`usb_host_devices`] (the census a USB relation is proved from) opens only
//! while every row is `Confirmed`; a row set back to `TBD(sample)` closes it
//! again with [`crate::RegistryUnavailable::MappingUnconfirmed`].
//!
//! | census field | Windows source |
//! | --- | --- |
//! | the entry | a **present** (`DEVPKEY_Device_IsPresent`, besides `DIGCF_PRESENT`) device-level node `USB\VID_hhhh&PID_hhhh\<suffix>` (no `&MI_xx` interface node); a phantom node keeps its last attachment's properties and is never an entry |
//! | vendor, product | `DEVPKEY_Device_HardwareIds`, the first `USB\VID_hhhh&PID_hhhh…` entry, which must name the same numbers as the instance ID |
//! | serial | the instance ID's third segment, **ASCII-lowercase folded** (the instance ID spells the device's serial in upper case, the HDC connect key is lower case); a suffix holding `&` is a Windows-generated, port-derived ID: **no serial, no identity, the node is passed over** |
//! | topology | the first `DEVPKEY_Device_LocationPaths` entry, as the decimal of the first eight bytes (big-endian) of its UTF-8 SHA-256 (see below) |
//! | product name | `DEVPKEY_Device_BusReportedDeviceDesc` (the device's own iProduct; `FriendlyName`/`DeviceDesc` come from the driver INF) |
//! | attachment | `DEVPKEY_Device_LastArrivalDate` (a `FILETIME`, new on every arrival, fixed within one) |
//!
//! One attachment is the pair (instance ID, `LastArrivalDate`): the instance
//! ID (and `PDOName`) repeats across attachments, so neither names one alone.
//! A relation carries the pair as its vendor, product and folded serial (the
//! instance ID) with its attachment ID (the arrival), and two reads agree only
//! when the whole pair does. The long-term device identity is the folded
//! serial alone (`stable_identity_sha256_for_serial`, which lower-cases too).
//!
//! The topology is a Windows-only spelling: Windows has no packed 32-bit
//! `locationID`, and the relation rule accepts only a canonical decimal
//! location. It is never byte-equal to a macOS topology, and it is **valid
//! only within one attachment**: the sample's board moved from `USB(10)`
//! (`HS10`, USB 2) to `USB(26)` (`SS10`, USB 3) when replugged into the same
//! physical connector. It is never part of the long-term identity: such a
//! replug is the same device identity in a new attachment.
use crate::usb_registry::UsbHostDevice;
use sha2::{Digest, Sha256};

/// Whether the processed DAYU200 USB sample has confirmed a census field's
/// Windows source.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CensusSample {
    /// `TBD(sample)`: not yet confirmed; the trusted census fails closed.
    Tbd,
    /// Confirmed by the processed sample (name the record when setting it).
    Confirmed,
}

/// One census field of CHG-2026-078 design §4: the macOS `UsbHostDevice`
/// field, its Windows source, and the sample's verdict on it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CensusField {
    pub field: &'static str,
    pub source: &'static str,
    pub sample: CensusSample,
}

/// CHG-2026-078 design §4, the Windows USB relation census mapping, in the
/// one place it is decided. Every row is confirmed by the DAYU200 USB sample of
/// 2026-10-04 (`dayu200-usb-properties-20261004-run.md`) and maintainer ruling
/// 2026-10-04, items 4 and 5; the trusted census opens only while every row is.
pub const CENSUS_MAPPING: [CensusField; 6] = [
    CensusField {
        field: "device",
        source: "a present (DEVPKEY_Device_IsPresent) device-level node USB\\VID_hhhh&PID_hhhh\\<suffix>, never an &MI_xx interface node or a phantom",
        sample: CensusSample::Confirmed,
    },
    CensusField {
        field: "vendorId/productId",
        source: "the first USB\\VID_hhhh&PID_hhhh entry of DEVPKEY_Device_HardwareIds, equal to the instance ID's",
        sample: CensusSample::Confirmed,
    },
    CensusField {
        field: "serial",
        source: "the instance ID's third segment, ASCII-lowercase folded; a suffix holding & is port-derived: no serial, no identity",
        sample: CensusSample::Confirmed,
    },
    CensusField {
        field: "topology",
        source: "the first DEVPKEY_Device_LocationPaths entry, hashed (ruling 11); valid only within one attachment",
        sample: CensusSample::Confirmed,
    },
    CensusField {
        field: "productName",
        source: "DEVPKEY_Device_BusReportedDeviceDesc",
        sample: CensusSample::Confirmed,
    },
    CensusField {
        field: "attachment",
        source: "DEVPKEY_Device_LastArrivalDate, with the instance ID: one attachment is the pair",
        sample: CensusSample::Confirmed,
    },
];

/// The census fields the sample has not confirmed yet, in mapping order.
pub fn unconfirmed_census_fields() -> Vec<&'static str> {
    unconfirmed(&CENSUS_MAPPING)
}

fn unconfirmed(mapping: &[CensusField]) -> Vec<&'static str> {
    mapping
        .iter()
        .filter(|row| row.sample == CensusSample::Tbd)
        .map(|row| row.field)
        .collect()
}

/// A device property the Windows census reads. The `DEVPKEY` each one names is
/// part of the confirmed property choice (module documentation).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NodeProperty {
    /// `DEVPKEY_Device_IsPresent`: a boolean.
    IsPresent,
    /// `DEVPKEY_Device_HardwareIds`: a string list.
    HardwareIds,
    /// `DEVPKEY_Device_LocationPaths`: a string list.
    LocationPaths,
    /// `DEVPKEY_Device_BusReportedDeviceDesc`: a string.
    BusReportedDeviceDesc,
    /// `DEVPKEY_Device_LastArrivalDate`: a `FILETIME`.
    LastArrivalDate,
}

/// A device property as the census reads it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NodeValue {
    /// `DEVPROP_TYPE_STRING`, decoded from UTF-16 with U+FFFD for an unpaired
    /// surrogate.
    Text(String),
    /// `DEVPROP_TYPE_STRING_LIST`, each string decoded as [`NodeValue::Text`].
    TextList(Vec<String>),
    /// `DEVPROP_TYPE_FILETIME`, as its 64-bit count of 100 ns intervals.
    FileTime(u64),
    /// `DEVPROP_TYPE_BOOLEAN`: `DEVPROP_TRUE` or `DEVPROP_FALSE` (any other
    /// byte is [`NodeValue::Other`]).
    Boolean(bool),
    /// Any other property type.
    Other,
}

/// One device node a census holds while it reads it.
pub trait DeviceNode {
    /// The node's device instance ID, if Plug and Play answers one.
    fn instance_id(&self) -> Option<String>;
    /// The property `key`, if the node has one.
    fn property(&self, key: NodeProperty) -> Option<NodeValue>;
}

impl UsbHostDevice {
    /// The Windows per-node rule, or `None` for a node the census passes over.
    /// The confirmed property choice: see the module documentation.
    pub fn from_device_node<N: DeviceNode + ?Sized>(node: &N) -> Option<Self> {
        let list = |key| match node.property(key) {
            Some(NodeValue::TextList(values)) => Some(values),
            _ => None,
        };
        // Present nodes only: a phantom keeps its last attachment's
        // properties. A node that does not answer `true` is passed over.
        if node.property(NodeProperty::IsPresent) != Some(NodeValue::Boolean(true)) {
            return None;
        }
        let instance_id = node.instance_id()?;
        let (vendor_id, product_id, serial) = device_instance(&instance_id)?;
        // The bus-reported hardware ID must name the numbers the instance ID
        // names; a node whose two disagree is no identity.
        let hardware = list(NodeProperty::HardwareIds)?
            .iter()
            .find_map(|id| usb_numbers(id.strip_prefix_ignore_case("USB\\")?))?;
        if hardware != (vendor_id, product_id) {
            return None;
        }
        let location = list(NodeProperty::LocationPaths)?
            .into_iter()
            .find(|path| !path.is_empty())?;
        let product_name = match node.property(NodeProperty::BusReportedDeviceDesc) {
            Some(NodeValue::Text(name)) => Some(name),
            _ => None,
        };
        let registry_entry_id = match node.property(NodeProperty::LastArrivalDate) {
            Some(NodeValue::FileTime(time)) if time != 0 => Some(time),
            _ => None,
        };
        Some(Self {
            serial,
            vendor_id,
            product_id,
            topology: location_topology(&location),
            product_name,
            registry_entry_id,
        })
    }
}

/// A device-level USB instance ID, `USB\VID_hhhh&PID_hhhh\<serial>`: its
/// numbers and its serial, ASCII-lowercase folded (maintainer ruling
/// 2026-10-04, item 4: the instance ID spells the serial in upper case, the
/// HDC connect key in lower case). An interface node (`…&MI_xx`), another
/// enumerator, a malformed ID and a Windows-generated, port-derived suffix
/// (one holding `&`) are `None`: no serial, no identity.
fn device_instance(instance_id: &str) -> Option<(u16, u16, String)> {
    let mut segments = instance_id.split('\\');
    let (enumerator, device, suffix) = (segments.next()?, segments.next()?, segments.next()?);
    if segments.next().is_some()
        || !enumerator.eq_ignore_ascii_case("USB")
        || device.len() != "VID_hhhh&PID_hhhh".len()
        || suffix.is_empty()
        || suffix.contains('&')
    {
        return None;
    }
    let (vendor, product) = usb_numbers(device)?;
    Some((vendor, product, suffix.to_ascii_lowercase()))
}

/// `VID_hhhh&PID_hhhh`, optionally followed by `&…` (a hardware ID's
/// `&REV_hhhh`), case-insensitively.
fn usb_numbers(text: &str) -> Option<(u16, u16)> {
    let hex = |digits: &str| {
        (digits.len() == 4 && digits.bytes().all(|byte| byte.is_ascii_hexdigit()))
            .then(|| u16::from_str_radix(digits, 16).ok())
            .flatten()
    };
    let rest = text.strip_prefix_ignore_case("VID_")?;
    let vendor = hex(rest.get(..4)?)?;
    let rest = rest.get(4..)?.strip_prefix_ignore_case("&PID_")?;
    let product = hex(rest.get(..4)?)?;
    let rest = rest.get(4..)?;
    (rest.is_empty() || rest.starts_with('&')).then_some((vendor, product))
}

/// The topology of one location path: the decimal of the first eight bytes,
/// big-endian, of the SHA-256 of its UTF-8 (ruling 11). Valid only within one
/// attachment (module documentation).
fn location_topology(location: &str) -> String {
    let digest = Sha256::digest(location.as_bytes());
    let mut first = [0_u8; 8];
    first.copy_from_slice(&digest[..8]);
    u64::from_be_bytes(first).to_string()
}

trait StripPrefixIgnoreCase {
    fn strip_prefix_ignore_case(&self, prefix: &str) -> Option<&str>;
}

impl StripPrefixIgnoreCase for str {
    fn strip_prefix_ignore_case(&self, prefix: &str) -> Option<&str> {
        let head = self.get(..prefix.len())?;
        head.eq_ignore_ascii_case(prefix)
            .then(|| &self[prefix.len()..])
    }
}

/// The census a USB relation is proved from: every device-level USB identity
/// present on the host ([`usb_device_node_census`]), while every field of
/// [`CENSUS_MAPPING`] is confirmed (as it is since the 2026-10-04 sample);
/// otherwise it fails closed with
/// [`crate::RegistryUnavailable::MappingUnconfirmed`] and reads nothing.
#[cfg(windows)]
pub fn usb_host_devices() -> Result<Vec<UsbHostDevice>, crate::RegistryUnavailable> {
    if !unconfirmed_census_fields().is_empty() {
        return Err(crate::RegistryUnavailable::MappingUnconfirmed);
    }
    usb_device_node_census()
}

/// Every device-level USB identity present on the host by the per-node rule,
/// in device information set order: nodes the rule passes over are not
/// listed, and nothing is deduplicated. Read-only: see the module
/// documentation. A relation source only through [`usb_host_devices`], which
/// holds the mapping gate.
#[cfg(windows)]
pub fn usb_device_node_census() -> Result<Vec<UsbHostDevice>, crate::RegistryUnavailable> {
    setupapi::census(|node| UsbHostDevice::from_device_node(node))
}

#[cfg(windows)]
mod setupapi {
    use super::{DeviceNode, NodeProperty, NodeValue};
    use crate::RegistryUnavailable;
    use windows_sys::Win32::Devices::DeviceAndDriverInstallation::{
        CM_Get_Device_IDW, CR_SUCCESS, DIGCF_ALLCLASSES, DIGCF_PRESENT, HDEVINFO,
        MAX_DEVICE_ID_LEN, SP_DEVINFO_DATA, SetupDiDestroyDeviceInfoList, SetupDiEnumDeviceInfo,
        SetupDiGetClassDevsW, SetupDiGetDevicePropertyW,
    };
    use windows_sys::Win32::Devices::Properties::{
        DEVPKEY_Device_BusReportedDeviceDesc, DEVPKEY_Device_HardwareIds, DEVPKEY_Device_IsPresent,
        DEVPKEY_Device_LastArrivalDate, DEVPKEY_Device_LocationPaths, DEVPROP_FALSE, DEVPROP_TRUE,
        DEVPROP_TYPE_BOOLEAN, DEVPROP_TYPE_FILETIME, DEVPROP_TYPE_STRING, DEVPROP_TYPE_STRING_LIST,
        DEVPROPTYPE,
    };
    use windows_sys::Win32::Foundation::{
        DEVPROPKEY, ERROR_INSUFFICIENT_BUFFER, ERROR_NO_MORE_ITEMS, GetLastError,
        INVALID_HANDLE_VALUE,
    };

    /// A property value larger than this is not one the census reads.
    const MAXIMUM_PROPERTY_BYTES: u32 = 64 * 1024;

    /// A device information set, destroyed once when dropped.
    struct DeviceSet(HDEVINFO);

    impl Drop for DeviceSet {
        fn drop(&mut self) {
            // SAFETY: a set this census created and destroys once.
            unsafe { SetupDiDestroyDeviceInfoList(self.0) };
        }
    }

    /// One member of the set, read while the set is held.
    struct Node<'a> {
        set: &'a DeviceSet,
        data: SP_DEVINFO_DATA,
    }

    fn key(property: NodeProperty) -> &'static DEVPROPKEY {
        match property {
            NodeProperty::IsPresent => &DEVPKEY_Device_IsPresent,
            NodeProperty::HardwareIds => &DEVPKEY_Device_HardwareIds,
            NodeProperty::LocationPaths => &DEVPKEY_Device_LocationPaths,
            NodeProperty::BusReportedDeviceDesc => &DEVPKEY_Device_BusReportedDeviceDesc,
            NodeProperty::LastArrivalDate => &DEVPKEY_Device_LastArrivalDate,
        }
    }

    impl DeviceNode for Node<'_> {
        fn instance_id(&self) -> Option<String> {
            let mut buffer = [0_u16; MAX_DEVICE_ID_LEN as usize + 1];
            // SAFETY: a devnode of the held set and a live buffer of the
            // length passed; the ID is nul-terminated within it.
            let status = unsafe {
                CM_Get_Device_IDW(
                    self.data.DevInst,
                    buffer.as_mut_ptr(),
                    buffer.len() as u32,
                    0,
                )
            };
            if status != CR_SUCCESS {
                return None;
            }
            let length = buffer.iter().position(|unit| *unit == 0)?;
            Some(String::from_utf16_lossy(&buffer[..length]))
        }

        fn property(&self, property: NodeProperty) -> Option<NodeValue> {
            let mut kind: DEVPROPTYPE = 0;
            let mut required = 0_u32;
            // SAFETY: a member of the held set and live outputs; a null
            // buffer of size zero only asks for the size.
            let answered = unsafe {
                SetupDiGetDevicePropertyW(
                    self.set.0,
                    &self.data,
                    key(property),
                    &mut kind,
                    std::ptr::null_mut(),
                    0,
                    &mut required,
                    0,
                )
            };
            // SAFETY: reads the calling thread's last error.
            if answered != 0 || unsafe { GetLastError() } != ERROR_INSUFFICIENT_BUFFER {
                return None;
            }
            if required == 0 || required > MAXIMUM_PROPERTY_BYTES {
                return None;
            }
            // `u16` units keep the buffer aligned for the UTF-16 it holds.
            let mut units = vec![0_u16; (required as usize).div_ceil(2)];
            // SAFETY: as above, with a live buffer of at least `required`
            // bytes.
            let answered = unsafe {
                SetupDiGetDevicePropertyW(
                    self.set.0,
                    &self.data,
                    key(property),
                    &mut kind,
                    units.as_mut_ptr().cast(),
                    required,
                    &mut required,
                    0,
                )
            };
            if answered == 0 {
                return None;
            }
            let bytes = required as usize;
            Some(match kind {
                DEVPROP_TYPE_STRING => {
                    NodeValue::Text(text(&units[..bytes / 2]).next().unwrap_or_default())
                }
                DEVPROP_TYPE_STRING_LIST => {
                    NodeValue::TextList(text(&units[..bytes / 2]).collect())
                }
                DEVPROP_TYPE_FILETIME if bytes == 8 => {
                    let mut time = [0_u8; 8];
                    for (index, unit) in units[..4].iter().enumerate() {
                        time[index * 2..index * 2 + 2].copy_from_slice(&unit.to_ne_bytes());
                    }
                    NodeValue::FileTime(u64::from_ne_bytes(time))
                }
                DEVPROP_TYPE_BOOLEAN if bytes == 1 => match units[0].to_ne_bytes()[0] {
                    DEVPROP_TRUE => NodeValue::Boolean(true),
                    DEVPROP_FALSE => NodeValue::Boolean(false),
                    _ => NodeValue::Other,
                },
                _ => NodeValue::Other,
            })
        }
    }

    /// The nul-separated strings of a UTF-16 value, up to its first empty
    /// string (a list's terminator).
    fn text(units: &[u16]) -> impl Iterator<Item = String> + '_ {
        units
            .split(|unit| *unit == 0)
            .take_while(|part| !part.is_empty())
            .map(String::from_utf16_lossy)
    }

    pub(super) fn census<T>(
        mut read: impl FnMut(&dyn DeviceNode) -> Option<T>,
    ) -> Result<Vec<T>, RegistryUnavailable> {
        let enumerator: Vec<u16> = "USB\0".encode_utf16().collect();
        // SAFETY: a nul-terminated enumerator and no class or window; the
        // set it returns is destroyed by its guard.
        let set = unsafe {
            SetupDiGetClassDevsW(
                std::ptr::null(),
                enumerator.as_ptr(),
                std::ptr::null_mut(),
                DIGCF_PRESENT | DIGCF_ALLCLASSES,
            )
        };
        if set == INVALID_HANDLE_VALUE as HDEVINFO {
            // SAFETY: reads the calling thread's last error.
            return Err(RegistryUnavailable::DeviceSet(unsafe { GetLastError() }));
        }
        let set = DeviceSet(set);
        let mut found = Vec::new();
        for index in 0.. {
            let mut data = SP_DEVINFO_DATA {
                cbSize: size_of::<SP_DEVINFO_DATA>() as u32,
                ..Default::default()
            };
            // SAFETY: the held set and a live, sized output.
            if unsafe { SetupDiEnumDeviceInfo(set.0, index, &mut data) } == 0 {
                // SAFETY: reads the calling thread's last error.
                return match unsafe { GetLastError() } {
                    ERROR_NO_MORE_ITEMS => Ok(found),
                    // An enumeration that stopped early may be short: the
                    // census is unavailable rather than a shorter list.
                    error => Err(RegistryUnavailable::Enumeration(error)),
                };
            }
            if let Some(value) = read(&Node { set: &set, data }) {
                found.push(value);
            }
        }
        Err(RegistryUnavailable::Enumeration(0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    /// A device node of an instance ID and named properties.
    #[derive(Clone)]
    struct Node {
        instance_id: Option<String>,
        properties: BTreeMap<&'static str, NodeValue>,
    }

    fn name(key: NodeProperty) -> &'static str {
        match key {
            NodeProperty::IsPresent => "IsPresent",
            NodeProperty::HardwareIds => "HardwareIds",
            NodeProperty::LocationPaths => "LocationPaths",
            NodeProperty::BusReportedDeviceDesc => "BusReportedDeviceDesc",
            NodeProperty::LastArrivalDate => "LastArrivalDate",
        }
    }

    impl DeviceNode for Node {
        fn instance_id(&self) -> Option<String> {
            self.instance_id.clone()
        }

        fn property(&self, key: NodeProperty) -> Option<NodeValue> {
            self.properties.get(name(key)).cloned()
        }
    }

    impl Node {
        fn with(mut self, key: NodeProperty, value: Option<NodeValue>) -> Self {
            match value {
                Some(value) => self.properties.insert(name(key), value),
                None => self.properties.remove(name(key)),
            };
            self
        }

        fn id(self, instance_id: Option<&str>) -> Self {
            Self {
                instance_id: instance_id.map(str::to_owned),
                ..self
            }
        }
    }

    const SERIAL: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const LOCATION: &str = "PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(3)";

    fn list(values: &[&str]) -> Option<NodeValue> {
        Some(NodeValue::TextList(
            values.iter().map(|value| (*value).to_owned()).collect(),
        ))
    }

    /// A DAYU200 in its HDC-normal personality as a synthetic device node.
    fn board() -> Node {
        Node {
            instance_id: None,
            properties: BTreeMap::new(),
        }
        .id(Some(&format!("USB\\VID_2207&PID_5000\\{SERIAL}")))
        .with(NodeProperty::IsPresent, Some(NodeValue::Boolean(true)))
        .with(
            NodeProperty::HardwareIds,
            list(&["USB\\VID_2207&PID_5000&REV_0223", "USB\\VID_2207&PID_5000"]),
        )
        .with(
            NodeProperty::LocationPaths,
            list(&[
                LOCATION,
                "ACPI(_SB_)#ACPI(PCI0)#ACPI(XHCI)#ACPI(RHUB)#ACPI(HS03)",
            ]),
        )
        .with(
            NodeProperty::BusReportedDeviceDesc,
            Some(NodeValue::Text("HDC Device".into())),
        )
        .with(
            NodeProperty::LastArrivalDate,
            Some(NodeValue::FileTime(134_037_216_000_000_000)),
        )
    }

    #[test]
    fn a_node_reads_as_the_census_identity() {
        let device = UsbHostDevice::from_device_node(&board()).unwrap();
        assert_eq!(
            device,
            UsbHostDevice {
                serial: SERIAL.into(),
                vendor_id: 0x2207,
                product_id: 0x5000,
                topology: location_topology(LOCATION),
                product_name: Some("HDC Device".into()),
                registry_entry_id: Some(134_037_216_000_000_000),
            }
        );
        // The topology is a canonical decimal, as the relation rule requires.
        let location: u64 = device.topology.parse().unwrap();
        assert_eq!(location.to_string(), device.topology);
        // Through a trait object, as a census hands nodes out.
        let node: &dyn DeviceNode = &board();
        assert_eq!(UsbHostDevice::from_device_node(node), Some(device));
    }

    #[test]
    fn the_topology_is_one_location_path_and_differs_between_paths() {
        assert_eq!(location_topology(LOCATION), location_topology(LOCATION));
        assert_ne!(
            location_topology(LOCATION),
            location_topology("PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(4)")
        );
        // The sample's two attachments into one physical connector, USB 2
        // and then USB 3: two location paths, so two topologies. Topology is
        // valid only within one attachment.
        assert_ne!(
            location_topology("PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(10)"),
            location_topology("PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(26)")
        );
        // Known value: SHA-256("") begins e3b0c44298fc1c14.
        assert_eq!(location_topology(""), 0xe3b0_c442_98fc_1c14_u64.to_string());
    }

    #[test]
    fn a_windows_generated_instance_suffix_is_no_serial() {
        for suffix in ["5&1a2b3c&0&3", "5&1A2B3C&0&3", "6&abc&0", "&", "AAAA&0"] {
            let node = board().id(Some(&format!("USB\\VID_2207&PID_5000\\{suffix}")));
            assert_eq!(UsbHostDevice::from_device_node(&node), None, "{suffix}");
        }
        let node = board().id(Some("USB\\VID_2207&PID_5000\\"));
        assert_eq!(
            UsbHostDevice::from_device_node(&node),
            None,
            "an empty suffix"
        );
    }

    #[test]
    fn only_a_device_level_usb_node_is_an_entry() {
        for id in [
            None,
            Some("USB\\VID_2207&PID_5000&MI_00\\6&1234&0&0000"),
            Some("USB\\VID_2207&PID_5000&MI_01\\aaaa"),
            Some("USB\\ROOT_HUB30\\4&2bd8a0a&0&0"),
            Some("USBSTOR\\VID_2207&PID_5000\\aaaa"),
            Some("HID\\VID_2207&PID_5000\\aaaa"),
            Some("USB\\VID_2207&PID_5000"),
            Some("USB\\VID_2207&PID_5000\\aaaa\\bbbb"),
            Some("USB\\VID_22G7&PID_5000\\aaaa"),
            Some("USB\\VID_2207&PID_500\\aaaa"),
            Some("USB\\VID_2207&PID_50000\\aaaa"),
        ] {
            assert_eq!(
                UsbHostDevice::from_device_node(&board().id(id)),
                None,
                "{id:?}"
            );
        }
        // Instance IDs are case-insensitive in their fixed parts; the
        // serial is ASCII-lowercase folded.
        let node = board().id(Some("usb\\vid_2207&pid_5000\\AbC123"));
        assert_eq!(
            UsbHostDevice::from_device_node(&node).unwrap().serial,
            "abc123"
        );
    }

    /// Maintainer ruling 2026-10-04, item 4: the instance ID spells the
    /// board's serial in upper-case hex, the HDC connect key is lower-case
    /// hex; the census folds the suffix, ASCII only, and the folded serial is
    /// the identity.
    #[test]
    fn an_upper_case_suffix_folds_to_the_lower_case_connect_key() {
        let upper = SERIAL.to_ascii_uppercase();
        let node = board().id(Some(&format!("USB\\VID_2207&PID_5000\\{upper}")));
        let device = UsbHostDevice::from_device_node(&node).unwrap();
        assert_eq!(device.serial, SERIAL);
        assert_eq!(
            Some(device),
            UsbHostDevice::from_device_node(&board()),
            "the same identity whichever case the instance ID spells"
        );
        // Only ASCII is folded: a non-ASCII letter stays as it is.
        let node = board().id(Some("USB\\VID_2207&PID_5000\\AB\u{c4}C"));
        assert_eq!(
            UsbHostDevice::from_device_node(&node).unwrap().serial,
            "ab\u{c4}c"
        );
    }

    /// Maintainer ruling 2026-10-04, item 5: present nodes only. A phantom
    /// (the sample's remembered loader node) keeps its last attachment's
    /// properties and is never an entry, nor is a node that does not answer
    /// its presence as a boolean.
    #[test]
    fn a_phantom_node_is_never_an_entry() {
        for value in [
            Some(NodeValue::Boolean(false)),
            None,
            Some(NodeValue::Other),
            Some(NodeValue::Text("true".into())),
            Some(NodeValue::FileTime(1)),
        ] {
            assert_eq!(
                UsbHostDevice::from_device_node(
                    &board().with(NodeProperty::IsPresent, value.clone())
                ),
                None,
                "{value:?}"
            );
        }
        let loader_phantom = board()
            .id(Some("USB\\VID_2207&PID_350A\\aaaaaaaaaaaaaaaa"))
            .with(
                NodeProperty::HardwareIds,
                list(&["USB\\VID_2207&PID_350A&REV_0100", "USB\\VID_2207&PID_350A"]),
            )
            .with(NodeProperty::IsPresent, Some(NodeValue::Boolean(false)));
        assert_eq!(UsbHostDevice::from_device_node(&loader_phantom), None);
        assert!(
            UsbHostDevice::from_device_node(
                &loader_phantom.with(NodeProperty::IsPresent, Some(NodeValue::Boolean(true)))
            )
            .is_some(),
            "the same node, present, is an entry"
        );
    }

    /// Ruling item 5: one attachment is (instance ID, `LastArrivalDate`). A
    /// new arrival of the same instance is a new attachment of the same
    /// identity, wherever it enumerated.
    #[test]
    fn a_new_arrival_is_a_new_attachment_of_the_same_identity() {
        let first = UsbHostDevice::from_device_node(
            &board()
                .with(
                    NodeProperty::LocationPaths,
                    list(&["PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(10)"]),
                )
                .with(NodeProperty::LastArrivalDate, Some(NodeValue::FileTime(9))),
        )
        .unwrap();
        let replugged = UsbHostDevice::from_device_node(
            &board()
                .id(Some(&format!(
                    "USB\\VID_2207&PID_5000\\{}",
                    SERIAL.to_ascii_uppercase()
                )))
                .with(
                    NodeProperty::LocationPaths,
                    list(&["PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(26)"]),
                )
                .with(NodeProperty::LastArrivalDate, Some(NodeValue::FileTime(11))),
        )
        .unwrap();
        assert_eq!(first.serial, replugged.serial, "the same identity");
        assert_eq!(
            (first.vendor_id, first.product_id),
            (replugged.vendor_id, replugged.product_id)
        );
        assert_ne!(first.registry_entry_id, replugged.registry_entry_id);
        assert_ne!(first.topology, replugged.topology);
    }

    #[test]
    fn a_node_without_matching_numbers_or_a_location_is_passed_over() {
        for value in [
            None,
            Some(NodeValue::Other),
            Some(NodeValue::Text("USB\\VID_2207&PID_5000".into())),
            list(&[]),
            list(&["USB\\VID_2207&PID_350A&REV_0100"]),
            list(&["USB\\Class_ff&SubClass_50"]),
        ] {
            assert_eq!(
                UsbHostDevice::from_device_node(
                    &board().with(NodeProperty::HardwareIds, value.clone())
                ),
                None,
                "hardware IDs {value:?}"
            );
        }
        // The first bus-reported ID with numbers is the one compared.
        let other_first = board().with(
            NodeProperty::HardwareIds,
            list(&["USB\\Class_ff", "usb\\vid_2207&pid_5000&rev_0223"]),
        );
        assert!(UsbHostDevice::from_device_node(&other_first).is_some());
        for value in [None, Some(NodeValue::Other), list(&[]), list(&[""])] {
            assert_eq!(
                UsbHostDevice::from_device_node(
                    &board().with(NodeProperty::LocationPaths, value.clone())
                ),
                None,
                "location paths {value:?}"
            );
        }
    }

    #[test]
    fn the_product_name_and_the_attachment_are_optional() {
        for value in [None, Some(NodeValue::Other), list(&["HDC Device"])] {
            let device = UsbHostDevice::from_device_node(
                &board().with(NodeProperty::BusReportedDeviceDesc, value.clone()),
            )
            .unwrap();
            assert_eq!(device.product_name, None, "{value:?}");
        }
        for value in [
            None,
            Some(NodeValue::FileTime(0)),
            Some(NodeValue::Other),
            Some(NodeValue::Text("134037216000000000".into())),
        ] {
            let device = UsbHostDevice::from_device_node(
                &board().with(NodeProperty::LastArrivalDate, value.clone()),
            )
            .unwrap();
            assert_eq!(device.registry_entry_id, None, "{value:?}");
        }
    }

    #[test]
    fn usb_numbers_read_hardware_id_forms() {
        assert_eq!(usb_numbers("VID_2207&PID_5000"), Some((0x2207, 0x5000)));
        assert_eq!(
            usb_numbers("vid_05ac&pid_12a8&rev_1401"),
            Some((0x05ac, 0x12a8))
        );
        assert_eq!(usb_numbers("VID_2207&PID_5000REV"), None);
        assert_eq!(usb_numbers("VID_+207&PID_5000"), None);
        assert_eq!(usb_numbers("VID_2207"), None);
        assert_eq!(usb_numbers("VÍD_2207&PID_5000"), None);
    }

    /// The gate: the 2026-10-04 sample confirmed every §4 field, so the
    /// trusted census is open; a row set back to `TBD(sample)` would close it.
    #[test]
    fn every_census_field_is_confirmed_and_a_tbd_row_closes_the_gate() {
        assert!(unconfirmed_census_fields().is_empty());
        assert_eq!(
            CENSUS_MAPPING.map(|row| row.field),
            [
                "device",
                "vendorId/productId",
                "serial",
                "topology",
                "productName",
                "attachment"
            ]
        );
        let mut mapping = CENSUS_MAPPING;
        mapping[2].sample = CensusSample::Tbd;
        assert_eq!(unconfirmed(&mapping), ["serial"]);
        assert!(
            crate::RegistryUnavailable::MappingUnconfirmed
                .to_string()
                .starts_with("USB registry unavailable: the Windows census field mapping")
        );
    }

    /// The trusted census answers over this host's device tree, by the same
    /// rule as the diagnostic census. Only the shape is asserted.
    #[cfg(windows)]
    #[test]
    fn the_trusted_census_answers_once_the_mapping_is_confirmed() {
        let devices = usb_host_devices().expect("the trusted census answers");
        for device in &devices {
            assert!(!device.serial.bytes().any(|byte| byte.is_ascii_uppercase()));
        }
    }

    /// This host's census through the production reader: it must answer, and
    /// every entry must be well formed. Only the shape is asserted and
    /// nothing identifying is printed.
    #[cfg(windows)]
    #[test]
    fn the_host_census_answers_with_well_formed_entries() {
        let devices = usb_device_node_census().expect("the host's USB device census answers");
        for device in &devices {
            assert!(!device.serial.is_empty());
            assert!(!device.serial.contains('&'));
            assert!(!device.serial.contains('\\'));
            assert!(!device.serial.bytes().any(|byte| byte.is_ascii_uppercase()));
            let location: u64 = device.topology.parse().expect("a decimal topology");
            assert_eq!(location.to_string(), device.topology);
            assert_ne!(device.registry_entry_id, Some(0));
        }
        eprintln!(
            "{} device-level USB identities with a serial on this host ({} with an attachment)",
            devices.len(),
            devices
                .iter()
                .filter(|device| device.registry_entry_id.is_some())
                .count()
        );
    }
}
