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
//! macOS's per-entry rule does: a node without both numbers, a topology and a
//! serial is no identity and is passed over; a property of an unexpected type
//! counts as absent; the product name is optional; the attachment is absent
//! when the node answers none or zero.
//!
//! # Provisional property choice
//!
//! Which Windows property carries which census field is decided in one place,
//! [`UsbHostDevice::from_device_node`] together with [`NodeProperty`], and is
//! **provisional** until the maintainer's DAYU200 USB-properties sample
//! (`evidence/runs/TASK-XPA-004/dayu200-usb-properties-crib-20260930.md`)
//! confirms or refutes it:
//!
//! | census field | Windows source (provisional) |
//! | --- | --- |
//! | the entry | a device-level node `USB\VID_hhhh&PID_hhhh\<suffix>` (no `&MI_xx` interface node) |
//! | vendor, product | `DEVPKEY_Device_HardwareIds`, the first `USB\VID_hhhh&PID_hhhh…` entry, which must name the same numbers as the instance ID |
//! | serial | the instance ID's third segment; a suffix holding `&` is a Windows-generated, port-derived ID: **no serial, the node is passed over** |
//! | topology | the first `DEVPKEY_Device_LocationPaths` entry, as the decimal of the first eight bytes (big-endian) of its UTF-8 SHA-256 (see below) |
//! | product name | `DEVPKEY_Device_BusReportedDeviceDesc` (the device's own iProduct; `FriendlyName`/`DeviceDesc` come from the driver INF) |
//! | attachment | `DEVPKEY_Device_LastArrivalDate` (a `FILETIME`, one arrival of the device) |
//!
//! The topology is a Windows-only spelling: Windows has no packed 32-bit
//! `locationID`, and the relation rule accepts only a canonical decimal
//! location. The location path names the physical port chain up to the host
//! controller, so its digest is stable for one port and differs between
//! ports; it is never byte-equal to a macOS topology.
use crate::usb_registry::UsbHostDevice;
use sha2::{Digest, Sha256};

/// A device property the Windows census reads. The `DEVPKEY` each one names is
/// part of the provisional property choice (module documentation).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NodeProperty {
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
    /// **Provisional** property choice: see the module documentation.
    pub fn from_device_node<N: DeviceNode + ?Sized>(node: &N) -> Option<Self> {
        let list = |key| match node.property(key) {
            Some(NodeValue::TextList(values)) => Some(values),
            _ => None,
        };
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
/// numbers and its serial. An interface node (`…&MI_xx`), another
/// enumerator, a malformed ID and a Windows-generated suffix (one holding
/// `&`) are `None`.
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
    Some((vendor, product, suffix.to_owned()))
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
/// big-endian, of the SHA-256 of its UTF-8. Provisional (module
/// documentation).
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

/// Every device-level USB identity present on the host, in device
/// information set order: nodes the per-node rule passes over are not listed,
/// and nothing is deduplicated. Read-only: see the module documentation.
#[cfg(windows)]
pub fn usb_host_devices() -> Result<Vec<UsbHostDevice>, crate::RegistryUnavailable> {
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
        DEVPKEY_Device_BusReportedDeviceDesc, DEVPKEY_Device_HardwareIds,
        DEVPKEY_Device_LastArrivalDate, DEVPKEY_Device_LocationPaths, DEVPROP_TYPE_FILETIME,
        DEVPROP_TYPE_STRING, DEVPROP_TYPE_STRING_LIST, DEVPROPTYPE,
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
    fn the_topology_is_stable_per_port_and_differs_between_ports() {
        assert_eq!(location_topology(LOCATION), location_topology(LOCATION));
        assert_ne!(
            location_topology(LOCATION),
            location_topology("PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(4)")
        );
        // Known value: SHA-256("") begins e3b0c44298fc1c14.
        assert_eq!(location_topology(""), 0xe3b0_c442_98fc_1c14_u64.to_string());
    }

    #[test]
    fn a_windows_generated_instance_suffix_is_no_serial() {
        for suffix in ["5&1a2b3c&0&3", "6&abc&0", "&"] {
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
        // serial is taken as it is.
        let node = board().id(Some("usb\\vid_2207&pid_5000\\AbC123"));
        assert_eq!(
            UsbHostDevice::from_device_node(&node).unwrap().serial,
            "AbC123"
        );
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

    /// This host's census through the production reader: it must answer, and
    /// every entry must be well formed. Only the shape is asserted and
    /// nothing identifying is printed.
    #[cfg(windows)]
    #[test]
    fn the_host_census_answers_with_well_formed_entries() {
        let devices = usb_host_devices().expect("the host's USB device census answers");
        for device in &devices {
            assert!(!device.serial.is_empty());
            assert!(!device.serial.contains('&'));
            assert!(!device.serial.contains('\\'));
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
