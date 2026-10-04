//! The Target store and the Target observation owner on NTFS (TASK-XPA-004,
//! XPA-AC-1 and XPA-AC-2), in process: the Swift Target adoption oracle's
//! device (`rust/tests/fixtures/target-adoption`) read through an in-process
//! scripted HDC, its USB relation proved by a synthetic Plug and Play node
//! read by the Windows census rule (`UsbHostDevice::from_device_node`), and
//! the owners writing a private directory the store itself created.
//!
//! What it proves on Windows: the adopted Target is the oracle's, named by
//! the SHA-256 of the normalised serial, and `targets.json` is the oracle's
//! bytes; a repeated adoption answers the same receipt and writes nothing; an
//! unauthorized candidate stops for the person; a node without a serial, or
//! two nodes carrying the candidate's serial, prove nothing and nothing is
//! adopted; a torn Target document and a lock name that is not a lock file
//! fail closed without a write. Every refusal is pre-admission with no new
//! dispatch. No process, device or board is involved; the serial is the
//! oracle's placeholder. (Two writers racing and a writer waiting out another
//! owner's locks are the store's unit tests, which run on NTFS too.)
#![cfg(windows)]

use arkdeck_hoststore::{
    ObservationError, Sources, TargetObservations, TargetStore, adoption_answer, parse_reference,
};
use arkdeck_platform::{DeviceNode, HostDirectory, NodeProperty, NodeValue, UsbHostDevice};
use arkdeck_provider_hdc::{
    DispatchFailure, HdcDispatch, ProcessPlan, Receipt, UsbRegistryRelations,
    stable_identity_sha256_for_serial,
};
use serde_json::{Map, Value, json};
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The oracle's connect key, which the board's USB serial equals.
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
/// The oracle's clock.
const NOW: &str = "2026-09-14T00:00:00Z";

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/target-adoption")
        .join(name)
}

