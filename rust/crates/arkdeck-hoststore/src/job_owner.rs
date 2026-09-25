//! Runtime-owned Job discovery. A read-only SQLite snapshot supplies Job
//! identity and state; presentation cursors retain immutable query results.
#[path = "import_references.rs"]
pub(crate) mod import_references;
#[path = "job_retention_census.rs"]
mod retention_census;
#[path = "workspace_references.rs"]
mod workspace_references;
use crate::job_record::{JobRecord, STATES, digest, failure, unreadable};
use crate::job_repository::{
    AdmissionVerdict, JobRepository, JobRow, JobWriteError, identifier, order_key,
};
use crate::snapshot_pager::SnapshotPager;
use arkdeck_contract::WireError;
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use serde_json::{Map, Value, json};
use std::{
    io,
    path::{Path, PathBuf},
};

#[path = "mutation_state_continuity.rs"]
mod mutation_state_continuity;

#[cfg(target_os = "macos")]
#[path = "job_flash_state.rs"]
mod flash_state;

#[cfg(test)]
#[path = "job_hdc_interlock_tests.rs"]
mod hdc_interlock_tests;

#[cfg(test)]
#[path = "job_list_stream_tests.rs"]
mod list_stream_tests;

pub struct JobStore {
    repository: JobRepository,
    path: PathBuf,
    root: HostDirectory,
    activity: std::sync::Mutex<()>,
    /// Readers cover final admission; a lifecycle exclusively freezes the
    /// participant inventory. Acquisition never waits behind a lifecycle.
    hdc_lifecycle: std::sync::RwLock<()>,
    /// Swift's resident runtime records that are ahead of their durable
    /// record: a `job.reconcile` that failed after its journal moved keeps
    /// what it had journaled in memory, never on disk. Every read of the Job
    /// sees it, as Swift's `recordForRead` does, until the Job is persisted
    /// again or the process ends.
    resident: std::sync::Mutex<std::collections::BTreeMap<String, JobRecord>>,
    /// The retained Sessions the last complete continuity scan let pass, in
    /// memory only (`mutation_state_continuity.rs`). Taken only under
    /// `activity`.
    session_verdicts: std::sync::Mutex<mutation_state_continuity::SessionVerdicts>,
}
const RECORD_BOUND: usize = 16 * 1024 * 1024;

/// Exclusive ownership of the final HDC participant inventory. Keep this
/// lease until the lifecycle has durably settled or recovered its boundary.
/// Dropping it releases admission, including on a normal error return.
#[must_use = "keep the interlock until the lifecycle outcome or recovery is durable"]
pub struct HdcLifecycleInterlock<'a> {
    _guard: std::sync::RwLockWriteGuard<'a, ()>,
}

pub(crate) struct JobAdmissionInterlock<'a> {
    jobs: &'a JobStore,
    _guard: std::sync::RwLockReadGuard<'a, ()>,
}

impl JobAdmissionInterlock<'_> {
    pub(crate) fn admit(
        &self,
        record: &JobRecord,
        request_hash: &str,
    ) -> Result<AdmissionVerdict, JobWriteError> {
        self.jobs.admit_interlocked(record, request_hash)
    }
}

fn guard_unavailable() -> JobWriteError {
    JobWriteError::Refused(io::Error::other("The Job activity guard is unavailable"))
}

