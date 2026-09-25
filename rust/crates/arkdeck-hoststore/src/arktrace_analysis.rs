//! Swift `ArkTraceAnalysisRequest` and `ArkTraceAnalysisEnvelopeValidator`:
//! the closed request an `analyzer.analyze-trace@1` Job's inputs make — its
//! cross-field contract, the arguments the reviewed CLI is given, its process
//! deadline and the path-free digest its durable action keeps — and the only
//! ArkTrace wire result that request accepts: the CLI's `context` or
//! `analyze` JSON envelope for exactly that invocation, whose tool, source,
//! parser, provenance, request echo, limits, data quality and truncation
//! agree with it, and whose rows, counts, ranges, keys and sections agree
//! with one another. The envelope is read as Swift's `JSONDecoder` reads a
//! `JSONValue` (member names unique and compared under canonical
//! equivalence, an integral number an integer); success authorizes
//! publishing the exact bytes, never a re-encoding.
use crate::arktrace_doctor::{boolean, exact_keys};
use crate::arktrace_profile::ArkTraceContract;
use crate::arktrace_summary::{ascii_sha256, contains_private_path, safe, valid_data_quality};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) const HALF_WINDOW_NS: i64 = 50_000_000;

/// Swift `ArkTraceAnalysisKind`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    Context,
    Cpu,
    Scheduling,
    Slices,
    Range,
    HotIntervals,
}

impl Kind {
    fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "context" => Self::Context,
            "cpu" => Self::Cpu,
            "scheduling" => Self::Scheduling,
            "slices" => Self::Slices,
            "range" => Self::Range,
            "hot-intervals" => Self::HotIntervals,
            _ => return None,
        })
    }

    pub(crate) fn raw(self) -> &'static str {
        match self {
            Self::Context => "context",
            Self::Cpu => "cpu",
            Self::Scheduling => "scheduling",
            Self::Slices => "slices",
            Self::Range => "range",
            Self::HotIntervals => "hot-intervals",
        }
    }
}

/// Swift `ArkTraceAnalysisRequest`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct AnalysisRequest {
    pub kind: Kind,
    pub timestamp_ns: Option<i64>,
    pub start_ns: Option<i64>,
    pub end_ns: Option<i64>,
    pub process_key: Option<i64>,
    pub pid: Option<i64>,
    pub thread_key: Option<i64>,
    pub tid: Option<i64>,
    pub threshold_ns: i64,
    pub limit: i64,
    pub timeout_ms: i64,
    pub max_rows: i64,
    pub max_events: i64,
    pub max_output_bytes: i64,
}

const CLOSED: &str = "analyzer analysis inputs violate the closed request contract";
const INCOMPLETE: &str = "analyzer analysis inputs are incomplete";
const TIME_SELECTION: &str = "analyzer analysis time selection is invalid";

impl AnalysisRequest {
    /// Swift `AnalyzerProvider.analysisRequest(_:)`: the request a Job's
    /// inputs make, or the provider's refusal.
    pub(crate) fn parse(inputs: &Map<String, Value>) -> Result<Self, &'static str> {
        let integer = |key: &str| match inputs.get(key) {
            Some(Value::Number(number)) => number.as_i64(),
            _ => None,
        };
        let present = |key: &str| inputs.contains_key(key);
        let optional = [
            "timestampNs",
            "startNs",
            "endNs",
            "processKey",
            "pid",
            "threadKey",
            "tid",
            "thresholdNs",
            "limit",
        ];
        let allowed = [
            "sourceArtifactRef",
            "kind",
            "timeoutMs",
            "maxRows",
            "maxEvents",
            "maxOutputBytes",
        ];
        if !inputs
            .keys()
            .all(|key| optional.contains(&key.as_str()) || allowed.contains(&key.as_str()))
            || !optional
                .iter()
                .all(|key| !present(key) || integer(key).is_some())
        {
            return Err(CLOSED);
        }
        let kind = inputs
            .get("kind")
            .and_then(Value::as_str)
            .and_then(Kind::parse);
        let (Some(kind), Some(timeout), Some(max_rows), Some(max_events), Some(max_output)) = (
            kind,
            integer("timeoutMs"),
            integer("maxRows"),
            integer("maxEvents"),
            integer("maxOutputBytes"),
        ) else {
            return Err(INCOMPLETE);
        };
        let timestamp = integer("timestampNs");
        let start = integer("startNs");
        let end = integer("endNs");
        let threshold = integer("thresholdNs").unwrap_or(0);
        let default_limit = 1_000.min(max_rows.min(max_events));
        let limit = integer("limit").unwrap_or(default_limit);
        let (has_timestamp, has_start, has_end) =
            (present("timestampNs"), present("startNs"), present("endNs"));
        let contract = ((has_timestamp && !has_start && !has_end)
            || (!has_timestamp && has_start && has_end))
            && match (start, end) {
                (None, None) => true,
                (Some(start), Some(end)) => start < end,
                _ => false,
            }
            && (100..=120_000).contains(&timeout)
            && (1..=100_000).contains(&max_rows)
            && (1..=100_000).contains(&max_events)
            && (1_024..=64 * 1_024 * 1_024).contains(&max_output)
            && threshold >= 0
            && limit >= 1
            && limit <= 1_000.min(max_rows.min(max_events))
            && timestamp.is_none_or(|value| value >= 0)
            && start.is_none_or(|value| value >= 0)
            && end.is_none_or(|value| value >= 1)
            && integer("pid").is_none_or(|value| value >= 0)
            && integer("tid").is_none_or(|value| value >= 0)
            && integer("processKey") != Some(0)
            && integer("threadKey") != Some(0)
            && !(present("processKey") && present("pid"))
            && !(present("threadKey") && present("tid"))
            && (kind != Kind::Context || (!present("thresholdNs") && !present("limit")));
        if !contract {
            return Err(CLOSED);
        }
        let request = Self {
            kind,
            timestamp_ns: timestamp,
            start_ns: start,
            end_ns: end,
            process_key: integer("processKey"),
            pid: integer("pid"),
            thread_key: integer("threadKey"),
            tid: integer("tid"),
            threshold_ns: threshold,
            limit,
            timeout_ms: timeout,
            max_rows,
            max_events,
            max_output_bytes: max_output,
        };
        if request.normalized_range().is_none() {
            return Err(TIME_SELECTION);
        }
        Ok(request)
    }

    /// Swift `processTimeoutSeconds`: the budget in whole seconds, at least
    /// one and at most 120.
    pub(crate) fn process_timeout_seconds(&self) -> i64 {
        1.max(120.min((self.timeout_ms + 999) / 1_000))
    }

    /// Swift `recoveryDigestSHA256`: the path-free identity a durable
    /// analyzer action keeps.
    pub(crate) fn recovery_digest_sha256(&self) -> String {
        let optional =
            |value: Option<i64>| value.map_or("null".to_owned(), |value| value.to_string());
        let fields = [
            "arktrace-analysis-request@1".to_owned(),
            self.kind.raw().to_owned(),
            optional(self.timestamp_ns),
            optional(self.start_ns),
            optional(self.end_ns),
            optional(self.process_key),
            optional(self.pid),
            optional(self.thread_key),
            optional(self.tid),
            self.threshold_ns.to_string(),
            self.limit.to_string(),
            self.timeout_ms.to_string(),
            self.max_rows.to_string(),
            self.max_events.to_string(),
            self.max_output_bytes.to_string(),
        ];
        arkdeck_contract::sha256_hex(fields.join("\0").as_bytes())
    }

    /// Swift `normalizedRange`: the explicit range, or the 100 ms window
    /// centred on the timestamp, clamped at zero.
    pub(crate) fn normalized_range(&self) -> Option<(i64, i64)> {
        if let (Some(start), Some(end)) = (self.start_ns, self.end_ns) {
            return Some((start, end));
        }
        let timestamp = self.timestamp_ns?;
        let start = 0.max(timestamp - timestamp.min(HALF_WINDOW_NS));
        let (end, overflow) = timestamp.overflowing_add(HALF_WINDOW_NS);
        (!overflow && start < end).then_some((start, end))
    }

    /// Swift `arguments(sourcePath:)`.
    pub(crate) fn arguments(&self, source_path: &str) -> Vec<String> {
        let mut result: Vec<String> = [
            if self.kind == Kind::Context {
                "context"
            } else {
                "analyze"
            },
            "--json",
            "--no-cache",
            "--timeout-ms",
        ]
        .map(str::to_owned)
        .to_vec();
        result.extend([
            self.timeout_ms.to_string(),
            "--max-rows".into(),
            self.max_rows.to_string(),
            "--max-events".into(),
            self.max_events.to_string(),
            "--max-output-bytes".into(),
            self.max_output_bytes.to_string(),
        ]);
        if let (Kind::Context, Some(timestamp)) = (self.kind, self.timestamp_ns) {
            result.extend([
                "--timestamp-ns".into(),
                timestamp.to_string(),
                "--window-ms".into(),
                "50".into(),
            ]);
        } else if let Some((start, end)) = self.normalized_range() {
            if self.kind != Kind::Context {
                result.extend(["--kind".into(), self.kind.raw().into()]);
            }
            result.extend([
                "--start-ns".into(),
                start.to_string(),
                "--end-ns".into(),
                end.to_string(),
            ]);
        }
        for (value, flag) in [
            (self.process_key, "--process-key"),
            (self.pid, "--pid"),
            (self.thread_key, "--thread-key"),
            (self.tid, "--tid"),
        ] {
            if let Some(value) = value {
                result.extend([flag.to_owned(), value.to_string()]);
            }
        }
        if self.kind != Kind::Context {
            result.extend([
                "--threshold-ns".into(),
                self.threshold_ns.to_string(),
                "--limit".into(),
                self.limit.to_string(),
            ]);
        }
        result.push(source_path.to_owned());
        result
    }
}

