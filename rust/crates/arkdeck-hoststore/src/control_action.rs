//! Swift `RuntimeControlPlaneHandler.hdcControlActionRequest` (CHG-2026-074,
//! TASK-XPA-014, TASK-XPA-012): `runtime.hdc.impact-preview`,
//! `runtime.hdc.restart`, `runtime.tool.select` and `control-action.list`,
//! `.show` and `.reconcile`, over the union owner
//! (`RuntimeControlActionResourceCoordinator`) the production daemon always
//! composes, paging in its own directory (`control-action-snapshots`).
//!
//! Without a managed HDC server `ArkDeckAgentDaemonMain` composes no HDC
//! control-action owner and no tool-selection owner: no control action can
//! exist, the lifecycle methods are unavailable before any parameter is read,
//! an exact identity is not found and a listing is one empty snapshot page.
//! Once its HDC server host has started the union owner routes to the HDC
//! control-action owner (`hdc_control_action.rs`), which previews and holds
//! the actions and requests a restart's impact approval, and it hands the
//! approvals to the human-action owner (`human_action.rs`); the
//! tool-selection owner is not composed here, so a selection is unavailable
//! before any parameter is read.
use crate::agent_execution::ActionRow;
use crate::control_action_value::digest;
use crate::hdc_control_action::{HdcControlActions, ImpactSource};
use crate::snapshot_pager::SnapshotPager;
use arkdeck_contract::WireError;
use serde_json::{Map, Value, json};
use std::io;
use std::path::Path;
use std::sync::Mutex;

/// The order the union owner lists control actions in.
const ORDER: &str = "createdAtThenControlActionId";

/// The union owner's control-action kinds (Swift `list`).
const KINDS: [&str; 2] = ["hdcLifecycle", "runtimeToolSelection"];

/// Swift `RuntimeControlActionResourceCoordinator.states`.
use crate::hdc_control_action::STATES;

/// Swift's handler answers every refusal of these routes with the
/// zero-dispatch proof and nothing else.
pub(crate) fn refused(code: &str, message: impl Into<String>) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: Some(Map::from_iter([("newDispatchCount".into(), json!(0))])),
    }
}

/// The handler checks for its HDC control-action owner before it reads any
/// parameter; the daemon composes none without a managed HDC server.
fn hdc_owner_unavailable() -> WireError {
    refused(
        "operationUnavailable",
        "the Runtime HDC control-action owner is unavailable",
    )
}

/// The handler checks for its tool-selection owner before it reads any
/// parameter, as for the lifecycle methods. Swift composes that owner only
/// beside a started HDC server host, its impact source and the registry
/// adapter; no composition here has one, with or without a managed server.
fn tool_selection_owner_unavailable() -> WireError {
    refused(
        "operationUnavailable",
        "the Runtime tool-selection owner is unavailable",
    )
}

/// Swift `HDCControlValue.identifier`: 1 to 128 bytes, an ASCII letter or
/// digit first, then letters, digits, `-`, `.`, `:` and `_`.
pub(crate) fn identifier(text: &str) -> bool {
    (1..=128).contains(&text.len())
        && text.as_bytes()[0].is_ascii_alphanumeric()
        && text
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-.:_".contains(&byte))
}

/// The handler's `control-action.show` and `.reconcile` check: exactly one
/// `controlAction`, an exact identity.
fn exact_identity(params: &Map<String, Value>) -> Result<&str, WireError> {
    params
        .get("controlAction")
        .and_then(Value::as_str)
        .filter(|id| params.len() == 1 && identifier(id))
        .ok_or_else(|| {
            refused(
                "invalidInput",
                "an exact control-action identity is required",
            )
        })
}

/// The handler's `runtime.hdc.restart` check: exactly the tuple naming one
/// preview of one action, each an exact identity or a lowercase digest.
fn restart_tuple(params: &Map<String, Value>) -> Result<(&str, &str, &str), WireError> {
    let text = |key: &str| params.get(key).and_then(Value::as_str);
    match (
        text("controlAction"),
        text("previewId"),
        text("previewDigest"),
    ) {
        (Some(action), Some(preview), Some(value))
            if params.len() == 3 && identifier(action) && identifier(preview) && digest(value) =>
        {
            Ok((action, preview, value))
        }
        _ => Err(refused(
            "invalidInput",
            "restart requires one exact control-action preview tuple",
        )),
    }
}

/// A `control-action.list` request as the handler passes it to its owner.
struct ListRequest<'a> {
    filters: Map<String, Value>,
    size: usize,
    cursor: Option<&'a str>,
}

