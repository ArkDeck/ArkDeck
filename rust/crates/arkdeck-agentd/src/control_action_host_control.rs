//! `runtime.hdc.impact-preview` and `control-action.list`, `.show` and
//! `.reconcile` through the control layer, as Swift's daemon answers them once
//! its HDC server host has started: every exchange of the committed corpora
//! such a daemon answered, replayed over the union owner and the HDC
//! control-action owner in the order the Swift test made it, with that test's
//! clock, Runtime starts, catalog digest and identities, and an impact source
//! answering the impact that test's source observed. The exchanges come from
//! `HDCControlActionContractTests` (a fake impact source: one ready preview,
//! read, listed and reconciled) and `ControlActionWithHostContractTests` (the
//! production impact source over the fixture HDC: the with-host refusals, an
//! unobserved and a blocked preview, a restart and an expiry, and a listing
//! over two pages). Answers compare whole; a page's random snapshot revision
//! and next cursor are checked and set aside, and the second page is asked
//! through the cursor this owner issued. The approval request the fake
//! source's restart made is counted, not replayed: restart is not here.
use arkdeck_contract::{
    CATALOG_DIGEST, CONTRACT_IDENTITY, DeviceObservationsResult, PROTOCOL_VERSION, WireError,
    sha256_hex,
};
use arkdeck_control::{Control, HdcStatus, HostServices};
use arkdeck_hoststore::{
    ControlActionResources, HdcControlActions, Impact, ImpactReading, ImpactSource, OwnerContext,
};
use arkdeck_platform::HostDirectory;
use serde_json::{Map, Value, json};
use std::collections::{BTreeSet, VecDeque};
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

const METHODS: [&str; 5] = [
    "runtime.hdc.impact-preview",
    "runtime.hdc.restart",
    "control-action.show",
    "control-action.reconcile",
    "control-action.list",
];
const HDC_UNAVAILABLE: &str = "the Runtime HDC control-action owner is unavailable";
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
/// control action or a page of them, or a lifecycle refusal only an HDC
/// control-action owner gives.
fn with_host(method: &str, frame: &Value) -> bool {
    if frame["ok"] == true {
        return frame["result"].get("controlActionId").is_some()
            || frame["result"]["items"]
                .as_array()
                .is_some_and(|items| !items.is_empty());
    }
    matches!(method, "runtime.hdc.impact-preview" | "runtime.hdc.restart")
        && frame["error"]["message"] != HDC_UNAVAILABLE
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
/// control-action owner and the replayed source.
struct ReplayHost {
    resources: ControlActionResources,
    source: Arc<Replay>,
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
}

/// What the corpora say of one request identity's action.
struct Action {
    id: String,
    preview_id: Option<String>,
    impact: Option<Impact>,
    catalog: String,
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

    /// The action of a request identity, from every line that shows it.
    fn action(&self, request: &str) -> Action {
        let mut found: Option<Action> = None;
        for (_, _, frame) in &self.lines {
            for record in records(frame) {
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
}

/// One replay: a state root with the union owner's directory and the HDC
/// owner's, the clock, the source and the identities the next previews take.
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
        directory.private_child("control-action-snapshots").unwrap();
        directory.private_child("hdc-control-actions").unwrap();
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

#[test]
fn every_with_host_exchange_of_the_corpora_is_answered_as_swift_recorded_it() {
    let mut corpora = Corpora::load();

    // The fake impact source's action: previewed, read, listed, reconciled.
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
    scenario.clock.fetch_add(60_000, Ordering::SeqCst);
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
    scenario.clock.fetch_add(300_000, Ordering::SeqCst);
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

    // Every with-host line is reproduced but the approval request.
    let unreplayed: Vec<_> = corpora
        .lines
        .iter()
        .filter(|(method, index, _)| !corpora.replayed.contains(&(*method, *index)))
        .map(|(method, index, frame)| (*method, *index, frame["result"]["state"].clone()))
        .collect();
    assert_eq!(
        unreplayed,
        [("runtime.hdc.restart", 1, json!("awaitingImpactApproval"))]
    );
    assert!(corpora.replayed.len() >= 23, "{:?}", corpora.replayed);
}
