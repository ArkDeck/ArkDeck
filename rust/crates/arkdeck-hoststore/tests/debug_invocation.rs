//! The Swift Flash recovery broker oracle (`rust/tests/fixtures/debug-invocation`,
//! recorded by `DebugInvocationOracleContractTests`) replayed through the
//! Rust owner: `debug.start` and `debug.evaluate` over the Rust planner, and
//! `debug.status` to read what they left.
//!
//! The Artifact root Swift's Import left and the four documents laid down
//! before the exchanges are laid down as recorded. Each exchange composes
//! the planner, the clock and the facts as its setup names them. An
//! invocation this owner mints is named by the replay, and read, as Swift's
//! are, as `<invocation-N>` in order of its start. Every answer and every
//! document left must be Swift's.
//!
//! `executePinnedRequest` (`execute.json`) is replayed over a scripted driver
//! answering as Swift's engine answered (the Job failed, classified
//! `safeToReflash`): the attempt's derived request, its permit record and the
//! settled evaluation must be Swift's.
//!
//! On Windows (TASK-XPA-008) the same replay runs over the same owner: a
//! recorded mode is the DACL the host store reads — a private directory
//! (`700`), an owner-only document (`600`), a sealed payload (`400`) — and a
//! document left is reported `600` when the store reads it as owner-only.
#![cfg(any(target_os = "macos", windows))]

