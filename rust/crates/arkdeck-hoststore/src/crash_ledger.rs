//! Swift's pinned crash-ledger analyzer: `HarnessCrashLedgerDerivedAnalyzer`
//! over `HarnessFaultLogLedger.readIndex` (CHG-2026-055 TASK-HFA-001/005,
//! CHG-2026-064 TASK-AND-001). The bytes of a Faultlogger listing — the
//! `crash-index.txt` that `capture.diagnostics@1` publishes — go in, and the
//! canonical `HarnessCrashLedgerAnalysis` document comes out. Nothing is
//! opened or written here: `arkdeck-agentd --analyze-crash-ledger` is the
//! executable face, the Runtime's analyzer child (`job_run`) the caller, and
//! `analyzer_output::verify` judges what it prints.
//!
//! The listing is read as Swift reads it, over Swift Characters: grapheme
//! clusters as the pinned Swift runtime draws them (`session_graphemes`), each
//! judged by its first scalar. Two of those properties differ between the Rust
//! standard library and the Swift runtime. Swift's `Character.isNumber` is
//! `Numeric_Type` other than none, which also holds the Han and cuneiform
//! numerals that `Nd`, `Nl` and `No` leave out, and its `isLetter` holds a few
//! Apple private-use scalars. Both differences are tabled below, and the
//! recorded Swift oracle (`rust/tests/fixtures/crash-ledger-analyzer`) compares
//! all four properties the listing is read by, scalar by scalar.
use crate::analyzer_output::{ANALYZER_REF, ANALYZER_VERSION, SCHEMA_VERSION};
use crate::session_graphemes::{graphemes, indices};
use serde_json::{Value, json};
use std::ffi::OsString;
use std::io;
use std::path::PathBuf;

/// `HarnessFaultLogLedger.listHeader`: what tells "the device answered" from
/// "no answer", the distinction the fail-closed reading rests on.
const LIST_HEADER: &str = "Fault log list:";
/// `emptyMarker`: the sentence the measured empty ledger prints.
const EMPTY_MARKER: &str = "No fault log exist.";
const ENTRY_FENCE: &str = "******";
/// An entry ends with a fixed-width `yyyyMMddHHmmss`, counted in Characters.
const TIMESTAMP_CHARACTERS: usize = 14;

/// One listed fault: `<kind>-<bundle>-<uid>-<yyyyMMddHHmmss>`, a name and not
/// a file name.
struct Entry<'a> {
    name: &'a str,
    kind: &'a str,
    bundle: &'a str,
    uid: &'a str,
    timestamp: &'a str,
}

/// Swift `HarnessCrashLedgerDerivedAnalyzer.analyze`: the analysis of `bytes`,
/// encoded as `CanonicalJSONEncoders.canonical()` encodes it (compact, sorted
/// keys, the solidus unescaped). Bytes that are no readable listing are a
/// structured `unreadable` answer, never an empty ledger, so a reader fails
/// closed on them.
pub fn analyze_crash_ledger(bytes: &[u8]) -> io::Result<Vec<u8>> {
    // `String(data:encoding: .utf8)`: valid UTF-8, one leading byte order mark
    // dropped.
    let reading = match std::str::from_utf8(bytes) {
        Ok(text) => read_index(text.strip_prefix('\u{feff}').unwrap_or(text)),
        Err(_) => Err("invalidEncoding"),
    };
    let mut document = json!({
        "schemaVersion": SCHEMA_VERSION,
        "analyzerRef": ANALYZER_REF,
        "analyzerVersion": ANALYZER_VERSION,
    });
    match reading {
        Ok(entries) => {
            document["status"] = json!("answered");
            document["entries"] = Value::Array(
                entries
                    .iter()
                    .map(|entry| {
                        json!({"name": entry.name, "kind": entry.kind, "bundle": entry.bundle,
                            "uid": entry.uid, "timestamp": entry.timestamp})
                    })
                    .collect(),
            );
        }
        Err(reason) => {
            document["status"] = json!("unreadable");
            document["entries"] = json!([]);
            document["unreadableReason"] = json!(reason);
        }
    }
    crate::session_json::encode(&document)
        .map_err(|_| io::Error::other("the analysis could not be encoded"))
}

