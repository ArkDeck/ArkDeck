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
//! The availability exchanges are not this owner's.
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION, sha256_hex};
use arkdeck_control::Control;
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{ProcessDispatch, UsbRelation};
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

#[test]
fn the_daemon_observes_and_adopts_the_swift_fake_device_through_the_control_layer() {
    let _lock = exclusive();
    let fixture = fixture();
    let cases = read_json(&fixture.join("cases.json"));
    let root = rebuild(&fixture);
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    let plugged: Arc<Mutex<Plugged>> = Arc::new(Mutex::new((Vec::new(), None)));
    let reads = Arc::new(AtomicU64::new(0));
    let usb = {
        let (plugged, reads) = (plugged.clone(), reads.clone());
        move || {
            let read = reads.fetch_add(1, Ordering::SeqCst) + 1;
            let (current, after) = &*plugged.lock().unwrap();
            Ok::<_, String>(match after {
                Some((count, later)) if read > *count => later.clone(),
                _ => current.clone(),
            })
        }
    };
    let host = crate::host::Host::from_environment()
        .with_targets(arkdeck_hoststore::TargetStore::open(&root.join("targets-state")).unwrap())
        .with_development_hdc(Some(ProcessDispatch::new(
            VerifiedTool::open(root.join("hdc"), &digest).unwrap(),
            None,
        )))
        .with_usb_relations(Arc::new(usb));
    let control = Control::new(host).unwrap();
    let mut labels = Labels::default();
    let mut replayed = 0;
    for (index, exchange) in cases["exchanges"].as_array().unwrap().iter().enumerate() {
        let name = exchange["name"].as_str().unwrap();
        let method = exchange["method"].as_str().unwrap();
        if method == "target.availability" {
            continue;
        }
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
        let recorded: Value =
            serde_json::from_str(&mask_times(&exchange["answer"].to_string())).unwrap();
        if recorded["ok"] == true {
            assert_eq!(reply["result"], recorded["result"], "{name}: {reply}");
        } else {
            assert_eq!(reply["error"], recorded["error"], "{name}: {reply}");
        }
        replayed += 1;
    }
    assert_eq!(replayed, 18, "every observation and adoption of the oracle");
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
