//! Foundation's CharacterSet predicates and NFC, as portable pinned tables.
//!
//! The Foundation store owners read text through CoreFoundation's predefined
//! character sets and `CFStringNormalize(kCFStringNormalizationFormC)`. These
//! functions answer the same way on every host from Unicode tables generated
//! by `rust/scripts/generate-host-text-tables.py`, never from the host's own
//! Unicode data (Win32 NLS, a newer ICU or the Rust standard library), whose
//! version follows the operating system. The tables are Unicode 17.0.0 with
//! the differences CoreFoundation was recorded to have (listed in the
//! generator), and NFC keeps two CoreFoundation behaviours that the standard
//! does not have (see `host_canonical_text`). On macOS the tests compare every
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

/// `CharacterSet.alphanumerics`: general categories L*, M* and N*, without
/// Todhri and the Tangut ideographs, as CoreFoundation holds them.
pub fn host_alphanumeric(scalar: char) -> bool {
    member(tables::ALPHANUMERIC, scalar)
}

/// `CharacterSet.whitespacesAndNewlines`: Z*, U+0009 to U+000D, U+0085 and,
/// as CoreFoundation holds it, U+200B.
pub fn host_whitespace_or_newline(scalar: char) -> bool {
    member(tables::WHITESPACE_OR_NEWLINE, scalar)
}

/// Canonical-equivalence key matching Swift String hashing/equality. Preserve
/// the original input separately for durable bytes and UTF-8 ordering.
///
/// It is the key the Foundation primitive produced, including two places
/// where that differs from Unicode NFC:
/// - one leading U+FEFF is dropped (CoreFoundation reads it as a byte order
///   mark when the text is created from UTF-8);
/// - a starter that came precomposed with a following starter (combining
///   class 0) in one input character joins no starter from another input
///   character, so `U+AC00 U+11A8` and `U+0CCA U+0CD5` stay as they are,
///   while `U+1100 U+1161 U+11A8` and `U+0CC6 U+0CC2 U+0CD5` compose fully
///   and a precomposed `U+AC01` or `U+0CCB` is kept whole;
/// - six Unicode 16 composites (`OWN_SOURCE_ONLY`) are kept precomposed but
///   never formed from separate characters.
///
/// The Foundation primitive returned `None` only when it could not allocate;
/// this one always answers.
pub fn host_canonical_text(value: &str) -> Option<String> {
    let value = value.strip_prefix('\u{feff}').unwrap_or(value);
    if value.is_ascii() {
        return Some(value.to_owned());
    }
    let mut scalars = decomposition(value);
    compose(&mut scalars);
    scalars
        .into_iter()
        .map(|(scalar, _)| char::from_u32(scalar))
        .collect()
}

