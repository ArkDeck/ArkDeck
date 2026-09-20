//! Swift `RuntimeHumanActionResourceCoordinator` over the agent execution
//! owner and the union control-action owner (CHG-2026-074, TASK-XPA-014):
//! `human-action.list` and `human-action.show` as Swift's daemon answers them
//! with its combined human-action owner. The rows are every execution's
//! physical-assistance actions and every control action's impact approval,
//! paged in one snapshot and cursor namespace the owner keeps in its own
//! directory (`human-action-snapshots`).
//!
//! An approval is answered by a person through the console challenge of
//! `human-action.resume`, which is not here. The combined owner still finds
//! it for a resume, as Swift's daemon does, and answers as that daemon
//! answers a request that cannot carry the challenge: the approval itself,
//! unchanged, for `human-action.resume`, and a refusal for `agent.resume`.
use crate::agent_execution::{ActionRow, AgentExecutionStore, valid_identifier};
use crate::control_action::ControlActionResources;
use crate::snapshot_pager::SnapshotPager;
use arkdeck_contract::WireError;
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use std::io;
use std::path::Path;
use std::sync::Mutex;

const UNREADABLE: &str = "human-action resource could not be read";

/// Swift's daemon answers every refusal of the human-action owner with the
/// zero-dispatch proof, and any other failure as unreadable.
fn refused(code: &str, message: impl Into<String>) -> WireError {
    if code == "internalError" {
        return WireError {
            code: code.into(),
            message: UNREADABLE.into(),
            details: None,
        };
    }
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([
            ("newDispatchCount".into(), json!(0)),
            ("phase".into(), json!("preAdmission")),
        ])),
    }
}

/// A failure of the owner, as the daemon answers it.
fn owned(error: WireError) -> WireError {
    refused(&error.code, error.message)
}

/// A refusal of a resume, as the handler that took it answers: the combined
/// human-action handler proves zero dispatch for every owner refusal, the
/// agent execution handler only for its named ones, and neither for a
/// failure that is not a refusal.
fn resume_failure(method: &str, code: &str, message: String) -> WireError {
    match method {
        "agent.resume" if code == "internalError" => {
            crate::agent_execution::internal(crate::agent_execution::UNREADABLE)
        }
        "agent.resume" => crate::agent_execution::failure(code, message),
        _ => refused(code, message),
    }
}

/// Swift `matching`: every execution's actions, then every control
/// action's approval.
fn rows(
    agents: &AgentExecutionStore,
    controls: Option<&ControlActionResources>,
) -> Result<Vec<ActionRow>, WireError> {
    let mut rows = agents.human_action_rows(None).map_err(owned)?;
    if let Some(controls) = controls {
        rows.extend(controls.human_action_rows(None).map_err(owned)?);
    }
    Ok(rows)
}

/// Swift's `identifier`: a field that is a bounded resource identity.
fn identity<'a>(params: &'a Map<String, Value>, key: &str) -> Result<&'a str, WireError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| valid_identifier(value))
        .ok_or_else(|| {
            refused(
                "invalidInput",
                format!("{key} must be a bounded resource identity"),
            )
        })
}

/// The combined human-action owner over its private pager directory.
pub struct HumanActionResources {
    /// Swift's `RuntimeSnapshotPager` over the owner's directory.
    pages: SnapshotPager,
    /// Swift's owner is an actor: one request at a time.
    gate: Mutex<()>,
}

