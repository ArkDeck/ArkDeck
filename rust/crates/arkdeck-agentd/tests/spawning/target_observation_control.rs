//! `device.observations` and `target.adopt` through the control layer. The
//! daemon's own host, composed with the development HDC over the shared fake
//! and the USB relations each exchange of the Swift Target adoption oracle
//! (`rust/tests/fixtures/target-adoption`) names, answers every recorded
//! observation and adoption through `Control` as Swift's daemon answered it,
//! once the observation identities read as the oracle's labels and every time
//! as `<time>`: the daemon runs on the host's clock. The control layer admits
//! each answer under the method's published schema. The fake's calls, the
//! Target document and the display names are Swift's, their times read alike;
//! byte equality on the oracle's clock is hoststore's `tests/target_adoption.rs`.
//! Availability reads the same durable binding without a fresh HDC dispatch.
//! Its tool leg reflects this composition's absent managed server; its host
//! operation entries share operation.list's current availability source.
//!
//! The same oracle replays through the Runtime's own relation reader, over a
//! host census that lists each relation's board as the I/O Registry would,
//! and an uncertain census fails closed through the same layer.
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, sha256_hex};
use arkdeck_control::Control;
use arkdeck_platform::{RegistryUnavailable, UsbHostDevice, VerifiedTool};
use arkdeck_provider_hdc::{
    DAYU200_NORMAL_PRODUCT_ID, ProcessDispatch, ROCKUSB_VENDOR_ID, UsbRegistryRelations,
    UsbRelation, UsbRelations,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// `HDCOracleFake`'s fixed root and lock, which the fake's driver names.
const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/target-adoption")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap_or_else(|error| panic!("{path:?}: {error}")))
        .unwrap_or_else(|error| panic!("{path:?}: {error}"))
}

/// Serializes every user of the fixed root, Swift producers included.
fn exclusive() -> File {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK)
        .unwrap();
    lock.lock().unwrap();
    lock
}

fn chmod(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

/// The root as `HDCOracleFake.install` left it, with an empty Target store.
fn rebuild(fixture: &Path) -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [root.clone(), root.join("targets-state")] {
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    fs::copy(fixture.join("hdc"), root.join("hdc")).unwrap();
    chmod(&root.join("hdc"), 0o700);
    fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
    fs::write(root.join("hdc-invocations.log"), b"").unwrap();
    root
}

/// Whether `text` is a lowercase UUID, as Swift spells one.
fn is_uuid(text: &str) -> bool {
    text.len() == 36
        && text.bytes().enumerate().all(|(index, byte)| {
            if [8, 13, 18, 23].contains(&index) {
                byte == b'-'
            } else {
                byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
            }
        })
}

/// The oracle's labels for the observation identities the owner mints at
/// random: `<obs-1>` for the first to appear, and so on.
#[derive(Default)]
struct Labels {
    labels: BTreeMap<String, String>,
    identities: BTreeMap<String, String>,
}

impl Labels {
    fn label(&mut self, text: &str) -> String {
        let mut out = String::new();
        let mut rest = text;
        while let Some(at) = rest.find("obs-") {
            match rest.get(at..at + 40) {
                Some(identity) if is_uuid(&identity[4..]) => {
                    out.push_str(&rest[..at]);
                    let count = self.labels.len() + 1;
                    let label = self
                        .labels
                        .entry(identity.to_owned())
                        .or_insert_with(|| format!("<obs-{count}>"))
                        .clone();
                    self.identities.insert(label.clone(), identity.to_owned());
                    out.push_str(&label);
                    rest = &rest[at + 40..];
                }
                _ => {
                    out.push_str(&rest[..at + 4]);
                    rest = &rest[at + 4..];
                }
            }
        }
        out + rest
    }

    fn identity(&self, text: &str) -> String {
        let mut text = text.to_owned();
        for (label, identity) in &self.identities {
            text = text.replace(label.as_str(), identity);
        }
        text
    }
}

/// `text` with every UTC time read as `<time>`.
fn mask_times(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut at = 0;
    while at < bytes.len() {
        if let Some(length) = time_at(&bytes[at..]) {
            out.push_str("<time>");
            at += length;
        } else {
            let character = text[at..].chars().next().unwrap();
            out.push(character);
            at += character.len_utf8();
        }
    }
    out
}

/// The length of the `YYYY-MM-DDTHH:MM:SS[.fraction]Z` time `bytes` starts
/// with, if it starts with one.
fn time_at(bytes: &[u8]) -> Option<usize> {
    let shape = b"dddd-dd-ddTdd:dd:dd";
    let shaped = bytes.len() > shape.len()
        && shape.iter().zip(bytes).all(|(want, got)| {
            if *want == b'd' {
                got.is_ascii_digit()
            } else {
                want == got
            }
        });
    if !shaped {
        return None;
    }
    let mut end = shape.len();
    if bytes[end] == b'.' {
        let digits = bytes[end + 1..]
            .iter()
            .take_while(|byte| byte.is_ascii_digit())
            .count();
        if digits == 0 {
            return None;
        }
        end += 1 + digits;
    }
    (bytes.get(end) == Some(&b'Z')).then_some(end + 1)
}

fn relations(value: &Value) -> Vec<UsbRelation> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|relation| UsbRelation::from_value(relation).unwrap())
        .collect()
}