/// The handler's `control-action.list` checks, in its order: only known
/// fields, an integer page size from 1 to 1000 (100 by default), a string
/// cursor of at most 256 bytes. The filters go to the owner unchecked.
fn list_request(params: &Map<String, Value>) -> Result<ListRequest<'_>, WireError> {
    if !params
        .keys()
        .all(|key| matches!(key.as_str(), "kind" | "state" | "pageSize" | "cursor"))
    {
        return Err(refused("invalidInput", "unknown control-action list field"));
    }
    let size = match params.get("pageSize") {
        None => 100,
        Some(value) => value
            .as_i64()
            .filter(|size| (1..=1000).contains(size))
            .and_then(|size| usize::try_from(size).ok())
            .ok_or_else(|| refused("invalidInput", "invalid page size"))?,
    };
    let cursor = match params.get("cursor") {
        None => None,
        Some(Value::String(cursor)) if cursor.len() <= 256 => Some(cursor.as_str()),
        Some(_) => return Err(refused("invalidCursor", "invalid control-action cursor")),
    };
    let filters = params
        .iter()
        .filter(|(key, _)| matches!(key.as_str(), "kind" | "state"))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    Ok(ListRequest {
        filters,
        size,
        cursor,
    })
}

/// A method the handler does not route here.
fn unknown_method() -> WireError {
    WireError {
        code: "unknownMethod".into(),
        message: "unknown control-action method".into(),
        details: None,
    }
}

/// The union control-action owner, with its private pager directory, over
/// the HDC control-action owner when the daemon's HDC server host started,
/// and never over a tool-selection owner.
pub struct ControlActionResources {
    /// Swift's `RuntimeSnapshotPager` over the owner's directory.
    pages: SnapshotPager,
    /// Swift's owners are actors: one request at a time. So, as Swift's
    /// pager, this one keeps no lock document beside its snapshots.
    gate: Mutex<()>,
    /// Swift's `hdc` owner.
    hdc: Option<HdcControlActions>,
}

