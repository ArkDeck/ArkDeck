//! Runtime-owned Job discovery. A read-only SQLite snapshot supplies Job
//! identity and state; presentation cursors retain immutable query results.
use crate::job_record::{JobRecord, STATES, failure, unreadable};
use crate::job_repository::{JobRepository, identifier};
use crate::snapshot_pager::SnapshotPager;
use arkdeck_contract::WireError;
use arkdeck_platform::HostDirectory;
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
impl JobStore {
    pub fn open(path: &Path) -> io::Result<Self> {
        let root = HostDirectory::open(path)?;
        let repository = JobRepository::open(path)?;
        root.private_child("cli-job-snapshots")?;
        Ok(Self {
            repository,
            path: path.into(),
            root,
            activity: std::sync::Mutex::new(()),
        })
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
        let mut active = std::collections::BTreeSet::new();
        for row in self.repository.rows(None).map_err(unreadable)? {
            let record = JobRecord::from_row(&row)?;
            if record.requires_session_retention() {
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
        self.repository
            .rows(Some(id))
            .map_err(unreadable)?
            .first()
            .ok_or_else(|| failure("notFound", "The referenced Job does not exist"))
            .and_then(JobRecord::from_row)
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