use arkdeck_hoststore::{
    ArtifactReadStore, DriverResult, FlashInvocations, FlashPlanner, FlashPlanning,
    ImportUploadStore, InvocationBroker, JobPlanner, RockchipFacts,
};
use serde_json::{Map, Value, json};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/debug-invocation")
}

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let base = std::env::temp_dir().canonicalize().unwrap();
        #[cfg(windows)]
        let base = match base.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
            Some(plain) => PathBuf::from(plain),
            None => base,
        };
        let root = base.join(format!(
            "arkdeck-debug-invocation-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        directory(&root);
        Self(root)
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(unix)]
fn directory(path: &Path) {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

/// A private directory, and each missing ancestor, as the host store makes
/// one.
#[cfg(windows)]
fn directory(path: &Path) {
    if let Some(parent) = path.parent()
        && fs::symlink_metadata(parent).is_err()
    {
        directory(parent);
    }
    arkdeck_platform::HostDirectory::open_or_create_private(path).unwrap();
}

/// A recorded file with its recorded mode: its permission bits on macOS; on
/// Windows the owner-only document the store reads (`600`), or that document
/// sealed by the store (`400`).
fn lay_down_file(destination: &Path, bytes: &[u8], mode: &str) {
    #[cfg(unix)]
    {
        fs::write(destination, bytes).unwrap();
        let mode = u32::from_str_radix(mode, 8).unwrap();
        fs::set_permissions(destination, fs::Permissions::from_mode(mode)).unwrap();
    }
    #[cfg(windows)]
    {
        let parent = arkdeck_platform::HostDirectory::open(destination.parent().unwrap()).unwrap();
        let name = destination.file_name().unwrap().to_str().unwrap();
        parent.create_document(name, bytes).unwrap();
        match mode {
            "600" => {}
            "400" => parent.seal_document(name).unwrap(),
            other => panic!("no Windows form of mode {other}"),
        }
    }
}

/// A document's mode as the oracle records it (see [`lay_down_file`]).
fn recorded_mode(path: &Path) -> String {
    #[cfg(unix)]
    {
        format!("{:o}", fs::metadata(path).unwrap().mode() & 0o777)
    }
    #[cfg(windows)]
    {
        arkdeck_platform::HostDirectory::open(path.parent().unwrap())
            .and_then(|parent| {
                parent.owner_only_document(path.file_name().unwrap().to_str().unwrap())
            })
            .map_or_else(|error| format!("not owner-only: {error}"), |_| "600".into())
    }
}

/// The inputs as Swift left them: the Artifact root and Target store below
/// the root, the documents in the broker's state directory.
fn lay_down(root: &Path, cases: &Value) {
    for input in cases["inputs"].as_array().unwrap() {
        let path = input["path"].as_str().unwrap();
        let destination = if path.starts_with("runtime-debug-invocations/") {
            root.join("state").join(path)
        } else {
            root.join(path)
        };
        directory(destination.parent().unwrap());
        lay_down_file(
            &destination,
            &fs::read(fixtures().join("inputs").join(path)).unwrap(),
            input["mode"].as_str().unwrap(),
        );
    }
}

/// The exchange's scripted Flash composition.
fn planning(setup: &Value) -> FlashPlanning {
    let text = |value: &Value| value.as_str().map(str::to_owned);
    let dispatch = text(&setup["dispatchUnavailable"]);
    FlashPlanning::new(
        text(&setup["unavailable"]),
        move || dispatch.clone(),
        text(&setup["toolchainSha256"]),
    )
}

fn facts(setup: &Value, target: &str) -> Result<RockchipFacts, String> {
    let facts = &setup["facts"];
    if let Some(error) = facts["error"].as_str() {
        return Err(error.to_owned());
    }
    Ok(RockchipFacts {
        target_id: target.to_owned(),
        binding_revision: facts["bindingRevision"].as_i64().unwrap(),
        identity_sha256: facts["deviceIdentitySha256"].as_str().unwrap().into(),
        tool_sha256: facts["toolSha256"].as_str().unwrap().into(),
        execution_connect_key: facts["executionConnectKey"].as_str().unwrap().into(),
        device_mode: "hdc".into(),
        build_fingerprint: None,
        profile_id: "dayu200".into(),
        server_facts: facts["serverFacts"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(key, value)| (key.clone(), value.as_str().unwrap().to_owned()))
            .collect::<BTreeMap<_, _>>(),
    })
}

/// The invocations this owner mints, by the replay's choice of identity,
/// read as Swift's are: `<invocation-N>` and its twelve-character suffix.
#[derive(Default)]
struct Labels {
    minted: Vec<(String, String)>,
}

impl Labels {
    fn identity(ordinal: usize) -> String {
        format!("debug-7e57a11d-0000-4000-8000-c0ffee{ordinal:06x}")
    }

    fn name(&mut self, method: &str, answer: &Value) {
        if method != "debug.start" {
            return;
        }
        let Some(identity) = answer["result"]["invocationID"].as_str() else {
            return;
        };
        if !self.minted.iter().any(|(minted, _)| minted == identity) {
            let label = format!("<invocation-{}>", self.minted.len() + 1);
            self.minted.push((identity.to_owned(), label));
        }
    }

    fn label(&self, text: &str) -> String {
        let named = self
            .minted
            .iter()
            .fold(text.to_owned(), |text, (identity, label)| {
                text.replace(identity, label)
            });
        self.minted.iter().fold(named, |text, (identity, label)| {
            text.replace(
                &identity[identity.len() - 12..],
                &format!("{}-suffix>", &label[..label.len() - 1]),
            )
        })
    }

    fn resolve(&self, params: &Map<String, Value>) -> Map<String, Value> {
        params
            .iter()
            .map(|(key, value)| {
                let value = match value.as_str() {
                    Some(text) => json!(
                        self.minted
                            .iter()
                            .fold(text.to_owned(), |text, (identity, label)| {
                                text.replace(label, identity)
                            })
                    ),
                    None => value.clone(),
                };
                (key.clone(), value)
            })
            .collect()
    }

    fn labelled(&self, value: &Value) -> Value {
        serde_json::from_str(&self.label(&serde_json::to_string(value).unwrap())).unwrap()
    }
}

struct Replay {
    root: Root,
    cases: Value,
    artifacts: ArtifactReadStore,
    imports: ImportUploadStore,
    owner: FlashInvocations,
    minted: RefCell<usize>,
    /// What the scripted driver answers, and every request it was handed.
    driver: RefCell<(Option<DriverResult>, Vec<Vec<u8>>)>,
}

impl Replay {
    fn new() -> Self {
        let cases: Value =
            serde_json::from_slice(&fs::read(fixtures().join("cases.json")).unwrap()).unwrap();
        let root = Root::new();
        for name in ["artifacts", "targets", "state", "engine"] {
            directory(&root.0.join(name));
        }
        lay_down(&root.0, &cases);
        Self {
            artifacts: ArtifactReadStore::open(&root.0.join("artifacts")).unwrap(),
            imports: ImportUploadStore::open(&root.0.join("artifacts")).unwrap(),
            owner: FlashInvocations::open(&root.0.join("state")).unwrap(),
            root,
            cases,
            minted: RefCell::new(0),
            driver: RefCell::new((None, Vec::new())),
        }
    }

    /// One exchange as Swift's handler answered it, wrapped as the oracle
    /// records answers.
    fn answer(&self, setup: &Value, method: &str, params: &Map<String, Value>) -> Value {
        let target = self.cases["targetId"].as_str().unwrap();
        let flash = planning(setup);
        let port = |_: &str| facts(setup, target);
        let engine = self.root.0.join("engine");
        let planner = FlashPlanner {
            planner: JobPlanner {
                artifacts: Some(&self.artifacts),
                imports: Some(&self.imports),
                analyzer: None,
                state_root: &engine,
                hdc: None,
                workspace: None,
            },
            flash: Some(&flash),
            facts: Some(&port),
        };
        let now = setup["now"].as_str().unwrap().to_owned();
        let broker = InvocationBroker {
            plan: &|request| planner.plan(request),
            now: &|| Some(now.clone()),
            mint: &|| {
                let mut minted = self.minted.borrow_mut();
                *minted += 1;
                Some(Labels::identity(*minted))
            },
            execute: &|request| {
                let mut driver = self.driver.borrow_mut();
                driver.1.push(request.to_vec());
                driver
                    .0
                    .clone()
                    .expect("no exchange of the oracle reaches the driver unscripted")
            },
        };
        let answer = match method {
            "debug.status" => self.owner.handle(method, params),
            _ => self.owner.broker(method, params, &broker),
        };
        match answer {
            Ok(result) => json!({"ok": true, "result": result}),
            Err(error) => json!({"ok": false, "error": {
                "code": error.code, "message": error.message,
                "details": error.details.map(Value::Object).unwrap_or(Value::Null)}}),
        }
    }

    /// Every document in the broker's directory, as the oracle records the
    /// documents left: labelled path, mode and bytes, by labelled path.
    fn documents(&self, labels: &Labels) -> Vec<Value> {
        let directory = self.root.0.join("state/runtime-debug-invocations");
        let mut documents: Vec<(String, Value)> = fs::read_dir(&directory)
            .unwrap()
            .map(|entry| {
                let entry = entry.unwrap();
                let name = entry.file_name().into_string().unwrap();
                let mode = recorded_mode(&entry.path());
                let bytes = fs::read(entry.path()).unwrap();
                let path = labels.label(&name);
                (
                    path.clone(),
                    json!({
                        "path": path,
                        "mode": mode,
                        "document": labels.label(&String::from_utf8(bytes).unwrap()),
                    }),
                )
            })
            .collect();
        documents.sort_by(|left, right| left.0.cmp(&right.0));
        documents
            .into_iter()
            .map(|(_, document)| document)
            .collect()
    }
}

#[test]
fn every_flash_invocation_is_brokered_as_swift_brokers_it() {
    let replay = Replay::new();
    let mut labels = Labels::default();
    let exchanges = replay.cases["exchanges"].as_array().unwrap();
    assert_eq!(exchanges.len(), 68);
    for exchange in exchanges {
        let name = exchange["name"].as_str().unwrap();
        let method = exchange["method"].as_str().unwrap();
        let params = labels.resolve(exchange["params"].as_object().unwrap());
        let answer = replay.answer(&exchange["setup"], method, &params);
        labels.name(method, &answer);
        assert_eq!(labels.labelled(&answer), exchange["answer"], "{name}");
    }
    assert_eq!(
        Value::Array(replay.documents(&labels)),
        replay.cases["left"],
        "the documents left"
    );

    // `executePinnedRequest`: the driver answers as Swift's engine did.
    let execute: Value =
        serde_json::from_slice(&fs::read(fixtures().join("execute.json")).unwrap()).unwrap();
    replay.driver.borrow_mut().0 = Some(DriverResult {
        job_id: Some("<job>".into()),
        outcome: "safeToReflash",
        detail: "Runtime Job terminal state failed".into(),
    });
    let answer = replay.answer(
        &execute["setup"],
        "debug.evaluate",
        &labels.resolve(execute["params"].as_object().unwrap()),
    );
    assert_eq!(labels.labelled(&answer), execute["answer"]);
    // The driver was handed the attempt's exact request once: the pinned
    // seed under the derived request id and idempotency key.
    let requests = replay.driver.borrow().1.clone();
    assert_eq!(requests.len(), 1);
    let request: Value = serde_json::from_slice(&requests[0]).unwrap();
    let attempt = &execute["answer"]["result"]["evaluations"][0];
    assert_eq!(
        labels.labelled(&request["requestId"]),
        attempt["requestID"],
        "{request}"
    );
    assert_eq!(
        labels.labelled(&request["idempotencyKey"]),
        attempt["idempotencyKey"]
    );
    assert!(request.get("authorization").is_none(), "{request}");
    // Its permit record is durable beside the invocation documents.
    let key = request["idempotencyKey"].as_str().unwrap();
    let permit: Value = serde_json::from_slice(
        &fs::read(
            replay
                .root
                .0
                .join("state/runtime-debug-attempts")
                .join(format!("{key}.json")),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(labels.labelled(&permit["invocationID"]), "<invocation-4>");
    assert_eq!(
        permit["candidateActionSHA256"],
        attempt["candidateActionSHA256"]
    );
    assert_eq!(permit["idempotencyKey"], json!(key));
}
