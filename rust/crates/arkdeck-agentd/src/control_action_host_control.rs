//! `runtime.hdc.impact-preview`, `runtime.hdc.restart` and
//! `control-action.list`, `.show` and `.reconcile` through the control layer,
//! with the impact approval a restart requests read through
//! `human-action.show`, `.list` and the resume routes, as Swift's daemon
//! answers them once its HDC server host has started: every exchange of the
//! committed corpora such a daemon answered, replayed over the union owner,
//! the HDC control-action owner and the combined human-action owner in the
//! order the Swift test made it, with that test's clock, Runtime starts,
//! catalog digest and identities, and an impact source answering the impact
//! that test's source observed. The exchanges come from
//! `HDCControlActionContractTests` (a fake impact source: one ready preview,
//! read, listed and reconciled, its restart and the approval shown, listed
//! and resumed outside a foreground console) and
//! `ControlActionWithHostContractTests` (the production impact source over
//! the fixture HDC: the with-host refusals, an unobserved and a blocked
//! preview, a restart and an expiry, and a listing over two pages; then a
//! blocked preview of a team-signed tool, of an unsigned one, and one whose
//! Target inventory changed while it was read, each read, reconciled and
//! listed; and its restart tests, whose source answers a registered healthy
//! server's facts over the production reading: an approval requested once
//! and refused in each way before, read, listed and reconciled; restarts
//! whose fresh reading failed or named a Target adopted after the review;
//! approvals that drifted or expired with their action; and the approvals of
//! an unsigned and a team-signed tool). Answers compare whole; a page's
//! random snapshot revision and next cursor are checked and set aside, and
//! the second page is asked through the cursor this owner issued. What only
//! a foreground console reaches is counted, not replayed (C2b): the console
//! challenge `human-action.resume` issues there, and the lifecycle a person's
//! answer to it starts.
use arkdeck_contract::{
    CATALOG_DIGEST, CONTRACT_IDENTITY, DeviceObservationsResult, PROTOCOL_VERSION, WireError,
    sha256_hex,
};
use arkdeck_control::{Control, HdcStatus, HostServices};
use arkdeck_hoststore::{
    AgentExecutionStore, ControlActionResources, HdcControlActions, HumanActionResources, Impact,
    ImpactReading, ImpactSource, OwnerContext,
};
use arkdeck_platform::HostDirectory;
use serde_json::{Map, Value, json};
use std::collections::{BTreeSet, VecDeque};
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

const METHODS: [&str; 9] = [
    "runtime.hdc.impact-preview",
    "runtime.hdc.restart",
    "control-action.show",
    "control-action.reconcile",
    "control-action.list",
    "human-action.show",
    "human-action.list",
    "human-action.resume",
    "agent.resume",
];
const HDC_UNAVAILABLE: &str = "the Runtime HDC control-action owner is unavailable";
const TUPLE_REQUIRED: &str = "restart requires one exact control-action preview tuple";
const UNPROVEN_IMPACT: &str = "fresh HDC impact could not be proven";
const DIFFERENT_IMPACT: &str = "fresh HDC impact differs from the reviewed preview";
/// What only a foreground console receives from `human-action.resume`: the
/// challenge it issues, and the action a person's answer to it advanced.
const CONSOLE_ANSWERS: [&str; 2] = [
    "arkdeck.impact-approval-challenge/1",
    "arkdeck.control-action/1",
];
/// 2026-09-01T00:00:00Z, the fake impact source's clock.
const FAKE_SOURCE_START: u64 = 1_788_220_800_000;
/// 2026-09-19T00:00:00Z, the production impact source's.
const HOST_START: u64 = 1_789_776_000_000;
/// The preview's own members; the rest is the impact.
const PREVIEW_METADATA: [&str; 12] = [
    "schemaVersion",
    "controlActionId",
    "previewId",
    "kind",
    "action",
    "createdAt",
    "expiresAt",
    "owner",
    "confirmationRequired",
    "dispatchCount",
    "digestAlgorithm",
    "previewDigest",
];

fn corpus(method: &str) -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
        "../../../Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    ));
    fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{path:?}: {error}"))
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// Whether a daemon with an HDC server host answered this corpus line: a
/// control action or a page of them, a lifecycle refusal only an HDC
/// control-action owner gives, or an answer about the impact approval a
/// control action requested.
fn with_host(method: &str, frame: &Value) -> bool {
    let owned = |value: &Value| value["owner"]["kind"] == "controlAction";
    match method {
        "human-action.show" => frame["ok"] == true && owned(&frame["result"]),
        "human-action.list" => frame["params"]["ownerKind"] == "controlAction",
        "human-action.resume" => {
            frame["ok"] == true && (owned(&frame["result"]) || console_answer(method, frame))
        }
        "agent.resume" => owned(&frame["error"]["details"]["humanAction"]),
        _ if frame["ok"] == true => {
            frame["result"].get("controlActionId").is_some()
                || frame["result"]["items"]
                    .as_array()
                    .is_some_and(|items| !items.is_empty())
        }
        _ => {
            matches!(method, "runtime.hdc.impact-preview" | "runtime.hdc.restart")
                && frame["error"]["message"] != HDC_UNAVAILABLE
        }
    }
}

