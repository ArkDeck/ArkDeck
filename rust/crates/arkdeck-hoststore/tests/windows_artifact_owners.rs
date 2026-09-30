//! The Artifact read, inspect, list and export owners on the Windows host
//! store (TASK-XPA-006, GJ-1's "artifact read/export" hop at the owner): a
//! Job's Artifacts recorded by the macOS Runtime
//! (`rust/tests/fixtures/agent-execution/artifacts/job-73b1…`), laid down
//! byte for byte in a private Artifact root on NTFS, are listed, inspected,
//! read and exported with the recorded bytes and digests (T0), and the
//! Swift daemon's recorded `artifact.inspect` and `artifact.read` frames are
//! reproduced. The export writes only a fresh file in the destination the
//! caller names, re-verifies its digest, and refuses what the macOS owner
//! refuses: an existing file (without an explicit overwrite), a junction in
//! the file's place or as the destination directory, a destination the
//! user does not own, and one inside the Artifact store.
//!
//! The Job owner's proof that the Job exists (`require_job`) is the
//! caller's: these tests pass one that accepts, as the macOS owner tests do;
//! the daemon composes the real one (`arkdeck-agentd`).
#![cfg(windows)]

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    ArtifactExportRequest, ArtifactInspectRequest, ArtifactReadRequest, ArtifactReadStore,
};
use arkdeck_platform::HostDirectory;
use serde_json::{Map, Value, json};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const JOB: &str = "job-73b1cb9a96d12a0ea736a065afdf5abd";
const STANDARD: &str = "ART-5ab8ddce1b835cb95173c1a4b08a7e5d";
const SENSITIVE: &str = "ART-e04cd422be1334393565566a35c7ff20";

fn recorded(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/agent-execution/artifacts")
        .join(JOB)
        .join(name)
}

