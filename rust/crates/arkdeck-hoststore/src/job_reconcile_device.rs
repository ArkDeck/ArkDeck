//! The device-bound half of Swift's `reconcileOwned` for the HDC provider:
//! the parked action materialized again from its durable record
//! (`PersistedTypedProviderAction.materialize()`), and the provider's
//! decision — `HDCObservationProviderAdapter.reconcile` for an action below
//! `deviceMutation`, and for a mutation its dedicated readback
//! (`reconciliationReadback`), dispatched once under the reconcile's own step
//! identity and judged by `verifyReconciliationReadback`. The original action
//! is never resent.
//!
//! Only the families below are ported. Every other persisted action is
//! refused by the reconciler before anything is written: the other mutations
//! Swift reads back (owned remote paths, packages, abilities, staging, native
//! libraries), the screen sequence's, and the read-only actions Swift's
//! provider has no reconcile source for, whose answer journals Swift's debug
//! rendering of the action.
use super::{Decision, other};
use crate::artifact_read_owner::swift_string;
use crate::device_facts::{DeviceFacts, HdcComposition};
use arkdeck_contract::{WireError, sha256_hex};
use arkdeck_provider_hdc::{
    Direction, DispatchFailure, Outcome, PointerInput, PortAction, PortRule,
};
use serde_json::{Map, Value};

/// The persisted kinds whose reconcile is ported: Swift's read-only
/// families that its provider confirms not executed, the pointer gesture,
/// which has no readback, and the two port-rule changes, which are read back.
const PORTED: [&str; 11] = [
    "hdc.observeTool",
    "hdc.observeServer",
    "hdc.listDeviceCandidates",
    "hdc.observeDevice",
    "hdc.queryProperty",
    "hdc.observeStorage",
    "hdc.captureHilog",
    "hdc.captureUIDump",
    "hdc.injectPointerInput",
    "hdc.createPortForward",
    "hdc.removePortForward",
];

/// Swift `HDCAllowlistedProperty`.
const PROPERTIES: [&str; 6] = [
    "const.product.model",
    "const.product.name",
    "const.product.software.version",
    "ro.build.characteristics",
    "const.ohos.apiversion",
    "const.ohos.fullname",
];

/// Whether this Runtime reconciles a Job parked on a persisted action of
/// this kind.
pub(super) fn ported(kind: &str) -> bool {
    PORTED.contains(&kind)
}

/// A parked HDC action, as its reconcile needs it.
pub(super) enum DeviceAction {
    /// A family whose effect is below `deviceMutation`, which Swift's HDC
    /// provider confirms not executed: observing again is always safe.
    ReadOnly,
    /// `injectPointerInput`: a mutation with no dedicated readback.
    Pointer,
    /// `createPortForward` or `removePortForward`, read back by `fport ls`.
    Port(PortAction),
}

/// Swift's interpolation of `DeviceProviderError.unsupportedAction`.
fn unsupported(detail: &str) -> WireError {
    other(format!("unsupportedAction({})", swift_string(detail)))
}

/// Swift's interpolation of an `HDCE0RequestError`.
fn out_of_bounds(field: &str, detail: &str) -> WireError {
    other(format!(
        "outOfBounds(field: {}, detail: {})",
        swift_string(field),
        swift_string(detail)
    ))
}

fn malformed(field: &str, detail: &str) -> WireError {
    other(format!(
        "malformed(field: {}, detail: {})",
        swift_string(field),
        swift_string(detail)
    ))
}

