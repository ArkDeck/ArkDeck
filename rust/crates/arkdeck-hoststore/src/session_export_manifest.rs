//! Pure transformation of an already validated Session manifest for derived
//! export. Artifact metadata is replaced by the materializer afterwards; this
//! intermediate document must not be published as a completed export.
use crate::SessionExportRedactor;
use arkdeck_contract::sha256_hex;
use serde_json::{Map, Value};
use std::{collections::BTreeSet, io};

pub struct RedactedSessionManifest {
    pub manifest: Value,
    pub redactor: SessionExportRedactor,
}

pub fn redact_session_manifest_fields(manifest: &Value) -> io::Result<RedactedSessionManifest> {
    let mut root = manifest.as_object().cloned().ok_or_else(invalid)?;
    let runtime = root
        .get("toolchain")
        .is_some_and(|t| t["kind"] == "runtimeProvider");
    let real = root
        .get("originalTarget")
        .is_some_and(|t| t["kind"] == "real");
    let structural: &[&str] = if runtime {
        &["targetId", "stableIdentitySHA256", "model", "firmware"]
    } else {
        &[]
    };
    let mut ids = BTreeSet::new();
    let mut keys = BTreeSet::new();
    if let Some(Value::Object(target)) = root.get_mut("originalTarget") {
        scalar(target.get_mut("connectKey"), &mut ids);
        if let Some(tree) = target.get_mut("identitySnapshot") {
            redact_tree(tree, &mut ids, &mut keys, structural)?;
        }
    }
    if let Some(Value::Array(bindings)) = root.get_mut("bindingHistory") {
        for binding in bindings {
            if let Some(binding) = binding.as_object_mut() {
                scalar(binding.get_mut("connectKey"), &mut ids);
                if let Some(tree) = binding.get_mut("identitySnapshot") {
                    redact_tree(tree, &mut ids, &mut keys, structural)?;
                }
                if let Some(tree) = binding.get_mut("evidence") {
                    redact_tree(tree, &mut ids, &mut keys, &[])?;
                }
            }
        }
    }
    if real {
        ids.extend(keys);
    }
    let redactor = SessionExportRedactor::new(ids);
    for (key, value) in &mut root {
        scrub(value, &mut vec![key.as_str()], &redactor)?;
    }
    if let Some(Value::Array(steps)) = root.get_mut("steps") {
        for step in steps {
            if let Some(step) = step.as_object_mut() {
                rehash(step)?;
                rehash_array(step.get_mut("compensationDescriptors"))?;
            }
        }
    }
    if let Some(Value::Array(compensations)) = root.get_mut("compensations") {
        for compensation in compensations {
            if let Some(Value::Object(descriptor)) = compensation.get_mut("descriptor") {
                rehash(descriptor)?;
            }
        }
    }
    if let Some(Value::Object(recovery)) = root.get_mut("recovery") {
        rehash_array(recovery.get_mut("unexecutedCompensations"))?;
    }
    Ok(RedactedSessionManifest {
        manifest: Value::Object(root),
        redactor,
    })
}
fn invalid() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "invalid Session export manifest transformation",
    )
}
fn sentinel() -> Value {
    Value::String("[REDACTED-DEVICE-ID]".into())
}
fn scalar(value: Option<&mut Value>, ids: &mut BTreeSet<String>) {
    if let Some(Value::String(s)) = value
        && !s.is_empty()
    {
        ids.insert(s.clone());
        *s = "[REDACTED-DEVICE-ID]".into();
    }
}
fn redact_tree(
    value: &mut Value,
    ids: &mut BTreeSet<String>,
    keys: &mut BTreeSet<String>,
    structural: &[&str],
) -> io::Result<()> {
    match value {
        Value::String(s) if !s.is_empty() => {
            ids.insert(s.clone());
            *value = sentinel();
        }
        Value::Array(values) => {
            for value in values {
                redact_tree(value, ids, keys, &[])?;
            }
        }
        Value::Object(fields) => {
            let mut output = Map::new();
            for (key, mut child) in std::mem::take(fields) {
                let output_key = if structural.contains(&key.as_str()) {
                    key
                } else {
                    keys.insert(key.clone());
                    let stem = format!("redacted-field-{}", sha256_hex(key.as_bytes()));
                    let mut name = stem.clone();
                    let mut collision = 0;
                    while output.contains_key(&name) {
                        collision += 1;
                        name = format!("{stem}-{collision}");
                    }
                    name
                };
                redact_tree(&mut child, ids, keys, &[])?;
                output.insert(output_key, child);
            }
            *fields = output;
        }
        Value::Number(number) => {
            let text = if number.is_i64() || number.is_u64() {
                number.to_string()
            } else {
                let mut text = crate::session_json::float_text(number).map_err(|_| invalid())?;
                // Swift String(Double) keeps .0 on fixed integral values,
                // but not scientific mantissas (verified against the host).
                if !text.contains(['.', 'e']) {
                    text.push_str(".0");
                }
                text
            };
            if text.len() >= 4 {
                ids.insert(text);
            }
            *value = sentinel();
        }
        Value::Bool(_) => *value = sentinel(),
        _ => (),
    }
    Ok(())
}
fn scrub<'a>(
    value: &'a mut Value,
    path: &mut Vec<&'a str>,
    redactor: &SessionExportRedactor,
) -> io::Result<()> {
    let key = path.join(".");
    let in_arguments = path.contains(&"arguments");
    if PRESERVED.contains(&key.as_str())
        || (in_arguments && path.last().is_some_and(|key| DIGEST_KEYS.contains(key)))
    {
        return Ok(());
    }
    match value {
        Value::String(s) => {
            let argument_id = in_arguments
                && path
                    .iter()
                    .rev()
                    .find(|k| **k != "*" && **k != "arguments")
                    .is_some_and(|key| ARGUMENT_IDS.contains(key));
            *s = if SCHEMA_IDS.contains(&key.as_str()) || argument_id {
                redactor.schema_identifier(s)
            } else {
                redactor.manifest_string(s)?
            };
        }
        Value::Array(values) => {
            path.push("*");
            for value in values {
                scrub(value, path, redactor)?;
            }
            path.pop();
        }
        Value::Object(fields) => {
            for (key, child) in fields {
                path.push(key.as_str());
                scrub(child, path, redactor)?;
                path.pop();
            }
        }
        _ => (),
    }
    Ok(())
}
fn rehash_array(value: Option<&mut Value>) -> io::Result<()> {
    if let Some(Value::Array(values)) = value {
        for value in values {
            if let Some(object) = value.as_object_mut() {
                rehash(object)?;
            }
        }
    }
    Ok(())
}
fn rehash(object: &mut Map<String, Value>) -> io::Result<()> {
    if object.contains_key("argumentsHash")
        && let Some(arguments @ Value::Object(_)) = object.get("arguments")
    {
        let bytes = crate::session_json::encode(arguments).map_err(|_| invalid())?;
        object.insert("argumentsHash".into(), Value::String(sha256_hex(&bytes)));
    }
    Ok(())
}

