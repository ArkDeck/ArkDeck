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
//! `executePinnedRequest` is the declared difference (`execute.json`): Swift
//! admits the pinned Flash and runs it; this Runtime refuses where Swift
//! begins, and the invocation is unchanged.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    ArtifactReadStore, FlashInvocations, FlashPlanner, FlashPlanning, ImportUploadStore,
    InvocationBroker, JobPlanner, RockchipFacts,
};
use serde_json::{Map, Value, json};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/debug-invocation")
}

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-debug-invocation-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        Self(root)
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn directory(path: &Path) {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
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
        fs::write(
            &destination,
            fs::read(fixtures().join("inputs").join(path)).unwrap(),
        )
        .unwrap();
        let mode = u32::from_str_radix(input["mode"].as_str().unwrap(), 8).unwrap();
        fs::set_permissions(&destination, fs::Permissions::from_mode(mode)).unwrap();
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
                let mode = entry.metadata().unwrap().mode() & 0o777;
                let bytes = fs::read(entry.path()).unwrap();
                let path = labels.label(&name);
                (
                    path.clone(),
                    json!({
                        "path": path,
                        "mode": format!("{mode:o}"),
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

    // The declared difference: Swift began and ran the attempt; this Runtime
    // refuses where Swift begins, and writes nothing.
    let execute: Value =
        serde_json::from_slice(&fs::read(fixtures().join("execute.json")).unwrap()).unwrap();
    let swift = &execute["answer"]["result"];
    let attempt = swift["evaluations"].as_array().unwrap().last().unwrap();
    assert_eq!(swift["invocationID"], "<invocation-4>");
    assert_eq!(swift["destructiveEpochsUsed"], 1);
    assert_eq!(attempt["candidateAction"], "executePinnedRequest");
    assert_eq!(attempt["jobID"], "<job>");
    let answer = replay.answer(
        &execute["setup"],
        "debug.evaluate",
        &labels.resolve(execute["params"].as_object().unwrap()),
    );
    assert_eq!(
        answer,
        json!({"ok": false, "error": {"code": "rejected", "details": null, "message":
            "executePinnedRequest is not available on the Rust Runtime yet: it runs the pinned \
             Flash, which this Runtime does not execute; the invocation is unchanged"}})
    );
    assert_eq!(
        Value::Array(replay.documents(&labels)),
        replay.cases["left"],
        "nothing was written"
    );
    assert!(
        !replay.root.0.join("state/runtime-debug-attempts").exists(),
        "no attempt permit was written"
    );
}
