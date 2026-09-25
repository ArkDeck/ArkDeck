//! Swift `ArkTraceSummaryEnvelopeValidator`: the only ArkTrace wire result
//! `analyzer.summarize-trace@1` accepts — the CLI's closed `summary` JSON
//! envelope for exactly the invocation that produced it: its tool, request,
//! limits, source, parser and provenance, a data quality whose warnings are
//! closed and ordered, a truncation that agrees with its sections, and a
//! result whose counts, nulls and truncation agree with its capabilities.
//! Every number is a 64-bit integer token, no member name repeats, and no
//! machine string names an absolute path, a `file:` URI or the source's own
//! path. Success authorizes publishing the exact bytes, never a re-encoding.
use crate::arktrace_doctor::{exact_keys, integer_tokens};
use crate::arktrace_profile::ArkTraceContract;
use serde_json::{Map, Value};
use std::collections::BTreeSet;

/// What a verified summary answers: the invocation a Job's typed action
/// recorded.
pub(crate) struct SummaryInvocation<'a> {
    pub analyzer_ref: &'a str,
    pub executable_sha256: &'a str,
    pub arguments: &'a [String],
    pub timeout_seconds: i64,
    pub output_byte_budget: Option<u64>,
    pub source_sha256: &'a str,
    pub source_byte_count: u64,
    pub contract: Option<&'a ArkTraceContract>,
}

/// Swift's `isSHA256` here: 64 lowercase hexadecimal ASCII bytes.
pub(crate) fn ascii_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn string(value: Option<&Value>) -> Option<&str> {
    value?.as_str()
}

/// `NSNumber` that is not a Boolean, read exactly as a 64-bit integer.
fn integer(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(number) => number.as_i64(),
        _ => None,
    }
}

fn boolean(value: Option<&Value>) -> Option<bool> {
    value?.as_bool()
}

fn object(value: Option<&Value>) -> Option<&Map<String, Value>> {
    value?.as_object()
}

/// Swift `safe(_:maximumBytes:)`: non-empty, bounded, no control or format
/// scalar (`CharacterSet.controlCharacters`).
pub(crate) fn safe(value: &str, maximum_bytes: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum_bytes
        && !value.chars().any(arkdeck_platform::host_control_character)
}

/// Swift `machineQualityScopes`.
pub(crate) const MACHINE_QUALITY_SCOPES: [&str; 51] = [
    "process.start_ts",
    "process.end_ts",
    "process.lifecycle",
    "process.name",
    "thread.start_ts",
    "thread.end_ts",
    "thread.ipid",
    "thread.lifecycle",
    "thread.name",
    "thread.processName",
    "sched_slice.ts",
    "sched_slice.dur",
    "sched_slice.cpu",
    "sched_slice.value",
    "sched_slice.identity",
    "sched_slice.overlap",
    "thread_state.ts",
    "thread_state.dur",
    "thread_state.cpu",
    "thread_state.value",
    "thread_state.identity",
    "thread_state.state",
    "callstack.ts",
    "callstack.dur",
    "callstack.depth",
    "callstack.parent_id",
    "callstack.cookie",
    "callstack.value",
    "callstack.identity",
    "measure.ts",
    "measure.filter_id",
    "measure.value",
    "measure.dur",
    "measure.optional",
    "cpu_measure_filter.id",
    "cpu_measure_filter.name",
    "cpu_measure_filter.cpu",
    "cpu_measure_filter.unit",
    "process_measure_filter.id",
    "process_measure_filter.name",
    "process_measure_filter.ipid",
    "process_measure_filter.unit",
    "stat",
    "stat.count",
    "stat.source",
    "stat.event_name",
    "stat.stat_type",
    "timeline.density.occupancy",
    "timeline.density.dominantThread",
    "timeline.counter",
    "timeline.counter.duration",
];

pub(crate) const QUALITY_CATEGORIES: [&str; 6] = [
    "probeTruncated",
    "invalidValue",
    "clampedValue",
    "droppedValue",
    "referentialIntegrity",
    "unavailableValue",
];