/// A private root created by the store itself, removed afterwards.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-win-targets-{:032x}",
            u128::from_le_bytes(arkdeck_platform::random_bytes().unwrap())
        ));
        HostDirectory::open_or_create_private(&path).unwrap();
        Self(path)
    }
    fn targets(&self) -> Option<Vec<u8>> {
        std::fs::read(self.0.join("targets.json")).ok()
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A present device node as the Windows census hands one to its rule.
#[derive(Clone)]
struct Node {
    instance_id: String,
    location: &'static str,
}
impl DeviceNode for Node {
    fn instance_id(&self) -> Option<String> {
        Some(self.instance_id.clone())
    }
    fn property(&self, key: NodeProperty) -> Option<NodeValue> {
        match key {
            NodeProperty::IsPresent => Some(NodeValue::Boolean(true)),
            NodeProperty::HardwareIds => Some(NodeValue::TextList(vec![
                "USB\\VID_2207&PID_5000&REV_0223".into(),
                "USB\\VID_2207&PID_5000".into(),
            ])),
            NodeProperty::LocationPaths => Some(NodeValue::TextList(vec![self.location.into()])),
            NodeProperty::BusReportedDeviceDesc => Some(NodeValue::Text("HDC Device".into())),
            NodeProperty::LastArrivalDate => Some(NodeValue::FileTime(133_000_000_000_000_017)),
        }
    }
}

/// The DAYU200 in its HDC-normal personality on one port, its serial the
/// oracle's connect key, spelt in upper case as the 2026-10-04 sample's
/// instance ID spells it (the census folds it).
fn board(location: &'static str) -> Node {
    Node {
        instance_id: format!("USB\\VID_2207&PID_5000\\{}", KEY.to_ascii_uppercase()),
        location,
    }
}

fn census(nodes: &[Node]) -> Vec<UsbHostDevice> {
    nodes
        .iter()
        .filter_map(UsbHostDevice::from_device_node)
        .collect()
}

/// The oracle's HDC: `-v` and `list targets -v`, the list in the state
/// `mode` names; every call counted.
struct Scripted {
    mode: Cell<&'static str>,
    calls: Cell<usize>,
}
impl Scripted {
    fn new() -> Self {
        Self {
            mode: Cell::new("normal"),
            calls: Cell::new(0),
        }
    }
}
/// The registered Windows tuple's capture of 2026-10-04 (CHG-2026-078, c2),
/// redacted: its `-v` bytes and a `list targets -v` file.
fn c2_capture(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/hdc-windows/c2")
        .join(name);
    String::from_utf8(std::fs::read(path).unwrap()).unwrap()
}

impl HdcDispatch for Scripted {
    /// In the `c2` modes, the executable stands for the registered Windows
    /// tuple, as `ProcessDispatch` names it for the real `hdc.exe`.
    fn registered_windows_tuple(&self) -> Option<&'static arkdeck_provider_hdc::WindowsHdcTuple> {
        self.mode.get().starts_with("c2").then(|| {
            arkdeck_provider_hdc::windows_tuple(
                "c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e",
            )
            .unwrap()
        })
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        self.calls.set(self.calls.get() + 1);
        let stdout = match (plan.arguments.join(" ").as_str(), self.mode.get()) {
            ("-v", "c2" | "c2-uart") => c2_capture("no-board/version.stdout.bin"),
            ("list targets -v", "c2") => {
                c2_capture("board-connected/list-targets-board-connected.stdout.bin")
            }
            ("list targets -v", "c2-uart") => c2_capture("no-board/list-targets-empty.stdout.bin"),
            ("-v", _) => "Ver: 3.2.0d\n".to_owned(),
            ("list targets -v", "unauthorized") => {
                format!("{KEY}\t\tUSB\tUnauthorized\tlocalhost\n")
            }
            ("list targets -v", _) => format!("{KEY}\t\tUSB\tConnected\tlocalhost\n"),
            (other, _) => panic!("unscripted {other}"),
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

/// The census a test replaces between steps.
type Census = Box<dyn Fn() -> Result<Vec<UsbHostDevice>, arkdeck_platform::RegistryUnavailable>>;

/// One owner over one root, the census it reads replaceable per step.
struct Owner {
    root: Root,
    targets: TargetStore,
    observations: TargetObservations,
    hdc: Scripted,
    nodes: std::rc::Rc<RefCell<Vec<Node>>>,
    relations: UsbRegistryRelations<Census>,
}
impl Owner {
    fn new() -> Self {
        let root = Root::new();
        let targets = TargetStore::open(&root.0).unwrap();
        let nodes = std::rc::Rc::new(RefCell::new(vec![board(
            "PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(3)",
        )]));
        let read = std::rc::Rc::clone(&nodes);
        Self {
            root,
            targets,
            observations: TargetObservations::default(),
            hdc: Scripted::new(),
            nodes,
            relations: UsbRegistryRelations::new(Box::new(move || Ok(census(&read.borrow())))),
        }
    }
    fn sources(&self) -> Sources<'_> {
        Sources {
            dispatch: &self.hdc,
            relations: &self.relations,
            targets: &self.targets,
            now: &|| NOW.to_owned(),
        }
    }
    /// `device.observations`: the one row's continuity and its reference.
    fn observe(&self) -> (String, Map<String, Value>) {
        let snapshot = self.observations.snapshot(&self.sources(), None).unwrap();
        let row = &snapshot.observations[0];
        let reference = json!({
            "candidate": row.candidate.connect_key,
            "observationId": row.observation_id,
            "observationGeneration": snapshot.generation.to_string(),
        });
        (
            row.continuity().to_owned(),
            reference.as_object().unwrap().clone(),
        )
    }
    /// `target.adopt` of `reference`, answered as the daemon answers it.
    fn adopt(&self, reference: &Map<String, Value>) -> Result<Value, Value> {
        let parsed = parse_reference(reference).map_err(|error| wire(&error))?;
        self.observations
            .adopt(&self.sources(), &parsed)
            .map(|adopted| adoption_answer(&adopted, &parsed))
            .map_err(|error| wire(&error))
    }
}

fn wire(error: &ObservationError) -> Value {
    serde_json::to_value(error.wire()).unwrap()
}

/// A refusal before admission that dispatched nothing new.
fn refused(answer: Result<Value, Value>, code: &str) {
    let error = answer.expect_err("refused");
    assert_eq!(error["code"], code, "{error}");
    assert_eq!(error["details"]["phase"], "preAdmission", "{error}");
    assert_eq!(error["details"]["newDispatchCount"], 0, "{error}");
}

#[test]
fn the_oracle_board_is_adopted_once_as_the_target_macos_adopts() {
    let owner = Owner::new();
    let (continuity, reference) = owner.observe();
    assert_eq!(continuity, "relationProven");
    let adopted = owner.adopt(&reference).unwrap();
    assert_eq!(
        adopted,
        json!({"outcome": "adopted", "targetId": "TGT-3ba3f5f43b92", "bindingRevision": 1,
            "observationId": reference["observationId"], "snapshotGeneration": "1"})
    );
    // XPA-AC-1: the stable identity is the SHA-256 of the normalised serial
    // (trimmed, lowercased), whatever case the serial arrives in, and the
    // Target document is the bytes the Swift owner wrote for this device.
    let identity = arkdeck_contract::sha256_hex(KEY.as_bytes());
    assert_eq!(stable_identity_sha256_for_serial(KEY), identity);
    assert_eq!(
        stable_identity_sha256_for_serial(&format!(" {}\n", KEY.to_uppercase())),
        identity
    );
    let written = owner.root.targets().unwrap();
    assert_eq!(
        written,
        std::fs::read(fixture("targets-state/targets.json")).unwrap(),
        "targets.json is the Swift owner's bytes"
    );
    // XPA-AC-2: a repeated adoption answers the same receipt, re-proving the
    // observation, and writes nothing.
    assert_eq!(owner.adopt(&reference).unwrap(), adopted);
    assert_eq!(owner.root.targets().unwrap(), written);
    // A restarted store reads the Target back.
    let reopened = TargetStore::open(&owner.root.0).unwrap();
    let listed = reopened.handle("target.list", &Map::new(), NOW).unwrap();
    assert_eq!(listed[0]["targetId"], "TGT-3ba3f5f43b92");
    let shown = reopened
        .handle(
            "target.show",
            json!({"targetId": "TGT-3ba3f5f43b92"}).as_object().unwrap(),
            NOW,
        )
        .unwrap();
    assert_eq!(shown["stablePhysicalIdentitySha256"], identity.as_str());
}

/// XPA-005 over CHG-2026-078: the registered Windows tuple's own capture,
/// six CR LF columns with the host's UART rows, is observed and adopted by
/// the same owner; the UART rows are never candidates.
#[test]
fn the_registered_windows_tuple_capture_is_observed_and_adopted() {
    let owner = Owner::new();
    owner.hdc.mode.set("c2-uart");
    let snapshot = owner.observations.snapshot(&owner.sources(), None).unwrap();
    assert!(snapshot.observations.is_empty(), "UART rows are no device");

    owner.hdc.mode.set("c2");
    let (continuity, reference) = owner.observe();
    assert_eq!(continuity, "relationProven");
    let adopted = owner.adopt(&reference).unwrap();
    assert_eq!(adopted["outcome"], "adopted", "{adopted}");
    assert_eq!(adopted["targetId"], "TGT-3ba3f5f43b92", "{adopted}");
    let listed = owner
        .targets
        .handle("target.list", &Map::new(), NOW)
        .unwrap();
    assert_eq!(listed[0]["toolVersion"], "3.2.0g", "{listed}");
    // Repeated: the same receipt, nothing rewritten.
    let written = owner.root.targets().unwrap();
    assert_eq!(owner.adopt(&reference).unwrap(), adopted);
    assert_eq!(owner.root.targets().unwrap(), written);
}

#[test]
fn an_unauthorized_candidate_stops_for_the_person() {
    let owner = Owner::new();
    owner.hdc.mode.set("unauthorized");
    let (continuity, reference) = owner.observe();
    assert_eq!(continuity, "relationProven");
    refused(owner.adopt(&reference), "targetTrustPending");
    assert_eq!(owner.root.targets(), None, "no Target was adopted");
}

#[test]
fn no_serial_or_two_boards_with_one_serial_prove_nothing() {
    let owner = Owner::new();
    // A Windows-generated, port-derived instance suffix is no serial.
    *owner.nodes.borrow_mut() = vec![Node {
        instance_id: "USB\\VID_2207&PID_5000\\5&1a2b3c&0&3".into(),
        location: "PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(3)",
    }];
    let (continuity, reference) = owner.observe();
    assert_eq!(continuity, "generationScoped");
    refused(owner.adopt(&reference), "admissionDenied");
    // Two boards carrying the candidate's serial on two ports: neither
    // relation is the candidate's alone, so none is selected.
    *owner.nodes.borrow_mut() = vec![
        board("PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(3)"),
        board("PCIROOT(0)#PCI(1400)#USBROOT(0)#USB(4)"),
    ];
    let (continuity, reference) = owner.observe();
    assert_eq!(continuity, "generationScoped");
    let calls = owner.hdc.calls.get();
    refused(owner.adopt(&reference), "admissionDenied");
    assert_eq!(owner.hdc.calls.get(), calls, "a refusal dispatches nothing");
    assert_eq!(owner.root.targets(), None, "no Target was adopted");
}

#[test]
fn a_torn_target_document_or_a_replaced_lock_fails_closed_without_a_write() {
    let owner = Owner::new();
    let (_, reference) = owner.observe();
    owner.adopt(&reference).unwrap();
    let whole = owner.root.targets().unwrap();
    let names = std::fs::read(owner.root.0.join("target-display-names.json")).unwrap();
    // A byte prefix, as a writer that died mid-write would leave one.
    std::fs::write(owner.root.0.join("targets.json"), &whole[..whole.len() / 2]).unwrap();
    let rename =
        json!({"targetId": "TGT-3ba3f5f43b92", "expectedGeneration": "1", "name": "Bench"});
    for (method, params) in [
        ("target.list", Map::new()),
        (
            "target.display-name.set",
            rename.as_object().unwrap().clone(),
        ),
    ] {
        let error = owner.targets.handle(method, &params, NOW).unwrap_err();
        assert_eq!(error.code, "recordUnreadable", "{method}");
    }
    assert!(TargetStore::open(&owner.root.0).is_err());
    assert_eq!(
        owner.root.targets().unwrap(),
        &whole[..whole.len() / 2],
        "nothing repaired"
    );
    assert_eq!(
        std::fs::read(owner.root.0.join("target-display-names.json")).unwrap(),
        names
    );
    // The whole document back, and the Target lock's name taken by a
    // directory: no lock is held, so nothing is read or written.
    std::fs::write(owner.root.0.join("targets.json"), &whole).unwrap();
    std::fs::remove_file(owner.root.0.join(".targets.lock")).unwrap();
    std::fs::create_dir(owner.root.0.join(".targets.lock")).unwrap();
    let error = owner
        .targets
        .handle("target.display-name.set", rename.as_object().unwrap(), NOW)
        .unwrap_err();
    assert_eq!(error.code, "recordUnreadable");
    assert_eq!(
        std::fs::read(owner.root.0.join("target-display-names.json")).unwrap(),
        names
    );
}
