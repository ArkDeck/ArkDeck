//! The shared Job-state preflight table (`spec/recovery/job-state-preflight.json`,
//! design §G.4) and the two classifiers that read it.
//!
//! Design §G.4 asks for the restart and cutover predicate to be written once and
//! shared by both implementations. The table classes every Job state as
//! blocking, parked or terminal: a parked Job is an `outcomeUnknown` lane with
//! nothing in flight, carried over as it is and never replayed (ADR-0009
//! decision 2, whose carriers the maintainer ruled on 2026-09-19 are ported
//! unchanged). It also classes agent-execution states and capability-use
//! outcomes.
//!
//! The table is compiled in from the copy Swift's
//! `JobStatePreflightTableContractTests` records beside its oracle, which that
//! test compares with `spec/` byte for byte; the copy lives under `rust/` so
//! the contract views, which carry only `rust/` and the registered inputs, see
//! it too.
//!
//! - [`classify_restart`] is `runtime service restart`'s carry-over of the
//!   daemon's current Jobs, as Swift's `RuntimeCLI.classifyAgentdRestartCurrentJobs`
//!   decides it.
//! - [`cutover_preflight`] is §G.4's M5 preflight over a state root's facts,
//!   which the caller gathers from the Job index, records and journals, the
//!   agent executions and the capability ledger. Beside the table's rules it
//!   refuses one cutover-only case, which the table does not class: a parked
//!   Flash Job whose enter-Loader transition only Swift's
//!   `flash.bind-current-loader` settles (F7, not ported).
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::sync::OnceLock;

/// The table as Swift records it.
pub const JOB_STATE_PREFLIGHT_TABLE: &str =
    include_str!("../../../tests/fixtures/job-state-preflight/table.json");

/// How the table classes a Job state.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum JobStateClass {
    Terminal,
    Parked,
    Blocking,
}

struct Table {
    states: BTreeMap<String, JobStateClass>,
    unlisted: JobStateClass,
    executions: BTreeMap<String, bool>,
    uses: BTreeMap<String, String>,
}

fn class(word: &str) -> JobStateClass {
    match word {
        "terminal" => JobStateClass::Terminal,
        "parked" => JobStateClass::Parked,
        "blocking" => JobStateClass::Blocking,
        other => panic!("the shared table names an unknown class {other}"),
    }
}

fn words(table: &Map<String, Value>, key: &str) -> BTreeMap<String, String> {
    table[key]
        .as_object()
        .unwrap_or_else(|| panic!("the shared table has no {key}"))
        .iter()
        .map(|(name, word)| (name.clone(), word.as_str().unwrap().to_owned()))
        .collect()
}

fn table() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| {
        let value: Value =
            serde_json::from_str(JOB_STATE_PREFLIGHT_TABLE).expect("the shared table is JSON");
        let table = value.as_object().expect("the shared table is an object");
        assert_eq!(table["schemaVersion"], "arkdeck.job-state-preflight/1");
        Table {
            states: words(table, "states")
                .into_iter()
                .map(|(state, word)| (state, class(&word)))
                .collect(),
            unlisted: class(table["unlistedState"].as_str().unwrap()),
            executions: words(table, "agentExecutionStates")
                .into_iter()
                .map(|(state, word)| (state, word == "active"))
                .collect(),
            uses: words(table, "capabilityUseOutcomes"),
        }
    })
}

/// The class of a Job state; a state the table does not list blocks.
pub fn job_state_class(state: &str) -> JobStateClass {
    table()
        .states
        .get(state)
        .copied()
        .unwrap_or(table().unlisted)
}

/// Every Job state the table lists, in its order.
pub fn job_states() -> impl Iterator<Item = &'static str> {
    table().states.keys().map(String::as_str)
}

/// Whether an agent execution in this state is active; a state the table does
/// not list is active.
pub fn agent_execution_active(state: &str) -> bool {
    table().executions.get(state).copied().unwrap_or(true)
}

