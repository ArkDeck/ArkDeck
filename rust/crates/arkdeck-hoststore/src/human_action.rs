//! Swift `RuntimeHumanActionResourceCoordinator` over the agent execution
//! owner (CHG-2026-074, TASK-XPA-014): `human-action.list` and
//! `human-action.show` as Swift's daemon answers them with its combined
//! human-action owner. The rows are every execution's physical-assistance
//! actions, paged in one snapshot and cursor namespace the owner keeps in its
//! own directory (`human-action-snapshots`). The Rust Runtime keeps no
//! control-action approvals, so a `controlAction` owner lists nothing.
use crate::agent_execution::{AgentExecutionStore, valid_identifier};
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
    /// checks in its order, answered by the combined owner over `agents`.
    pub fn answer(
        &self,
        method: &str,
        params: &Map<String, Value>,
        agents: &AgentExecutionStore,
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
                let mut rows = agents
                    .human_action_rows(None)
                    .map_err(owned)?
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
            "human-action.list" => self.list(params, agents),
            _ => Err(refused("internalError", UNREADABLE)),
        }
    }

    /// The daemon's list checks, then Swift's `list`: every action the owner
    /// filter selects, newest first and then by identity, paged through a
    /// stored snapshot a cursor names.
    fn list(
        &self,
        params: &Map<String, Value>,
        agents: &AgentExecutionStore,
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
                    // The Rust Runtime keeps no control-action approvals.
                    let mut rows = if kind.and_then(Value::as_str) == Some("controlAction") {
                        Vec::new()
                    } else {
                        agents.human_action_rows(owner.and_then(Value::as_str))?
                    };
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