/// Swift `PersistedTypedProviderAction.materialize()` for the ported kinds:
/// the same members required, in the same order, and the same typed
/// requests' bounds checked again. Its refusal is Swift's error, which the
/// handler answers `internalError`.
pub(super) fn materialize(action: &Value) -> Result<DeviceAction, WireError> {
    let kind = action["kind"].as_str().unwrap_or_default();
    let empty = Map::new();
    let arguments = action["arguments"].as_object().unwrap_or(&empty);
    let string = |key: &str| {
        arguments
            .get(key)
            .and_then(Value::as_str)
            .ok_or_else(|| unsupported(&format!("persisted {kind} is missing string {key}")))
    };
    let integer = |key: &str| {
        arguments
            .get(key)
            .and_then(Value::as_i64)
            .ok_or_else(|| unsupported(&format!("persisted {kind} is missing integer {key}")))
    };
    let optional_string = |key: &str| match arguments.get(key) {
        None => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.as_str())),
        Some(_) => Err(unsupported(&format!(
            "persisted {kind}.{key} is not a string"
        ))),
    };
    let optional_integer = |key: &str| match arguments.get(key) {
        None => Ok(None),
        Some(value) => value
            .as_i64()
            .map(Some)
            .ok_or_else(|| unsupported(&format!("persisted {kind}.{key} is not an integer"))),
    };
    match kind {
        "hdc.observeTool" | "hdc.observeServer" | "hdc.listDeviceCandidates" => {
            Ok(DeviceAction::ReadOnly)
        }
        "hdc.observeDevice" => string("connectKey").map(|_| DeviceAction::ReadOnly),
        "hdc.queryProperty" => {
            if PROPERTIES.contains(&string("property")?) {
                Ok(DeviceAction::ReadOnly)
            } else {
                Err(unsupported("persisted query property is not allowlisted"))
            }
        }
        "hdc.observeStorage" => {
            // Swift `HDCStoragePreflightRequest.maximumRequiredBytes`.
            let maximum = 8_i64 * 1024 * 1024 * 1024;
            if (1..=maximum).contains(&integer("requiredBytes")?) {
                Ok(DeviceAction::ReadOnly)
            } else {
                Err(out_of_bounds("requiredBytes", &format!("1...{maximum}")))
            }
        }
        "hdc.captureHilog" => {
            let duration = integer("durationSeconds")?;
            let Some(filters) = arguments.get("filters").and_then(Value::as_array) else {
                return Err(unsupported(&format!(
                    "persisted {kind} is missing array filters"
                )));
            };
            let filters = filters
                .iter()
                .map(|filter| {
                    filter.as_str().ok_or_else(|| {
                        unsupported(&format!("persisted {kind}.filters contains a non-string"))
                    })
                })
                .collect::<Result<Vec<&str>, _>>()?;
            let budget = integer("byteBudget")?;
            // Swift `HDCHilogCaptureRequest.init`.
            if !(1..=600).contains(&duration) {
                return Err(out_of_bounds("durationSeconds", "1...600"));
            }
            if filters.len() > 16 {
                return Err(out_of_bounds("filters", "at most 16"));
            }
            if filters.iter().any(|filter| {
                filter.is_empty()
                    || filter.len() > 200
                    || !filter
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b":*./_-".contains(&byte))
            }) {
                return Err(malformed(
                    "filters",
                    "filter tokens are bounded ASCII, no shell fragments",
                ));
            }
            if !(1024..=128 * 1024 * 1024).contains(&budget) {
                return Err(out_of_bounds("byteBudget", "1024...134217728"));
            }
            Ok(DeviceAction::ReadOnly)
        }
        "hdc.captureUIDump" => {
            let scope = string("scope")?;
            if !matches!(scope, "windowList" | "componentDetail") {
                return Err(unsupported("persisted UI dump scope is invalid"));
            }
            let window = optional_string("windowId")?;
            let component = optional_string("componentId")?;
            let budget = integer("byteBudget")?;
            // Swift `HDCUIDumpRequest.init`.
            if !(1024..=64 * 1024 * 1024).contains(&budget) {
                return Err(out_of_bounds("byteBudget", "1024...64MiB"));
            }
            let decimal = |value: Option<&str>| {
                value.is_some_and(|value| {
                    (1..=20).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_digit())
                })
            };
            match scope {
                "windowList" if window.is_some() || component.is_some() => Err(malformed(
                    "scope",
                    "windowList does not accept component identifiers",
                )),
                "componentDetail" if !decimal(window) || !decimal(component) => Err(malformed(
                    "componentDetail",
                    "windowID and componentID must be decimal identifiers",
                )),
                _ => Ok(DeviceAction::ReadOnly),
            }
        }
        "hdc.injectPointerInput" => {
            if arguments.get("gesture").and_then(Value::as_str).is_none() {
                return Err(unsupported(&format!(
                    "persisted {kind} is missing string gesture"
                )));
            }
            for key in ["pointerX", "pointerY", "displayWidth", "displayHeight"] {
                integer(key)?;
            }
            for key in ["pointerToX", "pointerToY", "durationMs", "displayId"] {
                optional_integer(key)?;
            }
            optional_string("screenEpochUtc")?;
            PointerInput::from_persisted(arguments)
                .map(|_| DeviceAction::Pointer)
                .map_err(|error| other(error.to_string()))
        }
        "hdc.createPortForward" | "hdc.removePortForward" => {
            // A record without a direction predates it: a forward rule.
            let direction = match optional_string("direction")? {
                None => Direction::Forward,
                Some(raw) => Direction::parse(raw).ok_or_else(|| {
                    unsupported(&format!(
                        "persisted {kind}.direction is not a closed port direction"
                    ))
                })?,
            };
            let rule = PortRule::new(direction, integer("localPort")?, integer("remotePort")?)
                .map_err(|error| other(error.to_string()))?;
            Ok(DeviceAction::Port(if kind == "hdc.createPortForward" {
                PortAction::Create(rule)
            } else {
                PortAction::Remove(rule)
            }))
        }
        _ => Err(unsupported(&format!(
            "persisted typed provider action kind {kind} is unknown"
        ))),
    }
}

