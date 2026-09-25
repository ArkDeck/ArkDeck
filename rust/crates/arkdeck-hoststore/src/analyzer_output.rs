//! Swift `AnalyzerProvider.verify` and the derived Artifact Swift publishes
//! from a verified answer (`RuntimeArtifactService.artifactContents`), for
//! the analyzers this Runtime runs: `crash-signature@1`, published as a
//! `HarnessCrashLedgerDerivedArtifact` envelope, `hilog-summary@1`, as a
//! `HilogSummaryDerivedArtifact` envelope, and the ArkTrace analyzers
//! `trace-summary@1` and `trace-analysis@1`, as the exact bytes they printed.
//! Verification only judges the child's receipt; it grants nothing and writes
//! nothing.
use crate::arktrace_analysis::{AnalysisInvocation, AnalysisRequest, Kind};
use crate::job_plan::AnalyzerProfile;
use arkdeck_contract::sha256_hex;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

const CRASH_SIGNATURE: &str = "crash-signature@1";
const HILOG_SUMMARY: &str = crate::hilog_summary::ANALYZER_REF;
const TRACE_SUMMARY: &str = crate::arktrace_profile::SUMMARY_REF;
const TRACE_ANALYSIS: &str = crate::arktrace_profile::ANALYSIS_REF;
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

/// The source identity Swift's typed analyzer action records, and the lease
/// path its invocation names as its last argument.
pub(crate) struct Source<'a> {
    pub artifact_id: &'a str,
    pub sha256: &'a str,
    pub byte_count: u64,
    pub path: &'a str,
}

/// Swift `AnalyzerInvocation`: the analyzer a typed action names, the
/// arguments it is given (the lease path last), its process deadline, the
/// budget its answer may use and, for `trace-analysis@1`, its request.
pub(crate) struct Invocation<'a> {
    pub profile: &'a AnalyzerProfile,
    pub arguments: Vec<String>,
    pub timeout_seconds: i64,
    pub output_byte_budget: usize,
    pub analysis: Option<AnalysisRequest>,
}

impl<'a> Invocation<'a> {
    /// Swift `AnalyzerProvider.action`: `trace-analysis@1` lowers its
    /// request from the Job's inputs; every other analyzer its profile's
    /// fixed arguments.
    pub(crate) fn of(
        profile: &'a AnalyzerProfile,
        inputs: &serde_json::Map<String, Value>,
        lease_path: &str,
    ) -> Result<Self, &'static str> {
        if profile.analyzer_ref == TRACE_ANALYSIS {
            let request = AnalysisRequest::parse(inputs)?;
            return Ok(Self {
                profile,
                arguments: request.arguments(lease_path),
                timeout_seconds: request.process_timeout_seconds(),
                output_byte_budget: usize::try_from(request.max_output_bytes)
                    .map_err(|_| "analyzer analysis inputs violate the closed request contract")?,
                analysis: Some(request),
            });
        }
        let mut arguments = profile.fixed_arguments.clone();
        arguments.push(lease_path.to_owned());
        Ok(Self {
            profile,
            arguments,
            timeout_seconds: profile.timeout_seconds,
            output_byte_budget: profile.output_byte_budget,
            analysis: None,
        })
    }
}

