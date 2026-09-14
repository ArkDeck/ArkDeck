//! Acceptance predicate for the pinned macOS ISO8601Timestamps.parse reader.
//! This is Date.ISO8601FormatStyle (Swift 6.2), not ISO8601DateFormatter or the
//! stricter Session timestamp validator. Dates are retained in their original
//! spelling; the Artifact discovery owner also uses their comparison time.
//!
//! Upstream reference: swiftlang/swift-foundation, swift-6.2-RELEASE,
//! DateComponents+ISO8601FormatStyle.swift and Calendar_Gregorian.swift.
//! Actual Swift store comparisons pin platform behavior, including permissive
//! component normalization and trailing text. Newer upstream parsing differs.

// Keep the acceptance predicate independent of calendar conversion. Existing
// History/display-name callers continue to use exactly the same parser domain.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
struct ParsedTimestamp {
    year: i32,
    month: i32,
    seconds_in_month: i64,
    nanoseconds: u32,
}

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl Reader<'_> {
    fn take(&mut self, byte: u8) -> bool {
        if self.bytes.get(self.offset) != Some(&byte) {
            return false;
        }
        self.offset += 1;
        true
    }

    fn expect(&mut self, byte: u8) -> Option<()> {
        self.take(byte).then_some(())
    }

    fn digits(&mut self, maximum: usize) -> Option<u64> {
        let start = self.offset;
        let mut value = 0;
        while self.offset - start < maximum {
            let Some(digit) = self.bytes.get(self.offset).filter(|d| d.is_ascii_digit()) else {
                break;
            };
            value = value * 10 + u64::from(digit - b'0');
            self.offset += 1;
        }
        (self.offset != start).then_some(value)
    }

    fn timezone(&mut self) -> Option<i32> {
        if self.take(b'Z') || self.take(b'z') {
            return Some(0);
        }
        if self
            .bytes
            .get(self.offset..self.offset + 3)
            .is_some_and(|v| v.eq_ignore_ascii_case(b"GMT") || v.eq_ignore_ascii_case(b"UTC"))
        {
            self.offset += 3;
            if !matches!(self.bytes.get(self.offset), Some(b'+' | b'-')) {
                return Some(0);
            }
        }
        let sign = if self.take(b'+') {
            1
        } else if self.take(b'-') {
            -1
        } else {
            return None;
        };
        let hours = self.digits(2)?;
        let mut seconds = hours * 3600;
        if self.take(b':') || self.bytes.get(self.offset).is_some_and(u8::is_ascii_digit) {
            seconds += self.digits(2)? * 60;
            self.take(b':');
            if self.bytes.get(self.offset).is_some_and(u8::is_ascii_digit) {
                seconds += self.digits(2)?;
            }
        }
        // TimeZone(secondsFromGMT:) accepts both endpoints. Individual offset
        // minutes/seconds are not range-checked by the pinned FormatStyle.
        (seconds <= 18 * 3600).then_some(seconds as i32 * sign)
    }

    fn parse(&mut self) -> Option<ParsedTimestamp> {
        let year = self.digits(10)?;
        self.expect(b'-')?;
        let month = self.digits(10)?;
        self.expect(b'-')?;
        let day = self.digits(10)?;
        self.expect(b'T')?;
        let hour = self.digits(10)?;
        self.expect(b':')?;
        let minute = self.digits(10)?;
        self.expect(b':')?;
        let second = self.digits(10)?;
        let mut nanoseconds = 0;
        if self.take(b'.') {
            let start = self.offset;
            let fraction = self.digits(10)?;
            let digits = self.offset - start;
            if digits > 9 {
                return None;
            }
            nanoseconds = fraction as u32 * 10_u32.pow(9 - digits as u32);
        }
        // FormatStyle checks the calendar's maximum month/day ranges, then
        // CalendarGregorian checks supported component sizes. It normalizes
        // dates such as February 31 and times such as 24:00:01 or second 61.
        if year > 506_714
            || !(1..=12).contains(&month)
            || !(1..=31).contains(&day)
            || [hour, minute, second].iter().any(|v| *v > i32::MAX as u64)
        {
            return None;
        }
        // The public parse method discards the consumed end index.
        let zone = self.timezone()?;
        Some(ParsedTimestamp {
            year: year as i32,
            month: month as i32,
            seconds_in_month: ((day - 1) * 86400 + hour * 3600 + minute * 60 + second) as i64
                - i64::from(zone),
            nanoseconds,
        })
    }
}

pub(crate) fn valid_format_timestamp(value: &str) -> bool {
    Reader {
        bytes: value.as_bytes(),
        offset: 0,
    }
    .parse()
    .is_some()
}

/// Date comparison value for Artifact discovery using the already-pinned
/// FormatStyle parser and the existing platform Gregorian calendar primitive.
#[cfg(target_os = "macos")]
pub(crate) fn format_timestamp_seconds(value: &str) -> Option<f64> {
    let parsed = Reader {
        bytes: value.as_bytes(),
        offset: 0,
    }
    .parse()?;
    // Start from day 1 so the parser's existing normalization (e.g. February
    // 31, 24:00) is not narrowed by Session's valid-day check in the primitive.
    let month = arkdeck_platform::host_gregorian_seconds(parsed.year, parsed.month, 1, 0, 0, 0)?;
    let seconds =
        month + parsed.seconds_in_month as f64 + f64::from(parsed.nanoseconds) / 1_000_000_000.0;
    seconds.is_finite().then_some(seconds)
}

