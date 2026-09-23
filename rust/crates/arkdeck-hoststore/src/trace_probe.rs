//! `trace.probe` against the Runtime-owned adopted HDC route: Swift's
//! `trace.probe` handler over `FoundationTraceRuntimeProbe`.
use crate::HdcComposition;
use arkdeck_contract::WireError;
use serde_json::{Value, json};

impl HdcComposition<'_> {
    /// The probe of the adopted Target's route, as Swift's handler projects
    /// its snapshot. An unadopted Target, an unreadable route or a lost tag
    /// list is refused with Swift's description of it; nothing is written.
    pub fn trace_probe(&self, target_id: &str) -> Result<Value, WireError> {
        let failed = |error: String| WireError {
            code: "rejected".into(),
            message: format!("Trace Runtime probe failed: {error}"),
            details: None,
        };
        let facts = self.facts(target_id).map_err(failed)?;
        let probe =
            arkdeck_provider_hdc::trace_probe(self.dispatch, &facts.connect_key).map_err(failed)?;
        let tools: Vec<Value> = probe
            .tools
            .iter()
            .map(|tool| {
                json!({"tool": tool.tool, "disposition": tool.disposition, "family": tool.family,
                    "rawHelpSha256": tool.raw_help_sha256, "detail": tool.detail})
            })
            .collect();
        let parameters: Vec<Value> = probe
            .parameters
            .iter()
            .map(|parameter| {
                json!({"name": parameter.name, "state": parameter.state,
                    "value": parameter.value, "detail": parameter.detail})
            })
            .collect();
        Ok(json!({
            "targetId": facts.target_id,
            "bindingRevision": facts.binding_revision,
            "adapterDisposition": probe.adapter_disposition,
            "tool": probe.tool,
            "family": probe.family,
            "supportedTags": probe.supported_tags,
            "rawHelp": probe.raw_help,
            "rawHelpSha256": probe.raw_help_sha256,
            "tools": tools,
            "parameters": parameters,
        }))
    }
}
