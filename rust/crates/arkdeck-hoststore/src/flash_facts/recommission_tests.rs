//! Synthetic host facts only: no installed Runtime, HDC or device is used.
use super::*;
use crate::job_owner::flash_recommission::{CHAIN_FACT, IdentityChain};
use arkdeck_platform::HostDirectory;
use arkdeck_provider_hdc::{DispatchFailure, NormalHardwareIdentity, ProcessPlan, Receipt};

const KEY: &str = "recommission-normal-cid";
const TARGET: &str = "TGT-recommission-facts";

struct Fixture {
    root: PathBuf,
    targets: TargetStore,
    facts: FlashHostFacts,
    binding_bytes: Vec<u8>,
    target_bytes: Vec<u8>,
}

impl Fixture {
    fn new(topology: &str) -> Self {
        let root = crate::test_private::temporary_root().join(format!(
            "arkdeck-recommission-facts-{:032x}",
            u128::from_le_bytes(arkdeck_platform::random_bytes().unwrap())
        ));
        crate::test_private::create_private_directory(&root);
        let target_root = HostDirectory::open_or_create_private(&root.join("targets")).unwrap();
        target_root
            .create_document(
                "targets.json",
                &serde_json::to_vec(&json!({
                    "schemaVersion": "1.0.0", "targets": [{
                        "targetID": TARGET, "bindingRevision": 1, "connectKey": KEY,
                        "stablePhysicalIdentitySHA256": sha256_hex(KEY.as_bytes()),
                        "toolVersion": "3.2.0f", "adoptedAtUTC": "2026-10-15T00:00:00Z"
                    }]
                }))
                .unwrap(),
            )
            .unwrap();
        let targets = TargetStore::open(&root.join("targets")).unwrap();
        RockchipBindingStore::new(&root)
            .install(
                &BindingSnapshot {
                    revision: 1,
                    serial: KEY.into(),
                    usb_topology: "42".into(),
                    evidence: vec![format!(
                        "identity:serial-sha256={}",
                        sha256_hex(KEY.as_bytes())
                    )],
                },
                false,
            )
            .unwrap();
        let device = UsbHostDevice {
            serial: KEY.into(),
            vendor_id: 0x2207,
            product_id: 0x5000,
            topology: topology.into(),
            product_name: Some("HDC Device".into()),
            registry_entry_id: Some(42),
        };
        let executable = std::env::current_exe().unwrap();
        let rockusb = NativeRockUsbIdentity::configured(
            Some(executable.to_string_lossy().into_owned()),
            Some(sha256_hex(&std::fs::read(&executable).unwrap())),
        );
        let jobs = root.join("jobs");
        crate::test_private::create_private_directory(&jobs);
        let facts = FlashHostFacts::new(&root, move || Ok(vec![device.clone()]))
            .with_rockusb(rockusb)
            .with_recommission_state(&jobs)
            .with_normal_identity_observer(|_, _, _, _| {
                Err("normalLoaderIdentity.boundLoaderIdentityMismatch")
            })
            .with_recommission_identity_observer(fresh_identity);
        Self {
            binding_bytes: std::fs::read(root.join(RockchipBindingStore::FILE_NAME)).unwrap(),
            target_bytes: std::fs::read(root.join("targets/targets.json")).unwrap(),
            root,
            targets,
            facts,
        }
    }

    fn read(&self, recommission: bool) -> Result<RockchipFacts, String> {
        self.facts
            .operation_facts(&self.targets, Some(&ReadOnlyHdc), TARGET, recommission)
    }

    fn assert_history_unchanged(&self) {
        assert_eq!(
            std::fs::read(self.root.join(RockchipBindingStore::FILE_NAME)).unwrap(),
            self.binding_bytes
        );
        assert_eq!(
            std::fs::read(self.root.join("targets/targets.json")).unwrap(),
            self.target_bytes
        );
        assert!(
            !self
                .root
                .join("jobs/flash-recommission-allocations.json")
                .exists()
        );
        assert!(!self.root.join("jobs/jobs").exists());
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // This uniquely created fixture is the only recursive cleanup target.
        assert_eq!(
            self.root.parent().unwrap(),
            crate::test_private::temporary_root()
        );
        assert!(
            self.root
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .starts_with("arkdeck-recommission-facts-")
        );
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

struct ReadOnlyHdc;
impl HdcDispatch for ReadOnlyHdc {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let stdout = if plan.arguments == ["list", "targets", "-v"] {
            format!("{KEY}\t\tUSB\tConnected\tlocalhost\n")
        } else {
            assert_eq!(
                plan.arguments,
                ["-t", KEY, "shell", "param", "get", "const.ohos.fullname"]
            );
            format!("{DAYU200_FIRMWARE}\n")
        };
        Ok(Receipt {
            exit_status: 0,
            stdout: stdout.into_bytes(),
            stderr: vec![],
            truncated: false,
            duration: Duration::ZERO,
        })
    }
}

fn fresh_identity(
    _: &dyn HdcDispatch,
    usb: &dyn UsbProbe,
    key: &str,
    expected: &str,
) -> Result<NormalHardwareIdentity, &'static str> {
    assert_eq!(key, KEY);
    assert_eq!(expected, sha256_hex(KEY.as_bytes()));
    let identity = usb
        .single_hdc_normal(expected)
        .map_err(|_| "synthetic.usbMissing")?;
    Ok(NormalHardwareIdentity {
        normal_identity_sha256: identity.serial_digest_sha256,
        hardware_serial_sha256: sha256_hex(b"synthetic-cpu"),
        usb_topology: identity.topology,
        connector_identity_sha256: sha256_hex(b"synthetic-connector"),
        stdout_sha256: sha256_hex(b"synthetic-read-receipt"),
        stdout_byte_count: 22,
        vendor_serial: Some(arkdeck_provider_hdc::VendorSerialProof {
            serial_sha256: sha256_hex(b"synthetic-loader-sn"),
            source_sha256: sha256_hex(b"synthetic-dual-source-receipt"),
            source_byte_count: 32,
        }),
    })
}

