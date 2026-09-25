//! Swift `RuntimeSessionPublicationWriter` for the Jobs this Runtime runs. At
//! its terminal boundary a Job becomes a formal Session under the configured
//! Sessions root, derived only from its durable record and Journal: the
//! Manifest proposal beside the Job, the Journal's `finalized` record, the
//! Session tree with a byte-identical Journal copy, the outcome audit, the
//! write-once Manifest and the catalog entry; and, whatever happened, the
//! ownership marker the Job record keeps.
//!
//! As in Swift, a restart never resumes a publication; only `job.reconcile`
//! starts one again, after the writer's confirmed refusal of an unbound
//! source (`job_reconcile.rs`).
//!
//! Unlike Swift, the Session is written aside, in the Sessions root's own
//! `.staging`, and renamed whole to its published name under the storage
//! lock. This Runtime's continuity scan reads every retained Session's
//! Journal and takes no storage lock, so it must never meet a Session before
//! it is complete: it passes staging over, and the rename is atomic. The
//! storage lock is held only to read the status, to create and remove
//! staging, and to rename and register, never while the Session is written.
//! What is published, and every answer, is Swift's. A staged Session a crash
//! left is removed at the daemon's next start once it is proved this
//! Runtime's (`recover_staged`), and nothing is published again.
use crate::job_journal_events::{self as events, Envelope};
use crate::job_journal_replay::ReplayFacts;
use crate::job_journal_writer::JournalWriter;
use crate::job_owner::JobStore;
use crate::job_record::JobRecord;
use crate::session_inventory::STAGING;
use crate::session_owner::{SessionStore, StorageHold};
use arkdeck_contract::sha256_hex;
use arkdeck_platform::{DocumentPublishError, HostDirectory, host_gregorian_timestamp};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::Mutex;

const APP_VERSION: &str = "ArkDeckKit-M1-006";
const PLATFORM_PROFILE: &str = "PLATFORM-MACOS@0.2.0";
/// Swift `SessionManifestDocument.maximumCanonicalBytes`, which is also a
/// publication claim's finalization headroom.
const MAXIMUM_MANIFEST: usize = 16 * 1024 * 1024;
const MAXIMUM_JOURNAL: usize = 64 * 1024 * 1024;
/// Swift `SessionArtifactPublicationBarrier`'s shards.
const SHARDS: &str = "0123456789abcdef";
const PROPOSAL: &str = "session-manifest.proposal.json";

/// What Swift `HostStorageProbing` reports about a Sessions root's volume.
pub struct StorageSnapshot {
    pub volume_identity: String,
    pub available_bytes: u64,
    pub read_only: bool,
}

/// Swift `HostStorageProbing`, and where a publication stands, which only a
/// test observes, to stop the publication there or to time it.
pub trait StorageProbe: Sync {
    fn snapshot(&self, root: &HostDirectory) -> io::Result<StorageSnapshot>;
    /// The publication has reached `point`.
    fn reached(&self, _point: PublicationPoint) {}
}

/// Where a Session publication stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PublicationPoint {
    /// The staged Session's directories and identity file exist, and nothing
    /// else.
    SessionCreated,
    /// `copied` of the Job Journal's `of` records are in the staged Session's
    /// Journal.
    JournalCopied { copied: usize, of: usize },
    /// The staged Session's Manifest is published.
    ManifestPublished,
    /// The storage lock is held, and the staged Session is still to be
    /// renamed to its published name.
    Moving,
    /// The storage lock was released, having been held for `held`.
    StorageReleased { held: std::time::Duration },
}

/// Swift `SystemHostStorageProbe`: the held root's file system.
pub struct SystemStorageProbe;

impl StorageProbe for SystemStorageProbe {
    fn snapshot(&self, root: &HostDirectory) -> io::Result<StorageSnapshot> {
        let capacity = root.export_capacity()?;
        Ok(StorageSnapshot {
            volume_identity: capacity.facts.volume_identity,
            available_bytes: capacity.available_bytes,
            read_only: capacity.read_only,
        })
    }
}

/// Swift `HostStorageCoordinator`'s active claims in this process: each
/// admitted publication's soft bytes on its volume, held until its receipt.
/// As in Swift, only a refused composition releases a claim early; any other
/// stop leaves it held.
#[derive(Default)]
pub struct StorageClaims(Mutex<BTreeMap<String, (String, u64)>>);

impl StorageClaims {
    /// Swift `admitUnchecked` for a light writer.
    fn admit(&self, claim: &str, volume: &str, bytes: u64, snapshot: &StorageSnapshot) -> bool {
        let mut claims = self
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if snapshot.volume_identity != volume || snapshot.read_only || claims.contains_key(claim) {
            return false;
        }
        let held = claims
            .values()
            .filter(|(held, _)| held == volume)
            .fold(0_u64, |sum, (_, bytes)| sum.saturating_add(*bytes));
        match held.checked_add(bytes) {
            Some(required) if required <= snapshot.available_bytes => {
                claims.insert(claim.into(), (volume.into(), bytes));
                true
            }
            _ => false,
        }
    }

    fn release(&self, claim: &str) {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(claim);
    }
}

/// Swift `RuntimeSessionPublicationWriter` over the Session owner this
/// composition holds.
pub struct SessionPublisher<'a> {
    pub sessions: &'a SessionStore,
    pub claims: &'a StorageClaims,
    pub probe: &'a dyn StorageProbe,
}

/// Why a publication stopped short of its receipt.
struct Stop {
    reason: &'static str,
    detail: String,
}

fn stop(reason: &'static str, detail: impl Into<String>) -> Stop {
    Stop {
        reason,
        detail: detail.into(),
    }
}

/// Swift's catch-all: anything the composer did not name is the storage's.
fn storage(detail: impl Into<String>) -> Stop {
    stop("storageUnavailable", detail)
}

/// Swift's rendering of `SessionStorageError.writeFailed`.
fn write_failed(path: &Path, error: &io::Error) -> Stop {
    storage(format!(
        "writeFailed(path: \"{}\", errno: {})",
        path.display(),
        error.raw_os_error().unwrap_or(0)
    ))
}

fn publish_failed(path: &Path, error: DocumentPublishError) -> Stop {
    match error {
        DocumentPublishError::BeforePublication(error)
        | DocumentPublishError::OutcomeUnknown(error) => write_failed(path, &error),
    }
}

