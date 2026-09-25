//! Swift `JSCrashSymbolizer` (TASK-XPA-015, M3): an obfuscated ArkTS crash
//! stack resolved back to its original source through the build's
//! `sourceMaps.map`, as the daemon's one-shot `--symbolize-crash` mode writes
//! it for `workspace.symbolize-crash@1`.
//!
//! An OpenHarmony `jscrash` fault log carries a `Stacktrace:` block whose
//! frames name a compiled unit, a line and a column. The map's top-level keys
//! are exactly those units, so the resolution is a lookup and a Source Map v3
//! decode: a frame either has a mapping segment that covers it or it is
//! reported unresolved. The report keeps every frame's raw text and adds the
//! resolution beneath it.
//!
//! Swift's text semantics are kept where they decide the answer: the dump is
//! split into lines at line feeds that are whole characters (a CR LF pair is
//! one character, so it is not a line end); prefixes, parentheses, colons and
//! Base64 digits are whole characters too; a unit is looked up by canonical
//! equivalence, as a Swift dictionary compares its keys, and a key the map
//! repeats keeps its first value, as `JSONSerialization` keeps it. Where Swift
//! traps — an arithmetic overflow in a hostile map — this answers an error.
use serde::de::{Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use std::fmt;
use unicode_segmentation::UnicodeSegmentation;

/// Swift `JSCrashSymbolizerError`, and the overflow Swift traps on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SymbolizeError {
    /// The map is not JSON, or not a JSON object.
    SourceMapUnreadable(String),
    /// A delta or a position overflowed 64 bits, where Swift's arithmetic
    /// traps.
    Overflow,
}

impl SymbolizeError {
    /// Swift's `String(describing:)` of the error (the overflow is this
    /// Runtime's own spelling).
    pub fn swift(&self) -> String {
        match self {
            Self::SourceMapUnreadable(detail) => format!(
                "sourceMapUnreadable({})",
                crate::artifact_read_owner::swift_string(detail)
            ),
            Self::Overflow => "arithmeticOverflow".into(),
        }
    }
}