// MARK: Private paths

/// Swift `containsPrivatePathInMachineValue`: any string value, at any depth,
/// that names the source path, a `file:` URI or an absolute path token.
pub(crate) fn contains_private_path(value: &Value, source_path: &str) -> bool {
    match value {
        Value::String(text) => private_path_in(text, source_path),
        Value::Array(items) => items
            .iter()
            .any(|item| contains_private_path(item, source_path)),
        Value::Object(fields) => fields
            .values()
            .any(|item| contains_private_path(item, source_path)),
        _ => false,
    }
}

fn private_path_in(text: &str, source_path: &str) -> bool {
    let decoded = decode_valid_percent_escapes(text);
    std::iter::once(text.to_owned())
        .chain((decoded != text).then_some(decoded))
        .any(|candidate| {
            candidate.contains(source_path)
                || contains_file_uri_token(&candidate)
                || contains_absolute_path_token(&candidate)
        })
}

fn ascii_identifier_byte(byte: u8) -> bool {
    byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-' | b'.')
}

fn contains_file_uri_token(text: &str) -> bool {
    let bytes = text.to_lowercase().into_bytes();
    let scheme = b"file:";
    if bytes.len() <= scheme.len() {
        return false;
    }
    (0..bytes.len() - scheme.len()).any(|index| {
        &bytes[index..index + scheme.len()] == scheme
            && bytes[index + scheme.len()] == b'/'
            && (index == 0 || !ascii_identifier_byte(bytes[index - 1]))
    })
}

fn ascii_alpha(scalar: char) -> bool {
    scalar.is_ascii_alphabetic()
}

fn scheme_continuation(scalar: char) -> bool {
    scalar.is_ascii_alphanumeric() || matches!(scalar, '+' | '-' | '.')
}

fn semantic_identifier(scalar: char) -> bool {
    arkdeck_platform::host_alphanumeric(scalar) || matches!(scalar, '_' | '-' | '.')
}

/// Swift `uriSeparatorEnd`: where a `scheme://` separator that begins at the
/// solidus `start` ends.
fn uri_separator_end(scalars: &[char], start: usize) -> Option<usize> {
    if start == 0 {
        return None;
    }
    let colon = start - 1;
    if scalars[colon] != ':' || colon == 0 {
        return None;
    }
    let mut end = start;
    while end + 1 < scalars.len() && scalars[end + 1] == '/' {
        end += 1;
    }
    if end + 1 - start < 2 {
        return None;
    }
    let mut scheme_start = colon;
    while scheme_start > 0 && scheme_continuation(scalars[scheme_start - 1]) {
        scheme_start -= 1;
    }
    (scheme_start < colon
        && ascii_alpha(scalars[scheme_start])
        && scalars[scheme_start..colon]
            .iter()
            .copied()
            .all(scheme_continuation))
    .then_some(end)
}

fn contains_absolute_path_token(text: &str) -> bool {
    let scalars: Vec<char> = text.chars().collect();
    let mut index = 0;
    while index < scalars.len() {
        if scalars[index] != '/' {
            index += 1;
            continue;
        }
        if let Some(end) = uri_separator_end(&scalars, index) {
            index = end + 1;
            continue;
        }
        if index == 0 || !semantic_identifier(scalars[index - 1]) {
            return true;
        }
        index += 1;
    }
    false
}

