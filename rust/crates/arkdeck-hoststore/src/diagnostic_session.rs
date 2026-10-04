//! Bounded host annotations and stop signalling for one admitted Diagnostic
//! Session. This file is not authority, a device receipt or a replay cursor.
//! A persisted document without its process-local owner cannot accept input.
use super::JobStore;
use crate::job_record::{JobRecord, failure, terminal};
use crate::job_repository::identifier;
use arkdeck_contract::{WireError, strict_json};
use arkdeck_platform::HostDirectory;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub(crate) const OPERATION: &str = "capture.diagnostic-session@1";
const DOCUMENT: &str = "diagnostic-control.json";
const BYTE_LIMIT: usize = 128 * 1024;

#[path = "diagnostic_clock.rs"]
mod clock_observation;
use clock_observation::ClockObservation;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Marker {
    pub marker_id: String,
    #[serde(rename = "atHostUTC")]
    pub at_host_utc: String,
    pub offset_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Document {
    schema_version: String,
    job_id: String,
    target_id: String,
    binding_revision: i64,
    maximum_seconds: u64,
    maximum_markers: usize,
    phase: String,
    stop_requested: bool,
    #[serde(rename = "armedAtHostUTC")]
    armed_at_host_utc: Option<String>,
    #[serde(rename = "endedAtHostUTC")]
    ended_at_host_utc: Option<String>,
    elapsed_ms: u64,
    pub markers: Vec<Marker>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clock_observation: Option<ClockObservation>,
}

fn unavailable() -> WireError {
    failure(
        "recordUnreadable",
        "the Diagnostic Session control record is unavailable",
    )
}

fn clock() -> Result<String, WireError> {
    crate::job_run::runtime_precise_now().ok_or_else(unavailable)
}

fn label_valid(label: &str) -> bool {
    (1..=64).contains(&label.len())
        && label
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b" ._-".contains(&byte))
}

impl Document {
    fn new(record: &JobRecord) -> Result<Self, WireError> {
        let inputs = &record.request["inputs"];
        let maximum_seconds = inputs["durationSeconds"]
            .as_u64()
            .filter(|seconds| (1..=120).contains(seconds))
            .ok_or_else(unavailable)?;
        let maximum_markers = inputs
            .get("maximumMarkers")
            .map_or(Some(50), Value::as_u64)
            .filter(|count| (1..=200).contains(count))
            .ok_or_else(unavailable)? as usize;
        Ok(Self {
            schema_version: "1.0.0".into(),
            job_id: record.job_id.clone(),
            target_id: record.request["target"]["targetId"]
                .as_str()
                .filter(|id| identifier(id))
                .ok_or_else(unavailable)?
                .into(),
            binding_revision: record.request["target"]["expectedBindingRevision"]
                .as_i64()
                .filter(|revision| *revision >= 0)
                .ok_or_else(unavailable)?,
            maximum_seconds,
            maximum_markers,
            phase: "preparing".into(),
            stop_requested: false,
            armed_at_host_utc: None,
            ended_at_host_utc: None,
            elapsed_ms: 0,
            markers: Vec::new(),
            clock_observation: None,
        })
    }

    fn validate(&self, record: &JobRecord) -> Result<(), WireError> {
        let expected = Self::new(record)?;
        let mut ids = std::collections::BTreeSet::new();
        let timestamp = |value: &str| crate::session_time::session_timestamp(value).is_some();
        if self.schema_version != "1.0.0"
            || self.job_id != expected.job_id
            || self.target_id != expected.target_id
            || self.binding_revision != expected.binding_revision
            || self.maximum_seconds != expected.maximum_seconds
            || self.maximum_markers != expected.maximum_markers
            || !["preparing", "recording", "finalizing"].contains(&self.phase.as_str())
            || self
                .clock_observation
                .as_ref()
                .is_some_and(|sample| !sample.valid_for(&self.job_id))
            || self.markers.len() > self.maximum_markers
            || self.elapsed_ms > self.maximum_seconds * 1_000
            || self
                .armed_at_host_utc
                .as_deref()
                .is_some_and(|at| !timestamp(at))
            || self
                .ended_at_host_utc
                .as_deref()
                .is_some_and(|at| !timestamp(at))
            || self.markers.iter().any(|mark| {
                !identifier(&mark.marker_id)
                    || !ids.insert(&mark.marker_id)
                    || !timestamp(&mark.at_host_utc)
                    || mark.offset_ms > self.maximum_seconds * 1_000
                    || mark
                        .label
                        .as_deref()
                        .is_some_and(|label| !label_valid(label))
            })
        {
            return Err(unavailable());
        }
        Ok(())
    }