/// A JSON value as `JSONSerialization` hands it over: an object keeps the
/// first value of a repeated key.
enum Json {
    Other,
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl<'de> Deserialize<'de> for Json {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct JsonVisitor;
        impl<'de> Visitor<'de> for JsonVisitor {
            type Value = Json;
            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a JSON value")
            }
            fn visit_bool<E>(self, _: bool) -> Result<Json, E> {
                Ok(Json::Other)
            }
            fn visit_i64<E>(self, _: i64) -> Result<Json, E> {
                Ok(Json::Other)
            }
            fn visit_u64<E>(self, _: u64) -> Result<Json, E> {
                Ok(Json::Other)
            }
            fn visit_f64<E>(self, _: f64) -> Result<Json, E> {
                Ok(Json::Other)
            }
            fn visit_str<E>(self, value: &str) -> Result<Json, E> {
                Ok(Json::String(value.to_owned()))
            }
            fn visit_string<E>(self, value: String) -> Result<Json, E> {
                Ok(Json::String(value))
            }
            fn visit_unit<E>(self) -> Result<Json, E> {
                Ok(Json::Other)
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<Json, A::Error> {
                let mut values = Vec::new();
                while let Some(value) = sequence.next_element()? {
                    values.push(value);
                }
                Ok(Json::Array(values))
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Json, A::Error> {
                let mut entries: Vec<(String, Json)> = Vec::new();
                while let Some((key, value)) = map.next_entry::<String, Json>()? {
                    entries.push((key, value));
                }
                Ok(Json::Object(entries))
            }
        }
        deserializer.deserialize_any(JsonVisitor)
    }
}

/// Swift String equality: canonical equivalence.
fn canonical(text: &str) -> String {
    arkdeck_platform::host_canonical_text(text).unwrap_or_else(|| text.to_owned())
}

impl Json {
    /// A Swift dictionary lookup: the first key canonically equal to `key`.
    fn get(&self, key: &str) -> Option<&Json> {
        let Json::Object(entries) = self else {
            return None;
        };
        let key = canonical(key);
        entries
            .iter()
            .find(|(candidate, _)| *candidate == key || canonical(candidate) == key)
            .map(|(_, value)| value)
    }
}

/// Swift `Int(Substring)`: optional sign, ASCII digits, no overflow.
fn integer(text: &str) -> Option<i64> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// Swift `parseFrame(_:)`: the parenthesised `<unit>:<line>:<column>` after
/// the last `(`, every separator a whole character.
fn parse_frame(line: &str) -> Option<(String, i64, i64)> {
    let characters: Vec<&str> = line.graphemes(true).collect();
    let open = characters.iter().rposition(|c| *c == "(")?;
    let close = characters.iter().rposition(|c| *c == ")")?;
    if open >= close {
        return None;
    }
    let inner = &characters[open + 1..close];
    let parts: Vec<String> = inner
        .split(|c| *c == ":")
        .map(|part| part.concat())
        .collect();
    if parts.len() < 3 {
        return None;
    }
    let column = integer(&parts[parts.len() - 1])?;
    let row = integer(&parts[parts.len() - 2])?;
    let unit = parts[..parts.len() - 2].join(":");
    if unit.is_empty() {
        return None;
    }
    Some((unit, row, column))
}

/// Swift `decodeVLQ(_:)`: six bits per digit, the low bit of a value its
/// sign, a trailing continuation no value at all.
fn decode_vlq(segment: &[&str]) -> Result<Option<Vec<i64>>, SymbolizeError> {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut values = Vec::new();
    let mut result: i64 = 0;
    let mut shift: u32 = 0;
    for character in segment {
        let [byte] = character.as_bytes() else {
            return Ok(None);
        };
        let Some(digit) = ALPHABET.iter().position(|a| a == byte) else {
            return Ok(None);
        };
        let digit = digit as i64;
        // Swift's `<<` discards what leaves the word; its `+=` traps.
        let shifted = if shift >= 64 {
            0
        } else {
            (digit & 31).wrapping_shl(shift)
        };
        result = result
            .checked_add(shifted)
            .ok_or(SymbolizeError::Overflow)?;
        if digit & 32 != 0 {
            shift += 5;
            continue;
        }
        let negative = result & 1 == 1;
        let magnitude = result >> 1;
        values.push(if negative { -magnitude } else { magnitude });
        result = 0;
        shift = 0;
    }
    Ok((shift == 0).then_some(values))
}

/// Swift `Precision`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Precision {
    Column,
    Line,
}

/// Swift `originalPosition(mappings:sources:line:column:)`: the segment that
/// starts at or before the column on the line, or — when none does — the
/// line's first segment, placed by line. Every row is decoded: the fields
/// are deltas against the whole document.
fn original_position(
    mappings: &str,
    sources: &[String],
    line: i64,
    column: i64,
) -> Result<Option<(String, i64, i64, Precision)>, SymbolizeError> {
    let overflow = || SymbolizeError::Overflow;
    let characters: Vec<&str> = mappings.graphemes(true).collect();
    let rows: Vec<&[&str]> = characters.split(|c| *c == ";").collect();
    if line < 1 || line > rows.len() as i64 {
        return Ok(None);
    }
    let (mut source_index, mut original_line, mut original_column) = (0_i64, 0_i64, 0_i64);
    let mut covering = None;
    let mut first_on_line = None;
    for (row_number, row) in rows.iter().enumerate() {
        let mut generated_column: i64 = 0;
        for segment in row
            .split(|c| *c == ",")
            .filter(|segment| !segment.is_empty())
        {
            let Some(fields) = decode_vlq(segment)? else {
                continue;
            };
            if fields.is_empty() {
                continue;
            }
            generated_column = generated_column
                .checked_add(fields[0])
                .ok_or_else(overflow)?;
            if fields.len() < 4 {
                continue;
            }
            source_index = source_index.checked_add(fields[1]).ok_or_else(overflow)?;
            original_line = original_line.checked_add(fields[2]).ok_or_else(overflow)?;
            original_column = original_column
                .checked_add(fields[3])
                .ok_or_else(overflow)?;
            if row_number as i64 != line - 1 {
                continue;
            }
            let here = (source_index, original_line, original_column);
            if first_on_line.is_none() {
                first_on_line = Some(here);
            }
            if generated_column <= column.checked_sub(1).ok_or_else(overflow)? {
                covering = Some(here);
            }
        }
    }
    let precision = if covering.is_some() {
        Precision::Column
    } else {
        Precision::Line
    };
    let Some((index, row, column)) = covering.or(first_on_line) else {
        return Ok(None);
    };
    if index < 0 || index >= sources.len() as i64 {
        return Ok(None);
    }
    Ok(Some((
        sources[index as usize].clone(),
        row.checked_add(1).ok_or_else(overflow)?,
        column.checked_add(1).ok_or_else(overflow)?,
        precision,
    )))
}

