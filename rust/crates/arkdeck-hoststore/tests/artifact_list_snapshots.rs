#![cfg(target_os = "macos")]
//! `artifact.list` keeps its pages where Swift's `artifactInventory` keeps
//! them, `.imports-v1/artifact-snapshots` below the Artifact root
//! (`RuntimeArtifactStore.swift:1096–1099`), apart from the Job owner's
//! `cli-job-snapshots`: neither pager reclaims the other's snapshots. An
//! Artifact snapshot a Runtime of before kept beside the Job owner's is not
//! moved: its cursor is answered as a reclaimed snapshot's, and the Job
//! owner's pager reclaims it in its turn.
use arkdeck_contract::{WireError, sha256_hex};
use arkdeck_hoststore::{ArtifactReadStore, ArtifactUsage, JobStore};
use arkdeck_platform::{HostSqlite, SqliteValue as Sql};
use serde_json::{Map, Value, json};
use std::{
    collections::BTreeSet,
    fs,
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    path::PathBuf,
};

const ARTIFACT_SNAPSHOTS: &str = "artifacts/.imports-v1/artifact-snapshots";
const JOB_SNAPSHOTS: &str = "store/cli-job-snapshots";
/// Swift `RuntimeSnapshotPager.invalidCursor()`.
const INVALID_CURSOR: &str =
    "cursor is invalid, belongs to another query or its snapshot was reclaimed";

