//! Swift's HiLog summary analyzer, `hilog-summary@1`
//! (`HilogSummaryDerivedAnalyzer` over `HilogSummaryArtifactContract`): the
//! bytes of a collected HiLog go in, and statistics over OpenHarmony's default
//! line header come out — how many lines, how many blank, how many carry no
//! recognized header, and how many of each severity. No log body, tag,
//! process ID or timestamp reaches the result. Nothing is opened or written
//! here: `arkdeck-agentd --summarize-hilog` is the executable face, the
//! Runtime's analyzer child the caller, and [`validate_hilog_report`] the
//! closed contract a verified answer must meet.
//!
//! Lines are cut at every line feed byte. A line of spaces, tabs and carriage
//! returns alone is blank; any other line is judged by its first 256 bytes,
//! less one trailing carriage return, decoded as Swift decodes them (an
//! ill-formed sequence replaced) and matched against Swift's header pattern,
//! an `NSRegularExpression` whose ICU semantics [`header_level`] spells out.
use crate::session_graphemes::graphemes;
use arkdeck_contract::sha256_hex;
use arkdeck_platform::{ProfilePath, ProfileReadError};
use serde_json::{Map, Value, json};
use std::ffi::OsString;
use std::io;

pub(crate) const ANALYZER_REF: &str = "hilog-summary@1";
pub(crate) const ANALYZER_VERSION: &str = "1.0.0";
/// `HilogSummaryArtifactContract.maximumInputBytes`.
pub const MAXIMUM_INPUT_BYTES: u64 = 512 * 1024 * 1024;
/// `HilogSummaryArtifactContract.maximumOutputBytes`, also the profile's
/// output byte budget.
pub(crate) const MAXIMUM_OUTPUT_BYTES: usize = 8 * 1024;
/// `HilogSummaryDerivedAnalyzer.incompatibleExecutableReason`: the host's
/// analyzer executable is not this daemon, so it has no HiLog mode to trust.
pub(crate) const INCOMPATIBLE_EXECUTABLE: &str = "analyzer.hilogRequiresCurrentDaemon";
const SCHEMA_VERSION: &str = "1.0.0";
const SCOPE: &str = "default-hilog-header-lines";
const REDACTION: &str = "content-and-identifiers-omitted";
/// Only this much of a line is kept to judge its header.
const PREFIX_BYTES: usize = 256;
const LEVELS: [char; 5] = ['D', 'I', 'W', 'E', 'F'];

/// Swift `HilogSummaryDerivedAnalyzer.analyze`: the summary of `bytes`, as
/// `CanonicalJSONEncoders.canonical()` encodes a `HilogSummaryAnalysis`
/// (compact, keys sorted).
pub fn analyze_hilog(bytes: &[u8]) -> io::Result<Vec<u8>> {
    if bytes.len() as u64 > MAXIMUM_INPUT_BYTES {
        return Err(io::Error::other("analyzer.hilogInputLimitExceeded"));
    }
    let mut prefix: Vec<u8> = Vec::with_capacity(PREFIX_BYTES);
    let mut line_has_bytes = false;
    let mut line_is_blank = true;
    let (mut lines, mut blanks, mut unknown) = (0u64, 0u64, 0u64);
    let mut levels = [0u64; 5];
    let mut finish_line = |prefix: &mut Vec<u8>, blank: bool| {
        lines += 1;
        if blank {
            blanks += 1;
        } else {
            if prefix.last() == Some(&b'\r') {
                prefix.pop();
            }
            match header_level(&String::from_utf8_lossy(prefix)) {
                Some(level) => {
                    levels[LEVELS.iter().position(|each| *each == level).unwrap_or(0)] += 1
                }
                None => unknown += 1,
            }
        }
        prefix.clear();
    };
    for &byte in bytes {
        if byte == b'\n' {
            finish_line(&mut prefix, line_is_blank);
            line_has_bytes = false;
            line_is_blank = true;
        } else {
            line_has_bytes = true;
            if !matches!(byte, b'\t' | b'\r' | b' ') {
                line_is_blank = false;
            }
            if prefix.len() < PREFIX_BYTES {
                prefix.push(byte);
            }
        }
    }
    if line_has_bytes {
        finish_line(&mut prefix, line_is_blank);
    }
    let document = json!({
        "schemaVersion": SCHEMA_VERSION,
        "analyzerRef": ANALYZER_REF,
        "analyzerVersion": ANALYZER_VERSION,
        "scope": SCOPE,
        "redaction": REDACTION,
        "sourceSHA256": sha256_hex(bytes),
        "sourceByteCount": bytes.len(),
        "headerCoverage": coverage(lines, blanks, unknown),
        "lineCount": lines,
        "blankLineCount": blanks,
        "unrecognizedLineCount": unknown,
        "levelCounts": {"D": levels[0], "I": levels[1], "W": levels[2], "E": levels[3],
            "F": levels[4]},
    });
    crate::session_json::encode(&document)
        .map_err(|_| io::Error::other("the summary could not be encoded"))
}