/// What a verified analysis answers: the invocation a Job's typed action
/// recorded.
pub(crate) struct AnalysisInvocation<'a> {
    pub analyzer_ref: &'a str,
    pub executable_sha256: &'a str,
    pub arguments: &'a [String],
    pub timeout_seconds: i64,
    pub output_byte_budget: Option<u64>,
    pub source_sha256: &'a str,
    pub source_byte_count: u64,
    pub request: Option<&'a AnalysisRequest>,
    pub contract: Option<&'a ArkTraceContract>,
}

// MARK: JSONValue reading

type Object = Map<String, Value>;

/// Swift `String` equality: canonical equivalence.
fn same_text(value: &str, expected: &str) -> bool {
    if value == expected || (value.is_ascii() && expected.is_ascii()) {
        return value == expected;
    }
    match (
        arkdeck_platform::host_canonical_text(value),
        arkdeck_platform::host_canonical_text(expected),
    ) {
        (Some(value), Some(expected)) => value == expected,
        _ => false,
    }
}

/// A decoded `[String: JSONValue]` tree whose member names are their
/// canonical form, so a lookup by name compares as Swift's `String` does.
fn canonical_names(value: Value) -> Option<Value> {
    Some(match value {
        Value::Object(fields) => {
            let mut canonical = Map::new();
            for (name, value) in fields {
                let name = if name.is_ascii() {
                    name
                } else {
                    arkdeck_platform::host_canonical_text(&name)?
                };
                canonical.insert(name, canonical_names(value)?);
            }
            Value::Object(canonical)
        }
        Value::Array(items) => Value::Array(
            items
                .into_iter()
                .map(canonical_names)
                .collect::<Option<Vec<_>>>()?,
        ),
        other => other,
    })
}

fn object(value: Option<&Value>) -> Option<&Object> {
    value?.as_object()
}

fn array(value: Option<&Value>) -> Option<&Vec<Value>> {
    value?.as_array()
}

fn string(value: Option<&Value>) -> Option<&str> {
    value?.as_str()
}

fn text_is(value: Option<&Value>, expected: &str) -> bool {
    string(value).is_some_and(|text| same_text(text, expected))
}

fn text_in(value: &str, allowed: &[&str]) -> bool {
    allowed.iter().any(|expected| same_text(value, expected))
}

/// Swift `integer(_:)`: `.integer`, or `.unsignedInteger` exactly in Int64.
fn integer(value: Option<&Value>) -> Option<i64> {
    value?.as_i64()
}

fn finite_number(value: Option<&Value>) -> Option<f64> {
    value?.as_f64().filter(|value| value.is_finite())
}

fn is_null(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Null))
}

fn matches_optional_integer(value: Option<&Value>, expected: Option<i64>) -> bool {
    match expected {
        Some(expected) => integer(value) == Some(expected),
        None => is_null(value),
    }
}

fn optional_integer(value: Option<&Value>) -> bool {
    is_null(value) || integer(value).is_some()
}

fn optional_nonnegative_integer(value: Option<&Value>) -> bool {
    is_null(value) || integer(value).is_some_and(|value| value >= 0)
}

fn optional_boolean(value: Option<&Value>) -> bool {
    is_null(value) || boolean(value).is_some()
}

fn optional_text(value: Option<&Value>, maximum_bytes: usize) -> bool {
    is_null(value) || string(value).is_some_and(|text| safe(text, maximum_bytes))
}

fn optional_enum(value: Option<&Value>, allowed: &[&str]) -> bool {
    is_null(value) || string(value).is_some_and(|text| text_in(text, allowed))
}

fn string_array(value: Option<&Value>, maximum_count: usize) -> Option<Vec<&str>> {
    let rows = array(value)?;
    if rows.len() > maximum_count {
        return None;
    }
    rows.iter()
        .map(|row| row.as_str().filter(|text| safe(text, 128)))
        .collect()
}

fn checked_total(values: &[usize]) -> Option<usize> {
    values
        .iter()
        .try_fold(0usize, |total, value| total.checked_add(*value))
        .filter(|total| i64::try_from(*total).is_ok())
}

fn checked_sum(values: &[i64]) -> Option<i64> {
    values
        .iter()
        .try_fold(0i64, |total, value| total.checked_add(*value))
}

fn range_duration(value: Option<&Value>) -> Option<i64> {
    let range = object(value)?;
    let (start, end) = (integer(range.get("startNs"))?, integer(range.get("endNs"))?);
    (start <= end).then(|| end.checked_sub(start)).flatten()
}

fn range_is_contained(value: Option<&Value>, expected: (i64, i64)) -> bool {
    let Some(range) = object(value) else {
        return false;
    };
    let (Some(start), Some(end)) = (integer(range.get("startNs")), integer(range.get("endNs")))
    else {
        return false;
    };
    start >= expected.0 && end <= expected.1
}

fn range_intersects(value: Option<&Value>, expected: (i64, i64)) -> bool {
    let Some(range) = object(value) else {
        return false;
    };
    let (Some(start), Some(end)) = (integer(range.get("startNs")), integer(range.get("endNs")))
    else {
        return false;
    };
    if start == end {
        return start >= expected.0 && start < expected.1;
    }
    start < expected.1 && end > expected.0
}

fn approximately_equal(lhs: f64, rhs: f64) -> bool {
    if !lhs.is_finite() || !rhs.is_finite() {
        return false;
    }
    let tolerance = 1e-12f64.max(rhs.abs() * 1e-12);
    (lhs - rhs).abs() <= tolerance
}

fn valid_range(value: Option<&Value>, expected: Option<(i64, i64)>) -> bool {
    let Some(range) = object(value) else {
        return false;
    };
    let (Some(start), Some(end)) = (integer(range.get("startNs")), integer(range.get("endNs")))
    else {
        return false;
    };
    exact_keys(range, &["startNs", "endNs"])
        && start >= 0
        && start <= end
        && expected.is_none_or(|expected| start == expected.0 && end == expected.1)
}

fn valid_event_key(value: Option<&Value>) -> bool {
    let Some(key) = object(value) else {
        return false;
    };
    exact_keys(key, &["table", "rowID"])
        && string(key.get("table")).is_some_and(|table| safe(table, 128))
        && integer(key.get("rowID")).is_some()
}

fn valid_optional_event_key(value: Option<&Value>) -> bool {
    is_null(value) || valid_event_key(value)
}

fn key_value(value: Option<&Value>, field: &str) -> Option<i64> {
    let key = object(value)?;
    if !exact_keys(key, &[field]) {
        return None;
    }
    integer(key.get(field)).filter(|key| *key != 0)
}

fn valid_key(value: Option<&Value>, field: &str) -> bool {
    key_value(value, field).is_some()
}

fn valid_optional_key(value: Option<&Value>, field: &str) -> bool {
    is_null(value) || valid_key(value, field)
}

fn matches_optional_key(value: Option<&Value>, field: &str, expected: Option<i64>) -> bool {
    match expected {
        Some(expected) => object(value).is_some_and(|key| {
            exact_keys(key, &[field]) && integer(key.get(field)) == Some(expected)
        }),
        None => is_null(value),
    }
}

// MARK: The envelope

struct TraceIdentity {
    duration_ns: i64,
    schema_fingerprint: String,
}

