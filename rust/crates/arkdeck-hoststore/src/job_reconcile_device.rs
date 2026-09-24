//! The device-bound half of Swift's `reconcileOwned` for the HDC provider:
//! the parked action materialized again from its durable record
//! (`PersistedTypedProviderAction.materialize()`), and the provider's
//! decision — `HDCObservationProviderAdapter.reconcile` for an action below
//! `deviceMutation`, and for a mutation its dedicated readback
//! (`reconciliationReadback`), dispatched once under the reconcile's own step
//! identity and judged by `verifyReconciliationReadback`. The original action
//! is never resent.
//!
//! The families ported: the read-only ones Swift's provider confirms not
//! executed (the observations, the bounded captures, a received file, a debug
//! template, a debug HAP's package and process readbacks, application
//! liveness, a native inspection); the pointer gesture, which has no
//! readback; and every mutation Swift reads back — the port rules (`fport
//! ls`), a debug HAP's staging, packages and ability (the owned path or
//! directory, `bm dump`, `pidof`), a diagnostic capture's owned file (`ls
//! -ld`), and a native library deployment's steps (its own inspection, whose
//! verdict table never calls a publish or a rollback not executed). Every
//! other persisted action is refused by the reconciler before anything is
//! written: the read-only actions Swift's provider has no reconcile source
//! for, whose answer journals Swift's debug rendering of the action.
//!
//! Two declared differences from Swift, each a Swift defect fixed here under
//! the maintainer's rule of 2026-09-20 (applied by the coordinating session
//! on 2026-09-24). A screen sequence's capture and cleanup, whose kinds
//! Swift's materialization does not know — so that there a reconcile of
//! either, once begun, fails, and the Job can never be concluded — are read
//! back as a capture file leg is (`ls -ld` of the archive and the frames
//! directory, [`ParkedScreenSequence`]); what those probes cannot settle
//! stays parked. And a receive or a cleanup of a JPEG still is rebuilt with
//! the still's own suffix, where Swift rebuilds the `.png` the device never
//! wrote and refuses the record.
use super::{Decision, other};
use crate::artifact_read_owner::swift_string;
use crate::device_facts::{DeviceFacts, HdcComposition};
use crate::device_steps::{StepAction, StepContext, refusal_detail};
use arkdeck_contract::{WireError, sha256_hex};
use arkdeck_provider_hdc::{
    DebugReadTemplate, Direction, DispatchFailure, Expected, FileAction, FileActionError,
    HapAction, NativeAction, Outcome, OwnedRemotePath, ParkedScreenSequence, PointerInput,
    PortAction, PortRule, Reconcile,
};
use serde_json::{Map, Value};

/// The persisted kinds whose reconcile is ported: Swift's read-only families
/// that its provider confirms not executed, the pointer gesture, which has no
/// readback, every mutation Swift reads back, and the screen sequence's two,
/// which Swift's materialization does not know and this Runtime reads back.
const PORTED: [&str; 38] = [
    "hdc.observeTool",
    "hdc.observeServer",
    "hdc.listDeviceCandidates",
    "hdc.observeDevice",
    "hdc.queryProperty",
    "hdc.observeStorage",
    "hdc.captureHilog",
    "hdc.captureUIDump",
    "hdc.receiveOwnedArtifact",
    "hdc.runDebugTemplate",
    "hdc.queryPackageReadback",
    "hdc.verifyProcessState",
    "hdc.observeApplicationLiveness",
    "hdc.inspectNativeLibrary",
    "hdc.injectPointerInput",
    "hdc.createPortForward",
    "hdc.removePortForward",
    "hdc.sendArtifactToStaging",
    "hdc.sendPackageSetToStaging",
    "hdc.installPackage",
    "hdc.installPackageSet",
    "hdc.startAbility",
    "hdc.stopAbility",
    "hdc.uninstallPackage",
    "hdc.cleanupStagedPackageSet",
    "hdc.cleanupOwnedRemotePath",
    "hdc.captureTrace",
    "hdc.captureComponentTree",
    "hdc.captureScreenshot",
    "hdc.sendNativeLibraryToStaging",
    "hdc.backupNativeLibrary",
    "hdc.publishNativeLibrary",
    "hdc.stopNativeTarget",
    "hdc.startNativeTarget",
    "hdc.cleanupNativeLibrary",
    "hdc.rollbackNativeLibrary",
    "hdc.captureScreenSequence",
    "hdc.cleanupScreenSequence",
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

/// Swift's answer for a mutation `reconciliationReadback` gives no probe.
const NO_READBACK: &str = "mutation has no dedicated readback; original not resent";

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
    /// A debug HAP's staging, package or ability mutation, or a cleanup of
    /// an owned path, read back by the presence it leaves.
    Hap(HapAction),
    /// A diagnostic capture that writes the provider-owned file named here,
    /// read back by that file's presence.
    Written(OwnedRemotePath),
    /// A native library deployment's mutation, read back by its inspection.
    Native(Box<NativeAction>),
    /// A screen sequence's capture or cleanup, read back by the presence of
    /// its archive and frames directory (a declared difference: Swift cannot
    /// materialize either kind).
    Sequence(ParkedScreenSequence),
}