/// Canonical decomposition in canonical order, each scalar with the index of
/// the input character it came from.
fn decomposition(value: &str) -> Vec<(u32, usize)> {
    let mut scalars = Vec::with_capacity(value.len());
    let mut parts = Vec::new();
    for (source, scalar) in value.chars().enumerate() {
        parts.clear();
        decompose(scalar as u32, &mut parts);
        scalars.extend(parts.iter().map(|part| (*part, source)));
    }
    reorder(&mut scalars);
    scalars
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
fn reorder(scalars: &mut [(u32, usize)]) {
    let mut start = 0;
    while start < scalars.len() {
        if combining_class(scalars[start].0) == 0 {
            start += 1;
            continue;
        }
        let mut end = start;
        while end < scalars.len() && combining_class(scalars[end].0) != 0 {
            end += 1;
        }
        scalars[start..end].sort_by_key(|(scalar, _)| combining_class(*scalar));
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

/// The last starter during composition: where it is, the input character it
/// came from, and whether it has joined a starter from that same character.
struct Starter {
    position: usize,
    source: usize,
    joined_own_starter: bool,
}

/// Canonical composition (UAX #15): each character joins the last starter
/// unless a character between them blocks it, with CoreFoundation's limit on
/// starters joining starters (see `host_canonical_text`).
fn compose(scalars: &mut Vec<(u32, usize)>) {
    let mut out: Vec<(u32, usize)> = Vec::with_capacity(scalars.len());
    let mut starter: Option<Starter> = None;
    let mut last_class = 0;
    for &(scalar, source) in scalars.iter() {
        let class = combining_class(scalar);
        if let Some(last) = starter.as_mut() {
            let adjacent = last.position + 1 == out.len();
            let own = source == last.source;
            if (own || class != 0 || !last.joined_own_starter)
                && (adjacent || (last_class != 0 && last_class < class))
                && let Some(composite) = primary_composite(out[last.position].0, scalar)
                && (own || tables::OWN_SOURCE_ONLY.binary_search(&composite).is_err())
            {
                out[last.position].0 = composite;
                last.joined_own_starter |= own && class == 0;
                continue;
            }
        }
        if class == 0 {
            starter = Some(Starter {
                position: out.len(),
                source,
                joined_own_starter: false,
            });
        }
        last_class = class;
        out.push((scalar, source));
    }
    *scalars = out;
}

/// NFD and the table facts, for the Foundation parity tests.
#[cfg(all(test, target_os = "macos"))]
pub(crate) mod oracle_access {
    /// NFD as the Foundation string holds it (one leading U+FEFF dropped).
    pub(crate) fn canonical_decomposition(value: &str) -> String {
        let value = value.strip_prefix('\u{feff}').unwrap_or(value);
        super::decomposition(value)
            .into_iter()
            .filter_map(|(scalar, _)| char::from_u32(scalar))
            .collect()
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
        // CoreFoundation's recorded differences: Todhri and the Tangut
        // ideograph ranges are not alphanumerics; Tangut components are.
        for scalar in [
            '\u{105c0}',
            '\u{105f3}',
            '\u{17000}',
            '\u{187ff}',
            '\u{18d00}',
        ] {
            assert!(!host_alphanumeric(scalar), "{scalar:?}");
        }
        assert!(host_alphanumeric('\u{18800}'));
        // Z* plus the C0 newlines, NEL and (CoreFoundation) U+200B; not
        // U+001C..U+001F, U+180E or U+FEFF.
        for scalar in ['\t', '\n', '\u{b}', '\u{c}', '\r', ' ', '\u{85}', '\u{a0}'] {
            assert!(host_whitespace_or_newline(scalar), "{scalar:?}");
        }
        for scalar in ['\u{1680}', '\u{2000}', '\u{2028}', '\u{2029}', '\u{3000}'] {
            assert!(host_whitespace_or_newline(scalar), "{scalar:?}");
        }
        assert!(host_whitespace_or_newline('\u{200b}'));
        for scalar in ['\u{1c}', '\u{1f}', '\u{200c}', '\u{180e}', '\u{feff}', 'a'] {
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
        // Hangul L+V joins; a precomposed LVT stays whole.
        assert_eq!(nfc("\u{1100}\u{1161}"), "\u{ac00}");
        assert_eq!(nfc("\u{ac01}"), "\u{ac01}");
        assert_eq!(nfc("\u{ac00}\u{11a7}"), "\u{ac00}\u{11a7}");
        // Starter + starter primary composites.
        assert_eq!(nfc("\u{b47}\u{b3e}"), "\u{b4b}");
        assert_eq!(nfc("\u{11099}\u{110ba}"), "\u{1109a}");
        assert_eq!(nfc("\u{cc6}\u{cd5}"), "\u{cc7}");
        assert_eq!(nfc("\u{ccb}"), "\u{ccb}");
        // CoreFoundation: a starter that joined another input character's
        // starter joins no further starter (Unicode would give U+AC01 and
        // U+0CCB); Unicode 16's starter-second composites never form.
        assert_eq!(nfc("\u{ac00}\u{11a8}"), "\u{ac00}\u{11a8}");
        assert_eq!(nfc("\u{cca}\u{cd5}"), "\u{cca}\u{cd5}");
        assert_eq!(nfc("\u{1100}\u{1161}\u{11a8}"), "\u{ac01}");
        assert_eq!(nfc("\u{cc6}\u{cc2}\u{cd5}"), "\u{ccb}");
        assert_eq!(nfc("\u{16121}\u{1611f}"), "\u{16121}\u{1611f}");
        assert_eq!(nfc("\u{16126}"), "\u{16126}");
        assert_eq!(nfc("\u{16d6a}"), "\u{16d6a}");
        // Todhri is unassigned there: no decomposition.
        assert_eq!(nfc("\u{105c9}"), "\u{105c9}");
        // One leading U+FEFF is read as a byte order mark and dropped.
        assert_eq!(nfc("\u{feff}"), "");
        assert_eq!(nfc("\u{feff}e\u{301}"), "\u{e9}");
        assert_eq!(nfc("\u{feff}\u{feff}"), "\u{feff}");
        assert_eq!(nfc("a\u{feff}"), "a\u{feff}");
        // A leading non-starter has nothing to join.
        assert_eq!(nfc("\u{301}e"), "\u{301}e");
        assert_eq!(nfc(""), "");
    }

    /// Unicode's own conformance file for the pinned version, when a
    /// maintainer supplies it: `ARKDECK_NORMALIZATION_TEST=<path to
    /// NormalizationTest.txt> cargo test -p arkdeck-platform -- --ignored`.
    /// Every line holds except those that involve CoreFoundation's recorded
    /// differences: a starter that composes with a preceding starter, Todhri,
    /// or a leading U+FEFF.
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
        let starter_seconds: std::collections::BTreeSet<u32> = tables::COMPOSITION
            .iter()
            .filter(|(_, second, _)| combining_class(*second) == 0)
            .map(|(_, second, _)| *second)
            .chain(V_BASE..T_BASE + T_COUNT)
            .chain([0x1611F, 0x16120, 0x16D67])
            .collect();
        let recorded = |value: &str| {
            value.starts_with('\u{feff}')
                || value.chars().any(|c| {
                    let mut parts = Vec::new();
                    decompose(c as u32, &mut parts);
                    (0x105C0..0x10600).contains(&(c as u32))
                        || parts.iter().any(|part| starter_seconds.contains(part))
                })
        };
        let mut listed = std::collections::BTreeSet::new();
        let (mut checked, mut exempt) = (0, 0);
        for line in text.lines() {
            let body = line.split('#').next().unwrap();
            if body.is_empty() || body.starts_with('@') {
                continue;
            }
            let columns: Vec<String> = body.split(';').take(5).map(field).collect();
            if columns[0].chars().count() == 1 {
                listed.insert(columns[0].chars().next().unwrap());
            }
            if columns.iter().any(|column| recorded(column)) {
                exempt += 1;
                continue;
            }
            // NFC(c1) = NFC(c2) = NFC(c3) = c2; NFC(c4) = NFC(c5) = c4.
            for (index, expected) in [(0, 1), (1, 1), (2, 1), (3, 3), (4, 3)] {
                assert_eq!(nfc(&columns[index]), columns[expected], "{line}");
            }
            checked += 1;
        }
        // Part 1 invariant: every other scalar is its own NFC.
        for scalar in (0..=0x10FFFF).filter_map(char::from_u32) {
            if !listed.contains(&scalar) && scalar != '\u{feff}' {
                assert_eq!(nfc(&scalar.to_string()), scalar.to_string(), "{scalar:?}");
            }
        }
        assert!(
            checked > 8_000 && exempt < 12_000,
            "{checked} lines, {exempt} exempt"
        );
    }
}