/// Swift `RuntimeJobEngine.reconciliationStepID`: the reconcile's own step
/// identity, which the readback is lowered under.
pub(super) fn reconciliation_step_id(step: &str, attempt: &str) -> String {
    let step: String = step.chars().take(72).collect();
    format!("reconcile-{step}-{}", &sha256_hex(attempt.as_bytes())[..32])
}

/// Swift's interpolation of the `RuntimeDispatchFailure` a dispatch threw.
fn dispatch_failure(failure: &DispatchFailure) -> String {
    match failure {
        DispatchFailure::Refused(reason) => format!("failed({})", swift_string(reason)),
        DispatchFailure::Unobservable(reason) => {
            format!("outcomeUnknown({})", swift_string(reason))
        }
    }
}

/// The provider's decision on a parked HDC action, against the fresh facts
/// the reconcile resolved (Swift `reconcileOwned` from `action.effect`): a
/// family below `deviceMutation` is confirmed not executed; a mutation with
/// no dedicated readback stays unknown; a port rule is read back once.
pub(super) fn decide(
    action: &DeviceAction,
    hdc: &HdcComposition<'_>,
    facts: &DeviceFacts,
    step: &str,
    attempt: &str,
) -> Decision {
    let original = match action {
        DeviceAction::ReadOnly => return Decision::NotExecuted,
        DeviceAction::Pointer => {
            return Decision::Unknown(
                "mutation has no dedicated readback; original not resent".into(),
            );
        }
        DeviceAction::Port(original) => original,
    };
    let failed = |error: String| {
        Decision::Unknown(format!(
            "dedicated readback failed: {error}; original not resent"
        ))
    };
    let Some(readback) = original.readback() else {
        return Decision::Unknown("mutation has no dedicated readback; original not resent".into());
    };
    let plan = match readback.lower(
        &reconciliation_step_id(step, attempt),
        Some(&facts.connect_key),
    ) {
        Ok(plan) => plan,
        Err(error) => return failed(error),
    };
    if !matches!(readback.effect(), "hostOnly" | "readOnly") {
        return failed(format!(
            "internalFailure({})",
            swift_string("mutation reconciliation produced a non-read-only plan")
        ));
    }
    let receipt = match arkdeck_provider_hdc::run(&plan, hdc.dispatch) {
        Ok(receipt) => receipt,
        Err(failure) => return failed(dispatch_failure(&failure)),
    };
    let outcome = match receipt.subprocesses.first() {
        Some(sole) => readback.verify(sole),
        None => Outcome::Unknown("dispatch produced no process result".into()),
    };
    verify_readback(original, &outcome)
}