/// `HilogSummaryArtifactContract.coverage`.
fn coverage(lines: u64, blanks: u64, unknown: u64) -> &'static str {
    if lines == blanks {
        "empty"
    } else if unknown == lines - blanks {
        "unrecognized"
    } else if unknown == 0 {
        "complete"
    } else {
        "partial"
    }
}

/// The severity Swift's header pattern captures at the start of `text`:
///
/// ```text
/// ^(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])[ \t]+(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]
/// \.[0-9]{3}(?:[0-9]{3}){0,2}[ \t]+[0-9]{1,10}[ \t]+[0-9]{1,10}[ \t]+([DIWEF])[ \t]+
/// [A-Z]?[0-9A-Fa-f]{5,8}/[^\x00-\x1F\x7F]{1,31}:(?:[ \t]|$)
/// ```
///
/// matched over code points as ICU matches it. Every quantified run is
/// followed by a character it cannot hold, so each is its whole run: the
/// fraction's digits are three, six or nine, each ID's one to ten. The domain
/// ends at the first solidus. The tag is one to 31 characters with no C0
/// control or DEL, closed by a colon followed by a space, a tab or the end;
/// the tag may hold colons itself, so any such colon closes it. ICU's `$`
/// outside multiline mode also matches just before one line terminator that
/// ends the input, a carriage return and line feed counted as one.
fn header_level(text: &str) -> Option<char> {
    let chars: Vec<char> = text.chars().collect();
    let at = |index: usize| chars.get(index).copied();
    let digit = |index: usize| at(index).is_some_and(|c| c.is_ascii_digit());
    let pair = |index: usize, first: &dyn Fn(char) -> bool, second: &dyn Fn(char, char) -> bool| matches!((at(index), at(index + 1)), (Some(a), Some(b)) if first(a) && second(a, b));
    // Spaces and tabs, at least one: the index past them.
    let blanks = |start: usize| {
        let mut index = start;
        while matches!(at(index), Some(' ' | '\t')) {
            index += 1;
        }
        (index > start).then_some(index)
    };
    // A run of digits within `range`: the index past it.
    let run = |start: usize, lengths: &dyn Fn(usize) -> bool| {
        let mut index = start;
        while digit(index) {
            index += 1;
        }
        lengths(index - start).then_some(index)
    };
    // Month, day.
    if !pair(0, &|a| a == '0' || a == '1', &|a, b| {
        (a == '0' && ('1'..='9').contains(&b)) || (a == '1' && ('0'..='2').contains(&b))
    }) || at(2) != Some('-')
        || !pair(3, &|a| ('0'..='3').contains(&a), &|a, b| match a {
            '0' => ('1'..='9').contains(&b),
            '1' | '2' => b.is_ascii_digit(),
            _ => b == '0' || b == '1',
        })
    {
        return None;
    }
    let mut index = blanks(5)?;
    // Hour, minute, second.
    if !pair(index, &|a| ('0'..='2').contains(&a), &|a, b| match a {
        '2' => ('0'..='3').contains(&b),
        _ => b.is_ascii_digit(),
    }) {
        return None;
    }
    index += 2;
    for _ in 0..2 {
        if at(index) != Some(':')
            || !at(index + 1).is_some_and(|c| ('0'..='5').contains(&c))
            || !digit(index + 2)
        {
            return None;
        }
        index += 3;
    }
    if at(index) != Some('.') {
        return None;
    }
    index = run(index + 1, &|length| matches!(length, 3 | 6 | 9))?;
    index = blanks(index)?;
    // Process and thread IDs.
    for _ in 0..2 {
        index = run(index, &|length| (1..=10).contains(&length))?;
        index = blanks(index)?;
    }
    let level = at(index).filter(|c| LEVELS.contains(c))?;
    index = blanks(index + 1)?;
    // The domain: an optional capital, then five to eight hex digits.
    let slash = index + chars[index..].iter().position(|c| *c == '/')?;
    let domain = &chars[index..slash];
    let hex =
        |part: &[char]| (5..=8).contains(&part.len()) && part.iter().all(char::is_ascii_hexdigit);
    if !(hex(domain) || (domain.first().is_some_and(char::is_ascii_uppercase) && hex(&domain[1..])))
    {
        return None;
    }
    // The tag.
    let start = slash + 1;
    for length in 1..=31 {
        match at(start + length - 1) {
            Some(c) if c > '\u{1f}' && c != '\u{7f}' => {}
            _ => return None,
        }
        let colon = start + length;
        if at(colon) == Some(':')
            && (matches!(at(colon + 1), Some(' ' | '\t')) || ends(&chars, colon + 1))
        {
            return Some(level);
        }
    }
    None
}