/// Whether a capability use with this outcome is unsettled; an outcome the
/// table does not list is.
pub fn capability_use_unsettled(outcome: &str) -> bool {
    table()
        .uses
        .get(outcome)
        .is_none_or(|word| word == "unsettled")
}

/// `runtime service restart`'s decision about the daemon's current Jobs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RestartPreflight {
    pub blocking_job_ids: Vec<String>,
    pub preserved_unknown_job_ids: Vec<String>,
}

/// A current Job the daemon answered in a shape the classifier cannot read:
/// Swift's `CLIError(exitCode: 69, "daemon returned a malformed current Runtime
/// Job")`, raised before anything is classified.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MalformedCurrentJob;

/// Swift `exactInt`: a JSON integer, or a number with no fraction, that fits.
fn exact_integer(value: Option<&Value>) -> Option<i64> {
    let number = value?.as_number()?;
    number.as_i64().or_else(|| {
        number
            .as_f64()
            .filter(|float| {
                float.fract() == 0.0 && *float >= i64::MIN as f64 && *float < i64::MAX as f64
            })
            .map(|float| float as i64)
    })
}

/// Swift `RuntimeCLI.classifyAgentdRestartCurrentJobs`: a current Job is
/// preserved only when it is parked, `outcomeUnknown`, not waiting for a human,
/// owes no cleanup residue, has no process in progress and has finished; every
/// other current Job blocks the restart. Both lists are sorted.
pub fn classify_restart(current: &[Value]) -> Result<RestartPreflight, MalformedCurrentJob> {
    let mut blocking = Vec::new();
    let mut preserved = Vec::new();
    for value in current {
        let job = value.as_object().ok_or(MalformedCurrentJob)?;
        let job_id = job
            .get("jobId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .ok_or(MalformedCurrentJob)?;
        let state = job
            .get("state")
            .and_then(Value::as_str)
            .ok_or(MalformedCurrentJob)?;
        let outcome_unknown = job
            .get("outcomeUnknown")
            .and_then(Value::as_bool)
            .ok_or(MalformedCurrentJob)?;
        let waiting_for_human = job
            .get("waitingForHuman")
            .and_then(Value::as_bool)
            .ok_or(MalformedCurrentJob)?;
        let residue =
            exact_integer(job.get("outstandingResidueCount")).ok_or(MalformedCurrentJob)?;
        let process_closed = matches!(job.get("processProgress"), Some(Value::Null));
        let finished = job
            .get("finishedAtUtc")
            .and_then(Value::as_str)
            .is_some_and(|finished| !finished.is_empty());
        if job_state_class(state) == JobStateClass::Parked
            && outcome_unknown
            && !waiting_for_human
            && residue == 0
            && process_closed
            && finished
        {
            preserved.push(job_id.to_owned());
        } else {
            blocking.push(job_id.to_owned());
        }
    }
    blocking.sort();
    preserved.sort();
    Ok(RestartPreflight {
        blocking_job_ids: blocking,
        preserved_unknown_job_ids: preserved,
    })
}

/// A Job as the cutover preflight sees it. `states` are the states its index
/// row, record and journal give (a crash window can leave them apart); the
/// most conservative one classes the Job. `journal_unresolved` is true when
/// its journal holds an outstanding intent, an unknown outcome or a torn tail.
/// `loader_transition` is set when its record and journal hold exactly the
/// enter-Loader transition Swift's `flash.bind-current-loader` settles and no
/// ArkForge lane held it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CutoverJob {
    pub job_id: String,
    pub states: Vec<String>,
    pub journal_unresolved: bool,
    pub loader_transition: Option<LoaderTransition>,
}

/// A DAYU200 Flash Job's enter-Loader transition left awaiting a Loader
/// binding, as Swift's `RuntimeJobEngine.loaderTransitionAwaitingBinding`
/// and `pendingLoaderTransition` find one (a Job from before CHG-059, whose
/// engine wrote the transition's intent itself): only Swift's
/// `settleLoaderTransitionAfterBinding`, after `flash.bind-current-loader`
/// binds `target_id` at `expected_binding_revision`, settles it. This Runtime
/// does not port that settlement (F7), so carried over, the Job would keep
/// refusing that binding.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct LoaderTransition {
    pub target_id: String,
    pub expected_binding_revision: i64,
}