// Matches SessionDiagnosticExporter.preservedManifestStringPaths.
const PRESERVED: &[&str] = &[
    "schemaVersion",
    "coreSpecBaseline",
    "status",
    "executionMode",
    "executionAuthority",
    "outcomeCertainty",
    "sessionDisposition",
    "createdAt",
    "completedAt",
    "archivedAt",
    "originalTarget.kind",
    "originalTarget.transport",
    "bindingHistory.*.transport",
    "bindingHistory.*.confirmedBy",
    "bindingHistory.*.channelProtection",
    "toolchain.kind",
    "toolchain.sha256",
    "toolchain.providerIdentity",
    "runtimeAuthority.kind",
    "runtimeAuthority.admittedAtUtc",
    "runtimeAuthority.validUntilUtc",
    "runtimeAuthority.consumptionFingerprintSha256",
    "runtimeAuthority.planDigest",
    "runtimeAuthority.stepSetDigest",
    "runtimeAuthority.targetBindingDigest",
    "runtimeAuthority.artifactDigest",
    "toolchain.profileIdentifier",
    "toolchain.reportedVersion",
    "toolchain.pathSource",
    "toolchain.serverOwnership",
    "workflow.kind",
    "workflow.profileVersion",
    "steps.*.kind",
    "steps.*.effect",
    "steps.*.cancellation",
    "steps.*.bindingRequirement",
    "steps.*.argumentsHash",
    "steps.*.compensationTrigger",
    "steps.*.disposition",
    "steps.*.outcomeCertainty",
    "steps.*.semanticResult",
    "steps.*.compensationDescriptors.*.kind",
    "steps.*.compensationDescriptors.*.effect",
    "steps.*.compensationDescriptors.*.cancellation",
    "steps.*.compensationDescriptors.*.bindingRequirement",
    "steps.*.compensationDescriptors.*.trigger",
    "steps.*.compensationDescriptors.*.argumentsHash",
    "parameters.*.beforeState.state",
    "parameters.*.desiredState.state",
    "parameters.*.afterState.state",
    "parameters.*.restoreState.state",
    "parameters.*.restoreDisposition",
    "compensations.*.descriptor.kind",
    "compensations.*.descriptor.effect",
    "compensations.*.descriptor.cancellation",
    "compensations.*.descriptor.bindingRequirement",
    "compensations.*.descriptor.trigger",
    "compensations.*.descriptor.argumentsHash",
    "compensations.*.disposition",
    "compensations.*.outcomeCertainty",
    "compensations.*.result",
    "confirmations.*.kind",
    "confirmations.*.scopeHash",
    "confirmations.*.decision",
    "confirmations.*.actor.kind",
    "confirmations.*.decidedAt",
    "artifacts.*.role",
    "artifacts.*.sha256",
    "recovery.deviceHazards.*.severity",
    "recovery.deviceHazards.*.outcomeCertainty",
    "recovery.lastDeviceMode.state",
    "recovery.managedHostProcessState",
    "recovery.unexecutedCompensations.*.kind",
    "recovery.unexecutedCompensations.*.effect",
    "recovery.unexecutedCompensations.*.cancellation",
    "recovery.unexecutedCompensations.*.bindingRequirement",
    "recovery.unexecutedCompensations.*.trigger",
    "recovery.unexecutedCompensations.*.argumentsHash",
    "recovery.userConfirmation.actor",
    "recovery.userConfirmation.decision",
    "recovery.userConfirmation.confirmedAt",
];