impl SessionPublisher<'_> {
    /// Swift `publish`: the marker this Job's record keeps, whatever
    /// happened. A marker that already holds its receipt stands.
    pub(crate) fn publish(
        &self,
        record: &JobRecord,
        journal: &mut JournalWriter,
        job_directory: &Path,
        now: &str,
    ) -> Value {
        if let Some(existing) = record
            .session_publication()
            .filter(|marker| marker.get("receipt").is_some())
        {
            return existing.clone();
        }
        self.attempt(record, journal, job_directory, now)
            .unwrap_or_else(|stopped| refused(record, &stopped))
    }

    /// Swift `attempt`: claim, compose, seal, create, copy, publish,
    /// register, receipt, release.
    fn attempt(
        &self,
        record: &JobRecord,
        journal: &mut JournalWriter,
        job_directory: &Path,
        now: &str,
    ) -> Result<Value, Stop> {
        let (root_path, policy_generation, _) =
            self.under_storage_lock(|held| held.publication_status().map_err(storage))?;
        let root = HostDirectory::open(&root_path).map_err(|e| write_failed(&root_path, &e))?;
        let facts = root
            .export_facts()
            .map_err(|e| write_failed(&root_path, &e))?;
        let (year, month) = utc_month(record.created())
            .ok_or_else(|| stop("sourceIntegrityFailed", "Job creation time is unreadable"))?;
        let session_id = format!("session-{}", record.job_id);
        let mut marker = Map::from_iter([
            ("sessionID".into(), json!(session_id)),
            ("catalogDigest".into(), json!(record.catalog_digest())),
            (
                "policyGeneration".into(),
                json!(policy_generation.to_string()),
            ),
            (
                "root".into(),
                json!({"path": foundation_path(&root_path), "device": facts.device.to_string(),
                    "inode": facts.inode.to_string(), "volumeIdentity": facts.volume_identity}),
            ),
            (
                "relativeSessionPath".into(),
                json!(format!("{year}/{month}/{session_id}")),
            ),
            ("claims".into(), json!([])),
            ("phase".into(), json!("awaitingStorage")),
        ]);

        // 1. Metadata and finalization headroom before anything is created.
        let journal_path = job_directory.join("journal.jsonl");
        let journal_bytes =
            std::fs::read(&journal_path).map_err(|e| write_failed(&journal_path, &e))?;
        let replayed = events_of(&journal_bytes)?;
        let metadata = (journal_bytes.len() as u64).max(1) + 64 * 1024;
        let claim = format!("session-publication-{}", record.job_id);
        let admission = uuid().map_err(|e| write_failed(&root_path, &e))?;
        let snapshot = self
            .probe
            .snapshot(&root)
            .map_err(|e| write_failed(&root_path, &e))?;
        if !self.claims.admit(
            &claim,
            &facts.volume_identity,
            metadata + MAXIMUM_MANIFEST as u64,
            &snapshot,
        ) {
            return Ok(Value::Object(marker));
        }
        marker.insert(
            "claims".into(),
            json!([{"volumeIdentity": facts.volume_identity, "claimID": claim,
                "admissionGeneration": admission, "writerClass": "light",
                "metadataHeadroomBytes": metadata.to_string(),
                "finalizationHeadroomBytes": MAXIMUM_MANIFEST.to_string(),
                "remainingGrowthBytes": "0"}]),
        );

        // 2. A Job whose facts cannot render the current contract never
        //    creates a Session directory at all.
        let completed = record.finished_at().unwrap_or(now).to_owned();
        let replay = journal.facts();
        let manifest = match compose(record, &replayed, &replay, &completed) {
            Ok(manifest) => manifest,
            Err(refusal) => {
                self.claims.release(&claim);
                return Err(refusal);
            }
        };
        let digest = sha256_hex(&manifest);

        // 3. The checkpoint of the record and Journal the proposal came from.
        let record_bytes = record
            .durable_bytes()
            .map_err(|error| storage(error.message))?;
        let last = last_sequence(&replayed);
        marker.insert(
            "checkpointSeal".into(),
            json!({"sha256": sha256_hex(&record_bytes),
                "byteCount": journal_bytes.len().to_string(), "lastSequence": last}),
        );
        marker.insert(
            "proposal".into(),
            json!({"manifestSHA256": digest, "manifestByteCount": manifest.len().to_string(),
                "terminalStatus": record.state, "outcomeCertainty": "confirmed",
                "completedAtUTC": completed}),
        );
        let job =
            HostDirectory::open(job_directory).map_err(|e| write_failed(job_directory, &e))?;
        job.publish_document(PROPOSAL, &manifest, MAXIMUM_MANIFEST)
            .map_err(|error| publish_failed(&job_directory.join(PROPOSAL), error))?;

        // 4. The Job's own Journal ends with `finalized`, which names the
        //    proposal; the Session's Journal seal binds the complete Journal.
        if !replay.finalized {
            let envelope = Envelope {
                event_id: "session-finalized".into(),
                sequence: last + 1,
                session_id: session_id.clone(),
                job_id: record.job_id.clone(),
                timestamp: now.into(),
            };
            journal
                .append(&events::finalized(
                    &envelope,
                    &record.state,
                    &digest,
                    "confirmed",
                ))
                .map_err(|error| storage(error.to_string()))?;
        }
        let sealed = std::fs::read(&journal_path).map_err(|e| write_failed(&journal_path, &e))?;
        let sealed_events = events_of(&sealed)?;

        // 5. The Session tree, created once: aside, in the Sessions root's
        //    `.staging`, and renamed whole to its published name in step 8.
        let session_path = root_path.join(&year).join(&month).join(&session_id);
        let year_root = root
            .private_child(&year)
            .map_err(|e| write_failed(&root_path.join(&year), &e))?;
        let month_root = year_root
            .private_child(&month)
            .map_err(|e| write_failed(&root_path.join(&year).join(&month), &e))?;
        match month_root.kind_and_size(&session_id) {
            Ok(_) => return Err(already_exists(&session_id)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => (),
            Err(error) => return Err(write_failed(&session_path, &error)),
        }
        // Staging is created and removed under the storage lock, so that no
        // publication removes it while another creates its Session there.
        let staging_path = root_path.join(STAGING);
        let (parent, name, session) = self.under_storage_lock(|_| {
            let parent = root
                .private_child(STAGING)
                .map_err(|e| write_failed(&staging_path, &e))?;
            let name = uuid().map_err(|e| write_failed(&staging_path, &e))?;
            let session = parent
                .create_private_child(&name)
                .map_err(|e| write_failed(&staging_path.join(&name), &e))?;
            root.sync().map_err(|e| write_failed(&root_path, &e))?;
            Ok((parent, name, session))
        })?;
        let staged_path = staging_path.join(&name);
        let mut staged = Staged {
            publisher: self,
            root: &root,
            parent,
            name,
            location: [year.clone(), month.clone(), session_id.clone()],
            moved: false,
        };
        let child = |parent: &HostDirectory, name: &str, path: &Path| {
            parent
                .private_child(name)
                .map_err(|e| write_failed(&path.join(name), &e))
        };
        let audit = child(&session, "audit", &session_path)?;
        let artifacts = child(&session, "artifacts", &session_path)?;
        let artifacts_path = session_path.join("artifacts");
        let raw = child(&artifacts, "raw", &artifacts_path)?;
        let derived = child(&artifacts, "derived", &artifacts_path)?;
        let partial = child(&artifacts, "partial", &artifacts_path)?;
        let identity = crate::session_json::encode(&json!({"jobId": record.job_id,
            "schemaVersion": "1.0.0", "sessionId": session_id}))
        .map_err(|_| storage("invalidRecord(\"invalid Session identity file\")"))?;
        session
            .create_document(".session-identity.json", &identity)
            .map_err(|e| write_failed(&session_path.join(".session-identity.json"), &e))?;
        for directory in [
            &audit,
            &raw,
            &derived,
            &partial,
            &artifacts,
            &session,
            &staged.parent,
        ] {
            directory
                .sync()
                .map_err(|e| write_failed(&session_path, &e))?;
        }
        let bound = session
            .export_facts()
            .map_err(|e| write_failed(&session_path, &e))?;
        marker.insert(
            "sessionRootIdentity".into(),
            json!({"device": bound.device.to_string(), "inode": bound.inode.to_string()}),
        );
        marker.insert("phase".into(), json!("prepared"));
        self.probe.reached(PublicationPoint::SessionCreated);

        // 6. The Session's Journal, byte for byte the Job's.
        {
            let mut copy = JournalWriter::open(&staged_path, true)
                .map_err(|error| storage(error.to_string()))?;
            for (index, event) in sealed_events.iter().enumerate() {
                copy.append(event)
                    .map_err(|error| storage(error.to_string()))?;
                self.probe.reached(PublicationPoint::JournalCopied {
                    copied: index + 1,
                    of: sealed_events.len(),
                });
            }
        }
        let copied = session
            .read("journal.jsonl", MAXIMUM_JOURNAL)
            .map_err(|e| write_failed(&session_path.join("journal.jsonl"), &e))?;
        if copied != sealed {
            return Err(stop(
                "sourceIntegrityFailed",
                "the Session Journal copy is not byte-identical to the Job Journal",
            ));
        }
        marker.insert(
            "journalSeal".into(),
            json!({"sha256": sha256_hex(&copied), "byteCount": copied.len().to_string(),
                "lastSequence": last_sequence(&sealed_events)}),
        );
        marker.insert("phase".into(), json!("sealed"));

        // 7. The outcome audit, then the write-once Manifest under the
        //    Session's terminal lock and every Artifact publication shard.
        let mut outcome = crate::session_json::encode(&json!({
            "auditId": format!("session-publication-{}", record.job_id), "category": "outcome",
            "correlationId": record.job_id,
            "details": {"manifestSha256": digest, "operation": record.operation(),
                "terminalStatus": record.state},
            "jobId": record.job_id, "recordId": "session-publication-outcome",
            "schemaVersion": "1.0.0", "sessionId": session_id, "timestamp": now}))
        .map_err(|_| storage("invalidRecord(\"Session audit record exceeds bound\")"))?;
        outcome.push(b'\n');
        audit
            .append_record("session.jsonl", &outcome)
            .map_err(|e| write_failed(&session_path.join("audit/session.jsonl"), &e))?;
        {
            let _terminal = session
                .wait_lock(".manifest.lock", true)
                .map_err(|e| write_failed(&session_path.join(".manifest.lock"), &e))?;
            let mut shards = Vec::with_capacity(SHARDS.len());
            for shard in SHARDS.chars() {
                let name = format!(".publication-lock-{shard}.lock");
                shards.push(
                    partial.wait_lock(&name, false).map_err(|e| {
                        write_failed(&artifacts_path.join("partial").join(&name), &e)
                    })?,
                );
            }
            // Swift `SessionManifestJournalValidator` over the Session's
            // Journal copy, under the terminal lock and every shard.
            let copied_events = events_of(&copied)?;
            if let Some(rule) = unbound_reconcile_revision(&manifest, &copied_events) {
                return Err(storage(format!(
                    "invalidManifest({})",
                    crate::artifact_read_owner::swift_string(&rule)
                )));
            }
            session
                .publish_exclusive("manifest.json", &manifest)
                .map_err(|error| publish_failed(&session_path.join("manifest.json"), error))?;
            while let Some(shard) = shards.pop() {
                drop(shard);
            }
        }
        if session
            .read("manifest.json", MAXIMUM_MANIFEST)
            .ok()
            .as_deref()
            != Some(manifest.as_slice())
        {
            return Err(stop(
                "contractViolation",
                "published Manifest does not read back",
            ));
        }
        marker.insert("phase".into(), json!("manifestPublished"));
        self.probe.reached(PublicationPoint::ManifestPublished);

        // 8. Under the storage lock, the complete Session renamed to its
        //    published name, never over another entry, staging removed once
        //    it is empty, and the catalog's own entry, read back, as the
        //    receipt.
        let generation = self.under_storage_lock(|held| {
            self.probe.reached(PublicationPoint::Moving);
            // A cleanup may have removed a container that was empty since.
            let year_root = root
                .private_child(&year)
                .map_err(|e| write_failed(&root_path.join(&year), &e))?;
            let month_root = year_root
                .private_child(&month)
                .map_err(|e| write_failed(&root_path.join(&year).join(&month), &e))?;
            if !staged
                .parent
                .move_exclusive(&staged.name, &month_root, &session_id)
                .map_err(|e| write_failed(&session_path, &e))?
            {
                return Err(already_exists(&session_id));
            }
            staged.moved = true;
            for directory in [&month_root, &year_root, &staged.parent] {
                directory
                    .sync()
                    .map_err(|e| write_failed(&session_path, &e))?;
            }
            root.remove_if_empty(STAGING)
                .and_then(|_| root.sync())
                .map_err(|e| write_failed(&staging_path, &e))?;
            held.register_published_session(&root_path, [&year, &month, &session_id])
                .map_err(storage)
        })?;
        marker.insert(
            "receipt".into(),
            json!({"manifestSHA256": digest, "catalogGeneration": generation.to_string(),
                "publishedAtUTC": now}),
        );
        marker.insert("phase".into(), json!("catalogPublished"));
        self.claims.release(&claim);
        Ok(Value::Object(marker))
    }
}

