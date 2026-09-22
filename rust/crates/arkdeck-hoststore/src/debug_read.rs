//! Debug control reads against the Runtime-owned adopted HDC route.
use crate::HdcComposition;
use arkdeck_contract::WireError;
use arkdeck_provider_hdc::{DebugReadTemplate, DispatchFailure, debug_inventory};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

fn failure(code: &str, message: impl Into<String>) -> WireError {
    WireError {
        code: code.into(),
        message: message.into(),
        details: None,
    }
}
impl HdcComposition<'_> {
    pub fn debug_read(
        &self,
        target_id: &str,
        template_id: Option<&str>,
    ) -> Result<Value, WireError> {
        let prefix = if template_id.is_some() {
            "Debug template failed"
        } else {
            "Debug Runtime probe failed"
        };
        let facts = self
            .facts(target_id)
            .map_err(|error| failure("rejected", format!("{prefix}: {error}")))?;
        if let Some(template_id) = template_id {
            let template = DebugReadTemplate::parse(template_id).ok_or_else(|| {
                failure(
                    "invalidParams",
                    "targetId and a closed templateId are required",
                )
            })?;
            let plan = template.plan(&facts.connect_key);
            let receipt = self.dispatch.dispatch(&plan).map_err(|error| {
                let description = match error {
                    DispatchFailure::Unobservable(reason) => format!("outcomeUnknown({reason:?})"),
                    DispatchFailure::Refused(reason) => format!("failed({reason:?})"),
                };
                failure("rejected", format!("Debug template failed: {description}"))
            })?;
            let stdout = std::str::from_utf8(&receipt.stdout).map_err(|_| {
                failure(
                    "rejected",
                    "Debug template failed: Debug read-only template output is not UTF-8",
                )
            })?;
            let stderr = std::str::from_utf8(&receipt.stderr).map_err(|_| {
                failure(
                    "rejected",
                    "Debug template failed: Debug read-only template output is not UTF-8",
                )
            })?;
            let lowering = std::iter::once(self.tool_sha256)
                .chain(plan.arguments.iter().map(String::as_str))
                .collect::<Vec<_>>()
                .join("\0");
            let digest = format!("{:x}", Sha256::digest(lowering.as_bytes()));
            let mut arguments = plan.arguments;
            arguments[1] = "<redacted-connect-key>".into();
            let milliseconds = receipt.duration.as_millis().saturating_add(u128::from(
                receipt.duration.subsec_nanos() % 1_000_000 >= 500_000,
            ));
            let milliseconds = u64::try_from(milliseconds).map_err(|_| {
                failure(
                    "internalError",
                    "Debug template duration is unrepresentable",
                )
            })?;
            return Ok(
                json!({"targetId": facts.target_id, "bindingRevision": facts.binding_revision,
                "templateId": template_id, "effect": "readOnly", "executable": "hdc",
                "executableSha256": self.tool_sha256, "arguments": arguments, "loweringSha256": digest,
                "exitCode": receipt.exit_status, "durationMilliseconds": milliseconds,
                "stdout": stdout, "stderr": stderr, "outputTruncated": receipt.truncated}),
            );
        }
        let inventory = debug_inventory(self.dispatch, &facts.connect_key);
        if facts.binding_revision < 1
            || inventory.packages.len() > 10_000
            || inventory.packages.iter().any(|name| {
                name.len() > 200
                    || name
                        .split('.')
                        .any(|part| !part.as_bytes().first().is_some_and(u8::is_ascii_alphabetic))
            })
            || inventory.port_rules.len() > 4096
        {
            return Err(failure(
                "internalError",
                "Debug Runtime probe returned an invalid bounded projection",
            ));
        }
        let rules: Vec<_> = inventory.port_rules.iter().map(|rule| json!({"direction":rule.direction.raw(), "localPort":rule.local_port, "remotePort":rule.remote_port})).collect();
        Ok(
            json!({"schemaVersion":"arkdeck.debug-probe/1", "targetId":facts.target_id,
            "bindingRevision": facts.binding_revision, "packages":inventory.packages,
            "portRules":rules, "warnings":inventory.warnings}),
        )
    }
}
