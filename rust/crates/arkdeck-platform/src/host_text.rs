//! Foundation's CharacterSet predicates and NFC, as portable pinned tables.
//!
//! The Foundation store owners read text through CoreFoundation's predefined
//! character sets and `CFStringNormalize(kCFStringNormalizationFormC)`. These
//! functions answer the same way on every host from Unicode tables generated
//! by `rust/scripts/generate-host-text-tables.py`, never from the host's own
//! Unicode data (Win32 NLS, a newer ICU or the Rust standard library), whose
//! version follows the operating system. On macOS the tests compare every
//! scalar, and the composition and reordering sequences, with CoreFoundation
//! itself (`host_text_foundation.rs`), so a table that drifts from the macOS
//! owner fails there. No filesystem, process or Runtime access.
#[path = "host_text_tables.rs"]
mod tables;

fn member(ranges: &[(u32, u32)], scalar: char) -> bool {
    let scalar = scalar as u32;
    let index = ranges.partition_point(|(_, end)| *end < scalar);
    ranges.get(index).is_some_and(|(start, _)| *start <= scalar)
}

/// `CharacterSet.controlCharacters`: general categories Cc and Cf.
pub fn host_control_character(scalar: char) -> bool {
    member(tables::CONTROL, scalar)
}

/// `CharacterSet.alphanumerics`: general categories L*, M* and N*.
pub fn host_alphanumeric(scalar: char) -> bool {
    member(tables::ALPHANUMERIC, scalar)
}

/// `CharacterSet.whitespacesAndNewlines`: Z*, U+0009 to U+000D and U+0085.
pub fn host_whitespace_or_newline(scalar: char) -> bool {
    member(tables::WHITESPACE_OR_NEWLINE, scalar)
}

/// Canonical-equivalence key matching Swift String hashing/equality. Preserve
/// the original input separately for durable bytes and UTF-8 ordering.
///
/// The Foundation primitive this replaces returned `None` only when it could
/// not allocate; this one always answers.
pub fn host_canonical_text(value: &str) -> Option<String> {
    if value.is_ascii() {
        return Some(value.to_owned());
    }
    let mut scalars = Vec::with_capacity(value.len());
    for scalar in value.chars() {
        decompose(scalar as u32, &mut scalars);
    }
    reorder(&mut scalars);
    compose(&mut scalars);
    scalars.into_iter().map(char::from_u32).collect()
}

const S_BASE: u32 = 0xAC00;
const L_BASE: u32 = 0x1100;
const V_BASE: u32 = 0x1161;
const T_BASE: u32 = 0x11A7;
const L_COUNT: u32 = 19;
const V_COUNT: u32 = 21;
const T_COUNT: u32 = 28;
const N_COUNT: u32 = V_COUNT * T_COUNT;
const S_COUNT: u32 = L_COUNT * N_COUNT;

fn combining_class(scalar: u32) -> u8 {
    let classes = tables::COMBINING_CLASS;
    let index = classes.partition_point(|(_, end, _)| *end < scalar);
    classes
        .get(index)
        .filter(|(start, _, _)| *start <= scalar)
        .map_or(0, |(_, _, class)| *class)
}

fn decompose(scalar: u32, out: &mut Vec<u32>) {
    if (S_BASE..S_BASE + S_COUNT).contains(&scalar) {
        let index = scalar - S_BASE;
        out.push(L_BASE + index / N_COUNT);
        out.push(V_BASE + (index % N_COUNT) / T_COUNT);
        if !index.is_multiple_of(T_COUNT) {
            out.push(T_BASE + index % T_COUNT);
        }
        return;
    }
    match tables::DECOMPOSITION.binary_search_by_key(&scalar, |(code, _, _)| *code) {
        Ok(index) => {
            let (_, first, second) = tables::DECOMPOSITION[index];
            decompose(first, out);
            if second != 0 {
                decompose(second, out);
            }
        }
        Err(_) => out.push(scalar),
    }
}

/// Canonical ordering: a stable sort of each run of non-starters by class.
fn reorder(scalars: &mut [u32]) {
    let mut start = 0;
    while start < scalars.len() {
        if combining_class(scalars[start]) == 0 {
            start += 1;
            continue;
        }
        let mut end = start;
        while end < scalars.len() && combining_class(scalars[end]) != 0 {
            end += 1;
        }
        scalars[start..end].sort_by_key(|scalar| combining_class(*scalar));
        start = end;
    }
}