    pub(crate) fn value(&self) -> Result<Value, WireError> {
        serde_json::to_value(self).map_err(|_| unavailable())
    }
}

struct State {
    document: Document,
    started: Option<Instant>,
    anchor_started: Option<(Instant, String)>,
    faulted: bool,
    owner_alive: bool,
}

pub(crate) struct LiveSession {
    root: HostDirectory,
    path: PathBuf,
    state: Mutex<State>,
    changed: Condvar,
}

impl LiveSession {
    fn persist(&self, document: &Document) -> Result<(), WireError> {
        self.root
            .validate_path(&self.path)
            .map_err(|_| unavailable())?;
        let bytes = crate::session_json::encode(&document.value()?).map_err(|_| unavailable())?;
        self.root
            .publish_document(DOCUMENT, &bytes, BYTE_LIMIT)
            .map_err(|_| unavailable())?;
        self.root
            .validate_path(&self.path)
            .map_err(|_| unavailable())
    }

    fn replace(&self, state: &mut State, next: Document) -> Result<(), WireError> {
        if state.faulted || !state.owner_alive {
            return Err(unavailable());
        }
        if let Err(error) = self.persist(&next) {
            // An uncertain publication is not retried. Wake the waiter so it
            // cannot proceed to a device dump after losing its control state.
            state.faulted = true;
            self.changed.notify_all();
            return Err(error);
        }
        state.document = next;
        Ok(())
    }

    fn elapsed(state: &State) -> u64 {
        if state.document.phase == "finalizing" {
            return state.document.elapsed_ms;
        }
        state.started.map_or(state.document.elapsed_ms, |start| {
            (start.elapsed().as_millis() as u64).min(state.document.maximum_seconds * 1_000)
        })
    }

    fn status(&self) -> Result<Value, WireError> {
        let state = self.state.lock().map_err(|_| unavailable())?;
        if state.faulted || !state.owner_alive {
            return Err(unavailable());
        }
        let mut document = state.document.clone();
        document.elapsed_ms = Self::elapsed(&state);
        document.value()
    }

    fn stop(&self) -> Result<(), WireError> {
        let mut state = self.state.lock().map_err(|_| unavailable())?;
        if state.faulted || !state.owner_alive {
            return Err(unavailable());
        }
        if !state.document.stop_requested && state.document.phase != "finalizing" {
            let mut next = state.document.clone();
            next.stop_requested = true;
            self.replace(&mut state, next)?;
            self.changed.notify_all();
        }
        Ok(())
    }

    fn mark(&self, id: &str, label: Option<&str>) -> Result<(), WireError> {
        let mut state = self.state.lock().map_err(|_| unavailable())?;
        if state.faulted || !state.owner_alive {
            return Err(unavailable());
        }
        if let Some(previous) = state
            .document
            .markers
            .iter()
            .find(|mark| mark.marker_id == id)
        {
            return if previous.label.as_deref() == label {
                Ok(())
            } else {
                Err(failure(
                    "conflict",
                    "marker ID already names a different label",
                ))
            };
        }
        if state.document.phase != "recording"
            || state.document.stop_requested
            || state.started.is_none_or(|start| {
                start.elapsed() >= Duration::from_secs(state.document.maximum_seconds)
            })
        {
            return Err(failure(
                "conflict",
                "Diagnostic Session is not accepting markers",
            ));
        }
        if state.document.markers.len() >= state.document.maximum_markers {
            return Err(failure(
                "conflict",
                "Diagnostic Session marker budget is exhausted",
            ));
        }
        let mut next = state.document.clone();
        next.markers.push(Marker {
            marker_id: id.into(),
            at_host_utc: clock()?,
            offset_ms: Self::elapsed(&state),
            label: label.map(str::to_owned),
        });
        self.replace(&mut state, next)
    }

    pub(crate) fn before_anchor(&self) -> Result<(), String> {
        let action = || -> Result<(), WireError> {
            let mut state = self.state.lock().map_err(|_| unavailable())?;
            if state.faulted
                || !state.owner_alive
                || state.document.phase != "preparing"
                || state.anchor_started.is_some()
                || state.document.clock_observation.is_some()
            {
                return Err(unavailable());
            }
            let monotonic = Instant::now();
            state.anchor_started = Some((monotonic, clock()?));
            Ok(())
        };
        action().map_err(|error| error.message)
    }

