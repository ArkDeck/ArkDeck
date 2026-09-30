//! The Session publication writer and the Session storage owner on Windows
//! (TASK-XPA-005/014), against every recorded Swift Session publication:
//! each recorded Job store with a Sessions tree beside it
//! (`rust/tests/fixtures/**/store` and its `sessions`), its Jobs published
//! again, in the order Swift's catalog registered them, into a Sessions root
//! and a storage owner of their own on NTFS.
//!
//! Each Job is given to the writer as it stood before Swift published it: its
//! recorded record without the publication marker, and its recorded Journal
//! without the `finalized` record the publication appends. A Job whose
//! recorded marker holds no receipt was refused storage, and is published
//! over a volume reported full. Then every Session file, the catalog, the
//! storage owner's directory, each Job's Manifest proposal and Journal, and
//! each marker are Swift's byte for byte, but for two things:
//!
//! * the marker's host values (the root's path, device, inode and volume,
//!   the claim's admission generation), read as the oracle's labels;
//! * the Manifest's `platformProfile`, which names the platform the Session
//!   was published on (`PLATFORM-WINDOWS@0.2.0` here, Swift's
//!   `PLATFORM-MACOS@0.2.0`), and so the Manifest's digest wherever the
//!   Journal, the audit record and the marker name it, the Manifest's byte
//!   count and the Journal seal.
//!
//! The Sessions are then read back through a storage owner opened again, as
//! after a restart: `session.list` a page at a time through the snapshot
//! pager, each cursor read by another owner opened after it was handed out,
//! and `session.show` of every Session.
use super::*;
use crate::test_private::create_private_directory;
use std::path::PathBuf;

const MACOS: &str = "PLATFORM-MACOS@0.2.0";

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures")
}

/// A fresh directory below the temporary directory, in the canonical
/// spelling the storage owner compares; removed afterwards.
struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let path = crate::session_owner::canonical_path(&std::env::temp_dir())
            .unwrap()
            .join(format!("ad-winsessions-{nonce:032x}"));
        create_private_directory(&path);
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The volume the Sessions root is on, with room for every claim, or none.
struct Volume {
    available: u64,
}
impl StorageProbe for Volume {
    fn snapshot(&self, root: &HostDirectory) -> io::Result<StorageSnapshot> {
        Ok(StorageSnapshot {
            volume_identity: root.export_facts()?.volume_identity,
            available_bytes: self.available,
            read_only: false,
        })
    }
}

/// A recorded store with the Sessions tree Swift published beside it.
struct Corpus {
    name: String,
    store: PathBuf,
    sessions: PathBuf,
    owner: Option<PathBuf>,
}

/// Every recorded store (`<corpus>/store/jobs`) with a Sessions tree beside
/// it (`<corpus>/sessions` or `Sessions`, holding a catalog).
fn corpora() -> Vec<Corpus> {
    fn walk(directory: &Path, depth: usize, found: &mut Vec<Corpus>) {
        let mut entries: Vec<_> = std::fs::read_dir(directory)
            .unwrap()
            .map(|entry| entry.unwrap())
            .filter(|entry| entry.file_type().unwrap().is_dir())
            .map(|entry| entry.file_name().into_string().unwrap())
            .collect();
        entries.sort();
        let sessions = entries
            .iter()
            .find(|name| name.eq_ignore_ascii_case("sessions"))
            .map(|name| directory.join(name))
            .filter(|path| path.join(".arkdeck-retention-catalog.json").is_file());
        if let Some(sessions) = sessions
            && directory.join("store/jobs").is_dir()
        {
            found.push(Corpus {
                name: directory
                    .strip_prefix(fixtures())
                    .unwrap()
                    .to_string_lossy()
                    .replace('\\', "/"),
                store: directory.join("store"),
                sessions,
                owner: Some(directory.join("session-owner")).filter(|path| path.is_dir()),
            });
        }
        if depth > 0 {
            for name in entries {
                walk(&directory.join(name), depth - 1, found);
            }
        }
    }
    let mut found = Vec::new();
    walk(&fixtures(), 4, &mut found);
    found
}

