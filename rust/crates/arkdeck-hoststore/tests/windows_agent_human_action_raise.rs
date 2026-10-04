//! On Windows (TASK-XPA-004): the Rust agent execution owner raising the
//! physical-assistance actions Swift's owner raised, the part of Swift's
//! physical-assistance oracle (`rust/tests/fixtures/agent-human-action`,
//! produced by `AgentHumanActionOracleContractTests`) that needs no adoption,
//! no resume and no Job, replayed in its recorded order over owners laid down
//! owner-only on NTFS (`agent_human_action_raise.rs` is the macOS replay, over
//! the shell fake HDC):
//!
//! * no device, then a device that is offline: `physicalConnection`, the
//!   execution `waitingForHuman`, listed and shown by the human-action owner;
//! * a device that is unauthorised: `deviceTrustPrompt`, `waitingForHuman`,
//!   then abandoned, expired and run again as Swift answered;
//! * two connected devices: `ambiguousIdentity` with both as choices, the
//!   bootstrap's `needsSelection` as a person answers it;
//! * a connected device whose physical identity is unproved: refused;
//! * every refusal of the human-action owner's list and show.
//!
//! A run that names no Target observes the devices through the Target
//! observation owner (the Swift `DeviceBootstrapMachine` counterpart), between
//! two reads of the USB relations each exchange plugged. The devices come from
//! a scripted HDC (`HdcDispatch`) answering `list targets -v` in the state the
//! oracle's fake HDC answered it for each exchange's mode: no `hdc` runs, and
//! no registered Windows HDC is needed, since the owners are fed a dispatch
//! directly. Every answer is Swift's once the identities the owners
//! mint read as the oracle's labels; the dispatch is asked for the four device
//! lists the oracle's fake recorded; the execution records are Swift's up to
//! the observation identities and generations Swift's skipped resume advanced;
//! and the Target document is untouched.
#![cfg(windows)]

use arkdeck_contract::{WireError, canonical_json, sha256_hex};
use arkdeck_hoststore::{
    AgentEngine, AgentExecutionStore, ArtifactReadStore, HumanActionResources, JobAdmitter,
    JobPlanner, JobStore, Observing, Sources, TargetObservations, TargetStore,
};
use arkdeck_platform::HostDirectory;
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt, UsbRelation};
use serde_json::{Map, Value, json};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The oracle's exchanges these owners serve without an adoption, a resume
/// or a Job (the macOS replay's list).
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

const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const OTHER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/agent-human-action")
}

fn fixed_now() -> Option<String> {
    Some("2026-09-14T00:00:00Z".into())
}

fn fixed_precise_now() -> Option<String> {
    Some("2026-09-14T00:00:00.000Z".into())
}

/// The oracle's fake HDC (`hdc-answers.sh`) for what these exchanges ask
/// of it: `list targets -v` in the state the current mode names. Every call
/// is recorded as the fake logs it: each argument followed by U+001F.
struct Scripted {
    mode: RefCell<String>,
    calls: RefCell<Vec<String>>,
}

impl HdcDispatch for Scripted {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let arguments = plan.arguments.join(" ");
        self.calls.borrow_mut().push(
            plan.arguments
                .iter()
                .map(|argument| format!("{argument}\u{1f}"))
                .collect(),
        );
        let row = |key: &str, state: &str| format!("{key}\t\tUSB\t{state}\tlocalhost\n");
        let stdout = match (arguments.as_str(), self.mode.borrow().as_str()) {
            ("list targets -v", "offline") => row(KEY, "Offline"),
            ("list targets -v", "unauthorized") => row(KEY, "Unauthorized"),
            ("list targets -v", "twoDevices") => row(KEY, "Connected") + &row(OTHER, "Connected"),
            ("list targets -v", "otherDevice") => row(OTHER, "Connected"),
            ("list targets -v", _) => row(KEY, "Connected"),
            ("-v", _) => "Ver: 3.2.0d\n".to_owned(),
            (other, mode) => panic!("unscripted `{other}` in mode {mode}"),
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

/// A private root holding the oracle's Target document, and the empty
/// owners beside it, owner-only on NTFS.
struct Root(PathBuf);

impl Root {
    fn new(fixture: &Path) -> Self {
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        // The temporary directory as the file system resolves it: the host
        // store opens a directory only by that spelling, never by a short
        // (`RUNNER~1`) or verbatim one.
        let temporary = std::env::temp_dir().canonicalize().unwrap();
        let temporary = match temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
        {
            Some(plain) => PathBuf::from(plain),
            None => temporary,
        };
        let root = temporary.join(format!("ad-winagent-raise-{nonce:016x}"));
        HostDirectory::open_or_create_private(&root).unwrap();
        for directory in [
            "targets-state",
            "artifacts",
            "jobs-state",
            "agent-executions",
            "human-action-snapshots",
        ] {
            HostDirectory::open_or_create_private(&root.join(directory)).unwrap();
        }
        HostDirectory::open(&root.join("targets-state"))
            .unwrap()
            .create_document(
                "targets.json",
                &fs::read(fixture.join("targets-state/targets.json")).unwrap(),
            )
            .unwrap();
        Self(root)
    }
}

impl Drop for Root {
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
fn rust_raises_and_reads_the_physical_assistance_swift_asked_for_on_windows() {
    let fixture = fixture();
    let cases: Value =
        serde_json::from_slice(&fs::read(fixture.join("cases.json")).unwrap()).unwrap();
    let root = Root::new(&fixture);
    let root = &root.0;
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
            workspace: None,
        },
        jobs: &jobs,
        now: fixed_now,
        authority: None,
    };
    let dispatch = Scripted {
        mode: RefCell::new("normal".into()),
        calls: RefCell::new(Vec::new()),
    };
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
            *dispatch.mode.borrow_mut() = mode.to_owned();
        }
        if let Some(plug) = exchange.get("usbRelations") {
            *plugged.borrow_mut() = relations(plug);
        }
        let method = exchange["method"].as_str().unwrap();
        let params: Value =
            serde_json::from_str(&labels.identity(&exchange["params"].to_string())).unwrap();
        let params = params.as_object().unwrap();
        let answer = if method.starts_with("human-action.") {
            // As the daemon composes it without a managed HDC server: no
            // control action holds an approval.
            resources.answer(method, params, &agents, None)
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

    // The devices were listed once for each run that observed them, as the
    // oracle's fake recorded them (its log's lines 1, 11, 12 and 13).
    let recorded = fs::read_to_string(fixture.join("hdc-invocations.log")).unwrap();
    let recorded: Vec<&str> = recorded.lines().collect();
    let expected: Vec<String> = [0, 10, 11, 12]
        .iter()
        .map(|line| recorded[*line].to_owned())
        .collect();
    assert_eq!(*dispatch.calls.borrow(), expected);
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
    // The three categories Swift raised, each by a run that then waits for a
    // person.
    let categories: Vec<String> = cases["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|exchange| {
            SERVED.contains(&exchange["name"].as_str().unwrap())
                && exchange["method"] == "agent.run"
        })
        .filter(|exchange| exchange["answer"]["result"]["state"] == "waitingForHuman")
        .filter_map(|exchange| {
            exchange["answer"]["result"]["humanAction"]["category"]
                .as_str()
                .map(str::to_owned)
        })
        .collect();
    for category in [
        "physicalConnection",
        "deviceTrustPrompt",
        "ambiguousIdentity",
    ] {
        assert!(
            categories.iter().any(|seen| seen == category),
            "{category}: {categories:?}"
        );
    }
}
