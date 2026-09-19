//! What the debug-hap oracle replays share: the fixed root `HDCOracleFake`'s
//! driver names and the lock every user of it takes, the root rebuilt as the
//! Swift oracle found it before its first request, a dispatcher that fails
//! the replay on any dispatch, an imported package, and the bytes of every
//! file below a directory.
use super::chmod;
use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk, sha256_hex};
use arkdeck_hoststore::{ArtifactReadStore, ImportBinding, ImportUploadStore};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};

pub const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";

/// Planning and admission dispatch nothing, and neither does a refused run;
/// a call here fails the replay.
pub struct NoDispatch;

impl HdcDispatch for NoDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        panic!(
            "a HAP plan, admission or refused run dispatched {:?}",
            plan.arguments
        )
    }
}

/// Serializes every user of the fixed root, Swift producers included.
pub fn exclusive() -> File {
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

/// The root as `HDCOracleFake.install` left it, with the Target document the
/// Swift oracle's adoption wrote, the packages it published before any
/// request, and the empty Job (`store`), Sessions and Session owner roots.
pub fn rebuild(fixture: &Path) -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        root.clone(),
        root.join("targets-state"),
        root.join("artifacts"),
        root.join("store"),
        root.join("Sessions"),
        root.join("session-owner"),
    ] {
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    fs::copy(fixture.join("hdc"), root.join("hdc")).unwrap();
    chmod(&root.join("hdc"), 0o700);
    fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
    fs::write(root.join("hdc-invocations.log"), b"").unwrap();
    fs::copy(
        fixture.join("targets-state/targets.json"),
        root.join("targets-state/targets.json"),
    )
    .unwrap();
    // Owner-only, as the Target owner requires and Swift wrote it; a checkout
    // leaves the fixture group-readable.
    chmod(&root.join("targets-state/targets.json"), 0o600);
    // The Artifacts the oracle published before any request, as a Job
    // publishes them: each payload sealed, its index owner-only.
    for input in fs::read_dir(fixture.join("artifacts"))
        .into_iter()
        .flatten()
    {
        let input = input.unwrap().path();
        let name = input.file_name().unwrap().to_owned();
        if !name.to_string_lossy().starts_with("job-input-") {
            continue;
        }
        let destination = root.join("artifacts").join(&name);
        fs::create_dir(&destination).unwrap();
        chmod(&destination, 0o700);
        for file in fs::read_dir(&input).unwrap() {
            let file = file.unwrap().path();
            let file_name = file.file_name().unwrap();
            fs::copy(&file, destination.join(file_name)).unwrap();
            chmod(
                &destination.join(file_name),
                if file_name == "index.json" {
                    0o600
                } else {
                    0o400
                },
            );
        }
    }
    root
}

/// A package imported (`begin`, one `append`, `commit`) as bound to one
/// Target binding: the commit's answer, whose receipt names its lease. The
/// bytes are a deliberate structural fixture, never a signed application or
/// hardware evidence.
pub fn import_package(
    imports: &ImportUploadStore,
    artifacts: &ArtifactReadStore,
    name: &str,
    target_id: &str,
    revision: u64,
    identity: &str,
    now: &str,
) -> Value {
    let binding = |intent: &ImportIntent| -> Result<ImportBinding, WireError> {
        Ok(ImportBinding {
            target_id: intent.target_id.clone(),
            binding_revision: Some(revision),
            stable_identity_sha256: Some(identity.to_owned()),
        })
    };
    let bytes = format!("PK\u{3}\u{4}isolated-{name}").into_bytes();
    let begin = imports
        .handle_resource(
            "artifact.import.begin",
            json!({"schemaVersion": "arkdeck.import-intent/1",
                "importRequestId": format!("hap-import-{name}"), "kind": "hap",
                "targetId": target_id, "bindingRevision": revision.to_string(),
                "deviceProfile": null, "name": format!("{name}.hap"),
                "byteCount": bytes.len().to_string(), "sha256": sha256_hex(&bytes)})
            .as_object()
            .unwrap(),
            now,
            false,
            binding,
        )
        .unwrap();
    let id = begin["importId"].as_str().unwrap();
    imports
        .handle_resource(
            "artifact.import.append",
            json!({"importId": id, "generation": "1", "offset": "0",
                "byteCount": bytes.len().to_string(), "sha256": sha256_hex(&bytes),
                "base64": encode_import_chunk(&bytes).unwrap()})
            .as_object()
            .unwrap(),
            now,
            false,
            binding,
        )
        .unwrap();
    imports
        .commit(
            json!({"importId": id, "generation": "1"})
                .as_object()
                .unwrap(),
            now,
            false,
            artifacts,
            1024 * 1024,
            binding,
        )
        .unwrap()
}

/// Every file below `root`, by its path relative to `root`, with its bytes.
pub fn tree_bytes(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    fn visit(root: &Path, path: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
        for entry in fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                visit(root, &path, out);
            } else {
                out.insert(
                    path.strip_prefix(root).unwrap().to_owned(),
                    fs::read(path).unwrap(),
                );
            }
        }
    }
    let mut out = BTreeMap::new();
    visit(root, root, &mut out);
    out
}

/// The fake driver's call log, which a replay that dispatches nothing leaves
/// empty.
pub fn invocations(root: &Path) -> Vec<u8> {
    fs::read(root.join("hdc-invocations.log")).unwrap()
}
