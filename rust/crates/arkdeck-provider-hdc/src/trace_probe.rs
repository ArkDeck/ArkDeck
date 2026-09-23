//! Swift `FoundationTraceRuntimeProbe`: which trace tool an adopted device
//! offers, judged only by the registered OpenHarmony trace-probe families
//! (`TraceProbeAdapter`, registry `OPENHARMONY-TRACE-PROBES@1.0.0`). Callers
//! provide the adopted route, never argv. Every read is fixed: `hitrace` and
//! `bytrace` help, the `hitrace` tag list once its help is the registered
//! family, and the nine catalog parameters, each bounded to 15 s.
//!
//! What is not known is never reported as an answer: a help read that cannot
//! complete is `probeFailed`, a parameter read that cannot complete is
//! `unreadable` with its reason, and a tag list that cannot be read fails the
//! whole probe. Only the exact registered help and tag-list bytes select a
//! tool for capture; a tool's name, its exit status or a familiar marker never
//! does.
use crate::{
    CommandFailure, CommandOutcome, DispatchFailure, HdcDispatch, ProcessPlan, Receipt,
    SemanticOutputParser, property_value,
};
use sha2::{Digest, Sha256};
use std::time::Duration;

/// Swift `TraceDebugParameterCatalog.definitions`, in catalog order.
pub const TRACE_PARAMETERS: [&str; 9] = [
    "persist.ace.trace.syntax.enabled",
    "persist.ace.trace.layout.enabled",
    "persist.ace.trace.build.enabled",
    "persist.ace.trace.measure.debug.enabled",
    "persist.ace.trace.sync.debug.enabled",
    "persist.ace.debug.enabled",
    "persist.ace.performance.monitor.enabled",
    "persist.sys.graphic.openDebugTrace",
    "persist.rosen.animationtrace.enabled",
];

/// Swift `TraceProbeAdapterProfile`: the registered help family names, the
/// exact sizes of the registered help and tag-list outputs, and the SHA-256
/// of each output after its leading `YYYY/MM/DD HH:MM:SS ` (the only bytes
/// the registry lets a capture time change).
pub const HITRACE_HELP_FAMILY: &str = "hitrace.dayu200-oh7.text";
pub const BYTRACE_HELP_FAMILY: &str = "bytrace.dayu200-oh7.text";
const HELP_BYTES: usize = 3_382;
const TAG_LIST_BYTES: usize = 3_604;
const HITRACE_HELP_SUFFIX_SHA256: &str =
    "b40edec78a823762d64599b21c4fd2c82be4a9071e0457120a6e6526433ed3f8";
const BYTRACE_HELP_SUFFIX_SHA256: &str =
    "e11541d1b671170d16c300d01dcbb5f50301e9e2533622f1e91b257a8561548e";
const HITRACE_TAG_LIST_SUFFIX_SHA256: &str =
    "9c781ec48cf4b1cc6f3115be75687efb7e8b9078fdee767e1bee150ad2b758d0";
const BYTRACE_TAG_LIST_SUFFIX_SHA256: &str =
    "d8475c07177f87f8640ef3a52382e0ccaed42115c6a1592ef42c99fffb18204a";

/// Swift's reads: 15 s each; help and tag lists keep 64 KiB, a parameter
/// 4 KiB, and a parameter value may be at most 400 bytes.
const READ_TIMEOUT: Duration = Duration::from_secs(15);
const HELP_CAPTURE_BYTES: usize = 64 * 1024;
const PARAMETER_CAPTURE_BYTES: usize = 4 * 1024;
const MAXIMUM_VALUE_BYTES: usize = 400;

/// Swift `TraceProbeTool`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TraceTool {
    Hitrace,
    Bytrace,
}
impl TraceTool {
    pub fn raw(self) -> &'static str {
        match self {
            Self::Hitrace => "hitrace",
            Self::Bytrace => "bytrace",
        }
    }
}

