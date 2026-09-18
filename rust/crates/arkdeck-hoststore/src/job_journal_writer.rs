//! Rust writer for one Job's current journal (TASK-XPA-014). Each append is a
//! canonical record checked by the closed per-event decoder and the Swift
//! replay/append rules under the Job directory's manifest lock, and durable
//! before it returns. The writer holds no Job authority of its own: callers
//! decide what to record, and nothing here dispatches, recovers or replays.
use crate::job_journal::JournalEvent;
use crate::job_journal_replay::{ReplayFacts, ReplayState};
use arkdeck_platform::{HostJournalAppender, JournalAppendError, JournalWritePoint};
use serde_json::Value;
use std::{fmt, io, path::Path};

#[derive(Debug)]
pub enum JournalWriteError {
    /// The journal or the proposed record breaks the closed format or its
    /// replay rules. Nothing was written.
    Invalid(String),
    /// Nothing was written: lock, identity, terminal Manifest or I/O refusal.
    Refused(io::Error),
    /// A write began and its durable result is unproven. The writer is
    /// poisoned; a new open replays and repairs before anything else.
    OutcomeUnknown(io::Error),
}
impl fmt::Display for JournalWriteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid(message) => write!(f, "journal record refused: {message}"),
            Self::Refused(error) => write!(f, "journal append refused before writing: {error}"),
            Self::OutcomeUnknown(error) => write!(f, "journal append outcome unknown: {error}"),
        }
    }
}
impl std::error::Error for JournalWriteError {}

/// Carries a replay-rule refusal through the platform appender's I/O errors.
#[derive(Debug)]
struct Violation(String);
impl fmt::Display for Violation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for Violation {}
fn violation(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, Violation(message.into()))
}
fn classify(error: io::Error) -> JournalWriteError {
    match error
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<Violation>())
    {
        Some(Violation(message)) => JournalWriteError::Invalid(message.clone()),
        None => JournalWriteError::Refused(error),
    }
}

pub struct JournalWriter {
    appender: HostJournalAppender,
    state: ReplayState,
}

impl JournalWriter {
    /// Opens `journal.jsonl` in an existing Job directory (creating it only
    /// when `create` is set). A torn tail is cut back to the last complete
    /// record only before terminal publication and behind a durable jobCreated
    /// (Swift `FileDurableJournal.init`); any other replay failure refuses.
    pub fn open(job_directory: &Path, create: bool) -> Result<Self, JournalWriteError> {
        let (appender, bytes) =
            HostJournalAppender::open(job_directory, create, |bytes, terminal| {
                let replay = ReplayState::replay(bytes).map_err(violation)?;
                if !replay.torn {
                    return Ok(None);
                }
                if terminal {
                    return Err(violation(
                        "cannot repair a torn journal after terminal Manifest publication",
                    ));
                }
                if replay.state.event_count() == 0 {
                    return Err(violation(
                        "cannot repair a torn journal without a durable jobCreated record",
                    ));
                }
                Ok(Some(replay.durable_length as u64))
            })
            .map_err(classify)?;
        let replay = ReplayState::replay(&bytes)
            .map_err(|message| JournalWriteError::Invalid(message.into()))?;
        if replay.torn {
            return Err(JournalWriteError::Invalid(
                "the journal tail is torn".into(),
            ));
        }
        Ok(Self {
            appender,
            state: replay.state,
        })
    }

    pub fn facts(&self) -> ReplayFacts {
        self.state.facts(false)
    }

    pub fn append(&mut self, event: &Value) -> Result<(), JournalWriteError> {
        self.append_with_checkpoint(event, |_| {})
    }

    /// As `append`; `checkpoint` observes the write points for crash tests.
    pub fn append_with_checkpoint(
        &mut self,
        event: &Value,
        checkpoint: impl Fn(JournalWritePoint),
    ) -> Result<(), JournalWriteError> {
        let mut record = crate::session_json::encode(event)
            .map_err(|_| JournalWriteError::Invalid("the record is not canonical JSON".into()))?;
        let decoded = JournalEvent::decode(&record).map_err(|_| {
            JournalWriteError::Invalid("the record violates the closed journal format".into())
        })?;
        record.push(b'\n');
        let Self { appender, state } = self;
        let mut rebuilt = None;
        let result = appender.append_with_checkpoint(
            &record,
            |snapshot| {
                let current = match snapshot {
                    None => &*state,
                    Some(bytes) => {
                        let replay = ReplayState::replay(bytes).map_err(violation)?;
                        if replay.torn {
                            return Err(violation("cannot append after a torn tail"));
                        }
                        &*rebuilt.insert(replay.state)
                    }
                };
                current.validate(&decoded).map_err(violation)
            },
            checkpoint,
        );
        // Another writer changed the file: the rebuilt replay is now current,
        // whether or not this record was accepted.
        if let Some(fresh) = rebuilt {
            *state = fresh;
        }
        match result {
            Ok(()) => {
                state.accept(&decoded);
                Ok(())
            }
            Err(JournalAppendError::Refused(error)) => Err(classify(error)),
            Err(JournalAppendError::OutcomeUnknown(error)) => {
                Err(JournalWriteError::OutcomeUnknown(error))
            }
        }
    }
}