impl ControlActionResources {
    /// `path` is the owner's private pager directory, which the composition
    /// makes.
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            pages: SnapshotPager::open_serialized(path)?,
            gate: Mutex::new(()),
            hdc: None,
        })
    }

    /// The union owner over the HDC control-action owner, as the daemon
    /// composes it once its HDC server host started.
    pub fn with_hdc(mut self, hdc: HdcControlActions) -> Self {
        self.hdc = Some(hdc);
        self
    }

    /// Called only after the combined human-action owner resolved the exact
    /// approval and the transport proved a foreground console peer.
    pub fn issue_interactive_challenge(
        &self,
        action: &str,
        reference: &str,
    ) -> Result<Value, WireError> {
        let _gate = self.gate.lock().map_err(|_| unreadable())?;
        self.hdc
            .as_ref()
            .ok_or_else(hdc_owner_unavailable)?
            .issue_interactive_challenge(action, reference)
    }

    /// The Runtime supplies the driver and impact source after resolving the
    /// unique approval owner. They are never deserialized from an RPC frame.
    pub fn consume_interactive_challenge(
        &self,
        action: &str,
        reference: &str,
        response: &str,
        jobs: &crate::JobStore,
        source: &dyn ImpactSource,
        driver: &dyn crate::HdcLifecycleDriver,
    ) -> Result<Value, WireError> {
        let _gate = self.gate.lock().map_err(|_| unreadable())?;
        self.hdc
            .as_ref()
            .ok_or_else(hdc_owner_unavailable)?
            .consume_interactive_challenge(action, reference, response, jobs, source, driver)
    }

    /// The handler's answer, with its checks in its order, over this owner.
    /// `source` is the impact source of the daemon's HDC server host; the
    /// HDC owner takes part only with it.
    pub fn answer(
        &self,
        method: &str,
        params: &Map<String, Value>,
        source: Option<&dyn ImpactSource>,
    ) -> Result<Value, WireError> {
        let hdc = self.hdc.as_ref().zip(source);
        match method {
            "runtime.hdc.impact-preview" => {
                let Some((hdc, source)) = hdc else {
                    return Err(hdc_owner_unavailable());
                };
                let _gate = self.gate.lock().map_err(|_| unreadable())?;
                hdc.preview(params, source)
            }
            // Swift's handler asks its HDC owner directly, not the union:
            // the owner's presence, then the tuple, then the request.
            "runtime.hdc.restart" => {
                let Some((hdc, source)) = hdc else {
                    return Err(hdc_owner_unavailable());
                };
                let (id, preview, value) = restart_tuple(params)?;
                let _gate = self.gate.lock().map_err(|_| unreadable())?;
                hdc.restart(id, preview, value, source)
            }
            "runtime.tool.select" => Err(tool_selection_owner_unavailable()),
            "control-action.show" | "control-action.reconcile" => {
                let id = exact_identity(params)?;
                let _gate = self.gate.lock().map_err(|_| unreadable())?;
                // Swift `actionOwner`: the one owner holding the identity.
                let Some((hdc, source)) = hdc else {
                    return Err(refused("resourceNotFound", "control action does not exist"));
                };
                if !hdc.list_records()?.iter().any(|record| record.id() == id) {
                    return Err(refused("resourceNotFound", "control action does not exist"));
                }
                if method == "control-action.show" {
                    hdc.show(id)
                } else {
                    hdc.reconcile(id, source)
                }
            }
            "control-action.list" => {
                let request = list_request(params)?;
                let _gate = self.gate.lock().map_err(|_| unreadable())?;
                self.list(request, hdc.map(|(hdc, _)| hdc))
            }
            _ => Err(unknown_method()),
        }
    }

    /// Swift's union `humanActionResourceRows`: the impact approvals its
    /// owners hold (only those of the action `owner` names, when given) —
    /// the HDC owner's, since no tool-selection owner is composed.
    pub(crate) fn human_action_rows(
        &self,
        owner: Option<&str>,
    ) -> Result<Vec<ActionRow>, WireError> {
        let _gate = self.gate.lock().map_err(|_| unreadable())?;
        match &self.hdc {
            Some(hdc) => hdc.human_action_rows(owner),
            None => Ok(Vec::new()),
        }
    }

    /// Swift's union `list`: its filter check, then every action the owners
    /// hold, refreshed and in creation-then-identity order, paged through a
    /// stored snapshot a cursor names.
    fn list(
        &self,
        request: ListRequest<'_>,
        hdc: Option<&HdcControlActions>,
    ) -> Result<Value, WireError> {
        let known = |key: &str, allowed: &[&str]| {
            request
                .filters
                .get(key)
                .is_none_or(|value| value.as_str().is_some_and(|text| allowed.contains(&text)))
        };
        if !known("kind", &KINDS) || !known("state", &STATES) {
            return Err(refused(
                "invalidInput",
                "unsupported control-action discovery filter",
            ));
        }
        // The actions are read before the pager, even for a cursor: reading
        // refreshes their age, as in Swift.
        let mut values = Vec::new();
        if let Some(hdc) = hdc
            && request
                .filters
                .get("kind")
                .is_none_or(|kind| kind == "hdcLifecycle")
        {
            values.extend(hdc.list_records()?.iter().map(|record| record.projection()));
        }
        if let Some(state) = request.filters.get("state") {
            values.retain(|value| value.get("state") == Some(state));
        }
        let mut identities = std::collections::BTreeSet::new();
        if !values.iter().all(|value| {
            value
                .get("controlActionId")
                .and_then(Value::as_str)
                .is_some_and(|id| identities.insert(id.to_owned()))
        }) {
            return Err(refused(
                "recordUnreadable",
                "control-action identity has multiple owners",
            ));
        }
        let key = |value: &Value| {
            let text = |key: &str| {
                value
                    .get(key)
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned()
            };
            (text("createdAt"), text("controlActionId"))
        };
        values.sort_by_key(key);
        self.pages
            .page_filtered(
                "control-action.list",
                &Value::Object(request.filters),
                ORDER,
                request.size,
                request.cursor,
                || Ok(values),
            )
            // The pager's refusals are the owner's own in Swift, with the
            // handler's zero-dispatch proof.
            .map_err(|error| refused(&error.code, error.message))
    }
}

/// Swift's handler for a failure that is not an owner's refusal.
pub(crate) fn unreadable() -> WireError {
    refused(
        "recordUnreadable",
        "control-action state cannot be read or persisted",
    )
}