/// Swift `TraceProbeAdapterSelection`, the tool being implicit: `hitrace`
/// can only be capture-eligible, `bytrace` only probe-only.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TraceSelection {
    CaptureEligible(&'static str),
    ProbeOnly(&'static str),
    Unsupported,
}

/// Swift `TraceProbeAdapter.evaluateHelp`: only the registered byte family of
/// the tool, with an empty stderr, selects it.
pub fn evaluate_help(tool: TraceTool, stdout: &[u8], stderr: &[u8]) -> TraceSelection {
    if !stderr.is_empty() || stdout.len() != HELP_BYTES {
        return TraceSelection::Unsupported;
    }
    let Some(suffix) = timestamp_normalized_suffix(stdout) else {
        return TraceSelection::Unsupported;
    };
    match (tool, sha256_hex(suffix).as_str()) {
        (TraceTool::Hitrace, HITRACE_HELP_SUFFIX_SHA256) => {
            TraceSelection::CaptureEligible(HITRACE_HELP_FAMILY)
        }
        (TraceTool::Bytrace, BYTRACE_HELP_SUFFIX_SHA256) => {
            TraceSelection::ProbeOnly(BYTRACE_HELP_FAMILY)
        }
        _ => TraceSelection::Unsupported,
    }
}

/// Swift `TraceProbeAdapter.evaluateTagList`: the exact registered tag-list
/// family of the tool, with an empty stderr, and the tag names it lists —
/// none, and no selection, for anything else.
pub fn evaluate_tag_list(
    tool: TraceTool,
    stdout: &[u8],
    stderr: &[u8],
) -> (TraceSelection, Vec<String>) {
    let unsupported = (TraceSelection::Unsupported, Vec::new());
    if !stderr.is_empty() || stdout.len() != TAG_LIST_BYTES {
        return unsupported;
    }
    let (Some(suffix), Ok(text)) = (
        timestamp_normalized_suffix(stdout),
        std::str::from_utf8(stdout),
    ) else {
        return unsupported;
    };
    let selection = match (tool, sha256_hex(suffix).as_str()) {
        (TraceTool::Hitrace, HITRACE_TAG_LIST_SUFFIX_SHA256) => {
            TraceSelection::CaptureEligible(HITRACE_HELP_FAMILY)
        }
        (TraceTool::Bytrace, BYTRACE_TAG_LIST_SUFFIX_SHA256) => {
            TraceSelection::ProbeOnly(BYTRACE_HELP_FAMILY)
        }
        _ => return unsupported,
    };
    // Swift splits on its newline Characters, drops the enter and header
    // lines, and keeps a name before " - " of 1...64 ASCII letters, digits
    // or underscores, trimmed of its whitespace (tabs and space separators).
    // Only the registered bytes reach here, so every rule is exercised on
    // the registry's own list.
    let tags: Vec<String> = text
        .split([
            '\n', '\r', '\u{b}', '\u{c}', '\u{85}', '\u{2028}', '\u{2029}',
        ])
        .filter(|line| !line.is_empty())
        .skip(2)
        .filter_map(|line| {
            let (name, _) = line.split_once(" - ")?;
            let name = name.trim_matches(|c: char| c == '\t' || is_space_separator(c));
            (!name.is_empty()
                && name.len() <= 64
                && name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_'))
            .then(|| name.to_owned())
        })
        .collect();
    let mut unique = tags.clone();
    unique.sort_unstable();
    unique.dedup();
    if tags.is_empty() || unique.len() != tags.len() {
        return unsupported;
    }
    (selection, tags)
}

/// Unicode general category Zs, which Swift's `.whitespaces` holds beside tab.
fn is_space_separator(c: char) -> bool {
    ('\u{2000}'..='\u{200a}').contains(&c)
        || [
            ' ', '\u{a0}', '\u{1680}', '\u{202f}', '\u{205f}', '\u{3000}',
        ]
        .contains(&c)
}

/// Swift `timestampNormalizedSuffix`: the bytes after an exact, calendar-valid
/// `YYYY/MM/DD HH:MM:SS ` prefix, or none.
fn timestamp_normalized_suffix(bytes: &[u8]) -> Option<&[u8]> {
    let prefix = bytes.get(..20)?;
    let digits = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18];
    if !digits.iter().all(|&index| prefix[index].is_ascii_digit())
        || prefix[4] != b'/'
        || prefix[7] != b'/'
        || prefix[10] != b' '
        || prefix[13] != b':'
        || prefix[16] != b':'
        || prefix[19] != b' '
    {
        return None;
    }
    let two = |index: usize| (prefix[index] - b'0') * 10 + (prefix[index + 1] - b'0');
    ((1..=12).contains(&two(5))
        && (1..=31).contains(&two(8))
        && two(11) <= 23
        && two(14) <= 59
        && two(17) <= 59)
        .then(|| &bytes[20..])
}

/// Swift `TraceRuntimeToolObservation`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceToolObservation {
    pub tool: &'static str,
    /// `captureEligible`, `probeOnly`, `unrecognized` or `probeFailed`.
    pub disposition: &'static str,
    pub family: Option<&'static str>,
    pub raw_help_sha256: Option<String>,
    pub detail: Option<&'static str>,
}