/// Swift's interpolation of `DeviceProviderError.unsupportedAction`, which
/// describes itself by its detail alone.
fn unsupported(detail: &str) -> WireError {
    other(detail)
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

/// A provider's refusal of a persisted action, as Swift interpolates it.
fn refused(error: FileActionError) -> WireError {
    other(refusal_detail(error))
}

/// Swift `PersistedTypedProviderAction.materialize()` for the ported kinds:
/// the same members required, in the same order, and the same typed
/// requests' bounds checked again. Its refusal is Swift's error, which the
/// handler answers `internalError`. A kind Swift's materialization does not
/// know is refused as Swift refuses it.
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
        "hdc.runDebugTemplate" => DebugReadTemplate::parse(string("templateId")?)
            .map(|_| DeviceAction::ReadOnly)
            .ok_or_else(|| unsupported("persisted debug template is not in the closed set")),
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
                .map_err(refused)
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
        _ => family_action(kind, arguments),
    }
}

/// The kinds each of a debug HAP's, a native deployment's and a diagnostic
/// capture's families rebuilds (a cleanup of an owned path as the debug
/// HAP's family rebuilds it: the one action both run), the screen
/// sequence's two, which only this Runtime reads, or Swift's refusal of a
/// kind no family knows.
fn family_action(kind: &str, arguments: &Map<String, Value>) -> Result<DeviceAction, WireError> {
    if let Some(action) = HapAction::from_persisted(kind, arguments).map_err(refused)? {
        return Ok(if action.effect() == "readOnly" {
            DeviceAction::ReadOnly
        } else {
            DeviceAction::Hap(action)
        });
    }
    if let Some(action) = NativeAction::from_persisted(kind, arguments).map_err(refused)? {
        return Ok(if action.effect() == "readOnly" {
            DeviceAction::ReadOnly
        } else {
            DeviceAction::Native(Box::new(action))
        });
    }
    if let Some(action) = FileAction::from_persisted(kind, arguments).map_err(refused)? {
        return Ok(match action.written_path() {
            Some(path) => DeviceAction::Written(path.clone()),
            None => DeviceAction::ReadOnly,
        });
    }
    if let Some(parked) = ParkedScreenSequence::from_persisted(kind, arguments).map_err(refused)? {
        return Ok(DeviceAction::Sequence(parked));
    }
    Err(unsupported(&format!(
        "persisted typed provider action kind {kind} is unknown"
    )))
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

/// Swift's answer for a readback that could not be lowered or dispatched.
fn failed(error: String) -> Decision {
    Decision::Unknown(format!(
        "dedicated readback failed: {error}; original not resent"
    ))
}

/// The provider's decision on a parked HDC action, against the fresh facts
/// the reconcile resolved (Swift `reconcileOwned` from `action.effect`): a
/// family below `deviceMutation` is confirmed not executed; a mutation with
/// no dedicated readback stays unknown; any other is read back once.
pub(super) fn decide(
    action: &DeviceAction,
    hdc: &HdcComposition<'_>,
    facts: &DeviceFacts,
    job_id: &str,
    step: &str,
    attempt: &str,
) -> Decision {
    // Swift `reconciliationReadback` lowers the probe, which must be at most
    // read-only; one dispatch, then its verdict.
    let read = |readback: &StepAction| -> Result<Outcome, Decision> {
        let context = StepContext {
            job_id,
            resolved: &[],
            library: None,
            helper: hdc.code_sign_helper,
        };
        let plan = readback
            .plan(
                &reconciliation_step_id(step, attempt),
                Some(&facts.connect_key),
                &context,
            )
            .map_err(failed)?;
        if !matches!(readback.effect(), "hostOnly" | "readOnly") {
            return Err(failed(format!(
                "internalFailure({})",
                swift_string("mutation reconciliation produced a non-read-only plan")
            )));
        }
        let receipt = arkdeck_provider_hdc::run(&plan, hdc.dispatch)
            .map_err(|failure| failed(dispatch_failure(&failure)))?;
        let unbound = Expected {
            connect_key: None,
            identity_sha256: None,
            tool_version: None,
        };
        Ok(readback.verify(&receipt, unbound, None))
    };
    let presence = |readback: Option<StepAction>, desired: Option<bool>| match readback {
        None => Decision::Unknown(NO_READBACK.into()),
        Some(readback) => match read(&readback) {
            Ok(outcome) => verify_presence(desired, &outcome),
            Err(decision) => decision,
        },
    };
    match action {
        DeviceAction::ReadOnly => Decision::NotExecuted,
        DeviceAction::Pointer => Decision::Unknown(NO_READBACK.into()),
        DeviceAction::Port(original) => presence(
            original.readback().map(StepAction::Port),
            original.desired_presence(),
        ),
        DeviceAction::Hap(original) => presence(
            original.readback().map(StepAction::Hap),
            original.desired_presence(),
        ),
        DeviceAction::Written(path) => presence(
            Some(StepAction::Hap(HapAction::ReadOwnedPathPresence {
                path: path.clone(),
            })),
            Some(true),
        ),
        DeviceAction::Native(original) => {
            let Some(readback) = original.readback() else {
                return Decision::Unknown(NO_READBACK.into());
            };
            match read(&StepAction::Native(Box::new(readback))) {
                Ok(outcome) => concluded(original.reconcile(outcome)),
                Err(decision) => decision,
            }
        }
        // Each probe dispatched once, in order; one that cannot be lowered
        // or dispatched leaves the step unknown, and nothing is resent.
        DeviceAction::Sequence(parked) => {
            let mut presences = Vec::new();
            for probe in parked.readbacks() {
                match read(&StepAction::Hap(probe)) {
                    Ok(outcome) => presences.push(definite_presence(&outcome)),
                    Err(decision) => return decision,
                }
            }
            concluded(parked.reconcile(&presences))
        }
    }
}

/// A provider's reconcile outcome as the reconcile's decision.
fn concluded(outcome: Reconcile) -> Decision {
    match outcome {
        Reconcile::ConfirmedCompleted(summary) => {
            Decision::Completed(summary.into_keys().collect())
        }
        Reconcile::ConfirmedNotExecuted => Decision::NotExecuted,
        Reconcile::StillUnknown(reason) => Decision::Unknown(reason),
    }
}

/// What a presence probe showed: the path there or not, or nothing definite.
fn definite_presence(outcome: &Outcome) -> Option<bool> {
    match outcome {
        Outcome::Verified(summary) => match summary.get("present").map(String::as_str) {
            Some("true") => Some(true),
            Some("false") => Some(false),
            _ => None,
        },
        _ => None,
    }
}

/// Swift `HDCObservationProviderAdapter.verifyReconciliationReadback` for a
/// presence readback: a definite presence equal to the one the mutation
/// wanted concludes it completed, the other one not executed; anything else
/// stays unknown.
fn verify_presence(desired: Option<bool>, outcome: &Outcome) -> Decision {
    let Some(present) = definite_presence(outcome) else {
        return Decision::Unknown("dedicated readback did not produce a definite presence".into());
    };
    let Some(desired) = desired else {
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
        let job = "job-0123456789abcdef0123456789abcdef";
        let owned = |step: &str, suffix: &str| {
            json!({"jobId": job, "stepId": step, "nonce": "owned",
                "remotePath": format!("/data/local/tmp/arkdeck-{job}-{step}-owned{suffix}")})
        };
        let with = |mut arguments: Value, extra: Value| {
            for (key, value) in extra.as_object().unwrap() {
                arguments[key] = value.clone();
            }
            arguments
        };
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
            json!({"kind": "hdc.runDebugTemplate", "arguments": {"templateId": "device.uptime"}}),
            json!({"kind": "hdc.queryPackageReadback",
                "arguments": {"bundleName": "com.example.demo"}}),
            json!({"kind": "hdc.verifyProcessState",
                "arguments": {"bundleName": "com.example.demo"}}),
            json!({"kind": "hdc.observeApplicationLiveness", "arguments": {
                "bundleName": "com.example.demo", "processName": "com.example.demo"}}),
            json!({"kind": "hdc.receiveOwnedArtifact", "arguments": with(
                owned("capture-ui-tree", ".json"), json!({"maximumBytes": 16777216}))}),
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
        // A debug HAP's mutations and a cleanup of an owned path, whichever
        // operation ran it, are read back through the debug HAP's family.
        for (action, readback) in [
            (
                json!({"kind": "hdc.installPackage", "arguments": with(owned("send-hap", ".hap"),
                    json!({"artifactLeaseId": "lease-v1:job-input-hap:ART-1",
                        "bundleName": "com.example.demo"}))}),
                "hdc.readPackagePresence",
            ),
            (
                json!({"kind": "hdc.startAbility", "arguments": {
                    "bundleName": "com.example.demo", "abilityName": "EntryAbility"}}),
                "hdc.readProcessPresence",
            ),
            (
                json!({"kind": "hdc.cleanupOwnedRemotePath",
                    "arguments": owned("capture-ui-tree", ".json")}),
                "hdc.readOwnedPathPresence",
            ),
        ] {
            let Ok(DeviceAction::Hap(original)) = materialize(&action) else {
                panic!("{action}");
            };
            assert_eq!(original.readback().unwrap().persisted().0, readback);
        }
        // A capture's owned file, whose suffix follows its step and type.
        for (action, path) in [
            (
                json!({"kind": "hdc.captureComponentTree",
                    "arguments": owned("capture-ui-tree", ".json")}),
                format!("/data/local/tmp/arkdeck-{job}-capture-ui-tree-owned.json"),
            ),
            (
                json!({"kind": "hdc.captureScreenshot", "arguments": with(
                    owned("capture-screenshot", ".jpeg"), json!({"imageType": "jpeg"}))}),
                format!("/data/local/tmp/arkdeck-{job}-capture-screenshot-owned.jpeg"),
            ),
            (
                json!({"kind": "hdc.captureTrace", "arguments": with(
                    owned("capture-trace", ".htrace"), json!({"durationSeconds": 5,
                        "categories": ["ability"], "bufferKB": 4096}))}),
                format!("/data/local/tmp/arkdeck-{job}-capture-trace-owned.htrace"),
            ),
        ] {
            let Ok(DeviceAction::Written(written)) = materialize(&action) else {
                panic!("{action}");
            };
            assert_eq!(written.remote_path, path);
        }
        for (action, message) in [
            (
                json!({"kind": "hdc.observeDevice", "arguments": {}}),
                "persisted hdc.observeDevice is missing string connectKey",
            ),
            (
                json!({"kind": "hdc.queryProperty", "arguments": {"property": "persist.sys"}}),
                "persisted query property is not allowlisted",
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
                "persisted hdc.captureUIDump.windowId is not a string",
            ),
            (
                json!({"kind": "hdc.injectPointerInput", "arguments": {"gesture": "tap",
                    "pointerY": 1500, "displayWidth": 1280, "displayHeight": 2832}}),
                "persisted hdc.injectPointerInput is missing integer pointerX",
            ),
            (
                json!({"kind": "hdc.createPortForward", "arguments": {"direction": "sideways",
                    "localPort": 23461, "remotePort": 34571}}),
                "persisted hdc.createPortForward.direction is not a closed port direction",
            ),
            (
                json!({"kind": "hdc.createPortForward", "arguments": {"direction": "forward",
                    "localPort": 80, "remotePort": 34571}}),
                "outOfBounds(field: \"localPort\", detail: \"1024...65535\")",
            ),
            (
                json!({"kind": "hdc.runDebugTemplate", "arguments": {"templateId": "shell"}}),
                "persisted debug template is not in the closed set",
            ),
            (
                json!({"kind": "hdc.captureComponentTree", "arguments": with(
                    owned("capture-ui-tree", ".json"),
                    json!({"remotePath": "/data/local/tmp/elsewhere.json"}))}),
                "persisted hdc.captureComponentTree remote path does not match its owned components",
            ),
            // A screen sequence's frames directory is owned as its archive is.
            (
                json!({"kind": "hdc.cleanupScreenSequence", "arguments": with(
                    owned("capture-screen-sequence", ".tar"), json!({"frameCount": 3,
                        "framesDirectory": "/data/local/tmp/elsewhere-frames"}))}),
                "persisted hdc.cleanupScreenSequence frames directory does not match its owned \
                 components",
            ),
            (
                json!({"kind": "hdc.captureScreenSequence", "arguments": owned(
                    "capture-screen-sequence", ".tar")}),
                "persisted hdc.captureScreenSequence is missing string framesDirectory",
            ),
            (
                json!({"kind": "hdc.receiveOwnedArtifact", "arguments": with(
                    owned("capture-screenshot", ".gif"), json!({"maximumBytes": 67108864}))}),
                "persisted hdc.receiveOwnedArtifact remote path does not match its owned components",
            ),
        ] {
            assert_eq!(refusal(action), message);
        }
        // Declared differences from Swift, whose materialization refuses
        // them: a JPEG still's receive and cleanup are read with the still's
        // own suffix, and a screen sequence's capture and cleanup are read
        // back through the paths they own.
        assert!(matches!(
            materialize(
                &json!({"kind": "hdc.receiveOwnedArtifact", "arguments": with(
                owned("capture-screenshot", ".jpeg"), json!({"maximumBytes": 67108864,
                    "expectedLeadingBytes": "ffd8ffe0"}))})
            ),
            Ok(DeviceAction::ReadOnly)
        ));
        let Ok(DeviceAction::Hap(still)) =
            materialize(&json!({"kind": "hdc.cleanupOwnedRemotePath",
            "arguments": owned("capture-screenshot", ".jpeg")}))
        else {
            panic!("a JPEG still's cleanup");
        };
        assert_eq!(
            still.readback(),
            Some(HapAction::ReadOwnedPathPresence {
                path: OwnedRemotePath::stable(
                    job,
                    "capture-screenshot",
                    arkdeck_provider_hdc::ImageType::Jpeg
                )
                .unwrap()
            })
        );
        let frames = format!("/data/local/tmp/arkdeck-{job}-capture-screen-sequence-owned-frames");
        for (kind, extra, cleanup) in [
            (
                "hdc.captureScreenSequence",
                json!({"framesDirectory": frames, "frameCount": 3, "imageType": "jpeg"}),
                false,
            ),
            (
                "hdc.cleanupScreenSequence",
                json!({"framesDirectory": frames, "frameCount": 3}),
                true,
            ),
        ] {
            let action = json!({"kind": kind,
                "arguments": with(owned("capture-screen-sequence", ".tar"), extra)});
            let Ok(DeviceAction::Sequence(parked)) = materialize(&action) else {
                panic!("{action}");
            };
            assert_eq!(parked.cleanup, cleanup);
            assert_eq!(parked.frames.remote_path, frames);
            assert_eq!(
                parked.archive.remote_path,
                format!("/data/local/tmp/arkdeck-{job}-capture-screen-sequence-owned.tar")
            );
        }
        for kind in [
            "hdc.readPortForwardPresence",
            "hdc.readPackagePresence",
            "hdc.readProcessPresence",
            "hdc.readOwnedPathPresence",
            "hdc.readOwnedDirectoryPresence",
            "hdc.captureCrashIndex",
            "hdc.captureCrashLog",
        ] {
            assert!(!ported(kind), "{kind}");
        }
        for kind in [
            "hdc.createPortForward",
            "hdc.installPackage",
            "hdc.publishNativeLibrary",
            "hdc.captureComponentTree",
            "hdc.captureScreenSequence",
        ] {
            assert!(ported(kind), "{kind}");
        }
    }

    /// A dispatcher answering each probe from a script in order, and
    /// recording every argv it was given.
    struct Scripted {
        answers: std::sync::Mutex<Vec<Result<arkdeck_provider_hdc::Receipt, DispatchFailure>>>,
        seen: std::sync::Mutex<Vec<Vec<String>>>,
    }

    impl arkdeck_provider_hdc::HdcDispatch for Scripted {
        fn dispatch(
            &self,
            plan: &arkdeck_provider_hdc::ProcessPlan,
        ) -> Result<arkdeck_provider_hdc::Receipt, DispatchFailure> {
            self.seen.lock().unwrap().push(plan.arguments.clone());
            self.answers.lock().unwrap().remove(0)
        }
    }

    /// An `ls -ld` answer: one listing line, or the not-found grammar.
    fn listing(
        path: &str,
        present: bool,
    ) -> Result<arkdeck_provider_hdc::Receipt, DispatchFailure> {
        Ok(arkdeck_provider_hdc::Receipt {
            exit_status: 0,
            stdout: if present {
                format!("drwxrwxrwx 2 shell shell 3452 2026-09-14 00:00 {path}\n")
            } else {
                format!("ls: {path}: No such file or directory\n")
            }
            .into_bytes(),
            stderr: Vec::new(),
            truncated: false,
            duration: std::time::Duration::ZERO,
        })
    }

    /// A parked screen sequence step (a declared difference from Swift) is
    /// concluded by `ls -ld` probes alone, each dispatched once under the
    /// reconcile's step identity, and never resent: the capture by its
    /// archive and frames directory, the cleanup by its frames directory;
    /// what the probes cannot settle — a partial capture, an indefinite or
    /// failed probe — stays unknown.
    #[test]
    fn a_parked_screen_sequence_is_concluded_by_its_probes_alone() {
        let job = "job-84892206b79174192e1fb101138299c5";
        let archive = format!("/data/local/tmp/arkdeck-{job}-capture-screen-sequence-owned.tar");
        let frames = format!("/data/local/tmp/arkdeck-{job}-capture-screen-sequence-owned-frames");
        let parked = |kind: &str| {
            let arguments = json!({"jobId": job, "stepId": "capture-screen-sequence",
                "nonce": "owned", "remotePath": archive, "framesDirectory": frames,
                "frameCount": 3, "imageType": "jpeg"});
            materialize(&json!({"kind": kind, "arguments": arguments})).unwrap()
        };
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "reconcile-sequence-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        std::os::unix::fs::DirBuilderExt::mode(&mut std::fs::DirBuilder::new(), 0o700)
            .create(&root)
            .unwrap();
        let targets = crate::TargetStore::open(&root).unwrap();
        let facts = DeviceFacts {
            target_id: "TGT-3ba3f5f43b92".into(),
            binding_revision: 1,
            tool_version: "3.2.0d".into(),
            tool_sha256: "0".repeat(64),
            connect_key: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
            identity: "1".repeat(64),
        };
        let attempt = format!("recovery-{job}-12");
        let decide_with =
            |action: &DeviceAction,
             answers: Vec<Result<arkdeck_provider_hdc::Receipt, DispatchFailure>>| {
                let scripted = Scripted {
                    answers: std::sync::Mutex::new(answers),
                    seen: std::sync::Mutex::new(Vec::new()),
                };
                let hdc = HdcComposition {
                    targets: &targets,
                    dispatch: &scripted,
                    receive_root: None,
                    tool_sha256: &facts.tool_sha256,
                    now: || Some("2026-09-14T00:00:00Z".into()),
                    code_sign_helper: None,
                };
                let decision = decide(
                    action,
                    &hdc,
                    &facts,
                    job,
                    "capture-screen-sequence",
                    &attempt,
                );
                let seen = scripted.seen.into_inner().unwrap();
                assert!(scripted.answers.into_inner().unwrap().is_empty());
                (decision, seen)
            };
        let probe = |path: &str| {
            ["-t", facts.connect_key.as_str(), "shell", "ls", "-ld", path]
                .map(str::to_owned)
                .to_vec()
        };
        let capture = parked("hdc.captureScreenSequence");
        let cleanup = parked("hdc.cleanupScreenSequence");
        // The capture: archive there, completed; nothing there, not
        // executed; frames without their archive, unknown.
        let (decision, seen) = decide_with(
            &capture,
            vec![listing(&archive, true), listing(&frames, true)],
        );
        assert!(matches!(decision, Decision::Completed(keys) if keys == ["postconditionPresent"]));
        assert_eq!(seen, [probe(&archive), probe(&frames)]);
        let (decision, _) = decide_with(
            &capture,
            vec![listing(&archive, false), listing(&frames, false)],
        );
        assert!(matches!(decision, Decision::NotExecuted));
        let (decision, _) = decide_with(
            &capture,
            vec![listing(&archive, false), listing(&frames, true)],
        );
        assert!(matches!(decision, Decision::Unknown(reason)
            if reason == format!("frames directory {frames} remains without its archive \
                {archive}; original not resent")));
        // An answer no presence reads, or a probe that cannot be dispatched,
        // settles nothing; a failed probe ends the reconcile's dispatches.
        let garbled = Ok(arkdeck_provider_hdc::Receipt {
            exit_status: 1,
            stdout: Vec::new(),
            stderr: b"hdc: device offline\n".to_vec(),
            truncated: false,
            duration: std::time::Duration::ZERO,
        });
        let (decision, seen) = decide_with(&capture, vec![garbled, listing(&frames, false)]);
        assert!(matches!(decision, Decision::Unknown(reason)
            if reason == "dedicated readback did not produce a definite presence"));
        assert_eq!(seen.len(), 2);
        let (decision, seen) = decide_with(
            &capture,
            vec![Err(DispatchFailure::Unobservable(
                "process timed out".into(),
            ))],
        );
        assert!(matches!(decision, Decision::Unknown(reason)
            if reason == "dedicated readback failed: outcomeUnknown(\"process timed out\"); \
                original not resent"));
        assert_eq!(seen, [probe(&archive)]);
        // The cleanup: frames directory gone, completed; still there, not
        // executed. Only the directory is probed.
        let (decision, seen) = decide_with(&cleanup, vec![listing(&frames, false)]);
        assert!(matches!(decision, Decision::Completed(keys) if keys == ["postconditionPresent"]));
        assert_eq!(seen, [probe(&frames)]);
        let (decision, _) = decide_with(&cleanup, vec![listing(&frames, true)]);
        assert!(matches!(decision, Decision::NotExecuted));
        drop(targets);
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_presence_readback_concludes_as_swift_verifies_it() {
        let present = |value: &str| {
            Outcome::Verified(BTreeMap::from([("present".to_owned(), value.to_owned())]))
        };
        assert!(matches!(
            verify_presence(Some(true), &present("true")),
            Decision::Completed(keys) if keys == ["postconditionPresent"]
        ));
        assert!(matches!(
            verify_presence(Some(true), &present("false")),
            Decision::NotExecuted
        ));
        assert!(matches!(
            verify_presence(Some(false), &present("false")),
            Decision::Completed(_)
        ));
        assert!(matches!(
            verify_presence(Some(false), &present("true")),
            Decision::NotExecuted
        ));
        for indefinite in [
            Outcome::Unknown("port-forward presence readback is not trustworthy".into()),
            present("TRUE"),
            Outcome::Verified(BTreeMap::new()),
        ] {
            assert!(matches!(
                verify_presence(Some(true), &indefinite),
                Decision::Unknown(reason)
                    if reason == "dedicated readback did not produce a definite presence"
            ));
        }
        assert!(matches!(
            verify_presence(None, &present("true")),
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
