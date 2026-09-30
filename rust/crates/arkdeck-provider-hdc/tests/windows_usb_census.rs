//! GJ-1 relation proof over the Windows USB census rule (TASK-XPA-004): a
//! synthetic Plug and Play device node, read by
//! `UsbHostDevice::from_device_node` exactly as the Windows census reads a
//! present node, feeds `UsbRegistryRelations`, which brackets an in-process
//! scripted HDC's `list targets -v` (the `device candidates` read) and holds
//! the adoption's final check over the identity readback (`target adopt`).
//! No process, device or board is involved; the node's serial is the observe
//! fixture's placeholder. On Windows the production reader also answers over
//! this host's own device tree, which proves nothing about a device.
use arkdeck_platform::{DeviceNode, NodeProperty, NodeValue, UsbHostDevice};
use arkdeck_provider_hdc::{
    DAYU200_NORMAL_PRODUCT_ID, DispatchFailure, Expected, HdcDispatch, NoUsbRelations, ProcessPlan,
    ROCKUSB_VENDOR_ID, Reading, Receipt, UsbRegistryRelations, UsbRelation, UsbRelations,
    adoption_holds, observe_device_identity, stable_identity_sha256_for_serial,
};
use std::cell::Cell;
use std::time::Duration;

const CONNECT_KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

/// A present device node as the Windows census hands one to its rule.
#[derive(Clone)]
struct Node {
    instance_id: String,
    hardware_ids: Vec<&'static str>,
    location: &'static str,
    name: Option<&'static str>,
    arrival: u64,
}

impl DeviceNode for Node {
    fn instance_id(&self) -> Option<String> {
        Some(self.instance_id.clone())
    }

    fn property(&self, key: NodeProperty) -> Option<NodeValue> {
        match key {
            NodeProperty::HardwareIds => Some(NodeValue::TextList(
                self.hardware_ids
                    .iter()
                    .map(|id| (*id).to_owned())
                    .collect(),
            )),
            NodeProperty::LocationPaths => Some(NodeValue::TextList(vec![self.location.into()])),
            NodeProperty::BusReportedDeviceDesc => {
                self.name.map(|name| NodeValue::Text(name.into()))
            }
            NodeProperty::LastArrivalDate => Some(NodeValue::FileTime(self.arrival)),
        }
    }
}

/// The DAYU200 in its HDC-normal personality, attached at `arrival`.
fn board(arrival: u64) -> Node {
    Node {
        instance_id: format!("USB\\VID_2207&PID_5000\\{CONNECT_KEY}"),
        hardware_ids: vec!["USB\\VID_2207&PID_5000&REV_0223", "USB\\VID_2207&PID_5000"],
        location: "PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(3)",
        name: Some("HDC Device"),
        arrival,
    }
}

/// A census of synthetic nodes, each read by the Windows per-node rule.
fn census(nodes: &[Node]) -> Vec<UsbHostDevice> {
    nodes
        .iter()
        .filter_map(UsbHostDevice::from_device_node)
        .collect()
}

/// An HDC answering `-v` and `list targets -v` with fixed bytes, as
/// 3.2.0f lists one USB device.
struct Scripted {
    calls: Cell<usize>,
}

impl HdcDispatch for Scripted {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        self.calls.set(self.calls.get() + 1);
        let stdout = match plan.arguments.join(" ").as_str() {
            "-v" => "Ver: 3.2.0f\n".to_owned(),
            "list targets -v" => format!("{CONNECT_KEY}\t\tUSB\tConnected\tlocalhost\n"),
            other => panic!("unscripted {other}"),
        };
        Ok(Receipt {
            exit_status: 0,
            stdout: stdout.into_bytes(),
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::from_millis(5),
        })
    }
}