/// Swift `TraceRuntimeParameterObservation`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceParameterObservation {
    pub name: &'static str,
    /// `value`, `missing` or `unreadable`.
    pub state: &'static str,
    pub value: Option<String>,
    pub detail: Option<String>,
}

/// Swift `TraceRuntimeProbeSnapshot` without the route facts the caller
/// already holds.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceProbe {
    /// `captureEligible` or `unsupported`.
    pub adapter_disposition: &'static str,
    pub tool: Option<&'static str>,
    pub family: Option<&'static str>,
    pub supported_tags: Vec<String>,
    pub raw_help: Option<String>,
    pub raw_help_sha256: Option<String>,
    /// `hitrace`, then `bytrace`.
    pub tools: [TraceToolObservation; 2],
    /// In catalog order.
    pub parameters: Vec<TraceParameterObservation>,
}

/// One help read as Swift `probeHelp` keeps it: its presentation, and the
/// evaluation of the bytes when the read completed.
struct HelpRead {
    observation: TraceToolObservation,
    evaluation: Option<(TraceSelection, Vec<u8>, String)>,
}

/// Swift `probeTraceRuntime` on the route's connect key. The help reads and
/// the nine parameter reads start together, as Swift's do; the tag list
/// follows the help reads. The probe fails only when the tag list of a
/// registered hitrace help cannot be read, and then with Swift's description
/// of why. Unlike Swift, which cancels the parameter reads it still awaits,
/// that failure is answered once they have ended, each within its budget.
pub fn trace_probe(
    dispatch: &(dyn HdcDispatch + Sync),
    connect_key: &str,
) -> Result<TraceProbe, String> {
    std::thread::scope(|scope| {
        let parameters = TRACE_PARAMETERS
            .map(|name| scope.spawn(move || parameter(dispatch, connect_key, name)));
        let bytrace = scope.spawn(move || help(dispatch, connect_key, TraceTool::Bytrace));
        let hitrace = help(dispatch, connect_key, TraceTool::Hitrace);
        let bytrace = bytrace.join().expect("a help read does not panic");
        let selected = selection(dispatch, connect_key, &hitrace);
        let parameters = parameters
            .into_iter()
            .map(|read| read.join().expect("a parameter read does not panic"))
            .collect();
        let (adapter_disposition, tool, family, supported_tags) = selected?;
        let (raw_help, raw_help_sha256) = match hitrace.evaluation {
            Some((_, bytes, digest)) => (swift_utf8(&bytes).map(str::to_owned), Some(digest)),
            None => (None, None),
        };
        Ok(TraceProbe {
            adapter_disposition,
            tool,
            family,
            supported_tags,
            raw_help,
            raw_help_sha256,
            tools: [hitrace.observation, bytrace.observation],
            parameters,
        })
    })
}

type Selected = (
    &'static str,
    Option<&'static str>,
    Option<&'static str>,
    Vec<String>,
);

