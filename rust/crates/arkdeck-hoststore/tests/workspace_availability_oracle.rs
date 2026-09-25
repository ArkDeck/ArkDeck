//! Replays the Swift oracle of what the daemon publishes about its workspace
//! composition (`rust/tests/fixtures/workspace-availability-oracle`, recorded
//! by `WorkspaceAvailabilityOracleContractTests`) against the Rust
//! composition over the same fixed root, stand-ins and clock, through three
//! starts: every `operation.list` workspace row — its availability, reasons,
//! codes and their origins — and every project and preset answer must be
//! Swift's, and each answer admitted by the published method schemas.
//!
//! One declared difference: `workspace.project.show` answers an operation's
//! reason and code as `null`, as its published schema still has them; Swift
//! answers them as `list` does (the widening is its own change).
#![cfg(target_os = "macos")]

mod support;

use arkdeck_contract::WireError;
use arkdeck_hoststore::{
    OperationAvailabilityContext, WorkspaceComposition, WorkspaceInspector, WorkspaceProjectStore,
    WorkspaceReference, WorkspaceToolchainPinning, operation_unavailability,
};
use serde_json::{Map, Value, json};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use support::chmod;

/// The recording's fixed root: the registrations pin its projects' roots.
const ROOT: &str = "/private/tmp/arkdeck-workspace-availability-oracle";
const LOCK: &str = "/private/tmp/arkdeck-workspace-availability-oracle.lock";
const TIMESTAMP: &str = "2026-09-25T00:00:00Z";
const SOURCE_MAP: &str = "entry/build/default/outputs/default/mapping/sourceMaps.map";

fn oracle_now() -> Option<String> {
    Some(TIMESTAMP.into())
}

/// Serializes every user of the fixed root: another worktree's run of this
/// binary would otherwise remove the root under this one.
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

fn oracle() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/workspace-availability-oracle")
}

/// An OpenHarmony-shaped project, as the oracle lays it out.
fn project(root: &Path, name: &str) -> PathBuf {
    let project = root.join(name);
    for (path, text) in [
        (
            "build-profile.json5",
            "{ app: {}, modules: [{ name: 'entry', srcPath: './entry' }] }\n",
        ),
        (
            "entry/src/main/module.json5",
            "{ module: { name: 'entry' } }\n",
        ),
        (
            "entry/src/main/ets/pages/Index.ets",
            "@Entry\n@Component\nstruct Index {\n  build() {}\n}\n",
        ),
        (SOURCE_MAP, "{}\n"),
    ] {
        let path = project.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }
    project
}

/// The fixed root, rebuilt; removed when the test ends.
struct Host {
    root: PathBuf,
    state: PathBuf,
    inspector: PathBuf,
    symbolizer: PathBuf,
}

impl Host {
    fn fixed() -> Self {
        let root = PathBuf::from(ROOT);
        let _ = fs::remove_dir_all(&root);
        fs::create_dir(&root).unwrap();
        chmod(&root, 0o700);
        let tools = root.join("tools");
        fs::create_dir(&tools).unwrap();
        for name in ["inspector", "symbolizer"] {
            fs::copy(oracle().join(format!("{name}.sh")), tools.join(name)).unwrap();
            chmod(&tools.join(name), 0o755);
        }
        let state = root.join("state");
        for directory in [state.clone(), state.join("workspace-projects")] {
            fs::create_dir(&directory).unwrap();
            chmod(&directory, 0o700);
        }
        project(&root, "alpha");
        project(&root, "beta");
        Self {
            inspector: tools.join("inspector"),
            symbolizer: tools.join("symbolizer"),
            root,
            state,
        }
    }