/// ICU's `$` at `index` outside multiline mode: the end of the input, or one
/// line terminator (CR LF counted as one) that ends it.
fn ends(chars: &[char], index: usize) -> bool {
    let terminator = |c: char| {
        matches!(
            c,
            '\n' | '\u{b}' | '\u{c}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
        )
    };
    match &chars[index.min(chars.len())..] {
        [] => true,
        [c] => terminator(*c),
        ['\r', '\n'] => true,
        _ => false,
    }
}

/// The mode's arguments after its flag, as Swift takes them: exactly one,
/// whose first Character is a solidus. Swift decodes an argument that is not
/// UTF-8 by replacing what is not, as `to_string_lossy` does, and opens the
/// decoded text. `None` is Swift's usage refusal.
pub fn hilog_source(values: &[OsString]) -> Option<String> {
    let [value] = values else {
        return None;
    };
    let value = value.to_string_lossy().into_owned();
    let absolute = graphemes(&value).next() == Some("/");
    absolute.then_some(value)
}

/// Swift `openPhysicalAbsolutePath`'s reading of a path string, over
/// Characters: an absolute path; with `inode_alias`, a `/.vol/` path of
/// exactly four parts whose device and inode are canonical decimals (a
/// positive inode); otherwise its non-empty components, none `.` or `..`.
pub fn profile_path(path: &str, inode_alias: bool) -> Result<ProfilePath, ProfileReadError> {
    let characters: Vec<&str> = graphemes(path).collect();
    if characters.first() != Some(&"/") {
        return Err(ProfileReadError::PhysicalPath);
    }
    // `split(separator: "/", omittingEmptySubsequences: false)`.
    let mut parts = vec![String::new()];
    for character in &characters {
        if *character == "/" {
            parts.push(String::new());
        } else if let Some(last) = parts.last_mut() {
            last.push_str(character);
        }
    }
    if inode_alias && characters.len() >= 6 && characters[..6] == ["/", ".", "v", "o", "l", "/"] {
        fn canonical<T: std::str::FromStr + ToString>(text: &str) -> Option<T> {
            let value = text.parse::<T>().ok()?;
            (value.to_string() == text).then_some(value)
        }
        let [_, _, device, inode] = parts.as_slice() else {
            return Err(ProfileReadError::PhysicalPath);
        };
        let (Some(device), Some(inode)) = (canonical::<u32>(device), canonical::<u64>(inode))
        else {
            return Err(ProfileReadError::PhysicalPath);
        };
        if inode == 0 {
            return Err(ProfileReadError::PhysicalPath);
        }
        return Ok(ProfilePath::InodeAlias {
            path: path.to_owned(),
            device,
            inode,
        });
    }
    let components: Vec<String> = parts.into_iter().filter(|part| !part.is_empty()).collect();
    if components.is_empty() || components.iter().any(|part| part == "." || part == "..") {
        return Err(ProfileReadError::PhysicalPath);
    }
    Ok(ProfilePath::Components(components))
}

