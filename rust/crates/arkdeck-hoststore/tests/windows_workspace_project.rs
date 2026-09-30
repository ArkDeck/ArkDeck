//! The workspace registration owner on NTFS (TASK-XPA-015): the store the
//! Windows daemon composes in `workspace-projects`, driven in process as the
//! Control layer drives it. A root is a drive path in the spelling on disk,
//! pinned by its volume serial and NTFS file reference; a link or junction in
//! its ancestry, another spelling of it, or a directory that replaced it is
//! refused as the macOS owner refuses a symbolic ancestry, a non-canonical
//! path or a moved root. No workspace execution, signing or device facts.
#![cfg(windows)]
use arkdeck_contract::{WireError, sha256_hex};
use arkdeck_hoststore::{WorkspaceProjectStore, WorkspaceReference};
use arkdeck_platform::HostDirectory;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const NOW: &str = "2026-09-30T00:00:00Z";

/// A fresh directory below the temporary directory, named as the disk
/// names it, with an owner-only `owner` the store lives in and two ordinary
/// project directories.
struct Root(PathBuf);
impl Root {
    fn new() -> Self {
        let temporary = std::fs::canonicalize(std::env::temp_dir()).unwrap();
        let temporary = temporary.to_str().unwrap();
        let temporary = temporary.strip_prefix(r"\\?\").unwrap_or(temporary);
        let nonce = u64::from_ne_bytes(arkdeck_platform::random_bytes::<8>().unwrap());
        let path = Path::new(temporary).join(format!("ad-winworkspace-{nonce:016x}"));
        std::fs::create_dir(&path).unwrap();
        HostDirectory::open_or_create_private(&path.join("owner")).unwrap();
        for name in ["first", "second"] {
            std::fs::create_dir(path.join(name)).unwrap();
        }
        Self(path)
    }
    fn store(&self) -> WorkspaceProjectStore {
        WorkspaceProjectStore::open(&self.0.join("owner")).unwrap()
    }
    fn at(&self, name: &str) -> String {
        self.0.join(name).to_str().unwrap().to_owned()
    }
    fn document(&self) -> Value {
        serde_json::from_slice(&std::fs::read(self.0.join("owner").join("projects.json")).unwrap())
            .unwrap()
    }
    /// A directory junction `name` to `target`, as an unelevated user makes
    /// one.
    fn junction(&self, name: &str, target: &str) {
        let status = Command::new("cmd.exe")
            .args(["/d", "/c", "mklink", "/J"])
            .arg(self.0.join(name))
            .arg(self.0.join(target))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "mklink /J {name}");
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn register(owner: &WorkspaceProjectStore, request: &str, root: &str) -> Result<Value, WireError> {
    call(
        owner,
        "workspace.project.register",
        json!({"registrationRequestId": request, "kind": "openharmony", "root": root}),
    )
}

/// Registration, listing and reading never consult the Job census.
fn call(owner: &WorkspaceProjectStore, method: &str, params: Value) -> Result<Value, WireError> {
    owner.handle(method, params.as_object().unwrap(), &|| NOW.into(), &|_| {
        panic!("only a project or preset mutation consults the Job census")
    })
}

/// A mutation, with a census that answers `census`.
fn mutate(
    owner: &WorkspaceProjectStore,
    method: &str,
    params: Value,
    census: &dyn Fn(WorkspaceReference<'_>) -> Result<(), WireError>,
) -> Result<Value, WireError> {
    owner.handle(method, params.as_object().unwrap(), &|| NOW.into(), census)
}

fn refused(result: Result<Value, WireError>, code: &str, message: &str) {
    let error = result.unwrap_err();
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        (code, message)
    );
    assert_eq!(
        error.details,
        Some(serde_json::Map::from_iter([
            ("phase".into(), json!("workspaceProjectOwner")),
            ("newDispatchCount".into(), json!(0)),
        ]))
    );
}

#[test]
fn a_registration_is_pinned_by_file_identity_and_survives_a_reopen() {
    let root = Root::new();
    let owner = root.store();
    let first = register(&owner, "registration-a", &root.at("first")).unwrap();
    assert_eq!(
        first["projectRef"],
        format!("project-{}", &sha256_hex(b"registration-a")[..24])
    );
    assert_eq!(first["configurationStatus"], "runtimeRestartRequired");
    assert_eq!(first["availability"], "unavailable");
    assert_eq!(first["operations"], json!([]));
    assert!(!first.to_string().contains(&root.at("first")), "{first}");
    let bytes = std::fs::read(root.0.join("owner").join("projects.json")).unwrap();
    // A replay answers the same and writes nothing.
    assert_eq!(
        register(&owner, "registration-a", &root.at("first")).unwrap(),
        first
    );
    assert_eq!(
        std::fs::read(root.0.join("owner").join("projects.json")).unwrap(),
        bytes
    );
    let document = root.document();
    assert_eq!(
        document["schemaVersion"],
        "arkdeck.workspace-project-store/3"
    );
    let record = &document["records"][0];
    assert_eq!(record["root"]["path"], root.at("first"));
    let (device, inode) = (
        record["root"]["device"].as_u64().unwrap(),
        record["root"]["inode"].as_u64().unwrap(),
    );
    assert!(device != 0 && inode != 0, "{record}");
    assert_eq!(record["registrationRoot"], record["root"]);
    assert_eq!(
        record["registrationDigest"],
        sha256_hex(format!("openharmony\0{}\0{device}\0{inode}", root.at("first")).as_bytes())
    );
    assert_eq!(record["registeredAtUTC"], NOW);

    register(&owner, "registration-b", &root.at("second")).unwrap();
    drop(owner);
    let reopened = root.store();
    let listed = call(&reopened, "workspace.project.list", json!({})).unwrap();
    assert_eq!(listed["schemaVersion"], "arkdeck.workspace-project-list/1");
    assert_eq!(listed["projects"].as_array().unwrap().len(), 2);
    assert_eq!(
        call(
            &reopened,
            "workspace.project.show",
            json!({"projectRef": first["projectRef"]})
        )
        .unwrap(),
        first
    );
    let started = reopened.startup_records().unwrap();
    assert_eq!(started.len(), 2);
    assert!(started.iter().all(|record| record.root.is_ok()));
}

#[test]
fn a_registration_tuple_and_a_root_are_not_reused() {
    let root = Root::new();
    let owner = root.store();
    register(&owner, "one", &root.at("first")).unwrap();
    refused(
        register(&owner, "one", &root.at("second")),
        "idempotencyConflict",
        "registration request identity belongs to another project",
    );
    refused(
        register(&owner, "two", &root.at("first")),
        "resourceConflict",
        "workspace root or project reference is already registered",
    );
    refused(
        call(
            &owner,
            "workspace.project.show",
            json!({"projectRef": "unknown"}),
        ),
        "workspaceReferenceNotFound",
        "workspace project is not registered",
    );
}

#[test]
fn only_the_spelling_on_disk_of_a_local_directory_is_a_root() {
    let root = Root::new();
    let owner = root.store();
    let canonical = "workspace root must be a canonical absolute directory";
    let first = root.at("first");
    let drive = &first[..2];
    for spelling in [
        "relative\\first".to_owned(),
        first.replace('\\', "/"),
        format!("{first}\\"),
        format!("{first}\\."),
        format!("{first}\\..\\first"),
        format!(r"\\?\{first}"),
        format!("{first}:stream"),
        format!("{first}."),
        format!("{drive}\\"),
        "/private/tmp/first".to_owned(),
    ] {
        refused(
            register(&owner, "spelling", &spelling),
            "invalidInput",
            canonical,
        );
    }
    // Opened, but not how the disk names it: another case of a component, or
    // of the drive letter.
    for spelling in [
        root.at("FIRST"),
        format!("{}{}", drive.to_ascii_lowercase(), &first[1..]),
    ] {
        refused(
            register(&owner, "case", &spelling),
            "invalidInput",
            canonical,
        );
    }
    // As on macOS, a name that cannot be looked up fails the ancestry walk,
    // and one that is not a directory fails the open.
    refused(
        register(&owner, "missing", &root.at("absent")),
        "invalidInput",
        "workspace root ancestry cannot contain a symbolic link",
    );
    std::fs::write(root.0.join("file"), b"").unwrap();
    refused(
        register(&owner, "file", &root.at("file")),
        "invalidInput",
        "workspace root cannot be opened as a directory",
    );
    assert!(!root.0.join("owner").join("projects.json").exists());
}

#[test]
fn a_junction_in_the_ancestry_or_at_the_root_is_refused() {
    let root = Root::new();
    let owner = root.store();
    std::fs::create_dir(root.0.join("first").join("inner")).unwrap();
    root.junction("linked", "first");
    let ancestry = "workspace root ancestry cannot contain a symbolic link";
    refused(
        register(&owner, "last", &root.at("linked")),
        "invalidInput",
        ancestry,
    );
    refused(
        register(&owner, "ancestor", &root.at("linked\\inner")),
        "invalidInput",
        ancestry,
    );
    // The directory itself, by its own name, is a root.
    register(&owner, "direct", &root.at("first\\inner")).unwrap();
}

#[test]
fn a_replaced_root_is_an_unavailable_project_not_an_unreadable_store() {
    let root = Root::new();
    let owner = root.store();
    let first = register(&owner, "one", &root.at("first")).unwrap();
    std::fs::rename(root.0.join("first"), root.0.join("moved")).unwrap();
    std::fs::create_dir(root.0.join("first")).unwrap();
    let started = owner.startup_records().unwrap();
    let error = started[0].root.as_ref().unwrap_err();
    assert_eq!(
        (error.code.as_str(), error.message.as_str()),
        (
            "factsDrifted",
            "workspace root identity changed after registration"
        )
    );
    // The same request for the new directory is another registration tuple.
    refused(
        register(&owner, "one", &root.at("first")),
        "idempotencyConflict",
        "registration request identity belongs to another project",
    );
    assert_eq!(
        call(
            &owner,
            "workspace.project.show",
            json!({"projectRef": first["projectRef"]})
        )
        .unwrap(),
        first
    );
}

/// The preset reads, and every project and preset mutation behind the Job
/// census: refused when the census cannot prove that no Job names the
/// reference (the Windows daemon, which composes no Job owner), carried out
/// on NTFS when it can.
#[test]
fn presets_are_read_and_mutations_wait_for_the_job_census() {
    let root = Root::new();
    let owner = root.store();
    let project = register(&owner, "one", &root.at("first")).unwrap()["projectRef"].clone();
    assert_eq!(
        call(
            &owner,
            "workspace.preset.list",
            json!({"projectRef": project})
        )
        .unwrap()["presets"],
        json!([])
    );
    let absent = call(
        &owner,
        "workspace.preset.show",
        json!({"projectRef": project, "presetRef": "preset-absent"}),
    )
    .unwrap_err();
    assert_eq!(absent.code, "workspaceReferenceNotFound");

    let unverified = |_: WorkspaceReference<'_>| {
        Err(WireError {
            code: "recordUnreadable".into(),
            message: "workspace Job references cannot be verified".into(),
            details: None,
        })
    };
    // No Job can name a preset not yet registered: its registration asks no
    // census.
    let symbol = json!({"registrationRequestId": "preset-one", "projectRef": project,
        "kind": "symbol", "templateRef": "openharmony.arkts-symbol@1", "timeoutSeconds": "600",
        "relativeSourceMap": "entry/build/sourceMaps.map"});
    let preset = mutate(&owner, "workspace.preset.register", symbol, &unverified).unwrap();
    assert_eq!(preset["kind"], "symbol", "{preset}");
    assert_eq!(
        preset["configurationStatus"], "runtimeRestartRequired",
        "{preset}"
    );
    let listed = call(
        &owner,
        "workspace.preset.list",
        json!({"projectRef": project}),
    )
    .unwrap();
    assert_eq!(listed["presets"], json!([preset]));
    assert_eq!(
        call(
            &owner,
            "workspace.preset.show",
            json!({"projectRef": project, "presetRef": preset["presetRef"]})
        )
        .unwrap(),
        preset
    );
    let before = std::fs::read(root.0.join("owner").join("projects.json")).unwrap();
    for (method, params) in [
        (
            "workspace.preset.update",
            json!({"mutationRequestId": "preset-update", "projectRef": project,
                "presetRef": preset["presetRef"], "expectedGeneration": "1",
                "kind": "symbol", "templateRef": "openharmony.arkts-symbol@1",
                "timeoutSeconds": "60", "relativeSourceMap": "entry/build/other.map"}),
        ),
        (
            "workspace.preset.remove",
            json!({"mutationRequestId": "preset-remove", "projectRef": project,
                "presetRef": preset["presetRef"], "expectedGeneration": "1"}),
        ),
        (
            "workspace.project.update",
            json!({"projectRef": project, "expectedGeneration": "1",
                "kind": "openharmony", "root": root.at("second")}),
        ),
        (
            "workspace.project.remove",
            json!({"projectRef": project, "expectedGeneration": "1"}),
        ),
    ] {
        let error = mutate(&owner, method, params, &unverified).unwrap_err();
        assert_eq!(error.code, "recordUnreadable", "{method}");
    }
    assert_eq!(
        std::fs::read(root.0.join("owner").join("projects.json")).unwrap(),
        before,
        "a refused mutation writes nothing"
    );

    let none = |_: WorkspaceReference<'_>| Ok(());
    let moved = mutate(
        &owner,
        "workspace.project.update",
        json!({"projectRef": project, "expectedGeneration": "1",
            "kind": "openharmony", "root": root.at("second")}),
        &none,
    )
    .unwrap();
    assert_eq!(moved["generation"], "2", "{moved}");
    assert_eq!(
        root.document()["records"][0]["root"]["path"],
        root.at("second")
    );
    drop(owner);
    let reopened = root.store();
    assert_eq!(
        call(
            &reopened,
            "workspace.project.show",
            json!({"projectRef": project})
        )
        .unwrap()["generation"],
        "2"
    );
}