impl SessionPublisher<'_> {
    /// `work` under the storage lock, and how long it was held reported once
    /// it is released.
    fn under_storage_lock<T>(
        &self,
        work: impl FnOnce(&StorageHold<'_>) -> Result<T, Stop>,
    ) -> Result<T, Stop> {
        let held = self
            .sessions
            .hold()
            .map_err(|error| storage(format!("{}: {}", error.code, error.message)))?;
        let taken = std::time::Instant::now();
        let result = work(&held);
        drop(held);
        self.probe.reached(PublicationPoint::StorageReleased {
            held: taken.elapsed(),
        });
        result
    }
}

/// What the daemon's start found in the active Sessions root's `.staging`
/// (`SessionPublisher::recover_staged`), each entry with its Job or why it
/// was kept.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct StagedRecovery {
    /// Staged Sessions removed, each proved this Runtime's: a publication a
    /// crash stopped before its rename, and the Job it was publishing.
    pub removed: Vec<(String, String)>,
    /// Staged entries kept exactly as they are, and why: nothing proved them
    /// this Runtime's, or they could not be removed. No admission or answer
    /// reads them.
    pub kept: Vec<(String, String)>,
}

impl SessionPublisher<'_> {
    /// At the daemon's start, before it serves: the staged Sessions a
    /// publication stopped by a crash left in the active Sessions root, between
    /// its staging and its rename. Swift has none: it writes a Session in
    /// place, and a crash leaves what it had written there.
    ///
    /// As in Swift, a restart never resumes a publication: nothing is
    /// published again. An entry is removed only when it is proved this
    /// Runtime's: a staged name, a private directory of this Runtime's, and
    /// the Session identity a publication creates, canonical, naming a Job
    /// this Runtime holds. Anything else is kept exactly as it is and named.
    pub fn recover_staged(&self, jobs: &JobStore) -> Result<StagedRecovery, String> {
        let root_path = self
            .under_storage_lock(|held| {
                held.configured_root()
                    .map_err(|error| storage(format!("{}: {}", error.code, error.message)))
            })
            .map_err(|stopped| stopped.detail)?;
        let mut recovery = StagedRecovery::default();
        let root = match HostDirectory::open(&root_path) {
            Ok(root) => root,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(recovery),
            Err(error) => return Err(error.to_string()),
        };
        let staging = match root.kind_and_size(STAGING) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(recovery),
            Ok((arkdeck_platform::HostEntryKind::Directory, _)) => root.child(STAGING),
            Ok(_) => Err(io::Error::other("not a directory")),
            Err(error) => Err(error),
        };
        let staging = match staging {
            Ok(staging) => staging,
            Err(error) => {
                recovery.kept.push((
                    STAGING.into(),
                    format!("staging is not this Runtime's: {error}"),
                ));
                return Ok(recovery);
            }
        };
        let names = staging
            .names(STAGED_LISTING_BOUND)
            .map_err(|error| error.to_string())?;
        for name in names {
            let job_id = match owned(jobs, &staging, &name) {
                Ok(job_id) => job_id,
                Err(reason) => {
                    recovery.kept.push((name, reason));
                    continue;
                }
            };
            match staging.remove_tree(&name) {
                Ok(()) => recovery.removed.push((name, job_id)),
                Err(error) => recovery
                    .kept
                    .push((name, format!("it could not be removed: {error}"))),
            }
        }
        // Staging goes once it is empty, under the storage lock, as a
        // publication removes it.
        self.under_storage_lock(|_| {
            staging
                .sync()
                .and_then(|()| root.remove_if_empty(STAGING))
                .and_then(|_| root.sync())
                .map_err(|e| write_failed(&root_path.join(STAGING), &e))
        })
        .map_err(|stopped| stopped.detail)?;
        Ok(recovery)
    }
}

