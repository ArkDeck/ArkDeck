//! Swift's read-only lane preview projection over resolved Target facts.
use super::{ALIAS_TOPOLOGY, RockchipFacts, target_records};
use crate::target_owner::TargetStore;
use arkdeck_contract::WireError;
use serde_json::{Value, json};

pub use arkdeck_provider_arkforge::LanePreview;

/// `ComposedLanePlanPreviewer.preview` over the facts the ArkForge provider
/// resolved for `target_id` (an error is Swift's `"\(error)"` of what it
/// threw), then asks the composed lane only for a confirmed topology.
pub fn preview_before_lane(
    facts: Result<RockchipFacts, String>,
    target_id: &str,
    preview: &dyn Fn(&str) -> LanePreview,
) -> LanePreview {
    let facts = match facts {
        Ok(facts) => facts,
        Err(error) => {
            return LanePreview::DeviceNotObserved(format!(
                "target facts could not be resolved: {error}"
            ));
        }
    };
    if !facts
        .server_facts
        .get(ALIAS_TOPOLOGY)
        .is_some_and(|topology| !topology.is_empty())
    {
        return LanePreview::DeviceNotObserved(format!(
            "no confirmed HDC-normal USB topology for {target_id}"
        ));
    }
    preview(
        facts
            .server_facts
            .get(ALIAS_TOPOLOGY)
            .expect("confirmed topology"),
    )
}

/// Swift's handler once its parameters were read: the Target, its identity
/// and revision, and the previewer's state for it, or `laneNotComposed`
/// when no lane was composed (`previewer` is none). A Target store that
/// cannot be read is refused with its failure, as Swift's handler catches it.
pub fn lane_plan_preview(
    targets: &TargetStore,
    target_id: &str,
    previewer: Option<&dyn Fn(&str) -> LanePreview>,
) -> Result<Value, WireError> {
    let target = target_records(targets)
        .map_err(|error| WireError {
            code: "rejected".into(),
            message: format!("lane plan preview could not resolve the target: {error}"),
            details: None,
        })?
        .into_iter()
        .find(|target| target.target_id == target_id)
        .ok_or_else(|| WireError {
            code: "notFound".into(),
            message: "target is not adopted".into(),
            details: None,
        })?;
    let mut fields = json!({
        "targetId": target.target_id,
        "bindingRevision": target.binding_revision,
    });
    let Some(previewer) = previewer else {
        fields["state"] = json!("laneNotComposed");
        return Ok(fields);
    };
    project_outcome(&mut fields, previewer(&target.target_id));
    Ok(fields)
}

fn project_outcome(fields: &mut Value, outcome: LanePreview) {
    match outcome {
        LanePreview::Available {
            plan_id,
            plan_sha256,
            observation_mode,
        } => {
            fields["state"] = json!("available");
            fields["planId"] = json!(plan_id);
            fields["planSha256"] = json!(plan_sha256);
            fields["observationMode"] = json!(observation_mode);
        }
        LanePreview::BundleNotInLaneStore => fields["state"] = json!("bundleNotInLaneStore"),
        LanePreview::DeviceNotObserved(reason) => {
            fields["state"] = json!("deviceNotObserved");
            fields["reason"] = json!(reason);
        }
        LanePreview::PreviewFailed(reason) => {
            fields["state"] = json!("previewFailed");
            fields["reason"] = json!(reason);
        }
        LanePreview::PlanNotExecutable {
            availability,
            reason,
            unknowns,
        } => {
            fields["state"] = json!("planNotExecutable");
            fields["availability"] = json!(availability);
            fields["reason"] = json!(reason);
            let mut entries: Vec<_> = unknowns.iter().collect();
            entries.sort_by_cached_key(|(key, _)| {
                arkdeck_platform::host_canonical_text(key).unwrap_or_else(|| (*key).clone())
            });
            fields["unknowns"] = json!(
                entries
                    .into_iter()
                    .map(|(k, v)| format!("{k}: {v}"))
                    .collect::<Vec<_>>()
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts(topology: Option<&str>) -> RockchipFacts {
        RockchipFacts {
            target_id: "TGT-HOST".into(),
            binding_revision: 2,
            identity_sha256: "a".repeat(64),
            tool_sha256: "b".repeat(64),
            execution_connect_key: "key".into(),
            device_mode: "hdc".into(),
            build_fingerprint: None,
            profile_id: "dayu200".into(),
            server_facts: topology
                .map(|topology| (ALIAS_TOPOLOGY.to_owned(), topology.to_owned()))
                .into_iter()
                .collect(),
        }
    }

    #[test]
    fn facts_fail_closed_before_the_lane_is_asked() {
        assert_eq!(
            preview_before_lane(Err("storeFailure(\"x\")".into()), "TGT-HOST", &|_| panic!(
                "missing facts must not ask the lane"
            )),
            LanePreview::DeviceNotObserved(
                "target facts could not be resolved: storeFailure(\"x\")".into()
            )
        );
        for missing in [None, Some("")] {
            assert_eq!(
                preview_before_lane(Ok(facts(missing)), "TGT-HOST", &|_| panic!(
                    "missing facts must not ask the lane"
                )),
                LanePreview::DeviceNotObserved(
                    "no confirmed HDC-normal USB topology for TGT-HOST".into()
                )
            );
        }
        assert_eq!(
            preview_before_lane(Ok(facts(Some("18874368"))), "TGT-HOST", &|topology| {
                assert_eq!(topology, "18874368");
                LanePreview::BundleNotInLaneStore
            }),
            LanePreview::BundleNotInLaneStore
        );
    }
    #[test]
    fn preview_projection_preserves_plan_fields_and_sorted_refusal_details() {
        let mut fields = json!({"targetId":"TGT-HOST", "bindingRevision":2});
        project_outcome(
            &mut fields,
            LanePreview::Available {
                plan_id: "PLAN-1".into(),
                plan_sha256: "a".repeat(64),
                observation_mode: "hdc-normal".into(),
            },
        );
        assert_eq!(
            fields,
            json!({"targetId":"TGT-HOST", "bindingRevision":2, "state":"available", "planId":"PLAN-1", "planSha256":"a".repeat(64), "observationMode":"hdc-normal"})
        );
        let mut fields = json!({});
        project_outcome(
            &mut fields,
            LanePreview::PlanNotExecutable {
                availability: "unavailable".into(),
                reason: "gated".into(),
                unknowns: [
                    ("RK-M02".into(), "mechanics".into()),
                    ("RK-A01".into(), "authority".into()),
                ]
                .into_iter()
                .collect(),
            },
        );
        assert_eq!(
            fields,
            json!({"state":"planNotExecutable", "availability":"unavailable", "reason":"gated", "unknowns":["RK-A01: authority", "RK-M02: mechanics"]})
        );
    }
}