#[test]
fn recommission_uses_the_fresh_attachment_without_rewriting_the_retained_binding() {
    for topology in ["42", "84"] {
        let fixture = Fixture::new(topology);
        let ordinary = fixture.read(false).unwrap();
        assert_eq!(ordinary.server_facts[ALIAS_TOPOLOGY], "42");
        assert!(!ordinary.server_facts.contains_key(CHAIN_FACT));
        assert_eq!(
            ordinary.server_facts["dayu200NormalLoaderHardwareIdentity"],
            "normalLoaderIdentity.boundLoaderIdentityMismatch"
        );

        let facts = fixture.read(true).unwrap();
        let chain = IdentityChain::from_facts(&facts).unwrap();
        assert_eq!(facts.server_facts[ALIAS_TOPOLOGY], topology);
        assert_eq!(chain.usb_topology, topology);
        assert_eq!(
            facts.server_facts[ALIAS_IDENTITY],
            chain.normal_identity_sha256
        );
        assert_eq!(chain.binding_revision, 1);
        assert_eq!(
            chain.binding_snapshot_sha256,
            sha256_hex(
                &serde_json::to_vec(&json!({
                    "revision": 1, "serialSHA256": sha256_hex(KEY.as_bytes()),
                "usbTopology": "42", "evidence": [format!("identity:serial-sha256={}", sha256_hex(KEY.as_bytes()))]
                }))
                .unwrap()
            )
        );
        fixture.assert_history_unchanged();
        assert_eq!(
            fixture.read(false).unwrap().server_facts[ALIAS_TOPOLOGY],
            "42"
        );
    }
}

#[test]
fn recommission_rejects_missing_or_inconsistent_fresh_identity_before_persisting() {
    let observers: [NormalHardwareIdentityObserver; 4] = [
        |hdc, usb, key, expected| {
            let mut observation = fresh_identity(hdc, usb, key, expected)?;
            observation.vendor_serial = None;
            Ok(observation)
        },
        |hdc, usb, key, expected| {
            let mut observation = fresh_identity(hdc, usb, key, expected)?;
            observation.normal_identity_sha256 = sha256_hex(b"other-cid");
            Ok(observation)
        },
        |hdc, usb, key, expected| {
            let mut observation = fresh_identity(hdc, usb, key, expected)?;
            observation.connector_identity_sha256.clear();
            Ok(observation)
        },
        |hdc, usb, key, expected| {
            let mut observation = fresh_identity(hdc, usb, key, expected)?;
            observation.usb_topology = "084".into();
            Ok(observation)
        },
    ];
    for observer in observers {
        let mut fixture = Fixture::new("84");
        fixture.facts.recommission_identity_observer = observer;
        assert_eq!(
            fixture.read(true).unwrap_err(),
            "recommission.identityChainIncomplete"
        );
        assert!(!fixture.root.join("normal-loader-identity").exists());
        fixture.assert_history_unchanged();
    }
}

#[test]
fn recommission_keeps_provider_refusals_and_requires_execution_facts_to_match_the_chain() {
    let mut fixture = Fixture::new("42");
    let facts = fixture.read(true).unwrap();
    for (key, value) in [
        (ALIAS_TOPOLOGY, "84".to_owned()),
        (ALIAS_IDENTITY, sha256_hex(b"other-cid")),
    ] {
        let mut drifted = facts.clone();
        drifted.server_facts.insert(key.into(), value);
        assert_eq!(
            IdentityChain::from_facts(&drifted).unwrap_err(),
            "recommission.identityChainDrifted"
        );
        drifted.server_facts.remove(key);
        assert_eq!(
            IdentityChain::from_facts(&drifted).unwrap_err(),
            "recommission.identityChainDrifted"
        );
    }
    fixture.facts.recommission_identity_observer =
        |_, _, _, _| Err("normalLoaderIdentity.usbChanged");
    assert_eq!(
        fixture.read(true).unwrap_err(),
        "normalLoaderIdentity.usbChanged"
    );
    fixture.assert_history_unchanged();
}
