//! The Rust agent execution owner raising Swift's physical-assistance
//! actions over the shared fake HDC: the part of Swift's physical-assistance
//! oracle (`rust/tests/fixtures/agent-human-action`) that needs no adoption,
//! no resume and no Job, replayed in its recorded order. A run that names no
//! target observes the fake's devices through the Target observation owner,
//! between two reads of the USB relations the exchange plugged, and raises
//! what a person must do (connect, trust or pick a device), or is refused
//! when a connected device's physical identity is unproved. The combined
//! human-action owner lists and shows those actions. Every answer is Swift's
//! once the identities the owners mint read as the oracle's labels; the fake
//! receives the oracle's four device lists; the execution records are
//! Swift's up to the observation identities and generations that Swift's
//! skipped resume advanced; and the Target document is untouched.
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::{WireError, canonical_json, sha256_hex};
use arkdeck_hoststore::{
    AgentEngine, AgentExecutionStore, ArtifactReadStore, HumanActionResources, JobAdmitter,
    JobPlanner, JobStore, Observing, Sources, TargetObservations, TargetStore,
};
use arkdeck_platform::VerifiedTool;
use arkdeck_provider_hdc::{ProcessDispatch, UsbRelation};
use serde_json::{Map, Value, json};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use support::{chmod, fixed_now, fixed_precise_now};

/// `HDCOracleFake`'s fixed root and lock, which the fake's driver names.
const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";

/// The oracle's exchanges these owners serve without an adoption, a resume
/// or a Job.
const SERVED: [&str; 19] = [
    "connect.run",
    "connect.rerun",
    "connect.status",
    "connect.list",
    "connect.show",
    "connect.waiting",
    "trust.run",
    "trust.abandonStale",
    "trust.abandon",
    "trust.expired",
    "trust.rerun",
    "ambiguous.run",
    "unproven.run",
    "refuse.listHalfFilter",
    "refuse.listKind",
    "refuse.listPageSize",
    "refuse.listCursor",
    "refuse.showUnknown",
    "refuse.showInvalid",
];

/// The kinds of identity the owners mint, which the oracle labels.
const KINDS: [&str; 4] = ["har", "resume", "candidate", "obs"];

/// Serializes every user of the fake's fixed root, Swift producers included.
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

/// The fake's root as `HDCOracleFake.install` leaves it.
fn install_fake(fixture: &Path) -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    fs::create_dir(&root).unwrap();
    chmod(&root, 0o700);
    fs::copy(fixture.join("hdc"), root.join("hdc")).unwrap();
    chmod(&root.join("hdc"), 0o700);
    fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
    fs::write(root.join("hdc-invocations.log"), b"").unwrap();
    root
}

/// A private state root holding the oracle's Target document, and the empty
/// owners beside it.
struct State(PathBuf);

impl State {
    fn new(fixture: &Path) -> Self {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("agent-human-action-raise-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for directory in [
            "",
            "targets-state",
            "artifacts",
            "jobs-state",
            "agent-executions",
            "human-action-snapshots",
        ] {
            let path = root.join(directory);
            fs::create_dir_all(&path).unwrap();
            chmod(&path, 0o700);
        }
        let targets = root.join("targets-state/targets.json");
        fs::copy(fixture.join("targets-state/targets.json"), &targets).unwrap();
        chmod(&targets, 0o600);
        Self(root)
    }
}

impl Drop for State {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
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

/// The oracle's labels for the identities the owners mint: `<har-1>` for the
/// first `har-` identity to appear, and so on for each kind.
#[derive(Default)]
struct Labels {
    labels: BTreeMap<String, String>,
    counts: BTreeMap<&'static str, usize>,
}

impl Labels {
    fn label(&mut self, text: &str) -> String {
        let mut out = String::new();
        let mut at = 0;
        'scan: while at < text.len() {
            for kind in KINDS {
                let start = at + kind.len() + 1;
                if text[at..].starts_with(kind)
                    && text[at + kind.len()..].starts_with('-')
                    && text.get(start..start + 36).is_some_and(is_uuid)
                {
                    let identity = &text[at..start + 36];
                    let label = match self.labels.get(identity) {
                        Some(label) => label.clone(),
                        None => {
                            let count = self.counts.entry(kind).or_default();
                            *count += 1;
                            let label = format!("<{kind}-{count}>");
                            self.labels.insert(identity.to_owned(), label.clone());
                            label
                        }
                    };
                    out.push_str(&label);
                    at = start + 36;
                    continue 'scan;
                }
            }
            let character = text[at..].chars().next().unwrap();
            out.push(character);
            at += character.len_utf8();
        }
        out
    }

    fn identity(&self, text: &str) -> String {
        let mut text = text.to_owned();
        for (identity, label) in &self.labels {
            text = text.replace(label.as_str(), identity);
        }
        text
    }
}

/// An owner's answer as the daemon frames it.
fn framed(answer: Result<Value, WireError>) -> Value {
    match answer {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => {
            let mut failure = Map::from_iter([
                ("code".into(), json!(error.code)),
                ("message".into(), json!(error.message)),
            ]);
            if let Some(details) = error.details {
                failure.insert("details".into(), Value::Object(details));
            }
            json!({"ok": false, "error": failure})
        }
    }
}

/// An observation's identity and generation, read alike: Swift's skipped
/// resume observed twice more, so both moved on there.
fn unnumbered(observation: &mut Value) {
    if let Some(observation) = observation.as_object_mut() {
        observation.insert("observationID".into(), json!("<obs>"));
        observation.insert("generation".into(), json!("<generation>"));
    }
}