#[cfg(all(test, target_os = "macos"))]
mod artifact_date_tests {
    use super::*;
    #[test]
    fn artifact_comparison_matches_swift_formatstyle_reference_values() {
        // Observed via the actual fractional.parse ?? plain.parse entry point
        // on the pinned macOS Swift toolchain, not a second Rust parser.
        for (value, bits) in [
            ("2026-09-11T01:00:00+02:00", 4_740_084_473_628_983_296),
            ("2026-09-11T00:00:00Z", 4_740_084_503_827_972_096),
            ("2026-09-11T00:00:00.09Z", 4_740_084_503_828_727_071),
            ("2026-09-11T00:00:00.1Z", 4_740_084_503_828_810_957),
            (
                "2026-09-11T08:00:00.100000000+08:00",
                4_740_084_503_828_810_957,
            ),
            ("2026-09-10T19:00:00.100-05:00", 4_740_084_503_828_810_957),
            ("2026-09-11T00:00:00.11Z", 4_740_084_503_828_894_843),
            ("2026-09-10T23:30:00-01:00", 4_740_084_518_927_466_496),
        ] {
            assert_eq!(
                format_timestamp_seconds(value).unwrap().to_bits(),
                bits,
                "{value}"
            );
        }
    }
    #[test]
    fn existing_format_acceptance_remains_independent_of_comparison_conversion() {
        for value in [
            "2026-02-31T24:00:01Z",
            "2026-09-11T00:00:00UTC",
            "2026-09-11T00:00:00.123456789Ztail",
        ] {
            assert!(valid_format_timestamp(value));
            assert!(format_timestamp_seconds(value).is_some());
        }
        for value in [
            "not-a-date",
            "2026-09-11T00:00:00.1234567890Z",
            "2026-09-11T00:00:00+19:00",
        ] {
            assert!(!valid_format_timestamp(value));
            assert!(format_timestamp_seconds(value).is_none());
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn utc_timestamps_are_the_plain_iso8601_form() {
        assert_eq!(utc_timestamp(0), "1970-01-01T00:00:00Z");
        assert_eq!(utc_timestamp(1_709_210_096), "2024-02-29T12:34:56Z");
        assert_eq!(utc_timestamp(1_789_344_000), "2026-09-14T00:00:00Z");
        assert!(valid_format_timestamp(&utc_now().unwrap()));
    }

    #[test]
    fn precise_timestamps_truncate_to_milliseconds() {
        // Swift `ISO8601Timestamps.string(from:includingFractionalSeconds:)`
        // on the pinned toolchain: .1239 s spells .123, .9999 s spells .999.
        assert_eq!(
            utc_precise_timestamp(1_789_344_000, 0),
            "2026-09-14T00:00:00.000Z"
        );
        assert_eq!(
            utc_precise_timestamp(1_789_344_000, 123),
            "2026-09-14T00:00:00.123Z"
        );
        assert!(valid_format_timestamp(&utc_precise_now().unwrap()));
    }
}

/// The current instant as Swift's precise Runtime clock spells it
/// (`ISO8601Timestamps.string(includingFractionalSeconds: true)`): UTC with
/// milliseconds, truncated.
#[cfg(target_os = "macos")]
pub(crate) fn utc_precise_now() -> Option<String> {
    let elapsed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?;
    Some(utc_precise_timestamp(
        elapsed.as_secs(),
        elapsed.subsec_millis(),
    ))
}

/// Unix seconds of a canonical plain UTC timestamp (`utc_timestamp`'s own
/// spelling, which the Runtime clock produces); any other spelling is none.
#[cfg(target_os = "macos")]
pub(crate) fn plain_utc_seconds(text: &str) -> Option<u64> {
    let bytes = text.as_bytes();
    if bytes.len() != 20 || !text.is_ascii() {
        return None;
    }
    let number = |range: std::ops::Range<usize>| text.get(range)?.parse::<i64>().ok();
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    // Hinnant's `days_from_civil`.
    let shifted = if month <= 2 { year - 1 } else { year };
    let era = shifted.div_euclid(400);
    let year_of_era = shifted - era * 400;
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    let seconds = u64::try_from(days * 86_400 + hour * 3_600 + minute * 60 + second).ok()?;
    (utc_timestamp(seconds) == text).then_some(seconds)
}

#[cfg(target_os = "macos")]
fn utc_precise_timestamp(seconds: u64, milliseconds: u32) -> String {
    let plain = utc_timestamp(seconds);
    format!("{}.{milliseconds:03}Z", &plain[..plain.len() - 1])
}

/// The current instant as Swift durable records spell it
/// (`ISO8601Timestamps.string`): whole seconds in UTC.
#[cfg(target_os = "macos")]
pub(crate) fn utc_now() -> Option<String> {
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    Some(utc_timestamp(seconds))
}

/// Unix seconds as `YYYY-MM-DDTHH:MM:SSZ` in the proleptic Gregorian calendar
/// (Hinnant's `civil_from_days`).
#[cfg(target_os = "macos")]
pub(crate) fn utc_timestamp(seconds: u64) -> String {
    let days = (seconds / 86_400) as i64 + 719_468;
    let era = days.div_euclid(146_097);
    let day_of_era = days.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * shifted_month + 2) / 5 + 1;
    let month = if shifted_month < 10 {
        shifted_month + 3
    } else {
        shifted_month - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    let second = seconds % 86_400;
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        second / 3_600,
        second % 3_600 / 60,
        second % 60
    )
}
