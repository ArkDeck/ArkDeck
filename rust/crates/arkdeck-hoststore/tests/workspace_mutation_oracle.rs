//! Replays #2041's Swift recording of `workspace.project.update/remove` and
//! `workspace.preset.register/update/remove/list/show`, all 78 frames in their
//! recorded order, against the Rust owner (TASK-XPA-015, M3). Every answer
//! must equal Swift's: a result byte for byte as JSON, a refusal by code,
//! message and details. Between frames the test changes the owner exactly as
//! the Swift test did: an owner without dependency pins, a full owner, a
//! retained dependency mutation, an unreadable document, and storage faults
//! raised from inside the clock.
#![cfg(target_os = "macos")]
use arkdeck_contract::WireError;
use arkdeck_hoststore::{
    WorkspaceCredentialPinning, WorkspaceProjectStore, WorkspaceToolchainPinning,
};
use serde_json::{Map, Value, json};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

const NOW: &str = "2026-09-19T00:00:00.000Z";
const FRAMES: &str = include_str!("../../../tests/fixtures/workspace-mutation-oracle/frames.jsonl");

struct Base(PathBuf);
impl Base {
    fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("workspace-oracle-{nonce:032x}"));
        for name in [
            "",
            "roots",
            "roots/first",
            "roots/second",
            "roots/third",
            "roots/fourth",
        ] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(path.join(name))
                .unwrap();
        }
        Self(path)
    }
    fn owner(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        if !path.exists() {
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        }
        path
    }
    fn root(&self, name: &str) -> String {
        self.0.join("roots").join(name).to_str().unwrap().to_owned()
    }
}
impl Drop for Base {
    fn drop(&mut self) {
        for entry in fs::read_dir(&self.0).into_iter().flatten().flatten() {
            let _ = fs::set_permissions(entry.path(), fs::Permissions::from_mode(0o700));
        }
        let _ = fs::remove_dir_all(&self.0);
    }
}

type Log = Arc<Mutex<Vec<String>>>;

/// The Swift test's `pinnedStore`: every pin is accepted except the foreign
/// credential, whose binding is refused. Each call is logged.
fn pinned(path: &Path, log: &Log) -> WorkspaceProjectStore {
    let foreign = format!("credential:sha256-{}", "d".repeat(64));
    let entry = |log: &Log| {
        let log = Arc::clone(log);
        move |line: String| log.lock().unwrap().push(line)
    };
    let (a, b, c, d, e) = (entry(log), entry(log), entry(log), entry(log), entry(log));
    WorkspaceProjectStore::open(path)
        .unwrap()
        .with_dependency_pinning(
            Some(WorkspaceToolchainPinning {
                acquire: Box::new(move |reference, generation, preset| {
                    a(format!(
                        "toolchain.acquire {reference} {generation} {preset}"
                    ));
                    Ok(())
                }),
                release: Box::new(move |reference, preset| {
                    b(format!("toolchain.release {reference} {preset}"));
                    Ok(())
                }),
            }),
            Some(WorkspaceCredentialPinning {
                validate_binding: Box::new(move |reference, project| {
                    c(format!("credential.validate {reference} {project}"));
                    if reference == foreign {
                        return Err(WireError {
                            code: "resourceConflict".into(),
                            message: "signing credential belongs to another project".into(),
                            details: None,
                        });
                    }
                    Ok(())
                }),
                acquire: Box::new(move |reference, preset, project| {
                    d(format!("credential.acquire {reference} {preset} {project}"));
                    Ok(())
                }),
                release: Box::new(move |reference, preset| {
                    e(format!("credential.release {reference} {preset}"));
                    Ok(())
                }),
            }),
        )
}

fn call(store: &WorkspaceProjectStore, method: &str, params: Value) -> Result<Value, WireError> {
    store.handle(method, params.as_object().unwrap(), &|| NOW.into(), &|_| {
        Ok(())
    })
}

struct Replay {
    frames: Vec<Value>,
    swift_roots: String,
    rust_roots: String,
}
impl Replay {
    fn new(base: &Base) -> Self {
        let frames: Vec<Value> = FRAMES
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let swift_roots = frames[0]["params"]["root"]
            .as_str()
            .unwrap()
            .strip_suffix("/first")
            .unwrap()
            .to_owned();
        Self {
            frames,
            swift_roots,
            rust_roots: base.0.join("roots").to_str().unwrap().to_owned(),
        }
    }