/// Swift `decodeValidPercentEscapes`: each valid `%HH` decoded on its own,
/// the result read as UTF-8 with ill-formed sequences replaced.
fn decode_valid_percent_escapes(text: &str) -> String {
    let source = text.as_bytes();
    let hex = |byte: u8| (byte as char).to_digit(16).map(|value| value as u8);
    let mut decoded = Vec::with_capacity(source.len());
    let mut index = 0;
    while index < source.len() {
        if source[index] == b'%'
            && index + 2 < source.len()
            && let (Some(high), Some(low)) = (hex(source[index + 1]), hex(source[index + 2]))
        {
            decoded.push(high << 4 | low);
            index += 3;
            continue;
        }
        decoded.push(source[index]);
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

// MARK: Sections

/// Swift `validateDataQuality`.
pub(crate) fn valid_data_quality(value: Option<&Value>) -> bool {
    let Some(quality) = object(value) else {
        return false;
    };
    let Some(warnings) = quality.get("warnings").and_then(Value::as_array) else {
        return false;
    };
    let Some(status) = string(quality.get("status")) else {
        return false;
    };
    if !exact_keys(quality, &["status", "warnings"]) || warnings.len() > 4_096 {
        return false;
    }
    let mut previous: Option<(String, String, i64)> = None;
    let mut identities = BTreeSet::new();
    for warning in warnings {
        let Some(warning) = warning.as_object() else {
            return false;
        };
        let Some(category) = string(warning.get("category")) else {
            return false;
        };
        if !exact_keys(warning, &["category", "scope", "count", "message"])
            || !QUALITY_CATEGORIES.contains(&category)
            || warning.get("message") != Some(&Value::Null)
        {
            return false;
        }
        let scope = match warning.get("scope") {
            Some(Value::Null) => String::new(),
            other => match string(other) {
                Some(scope) if MACHINE_QUALITY_SCOPES.contains(&scope) => scope.to_owned(),
                _ => return false,
            },
        };
        let count = match warning.get("count") {
            Some(Value::Null) => i64::MIN,
            other => match integer(other) {
                Some(count) if count >= 0 => count,
                _ => return false,
            },
        };
        let key = (category.to_owned(), scope, count);
        if previous.as_ref().is_some_and(|previous| *previous > key) {
            return false;
        }
        if !identities.insert(format!("{}\0{}\0{}", key.0, key.1, key.2)) {
            return false;
        }
        previous = Some(key);
    }
    status
        == if warnings.is_empty() {
            "ok"
        } else {
            "warnings"
        }
}

const TRUNCATION_SECTIONS: [&str; 8] = [
    "cpuCount",
    "processCount",
    "threadCount",
    "cpuSliceCount",
    "threadStateCount",
    "namedSliceCount",
    "counterSeriesCount",
    "eventCountBySource",
];

fn valid_truncation(value: Option<&Value>) -> bool {
    let Some(truncation) = object(value) else {
        return false;
    };
    let (Some(truncated), Some(raw)) = (
        boolean(truncation.get("truncated")),
        truncation.get("sections").and_then(Value::as_array),
    ) else {
        return false;
    };
    if !exact_keys(truncation, &["truncated", "sections"]) || raw.len() > 256 {
        return false;
    }
    let Some(sections) = raw
        .iter()
        .map(|section| section.as_str().filter(|section| safe(section, 128)))
        .collect::<Option<Vec<_>>>()
    else {
        return false;
    };
    let unique: BTreeSet<&str> = sections.iter().copied().collect();
    let mut sorted = sections.clone();
    sorted.sort_unstable();
    unique.len() == sections.len()
        && sections == sorted
        && sections
            .iter()
            .all(|section| TRUNCATION_SECTIONS.contains(section))
        && truncated == !sections.is_empty()
}

struct Capabilities {
    cpu_scheduling: bool,
    thread_states: bool,
    named_slices: bool,
    cpu_counters: bool,
    process_counters: bool,
}

fn capabilities(value: Option<&Value>) -> Option<Capabilities> {
    let fields = object(value)?;
    if !exact_keys(
        fields,
        &[
            "cpuScheduling",
            "threadStates",
            "namedSlices",
            "cpuCounters",
            "processCounters",
        ],
    ) {
        return None;
    }
    Some(Capabilities {
        cpu_scheduling: boolean(fields.get("cpuScheduling"))?,
        thread_states: boolean(fields.get("threadStates"))?,
        named_slices: boolean(fields.get("namedSlices"))?,
        cpu_counters: boolean(fields.get("cpuCounters"))?,
        process_counters: boolean(fields.get("processCounters"))?,
    })
}

fn optional_bounded_count(value: Option<&Value>) -> bool {
    value == Some(&Value::Null) || integer(value).is_some_and(|count| (0..=10_000).contains(&count))
}

fn valid_event_sources(value: Option<&Value>) -> bool {
    if value == Some(&Value::Null) {
        return true;
    }
    let Some(rows) = value.and_then(Value::as_array) else {
        return false;
    };
    if rows.len() > 10_000 {
        return false;
    }
    let mut previous: Option<&[u8]> = None;
    let mut identities = BTreeSet::new();
    for row in rows {
        let Some(row) = row.as_object() else {
            return false;
        };
        let (Some(source), Some(count)) = (string(row.get("source")), integer(row.get("count")))
        else {
            return false;
        };
        if !exact_keys(row, &["source", "count"]) || !safe(source, 1_024) || count < 0 {
            return false;
        }
        let identity = source.as_bytes();
        if previous.is_some_and(|previous| identity < previous) || !identities.insert(identity) {
            return false;
        }
        previous = Some(identity);
    }
    true
}

fn is_null(value: Option<&Value>) -> bool {
    value == Some(&Value::Null)
}

fn valid_result(value: Option<&Value>, trace: Option<&Value>, truncation: Option<&Value>) -> bool {
    let Some(result) = object(value) else {
        return false;
    };
    if !exact_keys(
        result,
        &[
            "range",
            "durationNs",
            "cpuCount",
            "processCount",
            "threadCount",
            "cpuSliceCount",
            "threadStateCount",
            "namedSliceCount",
            "counterSeriesCount",
            "eventCountBySource",
            "capabilities",
        ],
    ) {
        return false;
    }
    let Some(capabilities) = capabilities(result.get("capabilities")) else {
        return false;
    };
    let Some(trace_duration) = object(trace).and_then(|trace| integer(trace.get("durationNs")))
    else {
        return false;
    };
    let (Some(duration), Some(processes), Some(threads)) = (
        integer(result.get("durationNs")),
        integer(result.get("processCount")),
        integer(result.get("threadCount")),
    ) else {
        return false;
    };
    let range_holds = object(result.get("range")).is_some_and(|range| {
        exact_keys(range, &["startNs", "endNs"])
            && integer(range.get("startNs")) == Some(0)
            && integer(range.get("endNs")) == Some(duration)
    });
    let Some(sections) = object(truncation)
        .and_then(|truncation| truncation.get("sections"))
        .and_then(Value::as_array)
        .and_then(|sections| {
            sections
                .iter()
                .map(Value::as_str)
                .collect::<Option<BTreeSet<_>>>()
        })
    else {
        return false;
    };
    let counters = capabilities.cpu_counters || capabilities.process_counters;
    duration == trace_duration
        && (0..=1_000).contains(&processes)
        && (0..=1_000).contains(&threads)
        && range_holds
        && optional_bounded_count(result.get("cpuCount"))
        && optional_bounded_count(result.get("cpuSliceCount"))
        && optional_bounded_count(result.get("threadStateCount"))
        && optional_bounded_count(result.get("namedSliceCount"))
        && optional_bounded_count(result.get("counterSeriesCount"))
        && valid_event_sources(result.get("eventCountBySource"))
        && is_null(result.get("cpuCount")) == !capabilities.cpu_scheduling
        && is_null(result.get("cpuSliceCount")) == !capabilities.cpu_scheduling
        && is_null(result.get("threadStateCount")) == !capabilities.thread_states
        && is_null(result.get("namedSliceCount")) == !capabilities.named_slices
        && is_null(result.get("counterSeriesCount")) == !counters
        && ((!sections.contains("cpuCount") && !sections.contains("cpuSliceCount"))
            || capabilities.cpu_scheduling)
        && (!sections.contains("threadStateCount") || capabilities.thread_states)
        && (!sections.contains("namedSliceCount") || capabilities.named_slices)
        && (!sections.contains("counterSeriesCount") || counters)
        && (!sections.contains("eventCountBySource") || !is_null(result.get("eventCountBySource")))
}

/// Swift `ArkTraceSummaryEnvelopeValidator.validate(_:invocation:)`.
pub(crate) fn valid_summary(bytes: &[u8], invocation: &SummaryInvocation<'_>) -> bool {
    let Some(contract) = invocation.contract else {
        return false;
    };
    let Some(budget) = invocation.output_byte_budget else {
        return false;
    };
    let Some(source_path) = invocation.arguments.last() else {
        return false;
    };
    let expected_arguments = [
        "summary".to_owned(),
        "--json".to_owned(),
        "--no-cache".to_owned(),
        "--timeout-ms".to_owned(),
        (invocation.timeout_seconds * 1_000).to_string(),
        "--max-rows".to_owned(),
        "1000".to_owned(),
        "--max-events".to_owned(),
        "10000".to_owned(),
        "--max-output-bytes".to_owned(),
        budget.to_string(),
        source_path.clone(),
    ];
    if invocation.analyzer_ref != "trace-summary@1"
        || invocation.source_byte_count == 0
        || !ascii_sha256(invocation.source_sha256)
        || !ascii_sha256(invocation.executable_sha256)
        || bytes.len() as u64 > budget
        || source_path.is_empty()
        || bytes
            .windows(source_path.len())
            .any(|window| window == source_path.as_bytes())
        || invocation.arguments != expected_arguments
    {
        return false;
    }
    if crate::strict_json::validate(bytes).is_err() || !integer_tokens(bytes) {
        return false;
    }
    let Ok(Value::Object(root)) = serde_json::from_slice::<Value>(bytes) else {
        return false;
    };
    if contains_private_path(&Value::Object(root.clone()), source_path)
        || !exact_keys(
            &root,
            &[
                "schemaVersion",
                "tool",
                "request",
                "trace",
                "provenance",
                "limits",
                "dataQuality",
                "truncation",
                "result",
            ],
        )
        || string(root.get("schemaVersion")) != Some("1.0")
    {
        return false;
    }
    let tool = object(root.get("tool")).is_some_and(|tool| {
        exact_keys(tool, &["name", "version", "buildRevision"])
            && string(tool.get("name")) == Some("arktrace")
            && string(tool.get("version")) == Some(contract.tool_version.as_str())
            && string(tool.get("buildRevision")) == Some(invocation.executable_sha256)
    });
    let request = object(root.get("request")).is_some_and(|request| {
        exact_keys(request, &["command", "parameters"])
            && string(request.get("command")) == Some("summary")
            && object(request.get("parameters")).is_some_and(|parameters| {
                exact_keys(parameters, &["startNs", "endNs"])
                    && is_null(parameters.get("startNs"))
                    && is_null(parameters.get("endNs"))
            })
    });
    let limits = object(root.get("limits")).is_some_and(|limits| {
        exact_keys(
            limits,
            &["timeoutMs", "maxRows", "maxEvents", "maxOutputBytes"],
        ) && integer(limits.get("timeoutMs")) == Some(invocation.timeout_seconds * 1_000)
            && integer(limits.get("maxRows")) == Some(1_000)
            && integer(limits.get("maxEvents")) == Some(10_000)
            && integer(limits.get("maxOutputBytes")) == Some(budget as i64)
    });
    let trace = object(root.get("trace")).is_some_and(|trace| {
        exact_keys(
            trace,
            &[
                "sha256",
                "byteCount",
                "durationNs",
                "parser",
                "schemaFingerprint",
            ],
        ) && string(trace.get("sha256")) == Some(invocation.source_sha256)
            && integer(trace.get("byteCount")) == Some(invocation.source_byte_count as i64)
            && integer(trace.get("durationNs")).is_some_and(|duration| duration >= 0)
            && string(trace.get("schemaFingerprint")).is_some_and(ascii_sha256)
            && object(trace.get("parser")).is_some_and(|parser| {
                exact_keys(
                    parser,
                    &["name", "version", "upstreamRevision", "binarySha256"],
                ) && string(parser.get("name")) == Some("trace_streamer")
                    && string(parser.get("version")) == Some(contract.parser_version.as_str())
                    && string(parser.get("upstreamRevision"))
                        == Some(contract.parser_upstream_revision.as_str())
                    && string(parser.get("binarySha256")) == Some(contract.parser_sha256.as_str())
            })
    });
    let provenance = object(root.get("provenance")).is_some_and(|provenance| {
        exact_keys(
            provenance,
            &[
                "parserAdapterVersion",
                "parserBuildRecipeVersion",
                "schemaAdapterVersion",
                "indexSchemaVersion",
                "upstreamDatabaseSha256",
                "upstreamDatabaseByteCount",
            ],
        ) && string(provenance.get("upstreamDatabaseSha256")).is_some_and(ascii_sha256)
            && integer(provenance.get("upstreamDatabaseByteCount")).is_some_and(|bytes| bytes >= 0)
            && string(provenance.get("parserAdapterVersion"))
                == Some(contract.parser_adapter_version.as_str())
            && string(provenance.get("parserBuildRecipeVersion"))
                == Some(contract.parser_build_recipe_version.as_str())
            && string(provenance.get("schemaAdapterVersion"))
                == Some(contract.schema_adapter_version.as_str())
            && integer(provenance.get("indexSchemaVersion")) == Some(contract.index_schema_version)
    });
    tool && request
        && limits
        && trace
        && provenance
        && valid_data_quality(root.get("dataQuality"))
        && valid_truncation(root.get("truncation"))
        && valid_result(
            root.get("result"),
            root.get("trace"),
            root.get("truncation"),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Replays the Swift oracle `rust/tests/fixtures/arktrace-summary-validator`
    /// (`ArkTraceSummaryValidatorOracleContractTests`): every verdict Swift's
    /// validator gave, for every envelope and invocation it was given.
    #[test]
    fn rust_judges_the_swift_summary_envelopes() {
        let oracle: Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/arktrace-summary-validator/cases.json"
        ))
        .unwrap();
        let recorded = &oracle["contract"];
        let text = |key: &str| recorded[key].as_str().unwrap().to_owned();
        let contract = ArkTraceContract {
            tool_version: text("toolVersion"),
            parser_version: text("parserVersion"),
            parser_upstream_revision: text("parserUpstreamRevision"),
            parser_sha256: text("parserSHA256"),
            parser_build_recipe_version: text("parserBuildRecipeVersion"),
            parser_adapter_version: text("parserAdapterVersion"),
            schema_adapter_version: text("schemaAdapterVersion"),
            index_schema_version: recorded["indexSchemaVersion"].as_i64().unwrap(),
        };
        let mut differences = Vec::new();
        let cases = oracle["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 95);
        for case in cases {
            let invocation = &case["invocation"];
            let arguments: Vec<String> = invocation["arguments"]
                .as_array()
                .unwrap()
                .iter()
                .map(|argument| argument.as_str().unwrap().to_owned())
                .collect();
            let valid = valid_summary(
                case["envelope"].as_str().unwrap().as_bytes(),
                &SummaryInvocation {
                    analyzer_ref: invocation["analyzerRef"].as_str().unwrap(),
                    executable_sha256: invocation["executableSHA256"].as_str().unwrap(),
                    arguments: &arguments,
                    timeout_seconds: invocation["timeoutSeconds"].as_i64().unwrap(),
                    output_byte_budget: invocation["outputByteBudget"].as_u64(),
                    source_sha256: invocation["sourceSHA256"].as_str().unwrap(),
                    source_byte_count: invocation["sourceByteCount"].as_u64().unwrap(),
                    contract: invocation["contract"].as_bool().map(|_| &contract),
                },
            );
            if Value::Bool(valid) != case["valid"] {
                differences.push(format!(
                    "{}: swift {} rust {valid}",
                    case["name"], case["valid"]
                ));
            }
        }
        assert!(differences.is_empty(), "{}", differences.join("\n"));
    }
}