/// Whether a line is what only a foreground console receives (C2b): the
/// challenge, or the lifecycle a person's answer to it started.
fn console_answer(method: &str, frame: &Value) -> bool {
    method == "human-action.resume"
        && frame["ok"] == true
        && CONSOLE_ANSWERS
            .iter()
            .any(|schema| frame["result"]["schemaVersion"] == *schema)
}

/// The records a frame answers with: itself, or a page's items.
fn records(frame: &Value) -> Vec<&Value> {
    if frame["ok"] != true {
        return Vec::new();
    }
    match frame["result"]["items"].as_array() {
        Some(items) => items.iter().collect(),
        None => vec![&frame["result"]],
    }
}

/// The control actions a frame shows: its records, or the action a refusal
/// invalidated.
fn actions(frame: &Value) -> Vec<&Value> {
    let mut actions = records(frame);
    if frame["error"]["details"]["controlAction"].is_object() {
        actions.push(&frame["error"]["details"]["controlAction"]);
    }
    actions
        .into_iter()
        .filter(|action| action.get("controlActionId").is_some())
        .collect()
}

/// A restart's parameters naming a record's exact preview.
fn tuple(record: &Value) -> Value {
    json!({"controlAction": record["controlActionId"],
        "previewId": record["preview"]["previewId"],
        "previewDigest": record["preview"]["previewDigest"]})
}

/// The source the replay answers with: one exact impact, or none.
struct Replay {
    reading: Mutex<Result<ImpactReading, String>>,
}

impl ImpactSource for Replay {
    fn endpoint_reference(&self) -> String {
        format!("hdc-endpoint:{}", sha256_hex(b"127.0.0.1:8710"))
    }

    fn read_impact(&self) -> Result<ImpactReading, String> {
        self.reading.lock().unwrap().clone()
    }
}

/// A host whose control-action routes are the union owner over the HDC
/// control-action owner and the replayed source, and whose human-action
/// routes are the combined owner over it and an agent execution owner
/// holding no execution.
struct ReplayHost {
    resources: ControlActionResources,
    source: Arc<Replay>,
    agents: AgentExecutionStore,
    humans: HumanActionResources,
}