/// The relations an exchange plugged, and those it changes to after that
/// many reads.
type Plugged = (Vec<UsbRelation>, Option<(u64, Vec<UsbRelation>)>);

/// A current frame of `method`, without its LF.
fn frame(method: &str, id: &str, params: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
        "id": id, "method": method, "params": params,
    }))
    .unwrap()
}

/// The relations the current exchange plugged, as of this read: those it
/// changes to once it has been read more than its count, else its first.
fn plugged_now(plugged: &Mutex<Plugged>, reads: &AtomicU64) -> Vec<UsbRelation> {
    let read = reads.fetch_add(1, Ordering::SeqCst) + 1;
    let (current, after) = &*plugged.lock().unwrap();
    match after {
        Some((count, later)) if read > *count => later.clone(),
        _ => current.clone(),
    }
}

/// Every exchange of the oracle through `Control`, over the development HDC
/// in `root` and the USB relations `usb` reads, with each exchange's
/// relations plugged as it names them; every answer and the files the oracle
/// left are asserted.
fn replay_oracle(
    root: &Path,
    fixture: &Path,
    usb: Arc<dyn UsbRelations + Send + Sync>,
    plugged: &Mutex<Plugged>,
    reads: &AtomicU64,
) {
    let cases = read_json(&fixture.join("cases.json"));
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    let host = crate::host::Host::from_environment()
        .with_targets(arkdeck_hoststore::TargetStore::open(&root.join("targets-state")).unwrap())
        .with_development_hdc(Some(ProcessDispatch::new(
            VerifiedTool::open(root.join("hdc"), &digest).unwrap(),
            None,
        )))
        .with_usb_relations(usb);
    let control = Control::new(host).unwrap();
    let mut labels = Labels::default();
    let mut replayed = 0;
    for (index, exchange) in cases["exchanges"].as_array().unwrap().iter().enumerate() {
        let name = exchange["name"].as_str().unwrap();
        let method = exchange["method"].as_str().unwrap();
        if let Some(mode) = exchange["mode"].as_str() {
            fs::write(root.join("hdc-mode"), format!("{mode}\n")).unwrap();
        }
        if let Some(current) = exchange.get("usbRelations") {
            let after = exchange.get("usbRelationsAfter").map(|after| {
                (
                    after["reads"].as_u64().unwrap(),
                    relations(&after["relations"]),
                )
            });
            *plugged.lock().unwrap() = (relations(current), after);
            reads.store(0, Ordering::SeqCst);
        }
        let params: Value =
            serde_json::from_str(&labels.identity(&exchange["params"].to_string())).unwrap();
        let reply = control.handle_frame(&frame(method, &format!("adoption-{index:02}"), params));
        let reply: Value = serde_json::from_str(&mask_times(
            &labels.label(&String::from_utf8_lossy(reply.trim_ascii_end())),
        ))
        .unwrap();
        let mut recorded: Value =
            serde_json::from_str(&mask_times(&exchange["answer"].to_string())).unwrap();
        if method == "target.availability" && recorded["ok"] == true {
            // The Swift oracle supplied managed-HDC diagnostics; the Rust
            // development composition supplies only an external executable.
            recorded["result"]["tool"] = json!({
                "state": "absent", "reasonCode": "runtime_tool_unavailable",
                "reason": "Runtime has no managed HDC server",
            });
            let operations: Value = serde_json::from_slice(&control.handle_frame(&frame(
                "operation.list",
                "availability-operations",
                json!({}),
            )))
            .unwrap();
            recorded["result"]["operations"]["items"] = Value::Array(
                operations["result"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|operation| {
                        json!({
                            "reference": operation["reference"],
                            "availability": operation["availability"],
                            "reasons": operation["reasons"],
                            "reasonCodes": operation["reasonCodes"],
                        })
                    })
                    .collect(),
            );
        }
        if recorded["ok"] == true {
            assert_eq!(reply["result"], recorded["result"], "{name}: {reply}");
        } else {
            assert_eq!(reply["error"], recorded["error"], "{name}: {reply}");
        }
        replayed += 1;
    }
    assert_eq!(
        replayed, 21,
        "every observation, adoption and availability of the oracle"
    );
    for file in [
        "hdc-invocations.log",
        "targets-state/targets.json",
        "targets-state/target-display-names.json",
    ] {
        assert_eq!(
            mask_times(&String::from_utf8(fs::read(root.join(file)).unwrap()).unwrap()),
            mask_times(&String::from_utf8(fs::read(fixture.join(file)).unwrap()).unwrap()),
            "{file}"
        );
    }
}

