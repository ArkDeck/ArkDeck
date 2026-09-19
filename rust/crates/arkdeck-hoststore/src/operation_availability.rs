//! Host discovery for executable Rust operations. It never materializes a
//! request, reads device facts, admits a Job or establishes target readiness.
use crate::AnalyzerProfile;

pub struct OperationAvailabilityContext<'a> {
    pub planning_owner: bool,
    pub job_owner: bool,
    pub artifacts: bool,
    pub analyzer: Option<&'a AnalyzerProfile>,
    pub hdc_registered: bool,
    pub hdc_tool_current: bool,
    pub mutation_owner: bool,
}

/// Swift RuntimeJobEngine.operationAvailability's provider, dispatcher and
/// Artifact checks, limited to the operations this Rust executor can run.
/// None preserves provider_not_registered. Unsupported plans must never turn
/// executable just because the planner can materialize them.
pub fn operation_unavailability(
    reference: &str,
    provider: &str,
    context: &OperationAvailabilityContext<'_>,
) -> Option<Vec<(&'static str, String)>> {
    if !context.planning_owner
        || !["hdc", "analyzer"].contains(&provider)
        || (provider == "hdc" && !context.hdc_registered)
    {
        return None;
    }
    let mut reasons = Vec::new();
    let pointer = ["input.tap@1", "input.long-press@1", "input.swipe@1"].contains(&reference);
    if pointer && !context.mutation_owner {
        reasons.push((
            "provider_tool_unavailable",
            "runtime.mutationOwnerUnavailable".into(),
        ));
    }

    let supported = match provider {
        "hdc" => crate::device_run::runs(reference),
        "analyzer" => reference == "analyzer.extract-crash-signature@1",
        _ => false,
    };
    if !supported {
        reasons.push((
            "operation_not_supported",
            format!("Rust {provider} provider has no complete production executor for {reference}"),
        ));
    } else if provider == "analyzer" {
        match context.analyzer {
            None => reasons.push((
                "provider_tool_unavailable",
                "analyzer.profileUnavailable".into(),
            )),
            Some(profile) if !profile.still_matches() => {
                reasons.push(("tool_identity_drift", "analyzer.toolIdentityDrift".into()))
            }
            Some(_) => {}
        }
    } else if !context.hdc_tool_current {
        reasons.push(("tool_identity_drift", "hdc.toolIdentityDrift".into()));
    }
    if !context.job_owner {
        reasons.push((
            "provider_tool_unavailable",
            "runtime.jobOwnerUnavailable".into(),
        ));
    }
    // All three implemented operations publish through the Artifact owner.
    // Unsupported operations remain unavailable without pretending to resolve
    // their not-yet-implemented Artifact requirements.
    if supported && !context.artifacts {
        reasons.push((
            "artifact_store_unavailable",
            "runtime.artifactStoreUnavailable".into(),
        ));
    }
    Some(reasons)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn context() -> OperationAvailabilityContext<'static> {
        OperationAvailabilityContext {
            planning_owner: true,
            job_owner: true,
            artifacts: true,
            analyzer: None,
            hdc_registered: true,
            hdc_tool_current: true,
            mutation_owner: false,
        }
    }
    #[test]
    fn only_executors_are_available_and_missing_owners_keep_their_actual_reason() {
        let mut c = context();
        for reference in ["observe.device@1", "capture.diagnostics@1"] {
            assert!(
                operation_unavailability(reference, "hdc", &c)
                    .unwrap()
                    .is_empty()
            );
        }
        for reference in ["input.tap@1", "input.long-press@1", "input.swipe@1"] {
            assert_eq!(
                operation_unavailability(reference, "hdc", &c).unwrap()[0],
                (
                    "provider_tool_unavailable",
                    "runtime.mutationOwnerUnavailable".into()
                )
            );
            c.mutation_owner = true;
            assert!(
                operation_unavailability(reference, "hdc", &c)
                    .unwrap()
                    .is_empty()
            );
            c.mutation_owner = false;
        }
        assert_eq!(
            operation_unavailability("debug.hap@1", "hdc", &c).unwrap()[0].0,
            "operation_not_supported"
        );
        assert_eq!(
            operation_unavailability("analyzer.extract-crash-signature@1", "analyzer", &c).unwrap()
                [0],
            (
                "provider_tool_unavailable",
                "analyzer.profileUnavailable".into()
            )
        );
        c.artifacts = false;
        c.job_owner = false;
        c.hdc_tool_current = false;
        let reasons = operation_unavailability("observe.device@1", "hdc", &c).unwrap();
        assert_eq!(
            reasons.iter().map(|(code, _)| *code).collect::<Vec<_>>(),
            [
                "tool_identity_drift",
                "provider_tool_unavailable",
                "artifact_store_unavailable"
            ]
        );
        c.hdc_registered = false;
        assert!(operation_unavailability("observe.device@1", "hdc", &c).is_none());
        c.planning_owner = false;
        assert!(
            operation_unavailability("analyzer.extract-crash-signature@1", "analyzer", &c)
                .is_none()
        );
    }
}