/// A verified answer: Swift's provenance summary, keyed as Swift keys it, and
/// what the derived Artifact holds.
pub(crate) struct Verified {
    pub summary: BTreeMap<&'static str, String>,
    analyzer_ref: String,
    analysis: Value,
    /// What the analyzer printed, which an ArkTrace product publishes as it
    /// is.
    stdout: Vec<u8>,
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
            // ArkTrace's validated machine envelope carries its own complete
            // provenance; a wrapper would change the reviewed bytes.
            TRACE_SUMMARY | TRACE_ANALYSIS => return Some(self.stdout.clone()),
            _ => return None,
        };
        crate::session_json::encode(&envelope).ok()
    }

    /// Swift `RuntimeArtifactService.traceSummaryDerivation` and
    /// `traceAnalysisDerivation`: the closed provenance an ArkTrace product is
    /// published with, from the verified summary; `None` for any other
    /// product, or when a member is missing.
    pub(crate) fn derivation(&self) -> Option<Value> {
        if ![TRACE_SUMMARY, TRACE_ANALYSIS].contains(&self.analyzer_ref.as_str()) {
            return None;
        }
        let field = |key: &str| self.summary.get(key).cloned();
        let number = |key: &str| field(key)?.parse::<i64>().ok();
        let mut derivation = json!({
            "analyzerRef": field("analyzerRef")?,
            "analyzerVersion": field("analyzerVersion")?,
            "sourceArtifactID": field("sourceArtifactId")?,
            "sourceSHA256": field("sourceSha256")?,
            "sourceByteCount": number("sourceByteCount")?,
            "toolSHA256": field("toolSha256")?,
            "parserSHA256": field("parserSha256")?,
            "parserVersion": field("parserVersion")?,
            "parserUpstreamRevision": field("parserUpstreamRevision")?,
            "parserBuildRecipeVersion": field("parserBuildRecipeVersion")?,
            "parserAdapterVersion": field("parserAdapterVersion")?,
            "schemaAdapterVersion": field("schemaAdapterVersion")?,
            "indexSchemaVersion": number("indexSchemaVersion")?,
            "timeoutMs": number("requestTimeoutMs")?,
            "maxRows": number("requestMaxRows")?,
            "maxEvents": number("requestMaxEvents")?,
            "maxOutputBytes": number("requestMaxOutputBytes")?,
        });
        if self.analyzer_ref == TRACE_ANALYSIS {
            // Each optional request member is present, as a number or "null";
            // a null one is not encoded.
            let members = derivation.as_object_mut()?;
            members.insert("requestCommand".into(), json!(field("requestCommand")?));
            members.insert("requestKind".into(), json!(field("requestKind")?));
            for (key, name) in [
                ("requestTimestampNs", "requestTimestampNs"),
                ("requestStartNs", "requestStartNs"),
                ("requestEndNs", "requestEndNs"),
                ("requestProcessKey", "requestProcessKey"),
                ("requestPid", "requestPID"),
                ("requestThreadKey", "requestThreadKey"),
                ("requestTid", "requestTID"),
            ] {
                match field(key)?.as_str() {
                    "null" => {}
                    raw => {
                        members.insert(name.into(), json!(raw.parse::<i64>().ok()?));
                    }
                }
            }
            members.insert(
                "requestThresholdNs".into(),
                json!(number("requestThresholdNs")?),
            );
            members.insert("requestLimit".into(), json!(number("requestLimit")?));
        }
        Some(derivation)
    }
}