const STAGED_LISTING_BOUND: usize = 4096;

/// The Job whose staged Session `name` is, if the entry is proved this
/// Runtime's; otherwise why not.
fn owned(jobs: &JobStore, staging: &HostDirectory, name: &str) -> Result<String, String> {
    if !staged_name(name) {
        return Err("its name is not one a publication stages".into());
    }
    let session = staging
        .child(name)
        .map_err(|_| "it is not a private directory of this Runtime's".to_owned())?;
    let identity = session
        .read(".session-identity.json", 4096)
        .map_err(|_| "it holds no readable Session identity".to_owned())?;
    let job_id = serde_json::from_slice::<Value>(&identity)
        .ok()
        .and_then(|value| {
            let job_id = value["jobId"].as_str()?.to_owned();
            let expected = json!({"jobId": job_id, "schemaVersion": "1.0.0",
                "sessionId": format!("session-{job_id}")});
            (crate::session_json::encode(&expected).ok()? == identity).then_some(job_id)
        })
        .ok_or_else(|| "its Session identity is not one a publication creates".to_owned())?;
    jobs.read_snapshot(&job_id).map_err(|error| {
        format!(
            "its Job {job_id} is not one this Runtime holds: {}",
            error.message
        )
    })?;
    Ok(job_id)
}

/// A name `uuid` gives a staged Session: Swift's `UUID().uuidString`.
fn staged_name(name: &str) -> bool {
    let parts: Vec<&str> = name.split('-').collect();
    parts.iter().map(|part| part.len()).eq([8, 4, 4, 4, 12])
        && parts.iter().all(|part| {
            part.bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'A'..=b'F'))
        })
}

/// A staged Session. One whose publication stopped short of its rename is
/// renamed to its published name as it stands, as Swift, which writes a
/// Session in place, leaves what it had written; removed only when that name
/// is taken. Staging goes once it is empty.
struct Staged<'s, 'p> {
    publisher: &'s SessionPublisher<'p>,
    root: &'s HostDirectory,
    parent: HostDirectory,
    name: String,
    /// `yyyy`, `mm` and the Session identity.
    location: [String; 3],
    moved: bool,
}

impl Drop for Staged<'_, '_> {
    fn drop(&mut self) {
        if self.moved {
            return;
        }
        let _ = self.publisher.under_storage_lock(|_| {
            let [year, month, session_id] = &self.location;
            let moved = self
                .root
                .private_child(year)
                .and_then(|year| {
                    let month = year.private_child(month)?;
                    let moved = self.parent.move_exclusive(&self.name, &month, session_id)?;
                    if moved {
                        month.sync()?;
                        year.sync()?;
                    }
                    Ok(moved)
                })
                .unwrap_or(false);
            if !moved {
                let _ = self.parent.remove_tree(&self.name);
            }
            let _ = self.parent.sync();
            let _ = self.root.remove_if_empty(STAGING);
            let _ = self.root.sync();
            Ok(())
        });
    }
}

/// Swift's refusal of a Session path something already holds.
fn already_exists(session_id: &str) -> Stop {
    storage(format!(
        "invalidRecord(\"Session already exists: {session_id}\")"
    ))
}

/// Swift `refusedRecord`: an unbound marker carrying the confirmed reason.
fn refused(record: &JobRecord, stopped: &Stop) -> Value {
    json!({
        "sessionID": format!("session-{}", record.job_id),
        "catalogDigest": record.catalog_digest(), "policyGeneration": "0",
        "root": {"path": "", "device": "0", "inode": "0", "volumeIdentity": ""},
        "relativeSessionPath": "", "claims": [], "phase": "awaitingStorage",
        "failure": {"code": stopped.reason, "certainty": "confirmed",
            "detail": stopped.detail.chars().take(512).collect::<String>()},
    })
}