#[test]
fn the_daemon_observes_and_adopts_the_swift_fake_device_through_the_control_layer() {
    let _turn = crate::turn();
    let _lock = exclusive();
    let fixture = fixture();
    let root = rebuild(&fixture);
    let plugged: Arc<Mutex<Plugged>> = Arc::new(Mutex::new((Vec::new(), None)));
    let reads = Arc::new(AtomicU64::new(0));
    let usb = {
        let (plugged, reads) = (plugged.clone(), reads.clone());
        move || Ok::<_, String>(plugged_now(&plugged, &reads))
    };
    replay_oracle(&root, &fixture, Arc::new(usb), &plugged, &reads);

    // A cold composition resolves the persisted binding without replaying
    // observation/adoption or changing its revision. Availability performs no
    // device round trip even when a development HDC dispatcher exists above.
    let restarted =
        Control::new(crate::host::Host::from_environment().with_targets(
            arkdeck_hoststore::TargetStore::open(&root.join("targets-state")).unwrap(),
        ))
        .unwrap();
    let target = json!({"targetId":"TGT-3ba3f5f43b92"});
    let reply: Value = serde_json::from_slice(&restarted.handle_frame(&frame(
        "target.availability",
        "cold-availability",
        target.clone(),
    )))
    .unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["result"]["binding"]["state"], "ready");
    assert_eq!(reply["result"]["presence"]["state"], "unresolved");
    assert_eq!(reply["result"]["tool"]["state"], "absent");
    for params in [
        json!({}),
        json!({"targetId":""}),
        json!({"targetId":17}),
        json!({"targetId":"TGT-3ba3f5f43b92", "refresh":true}),
    ] {
        let reply: Value = serde_json::from_slice(&restarted.handle_frame(&frame(
            "target.availability",
            "bad-availability",
            params,
        )))
        .unwrap();
        assert_eq!(reply["error"]["code"], "invalidParams", "{reply}");
    }
    let original = fs::read(root.join("targets-state/targets.json")).unwrap();
    fs::write(root.join("targets-state/targets.json"), b"{broken").unwrap();
    let reply: Value = serde_json::from_slice(&restarted.handle_frame(&frame(
        "target.availability",
        "broken-availability",
        target,
    )))
    .unwrap();
    assert_eq!(reply["error"]["code"], "recordUnreadable", "{reply}");
    fs::write(root.join("targets-state/targets.json"), original).unwrap();
    assert_eq!(
        fs::read(root.join("hdc-invocations.log")).unwrap(),
        fs::read(fixture.join("hdc-invocations.log")).unwrap()
    );
}