fn primary_composite(first: u32, second: u32) -> Option<u32> {
    if (L_BASE..L_BASE + L_COUNT).contains(&first) && (V_BASE..V_BASE + V_COUNT).contains(&second) {
        return Some(S_BASE + ((first - L_BASE) * V_COUNT + (second - V_BASE)) * T_COUNT);
    }
    if (S_BASE..S_BASE + S_COUNT).contains(&first)
        && (first - S_BASE).is_multiple_of(T_COUNT)
        && (T_BASE + 1..T_BASE + T_COUNT).contains(&second)
    {
        return Some(first + (second - T_BASE));
    }
    tables::COMPOSITION
        .binary_search_by(|(a, b, _)| (*a, *b).cmp(&(first, second)))
        .ok()
        .map(|index| tables::COMPOSITION[index].2)
}

/// Canonical composition (UAX #15): each character joins the last starter
/// unless a character between them blocks it.
fn compose(scalars: &mut Vec<u32>) {
    let mut out: Vec<u32> = Vec::with_capacity(scalars.len());
    let mut starter: Option<usize> = None;
    let mut last_class = 0;
    for &scalar in scalars.iter() {
        let class = combining_class(scalar);
        if let Some(position) = starter {
            let adjacent = position + 1 == out.len();
            if (adjacent || (last_class != 0 && last_class < class))
                && let Some(composite) = primary_composite(out[position], scalar)
            {
                out[position] = composite;
                continue;
            }
        }
        if class == 0 {
            starter = Some(out.len());
        }
        last_class = class;
        out.push(scalar);
    }
    *scalars = out;
}

/// NFD and the table facts, for the Foundation parity tests.
#[cfg(all(test, target_os = "macos"))]
pub(crate) mod oracle_access {
    pub(crate) fn canonical_decomposition(value: &str) -> String {
        let mut scalars = Vec::new();
        for scalar in value.chars() {
            super::decompose(scalar as u32, &mut scalars);
        }
        super::reorder(&mut scalars);
        scalars.into_iter().filter_map(char::from_u32).collect()
    }
    pub(crate) const COMPOSITION: &[(u32, u32, u32)] = super::tables::COMPOSITION;
    pub(crate) const COMBINING_CLASS: &[(u32, u32, u8)] = super::tables::COMBINING_CLASS;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nfc(value: &str) -> String {
        host_canonical_text(value).unwrap()
    }

    #[test]
    fn tables_are_the_pinned_unicode_version_and_sorted() {
        assert_eq!(tables::UNICODE_VERSION, "17.0.0");
        for ranges in [
            tables::CONTROL,
            tables::ALPHANUMERIC,
            tables::WHITESPACE_OR_NEWLINE,
        ] {
            assert!(ranges.iter().all(|(start, end)| start <= end));
            assert!(ranges.windows(2).all(|pair| pair[0].1 + 1 < pair[1].0));
        }
        assert!(
            tables::COMBINING_CLASS
                .windows(2)
                .all(|pair| pair[0].1 < pair[1].0)
        );
        assert!(tables::DECOMPOSITION.windows(2).all(|p| p[0].0 < p[1].0));
        assert!(
            tables::COMPOSITION
                .windows(2)
                .all(|p| (p[0].0, p[0].1) < (p[1].0, p[1].1))
        );
        // Every table entry is a Unicode scalar value.
        assert!(tables::DECOMPOSITION.iter().all(|(a, b, c)| {
            char::from_u32(*a).is_some()
                && char::from_u32(*b).is_some()
                && (*c == 0 || char::from_u32(*c).is_some())
        }));
    }

    #[test]
    fn character_sets_pin_foundation_category_edges() {
        // Cc and Cf, including format characters Rust's is_control omits.
        for scalar in ['\0', '\u{1f}', '\u{7f}', '\u{9f}', '\u{ad}', '\u{200b}'] {
            assert!(host_control_character(scalar), "{scalar:?}");
        }
        for scalar in ['\u{200e}', '\u{2066}', '\u{feff}', '\u{e0001}'] {
            assert!(host_control_character(scalar), "{scalar:?}");
        }
        for scalar in [' ', 'a', '\u{a0}', '\u{2028}', '\u{e000}', '\u{10ffff}'] {
            assert!(!host_control_character(scalar), "{scalar:?}");
        }
        // L*, M*, N*: marks and letter numbers count, unlike Rust's predicate
        // for marks; punctuation, symbols and unassigned scalars do not.
        for scalar in [
            'a',
            'Z',
            '0',
            '\u{301}',
            '\u{2160}',
            '\u{4e00}',
            '\u{e01ef}',
        ] {
            assert!(host_alphanumeric(scalar), "{scalar:?}");
        }
        for scalar in ['_', '-', '.', ' ', '\u{a0}', '\u{378}', '\u{e000}'] {
            assert!(!host_alphanumeric(scalar), "{scalar:?}");
        }
        // Z* plus the C0 newlines and NEL; not U+001C..U+001F or U+200B.
        for scalar in ['\t', '\n', '\u{b}', '\u{c}', '\r', ' ', '\u{85}', '\u{a0}'] {
            assert!(host_whitespace_or_newline(scalar), "{scalar:?}");
        }
        for scalar in ['\u{1680}', '\u{2000}', '\u{2028}', '\u{2029}', '\u{3000}'] {
            assert!(host_whitespace_or_newline(scalar), "{scalar:?}");
        }
        for scalar in ['\u{1c}', '\u{1f}', '\u{200b}', '\u{180e}', '\u{feff}', 'a'] {
            assert!(!host_whitespace_or_newline(scalar), "{scalar:?}");
        }
    }

