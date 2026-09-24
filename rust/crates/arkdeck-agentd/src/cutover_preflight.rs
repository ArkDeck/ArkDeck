//! `arkdeck-agentd --cutover-preflight [--hold-instance-lock]`: design §G.4's
//! M5 cutover preflight over the production layout, a one-shot read that
//! composes nothing (协调会话受托裁定 2026-09-24).
//!
//! It answers whether the account's state may be carried over to this
//! Runtime as it is. Every Job the index or `jobs/` names is classed by the
//! shared preflight table (#2026) from the states its index row, record and
//! journal give: the thirteen blocking states — or any state the table does
//! not list — refuse, as does a journal holding an outstanding intent, an
//! unknown outcome or a torn tail unless the Job is a parked outcome-unknown
//! lane; an agent execution still active, unless it is only owned by a parked
//! or terminal Job; a capability use reserved and not settled; and an HDC
//! tool selection pending in the bootstrap store (the production composition
//! refuses to start beside one). A source that cannot be read refuses too —
//! a Job record that does not decode as `unreadableRecord`, a Job directory
//! no source gives a state for as `missingRecord` — since the cutover cannot
//! be proved safe past it. Parked Jobs and their unknown outcomes, terminal
//! Jobs and settled or parked uses are carried over as they are, never
//! replayed.
//!
//! Without `--hold-instance-lock` the read takes no lock, so it may run beside
//! the Runtime it would replace: the CLI's first pass, whose refusal changes
//! nothing. With it, the process first takes that Runtime's instance lock
//! (`Agentd/instance.lock`, created if absent, as Swift's daemon and the
//! production composition take it) — a Runtime still holding it refuses the
//! pass — then records a snapshot of every file below the state directory
//! (relative path, byte count, SHA-256 and a root digest) before reading the
//! facts, all while no Runtime can start: the CLI's second pass, after the old
//! service is booted out. The lock is released when the process ends.
//!
//! Neither pass writes a record, journal, ledger or index row; the Job index's
//! SQLite connection has only the effects any reader of it has on its
//! `-wal`/`-shm` pair (`arkdeck_hoststore::cutover_facts`).
//!
//! The answer is one `arkdeck.cutover-preflight/1` document on stdout with
//! exit 0, clear or not; exit 64 is a malformed invocation and 69 a process
//! that may not run the preflight here (the facade's executable, another
//! composition's inputs, no account home), each with only a stderr line.
use crate::production::{self, Layout};
use arkdeck_contract::{CutoverBlock, JobStateClass, canonical_json, sha256_hex};
use arkdeck_hoststore::{CutoverFacts, CutoverRoots};
use arkdeck_platform::{HostDirectory, TreeEntryKind};
use serde_json::{Value, json};
use std::ffi::OsString;
use std::io::{self, Write};

pub(crate) const FLAG: &str = "--cutover-preflight";
const HOLD: &str = "--hold-instance-lock";
const SCHEMA: &str = "arkdeck.cutover-preflight/1";
const SNAPSHOT_SCHEMA: &str = "arkdeck.cutover-snapshot/1";
const INSTANCE_LOCK: &str = "instance.lock";

/// The one-shot preflight for this process's arguments (after its own
/// name), answering its exit status.
pub(crate) fn run(arguments: &[OsString]) -> i32 {
    let hold = match arguments {
        [flag] if flag == FLAG => false,
        [flag, hold] if flag == FLAG && hold == HOLD => true,
        _ => {
            eprintln!("usage: arkdeck-agentd {FLAG} [{HOLD}]");
            return 64;
        }
    };
    match production::requested(std::env::var_os(production::COMPOSITION).as_deref()) {
        Ok(true) => (),
        Ok(false) => {
            eprintln!(
                "arkdeck-agentd: the cutover preflight reads the production layout; set {}=production",
                production::COMPOSITION
            );
            return 64;
        }
        Err(error) => {
            eprintln!("arkdeck-agentd: {error}");
            return 64;
        }
    }
    if let Err(error) = production::refuse_other_compositions(
        &|name| std::env::var_os(name).is_some(),
        crate::facade::swift_executable().is_some(),
    ) {
        eprintln!("arkdeck-agentd: {error}");
        return 69;
    }
    let layout = match Layout::account() {
        Ok(layout) => layout,
        Err(error) => {
            eprintln!("arkdeck-agentd: {error}");
            return 69;
        }
    };
    let document = preflight(&layout, hold);
    let mut bytes = match canonical_json(&document) {
        Ok(bytes) => bytes,
        Err(error) => {
            eprintln!("arkdeck-agentd: the preflight answer is unrepresentable: {error:?}");
            return 70;
        }
    };
    bytes.push(b'\n');
    if io::stdout().lock().write_all(&bytes).is_err() {
        return 74;
    }
    0
}

fn block(kind: &str, fields: Value) -> Value {
    let mut value = fields;
    value["kind"] = json!(kind);
    value
}

