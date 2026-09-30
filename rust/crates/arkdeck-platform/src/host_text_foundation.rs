//! The CoreFoundation character sets and normalization that `host_text`
//! replaced, kept as the macOS parity oracle for its portable tables. Test
//! builds on macOS only; no Runtime path links it.
use std::ffi::c_void;

#[repr(C)]
struct Range {
    location: isize,
    length: isize,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFCharacterSetGetPredefined(identifier: isize) -> *const c_void;
    fn CFCharacterSetIsLongCharacterMember(set: *const c_void, scalar: u32) -> u8;
    fn CFStringCreateWithBytes(
        allocator: *const c_void,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external: u8,
    ) -> *const c_void;
    fn CFStringCreateMutableCopy(
        allocator: *const c_void,
        maximum: isize,
        string: *const c_void,
    ) -> *mut c_void;
    fn CFStringNormalize(string: *mut c_void, form: isize);
    fn CFStringGetLength(string: *const c_void) -> isize;
    fn CFStringGetMaximumSizeForEncoding(length: isize, encoding: u32) -> isize;
    fn CFStringGetBytes(
        string: *const c_void,
        range: Range,
        encoding: u32,
        loss: u8,
        external: u8,
        buffer: *mut u8,
        maximum: isize,
        used: *mut isize,
    ) -> isize;
    fn CFRelease(object: *const c_void);
}

fn member(identifier: isize, scalar: char) -> bool {
    // SAFETY: these predefined sets are immutable, borrowed, process-lifetime
    // CoreFoundation objects. Rust char supplies a valid Unicode scalar value.
    unsafe {
        let set = CFCharacterSetGetPredefined(identifier);
        CFCharacterSetIsLongCharacterMember(set, scalar as u32) != 0
    }
}

pub(crate) fn control_character(scalar: char) -> bool {
    // CFCharacterSet.h: kCFCharacterSetControl = 1 (Cc and Cf).
    member(1, scalar)
}

pub(crate) fn alphanumeric(scalar: char) -> bool {
    // CFCharacterSet.h: kCFCharacterSetAlphaNumeric = 10 (L*, M* and N*).
    member(10, scalar)
}

pub(crate) fn whitespace_or_newline(scalar: char) -> bool {
    // CFCharacterSet.h: kCFCharacterSetWhitespaceAndNewline = 3.
    member(3, scalar)
}

/// `form`: kCFStringNormalizationFormD = 0, kCFStringNormalizationFormC = 2.
pub(crate) fn normalize(value: &str, form: isize) -> Option<String> {
    const UTF8: u32 = 0x08000100;
    struct Owned(*const c_void);
    impl Drop for Owned {
        fn drop(&mut self) {
            // SAFETY: constructed only for a nonnull create-rule CF object.
            unsafe { CFRelease(self.0) };
        }
    }
    let length = isize::try_from(value.len()).ok()?;
    // SAFETY: all byte ranges remain live for the call. Create-rule strings
    // have RAII owners; only the private mutable copy is normalized.
    unsafe {
        let source = CFStringCreateWithBytes(std::ptr::null(), value.as_ptr(), length, UTF8, 0);
        if source.is_null() {
            return None;
        }
        let source = Owned(source);
        let copy = CFStringCreateMutableCopy(std::ptr::null(), 0, source.0);
        if copy.is_null() {
            return None;
        }
        let copy_owner = Owned(copy);
        CFStringNormalize(copy, form);
        let units = CFStringGetLength(copy_owner.0);
        let maximum = CFStringGetMaximumSizeForEncoding(units, UTF8);
        let mut buffer = vec![0; usize::try_from(maximum).ok()?];
        let mut used = 0;
        let converted = CFStringGetBytes(
            copy_owner.0,
            Range {
                location: 0,
                length: units,
            },
            UTF8,
            0,
            0,
            buffer.as_mut_ptr(),
            maximum,
            &mut used,
        );
        if converted != units || used < 0 || used > maximum {
            return None;
        }
        buffer.truncate(used as usize);
        String::from_utf8(buffer).ok()
    }
}