    /// Frame `index` sent to `store` with `now` as its clock, its answer
    /// compared with Swift's.
    fn frame(&self, store: &WorkspaceProjectStore, index: usize, now: &dyn Fn() -> String) {
        let frame = &self.frames[index];
        let method = frame["method"].as_str().unwrap();
        let mut params: Map<String, Value> =
            frame["params"].as_object().cloned().unwrap_or_default();
        if let Some(Value::String(root)) = params.get_mut("root")
            && let Some(rest) = root.strip_prefix(&self.swift_roots)
        {
            *root = format!("{}{rest}", self.rust_roots);
        }
        let answer = store.handle(method, &params, now, &|_| Ok(()));
        if frame["ok"] == true {
            assert_eq!(
                answer.as_ref().map_err(|error| error.clone()),
                Ok(&frame["result"]),
                "frame {index} {method}"
            );
        } else {
            let error = answer.expect_err(&format!("frame {index} {method} must be refused"));
            let recorded = &frame["error"];
            assert_eq!(
                json!({"code": error.code, "message": error.message, "details": error.details}),
                json!({"code": recorded["code"], "message": recorded["message"],
                       "details": recorded.get("details")}),
                "frame {index} {method}"
            );
        }
    }
}

#[test]
fn the_rust_owner_answers_every_recorded_frame_as_swift_did() {
    let base = Base::new();
    let replay = Replay::new(&base);
    assert_eq!(replay.frames.len(), 78);
    let now = || -> String { NOW.into() };

    // Frames 0-52: registration, reads, updates and removals on one owner
    // whose pins are all accepted but the foreign credential's.
    let log: Log = Arc::default();
    let owner = base.owner("owner");
    let main = pinned(&owner, &log);
    for index in 0..=52 {
        replay.frame(&main, index, &now);
    }
    let toolchain = format!("toolchain:sha256:{}", "b".repeat(64));
    let credential = format!("credential:sha256-{}", "c".repeat(64));
    let foreign = format!("credential:sha256-{}", "d".repeat(64));
    let beta = replay.frames[1]["result"]["projectRef"].as_str().unwrap();
    let build = replay.frames[3]["result"]["presetRef"].as_str().unwrap();
    let signing = replay.frames[6]["result"]["presetRef"].as_str().unwrap();
    assert_eq!(
        *log.lock().unwrap(),
        [
            format!("toolchain.acquire {toolchain} 1 {build}"),
            format!("credential.validate {credential} {beta}"),
            format!("toolchain.acquire {toolchain} 1 {signing}"),
            format!("credential.acquire {credential} {signing} {beta}"),
            format!("credential.validate {foreign} {beta}"),
            format!("toolchain.release {toolchain} {build}"),
        ],
        "the dependency transaction pins and releases as Swift's store does"
    );

    // The document after frame 52 is Swift's: its presets byte for byte,
    // its projects in every field but the private roots.
    let swift: &[u8] =
        include_bytes!("../../../tests/fixtures/workspace-mutation-oracle/swift-projects.json");
    let rust = fs::read(owner.join("projects.json")).unwrap();
    let presets = |bytes: &[u8]| -> String {
        let text = std::str::from_utf8(bytes).unwrap();
        let body = text.strip_prefix("{\"presets\":").unwrap();
        body[..body.find(",\"records\":[").unwrap()].to_owned()
    };
    assert_eq!(presets(&rust), presets(swift));
    let projects = |bytes: &[u8]| -> Value {
        let mut document: Value = serde_json::from_slice(bytes).unwrap();
        for record in document["records"].as_array_mut().unwrap() {
            let record = record.as_object_mut().unwrap();
            for key in ["root", "registrationRoot", "registrationDigest"] {
                assert!(record.remove(key).is_some(), "{key}");
            }
        }
        document.as_object_mut().unwrap().remove("presets");
        document
    };
    assert_eq!(projects(&rust), projects(swift));

    // Frame 53: the same document under an owner without dependency pins
    // refuses a pinned preset before any write.
    let unpinned = WorkspaceProjectStore::open(&owner).unwrap();
    let before = fs::read(owner.join("projects.json")).unwrap();
    replay.frame(&unpinned, 53, &now);
    assert_eq!(fs::read(owner.join("projects.json")).unwrap(), before);

    // Frame 54: a full owner refuses the 257th preset. Swift registered the
    // 256 presets through its store; here the owner registers the first and
    // the other 255 are written in the same shape, because registering each
    // revalidates every earlier record and takes most of a minute unoptimized.
    // A record written wrongly would make the owner answer recordUnreadable.
    let quota_owner = base.owner("quota");
    let quota = pinned(&quota_owner, &Arc::default());
    let project = call(
        &quota,
        "workspace.project.register",
        json!({"registrationRequestId": "quota-project", "kind": "openharmony",
               "root": base.root("first")}),
    )
    .unwrap()["projectRef"]
        .clone();
    let symbol = |n: usize| {
        json!({"registrationRequestId": format!("quota-{n}"), "projectRef": project,
               "kind": "symbol", "templateRef": "openharmony.arkts-symbol@1",
               "timeoutSeconds": "60", "relativeSourceMap": format!("entry/{n}.map")})
    };
    call(&quota, "workspace.preset.register", symbol(0)).unwrap();
    let full = quota_owner.join("projects.json");
    let mut document: Value = serde_json::from_slice(&fs::read(&full).unwrap()).unwrap();
    let first = document["presets"][0].clone();
    let mut presets = vec![first.clone()];
    for n in 1..256 {
        let request = format!("quota-{n}");
        let constraints = json!({"relativeSourceMap": format!("entry/{n}.map")});
        let digest = arkdeck_contract::sha256_hex(
            &arkdeck_contract::canonical_json(&json!({
                "schemaVersion": "arkdeck.workspace-preset-definition/1",
                "projectRef": project, "kind": "symbol",
                "templateRef": "openharmony.arkts-symbol@1", "toolchainRef": null,
                "toolchainGeneration": null, "credentialRef": null, "timeoutSeconds": 60,
                "constraints": constraints,
            }))
            .unwrap(),
        );
        let mut preset = first.clone();
        for (key, value) in [
            (
                "presetRef",
                json!(format!(
                    "preset-{}",
                    &arkdeck_contract::sha256_hex(request.as_bytes())[..24]
                )),
            ),
            ("registrationRequestID", json!(request)),
            ("lastMutationRequestID", json!(request)),
            ("constraints", constraints.clone()),
            ("registrationConstraints", constraints),
            ("registrationDigest", json!(digest)),
            ("currentDefinitionDigest", json!(digest)),
            ("lastMutationDigest", json!(digest)),
        ] {
            preset[key] = value;
        }
        presets.push(preset);
    }
    presets.sort_by(|a, b| a["presetRef"].as_str().cmp(&b["presetRef"].as_str()));
    document["presets"] = json!(presets);
    fs::write(&full, serde_json::to_vec(&document).unwrap()).unwrap();
    // The owner reads the full document back as its own before refusing.
    let listed = call(
        &quota,
        "workspace.preset.list",
        json!({"projectRef": project}),
    )
    .unwrap();
    assert_eq!(listed["presets"].as_array().unwrap().len(), 256);
    replay.frame(&quota, 54, &now);

    // Frames 55-68: a retained dependency mutation, then an unreadable
    // document, refuse all seven methods and leave the file as it was.
    let projects = owner.join("projects.json");
    let original = fs::read(&projects).unwrap();
    let mut document: Value = serde_json::from_slice(&original).unwrap();
    document["pendingToolchainMutation"] = json!({
        "action": "release", "toolchainRef": toolchain, "toolchainGeneration": 1,
        "presetRef": "preset-retained",
    });
    let pending = serde_json::to_vec(&document).unwrap();
    for (bytes, frames) in [(pending, 55..=61), (b"{broken".to_vec(), 62..=68)] {
        fs::write(&projects, &bytes).unwrap();
        for index in frames {
            replay.frame(&unpinned, index, &now);
            assert_eq!(fs::read(&projects).unwrap(), bytes, "frame {index}");
        }
    }
    fs::write(&projects, &original).unwrap();

    // Frames 69-77: staging and rename failures raised from inside the clock,
    // after the document is loaded and before it is published, each on an
    // owner holding one project and one preset.
    let methods = [
        "workspace.project.update",
        "workspace.project.remove",
        "workspace.preset.register",
        "workspace.preset.update",
        "workspace.preset.remove",
    ];
    let mut index = 69;
    for failure in ["ioFailure", "outcomeUnknown"] {
        for (offset, method) in methods.iter().enumerate() {
            if failure == "outcomeUnknown" && *method == "workspace.project.remove" {
                continue;
            }
            let directory = base.owner(&format!("fault-{failure}-{offset}"));
            let prepared = pinned(&directory, &Arc::default());
            let project = call(
                &prepared,
                "workspace.project.register",
                json!({"registrationRequestId": "fault-project", "kind": "openharmony",
                       "root": base.root("first")}),
            )
            .unwrap()["projectRef"]
                .clone();
            if *method != "workspace.project.remove" {
                call(
                    &prepared,
                    "workspace.preset.register",
                    json!({"registrationRequestId": "fault-preset", "projectRef": project,
                           "kind": "symbol", "templateRef": "openharmony.arkts-symbol@1",
                           "timeoutSeconds": "60", "relativeSourceMap": "entry/a.map"}),
                )
                .unwrap();
            }
            let faulty = pinned(&directory, &Arc::default());
            let fault = || -> String {
                if failure == "ioFailure" {
                    fs::set_permissions(&directory, fs::Permissions::from_mode(0o500)).unwrap();
                } else {
                    let document = directory.join("projects.json");
                    let _ = fs::remove_file(&document);
                    let _ = fs::create_dir(&document);
                }
                NOW.into()
            };
            if *method == "workspace.project.remove" {
                // Removal reads no clock: its directory is read-only first.
                fs::set_permissions(&directory, fs::Permissions::from_mode(0o500)).unwrap();
            }
            assert_eq!(replay.frames[index]["method"], *method);
            assert_eq!(replay.frames[index]["error"]["code"], failure);
            replay.frame(&faulty, index, &fault);
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
            index += 1;
        }
    }
    assert_eq!(index, 78);
}