/// The document for `layout`, holding its Runtime's instance lock while it
/// reads when `hold` asks for it.
pub(crate) fn preflight(layout: &Layout, hold: bool) -> Value {
    let mut blocks = Vec::new();
    let mut held = None;
    let mut snapshot = Value::Null;
    let state_present = layout.state.exists();
    if hold && state_present {
        match HostDirectory::open(&layout.state) {
            Err(error) => blocks.push(block(
                "unreadable",
                json!({"source": "stateDirectory", "reason": error.to_string()}),
            )),
            Ok(state) => match state.lock_document(INSTANCE_LOCK) {
                Ok(lock) => held = Some(lock),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => blocks.push(block(
                    "runtimeRunning",
                    json!({"reason": "another Runtime holds the instance lock of the state directory"}),
                )),
                Err(error) => blocks.push(block(
                    "unreadable",
                    json!({"source": "instanceLock", "reason": error.to_string()}),
                )),
            },
        }
    }
    if hold {
        // Only a pass that holds the lock (or finds no state at all) records
        // the state the cutover carries over.
        if held.is_some() || !state_present {
            snapshot = match state_snapshot(layout, state_present) {
                Ok(snapshot) => snapshot,
                Err(error) => {
                    blocks.push(block(
                        "unreadable",
                        json!({"source": "snapshot", "reason": error.to_string()}),
                    ));
                    Value::Null
                }
            };
        }
    }
    let facts = arkdeck_hoststore::cutover_facts(CutoverRoots {
        jobs: &layout.state,
        agent_executions: &layout.agent_executions,
        capabilities: &layout.capabilities,
        bootstrap: &layout.bootstrap,
    });
    blocks.extend(fact_blocks(&facts));
    let document = json!({
        "schemaVersion": SCHEMA,
        "stateDirectory": layout.state.to_string_lossy(),
        "instanceLockHeld": held.is_some(),
        "clear": blocks.is_empty(),
        "blocks": blocks,
        "carriedOver": carried_over(&facts),
        "counts": {
            "jobs": facts.jobs.len(),
            "agentExecutions": facts.executions.len(),
            "capabilityUses": facts.uses.len(),
        },
        "snapshot": snapshot,
    });
    drop(held);
    document
}

/// The shared table's refusals, then the pending selection and every source
/// that could not be read.
fn fact_blocks(facts: &CutoverFacts) -> Vec<Value> {
    let mut blocks: Vec<Value> = arkdeck_contract::cutover_preflight(
        &facts.jobs,
        &facts.executions,
        &facts.uses,
    )
    .into_iter()
    .map(|refusal| match refusal {
        CutoverBlock::JobState { job_id, state } => {
            block("jobState", json!({"jobId": job_id, "state": state}))
        }
        CutoverBlock::UnresolvedJournal { job_id } => {
            block("unresolvedJournal", json!({"jobId": job_id}))
        }
        CutoverBlock::ActiveExecution {
            execution_id,
            state,
        } => block(
            "activeAgentExecution",
            json!({"executionId": execution_id, "state": state}),
        ),
        CutoverBlock::UnsettledUse {
            capability_id,
            use_ordinal,
            job_id,
        } => block(
            "unsettledCapabilityUse",
            json!({"capabilityId": capability_id, "useOrdinal": use_ordinal, "jobId": job_id}),
        ),
    })
    .collect();
    if let Some(action) = &facts.pending_tool_selection {
        blocks.push(block(
            "pendingToolSelection",
            json!({"controlActionId": action}),
        ));
    }
    for source in &facts.unreadable {
        blocks.push(block(
            "unreadable",
            json!({"source": source.source, "reason": source.reason}),
        ));
    }
    blocks
}

/// What the cutover carries over as it is: parked Jobs (their unknown
/// outcomes never replayed), terminal Jobs and outcome-unknown uses.
fn carried_over(facts: &CutoverFacts) -> Value {
    let mut parked = Vec::new();
    let mut terminal = 0;
    for job in &facts.jobs {
        match arkdeck_contract::cutover_job_class(job) {
            JobStateClass::Parked => parked.push(job.job_id.clone()),
            JobStateClass::Terminal => terminal += 1,
            JobStateClass::Blocking => (),
        }
    }
    json!({
        "parkedJobIds": parked,
        "terminalJobCount": terminal,
        "outcomeUnknownUseCount": facts
            .uses
            .iter()
            .filter(|use_| use_.outcome == "outcomeUnknown")
            .count(),
    })
}

/// Every entry below the state directory with a root digest over them.
fn state_snapshot(layout: &Layout, present: bool) -> io::Result<Value> {
    let entries = if present {
        arkdeck_platform::snapshot_tree(&layout.state)?
    } else {
        Vec::new()
    };
    let (mut files, mut bytes) = (0u64, 0u64);
    let entries: Vec<Value> = entries
        .into_iter()
        .map(|entry| match entry.kind {
            TreeEntryKind::File { byte_count, sha256 } => {
                files += 1;
                bytes += byte_count;
                json!({"path": entry.path, "kind": "file", "byteCount": byte_count, "sha256": sha256})
            }
            TreeEntryKind::Directory => json!({"path": entry.path, "kind": "directory"}),
            TreeEntryKind::Symlink { target } => {
                json!({"path": entry.path, "kind": "symlink", "target": target})
            }
            TreeEntryKind::Socket => json!({"path": entry.path, "kind": "socket"}),
            TreeEntryKind::Other => json!({"path": entry.path, "kind": "other"}),
        })
        .collect();
    let digest = sha256_hex(
        &canonical_json(&Value::Array(entries.clone()))
            .map_err(|error| io::Error::other(format!("{error:?}")))?,
    );
    Ok(json!({
        "schemaVersion": SNAPSHOT_SCHEMA,
        "stateDirectory": layout.state.to_string_lossy(),
        "stateDirectoryPresent": present,
        "takenAtUtc": crate::host::utc_now(),
        "entries": entries,
        "fileCount": files,
        "byteCount": bytes,
        "rootSha256": digest,
    }))
}