/// Portable tables against CoreFoundation on this Mac: every scalar for the
/// three character sets, NFC and NFD, then every composition pair, every
/// table starter before every non-starter, and every ordered pair of
/// non-starters. A mismatch names the differing scalars as ranges, or the
/// differing sequences with both normalizations.
#[cfg(test)]
mod parity {
    use super::*;
    use crate::host_text::oracle_access::{COMBINING_CLASS, COMPOSITION, canonical_decomposition};
    use crate::host_whitespace_or_newline;
    use crate::{host_alphanumeric, host_canonical_text, host_control_character};

    /// A character-set membership test, portable or Foundation.
    type Predicate = fn(char) -> bool;

    fn hex(text: Option<&str>) -> String {
        text.map_or_else(
            || "None".to_owned(),
            |text| {
                text.chars()
                    .map(|c| format!("{:04X}", c as u32))
                    .collect::<Vec<_>>()
                    .join(" ")
            },
        )
    }

    /// Scalars as `start-end` ranges.
    fn ranges(scalars: &[u32]) -> String {
        let mut spans: Vec<(u32, u32)> = Vec::new();
        for &scalar in scalars {
            match spans.last_mut() {
                Some((_, end)) if *end + 1 == scalar => *end = scalar,
                _ => spans.push((scalar, scalar)),
            }
        }
        spans
            .iter()
            .map(|(start, end)| format!("{start:04X}-{end:04X}"))
            .collect::<Vec<_>>()
            .join(" ")
    }

    fn scalars() -> impl Iterator<Item = char> {
        (0..=0x10FFFF_u32).filter_map(char::from_u32)
    }

    fn non_starters() -> Vec<char> {
        COMBINING_CLASS
            .iter()
            .flat_map(|(start, end, _)| *start..=*end)
            .filter_map(char::from_u32)
            .collect()
    }

    /// A sequence whose NFC differs, with both answers.
    fn nfc_mismatch(text: &str) -> Option<String> {
        let portable = host_canonical_text(text);
        let foundation = normalize(text, 2);
        (portable != foundation).then(|| {
            format!(
                "[{}] portable [{}] foundation [{}]",
                hex(Some(text)),
                hex(portable.as_deref()),
                hex(foundation.as_deref())
            )
        })
    }

    fn report(name: &str, mismatches: &[String], total: usize) -> Option<String> {
        (!mismatches.is_empty()).then(|| {
            format!(
                "{name}: {} of {total} differ from CoreFoundation: {}",
                mismatches.len(),
                mismatches[..mismatches.len().min(300)].join("; ")
            )
        })
    }

    #[test]
    fn character_sets_match_corefoundation_for_every_scalar() {
        let sets: [(&str, Predicate, Predicate); 3] = [
            (
                "controlCharacters",
                host_control_character,
                control_character,
            ),
            ("alphanumerics", host_alphanumeric, alphanumeric),
            (
                "whitespacesAndNewlines",
                host_whitespace_or_newline,
                whitespace_or_newline,
            ),
        ];
        let mut failures = Vec::new();
        for (name, portable, foundation) in sets {
            for member in [true, false] {
                let differing: Vec<u32> = scalars()
                    .filter(|scalar| portable(*scalar) == member && foundation(*scalar) != member)
                    .map(|scalar| scalar as u32)
                    .collect();
                if !differing.is_empty() {
                    failures.push(format!(
                        "{name}: {} scalars portable={member} foundation={}: {}",
                        differing.len(),
                        !member,
                        ranges(&differing)
                    ));
                }
            }
        }
        assert!(
            failures.is_empty(),
            "{}",
            failures.join(
                "
"
            )
        );
    }