/// Swift `probeTools` after its two help reads: only a registered hitrace
/// help whose own registered tag list reads back selects hitrace.
fn selection(
    dispatch: &dyn HdcDispatch,
    connect_key: &str,
    hitrace: &HelpRead,
) -> Result<Selected, String> {
    let unsupported = ("unsupported", None, None, Vec::new());
    let Some((TraceSelection::CaptureEligible(family), _, _)) = &hitrace.evaluation else {
        return Ok(unsupported);
    };
    let receipt = read(
        dispatch,
        &plan(connect_key, &["shell", "hitrace", "-l"], HELP_CAPTURE_BYTES),
    )?;
    Ok(
        match evaluate_tag_list(TraceTool::Hitrace, &receipt.stdout, &receipt.stderr) {
            (TraceSelection::CaptureEligible(tags_family), tags) if tags_family == *family => (
                "captureEligible",
                Some(TraceTool::Hitrace.raw()),
                Some(*family),
                tags,
            ),
            _ => unsupported,
        },
    )
}

/// Swift `probeHelp` over `readAllowingNonZero`: a help read keeps any exit,
/// since help is not an operation receipt and its documentation may spell a
/// failure marker; the registered family alone judges it.
fn help(dispatch: &dyn HdcDispatch, connect_key: &str, tool: TraceTool) -> HelpRead {
    let plan = plan(
        connect_key,
        &["shell", tool.raw(), "--help"],
        HELP_CAPTURE_BYTES,
    );
    let receipt = match dispatch.dispatch(&plan) {
        Ok(receipt) if !stdout_truncated(&receipt, plan.capture_bytes) => receipt,
        _ => {
            return HelpRead {
                observation: TraceToolObservation {
                    tool: tool.raw(),
                    disposition: "probeFailed",
                    family: None,
                    raw_help_sha256: None,
                    detail: Some("read-only probe could not complete"),
                },
                evaluation: None,
            };
        }
    };
    let selection = evaluate_help(tool, &receipt.stdout, &receipt.stderr);
    let digest = sha256_hex(&receipt.stdout);
    let (disposition, family) = match selection {
        TraceSelection::CaptureEligible(family) => ("captureEligible", Some(family)),
        TraceSelection::ProbeOnly(family) => ("probeOnly", Some(family)),
        TraceSelection::Unsupported => ("unrecognized", None),
    };
    HelpRead {
        observation: TraceToolObservation {
            tool: tool.raw(),
            disposition,
            family,
            raw_help_sha256: Some(digest.clone()),
            detail: (receipt.exit_status != 0).then_some("probe exited non-zero"),
        },
        evaluation: Some((selection, receipt.stdout, digest)),
    }
}

/// Swift `read`: an operation receipt must carry no transport or
/// authorization marker, exit zero and keep its whole stdout.
fn read(dispatch: &dyn HdcDispatch, plan: &ProcessPlan) -> Result<Receipt, String> {
    let receipt = dispatch.dispatch(plan).map_err(swift_described)?;
    if let Some(reason) = semantic_failure(&receipt) {
        return Err(format!("read-only HDC probe failed: {reason}"));
    }
    if receipt.exit_status != 0 {
        return Err(format!(
            "read-only HDC probe exited {}",
            receipt.exit_status
        ));
    }
    if stdout_truncated(&receipt, plan.capture_bytes) {
        return Err("read-only HDC probe output was truncated".into());
    }
    Ok(receipt)
}