/// Every entry below `path`, by its relative name, with the bytes of each
/// file.
fn tree(path: &Path) -> BTreeMap<String, Option<Vec<u8>>> {
    fn walk(root: &Path, directory: &Path, tree: &mut BTreeMap<String, Option<Vec<u8>>>) {
        for entry in std::fs::read_dir(directory).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            let name = path
                .strip_prefix(root)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            if entry.file_type().unwrap().is_dir() {
                tree.insert(name, None);
                walk(root, &path, tree);
            } else {
                tree.insert(name, Some(std::fs::read(&path).unwrap()));
            }
        }
    }
    let mut tree = BTreeMap::new();
    walk(path, path, &mut tree);
    tree
}

/// A marker with its host values read as the oracle's labels.
fn labelled(mut marker: Value) -> Value {
    for claim in marker["claims"].as_array_mut().into_iter().flatten() {
        for key in ["admissionGeneration", "volumeIdentity"] {
            claim[key] = json!(format!("<{key}>"));
        }
    }
    for (name, keys) in [
        ("root", &["path", "device", "inode", "volumeIdentity"][..]),
        ("sessionRootIdentity", &["device", "inode"][..]),
    ] {
        if let Some(nested) = marker.get_mut(name).and_then(Value::as_object_mut) {
            for key in keys {
                nested.insert((*key).into(), json!(format!("<{key}>")));
            }
        }
    }
    marker
}

/// `bytes` with every recorded Manifest digest replaced by the digest of
/// the Manifest published here.
fn substituted(bytes: &[u8], digests: &BTreeMap<String, String>) -> Vec<u8> {
    // A lock's marker byte is no text, and names no digest.
    let Ok(mut text) = String::from_utf8(bytes.to_vec()) else {
        return bytes.to_vec();
    };
    for (recorded, published) in digests {
        text = text.replace(recorded, published);
    }
    text.into_bytes()
}

/// The recorded Journal without the `finalized` record a publication
/// appends; every other record keeps its bytes.
fn before_publication(journal: &[u8]) -> Vec<u8> {
    let mut kept = Vec::new();
    for line in journal.split_inclusive(|byte| *byte == b'\n') {
        let event: Value = serde_json::from_slice(line).unwrap();
        if event["kind"] != "finalized" {
            kept.extend_from_slice(line);
        }
    }
    kept
}

struct Recorded {
    id: String,
    record: Value,
    marker: Value,
}

impl Recorded {
    /// Refused storage: stopped before any claim, and not by a refusal of
    /// the Job's facts.
    fn refused_storage(&self) -> bool {
        self.marker.get("receipt").is_none()
            && self.marker.get("failure").is_none()
            && self.marker["claims"].as_array().is_some_and(Vec::is_empty)
    }

    fn receipt_generation(&self) -> Option<u64> {
        self.marker["receipt"]["catalogGeneration"]
            .as_str()
            .map(|text| text.parse().unwrap())
    }
}

#[test]
fn recorded_swift_sessions_are_published_again_byte_for_byte() {
    let corpora = corpora();
    assert!(corpora.len() >= 30, "{}", corpora.len());
    let (mut published, mut refused, mut resealed) = (0, 0, 0);
    for corpus in &corpora {
        let (p, r) = publish_corpus(corpus, &mut resealed);
        published += p;
        refused += r;
    }
    println!(
        "{} corpora: {published} Sessions published byte for byte, {refused} Jobs refused; {resealed} recorded records were persisted again after their publication",
        corpora.len()
    );
    assert!(published >= 50, "{published}");
}

