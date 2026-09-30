//! The bootstrap registries use Foundation's legacy ISO8601DateFormatter.
//! Keep this separate from Session's calendar and the newer ISO8601FormatStyle.
//!
//! Foundation's formatter (`CFDateFormatterCreateISO8601Formatter` with the
//! internet date-time options) writes `yyyy-MM-dd'T'HH:mm:ssXXXXX`: a
//! four-digit year, two-digit fields and either `Z` or `+hh:mm`/`-hh:mm`.
//! This portable check accepts exactly that written shape and, within it,
//! agrees with the formatter's parse on every field value, as recorded
//! against Foundation on macOS (PR #2336): any four-digit year including
//! 0000, months 01 to 12, days 01 to 31 in every month (the parse carries
//! 2026-02-31 over rather than refusing it), hours 00 to 24, minutes and
//! seconds 00 to 59, and any two-digit offset fields, which the formatter
//! reads without a range check.
//!
//! The ICU parser behind Foundation also takes spellings the formatter never
//! writes (one-digit or over-long fields, other decimal digit scripts,
//! leading white space and bidi marks, `z`, `GMT`/`UTC` zones, basic-format
//! and seconds offsets, and any text after the zone). This check refuses
//! them: a registry holding one fails closed as invalid instead of being read
//! the way one ICU version happens to. The macOS tests compare both answers
//! (`host_date_formatter_foundation.rs`).

/// `None` indicates allocation failure; `Some(false)` is a formatter refusal.
/// This portable form always answers.
pub fn host_legacy_iso8601(value: &str) -> Option<bool> {
    Some(accepted(value.as_bytes()))
}

fn number(bytes: &[u8]) -> Option<i64> {
    bytes.iter().try_fold(0_i64, |value, byte| {
        byte.is_ascii_digit()
            .then(|| value * 10 + i64::from(byte - b'0'))
    })
}

fn accepted(bytes: &[u8]) -> bool {
    let zone = match bytes.len() {
        20 => bytes[19] == b'Z',
        25 => {
            matches!(bytes[19], b'+' | b'-')
                && bytes[22] == b':'
                && number(&bytes[20..22]).is_some()
                && number(&bytes[23..25]).is_some()
        }
        _ => false,
    };
    if !zone
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
    {
        return false;
    }
    let field = |at: usize, width: usize| number(&bytes[at..at + width]);
    let (Some(_year), Some(month), Some(day), Some(hour), Some(minute), Some(second)) = (
        field(0, 4),
        field(5, 2),
        field(8, 2),
        field(11, 2),
        field(14, 2),
        field(17, 2),
    ) else {
        return false;
    };
    (1..=12).contains(&month)
        && (1..=31).contains(&day)
        && hour <= 24
        && minute <= 59
        && second <= 59
}

#[cfg(test)]
mod tests {
    use super::*;

    fn accepts(value: &str) -> bool {
        host_legacy_iso8601(value) == Some(true)
    }

    #[test]
    fn accepts_the_written_internet_date_time_shape() {
        for value in [
            "2026-09-11T00:00:00Z",
            "2026-09-11T00:00:00+05:30",
            "2026-09-11T00:00:00-00:00",
            "2026-09-11T23:59:59+99:99",
            "0000-01-01T00:00:00Z",
            "0001-01-01T00:00:00Z",
            "9999-12-31T23:59:59Z",
            "2024-02-29T12:34:56Z",
            "2026-02-31T00:00:00Z",
            "2026-09-11T24:00:00Z",
            "1582-10-10T00:00:00Z",
        ] {
            assert!(accepts(value), "{value}");
        }
    }

    #[test]
    fn refuses_invalid_fields_and_other_spellings() {
        for value in [
            "",
            "2026-09-11T00:00:00",
            "2026-00-11T00:00:00Z",
            "2026-13-11T00:00:00Z",
            "2026-09-32T00:00:00Z",
            "2026-09-00T00:00:00Z",
            "2026-09-11T25:00:00Z",
            "2026-09-11T23:60:00Z",
            "2026-09-11T23:59:60Z",
            "2026-09-11t00:00:00Z",
            "2026-09-11 00:00:00Z",
            "2026-09-11T00:00:00z",
            "2026-09-11T00:00:00.5Z",
            "2026-09-11T00:00:00+0530",
            "2026-09-11T00:00:00+05:30:15",
            "2026-09-11T00:00:00UTC",
            "2026-09-11T00:00:00Zjunk",
            " 2026-09-11T00:00:00Z",
            "2026-9-11T00:00:00Z",
            "12026-09-11T00:00:00Z",
            "+2026-09-11T00:00:00Z",
            "2026-09-11T00:00:00+\u{0665}5:30",
            "\u{0662}\u{0660}\u{0662}\u{0666}-09-11T00:00:00Z",
        ] {
            assert!(!accepts(value), "{value:?}");
        }
    }
}
