//! Swift `AnalyzerProvider.verify` and the derived Artifact Swift publishes
//! from a verified answer (`RuntimeArtifactService.artifactContents`), for
//! the analyzers this Runtime runs: `crash-signature@1`, published as a
//! `HarnessCrashLedgerDerivedArtifact` envelope, and `hilog-summary@1`, as a
//! `HilogSummaryDerivedArtifact` envelope. Verification only judges the
//! child's receipt; it grants nothing and writes nothing.
use crate::job_plan::AnalyzerProfile;
use arkdeck_contract::sha256_hex;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

const CRASH_SIGNATURE: &str = "crash-signature@1";
const HILOG_SUMMARY: &str = crate::hilog_summary::ANALYZER_REF;
/// `HarnessCrashLedgerAnalysis.schemaVersion`.
pub(crate) const SCHEMA_VERSION: &str = "1.0.0";
/// `HarnessCrashLedgerAnalysis.analyzerRef` and `analyzerVersion`, which the
/// crash-ledger mode prints into every analysis.
pub(crate) const ANALYZER_REF: &str = CRASH_SIGNATURE;
pub(crate) const ANALYZER_VERSION: &str = "arkdeck-fault-log-ledger@1";

/// Swift `ProviderProcessReceipt` for a child that exited.
pub(crate) struct Receipt<'a> {
    pub exit_status: i32,
    pub stdout: &'a [u8],
    pub stderr: &'a [u8],
    pub truncated: bool,
}

/// The source identity Swift's typed analyzer action records.
pub(crate) struct Source<'a> {
    pub artifact_id: &'a str,
    pub sha256: &'a str,
    pub byte_count: u64,
}

/// A verified answer: Swift's provenance summary, keyed as Swift keys it, and
/// what the derived Artifact holds.
pub(crate) struct Verified {
    pub summary: BTreeMap<&'static str, String>,
    analyzer_ref: String,
    analysis: Value,
}

impl Verified {
    /// Swift's timeline spelling of the verified facts: the summary keys,
    /// sorted, as a Swift array describes itself.
    pub(crate) fn fact_names(&self) -> String {
        let names: Vec<String> = self
            .summary
            .keys()
            .map(|key| format!("\"{key}\""))
            .collect();
        format!("[{}]", names.join(", "))
    }

    /// The published envelope bytes: compact, sorted keys, unescaped solidus.
    pub(crate) fn envelope(&self) -> Option<Vec<u8>> {
        let field = |key: &str| self.summary.get(key).cloned();
        let count = |key: &str| field(key)?.parse::<u64>().ok();
        let envelope = match self.analyzer_ref.as_str() {
            CRASH_SIGNATURE => json!({
                "schemaVersion": SCHEMA_VERSION,
                "analyzerRef": field("analyzerRef")?,
                "analyzerVersion": field("analyzerVersion")?,
                "sourceArtifactID": field("sourceArtifactId")?,
                "sourceSHA256": field("sourceSha256")?,
                "sourceByteCount": count("sourceByteCount")?,
                "analyzerOutputSHA256": field("derivedSha256")?,
                "analyzerOutputByteCount": count("derivedByteCount")?,
                "result": self.analysis,
            }),
            HILOG_SUMMARY => json!({
                "sourceArtifactID": field("sourceArtifactId")?,
                "analyzerExecutableSHA256": field("toolSha256")?,
                "analyzerOutputSHA256": field("derivedSha256")?,
                "analyzerOutputByteCount": count("derivedByteCount")?,
                "result": self.analysis,
            }),
            _ => return None,
        };
        crate::session_json::encode(&envelope).ok()
    }
}