/// Inspect an existing journal without acquiring write authority or repairing
/// a torn tail. The caller must quiesce the owner for a terminal audit.
pub fn inspect_journal(job_directory: &Path) -> Result<ReplayFacts, JournalWriteError> {
    let root =
        arkdeck_platform::HostDirectory::open(job_directory).map_err(JournalWriteError::Refused)?;
    let bytes = root
        .read("journal.jsonl", 64 * 1024 * 1024)
        .map_err(JournalWriteError::Refused)?;
    let replay = ReplayState::replay(&bytes)
        .map_err(|message| JournalWriteError::Invalid(message.into()))?;
    Ok(replay.state.facts(replay.torn))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::job_journal_events::{self as events, Envelope, Target};
    use serde_json::json;
    use std::{
        fs,
        os::unix::fs::DirBuilderExt,
        path::{Path, PathBuf},
    };

    const SESSION: &str = "session-rust-writer";
    const JOB: &str = "job-rust-writer";
    const SCENARIOS: [&str; 4] = ["succeeded", "unknown", "compensation", "plan-only"];

    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("journal-writer-{nonce:032x}"));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            Self(path)
        }
        fn with(name: &str) -> Self {
            let root = Self::new();
            fs::write(root.journal(), fixture(&format!("{name}.jsonl"))).unwrap();
            root
        }
        fn journal(&self) -> PathBuf {
            self.0.join("journal.jsonl")
        }
        fn bytes(&self) -> Vec<u8> {
            fs::read(self.journal()).unwrap()
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn fixture(name: &str) -> Vec<u8> {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/journal-writer")
            .join(name);
        fs::read(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
    }
    fn facts(name: &str) -> ReplayFacts {
        serde_json::from_slice(&fixture(&format!("{name}.replay.json"))).unwrap()
    }

    fn at(sequence: i64) -> Envelope {
        Envelope {
            event_id: format!("evt-{sequence:02}"),
            sequence,
            session_id: SESSION.into(),
            job_id: JOB.into(),
            timestamp: format!("2026-09-13T00:00:{sequence:02}Z"),
        }
    }
    fn host() -> Target {
        Target {
            scope: "host".into(),
            target_id: "host-1".into(),
            connect_key: None,
            identity_snapshot_hash: None,
        }
    }
    fn device() -> Target {
        Target {
            scope: "device".into(),
            target_id: "TGT-fixture".into(),
            connect_key: Some("fixture-only".into()),
            identity_snapshot_hash: Some("b".repeat(64)),
        }
    }
    fn probe_step() -> Value {
        json!({"id":"probe-host-tool", "kind":"probeHostTool", "effect":"hostOnly",
            "cancellation":"immediate", "bindingRequirement":"none",
            "arguments":{"toolIdentity":"hdc", "candidatePath":"/usr/bin/true"},
            "compensationDescriptors":[]})
    }
    fn capture_step(id: &str, artifact: &str, compensations: Vec<Value>) -> Value {
        json!({"id":id, "kind":"captureRemoteStdout", "effect":"readOnly",
            "cancellation":"immediate", "bindingRequirement":"confirmedDevice",
            "arguments":{"catalogId":"arkui-ui-dump", "actionId":"nodeSummary",
                "parameters":{}, "artifactId":artifact},
            "compensationDescriptors":compensations})
    }
    fn finalize_step() -> Value {
        json!({"id":"finalize-session", "kind":"finalizeSession", "effect":"hostOnly",
            "cancellation":"atSafeBoundary", "bindingRequirement":"none",
            "arguments":{"sessionId":SESSION, "publicationPolicy":"atomicAfterValidation"},
            "compensationDescriptors":[]})
    }
    fn reboot_step() -> Value {
        json!({"id":"reboot-device", "kind":"rebootDevice", "effect":"deviceMutation",
            "cancellation":"atSafeBoundary", "bindingRequirement":"confirmedDevice",
            "arguments":{"targetMode":"normal", "reason":"fixture"},
            "compensationDescriptors":[]})
    }
    fn stop_descriptor() -> Value {
        let arguments = json!({"captureStepId":"capture-trace", "stopPolicy":"safe"});
        let hash = arkdeck_contract::sha256_hex(&crate::session_json::encode(&arguments).unwrap());
        json!({"id":"stop-capture", "kind":"stopRemoteCapture", "effect":"deviceMutation",
            "cancellation":"atSafeBoundary", "bindingRequirement":"confirmedDevice",
            "trigger":"onFailure", "arguments":arguments, "argumentsHash":hash})
    }

    /// The shared oracle's scenarios; Swift builds the same records in
    /// `JournalRustWriterParityContractTests`.
    fn scenario(name: &str) -> Vec<Value> {
        match name {
            "succeeded" => vec![
                events::job_created(&at(0), "execute", "standardAgent", "CORE-3.0.0"),
                events::state_transition(&at(1), "queued", "preflight", "admitted", None),
                events::step_intent(&at(2), &probe_step(), &host(), 1, None).unwrap(),
                events::step_outcome(
                    &at(3),
                    "probe-host-tool",
                    1,
                    "evt-02",
                    "succeeded",
                    "confirmed",
                    None,
                    None,
                ),
                events::state_transition(&at(4), "preflight", "running", "preflightComplete", None),
                events::step_intent(
                    &at(5),
                    &capture_step("capture-ui-dump", "ui-dump", vec![]),
                    &device(),
                    1,
                    Some(1),
                )
                .unwrap(),
                events::step_outcome(
                    &at(6),
                    "capture-ui-dump",
                    1,
                    "evt-05",
                    "succeeded",
                    "confirmed",
                    Some("captured"),
                    Some("UI dump captured"),
                ),
                events::state_transition(&at(7), "running", "finalizing", "stepsComplete", None),
                events::step_intent(&at(8), &finalize_step(), &host(), 1, None).unwrap(),
                events::step_outcome(
                    &at(9),
                    "finalize-session",
                    1,
                    "evt-08",
                    "succeeded",
                    "confirmed",
                    None,
                    None,
                ),
                events::state_transition(&at(10), "finalizing", "succeeded", "completed", None),
            ],
            "unknown" => vec![
                events::job_created(&at(0), "execute", "standardAgent", "CORE-3.0.0"),
                events::state_transition(&at(1), "queued", "preflight", "admitted", None),
                events::state_transition(&at(2), "preflight", "running", "preflightComplete", None),
                events::step_intent(&at(3), &reboot_step(), &device(), 1, Some(1)).unwrap(),
                events::step_outcome(
                    &at(4),
                    "reboot-device",
                    1,
                    "evt-03",
                    "failed",
                    "outcomeUnknown",
                    Some("transportLost"),
                    Some("reply lost after dispatch"),
                ),
                events::state_transition(
                    &at(5),
                    "running",
                    "waitingForRecovery",
                    "outcomeUnknown",
                    Some("evt-04"),
                ),
                events::state_transition(
                    &at(6),
                    "waitingForRecovery",
                    "reconciling",
                    "startupReconcile",
                    None,
                ),
                events::reconcile_started(&at(7), "recovery-1", "waitingForRecovery", 6, "startup"),
                events::reconcile_outcome(
                    &at(8),
                    None,
                    "recovery-1",
                    "waitingForRecovery",
                    "waitingForRecovery",
                    "outcomeUnknown",
                    false,
                    &["readbackUnavailable"],
                ),
                events::state_transition(
                    &at(9),
                    "reconciling",
                    "waitingForRecovery",
                    "reconcileUnproven",
                    Some("evt-08"),
                ),
            ],
            "compensation" => vec![
                events::job_created(&at(0), "execute", "standardAgent", "CORE-3.0.0"),
                events::state_transition(&at(1), "queued", "preflight", "admitted", None),
                events::state_transition(&at(2), "preflight", "running", "preflightComplete", None),
                events::step_intent(
                    &at(3),
                    &capture_step("capture-trace", "trace-dump", vec![stop_descriptor()]),
                    &device(),
                    1,
                    Some(1),
                )
                .unwrap(),
                events::step_outcome(
                    &at(4),
                    "capture-trace",
                    1,
                    "evt-03",
                    "succeeded",
                    "confirmed",
                    None,
                    None,
                ),
                events::state_transition(&at(5), "running", "finalizing", "laterStepFailed", None),
                events::compensation_intent(
                    &at(6),
                    "capture-trace",
                    &stop_descriptor(),
                    &device(),
                    1,
                    Some(1),
                )
                .unwrap(),
                events::compensation_outcome(
                    &at(7),
                    "capture-trace",
                    "stop-capture",
                    1,
                    "evt-06",
                    "succeeded",
                    "confirmed",
                    None,
                    None,
                ),
                events::state_transition(&at(8), "finalizing", "failed", "compensated", None),
            ],
            "plan-only" => vec![
                events::job_created(&at(0), "planOnly", "standardAgent", "CORE-3.0.0"),
                events::state_transition(&at(1), "queued", "preflight", "admitted", None),
                events::state_transition(&at(2), "preflight", "planning", "planOnly", None),
                events::state_transition(
                    &at(3),
                    "planning",
                    "finalizing",
                    "planMaterialized",
                    None,
                ),
                events::state_transition(&at(4), "finalizing", "planned", "planned", None),
            ],
            _ => unreachable!(),
        }
    }
    fn continuation(name: &str) -> Value {
        let manifest = "c".repeat(64);
        match name {
            "succeeded" => events::finalized(&at(11), "succeeded", &manifest, "confirmed"),
            "unknown" => events::state_transition(
                &at(10),
                "waitingForRecovery",
                "reconciling",
                "manualReconcile",
                None,
            ),
            "compensation" => events::finalized(&at(9), "failed", &manifest, "confirmed"),
            "plan-only" => events::finalized(&at(5), "planned", &manifest, "confirmed"),
            _ => unreachable!(),
        }
    }

    #[test]
    fn each_scenario_writes_the_shared_oracle_bytes_and_facts() {
        for name in SCENARIOS {
            let root = Root::new();
            let mut writer = JournalWriter::open(&root.0, true).unwrap();
            for event in scenario(name) {
                writer.append(&event).unwrap();
            }
            let expected = fixture(&format!("{name}.jsonl"));
            assert_eq!(
                String::from_utf8(root.bytes()).unwrap(),
                String::from_utf8(expected.clone()).unwrap(),
                "{name}"
            );
            assert_eq!(writer.facts(), facts(name), "{name}");
            assert_eq!(
                ReplayState::replay(&expected).unwrap().state.facts(false),
                facts(name),
                "{name}"
            );
        }
    }

    #[test]
    fn each_oracle_reopens_continues_and_survives_restart() {
        for name in SCENARIOS {
            let root = Root::with(name);
            let mut writer = JournalWriter::open(&root.0, false).unwrap();
            assert_eq!(writer.facts(), facts(name), "{name}");
            writer.append(&continuation(name)).unwrap();
            drop(writer);
            let reopened = JournalWriter::open(&root.0, false).unwrap();
            assert_eq!(
                reopened.facts().event_count,
                facts(name).event_count + 1,
                "{name}"
            );
            let bytes = root.bytes();
            let tail = bytes[..bytes.len() - 1]
                .rsplit(|b| *b == b'\n')
                .next()
                .unwrap();
            assert_eq!(
                JournalEvent::decode(tail).unwrap().kind(),
                continuation(name)["kind"].as_str().unwrap()
            );
        }
    }

    #[test]
    fn a_torn_tail_is_cut_back_only_behind_a_durable_job_created() {
        let torn = b"{\"schemaVersion\":\"1.0.0\",\"eventId\":\"evt-";
        let root = Root::with("unknown");
        let golden = root.bytes();
        fs::write(root.journal(), [golden.as_slice(), torn].concat()).unwrap();
        let writer = JournalWriter::open(&root.0, false).unwrap();
        assert_eq!(root.bytes(), golden);
        assert_eq!(writer.facts(), facts("unknown"));

        let lone = Root::new();
        fs::write(lone.journal(), torn).unwrap();
        assert!(matches!(
            JournalWriter::open(&lone.0, false),
            Err(JournalWriteError::Invalid(_))
        ));
        assert_eq!(lone.bytes(), torn);

        let published = Root::with("succeeded");
        let golden = published.bytes();
        fs::write(published.journal(), [golden.as_slice(), torn].concat()).unwrap();
        fs::write(published.0.join("manifest.json"), b"{}").unwrap();
        assert!(JournalWriter::open(&published.0, false).is_err());
        assert_eq!(published.bytes(), [golden.as_slice(), torn].concat());
    }

    #[test]
    fn records_breaking_replay_rules_are_refused_before_any_byte() {
        let root = Root::with("unknown");
        let golden = root.bytes();
        let mut writer = JournalWriter::open(&root.0, false).unwrap();
        let mut duplicate = continuation("unknown");
        duplicate["eventId"] = json!("evt-09");
        let mut gap = continuation("unknown");
        gap["sequence"] = json!(11);
        let mut extra = continuation("unknown");
        extra["payload"]["future"] = json!(true);
        let orphan = events::step_outcome(
            &at(10),
            "reboot-device",
            1,
            "evt-99",
            "succeeded",
            "confirmed",
            None,
            None,
        );
        let blocked = events::step_intent(&at(10), &probe_step(), &host(), 1, None).unwrap();
        let illegal =
            events::state_transition(&at(10), "waitingForRecovery", "running", "resume", None);
        for refused in [duplicate, gap, extra, orphan, blocked, illegal] {
            assert!(
                matches!(writer.append(&refused), Err(JournalWriteError::Invalid(_))),
                "{refused}"
            );
            assert_eq!(root.bytes(), golden);
        }
        writer.append(&continuation("unknown")).unwrap();

        let plan = Root::with("plan-only");
        let mut writer = JournalWriter::open(&plan.0, false).unwrap();
        let mutation = events::step_intent(&at(5), &reboot_step(), &device(), 1, Some(1)).unwrap();
        assert!(matches!(
            writer.append(&mutation),
            Err(JournalWriteError::Invalid(_))
        ));
    }

    #[test]
    fn terminal_manifest_publication_ends_the_journal() {
        let root = Root::with("succeeded");
        let golden = root.bytes();
        let mut writer = JournalWriter::open(&root.0, false).unwrap();
        fs::write(root.0.join("manifest.json"), b"{}").unwrap();
        assert!(matches!(
            writer.append(&continuation("succeeded")),
            Err(JournalWriteError::Refused(_))
        ));
        assert_eq!(root.bytes(), golden);
        let empty = Root::new();
        fs::write(empty.0.join("manifest.json"), b"{}").unwrap();
        assert!(JournalWriter::open(&empty.0, true).is_err());
        assert!(!empty.journal().exists());
    }

    #[test]
    fn a_replaced_journal_inode_is_refused() {
        let root = Root::with("succeeded");
        let golden = root.bytes();
        let mut writer = JournalWriter::open(&root.0, false).unwrap();
        fs::rename(root.journal(), root.0.join("journal.retained")).unwrap();
        fs::write(root.journal(), &golden).unwrap();
        assert!(matches!(
            writer.append(&continuation("succeeded")),
            Err(JournalWriteError::Refused(_))
        ));
        assert_eq!(root.bytes(), golden);
        assert_eq!(fs::read(root.0.join("journal.retained")).unwrap(), golden);
    }

    #[test]
    fn another_writer_forces_a_full_replay_before_the_next_append() {
        let root = Root::with("unknown");
        let mut first = JournalWriter::open(&root.0, false).unwrap();
        let mut second = JournalWriter::open(&root.0, false).unwrap();
        second.append(&continuation("unknown")).unwrap();
        // The first writer's cached sequence is stale; the full replay refuses it.
        assert!(matches!(
            first.append(&continuation("unknown")),
            Err(JournalWriteError::Invalid(_))
        ));
        let next =
            events::reconcile_started(&at(11), "recovery-2", "waitingForRecovery", 10, "manual");
        first.append(&next).unwrap();
        assert_eq!(first.facts().event_count, facts("unknown").event_count + 2);
    }

    #[test]
    fn a_held_manifest_lock_is_awaited() {
        let root = Root::with("succeeded");
        let mut writer = JournalWriter::open(&root.0, false).unwrap();
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(root.0.join(".manifest.lock"))
            .unwrap();
        lock.try_lock().unwrap();
        let holder = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(300));
            lock.unlock().unwrap();
        });
        writer.append(&continuation("succeeded")).unwrap();
        holder.join().unwrap();
        assert!(writer.facts().finalized);
    }
}
