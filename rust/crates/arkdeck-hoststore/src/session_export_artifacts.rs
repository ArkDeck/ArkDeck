//! Bounded Session export content plan and final manifest transformation.
//! The publisher must supply measurements of staged bytes. This module neither
//! publishes output nor claims that the source filesystem stayed unchanged.
use crate::{SessionExportRedactor, redact_session_manifest_fields, session_manifest};
use arkdeck_contract::sha256_hex;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    io,
};

pub struct PlannedExportArtifact {
    pub source: Value,
    pub output_path: String,
}
/// Measurements are produced by the local staged-file writer, never accepted
/// as caller-supplied authorization or as a substitute for source validation.
pub struct ExportArtifactMeasurement {
    pub artifact_id: String,
    pub size: u64,
    pub sha256: String,
}
pub struct PreparedSessionExport {
    artifacts: Vec<PlannedExportArtifact>,
    excluded_ids: Vec<String>,
    manifest: Value,
    redactor: SessionExportRedactor,
}
impl PreparedSessionExport {
    pub fn new(bytes: &[u8], allow_sensitive: bool) -> io::Result<Self> {
        if bytes.len() > 16 * 1024 * 1024 {
            return Err(invalid());
        }
        let summary = session_manifest::decode_manifest(bytes).map_err(|e| match e {
            session_manifest::ManifestError::Invalid => invalid(),
            session_manifest::ManifestError::Unsupported => io::Error::new(
                io::ErrorKind::Unsupported,
                "Session export manifest has unsupported typed content",
            ),
        })?;
        let source = crate::session_json::parse(bytes).map_err(|_| invalid())?;
        let transformed = redact_session_manifest_fields(&source)?;
        let mut artifacts = Vec::new();
        let mut excluded_ids = Vec::new();
        let mut source_paths = BTreeSet::new();
        let mut output_paths = BTreeSet::new();
        for source in summary.artifacts {
            let path = text(&source, "relativePath")?;
            if !source_paths.insert(path.to_owned()) {
                return Err(invalid());
            }
            if !allow_sensitive && ["raw", "partial"].contains(&text(&source, "role")?) {
                excluded_ids.push(text(&source, "id")?.to_owned());
                continue;
            }
            let output_path = transformed.redactor.relative_path(path)?;
            if !output_paths.insert(output_path.clone()) {
                return Err(invalid());
            }
            artifacts.push(PlannedExportArtifact {
                source,
                output_path,
            });
        }
        excluded_ids.sort();
        Ok(Self {
            artifacts,
            excluded_ids,
            manifest: transformed.manifest,
            redactor: transformed.redactor,
        })
    }
    pub fn maximum_growth_bytes(&self) -> io::Result<u64> {
        let mut maximum = 16_u64 * 1024 * 1024;
        for artifact in &self.artifacts {
            let size = artifact.source["size"].as_u64().ok_or_else(invalid)?;
            maximum = maximum
                .checked_add(size.max(64 * 1024 * 1024))
                .ok_or_else(invalid)?;
        }
        Ok(maximum)
    }
    pub fn artifacts(&self) -> &[PlannedExportArtifact] {
        &self.artifacts
    }
    pub fn excluded_ids(&self) -> &[String] {
        &self.excluded_ids
    }
    pub fn requires_payload_redaction(&self) -> bool {
        self.redactor.has_identifiers()
    }

    /// For identity-bearing exports the caller reads one bounded anchored file
    /// at a time, then verifies these original bytes before transformation.
    /// Identity-free exports can stream-copy instead and pass their verified
    /// source/output measurements to finish without buffering the payload.
    pub fn redact_payload(&self, id: &str, bytes: &[u8]) -> io::Result<Vec<u8>> {
        let artifact = self
            .artifacts
            .iter()
            .find(|a| a.source["id"] == id)
            .ok_or_else(invalid)?;
        if artifact.source["size"].as_u64() != Some(bytes.len() as u64)
            || artifact.source["sha256"] != sha256_hex(bytes)
        {
            return Err(invalid());
        }
        self.redactor.artifact_bytes(bytes)
    }

