//! What the debug-hap oracle replays share: the fixed root `HDCOracleFake`'s
//! driver names and the lock every user of it takes, the root rebuilt as the
//! Swift oracle found it before its first request, a dispatcher that fails
//! the replay on any dispatch, an imported package, and the bytes of every
//! file below a directory.
//!
//! The fake's driver is a POSIX shell script at a fixed macOS root, so on
//! Windows only the replays that dispatch nothing (planning and admission)
//! run: the same layout below the temporary directory, owner-only as the
//! store makes it, with each published payload sealed by the store.
#[cfg(unix)]
use super::chmod;
use arkdeck_contract::{ImportIntent, WireError, encode_import_chunk, sha256_hex};
use arkdeck_hoststore::{ArtifactReadStore, ImportBinding, ImportUploadStore};
use arkdeck_provider_hdc::{DispatchFailure, HdcDispatch, ProcessPlan, Receipt};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};

#[cfg(unix)]
pub const ROOT: &str = "/private/tmp/arkdeck-hdc-oracle";
#[cfg(unix)]
const LOCK: &str = "/private/tmp/arkdeck-hdc-oracle.lock";

/// The oracle's root: the fake's fixed one on macOS; on Windows the same
/// name below the temporary directory.
fn root() -> PathBuf {
    #[cfg(unix)]
    let root = PathBuf::from(ROOT);
    #[cfg(windows)]
    let root = super::fixture_fs::temporary_root().join("arkdeck-hdc-oracle");
    root
}

/// A directory `rebuild` creates: owner-only (0700 on macOS).
pub fn private_dir(path: &Path) {
    #[cfg(unix)]
    {
        fs::create_dir(path).unwrap();
        chmod(path, 0o700);
    }
    #[cfg(windows)]
    super::fixture_fs::private_dir(path);
}

/// `source` copied into `directory` as `name`, owner read/write only (0600
/// on macOS; on Windows its owner-only directory's DACL).
fn owner_only_copy(source: &Path, directory: &Path, name: &std::ffi::OsStr) {
    fs::copy(source, directory.join(name)).unwrap();
    #[cfg(unix)]
    chmod(&directory.join(name), 0o600);
}

/// `source` published into `directory` as `name` and sealed: 0400 on
/// macOS; on Windows created and sealed by the store itself.
fn sealed_copy(source: &Path, directory: &Path, name: &std::ffi::OsStr) {
    #[cfg(unix)]
    {
        fs::copy(source, directory.join(name)).unwrap();
        chmod(&directory.join(name), 0o400);
    }
    #[cfg(windows)]
    {
        let directory = arkdeck_platform::HostDirectory::open(directory).unwrap();
        let name = name.to_str().unwrap();
        directory
            .create_document(name, &fs::read(source).unwrap())
            .unwrap();
        directory.seal_document(name).unwrap();
    }
}

/// Planning and admission dispatch nothing; a call here fails the replay.
pub struct NoDispatch;

impl HdcDispatch for NoDispatch {
    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        panic!("a HAP plan or admission dispatched {:?}", plan.arguments)
    }
}

/// The fixed root's lock, held for one test. On Windows the root this test
/// rebuilt is removed when the test lets go of it, before the lock is
/// released, so nothing is left in the temporary directory; the lock file
/// itself stays, as the cross-process lock. On macOS the root stays where
/// the Swift oracle's producers expect it.
pub struct Exclusive(#[allow(dead_code)] File);

#[cfg(windows)]
impl Drop for Exclusive {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(root());
    }
}

/// Serializes every user of the fixed root, Swift producers included.
pub fn exclusive() -> Exclusive {
    Exclusive(lock_file())
}

fn lock_file() -> File {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open({
            #[cfg(unix)]
            let lock = PathBuf::from(LOCK);
            #[cfg(windows)]
            let lock = super::fixture_fs::temporary_root().join("arkdeck-hdc-oracle.lock");
            lock
        })
        .unwrap();
    lock.lock().unwrap();
    lock
}

