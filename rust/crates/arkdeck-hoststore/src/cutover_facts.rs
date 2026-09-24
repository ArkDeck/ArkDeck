//! The state-root facts design §G.4's cutover preflight decides on
//! (`arkdeck_contract::cutover_preflight`, the shared table of #2026), read
//! without any owner of the state: every Job the index, `jobs/` or both name,
//! with the states its index row, record and journal give and whether that
//! journal is resolved; every agent execution; every capability use; and the
//! HDC tool selection pending in the bootstrap store, if one is (the
//! production composition refuses to start beside one).
//!
//! Nothing here takes an owner's lock, marks a lock document, or writes a
//! record, journal, ledger or index row. Every document is read whole —
//! records, checkpoints and indexes are published atomically, journals and
//! ledgers only appended — so the facts are safe to read beside a running
//! owner (the lock-free first pass) and exact once no Runtime holds the state
//! (the second pass, under the instance lock). The Job index is read through
//! the connection Swift's repository inspects with, so its only effects are
//! SQLite's own: beside a shared-memory index (a live or stopped Swift daemon
//! leaves one) a read-only connection reads through it and may record its
//! read mark there; without one, a connection that never writes opens the
//! database and, as every connection to it does under Apple's persistent
//! write-ahead log, leaves an empty log and a new index beside it with the
//! database's own mode. What cannot be read is named as unreadable, and the
//! cutover cannot be proved safe past it.
use arkdeck_contract::{CutoverExecution, CutoverJob, CutoverUse};
use arkdeck_platform::HostDirectory;
use std::collections::BTreeMap;
use std::io;
use std::path::Path;

/// A Job record that exists but does not decode: the table does not list
/// this state, so the Job blocks, named by it.
pub const UNREADABLE_RECORD: &str = "unreadableRecord";

/// A Job directory whose record, journal and index row give no state at all
/// (an admission a crash cut short, or a directory the owner did not write):
/// unlisted too, so it blocks, named by it.
pub const MISSING_RECORD: &str = "missingRecord";

/// The roots the facts are read from, as the production layout names them.
#[derive(Clone, Copy, Debug)]
pub struct CutoverRoots<'a> {
    /// The Job owner's root: `runtime-jobs.sqlite3` and `jobs/`.
    pub jobs: &'a Path,
    pub agent_executions: &'a Path,
    pub capabilities: &'a Path,
    /// The bootstrap registry holding the tool index.
    pub bootstrap: &'a Path,
}

/// One source the preflight could not read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UnreadableSource {
    pub source: String,
    pub reason: String,
}

/// Everything the cutover preflight decides on.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CutoverFacts {
    pub jobs: Vec<CutoverJob>,
    pub executions: Vec<CutoverExecution>,
    pub uses: Vec<CutoverUse>,
    /// The control action of a pending HDC tool selection.
    pub pending_tool_selection: Option<String>,
    pub unreadable: Vec<UnreadableSource>,
}

impl CutoverFacts {
    fn unreadable(&mut self, source: impl Into<String>, reason: impl Into<String>) {
        self.unreadable.push(UnreadableSource {
            source: source.into(),
            reason: reason.into(),
        });
    }
}

/// Reads the facts below `roots`. It never fails as a whole: each source it
/// cannot read is listed as unreadable beside what it could.
pub fn cutover_facts(roots: CutoverRoots<'_>) -> CutoverFacts {
    let mut facts = CutoverFacts::default();
    jobs(roots.jobs, &mut facts);
    match crate::AgentExecutionStore::cutover_executions(roots.agent_executions) {
        Ok(executions) => {
            facts.executions = executions
                .into_iter()
                .map(|(execution_id, state, job_id)| CutoverExecution {
                    execution_id,
                    state,
                    job_id,
                })
                .collect();
        }
        Err(reason) => facts.unreadable("agentExecutions", reason),
    }
    match crate::CapabilityStore::cutover_uses(roots.capabilities) {
        Ok(uses) => {
            facts.uses = uses
                .into_iter()
                .map(|(capability_id, use_ordinal, outcome, job_id)| CutoverUse {
                    capability_id,
                    use_ordinal,
                    outcome,
                    job_id,
                })
                .collect();
        }
        Err(error) => facts.unreadable("capabilities", error.swift()),
    }
    match crate::tool_selection_ledger::cutover_pending_selection(roots.bootstrap) {
        Ok(pending) => facts.pending_tool_selection = pending,
        Err(reason) => facts.unreadable("toolSelection", reason),
    }
    facts
}