    pub(crate) fn after_anchor(&self) -> Result<(), String> {
        let action = || -> Result<(), WireError> {
            let mut state = self.state.lock().map_err(|_| unavailable())?;
            if state.faulted || !state.owner_alive || state.document.phase != "preparing" {
                return Err(unavailable());
            }
            let (start, at) = state.anchor_started.take().ok_or_else(unavailable)?;
            let end = clock()?;
            let elapsed = u64::try_from(start.elapsed().as_nanos()).map_err(|_| unavailable())?;
            let mut next = state.document.clone();
            next.clock_observation = Some(
                ClockObservation::new(&next.job_id, at, end, elapsed).ok_or_else(unavailable)?,
            );
            self.replace(&mut state, next)
        };
        action().map_err(|error| error.message)
    }

    /// Called only after the provider verified the unique anchor. Readiness
    /// is durable before observers may see it. Stop and deadline freeze marks
    /// under the same mutex, so no annotation can sneak into finalization.
    pub(crate) fn wait(&self, maximum_seconds: u64) -> Result<(), String> {
        let run = || -> Result<(), WireError> {
            let mut state = self.state.lock().map_err(|_| unavailable())?;
            if state.faulted
                || !state.owner_alive
                || state.document.phase != "preparing"
                || state.document.maximum_seconds != maximum_seconds
            {
                return Err(unavailable());
            }
            let start = Instant::now();
            let mut next = state.document.clone();
            next.phase = "recording".into();
            next.armed_at_host_utc = Some(clock()?);
            self.replace(&mut state, next)?;
            state.started = Some(start);
            self.changed.notify_all();
            let maximum = Duration::from_secs(maximum_seconds);
            while !state.document.stop_requested && !state.faulted && state.owner_alive {
                let Some(remaining) = maximum.checked_sub(start.elapsed()) else {
                    break;
                };
                let (next_state, _) = self
                    .changed
                    .wait_timeout(state, remaining)
                    .map_err(|_| unavailable())?;
                state = next_state;
            }
            if state.faulted || !state.owner_alive {
                return Err(unavailable());
            }
            let mut next = state.document.clone();
            next.phase = "finalizing".into();
            next.elapsed_ms = Self::elapsed(&state);
            next.ended_at_host_utc = Some(clock()?);
            self.replace(&mut state, next)?;
            Ok(())
        };
        run().map_err(|error| error.message)
    }
}

#[cfg(test)]
#[path = "diagnostic_session_tests.rs"]
mod tests;

/// Removing the live handle closes mutation access even if unwinding leaves
/// a persisted recording phase. Its document cannot recreate this guard.
pub(crate) struct SessionGuard<'a> {
    jobs: &'a JobStore,
    id: String,
    pub session: Arc<LiveSession>,
}
impl Drop for SessionGuard<'_> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.session.state.lock() {
            state.owner_alive = false;
            self.session.changed.notify_all();
        }
        if let Ok(mut sessions) = self.jobs.diagnostic_sessions.lock() {
            sessions.remove(&self.id);
        }
    }
}