/// Swift `readParameter` and `parameterObservation`: OpenHarmony's exact 106
/// answer for this key is a missing parameter; any other failure, a value
/// that is not UTF-8 or longer than 400 bytes is unreadable, with its reason.
fn parameter(
    dispatch: &dyn HdcDispatch,
    connect_key: &str,
    name: &'static str,
) -> TraceParameterObservation {
    let observation = |state, value, detail| TraceParameterObservation {
        name,
        state,
        value,
        detail,
    };
    let unreadable = |detail: String| observation("unreadable", None, Some(detail));
    let plan = plan(
        connect_key,
        &["shell", "param", "get", name],
        PARAMETER_CAPTURE_BYTES,
    );
    let receipt = match dispatch.dispatch(&plan) {
        Ok(receipt) => receipt,
        Err(failure) => return unreadable(swift_described(failure)),
    };
    if stdout_truncated(&receipt, plan.capture_bytes) {
        return unreadable("read-only HDC probe output was truncated".into());
    }
    // OpenHarmony reports an absent key as a zero-exit semantic failure; only
    // the exact, quiet form for the key this read asked for means missing.
    let expected = format!("Get parameter \"{name}\" fail! errNum is:106!");
    if receipt.exit_status == 0
        && receipt.stderr.is_empty()
        && swift_utf8(&receipt.stdout).is_some_and(|text| text.trim() == expected)
    {
        return observation("missing", None, None);
    }
    if let Some(reason) = semantic_failure(&receipt) {
        return unreadable(format!("read-only HDC probe failed: {reason}"));
    }
    if receipt.exit_status != 0 {
        return unreadable(format!(
            "read-only HDC probe exited {}",
            receipt.exit_status
        ));
    }
    let Some(text) = swift_utf8(&receipt.stdout) else {
        return unreadable("parameter output is not UTF-8".into());
    };
    match property_value(text, name) {
        "" => observation("missing", None, None),
        value if value.len() > MAXIMUM_VALUE_BYTES => {
            unreadable("parameter value is oversized".into())
        }
        value => observation("value", Some(value.to_owned()), None),
    }
}

fn plan(connect_key: &str, command: &[&str], capture_bytes: usize) -> ProcessPlan {
    ProcessPlan {
        arguments: ["-t", connect_key]
            .into_iter()
            .chain(command.iter().copied())
            .map(str::to_owned)
            .collect(),
        timeout: READ_TIMEOUT,
        capture_bytes,
    }
}

/// Swift `HDCReadOnlyProbeReceiptValidation.semanticFailureReason`.
fn semantic_failure(receipt: &Receipt) -> Option<String> {
    let mut parser = SemanticOutputParser::new();
    parser.consume(&receipt.stdout);
    parser.consume(&receipt.stderr);
    match parser.finish(0) {
        CommandOutcome::Failure(CommandFailure::Unauthorized) => {
            Some("target authorization is unavailable".into())
        }
        CommandOutcome::Failure(CommandFailure::Offline) => Some("target is offline".into()),
        CommandOutcome::Failure(CommandFailure::ExplicitFailureMarker) => {
            Some("HDC reported an explicit failure".into())
        }
        CommandOutcome::Failure(CommandFailure::NonZeroExit(status)) => {
            Some(format!("HDC exited {status}"))
        }
        CommandOutcome::Success | CommandOutcome::UnknownOutput => None,
    }
}

/// Swift's runner reports whether stdout alone went past its capture; the
/// dispatch reports either stream. Each stream keeps at most the capture, so
/// a stdout shorter than it, beside a full stderr, was whole. Only when both
/// are full is it unknown which overflowed, and the read then counts as
/// truncated, as nothing in it may be taken for all of it.
fn stdout_truncated(receipt: &Receipt, capture_bytes: usize) -> bool {
    receipt.truncated
        && (receipt.stderr.len() < capture_bytes || receipt.stdout.len() >= capture_bytes)
}

/// Swift `String(data:encoding: .utf8)`: strict UTF-8, one leading byte-order
/// mark dropped.
fn swift_utf8(bytes: &[u8]) -> Option<&str> {
    std::str::from_utf8(bytes)
        .ok()
        .map(|text| text.strip_prefix('\u{feff}').unwrap_or(text))
}

/// Swift's `String(describing:)` of the runner's `RuntimeDispatchFailure`.
fn swift_described(failure: DispatchFailure) -> String {
    match failure {
        DispatchFailure::Unobservable(reason) => {
            format!("outcomeUnknown({})", swift_quoted(&reason))
        }
        DispatchFailure::Refused(reason) => format!("failed({})", swift_quoted(&reason)),
    }
}