/// Swift `HilogSummaryArtifactContract.validateReport`: the producer's
/// canonical, closed document, about exactly this source, whose counts add
/// up. Decoding drops unknown keys and re-encoding must give the same bytes,
/// so no field outside the contract, no duplicate and no other spelling
/// passes.
pub(crate) fn validate_hilog_report(bytes: &[u8], source_sha256: &str, source_bytes: u64) -> bool {
    if bytes.len() > MAXIMUM_OUTPUT_BYTES {
        return false;
    }
    let Some(report) = decode_report(bytes) else {
        return false;
    };
    if crate::session_json::encode(&Value::Object(report.fields.clone()))
        .ok()
        .as_deref()
        != Some(bytes)
    {
        return false;
    }
    let text = |key: &str| report.fields.get(key).and_then(Value::as_str);
    let lines = report.integer("lineCount");
    let blanks = report.integer("blankLineCount");
    let unknown = report.integer("unrecognizedLineCount");
    let source = report.integer("sourceByteCount");
    let levels = report
        .fields
        .get("levelCounts")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    if text("schemaVersion") != Some(SCHEMA_VERSION)
        || text("analyzerRef") != Some(ANALYZER_REF)
        || text("analyzerVersion") != Some(ANALYZER_VERSION)
        || text("scope") != Some(SCOPE)
        || text("redaction") != Some(REDACTION)
        || text("sourceSHA256") != Some(source_sha256)
        || source != source_bytes as i128
        || source <= 0
        || source > MAXIMUM_INPUT_BYTES as i128
        || lines < 1
        || lines > source
        || blanks < 0
        || blanks > lines
        || unknown < 0
        || unknown > lines
        || levels.len() != 5
        || !LEVELS
            .iter()
            .all(|level| levels.contains_key(&level.to_string()))
    {
        return false;
    }
    let mut recognized = 0i128;
    for value in levels.values() {
        let Some(count) = value.as_i64().map(i128::from) else {
            return false;
        };
        if count < 0 || count > lines {
            return false;
        }
        recognized += count;
    }
    recognized + blanks + unknown == lines
        && text("headerCoverage") == Some(coverage(lines as u64, blanks as u64, unknown as u64))
}

/// A `HilogSummaryAnalysis` as Swift's `JSONDecoder` reads one: every
/// declared key with its declared type (the coverage one of its four cases,
/// the level counts a dictionary of integers), unknown keys dropped.
struct Report {
    fields: Map<String, Value>,
}

impl Report {
    fn integer(&self, key: &str) -> i128 {
        self.fields
            .get(key)
            .and_then(Value::as_i64)
            .map_or(-1, i128::from)
    }
}