impl HostServices for ReplayHost {
    fn observed_at(&self) -> String {
        "2026-09-19T00:00:00Z".into()
    }
    fn hdc_status(&self, deep: bool) -> HdcStatus {
        HdcStatus::unavailable(deep, "hdc.notConfigured")
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "device observations are not served here".into(),
            details: None,
        })
    }
    fn control_action(
        &self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, WireError> {
        self.resources.answer(
            method,
            params,
            Some(self.source.as_ref() as &dyn ImpactSource),
        )
    }
    fn human_action(&self, method: &str, params: &Map<String, Value>) -> Result<Value, WireError> {
        self.humans
            .answer(method, params, &self.agents, Some(&self.resources))
    }
    /// Only the resumes of an approval: no execution is served here.
    fn agent_execution(
        &self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, WireError> {
        self.humans
            .resume_control_action(method, params, &self.agents, &self.resources)
            .unwrap_or_else(|| {
                Err(WireError {
                    code: "rejected".into(),
                    message: "no agent execution is served here".into(),
                    details: None,
                })
            })
    }
}

/// What the corpora say of one request identity's action.
struct Action {
    id: String,
    preview_id: Option<String>,
    impact: Option<Impact>,
    catalog: String,
    /// The random identities of its approval's `har-` and `resume-`.
    approval: Option<(String, String)>,
}

/// Every with-host corpus line, and which of them the replay reproduced.
struct Corpora {
    lines: Vec<(&'static str, usize, Value)>,
    replayed: BTreeSet<(&'static str, usize)>,
}

impl Corpora {
    fn load() -> Self {
        let mut lines = Vec::new();
        for method in METHODS {
            for (index, frame) in corpus(method).into_iter().enumerate() {
                if with_host(method, &frame) {
                    lines.push((method, index + 1, frame));
                }
            }
        }
        Self {
            lines,
            replayed: BTreeSet::new(),
        }
    }

    /// Whether a line shows the action of a request identity. The published
    /// view's corpora can predate an action a later recording added.
    fn shows(&self, request: &str) -> bool {
        self.lines.iter().any(|(_, _, frame)| {
            actions(frame)
                .iter()
                .any(|action| action["actionRequestId"] == request)
        })
    }

    /// The action of a request identity, from every line that shows it.
    fn action(&self, request: &str) -> Action {
        let mut found: Option<Action> = None;
        for (_, _, frame) in &self.lines {
            for record in actions(frame) {
                if record["actionRequestId"] != request {
                    continue;
                }
                let action = found.get_or_insert_with(|| Action {
                    id: record["controlActionId"]
                        .as_str()
                        .unwrap()
                        .strip_prefix("control-action-")
                        .unwrap()
                        .to_owned(),
                    preview_id: None,
                    impact: None,
                    catalog: record["catalogDigest"].as_str().unwrap().to_owned(),
                    approval: None,
                });
                if let Value::Object(preview) = &record["preview"] {
                    let facts = preview
                        .iter()
                        .filter(|(key, _)| !PREVIEW_METADATA.contains(&key.as_str()))
                        .map(|(key, value)| (key.clone(), value.clone()))
                        .collect();
                    action.impact = Some(Impact::new(facts).unwrap());
                    action.preview_id = Some(
                        preview["previewId"]
                            .as_str()
                            .unwrap()
                            .strip_prefix("preview-")
                            .unwrap()
                            .to_owned(),
                    );
                }
                if let Value::Object(approval) = &record["humanAction"] {
                    let identity = |key: &str, prefix: &str| {
                        approval[key]
                            .as_str()
                            .unwrap()
                            .strip_prefix(prefix)
                            .unwrap()
                            .to_owned()
                    };
                    action.approval = Some((
                        identity("actionId", "har-"),
                        identity("resumeReference", "resume-"),
                    ));
                }
            }
        }
        found.unwrap_or_else(|| panic!("no committed line shows {request}"))
    }

    /// The one with-host line `select` picks.
    fn line(&self, method: &str, select: impl Fn(&Value) -> bool) -> (&'static str, usize, Value) {
        let mut matches = self
            .lines
            .iter()
            .filter(|(line_method, _, frame)| *line_method == method && select(frame));
        let found = matches
            .next()
            .unwrap_or_else(|| panic!("no committed {method} line matches"))
            .clone();
        assert!(matches.next().is_none(), "two {method} lines match");
        found
    }

    /// The line of a request identity's answer in `state`.
    fn answered(&self, method: &str, request: &str, state: &str) -> (&'static str, usize, Value) {
        self.line(method, |frame| {
            frame["ok"] == true
                && frame["result"]["actionRequestId"] == request
                && frame["result"]["state"] == state
        })
    }

    /// The page whose items are these request identities, in order.
    fn page(&self, params: Value, requests: &[&str]) -> (&'static str, usize, Value) {
        let requests: Vec<Value> = requests.iter().map(|request| json!(request)).collect();
        self.line("control-action.list", |frame| {
            let items: Vec<Value> = records(frame)
                .into_iter()
                .map(|record| record["actionRequestId"].clone())
                .collect();
            let mut asked = frame["params"].clone();
            if let Some(fields) = asked.as_object_mut() {
                fields.remove("cursor");
            }
            asked == params && items == requests
        })
    }

    /// The with-host refusal of `method` with this message and request.
    fn refusal(&self, method: &str, message: &str, request: Value) -> (&'static str, usize, Value) {
        self.line(method, |frame| {
            frame["ok"] == false
                && frame["error"]["message"] == message
                && frame["params"]["actionRequestId"] == request
        })
    }

    /// The restart refusal with this code whose parameters `select` picks.
    fn restart_refusal(
        &self,
        code: &str,
        select: impl Fn(&Value) -> bool,
    ) -> (&'static str, usize, Value) {
        self.line("runtime.hdc.restart", |frame| {
            frame["ok"] == false && frame["error"]["code"] == code && select(frame)
        })
    }

    /// The `factsDrifted` refusal of a restart whose invalidated action is
    /// this request identity's.
    fn drifted(&self, message: &str, request: &str) -> (&'static str, usize, Value) {
        self.restart_refusal("factsDrifted", |frame| {
            frame["error"]["message"] == message
                && frame["error"]["details"]["controlAction"]["actionRequestId"] == request
        })
    }
}

/// One replay: a state root with the union owner's directory, the HDC
/// owner's and the human-action owners', the clock, the source and the
/// identities the next previews and restarts take.
struct Scenario {
    root: PathBuf,
    clock: Arc<AtomicU64>,
    source: Arc<Replay>,
    ids: Arc<Mutex<VecDeque<String>>>,
}

impl Scenario {
    fn new(start: u64) -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "control-action-host-control-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let directory = HostDirectory::open(&root).unwrap();
        for name in [
            "control-action-snapshots",
            "hdc-control-actions",
            "agent-executions",
            "human-action-snapshots",
        ] {
            directory.private_child(name).unwrap();
        }
        Self {
            root,
            clock: Arc::new(AtomicU64::new(start)),
            source: Arc::new(Replay {
                reading: Mutex::new(Err("no reading".into())),
            }),
            ids: Arc::new(Mutex::new(VecDeque::new())),
        }
    }

    /// A Runtime start: its epoch, the catalog it binds.
    fn start(&self, epoch: &str, catalog: &str) -> Control<ReplayHost> {
        let clock = Arc::clone(&self.clock);
        let ids = Arc::clone(&self.ids);
        let owner = HdcControlActions::open(
            &self.root.join("hdc-control-actions"),
            OwnerContext {
                epoch: epoch.into(),
                catalog: catalog.into(),
                clock: Box::new(move || Some(clock.load(Ordering::SeqCst))),
                uuid: Box::new(move || {
                    Ok(ids
                        .lock()
                        .unwrap()
                        .pop_front()
                        .expect("a replayed identity"))
                }),
            },
        )
        .unwrap();
        let resources = ControlActionResources::open(&self.root.join("control-action-snapshots"))
            .unwrap()
            .with_hdc(owner);
        Control::new(ReplayHost {
            resources,
            source: Arc::clone(&self.source),
            agents: AgentExecutionStore::open(&self.root.join("agent-executions")).unwrap(),
            humans: HumanActionResources::open(&self.root.join("human-action-snapshots")).unwrap(),
        })
        .unwrap()
    }

    /// The next preview's identities: its action's, then its preview's.
    fn identities(&self, action: &Action) {
        let mut ids = self.ids.lock().unwrap();
        ids.push_back(action.id.clone());
        if let Some(preview) = &action.preview_id {
            ids.push_back(preview.clone());
        }
    }

    /// The next restart's identities: its approval's `har-` and `resume-`.
    fn approval_identities(&self, action: &Action) {
        let (approval, resume) = action.approval.clone().expect("a recorded approval");
        let mut ids = self.ids.lock().unwrap();
        ids.push_back(approval);
        ids.push_back(resume);
    }

    fn observe(&self, action: Option<&Action>) {
        *self.source.reading.lock().unwrap() = match action.and_then(|a| a.impact.clone()) {
            Some(impact) => Ok(ImpactReading {
                impact,
                relations: Vec::new(),
                blocker: None,
            }),
            None => Err("empty observation output".into()),
        };
    }

    /// The action's impact once a Target was adopted after its review: the
    /// fresh reading names it, the reviewed preview does not. No frame holds
    /// that reading, so any Target identity reads the same.
    fn observe_adopted(&self, action: &Action) {
        let mut facts = action.impact.clone().unwrap().value().clone();
        facts.insert(
            "affectedTargetIds".into(),
            json!(["TGT-adopted-after-review"]),
        );
        *self.source.reading.lock().unwrap() = Ok(ImpactReading {
            impact: Impact::new(facts).unwrap(),
            relations: Vec::new(),
            blocker: None,
        });
    }

    fn advance(&self, milliseconds: i64) {
        if milliseconds >= 0 {
            self.clock
                .fetch_add(milliseconds.unsigned_abs(), Ordering::SeqCst);
        } else {
            self.clock
                .fetch_sub(milliseconds.unsigned_abs(), Ordering::SeqCst);
        }
    }
}

impl Drop for Scenario {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn reply(control: &Control<ReplayHost>, method: &str, params: &Value) -> Value {
    let request = serde_json::to_vec(&json!({
        "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
        "id": "control-action-host", "method": method, "params": params,
    }))
    .unwrap();
    serde_json::from_slice(control.handle_frame(&request).trim_ascii_end()).unwrap()
}

/// A preview no committed line holds (its answer was the same as another
/// line's), answered ready over the preview the corpora show for it.
fn ready(control: &Control<ReplayHost>, action: &Action, request: &str) -> Value {
    let answer = reply(
        control,
        "runtime.hdc.impact-preview",
        &json!({"action": "restart", "actionRequestId": request,
            "serverEndpointRef": format!("hdc-endpoint:{}", sha256_hex(b"127.0.0.1:8710")),
            "expectedServerGeneration": "100000023"}),
    );
    let record = answer["result"].clone();
    assert_eq!(record["state"], "previewReady", "{answer}");
    assert_eq!(
        record["controlActionId"],
        json!(format!("control-action-{}", action.id))
    );
    assert_eq!(
        record["preview"]["previewId"],
        json!(format!("preview-{}", action.preview_id.as_ref().unwrap()))
    );
    record
}

/// A restart no committed line holds, answered with its approval: the one the
/// corpora show for the action, waiting.
fn approved(control: &Control<ReplayHost>, action: &Action, record: &Value) -> Value {
    let answer = reply(control, "runtime.hdc.restart", &tuple(record));
    let awaiting = answer["result"].clone();
    assert_eq!(awaiting["state"], "awaitingImpactApproval", "{answer}");
    let (approval, resume) = action.approval.clone().unwrap();
    assert_eq!(
        awaiting["humanAction"]["actionId"],
        json!(format!("har-{approval}"))
    );
    assert_eq!(
        awaiting["humanAction"]["resumeReference"],
        json!(format!("resume-{resume}"))
    );
    assert_eq!(awaiting["humanAction"]["status"], "waiting");
    awaiting
}

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

/// Sends the line's request (with `params` instead, when given) and compares
/// the answer with the line; returns the answer.
fn replay(
    corpora: &mut Corpora,
    control: &Control<ReplayHost>,
    line: (&'static str, usize, Value),
    params: Option<Value>,
) -> Value {
    let (method, index, frame) = line;
    let context = format!("{method} line {index}");
    let answer = reply(control, method, params.as_ref().unwrap_or(&frame["params"]));
    assert_eq!(answer["ok"], frame["ok"], "{context}: {answer}");
    if frame["ok"] == true {
        let mut expected = frame["result"].clone();
        if expected.get("snapshotRevision").is_some() {
            let revision = answer["result"]["snapshotRevision"].as_str().unwrap();
            assert!(is_uuid(revision), "{context}: {revision}");
            expected["snapshotRevision"] = json!(revision);
            if let Some(cursor) = answer["result"]["nextCursor"].as_str() {
                let (issued, token) = cursor.split_once('.').unwrap();
                assert!(issued == revision && is_uuid(token), "{context}: {cursor}");
                assert!(expected["nextCursor"].is_string(), "{context}");
                expected["nextCursor"] = json!(cursor);
            }
        }
        assert_eq!(answer["result"], expected, "{context}");
    } else {
        assert_eq!(answer["error"], frame["error"], "{context}");
    }
    corpora.replayed.insert((method, index));
    answer
}

/// The approval a record carries, as `human-action.show` answers it; and as
/// the only item `human-action.list` pages for its owner.
fn assert_approval_served(control: &Control<ReplayHost>, record: &Value) {
    let approval = record["humanAction"].clone();
    let shown = reply(
        control,
        "human-action.show",
        &json!({"humanAction": approval["actionId"]}),
    );
    assert_eq!(shown["result"], approval, "{shown}");
    let page = reply(
        control,
        "human-action.list",
        &json!({"ownerKind": "controlAction", "owner": record["controlActionId"]}),
    );
    assert_eq!(page["result"]["items"], json!([approval]), "{page}");
}

#[test]
fn every_with_host_exchange_of_the_corpora_is_answered_as_swift_recorded_it() {
    let mut corpora = Corpora::load();

    // The fake impact source's action: previewed, read, listed, reconciled;
    // then its restart requests the approval (the source's clock is frozen),
    // once, and the human-action owner serves it.
    let cli = corpora.action("cli-action");
    let scenario = Scenario::new(FAKE_SOURCE_START);
    let control = scenario.start("epoch", &cli.catalog);
    scenario.identities(&cli);
    scenario.observe(Some(&cli));
    let preview = corpora.answered("runtime.hdc.impact-preview", "cli-action", "previewReady");
    replay(&mut corpora, &control, preview, None);
    let id = json!(format!("control-action-{}", cli.id));
    for method in ["control-action.show", "control-action.reconcile"] {
        let line = corpora.answered(method, "cli-action", "previewReady");
        replay(
            &mut corpora,
            &control,
            line,
            Some(json!({"controlAction": id})),
        );
    }
    let page = corpora.page(json!({"pageSize": 1}), &["cli-action"]);
    replay(&mut corpora, &control, page, None);
    scenario.approval_identities(&cli);
    let line = corpora.answered(
        "runtime.hdc.restart",
        "cli-action",
        "awaitingImpactApproval",
    );
    let approval =
        replay(&mut corpora, &control, line.clone(), None)["result"]["humanAction"].clone();
    // A lost receipt answers the same approval.
    replay(&mut corpora, &control, line, None);
    let line = corpora.line("human-action.show", |_| true);
    replay(&mut corpora, &control, line, None);
    let line = corpora.line("human-action.list", |_| true);
    replay(&mut corpora, &control, line, None);
    // Outside a foreground console a resume never advances it: `agent.resume`
    // cannot consume it, and `human-action.resume` gets it back unchanged,
    // with or without a preseeded challenge response.
    let line = corpora.line("agent.resume", |_| true);
    replay(&mut corpora, &control, line, None);
    for preseeded in [false, true] {
        let line = corpora.line("human-action.resume", |frame| {
            frame["result"] == approval
                && frame["params"].get("challengeResponse").is_some() == preseeded
        });
        replay(&mut corpora, &control, line, None);
    }
    // The union owner holds the HDC owner here and still no tool-selection
    // owner (TASK-XPA-012): a selection is unavailable before its intent is
    // read, and nothing makes the owner's directory.
    let selection = reply(
        &control,
        "runtime.tool.select",
        &json!({"actionRequestId": "cli-selection", "expectedActiveGeneration": "1",
            "tool": format!("tool:sha256:{}", "b".repeat(64))}),
    );
    assert_eq!(
        selection["error"],
        json!({"code": "operationUnavailable",
            "message": "the Runtime tool-selection owner is unavailable",
            "details": {"newDispatchCount": 0}}),
        "{selection}"
    );
    assert!(
        !scenario
            .root
            .join("tool-selection-control-actions")
            .exists()
    );
    drop(control);
    drop(scenario);

    // The production source over the fixture HDC: refusals first, then an
    // unobserved and a blocked preview, read, reconciled and paged.
    let blocked = corpora.action("host-blocked");
    let unobserved = corpora.action("host-unobserved");
    assert_eq!(blocked.catalog, CATALOG_DIGEST);
    let scenario = Scenario::new(HOST_START);
    let control = scenario.start("epoch-1", CATALOG_DIGEST);
    let required = "an exact restart intent and request identity are required";
    for line in [
        corpora.refusal("runtime.hdc.impact-preview", required, Value::Null),
        corpora.refusal(
            "runtime.hdc.impact-preview",
            required,
            json!("host-generation"),
        ),
        corpora.refusal(
            "runtime.hdc.impact-preview",
            "the exact HDC endpoint reference is not configured",
            json!("host-elsewhere"),
        ),
    ] {
        replay(&mut corpora, &control, line, None);
    }
    scenario.identities(&unobserved);
    scenario.observe(None);
    let line = corpora.answered(
        "runtime.hdc.impact-preview",
        "host-unobserved",
        "previewDrifted",
    );
    replay(&mut corpora, &control, line, None);
    scenario.identities(&blocked);
    scenario.observe(Some(&blocked));
    let line = corpora.answered("runtime.hdc.impact-preview", "host-blocked", "blocked");
    let first = replay(&mut corpora, &control, line.clone(), None);
    // A lost receipt: the same action, observed no more.
    scenario.observe(None);
    assert_eq!(replay(&mut corpora, &control, line, None), first);
    let conflict = corpora.refusal(
        "runtime.hdc.impact-preview",
        "the request identity belongs to a different lifecycle intent",
        json!("host-blocked"),
    );
    replay(&mut corpora, &control, conflict, None);
    // Reconciling the blocked preview observes the same impact again.
    scenario.observe(Some(&blocked));
    for (request, state) in [
        ("host-blocked", "blocked"),
        ("host-unobserved", "previewDrifted"),
    ] {
        for method in ["control-action.show", "control-action.reconcile"] {
            let line = corpora.answered(method, request, state);
            replay(&mut corpora, &control, line, None);
        }
    }
    let page = corpora.page(json!({}), &["host-blocked", "host-unobserved"]);
    replay(&mut corpora, &control, page, None);
    let first = corpora.page(json!({"pageSize": 1}), &["host-blocked"]);
    let answer = replay(&mut corpora, &control, first, None);
    let cursor = answer["result"]["nextCursor"].clone();
    let second = corpora.page(json!({"pageSize": 1}), &["host-unobserved"]);
    let answer_two = replay(
        &mut corpora,
        &control,
        second,
        Some(json!({"pageSize": 1, "cursor": cursor})),
    );
    assert_eq!(
        answer_two["result"]["snapshotRevision"],
        answer["result"]["snapshotRevision"]
    );
    let page = corpora.page(json!({"state": "blocked"}), &["host-blocked"]);
    replay(&mut corpora, &control, page, None);
    drop(control);
    drop(scenario);

    // A Runtime restart and an expiry, read without observing again.
    let restarted = corpora.action("host-restarted");
    let expiring = corpora.action("host-expiring");
    let scenario = Scenario::new(HOST_START);
    let control = scenario.start("epoch-a", CATALOG_DIGEST);
    scenario.identities(&restarted);
    scenario.observe(Some(&restarted));
    let before = reply(
        &control,
        "runtime.hdc.impact-preview",
        &json!({"action": "restart", "actionRequestId": "host-restarted",
            "serverEndpointRef": format!("hdc-endpoint:{}", sha256_hex(b"127.0.0.1:8710")),
            "expectedServerGeneration": "100000023"}),
    );
    assert_eq!(before["result"]["state"], "blocked", "{before}");
    drop(control);
    scenario.advance(60_000);
    scenario.observe(None);
    let control = scenario.start("epoch-b", CATALOG_DIGEST);
    let line = corpora.answered("control-action.show", "host-restarted", "previewDrifted");
    replay(&mut corpora, &control, line, None);
    scenario.identities(&expiring);
    scenario.observe(Some(&expiring));
    let preview = reply(
        &control,
        "runtime.hdc.impact-preview",
        &json!({"action": "restart", "actionRequestId": "host-expiring",
            "serverEndpointRef": format!("hdc-endpoint:{}", sha256_hex(b"127.0.0.1:8710")),
            "expectedServerGeneration": "100000023"}),
    );
    assert_eq!(preview["result"]["state"], "blocked", "{preview}");
    scenario.advance(300_000);
    scenario.observe(None);
    let line = corpora.answered("control-action.show", "host-expiring", "expired");
    replay(&mut corpora, &control, line, None);
    for (request, state) in [
        ("host-expiring", "expired"),
        ("host-restarted", "previewDrifted"),
    ] {
        let line = corpora.answered("control-action.reconcile", request, state);
        replay(&mut corpora, &control, line, None);
    }
    let page = corpora.page(json!({}), &["host-restarted", "host-expiring"]);
    replay(&mut corpora, &control, page, None);
    drop(control);
    drop(scenario);

    // A team-signed tool, an unsigned one, and a Target inventory that changed
    // while the impact was read (the critical Job gate unknown, with its
    // reason): each a blocked preview, read, reconciled over the same impact
    // and listed alone.
    for request in [
        "host-team-signed",
        "host-unsigned",
        "host-inventory-changed",
    ] {
        if !corpora.shows(request) {
            continue;
        }
        let action = corpora.action(request);
        assert_eq!(action.catalog, CATALOG_DIGEST);
        let scenario = Scenario::new(HOST_START);
        let control = scenario.start("epoch-1", CATALOG_DIGEST);
        scenario.identities(&action);
        scenario.observe(Some(&action));
        let line = corpora.answered("runtime.hdc.impact-preview", request, "blocked");
        replay(&mut corpora, &control, line, None);
        for method in ["control-action.show", "control-action.reconcile"] {
            let line = corpora.answered(method, request, "blocked");
            replay(&mut corpora, &control, line, None);
        }
        let page = corpora.page(json!({}), &[request]);
        replay(&mut corpora, &control, page, None);
        drop(control);
        drop(scenario);
    }

    // The restart tests read the impact through a source that answers what a
    // registered 3.2.0d server proves; this one answers the impacts they
    // recorded. A ready preview's restart requests its approval once, after
    // each refusal Swift gives before one.
    if corpora.shows("host-restart") {
        let action = corpora.action("host-restart");
        assert_eq!(action.catalog, CATALOG_DIGEST);
        let scenario = Scenario::new(HOST_START);
        let control = scenario.start("epoch-1", CATALOG_DIGEST);
        scenario.identities(&action);
        scenario.observe(Some(&action));
        let line = corpora.answered("runtime.hdc.impact-preview", "host-restart", "previewReady");
        let ready = replay(&mut corpora, &control, line, None)["result"].clone();
        let exact = tuple(&ready);
        let mismatch = corpora.restart_refusal("reviewedPlanMismatch", |_| true);
        for line in [
            corpora.restart_refusal("invalidInput", |frame| {
                frame["error"]["message"] == TUPLE_REQUIRED && frame["params"] == json!({})
            }),
            corpora.restart_refusal("invalidInput", |frame| {
                frame["error"]["message"] == TUPLE_REQUIRED && frame["params"] != json!({})
            }),
            corpora.restart_refusal("resourceNotFound", |_| true),
            mismatch.clone(),
        ] {
            replay(&mut corpora, &control, line, None);
        }
        let mut other_preview = exact.clone();
        other_preview["previewId"] = json!("preview-9f1c2d3e-4b5a-4c6d-8e7f-0a1b2c3d4e5f");
        replay(
            &mut corpora,
            &control,
            mismatch.clone(),
            Some(other_preview),
        );
        // Half a minute later, the exact tuple: the fresh impact is the
        // reviewed one.
        scenario.advance(30_000);
        scenario.approval_identities(&action);
        let line = corpora.answered(
            "runtime.hdc.restart",
            "host-restart",
            "awaitingImpactApproval",
        );
        let awaiting = replay(&mut corpora, &control, line.clone(), None)["result"].clone();
        assert_eq!(
            reply(&control, "runtime.hdc.restart", &exact)["result"],
            awaiting
        );
        replay(&mut corpora, &control, line, None);
        replay(&mut corpora, &control, mismatch, None);
        for (method, list) in [
            ("runtime.hdc.impact-preview", false),
            ("control-action.show", false),
            ("control-action.reconcile", false),
            ("control-action.list", true),
        ] {
            let line = if list {
                corpora.page(json!({}), &["host-restart"])
            } else {
                corpora.answered(method, "host-restart", "awaitingImpactApproval")
            };
            replay(&mut corpora, &control, line, None);
        }
        let line = corpora.page(
            json!({"state": "awaitingImpactApproval"}),
            &["host-restart"],
        );
        replay(&mut corpora, &control, line, None);
        assert_approval_served(&control, &awaiting);
        // A clock behind the last observation is refused before any read.
        scenario.advance(-1_000);
        let line = corpora.restart_refusal("orchestrationClockUntrusted", |_| true);
        replay(&mut corpora, &control, line, None);
        drop(control);
        drop(scenario);
    }

    // Restarts refused because the fresh impact could not be proven or names
    // a Target adopted after the review: no approval, the action invalidated
    // in the refusal, and no longer eligible.
    if corpora.shows("host-restart-unproven") {
        let unproven = corpora.action("host-restart-unproven");
        let drifted = corpora.action("host-restart-drifted");
        let scenario = Scenario::new(HOST_START);
        let control = scenario.start("epoch-1", CATALOG_DIGEST);
        scenario.identities(&unproven);
        scenario.observe(Some(&unproven));
        let unproven_ready = ready(&control, &unproven, "host-restart-unproven");
        scenario.identities(&drifted);
        scenario.observe(Some(&drifted));
        let drifted_ready = ready(&control, &drifted, "host-restart-drifted");
        scenario.advance(30_000);
        scenario.observe(None);
        let line = corpora.drifted(UNPROVEN_IMPACT, "host-restart-unproven");
        replay(&mut corpora, &control, line, None);
        let line = corpora.restart_refusal("admissionDenied", |_| true);
        replay(&mut corpora, &control, line, Some(tuple(&unproven_ready)));
        scenario.observe_adopted(&drifted);
        let line = corpora.drifted(DIFFERENT_IMPACT, "host-restart-drifted");
        let answer = replay(&mut corpora, &control, line, None);
        assert_eq!(
            answer["error"]["details"]["controlAction"]["preview"],
            drifted_ready["preview"]
        );
        drop(control);
        drop(scenario);
    }

    // Two approvals awaited: one drifts when reconciled after a Target was
    // adopted, the other expires with its preview; both expire their
    // approval, are served expired and are no longer eligible.
    if corpora.shows("host-approval-expiring") {
        let expiring = corpora.action("host-approval-expiring");
        let drifting = corpora.action("host-approval-drifting");
        let scenario = Scenario::new(HOST_START);
        let control = scenario.start("epoch-1", CATALOG_DIGEST);
        scenario.identities(&expiring);
        scenario.observe(Some(&expiring));
        let expiring_ready = ready(&control, &expiring, "host-approval-expiring");
        scenario.advance(1_000);
        scenario.identities(&drifting);
        scenario.observe(Some(&drifting));
        let drifting_ready = ready(&control, &drifting, "host-approval-drifting");
        scenario.advance(29_000);
        scenario.approval_identities(&expiring);
        scenario.observe(Some(&expiring));
        approved(&control, &expiring, &expiring_ready);
        scenario.approval_identities(&drifting);
        scenario.observe(Some(&drifting));
        approved(&control, &drifting, &drifting_ready);
        scenario.observe_adopted(&drifting);
        scenario.advance(30_000);
        let line = corpora.answered(
            "control-action.reconcile",
            "host-approval-drifting",
            "previewDrifted",
        );
        let drifted = replay(&mut corpora, &control, line, None)["result"].clone();
        let line = corpora.answered(
            "control-action.show",
            "host-approval-drifting",
            "previewDrifted",
        );
        replay(&mut corpora, &control, line, None);
        assert_approval_served(&control, &drifted);
        let ineligible = corpora.restart_refusal("admissionDenied", |_| true);
        replay(&mut corpora, &control, ineligible.clone(), None);
        scenario.advance(240_000);
        let line = corpora.answered("control-action.show", "host-approval-expiring", "expired");
        let expired = replay(&mut corpora, &control, line, None)["result"].clone();
        let line = corpora.answered(
            "control-action.reconcile",
            "host-approval-expiring",
            "expired",
        );
        replay(&mut corpora, &control, line, None);
        assert_approval_served(&control, &expired);
        replay(
            &mut corpora,
            &control,
            ineligible,
            Some(tuple(&expiring_ready)),
        );
        let page = corpora.page(
            json!({}),
            &["host-approval-expiring", "host-approval-drifting"],
        );
        replay(&mut corpora, &control, page, None);
        drop(control);
        drop(scenario);
    }

    // An unsigned and a team-signed tool: the ready preview's restart awaits
    // its approval with the tool's signature, and another's, refused once the
    // observation fails, keeps it in the action it invalidated.
    for request in ["host-unsigned-restart", "host-team-signed-restart"] {
        if !corpora.shows(request) {
            continue;
        }
        let action = corpora.action(request);
        let other_request = format!("{request}-unproven");
        let other = corpora.action(&other_request);
        assert_eq!(action.catalog, CATALOG_DIGEST);
        let scenario = Scenario::new(HOST_START);
        let control = scenario.start("epoch-1", CATALOG_DIGEST);
        scenario.identities(&action);
        scenario.observe(Some(&action));
        let line = corpora.answered("runtime.hdc.impact-preview", request, "previewReady");
        replay(&mut corpora, &control, line, None);
        scenario.identities(&other);
        scenario.observe(Some(&other));
        ready(&control, &other, &other_request);
        scenario.advance(30_000);
        scenario.approval_identities(&action);
        scenario.observe(Some(&action));
        let line = corpora.answered("runtime.hdc.restart", request, "awaitingImpactApproval");
        replay(&mut corpora, &control, line, None);
        scenario.observe(None);
        let line = corpora.drifted(UNPROVEN_IMPACT, &other_request);
        replay(&mut corpora, &control, line, None);
        drop(control);
        drop(scenario);
    }

    // Every with-host line is reproduced but what only a foreground console
    // receives (C2b): each line is replayed or the console's, never both.
    let unreplayed: Vec<_> = corpora
        .lines
        .iter()
        .filter(|(method, index, _)| !corpora.replayed.contains(&(*method, *index)))
        .collect();
    for (method, index, frame) in &unreplayed {
        assert!(
            console_answer(method, frame),
            "{method} line {index} was not replayed: {frame}"
        );
    }
    let console = corpora
        .lines
        .iter()
        .filter(|(method, _, frame)| console_answer(method, frame))
        .count();
    assert_eq!(unreplayed.len(), console, "a console answer was replayed");
    // The challenge and the lifecycle after it are one each in every view;
    // the fake source's lines and C1's are replayed in every view.
    assert!(console >= 2, "{console}");
    assert!(corpora.replayed.len() >= 29, "{:?}", corpora.replayed);
}