/// Swift `RuntimeSessionManifestComposer.compose`: this Job's canonical
/// Manifest, rendered only from its record and Journal, or the refusal
/// naming the fact it lacks.
fn compose(
    record: &JobRecord,
    events: &[Value],
    replay: &ReplayFacts,
    completed: &str,
) -> Result<Vec<u8>, Stop> {
    let status = record.state.as_str();
    if !["succeeded", "failed", "cancelled", "interrupted"].contains(&status) {
        return Err(stop(
            "contractViolation",
            format!("terminal state {status} has no current Manifest status"),
        ));
    }
    if record.outcome_unknown()
        || !replay.outstanding_intents.is_empty()
        || !replay.unknown_outcomes.is_empty()
    {
        return Err(stop(
            "contractViolation",
            "an unresolved Job cannot be sealed as a confirmed Session",
        ));
    }
    let created = events.first().filter(|event| event["kind"] == "jobCreated");
    let fact = |key: &str| created.and_then(|event| event["payload"][key].as_str());
    let (Some(mode), Some(authority), Some(baseline)) = (
        fact("executionMode"),
        fact("executionAuthority"),
        fact("coreBaseline"),
    ) else {
        return Err(stop(
            "sourceIntegrityFailed",
            "the Job Journal does not open with its own creation facts",
        ));
    };
    let steps = manifest_steps(events)?;
    let compensations = manifest_compensations(events)?;
    let device = device_context(record, events, mode)?;
    let mut bindings = manifest_bindings(events);
    if let Some(device) = &device
        && bindings.is_empty()
    {
        bindings = vec![device.binding.clone()];
    }
    let (target, toolchain) = match &device {
        Some(device) => (device.target.clone(), device.toolchain.clone()),
        // An honest host branch: no device is named, not even the target the
        // request carried.
        None if !touches_device(events) && bindings.is_empty() => (
            json!({"kind": "host", "connectKey": null, "transport": "host",
                "identitySnapshot": {"workspaceScope": record.request["target"]["targetId"],
                    "providerId": record.provider(), "catalogDigest": record.catalog_digest()}}),
            json!({"kind": "none"}),
        ),
        None => {
            return Err(stop(
                "sourceIntegrityFailed",
                "device-bound Session publication needs target and toolchain facts this Job \
                 record does not carry",
            ));
        }
    };
    let mut manifest = json!({
        "schemaVersion": "1.0.0", "appVersion": APP_VERSION, "coreSpecBaseline": baseline,
        "platformProfile": PLATFORM_PROFILE, "sessionId": format!("session-{}", record.job_id),
        "jobId": record.job_id, "status": status, "executionMode": mode,
        "executionAuthority": authority, "outcomeCertainty": "confirmed",
        "sessionDisposition": "finalized", "createdAt": record.created(),
        "completedAt": completed, "archivedAt": null,
        "originalTarget": target, "bindingHistory": bindings, "toolchain": toolchain,
        "workflow": {"kind": record.operation(), "profileVersion": record.catalog_digest(),
            "providerIdentity": record.provider()},
        "steps": steps, "parameters": [], "compensations": compensations,
        "confirmations": [],
        // Runtime Artifacts stay in the Artifact store; Swift copies none.
        "artifacts": [], "warnings": [], "recovery": null,
    });
    if let Some(device) = device {
        manifest["runtimeAuthority"] = device.authority;
    }
    manifest["failure"] = if status == "failed" {
        let Some(failure) = record.operation_failure() else {
            return Err(stop(
                "sourceIntegrityFailed",
                "a failed Job must carry its durable failure facts",
            ));
        };
        let text = |key: &str| failure[key].as_str().unwrap_or_default().to_owned();
        json!({"stage": "runtime", "code": text("code"),
            "summary": format!("{}/{}/{}", text("category"), text("retryability"), text("recovery"))})
    } else {
        Value::Null
    };
    let refused = |rule: Option<&str>| {
        stop(
            "contractViolation",
            match rule {
                Some(rule) => format!(
                    "composed Manifest was refused by the current contract: invalidManifest({})",
                    crate::artifact_read_owner::swift_string(rule)
                ),
                None => "composed Manifest was refused by the current contract".into(),
            },
        )
    };
    let bytes = crate::session_json::encode(&manifest).map_err(|_| refused(None))?;
    // Swift `SessionManifestDocument(data:)`: the locked contract and bound,
    // a rule it names refused under that name.
    if bytes.len() > MAXIMUM_MANIFEST {
        return Err(refused(None));
    }
    match crate::session_manifest::decode_manifest(&bytes) {
        Ok(_) => Ok(bytes),
        Err(crate::session_manifest::ManifestError::Rule(rule)) => Err(refused(Some(rule))),
        Err(_) => Err(refused(None)),
    }
}

/// Swift `manifestSteps`: each intent's typed declaration with the tuple its
/// correlated outcome proves; a retried Step keeps its latest row.
fn manifest_steps(events: &[Value]) -> Result<Vec<Value>, Stop> {
    let outcomes = correlated(events, "stepOutcome");
    let mut steps: Vec<Value> = Vec::new();
    let mut seen = BTreeSet::new();
    for event in events.iter().filter(|event| event["kind"] == "stepIntent") {
        let event_id = event["eventId"].as_str().unwrap_or_default();
        let (Some(step_id), Some(Value::Object(step))) =
            (event["stepId"].as_str(), event["payload"].get("step"))
        else {
            return Err(stop(
                "sourceIntegrityFailed",
                format!("Journal Step intent {event_id} carries no typed declaration"),
            ));
        };
        if !seen.insert(step_id) {
            steps.retain(|existing| existing["id"] != step_id);
        }
        let Some(hash) = event["argumentsHash"].as_str() else {
            return Err(stop(
                "sourceIntegrityFailed",
                format!("Journal Step intent {event_id} carries no arguments hash"),
            ));
        };
        let (disposition, certainty, result) =
            execution_tuple(outcomes.get(event_id).copied(), step_id)?;
        let mut row = step.clone();
        row.insert("argumentsHash".into(), json!(hash));
        row.insert("sourceStepId".into(), Value::Null);
        row.insert("compensationTrigger".into(), Value::Null);
        row.insert(
            "bindingRevision".into(),
            event["bindingRevision"]
                .as_i64()
                .map_or(Value::Null, |revision| json!(revision)),
        );
        row.insert("disposition".into(), json!(disposition));
        row.insert("outcomeCertainty".into(), json!(certainty));
        row.insert("semanticResult".into(), json!(result));
        steps.push(Value::Object(row));
    }
    Ok(steps)
}

/// Swift `manifestCompensations`.
fn manifest_compensations(events: &[Value]) -> Result<Vec<Value>, Stop> {
    let outcomes = correlated(events, "compensationOutcome");
    let mut records: Vec<Value> = Vec::new();
    for event in events
        .iter()
        .filter(|event| event["kind"] == "compensationIntent")
    {
        let event_id = event["eventId"].as_str().unwrap_or_default();
        let (Some(descriptor_id), Some(descriptor), Some(source)) = (
            event["stepId"].as_str(),
            event["payload"].get("descriptor"),
            event["payload"]["compensationOfStepId"].as_str(),
        ) else {
            return Err(stop(
                "sourceIntegrityFailed",
                format!("Journal compensation intent {event_id} is incomplete"),
            ));
        };
        let outcome = outcomes.get(event_id).copied();
        let (disposition, certainty, result) = execution_tuple(outcome, descriptor_id)?;
        let mut identities = vec![json!(event_id)];
        if let Some(outcome) = outcome {
            identities.push(outcome["eventId"].clone());
        }
        let failure = if result == "failed" {
            json!({"stage": "compensation", "code": "compensation.failed",
                "summary": outcome.and_then(|outcome| outcome["payload"]["summary"].as_str())
                    .unwrap_or("compensation reported failure")})
        } else {
            Value::Null
        };
        records.retain(|existing| existing["descriptor"]["id"] != descriptor_id);
        records.push(json!({"descriptor": descriptor, "sourceStepId": source,
            "disposition": disposition, "outcomeCertainty": certainty, "result": result,
            "failure": failure, "journalEventIds": identities}));
    }
    Ok(records)
}

/// Each outcome of `kind` by the intent it correlates to.
fn correlated<'a>(events: &'a [Value], kind: &str) -> BTreeMap<&'a str, &'a Value> {
    events
        .iter()
        .filter(|event| event["kind"] == kind)
        .filter_map(|event| {
            Some((
                event["payload"]["correlatesToIntentEventId"].as_str()?,
                event,
            ))
        })
        .collect()
}