impl HumanActionResources {
    /// `path` is the owner's private pager directory, which the composition
    /// makes.
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            pages: SnapshotPager::open_serialized(path)?,
            gate: Mutex::new(()),
        })
    }

    /// The daemon's `human-action.show` and `human-action.list`, with its
    /// checks in its order, answered by the combined owner over `agents` and
    /// the union control-action owner the daemon composes beside them.
    pub fn answer(
        &self,
        method: &str,
        params: &Map<String, Value>,
        agents: &AgentExecutionStore,
        controls: Option<&ControlActionResources>,
    ) -> Result<Value, WireError> {
        let _gate = self
            .gate
            .lock()
            .map_err(|_| refused("internalError", UNREADABLE))?;
        match method {
            "human-action.show" => {
                if params.len() != 1 || !params.contains_key("humanAction") {
                    return Err(refused(
                        "invalidInput",
                        "show requires one exact human action",
                    ));
                }
                let id = identity(params, "humanAction")?;
                let mut rows = rows(agents, controls)?
                    .into_iter()
                    .filter(|row| row.id == id);
                match (rows.next(), rows.next()) {
                    (Some(row), None) => Ok(row.value),
                    (None, _) => Err(refused("resourceNotFound", "human action does not exist")),
                    (Some(_), Some(_)) => Err(refused(
                        "recordUnreadable",
                        "human action has multiple owners",
                    )),
                }
            }
            "human-action.list" => self.list(params, agents, controls),
            _ => Err(refused("internalError", UNREADABLE)),
        }
    }

    /// Swift's daemon for `human-action.resume` and `agent.resume` when the
    /// request names a control action's impact approval: `None` otherwise,
    /// and the agent execution owner answers as before. A request whose
    /// fields or identities Swift's handler refuses is that owner's too.
    ///
    /// Swift's owner lookup reads both owners' rows, and a reference both
    /// hold has multiple owners. An approval's `human-action.resume` answers
    /// the approval unchanged, as Swift's daemon answers every request
    /// outside a foreground console: only that console gets the challenge a
    /// person answers, and none is issued here. `agent.resume` cannot consume
    /// an approval.
    pub fn resume_control_action(
        &self,
        method: &str,
        params: &Map<String, Value>,
        agents: &AgentExecutionStore,
        controls: &ControlActionResources,
    ) -> Option<Result<Value, WireError>> {
        let text = |key: &str| {
            params
                .get(key)
                .and_then(Value::as_str)
                .filter(|value| valid_identifier(value))
        };
        let action = match method {
            "human-action.resume"
                if params.contains_key("humanAction")
                    && params.contains_key("resumeReference")
                    && params.keys().all(|key| {
                        matches!(
                            key.as_str(),
                            "resumeReference" | "humanAction" | "selection" | "challengeResponse"
                        )
                    }) =>
            {
                Some(text("humanAction")?)
            }
            "agent.resume"
                if params.contains_key("resumeReference")
                    && params
                        .keys()
                        .all(|key| matches!(key.as_str(), "resumeReference" | "selection")) =>
            {
                None
            }
            _ => return None,
        };
        let reference = text("resumeReference")?;
        let named = |row: &ActionRow| {
            row.value.get("resumeReference") == Some(&json!(reference))
                && action.is_none_or(|action| row.id == action)
        };
        let gate = match self.gate.lock() {
            Ok(gate) => gate,
            Err(_) => {
                return Some(Err(resume_failure(
                    method,
                    "internalError",
                    UNREADABLE.into(),
                )));
            }
        };
        let approvals = match controls.human_action_rows(None) {
            Ok(rows) => rows.into_iter().filter(named).collect::<Vec<_>>(),
            Err(error) => return Some(Err(resume_failure(method, &error.code, error.message))),
        };
        let approval = approvals.first()?.value.clone();
        let physical = match agents.human_action_rows(None) {
            Ok(rows) => rows.iter().filter(|row| named(row)).count(),
            Err(error) => return Some(Err(resume_failure(method, &error.code, error.message))),
        };
        drop(gate);
        if approvals.len() + physical > 1 {
            return Some(Err(resume_failure(
                method,
                "recordUnreadable",
                "human action reference has multiple owners".into(),
            )));
        }
        Some(if method == "agent.resume" {
            let mut error = resume_failure(
                method,
                "admissionDenied",
                "agent resume cannot consume an impact approval".into(),
            );
            error
                .details
                .get_or_insert_with(Map::new)
                .insert("humanAction".into(), approval);
            Err(error)
        } else if params.contains_key("selection") {
            Err(refused(
                "invalidInput",
                "impact approval accepts no selection",
            ))
        } else {
            Ok(approval)
        })
    }

    /// The daemon's list checks, then Swift's `list`: every action the owner
    /// filter selects, newest first and then by identity, paged through a
    /// stored snapshot a cursor names.
    fn list(
        &self,
        params: &Map<String, Value>,
        agents: &AgentExecutionStore,
        controls: Option<&ControlActionResources>,
    ) -> Result<Value, WireError> {
        if !params
            .keys()
            .all(|key| matches!(key.as_str(), "ownerKind" | "owner" | "pageSize" | "cursor"))
        {
            return Err(refused("invalidInput", "unknown human-action list field"));
        }
        let size = match params.get("pageSize") {
            None => 100,
            Some(value) => value
                .as_i64()
                .filter(|size| (1..=1000).contains(size))
                .and_then(|size| usize::try_from(size).ok())
                .ok_or_else(|| refused("invalidInput", "pageSize must be between 1 and 1000"))?,
        };
        let cursor = match params.get("cursor") {
            None => None,
            Some(Value::String(cursor)) if cursor.len() <= 256 => Some(cursor.as_str()),
            Some(_) => {
                return Err(refused(
                    "invalidCursor",
                    "cursor must be a bounded opaque string",
                ));
            }
        };
        let (kind, owner) = (params.get("ownerKind"), params.get("owner"));
        if kind.is_some() != owner.is_some()
            || kind.is_some_and(|kind| {
                !matches!(kind.as_str(), Some("agentExecution" | "controlAction"))
            })
            || owner.is_some_and(|owner| !owner.as_str().is_some_and(valid_identifier))
        {
            return Err(refused("invalidInput", "invalid human-action owner filter"));
        }
        let filters: Map<String, Value> = params
            .iter()
            .filter(|(key, _)| matches!(key.as_str(), "ownerKind" | "owner"))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        self.pages
            .page_filtered(
                "human-action.list",
                &Value::Object(filters),
                "createdAtDescActionIdAsc",
                size,
                cursor,
                || {
                    let (kind, owner) =
                        (kind.and_then(Value::as_str), owner.and_then(Value::as_str));
                    let mut rows = Vec::new();
                    if kind.is_none_or(|kind| kind == "agentExecution") {
                        rows.extend(agents.human_action_rows(owner)?);
                    }
                    if kind.is_none_or(|kind| kind == "controlAction")
                        && let Some(controls) = controls
                    {
                        rows.extend(controls.human_action_rows(owner)?);
                    }
                    let mut identities = BTreeSet::new();
                    if !rows.iter().all(|row| identities.insert(row.id.clone())) {
                        return Err(refused(
                            "recordUnreadable",
                            "human action identity has multiple owners",
                        ));
                    }
                    rows.sort_by(|a, b| b.created.cmp(&a.created).then_with(|| a.id.cmp(&b.id)));
                    Ok(rows.into_iter().map(|row| row.value).collect())
                },
            )
            .map_err(|error| {
                // The pager's refusals are the owner's own in Swift.
                if error.code == "invalidCursor" {
                    refused(
                        "invalidCursor",
                        "cursor is invalid, belongs to another query or its snapshot was reclaimed",
                    )
                } else {
                    owned(error)
                }
            })
    }
}
