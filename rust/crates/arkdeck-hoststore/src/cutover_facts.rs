//! The state-root facts design §G.4's cutover preflight decides on
//! (`arkdeck_contract::cutover_preflight`, the shared table of #2026), read
//! without any owner of the state: every Job the index, `jobs/` or both name,
//! with the states its index row, record and journal give, whether that
//! journal is resolved and whether it awaits a Loader binding only Swift's
//! Runtime settles; every agent execution; every capability use; the HDC
//! tool selection pending in the bootstrap store, if one is (the production
//! composition refuses to start beside one); and the first refusal of the
//! continuity proof of the retained Sessions, which every device mutation of
//! the Runtime that carries the state over makes.
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
//!
//! The retained Sessions are scanned by the continuity proof itself
//! (`JobStore::require_retained_sessions`), whose failed publications are
//! read from this state root's Job store without opening it as an owner: an
//! owner would create and mark its lock document and create its snapshot
//! directory in the state it reads. Beside a running Swift daemon, a Session
//! that daemon is publishing in place can read as one a publication left
//! short; the held pass reads none.
use crate::job_journal_replay::ReplayFacts;
use crate::job_record::JobRecord;
use crate::job_repository::InspectedIndex;
use arkdeck_contract::{CutoverExecution, CutoverJob, CutoverUse, LoaderTransition, WireError};
use arkdeck_platform::HostDirectory;
use std::collections::{BTreeMap, BTreeSet};
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
    /// The Job owner's root: `runtime-jobs.sqlite3` and `jobs/`, beside the
    /// Session storage settings (`session-storage.json`), as the production
    /// composition keeps them in its state directory.
    pub jobs: &'a Path,
    pub agent_executions: &'a Path,
    pub capabilities: &'a Path,
    /// The bootstrap registry holding the tool index.
    pub bootstrap: &'a Path,
    /// The default Session root, the state directory's sibling `Sessions`.
    pub sessions: &'a Path,
}

/// One source the preflight could not read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UnreadableSource {
    pub source: String,
    pub reason: String,
}

/// The continuity proof's refusal of the retained Sessions under a Session
/// root, exactly as a device mutation's proof would answer it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RetainedSessionsRefusal {
    pub sessions_root: String,
    pub code: String,
    pub message: String,
}

/// Everything the cutover preflight decides on.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CutoverFacts {
    pub jobs: Vec<CutoverJob>,
    pub executions: Vec<CutoverExecution>,
    pub uses: Vec<CutoverUse>,
    /// The control action of a pending HDC tool selection.
    pub pending_tool_selection: Option<String>,
    /// The first refusal of the retained Sessions' continuity proof, over the
    /// default Session root and then the one the settings select.
    pub retained_sessions: Option<RetainedSessionsRefusal>,
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

/// The Job owner's root and its index, each where it could be opened.
#[derive(Default)]
struct JobRoot {
    directory: Option<HostDirectory>,
    index: Option<InspectedIndex>,
}

/// Reads the facts below `roots`. It never fails as a whole: each source it
/// cannot read is listed as unreadable beside what it could.
pub fn cutover_facts(roots: CutoverRoots<'_>) -> CutoverFacts {
    let mut facts = CutoverFacts::default();
    let store = jobs(roots.jobs, &mut facts);
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
    match arkdeck_bootstrap::cutover_pending_selection(roots.bootstrap) {
        Ok(pending) => facts.pending_tool_selection = pending,
        Err(reason) => facts.unreadable("toolSelection", reason),
    }
    retained_sessions(roots, &store, &mut facts);
    facts
}

fn job<'a>(jobs: &'a mut BTreeMap<String, CutoverJob>, id: &str) -> &'a mut CutoverJob {
    jobs.entry(id.to_owned()).or_insert_with(|| CutoverJob {
        job_id: id.to_owned(),
        states: Vec::new(),
        journal_unresolved: false,
        loader_transition: None,
    })
}