/// The handler's answer with no control-action owner at all, as a daemon
/// that keeps no state composes it: the same checks, then the owner's
/// absence. For `control-action.show` and `.reconcile` of an exact identity
/// Swift answers `operationUnavailable` ("the Runtime control-action owner is
/// unavailable"), which their published schemas do not admit, so that request
/// keeps the read-only foundation's refusal.
pub fn control_action_without_owner(
    method: &str,
    params: &Map<String, Value>,
) -> Result<Value, WireError> {
    match method {
        "runtime.hdc.impact-preview" | "runtime.hdc.restart" => Err(hdc_owner_unavailable()),
        "runtime.tool.select" => Err(tool_selection_owner_unavailable()),
        "control-action.show" | "control-action.reconcile" => {
            exact_identity(params)?;
            Err(WireError {
                code: "rejected".into(),
                message: "this method is unavailable in the read-only Rust foundation".into(),
                details: None,
            })
        }
        "control-action.list" => {
            list_request(params)?;
            Err(refused(
                "operationUnavailable",
                "the Runtime control-action owner is unavailable",
            ))
        }
        _ => Err(unknown_method()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identities_are_swift_control_identifiers() {
        for good in [
            "control-action-5f0c1a52-0b4e-4c8a-9d2e-2b7f3c6a9e10",
            "a",
            "A:b.c_d-e",
            &"x".repeat(128),
        ] {
            assert!(identifier(good), "{good}");
        }
        for bad in [
            "",
            "-a",
            ":a",
            "control action/1",
            "a/b",
            "é",
            &"x".repeat(129),
        ] {
            assert!(!identifier(bad), "{bad}");
        }
    }

    #[test]
    fn the_handler_checks_come_in_swift_order() {
        let params = |value: Value| value.as_object().unwrap().clone();
        // An unknown field is refused before a bad page size or cursor.
        let error = list_request(&params(json!({"x": 1, "pageSize": 0})))
            .err()
            .unwrap();
        assert_eq!(error.message, "unknown control-action list field");
        // A bad page size before a bad cursor.
        let error = list_request(&params(json!({"pageSize": 1001, "cursor": 1})))
            .err()
            .unwrap();
        assert_eq!(error.message, "invalid page size");
        for size in [json!(0), json!(1001), json!(-1), json!("1"), json!(null)] {
            let error = list_request(&params(json!({"pageSize": size})))
                .err()
                .unwrap();
            assert_eq!(error.code, "invalidInput");
        }
        for cursor in [json!("c".repeat(257)), json!(1), json!(null)] {
            let error = list_request(&params(json!({"cursor": cursor})))
                .err()
                .unwrap();
            assert_eq!(
                (error.code.as_str(), error.message.as_str()),
                ("invalidCursor", "invalid control-action cursor")
            );
        }
        // A filter the owner refuses passes the handler unchanged.
        let fields = params(
            json!({"kind": 7, "state": "running", "pageSize": 1000, "cursor": "c".repeat(256)}),
        );
        let request = list_request(&fields).unwrap();
        assert_eq!(request.size, 1000);
        assert_eq!(request.cursor.map(str::len), Some(256));
        assert_eq!(
            Value::Object(request.filters),
            json!({"kind": 7, "state": "running"})
        );
        let empty = Map::new();
        let request = list_request(&empty).unwrap();
        assert_eq!((request.size, request.cursor), (100, None));
        // Show and reconcile: exactly one field, an exact identity.
        for fields in [
            json!({}),
            json!({"controlAction": "a", "executable": "/usr/bin/false"}),
            json!({"controlAction": 1}),
            json!({"controlAction": "control action/1"}),
        ] {
            assert_eq!(
                exact_identity(&params(fields)).err().unwrap().code,
                "invalidInput"
            );
        }
        assert_eq!(
            exact_identity(&params(json!({"controlAction": "a"}))).unwrap(),
            "a"
        );
        // Restart: exactly the tuple, each member an exact identity or a
        // lowercase digest.
        let digest = "a".repeat(64);
        for fields in [
            json!({}),
            json!({"controlAction": "a", "previewId": "p"}),
            json!({"controlAction": "a", "previewId": "p", "previewDigest": digest.to_uppercase()}),
            json!({"controlAction": "a", "previewId": "p", "previewDigest": "a".repeat(63)}),
            json!({"controlAction": "a b", "previewId": "p", "previewDigest": digest}),
            json!({"controlAction": "a", "previewId": 1, "previewDigest": digest}),
            json!({"controlAction": "a", "previewId": "p", "previewDigest": digest, "x": 1}),
        ] {
            let error = restart_tuple(&params(fields.clone())).err().unwrap();
            assert_eq!(
                (error.code.as_str(), error.message.as_str()),
                (
                    "invalidInput",
                    "restart requires one exact control-action preview tuple"
                ),
                "{fields}"
            );
        }
        assert_eq!(
            restart_tuple(&params(
                json!({"controlAction": "a", "previewId": "p", "previewDigest": digest})
            ))
            .unwrap(),
            ("a", "p", digest.as_str())
        );
    }
}
