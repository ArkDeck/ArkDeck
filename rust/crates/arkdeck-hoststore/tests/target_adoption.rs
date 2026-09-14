//! Replays the Swift Target adoption oracle (`rust/tests/fixtures/target-adoption`,
//! produced by `TargetAdoptionOracleContractTests`) against the Rust Target
//! observation owner over the shared fake HDC. The root starts as the
//! oracle's did, with no Target adopted. Each recorded observation and
//! adoption is sent in order, while the fake answers in the mode the oracle
//! names and the owner reads the USB relations the exchange names
//! (`usbRelations`, and after `usbRelationsAfter.reads` reads, its
//! `relations`). Every answer — its result, or its refusal's code, message
//! and details — must be Swift's once the observation identities read as the
//! oracle's labels, and the fake's calls, the Target document and the
//! display names must be Swift's byte for byte. The availability exchanges
//! are the daemon's and are not replayed here.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    Sources, TargetObservations, TargetStore, adoption_answer, parse_reference,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{ProcessDispatch, UsbRelation};
use serde_json::{Map, Value, json};
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use support::chmod;

/// `HDCOracleFake`'s fixed root and lock, which the fake's driver names.
const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";

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
/// random (`HDCOracleHarness.RandomIdentities`): `<obs-1>` for the first to
/// appear, and so on.
#[derive(Default)]
struct Labels {
    labels: BTreeMap<String, String>,
    identities: BTreeMap<String, String>,
}

impl Labels {
    /// The text with every observation identity read as its label, a new
    /// one labelled in the order it first appears.
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

    /// The text with every label read as the identity it stands for.
    fn identity(&self, text: &str) -> String {
        let mut text = text.to_owned();
        for (label, identity) in &self.identities {
            text = text.replace(label.as_str(), identity);
        }
        text
    }
}

/// The relations an exchange plugged, and those it changes to after that
/// many reads.
type Plugged = (Vec<UsbRelation>, Option<(u64, Vec<UsbRelation>)>);

fn relations(value: &Value) -> Vec<UsbRelation> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|relation| UsbRelation::from_value(relation).unwrap())
        .collect()
}

#[test]
fn rust_adopts_the_swift_fake_device() {
    let _lock = exclusive();
    let fixture = support::fixture("target-adoption");
    let cases = support::document(&fixture, "cases.json");
    let provenance = support::document(&fixture, "provenance.json");
    let root = rebuild(&fixture);
    let digest = sha256_hex(&fs::read(root.join("hdc")).unwrap());
    assert_eq!(provenance["hdcSHA256"], digest.as_str());
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let dispatch =
        ProcessDispatch::new(VerifiedTool::open(root.join("hdc"), &digest).unwrap(), None);
    let plugged: RefCell<Plugged> = RefCell::new((Vec::new(), None));
    let reads = Cell::new(0u64);
    let observed = || {
        reads.set(reads.get() + 1);
        let (current, after) = &*plugged.borrow();
        Ok::<_, String>(match after {
            Some((count, later)) if reads.get() > *count => later.clone(),
            _ => current.clone(),
        })
    };
    let now_utc = provenance["nowUTC"].as_str().unwrap().to_owned();
    let now = || now_utc.clone();
    let sources = Sources {
        dispatch: &dispatch,
        relations: &observed,
        targets: &targets,
        now: &now,
    };
    let owner = TargetObservations::default();
    let mut labels = Labels::default();
    let mut replayed = 0;
    for exchange in cases["exchanges"].as_array().unwrap() {
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
            *plugged.borrow_mut() = (relations(current), after);
            reads.set(0);
        }
        let params: Map<String, Value> =
            serde_json::from_str(&labels.identity(&exchange["params"].to_string())).unwrap();
        let answer = match method {
            "device.observations" => {
                assert!(params.is_empty(), "{name}");
                owner
                    .snapshot(&sources, None)
                    .and_then(|snapshot| snapshot.answer(&targets))
            }
            "target.adopt" => parse_reference(&params).and_then(|reference| {
                owner
                    .adopt(&sources, &reference)
                    .map(|adopted| adoption_answer(&adopted, &reference))
            }),
            other => panic!("{name}: unexpected method {other}"),
        };
        let produced = match answer {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(error) => {
                let wire = error.wire();
                let mut refusal = json!({"code": wire.code, "message": wire.message});
                if let Some(details) = wire.details {
                    refusal["details"] = Value::Object(details);
                }
                json!({"ok": false, "error": refusal})
            }
        };
        let produced: Value = serde_json::from_str(&labels.label(&produced.to_string())).unwrap();
        let recorded = &exchange["answer"];
        assert_eq!(produced["ok"], recorded["ok"], "{name}");
        if recorded["ok"] == true {
            assert_eq!(produced["result"], recorded["result"], "{name}");
        } else {
            assert_eq!(produced["error"], recorded["error"], "{name}");
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
            String::from_utf8(fs::read(root.join(file)).unwrap()).unwrap(),
            String::from_utf8(fs::read(fixture.join(file)).unwrap()).unwrap(),
            "{file}"
        );
    }
}