/// Swift `executionTuple`: derived only from a recorded outcome; a Step with
/// no outcome did not execute.
fn execution_tuple(
    outcome: Option<&Value>,
    context: &str,
) -> Result<(&'static str, &'static str, &'static str), Stop> {
    let Some(outcome) = outcome else {
        return Ok(("skipped", "notApplicable", "notRun"));
    };
    let (Some(result), Some(certainty)) = (
        outcome["payload"]["result"].as_str(),
        outcome["payload"]["outcomeCertainty"].as_str(),
    ) else {
        return Err(stop(
            "sourceIntegrityFailed",
            format!("Journal outcome for {context} is incomplete"),
        ));
    };
    if certainty != "confirmed" {
        return Ok(("outcomeUnknown", "outcomeUnknown", "unknown"));
    }
    Ok((
        "executed",
        "confirmed",
        if result == "succeeded" {
            "succeeded"
        } else {
            "failed"
        },
    ))
}

/// Swift `manifestBindings`: the Journal's confirmed bindings by revision.
fn manifest_bindings(events: &[Value]) -> Vec<Value> {
    let mut by_revision = BTreeMap::new();
    for event in events
        .iter()
        .filter(|event| event["kind"] == "bindingConfirmed")
    {
        let (Some(revision), Some(binding)) = (
            event["bindingRevision"].as_i64(),
            event["payload"]["binding"].as_object(),
        ) else {
            continue;
        };
        let mut entry = binding.clone();
        entry.insert("revision".into(), json!(revision));
        by_revision.insert(revision, Value::Object(entry));
    }
    by_revision.into_values().collect()
}