fn plain(path: PathBuf) -> PathBuf {
    match path.to_str().and_then(|text| text.strip_prefix(r"\\?\")) {
        Some(text) => PathBuf::from(text),
        None => path,
    }
}

/// A fresh scratch directory below the temporary directory: `artifacts`,
/// the owner-only Artifact root, and the directories exports go to.
struct Scratch(PathBuf);
impl Scratch {
    fn new(label: &str) -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = plain(std::env::temp_dir().canonicalize().unwrap())
            .join(format!("{label}-{nonce:032x}"));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn artifacts(&self) -> PathBuf {
        self.0.join("artifacts")
    }
    /// The recorded Job directory as the macOS Runtime published it: its
    /// index owner-only, each payload sealed owner read-only.
    fn with_recorded_job(self) -> Self {
        let root = HostDirectory::open_or_create_private(&self.artifacts()).unwrap();
        let job = root.create_private_child(JOB).unwrap();
        for entry in std::fs::read_dir(recorded("")).unwrap() {
            let name = entry.unwrap().file_name().into_string().unwrap();
            job.create_document(&name, &std::fs::read(recorded(&name)).unwrap())
                .unwrap();
            if name != "index.json" {
                job.seal_document(&name).unwrap();
            }
        }
        self
    }
    fn store(&self) -> ArtifactReadStore {
        ArtifactReadStore::open(&self.artifacts()).unwrap()
    }
    /// Every entry below the Artifact root with its bytes, for a byte-level
    /// comparison before and after.
    fn tree(&self) -> Vec<(PathBuf, Option<Vec<u8>>)> {
        fn walk(path: &Path, into: &mut Vec<(PathBuf, Option<Vec<u8>>)>) {
            let mut entries: Vec<_> = std::fs::read_dir(path)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .collect();
            entries.sort();
            for entry in entries {
                if entry.is_dir() {
                    into.push((entry.clone(), None));
                    walk(&entry, into);
                } else {
                    into.push((entry.clone(), Some(std::fs::read(&entry).unwrap())));
                }
            }
        }
        let mut tree = Vec::new();
        walk(&self.artifacts(), &mut tree);
        tree
    }
    fn destination(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        std::fs::create_dir(&path).unwrap();
        path
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn index() -> Value {
    serde_json::from_slice(&std::fs::read(recorded("index.json")).unwrap()).unwrap()
}
fn owner() -> Value {
    json!({"kind": "job", "id": JOB})
}
fn params(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}
fn accept(_: &str) -> Result<(), arkdeck_contract::WireError> {
    Ok(())
}

#[test]
fn recorded_job_artifacts_list_inspect_and_read_with_their_recorded_bytes() {
    let scratch = Scratch::new("ad-winart").with_recorded_job();
    let before = scratch.tree();
    let store = scratch.store();
    let rows = index()["artifacts"].as_array().unwrap().clone();
    // The snapshot holds every recorded row, verified, newest first then by
    // identity (all three share a creation time).
    let listed = store.list(JOB).unwrap();
    assert_eq!(listed.len(), rows.len());
    let mut expected = rows.clone();
    expected.sort_by(|a, b| a["artifactID"].as_str().cmp(&b["artifactID"].as_str()));
    assert_eq!(listed.page(0, 1000).unwrap().items, expected);
    for row in &rows {
        let id = row["artifactID"].as_str().unwrap();
        assert_eq!(&store.inspect(JOB, id).unwrap(), row);
        let bytes = std::fs::read(recorded(id)).unwrap();
        assert_eq!(sha256_hex(&bytes), row["sha256"]);
        let sensitive = row["privacy"] == "sensitive";
        if sensitive {
            assert_eq!(
                store.read(JOB, id, 0, 4096, false).unwrap_err().kind(),
                ErrorKind::PermissionDenied
            );
        }
        let range = store.read(JOB, id, 0, 4096, true).unwrap();
        assert_eq!(range.bytes, bytes, "{id}");
        assert_eq!(range.sha256, row["sha256"]);
        assert!(range.eof);
        // A second, warm read reuses the sealed payload's proof.
        let tail = store.read(JOB, id, 7, 5, true).unwrap();
        assert_eq!(tail.bytes, bytes[7..12].to_vec());
        assert_eq!(tail.next_offset, 12);
    }
    // The wire answers, as the daemon's resource handler gives them.
    let inspected = store
        .handle_resource(
            "artifact.inspect",
            &params(json!({"owner": owner(), "artifactId": STANDARD})),
            accept,
        )
        .unwrap();
    arkdeck_contract::validate_method_value("artifact.inspect", "result", &inspected).unwrap();
    assert_eq!(inspected["artifactDigest"], rows[0]["sha256"]);
    let read = store
        .handle_resource(
            "artifact.read",
            &params(json!({"owner": owner(), "artifactId": STANDARD})),
            accept,
        )
        .unwrap();
    arkdeck_contract::validate_method_value("artifact.read", "result", &read).unwrap();
    assert_eq!(read["totalByteCount"], 240);
    let denied = store
        .handle_resource(
            "artifact.read",
            &params(json!({"owner": owner(), "artifactId": SENSITIVE})),
            accept,
        )
        .unwrap_err();
    assert_eq!(denied.code, "sensitiveAccessDenied", "{denied:?}");
    // Reads never write the Artifact store.
    assert_eq!(scratch.tree(), before);
    // The list keeps its pages below the Import namespace, as on macOS.
    let page = store
        .handle_list(&params(json!({"owner": owner(), "pageSize": 2})), accept)
        .unwrap();
    arkdeck_contract::validate_method_value("artifact.list", "result", &page).unwrap();
    assert_eq!(page["items"].as_array().unwrap().len(), 2, "{page}");
    assert!(
        scratch
            .artifacts()
            .join(".imports-v1/artifact-snapshots")
            .is_dir()
    );
    // A Job the Job owner does not prove is refused before anything is read.
    let refused = store
        .handle_resource(
            "artifact.read",
            &params(json!({"owner": owner(), "artifactId": STANDARD})),
            |_| {
                Err(arkdeck_contract::WireError {
                    code: "operationUnavailable".into(),
                    message: "The Job owner is not configured".into(),
                    details: None,
                })
            },
        )
        .unwrap_err();
    assert_eq!(refused.code, "operationUnavailable");
}

#[test]
fn a_changed_payload_or_index_is_refused_before_any_byte_is_returned() {
    let scratch = Scratch::new("ad-winart").with_recorded_job();
    let store = scratch.store();
    store.read(JOB, STANDARD, 0, 16, true).unwrap();
    // The recorded payload replaced by different bytes of the same size.
    let job = HostDirectory::open(&scratch.artifacts().join(JOB)).unwrap();
    let mut changed = std::fs::read(recorded(STANDARD)).unwrap();
    changed[0] ^= 1;
    std::fs::rename(
        scratch.artifacts().join(JOB).join(STANDARD),
        scratch.0.join("moved-away"),
    )
    .unwrap();
    job.create_document(STANDARD, &changed).unwrap();
    job.seal_document(STANDARD).unwrap();
    assert_eq!(
        store.read(JOB, STANDARD, 0, 16, true).unwrap_err().kind(),
        ErrorKind::InvalidData
    );
    // Every published row is verified, so another row's read is refused too.
    assert!(store.read(JOB, SENSITIVE, 0, 16, true).is_err());
    assert!(store.list(JOB).is_err());
}

fn export(store: &ArtifactReadStore, destination: &Path, extra: Value) -> Result<Value, String> {
    let mut request = json!({"owner": owner(), "artifactId": STANDARD,
        "destinationDirectory": destination.to_str().unwrap()});
    for (key, value) in extra.as_object().unwrap() {
        request[key] = value.clone();
    }
    store
        .handle_resource("artifact.export", &params(request), accept)
        .map_err(|error| error.code)
}

fn names(directory: &Path) -> Vec<String> {
    let mut names: Vec<_> = std::fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}

fn junction(link: &Path, target: &Path) {
    let made = Command::new("cmd")
        .args(["/C", "mklink", "/J"])
        .arg(link)
        .arg(target)
        .stdout(Stdio::null())
        .status()
        .unwrap();
    assert!(made.success());
}

#[test]
fn export_publishes_one_verified_file_and_refuses_what_macos_refuses() {
    let scratch = Scratch::new("ad-winart").with_recorded_job();
    let before = scratch.tree();
    let store = scratch.store();
    // A fresh directory the user owns; like a macOS user directory with
    // public mode bits, its inherited DACL may grant others access.
    let destination = scratch.destination("exports");
    let receipt = export(&store, &destination, json!({})).unwrap();
    arkdeck_contract::validate_method_value("artifact.export", "result", &receipt).unwrap();
    let file = format!("{STANDARD}-tool-facts.json");
    let bytes = std::fs::read(recorded(STANDARD)).unwrap();
    assert_eq!(
        receipt,
        json!({"schemaVersion": "arkdeck.artifact-export/1", "owner": owner(),
            "artifactId": STANDARD, "artifactDigest": sha256_hex(&bytes), "byteCount": 240,
            "privacy": "standard", "exportedPath": destination.join(&file).to_str().unwrap(),
            "overwritten": false})
    );
    assert_eq!(std::fs::read(destination.join(&file)).unwrap(), bytes);
    assert_eq!(names(&destination), std::slice::from_ref(&file));
    // The exported file, read through no link, as the export parent sees it.
    let parent = HostDirectory::open_export_parent(&destination).unwrap();
    let exported = parent.file_identity(&file).unwrap();
    assert_eq!(exported.size, 240);

    // An existing file is never replaced without an explicit overwrite.
    assert_eq!(
        export(&store, &destination, json!({})).unwrap_err(),
        "resourceConflict"
    );
    assert_eq!(std::fs::read(destination.join(&file)).unwrap(), bytes);
    // With one, the same owner-held regular file is replaced by the verified
    // bytes.
    let overwritten = export(&store, &destination, json!({"overwrite": true})).unwrap();
    assert_eq!(overwritten["overwritten"], true);
    assert_eq!(names(&destination), std::slice::from_ref(&file));

    // A junction in the file's place is not followed, even with overwrite.
    let linked = scratch.destination("linked");
    let target = scratch.destination("junction-target");
    junction(&linked.join(&file), &target);
    for extra in [json!({}), json!({"overwrite": true})] {
        assert_eq!(
            export(&store, &linked, extra).unwrap_err(),
            "resourceConflict"
        );
    }
    assert!(names(&target).is_empty(), "nothing written through it");
    std::fs::remove_dir(linked.join(&file)).unwrap();

    // A junction as the destination directory is not its physical path.
    let alias = scratch.0.join("alias");
    junction(&alias, &target);
    assert_eq!(
        export(&store, &alias, json!({})).unwrap_err(),
        "invalidInput"
    );
    assert!(names(&target).is_empty());
    std::fs::remove_dir(&alias).unwrap();

    // Another spelling of the destination (case) is not its physical path.
    let upper = PathBuf::from(destination.to_str().unwrap().to_uppercase());
    if upper != destination {
        assert_eq!(
            export(&store, &upper, json!({"overwrite": true})).unwrap_err(),
            "invalidInput"
        );
    }

    // Inside the Artifact store: refused before any staging.
    assert_eq!(
        export(&store, &scratch.artifacts().join(JOB), json!({})).unwrap_err(),
        "invalidInput"
    );
    // Not a local drive's absolute path.
    for path in [r"relative\exports", r"\\localhost\c$\exports", r"C:exports"] {
        let request = json!({"owner": owner(), "artifactId": STANDARD,
            "destinationDirectory": path});
        assert_eq!(
            store
                .handle_resource("artifact.export", &params(request), accept)
                .unwrap_err()
                .code,
            "invalidInput",
            "{path}"
        );
    }
    // A destination directory the user does not own (the macOS owner refuses
    // a parent another uid owns): the Windows directory, which
    // TrustedInstaller owns and the user may not add to. (A directory the
    // user may write but does not own cannot be made without elevation; the
    // owner rule itself is `owned(.., ExportParent)`, shared with macOS.)
    let windows = PathBuf::from(std::env::var_os("SystemRoot").unwrap());
    assert_eq!(
        export(&store, &windows, json!({})).unwrap_err(),
        "invalidInput"
    );
    assert!(!windows.join(&file).exists());

    // A sensitive Artifact needs the explicit opt-in.
    let request = json!({"owner": owner(), "artifactId": SENSITIVE,
        "destinationDirectory": destination.to_str().unwrap()});
    assert_eq!(
        store
            .handle_resource("artifact.export", &params(request.clone()), accept)
            .unwrap_err()
            .code,
        "sensitiveAccessDenied"
    );
    let mut allowed = request;
    allowed["allowSensitive"] = json!(true);
    let receipt = store
        .handle_resource("artifact.export", &params(allowed), accept)
        .unwrap();
    assert_eq!(receipt["privacy"], "sensitive");
    assert_eq!(
        std::fs::read(destination.join(format!("{SENSITIVE}-device-facts.json"))).unwrap(),
        std::fs::read(recorded(SENSITIVE)).unwrap()
    );
    // The export never wrote the Artifact store.
    assert_eq!(scratch.tree(), before);
    // The request's own parsing: a Windows path stays a Windows path.
    let request = ArtifactExportRequest::from_params(&params(json!({"owner": owner(),
        "artifactId": STANDARD, "destinationDirectory": r"c:\Users\..\Temp\.\x"})))
    .unwrap();
    assert_eq!(request.reference().job_id(), JOB);
}

fn swift_artifact_corpus(method: &str) -> Vec<Value> {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .unwrap();
    std::fs::read_to_string(repo.join(format!(
        "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/{method}.jsonl"
    )))
    .unwrap()
    .lines()
    .map(|line| arkdeck_contract::strict_json(line.as_bytes()).unwrap())
    .collect()
}

/// One published (or missing) Artifact installed as the macOS Runtime
/// publishes it.
fn install(scratch: &Scratch, metadata: &Value, bytes: &[u8]) {
    let published = metadata["status"].get("published").is_some();
    let root = HostDirectory::open_or_create_private(&scratch.artifacts()).unwrap();
    let job = root
        .create_private_child(metadata["jobID"].as_str().unwrap())
        .unwrap();
    if published {
        assert_eq!(metadata["sha256"], sha256_hex(bytes));
        let id = metadata["artifactID"].as_str().unwrap();
        job.create_document(id, bytes).unwrap();
        job.seal_document(id).unwrap();
    }
    job.create_document(
        "index.json",
        &serde_json::to_vec(&json!({"schemaVersion":"1.0.0","artifacts":[metadata]})).unwrap(),
    )
    .unwrap();
}

fn metadata_from_inspect_projection(value: &Value) -> Value {
    let mut metadata = json!({"artifactID":value["artifactId"],"jobID":value["owner"]["id"],"sessionID":"fixture-session","stepID":"fixture-step",
        "name":value["name"],"mediaType":value["mediaType"],"sha256":value["artifactDigest"],"createdAtUTC":value["createdAtUtc"],
        "providerID":value["providerId"],"sourceOperation":value["sourceOperation"],"privacy":value["privacy"],"byteCount":value["byteCount"],
        "bindingSnapshot":{"targetID":value["binding"]["targetId"],"bindingRevision":value["binding"]["bindingRevision"],"stableIdentitySHA256":value["binding"]["stableIdentitySha256"]},
        "retention":{"retentionClass":value["retention"]["class"],"pinned":value["retention"]["pinned"],"deadlineUTC":value["retention"]["deadlineUtc"]},
        "status":{"published":{}},"redactionApplied":value["redactionApplied"]});
    if value["status"] == "missing" {
        metadata["sha256"] = json!("");
        metadata["status"] = json!({"missing":{"reason":"fixture product unavailable"}});
    }
    if value["observationWindow"].is_object() {
        metadata["observationWindow"] = json!({
            "startUTC":value["observationWindow"]["startUtc"],
            "endUTC":value["observationWindow"]["endUtc"]});
    }
    metadata
}

#[test]
fn the_swift_daemon_s_recorded_inspect_and_read_frames_are_reproduced() {
    let mut consumed = 0;
    for row in swift_artifact_corpus("artifact.inspect") {
        if row["ok"] != true || row["params"]["owner"]["kind"] != "job" {
            continue;
        }
        let bytes: &[u8] = if row["result"]["status"] == "missing" {
            b""
        } else {
            [
                b"fixture-content".as_slice(),
                b"native fixture bytes\n".as_slice(),
            ]
            .into_iter()
            .find(|bytes| row["result"]["artifactDigest"] == sha256_hex(bytes))
            .expect("a native inspect producer's complete fixture bytes are required")
        };
        let scratch = Scratch::new("ad-winart-inspect");
        install(
            &scratch,
            &metadata_from_inspect_projection(&row["result"]),
            bytes,
        );
        let request =
            ArtifactInspectRequest::from_params(row["params"].as_object().unwrap()).unwrap();
        assert_eq!(
            scratch.store().inspect_wire(&request).unwrap(),
            row["result"]
        );
        consumed += 1;
    }
    for row in swift_artifact_corpus("artifact.read") {
        if row["ok"] != true || row["params"]["owner"]["kind"] != "job" {
            continue;
        }
        let sensitive = row["params"]["owner"]["id"] != "job-window-wire";
        let bytes: &[u8] = if sensitive {
            b"private fixture content"
        } else {
            b"fixture-content"
        };
        let digest = sha256_hex(bytes);
        let metadata = json!({"artifactID": row["result"]["artifactId"],
            "jobID": row["params"]["owner"]["id"], "sessionID": "SESSION-1", "stepID": "step",
            "name": "private", "mediaType": "application/octet-stream", "sha256": digest,
            "createdAtUTC": "2026-09-11T00:00:00.000Z", "providerID": "fixture",
            "sourceOperation": "fixture.read",
            "privacy": if sensitive { "sensitive" } else { "standard" },
            "byteCount": bytes.len(), "bindingSnapshot": {"targetID": "fixture-target"},
            "retention": {"retentionClass": "default", "pinned": false},
            "status": {"published": {}}, "redactionApplied": false});
        let scratch = Scratch::new("ad-winart-read");
        install(&scratch, &metadata, bytes);
        let request = ArtifactReadRequest::from_params(row["params"].as_object().unwrap()).unwrap();
        assert_eq!(scratch.store().read_wire(&request).unwrap(), row["result"]);
        consumed += 1;
    }
    assert!(consumed > 1, "the recorded Swift frames were consumed");
}