/// The mode's arguments after its flag, as Swift takes them: exactly one,
/// whose first Character is a solidus (`hasPrefix("/")` compares Characters,
/// so a mark joined to it refuses), read as `URL(filePath:)` reads it, with
/// its trailing solidi dropped. Swift decodes an argument that is not UTF-8
/// by replacing what is not, as `to_string_lossy` does. `None` is Swift's
/// usage refusal.
pub fn crash_ledger_source(values: &[OsString]) -> Option<PathBuf> {
    let [value] = values else {
        return None;
    };
    let value = value.to_string_lossy();
    if graphemes(&value).next() != Some("/") {
        return None;
    }
    let path = value.trim_end_matches('/');
    Some(PathBuf::from(if path.is_empty() { "/" } else { path }))
}

/// Swift `HarnessFaultLogLedger.readIndex`.
fn read_index(text: &str) -> Result<Vec<Entry<'_>>, &'static str> {
    if !contains(text, LIST_HEADER) {
        return Err("ledgerHeaderAbsent");
    }
    // `split(whereSeparator: \.isNewline)` over Characters, then
    // `trimmingCharacters(in: .whitespaces)` over scalars. A line break is a
    // Character of its own (or CR LF, whose split leaves an empty line that
    // is dropped as Swift drops empty ones), so splitting at scalars cuts the
    // same lines.
    let lines: Vec<&str> = text
        .split(is_newline)
        .filter(|line| !line.is_empty())
        .map(|line| line.trim_matches(is_whitespace))
        .collect();
    let first = lines.iter().position(|line| *line == ENTRY_FENCE);
    let last = lines.iter().rposition(|line| *line == ENTRY_FENCE);
    let Some((first, last)) = first.zip(last).filter(|(first, last)| last > first) else {
        // The measured empty form prints the marker sentence; some builds
        // print the header with no fence at all. Both mean an empty ledger.
        return if contains(text, EMPTY_MARKER) {
            Ok(Vec::new())
        } else {
            Err("ledgerFenceAbsent")
        };
    };
    lines[first + 1..last]
        .iter()
        .filter(|line| !line.is_empty())
        .map(|line| parse_entry_name(line).ok_or("entryNameUnparseable"))
        .collect()
}

/// Swift `HarnessFaultLogLedger.parse(entryName:)`, decomposed from the right:
/// the last two fields are the timestamp and uid, the first is the kind, and
/// whatever is left is the bundle, whose name may carry hyphens itself.
fn parse_entry_name(name: &str) -> Option<Entry<'_>> {
    // `split(separator: "-", omittingEmptySubsequences: false)`: a Character
    // that is exactly a hyphen separates; a hyphen a mark is joined to does
    // not.
    let mut fields = Vec::new();
    let mut start = 0;
    for (offset, character) in indices(name) {
        if character == "-" {
            fields.push(&name[start..offset]);
            start = offset + 1;
        }
    }
    fields.push(&name[start..]);
    if fields.len() < 4 {
        return None;
    }
    let (kind, uid, timestamp) = (
        fields[0],
        fields[fields.len() - 2],
        fields[fields.len() - 1],
    );
    // `fields[1..<count - 2].joined(separator: "-")`: the bytes between the
    // kind's hyphen and the uid's.
    let bundle = &name[kind.len() + 1..name.len() - timestamp.len() - uid.len() - 2];
    let every = |field: &str, holds: fn(char) -> bool| {
        graphemes(field).all(|character| character.chars().next().is_some_and(holds))
    };
    let parsed = graphemes(timestamp).count() == TIMESTAMP_CHARACTERS
        && every(timestamp, is_number)
        && !uid.is_empty()
        && every(uid, is_number)
        && !kind.is_empty()
        && every(kind, is_letter)
        && !bundle.is_empty();
    parsed.then_some(Entry {
        name,
        kind,
        bundle,
        uid,
        timestamp,
    })
}