#[test]
fn a_windows_census_node_proves_the_candidate_and_holds_the_adoption() {
    let dispatch = Scripted {
        calls: Cell::new(0),
    };
    // Without a census every candidate is listed but unproved: what the
    // Windows Runtime composed before this census.
    let reading = Reading::take(&dispatch, &NoUsbRelations).unwrap();
    assert_eq!(reading.rows()[0].continuity(), "generationScoped");

    // The board beside nodes that are not it: another vendor's device, the
    // board's own interface node, the board with a Windows-generated suffix
    // (no serial), and the Loader personality.
    let nodes = vec![
        Node {
            instance_id: "USB\\VID_046D&PID_C52B\\bbbbbbbb".into(),
            hardware_ids: vec!["USB\\VID_046D&PID_C52B&REV_1211"],
            location: "PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(1)",
            name: Some("USB Receiver"),
            arrival: 5,
        },
        Node {
            instance_id: "USB\\VID_2207&PID_5000&MI_00\\6&1234&0&0000".into(),
            ..board(7)
        },
        Node {
            instance_id: "USB\\VID_2207&PID_5000\\5&1a2b3c&0&3".into(),
            ..board(8)
        },
        Node {
            instance_id: format!("USB\\VID_2207&PID_350A\\{CONNECT_KEY}"),
            hardware_ids: vec!["USB\\VID_2207&PID_350A&REV_0100"],
            name: None,
            ..board(9)
        },
        board(133_000_000_000_000_017),
    ];
    let devices = census(&nodes);
    assert_eq!(
        devices.len(),
        3,
        "the interface and the generated suffix are passed over"
    );
    let reader = UsbRegistryRelations::new(move || Ok(devices.clone()));
    let reading = Reading::take(&dispatch, &reader).unwrap();
    reading.validate().unwrap();
    let row = &reading.rows()[0];
    assert_eq!(row.continuity(), "relationProven");
    let relation = row.relation.clone().unwrap();
    assert_eq!(relation.serial, CONNECT_KEY);
    assert_eq!(relation.attachment_id, 133_000_000_000_000_017);
    assert_eq!(relation.vendor_id, ROCKUSB_VENDOR_ID);
    assert_eq!(relation.product_id, DAYU200_NORMAL_PRODUCT_ID);
    assert!(
        relation.is_usable(),
        "a Windows topology is a canonical decimal"
    );

    // The adoption's final check over the same census and the readback, and
    // the stable identity, exactly as on macOS.
    let identity = observe_device_identity(&dispatch, CONNECT_KEY, Expected::default()).unwrap();
    assert!(adoption_holds(
        &relation,
        &reader.relations().unwrap(),
        &identity
    ));
    assert_eq!(
        stable_identity_sha256_for_serial(&relation.serial),
        stable_identity_sha256_for_serial(&CONNECT_KEY.to_uppercase()),
        "the stable identity hashes the normalised serial"
    );

    // A replug (a new arrival) between the brackets proves nothing, and a
    // replug before adoption fails the final check.
    let arrivals = Cell::new(0_u64);
    let replugging = UsbRegistryRelations::new(move || {
        arrivals.set(arrivals.get() + 1);
        Ok(census(&[board(arrivals.get())]))
    });
    let reading = Reading::take(&dispatch, &replugging).unwrap();
    assert_eq!(reading.rows()[0].continuity(), "generationScoped");
    let replugged: Vec<UsbRelation> = replugging.relations().unwrap();
    assert!(!adoption_holds(&relation, &replugged, &identity));

    // Without the bus-reported name or the arrival, or without a serial,
    // the node proves nothing.
    for node in [
        Node {
            name: None,
            ..board(17)
        },
        Node {
            arrival: 0,
            ..board(17)
        },
        Node {
            instance_id: "USB\\VID_2207&PID_5000\\5&1a2b3c&0&3".into(),
            ..board(17)
        },
    ] {
        let reader = UsbRegistryRelations::new(move || Ok(census(std::slice::from_ref(&node))));
        let reading = Reading::take(&dispatch, &reader).unwrap();
        assert_eq!(reading.rows()[0].continuity(), "generationScoped");
    }
}

/// This host's device tree through the production reader: it answers whether
/// or not a board is attached, and anything it lists is an HDC-normal DAYU200
/// relation with an attachment. A host-only read, never device evidence;
/// nothing identifying is printed.
#[cfg(windows)]
#[test]
fn the_system_census_reader_answers_on_this_host() {
    let relations = UsbRegistryRelations::system()
        .relations()
        .expect("the host's USB device census answers");
    eprintln!(
        "{} DAYU200 relation(s) on this host: a host-only read, not device evidence",
        relations.len()
    );
    for relation in &relations {
        assert_eq!(relation.vendor_id, ROCKUSB_VENDOR_ID);
        assert_eq!(relation.product_id, DAYU200_NORMAL_PRODUCT_ID);
        assert_ne!(relation.attachment_id, 0);
        assert!(relation.is_usable());
    }
}
