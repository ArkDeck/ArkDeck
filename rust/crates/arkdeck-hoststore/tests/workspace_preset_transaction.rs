//! The crash-recovered dependency transaction of workspace preset mutations,
//! as Swift `RuntimeWorkspaceProjectStore.reconcileDependencyMutation` runs it
//! (TASK-XPA-015, M3): an intent persisted before a process died is completed
//! by the next access, a refused pin abandons the intent and restores the
//! document, a changed dependency is acquired before the old one is released,
//! and an intent that does not match the durable record is refused.
#![cfg(target_os = "macos")]
use arkdeck_contract::WireError;
use arkdeck_hoststore::{
    WorkspaceCredentialPinning, WorkspaceProjectStore, WorkspaceToolchainPinning,
};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::DirBuilderExt,
    path::PathBuf,
    sync::{Arc, Mutex},
};

const NOW: &str = "2026-09-19T00:00:00.000Z";

fn toolchain(digit: &str) -> String {
    format!("toolchain:sha256:{}", digit.repeat(64))
}
fn credential(digit: &str) -> String {
    format!("credential:sha256-{}", digit.repeat(64))
}

struct Fixture {
    base: PathBuf,
    log: Arc<Mutex<Vec<String>>>,
}
impl Fixture {
    fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let base = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("workspace-transaction-{nonce:032x}"));
        for name in ["", "owner", "root"] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(base.join(name))
                .unwrap();
        }
        Self {
            base,
            log: Arc::default(),
        }
    }

    /// An owner whose pins succeed, except a toolchain acquire when
    /// `refuse_toolchain` is set, which the DevEco owner refuses.
    fn store(&self, refuse_toolchain: bool) -> WorkspaceProjectStore {
        let entry = || {
            let log = Arc::clone(&self.log);
            move |line: String| log.lock().unwrap().push(line)
        };
        let (a, b, c, d) = (entry(), entry(), entry(), entry());
        WorkspaceProjectStore::open(&self.base.join("owner"))
            .unwrap()
            .with_dependency_pinning(
                Some(WorkspaceToolchainPinning {
                    acquire: Box::new(move |reference, generation, preset| {
                        if refuse_toolchain {
                            return Err(WireError {
                                code: "resourceConflict".into(),
                                message: "DevEco toolchain is retired or changed".into(),
                                details: None,
                            });
                        }
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
                    validate_binding: Box::new(|_, _| Ok(())),
                    acquire: Box::new(move |reference, preset, _| {
                        c(format!("credential.acquire {reference} {preset}"));
                        Ok(())
                    }),
                    release: Box::new(move |reference, preset| {
                        d(format!("credential.release {reference} {preset}"));
                        Ok(())
                    }),
                }),
            )
    }

    fn call(
        &self,
        store: &WorkspaceProjectStore,
        method: &str,
        params: Value,
    ) -> Result<Value, WireError> {
        store.handle(method, params.as_object().unwrap(), &|| NOW.into(), &|_| {
            Ok(())
        })
    }

    fn project(&self, store: &WorkspaceProjectStore) -> String {
        self.call(
            store,
            "workspace.project.register",
            json!({"registrationRequestId": "project", "kind": "openharmony",
                   "root": self.base.join("root").to_str().unwrap()}),
        )
        .unwrap()["projectRef"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    fn document(&self) -> Value {
        serde_json::from_slice(&self.bytes()).unwrap()
    }
    fn bytes(&self) -> Vec<u8> {
        fs::read(self.base.join("owner/projects.json")).unwrap()
    }
    fn write(&self, document: &Value) {
        fs::write(
            self.base.join("owner/projects.json"),
            serde_json::to_vec(document).unwrap(),
        )
        .unwrap();
    }
    fn take_log(&self) -> Vec<String> {
        std::mem::take(&mut *self.log.lock().unwrap())
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.base);
    }
}

fn build(project: &str, request: &str, digit: &str) -> Value {
    json!({"registrationRequestId": request, "projectRef": project, "kind": "build",
           "templateRef": "openharmony.hvigor-build@1", "timeoutSeconds": "600",
           "toolchainRef": toolchain(digit), "toolchainGeneration": "1",
           "module": "entry", "product": "default", "buildMode": "debug"})
}
fn signing(project: &str, request: &str) -> Value {
    json!({"registrationRequestId": request, "projectRef": project, "kind": "signing",
           "templateRef": "openharmony.local-sign@1", "timeoutSeconds": "600",
           "toolchainRef": toolchain("a"), "toolchainGeneration": "1",
           "credentialRef": credential("c")})
}
/// `definition` as an update of `preset` at `generation`.
fn update(definition: Value, preset: &str, request: &str, generation: &str) -> Value {
    let mut fields = definition;
    let fields_map = fields.as_object_mut().unwrap();
    fields_map.remove("registrationRequestId");
    fields_map.insert("mutationRequestId".into(), json!(request));
    fields_map.insert("presetRef".into(), json!(preset));
    fields_map.insert("expectedGeneration".into(), json!(generation));
    fields
}

#[test]
fn an_acquire_intent_left_by_a_dead_process_is_completed_by_the_next_access() {
    let fixture = Fixture::new();
    let store = fixture.store(false);
    let project = fixture.project(&store);
    let preset = fixture
        .call(
            &store,
            "workspace.preset.register",
            build(&project, "build", "a"),
        )
        .unwrap();
    let preset_ref = preset["presetRef"].as_str().unwrap().to_owned();
    fixture.take_log();
    // The document as Swift leaves it between persisting the intent and
    // publishing the preset: the record only inside the pending mutation.
    let mut document = fixture.document();
    let record = document["presets"][0].clone();
    document["presets"] = json!([]);
    document["pendingToolchainMutation"] = json!({
        "action": "acquire", "toolchainRef": toolchain("a"), "toolchainGeneration": 1,
        "presetRef": preset_ref, "proposedRecord": record,
    });
    fixture.write(&document);
    let restarted = fixture.store(false);
    let listed = fixture
        .call(
            &restarted,
            "workspace.preset.list",
            json!({"projectRef": project}),
        )
        .unwrap();
    assert_eq!(listed["presets"], json!([preset]));
    assert_eq!(
        fixture.take_log(),
        [format!(
            "toolchain.acquire {} 1 {preset_ref}",
            toolchain("a")
        )]
    );
    let completed = fixture.document();
    assert!(completed.get("pendingToolchainMutation").is_none());
    assert_eq!(completed["presets"], json!([record]));
}

#[test]
fn a_refused_pin_abandons_the_intent_and_restores_the_document() {
    let fixture = Fixture::new();
    let store = fixture.store(true);
    let project = fixture.project(&store);
    let before = fixture.bytes();
    let refused = fixture
        .call(
            &store,
            "workspace.preset.register",
            build(&project, "build", "a"),
        )
        .unwrap_err();
    assert_eq!(
        (refused.code.as_str(), refused.message.as_str()),
        ("resourceConflict", "DevEco toolchain is retired or changed")
    );
    assert_eq!(
        refused.details,
        Some(serde_json::Map::from_iter([
            ("phase".into(), json!("workspacePresetOwner")),
            ("newDispatchCount".into(), json!(0)),
        ]))
    );
    assert_eq!(
        fixture.bytes(),
        before,
        "nothing of the refused preset remains"
    );
    assert!(fixture.take_log().is_empty());
}

#[test]
fn a_changed_toolchain_is_acquired_before_the_old_one_is_released() {
    let fixture = Fixture::new();
    let store = fixture.store(false);
    let project = fixture.project(&store);
    let preset = fixture
        .call(
            &store,
            "workspace.preset.register",
            build(&project, "build", "a"),
        )
        .unwrap()["presetRef"]
        .as_str()
        .unwrap()
        .to_owned();
    fixture.take_log();
    let moved = fixture
        .call(
            &store,
            "workspace.preset.update",
            update(build(&project, "unused", "b"), &preset, "move", "1"),
        )
        .unwrap();
    assert_eq!(
        (&moved["generation"], &moved["toolchainRef"]),
        (&json!("2"), &json!(toolchain("b")))
    );
    assert_eq!(
        fixture.take_log(),
        [
            format!("toolchain.acquire {} 1 {preset}", toolchain("b")),
            format!("toolchain.release {} {preset}", toolchain("a")),
        ]
    );
    assert!(fixture.document().get("pendingToolchainMutation").is_none());
    // The same definition again changes no dependency and pins nothing.
    fixture
        .call(
            &store,
            "workspace.preset.update",
            update(build(&project, "unused", "b"), &preset, "again", "2"),
        )
        .unwrap();
    assert!(fixture.take_log().is_empty());
}

#[test]
fn dropping_or_removing_a_preset_s_dependencies_releases_every_pin() {
    let fixture = Fixture::new();
    let store = fixture.store(false);
    let project = fixture.project(&store);
    let first = fixture
        .call(
            &store,
            "workspace.preset.register",
            signing(&project, "signing"),
        )
        .unwrap()["presetRef"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        fixture.take_log(),
        [
            format!("toolchain.acquire {} 1 {first}", toolchain("a")),
            format!("credential.acquire {} {first}", credential("c")),
        ]
    );
    // Signing to symbol: nothing is pinned any more, so both are released.
    let symbol = json!({"kind": "symbol", "templateRef": "openharmony.arkts-symbol@1",
        "timeoutSeconds": "60", "relativeSourceMap": "entry/a.map", "projectRef": project,
        "registrationRequestId": "unused"});
    let changed = fixture
        .call(
            &store,
            "workspace.preset.update",
            update(symbol, &first, "drop", "1"),
        )
        .unwrap();
    assert_eq!(changed["kind"], "symbol");
    assert_eq!(
        fixture.take_log(),
        [
            format!("toolchain.release {} {first}", toolchain("a")),
            format!("credential.release {} {first}", credential("c")),
        ]
    );
    // Removing a pinned preset releases its pins after the removal is durable.
    let second = fixture
        .call(
            &store,
            "workspace.preset.register",
            signing(&project, "second"),
        )
        .unwrap()["presetRef"]
        .as_str()
        .unwrap()
        .to_owned();
    fixture.take_log();
    let removed = fixture
        .call(
            &store,
            "workspace.preset.remove",
            json!({"mutationRequestId": "remove", "projectRef": project,
                   "presetRef": second, "expectedGeneration": "1"}),
        )
        .unwrap();
    assert_eq!(removed["configurationStatus"], "removed");
    assert_eq!(
        fixture.take_log(),
        [
            format!("toolchain.release {} {second}", toolchain("a")),
            format!("credential.release {} {second}", credential("c")),
        ]
    );
    let document = fixture.document();
    assert!(document.get("pendingToolchainMutation").is_none());
    // Swift's encoder omits a nil optional; so does this owner.
    let symbol_record = document["presets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|preset| preset["presetRef"] == first)
        .unwrap();
    for key in ["toolchainRef", "toolchainGeneration", "credentialRef"] {
        assert!(symbol_record.get(key).is_none(), "{key}");
    }
}

#[test]
fn an_intent_that_does_not_match_its_record_is_refused_without_a_write() {
    let fixture = Fixture::new();
    let store = fixture.store(false);
    let project = fixture.project(&store);
    let preset = fixture
        .call(
            &store,
            "workspace.preset.register",
            build(&project, "build", "a"),
        )
        .unwrap()["presetRef"]
        .as_str()
        .unwrap()
        .to_owned();
    fixture.take_log();
    let record = fixture.document()["presets"][0].clone();
    let list = json!({"projectRef": project});
    for (pending, message) in [
        // Releasing the toolchain the available preset still holds.
        (
            json!({"action": "release", "toolchainRef": toolchain("a"),
                   "toolchainGeneration": 1, "presetRef": preset}),
            "workspace preset release does not match its durable record",
        ),
        // Releasing for a preset the document does not carry.
        (
            json!({"action": "release", "toolchainRef": toolchain("a"),
                   "toolchainGeneration": 1, "presetRef": "preset-retained"}),
            "workspace preset release does not match its durable record",
        ),
        // Acquiring a toolchain the proposed record does not name.
        (
            json!({"action": "acquire", "toolchainRef": toolchain("b"),
                   "toolchainGeneration": 1, "presetRef": preset,
                   "proposedRecord": record}),
            "workspace preset acquire transaction is inconsistent",
        ),
        // A release that also proposes a record.
        (
            json!({"action": "release", "toolchainRef": toolchain("a"),
                   "toolchainGeneration": 1, "presetRef": preset,
                   "proposedRecord": record}),
            "workspace preset release transaction is inconsistent",
        ),
        (
            json!({"action": "swap", "toolchainRef": toolchain("a"),
                   "toolchainGeneration": 1, "presetRef": preset}),
            "workspace preset transaction is inconsistent",
        ),
    ] {
        let mut document = fixture.document();
        document["pendingToolchainMutation"] = pending;
        fixture.write(&document);
        let before = fixture.bytes();
        let refused = fixture
            .call(&store, "workspace.preset.list", list.clone())
            .unwrap_err();
        assert_eq!(
            (refused.code.as_str(), refused.message.as_str()),
            ("recordUnreadable", message)
        );
        assert_eq!(fixture.bytes(), before);
        let mut restored = fixture.document();
        restored
            .as_object_mut()
            .unwrap()
            .remove("pendingToolchainMutation");
        fixture.write(&restored);
    }
    assert!(
        fixture.take_log().is_empty(),
        "no refused intent pinned anything"
    );
}

#[test]
fn a_retained_intent_without_its_owner_refuses_every_access_by_that_owner() {
    let fixture = Fixture::new();
    let store = fixture.store(false);
    let project = fixture.project(&store);
    let mut document = fixture.document();
    document["pendingToolchainMutation"] = json!({
        "action": "release", "credentialRef": credential("c"), "presetRef": "preset-retained",
    });
    fixture.write(&document);
    let before = fixture.bytes();
    let unpinned = WorkspaceProjectStore::open(&fixture.base.join("owner")).unwrap();
    for (method, params) in [
        ("workspace.project.list", json!({})),
        ("workspace.preset.list", json!({"projectRef": project})),
    ] {
        let refused = fixture.call(&unpinned, method, params).unwrap_err();
        assert_eq!(
            (refused.code.as_str(), refused.message.as_str()),
            (
                "operationUnavailable",
                "signing credential reference owner is unavailable"
            ),
            "{method}"
        );
        assert_eq!(fixture.bytes(), before);
    }
}

/// One key more than Swift's `PresetRecord` or `PendingDependencyMutation`
/// is refused, not dropped.
#[test]
fn a_preset_or_intent_with_one_more_key_is_refused() {
    let fixture = Fixture::new();
    let store = fixture.store(false);
    let project = fixture.project(&store);
    let preset = fixture
        .call(
            &store,
            "workspace.preset.register",
            build(&project, "build", "a"),
        )
        .unwrap()["presetRef"]
        .as_str()
        .unwrap()
        .to_owned();
    let original = fixture.document();
    let record = original["presets"][0].clone();
    let mut extended = record.clone();
    extended["note"] = json!("x");
    let mut documents = Vec::new();
    let mut one = original.clone();
    one["presets"][0]["note"] = json!("x");
    documents.push(one);
    let mut two = original.clone();
    two["pendingToolchainMutation"] = json!({"action": "release",
        "toolchainRef": toolchain("a"), "toolchainGeneration": 1, "presetRef": preset,
        "note": "x"});
    documents.push(two);
    let mut three = original.clone();
    three["presets"] = json!([]);
    three["pendingToolchainMutation"] = json!({"action": "acquire",
        "toolchainRef": toolchain("a"), "toolchainGeneration": 1, "presetRef": preset,
        "proposedRecord": extended});
    documents.push(three);
    for document in documents {
        fixture.write(&document);
        let before = fixture.bytes();
        let refused = fixture
            .call(
                &store,
                "workspace.preset.list",
                json!({"projectRef": project}),
            )
            .unwrap_err();
        assert_eq!(refused.code, "recordUnreadable", "{document}");
        assert_eq!(fixture.bytes(), before);
    }
    fixture.write(&original);
    fixture
        .call(
            &store,
            "workspace.preset.list",
            json!({"projectRef": project}),
        )
        .unwrap();
}