fn job<'a>(jobs: &'a mut BTreeMap<String, CutoverJob>, id: &str) -> &'a mut CutoverJob {
    jobs.entry(id.to_owned()).or_insert_with(|| CutoverJob {
        job_id: id.to_owned(),
        states: Vec::new(),
        journal_unresolved: false,
    })
}

/// Every Job of the root, each with the states its index row, record and
/// journal give, in identity order.
fn jobs(root: &Path, facts: &mut CutoverFacts) {
    let mut jobs: BTreeMap<String, CutoverJob> = BTreeMap::new();
    let directory = match HostDirectory::open(root) {
        Ok(directory) => directory,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return,
        Err(error) => {
            facts.unreadable("jobs", error.to_string());
            return;
        }
    };
    match crate::job_repository::cutover_index_states(root) {
        Ok(rows) => {
            for (id, state) in rows {
                job(&mut jobs, &id).states.push(state);
            }
        }
        Err(error) => facts.unreadable("jobIndex", error.to_string()),
    }
    let jobs_directory = match directory.child("jobs") {
        Ok(child) => Some(child),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => {
            facts.unreadable("jobs", error.to_string());
            None
        }
    };
    if let Some(jobs_directory) = jobs_directory {
        match jobs_directory.names(1 << 20) {
            Err(error) => facts.unreadable("jobs", error.to_string()),
            Ok(mut names) => {
                names.sort();
                for name in names {
                    if !crate::job_repository::identifier(&name) {
                        continue;
                    }
                    // A plain file, whatever its mode, is no Job and is left
                    // to the snapshot; anything else named as a Job that
                    // cannot be opened as the owner's directory cannot be
                    // proved safe.
                    if matches!(
                        jobs_directory.kind_and_size(&name),
                        Ok((arkdeck_platform::HostEntryKind::Regular, _))
                    ) {
                        continue;
                    }
                    let entry = job(&mut jobs, &name);
                    let Ok(job_directory) = jobs_directory.child(&name) else {
                        entry.states.push(UNREADABLE_RECORD.into());
                        continue;
                    };
                    match job_directory.read("job-record.json", 16 * 1024 * 1024) {
                        Ok(bytes) => match crate::JobRecord::decode(&bytes) {
                            Ok(record) => entry.states.push(record.state),
                            Err(_) => entry.states.push(UNREADABLE_RECORD.into()),
                        },
                        Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                        Err(_) => entry.states.push(UNREADABLE_RECORD.into()),
                    }
                    match job_directory.read("journal.jsonl", 64 * 1024 * 1024) {
                        Ok(bytes) => match crate::job_journal_replay::ReplayState::replay(&bytes) {
                            Ok(replay) => {
                                let replayed = replay.state.facts(replay.torn);
                                if let Some(state) = replayed.current_state.clone() {
                                    entry.states.push(state);
                                }
                                entry.journal_unresolved = replayed.has_torn_tail
                                    || !replayed.outstanding_intents.is_empty()
                                    || !replayed.unknown_outcomes.is_empty();
                            }
                            // A journal that does not replay proves nothing
                            // resolved.
                            Err(_) => entry.journal_unresolved = true,
                        },
                        Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                        Err(_) => entry.journal_unresolved = true,
                    }
                    if entry.states.is_empty() {
                        entry.states.push(MISSING_RECORD.into());
                    }
                }
            }
        }
    }
    facts.jobs = jobs.into_values().collect();
}