    /// One start of the daemon's workspace composition: the registration
    /// owner, whose Hvigor presets pin toolchains the DevEco registry does
    /// not hold, composed over the state root.
    fn start(&self, inspector: bool) -> (Arc<WorkspaceProjectStore>, WorkspaceComposition) {
        let store = Arc::new(
            WorkspaceProjectStore::open(&self.state.join("workspace-projects"))
                .unwrap()
                .with_dependency_pinning(
                    Some(WorkspaceToolchainPinning {
                        acquire: Box::new(|_, _, _| Ok(())),
                        release: Box::new(|_, _| Ok(())),
                    }),
                    None,
                ),
        );
        let (composition, notes) = WorkspaceComposition::compose(
            Arc::clone(&store),
            &self.state,
            "/var/empty",
            oracle_now,
            &|_, _, _| Err("the DevEco toolchain is not registered".into()),
            None,
            Some(self.symbolizer.to_str().unwrap()),
        )
        .unwrap();
        assert!(notes.unadopted.is_empty());
        let inspector = inspector
            .then(|| WorkspaceInspector::hashing(self.inspector.to_str().unwrap()).unwrap());
        (store, composition.with_inspector(inspector))
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// The recorded frames, in order, each consumed by the method it answers.
struct Frames(std::vec::IntoIter<Value>, usize);

impl Frames {
    fn load() -> Self {
        let frames: Vec<Value> = fs::read_to_string(oracle().join("frames.jsonl"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        Self(frames.into_iter(), 0)
    }

    fn next(&mut self, method: &str) -> Value {
        let frame = self.0.next().expect("a recorded frame");
        assert_eq!(frame["method"], method, "frame {}", self.1);
        self.1 += 1;
        frame
    }
}

/// `operation.list`'s origin of a reason code, as the control layer maps it.
fn origin(code: &str) -> &'static str {
    match code {
        "provider_not_registered" | "operation_not_supported" | "workspace_preset_not_offered" => {
            "product_build"
        }
        _ => "host_configuration",
    }
}

/// Every workspace row of the recorded `operation.list`, as the Rust
/// availability answers it with every owner composed.
fn assert_rows(frames: &mut Frames, workspace: &WorkspaceComposition) {
    let frame = frames.next("operation.list");
    let context = OperationAvailabilityContext {
        planning_owner: true,
        job_owner: true,
        artifacts: true,
        analyzer: None,
        hdc_registered: false,
        hdc_tool_current: false,
        mutation_owner: true,
        code_sign_helper: false,
        workspace: Some(workspace),
    };
    let mut rows = 0;
    for row in frame["result"].as_array().unwrap() {
        let reference = row["reference"].as_str().unwrap();
        if !reference.starts_with("workspace.") {
            continue;
        }
        let reasons = operation_unavailability(reference, "workspace", &context).unwrap();
        let answered = json!({
            "availability": if reasons.is_empty() { "available" } else { "unavailable" },
            "reasons": reasons.iter().map(|(_, reason)| reason).collect::<Vec<_>>(),
            "reasonCodes": reasons.iter().map(|(code, _)| code).collect::<Vec<_>>(),
            "reasonOrigins": reasons.iter().map(|(code, _)| origin(code)).collect::<Vec<_>>(),
        });
        let recorded = json!({
            "availability": row["availability"], "reasons": row["reasons"],
            "reasonCodes": row["reasonCodes"], "reasonOrigins": row["reasonOrigins"],
        });
        assert_eq!(answered, recorded, "frame {}: {reference}", frames.1 - 1);
        rows += 1;
    }
    assert_eq!(rows, 13, "every workspace operation of the Catalog");
}

/// The Rust registration owner's answer to one recorded frame.
fn answer(store: &WorkspaceProjectStore, frame: &Value) -> Value {
    let method = frame["method"].as_str().unwrap();
    let params: Map<String, Value> = frame["params"].as_object().cloned().unwrap_or_default();
    let census = |_: WorkspaceReference<'_>| -> Result<(), WireError> { Ok(()) };
    let answer = match store.handle(method, &params, &|| TIMESTAMP.to_owned(), &census) {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => {
            let mut refusal = json!({"code": error.code, "message": error.message});
            if let Some(details) = error.details {
                refusal["details"] = Value::Object(details);
            }
            json!({"ok": false, "error": refusal})
        }
    };
    support::hdc_oracle::assert_conforms(method, &answer);
    answer
}

/// One recorded project or preset exchange, answered as Swift answered it.
fn assert_answer(frames: &mut Frames, store: &WorkspaceProjectStore, method: &str) -> Value {
    let frame = frames.next(method);
    let answer = answer(store, &frame);
    let mut expected = json!({"ok": frame["ok"]});
    if frame["ok"] == true {
        expected["result"] = frame["result"].clone();
        if method == "workspace.project.show" {
            // Declared: the published `show` has an operation's reason and
            // code as `null`.
            for operation in expected["result"]["operations"].as_array_mut().unwrap() {
                operation["reason"] = Value::Null;
                operation["reasonCode"] = Value::Null;
            }
        }
    } else {
        expected["error"] = frame["error"].clone();
    }
    assert_eq!(answer, expected, "frame {}: {method}", frames.1 - 1);
    answer
}

#[test]
fn the_rust_composition_publishes_what_swift_s_daemon_published() {
    // Taken first, so the root is removed before the lock is released.
    let _lock = exclusive();
    let host = Host::fixed();
    let mut frames = Frames::load();

    // 1. No project; two registered, with their presets.
    let (store, workspace) = host.start(false);
    assert_rows(&mut frames, &workspace);
    for method in [
        "workspace.project.list",
        "workspace.project.register",
        "workspace.project.register",
        "workspace.preset.register",
        "workspace.preset.register",
        "workspace.preset.register",
        "workspace.project.list",
        "workspace.project.show",
        "workspace.preset.list",
        "workspace.preset.show",
    ] {
        assert_answer(&mut frames, &store, method);
    }

    // 2. Both composed, an inspector configured; the symbolizer drifts and
    // is restored; a preset added, one removed, a project updated.
    drop((store, workspace));
    let (store, workspace) = host.start(true);
    assert_rows(&mut frames, &workspace);
    for method in [
        "workspace.project.list",
        "workspace.project.show",
        "workspace.project.show",
        "workspace.preset.list",
        "workspace.preset.show",
        "workspace.preset.list",
    ] {
        assert_answer(&mut frames, &store, method);
    }
    let symbolizer = fs::read(&host.symbolizer).unwrap();
    let mut drifted = symbolizer.clone();
    drifted.extend_from_slice(b"# drifted\n");
    fs::write(&host.symbolizer, drifted).unwrap();
    assert_rows(&mut frames, &workspace);
    assert_answer(&mut frames, &store, "workspace.project.show");
    fs::write(&host.symbolizer, symbolizer).unwrap();
    for method in [
        "workspace.preset.register",
        "workspace.preset.remove",
        "workspace.project.update",
        "workspace.project.list",
        "workspace.preset.list",
    ] {
        assert_answer(&mut frames, &store, method);
    }

    // 3. The second project's root is gone; no inspector.
    fs::remove_dir_all(host.root.join("beta")).unwrap();
    drop((store, workspace));
    let (store, workspace) = host.start(false);
    assert_rows(&mut frames, &workspace);
    for method in [
        "workspace.project.list",
        "workspace.project.show",
        "workspace.preset.list",
        "workspace.preset.show",
        "workspace.preset.list",
        "workspace.preset.remove",
        "workspace.project.list",
    ] {
        assert_answer(&mut frames, &store, method);
    }
    assert!(frames.0.next().is_none(), "every recorded frame answered");
}