/// Swift `ArkTraceAnalysisEnvelopeValidator.validate(_:invocation:)`.
pub(crate) fn valid_analysis(bytes: &[u8], invocation: &AnalysisInvocation<'_>) -> bool {
    let (Some(request), Some(contract)) = (invocation.request, invocation.contract) else {
        return false;
    };
    let Some(source_path) = invocation.arguments.last() else {
        return false;
    };
    if invocation.analyzer_ref != "trace-analysis@1"
        || invocation.source_byte_count == 0
        || !ascii_sha256(invocation.source_sha256)
        || !ascii_sha256(invocation.executable_sha256)
        || invocation.timeout_seconds != request.process_timeout_seconds()
        || invocation.output_byte_budget != u64::try_from(request.max_output_bytes).ok()
        || bytes.len() as u64 > request.max_output_bytes as u64
        || source_path.is_empty()
        || invocation.arguments != request.arguments(source_path).as_slice()
        || bytes
            .windows(source_path.len())
            .any(|window| window == source_path.as_bytes())
    {
        return false;
    }
    if crate::strict_json::validate(bytes).is_err() {
        return false;
    }
    let Some(decoded) = crate::session_json::parse_foundation(bytes)
        .ok()
        .and_then(canonical_names)
    else {
        return false;
    };
    let Some(root) = decoded.as_object() else {
        return false;
    };
    if !exact_keys(
        root,
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
    ) || !text_is(root.get("schemaVersion"), "1.0")
    {
        return false;
    }
    // Swift reads the same bytes as `JSONSerialization` for the path check.
    let Ok(Value::Object(bridged)) = serde_json::from_slice::<Value>(bytes) else {
        return false;
    };
    if contains_private_path(&Value::Object(bridged), source_path)
        || !valid_tool(root.get("tool"), invocation, contract)
        || !valid_limits(root.get("limits"), request)
    {
        return false;
    }
    let Some(trace) = valid_trace(root.get("trace"), invocation, contract) else {
        return false;
    };
    valid_provenance(root.get("provenance"), contract)
        && valid_request(root.get("request"), request)
        && valid_data_quality(root.get("dataQuality"))
        && valid_truncation_root(root.get("truncation"))
        && if request.kind == Kind::Context {
            valid_context_result(
                root.get("result"),
                request,
                &trace,
                root.get("dataQuality"),
                root.get("truncation"),
            )
        } else {
            valid_analysis_result(
                root.get("result"),
                request,
                &trace,
                root.get("dataQuality"),
                root.get("truncation"),
            )
        }
}

fn valid_tool(
    value: Option<&Value>,
    invocation: &AnalysisInvocation<'_>,
    contract: &ArkTraceContract,
) -> bool {
    object(value).is_some_and(|tool| {
        exact_keys(tool, &["name", "version", "buildRevision"])
            && text_is(tool.get("name"), "arktrace")
            && text_is(tool.get("version"), &contract.tool_version)
            && text_is(tool.get("buildRevision"), invocation.executable_sha256)
    })
}

fn valid_limits(value: Option<&Value>, request: &AnalysisRequest) -> bool {
    object(value).is_some_and(|limits| {
        exact_keys(
            limits,
            &["timeoutMs", "maxRows", "maxEvents", "maxOutputBytes"],
        ) && integer(limits.get("timeoutMs")) == Some(request.timeout_ms)
            && integer(limits.get("maxRows")) == Some(request.max_rows)
            && integer(limits.get("maxEvents")) == Some(request.max_events)
            && integer(limits.get("maxOutputBytes")) == Some(request.max_output_bytes)
    })
}

fn valid_trace(
    value: Option<&Value>,
    invocation: &AnalysisInvocation<'_>,
    contract: &ArkTraceContract,
) -> Option<TraceIdentity> {
    let trace = object(value)?;
    let duration = integer(trace.get("durationNs"))?;
    let schema = string(trace.get("schemaFingerprint"))?;
    let parser = object(trace.get("parser"))?;
    let valid = exact_keys(
        trace,
        &[
            "sha256",
            "byteCount",
            "durationNs",
            "parser",
            "schemaFingerprint",
        ],
    ) && text_is(trace.get("sha256"), invocation.source_sha256)
        && integer(trace.get("byteCount")) == i64::try_from(invocation.source_byte_count).ok()
        && duration >= 0
        && ascii_sha256(schema)
        && exact_keys(
            parser,
            &["name", "version", "upstreamRevision", "binarySha256"],
        )
        && text_is(parser.get("name"), "trace_streamer")
        && text_is(parser.get("version"), &contract.parser_version)
        && text_is(
            parser.get("upstreamRevision"),
            &contract.parser_upstream_revision,
        )
        && text_is(parser.get("binarySha256"), &contract.parser_sha256);
    valid.then(|| TraceIdentity {
        duration_ns: duration,
        schema_fingerprint: schema.to_owned(),
    })
}

fn valid_provenance(value: Option<&Value>, contract: &ArkTraceContract) -> bool {
    object(value).is_some_and(|provenance| {
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
            && integer(provenance.get("upstreamDatabaseByteCount")).is_some_and(|count| count >= 0)
            && text_is(
                provenance.get("parserAdapterVersion"),
                &contract.parser_adapter_version,
            )
            && text_is(
                provenance.get("parserBuildRecipeVersion"),
                &contract.parser_build_recipe_version,
            )
            && text_is(
                provenance.get("schemaAdapterVersion"),
                &contract.schema_adapter_version,
            )
            && integer(provenance.get("indexSchemaVersion")) == Some(contract.index_schema_version)
    })
}

const FILTER_KEYS: [&str; 12] = [
    "cpu",
    "processKey",
    "pid",
    "threadKey",
    "tid",
    "rawState",
    "normalizedState",
    "name",
    "nameMatch",
    "minimumDurationNs",
    "depth",
    "counterFilterID",
];

const UNREQUESTED_FILTERS: [&str; 7] = [
    "cpu",
    "rawState",
    "normalizedState",
    "name",
    "minimumDurationNs",
    "depth",
    "counterFilterID",
];