/// Swift `DeviceContext`: the audit projection of device facts this Job
/// already owns.
struct DeviceContext {
    target: Value,
    binding: Value,
    toolchain: Value,
    authority: Value,
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Swift `deviceContext`: a Job whose Journal holds an intent that can touch
/// a device becomes a device Session only through its own verified
/// observation, Journal device outcomes that are confirmed and agree with it,
/// and its admission audit. None when no intent can touch a device.
fn device_context(
    record: &JobRecord,
    events: &[Value],
    mode: &str,
) -> Result<Option<DeviceContext>, Stop> {
    fn declaration(event: &Value) -> Option<&Value> {
        let key = match event["kind"].as_str() {
            Some("stepIntent") => "step",
            Some("compensationIntent") => "descriptor",
            _ => return None,
        };
        Some(&event["payload"][key]).filter(|step| step.is_object())
    }
    let intents: Vec<&Value> = events
        .iter()
        .filter(|event| {
            declaration(event).is_some_and(|step| {
                step["effect"].as_str() != Some("hostOnly")
                    || step["bindingRequirement"].as_str() != Some("none")
            })
        })
        .collect();
    if intents.is_empty() {
        return Ok(None);
    }
    let refused = |detail: &str| stop("sourceIntegrityFailed", format!("device Session: {detail}"));
    let inconsistent = || refused("missing or inconsistent job-local target/tool observation");
    let requested = &record.request["target"];
    let observed = record.evidence_observation().filter(|_| mode == "execute");
    let text = |key: &str| observed.and_then(|observation| observation[key].as_str());
    let seconds = |at: Option<&str>| at.and_then(crate::format_time::format_timestamp_seconds);
    let target_id = text("targetID")
        .filter(|target| Some(*target) == requested["targetId"].as_str())
        .ok_or_else(inconsistent)?;
    let revision = observed
        .and_then(|observation| observation["bindingRevision"].as_i64())
        .filter(|revision| {
            *revision > 0
                && Some(*revision) == requested["expectedBindingRevision"].as_i64()
                && record
                    .materialized_binding()
                    .is_none_or(|bound| bound == *revision)
        })
        .ok_or_else(inconsistent)?;
    let identity = text("stableIdentitySHA256")
        .filter(|identity| {
            lowercase_sha256(identity)
                && record
                    .materialized_identity()
                    .is_none_or(|bound| bound == *identity)
        })
        .ok_or_else(inconsistent)?;
    let provider = text("providerID")
        .filter(|provider| *provider == record.provider() && ["hdc", "arkforge"].contains(provider))
        .ok_or_else(inconsistent)?;
    let model = text("model")
        .filter(|model| !model.is_empty())
        .ok_or_else(inconsistent)?;
    let firmware = text("firmware")
        .filter(|firmware| !firmware.is_empty())
        .ok_or_else(inconsistent)?;
    let transport = text("transport")
        .filter(|transport| ["usb", "tcp", "uart"].contains(transport))
        .ok_or_else(inconsistent)?;
    let confirmed = text("confirmedAtUTC").ok_or_else(inconsistent)?;
    let tool_version = text("toolVersion")
        .filter(|version| !version.is_empty())
        .ok_or_else(inconsistent)?;
    let tool_sha256 = text("toolSHA256")
        .filter(|digest| lowercase_sha256(digest))
        .ok_or_else(inconsistent)?;
    let (Some(confirmed_at), Some(started_at), Some(finished_at)) = (
        seconds(Some(confirmed)),
        seconds(Some(record.created())),
        seconds(record.finished_at()),
    ) else {
        return Err(inconsistent());
    };
    if text("confirmationMethod") != Some("machineReadback")
        || started_at > confirmed_at
        || confirmed_at > finished_at
    {
        return Err(inconsistent());
    }

    let mut connect_key: Option<&str> = None;
    let mut confirmed_outcome = false;
    let mut mutation = false;
    for intent in intents {
        let target = &intent["payload"]["target"];
        let key = target["connectKey"].as_str().filter(|key| !key.is_empty());
        let agrees = intent["bindingRevision"].as_i64() == Some(revision)
            && target["scope"] == "device"
            && target["targetId"] == target_id
            && target["identitySnapshotHash"] == identity
            && key.is_some()
            && connect_key.is_none_or(|known| Some(known) == key);
        if !agrees {
            return Err(refused(
                "Journal target or binding differs from the verified observation",
            ));
        }
        connect_key = key;
        let outcome = events
            .iter()
            .filter(|event| {
                matches!(
                    event["kind"].as_str(),
                    Some("stepOutcome" | "compensationOutcome")
                )
            })
            .find(|event| {
                event["payload"]["correlatesToIntentEventId"].as_str() == intent["eventId"].as_str()
            })
            .filter(|outcome| outcome["payload"]["outcomeCertainty"] == "confirmed")
            .ok_or_else(|| refused("Journal device outcome is missing or not confirmed"))?;
        confirmed_outcome |= outcome["payload"]["result"] == "succeeded";
        mutation |= declaration(intent).is_some_and(|step| {
            matches!(
                step["effect"].as_str(),
                Some("deviceMutation" | "destructive")
            )
        });
    }
    let (Some(connect_key), true) = (connect_key, confirmed_outcome) else {
        return Err(refused(
            "no confirmed device outcome substantiates the target",
        ));
    };
    let unaudited = || refused("missing admission audit or unsupported recovery provenance");
    let admission = record.admission().ok_or_else(unaudited)?;
    let member = |key: &str| admission.get(key).cloned().unwrap_or(Value::Null);
    let admitted = seconds(admission["admittedAtUTC"].as_str());
    if !admission["reference"]
        .as_str()
        .is_some_and(|reference| !reference.is_empty())
        || !admitted.is_some_and(|admitted| admitted <= confirmed_at)
        || !member("completeOverwriteRecovery").is_null()
    {
        return Err(unaudited());
    }
    let mut authority = json!({
        "kind": member("kind"), "reference": member("reference"),
        "admittedAtUtc": member("admittedAtUTC"), "validUntilUtc": member("validUntilUTC"),
        "consumptionFingerprintSha256": member("consumptionFingerprintSHA256"),
        "reservationId": null, "useOrdinal": null, "planDigest": null,
        "stepSetDigest": null, "targetBindingDigest": null, "artifactDigest": null,
    });
    match admission["kind"].as_str() {
        Some("defaultReadOnlyPolicy") => {
            if mutation
                || !member("validUntilUTC").is_null()
                || !member("consumptionFingerprintSHA256").is_null()
                || !member("runtimeCapabilityCorrelation").is_null()
            {
                return Err(refused("read-only policy cannot substantiate a mutation"));
            }
        }
        Some("runtimeCapability") => {
            let correlation = &admission["runtimeCapabilityCorrelation"];
            if !correlation["reservationID"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
                || !correlation["useOrdinal"].as_u64().is_some_and(|n| n > 0)
                || !admission["consumptionFingerprintSHA256"]
                    .as_str()
                    .is_some_and(lowercase_sha256)
                || !seconds(admission["validUntilUTC"].as_str())
                    .zip(admitted)
                    .is_some_and(|(expiry, start)| start < expiry)
                || correlation["planDigestSHA256"].as_str() != record.materialized_plan()
                || ![
                    "planDigestSHA256",
                    "stepSetDigestSHA256",
                    "targetBindingDigestSHA256",
                ]
                .iter()
                .all(|key| correlation[*key].as_str().is_some_and(lowercase_sha256))
                || (!correlation["artifactSHA256"].is_null()
                    && !correlation["artifactSHA256"]
                        .as_str()
                        .is_some_and(lowercase_sha256))
            {
                return Err(refused(
                    "missing or inconsistent consumed Runtime capability audit",
                ));
            }
            for (destination, source) in [
                ("reservationId", "reservationID"),
                ("useOrdinal", "useOrdinal"),
                ("planDigest", "planDigestSHA256"),
                ("stepSetDigest", "stepSetDigestSHA256"),
                ("targetBindingDigest", "targetBindingDigestSHA256"),
                ("artifactDigest", "artifactSHA256"),
            ] {
                authority[destination] = correlation[source].clone();
            }
        }
        _ => {
            return Err(refused(
                "missing or inconsistent consumed Runtime capability audit",
            ));
        }
    }
    let snapshot = json!({"targetId": target_id, "stableIdentitySHA256": identity,
        "model": model, "firmware": firmware});
    Ok(Some(DeviceContext {
        target: json!({"kind": "real", "connectKey": connect_key, "transport": transport,
            "identitySnapshot": snapshot}),
        binding: json!({
            "revision": revision, "connectKey": connect_key, "transport": transport,
            "identitySnapshot": snapshot,
            "evidence": [
                format!("Job-local machine readback at {confirmed}"),
                format!("Confirmed Journal device outcomes at binding revision {revision}"),
            ],
            "confirmedBy": "corePolicy", "channelProtection": "unverifiedAssumeUnprotected",
        }),
        toolchain: json!({"kind": "runtimeProvider", "providerIdentity": provider,
            "profileIdentifier": record.operation(), "reportedVersion": tool_version,
            "sha256": tool_sha256}),
        authority,
    }))
}

/// Whether any intent can touch a device, which is what makes Swift build a
/// device Session.
fn touches_device(events: &[Value]) -> bool {
    events.iter().any(|event| {
        let declaration = match event["kind"].as_str() {
            Some("stepIntent") => &event["payload"]["step"],
            Some("compensationIntent") => &event["payload"]["descriptor"],
            _ => return false,
        };
        declaration.is_object()
            && (declaration["effect"].as_str() != Some("hostOnly")
                || declaration["bindingRequirement"].as_str() != Some("none"))
    })
}

/// The rule of Swift's `SessionManifestJournalValidator` a Manifest this
/// writer composes can break, which it names: a `reconcileOutcome` whose
/// binding revision the Manifest's binding history does not hold. A
/// device-bound Job reconciled before any of its steps confirmed a binding
/// journals the fresh facts' revision there, and Swift then refuses the
/// Manifest. The validator's other rules correlate the Journal's intents,
/// outcomes and finalized record with the Manifest, which is composed from
/// that same Journal.
fn unbound_reconcile_revision(manifest: &[u8], events: &[Value]) -> Option<String> {
    let manifest: Value = serde_json::from_slice(manifest).ok()?;
    let revisions: BTreeSet<i64> = manifest["bindingHistory"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|binding| binding["revision"].as_i64())
        .collect();
    events
        .iter()
        .filter(|event| event["kind"] == "reconcileOutcome")
        .find(|event| {
            event["bindingRevision"]
                .as_i64()
                .is_some_and(|revision| !revisions.contains(&revision))
        })
        .map(|event| {
            format!(
                "journal binding revision does not exist in Manifest: {}",
                event["eventId"].as_str().unwrap_or_default()
            )
        })
}

/// Every record of a Journal whose tail is whole.
fn events_of(bytes: &[u8]) -> Result<Vec<Value>, Stop> {
    let unreadable = || storage("sequenceViolation(\"the Job Journal cannot be replayed\")");
    bytes
        .strip_suffix(b"\n")
        .ok_or_else(unreadable)?
        .split(|byte| *byte == b'\n')
        .map(|line| serde_json::from_slice(line).map_err(|_| unreadable()))
        .collect()
}

fn last_sequence(events: &[Value]) -> i64 {
    events
        .last()
        .and_then(|event| event["sequence"].as_i64())
        .unwrap_or(-1)
}

/// The UTC `yyyy` and `mm` of an ISO 8601 time: Swift's Session partition.
fn utc_month(at: &str) -> Option<(String, String)> {
    let text = host_gregorian_timestamp(crate::session_time::session_timestamp(at)?)?;
    Some((text.get(..4)?.to_owned(), text.get(5..7)?.to_owned()))
}

/// Foundation `URL.resolvingSymlinksInPath()` of an already canonical path:
/// a `/private` prefix is dropped when the remainder names the same
/// directory, as `/tmp` and `/var` do.
fn foundation_path(path: &Path) -> String {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix("/private/") {
        let stripped = format!("/{rest}");
        if let (Ok(short), Ok(long)) = (std::fs::metadata(&stripped), std::fs::metadata(path))
            && short.dev() == long.dev()
            && short.ino() == long.ino()
        {
            return stripped;
        }
    }
    text.into_owned()
}

/// Swift `UUID().uuidString`: a random version 4 identity in upper case.
fn uuid() -> io::Result<String> {
    let mut bytes = arkdeck_platform::random_bytes::<16>()?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02X}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

#[cfg(test)]
mod measurement {
    //! What a Session publication whose Journal holds more than ten thousand
    //! records holds the storage lock for, and what proving a device
    //! mutation's state waits meanwhile (TASK-XPA-014). A measurement for a
    //! quiet host, not a check:
    //! `cargo test -p arkdeck-hoststore --lib session_publication::measurement -- --ignored --nocapture`.
    //!
    //! The Journal is the Swift pointer oracle's tap with its evidence-model
    //! read retried 5,000 more times (10,013 records). Each sample publishes
    //! it for another Job into a Sessions root of its own, while another
    //! thread proves the mutation state over and over; none may be refused.
    //! The proof is then timed once more with nothing else running, over the
    //! one Session the sample retained. A root of its own per sample keeps
    //! each proof to one retained Session: the proof's Journal replay grows
    //! with the square of a Journal's length.
    use super::*;
    use crate::{CapabilityStore, DeviceHolds, JobStore, MutationAuthority};
    use std::os::unix::fs::DirBuilderExt;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};

    const JOB: &str = "4ac2c3640786ad0e831952ab62bb71bc";
    const RETRIES: i64 = 5_000;
    const SAMPLES: usize = 12;

    struct Timing(Mutex<Vec<Duration>>);
    impl StorageProbe for Timing {
        fn snapshot(&self, root: &HostDirectory) -> io::Result<StorageSnapshot> {
            Ok(StorageSnapshot {
                volume_identity: root.export_facts()?.volume_identity,
                available_bytes: u64::MAX / 4,
                read_only: false,
            })
        }
        fn reached(&self, point: PublicationPoint) {
            if let PublicationPoint::StorageReleased { held } = point {
                self.0.lock().unwrap().push(held);
            }
        }
    }

    fn fixture(name: &str) -> String {
        std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/pointer-input/store/jobs")
                .join(format!("job-{JOB}"))
                .join(name),
        )
        .unwrap()
    }

