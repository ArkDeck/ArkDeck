//! Target-independent presentation projection. Never materializes or admits a Job.
use crate::{job_plan::step_set_digest, operation_catalog::CatalogOperation};
use arkdeck_contract::CATALOG_DIGEST;
use serde_json::{Map, Value, json};

pub(crate) fn selected_steps(
    descriptor: &CatalogOperation,
    inputs: &Map<String, Value>,
) -> Vec<Value> {
    descriptor
        .steps
        .iter()
        .filter(|step| descriptor.step_is_selected(step, inputs))
        .map(|step| {
            json!({"stepId":step.step_id,"kind":step.kind,"effect":step.effect,
            "cancellation":step.cancellation,"binding":step.binding,"optional":step.optional})
        })
        .collect()
}

/// Offline, compiled-Catalog review for the Flash App's default full restore.
/// No target, Artifact, environment, filesystem, Provider or Runtime authority is read.
/// The operation's execution availability is deliberately not implied by this document.
pub fn flash_catalog_review() -> Value {
    let descriptor =
        CatalogOperation::lookup("flash.full-restore", Some(1)).expect("published Flash operation");
    let inputs = Map::from_iter([("verification".into(), json!("full"))]);
    let mut steps = selected_steps(descriptor, &inputs);
    for step in &mut steps {
        // The existing Flash lane owns these exact named steps; kinds are not authority.
        let lane = matches!(
            step["stepId"].as_str(),
            Some(
                "enter-loader-mode"
                    | "wait-loader-disconnect"
                    | "wait-loader-reconnect"
                    | "rebind-loader-identity"
                    | "flash-partitions"
                    | "verify-flash-readback"
                    | "reboot-device"
                    | "wait-for-hdc"
                    | "rebind-and-verify-build"
            )
        );
        step["executionOwner"] = json!(if lane { "arkforgeLane" } else { "runtimeHost" });
    }
    json!({"schemaVersion":"arkdeck.catalog-review/1", "catalogDigest":CATALOG_DIGEST,
        "operation":descriptor.reference(),"providerId":descriptor.provider,"selectionInputs":inputs,
        "steps":steps,
        "stepSetDigestSHA256":step_set_digest(descriptor, &inputs).expect("published Flash steps"),
        "jobAdmitted":false,"dispatchDisposition":"notDispatched"})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offline_review_matches_the_existing_flash_review_and_frozen_step_digest() {
        let value = flash_catalog_review();
        assert_eq!(value["selectionInputs"], json!({"verification":"full"}));
        assert_eq!(
            value["stepSetDigestSHA256"],
            "c1ab01f8c7c24649080d109c481f9c034ffb73edcc62033684ac8a59875e0b12"
        );
        assert_eq!(value["catalogDigest"], CATALOG_DIGEST);
        assert_eq!(value["jobAdmitted"], false);
        assert_eq!(value["dispatchDisposition"], "notDispatched");
        assert!(value.get("materializedPlanDigest").is_none());
        assert!(value.get("targetId").is_none());
        let descriptor = CatalogOperation::lookup("flash.full-restore", Some(1)).unwrap();
        let inputs = value["selectionInputs"].as_object().unwrap();
        let mut steps = value["steps"].as_array().unwrap().clone();
        for step in &mut steps {
            let owner = step
                .as_object_mut()
                .unwrap()
                .remove("executionOwner")
                .unwrap();
            if step["stepId"] == "capture-post-flash-diagnostics" {
                assert_eq!(owner, "runtimeHost");
            }
            if step["stepId"] == "flash-partitions" {
                assert_eq!(owner, "arkforgeLane");
            }
        }
        assert_eq!(steps, selected_steps(descriptor, inputs));
    }

    #[test]
    fn app_generated_literal_is_exactly_the_runtime_projection() {
        let source = include_str!(
            "../../../../Packages/ArkDeckKit/Sources/ArkDeckCore/FlashReviewCatalogGenerated.swift"
        );
        let (_, rest) = source.split_once("#\"\"\"\n").unwrap();
        let (json, _) = rest.split_once("\n\"\"\"#").unwrap();
        let generated: Value = serde_json::from_str(json).unwrap();
        assert_eq!(
            generated,
            flash_catalog_review(),
            "regenerate with cargo run -p arkdeck-hoststore --example flash_catalog_review"
        );
    }
}