fn with_filters(extra: &[&'static str]) -> Vec<&'static str> {
    FILTER_KEYS.iter().chain(extra).copied().collect()
}

fn valid_request(value: Option<&Value>, request: &AnalysisRequest) -> bool {
    let Some(echo) = object(value) else {
        return false;
    };
    let Some(parameters) = object(echo.get("parameters")) else {
        return false;
    };
    if !exact_keys(echo, &["command", "parameters"]) {
        return false;
    }
    if request.kind == Kind::Context {
        if !text_is(echo.get("command"), "context")
            || !exact_keys(
                parameters,
                &with_filters(&[
                    "startNs",
                    "endNs",
                    "timestampNs",
                    "windowBeforeNs",
                    "windowAfterNs",
                ]),
            )
            || !valid_request_filters(parameters, request)
        {
            return false;
        }
        if let Some(timestamp) = request.timestamp_ns {
            return integer(parameters.get("timestampNs")) == Some(timestamp)
                && integer(parameters.get("windowBeforeNs")) == Some(HALF_WINDOW_NS)
                && integer(parameters.get("windowAfterNs")) == Some(HALF_WINDOW_NS)
                && is_null(parameters.get("startNs"))
                && is_null(parameters.get("endNs"));
        }
        return integer(parameters.get("startNs")) == request.start_ns
            && integer(parameters.get("endNs")) == request.end_ns
            && is_null(parameters.get("timestampNs"))
            && is_null(parameters.get("windowBeforeNs"))
            && is_null(parameters.get("windowAfterNs"));
    }
    let Some(range) = request.normalized_range() else {
        return false;
    };
    text_is(echo.get("command"), "analyze")
        && exact_keys(
            parameters,
            &with_filters(&["kind", "startNs", "endNs", "thresholdNs", "limit"]),
        )
        && valid_request_filters(parameters, request)
        && text_is(parameters.get("kind"), request.kind.raw())
        && integer(parameters.get("startNs")) == Some(range.0)
        && integer(parameters.get("endNs")) == Some(range.1)
        && integer(parameters.get("thresholdNs")) == Some(request.threshold_ns)
        && integer(parameters.get("limit")) == Some(request.limit)
}

fn valid_request_filters(parameters: &Object, request: &AnalysisRequest) -> bool {
    matches_optional_integer(parameters.get("processKey"), request.process_key)
        && matches_optional_integer(parameters.get("pid"), request.pid)
        && matches_optional_integer(parameters.get("threadKey"), request.thread_key)
        && matches_optional_integer(parameters.get("tid"), request.tid)
        && text_is(parameters.get("nameMatch"), "exact")
        && UNREQUESTED_FILTERS
            .iter()
            .all(|key| is_null(parameters.get(*key)))
}

fn valid_result_filters(value: Option<&Value>, request: &AnalysisRequest) -> bool {
    object(value).is_some_and(|filters| {
        exact_keys(filters, &FILTER_KEYS)
            && matches_optional_key(filters.get("processKey"), "ipid", request.process_key)
            && matches_optional_integer(filters.get("pid"), request.pid)
            && matches_optional_key(filters.get("threadKey"), "itid", request.thread_key)
            && matches_optional_integer(filters.get("tid"), request.tid)
            && text_is(filters.get("nameMatch"), "exact")
            && UNREQUESTED_FILTERS
                .iter()
                .all(|key| is_null(filters.get(*key)))
    })
}

/// Swift `expectedRange(request:traceDuration:)`.
fn expected_range(request: &AnalysisRequest, trace_duration: i64) -> Option<(i64, i64)> {
    if let (Kind::Context, Some(timestamp)) = (request.kind, request.timestamp_ns) {
        let start = 0.max(timestamp - timestamp.min(HALF_WINDOW_NS));
        let (candidate, overflow) = timestamp.overflowing_add(HALF_WINDOW_NS);
        let end = trace_duration.min(if overflow { i64::MAX } else { candidate });
        return (start < end).then_some((start, end));
    }
    let range = request.normalized_range()?;
    (range.1 <= trace_duration).then_some(range)
}

// MARK: Context

fn valid_context_result(
    value: Option<&Value>,
    request: &AnalysisRequest,
    trace: &TraceIdentity,
    outer_quality: Option<&Value>,
    outer_truncation: Option<&Value>,
) -> bool {
    let Some(result) = object(value) else {
        return false;
    };
    if !exact_keys(
        result,
        &[
            "range",
            "filters",
            "processes",
            "threads",
            "cpuSlices",
            "threadStates",
            "slices",
            "counters",
            "summary",
            "dataQuality",
            "truncation",
        ],
    ) {
        return false;
    }
    let Some(expected) = expected_range(request, trace.duration_ns) else {
        return false;
    };
    let max_rows = usize::try_from(request.max_rows).unwrap_or(usize::MAX);
    let max_events = usize::try_from(request.max_events).unwrap_or(usize::MAX);
    if !valid_range(result.get("range"), Some(expected))
        || !valid_result_filters(result.get("filters"), request)
        || !valid_data_quality(result.get("dataQuality"))
        || result.get("dataQuality") != outer_quality
    {
        return false;
    }
    let Some(processes) = array(result.get("processes")) else {
        return false;
    };
    if processes.len() > max_rows || !processes.iter().all(valid_process) {
        return false;
    }
    let Some(threads) = array(result.get("threads")) else {
        return false;
    };
    if checked_total(&[processes.len(), threads.len()]).is_none_or(|total| total > max_rows)
        || !threads.iter().all(valid_thread)
    {
        return false;
    }
    let (Some(cpu_slices), Some(thread_states), Some(slices), Some(counters)) = (
        array(result.get("cpuSlices")),
        array(result.get("threadStates")),
        array(result.get("slices")),
        array(result.get("counters")),
    ) else {
        return false;
    };
    if !cpu_slices.iter().all(|row| valid_cpu_slice(row, expected))
        || !thread_states
            .iter()
            .all(|row| valid_thread_state(row, expected))
        || !slices.iter().all(|row| valid_slice(row, expected))
        || !counters
            .iter()
            .all(|row| valid_counter_series(row, expected))
        || !valid_context_capabilities(
            result.get("summary"),
            cpu_slices,
            thread_states,
            slices,
            counters,
        )
        || !valid_context_references(
            processes,
            threads,
            cpu_slices,
            thread_states,
            slices,
            counters,
            result.get("truncation"),
        )
    {
        return false;
    }
    let sample_counts: Vec<usize> = counters.iter().filter_map(counter_sample_count).collect();
    let Some(counter_samples) = checked_total(&sample_counts) else {
        return false;
    };
    if checked_total(&[
        cpu_slices.len(),
        thread_states.len(),
        slices.len(),
        counter_samples,
    ])
    .is_none_or(|total| total > max_events)
        || !valid_context_summary(
            result.get("summary"),
            expected,
            trace,
            request,
            result.get("dataQuality"),
        )
    {
        return false;
    }
    let counts = BTreeMap::from([
        ("processes", processes.len()),
        ("threads", threads.len()),
        ("cpuSlices", cpu_slices.len()),
        ("threadStates", thread_states.len()),
        ("slices", slices.len()),
        ("counters", counter_samples),
        ("summary", 1),
    ]);
    valid_outer_truncation(
        outer_truncation,
        valid_context_truncation(result.get("truncation"), &counts).as_deref(),
    )
}

fn valid_context_summary(
    value: Option<&Value>,
    expected: (i64, i64),
    trace: &TraceIdentity,
    request: &AnalysisRequest,
    context_quality: Option<&Value>,
) -> bool {
    let Some(summary) = object(value) else {
        return false;
    };
    exact_keys(
        summary,
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
            "schemaFingerprint",
            "dataQuality",
            "truncatedSections",
        ],
    ) && valid_range(summary.get("range"), Some(expected))
        && integer(summary.get("durationNs")) == Some(expected.1 - expected.0)
        && text_is(summary.get("schemaFingerprint"), &trace.schema_fingerprint)
        && integer(summary.get("processCount"))
            .is_some_and(|count| count >= 0 && count <= request.max_rows)
        && integer(summary.get("threadCount"))
            .is_some_and(|count| count >= 0 && count <= request.max_rows)
        && valid_data_quality(summary.get("dataQuality"))
        && quality_is_subset(summary.get("dataQuality"), context_quality)
        && valid_capabilities_and_summary_counts(summary, request)
        && valid_event_sources(summary.get("eventCountBySource"), request.max_events)
        && valid_summary_truncated_sections(summary.get("truncatedSections"), summary)
}

fn valid_context_capabilities(
    summary: Option<&Value>,
    cpu_slices: &[Value],
    thread_states: &[Value],
    slices: &[Value],
    counters: &[Value],
) -> bool {
    let Some(capabilities) =
        object(summary).and_then(|summary| object(summary.get("capabilities")))
    else {
        return false;
    };
    let flags: Option<Vec<bool>> = [
        "cpuScheduling",
        "threadStates",
        "namedSlices",
        "cpuCounters",
        "processCounters",
    ]
    .iter()
    .map(|name| boolean(capabilities.get(*name)))
    .collect();
    let Some(
        [
            cpu_scheduling,
            states,
            named_slices,
            cpu_counters,
            process_counters,
        ],
    ) = flags
        .as_deref()
        .and_then(|flags| <[bool; 5]>::try_from(flags).ok())
    else {
        return false;
    };
    if !(cpu_scheduling || cpu_slices.is_empty())
        || !(states || thread_states.is_empty())
        || !(named_slices || slices.is_empty())
    {
        return false;
    }
    counters.iter().all(|row| {
        object(Some(row))
            .and_then(|row| string(row.get("scope")))
            .is_some_and(|scope| {
                (same_text(scope, "cpu") && cpu_counters)
                    || (same_text(scope, "process") && process_counters)
            })
    })
}

fn valid_context_references(
    processes: &[Value],
    threads: &[Value],
    cpu_slices: &[Value],
    thread_states: &[Value],
    slices: &[Value],
    counters: &[Value],
    truncation: Option<&Value>,
) -> bool {
    let process_keys: Vec<i64> = processes
        .iter()
        .filter_map(|row| object(Some(row)).and_then(|row| key_value(row.get("key"), "ipid")))
        .collect();
    let thread_keys: Vec<i64> = threads
        .iter()
        .filter_map(|row| object(Some(row)).and_then(|row| key_value(row.get("key"), "itid")))
        .collect();
    let process_set: BTreeSet<i64> = process_keys.iter().copied().collect();
    let thread_set: BTreeSet<i64> = thread_keys.iter().copied().collect();
    if process_keys.len() != processes.len()
        || process_set.len() != process_keys.len()
        || thread_keys.len() != threads.len()
        || thread_set.len() != thread_keys.len()
    {
        return false;
    }
    let Some(omitted) = object(truncation)
        .and_then(|truncation| boolean(truncation.get("referenceOmittedByBudget")))
    else {
        return false;
    };
    if omitted {
        return true;
    }
    let references = |rows: &[Value], process_field: Option<&str>, thread_field: Option<&str>| {
        rows.iter().all(|row| {
            let Some(row) = object(Some(row)) else {
                return false;
            };
            let process_closed = process_field
                .and_then(|field| key_value(row.get(field), "ipid"))
                .is_none_or(|key| process_set.contains(&key));
            let thread_closed = thread_field
                .and_then(|field| key_value(row.get(field), "itid"))
                .is_none_or(|key| thread_set.contains(&key));
            process_closed && thread_closed
        })
    };
    references(threads, Some("processKey"), None)
        && references(cpu_slices, Some("processKey"), Some("threadKey"))
        && references(thread_states, Some("processKey"), Some("threadKey"))
        && references(slices, Some("processKey"), Some("threadKey"))
        && references(counters, Some("processKey"), None)
}

fn valid_capabilities_and_summary_counts(summary: &Object, request: &AnalysisRequest) -> bool {
    let Some(capabilities) = object(summary.get("capabilities")) else {
        return false;
    };
    let names = [
        "cpuScheduling",
        "threadStates",
        "namedSlices",
        "cpuCounters",
        "processCounters",
    ];
    if !exact_keys(capabilities, &names) {
        return false;
    }
    let flags: Option<Vec<bool>> = names
        .iter()
        .map(|name| boolean(capabilities.get(*name)))
        .collect();
    let Some(
        [
            cpu_scheduling,
            thread_states,
            named_slices,
            cpu_counters,
            process_counters,
        ],
    ) = flags
        .as_deref()
        .and_then(|flags| <[bool; 5]>::try_from(flags).ok())
    else {
        return false;
    };
    let count = |name: &str, available: bool, maximum: i64| {
        if available {
            integer(summary.get(name)).is_some_and(|count| count >= 0 && count <= maximum)
        } else {
            is_null(summary.get(name))
        }
    };
    count("cpuCount", cpu_scheduling, request.max_rows)
        && count("cpuSliceCount", cpu_scheduling, request.max_events)
        && count("threadStateCount", thread_states, request.max_events)
        && count("namedSliceCount", named_slices, request.max_events)
        && count(
            "counterSeriesCount",
            cpu_counters || process_counters,
            request.max_events,
        )
}

fn valid_event_sources(value: Option<&Value>, maximum_rows: i64) -> bool {
    if is_null(value) {
        return true;
    }
    let Some(rows) = array(value) else {
        return false;
    };
    if rows.len() as i64 > maximum_rows {
        return false;
    }
    let mut previous: Option<&[u8]> = None;
    let mut identities = BTreeSet::new();
    for row in rows {
        let Some(row) = row.as_object() else {
            return false;
        };
        let Some(source) = string(row.get("source")) else {
            return false;
        };
        if !exact_keys(row, &["source", "count"])
            || !safe(source, 1_024)
            || integer(row.get("count")).is_none_or(|count| count < 0)
        {
            return false;
        }
        let bytes = source.as_bytes();
        if previous.is_some_and(|previous| previous >= bytes) || !identities.insert(bytes) {
            return false;
        }
        previous = Some(bytes);
    }
    true
}

fn valid_summary_truncated_sections(value: Option<&Value>, summary: &Object) -> bool {
    let Some(sections) = string_array(value, 8) else {
        return false;
    };
    let ordered = [
        "cpuCount",
        "processCount",
        "threadCount",
        "cpuSliceCount",
        "threadStateCount",
        "namedSliceCount",
        "counterSeriesCount",
        "eventCountBySource",
    ];
    let mut unique = Vec::<&str>::new();
    for section in &sections {
        if unique.iter().any(|seen| same_text(seen, section)) {
            return false;
        }
        unique.push(section);
    }
    let positions: Vec<usize> = sections
        .iter()
        .filter_map(|section| ordered.iter().position(|name| same_text(section, name)))
        .collect();
    if positions.len() != sections.len() || !positions.is_sorted() {
        return false;
    }
    let unavailable: Vec<&str> = [
        "cpuCount",
        "cpuSliceCount",
        "threadStateCount",
        "namedSliceCount",
        "counterSeriesCount",
        "eventCountBySource",
    ]
    .into_iter()
    .filter(|name| is_null(summary.get(*name)))
    .collect();
    !sections
        .iter()
        .any(|section| unavailable.iter().any(|name| same_text(section, name)))
}

fn valid_context_truncation(
    value: Option<&Value>,
    counts: &BTreeMap<&str, usize>,
) -> Option<Vec<String>> {
    let truncation = object(value)?;
    let names = [
        "processes",
        "threads",
        "cpuSlices",
        "threadStates",
        "slices",
        "counters",
        "summary",
    ];
    let mut all: Vec<&str> = names.to_vec();
    all.push("referenceOmittedByBudget");
    if !exact_keys(truncation, &all) {
        return None;
    }
    let references = boolean(truncation.get("referenceOmittedByBudget"))?;
    let mut truncated = Vec::new();
    for name in names {
        if valid_section_status(truncation.get(name), *counts.get(name)?, false)? {
            truncated.push(name.to_owned());
        }
    }
    if references {
        truncated.push("references".to_owned());
    }
    truncated.sort();
    Some(truncated)
}

fn valid_analysis_sections(
    value: Option<&Value>,
    counts: &BTreeMap<&str, usize>,
) -> Option<Vec<String>> {
    let names = [
        "cpuUtilization",
        "topProcesses",
        "topThreads",
        "longSlices",
        "threadStateDistribution",
        "schedulingLatency",
        "hotIntervals",
    ];
    let sections = object(value)?;
    if !exact_keys(sections, &names) {
        return None;
    }
    let mut truncated = Vec::new();
    for name in names {
        let aggregates = name == "cpuUtilization" || name == "threadStateDistribution";
        if valid_section_status(sections.get(name), *counts.get(name)?, aggregates)? {
            truncated.push(name.to_owned());
        }
    }
    truncated.sort();
    Some(truncated)
}

/// Swift `validateSectionStatus`: whether the section is truncated, or
/// `None` when its status does not hold.
fn valid_section_status(
    value: Option<&Value>,
    returned: usize,
    permits_aggregation: bool,
) -> Option<bool> {
    let status = object(value)?;
    let returned = i64::try_from(returned).ok()?;
    if !exact_keys(status, &["returnedCount", "matchedCount", "truncated"])
        || integer(status.get("returnedCount")) != Some(returned)
    {
        return None;
    }
    let truncated = boolean(status.get("truncated"))?;
    if is_null(status.get("matchedCount")) {
        if !truncated {
            return None;
        }
    } else {
        let matched = integer(status.get("matchedCount"))?;
        if matched < returned || !(matched == returned || truncated || permits_aggregation) {
            return None;
        }
    }
    Some(truncated)
}

fn valid_outer_truncation(value: Option<&Value>, expected: Option<&[String]>) -> bool {
    let (Some(expected), Some(truncation)) = (expected, object(value)) else {
        return false;
    };
    let Some(truncated) = boolean(truncation.get("truncated")) else {
        return false;
    };
    let Some(sections) = string_array(truncation.get("sections"), 256) else {
        return false;
    };
    exact_keys(truncation, &["truncated", "sections"])
        && sections.len() == expected.len()
        && sections
            .iter()
            .zip(expected)
            .all(|(section, expected)| same_text(section, expected))
        && truncated == !sections.is_empty()
}

fn valid_truncation_root(value: Option<&Value>) -> bool {
    let Some(truncation) = object(value) else {
        return false;
    };
    let Some(truncated) = boolean(truncation.get("truncated")) else {
        return false;
    };
    let Some(sections) = string_array(truncation.get("sections"), 256) else {
        return false;
    };
    let mut sorted = sections.clone();
    sorted.sort();
    let mut unique: Vec<&str> = Vec::new();
    for section in &sections {
        if unique.iter().any(|seen| same_text(seen, section)) {
            return false;
        }
        unique.push(section);
    }
    exact_keys(truncation, &["truncated", "sections"])
        && sections == sorted
        && truncated == !sections.is_empty()
}

fn quality_is_subset(lhs: Option<&Value>, rhs: Option<&Value>) -> bool {
    let (Some(left), Some(right)) = (object(lhs), object(rhs)) else {
        return false;
    };
    let (Some(left), Some(right)) = (array(left.get("warnings")), array(right.get("warnings")))
    else {
        return false;
    };
    left.iter().all(|warning| right.contains(warning))
}

// MARK: Context rows

fn valid_process(value: &Value) -> bool {
    object(Some(value)).is_some_and(|row| {
        exact_keys(
            row,
            &["key", "pid", "name", "startNs", "endNs", "threadCount"],
        ) && valid_key(row.get("key"), "ipid")
            && integer(row.get("pid")).is_some()
            && optional_text(row.get("name"), 4_096)
            && optional_nonnegative_integer(row.get("startNs"))
            && optional_nonnegative_integer(row.get("endNs"))
            && optional_nonnegative_integer(row.get("threadCount"))
    })
}

fn valid_thread(value: &Value) -> bool {
    object(Some(value)).is_some_and(|row| {
        exact_keys(
            row,
            &[
                "key",
                "processKey",
                "tid",
                "pid",
                "name",
                "processName",
                "startNs",
                "endNs",
                "isMainThread",
            ],
        ) && valid_key(row.get("key"), "itid")
            && valid_optional_key(row.get("processKey"), "ipid")
            && integer(row.get("tid")).is_some()
            && optional_integer(row.get("pid"))
            && optional_text(row.get("name"), 4_096)
            && optional_text(row.get("processName"), 4_096)
            && optional_nonnegative_integer(row.get("startNs"))
            && optional_nonnegative_integer(row.get("endNs"))
            && optional_boolean(row.get("isMainThread"))
    })
}

fn valid_cpu_slice(value: &Value, range: (i64, i64)) -> bool {
    object(Some(value)).is_some_and(|row| {
        exact_keys(
            row,
            &[
                "key",
                "range",
                "cpu",
                "threadKey",
                "processKey",
                "tid",
                "pid",
                "threadName",
                "processName",
                "endState",
                "priority",
                "isOpenEnded",
            ],
        ) && valid_event_key(row.get("key"))
            && valid_range(row.get("range"), None)
            && range_intersects(row.get("range"), range)
            && integer(row.get("cpu")).is_some_and(|cpu| cpu >= 0)
            && valid_optional_key(row.get("threadKey"), "itid")
            && valid_optional_key(row.get("processKey"), "ipid")
            && optional_integer(row.get("tid"))
            && optional_integer(row.get("pid"))
            && optional_text(row.get("threadName"), 4_096)
            && optional_text(row.get("processName"), 4_096)
            && optional_text(row.get("endState"), 4_096)
            && optional_integer(row.get("priority"))
            && boolean(row.get("isOpenEnded")).is_some()
    })
}

const NORMALIZED_STATES: [&str; 5] = ["running", "runnable", "sleeping", "blocked", "stopped"];

fn valid_thread_state(value: &Value, range: (i64, i64)) -> bool {
    object(Some(value)).is_some_and(|row| {
        exact_keys(
            row,
            &[
                "key",
                "range",
                "threadKey",
                "processKey",
                "state",
                "normalizedState",
                "cpu",
                "tid",
                "pid",
                "processName",
                "threadName",
                "isOpenEnded",
            ],
        ) && valid_event_key(row.get("key"))
            && valid_range(row.get("range"), None)
            && range_intersects(row.get("range"), range)
            && valid_key(row.get("threadKey"), "itid")
            && valid_optional_key(row.get("processKey"), "ipid")
            && string(row.get("state")).is_some_and(|state| safe(state, 4_096))
            && optional_enum(row.get("normalizedState"), &NORMALIZED_STATES)
            && optional_nonnegative_integer(row.get("cpu"))
            && optional_integer(row.get("tid"))
            && optional_integer(row.get("pid"))
            && optional_text(row.get("processName"), 4_096)
            && optional_text(row.get("threadName"), 4_096)
            && boolean(row.get("isOpenEnded")).is_some()
    })
}

fn valid_slice(value: &Value, range: (i64, i64)) -> bool {
    object(Some(value)).is_some_and(|row| {
        exact_keys(
            row,
            &[
                "key",
                "range",
                "threadKey",
                "processKey",
                "pid",
                "tid",
                "processName",
                "threadName",
                "name",
                "category",
                "depth",
                "parentEventKey",
                "isAsync",
                "isOpenEnded",
            ],
        ) && valid_event_key(row.get("key"))
            && valid_range(row.get("range"), None)
            && range_intersects(row.get("range"), range)
            && valid_optional_key(row.get("threadKey"), "itid")
            && valid_optional_key(row.get("processKey"), "ipid")
            && optional_integer(row.get("pid"))
            && optional_integer(row.get("tid"))
            && optional_text(row.get("processName"), 4_096)
            && optional_text(row.get("threadName"), 4_096)
            && string(row.get("name")).is_some_and(|name| safe(name, 4_096))
            && optional_text(row.get("category"), 4_096)
            && optional_nonnegative_integer(row.get("depth"))
            && valid_optional_event_key(row.get("parentEventKey"))
            && boolean(row.get("isAsync")).is_some()
            && boolean(row.get("isOpenEnded")).is_some()
    })
}

fn valid_counter_series(value: &Value, range: (i64, i64)) -> bool {
    let Some(row) = object(Some(value)) else {
        return false;
    };
    let Some(scope) = string(row.get("scope")) else {
        return false;
    };
    let Some(samples) = array(row.get("samples")) else {
        return false;
    };
    let valid = exact_keys(
        row,
        &[
            "filterID",
            "name",
            "scope",
            "cpu",
            "processKey",
            "pid",
            "processName",
            "unit",
            "samples",
        ],
    ) && integer(row.get("filterID")).is_some()
        && string(row.get("name")).is_some_and(|name| safe(name, 4_096))
        && text_in(scope, &["cpu", "process"])
        && optional_nonnegative_integer(row.get("cpu"))
        && valid_optional_key(row.get("processKey"), "ipid")
        && optional_integer(row.get("pid"))
        && optional_text(row.get("processName"), 4_096)
        && optional_text(row.get("unit"), 4_096)
        && samples
            .iter()
            .all(|sample| valid_counter_sample(sample, range))
        // A counter is a step function: one sample may carry its value in
        // from before the window, and no more.
        && samples
            .iter()
            .filter(|sample| sample_starts_before_window(sample, range))
            .count()
            <= 1;
    if !valid {
        return false;
    }
    if same_text(scope, "cpu") {
        !is_null(row.get("cpu")) && is_null(row.get("processKey"))
    } else {
        is_null(row.get("cpu")) && !is_null(row.get("processKey"))
    }
}

fn sample_starts_before_window(value: &Value, range: (i64, i64)) -> bool {
    object(Some(value))
        .and_then(|sample| integer(sample.get("timestampNs")))
        .is_some_and(|timestamp| timestamp < range.0)
}

fn valid_counter_sample(value: &Value, range: (i64, i64)) -> bool {
    let Some(sample) = object(Some(value)) else {
        return false;
    };
    let Some(timestamp) = integer(sample.get("timestampNs")) else {
        return false;
    };
    if !exact_keys(sample, &["key", "timestampNs", "value", "durationNs"])
        || !valid_event_key(sample.get("key"))
        || timestamp >= range.1
        || integer(sample.get("value")).is_none()
        || !optional_nonnegative_integer(sample.get("durationNs"))
    {
        return false;
    }
    if timestamp >= range.0 {
        return true;
    }
    // A sample from before the window holds only as the value in force at
    // its start: its own validity has to reach the window.
    integer(sample.get("durationNs"))
        .filter(|duration| *duration >= 0)
        .and_then(|duration| checked_sum(&[timestamp, duration]))
        .is_some_and(|end| end > range.0)
}

fn counter_sample_count(value: &Value) -> Option<usize> {
    Some(array(object(Some(value))?.get("samples"))?.len())
}

// MARK: Analysis

fn valid_analysis_result(
    value: Option<&Value>,
    request: &AnalysisRequest,
    trace: &TraceIdentity,
    outer_quality: Option<&Value>,
    outer_truncation: Option<&Value>,
) -> bool {
    let Some(result) = object(value) else {
        return false;
    };
    let Some(analysis) = object(result.get("analysis")) else {
        return false;
    };
    if !exact_keys(result, &["analysis", "kind"])
        || !text_is(result.get("kind"), request.kind.raw())
        || !exact_keys(
            analysis,
            &[
                "kind",
                "parameters",
                "range",
                "cpuUtilization",
                "topProcesses",
                "topThreads",
                "longSlices",
                "threadStateDistribution",
                "schedulingLatency",
                "hotIntervals",
                "sections",
                "dataQuality",
            ],
        )
        || !text_is(analysis.get("kind"), "deterministicBatch")
    {
        return false;
    }
    let Some(expected) = expected_range(request, trace.duration_ns) else {
        return false;
    };
    if !valid_range(analysis.get("range"), Some(expected))
        || !valid_analysis_parameters(analysis.get("parameters"), request)
        || !valid_data_quality(analysis.get("dataQuality"))
        || analysis.get("dataQuality") != outer_quality
    {
        return false;
    }
    let (Some(cpu), Some(processes), Some(threads), Some(long_slices), Some(states)) = (
        array(analysis.get("cpuUtilization")),
        array(analysis.get("topProcesses")),
        array(analysis.get("topThreads")),
        array(analysis.get("longSlices")),
        array(analysis.get("threadStateDistribution")),
    ) else {
        return false;
    };
    if !cpu.iter().all(|row| valid_cpu_utilization(row, expected))
        || !processes
            .iter()
            .all(|row| valid_running_process(row, expected))
        || !threads
            .iter()
            .all(|row| valid_running_thread(row, expected))
        || !long_slices
            .iter()
            .all(|row| valid_long_slice(row, request.threshold_ns, expected))
        || !states
            .iter()
            .all(|row| valid_state_distribution(row, expected))
    {
        return false;
    }
    let Some(sample_count) = valid_scheduling_latency(analysis.get("schedulingLatency"), expected)
    else {
        return false;
    };
    let Some(hot) = array(analysis.get("hotIntervals")) else {
        return false;
    };
    if !hot.iter().all(|row| valid_hot_interval(row, expected))
        || checked_total(&[
            cpu.len(),
            processes.len(),
            threads.len(),
            long_slices.len(),
            states.len(),
            sample_count,
            hot.len(),
        ])
        .is_none_or(|total| total as i64 > request.max_rows)
    {
        return false;
    }
    let counts = BTreeMap::from([
        ("cpuUtilization", cpu.len()),
        ("topProcesses", processes.len()),
        ("topThreads", threads.len()),
        ("longSlices", long_slices.len()),
        ("threadStateDistribution", states.len()),
        ("schedulingLatency", sample_count),
        ("hotIntervals", hot.len()),
    ]);
    valid_outer_truncation(
        outer_truncation,
        valid_analysis_sections(analysis.get("sections"), &counts).as_deref(),
    )
}

fn valid_analysis_parameters(value: Option<&Value>, request: &AnalysisRequest) -> bool {
    let Some(parameters) = object(value) else {
        return false;
    };
    let event_keys = [
        "maximumCPUSlices",
        "maximumProcessSlices",
        "maximumThreadSlices",
        "maximumStateIntervals",
        "maximumNamedSlices",
        "maximumSchedulingEvents",
        "maximumHotEvents",
    ];
    let limit_keys = [
        "topProcessLimit",
        "topThreadLimit",
        "longSliceLimit",
        "schedulingSampleLimit",
        "hotIntervalLimit",
    ];
    let mut all = vec!["filters"];
    all.extend(event_keys);
    all.extend(limit_keys);
    all.extend([
        "hotBucketCount",
        "minimumLongSliceDurationNs",
        "timeoutSeconds",
        "timeoutAttoseconds",
    ]);
    let seconds = request.timeout_ms / 1_000;
    let attoseconds = (request.timeout_ms % 1_000) * 1_000_000_000_000_000;
    exact_keys(parameters, &all)
        && valid_result_filters(parameters.get("filters"), request)
        && event_keys
            .iter()
            .all(|key| integer(parameters.get(*key)) == Some(request.max_events))
        && limit_keys
            .iter()
            .all(|key| integer(parameters.get(*key)) == Some(request.limit))
        && integer(parameters.get("hotBucketCount")) == Some(100)
        && integer(parameters.get("minimumLongSliceDurationNs")) == Some(request.threshold_ns)
        && integer(parameters.get("timeoutSeconds")) == Some(seconds)
        && integer(parameters.get("timeoutAttoseconds")) == Some(attoseconds)
}

fn range_length(range: (i64, i64)) -> Option<i64> {
    range
        .1
        .checked_sub(range.0)
        .filter(|duration| *duration > 0)
}

fn valid_cpu_utilization(value: &Value, range: (i64, i64)) -> bool {
    let Some(row) = object(Some(value)) else {
        return false;
    };
    let (Some(raw), Some(occupied), Some(utilization), Some(duration)) = (
        integer(row.get("rawRunningNs")),
        integer(row.get("occupiedNs")),
        finite_number(row.get("utilization")),
        range_length(range),
    ) else {
        return false;
    };
    exact_keys(
        row,
        &[
            "cpu",
            "rawRunningNs",
            "occupiedNs",
            "sliceCount",
            "utilization",
        ],
    ) && integer(row.get("cpu")).is_some_and(|cpu| cpu >= 0)
        && raw >= 0
        && occupied >= 0
        && integer(row.get("sliceCount")).is_some_and(|count| count >= 0)
        && occupied == duration.min(raw)
        && approximately_equal(utilization, occupied as f64 / duration as f64)
}

fn valid_running_process(value: &Value, range: (i64, i64)) -> bool {
    let Some(row) = object(Some(value)) else {
        return false;
    };
    let (Some(running), Some(share), Some(duration)) = (
        integer(row.get("runningNs")),
        finite_number(row.get("shareOfOneCPU")),
        range_length(range),
    ) else {
        return false;
    };
    exact_keys(
        row,
        &[
            "processKey",
            "pid",
            "name",
            "runningNs",
            "shareOfOneCPU",
            "sliceCount",
        ],
    ) && valid_key(row.get("processKey"), "ipid")
        && optional_integer(row.get("pid"))
        && optional_text(row.get("name"), 4_096)
        && running >= 0
        && integer(row.get("sliceCount")).is_some_and(|count| count >= 0)
        && approximately_equal(share, running as f64 / duration as f64)
}

fn valid_running_thread(value: &Value, range: (i64, i64)) -> bool {
    let Some(row) = object(Some(value)) else {
        return false;
    };
    let (Some(running), Some(share), Some(duration)) = (
        integer(row.get("runningNs")),
        finite_number(row.get("shareOfOneCPU")),
        range_length(range),
    ) else {
        return false;
    };
    exact_keys(
        row,
        &[
            "threadKey",
            "processKey",
            "tid",
            "pid",
            "name",
            "processName",
            "runningNs",
            "shareOfOneCPU",
            "sliceCount",
        ],
    ) && valid_key(row.get("threadKey"), "itid")
        && valid_optional_key(row.get("processKey"), "ipid")
        && optional_integer(row.get("tid"))
        && optional_integer(row.get("pid"))
        && optional_text(row.get("name"), 4_096)
        && optional_text(row.get("processName"), 4_096)
        && running >= 0
        && integer(row.get("sliceCount")).is_some_and(|count| count >= 0)
        && approximately_equal(share, running as f64 / duration as f64)
}

fn valid_long_slice(value: &Value, minimum_duration_ns: i64, requested: (i64, i64)) -> bool {
    object(Some(value)).is_some_and(|row| {
        exact_keys(
            row,
            &[
                "key",
                "range",
                "name",
                "category",
                "processKey",
                "threadKey",
                "pid",
                "tid",
                "processName",
                "threadName",
            ],
        ) && valid_event_key(row.get("key"))
            && valid_range(row.get("range"), None)
            && range_intersects(row.get("range"), requested)
            && range_duration(row.get("range"))
                .is_some_and(|duration| duration >= minimum_duration_ns)
            && string(row.get("name")).is_some_and(|name| safe(name, 4_096))
            && optional_text(row.get("category"), 4_096)
            && valid_optional_key(row.get("processKey"), "ipid")
            && valid_optional_key(row.get("threadKey"), "itid")
            && optional_integer(row.get("pid"))
            && optional_integer(row.get("tid"))
            && optional_text(row.get("processName"), 4_096)
            && optional_text(row.get("threadName"), 4_096)
    })
}

fn valid_state_distribution(value: &Value, range: (i64, i64)) -> bool {
    let Some(row) = object(Some(value)) else {
        return false;
    };
    let (Some(duration), Some(percentage), Some(range_duration)) = (
        integer(row.get("durationNs")),
        finite_number(row.get("percentageOfRange")),
        range_length(range),
    ) else {
        return false;
    };
    exact_keys(
        row,
        &[
            "threadKey",
            "processKey",
            "tid",
            "pid",
            "rawState",
            "normalizedState",
            "durationNs",
            "percentageOfRange",
            "intervalCount",
        ],
    ) && valid_key(row.get("threadKey"), "itid")
        && valid_optional_key(row.get("processKey"), "ipid")
        && optional_integer(row.get("tid"))
        && optional_integer(row.get("pid"))
        && string(row.get("rawState")).is_some_and(|state| safe(state, 4_096))
        && optional_enum(row.get("normalizedState"), &NORMALIZED_STATES)
        && duration >= 0
        && duration <= range_duration
        && approximately_equal(percentage, duration as f64 / range_duration as f64)
        && integer(row.get("intervalCount")).is_some_and(|count| count >= 0)
}

/// Swift `validateSchedulingLatency`: the samples it returned, or `None`.
fn valid_scheduling_latency(value: Option<&Value>, range: (i64, i64)) -> Option<usize> {
    let latency = object(value)?;
    let supported = boolean(latency.get("supported"))?;
    let count = integer(latency.get("count")).filter(|count| *count >= 0)?;
    let samples = array(latency.get("topSamples"))?;
    if !exact_keys(
        latency,
        &[
            "supported",
            "unsupportedReason",
            "count",
            "percentiles",
            "topSamples",
            "truncated",
        ],
    ) || !samples
        .iter()
        .all(|sample| valid_scheduling_sample(sample, range))
        || samples.len() as i64 > count
        || boolean(latency.get("truncated")).is_none()
    {
        return None;
    }
    if supported {
        let percentiles = if count == 0 {
            is_null(latency.get("percentiles"))
        } else {
            valid_percentiles(latency.get("percentiles"))
        };
        if !is_null(latency.get("unsupportedReason")) || !percentiles {
            return None;
        }
    } else {
        let reason = string(latency.get("unsupportedReason"))?;
        if !text_in(
            reason,
            &["capabilityUnavailable", "noProvableRunnableTransitions"],
        ) || !is_null(latency.get("percentiles"))
            || count != 0
            || !samples.is_empty()
        {
            return None;
        }
    }
    Some(samples.len())
}

fn valid_percentiles(value: Option<&Value>) -> bool {
    let Some(percentiles) = object(value) else {
        return false;
    };
    let values: Option<Vec<i64>> = ["p50Ns", "p90Ns", "p95Ns", "p99Ns", "maxNs"]
        .iter()
        .map(|name| integer(percentiles.get(*name)))
        .collect();
    let Some([p50, p90, p95, p99, max]) = values
        .as_deref()
        .and_then(|values| <[i64; 5]>::try_from(values).ok())
    else {
        return false;
    };
    exact_keys(percentiles, &["p50Ns", "p90Ns", "p95Ns", "p99Ns", "maxNs"])
        && 0 <= p50
        && p50 <= p90
        && p90 <= p95
        && p95 <= p99
        && p99 <= max
}

fn valid_scheduling_sample(value: &Value, range: (i64, i64)) -> bool {
    let Some(sample) = object(Some(value)) else {
        return false;
    };
    let (Some(runnable_end), Some(running_start), Some(latency)) = (
        integer(sample.get("runnableEndNs")),
        integer(sample.get("runningStartNs")),
        integer(sample.get("latencyNs")),
    ) else {
        return false;
    };
    exact_keys(
        sample,
        &[
            "threadKey",
            "runnableEventKey",
            "runningEventKey",
            "runnableEndNs",
            "runningStartNs",
            "latencyNs",
        ],
    ) && valid_key(sample.get("threadKey"), "itid")
        && valid_event_key(sample.get("runnableEventKey"))
        && valid_event_key(sample.get("runningEventKey"))
        && runnable_end >= 0
        && running_start == runnable_end
        && runnable_end >= range.0
        && running_start <= range.1
        && latency >= 0
        && latency <= runnable_end - range.0
}

fn valid_hot_interval(value: &Value, requested: (i64, i64)) -> bool {
    let Some(row) = object(Some(value)) else {
        return false;
    };
    let Some(score) = object(row.get("score")) else {
        return false;
    };
    let (Some(cpu_busy), Some(switches), Some(switch_score), Some(long), Some(total)) = (
        integer(score.get("cpuBusyNs")),
        integer(score.get("contextSwitchCount")),
        integer(score.get("contextSwitchScoreNs")),
        integer(score.get("longSliceNs")),
        integer(score.get("total")),
    ) else {
        return false;
    };
    exact_keys(row, &["range", "score", "cpuSliceCount", "namedSliceCount"])
        && valid_range(row.get("range"), None)
        && range_is_contained(row.get("range"), requested)
        && integer(row.get("cpuSliceCount")).is_some_and(|count| count >= 0)
        && integer(row.get("namedSliceCount")).is_some_and(|count| count >= 0)
        && exact_keys(
            score,
            &[
                "cpuBusyNs",
                "contextSwitchCount",
                "contextSwitchScoreNs",
                "longSliceNs",
                "total",
            ],
        )
        && cpu_busy >= 0
        && switches >= 0
        && switch_score >= 0
        && switches <= i64::MAX / 1_000_000
        && switch_score == switches * 1_000_000
        && long >= 0
        && checked_sum(&[cpu_busy, switch_score, long]) == Some(total)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn oracle(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/arktrace-analysis-validator")
            .join(name)
    }

    fn text(value: &Value) -> String {
        value.as_str().unwrap().to_owned()
    }

    fn request_from(projection: &Value) -> Option<AnalysisRequest> {
        if projection.is_null() {
            return None;
        }
        let optional = |key: &str| projection[key].as_i64();
        let required = |key: &str| projection[key].as_i64().unwrap();
        Some(AnalysisRequest {
            kind: Kind::parse(projection["kind"].as_str().unwrap()).unwrap(),
            timestamp_ns: optional("timestampNs"),
            start_ns: optional("startNs"),
            end_ns: optional("endNs"),
            process_key: optional("processKey"),
            pid: optional("pid"),
            thread_key: optional("threadKey"),
            tid: optional("tid"),
            threshold_ns: required("thresholdNs"),
            limit: required("limit"),
            timeout_ms: required("timeoutMs"),
            max_rows: required("maxRows"),
            max_events: required("maxEvents"),
            max_output_bytes: required("maxOutputBytes"),
        })
    }

    fn projection(request: &AnalysisRequest) -> Value {
        serde_json::json!({
            "kind": request.kind.raw(),
            "timestampNs": request.timestamp_ns,
            "startNs": request.start_ns,
            "endNs": request.end_ns,
            "processKey": request.process_key,
            "pid": request.pid,
            "threadKey": request.thread_key,
            "tid": request.tid,
            "thresholdNs": request.threshold_ns,
            "limit": request.limit,
            "timeoutMs": request.timeout_ms,
            "maxRows": request.max_rows,
            "maxEvents": request.max_events,
            "maxOutputBytes": request.max_output_bytes,
        })
    }

    /// Replays `ArkTraceAnalysisValidatorOracleContractTests`: every edited
    /// reviewed envelope, for its invocation, judged as Swift judged it.
    #[test]
    fn rust_judges_the_swift_analysis_envelopes() {
        let recorded: Value =
            serde_json::from_slice(&std::fs::read(oracle("cases.json")).unwrap()).unwrap();
        let contract = &recorded["contract"];
        let contract = ArkTraceContract {
            tool_version: text(&contract["toolVersion"]),
            parser_version: text(&contract["parserVersion"]),
            parser_upstream_revision: text(&contract["parserUpstreamRevision"]),
            parser_sha256: text(&contract["parserSHA256"]),
            parser_build_recipe_version: text(&contract["parserBuildRecipeVersion"]),
            parser_adapter_version: text(&contract["parserAdapterVersion"]),
            schema_adapter_version: text(&contract["schemaAdapterVersion"]),
            index_schema_version: contract["indexSchemaVersion"].as_i64().unwrap(),
        };
        let cases = recorded["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 176);
        let mut differences = Vec::new();
        for case in cases {
            let mut envelope = std::fs::read_to_string(oracle(&format!(
                "reviewed/{}.json",
                case["base"].as_str().unwrap()
            )))
            .unwrap();
            for edit in case["edits"].as_array().unwrap() {
                let find = edit["find"].as_str().unwrap();
                assert!(envelope.contains(find), "{}", case["name"]);
                envelope = envelope.replacen(find, edit["replace"].as_str().unwrap(), 1);
            }
            let invocation = &case["invocation"];
            let request = request_from(&invocation["request"]);
            let arguments: Vec<String> = invocation["arguments"]
                .as_array()
                .unwrap()
                .iter()
                .map(text)
                .collect();
            let (analyzer_ref, executable_sha256, source_sha256) = (
                text(&invocation["analyzerRef"]),
                text(&invocation["executableSHA256"]),
                text(&invocation["sourceSHA256"]),
            );
            let valid = valid_analysis(
                envelope.as_bytes(),
                &AnalysisInvocation {
                    analyzer_ref: &analyzer_ref,
                    executable_sha256: &executable_sha256,
                    arguments: &arguments,
                    timeout_seconds: invocation["timeoutSeconds"].as_i64().unwrap(),
                    output_byte_budget: invocation["outputByteBudget"].as_u64(),
                    source_sha256: &source_sha256,
                    source_byte_count: invocation["sourceByteCount"].as_u64().unwrap(),
                    request: request.as_ref(),
                    contract: (!invocation["contract"].is_null()).then_some(&contract),
                },
            );
            if Some(valid) != case["valid"].as_bool() {
                differences.push(format!(
                    "{}: swift {} rust {valid}",
                    case["name"], case["valid"]
                ));
            }
        }
        assert!(differences.is_empty(), "{}", differences.join("\n"));
    }

    /// Replays the request cases of the same oracle: each Job's inputs read
    /// as a request's JSON carries them, parsed or refused as Swift does,
    /// with the arguments, deadline, digest and range of a parsed request.
    #[test]
    fn rust_parses_the_swift_analysis_requests() {
        let recorded: Value =
            serde_json::from_slice(&std::fs::read(oracle("request-cases.json")).unwrap()).unwrap();
        let source_path = "/private/tmp/arkdeck-trace-source/job-trace/trace.htrace";
        let mut compared = 0;
        for case in recorded.as_array().unwrap() {
            let inputs =
                crate::session_json::parse_foundation(case["inputs"].as_str().unwrap().as_bytes())
                    .unwrap();
            let outcome = match AnalysisRequest::parse(inputs.as_object().unwrap()) {
                Err(reason) => serde_json::json!({"refused": reason}),
                Ok(request) => serde_json::json!({
                    "request": projection(&request),
                    "arguments": request.arguments(source_path),
                    "processTimeoutSeconds": request.process_timeout_seconds(),
                    "recoveryDigestSHA256": request.recovery_digest_sha256(),
                    "normalizedRange": request.normalized_range().map(|(start, end)| [start, end]),
                }),
            };
            assert_eq!(outcome, case["outcome"], "{}", case["name"]);
            compared += 1;
        }
        assert_eq!(compared, 49);
    }
}