/// An agent execution: its state and the Job it owns, if any.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CutoverExecution {
    pub execution_id: String,
    pub state: String,
    pub job_id: Option<String>,
}

/// A capability use: its capability, ordinal, outcome and Job.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CutoverUse {
    pub capability_id: String,
    pub use_ordinal: i64,
    pub outcome: String,
    pub job_id: String,
}

/// Why the cutover is refused.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum CutoverBlock {
    /// A Job whose most conservative state blocks (or has no state at all).
    JobState { job_id: String, state: String },
    /// A Job that is not parked, whose journal is unresolved.
    UnresolvedJournal { job_id: String },
    /// A parked Flash Job whose enter-Loader transition only Swift's
    /// `flash.bind-current-loader` settles: settled there first, it is
    /// carried over as the terminal Job the settlement leaves.
    LoaderTransitionAwaitingBinding {
        job_id: String,
        target_id: String,
        expected_binding_revision: i64,
    },
    /// An agent execution that is active and not merely owned by a parked or
    /// terminal Job.
    ActiveExecution { execution_id: String, state: String },
    /// A capability use reserved or consumed without an outcome.
    UnsettledUse {
        capability_id: String,
        use_ordinal: i64,
        job_id: String,
    },
}

/// The class of a Job from all the states its sources give.
pub fn cutover_job_class(job: &CutoverJob) -> JobStateClass {
    job.states
        .iter()
        .map(|state| job_state_class(state))
        .max()
        .unwrap_or(JobStateClass::Blocking)
}