impl JobStore {
    pub(crate) fn begin_diagnostic_session(
        &self,
        record: &JobRecord,
    ) -> Result<SessionGuard<'_>, WireError> {
        if record.operation() != OPERATION || record.state != "running" {
            return Err(unavailable());
        }
        let mut sessions = self.diagnostic_sessions.lock().map_err(|_| unavailable())?;
        if sessions.contains_key(&record.job_id) {
            return Err(failure(
                "conflict",
                "Diagnostic Session already has an owner",
            ));
        }
        self.root
            .validate_path(&self.path)
            .map_err(|_| unavailable())?;
        let root = self
            .root
            .child("jobs")
            .and_then(|jobs| jobs.child(&record.job_id))
            .map_err(|_| unavailable())?;
        let document = Document::new(record)?;
        let bytes = crate::session_json::encode(&document.value()?).map_err(|_| unavailable())?;
        // Exclusive creation refuses any prior generation, including one
        // interrupted before the first device command. No implicit restart.
        root.create_document(DOCUMENT, &bytes)
            .map_err(|_| unavailable())?;
        let session = Arc::new(LiveSession {
            root,
            path: self.path.join("jobs").join(&record.job_id),
            state: Mutex::new(State {
                document,
                started: None,
                anchor_started: None,
                faulted: false,
                owner_alive: true,
            }),
            changed: Condvar::new(),
        });
        sessions.insert(record.job_id.clone(), Arc::clone(&session));
        Ok(SessionGuard {
            jobs: self,
            id: record.job_id.clone(),
            session,
        })
    }

    pub(crate) fn diagnostic_document(
        &self,
        record: &JobRecord,
    ) -> Result<Option<Document>, WireError> {
        if record.operation() != OPERATION {
            return Err(failure("invalidParams", "Job is not a Diagnostic Session"));
        }
        self.root
            .validate_path(&self.path)
            .map_err(|_| unavailable())?;
        let directory = self
            .root
            .child("jobs")
            .and_then(|jobs| jobs.child(&record.job_id))
            .map_err(|_| unavailable())?;
        let bytes = match directory.read(DOCUMENT, BYTE_LIMIT) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(unavailable()),
        };
        let value = strict_json(&bytes).map_err(|_| unavailable())?;
        let document: Document = serde_json::from_value(value).map_err(|_| unavailable())?;
        document.validate(record)?;
        Ok(Some(document))
    }

    /// Closed host-only controls. They never mutate a Job request, capability,
    /// trusted fact, remote path or device command, and never start a run.
    pub fn diagnostic_session_control(
        &self,
        method: &str,
        params: &Map<String, Value>,
    ) -> Result<Value, WireError> {
        let marking = method == "diagnostic.session.mark";
        if ![
            "diagnostic.session.status",
            "diagnostic.session.mark",
            "diagnostic.session.stop",
        ]
        .contains(&method)
            || params.keys().any(|key| {
                if marking {
                    !["jobId", "markerId", "label"].contains(&key.as_str())
                } else {
                    key != "jobId"
                }
            })
        {
            return Err(failure(
                "invalidParams",
                "Diagnostic Session requires closed typed parameters",
            ));
        }
        let id = params
            .get("jobId")
            .and_then(Value::as_str)
            .filter(|id| identifier(id))
            .ok_or_else(|| failure("invalidParams", "exact Job ID required"))?;
        let record = self.read_snapshot(id)?;
        if record.operation() != OPERATION {
            return Err(failure("invalidParams", "Job is not a Diagnostic Session"));
        }
        let live = self
            .diagnostic_sessions
            .lock()
            .map_err(|_| unavailable())?
            .get(id)
            .cloned();
        if marking {
            let marker_id = params
                .get("markerId")
                .and_then(Value::as_str)
                .filter(|id| identifier(id))
                .ok_or_else(|| failure("invalidParams", "bounded marker ID required"))?;
            let label = params.get("label").map(|value| value.as_str().filter(|label| label_valid(label))
                .ok_or_else(|| failure("invalidParams", "marker label must be 1...64 ASCII letters, digits, spaces, dots, underscores or hyphens")))
                .transpose()?;
            live.as_ref()
                .ok_or_else(|| {
                    failure("conflict", "Diagnostic Session has no live recording owner")
                })?
                .mark(marker_id, label)?;
        } else if method == "diagnostic.session.stop" {
            if let Some(live) = &live {
                live.stop()?;
            } else if !terminal(&record.state) {
                return Err(failure(
                    "conflict",
                    "Diagnostic Session has no live recording owner",
                ));
            }
        }
        let persisted = if live.is_none() {
            self.diagnostic_document(&record)?
        } else {
            None
        };
        let had_persisted_owner = persisted.is_some();
        let mut value = if let Some(live) = &live {
            live.status()?
        } else {
            persisted.unwrap_or(Document::new(&record)?).value()?
        };
        let phase = if record.outcome_unknown() || record.state == "waitingForRecovery" {
            "interrupted"
        } else if terminal(&record.state) {
            "closed"
        } else if live.is_none()
            && (value["phase"] == "recording"
                || (had_persisted_owner && value["phase"] == "preparing"))
        {
            "interrupted"
        } else {
            value["phase"].as_str().unwrap_or("interrupted")
        };
        value["state"] = json!(phase);
        value["jobState"] = json!(record.state);
        value["outcomeUnknown"] = json!(record.outcome_unknown());
        value["controlAvailable"] = json!(live.is_some());
        value
            .as_object_mut()
            .ok_or_else(unavailable)?
            .remove("phase");
        // Wire status is unchanged. The immutable capture artifacts carry
        // optional clock observations, never control or execution authority.
        value
            .as_object_mut()
            .ok_or_else(unavailable)?
            .remove("clockObservation");
        Ok(value)
    }
}