fn decode_report(bytes: &[u8]) -> Option<Report> {
    // Whatever a lenient reader would accept beyond the canonical spelling
    // cannot re-encode to the same bytes, so any JSON reader serves.
    let value = serde_json::from_slice::<Value>(bytes).ok()?;
    let object = value.as_object()?;
    let mut fields = Map::new();
    for key in [
        "schemaVersion",
        "analyzerRef",
        "analyzerVersion",
        "scope",
        "redaction",
        "sourceSHA256",
    ] {
        fields.insert(key.into(), Value::from(object.get(key)?.as_str()?));
    }
    let coverage = object.get("headerCoverage")?.as_str()?;
    if !["complete", "partial", "unrecognized", "empty"].contains(&coverage) {
        return None;
    }
    fields.insert("headerCoverage".into(), Value::from(coverage));
    for key in [
        "sourceByteCount",
        "lineCount",
        "blankLineCount",
        "unrecognizedLineCount",
    ] {
        fields.insert(key.into(), Value::from(object.get(key)?.as_i64()?));
    }
    let mut levels = Map::new();
    for (key, count) in object.get("levelCounts")?.as_object()? {
        levels.insert(key.clone(), Value::from(count.as_i64()?));
    }
    fields.insert("levelCounts".into(), Value::Object(levels));
    Some(Report { fields })
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEADER: &str = "09-25 10:00:00.123  1234  5678 I C02D01/HiLog: body";

    #[test]
    fn the_header_pattern_is_read_as_icu_reads_it() {
        assert_eq!(header_level(HEADER), Some('I'));
        for (text, expected) in [
            (
                "12-31 23:59:59.123456789\t1\t2\tF\tA1234ABCD/t: x",
                Some('F'),
            ),
            ("01-01 00:00:00.000 1 2 D 0000F/tag:", Some('D')),
            ("01-01 00:00:00.000 1 2 D 0000F/tag:\r\n", Some('D')),
            ("01-01 00:00:00.000 1 2 D 0000F/tag:\u{85}", Some('D')),
            ("01-01 00:00:00.000 1 2 D 0000F/tag:\u{85}x", None),
            ("01-01 00:00:00.000 1 2 D 0000F/t:g: x", Some('D')),
            ("01-01 00:00:00.0000 1 2 D 0000F/tag: x", None),
            ("13-01 00:00:00.000 1 2 D 0000F/tag: x", None),
            ("01-32 00:00:00.000 1 2 D 0000F/tag: x", None),
            ("01-01 24:00:00.000 1 2 D 0000F/tag: x", None),
            ("01-01 00:00:00.000 12345678901 2 D 0000F/tag: x", None),
            ("01-01 00:00:00.000 1 2 d 0000F/tag: x", None),
            ("01-01 00:00:00.000 1 2 D 0000/tag: x", None),
            ("01-01 00:00:00.000 1 2 D G0000F/tag: x", Some('D')),
            ("01-01 00:00:00.000 1 2 D gg0000F/tag: x", None),
            ("01-01 00:00:00.000 1 2 D 0000F/: x", None),
            (
                "01-01 00:00:00.000 1 2 D 0000F/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: x",
                Some('D'),
            ),
            (
                "01-01 00:00:00.000 1 2 D 0000F/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: x",
                None,
            ),
            ("01-01 00:00:00.000 1 2 D 0000F/ta\u{7f}g: x", None),
        ] {
            assert_eq!(header_level(text), expected, "{text:?}");
        }
    }

    #[test]
    fn a_summary_counts_lines_and_is_its_own_valid_report() {
        let bytes = format!("{HEADER}\r\n\n \t\r\nbody without a header\n{HEADER}");
        let document = analyze_hilog(bytes.as_bytes()).unwrap();
        let value: Value = serde_json::from_slice(&document).unwrap();
        assert_eq!(value["lineCount"], 5);
        assert_eq!(value["blankLineCount"], 2);
        assert_eq!(value["unrecognizedLineCount"], 1);
        assert_eq!(value["levelCounts"]["I"], 2);
        assert_eq!(value["headerCoverage"], "partial");
        assert!(validate_hilog_report(
            &document,
            &sha256_hex(bytes.as_bytes()),
            bytes.len() as u64
        ));
        // Another source, a reordered spelling or an extra member is refused.
        assert!(!validate_hilog_report(
            &document,
            &"0".repeat(64),
            bytes.len() as u64
        ));
        let mut extended = value.clone();
        extended["note"] = json!("x");
        let extended = serde_json::to_vec(&extended).unwrap();
        assert!(!validate_hilog_report(
            &extended,
            &sha256_hex(bytes.as_bytes()),
            bytes.len() as u64
        ));
    }

    #[test]
    fn paths_are_read_over_characters() {
        assert_eq!(
            profile_path("/.vol/16777234/42", true),
            Ok(ProfilePath::InodeAlias {
                path: "/.vol/16777234/42".into(),
                device: 16_777_234,
                inode: 42
            })
        );
        for refused in [
            "/.vol/+1/2",
            "/.vol/1/0",
            "/.vol/1/2/3",
            "/.vol/01/2",
            "x",
            "/",
            "/a/../b",
        ] {
            assert_eq!(
                profile_path(refused, true),
                Err(ProfileReadError::PhysicalPath),
                "{refused}"
            );
        }
        // Without the alias, `.vol` is a component like any other.
        assert_eq!(
            profile_path("/.vol/1/2", false),
            Ok(ProfilePath::Components(vec![
                ".vol".into(),
                "1".into(),
                "2".into()
            ]))
        );
        // A solidus a mark is joined to is no separator.
        assert_eq!(
            profile_path("/a/\u{301}b", false),
            Ok(ProfilePath::Components(vec!["a/\u{301}b".into()]))
        );
        assert_eq!(hilog_source(&["/\u{301}x".into()]), None);
        assert_eq!(hilog_source(&["/x".into()]), Some("/x".into()));
        assert_eq!(hilog_source(&["/x".into(), "/y".into()]), None);
    }
}