/// Every Job of the root, each with the states its index row, record and
/// journal give, in identity order; the root and its index are kept for the
/// retained Sessions' proof.
fn jobs(root: &Path, facts: &mut CutoverFacts) -> JobRoot {
    let mut jobs: BTreeMap<String, CutoverJob> = BTreeMap::new();
    let directory = match HostDirectory::open(root) {
        Ok(directory) => directory,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return JobRoot::default(),
        Err(error) => {
            facts.unreadable("jobs", error.to_string());
            return JobRoot::default();
        }
    };
    let index = match InspectedIndex::open(root) {
        Ok(index) => index,
        Err(error) => {
            facts.unreadable("jobIndex", error.to_string());
            None
        }
    };
    if let Some(index) = &index {
        match index.states() {
            Ok(rows) => {
                for (id, state) in rows {
                    job(&mut jobs, &id).states.push(state);
                }
            }
            Err(error) => facts.unreadable("jobIndex", error.to_string()),
        }
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
                    let mut record = None;
                    match job_directory.read("job-record.json", 16 * 1024 * 1024) {
                        Ok(bytes) => match JobRecord::decode(&bytes) {
                            Ok(decoded) => {
                                entry.states.push(decoded.state.clone());
                                record = Some(decoded);
                            }
                            Err(_) => entry.states.push(UNREADABLE_RECORD.into()),
                        },
                        Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                        Err(_) => entry.states.push(UNREADABLE_RECORD.into()),
                    }
                    let mut journal = None;
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
                                journal =
                                    Some((replayed, replay.state.holds_destructive_step_intent()));
                            }
                            // A journal that does not replay proves nothing
                            // resolved.
                            Err(_) => entry.journal_unresolved = true,
                        },
                        Err(error) if error.kind() == io::ErrorKind::NotFound => (),
                        Err(_) => entry.journal_unresolved = true,
                    }
                    // An ArkForge lane that prepared a daemon Job for it keeps
                    // its correlation beside the record; whatever is there,
                    // the lane's own plan held the Loader transition.
                    let lane_held = !matches!(
                        job_directory.kind_and_size(crate::job_owner::arkforge_job_state::FILE),
                        Err(error) if error.kind() == io::ErrorKind::NotFound
                    );
                    if !lane_held
                        && let (Some(record), Some((journal, destructive))) = (&record, &journal)
                    {
                        entry.loader_transition = loader_transition(record, journal, *destructive);
                    }
                    if entry.states.is_empty() {
                        entry.states.push(MISSING_RECORD.into());
                    }
                }
            }
        }
    }
    facts.jobs = jobs.into_values().collect();
    JobRoot {
        directory: Some(directory),
        index,
    }
}

/// Swift `RuntimeJobEngine.loaderTransitionAwaitingBinding` and
/// `pendingLoaderTransition` over one Job, for the Target and binding
/// revision its own request expects: a DAYU200 flash Job parked with an
/// unknown outcome at its enter-Loader intent (the record), whose journal,
/// whole and never destructive, holds that one intent outstanding and
/// nothing unknown, at the expected binding revision. Swift's
/// `settleLoaderTransitionAfterBinding` settles exactly such a Job once
/// `flash.bind-current-loader` binds that Target; this Runtime does not
/// (F7), so its binding would stay refused.
fn loader_transition(
    record: &JobRecord,
    journal: &ReplayFacts,
    destructive: bool,
) -> Option<LoaderTransition> {
    let (target_id, expected_binding_revision) =
        crate::job_owner::loader_transition_candidate(record)?;
    let [intent] = journal.outstanding_intents.as_slice() else {
        return None;
    };
    (!journal.has_torn_tail
        && journal.current_state.as_deref() == Some("waitingForRecovery")
        && journal.unknown_outcomes.is_empty()
        && record.recovery_intent() == Some(intent.event_id.as_str())
        && intent.step_id == "enter-loader-mode"
        && intent.attempt > 0
        && intent.effect == "deviceMutation"
        && intent.binding_revision == Some(expected_binding_revision)
        && !destructive)
        .then(|| LoaderTransition {
            target_id: target_id.to_owned(),
            expected_binding_revision,
        })
}

/// The continuity proof of the retained Sessions under `sessions_root`, as a
/// device mutation of the Runtime whose Job store is at `jobs` makes it
/// (`JobStore::require_retained_sessions`), read without any owner of that
/// store: the cutover preflight's scan of one Session root. A Job store or
/// index that cannot be opened accounts for no Session.
pub fn cutover_retained_sessions(jobs: &Path, sessions_root: &Path) -> Result<(), WireError> {
    let directory = HostDirectory::open(jobs).ok();
    let index = InspectedIndex::open(jobs).ok().flatten();
    crate::job_owner::require_retained_sessions_without_owner(
        directory.as_ref(),
        index.as_ref(),
        sessions_root,
    )
}

/// The continuity proof of the retained Sessions, over the Session roots a
/// device mutation's proof reads (`MutationAuthority::require_state`): the default
/// root and the one the storage settings select. The first refusal, in the
/// order that proof reads them, is kept; settings that cannot be read are
/// named, and the default root is still read.
fn retained_sessions(roots: CutoverRoots<'_>, store: &JobRoot, facts: &mut CutoverFacts) {
    let mut sessions = BTreeSet::from([roots.sessions.to_path_buf()]);
    match crate::session_owner::configured_root_without_owner(roots.jobs, roots.sessions) {
        Ok(configured) => {
            sessions.insert(configured);
        }
        Err(error) => facts.unreadable("sessionStorage", error.message),
    }
    for root in sessions {
        if let Err(refusal) = crate::job_owner::require_retained_sessions_without_owner(
            store.directory.as_ref(),
            store.index.as_ref(),
            &root,
        ) {
            facts.retained_sessions = Some(RetainedSessionsRefusal {
                sessions_root: root.to_string_lossy().into_owned(),
                code: refusal.code,
                message: refusal.message,
            });
            return;
        }
    }
}