/// The root as `HDCOracleFake.install` left it, with the Target document the
/// Swift oracle's adoption wrote, the packages it published before any
/// request, and the empty Job (`store`), Sessions and Session owner roots.
pub fn rebuild(fixture: &Path) -> PathBuf {
    let root = root();
    let _ = fs::remove_dir_all(&root);
    for directory in [
        root.clone(),
        root.join("targets-state"),
        root.join("artifacts"),
        root.join("store"),
        root.join("Sessions"),
        root.join("session-owner"),
    ] {
        private_dir(&directory);
    }
    fs::copy(fixture.join("hdc"), root.join("hdc")).unwrap();
    #[cfg(unix)]
    chmod(&root.join("hdc"), 0o700);
    fs::copy(fixture.join("hdc-answers.sh"), root.join("hdc-answers.sh")).unwrap();
    fs::write(root.join("hdc-invocations.log"), b"").unwrap();
    // Owner-only, as the Target owner requires and Swift wrote it; a checkout
    // leaves the fixture group-readable.
    owner_only_copy(
        &fixture.join("targets-state").join("targets.json"),
        &root.join("targets-state"),
        "targets.json".as_ref(),
    );
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
        private_dir(&destination);
        for file in fs::read_dir(&input).unwrap() {
            let file = file.unwrap().path();
            let file_name = file.file_name().unwrap();
            if file_name == "index.json" {
                owner_only_copy(&file, &destination, file_name);
            } else {
                sealed_copy(&file, &destination, file_name);
            }
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

/// The values a replay derives from its packages' host paths, read as the
/// Swift oracle's. A HAP plan's digest covers each send's arguments, which
/// name the package's host path: on macOS the replay's root is the oracle's,
/// so nothing is relabelled and every value must be Swift's as it is; on
/// Windows the root is spelled otherwise, so its plan digest and whatever is
/// derived from it (the Runtime capability named by the plan) differ, and
/// only those. Each Windows value maps to exactly one Swift value and back,
/// and is replaced only where it is a whole JSON string, in one pass, so a
/// replay that relabels them still proves every other byte is Swift's.
/// `hap_plan_digest`'s unit test proves the digests themselves are Swift's
/// over the oracle's paths, and `capability_write.rs` the capability store's
/// hashes over Swift's inputs.
#[derive(Default)]
pub struct HostLabels {
    swift: BTreeMap<String, String>,
    host: BTreeMap<String, String>,
    portable: bool,
}

/// The capability store members derived from a plan digest and the Runtime
/// capability it names: the IDs, the fingerprints of a use's query and scope,
/// and the hash chain of its receipt and outcomes.
pub const DERIVED: [&str; 7] = [
    "capabilityID",
    "materializedPlanDigest",
    "queryFingerprintSHA256",
    "authorizationScopeFingerprintSHA256",
    "receiptSHA256",
    "recordSHA256",
    "previousRecordSHA256",
];

impl HostLabels {
    /// A separately versioned Rust oracle can be recorded on either host.
    /// Historical Swift oracles keep the default macOS exact-byte behavior.
    pub fn portable() -> Self {
        Self {
            portable: true,
            ..Self::default()
        }
    }
    /// Learns every string under one of `keys` in `host` as the one at the
    /// same place in `swift`, walking both documents together (Windows only).
    pub fn learn_keys(&mut self, host: &Value, swift: &Value, keys: &[&str]) {
        match (host, swift) {
            (Value::Object(host), Value::Object(swift)) => {
                for (key, value) in host {
                    let Some(other) = swift.get(key) else {
                        continue;
                    };
                    match (keys.contains(&key.as_str()), value.as_str(), other.as_str()) {
                        (true, Some(value), Some(other)) => self.learn_value(value, other),
                        _ => self.learn_keys(value, other, keys),
                    }
                }
            }
            (Value::Array(host), Value::Array(swift)) => {
                for (value, other) in host.iter().zip(swift) {
                    self.learn_keys(value, other, keys);
                }
            }
            _ => (),
        }
    }

    /// As [`Self::learn_keys`] for `key`, only inside an object under
    /// `parent`, wherever in the documents that is.
    pub fn learn_within(&mut self, host: &Value, swift: &Value, parent: &str, key: &str) {
        match (host, swift) {
            (Value::Object(host), Value::Object(swift)) => {
                for (name, value) in host {
                    let Some(other) = swift.get(name) else {
                        continue;
                    };
                    if name == parent {
                        self.learn_keys(value, other, &[key]);
                    } else {
                        self.learn_within(value, other, parent, key);
                    }
                }
            }
            (Value::Array(host), Value::Array(swift)) => {
                for (value, other) in host.iter().zip(swift) {
                    self.learn_within(value, other, parent, key);
                }
            }
            _ => (),
        }
    }

    /// A value this host derived where Swift's replay derived `swift`: the
    /// same value on macOS; on Windows learned as its label.
    pub fn derived(&mut self, host: &str, swift: &str) {
        if cfg!(windows) || self.portable {
            self.learn_value(host, swift);
        } else {
            assert_eq!(host, swift);
        }
    }

    /// The host value read as `swift` (itself on macOS).
    pub fn host(&self, swift: &str) -> String {
        self.host
            .get(swift)
            .cloned()
            .unwrap_or_else(|| swift.to_owned())
    }

    /// Learns `actual`'s string at `pointer` as `expected`'s at the same
    /// place (Windows only; on macOS nothing is learned).
    pub fn learn(&mut self, actual: &Value, expected: &Value, pointer: &str) {
        if (cfg!(windows) || self.portable)
            && let (Some(host), Some(swift)) = (
                actual.pointer(pointer).and_then(Value::as_str),
                expected.pointer(pointer).and_then(Value::as_str),
            )
        {
            self.learn_value(host, swift);
        }
    }

    /// Learns one host value as one Swift value (Windows only).
    pub fn learn_value(&mut self, host: &str, swift: &str) {
        if cfg!(windows) || self.portable {
            assert_eq!(host.len(), swift.len(), "{host} relabels {swift}");
            if let Some(previous) = self.swift.insert(host.to_owned(), swift.to_owned()) {
                assert_eq!(previous, swift, "{host} reads as two Swift values");
            }
            if let Some(previous) = self.host.insert(swift.to_owned(), host.to_owned()) {
                assert_eq!(previous, host, "{swift} is read from two host values");
            }
        }
    }

    /// `bytes` with every learned host value read as Swift's where it is a
    /// whole quoted string, in one pass (no replacement is read again).
    pub fn swift_bytes(&self, bytes: &[u8]) -> Vec<u8> {
        // A payload that is not text names no label.
        let Ok(text) = String::from_utf8(bytes.to_vec()) else {
            return bytes.to_vec();
        };
        let text = text
            .split('"')
            .map(|segment| self.swift.get(segment).map_or(segment, String::as_str))
            .collect::<Vec<_>>()
            .join("\"");
        // A Runtime capability's ID is also named inside a refusal's words
        // (`lineageBlocked("… capability <ID>-G1 use 1 …")`): each learned ID,
        // long and derived from a plan digest, is read as Swift's there too.
        self.swift
            .iter()
            .filter(|(host, _)| host.starts_with("CAP-"))
            .fold(text, |text, (host, swift)| {
                text.replace(host.as_str(), swift)
            })
            .into_bytes()
    }

    /// `value` with every learned host value read as Swift's.
    pub fn swift(&self, value: &Value) -> Value {
        serde_json::from_slice(&self.swift_bytes(&serde_json::to_vec(value).unwrap())).unwrap()
    }

    /// `value`, a Swift document, with every learned Swift value read as this
    /// host's (whole JSON strings, one pass): what the host would have
    /// written in its place. Unchanged on macOS.
    pub fn host_json(&self, value: &Value) -> Value {
        let text = String::from_utf8(serde_json::to_vec(value).unwrap()).unwrap();
        let text = text
            .split('"')
            .map(|segment| self.host.get(segment).map_or(segment, String::as_str))
            .collect::<Vec<_>>()
            .join("\"");
        serde_json::from_str(&text).unwrap()
    }

    /// How many host values were relabelled.
    pub fn len(&self) -> usize {
        self.swift.len()
    }
}