/// Swift `hasPrefix` on whole characters.
fn has_prefix(line: &str, prefix: &str) -> bool {
    let mut characters = line.graphemes(true);
    prefix
        .graphemes(true)
        .all(|expected| characters.next() == Some(expected))
}

/// Swift `CharacterSet.whitespaces`: tab and the space separators.
fn whitespace(scalar: char) -> bool {
    matches!(
        scalar,
        '\t' | ' ' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// Swift `split(separator: "\n", omittingEmptySubsequences: false)` over a
/// String: a line feed ends a line only where it is a character of its own —
/// never the second half of a CR LF pair.
fn lines(text: &str) -> Vec<String> {
    let mut lines = vec![String::new()];
    for character in text.graphemes(true) {
        if character == "\n" {
            lines.push(String::new());
        } else if let Some(last) = lines.last_mut() {
            last.push_str(character);
        }
    }
    lines
}

/// Swift `JSCrashSymbolizer.symbolize(sourceMapData:dumpText:)` over the
/// map's bytes and the dump's bytes (decoded as Swift decodes them, invalid
/// UTF-8 replaced): the report, or why the map cannot be read.
pub fn symbolize_crash(source_map: &[u8], dump: &[u8]) -> Result<String, SymbolizeError> {
    let object: Json = serde_json::from_slice(source_map)
        .map_err(|error| SymbolizeError::SourceMapUnreadable(error.to_string()))?;
    if !matches!(object, Json::Object(_)) {
        return Err(SymbolizeError::SourceMapUnreadable(
            "not a JSON object".into(),
        ));
    }
    let text = String::from_utf8_lossy(dump);
    let mut report: Vec<String> = Vec::new();
    let mut in_stack = false;
    let (mut frames, mut resolved) = (0_u64, 0_u64);
    for line in lines(&text) {
        if has_prefix(&line, "Stacktrace:") {
            in_stack = true;
            report.push(line);
            continue;
        }
        if !in_stack {
            continue;
        }
        // The block ends at the first line that is not an indented frame.
        if !has_prefix(&line, "    ") && !has_prefix(&line, "\t") {
            if line.chars().all(whitespace) {
                continue;
            }
            in_stack = false;
            continue;
        }
        report.push(line.clone());
        frames += 1;
        let Some((unit, row, column)) = parse_frame(&line) else {
            report.push("        <unparsed frame>".into());
            continue;
        };
        let entry = object.get(&unit);
        let mappings = entry.and_then(|entry| match entry.get("mappings") {
            Some(Json::String(mappings)) => Some(mappings),
            _ => None,
        });
        let sources = entry.and_then(|entry| match entry.get("sources") {
            Some(Json::Array(values)) => values
                .iter()
                .map(|value| match value {
                    Json::String(source) => Some(source.clone()),
                    _ => None,
                })
                .collect::<Option<Vec<String>>>(),
            _ => None,
        });
        let (Some(mappings), Some(sources)) = (mappings, sources) else {
            // A frame whose unit is not in this map is not a failure: an
            // unobfuscated build names its own source directly, and a frame
            // from another module belongs to another map.
            report.push(format!("        <unresolved: no mapping for {unit}>"));
            continue;
        };
        let Some((source, row, column, precision)) =
            original_position(mappings, &sources, row, column)?
        else {
            report.push(format!(
                "        <unresolved: line {row} has no mapping segment>"
            ));
            continue;
        };
        resolved += 1;
        let placed = if precision == Precision::Column {
            ""
        } else {
            "  (placed by line)"
        };
        report.push(format!("        -> {source}:{row}:{column}{placed}"));
    }
    report.push(String::new());
    report.push(format!("frames: {frames}  resolved: {resolved}"));
    Ok(report.join("\n") + "\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_parse_as_swift_parses_them() {
        assert_eq!(
            parse_frame("    at anonymous (a|b|1.0.0|src/x.ts:14:1)"),
            Some(("a|b|1.0.0|src/x.ts".into(), 14, 1))
        );
        assert_eq!(
            parse_frame("    at f (a:b:c:1:3)"),
            Some(("a:b:c".into(), 1, 3))
        );
        assert_eq!(parse_frame("    at f (u:+1:-3)"), Some(("u".into(), 1, -3)));
        for unparsed in [
            "    at anonymous (no position here)",
            "    at f (:1:1)",
            "    at f (u:1: 2)",
            "    at f (u:1)",
            "    at f ) (u:1:1",
            "    at f (u:1:+)",
        ] {
            assert_eq!(parse_frame(unparsed), None, "{unparsed}");
        }
    }

    #[test]
    fn vlq_decodes_sign_and_continuation() {
        let decode = |text: &str| decode_vlq(&text.graphemes(true).collect::<Vec<_>>()).unwrap();
        assert_eq!(decode("AAAA"), Some(vec![0, 0, 0, 0]));
        assert_eq!(decode("D"), Some(vec![-1]));
        assert_eq!(decode("C"), Some(vec![1]));
        assert_eq!(decode("gB"), Some(vec![16]));
        assert_eq!(decode("!"), None);
        assert_eq!(decode("g"), None, "a trailing continuation is no value");
        // A value's digits occupy disjoint bits, so decoding itself never
        // overflows; the widest value round-trips.
        assert_eq!(decode(&vlq(i64::MAX >> 1)), Some(vec![i64::MAX >> 1]));
    }

    /// Base64 VLQ of one value, as a source map encodes it.
    fn vlq(value: i64) -> String {
        const ALPHABET: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut remaining = if value < 0 {
            (value.unsigned_abs() << 1) | 1
        } else {
            (value as u64) << 1
        };
        let mut text = String::new();
        loop {
            let mut digit = remaining & 31;
            remaining >>= 5;
            if remaining > 0 {
                digit |= 32;
            }
            text.push(ALPHABET[digit as usize] as char);
            if remaining == 0 {
                return text;
            }
        }
    }

    /// Where Swift's arithmetic traps — deltas that sum past 64 bits — this
    /// answers an error.
    #[test]
    fn deltas_past_64_bits_are_an_error() {
        let segment = format!("A{}AA", vlq(i64::MAX >> 1));
        let mappings = [segment.as_str(); 3].join(",");
        assert_eq!(
            original_position(&mappings, &["a".into()], 1, 1),
            Err(SymbolizeError::Overflow)
        );
        let fine = [segment.as_str(); 2].join(",");
        assert_eq!(original_position(&fine, &["a".into()], 1, 1), Ok(None));
    }

    /// Swift compares dictionary keys by canonical equivalence, both ways:
    /// a decomposed key in the map answers a precomposed unit in the stack.
    #[test]
    fn a_unit_is_looked_up_by_canonical_equivalence() {
        let map = "{\"u\\u0308|x\":{\"sources\":[\"s\"],\"mappings\":\"AAAA\"}}";
        let dump = "Stacktrace:\n    at f (\u{fc}|x:1:1)\n";
        assert_eq!(
            symbolize_crash(map.as_bytes(), dump.as_bytes()).unwrap(),
            "Stacktrace:\n    at f (\u{fc}|x:1:1)\n        -> s:1:1\n\nframes: 1  resolved: 1\n"
        );
    }

    #[test]
    fn a_crlf_pair_is_not_a_line_end() {
        assert_eq!(lines("a\r\nb\nc"), ["a\r\nb", "c"]);
        assert_eq!(lines(""), [""]);
        assert!(has_prefix("Stacktrace: x", "Stacktrace:"));
        assert!(!has_prefix("Stacktrace\u{301}:", "Stacktrace:"));
        assert!(!has_prefix("Stacktrace:\u{301}", "Stacktrace:"));
    }
}