    #[test]
    fn normalization_matches_corefoundation_for_every_scalar() {
        let mut nfc = Vec::new();
        let mut nfd = Vec::new();
        for scalar in scalars() {
            let text = scalar.to_string();
            nfc.extend(nfc_mismatch(&text));
            let portable = canonical_decomposition(&text);
            let foundation = normalize(&text, 0);
            if Some(portable.as_str()) != foundation.as_deref() {
                nfd.push(format!(
                    "[{}] portable [{}] foundation [{}]",
                    hex(Some(&text)),
                    hex(Some(&portable)),
                    hex(foundation.as_deref())
                ));
            }
        }
        let failures: Vec<String> = [
            report("NFC of one scalar", &nfc, 0x110000 - 0x800),
            report("NFD of one scalar", &nfd, 0x110000 - 0x800),
        ]
        .into_iter()
        .flatten()
        .collect();
        assert!(
            failures.is_empty(),
            "{}",
            failures.join(
                "
"
            )
        );
    }

    #[test]
    fn composition_and_reordering_match_corefoundation() {
        let marks = non_starters();
        let mut firsts: Vec<u32> = COMPOSITION.iter().map(|(first, _, _)| *first).collect();
        firsts.dedup();
        let mut seconds: Vec<char> = COMPOSITION
            .iter()
            .filter_map(|(_, second, _)| char::from_u32(*second))
            .chain(marks.iter().copied())
            .collect();
        seconds.sort_unstable();
        seconds.dedup();
        let mut failures = Vec::new();
        let mut pairs = Vec::new();
        let mut total = 0;
        for first in firsts.iter().filter_map(|first| char::from_u32(*first)) {
            for second in &seconds {
                total += 1;
                pairs.extend(nfc_mismatch(&format!("{first}{second}")));
            }
        }
        failures.extend(report("NFC of starter + second", &pairs, total));
        // Hangul: every leading consonant with every vowel, and every LV
        // syllable with every trailing consonant, plus the out-of-range T.
        let mut hangul = Vec::new();
        total = 0;
        for l in 0x1100..0x1113 {
            for v in 0x1161..0x1176 {
                total += 1;
                let text: String = [l, v].into_iter().filter_map(char::from_u32).collect();
                hangul.extend(nfc_mismatch(&text));
            }
        }
        for lv in (0xAC00..0xD7A4).step_by(28) {
            for t in 0x11A7..0x11C3 {
                total += 1;
                let text: String = [lv, t].into_iter().filter_map(char::from_u32).collect();
                hangul.extend(nfc_mismatch(&text));
            }
        }
        failures.extend(report("NFC of Hangul jamo sequences", &hangul, total));
        let mut reordered = Vec::new();
        total = 0;
        for first in &marks {
            for second in &marks {
                total += 1;
                reordered.extend(nfc_mismatch(&format!("a{first}{second}")));
            }
        }
        failures.extend(report("NFC of a + two non-starters", &reordered, total));
        // The recorded CoreFoundation rules around starters joining starters
        // and the leading byte order mark, across input characters.
        let probes: Vec<String> = [
            &[0x1100, 0x1161, 0x11A8][..],
            &[0x1100, 0xAC00],
            &[0xAC01, 0x0301],
            &[0xAC00, 0x0301, 0x11A8],
            &[0x0CC6, 0x0CC2, 0x0CD5],
            &[0x0CC6, 0x0CD5],
            &[0x0CCA, 0x0CD5],
            &[0x0CCB, 0x0CD5],
            &[0x0DD9, 0x0DCF, 0x0DCA],
            &[0x0DDC, 0x0DCA],
            &[0x0B47, 0x0B3E, 0x0B57],
            &[0x0B47, 0x0B57],
            &[0x09C7, 0x09BE],
            &[0x1025, 0x102E],
            &[0x11131, 0x11127],
            &[0xFEFF],
            &[0xFEFF, 0xFEFF],
            &[0xFEFF, 0x0065, 0x0301],
            &[0x0061, 0xFEFF],
            &[0x0061, 0xFEFF, 0x0301],
            &[0x0065, 0x0301, 0xFEFF],
        ]
        .iter()
        .map(|scalars| scalars.iter().filter_map(|s| char::from_u32(*s)).collect())
        .collect();
        let probed: Vec<String> = probes
            .iter()
            .filter_map(|text| nfc_mismatch(text))
            .collect();
        failures.extend(report("NFC of recorded-rule probes", &probed, probes.len()));
        assert!(
            failures.is_empty(),
            "{}",
            failures.join(
                "
"
            )
        );
    }
}
