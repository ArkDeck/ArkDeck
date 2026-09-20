//! What the replays of the Swift writer oracles share: the fixed root every
//! producer serializes on, the oracles' clock and storage probe, the sources
//! as Swift published them before any run, and the reading of everything a
//! replay leaves — the Job index and files, every Artifact, every file of the
//! Sessions root and the storage owner, and every entry's kind and mode —
//! which must be Swift's byte for byte, once each Job record's volume, device,
//! inode and claim generation are read as labels.
#![allow(dead_code)]

pub mod debug_hap;
pub mod hdc_oracle;
pub mod native_library;

use arkdeck_hoststore::{StorageProbe, StorageSnapshot};
use arkdeck_platform::{HostDirectory, HostSqlite, SqliteValue as Sql};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

const ROOT: &str = "/private/tmp/arkdeck-job-plan-oracle";
const LOCK: &str = "/private/tmp/arkdeck-job-plan-oracle.lock";
const MACHINE_FACTS: [&str; 4] = ["device", "inode", "volumeIdentity", "admissionGeneration"];

pub fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

/// One of the oracle's recorded JSON documents.
pub fn document(fixture: &Path, name: &str) -> Value {
    serde_json::from_slice(&fs::read(fixture.join(name)).unwrap()).unwrap()
}