// Matches SessionDiagnosticExporter.schemaIdentifierManifestPaths.
const SCHEMA_IDS: &[&str] = &[
    "sessionId",
    "jobId",
    "steps.*.id",
    "steps.*.sourceStepId",
    "steps.*.compensationDescriptors.*.id",
    "parameters.*.name",
    "compensations.*.descriptor.id",
    "compensations.*.sourceStepId",
    "compensations.*.failure.code",
    "compensations.*.journalEventIds.*",
    "confirmations.*.confirmationId",
    "confirmations.*.relatedStepIds.*",
    "artifacts.*.id",
    "artifacts.*.derivedFrom.*",
    "failure.code",
    "recovery.deviceHazards.*.code",
    "recovery.abandonAuditEventIds.*",
    "recovery.lastConfirmedStepId",
    "recovery.unexecutedCompensations.*.id",
    "recovery.userConfirmation.confirmationId",
    "recovery.recoveryOfSessionId",
    "recovery.recoveryOfJobId",
];

// Matches SessionDiagnosticExporter.workflowArgumentIdentifierKeys.
const ARGUMENT_IDS: &[&str] = &[
    "artifactId",
    "artifactSeriesId",
    "buildPresetRef",
    "bufferId",
    "captureStepId",
    "clientIdentity",
    "confirmationId",
    "dumpArtifactId",
    "evidencePolicy",
    "forwardId",
    "imageArtifactId",
    "inputArtifactId",
    "inputArtifactIds",
    "outputArtifactId",
    "ownershipEvidenceId",
    "packageArtifactId",
    "patchArtifactId",
    "patchAttemptRef",
    "probeId",
    "processorId",
    "projectRef",
    "name",
    "profileId",
    "promptKey",
    "reason",
    "safeBoundaryId",
    "semanticResultPolicy",
    "sessionId",
    "snapshotStepId",
    "sourceArtifactId",
    "sourceProjectRef",
    "stopPolicy",
    "symbolPresetRef",
    "testPresetRef",
    "toolIdentity",
    "validationPolicy",
    "volumeIdentity",
    "workspaceProjectRef",
];

