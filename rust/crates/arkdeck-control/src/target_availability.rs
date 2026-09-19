//! Bounded Target availability projection. This is not execution admission:
//! binding presence does not establish physical continuity or capability.
use super::{Control, HostServices};
use arkdeck_contract::WireError;
use serde_json::{Map, Value, json};

impl<H: HostServices> Control<H> {
    pub(super) fn target_availability(
        &self,
        params: &Map<String, Value>,
    ) -> Result<Value, WireError> {
        let target_id = params
            .get("targetId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .ok_or_else(|| WireError {
                code: "invalidParams".into(),
                message: "targetId is required".into(),
                details: None,
            })?;
        let record = self
            .host
            .target_resource("target.show", params)
            .map_err(|mut error| {
                if error.code == "notFound" {
                    error.message = format!("no durable target {target_id}");
                }
                error
            })?;
        // Share operation.list's fresh host availability, without promoting
        // a host-ready operation to target resolution or execution admission.
        let availability = self.operation_availability();
        let operations: Vec<_> = availability
            .as_array()
            .expect("validated operation list")
            .iter()
            .map(|operation| {
                json!({
                    "reference": operation["reference"],
                    "availability": operation["availability"],
                    "reasons": operation["reasons"],
                    "reasonCodes": operation["reasonCodes"],
                })
            })
            .collect();
        Ok(json!({
            "targetId": record["targetId"],
            "observedAtUtc": self.host.observed_at(),
            "binding": {
                "state": "ready",
                "bindingRevision": record["bindingRevision"],
                "toolVersion": record["toolVersion"],
                "stablePhysicalIdentitySha256": record["stablePhysicalIdentitySha256"],
                "adoptedAtUtc": record["adoptedAtUtc"],
            },
            // The Rust composition has no warm presentation snapshot source.
            // Calling observations() here would force a device round trip.
            "presence": {
                "state": "unresolved", "observedAtUtc": null,
                "observationHealth": null,
                "reasonCode": "device_observation_unavailable",
                "reason": "the Runtime has no device observation source configured",
            },
            // Like runtime.hdc.status, this reports the managed server owner,
            // not a development/external HDC executable's existence.
            "tool": {
                "state": "absent", "reasonCode": "runtime_tool_unavailable",
                "reason": "Runtime has no managed HDC server",
            },
            "operations": {
                "scope": "host", "targetResolution": "unresolved",
                "reasonCode": "target_scoped_operation_availability_unavailable",
                "reason": "operation availability is computed per host; no target-scoped resolver exists",
                "items": operations,
            },
            "profile": {
                "state": "unresolved", "reasonCode": "profile_resolver_unavailable",
                "reason": "no target-to-profile resolver exists; catalog profiles are published but unmatched",
            },
        }))
    }
}