/// Swift's `debugDescription` of a `String`: quoted, each scalar as
/// `Unicode.Scalar.escaped(asASCII: false)` spells it — `\u{XX}` with two
/// upper-case digits for any other ASCII control, other scalars as they are.
fn swift_quoted(text: &str) -> String {
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('"');
    for scalar in text.chars() {
        match scalar {
            '\\' => quoted.push_str("\\\\"),
            '\'' => quoted.push_str("\\'"),
            '"' => quoted.push_str("\\\""),
            ' '..='~' => quoted.push(scalar),
            '\0' => quoted.push_str("\\0"),
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\t' => quoted.push_str("\\t"),
            control if control.is_ascii() => {
                quoted.push_str(&format!("\\u{{{:02X}}}", u32::from(control)));
            }
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swift_quoting_matches_what_swift_prints() {
        // Recorded from Swift 6 `String(describing:)` of an enum payload.
        assert_eq!(
            swift_quoted("a'b\"c\\d\u{1}e\u{7f}f\u{e9}g\n"),
            r#""a\'b\"c\\d\u{01}e\u{7F}fég\n""#
        );
        assert_eq!(
            swift_quoted("x\u{85}y\u{2028}z\0w\u{1f}v~u\u{feff}t"),
            "\"x\u{85}y\u{2028}z\\0w\\u{1F}v~u\u{feff}t\""
        );
    }

    #[test]
    fn swift_utf8_drops_one_leading_byte_order_mark() {
        assert_eq!(swift_utf8(b"\xef\xbb\xbfA\n"), Some("A\n"));
        assert_eq!(swift_utf8(b"\xef\xbb\xbf"), Some(""));
        assert_eq!(swift_utf8(b"\xef\xbb\xbf\xef\xbb\xbfA"), Some("\u{feff}A"));
        assert_eq!(swift_utf8(b"A\xef\xbb\xbfB"), Some("A\u{feff}B"));
        assert_eq!(swift_utf8(b"\xc0\x80"), None);
        assert_eq!(swift_utf8(b"\xed\xa0\x80"), None);
    }

    #[test]
    fn only_a_calendar_valid_capture_time_is_normalized() {
        let suffix = b"2026/09/14 08:30:00 rest";
        assert_eq!(timestamp_normalized_suffix(suffix), Some(&b"rest"[..]));
        for prefix in [
            "2026/13/14 08:30:00 ",
            "2026/00/14 08:30:00 ",
            "2026/09/32 08:30:00 ",
            "2026/09/00 08:30:00 ",
            "2026/09/14 24:30:00 ",
            "2026/09/14 08:60:00 ",
            "2026/09/14 08:30:60 ",
            "2026-09-14 08:30:00 ",
            "2026/09/14T08:30:00 ",
            "2026/09/14 08:30:00x",
            "2026/09/1a 08:30:00 ",
        ] {
            let bytes = [prefix.as_bytes(), b"rest"].concat();
            assert_eq!(timestamp_normalized_suffix(&bytes), None, "{prefix}");
        }
        assert_eq!(timestamp_normalized_suffix(b"2026/09/14 08:30:00"), None);
    }

    #[test]
    fn a_stdout_is_truncated_only_when_it_may_have_overflowed() {
        let receipt = |stdout: usize, stderr: usize, truncated: bool| Receipt {
            exit_status: 0,
            stdout: vec![b'o'; stdout],
            stderr: vec![b'e'; stderr],
            truncated,
            duration: Duration::ZERO,
        };
        assert!(!stdout_truncated(&receipt(4096, 10, false), 4096));
        assert!(stdout_truncated(&receipt(4096, 10, true), 4096));
        // Only stderr can have overflowed: Swift's runner keeps the stdout.
        assert!(!stdout_truncated(&receipt(5, 4096, true), 4096));
        // Both full: which one overflowed is unknown, so it counts.
        assert!(stdout_truncated(&receipt(4096, 4096, true), 4096));
    }
}