    pub fn finish(&self, measurements: &[ExportArtifactMeasurement]) -> io::Result<Vec<u8>> {
        let mut measured = BTreeMap::new();
        for measurement in measurements {
            if measurement.size > i64::MAX as u64
                || !session_manifest::hash(&measurement.sha256)
                || measurement.sha256 != measurement.sha256.to_ascii_lowercase()
                || measured
                    .insert(measurement.artifact_id.as_str(), measurement)
                    .is_some()
            {
                return Err(invalid());
            }
        }
        let included: BTreeSet<_> = self
            .artifacts
            .iter()
            .map(|a| text(&a.source, "id"))
            .collect::<io::Result<_>>()?;
        if included != measured.keys().copied().collect() {
            return Err(invalid());
        }
        let mut exported = Vec::new();
        for artifact in &self.artifacts {
            let source = &artifact.source;
            let measurement = measured[text(source, "id")?];
            if self.requires_payload_redaction() {
                if measurement.size > 64 * 1024 * 1024 {
                    return Err(invalid());
                }
            } else if source["size"].as_u64() != Some(measurement.size)
                || source["sha256"] != measurement.sha256
            {
                return Err(invalid());
            }
            let role = text(source, "role")?;
            let preserve = role != "derived"
                || source["derivedFrom"].as_array().is_some_and(|refs| {
                    refs.iter()
                        .all(|id| id.as_str().is_some_and(|id| included.contains(id)))
                });
            let exported_role = if preserve { role } else { "diagnostic" };
            let redacted = self.requires_payload_redaction();
            let origin = if redacted && exported_role != "derived" || !preserve {
                format!(
                    "export:v1:{}:source-role:{role}:source-sha256:{}",
                    if redacted { "redacted" } else { "copied" },
                    text(source, "sha256")?
                )
            } else {
                text(source, "origin")?.to_owned()
            };
            let mut row = json!({"id":self.redactor.schema_identifier(text(source, "id")?),
                "role":exported_role,"origin":origin,"relativePath":artifact.output_path,
                "size":measurement.size,"sha256":measurement.sha256});
            if let Some(media) = source.get("mediaType").and_then(Value::as_str) {
                row["mediaType"] = Value::String(if redacted {
                    self.redactor.manifest_string(media)?
                } else {
                    media.to_owned()
                });
            }
            if preserve && let Some(refs) = source.get("derivedFrom").and_then(Value::as_array) {
                row["derivedFrom"] = Value::Array(
                    refs.iter()
                        .map(|id| {
                            id.as_str()
                                .map(|id| Value::String(self.redactor.schema_identifier(id)))
                                .ok_or_else(invalid)
                        })
                        .collect::<io::Result<_>>()?,
                );
            }
            if redacted && exported_role == "derived" {
                let refs = source["derivedFrom"].as_array().ok_or_else(invalid)?;
                let hashes = refs
                    .iter()
                    .map(|id| {
                        measured
                            .get(id.as_str().ok_or_else(invalid)?)
                            .map(|m| m.sha256.clone())
                            .ok_or_else(invalid)
                    })
                    .collect::<io::Result<Vec<_>>>()?;
                let origin = text(source, "origin")?
                    .strip_prefix("derived:")
                    .ok_or_else(invalid)?;
                let origin = session_manifest::base64(origin).map_err(|_| invalid())?;
                let origin = crate::session_json::parse(&origin).map_err(|_| invalid())?;
                let provenance = json!({"operation":"device-identifier-redaction","inputHashes":hashes,
                    "parameters":{"export.originalOperationSha256":sha256_hex(text(&origin,"operation")?.as_bytes()),"export.originalArtifactSha256":text(source,"sha256")?},
                    "statistics":{"export.outputBytes":measurement.size,"export.sourceCount":refs.len()}});
                let bytes = crate::session_json::encode(&provenance).map_err(|_| invalid())?;
                if bytes.len() > 16 * 1024 {
                    return Err(invalid());
                }
                row["origin"] = Value::String(format!("derived:{}", encode_base64(&bytes)));
            }
            exported.push(row);
        }
        let mut manifest = self.manifest.clone();
        manifest["artifacts"] = Value::Array(exported);
        let bytes = crate::session_json::encode(&manifest).map_err(|_| invalid())?;
        if bytes.len() > 16 * 1024 * 1024 {
            return Err(invalid());
        }
        let decoded = session_manifest::decode_manifest(&bytes).map_err(|_| invalid())?;
        if manifest["artifacts"].as_array() != Some(&decoded.artifacts) {
            return Err(invalid());
        }
        Ok(bytes)
    }
}
fn text<'a>(value: &'a Value, key: &str) -> io::Result<&'a str> {
    value.get(key).and_then(Value::as_str).ok_or_else(invalid)
}
fn invalid() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "invalid Session export Artifact transformation",
    )
}
fn encode_base64(bytes: &[u8]) -> String {
    const DIGITS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let a = chunk[0] as usize;
        let b = chunk.get(1).copied().unwrap_or(0) as usize;
        let c = chunk.get(2).copied().unwrap_or(0) as usize;
        output.push(DIGITS[a >> 2] as char);
        output.push(DIGITS[((a & 3) << 4) | (b >> 4)] as char);
        output.push(if chunk.len() > 1 {
            DIGITS[((b & 15) << 2) | (c >> 6)] as char
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            DIGITS[c & 63] as char
        } else {
            '='
        });
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    const SOURCE: &[u8] =
        include_bytes!("../../../tests/fixtures/session-export/swift-export-source.json");
    const EXPECTED: &[u8] =
        include_bytes!("../../../tests/fixtures/session-export/swift-export-result.json");
    fn payloads() -> BTreeMap<&'static str, Vec<u8>> {
        let mut diagnostic = vec![0xff, 0];
        diagnostic.extend_from_slice(
            b"device=fixture-device serial=fixture-serial key-only-fixture-token usb real ID",
        );
        BTreeMap::from([
            ("app-diagnostic", diagnostic),
            ("plan-fixture-serial", b"target fixture-device via fixture-serial and key-only-fixture-token; slot values 111111 stay bounded".to_vec()),
        ])
    }
    #[test]
    fn actual_swift_export_matches_complete_rust_manifest_and_payload_hashes() {
        let plan = PreparedSessionExport::new(SOURCE, false).unwrap();
        assert_eq!(plan.excluded_ids(), ["partial-device", "raw-device"]);
        let payloads = payloads();
        let mut measurements = Vec::new();
        for artifact in plan.artifacts() {
            let id = text(&artifact.source, "id").unwrap();
            let output = plan.redact_payload(id, &payloads[id]).unwrap();
            assert!(
                !output
                    .windows(b"fixture-device".len())
                    .any(|w| w == b"fixture-device")
            );
            measurements.push(ExportArtifactMeasurement {
                artifact_id: id.into(),
                size: output.len() as u64,
                sha256: sha256_hex(&output),
            });
        }
        assert_eq!(plan.finish(&measurements).unwrap(), EXPECTED);
    }
    #[test]
    fn changed_payload_and_incomplete_or_duplicate_measurements_refuse() {
        let plan = PreparedSessionExport::new(SOURCE, false).unwrap();
        assert!(plan.redact_payload("app-diagnostic", b"changed").is_err());
        assert!(plan.redact_payload("raw-device", b"device-raw").is_err());
        assert!(plan.finish(&[]).is_err());
        let duplicate = || ExportArtifactMeasurement {
            artifact_id: "app-diagnostic".into(),
            size: 0,
            sha256: sha256_hex(b""),
        };
        assert!(plan.finish(&[duplicate(), duplicate()]).is_err());
    }
}

