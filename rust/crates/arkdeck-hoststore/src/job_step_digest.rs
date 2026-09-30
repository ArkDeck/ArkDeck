//! Swift `RuntimeJobEngine.stepSetDigest`: the digest of a Job's selected
//! Catalog steps, and for `debug.hap@1` its failure-only compensations. The
//! planner computes it (`job_plan::step_set_digest`); the Job record's reader
//! checks a consumed HAP's correlation against it. It is provenance, never
//! dispatch permission.
use crate::operation_catalog::{CatalogOperation, CatalogStep};
use arkdeck_contract::sha256_hex;
use serde_json::{Map, Value};

fn selected_step_lines(descriptor: &CatalogOperation, inputs: &Map<String, Value>) -> Vec<String> {
    descriptor
        .steps
        .iter()
        .filter(|step| descriptor.step_is_selected(step, inputs))
        .map(|step| {
            format!(
                "{}|{}|{}|{}|{}",
                step.step_id, step.kind, step.effect, step.cancellation, step.binding
            )
        })
        .collect()
}

/// Historical Swift stepSetDigest before #1773 added HAP compensation lines.
/// Only the terminal historical-record reader uses this; never admission.
pub(crate) fn historical_hap_step_set_digest(
    descriptor: &CatalogOperation,
    inputs: &Map<String, Value>,
) -> String {
    sha256_hex(
        selected_step_lines(descriptor, inputs)
            .join("\n")
            .as_bytes(),
    )
}

/// Swift RuntimeJobEngine.stepSetDigest; `None` when a `debug.hap@1`
/// descriptor lacks a compensation step it names.
pub(crate) fn step_set_digest(
    descriptor: &CatalogOperation,
    inputs: &Map<String, Value>,
) -> Option<String> {
    let mut lines = selected_step_lines(descriptor, inputs);
    if descriptor.reference() == "debug.hap@1" {
        for step in hap_compensations(descriptor, inputs)? {
            lines.push(format!(
                "compensation-{}|{}|{}|{}|{}",
                step.step_id, step.kind, step.effect, step.cancellation, step.binding
            ));
        }
    }
    Some(sha256_hex(lines.join("\n").as_bytes()))
}

/// A HAP Job's failure-only compensations, in Swift's order, the uninstall
/// only unless the request retains the installation; `None` when the
/// descriptor lacks one of them.
pub(crate) fn hap_compensations<'a>(
    descriptor: &'a CatalogOperation,
    inputs: &Map<String, Value>,
) -> Option<Vec<&'a CatalogStep>> {
    [
        "stop-ability",
        "cleanup-uninstall",
        "cleanup-remote-staging",
    ]
    .into_iter()
    .filter(|id| {
        *id != "cleanup-uninstall"
            || inputs.get("cleanupPolicy").and_then(Value::as_str) != Some("retain")
    })
    .map(|id| descriptor.steps.iter().find(|step| step.step_id == id))
    .collect()
}