/// A daemon's Job owner root, `store`, beside its Artifact root,
/// `artifacts`: two finished Jobs, and two Artifacts of `job-a`.
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let nonce = arkdeck_platform::random_bytes::<8>().unwrap();
        let root = PathBuf::from(format!(
            "/private/tmp/arkdeck-artifact-list-snapshots-{}-{:x}",
            std::process::id(),
            u64::from_ne_bytes(nonce)
        ));
        for directory in ["", "store", "artifacts", "artifacts/job-a"] {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(root.join(directory))
                .unwrap();
        }
        let fixture = Self(root);
        drop(JobStore::open(&fixture.0.join("store")).unwrap());
        fixture.seed("job-a", 1);
        fixture.seed("job-b", 2);
        let rows: Vec<Value> = ["first", "second"]
            .into_iter()
            .map(|name| fixture.artifact(name))
            .collect();
        let index = fixture.0.join("artifacts/job-a/index.json");
        fs::write(
            &index,
            serde_json::to_vec(&json!({"schemaVersion":"1.0.0","artifacts":rows})).unwrap(),
        )
        .unwrap();
        fs::set_permissions(index, fs::Permissions::from_mode(0o600)).unwrap();
        fixture
    }

    /// A finished Job's row, as `tests/job_owner.rs` seeds one.
    fn seed(&self, id: &str, sequence: i64) {
        let record = json!({"jobID":id, "request":{"documentType":"runtime-operation-request", "schemaVersion":"1.0.0", "requestId":format!("req-{id}"), "idempotencyKey":format!("idem-{id}"), "target":{"targetId":"TGT-fixture", "expectedBindingRevision":1}, "operation":{"id":"observe.device", "version":1}, "inputs":{}, "requestedOutputs":["derivedArtifacts"]}, "operationReference":"observe.device@1", "catalogDigest":arkdeck_contract::CATALOG_DIGEST, "providerID":"hdc", "createdAtUTC":"2026-08-31T12:00:00Z", "actualEffect":"readOnly", "materializedPlanDigest":"a".repeat(64), "materializedBindingRevision":1, "state":"succeeded", "outcomeUnknown":false, "timeline":["created", "completed"], "actualStepKinds":[], "skipReasons":{}});
        let date = "2026-08-31T12:00:00Z";
        let seconds = arkdeck_platform::host_gregorian_seconds(2026, 8, 31, 12, 0, 0).unwrap();
        HostSqlite::open(&self.0.join("store/runtime-jobs.sqlite3"), false, false)
            .unwrap()
            .execute(
                "INSERT INTO runtime_job VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                &[
                    Sql::Text(id.into()),
                    Sql::Text(format!("idem-{id}")),
                    Sql::Text("b".repeat(64)),
                    Sql::Text("succeeded".into()),
                    Sql::Integer(sequence),
                    Sql::Text(date.into()),
                    Sql::Text(format!("{:016x}", seconds.to_bits() ^ (1 << 63))),
                    Sql::Text(date.into()),
                    Sql::Integer(1),
                    Sql::Blob(serde_json::to_vec(&record).unwrap()),
                ],
            )
            .unwrap();
    }

    /// A published Artifact of `job-a`, as `tests/artifact_read_owner.rs`
    /// publishes one.
    fn artifact(&self, name: &str) -> Value {
        let digest = sha256_hex(name.as_bytes());
        let id = format!(
            "ART-{}",
            &sha256_hex(format!("job-a\0{name}\0{digest}").as_bytes())[..32]
        );
        let payload = self.0.join("artifacts/job-a").join(&id);
        fs::write(&payload, name).unwrap();
        fs::set_permissions(payload, fs::Permissions::from_mode(0o400)).unwrap();
        json!({"artifactID":id,"jobID":"job-a","sessionID":"SESSION-1","stepID":"step",
            "name":name,"mediaType":"application/octet-stream","sha256":digest,"createdAtUTC":"2026-09-11T00:00:00.000Z",
            "providerID":"fixture","sourceOperation":"fixture.read","privacy":"standard","byteCount":name.len(),
            "bindingSnapshot":{"targetID":"fixture-target"},"retention":{"retentionClass":"default","pinned":false},
            "status":{"published":{}},"redactionApplied":false})
    }

    fn owners(&self) -> (JobStore, ArtifactReadStore) {
        (
            JobStore::open(&self.0.join("store")).unwrap(),
            ArtifactReadStore::open(&self.0.join("artifacts")).unwrap(),
        )
    }

    /// The snapshot documents a pager's directory holds.
    fn snapshots(&self, directory: &str) -> BTreeSet<String> {
        fs::read_dir(self.0.join(directory))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .filter(|name| name.starts_with("snapshot-"))
            .collect()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

/// `job-a`'s Artifact list, a page of one Artifact from `cursor` on.
fn list(
    (jobs, artifacts): &(JobStore, ArtifactReadStore),
    cursor: Option<&Value>,
) -> Result<Value, WireError> {
    let mut params = json!({"owner":{"kind":"job","id":"job-a"},"pageSize":1});
    if let Some(cursor) = cursor {
        params["cursor"] = cursor.clone();
    }
    artifacts.handle_list(params.as_object().unwrap(), |job| {
        jobs.read_snapshot(job).map(|_| ())
    })
}

/// The Job list, a page of one Job from `cursor` on.
fn job_list((jobs, _): &(JobStore, ArtifactReadStore), cursor: Option<&Value>) -> Value {
    let mut params = Map::from_iter([("pageSize".into(), json!(1))]);
    if let Some(cursor) = cursor {
        params.insert("cursor".into(), cursor.clone());
    }
    jobs.handle_resource("job.list", &params).unwrap()
}

/// The list's first page makes Swift's directory, private, and keeps its
/// snapshot there, never in the Job owner's; the next page is read from it.
/// Neither the Artifact quota nor its usage census counts the page.
#[test]
fn the_artifact_list_keeps_its_pages_where_swift_does() {
    let fixture = Fixture::new();
    let owners = fixture.owners();
    let usage = ArtifactUsage::open(&fixture.0.join("artifacts"), 1 << 30).unwrap();
    let (status, quota) = (usage.status().unwrap(), usage.quota().unwrap());
    let first = list(&owners, None).unwrap();
    assert_eq!(first["hasMore"], true, "{first}");
    let directory = fs::symlink_metadata(fixture.0.join(ARTIFACT_SNAPSHOTS)).unwrap();
    assert!(directory.is_dir());
    assert_eq!(directory.mode() & 0o777, 0o700);
    assert_eq!(
        fixture.snapshots(ARTIFACT_SNAPSHOTS),
        BTreeSet::from([format!(
            "snapshot-{}.json",
            first["snapshotRevision"].as_str().unwrap()
        )])
    );
    assert_eq!(fixture.snapshots(JOB_SNAPSHOTS), BTreeSet::new());
    let next = list(&owners, Some(&first["nextCursor"])).unwrap();
    assert_eq!(next["snapshotRevision"], first["snapshotRevision"]);
    assert_eq!(next["hasMore"], false, "{next}");
    assert_ne!(next["items"], first["items"]);
    assert_eq!(usage.status().unwrap(), status);
    assert_eq!(usage.quota().unwrap(), quota);
}

/// The Artifact list's pager reclaims its own snapshots only: lists past its
/// 32-snapshot budget leave the Job list's snapshot, and its cursor still
/// answers the next page. While both pagers kept their snapshots in the Job
/// owner's directory, the 32nd list reclaimed it.
#[test]
fn artifact_lists_leave_a_job_list_cursor_alone() {
    let fixture = Fixture::new();
    let owners = fixture.owners();
    let first = job_list(&owners, None);
    let job_snapshots = fixture.snapshots(JOB_SNAPSHOTS);
    assert_eq!(job_snapshots.len(), 1);
    for _ in 0..40 {
        list(&owners, None).unwrap();
    }
    let next = job_list(&owners, Some(&first["nextCursor"]));
    assert_eq!(next["snapshotRevision"], first["snapshotRevision"]);
    assert_ne!(next["items"], first["items"]);
    assert_eq!(fixture.snapshots(JOB_SNAPSHOTS), job_snapshots);
    assert_eq!(fixture.snapshots(ARTIFACT_SNAPSHOTS).len(), 32);
}

/// An Artifact snapshot a Runtime of before kept in the Job owner's
/// directory, the same pager's document, is not moved. Its cursor is
/// answered as Swift answers a reclaimed snapshot's, and the snapshot counts
/// toward the Job owner's 32-snapshot budget, which reclaims it first, as
/// the oldest, once the budget is reached.
#[test]
fn an_artifact_snapshot_of_before_is_answered_as_reclaimed_and_reclaimed_by_the_job_pager() {
    let fixture = Fixture::new();
    let owners = fixture.owners();
    let first = list(&owners, None).unwrap();
    let before = format!(
        "snapshot-{}.json",
        first["snapshotRevision"].as_str().unwrap()
    );
    fs::rename(
        fixture.0.join(ARTIFACT_SNAPSHOTS).join(&before),
        fixture.0.join(JOB_SNAPSHOTS).join(&before),
    )
    .unwrap();
    let refused = list(&owners, Some(&first["nextCursor"])).unwrap_err();
    assert_eq!(
        (refused.code.as_str(), refused.message.as_str()),
        ("invalidCursor", INVALID_CURSOR)
    );
    assert_eq!(
        Value::Object(refused.details.unwrap()),
        json!({"phase":"artifactOwner","newDispatchCount":0})
    );
    for _ in 0..31 {
        job_list(&owners, None);
    }
    let full = fixture.snapshots(JOB_SNAPSHOTS);
    assert_eq!(full.len(), 32);
    assert!(full.contains(&before));
    job_list(&owners, None);
    let kept = fixture.snapshots(JOB_SNAPSHOTS);
    assert_eq!(kept.len(), 32);
    assert!(!kept.contains(&before));
    assert!(
        full.iter()
            .all(|name| *name == before || kept.contains(name))
    );
}