// Matches SessionDiagnosticExporter.workflowArgumentDigestKeys.
const DIGEST_KEYS: &[&str] = &[
    "allowedFileScopesDigest",
    "dumpSha256",
    "expectedSha256",
    "expectedWorkspaceRevision",
    "imageSha256",
    "impactSnapshotHash",
    "inputSha256",
    "packageSha256",
    "patchSha256",
    "scopeHash",
    "sourceSha256",
    "workspaceRevision",
];

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn real_runtime_identity_keys_seed_bytes_without_scrubbing_structural_vocabulary() {
        let manifest = json!({
            "schemaVersion":"fixture",
            "sessionId":"session-dev123", "jobId":"job-dev123",
            "originalTarget":{"kind":"real","transport":"dev123", "connectKey":"dev123",
                "identitySnapshot":{"targetId":"dev123","model":"model-secret","firmware":"fw-secret","private-key":"private-value"}},
            "toolchain":{"kind":"runtimeProvider","sha256":"dev123"},
            "bindingHistory":[{"connectKey":"second-device","identitySnapshot":{},"evidence":{"evidence-secret":true}}],
            "steps":[{"id":"step-dev123","kind":"fixture", "arguments":{"inputArtifactId":"dev123","inputSha256":"dev123","label":"prefix-dev123"},"argumentsHash":"old"}],
            "artifacts":[{"id":"artifact-dev123","sha256":"dev123","role":"derived"}]
        });
        let original = manifest.clone();
        let output = redact_session_manifest_fields(&manifest).unwrap();
        assert_eq!(manifest, original);
        let root = &output.manifest;
        assert_eq!(root["originalTarget"]["kind"], "real");
        assert_eq!(root["originalTarget"]["transport"], "dev123");
        assert_eq!(root["originalTarget"]["connectKey"], "[REDACTED-DEVICE-ID]");
        assert_eq!(
            root["originalTarget"]["identitySnapshot"]["targetId"],
            "[REDACTED-DEVICE-ID]"
        );
        assert!(
            root["originalTarget"]["identitySnapshot"]
                .get("private-key")
                .is_none()
        );
        assert_eq!(root["toolchain"]["sha256"], "dev123");
        assert_eq!(root["steps"][0]["arguments"]["inputSha256"], "dev123");
        assert_eq!(
            root["steps"][0]["arguments"]["inputArtifactId"],
            output.redactor.schema_identifier("dev123")
        );
        assert_eq!(root["steps"][0]["arguments"]["label"], "prefix-[R]");
        assert_eq!(
            root["steps"][0]["argumentsHash"],
            sha256_hex(&crate::session_json::encode(&root["steps"][0]["arguments"]).unwrap())
        );
        assert_eq!(root["artifacts"][0]["sha256"], "dev123");
        assert_eq!(output.redactor.artifact_bytes(b"private-key evidence-secret targetId dev123 second-device").unwrap(), b"[REDACTED-DEVICE-ID] [REDACTED-DEVICE-ID] targetId [REDACTED-DEVICE-ID] [REDACTED-DEVICE-ID]");
    }

    #[test]
    fn simulation_identity_keys_do_not_become_artifact_identifiers() {
        let manifest = json!({"originalTarget":{"kind":"simulated","connectKey":"","identitySnapshot":{"simulated-key":"simulated-value", "number":12345, "flag":true,"empty":"","null":null}}});
        let output = redact_session_manifest_fields(&manifest).unwrap();
        assert_eq!(
            output
                .redactor
                .artifact_bytes(b"simulated-key simulated-value 12345 true")
                .unwrap(),
            b"simulated-key [REDACTED-DEVICE-ID] [REDACTED-DEVICE-ID] true"
        );
        let snapshot = output.manifest["originalTarget"]["identitySnapshot"]
            .as_object()
            .unwrap();
        let null = format!("redacted-field-{}", sha256_hex(b"null"));
        assert!(snapshot[&null].is_null());
        let empty = format!("redacted-field-{}", sha256_hex(b"empty"));
        assert_eq!(snapshot[&empty], "");
    }

    #[test]
    fn compensation_and_recovery_arguments_are_rehashed_after_scrubbing() {
        let descriptor = json!({"id":"dev123", "arguments":{"sessionId":"dev123","nested":{"packageSha256":"dev123"}}, "argumentsHash":"old"});
        let manifest = json!({"originalTarget":{"kind":"real","connectKey":"dev123"},
            "steps":[{"compensationDescriptors":[descriptor.clone()]}],
            "compensations":[{"descriptor":descriptor.clone()}],
            "recovery":{"unexecutedCompensations":[descriptor]}});
        let output = redact_session_manifest_fields(&manifest).unwrap().manifest;
        for descriptor in [
            &output["steps"][0]["compensationDescriptors"][0],
            &output["compensations"][0]["descriptor"],
            &output["recovery"]["unexecutedCompensations"][0],
        ] {
            assert!(
                descriptor["id"]
                    .as_str()
                    .unwrap()
                    .starts_with("redacted-device-")
            );
            assert!(
                descriptor["arguments"]["sessionId"]
                    .as_str()
                    .unwrap()
                    .starts_with("redacted-device-")
            );
            assert_eq!(descriptor["arguments"]["nested"]["packageSha256"], "dev123");
            assert_eq!(
                descriptor["argumentsHash"],
                sha256_hex(&crate::session_json::encode(&descriptor["arguments"]).unwrap())
            );
        }
    }

    #[test]
    fn numeric_identity_spelling_matches_current_swift_scalar_strings() {
        // These literals were checked with the installed Swift String(Double).
        let manifest = json!({"originalTarget":{"kind":"real","identitySnapshot":
            [1.0, -0.0, 1e-5, 1e16, 1234.5]}});
        let output = redact_session_manifest_fields(&manifest).unwrap();
        assert_eq!(output.redactor.artifact_bytes(b"1.0 -0.0 1e-05 1e+16 1234.5").unwrap(),
            b"1.0 [REDACTED-DEVICE-ID] [REDACTED-DEVICE-ID] [REDACTED-DEVICE-ID] [REDACTED-DEVICE-ID]");
    }

    #[test]
    fn path_redaction_preserves_layout_and_refuses_unsafe_paths() {
        let redactor = SessionExportRedactor::new(BTreeSet::from(["dev123".into(), "ab".into()]));
        assert_eq!(
            redactor.relative_path("logs/dev123.log").unwrap(),
            format!("logs/{}", redactor.schema_identifier("dev123.log"))
        );
        assert_eq!(
            redactor.relative_path("logs/ab").unwrap(),
            format!("logs/{}", redactor.schema_identifier("ab"))
        );
        for path in ["../dev123", "/dev123", "logs//dev123", "logs/a:"] {
            assert!(redactor.relative_path(path).is_err());
        }
    }
}

#[cfg(test)]
mod swift_export_test {
    use super::*;
    #[test]
    fn matches_manifest_fields_from_actual_swift_export() {
        let source =
            include_bytes!("../../../tests/fixtures/session-export/swift-export-source.json");
        let expected =
            include_bytes!("../../../tests/fixtures/session-export/swift-export-result.json");
        let source = crate::session_json::parse(source).unwrap();
        let mut expected = crate::session_json::parse(expected).unwrap();
        let mut actual = redact_session_manifest_fields(&source).unwrap().manifest;
        // Artifact metadata is rewritten after copying/redacting payloads;
        // this test verifies every other manifest field against the exporter.
        actual.as_object_mut().unwrap().remove("artifacts");
        expected.as_object_mut().unwrap().remove("artifacts");
        assert_eq!(actual, expected);
        assert_eq!(
            crate::session_json::encode(&actual).unwrap(),
            crate::session_json::encode(&expected).unwrap()
        );
    }
}