/// The oracle's candidate: the fake's one connect key and USB serial.
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

/// The board of `relation` as the host census lists it in its HDC-normal
/// personality: the location as its topology, the attachment as its registry
/// entry ID, and the product name between quotes as the board reports it.
fn listed(relation: &UsbRelation) -> UsbHostDevice {
    UsbHostDevice {
        serial: relation.serial.clone(),
        vendor_id: relation.vendor_id,
        product_id: relation.product_id,
        topology: relation.location.clone(),
        product_name: Some("\"HDC Device\"".into()),
        registry_entry_id: Some(relation.attachment_id),
    }
}

/// A host census listing `relations`' boards among entries the reader must
/// pass over, each with the candidate's serial, so that reading any of them
/// as a relation would leave the candidate unproved: a board named otherwise
/// or not at all, one without a registry entry ID, the Loader personality,
/// and another vendor's device.
fn census_listing(relations: &[UsbRelation]) -> Vec<UsbHostDevice> {
    let passed_over = |registry_entry_id: Option<u64>, product_name: Option<&str>| UsbHostDevice {
        serial: KEY.into(),
        vendor_id: ROCKUSB_VENDOR_ID,
        product_id: DAYU200_NORMAL_PRODUCT_ID,
        topology: "200".into(),
        product_name: product_name.map(str::to_owned),
        registry_entry_id,
    };
    let mut listing = vec![
        passed_over(Some(90), Some("\"HDC Device 2\"")),
        passed_over(Some(91), None),
        passed_over(None, Some("\"HDC Device\"")),
        UsbHostDevice {
            product_id: 0x350a,
            ..passed_over(Some(92), None)
        },
        UsbHostDevice {
            vendor_id: 0x05ac,
            product_id: 0x0342,
            ..passed_over(Some(93), Some("Keyboard"))
        },
    ];
    listing.extend(relations.iter().map(listed));
    listing
}

/// The same Swift oracle with the Runtime's own reader in place of its
/// scripted relations: each exchange's relations reach the Target owner only
/// through a census of the boards they name, read as Swift's
/// `registeredDAYU200()` reads the registry. Every answer and file is the
/// oracle's, so the registry reader proves, refuses and adopts exactly as the
/// relations Swift's coordinator was given.
#[test]
fn the_registry_reader_adopts_the_swift_fake_device_as_the_oracle_s_relations_do() {
    let _turn = crate::turn();
    let _lock = exclusive();
    let fixture = fixture();
    let root = rebuild(&fixture);
    let plugged: Arc<Mutex<Plugged>> = Arc::new(Mutex::new((Vec::new(), None)));
    let reads = Arc::new(AtomicU64::new(0));
    let census = {
        let (plugged, reads) = (plugged.clone(), reads.clone());
        move || Ok(census_listing(&plugged_now(&plugged, &reads)))
    };
    replay_oracle(
        &root,
        &fixture,
        Arc::new(UsbRegistryRelations::new(census)),
        &plugged,
        &reads,
    );
}

/// What the uncertain census answers: its listing, and the read after which
/// every read fails.
type Census = (Vec<UsbHostDevice>, u64, Option<u64>);