impl JobStore {
    /// Refuse immediately if a lifecycle has frozen admission. Ordinary
    /// concurrent submissions share the gate; no waiting writer is installed.
    pub(crate) fn admission_interlock(&self) -> Result<JobAdmissionInterlock<'_>, WireError> {
        let guard = self.hdc_lifecycle.try_read().map_err(|error| match error {
            std::sync::TryLockError::WouldBlock => failure(
                "resourceConflict",
                "a confirmed host-wide HDC lifecycle action currently blocks new Job admission",
            ),
            std::sync::TryLockError::Poisoned(_) => failure(
                "internalError",
                "the HDC lifecycle interlock is unavailable",
            ),
        })?;
        Ok(JobAdmissionInterlock {
            jobs: self,
            _guard: guard,
        })
    }

    /// Freeze admission before reading current Jobs. The same gate covers
    /// final admission after materialization, so either the Job is visible
    /// to this census or its admission is refused. No caller-supplied census.
    pub fn acquire_hdc_lifecycle_interlock(&self) -> Result<HdcLifecycleInterlock<'_>, WireError> {
        let guard = self
            .hdc_lifecycle
            .try_write()
            .map_err(|error| match error {
                std::sync::TryLockError::WouldBlock => failure(
                    "resourceConflict",
                    "another HDC lifecycle action or Job admission owns the final Job interlock",
                ),
                std::sync::TryLockError::Poisoned(_) => failure(
                    "internalError",
                    "the HDC lifecycle interlock is unavailable",
                ),
            })?;
        if !self.current_jobs()?.is_empty() {
            return Err(failure(
                "factsDrifted",
                "current Runtime Jobs block the HDC lifecycle action",
            ));
        }
        Ok(HdcLifecycleInterlock { _guard: guard })
    }

    pub fn open(path: &Path) -> io::Result<Self> {
        Self::open_with(path, JobRepository::open)
    }

    /// The Rust Job owner's store: the same census and readers, plus the
    /// admission index and `job-record.json` writers. Only a state root this
    /// process owns is opened this way; a paired Swift daemon keeps its own
    /// Job owner, and the exclusive owner lock refuses a second one.
    pub fn open_owner(path: &Path) -> io::Result<Self> {
        Self::open_with(path, JobRepository::open_owner)
    }

    /// The Rust Job owner's store at the Runtime's state root, where Swift's
    /// daemon keeps its Job index, Job directories and `cli-job-snapshots`
    /// beside every other owner's entry: the production composition's layout,
    /// whose root a device mutation proves its state continuity against. It
    /// differs from [`Self::open_owner`] only in creating a first index beside
    /// those entries (`JobRepository::open_state_root_owner`).
    pub fn open_state_root_owner(path: &Path) -> io::Result<Self> {
        Self::open_with(path, JobRepository::open_state_root_owner)
    }

    fn open_with(
        path: &Path,
        repository: impl FnOnce(&Path) -> io::Result<JobRepository>,
    ) -> io::Result<Self> {
        let root = HostDirectory::open(path)?;
        let repository = repository(path)?;
        root.private_child("cli-job-snapshots")?;
        Ok(Self {
            repository,
            path: path.into(),
            root,
            activity: std::sync::Mutex::new(()),
            hdc_lifecycle: std::sync::RwLock::new(()),
            resident: Default::default(),
            session_verdicts: Default::default(),
        })
    }

    /// Keep `record` as the Job's resident record, ahead of its durable one.
    pub(crate) fn hold_resident(&self, record: JobRecord) {
        self.resident
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(record.job_id.clone(), record);
    }

    fn resident(&self, job_id: &str) -> Option<JobRecord> {
        self.resident
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(job_id)
            .cloned()
    }

    /// Whether the Job's record is held resident ahead of its durable one.
    pub(crate) fn holds_resident(&self, job_id: &str) -> bool {
        self.resident
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .contains_key(job_id)
    }

    /// Swift `RuntimeJobRepository.job(jobID:)`: the Job's index row, if any.
    pub(crate) fn job_row(&self, id: &str) -> io::Result<Option<JobRow>> {
        if !identifier(id) {
            return Ok(None);
        }
        self.root.validate_path(&self.path)?;
        Ok(self.repository.rows(Some(id))?.into_iter().next())
    }

    /// Swift `RuntimeJobRepository.activeJobs()`: every row whose state is
    /// not terminal, a state this build does not know included, in creation
    /// and then identity order.
    pub(crate) fn active_rows(&self) -> io::Result<Vec<JobRow>> {
        self.root.validate_path(&self.path)?;
        Ok(self
            .repository
            .map_rows(None, |row| {
                Ok((!crate::job_record::terminal(&row.state)).then_some(row))
            })?
            .into_iter()
            .flatten()
            .collect())
    }

    /// The Job's `job-record.json` as it stands, read through no link and
    /// creating nothing.
    pub(crate) fn record_bytes(&self, job_id: &str) -> io::Result<Vec<u8>> {
        if !identifier(job_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "The Job identity is not a Runtime identifier",
            ));
        }
        self.root
            .child("jobs")?
            .child(job_id)?
            .read("job-record.json", RECORD_BOUND)
    }

    /// Whether the Job's directory holds an entry `name`; an absent Job
    /// directory holds none.
    pub(crate) fn job_entry_exists(&self, job_id: &str, name: &str) -> io::Result<bool> {
        let absent = |error: &io::Error| error.kind() == io::ErrorKind::NotFound;
        let jobs = match self.root.child("jobs") {
            Err(error) if absent(&error) => return Ok(false),
            other => other?,
        };
        let job = match jobs.child(job_id) {
            Err(error) if absent(&error) => return Ok(false),
            other => other?,
        };
        match job.kind_and_size(name) {
            Ok(_) => Ok(true),
            Err(error) if absent(&error) => Ok(false),
            Err(error) => Err(error),
        }
    }

    /// Swift `RuntimeJobRecord.persist(into:)`: `jobs/<jobID>/job-record.json`
    /// alone, for a row that already describes the record; the index row is
    /// left as it is.
    pub(crate) fn publish_record_file(&self, record: &JobRecord) -> Result<(), JobWriteError> {
        let (key, bytes) = self.writable_record(record)?;
        let _guard = self.activity.lock().map_err(|_| guard_unavailable())?;
        self.root
            .validate_path(&self.path)
            .map_err(JobWriteError::Refused)?;
        self.repository
            .describes(&record.job_id, key, record.created())
            .map_err(JobWriteError::Refused)?;
        self.root
            .private_child("jobs")
            .and_then(|jobs| jobs.private_child(&record.job_id))
            .map_err(JobWriteError::Refused)?
            .publish_document("job-record.json", &bytes, RECORD_BOUND)
            .map_err(|error| match error {
                DocumentPublishError::BeforePublication(error) => JobWriteError::Refused(error),
                DocumentPublishError::OutcomeUnknown(error) => JobWriteError::OutcomeUnknown(error),
            })
    }

    /// Swift `RuntimeJobEngine`'s `cli-job-snapshots`: where this owner's
    /// resource pages are kept, made when the store opens.
    pub fn snapshot_directory(&self) -> PathBuf {
        self.path.join("cli-job-snapshots")
    }

    /// Swift RuntimeAdmissionService.lookup.
    pub fn lookup(
        &self,
        idempotency_key: &str,
        request_hash: &str,
    ) -> Result<AdmissionVerdict, JobWriteError> {
        self.repository
            .lookup(idempotency_key, request_hash)
            .map_err(JobWriteError::Refused)
    }

    /// Swift RuntimeAdmissionService.admit: the idempotency identity, Job
    /// identity, initial state and exact initial record bytes commit in one
    /// transaction. The caller starts the Job's journal only after `Admitted`.
    pub fn admit(
        &self,
        record: &JobRecord,
        request_hash: &str,
    ) -> Result<AdmissionVerdict, JobWriteError> {
        self.admission_interlock()
            .map_err(|error| JobWriteError::Refused(io::Error::other(error.message)))?
            .admit(record, request_hash)
    }

    fn admit_interlocked(
        &self,
        record: &JobRecord,
        request_hash: &str,
    ) -> Result<AdmissionVerdict, JobWriteError> {
        if !digest(request_hash) {
            return Err(JobWriteError::Invalid(
                "The admission request hash is not a SHA-256 digest",
            ));
        }
        let (key, bytes) = self.writable_record(record)?;
        let _guard = self.activity.lock().map_err(|_| guard_unavailable())?;
        self.root
            .validate_path(&self.path)
            .map_err(JobWriteError::Refused)?;
        self.repository.admit(
            &record.job_id,
            key,
            request_hash,
            &record.state,
            record.created(),
            &bytes,
        )
    }

    /// The Job's private `jobs/<jobID>` directory, created on first use; the
    /// admission journal opens there before the record is published.
    pub(crate) fn job_directory(&self, job_id: &str) -> Result<PathBuf, JobWriteError> {
        if !identifier(job_id) {
            return Err(JobWriteError::Invalid(
                "The Job identity is not a Runtime identifier",
            ));
        }
        let _guard = self.activity.lock().map_err(|_| guard_unavailable())?;
        self.root
            .validate_path(&self.path)
            .map_err(JobWriteError::Refused)?;
        self.root
            .private_child("jobs")
            .and_then(|jobs| jobs.private_child(job_id))
            .map_err(JobWriteError::Refused)?;
        Ok(self.path.join("jobs").join(job_id))
    }

    /// A Job's journal bytes as they stand, read through no link and
    /// creating nothing.
    pub(crate) fn journal_bytes(&self, job_id: &str) -> io::Result<Vec<u8>> {
        if !identifier(job_id) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "The Job identity is not a Runtime identifier",
            ));
        }
        self.root
            .child("jobs")?
            .child(job_id)?
            .read("journal.jsonl", 64 * 1024 * 1024)
    }

    /// Swift RuntimeJobEngine.persistRuntimeRecord: publish
    /// `jobs/<jobID>/job-record.json` atomically, then advance the index row
    /// with the same bytes. An index row must already describe this Job; once
    /// the record is published, an index failure is an uncertain outcome.
    pub fn persist(&self, record: &JobRecord, updated_at: &str) -> Result<(), JobWriteError> {
        if order_key(updated_at).is_err() {
            return Err(JobWriteError::Invalid(
                "The Job update time is not a Runtime timestamp",
            ));
        }
        let (key, bytes) = self.writable_record(record)?;
        let _guard = self.activity.lock().map_err(|_| guard_unavailable())?;
        self.root
            .validate_path(&self.path)
            .map_err(JobWriteError::Refused)?;
        self.repository
            .describes(&record.job_id, key, record.created())
            .map_err(JobWriteError::Refused)?;
        let directory = self
            .root
            .private_child("jobs")
            .and_then(|jobs| jobs.private_child(&record.job_id))
            .map_err(JobWriteError::Refused)?;
        directory
            .publish_document("job-record.json", &bytes, RECORD_BOUND)
            .map_err(|error| match error {
                DocumentPublishError::BeforePublication(error) => JobWriteError::Refused(error),
                DocumentPublishError::OutcomeUnknown(error) => JobWriteError::OutcomeUnknown(error),
            })?;
        self.repository
            .update(
                &record.job_id,
                key,
                record.created(),
                &record.state,
                updated_at,
                &bytes,
            )
            .map_err(|error| match error {
                JobWriteError::Refused(error) | JobWriteError::OutcomeUnknown(error) => {
                    JobWriteError::OutcomeUnknown(error)
                }
                JobWriteError::Invalid(message) => JobWriteError::OutcomeUnknown(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    message,
                )),
            })?;
        // The durable record is the Job's record again.
        self.resident
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&record.job_id);
        Ok(())
    }

    fn writable_record<'a>(
        &self,
        record: &'a JobRecord,
    ) -> Result<(&'a str, Vec<u8>), JobWriteError> {
        if !self.repository.writable() {
            return Err(JobWriteError::Refused(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "The Job store was opened for reading",
            )));
        }
        let key = record.idempotency_key().ok_or(JobWriteError::Invalid(
            "The Job record has no idempotency key",
        ))?;
        let bytes = record.durable_bytes().map_err(|_| {
            JobWriteError::Invalid("The Job record is not a current durable record")
        })?;
        Ok((key, bytes))
    }

    /// Swift `RuntimeJobEngine.unreadableDurableRecords(sampleLimit:)`: every
    /// durable Job record in the index this build cannot decode, counted, with
    /// the first `limit` identities in the index's order. It reads the index
    /// only, changes nothing, and grants no authority; `doctor --deep` names
    /// what it finds. A store whose index cannot be read at all is the
    /// caller's refusal, not an empty answer.
    pub fn unreadable_records(&self, limit: usize) -> Result<(u64, Vec<String>), WireError> {
        let rows = self.repository.rows(None).map_err(unreadable)?;
        let (mut total, mut sample) = (0_u64, Vec::new());
        for row in &rows {
            if JobRecord::from_row(row).is_err() {
                total += 1;
                if sample.len() < limit {
                    sample.push(row.id.clone());
                }
            }
        }
        Ok((total, sample))
    }

    /// Keep the complete Job activity census stable through a Session owner's
    /// preview/apply turn. Every future Job writer must acquire this same guard.
    /// Unreadable or unsupported records prevent reclamation; absence of an
    /// activity owner must never be interpreted as an empty active set.
    pub fn with_active_sessions<R>(
        &self,
        action: impl FnOnce(&std::collections::BTreeSet<String>) -> Result<R, WireError>,
    ) -> Result<R, WireError> {
        let _guard = self.activity.lock().map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let rows = self.repository.rows(None).map_err(unreadable)?;
        let indexed: std::collections::BTreeSet<_> =
            rows.iter().map(|row| row.id.as_str()).collect();
        // Until journal reconciliation is migrated, an indexed Job directory
        // may carry later or uncertain durable effects absent from the SQLite
        // snapshot. Keep it, even when the indexed state is terminal. Orphaned
        // and unsafe entries cannot be explained by a complete Job census.
        let retained_history = match self.root.child("jobs") {
            Ok(jobs) => {
                let names = jobs.names(100_000).map_err(unreadable)?;
                for name in &names {
                    if !indexed.contains(name.as_str()) {
                        return Err(unreadable(()));
                    }
                    jobs.child(name).map_err(unreadable)?;
                }
                names.into_iter().collect::<std::collections::BTreeSet<_>>()
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => Default::default(),
            Err(error) => return Err(unreadable(error)),
        };
        let mut active = std::collections::BTreeSet::new();
        for row in &rows {
            let record = JobRecord::from_row(row)?;
            if record.requires_session_retention() || retained_history.contains(&record.job_id) {
                active.insert(format!("session-{}", record.job_id));
            }
        }
        action(&active)
    }

    /// Swift `RuntimeJobEngine.listCurrentJobs`, from this owner's resident
    /// records when ahead of its durable rows: every Job not in a terminal
    /// state, holding outstanding cleanup residue, or of unknown outcome,
    /// in identity order. Swift lets an
    /// established recovery epoch or a Target alias resolution settle an
    /// unknown outcome; this owner holds neither index, so an outcome-unknown
    /// Job stays current. An unreadable row fails the whole read.
    pub fn current_jobs(&self) -> Result<Vec<crate::hdc_impact_source::CurrentJob>, WireError> {
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let rows = self.repository.rows(None).map_err(unreadable)?;
        let mut jobs = Vec::new();
        for row in &rows {
            let record = self
                .resident(&row.id)
                .map(Ok)
                .unwrap_or_else(|| JobRecord::from_row(row))?;
            let residues = record.residues().unwrap_or(0);
            if residues > 0
                || record.outcome_unknown()
                || !crate::job_record::terminal(&record.state)
            {
                jobs.push(crate::hdc_impact_source::CurrentJob {
                    job_id: record.job_id.clone(),
                    state: record.state.clone(),
                    outcome_unknown: record.outcome_unknown(),
                    residues,
                });
            }
        }
        jobs.sort_by(|left, right| left.job_id.cmp(&right.job_id));
        Ok(jobs)
    }

    /// Swift `RuntimeJobEngine.loaderTransitionAwaitingBinding`'s candidates:
    /// every DAYU200 flash Job for exactly this Target and binding revision
    /// parked in `waitingForRecovery` with an unknown outcome at its
    /// outstanding `enter-loader-mode` intent, by identity. An unreadable row
    /// fails the whole read.
    pub fn loader_transitions_awaiting_binding(
        &self,
        target_id: &str,
        expected_binding_revision: i64,
    ) -> Result<Vec<String>, WireError> {
        let rows = self.active_rows().map_err(unreadable)?;
        let mut jobs = Vec::new();
        for row in &rows {
            let record = self
                .resident(&row.id)
                .map(Ok)
                .unwrap_or_else(|| JobRecord::from_row(row))?;
            let target = &record.request["target"];
            if record.dayu200_flash()
                && target["targetId"].as_str() == Some(target_id)
                && target["expectedBindingRevision"].as_i64() == Some(expected_binding_revision)
                && record.state == "waitingForRecovery"
                && record.outcome_unknown()
                && record.recovery_step() == Some("enter-loader-mode")
                && record.recovery_intent().is_some()
            {
                jobs.push(record.job_id.clone());
            }
        }
        jobs.sort();
        Ok(jobs)
    }

    pub fn read_snapshot(&self, id: &str) -> Result<JobRecord, WireError> {
        if !identifier(id) {
            return Err(failure(
                "invalidInput",
                "An exact bounded Job identity is required",
            ));
        }
        // A resident record is what Swift reads first.
        if let Some(record) = self.resident(id) {
            return Ok(record);
        }
        // Swift `RuntimeJobResourceReader` spellings: an absent Job, a record
        // that cannot be read, and an index that cannot be read at all.
        self.repository
            .rows(Some(id))
            .map_err(|_| failure("recordUnreadable", "the Job read resource is unreadable"))?
            .first()
            .ok_or_else(|| failure("notFound", "the referenced Job does not exist"))
            .and_then(|row| {
                JobRecord::from_row(row).map_err(|_| {
                    failure(
                        "recordUnreadable",
                        &format!("the referenced Job record is unreadable: {id}"),
                    )
                })
            })
    }

    /// Swift `evidenceSnapshot`'s read of the superseding recovery epochs,
    /// which it makes for every snapshot and which throws when they are
    /// unreadable: whether an epoch names this Job as the Job that recovered.
    /// An absent document names none; Swift's read would also create the
    /// store's lock, an incidental file this read does not create.
    pub(crate) fn recovery_epoch_names(
        &self,
        job_id: &str,
    ) -> Result<bool, crate::RecoveryEpochError> {
        match self.root.document_metadata(crate::RECOVERY_EPOCH_DOCUMENT) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
            _ => {}
        }
        Ok(crate::list_recovery_epochs(&self.root)?
            .iter()
            .any(|epoch| crate::swift_decoding::same_text(&epoch.draft.recovery_job_id, job_id)))
    }

    pub fn handle_resource(
        &self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, WireError> {
        self.root.validate_path(&self.path).map_err(unreadable)?;
        if method == "job.list" {
            return self.list(params);
        }
        let allowed: &[&str] = if method == "job.events" {
            &["jobId", "pageSize", "afterCursor"]
        } else if method == "job.timeline" {
            &["jobId", "pageSize", "cursor"]
        } else {
            &["jobId"]
        };
        if params.keys().any(|k| !allowed.contains(&k.as_str())) {
            return Err(failure("invalidInput", "Job read options are closed"));
        }
        let id = params
            .get("jobId")
            .and_then(Value::as_str)
            .filter(|s| identifier(s))
            .ok_or_else(|| failure("invalidInput", "An exact Job identity is required"))?;
        let record = self.read_snapshot(id)?;
        let result = match method {
            "job.events" => {
                let mut paging = params.clone();
                if let Some(value) = paging.remove("afterCursor") {
                    paging.insert("cursor".into(), value);
                }
                let (size, cursor) = pagination(&paging)?;
                crate::job_events::page(
                    &self.path.join("jobs").join(id),
                    id,
                    &format!("session-{id}"),
                    cursor,
                    size,
                )?
            }
            "job.status" => record.status(),
            "job.show" => record.show(),
            "job.timeline" => {
                let (size, cursor) = pagination(params)?;
                SnapshotPager::open(&self.path.join("cli-job-snapshots"))
                    .map_err(unreadable)?
                    .page_filtered(
                        method,
                        &json!({"jobId":id}),
                        "entryIndexAscPartIndexAsc",
                        size,
                        cursor,
                        || Ok(record.timeline_rows()),
                    )?
            }
            _ => return Err(failure("unknownMethod", "Not a Job read resource method")),
        };
        if serde_json::to_vec(&result).map_err(unreadable)?.len() > 4 * 1024 * 1024 {
            return Err(failure(
                "recordUnreadable",
                "The Job projection exceeds its response bound",
            ));
        }
        Ok(result)
    }

    fn list(&self, params: &Map<String, Value>) -> Result<Value, WireError> {
        if params.keys().any(|k| {
            ![
                "order",
                "includeCurrent",
                "includeTimeline",
                "pageSize",
                "cursor",
                "state",
                "operation",
                "target",
                "thread",
            ]
            .contains(&k.as_str())
        }) {
            return Err(failure("invalidInput", "Job list options are closed"));
        }
        let bool_value = |key| -> Result<bool, WireError> {
            params.get(key).map_or(Ok(false), |v| {
                v.as_bool().ok_or_else(|| {
                    failure("invalidInput", "Job list projection flags must be boolean")
                })
            })
        };
        let current = bool_value("includeCurrent")?;
        let timeline = bool_value("includeTimeline")?;
        let order = params
            .get("order")
            .map_or(Some("createdAtDescJobIdAsc"), Value::as_str)
            .filter(|s| ["createdAtDescJobIdAsc", "createdAtAscJobIdAsc"].contains(s))
            .ok_or_else(|| failure("invalidInput", "The Job order is not published"))?;
        let mut filters = json!({"includeCurrent":current, "includeTimeline":timeline});
        for key in ["state", "operation", "target", "thread"] {
            if let Some(value) = params.get(key) {
                let text = value
                    .as_str()
                    .filter(|s| !s.is_empty() && s.len() <= 256 && !s.chars().any(char::is_control))
                    .ok_or_else(|| {
                        failure("invalidInput", "Job filters require bounded strings")
                    })?;
                if key == "state" && !STATES.contains(&text) {
                    return Err(failure("invalidInput", "The Job state is not published"));
                }
                filters[key] = value.clone();
            }
        }
        let (size, cursor) = pagination(params)?;
        // The repository hands the rows over in the list's order, creation
        // time and then identity, so each history row goes to the snapshot as
        // it is projected, and no list of them all is held.
        let descending = order == "createdAtDescJobIdAsc";
        SnapshotPager::open(&self.path.join("cli-job-snapshots"))
            .map_err(unreadable)?
            .page_streamed("job.list", &filters, order, size, cursor, |emit| {
                // A typed record refusal is the list's answer once the
                // repository has validated every source row in its complete
                // snapshot: the refusal of the first such record in creation
                // order, however the rows are handed over.
                let mut refused: Option<(String, String, WireError)> = None;
                self.repository
                    .map_rows_ordered(None, descending, |row| {
                        let projected = (|| -> Result<_, WireError> {
                            let record = JobRecord::from_row(&row)?;
                            let value = record.history(timeline);
                            if [
                                ("state", "state"),
                                ("operation", "operation"),
                                ("target", "targetId"),
                                ("thread", "threadId"),
                            ]
                            .iter()
                            .any(|(filter, field)| {
                                filters
                                    .get(*filter)
                                    .is_some_and(|expected| expected != &value[*field])
                            }) {
                                return Ok(None);
                            }
                            Ok(Some(value))
                        })();
                        match projected {
                            Ok(Some(value)) => emit(value),
                            Ok(None) => {}
                            Err(error) => {
                                if refused.as_ref().is_none_or(|(key, id, _)| {
                                    (&row.order_key, &row.id) < (key, id)
                                }) {
                                    refused = Some((row.order_key, row.id, error));
                                }
                            }
                        }
                        Ok(())
                    })
                    .map_err(unreadable)?;
                refused.map_or(Ok(()), |(_, _, error)| Err(error))
            })
    }
}
fn pagination(params: &Map<String, Value>) -> Result<(usize, Option<&str>), WireError> {
    let size = params
        .get("pageSize")
        .map_or(Some(100), Value::as_u64)
        .filter(|n| (1..=1000).contains(n))
        .ok_or_else(|| failure("invalidInput", "pageSize must be between 1 and 1000"))?
        as usize;
    let cursor = match params.get("cursor") {
        None => None,
        Some(Value::String(s)) if !s.is_empty() && s.len() <= 2048 => Some(s.as_str()),
        _ => return Err(failure("invalidCursor", "The Job cursor is malformed")),
    };
    Ok((size, cursor))
}