/// A refusal: Swift's semantic code and detail.
pub(crate) type Refusal = (&'static str, String);

/// Swift's checks in Swift's order; the first refusal wins, for the
/// invocation the typed action named.
pub(crate) fn verify(
    receipt: &Receipt<'_>,
    source: &Source<'_>,
    invocation: &Invocation<'_>,
) -> Result<Verified, Refusal> {
    let profile = invocation.profile;
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
    if receipt.stdout.len() > invocation.output_byte_budget {
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
        // Swift `ArkTraceSummaryEnvelopeValidator`: a silent child, and the
        // closed envelope of exactly this invocation.
        TRACE_SUMMARY => {
            let summary = crate::arktrace_summary::SummaryInvocation {
                analyzer_ref: reference,
                executable_sha256: &profile.executable_sha256,
                arguments: &invocation.arguments,
                timeout_seconds: invocation.timeout_seconds,
                output_byte_budget: Some(invocation.output_byte_budget as u64),
                source_sha256: source.sha256,
                source_byte_count: source.byte_count,
                contract: profile.arktrace_summary.as_ref(),
            };
            if !receipt.stderr.is_empty()
                || !crate::arktrace_summary::valid_summary(receipt.stdout, &summary)
            {
                return Err((
                    "analyzer.schemaMismatch",
                    format!("{reference} produced JSON outside ArkTrace contract 1.0"),
                ));
            }
            document
        }
        // Swift `ArkTraceAnalysisEnvelopeValidator`: a silent child, and the
        // closed context or analysis envelope of exactly this request.
        TRACE_ANALYSIS => {
            let analysis = AnalysisInvocation {
                analyzer_ref: reference,
                executable_sha256: &profile.executable_sha256,
                arguments: &invocation.arguments,
                timeout_seconds: invocation.timeout_seconds,
                output_byte_budget: Some(invocation.output_byte_budget as u64),
                source_sha256: source.sha256,
                source_byte_count: source.byte_count,
                request: invocation.analysis.as_ref(),
                contract: profile.arktrace_analysis.as_ref(),
            };
            if !receipt.stderr.is_empty()
                || !crate::arktrace_analysis::valid_analysis(receipt.stdout, &analysis)
            {
                return Err((
                    "analyzer.schemaMismatch",
                    format!("{reference} produced JSON outside ArkTrace analysis contract 1.0"),
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
    if let Some(contract) = &profile.arktrace_summary {
        summary.insert("toolSha256", profile.executable_sha256.clone());
        summary.insert("parserSha256", contract.parser_sha256.clone());
        summary.insert("parserVersion", contract.parser_version.clone());
        summary.insert(
            "parserUpstreamRevision",
            contract.parser_upstream_revision.clone(),
        );
        summary.insert(
            "parserBuildRecipeVersion",
            contract.parser_build_recipe_version.clone(),
        );
        summary.insert(
            "parserAdapterVersion",
            contract.parser_adapter_version.clone(),
        );
        summary.insert(
            "schemaAdapterVersion",
            contract.schema_adapter_version.clone(),
        );
        summary.insert(
            "indexSchemaVersion",
            contract.index_schema_version.to_string(),
        );
        summary.insert(
            "requestTimeoutMs",
            (invocation.timeout_seconds * 1_000).to_string(),
        );
        summary.insert("requestMaxRows", "1000".to_owned());
        summary.insert("requestMaxEvents", "10000".to_owned());
        summary.insert(
            "requestMaxOutputBytes",
            invocation.output_byte_budget.to_string(),
        );
    }
    if let (Some(contract), Some(request)) = (&profile.arktrace_analysis, &invocation.analysis) {
        let optional =
            |value: Option<i64>| value.map_or("null".to_owned(), |value| value.to_string());
        for (key, value) in [
            ("toolSha256", profile.executable_sha256.clone()),
            ("parserSha256", contract.parser_sha256.clone()),
            ("parserVersion", contract.parser_version.clone()),
            (
                "parserUpstreamRevision",
                contract.parser_upstream_revision.clone(),
            ),
            (
                "parserBuildRecipeVersion",
                contract.parser_build_recipe_version.clone(),
            ),
            (
                "parserAdapterVersion",
                contract.parser_adapter_version.clone(),
            ),
            (
                "schemaAdapterVersion",
                contract.schema_adapter_version.clone(),
            ),
            (
                "indexSchemaVersion",
                contract.index_schema_version.to_string(),
            ),
            (
                "requestCommand",
                if request.kind == Kind::Context {
                    "context"
                } else {
                    "analyze"
                }
                .to_owned(),
            ),
            ("requestKind", request.kind.raw().to_owned()),
            ("requestTimestampNs", optional(request.timestamp_ns)),
            ("requestStartNs", optional(request.start_ns)),
            ("requestEndNs", optional(request.end_ns)),
            ("requestProcessKey", optional(request.process_key)),
            ("requestPid", optional(request.pid)),
            ("requestThreadKey", optional(request.thread_key)),
            ("requestTid", optional(request.tid)),
            ("requestThresholdNs", request.threshold_ns.to_string()),
            ("requestLimit", request.limit.to_string()),
            ("requestTimeoutMs", request.timeout_ms.to_string()),
            ("requestMaxRows", request.max_rows.to_string()),
            ("requestMaxEvents", request.max_events.to_string()),
            (
                "requestMaxOutputBytes",
                request.max_output_bytes.to_string(),
            ),
        ] {
            summary.insert(key, value);
        }
    }
    Ok(Verified {
        summary,
        analyzer_ref: reference.to_owned(),
        analysis,
        stdout: receipt.stdout.to_vec(),
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

    fn invoked<'a>(profile: &'a AnalyzerProfile, path: &str) -> Invocation<'a> {
        Invocation::of(profile, &Map::new(), path).unwrap()
    }

    const SOURCE: Source<'static> = Source {
        artifact_id: "ART-00000000000000000000000000000001",
        sha256: "0000000000000000000000000000000000000000000000000000000000000002",
        byte_count: 30,
        path: "/private/tmp/arkdeck-analyzer-output/source.log",
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
        let refused = |receipt: Receipt<'_>| {
            verify(&receipt, &SOURCE, &invoked(&crash(16), SOURCE.path))
                .err()
                .unwrap()
                .0
        };
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
        let verified = verify(
            &receipt(stdout),
            &SOURCE,
            &invoked(&crash(1 << 20), SOURCE.path),
        )
        .unwrap();
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
                verify(
                    &receipt(wrong.as_bytes()),
                    &SOURCE,
                    &invoked(&crash(1 << 20), SOURCE.path)
                )
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
            path: SOURCE.path,
        };
        let hilog = profile(HILOG_SUMMARY, 8 * 1024);
        let verified = verify(&receipt(&stdout), &source, &invoked(&hilog, source.path)).unwrap();
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
            verify(&noisy, &source, &invoked(&hilog, source.path))
                .err()
                .unwrap()
                .0,
            "analyzer.schemaMismatch"
        );
        assert_eq!(
            verify(&receipt(&stdout), &SOURCE, &invoked(&hilog, SOURCE.path))
                .err()
                .unwrap()
                .0,
            "analyzer.schemaMismatch"
        );
    }

    /// A reviewed ArkTrace summary (the `reviewed` case of the
    /// `arktrace-summary-validator` oracle) is published as the bytes the
    /// child printed, with the closed derivation Swift's
    /// `traceSummaryDerivation` builds from its verified summary; a child
    /// that also wrote to stderr is refused with Swift's detail.
    #[test]
    fn a_trace_summary_is_its_own_bytes_with_its_derivation() {
        let oracle: Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/arktrace-summary-validator/cases.json"
        ))
        .unwrap();
        let case = &oracle["cases"][0];
        assert_eq!(case["name"], "reviewed");
        let invocation = &case["invocation"];
        let contract = &oracle["contract"];
        let text = |value: &Value| value.as_str().unwrap().to_owned();
        let arguments: Vec<String> = invocation["arguments"]
            .as_array()
            .unwrap()
            .iter()
            .map(text)
            .collect();
        let (path, fixed) = arguments.split_last().unwrap();
        let summary = AnalyzerProfile {
            analyzer_version: "0.1.0+1".into(),
            executable_sha256: text(&invocation["executableSHA256"]),
            fixed_arguments: fixed.to_vec(),
            output_byte_budget: 8 * 1024 * 1024,
            arktrace_summary: Some(crate::arktrace_profile::ArkTraceContract {
                tool_version: text(&contract["toolVersion"]),
                parser_version: text(&contract["parserVersion"]),
                parser_upstream_revision: text(&contract["parserUpstreamRevision"]),
                parser_sha256: text(&contract["parserSHA256"]),
                parser_build_recipe_version: text(&contract["parserBuildRecipeVersion"]),
                parser_adapter_version: text(&contract["parserAdapterVersion"]),
                schema_adapter_version: text(&contract["schemaAdapterVersion"]),
                index_schema_version: contract["indexSchemaVersion"].as_i64().unwrap(),
            }),
            ..profile(TRACE_SUMMARY, 8 * 1024 * 1024)
        };
        let source_sha256 = text(&invocation["sourceSHA256"]);
        let source = Source {
            artifact_id: "ART-SOURCE",
            sha256: &source_sha256,
            byte_count: invocation["sourceByteCount"].as_u64().unwrap(),
            path,
        };
        let stdout = case["envelope"].as_str().unwrap().as_bytes();
        let verified = verify(&receipt(stdout), &source, &invoked(&summary, source.path)).unwrap();
        assert_eq!(verified.envelope().unwrap(), stdout);
        assert_eq!(
            verified.derivation().unwrap(),
            json!({
                "analyzerRef": "trace-summary@1", "analyzerVersion": "0.1.0+1",
                "sourceArtifactID": "ART-SOURCE", "sourceSHA256": source_sha256,
                "sourceByteCount": 4096, "toolSHA256": "b".repeat(64),
                "parserSHA256": "5".repeat(64), "parserVersion": "4.3.7",
                "parserUpstreamRevision": "6".repeat(40),
                "parserBuildRecipeVersion": "7".repeat(64), "parserAdapterVersion": "1",
                "schemaAdapterVersion": "2", "indexSchemaVersion": 3, "timeoutMs": 30000,
                "maxRows": 1000, "maxEvents": 10000, "maxOutputBytes": 8388608,
            })
        );
        let noisy = Receipt {
            stderr: b"warning\n",
            ..receipt(stdout)
        };
        assert_eq!(
            verify(&noisy, &source, &invoked(&summary, source.path))
                .err()
                .unwrap(),
            (
                "analyzer.schemaMismatch",
                "trace-summary@1 produced JSON outside ArkTrace contract 1.0".to_owned()
            )
        );
        // Another analyzer's verified answer carries no derivation.
        assert!(
            verify(
                &receipt(stdout),
                &source,
                &invoked(&profile(CRASH_SIGNATURE, 1 << 20), source.path)
            )
            .map_or(true, |verified| verified.derivation().is_none())
        );
    }
}