    #[test]
    fn canonical_text_composes_reorders_and_keeps_exclusions() {
        assert_eq!(nfc("plain ascii"), "plain ascii");
        assert_eq!(nfc("e\u{301}"), "\u{e9}");
        assert_eq!(nfc("\u{e9}"), "\u{e9}");
        // Singletons decompose and never recompose.
        assert_eq!(nfc("\u{212b}"), "\u{c5}");
        assert_eq!(nfc("\u{2126}"), "\u{3a9}");
        // Composition exclusions stay decomposed.
        assert_eq!(nfc("\u{958}"), "\u{915}\u{93c}");
        assert_eq!(nfc("\u{2adc}"), "\u{2add}\u{338}");
        // Non-starter decompositions.
        assert_eq!(nfc("\u{344}"), "\u{308}\u{301}");
        // Reordering by class, then composition past a lower class.
        assert_eq!(nfc("a\u{301}\u{323}"), "\u{1ea1}\u{301}");
        assert_eq!(nfc("a\u{323}\u{301}"), "\u{1ea1}\u{301}");
        assert_eq!(nfc("\u{1e0b}\u{323}"), "\u{1e0d}\u{307}");
        // A same-class mark blocks the second one.
        assert_eq!(nfc("a\u{301}\u{301}"), "\u{e1}\u{301}");
        // A starter between blocks composition.
        assert_eq!(nfc("a b\u{301}"), "a b\u{301}");
        // Hangul L+V, LV+T and a precomposed LVT round trip.
        assert_eq!(nfc("\u{1100}\u{1161}"), "\u{ac00}");
        assert_eq!(nfc("\u{1100}\u{1161}\u{11a8}"), "\u{ac01}");
        assert_eq!(nfc("\u{ac01}"), "\u{ac01}");
        assert_eq!(nfc("\u{ac00}\u{11a7}"), "\u{ac00}\u{11a7}");
        // Starter + starter primary composites.
        assert_eq!(nfc("\u{b47}\u{b3e}"), "\u{b4b}");
        assert_eq!(nfc("\u{11099}\u{110ba}"), "\u{1109a}");
        // A leading non-starter has nothing to join.
        assert_eq!(nfc("\u{301}e"), "\u{301}e");
        assert_eq!(nfc(""), "");
    }

    /// Unicode's own conformance file for the pinned version, when a
    /// maintainer supplies it: `ARKDECK_NORMALIZATION_TEST=<path to
    /// NormalizationTest.txt> cargo test -p arkdeck-platform -- --ignored`.
    #[test]
    #[ignore = "needs the Unicode 17.0.0 NormalizationTest.txt named by ARKDECK_NORMALIZATION_TEST"]
    fn canonical_text_passes_unicode_normalization_test() {
        let path = std::env::var_os("ARKDECK_NORMALIZATION_TEST")
            .expect("ARKDECK_NORMALIZATION_TEST names NormalizationTest.txt");
        let text = std::fs::read_to_string(path).unwrap();
        assert!(text.starts_with("# NormalizationTest-17.0.0.txt"));
        let field = |value: &str| -> String {
            value
                .split(' ')
                .map(|hex| char::from_u32(u32::from_str_radix(hex, 16).unwrap()).unwrap())
                .collect()
        };
        let mut listed = std::collections::BTreeSet::new();
        let mut checked = 0;
        for line in text.lines() {
            let body = line.split('#').next().unwrap();
            if body.is_empty() || body.starts_with('@') {
                continue;
            }
            let columns: Vec<String> = body.split(';').take(5).map(field).collect();
            // NFC(c1) = NFC(c2) = NFC(c3) = c2; NFC(c4) = NFC(c5) = c4.
            for (index, expected) in [(0, 1), (1, 1), (2, 1), (3, 3), (4, 3)] {
                assert_eq!(nfc(&columns[index]), columns[expected], "{line}");
            }
            if columns[0].chars().count() == 1 {
                listed.insert(columns[0].chars().next().unwrap());
            }
            checked += 1;
        }
        // Part 1 invariant: every other scalar is its own NFC.
        for scalar in (0..=0x10FFFF).filter_map(char::from_u32) {
            if !listed.contains(&scalar) {
                assert_eq!(nfc(&scalar.to_string()), scalar.to_string(), "{scalar:?}");
            }
        }
        assert!(checked > 19_000, "{checked} lines");
    }
}
