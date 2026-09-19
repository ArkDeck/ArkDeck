//! The Jobs whose Artifacts the startup retention sweep keeps, from a complete
//! read-only census of the durable Job owner. Swift keeps the Jobs its
//! recovery found non-terminal and the records it quarantined; this census
//! keeps every Job it cannot prove settled: not terminal, of unknown outcome,
//! without its Job directory, whose on-disk record differs from its row, or
//! whose journal does not replay to that terminal state finalized, with no
//! torn tail, outstanding intent or unknown outcome. A Job directory no row
//! explains is kept too. Every kept Job's input leases are kept wherever they
//! live. A row the census cannot decode, or whose submission does not verify,
//! stops the sweep: its references are unknown. This grants no authority and
//! repairs nothing.
use super::*;
use crate::artifact_publication::RetentionKeep;
use std::collections::{BTreeMap, BTreeSet};

impl JobStore {
    /// Runs `action` with what the sweep keeps, holding the Job activity
    /// guard through both, so no Job changes state beside the sweep.
    pub(crate) fn with_retention_keep<R>(
        &self,
        action: impl FnOnce(RetentionKeep) -> R,
    ) -> Result<R, WireError> {
        let _guard = self.activity.lock().map_err(unreadable)?;
        self.root.validate_path(&self.path).map_err(unreadable)?;
        let rows = self.repository.rows(None).map_err(unreadable)?;
        let indexed: BTreeSet<_> = rows.iter().map(|row| row.id.clone()).collect();
        let mut keep = RetentionKeep::default();
        let mut directories = BTreeMap::new();
        match self.root.child("jobs") {
            Ok(jobs) => {
                for id in jobs.names(100_000).map_err(unreadable)? {
                    if !indexed.contains(&id) {
                        keep.jobs.insert(id);
                        continue;
                    }
                    match jobs.child(&id) {
                        Ok(directory) => {
                            directories.insert(id, directory);
                        }
                        Err(_) => {
                            keep.jobs.insert(id);
                        }
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(unreadable(error)),
        }
        for row in &rows {
            let record = JobRecord::from_row(row)?;
            if !record.verifies_submission(&row.request_hash) {
                return Err(unreadable(()));
            }
            if settled(&row.id, &record, directories.get(&row.id)) {
                continue;
            }
            keep.jobs.insert(row.id.clone());
            if let Some(inputs) = record.request.get("inputs") {
                keep.lease_all(inputs);
            }
        }
        Ok(action(keep))
    }
}

/// A terminal Job of known outcome whose on-disk record is its row's and
/// whose journal replays to that state, finalized and settled.
fn settled(id: &str, record: &JobRecord, directory: Option<&HostDirectory>) -> bool {
    if record.requires_session_retention() {
        return false;
    }
    let Some(directory) = directory else {
        return false;
    };
    let same_record = directory
        .read("job-record.json", RECORD_BOUND)
        .ok()
        .and_then(|bytes| JobRecord::decode(&bytes).ok())
        .and_then(|on_disk| Some(on_disk.value().ok()? == record.value().ok()?));
    if same_record != Some(true) {
        return false;
    }
    let Ok(journal) = directory.read("journal.jsonl", 64 * 1024 * 1024) else {
        return false;
    };
    for line in journal
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
    {
        match crate::job_journal::JournalEvent::decode(line) {
            Ok(event) if event.job_id() == id && event.session_id() == format!("session-{id}") => {}
            _ => return false,
        }
    }
    let Ok(replay) = crate::job_journal_replay::ReplayState::replay(&journal) else {
        return false;
    };
    let facts = replay.state.facts(replay.torn);
    !facts.has_torn_tail
        && facts.current_state.as_deref() == Some(&record.state)
        && facts.finalized
        && facts.outstanding_intents.is_empty()
        && facts.unknown_outcomes.is_empty()
        && !facts.requires_unknown_finalized_outcome
}