/// Design §G.4's cutover preflight: every reason to refuse, sorted; empty
/// means every Job, execution and use may be carried over as it is. The
/// table's rules, and a parked Job's Loader transition only Swift settles.
pub fn cutover_preflight(
    jobs: &[CutoverJob],
    executions: &[CutoverExecution],
    uses: &[CutoverUse],
) -> Vec<CutoverBlock> {
    let classes: BTreeMap<&str, JobStateClass> = jobs
        .iter()
        .map(|job| (job.job_id.as_str(), cutover_job_class(job)))
        .collect();
    let mut blocks = Vec::new();
    for job in jobs {
        let class = classes[job.job_id.as_str()];
        if class == JobStateClass::Blocking {
            let state = job
                .states
                .iter()
                .find(|state| job_state_class(state) == JobStateClass::Blocking)
                .cloned()
                .unwrap_or_default();
            blocks.push(CutoverBlock::JobState {
                job_id: job.job_id.clone(),
                state,
            });
        }
        if job.journal_unresolved && class != JobStateClass::Parked {
            blocks.push(CutoverBlock::UnresolvedJournal {
                job_id: job.job_id.clone(),
            });
        }
        // A parked Job is carried over as it is, unless only Swift's Runtime
        // can settle the Loader transition it awaits.
        if class == JobStateClass::Parked
            && let Some(transition) = &job.loader_transition
        {
            blocks.push(CutoverBlock::LoaderTransitionAwaitingBinding {
                job_id: job.job_id.clone(),
                target_id: transition.target_id.clone(),
                expected_binding_revision: transition.expected_binding_revision,
            });
        }
    }
    for execution in executions {
        let owned_by_settled_job = execution.state == "jobOwned"
            && execution.job_id.as_deref().is_some_and(|job| {
                matches!(
                    classes.get(job),
                    Some(JobStateClass::Parked | JobStateClass::Terminal)
                )
            });
        if agent_execution_active(&execution.state) && !owned_by_settled_job {
            blocks.push(CutoverBlock::ActiveExecution {
                execution_id: execution.execution_id.clone(),
                state: execution.state.clone(),
            });
        }
    }
    for used in uses {
        if capability_use_unsettled(&used.outcome) {
            blocks.push(CutoverBlock::UnsettledUse {
                capability_id: used.capability_id.clone(),
                use_ordinal: used.use_ordinal,
                job_id: used.job_id.clone(),
            });
        }
    }
    blocks.sort();
    blocks
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::Path;

    fn restart_oracle() -> Value {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/job-state-preflight/restart.json");
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    #[test]
    fn the_table_classes_every_state_the_swift_oracle_names() {
        let listed: Vec<&str> = job_states().collect();
        assert_eq!(listed.len(), 20);
        let parked: Vec<&str> = listed
            .iter()
            .copied()
            .filter(|state| job_state_class(state) == JobStateClass::Parked)
            .collect();
        assert_eq!(parked, ["waitingForRecovery"]);
        assert_eq!(job_state_class("futureState"), JobStateClass::Blocking);
        for state in [
            "planned",
            "succeeded",
            "recovered",
            "failed",
            "cancelled",
            "interrupted",
        ] {
            assert_eq!(job_state_class(state), JobStateClass::Terminal, "{state}");
        }
        assert!(agent_execution_active("jobOwned"));
        assert!(!agent_execution_active("completed"));
        assert!(agent_execution_active("futureExecutionState"));
        assert!(capability_use_unsettled("pending"));
        assert!(!capability_use_unsettled("outcomeUnknown"));
        assert!(!capability_use_unsettled("safeToReflash"));
        assert!(capability_use_unsettled("futureOutcome"));
    }

    #[test]
    fn the_restart_classifier_decides_every_swift_case() {
        let oracle = restart_oracle();
        let rows = oracle["rows"].as_array().unwrap();
        assert!(rows.len() >= 147, "{} rows", rows.len());
        let decided = classify_restart(rows).unwrap();
        let ids = |key: &str| -> Vec<String> {
            oracle[key]
                .as_array()
                .unwrap()
                .iter()
                .map(|id| id.as_str().unwrap().to_owned())
                .collect()
        };
        assert_eq!(decided.blocking_job_ids, ids("blockingJobIds"));
        assert_eq!(
            decided.preserved_unknown_job_ids,
            ids("preservedUnknownJobIds")
        );
        for refusal in oracle["refusals"].as_array().unwrap() {
            let rows = [
                json!({"jobId": "job-good", "state": "running", "outcomeUnknown": false,
                    "waitingForHuman": false, "outstandingResidueCount": 0,
                    "processProgress": null, "finishedAtUtc": null}),
                refusal["row"].clone(),
            ];
            assert_eq!(
                classify_restart(&rows),
                Err(MalformedCurrentJob),
                "{}",
                refusal["name"]
            );
            assert_eq!(refusal["exitCode"], 69);
        }
    }

    fn job(id: &str, states: &[&str], journal_unresolved: bool) -> CutoverJob {
        CutoverJob {
            job_id: id.into(),
            states: states.iter().map(|state| (*state).into()).collect(),
            journal_unresolved,
            loader_transition: None,
        }
    }

    #[test]
    fn the_cutover_carries_parked_and_terminal_and_refuses_everything_in_flight() {
        let jobs = [
            job("job-parked", &["waitingForRecovery"; 3], true),
            job("job-done", &["succeeded"; 3], false),
            job("job-running", &["running"; 3], true),
            job(
                "job-lagging-index",
                &["succeeded", "running", "running"],
                false,
            ),
            job("job-terminal-unresolved", &["failed"; 3], true),
            job("job-unknown-state", &["futureState"], false),
        ];
        let executions = [
            CutoverExecution {
                execution_id: "execution-parked".into(),
                state: "jobOwned".into(),
                job_id: Some("job-parked".into()),
            },
            CutoverExecution {
                execution_id: "execution-running".into(),
                state: "jobOwned".into(),
                job_id: Some("job-running".into()),
            },
            CutoverExecution {
                execution_id: "execution-human".into(),
                state: "waitingForHuman".into(),
                job_id: None,
            },
            CutoverExecution {
                execution_id: "execution-done".into(),
                state: "completed".into(),
                job_id: Some("job-done".into()),
            },
        ];
        let uses = [
            CutoverUse {
                capability_id: "cap-a".into(),
                use_ordinal: 1,
                outcome: "outcomeUnknown".into(),
                job_id: "job-parked".into(),
            },
            CutoverUse {
                capability_id: "cap-a".into(),
                use_ordinal: 2,
                outcome: "pending".into(),
                job_id: "job-done".into(),
            },
            CutoverUse {
                capability_id: "cap-b".into(),
                use_ordinal: 1,
                outcome: "safeToReflash".into(),
                job_id: "job-done".into(),
            },
        ];
        let mut expected = vec![
            CutoverBlock::JobState {
                job_id: "job-running".into(),
                state: "running".into(),
            },
            CutoverBlock::UnresolvedJournal {
                job_id: "job-running".into(),
            },
            CutoverBlock::JobState {
                job_id: "job-lagging-index".into(),
                state: "running".into(),
            },
            CutoverBlock::UnresolvedJournal {
                job_id: "job-terminal-unresolved".into(),
            },
            CutoverBlock::JobState {
                job_id: "job-unknown-state".into(),
                state: "futureState".into(),
            },
            CutoverBlock::ActiveExecution {
                execution_id: "execution-running".into(),
                state: "jobOwned".into(),
            },
            CutoverBlock::ActiveExecution {
                execution_id: "execution-human".into(),
                state: "waitingForHuman".into(),
            },
            CutoverBlock::UnsettledUse {
                capability_id: "cap-a".into(),
                use_ordinal: 2,
                job_id: "job-done".into(),
            },
        ];
        expected.sort();
        assert_eq!(cutover_preflight(&jobs, &executions, &uses), expected);
        let carried = [job("job-parked", &["waitingForRecovery"], true)];
        assert!(cutover_preflight(&carried, &executions[..1], &uses[..1]).is_empty());
        assert_eq!(
            cutover_job_class(&job("job-no-sources", &[], false)),
            JobStateClass::Blocking
        );
    }

    #[test]
    fn a_parked_loader_transition_only_swift_settles_refuses_the_cutover() {
        let awaiting = |id: &str, states: &[&str]| CutoverJob {
            loader_transition: Some(LoaderTransition {
                target_id: "target-dayu200".into(),
                expected_binding_revision: 3,
            }),
            ..job(id, states, true)
        };
        // Parked, whichever source parks it: refused by name, with the
        // binding that settles it on Swift's Runtime.
        let parked = awaiting("job-loader", &["waitingForRecovery", "failed"]);
        assert_eq!(
            cutover_preflight(std::slice::from_ref(&parked), &[], &[]),
            [CutoverBlock::LoaderTransitionAwaitingBinding {
                job_id: "job-loader".into(),
                target_id: "target-dayu200".into(),
                expected_binding_revision: 3,
            }]
        );
        // Its owning execution is still carried with the parked Job.
        let owned = CutoverExecution {
            execution_id: "execution-loader".into(),
            state: "jobOwned".into(),
            job_id: Some("job-loader".into()),
        };
        assert_eq!(
            cutover_preflight(std::slice::from_ref(&parked), &[owned], &[]).len(),
            1
        );
        // Another parked Job, even with an unresolved journal, is carried
        // over as before.
        assert!(
            cutover_preflight(
                &[job("job-parked", &["waitingForRecovery"], true)],
                &[],
                &[]
            )
            .is_empty()
        );
        // A Job that is not parked is refused by the table's rules alone.
        assert_eq!(
            cutover_preflight(&[awaiting("job-running", &["running"])], &[], &[]),
            [
                CutoverBlock::JobState {
                    job_id: "job-running".into(),
                    state: "running".into(),
                },
                CutoverBlock::UnresolvedJournal {
                    job_id: "job-running".into(),
                },
            ]
        );
        assert_eq!(
            cutover_preflight(&[awaiting("job-failed", &["failed"])], &[], &[]),
            [CutoverBlock::UnresolvedJournal {
                job_id: "job-failed".into(),
            }]
        );
    }
}