/// Publishes every recorded Job of `corpus` again; answers how many were
/// published and how many refused storage.
fn publish_corpus(corpus: &Corpus, resealed: &mut usize) -> (usize, usize) {
    let name = &corpus.name;
    let mut jobs = Vec::new();
    let mut ids: Vec<_> = std::fs::read_dir(corpus.store.join("jobs"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    ids.sort();
    for id in ids {
        let path = corpus.store.join("jobs").join(&id).join("job-record.json");
        let Ok(bytes) = std::fs::read(&path) else {
            continue;
        };
        let mut record: Value = serde_json::from_slice(&bytes).unwrap();
        if let Some(marker) = record
            .as_object_mut()
            .unwrap()
            .remove("sessionPublicationRecord")
        {
            jobs.push(Recorded { id, record, marker });
        }
    }
    // Refused ones first (they register nothing), then in the order
    // Swift's catalog registered them.
    jobs.sort_by_key(|job| (job.receipt_generation(), job.id.clone()));

    let scratch = Scratch::new();
    let (owner, sessions_root) = (scratch.0.join("session-owner"), scratch.0.join("Sessions"));
    create_private_directory(&owner);
    create_private_directory(&sessions_root);
    create_private_directory(&scratch.0.join("jobs"));
    let sessions = SessionStore::open(&owner, &sessions_root).unwrap();
    let claims = StorageClaims::default();
    let (ample, full) = (
        Volume {
            available: u64::MAX / 4,
        },
        Volume { available: 0 },
    );
    let mut digests = BTreeMap::new();
    let mut expected_jobs = Vec::new();
    let (mut published, mut refused) = (0, 0);
    for job in &jobs {
        let recorded = corpus.store.join("jobs").join(&job.id);
        let directory = scratch.0.join("jobs").join(&job.id);
        create_private_directory(&directory);
        let journal = std::fs::read(recorded.join("journal.jsonl")).unwrap();
        HostDirectory::open(&directory)
            .unwrap()
            .create_document("journal.jsonl", &before_publication(&journal))
            .unwrap();
        let record = JobRecord::decode(&serde_json::to_vec(&job.record).unwrap())
            .unwrap_or_else(|error| panic!("{name} {}: {}", job.id, error.message));
        let receipt = job.marker.get("receipt");
        let now = receipt
            .and_then(|receipt| receipt["publishedAtUTC"].as_str())
            .or(job.record["finishedAtUTC"].as_str())
            .unwrap_or("2026-09-14T00:00:00Z")
            .to_owned();
        let publisher = SessionPublisher {
            sessions: &sessions,
            claims: &claims,
            probe: if job.refused_storage() { &full } else { &ample },
        };
        // A publication Swift found its Session already in place: the
        // oracle put an entry there first, and took it away again.
        let collision = job.marker["failure"]["detail"]
            .as_str()
            .is_some_and(|detail| detail.contains("Session already exists"))
            .then(|| {
                let (year, month) = utc_month(record.created()).unwrap();
                let path = sessions_root
                    .join(year)
                    .join(month)
                    .join(format!("session-{}", job.id));
                std::fs::create_dir_all(&path).unwrap();
                path
            });
        let mut writer = JournalWriter::open(&directory, false).unwrap();
        let marker = publisher.publish(&record, &mut writer, &directory, &now);
        drop(writer);
        if let Some(path) = collision {
            std::fs::remove_dir(path).unwrap();
        }

        let mut expected = job.marker.clone();
        let mut proposal = None;
        // The checkpoint seals the record the writer was given. A recorded
        // record Swift persisted again after its publication (a later
        // reconciliation) is not that record, however the marker is taken
        // off; its seal is then the one of the record given here.
        let given = sha256_hex(&record.durable_bytes().unwrap());
        if let Some(seal) = expected.get_mut("checkpointSeal")
            && seal["sha256"] != json!(given)
        {
            seal["sha256"] = json!(given);
            *resealed += 1;
        }
        let mut expected_journal = journal.clone();
        // The Manifest Swift proposed beside the Job, published or not, and
        // the one proposed here: the same but for the platform it names.
        if let Ok(recorded_proposal) = std::fs::read(recorded.join(PROPOSAL)) {
            let text = String::from_utf8(recorded_proposal.clone()).unwrap();
            assert_eq!(text.matches(MACOS).count(), 1, "{name} {}", job.id);
            let windows = text.replace(MACOS, PLATFORM_PROFILE).into_bytes();
            digests.insert(sha256_hex(&recorded_proposal), sha256_hex(&windows));
            expected_journal = substituted(&journal, &digests);
            expected = serde_json::from_slice(&substituted(
                &serde_json::to_vec(&expected).unwrap(),
                &digests,
            ))
            .unwrap();
            if let Some(proposed) = expected.get_mut("proposal") {
                proposed["manifestByteCount"] = json!(windows.len().to_string());
            }
            if let Some(seal) = expected.get_mut("journalSeal") {
                seal["sha256"] = json!(sha256_hex(&expected_journal));
            }
            proposal = Some(windows);
        }
        if receipt.is_some() {
            let relative = job.marker["relativeSessionPath"].as_str().unwrap();
            let manifest = std::fs::read(corpus.sessions.join(relative).join("manifest.json"))
                .unwrap_or_else(|_| panic!("{name} {}: no recorded Manifest", job.id));
            assert_eq!(
                std::fs::read(recorded.join(PROPOSAL)).ok(),
                Some(manifest),
                "{name} {}: Swift's Manifest is its proposal",
                job.id
            );
            published += 1;
        } else {
            refused += 1;
        }
        assert_eq!(
            labelled(marker),
            labelled(expected),
            "{name} {}: the marker",
            job.id
        );
        assert_eq!(
            std::fs::read(directory.join(PROPOSAL)).ok(),
            proposal,
            "{name} {}: the Manifest proposal",
            job.id
        );
        assert_eq!(
            std::fs::read(directory.join("journal.jsonl")).unwrap(),
            expected_journal,
            "{name} {}: the Job Journal",
            job.id
        );
        expected_jobs.push(job);
    }

    // Every file of the Sessions root, and the storage owner's directory.
    let expected: BTreeMap<_, _> = tree(&corpus.sessions)
        .into_iter()
        .map(|(path, bytes)| {
            let bytes = bytes.map(|bytes| {
                if path.ends_with("/manifest.json") {
                    String::from_utf8(bytes)
                        .unwrap()
                        .replace(MACOS, PLATFORM_PROFILE)
                        .into_bytes()
                } else {
                    substituted(&bytes, &digests)
                }
            });
            (path, bytes)
        })
        .collect();
    let actual = tree(&sessions_root);
    // Every published Session is in the recorded tree; so is a Session a
    // publication stopped after creating it (Swift writes it in place, and
    // this writer renames what it staged to the same name).
    let own: BTreeSet<String> = expected_jobs
        .iter()
        .filter(|job| job.marker.get("receipt").is_some())
        .map(|job| {
            job.marker["relativeSessionPath"]
                .as_str()
                .unwrap()
                .to_owned()
        })
        .collect();
    for session in &own {
        assert!(expected.contains_key(session), "{name}: {session}");
    }
    // Git keeps no empty directory: the recording holds every file and each
    // directory with a file below it; each Session's empty `raw` and
    // `derived` Artifact directories are checked by name.
    let mut actual = actual;
    let sessions_here: Vec<String> = actual
        .keys()
        .filter(|path| {
            path.split('/').count() == 3
                && path
                    .rsplit('/')
                    .next()
                    .is_some_and(|last| last.starts_with("session-"))
        })
        .cloned()
        .collect();
    for session in &sessions_here {
        for empty in ["artifacts/raw", "artifacts/derived"] {
            let path = format!("{session}/{empty}");
            if !expected.contains_key(&path) {
                assert_eq!(actual.remove(&path), Some(None), "{name}: {path}");
            }
        }
    }
    assert_eq!(
        actual.keys().collect::<Vec<_>>(),
        expected.keys().collect::<Vec<_>>(),
        "{name}: the Sessions tree"
    );
    for (path, bytes) in &expected {
        assert_eq!(&actual[path], bytes, "{name}: {path}");
    }
    if let Some(recorded) = &corpus.owner {
        assert_eq!(tree(&owner), tree(recorded), "{name}: the storage owner");
    }

    // A Session a publication stopped after creating it is one the catalog
    // does not account for, and the census refuses the list, as Swift's.
    if sessions_here.len() != own.len() {
        let refusal = SessionStore::open(&owner, &sessions_root)
            .unwrap()
            .handle_resource("session.list", &Map::new())
            .unwrap_err();
        assert!(
            refusal.message.contains("unaccounted content"),
            "{name}: {}",
            refusal.message
        );
        return (published, refused);
    }
    // Read back as after a restart: a list a page at a time, each cursor
    // read by an owner opened after it was handed out, and each Session.
    let mut listed = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let reopened = SessionStore::open(&owner, &sessions_root).unwrap();
        let mut params = Map::from_iter([("pageSize".into(), json!(1))]);
        if let Some(cursor) = &cursor {
            params.insert("cursor".into(), json!(cursor));
        }
        let page = reopened
            .handle_resource("session.list", &params)
            .unwrap_or_else(|error| panic!("{name}: {}", error.message));
        arkdeck_contract::validate_method_value("session.list", "result", &page)
            .unwrap_or_else(|error| panic!("{name}: {error}"));
        for item in page["items"].as_array().unwrap() {
            listed.push(item["sessionId"].as_str().unwrap().to_owned());
        }
        match page["nextCursor"].as_str() {
            Some(next) => cursor = Some(next.to_owned()),
            None => break,
        }
    }
    let registered: BTreeSet<String> = own
        .iter()
        .map(|relative| relative.rsplit('/').next().unwrap().to_owned())
        .collect();
    assert_eq!(
        listed.iter().cloned().collect::<BTreeSet<_>>(),
        registered,
        "{name}: session.list"
    );
    assert_eq!(listed.len(), registered.len(), "{name}: session.list");
    let reopened = SessionStore::open(&owner, &sessions_root).unwrap();
    for id in &registered {
        let shown = reopened
            .handle_resource(
                "session.show",
                &Map::from_iter([("sessionId".into(), json!(id))]),
            )
            .unwrap_or_else(|error| panic!("{name} {id}: {}", error.message));
        arkdeck_contract::validate_method_value("session.show", "result", &shown)
            .unwrap_or_else(|error| panic!("{name} {id}: {error}"));
    }
    (published, refused)
}

/// The recorded `observe.device@1` Job that observed its device, which the
/// crash test publishes.
const CRASHED: &str = "job-0f77f8c52864d676372962eccb17389c";
/// Where the crash test's child publishes, handed to it by the parent.
const CRASH_ROOT: &str = "ARKDECK_WINDOWS_STAGED_CRASH_ROOT";

/// The recorded Job as it stood before its publication, its Journal then,
/// and its request hash.
fn crashed_job() -> (JobRecord, Vec<u8>, String) {
    let store = fixtures().join("observe-device/store");
    let directory = store.join("jobs").join(CRASHED);
    let mut record: Value =
        serde_json::from_slice(&std::fs::read(directory.join("job-record.json")).unwrap()).unwrap();
    record
        .as_object_mut()
        .unwrap()
        .remove("sessionPublicationRecord");
    let index: Value =
        serde_json::from_slice(&std::fs::read(store.join("index.json")).unwrap()).unwrap();
    let hash = index["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["jobId"] == CRASHED)
        .unwrap()["requestHash"]
        .as_str()
        .unwrap()
        .to_owned();
    (
        JobRecord::decode(&serde_json::to_vec(&record).unwrap()).unwrap(),
        before_publication(&std::fs::read(directory.join("journal.jsonl")).unwrap()),
        hash,
    )
}

/// A volume with room, and a process that ends once the staged Session's
/// Manifest is published, before its rename.
struct CrashAfterManifest;
impl StorageProbe for CrashAfterManifest {
    fn snapshot(&self, root: &HostDirectory) -> io::Result<StorageSnapshot> {
        Volume {
            available: u64::MAX / 4,
        }
        .snapshot(root)
    }
    fn reached(&self, point: PublicationPoint) {
        if point == PublicationPoint::ManifestPublished {
            std::process::exit(75);
        }
    }
}

/// The crash test's child: publishes the Job in the root its parent names,
/// and ends the process there. Without that root it does nothing.
#[test]
fn staged_crash_child() {
    let Some(root) = std::env::var_os(CRASH_ROOT).map(PathBuf::from) else {
        return;
    };
    let (record, _, _) = crashed_job();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    let claims = StorageClaims::default();
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &CrashAfterManifest,
    };
    let directory = root.join("jobs-state/jobs").join(CRASHED);
    let mut writer = JournalWriter::open(&directory, false).unwrap();
    let marker = publisher.publish(&record, &mut writer, &directory, "2026-09-14T00:00:00Z");
    panic!("the publication was not stopped: {marker}");
}

/// A publication a crash stopped between its Manifest and its rename leaves
/// its Session staged, never published. The next start removes it once it is
/// proved this Runtime's (a staged name, a private directory, the identity a
/// publication writes, a Job this Runtime holds), keeps and names anything
/// else, publishes nothing again and leaves the Job as the crash left it.
/// Once staging is empty it goes.
#[test]
fn a_session_a_crash_left_staged_is_removed_at_the_next_start_and_nothing_else() {
    let scratch = Scratch::new();
    let root = &scratch.0;
    for name in ["session-owner", "Sessions", "jobs-state"] {
        create_private_directory(&root.join(name));
    }
    let (record, journal, hash) = crashed_job();
    {
        let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
        assert_eq!(
            jobs.admit(&record, &hash).unwrap(),
            crate::AdmissionVerdict::Admitted
        );
        jobs.persist(&record, "2026-09-14T00:00:00Z").unwrap();
    }
    let directory = root.join("jobs-state/jobs").join(CRASHED);
    HostDirectory::open(&directory)
        .unwrap()
        .create_document("journal.jsonl", &journal)
        .unwrap();

    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "session_publication::windows_tests::staged_crash_child",
            "--nocapture",
        ])
        .env(CRASH_ROOT, root)
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(75), "{output:?}");
    let session = root.join(format!("Sessions/2026/09/session-{CRASHED}"));
    let staging = root.join("Sessions").join(STAGING);
    let staged: Vec<String> = std::fs::read_dir(&staging)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(staged.len(), 1, "{staged:?}");
    let staged = staged[0].clone();
    assert!(staging.join(&staged).join("manifest.json").is_file());
    assert!(!session.exists());
    let left = |name: &str| std::fs::read(directory.join(name)).unwrap();
    let (record_bytes, journal_bytes) = (left("job-record.json"), left("journal.jsonl"));

    // What nothing proves this Runtime's is kept as it is.
    let rogue = [
        ("not-a-staged-name", None),
        ("00000000-0000-4000-8000-000000000000", None),
        (
            "11111111-1111-4111-8111-111111111111",
            Some(
                r#"{"jobId":"job-ffffffffffffffffffffffffffffffff","schemaVersion":"1.0.0","sessionId":"session-job-ffffffffffffffffffffffffffffffff"}"#,
            ),
        ),
    ];
    let staging_directory = HostDirectory::open(&staging).unwrap();
    for (name, identity) in rogue {
        let entry = staging_directory.create_private_child(name).unwrap();
        if let Some(identity) = identity {
            entry
                .create_document(".session-identity.json", identity.as_bytes())
                .unwrap();
        }
    }
    drop(staging_directory);

    let jobs = JobStore::open_owner(&root.join("jobs-state")).unwrap();
    let sessions = SessionStore::open(&root.join("session-owner"), &root.join("Sessions")).unwrap();
    let claims = StorageClaims::default();
    let ample = Volume {
        available: u64::MAX / 4,
    };
    let publisher = SessionPublisher {
        sessions: &sessions,
        claims: &claims,
        probe: &ample,
    };
    let recovered = publisher.recover_staged(&jobs).unwrap();
    assert_eq!(recovered.removed, [(staged.clone(), CRASHED.to_owned())]);
    let kept: BTreeSet<&str> = recovered
        .kept
        .iter()
        .map(|(name, _)| name.as_str())
        .collect();
    assert_eq!(
        kept,
        rogue.iter().map(|(name, _)| *name).collect(),
        "{:?}",
        recovered.kept
    );
    assert!(!staging.join(&staged).exists());
    for (name, _) in rogue {
        assert!(staging.join(name).is_dir(), "{name}");
    }
    // Nothing is published again, and the Job is left as the crash left it.
    assert!(!session.exists());
    assert_eq!(left("job-record.json"), record_bytes);
    assert_eq!(left("journal.jsonl"), journal_bytes);
    // A second start changes nothing.
    let again = publisher.recover_staged(&jobs).unwrap();
    assert!(again.removed.is_empty());
    assert_eq!(again.kept, recovered.kept);
    // Once nothing is left in it, staging goes.
    for (name, _) in rogue {
        std::fs::remove_dir_all(staging.join(name)).unwrap();
    }
    assert_eq!(
        publisher.recover_staged(&jobs).unwrap(),
        StagedRecovery::default()
    );
    assert!(!staging.exists());
}
