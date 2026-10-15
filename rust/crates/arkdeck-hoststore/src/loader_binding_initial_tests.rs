use super::*;
use arkdeck_platform::{HostDirectory, random_bytes};
use arkdeck_provider_hdc::LoaderIdentity;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-initial-binding-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        HostDirectory::open_or_create_private(&path).unwrap();
        Self(path)
    }
    fn targets(&self, records: Vec<Value>) -> TargetStore {
        let directory = self.0.join("targets");
        let root = HostDirectory::open_or_create_private(&directory).unwrap();
        root.publish_document(
            "targets.json",
            &serde_json::to_vec(&json!({
                "schemaVersion": "1.0.0", "targets": records
            }))
            .unwrap(),
            4 * 1024 * 1024,
        )
        .unwrap();
        TargetStore::open(&directory).unwrap()
    }
    fn bytes(&self) -> Option<Vec<u8>> {
        std::fs::read(self.0.join(RockchipBindingStore::FILE_NAME)).ok()
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn device() -> UsbHostDevice {
    UsbHostDevice {
        serial: "initial-binding-test-board".into(),
        vendor_id: 0x2207,
        product_id: 0x5000,
        topology: "17956864".into(),
        product_name: Some("HDC Device".into()),
        registry_entry_id: Some(42),
    }
}
fn target(id: &str, serial: &str, revision: i64) -> Value {
    json!({"targetID": id, "bindingRevision": revision, "connectKey": serial,
        "stablePhysicalIdentitySHA256": sha256_hex(serial.as_bytes()),
        "toolVersion": "3.2.0f", "adoptedAtUTC": "2026-10-15T00:00:00Z"})
}
struct Observer;
impl LoaderObserver for Observer {
    fn observe_loader(
        &self,
        identity: &str,
        topology: Option<&str>,
        _: &str,
    ) -> Result<LoaderIdentity, String> {
        Ok(LoaderIdentity {
            serial_digest_sha256: identity.into(),
            topology: topology.unwrap().into(),
        })
    }
}
fn owner(root: &Root, devices: Vec<Vec<UsbHostDevice>>) -> LoaderBinding {
    let devices = Arc::new(Mutex::new(devices));
    LoaderBinding::new(
        &root.0,
        move || {
            let mut script = devices.lock().unwrap();
            Ok(if script.len() > 1 {
                script.remove(0)
            } else {
                script[0].clone()
            })
        },
        Observer,
    )
}

#[test]
fn initial_normal_binding_is_runtime_owned_durable_and_idempotent() {
    let root = Root::new();
    let device = device();
    let targets = root.targets(vec![target("TGT-A", &device.serial, 1)]);
    let before = targets.records().unwrap();
    let owner = owner(&root, vec![vec![device.clone()]]);
    let first = owner.bind(&targets, None, "TGT-A", 1).unwrap();
    assert_eq!(first["updated"], true);
    assert_eq!(first["bindingRevision"], 1);
    assert_eq!(first["previousBindingRevision"], 1);
    assert_eq!(first["settledJobId"], Value::Null);
    let bytes = root.bytes().unwrap();
    let binding = owner.store.load_existing().unwrap();
    assert!(binding.matches_confirmed_live_identity(&device).unwrap());
    let retry = owner.bind(&targets, None, "TGT-A", 1).unwrap();
    assert_eq!(retry["updated"], false);
    assert_eq!(
        retry["selectionEvidenceSha256"],
        first["selectionEvidenceSha256"]
    );
    assert_eq!(root.bytes().unwrap(), bytes);
    assert_eq!(targets.records().unwrap(), before);
}

#[test]
fn bootstrap_refuses_loader_wrong_target_alias_advanced_and_ambiguous_targets() {
    for case in 0..6 {
        let root = Root::new();
        let mut device = device();
        let mut record = target("TGT-A", &device.serial, 1);
        let mut records = Vec::new();
        match case {
            0 => device.product_id = 0x350a,
            1 => record = target("TGT-A", "another-board", 1),
            2 => record["connectKey"] = json!("unproved-alias"),
            3 => record["bindingRevision"] = json!(2),
            4 => {
                let mut duplicate = target("TGT-B", "other-route", 1);
                duplicate["stablePhysicalIdentitySHA256"] =
                    json!(sha256_hex(device.serial.as_bytes()));
                records.push(duplicate);
            }
            5 => device.product_name = Some("Unregistered product".into()),
            _ => unreachable!(),
        }
        records.push(record);
        let targets = root.targets(records);
        let before = targets.records().unwrap();
        let owner = owner(&root, vec![vec![device]]);
        assert!(
            owner
                .bind(&targets, None, "TGT-A", if case == 3 { 2 } else { 1 })
                .is_err(),
            "case {case}"
        );
        assert!(root.bytes().is_none(), "case {case}");
        assert_eq!(targets.records().unwrap(), before);
    }
}

#[test]
fn bootstrap_refuses_hotplug_port_identity_mode_and_attachment_drift() {
    for case in 0..6 {
        let root = Root::new();
        let first = device();
        let mut second = first.clone();
        let targets = root.targets(vec![target("TGT-A", &first.serial, 1)]);
        let next = match case {
            0 => vec![],
            1 => vec![first.clone(), first.clone()],
            2 => {
                second.topology = "17956865".into();
                vec![second]
            }
            3 => {
                second.serial = "another-board".into();
                vec![second]
            }
            4 => {
                second.product_id = 0x350a;
                vec![second]
            }
            5 => {
                second.registry_entry_id = Some(43);
                vec![second]
            }
            _ => unreachable!(),
        };
        let owner = owner(&root, vec![vec![first], next]);
        assert!(
            owner.bind(&targets, None, "TGT-A", 1).is_err(),
            "case {case}"
        );
        assert!(root.bytes().is_none());
    }
}

#[test]
fn concurrent_binding_is_preserved_and_never_upgraded_to_runtime_attestation() {
    let root = Root::new();
    let device = device();
    let targets = root.targets(vec![target("TGT-A", &device.serial, 1)]);
    let candidate = BindingSnapshot {
        revision: 1,
        serial: device.serial.clone(),
        usb_topology: device.topology.clone(),
        evidence: vec![
            HDC_NORMAL_READBACK.into(),
            CROSS_MODE_USB.into(),
            format!(
                "identity:serial-sha256={}",
                sha256_hex(device.serial.as_bytes())
            ),
        ],
    };
    let expected = candidate.encode();
    let directory = root.0.clone();
    let calls = Mutex::new(0);
    let owner = LoaderBinding::new(
        &root.0,
        move || {
            let mut calls = calls.lock().unwrap();
            *calls += 1;
            if *calls == 2 {
                RockchipBindingStore::new(&directory)
                    .install(&candidate, false)
                    .unwrap();
            }
            Ok(vec![device.clone()])
        },
        Observer,
    );
    assert!(owner.bind(&targets, None, "TGT-A", 1).is_err());
    assert_eq!(root.bytes().unwrap(), expected);
    assert!(owner.bind(&targets, None, "TGT-A", 1).is_err());
    assert_eq!(root.bytes().unwrap(), expected);
}