    /// The tap's Journal without its `finalized` record, its evidence-model
    /// read retried `RETRIES` times more.
    fn long_journal() -> String {
        let events: Vec<Value> = fixture("journal.jsonl")
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .filter(|event| event["kind"] != "finalized")
            .collect();
        let find = |kind: &str| {
            events
                .iter()
                .find(|event| event["kind"] == kind && event["stepId"] == "read-evidence-model")
                .unwrap()
                .clone()
        };
        let (intent, outcome) = (find("stepIntent"), find("stepOutcome"));
        let mut all = Vec::new();
        for event in events {
            let last = event["eventId"] == outcome["eventId"];
            all.push(event);
            if last {
                for attempt in 2..=RETRIES + 1 {
                    let id =
                        |event: &Value| format!("{}-{attempt}", event["eventId"].as_str().unwrap());
                    let (mut retried, mut answered) = (intent.clone(), outcome.clone());
                    retried["eventId"] = json!(id(&intent));
                    retried["attempt"] = json!(attempt);
                    answered["eventId"] = json!(id(&outcome));
                    answered["attempt"] = json!(attempt);
                    answered["payload"]["correlatesToIntentEventId"] = json!(id(&intent));
                    all.push(retried);
                    all.push(answered);
                }
            }
        }
        let mut journal = String::new();
        for (sequence, mut event) in all.into_iter().enumerate() {
            event["sequence"] = json!(sequence);
            journal.push_str(
                std::str::from_utf8(&crate::session_json::encode(&event).unwrap()).unwrap(),
            );
            journal.push('\n');
        }
        journal
    }

    fn private(path: &Path) {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)
            .unwrap();
    }

    fn summary(name: &str, mut samples: Vec<Duration>) {
        samples.sort();
        let at = |fraction: f64| samples[((samples.len() - 1) as f64 * fraction).round() as usize];
        println!(
            "{name}: n={} min={:?} median={:?} p95={:?} p99={:?} max={:?}",
            samples.len(),
            samples[0],
            at(0.5),
            at(0.95),
            at(0.99),
            samples[samples.len() - 1]
        );
    }

    #[test]
    #[ignore = "a measurement for a quiet host"]
    fn a_publication_of_a_ten_thousand_record_journal_holds_the_storage_lock_briefly() {
        let journal = long_journal();
        let record = {
            let mut record: Value = serde_json::from_str(&fixture("job-record.json")).unwrap();
            record
                .as_object_mut()
                .unwrap()
                .remove("sessionPublicationRecord");
            serde_json::to_string(&record).unwrap()
        };
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("publication-measure-{nonce:032x}"));
        for name in ["store", "jobs"] {
            private(&root.join(name));
        }
        let jobs = JobStore::open_owner(&root.join("store")).unwrap();
        let capabilities = CapabilityStore::open(&root.join("store/capabilities")).unwrap();
        let holds = DeviceHolds::default();
        println!(
            "journal: {} records, {} bytes; {SAMPLES} samples",
            journal.lines().count(),
            journal.len()
        );
        let (mut storage, mut totals, mut waits, mut proofs) =
            (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for sample in 1..=SAMPLES {
            let owner = root.join(format!("sample-{sample}"));
            private(&owner.join("session-owner"));
            private(&owner.join("Sessions"));
            let sessions =
                SessionStore::open(&owner.join("session-owner"), &owner.join("Sessions")).unwrap();
            let authority = MutationAuthority {
                default_root: &root.join("store"),
                sessions: Some(&sessions),
                capabilities: &capabilities,
                holds: &holds,
            };
            let id = format!("{sample:032x}");
            let directory = root.join("jobs").join(format!("job-{id}"));
            private(&directory);
            std::fs::write(directory.join("journal.jsonl"), journal.replace(JOB, &id)).unwrap();
            let record = JobRecord::decode(record.replace(JOB, &id).as_bytes()).unwrap();
            let mut writer = JournalWriter::open(&directory, false).unwrap();
            let probe = Timing(Mutex::new(Vec::new()));
            let claims = StorageClaims::default();
            let publisher = SessionPublisher {
                sessions: &sessions,
                claims: &claims,
                probe: &probe,
            };
            let done = AtomicBool::new(false);
            let (marker, total, sample_waits) = std::thread::scope(|scope| {
                let proving = scope.spawn(|| {
                    let mut waited = Vec::new();
                    while !done.load(Ordering::SeqCst) {
                        let started = Instant::now();
                        authority.require_state(&jobs).unwrap();
                        waited.push(started.elapsed());
                    }
                    waited
                });
                let started = Instant::now();
                let marker =
                    publisher.publish(&record, &mut writer, &directory, "2026-09-14T00:00:01Z");
                let total = started.elapsed();
                done.store(true, Ordering::SeqCst);
                (marker, total, proving.join().unwrap())
            });
            assert!(marker.get("receipt").is_some(), "{marker}");
            let held = probe.0.lock().unwrap().clone();
            let started = Instant::now();
            authority.require_state(&jobs).unwrap();
            let proof = started.elapsed();
            println!(
                "sample {sample}: publication {total:?}; storage lock held {held:?}; \
                 {} proofs meanwhile, longest {:?}; proof alone over 1 retained {proof:?}",
                sample_waits.len(),
                sample_waits.iter().max().unwrap()
            );
            storage.extend(held);
            totals.push(total);
            waits.extend(sample_waits);
            proofs.push(proof);
        }
        summary("storage lock held by a publication", storage);
        summary("a whole publication", totals);
        summary("a proof during a publication", waits);
        summary("a proof alone", proofs);
        std::fs::remove_dir_all(&root).unwrap();
    }
}
