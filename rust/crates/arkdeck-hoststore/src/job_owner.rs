//! Runtime-owned Job discovery. A read-only SQLite snapshot supplies Job
//! identity and state; presentation cursors retain immutable query results.
use crate::job_record::{JobRecord, STATES, digest, failure, unreadable};
use crate::job_repository::{
    AdmissionVerdict, JobRepository, JobWriteError, identifier, order_key,
};
use crate::snapshot_pager::SnapshotPager;
use arkdeck_contract::WireError;
use arkdeck_platform::{DocumentPublishError, HostDirectory};
use serde_json::{Map, Value, json};
use std::{
    io,
    path::{Path, PathBuf},
};

pub struct JobStore {
    repository: JobRepository,
    path: PathBuf,
    root: HostDirectory,
    activity: std::sync::Mutex<()>,
}
const RECORD_BOUND: usize = 16 * 1024 * 1024;

fn guard_unavailable() -> JobWriteError {
    JobWriteError::Refused(io::Error::other("The Job activity guard is unavailable"))
}

impl JobStore {
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
            })
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

    pub fn read_snapshot(&self, id: &str) -> Result<JobRecord, WireError> {
        if !identifier(id) {
            return Err(failure(
                "invalidInput",
                "An exact bounded Job identity is required",
            ));
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

    /// Whether the state root holds Swift's superseding recovery epochs,
    /// which this Runtime does not read yet.
    pub(crate) fn holds_recovery_epochs(&self) -> io::Result<bool> {
        match self
            .root
            .document_metadata("superseding-recovery-epochs.json")
        {
            Ok(_) => Ok(true),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error),
        }
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
        SnapshotPager::open(&self.path.join("cli-job-snapshots"))
            .map_err(unreadable)?
            .page_filtered("job.list", &filters, order, size, cursor, || {
                let mut rows = Vec::new();
                for row in self.repository.rows(None).map_err(unreadable)? {
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
                        continue;
                    }
                    rows.push((row.order_key, row.id, value));
                }
                rows.sort_by(|a, b| {
                    (if order == "createdAtDescJobIdAsc" {
                        b.0.cmp(&a.0)
                    } else {
                        a.0.cmp(&b.0)
                    })
                    .then(a.1.cmp(&b.1))
                });
                Ok(rows.into_iter().map(|(_, _, value)| value).collect())
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