pub fn chmod(path: &Path, mode: u32) {
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

pub fn fixed_now() -> Option<String> {
    Some("2026-09-14T00:00:00Z".into())
}

pub fn fixed_precise_now() -> Option<String> {
    Some("2026-09-14T00:00:00.000Z".into())
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

/// The oracle's probe: this machine's volume with room for every claim,
/// unless a case reports it full.
pub struct OracleProbe(AtomicBool, u64);

impl OracleProbe {
    pub fn new(provenance: &Value) -> Self {
        Self(
            AtomicBool::new(false),
            provenance["availableBytes"].as_u64().unwrap(),
        )
    }
    pub fn exhaust(&self, full: bool) {
        self.0.store(full, Ordering::SeqCst);
    }
}

impl StorageProbe for OracleProbe {
    fn snapshot(&self, root: &HostDirectory) -> io::Result<StorageSnapshot> {
        Ok(StorageSnapshot {
            volume_identity: root.export_facts()?.volume_identity,
            available_bytes: if self.0.load(Ordering::SeqCst) {
                0
            } else {
                self.1
            },
            read_only: false,
        })
    }
}

/// The given source Jobs as Swift published them before any run, the one a
/// case later removes rebuilt from its mode, and the empty owner and
/// Sessions roots.
pub fn rebuild(fixture: &Path, sources: &[&str], cases: &[Value]) -> PathBuf {
    let root = PathBuf::from(ROOT);
    let _ = fs::remove_dir_all(&root);
    for directory in [
        root.clone(),
        root.join("artifacts"),
        root.join("jobs-state"),
        root.join("Sessions"),
        root.join("session-owner"),
    ] {
        fs::create_dir(&directory).unwrap();
        chmod(&directory, 0o700);
    }
    fs::copy(fixture.join("analyzer"), root.join("analyzer")).unwrap();
    chmod(&root.join("analyzer"), 0o700);
    for job in sources {
        let destination = root.join("artifacts").join(job);
        fs::create_dir(&destination).unwrap();
        chmod(&destination, 0o700);
        for file in fs::read_dir(fixture.join("artifacts").join(job)).unwrap() {
            let file = file.unwrap().path();
            let name = file.file_name().unwrap();
            fs::copy(&file, destination.join(name)).unwrap();
            chmod(
                &destination.join(name),
                if name == "index.json" { 0o600 } else { 0o400 },
            );
        }
    }
    for case in cases {
        let Some(removed) = case["removesSourcePayload"].as_str() else {
            continue;
        };
        let path = root.join("artifacts").join(removed);
        fs::write(
            &path,
            format!(
                "{}\nFault log list:\n******\n",
                case["mode"].as_str().unwrap()
            ),
        )
        .unwrap();
        chmod(&path, 0o400);
    }
    root
}

/// A Job record's publication marker names this machine's volume, device,
/// inode and claim generation; each reads as a fixed label, and a refused
/// marker's blank or zero value stays as it is.
fn machine_independent(bytes: &[u8]) -> Vec<u8> {
    let mut text = String::from_utf8(bytes.to_vec()).unwrap();
    for key in MACHINE_FACTS {
        let needle = format!("\"{key}\"");
        let label = format!("<{key}>");
        let mut out = String::new();
        let mut rest = text.as_str();
        while let Some(at) = rest.find(&needle) {
            let (head, tail) = rest.split_at(at + needle.len());
            out.push_str(head);
            rest = tail;
            let Some(value) = tail
                .trim_start_matches(' ')
                .strip_prefix(':')
                .map(|after| after.trim_start_matches(' '))
                .and_then(|after| after.strip_prefix('"'))
            else {
                continue;
            };
            let Some(end) = value.find('"') else {
                continue;
            };
            out.push_str(&tail[..tail.len() - value.len()]);
            let current = &value[..end];
            out.push_str(if current.is_empty() || current == "0" {
                current
            } else {
                &label
            });
            rest = &value[end..];
        }
        out.push_str(rest);
        text = out;
    }
    text.into_bytes()
}

/// The facts the Swift oracle records of the Job index, each record's
/// digest taken over its machine-independent reading.
pub fn index(path: &Path) -> Value {
    let mut db = HostSqlite::open(&path.join("runtime-jobs.sqlite3"), true, false).unwrap();
    let cell = |value: &Sql| match value {
        Sql::Null => Value::Null,
        Sql::Integer(n) => json!(n),
        Sql::Text(text) => json!(text),
        Sql::Blob(bytes) => json!(arkdeck_contract::sha256_hex(&machine_independent(bytes))),
    };
    let mut query = |sql: &str| db.query(sql, &[], 64 << 20).unwrap();
    let schema: Vec<Value> =
        query("SELECT name, type, tbl_name, sql FROM sqlite_schema ORDER BY name")
            .iter()
            .map(|row| {
                json!({"name": cell(&row[0]), "type": cell(&row[1]), "tableName": cell(&row[2]),
                "sql": cell(&row[3])})
            })
            .collect();
    let rows: Vec<Value> = query(
        "SELECT job_id, idempotency_key, request_hash, state, admission_sequence, created_at_utc, created_at_order_key, updated_at_utc, version, initial_record_json FROM runtime_job ORDER BY admission_sequence",
    )
    .iter()
    .map(|row| {
        json!({"jobId": cell(&row[0]), "idempotencyKey": cell(&row[1]),
            "requestHash": cell(&row[2]), "state": cell(&row[3]),
            "admissionSequence": cell(&row[4]), "createdAtUTC": cell(&row[5]),
            "createdAtOrderKey": cell(&row[6]), "updatedAtUTC": cell(&row[7]),
            "version": cell(&row[8]), "recordSHA256": cell(&row[9])})
    })
    .collect();
    let version = cell(&query("PRAGMA user_version")[0][0]);
    let mode = cell(&query("PRAGMA journal_mode")[0][0]);
    json!({"userVersion": version, "journalMode": mode, "schema": schema, "rows": rows})
}

/// A Job store snapshot the Swift oracle recorded under `prefix` (its
/// `storeSnapshot`: the Job index and every file below the Job directories,
/// each Job record read machine-independently) against the store at `jobs`,
/// which may still be open.
pub fn assert_store(fixture: &Path, prefix: &str, jobs: &Path) {
    assert_eq!(
        index(jobs),
        document(fixture, &format!("{prefix}/index.json")),
        "{prefix}/index.json"
    );
    let (mut actual, mut recorded) = (BTreeMap::new(), BTreeMap::new());
    walk(&jobs.join("jobs"), prefix, &mut actual, &mut Vec::new());
    walk(
        &fixture.join(prefix).join("jobs"),
        prefix,
        &mut recorded,
        &mut Vec::new(),
    );
    assert_eq!(
        actual.keys().collect::<Vec<_>>(),
        recorded.keys().collect::<Vec<_>>(),
        "{prefix}"
    );
    for (path, bytes) in &recorded {
        assert_eq!(
            String::from_utf8_lossy(&actual[path]),
            String::from_utf8_lossy(bytes),
            "{path}"
        );
    }
}

/// Every entry below `base` as `prefix/<relative path>`: each file's bytes
/// (a Job record's read machine-independently) and each entry's kind and mode.
fn walk(
    base: &Path,
    prefix: &str,
    files: &mut BTreeMap<String, Vec<u8>>,
    tree: &mut Vec<(String, &'static str, String)>,
) {
    let mut entries = Vec::new();
    let mut pending = vec![PathBuf::new()];
    while let Some(relative) = pending.pop() {
        for entry in fs::read_dir(base.join(&relative)).unwrap() {
            let entry = entry.unwrap();
            let path = relative.join(entry.file_name());
            if entry.file_type().unwrap().is_dir() {
                pending.push(path.clone());
            }
            entries.push(path);
        }
    }
    entries.sort();
    for relative in entries {
        let path = base.join(&relative);
        let metadata = fs::symlink_metadata(&path).unwrap();
        // A pager snapshot is named and filled by a random revision: the
        // oracle keeps that it exists and its mode, not its name or bytes.
        let snapshot =
            prefix == "agent-executions" && metadata.is_file() && pager_snapshot(&relative);
        let name = if snapshot {
            format!("{prefix}/snapshots/snapshot-<revision>.json")
        } else {
            format!("{prefix}/{}", relative.display())
        };
        let kind = if metadata.is_dir() {
            "directory"
        } else {
            "file"
        };
        tree.push((
            name.clone(),
            kind,
            format!("{:o}", metadata.permissions().mode() & 0o777),
        ));
        if metadata.is_file() && !snapshot {
            let bytes = fs::read(&path).unwrap();
            files.insert(
                name,
                if relative.file_name().unwrap() == "job-record.json" {
                    machine_independent(&bytes)
                } else {
                    bytes
                },
            );
        }
    }
}

/// `snapshots/snapshot-<revision>.json` below the agent execution directory:
/// a page snapshot the owner's pager wrote under a random revision.
fn pager_snapshot(relative: &Path) -> bool {
    relative
        .to_str()
        .and_then(|path| path.strip_prefix("snapshots/snapshot-"))
        .and_then(|name| name.strip_suffix(".json"))
        .is_some_and(|revision| {
            revision.len() == 36
                && revision.bytes().enumerate().all(|(index, byte)| {
                    if [8, 13, 18, 23].contains(&index) {
                        byte == b'-'
                    } else {
                        byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
                    }
                })
        })
}

/// Every Artifact index and payload, and the root's own documents (the
/// cleanup debt ledger), the verification cache aside.
fn artifacts(base: &Path) -> BTreeMap<String, Vec<u8>> {
    let mut files = BTreeMap::new();
    for directory in fs::read_dir(base).unwrap() {
        let directory = directory.unwrap().path();
        let job = directory.file_name().unwrap().to_str().unwrap().to_owned();
        if job.starts_with('.') {
            continue;
        }
        if directory.is_file() {
            files.insert(format!("artifacts/{job}"), fs::read(&directory).unwrap());
            continue;
        }
        for file in fs::read_dir(&directory).unwrap() {
            let file = file.unwrap().path();
            let name = file.file_name().unwrap().to_str().unwrap().to_owned();
            if !name.starts_with('.') {
                files.insert(format!("artifacts/{job}/{name}"), fs::read(&file).unwrap());
            }
        }
    }
    files
}

/// Everything the replay left below `root` against what the Swift oracle
/// recorded: the Job index, every entry's kind and mode, and every file. An
/// agent execution directory beside the Job state is read as well. The Job
/// owner must be closed first.
pub fn assert_leftovers(fixture: &Path, root: &Path) {
    assert_leftovers_at(fixture, root, &root.join("jobs-state"));
}

pub fn assert_leftovers_at(fixture: &Path, root: &Path, jobs: &Path) {
    assert_leftovers_with(fixture, root, jobs, |_, bytes| bytes, |_| ());
}

/// As [`assert_leftovers_at`], against what the oracle recorded as `expected`
/// reads each recorded file (by its fixture path) and `index` reads the
/// recorded index: for the files and rows a later exchange the replay does
/// not make changed, what they held before it.
pub fn assert_leftovers_with(
    fixture: &Path,
    root: &Path,
    jobs: &Path,
    expected: impl Fn(&str, Vec<u8>) -> Vec<u8>,
    index_before: impl Fn(&mut Value),
) {
    let mut recorded_index = document(fixture, "store/index.json");
    index_before(&mut recorded_index);
    assert_eq!(index(jobs), recorded_index);
    let (mut files, mut tree) = (BTreeMap::new(), Vec::new());
    let mut bases = vec![
        (jobs.join("jobs"), "store/jobs"),
        (root.join("Sessions"), "sessions"),
        (root.join("session-owner"), "session-owner"),
    ];
    if jobs.join("capabilities").exists() {
        bases.insert(1, (jobs.join("capabilities"), "store/capabilities"));
    }
    if root.join("agent-executions").exists() {
        bases.push((root.join("agent-executions"), "agent-executions"));
    }
    for (base, prefix) in bases {
        walk(&base, prefix, &mut files, &mut tree);
    }
    files.extend(artifacts(&root.join("artifacts")));
    let actual: Vec<Value> = tree
        .iter()
        .map(|(path, kind, mode)| json!({"path": path, "kind": kind, "mode": mode}))
        .collect();
    assert_eq!(
        actual,
        document(fixture, "tree.json").as_array().unwrap().clone()
    );
    let mut recorded = BTreeMap::new();
    for (path, _) in document(fixture, "provenance.json")["files"]
        .as_object()
        .unwrap()
    {
        if [
            "store/jobs/",
            "store/capabilities/",
            "sessions/",
            "session-owner/",
            "artifacts/",
            "agent-executions/",
        ]
        .iter()
        .any(|prefix| path.starts_with(prefix))
        {
            recorded.insert(
                path.clone(),
                expected(path, fs::read(fixture.join(path)).unwrap()),
            );
        }
    }
    assert_eq!(
        files.keys().collect::<Vec<_>>(),
        recorded.keys().collect::<Vec<_>>()
    );
    for (path, bytes) in &recorded {
        assert_eq!(
            String::from_utf8_lossy(&files[path]),
            String::from_utf8_lossy(bytes),
            "{path}"
        );
    }
}