#[cfg(test)]
mod derived_tests {
    use super::*;
    const SOURCE: &[u8] =
        include_bytes!("../../../tests/fixtures/session-export/swift-derived-source.json");
    const DEFAULT: &[u8] =
        include_bytes!("../../../tests/fixtures/session-export/swift-derived-default.json");
    const SENSITIVE: &[u8] =
        include_bytes!("../../../tests/fixtures/session-export/swift-derived-sensitive.json");
    #[test]
    fn actual_swift_derived_exports_match_for_excluded_and_included_sources() {
        for (allow, expected) in [(false, DEFAULT), (true, SENSITIVE)] {
            let plan = PreparedSessionExport::new(SOURCE, allow).unwrap();
            assert_eq!(
                plan.maximum_growth_bytes().unwrap(),
                (16 + if allow { 128 } else { 64 }) * 1024 * 1024
            );
            let mut measurements = Vec::new();
            for artifact in plan.artifacts() {
                let id = text(&artifact.source, "id").unwrap();
                let input: &[u8] = if id == "export-raw" {
                    b"raw-device-trace"
                } else {
                    b"filtered-diagnostic-trace"
                };
                let output = plan.redact_payload(id, input).unwrap();
                measurements.push(ExportArtifactMeasurement {
                    artifact_id: id.into(),
                    size: output.len() as u64,
                    sha256: sha256_hex(&output),
                });
            }
            let output = plan.finish(&measurements).unwrap();
            assert_eq!(output, expected, "allowSensitive={allow}");
            let output = crate::session_json::parse(&output).unwrap();
            let derived = output["artifacts"]
                .as_array()
                .unwrap()
                .iter()
                .find(|a| a["id"] == "export-derived")
                .unwrap();
            if allow {
                assert_eq!(derived["role"], "derived");
                assert_eq!(derived["derivedFrom"], json!(["export-raw"]));
                let origin = session_manifest::base64(
                    derived["origin"]
                        .as_str()
                        .unwrap()
                        .strip_prefix("derived:")
                        .unwrap(),
                )
                .unwrap();
                let provenance = crate::session_json::parse(&origin).unwrap();
                assert_eq!(provenance["operation"], "device-identifier-redaction");
                assert_eq!(
                    provenance["inputHashes"][0],
                    output["artifacts"][0]["sha256"]
                );
            } else {
                assert_eq!(derived["role"], "diagnostic");
                assert!(derived.get("derivedFrom").is_none());
            }
        }
    }
}
