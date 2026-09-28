//! Fixed vectors for the two ArkForge digest domains ArkDeck recomputes
//! (F1/F2, 2026-09-28): the USB topology digest the Loader join selects by,
//! and the admission device-facts digest the execution authority compares
//! before it signs a permit.
//!
//! The expected values were computed by ArkForge's own producers at the pinned
//! revision (`c1dc0553b42627581583abfba3fec34d13343282`):
//! `arkforge_transport::usb::UsbDeviceRecord::topology_digest` and
//! `arkforge_transport::DeviceObservation::admission_facts_digest`. The program
//! that printed them is recorded in
//! `openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-017/arkforge-digest-domains-run.md`.
//! A pin move that changes either domain or its encoding fails here.

use arkdeck_provider_arkforge::authority::device_facts_digest;
use arkdeck_provider_arkforge::topology_digest;
use arkforge_core::digest::sha256;
use arkforge_ipc::messages::{KeyValue, StepAdmissionSnapshot};

/// `(USB location id, UsbDeviceRecord::topology_digest)`.
const TOPOLOGY: [(&str, &str); 4] = [
    (
        "18874368",
        "3ec01c30971df27e26543c63b3856452cbae569f060278e2d10d021a68cfc1be",
    ),
    (
        "19922944",
        "6ea4b7679e672a207f517e4b80a7905df75d2dd4c5237a5db36a65524d39f1e5",
    ),
    (
        "0",
        "6504f357f2ff8c756ebee2ba8c0bb732b690da6b30cb2596872e9f6f90ae1da1",
    ),
    (
        "4294967295",
        "af09e7143f827c0a6838acb78d003b4a0487b6566c8c108769d146f70a33130c",
    ),
];

#[test]
fn the_topology_digest_is_arkforges_usb_topology_digest() {
    for (location, expected) in TOPOLOGY {
        assert_eq!(
            topology_digest(location).as_deref(),
            Some(expected),
            "{location}"
        );
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The observation the vector program hashed: a DAYU200 Loader at location
/// 18874368, descriptor digest `[0x11; 32]`, one protocol identity fact.
fn snapshot(serial_kind: &str, malformed: bool) -> StepAdmissionSnapshot {
    let topology: Vec<u8> = (0..32)
        .map(|index| u8::from_str_radix(&TOPOLOGY[0].1[index * 2..index * 2 + 2], 16).unwrap())
        .collect();
    StepAdmissionSnapshot {
        observed_mode: "rockusb-loader".into(),
        topology_sha256: topology,
        descriptor_sha256: vec![0x11; 32],
        serial_evidence_kind: serial_kind.into(),
        serial_sha256: if serial_kind == "absent" {
            Vec::new()
        } else {
            sha256(b"serial").as_bytes().to_vec()
        },
        protocol_identity: vec![KeyValue {
            key: "usb.identity".into(),
            value: "0x2207:0x350a".into(),
        }],
        identity_strength: "serialAndTopology".into(),
        malformed_descriptor: malformed,
        ..StepAdmissionSnapshot::default()
    }
}

#[test]
fn the_admission_facts_digest_is_arkforges_admission_facts_digest() {
    assert_eq!(
        hex(&device_facts_digest(&snapshot("absent", false))),
        "fb58048e33a273065af0a76aadfa9d7670f8799eb6052874197a73becbb9efcd"
    );
    assert_eq!(
        hex(&device_facts_digest(&snapshot("descriptor", true))),
        "ebdc218f4514782fa6e2d69726b6a12eadbe7fdbcb8ef04ded4d49ec7966076a"
    );
}
