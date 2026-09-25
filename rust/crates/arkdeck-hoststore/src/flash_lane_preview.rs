//! Swift's `flash.lanePlanPreview` (`AgentDaemon.swift` 472-535) after its
//! parameters, as far as this Runtime reaches: the Target named in the
//! Target store, then, with a lane composed, `main.swift`'s
//! `ComposedLanePlanPreviewer` (1377-1409) up to the lane's own call — the
//! Target's facts through the ArkForge provider's port, and the confirmed
//! HDC-normal topology among them.
//!
//! There Swift asks `arkforged`, over its controller session, whether its
//! store holds the archive and what plan it would materialize. This
//! Runtime's ArkForge client has neither call yet, so its preview stops there
//! and fails, saying why: a declared difference, which never reads as an
//! available plan and sends nothing to `arkforged`.
use super::{ALIAS_TOPOLOGY, RockchipFacts, target_records};
use crate::target_owner::TargetStore;
use arkdeck_contract::WireError;
use serde_json::{Value, json};

/// Why this Runtime's preview stops where Swift's asks the lane.
pub const LANE_PREVIEW_UNAVAILABLE: &str = "this Runtime cannot ask arkforged for the lane plan \
     yet: its ArkForge client has no controller-side archive inspection or plan \
     materialization; nothing was sent to arkforged";

/// What the lane plan previewer answered, of Swift's
/// `ArkForgeLanePlanPreviewOutcome`: the two states this Runtime reaches.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LanePreview {
    /// `deviceNotObserved(reason)`: the Target's facts, or a confirmed
    /// HDC-normal topology among them, are missing.
    DeviceNotObserved(String),
    /// `previewFailed(detail)`.
    PreviewFailed(String),
}

/// `ComposedLanePlanPreviewer.preview` over the facts the ArkForge provider
/// resolved for `target_id` (an error is Swift's `"\(error)"` of what it
/// threw), stopping where Swift asks the lane.
pub fn preview_before_lane(facts: Result<RockchipFacts, String>, target_id: &str) -> LanePreview {
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
    LanePreview::PreviewFailed(LANE_PREVIEW_UNAVAILABLE.to_owned())
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
    let (state, reason) = match previewer(&target.target_id) {
        LanePreview::DeviceNotObserved(reason) => ("deviceNotObserved", reason),
        LanePreview::PreviewFailed(reason) => ("previewFailed", reason),
    };
    fields["state"] = json!(state);
    fields["reason"] = json!(reason);
    Ok(fields)
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
    fn the_preview_stops_where_swift_asks_the_lane() {
        assert_eq!(
            preview_before_lane(Err("storeFailure(\"x\")".into()), "TGT-HOST"),
            LanePreview::DeviceNotObserved(
                "target facts could not be resolved: storeFailure(\"x\")".into()
            )
        );
        for missing in [None, Some("")] {
            assert_eq!(
                preview_before_lane(Ok(facts(missing)), "TGT-HOST"),
                LanePreview::DeviceNotObserved(
                    "no confirmed HDC-normal USB topology for TGT-HOST".into()
                )
            );
        }
        assert_eq!(
            preview_before_lane(Ok(facts(Some("18874368"))), "TGT-HOST"),
            LanePreview::PreviewFailed(LANE_PREVIEW_UNAVAILABLE.into())
        );
    }
}
