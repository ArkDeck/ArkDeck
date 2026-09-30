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
/// non-starters. A mismatch lists the first scalars that differ.
#[cfg(test)]
mod parity {
    use super::*;
    use crate::host_text::oracle_access::{COMBINING_CLASS, COMPOSITION, canonical_decomposition};
    use crate::host_whitespace_or_newline;
    use crate::{host_alphanumeric, host_canonical_text, host_control_character};

    fn report(name: &str, mismatches: &[String], total: usize) {
        assert!(
            mismatches.is_empty(),
            "{name}: {} of {total} differ from CoreFoundation; first: {:?}",
            mismatches.len(),
            &mismatches[..mismatches.len().min(40)]
        );
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

    #[test]
    fn character_sets_match_corefoundation_for_every_scalar() {
        let sets: [(&str, fn(char) -> bool, fn(char) -> bool); 3] = [
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
        for (name, portable, foundation) in sets {
            let mismatches: Vec<String> = scalars()
                .filter(|scalar| portable(*scalar) != foundation(*scalar))
                .map(|scalar| format!("U+{:04X} portable={}", scalar as u32, portable(scalar)))
                .collect();
            report(name, &mismatches, 0x110000 - 0x800);
        }
    }

    #[test]
    fn normalization_matches_corefoundation_for_every_scalar() {
        let mut nfc = Vec::new();
        let mut nfd = Vec::new();
        for scalar in scalars() {
            let text = scalar.to_string();
            if host_canonical_text(&text) != normalize(&text, 2) {
                nfc.push(format!("U+{:04X}", scalar as u32));
            }
            if Some(canonical_decomposition(&text)) != normalize(&text, 0) {
                nfd.push(format!("U+{:04X}", scalar as u32));
            }
        }
        report("NFC of one scalar", &nfc, 0x110000 - 0x800);
        report("NFD of one scalar", &nfd, 0x110000 - 0x800);
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
        let mut mismatches = Vec::new();
        let mut total = 0;
        let mut check = |text: String| {
            total += 1;
            if host_canonical_text(&text) != normalize(&text, 2) {
                mismatches.push(
                    text.chars()
                        .map(|c| format!("{:04X}", c as u32))
                        .collect::<Vec<_>>()
                        .join(" "),
                );
            }
        };
        for first in firsts.iter().filter_map(|first| char::from_u32(*first)) {
            for second in &seconds {
                check(format!("{first}{second}"));
            }
        }
        // Hangul: every leading consonant with every vowel, and every LV
        // syllable with every trailing consonant, plus the out-of-range T.
        for l in 0x1100..0x1113 {
            for v in 0x1161..0x1176 {
                check([l, v].into_iter().filter_map(char::from_u32).collect());
            }
        }
        for lv in (0xAC00..0xD7A4).step_by(28) {
            for t in 0x11A7..0x11C3 {
                check([lv, t].into_iter().filter_map(char::from_u32).collect());
            }
        }
        for first in &marks {
            for second in &marks {
                check(format!("a{first}{second}"));
            }
        }
        report(
            "NFC of composition and reordering sequences",
            &mismatches,
            total,
        );
    }
}
