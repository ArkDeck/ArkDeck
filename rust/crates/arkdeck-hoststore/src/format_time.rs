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
}
