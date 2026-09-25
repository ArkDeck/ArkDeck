//! Production local owner tests. No workspace execution, signing or device facts.
#![cfg(target_os = "macos")]
use arkdeck_hoststore::WorkspaceProjectStore;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt, symlink},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};
const NOW: &str = "2026-09-19T00:00:00.000Z";
/// Tests run as threads of one process, and the clock's resolution is
/// coarser than their start spacing: each root also takes a sequence number.
static ROOTS: AtomicUsize = AtomicUsize::new(0);
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-workspace-project-{}-{}-{}",
            std::process::id(),
            ROOTS.fetch_add(1, Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        for name in ["owner", "first", "second"] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(path.join(name))
                .unwrap();
        }
        Self(path)
    }
    fn store(&self) -> WorkspaceProjectStore {
        WorkspaceProjectStore::open(&self.0.join("owner")).unwrap()
    }
    fn path(&self) -> PathBuf {
        self.0.join("owner/projects.json")
    }
    fn params(&self, id: &str, root: &str) -> Value {
        json!({"registrationRequestId":id,"kind":"openharmony","root":self.0.join(root).to_str().unwrap()})
    }
    fn write(&self, value: &Value) {
        fs::write(self.path(), serde_json::to_vec(value).unwrap()).unwrap();
        fs::set_permissions(self.path(), fs::Permissions::from_mode(0o600)).unwrap();
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn call(
    owner: &WorkspaceProjectStore,
    verb: &str,
    params: Value,
) -> Result<Value, arkdeck_contract::WireError> {
    // Registration, listing and reading never consult the Job census.
    owner.handle(
        &format!("workspace.project.{verb}"),
        params.as_object().unwrap(),
        &|| NOW.into(),
        &|_| panic!("only a project mutation consults the Job census"),
    )
}
#[test]
fn real_nonempty_registration_is_private_idempotent_and_survives_restart() {
    let root = Root::new();
    let owner = root.store();
    let first = call(&owner, "register", root.params("registration-a", "first")).unwrap();
    let bytes = fs::read(root.path()).unwrap();
    assert_eq!(
        call(&owner, "register", root.params("registration-a", "first")).unwrap(),
        first
    );
    assert_eq!(bytes, fs::read(root.path()).unwrap());
    assert_eq!(
        first["projectRef"],
        format!(
            "project-{}",
            &arkdeck_contract::sha256_hex(b"registration-a")[..24]
        )
    );
    assert!(!first.to_string().contains(root.0.to_str().unwrap()));
    assert!(first.get("inode").is_none());
    call(&owner, "register", root.params("registration-b", "second")).unwrap();
    drop(owner);
    let reopened = root.store();
    let list = call(&reopened, "list", json!({})).unwrap();
    assert_eq!(list["projects"].as_array().unwrap().len(), 2);
    assert_eq!(
        call(&reopened, "show", json!({"projectRef":first["projectRef"]})).unwrap(),
        first
    );
    assert_eq!(
        fs::metadata(root.path()).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(first["configurationStatus"], "runtimeRestartRequired");
    assert_eq!(first["operations"], json!([]));
}
#[test]
fn changed_root_and_registration_tuple_cannot_reuse_receipt() {
    let root = Root::new();
    let owner = root.store();
    call(&owner, "register", root.params("one", "first")).unwrap();
    assert_eq!(
        call(&owner, "register", root.params("one", "second"))
            .unwrap_err()
            .code,
        "idempotencyConflict"
    );
    assert_eq!(
        call(&owner, "register", root.params("two", "first"))
            .unwrap_err()
            .code,
        "resourceConflict"
    );
    fs::rename(root.0.join("first"), root.0.join("old-first")).unwrap();
    fs::create_dir(root.0.join("first")).unwrap();
    assert_eq!(
        call(&owner, "register", root.params("one", "first"))
            .unwrap_err()
            .code,
        "idempotencyConflict"
    );
    assert_eq!(
        call(&owner, "show", json!({"projectRef":"unknown"}))
            .unwrap_err()
            .code,
        "workspaceReferenceNotFound"
    );
}
#[test]
fn parallel_identical_registration_has_one_durable_row() {
    let root = Root::new();
    let owner = Arc::new(root.store());
    let params = root.params("one", "first");
    std::thread::scope(|scope| {
        let joins: Vec<_> = (0..8)
            .map(|_| {
                let owner = owner.clone();
                let params = params.clone();
                scope.spawn(move || call(&owner, "register", params).unwrap())
            })
            .collect();
        let rows: Vec<_> = joins.into_iter().map(|j| j.join().unwrap()).collect();
        assert!(rows.iter().all(|v| v == &rows[0]));
    });
    assert_eq!(
        call(&owner, "list", json!({})).unwrap()["projects"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}
#[test]
fn symlink_ancestry_duplicate_json_and_nonprivate_store_are_refused() {
    let root = Root::new();
    let owner = root.store();
    symlink(root.0.join("first"), root.0.join("link")).unwrap();
    assert_eq!(
        call(&owner, "register", root.params("one", "link"))
            .unwrap_err()
            .code,
        "invalidInput"
    );
    fs::write(
        root.path(),
        b"{\"records\":[],\"records\":[],\"schemaVersion\":\"arkdeck.workspace-project-store/3\"}",
    )
    .unwrap();
    fs::set_permissions(root.path(), fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(
        call(&owner, "list", json!({})).unwrap_err().code,
        "recordUnreadable"
    );
    root.write(
        &json!({"schemaVersion":"arkdeck.workspace-project-store/3","records":[],"presets":[]}),
    );
    fs::set_permissions(root.path(), fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(
        call(&owner, "list", json!({})).unwrap_err().code,
        "recordUnreadable"
    );
}
#[test]
fn pending_dependency_transaction_is_retained_byte_for_byte_on_every_entry() {
    let root = Root::new();
    let owner = root.store();
    let first = call(&owner, "register", root.params("one", "first")).unwrap();
    let mut document: Value = serde_json::from_slice(&fs::read(root.path()).unwrap()).unwrap();
    document["pendingToolchainMutation"] = json!({"action":"release","toolchainRef":format!("toolchain:sha256:{}","a".repeat(64)),"toolchainGeneration":1,"presetRef":"preset-old"});
    root.write(&document);
    let before = fs::read(root.path()).unwrap();
    for (method, params) in [
        ("list", json!({})),
        ("show", json!({"projectRef":first["projectRef"]})),
        ("register", root.params("two", "second")),
    ] {
        assert_eq!(
            call(&owner, method, params).unwrap_err().code,
            "operationUnavailable"
        );
        assert_eq!(before, fs::read(root.path()).unwrap());
    }
    drop(owner);
    assert_eq!(
        call(&root.store(), "list", json!({})).unwrap_err().code,
        "operationUnavailable"
    );
    assert_eq!(before, fs::read(root.path()).unwrap());
}
fn retained_symbol(project: &str) -> Value {
    let constraints = json!({"relativeSourceMap":"maps/main.js.map"});
    let definition = json!({"schemaVersion":"arkdeck.workspace-preset-definition/1","projectRef":project,"kind":"symbol","templateRef":"openharmony.arkts-symbol@1","toolchainRef":null,"toolchainGeneration":null,"credentialRef":null,"timeoutSeconds":60,"constraints":constraints});
    let digest =
        arkdeck_contract::sha256_hex(&arkdeck_contract::canonical_json(&definition).unwrap());
    json!({"presetRef":"preset-retained","generation":1,"projectRef":project,"kind":"symbol","templateRef":"openharmony.arkts-symbol@1","timeoutSeconds":60,"constraints":constraints,"registrationRequestID":"preset-registration","registrationProjectRef":project,"registrationKind":"symbol","registrationTemplateRef":"openharmony.arkts-symbol@1","registrationTimeoutSeconds":60,"registrationConstraints":constraints,"registrationDigest":digest,"currentDefinitionDigest":digest,"registeredAtUTC":NOW,"updatedAtUTC":NOW,"state":"available","lastMutationRequestID":"preset-registration","lastMutationDigest":digest})
}
#[test]
fn completed_presets_are_validated_and_preserved_without_acquiring_dependencies() {
    let root = Root::new();
    let owner = root.store();
    let first = call(&owner, "register", root.params("one", "first")).unwrap();
    let mut document: Value = serde_json::from_slice(&fs::read(root.path()).unwrap()).unwrap();
    let preset = retained_symbol(first["projectRef"].as_str().unwrap());
    document["presets"] = json!([preset]);
    root.write(&document);
    call(&owner, "register", root.params("two", "second")).unwrap();
    let mut saved: Value = serde_json::from_slice(&fs::read(root.path()).unwrap()).unwrap();
    assert_eq!(saved["presets"], json!([preset]));
    saved["presets"][0]["currentDefinitionDigest"] = json!("b".repeat(64));
    root.write(&saved);
    let bytes = fs::read(root.path()).unwrap();
    assert_eq!(
        call(&owner, "list", json!({})).unwrap_err().code,
        "recordUnreadable"
    );
    assert_eq!(bytes, fs::read(root.path()).unwrap());
}

/// One preset or project request, with no Job to find in the census.
fn owner_call(
    owner: &WorkspaceProjectStore,
    method: &str,
    params: Value,
) -> Result<Value, arkdeck_contract::WireError> {
    owner.handle(method, params.as_object().unwrap(), &|| NOW.into(), &|_| {
        Ok(())
    })
}

/// A registered project with one symbol preset, the preset removed and then
/// the project: the removed preset's record stays behind, naming a project
/// the store no longer holds. Answers the project and preset references.
fn remove_after_presets(
    root: &Root,
    owner: &WorkspaceProjectStore,
    request: &str,
) -> (Value, Value) {
    let project =
        call(owner, "register", root.params(request, "first")).unwrap()["projectRef"].clone();
    let preset = owner_call(
        owner,
        "workspace.preset.register",
        json!({"registrationRequestId": format!("{request}-symbol"), "projectRef": project,
            "kind": "symbol", "templateRef": "openharmony.arkts-symbol@1",
            "timeoutSeconds": "300", "relativeSourceMap": "entry/build/sourceMaps.map"}),
    )
    .unwrap()["presetRef"]
        .clone();
    owner_call(
        owner,
        "workspace.preset.remove",
        json!({"mutationRequestId": format!("{request}-symbol-remove"), "projectRef": project,
            "presetRef": preset, "expectedGeneration": "1"}),
    )
    .unwrap();
    let removed = owner_call(
        owner,
        "workspace.project.remove",
        json!({"projectRef": project, "expectedGeneration": "1"}),
    )
    .unwrap();
    assert_eq!(removed["configurationStatus"], "removed");
    (project, preset)
}

/// The store a project removed after its presets leaves behind reads again,
/// now and after a restart: its list is empty, its project and presets are
/// not found, the preset removal's replay answers its tombstone.
#[test]
fn a_project_removed_after_its_presets_leaves_a_readable_store() {
    let root = Root::new();
    let owner = root.store();
    let (project, preset) = remove_after_presets(&root, &owner, "tombstone");
    for owner in [owner, root.store()] {
        assert_eq!(
            call(&owner, "list", json!({})).unwrap()["projects"],
            json!([])
        );
        assert_eq!(
            call(&owner, "show", json!({"projectRef": project}))
                .unwrap_err()
                .code,
            "workspaceReferenceNotFound"
        );
        assert_eq!(
            owner_call(
                &owner,
                "workspace.preset.list",
                json!({"projectRef": project})
            )
            .unwrap_err()
            .code,
            "workspaceReferenceNotFound"
        );
        let replay = owner_call(
            &owner,
            "workspace.preset.remove",
            json!({"mutationRequestId": "tombstone-symbol-remove", "projectRef": project,
                "presetRef": preset, "expectedGeneration": "1"}),
        )
        .unwrap();
        assert_eq!(replay["configurationStatus"], "removed");
    }
}

/// Only that shape is accepted: the same tombstone damaged, a preset in a
/// removed state its generation cannot have, and an available preset whose
/// project is gone are each refused, as before, and nothing is written.
#[test]
fn only_a_removed_preset_may_outlive_its_project() {
    let root = Root::new();
    let owner = root.store();
    let (_, preset) = remove_after_presets(&root, &owner, "tombstone");
    let healthy: Value = serde_json::from_slice(&fs::read(root.path()).unwrap()).unwrap();
    assert_eq!(healthy["presets"][0]["presetRef"], preset);
    let refused = |document: &Value, message: &str| {
        root.write(document);
        let bytes = fs::read(root.path()).unwrap();
        let error = call(&root.store(), "list", json!({})).unwrap_err();
        assert_eq!(
            (error.code.as_str(), error.message.as_str()),
            ("recordUnreadable", message)
        );
        assert_eq!(bytes, fs::read(root.path()).unwrap());
    };
    let mut damaged = healthy.clone();
    damaged["presets"][0]["lastMutationDigest"] = json!("0".repeat(64));
    refused(&damaged, "workspace preset store record is inconsistent");
    let mut regressed = healthy.clone();
    regressed["presets"][0]["generation"] = json!(1);
    refused(
        &regressed,
        "workspace preset state and generation are inconsistent",
    );
    // An available preset of a project that is registered, then the
    // project's record dropped from the file.
    let second = root.store();
    root.write(
        &json!({"schemaVersion": "arkdeck.workspace-project-store/3",
        "records": [], "presets": []}),
    );
    let project =
        call(&second, "register", root.params("available", "second")).unwrap()["projectRef"]
            .clone();
    owner_call(
        &second,
        "workspace.preset.register",
        json!({"registrationRequestId": "available-symbol", "projectRef": project,
            "kind": "symbol", "templateRef": "openharmony.arkts-symbol@1",
            "timeoutSeconds": "300", "relativeSourceMap": "entry/build/sourceMaps.map"}),
    )
    .unwrap();
    let mut orphan: Value = serde_json::from_slice(&fs::read(root.path()).unwrap()).unwrap();
    orphan["records"] = json!([]);
    refused(&orphan, "workspace preset store record is inconsistent");
    root.write(&healthy);
    assert_eq!(
        call(&root.store(), "list", json!({})).unwrap()["projects"],
        json!([])
    );
}

/// After the fix the removals repeat: the same project registered again, a
/// new preset registered and removed, the project removed again — each
/// succeeds, and the store with two tombstones still reads.
#[test]
fn the_preset_and_project_removals_can_be_repeated() {
    let root = Root::new();
    let owner = root.store();
    let (project, _) = remove_after_presets(&root, &owner, "tombstone");
    let again = call(&owner, "register", root.params("tombstone", "first")).unwrap();
    assert_eq!(again["projectRef"], project);
    let preset = owner_call(
        &owner,
        "workspace.preset.register",
        json!({"registrationRequestId": "tombstone-symbol-again", "projectRef": project,
            "kind": "symbol", "templateRef": "openharmony.arkts-symbol@1",
            "timeoutSeconds": "300", "relativeSourceMap": "entry/build/sourceMaps.map"}),
    )
    .unwrap()["presetRef"]
        .clone();
    owner_call(
        &owner,
        "workspace.preset.remove",
        json!({"mutationRequestId": "tombstone-symbol-again-remove", "projectRef": project,
            "presetRef": preset, "expectedGeneration": "1"}),
    )
    .unwrap();
    owner_call(
        &owner,
        "workspace.project.remove",
        json!({"projectRef": project, "expectedGeneration": "1"}),
    )
    .unwrap();
    let document: Value = serde_json::from_slice(&fs::read(root.path()).unwrap()).unwrap();
    assert_eq!(document["presets"].as_array().unwrap().len(), 2);
    assert_eq!(document["records"], json!([]));
    assert_eq!(
        call(&root.store(), "list", json!({})).unwrap()["projects"],
        json!([])
    );
}

/// A daemon starts over the store the removals leave behind: its composition
/// reads the registrations and the presets at start-up, as Swift's daemon
/// reads `startupRecords()` and `presetCompositionRecords()`, and before the
/// fix that read refused the store, so the daemon did not start.
#[test]
fn a_store_left_by_the_removals_composes_at_start_up() {
    let root = Root::new();
    let owner = root.store();
    remove_after_presets(&root, &owner, "tombstone");
    let store = Arc::new(root.store());
    let state = root.0.join("state");
    fs::DirBuilder::new().mode(0o700).create(&state).unwrap();
    let (_, notes) = arkdeck_hoststore::WorkspaceComposition::compose(
        Arc::clone(&store),
        &state,
        "/var/empty",
        || Some(NOW.into()),
        &|_, _, _| Err("the DevEco registry holds no toolchain".into()),
        None,
        None,
    )
    .unwrap();
    assert!(notes.unadopted.is_empty());
    assert!(store.startup_records().unwrap().is_empty());
    assert!(store.preset_composition_records().unwrap().is_empty());
}