/// A record's canonical text with its identities labelled and each
/// observation it names unnumbered.
fn comparable(labels: &mut Labels, bytes: &[u8]) -> Value {
    let mut record: Value =
        serde_json::from_str(&labels.label(std::str::from_utf8(bytes).unwrap())).unwrap();
    for action in record["actions"].as_array_mut().unwrap() {
        if let Some(observation) = action.get_mut("observation") {
            unnumbered(observation);
        }
        for selection in action["selections"].as_array_mut().unwrap() {
            unnumbered(&mut selection["observation"]);
        }
    }
    record
}

fn relations(value: &Value) -> Vec<UsbRelation> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|relation| UsbRelation::from_value(relation).unwrap())
        .collect()
}

fn execution_file(id: &str) -> String {
    format!("execution-{}.json", sha256_hex(id.as_bytes()))
}

#[test]
fn rust_raises_and_reads_the_physical_assistance_swift_asked_for() {
    let _lock = exclusive();
    let fixture = support::fixture("agent-human-action");
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture.join("cases.json")).unwrap()).unwrap();
    let hdc = install_fake(&fixture);
    let state = State::new(&fixture);
    let root = &state.0;
    let targets = TargetStore::open(&root.join("targets-state")).unwrap();
    let artifacts = ArtifactReadStore::open(&root.join("artifacts")).unwrap();
    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let agents = AgentExecutionStore::open(&root.join("agent-executions")).unwrap();
    let resources = HumanActionResources::open(&root.join("human-action-snapshots")).unwrap();
    let admitter = JobAdmitter {
        planner: JobPlanner {
            imports: None,
            artifacts: Some(&artifacts),
            analyzer: None,
            state_root: root,
            hdc: None,
        },
        jobs: &jobs,
        now: fixed_now,
    };
    let digest = sha256_hex(&fs::read(hdc.join("hdc")).unwrap());
    let dispatch =
        ProcessDispatch::new(VerifiedTool::open(hdc.join("hdc"), &digest).unwrap(), None);
    // What the oracle's harness plugged, until an exchange plugs again.
    let plugged: RefCell<Vec<UsbRelation>> = RefCell::new(Vec::new());
    let usb = || Ok::<_, String>(plugged.borrow().clone());
    let observer = TargetObservations::default();
    let clock = || "2026-09-14T00:00:00Z".to_owned();
    let engine = AgentEngine {
        targets: &targets,
        jobs: &jobs,
        admitter: &admitter,
        now: fixed_precise_now,
        observations: Some(Observing {
            owner: &observer,
            sources: Sources {
                dispatch: &dispatch,
                relations: &usb,
                targets: &targets,
                now: &clock,
            },
        }),
    };
    let mut labels = Labels::default();
    let mut replayed = 0;
    for exchange in cases["exchanges"].as_array().unwrap() {
        let name = exchange["name"].as_str().unwrap();
        if !SERVED.contains(&name) {
            continue;
        }
        if let Some(mode) = exchange["mode"].as_str() {
            fs::write(hdc.join("hdc-mode"), format!("{mode}\n")).unwrap();
        }
        if let Some(plug) = exchange.get("usbRelations") {
            *plugged.borrow_mut() = relations(plug);
        }
        let method = exchange["method"].as_str().unwrap();
        let params: Value =
            serde_json::from_str(&labels.identity(&exchange["params"].to_string())).unwrap();
        let params = params.as_object().unwrap();
        let answer = if method.starts_with("human-action.") {
            resources.answer(method, params, &agents)
        } else {
            agents
                .advance(method, params, &engine)
                .map(|answer| answer.value)
        };
        let text = String::from_utf8(canonical_json(&framed(answer)).unwrap()).unwrap();
        let mut answer: Value = serde_json::from_str(&labels.label(&text)).unwrap();
        if let Some(revision) = answer.pointer_mut("/result/snapshotRevision") {
            *revision = json!("<snapshotRevision>");
        }
        assert_eq!(answer, exchange["answer"], "{name}");
        replayed += 1;
    }
    assert_eq!(replayed, SERVED.len());

    // The fake listed the devices once for each run that observed them.
    let recorded = fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap();
    let recorded: Vec<&str> = recorded.lines().collect();
    let expected: String = [0, 10, 11, 12]
        .iter()
        .map(|line| format!("{}\n", recorded[*line]))
        .collect();
    assert_eq!(
        fs::read_to_string(hdc.join("hdc-invocations.log")).unwrap(),
        expected
    );
    // Nothing was adopted.
    assert_eq!(
        fs::read(root.join("targets-state/targets.json")).unwrap(),
        fs::read(fixture.join("targets-state/targets.json")).unwrap()
    );
    for execution in ["har-unproven", "har-trust", "har-ambiguous"] {
        let file = execution_file(execution);
        assert_eq!(
            comparable(
                &mut labels,
                &fs::read(root.join("agent-executions").join(&file)).unwrap()
            ),
            comparable(
                &mut Labels::default(),
                &fs::read(fixture.join("agent-executions").join(&file)).unwrap()
            ),
            "{execution}"
        );
    }
    // Swift resumed this one next; here it still waits, run twice.
    let connect: Value = serde_json::from_slice(
        &fs::read(
            root.join("agent-executions")
                .join(execution_file("har-connect")),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(connect["state"], "waitingForHuman");
    assert_eq!(connect["generation"], 4);
    assert_eq!(connect["actions"].as_array().unwrap().len(), 1);
}