/// A refusal: Swift's semantic code and detail.
pub(crate) type Refusal = (&'static str, String);

/// Swift's checks in Swift's order; the first refusal wins. `profile` is the
/// analyzer the typed action named, with the budget its answer may use.
pub(crate) fn verify(
    receipt: &Receipt<'_>,
    source: &Source<'_>,
    profile: &AnalyzerProfile,
) -> Result<Verified, Refusal> {
    let reference = profile.analyzer_ref.as_str();
    if receipt.exit_status != 0 {
        return Err((
            "analyzer.failed",
            format!("{reference} exited {}", receipt.exit_status),
        ));
    }
    if receipt.truncated {
        return Err((
            "analyzer.truncatedResult",
            format!("{reference} output was truncated"),
        ));
    }
    if receipt.stdout.len() > profile.output_byte_budget {
        return Err((
            "analyzer.outputLimitExceeded",
            format!("{reference} output exceeded its byte budget"),
        ));
    }
    if receipt.stdout.is_empty() {
        return Err((
            "analyzer.emptyResult",
            format!("{reference} produced no output for {}", source.artifact_id),
        ));
    }
    // `JSONSerialization.jsonObject(with:)` without fragments: an object or
    // an array at the top.
    let document = serde_json::from_slice::<Value>(receipt.stdout)
        .ok()
        .filter(|value| value.is_object() || value.is_array())
        .ok_or_else(|| {
            (
                "analyzer.malformedResult",
                format!("{reference} did not produce a structured result"),
            )
        })?;
    let analysis = match reference {
        CRASH_SIGNATURE => decode_analysis(&document)
            .filter(|analysis| {
                analysis["schemaVersion"] == SCHEMA_VERSION
                    && analysis["analyzerRef"] == reference
                    && analysis["analyzerVersion"] == profile.analyzer_version.as_str()
            })
            .ok_or_else(|| {
                (
                    "analyzer.schemaMismatch",
                    format!("{reference} produced JSON outside its versioned schema"),
                )
            })?,
        // Swift `HilogSummaryDerivedAnalyzer.validate`: a silent child, and
        // the producer's canonical, closed summary of exactly this source.
        HILOG_SUMMARY => {
            if !receipt.stderr.is_empty()
                || profile.analyzer_version != crate::hilog_summary::ANALYZER_VERSION
                || !crate::hilog_summary::validate_hilog_report(
                    receipt.stdout,
                    source.sha256,
                    source.byte_count,
                )
            {
                return Err((
                    "analyzer.schemaMismatch",
                    "hilog-summary@1 produced an invalid or source-mismatched summary".into(),
                ));
            }
            document
        }
        _ => {
            return Err((
                "analyzer.schemaMismatch",
                format!("{reference} produced JSON outside its versioned schema"),
            ));
        }
    };
    let mut summary = BTreeMap::from([
        ("analyzerRef", reference.to_owned()),
        ("analyzerVersion", profile.analyzer_version.clone()),
        ("sourceArtifactId", source.artifact_id.to_owned()),
        ("sourceSha256", source.sha256.to_owned()),
        ("sourceByteCount", source.byte_count.to_string()),
        ("derivedSha256", sha256_hex(receipt.stdout)),
        ("derivedByteCount", receipt.stdout.len().to_string()),
        ("truncated", "false".to_owned()),
    ]);
    if reference == HILOG_SUMMARY {
        summary.insert("toolSha256", profile.executable_sha256.clone());
    }
    Ok(Verified {
        summary,
        analyzer_ref: reference.to_owned(),
        analysis,
    })
}

/// Swift `JSONDecoder` over `HarnessCrashLedgerAnalysis`, then its encoder:
/// the declared keys with their declared types, unknown keys dropped, and
/// `unreadableReason` kept only when it is a string.
fn decode_analysis(document: &Value) -> Option<Value> {
    let object = document.as_object()?;
    let text = |fields: &Map<String, Value>, key: &str| -> Option<Value> {
        fields.get(key)?.as_str().map(Value::from)
    };
    let status = text(object, "status")?;
    if !["answered", "unreadable"].contains(&status.as_str()?) {
        return None;
    }
    let mut entries = Vec::new();
    for entry in object.get("entries")?.as_array()? {
        let entry = entry.as_object()?;
        let mut decoded = Map::new();
        for key in ["name", "kind", "bundle", "uid", "timestamp"] {
            decoded.insert(key.into(), text(entry, key)?);
        }
        entries.push(Value::Object(decoded));
    }
    let mut decoded = Map::new();
    for key in ["schemaVersion", "analyzerRef", "analyzerVersion"] {
        decoded.insert(key.into(), text(object, key)?);
    }
    decoded.insert("status".into(), status);
    decoded.insert("entries".into(), Value::Array(entries));
    match object.get("unreadableReason") {
        None | Some(Value::Null) => {}
        Some(Value::String(reason)) => {
            decoded.insert("unreadableReason".into(), Value::from(reason.as_str()));
        }
        Some(_) => return None,
    }
    Some(Value::Object(decoded))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    const SOURCE: Source<'static> = Source {
        artifact_id: "ART-00000000000000000000000000000001",
        sha256: "0000000000000000000000000000000000000000000000000000000000000002",
        byte_count: 30,
    };

    fn profile(analyzer_ref: &str, budget: usize) -> AnalyzerProfile {
        AnalyzerProfile {
            analyzer_ref: analyzer_ref.into(),
            analyzer_version: if analyzer_ref == CRASH_SIGNATURE {
                ANALYZER_VERSION.into()
            } else {
                "1.0.0".into()
            },
            executable_path: PathBuf::from("/analyzer"),
            executable_sha256: "e".repeat(64),
            fixed_arguments: Vec::new(),
            timeout_seconds: 30,
            output_byte_budget: budget,
            canonical_namespace_root: None,
            pinned_files: Vec::new(),
            pinned_trees: Vec::new(),
            arktrace_summary: None,
            arktrace_analysis: None,
        }
    }

    fn crash(budget: usize) -> AnalyzerProfile {
        profile(CRASH_SIGNATURE, budget)
    }

    fn receipt(stdout: &[u8]) -> Receipt<'_> {
        Receipt {
            exit_status: 0,
            stdout,
            stderr: b"",
            truncated: false,
        }
    }

    #[test]
    fn checks_run_in_swift_order() {
        let refused = |receipt: Receipt<'_>| verify(&receipt, &SOURCE, &crash(16)).err().unwrap().0;
        let failed = Receipt {
            exit_status: 3,
            stdout: b"",
            stderr: b"",
            truncated: true,
        };
        assert_eq!(refused(failed), "analyzer.failed");
        let truncated = Receipt {
            exit_status: 0,
            stdout: b"",
            stderr: b"",
            truncated: true,
        };
        assert_eq!(refused(truncated), "analyzer.truncatedResult");
        assert_eq!(
            refused(receipt(&[b' '; 17])),
            "analyzer.outputLimitExceeded"
        );
        assert_eq!(refused(receipt(b"")), "analyzer.emptyResult");
        assert_eq!(refused(receipt(b"\"text\"")), "analyzer.malformedResult");
        assert_eq!(refused(receipt(b"[]")), "analyzer.schemaMismatch");
    }

    #[test]
    fn the_envelope_keeps_declared_keys_and_the_raw_output_digest() {
        let stdout = br#"{"status":"unreadable","extra":1,"schemaVersion":"1.0.0","analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","entries":[{"uid":"1","timestamp":"t","name":"a/b","kind":"k","bundle":"b","x":null}],"unreadableReason":"r"}"#;
        let verified = verify(&receipt(stdout), &SOURCE, &crash(1 << 20)).unwrap();
        assert_eq!(
            verified.fact_names(),
            r#"["analyzerRef", "analyzerVersion", "derivedByteCount", "derivedSha256", "sourceArtifactId", "sourceByteCount", "sourceSha256", "truncated"]"#
        );
        let envelope = String::from_utf8(verified.envelope().unwrap()).unwrap();
        assert_eq!(
            envelope,
            format!(
                r#"{{"analyzerOutputByteCount":{},"analyzerOutputSHA256":"{}","analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","result":{{"analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","entries":[{{"bundle":"b","kind":"k","name":"a/b","timestamp":"t","uid":"1"}}],"schemaVersion":"1.0.0","status":"unreadable","unreadableReason":"r"}},"schemaVersion":"1.0.0","sourceArtifactID":"{}","sourceByteCount":30,"sourceSHA256":"{}"}}"#,
                stdout.len(),
                sha256_hex(stdout),
                SOURCE.artifact_id,
                SOURCE.sha256
            )
        );
        for wrong in [
            r#"{"status":"answered","schemaVersion":"1.0.0","analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","entries":[{"name":"x"}]}"#,
            r#"{"status":"done","schemaVersion":"1.0.0","analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","entries":[]}"#,
            r#"{"status":"answered","schemaVersion":"1.0.0","analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","entries":[],"unreadableReason":7}"#,
        ] {
            assert_eq!(
                verify(&receipt(wrong.as_bytes()), &SOURCE, &crash(1 << 20))
                    .err()
                    .unwrap()
                    .0,
                "analyzer.schemaMismatch"
            );
        }
    }

    #[test]
    fn a_hilog_summary_is_the_silent_canonical_summary_of_its_source() {
        let bytes = b"09-25 10:00:00.123  1 2 I C02D01/HiLog: x\n";
        let stdout = crate::hilog_summary::analyze_hilog(bytes).unwrap();
        let digest = sha256_hex(bytes);
        let source = Source {
            artifact_id: SOURCE.artifact_id,
            sha256: &digest,
            byte_count: bytes.len() as u64,
        };
        let hilog = profile(HILOG_SUMMARY, 8 * 1024);
        let verified = verify(&receipt(&stdout), &source, &hilog).unwrap();
        assert_eq!(verified.summary["toolSha256"], "e".repeat(64));
        let envelope: Value = serde_json::from_slice(&verified.envelope().unwrap()).unwrap();
        assert_eq!(
            envelope["result"],
            serde_json::from_slice::<Value>(&stdout).unwrap()
        );
        assert_eq!(envelope["analyzerExecutableSHA256"], "e".repeat(64));
        // A child that also wrote to stderr, or a summary of other bytes.
        let noisy = Receipt {
            stderr: b"warning\n",
            ..receipt(&stdout)
        };
        assert_eq!(
            verify(&noisy, &source, &hilog).err().unwrap().0,
            "analyzer.schemaMismatch"
        );
        assert_eq!(
            verify(&receipt(&stdout), &SOURCE, &hilog).err().unwrap().0,
            "analyzer.schemaMismatch"
        );
    }
}