/// Swift `HDCObservationProviderAdapter.verifyReconciliationReadback` for a
/// port rule: a definite presence equal to the one the change wanted
/// concludes it completed, the other one not executed; anything else stays
/// unknown.
fn verify_readback(original: &PortAction, outcome: &Outcome) -> Decision {
    let present = match outcome {
        Outcome::Verified(summary) => match summary.get("present").map(String::as_str) {
            Some("true") => Some(true),
            Some("false") => Some(false),
            _ => None,
        },
        _ => None,
    };
    let Some(present) = present else {
        return Decision::Unknown("dedicated readback did not produce a definite presence".into());
    };
    let Some(desired) = original.desired_presence() else {
        return Decision::Unknown("readback was not paired with a mutation".into());
    };
    if present == desired {
        Decision::Completed(vec!["postconditionPresent".into()])
    } else {
        Decision::NotExecuted
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::BTreeMap;

    fn refusal(action: Value) -> String {
        match materialize(&action) {
            Err(error) => {
                assert_eq!(error.code, "internalError");
                error.message
            }
            Ok(_) => panic!("{action} materialized"),
        }
    }

    #[test]
    fn the_reconcile_step_identity_is_swifts() {
        let attempt = "recovery-job-f98bab40c1609df91bd30c251cf723da-12";
        assert_eq!(
            reconciliation_step_id("create-port-rule", attempt),
            format!(
                "reconcile-create-port-rule-{}",
                &sha256_hex(attempt.as_bytes())[..32]
            )
        );
        let long = "s".repeat(80);
        assert!(
            reconciliation_step_id(&long, attempt)
                .starts_with(&format!("reconcile-{}-", "s".repeat(72)))
        );
    }

    #[test]
    fn a_persisted_action_is_materialized_as_swift_materializes_it() {
        for action in [
            json!({"kind": "hdc.observeTool", "arguments": {}}),
            json!({"kind": "hdc.observeServer", "arguments": {"ignored": 1}}),
            json!({"kind": "hdc.observeDevice", "arguments": {"connectKey": "resolved-by-binding"}}),
            json!({"kind": "hdc.queryProperty", "arguments": {"property": "const.ohos.fullname"}}),
            json!({"kind": "hdc.observeStorage", "arguments": {"requiredBytes": 134217728}}),
            json!({"kind": "hdc.captureHilog", "arguments": {"durationSeconds": 30,
                "filters": ["A:B", "*"], "byteBudget": 16777216}}),
            json!({"kind": "hdc.captureUIDump", "arguments": {"scope": "windowList",
                "byteBudget": 8388608}}),
            json!({"kind": "hdc.captureUIDump", "arguments": {"scope": "componentDetail",
                "byteBudget": 8388608, "windowId": "12", "componentId": "3"}}),
        ] {
            assert!(
                matches!(materialize(&action), Ok(DeviceAction::ReadOnly)),
                "{action}"
            );
        }
        assert!(matches!(
            materialize(&json!({"kind": "hdc.injectPointerInput", "arguments": {
                "gesture": "tap", "pointerX": 640, "pointerY": 1500,
                "displayWidth": 1280, "displayHeight": 2832}})),
            Ok(DeviceAction::Pointer)
        ));
        let rule = PortRule::new(Direction::Forward, 23461, 34571).unwrap();
        assert!(matches!(
            materialize(&json!({"kind": "hdc.createPortForward", "arguments": {
                "direction": "forward", "localPort": 23461, "remotePort": 34571}})),
            Ok(DeviceAction::Port(PortAction::Create(read))) if read == rule
        ));
        // A record written before the direction existed names a forward rule.
        assert!(matches!(
            materialize(&json!({"kind": "hdc.removePortForward", "arguments": {
                "localPort": 23461, "remotePort": 34571}})),
            Ok(DeviceAction::Port(PortAction::Remove(read))) if read == rule
        ));
        for (action, message) in [
            (
                json!({"kind": "hdc.observeDevice", "arguments": {}}),
                "unsupportedAction(\"persisted hdc.observeDevice is missing string connectKey\")",
            ),
            (
                json!({"kind": "hdc.queryProperty", "arguments": {"property": "persist.sys"}}),
                "unsupportedAction(\"persisted query property is not allowlisted\")",
            ),
            (
                json!({"kind": "hdc.observeStorage", "arguments": {"requiredBytes": 0}}),
                "outOfBounds(field: \"requiredBytes\", detail: \"1...8589934592\")",
            ),
            (
                json!({"kind": "hdc.captureHilog", "arguments": {"durationSeconds": 30,
                    "filters": ["a;b"], "byteBudget": 16777216}}),
                "malformed(field: \"filters\", detail: \"filter tokens are bounded ASCII, no shell fragments\")",
            ),
            (
                json!({"kind": "hdc.captureUIDump", "arguments": {"scope": "windowList",
                    "byteBudget": 8388608, "windowId": "1"}}),
                "malformed(field: \"scope\", detail: \"windowList does not accept component identifiers\")",
            ),
            (
                json!({"kind": "hdc.captureUIDump", "arguments": {"scope": "windowList",
                    "byteBudget": 8388608, "windowId": null}}),
                "unsupportedAction(\"persisted hdc.captureUIDump.windowId is not a string\")",
            ),
            (
                json!({"kind": "hdc.injectPointerInput", "arguments": {"gesture": "tap",
                    "pointerY": 1500, "displayWidth": 1280, "displayHeight": 2832}}),
                "unsupportedAction(\"persisted hdc.injectPointerInput is missing integer pointerX\")",
            ),
            (
                json!({"kind": "hdc.createPortForward", "arguments": {"direction": "sideways",
                    "localPort": 23461, "remotePort": 34571}}),
                "unsupportedAction(\"persisted hdc.createPortForward.direction is not a closed port direction\")",
            ),
            (
                json!({"kind": "hdc.createPortForward", "arguments": {"direction": "forward",
                    "localPort": 80, "remotePort": 34571}}),
                "outOfBounds(field: \"localPort\", detail: \"1024...65535\")",
            ),
        ] {
            assert_eq!(refusal(action), message);
        }
        assert!(!ported("hdc.readPortForwardPresence"));
        assert!(!ported("hdc.captureCrashIndex"));
        assert!(!ported("hdc.captureTrace"));
        assert!(!ported("hdc.receiveOwnedArtifact"));
        assert!(ported("hdc.createPortForward"));
    }

    #[test]
    fn a_port_rule_readback_concludes_as_swift_verifies_it() {
        let rule = PortRule::new(Direction::Forward, 23461, 34571).unwrap();
        let present = |value: &str| {
            Outcome::Verified(BTreeMap::from([("present".to_owned(), value.to_owned())]))
        };
        let create = PortAction::Create(rule.clone());
        let remove = PortAction::Remove(rule.clone());
        assert!(matches!(
            verify_readback(&create, &present("true")),
            Decision::Completed(keys) if keys == ["postconditionPresent"]
        ));
        assert!(matches!(
            verify_readback(&create, &present("false")),
            Decision::NotExecuted
        ));
        assert!(matches!(
            verify_readback(&remove, &present("false")),
            Decision::Completed(_)
        ));
        assert!(matches!(
            verify_readback(&remove, &present("true")),
            Decision::NotExecuted
        ));
        for indefinite in [
            Outcome::Unknown("port-forward presence readback is not trustworthy".into()),
            present("TRUE"),
            Outcome::Verified(BTreeMap::new()),
        ] {
            assert!(matches!(
                verify_readback(&create, &indefinite),
                Decision::Unknown(reason)
                    if reason == "dedicated readback did not produce a definite presence"
            ));
        }
        assert!(matches!(
            verify_readback(&PortAction::ReadPresence(rule), &present("true")),
            Decision::Unknown(reason) if reason == "readback was not paired with a mutation"
        ));
        assert_eq!(
            dispatch_failure(&DispatchFailure::Refused("dispatch refused: gone".into())),
            "failed(\"dispatch refused: gone\")"
        );
        assert_eq!(
            dispatch_failure(&DispatchFailure::Unobservable("process timed out".into())),
            "outcomeUnknown(\"process timed out\")"
        );
    }
}
