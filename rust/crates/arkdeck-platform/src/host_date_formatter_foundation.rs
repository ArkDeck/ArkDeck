//! Foundation's legacy ISO8601DateFormatter that `host_date_formatter`
//! replaced, kept as the macOS parity oracle. Test builds on macOS only.
use std::ffi::c_void;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithBytes(
        allocator: *const c_void,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external: u8,
    ) -> *const c_void;
    fn CFDateFormatterCreateISO8601Formatter(
        allocator: *const c_void,
        options: usize,
    ) -> *const c_void;
    fn CFDateFormatterCreateDateFromString(
        allocator: *const c_void,
        formatter: *const c_void,
        value: *const c_void,
        range: *mut c_void,
    ) -> *const c_void;
    fn CFRelease(value: *const c_void);
}

struct Owned(*const c_void);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: this wrapper exclusively owns a nonnull create-rule object.
        unsafe { CFRelease(self.0) };
    }
}

/// `None` indicates allocation failure; `Some(false)` is a formatter refusal.
pub(crate) fn parse(value: &str) -> Option<bool> {
    let length = isize::try_from(value.len()).ok()?;
    // Public CFDateFormatter.h: WithInternetDateTime = FullDate | FullTime.
    let options =
        (1 << 0) | (1 << 1) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10);
    // SAFETY: UTF-8 buffer is valid for length bytes, with the standard UTF-8
    // encoding constant. Created objects stay alive throughout the parse.
    unsafe {
        let text = CFStringCreateWithBytes(std::ptr::null(), value.as_ptr(), length, 0x08000100, 0);
        if text.is_null() {
            return None;
        }
        let text = Owned(text);
        let formatter = CFDateFormatterCreateISO8601Formatter(std::ptr::null(), options);
        if formatter.is_null() {
            return None;
        }
        let formatter = Owned(formatter);
        let date = CFDateFormatterCreateDateFromString(
            std::ptr::null(),
            formatter.0,
            text.0,
            std::ptr::null_mut(),
        );
        if date.is_null() {
            return Some(false);
        }
        let _date = Owned(date);
        Some(true)
    }
}

/// The portable check against Foundation's formatter on this Mac. Within the
/// written shape (`yyyy-MM-dd'T'HH:mm:ss` and `Z` or `±hh:mm`) both answer
/// alike for every field value tried; across every string tried, including
/// the spellings only ICU's parser takes, the portable check accepts nothing
/// Foundation refuses.
#[cfg(test)]
mod parity {
    use crate::host_legacy_iso8601;

    fn in_shape() -> Vec<String> {
        let mut values = Vec::new();
        for year in [
            0, 1, 99, 1500, 1580, 1582, 1600, 1700, 1900, 2000, 2024, 2026, 9999,
        ] {
            for month in 0..=13 {
                for day in 0..=32 {
                    values.push(format!("{year:04}-{month:02}-{day:02}T00:00:00Z"));
                }
            }
        }
        for value in 0..=99 {
            values.push(format!("2026-09-11T{value:02}:00:00Z"));
            values.push(format!("2026-09-11T00:{value:02}:00Z"));
            values.push(format!("2026-09-11T00:00:{value:02}Z"));
            for minute in [0, 30, 59, 60, 99] {
                values.push(format!("2026-09-11T00:00:00+{value:02}:{minute:02}"));
                values.push(format!("2026-09-11T00:00:00-{value:02}:{minute:02}"));
            }
        }
        values
    }

    fn other_spellings() -> Vec<String> {
        let base = "2026-09-11T00:00:00Z";
        let mut values: Vec<String> = [
            "",
            "2026-09-11T00:00:00",
            "2026-09-11T00:00:00z",
            "2026-09-11T00:00:00.5Z",
            "2026-09-11t00:00:00Z",
            "2026-09-11 00:00:00Z",
            "2026-9-11T00:00:00Z",
            "2026-09-1T00:00:00Z",
            "2026-09-11T0:00:00Z",
            "026-09-11T00:00:00Z",
            "12026-09-11T00:00:00Z",
            "002026-09-11T00:00:00Z",
            "-2026-09-11T00:00:00Z",
            "+2026-09-11T00:00:00Z",
            "2026-09-11T00:00:00+0530",
            "2026-09-11T00:00:00+05",
            "2026-09-11T00:00:00+5:30",
            "2026-09-11T00:00:00+05:30:15",
            "2026-09-11T00:00:00+24:00",
            "2026-09-11T00:00:00Zjunk",
            "2026-09-11T00:00:00Z ",
            " 2026-09-11T00:00:00Z",
            "2026-09-11T00:00:00 Z",
            "2026-09-11T00:00:00UTC",
            "2026-09-11T00:00:00GMT",
            "2026-09-11T00:00:00UT",
            "2026-09-11T00:00:00GMT+05:00",
            "2026-09-11T00:00:00EST",
            "2026-09-11T00:00:00+05:30Z",
            "2026-09-11T00:00:00+05:30junk",
            "2026-09-11T00:00:00+",
            "2026-09-11T00:00:00\u{2212}05:00",
            "2026-09-11T00:00:00\u{a0}Z",
            "\u{200e}2026-09-11T00:00:00Z",
            "2026-09-11T00:00:00\u{221e}Z",
            "\u{0662}\u{0660}\u{0662}\u{0666}-09-11T00:00:00Z",
            "\u{ff12}\u{ff10}\u{ff12}\u{ff16}-09-11T00:00:00Z",
            "2026-09-11T00:00:00\u{ff3a}",
            "2026-4294967305-11T00:00:00Z",
            "99999-12-31T23:59:59Z",
            "5828963-12-31T23:59:59Z",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
        for position in 0..base.len() {
            for byte in 0x20_u8..0x7F {
                let mut value = base.as_bytes().to_vec();
                value[position] = byte;
                values.push(String::from_utf8(value).unwrap());
            }
        }
        values
    }

    #[test]
    fn written_shape_matches_foundation_for_every_field_value() {
        let values = in_shape();
        let mismatches: Vec<String> = values
            .iter()
            .filter(|value| host_legacy_iso8601(value) != super::parse(value))
            .map(|value| format!("{value} foundation={:?}", super::parse(value)))
            .collect();
        assert!(
            mismatches.is_empty(),
            "{} of {} differ from Foundation; first: {:?}",
            mismatches.len(),
            values.len(),
            &mismatches[..mismatches.len().min(1000)]
        );
    }

    #[test]
    fn portable_check_accepts_nothing_foundation_refuses() {
        let values: Vec<String> = in_shape().into_iter().chain(other_spellings()).collect();
        let widened: Vec<&String> = values
            .iter()
            .filter(|value| host_legacy_iso8601(value) == Some(true))
            .filter(|value| super::parse(value) != Some(true))
            .collect();
        assert!(
            widened.is_empty(),
            "accepted but refused by Foundation: {widened:?}"
        );
        let narrowed = values
            .iter()
            .filter(|value| host_legacy_iso8601(value) != Some(true))
            .filter(|value| super::parse(value) == Some(true))
            .count();
        eprintln!(
            "{narrowed} of {} spellings outside the written shape are refused here but parsed by Foundation",
            values.len()
        );
    }
}