/// Swift `String.contains(_:)` over Characters: `needle`'s Characters as a run
/// of the text's, found in one pass however long the text. The needles here
/// are ASCII, and no scalar decomposes canonically to any of their
/// characters, so Character equality is equality of the clusters' bytes.
fn contains(text: &str, needle: &str) -> bool {
    let needle: Vec<&str> = graphemes(needle).collect();
    // Knuth–Morris–Pratt: how much of the needle a mismatch leaves matched.
    let mut fallback = vec![0; needle.len()];
    let mut matched = 0;
    for index in 1..needle.len() {
        while matched > 0 && needle[index] != needle[matched] {
            matched = fallback[matched - 1];
        }
        if needle[index] == needle[matched] {
            matched += 1;
        }
        fallback[index] = matched;
    }
    matched = 0;
    for character in graphemes(text) {
        while matched > 0 && character != needle[matched] {
            matched = fallback[matched - 1];
        }
        if character == needle[matched] {
            matched += 1;
            if matched == needle.len() {
                return true;
            }
        }
    }
    false
}

/// Swift `Character.isNewline` of a Character's first scalar.
fn is_newline(scalar: char) -> bool {
    matches!(
        scalar,
        '\n' | '\u{b}' | '\u{c}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// Foundation `CharacterSet.whitespaces` on this host: the tab, the space
/// separators, and U+200B, which CoreFoundation still counts as one.
fn is_whitespace(scalar: char) -> bool {
    matches!(
        scalar,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200b}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

/// Swift `Unicode.Scalar.Properties.numericType != nil`, which
/// `Character.isNumber` asks of a Character's first scalar.
fn is_number(scalar: char) -> bool {
    scalar.is_numeric() || tabled(scalar, NUMERIC_BEYOND_STD)
}

/// Swift `Unicode.Scalar.Properties.isAlphabetic`, which `Character.isLetter`
/// asks of a Character's first scalar.
fn is_letter(scalar: char) -> bool {
    scalar.is_alphabetic() || tabled(scalar, ALPHABETIC_BEYOND_STD)
}

fn tabled(scalar: char, ranges: &[(u32, u32)]) -> bool {
    let scalar = scalar as u32;
    let index = ranges.partition_point(|(_, last)| *last < scalar);
    ranges.get(index).is_some_and(|(first, _)| *first <= scalar)
}

// The scalars Swift 6.4's runtime (macOS 27) holds and the standard library of
// Rust 1.98 does not, found by comparing both over every scalar; the oracle
// test proves the union. Swift holds no scalar the standard library leaves out
// otherwise.

/// `Numeric_Type` numerals outside `Nd`, `Nl` and `No`: Han and compatibility
/// ideographs and cuneiform signs.
#[rustfmt::skip]
const NUMERIC_BEYOND_STD: &[(u32, u32)] = &[
    (0x3405, 0x3405), (0x3483, 0x3483), (0x382A, 0x382A), (0x3B4D, 0x3B4D), (0x4E00, 0x4E00),
    (0x4E03, 0x4E03), (0x4E07, 0x4E07), (0x4E09, 0x4E09), (0x4E24, 0x4E24), (0x4E5D, 0x4E5D),
    (0x4E8C, 0x4E8C), (0x4E94, 0x4E94), (0x4E96, 0x4E96), (0x4EAC, 0x4EAC), (0x4EBF, 0x4EC0),
    (0x4EDF, 0x4EDF), (0x4EE8, 0x4EE8), (0x4F0D, 0x4F0D), (0x4F70, 0x4F70), (0x4FE9, 0x4FE9),
    (0x5006, 0x5006), (0x5104, 0x5104), (0x5146, 0x5146), (0x5169, 0x5169), (0x516B, 0x516B),
    (0x516D, 0x516D), (0x5341, 0x5341), (0x5343, 0x5345), (0x534C, 0x534C), (0x53C1, 0x53C4),
    (0x56DB, 0x56DB), (0x58F1, 0x58F1), (0x58F9, 0x58F9), (0x5E7A, 0x5E7A), (0x5EFE, 0x5EFF),
    (0x5F0C, 0x5F0E), (0x5F10, 0x5F10), (0x62D0, 0x62D0), (0x62FE, 0x62FE), (0x634C, 0x634C),
    (0x67D2, 0x67D2), (0x6D1E, 0x6D1E), (0x6F06, 0x6F06), (0x7396, 0x7396), (0x767E, 0x767E),
    (0x7695, 0x7695), (0x79ED, 0x79ED), (0x8086, 0x8086), (0x842C, 0x842C), (0x8CAE, 0x8CAE),
    (0x8CB3, 0x8CB3), (0x8D30, 0x8D30), (0x920E, 0x920E), (0x94A9, 0x94A9), (0x9621, 0x9621),
    (0x9646, 0x9646), (0x964C, 0x964C), (0x9678, 0x9678), (0x96F6, 0x96F6), (0xF96B, 0xF96B),
    (0xF973, 0xF973), (0xF978, 0xF978), (0xF9B2, 0xF9B2), (0xF9D1, 0xF9D1), (0xF9D3, 0xF9D3),
    (0xF9FD, 0xF9FD), (0x12038, 0x12039), (0x12079, 0x12079), (0x12226, 0x12226),
    (0x1222B, 0x1222B), (0x1230B, 0x1230B), (0x1230D, 0x1230D), (0x12399, 0x12399),
    (0x20001, 0x20001), (0x20064, 0x20064), (0x200E2, 0x200E2), (0x20121, 0x20121),
    (0x2092A, 0x2092A), (0x20983, 0x20983), (0x2098C, 0x2098C), (0x2099C, 0x2099C),
    (0x20AEA, 0x20AEA), (0x20AFD, 0x20AFD), (0x20B19, 0x20B19), (0x22390, 0x22390),
    (0x22998, 0x22998), (0x23B1B, 0x23B1B), (0x2626D, 0x2626D), (0x2F890, 0x2F890),
];

/// Private-use scalars Swift reports alphabetic.
#[rustfmt::skip]
const ALPHABETIC_BEYOND_STD: &[(u32, u32)] = &[
    (0xF882, 0xF882), (0xF89A, 0xF89E), (0xF8A2, 0xF8A7), (0xF8B8, 0xF8B8), (0xF8C1, 0xF8D6),
];

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn oracle() -> Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../tests/fixtures/crash-ledger-analyzer/oracle.json"
        );
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    fn unbase64(text: &str) -> Vec<u8> {
        let digit = |byte: u8| match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => panic!("not base64: {byte}"),
        };
        let mut bytes = Vec::new();
        for group in text.as_bytes().chunks(4) {
            let digits: Vec<u32> = group
                .iter()
                .filter(|byte| **byte != b'=')
                .map(|byte| u32::from(digit(*byte)))
                .collect();
            let value = digits
                .iter()
                .enumerate()
                .fold(0, |value, (index, digit)| value | digit << (18 - 6 * index));
            bytes.extend(&value.to_be_bytes()[1..digits.len()]);
        }
        bytes
    }

    #[test]
    fn every_listing_swift_analyzed_is_analyzed_to_the_same_bytes() {
        let oracle = oracle();
        let mut analyzed = 0;
        for case in oracle["cases"].as_array().unwrap() {
            let Some(input) = case["input"].as_str() else {
                continue;
            };
            if case["exitStatus"] != 0 {
                continue;
            }
            let output = analyze_crash_ledger(&unbase64(input)).unwrap();
            assert_eq!(
                String::from_utf8(output).unwrap(),
                case["stdout"].as_str().unwrap(),
                "{}",
                case["name"]
            );
            analyzed += 1;
        }
        assert!(analyzed > 60, "{analyzed}");
    }

    #[test]
    fn the_character_properties_are_swifts_for_every_scalar() {
        let oracle = oracle();
        let properties: BTreeMap<&str, fn(char) -> bool> = BTreeMap::from([
            ("isLetter", is_letter as fn(char) -> bool),
            ("isNewline", is_newline),
            ("isNumber", is_number),
            ("whitespaces", is_whitespace),
        ]);
        let recorded = oracle["properties"].as_object().unwrap();
        assert_eq!(
            recorded.keys().map(String::as_str).collect::<Vec<_>>(),
            properties.keys().copied().collect::<Vec<_>>()
        );
        for (name, holds) in properties {
            let ranges: Vec<(u32, u32)> = recorded[name]
                .as_array()
                .unwrap()
                .iter()
                .map(|range| {
                    (
                        range[0].as_u64().unwrap() as u32,
                        range[1].as_u64().unwrap() as u32,
                    )
                })
                .collect();
            for scalar in (0..=0x10_FFFF).filter_map(char::from_u32) {
                assert_eq!(
                    holds(scalar),
                    tabled(scalar, &ranges),
                    "{name} of U+{:04X}",
                    scalar as u32
                );
            }
        }
    }

    #[test]
    fn the_arguments_are_taken_as_swift_takes_them() {
        use std::os::unix::ffi::OsStringExt;
        let refused: [&[&str]; 6] = [
            &[],
            &["/a", "/b"],
            &["a/b"],
            &[""],
            &["/\u{301}a"],
            &["\u{600}/a"],
        ];
        for values in refused {
            let values: Vec<OsString> = values.iter().map(OsString::from).collect();
            assert_eq!(crash_ledger_source(&values), None, "{values:?}");
        }
        let taken: [(&[u8], &str); 9] = [
            (b"/a/b", "/a/b"),
            (b"/a/b/", "/a/b"),
            (b"/a/b///", "/a/b"),
            (b"/a/./b", "/a/./b"),
            (b"//a", "//a"),
            (b"/", "/"),
            (b"///", "/"),
            (b"/.vol/16777234/42", "/.vol/16777234/42"),
            (b"/a\xff\xfe/b", "/a\u{fffd}\u{fffd}/b"),
        ];
        for (argument, path) in taken {
            // Compared as spelled: a path's components ignore its trailing
            // solidi, and reading the file does not.
            assert_eq!(
                crash_ledger_source(&[OsString::from_vec(argument.to_vec())])
                    .map(PathBuf::into_os_string),
                Some(OsString::from(path)),
                "{argument:?}"
            );
        }
    }

    #[test]
    fn a_refusal_is_never_an_empty_ledger() {
        let unreadable = |bytes: &[u8]| {
            let output: Value =
                serde_json::from_slice(&analyze_crash_ledger(bytes).unwrap()).unwrap();
            (output["status"].clone(), output["unreadableReason"].clone())
        };
        assert_eq!(
            unreadable(b""),
            (json!("unreadable"), json!("ledgerHeaderAbsent"))
        );
        assert_eq!(
            unreadable(b"Fault log list:\n******\n"),
            (json!("unreadable"), json!("ledgerFenceAbsent"))
        );
        assert_eq!(
            unreadable(b"Fault log list:\n******\nnot-an-entry\n******\n"),
            (json!("unreadable"), json!("entryNameUnparseable"))
        );
        assert_eq!(
            unreadable(b"\xffFault log list:"),
            (json!("unreadable"), json!("invalidEncoding"))
        );
        assert_eq!(
            unreadable(b"Fault log list:\n******\n******\n"),
            (json!("answered"), Value::Null)
        );
    }
}