/// A census the Runtime cannot take, or a board the registry lists without an
/// attachment, proves nothing through `Control`: the observation fails in
/// Swift's words or lists the candidate unproved, and no adoption writes a
/// Target — also when only the adoption's final read fails. Only a board
/// listed unchanged throughout is adopted.
#[test]
fn an_uncertain_registry_fails_closed_through_the_control_layer() {
    let _turn = crate::turn();
    let _lock = exclusive();
    let root = rebuild(&fixture());
    fs::write(root.join("hdc-mode"), "normal\n").unwrap();
    let board = UsbRelation {
        serial: KEY.into(),
        location: "100".into(),
        attachment_id: 30,
        vendor_id: ROCKUSB_VENDOR_ID,
        product_id: DAYU200_NORMAL_PRODUCT_ID,
    };
    let state: Arc<Mutex<Census>> = Arc::new(Mutex::new((
        census_listing(std::slice::from_ref(&board)),
        0,
        None,
    )));
    let census = {
        let state = state.clone();
        move || {
            let mut state = state.lock().unwrap();
            state.1 += 1;
            match state.2 {
                Some(last) if state.1 > last => Err(RegistryUnavailable::Services(-536_870_212)),
                _ => Ok(state.0.clone()),
            }
        }
    };
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    let control = Control::new(
        crate::host::Host::from_environment()
            .with_targets(
                arkdeck_hoststore::TargetStore::open(&root.join("targets-state")).unwrap(),
            )
            .with_development_hdc(Some(ProcessDispatch::new(
                VerifiedTool::open(root.join("hdc"), &digest).unwrap(),
                None,
            )))
            .with_usb_relations(Arc::new(UsbRegistryRelations::new(census))),
    )
    .unwrap();
    let call = |method: &str, params: Value| -> Value {
        serde_json::from_slice(&control.handle_frame(&frame(method, "uncertain", params))).unwrap()
    };
    let observe = || {
        let reply = call("device.observations", json!({}));
        assert_eq!(reply["ok"], true, "{reply}");
        let row = reply["result"]["observations"][0].clone();
        let reference = json!({
            "candidate": KEY,
            "observationId": row["observationId"],
            "observationGeneration": reply["result"]["snapshotGeneration"],
        });
        (
            row["observationContinuity"].as_str().unwrap().to_owned(),
            reference,
        )
    };
    let fail_after = |more: u64| {
        let mut state = state.lock().unwrap();
        state.2 = Some(state.1 + more);
    };
    let targets = root.join("targets-state/targets.json");
    let unavailable = json!({
        "code": "internalError",
        "message": "admissionRejected(\"USB registry unavailable\")",
    });

    // A census that cannot be taken fails the observation, which breaks its
    // continuity: the reference from before no longer adopts.
    let (continuity, reference) = observe();
    assert_eq!(continuity, "relationProven");
    fail_after(0);
    assert_eq!(call("device.observations", json!({}))["error"], unavailable);
    let reply = call("target.adopt", reference);
    assert_eq!(reply["error"]["code"], "resourceConflict", "{reply}");
    assert!(!targets.exists(), "no Target was adopted");

    // Only the adoption's final read fails: the adoption fails in the same
    // words and writes nothing.
    state.lock().unwrap().2 = None;
    let (continuity, reference) = observe();
    assert_eq!(continuity, "relationProven");
    // The adoption re-reads the bracket (two reads) before its final read.
    fail_after(2);
    assert_eq!(call("target.adopt", reference)["error"], unavailable);
    assert!(!targets.exists(), "no Target was adopted");

    // A board the registry lists without an attachment proves nothing.
    {
        let mut state = state.lock().unwrap();
        state.0 = census_listing(&[]);
        state.0.push(UsbHostDevice {
            registry_entry_id: None,
            ..listed(&board)
        });
        state.2 = None;
    }
    let (continuity, reference) = observe();
    assert_eq!(continuity, "generationScoped");
    let reply = call("target.adopt", reference);
    assert_eq!(reply["error"]["code"], "admissionDenied", "{reply}");
    assert_eq!(
        reply["error"]["message"],
        "this observation has no independently proved physical relation"
    );
    assert!(!targets.exists(), "no Target was adopted");

    // Listed unchanged throughout, the board is adopted.
    state.lock().unwrap().0 = census_listing(std::slice::from_ref(&board));
    let (continuity, reference) = observe();
    assert_eq!(continuity, "relationProven");
    let reply = call("target.adopt", reference);
    assert_eq!(reply["result"]["outcome"], "adopted", "{reply}");
    assert_eq!(reply["result"]["targetId"], "TGT-3ba3f5f43b92");
    assert!(targets.exists());
}
