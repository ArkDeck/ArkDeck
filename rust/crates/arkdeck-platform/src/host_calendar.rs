//! Foundation's Gregorian calendar in UTC, as portable arithmetic.
//!
//! The Session store's frozen dates were read and written through
//! `CFCalendar` with the Gregorian identifier and a zero-offset zone. That
//! calendar is Julian before 1582-10-15 (Julian day 2,299,161) and Gregorian
//! from then on, and its year component is the year of the era, so a date in
//! 1 BC decomposes as year 1. These functions reproduce that arithmetic on
//! every host with no calendar, locale or time-zone database. On macOS the
//! tests compare them with CoreFoundation itself
//! (`host_calendar_foundation.rs`) across the cutover, the eras, leap days and
//! fractional instants.

/// Julian day number of the Foundation reference date, 2001-01-01.
const REFERENCE_DAY: i64 = 2_451_911;
/// Julian day number of 1582-10-15, the first Gregorian day.
const GREGORIAN_START: i64 = 2_299_161;
const DAY: i64 = 86_400;
/// Far beyond year 9999 of either era; keeps the day arithmetic in range.
const LIMIT: f64 = 1.0e15;
/// Julian day 0.0, noon of 4713-01-01 BC (Julian): Foundation's calendar
/// reads any earlier instant as this one.
const EARLIEST: f64 = -211_845_067_200.0;

fn gregorian_day(year: i64, month: i64, day: i64) -> i64 {
    let a = (14 - month) / 12;
    let y = year + 4800 - a;
    let m = month + 12 * a - 3;
    day + (153 * m + 2) / 5 + 365 * y + y.div_euclid(4) - y.div_euclid(100) + y.div_euclid(400)
        - 32_045
}

fn julian_day(year: i64, month: i64, day: i64) -> i64 {
    let a = (14 - month) / 12;
    let y = year + 4800 - a;
    let m = month + 12 * a - 3;
    day + (153 * m + 2) / 5 + 365 * y + y.div_euclid(4) - 32_083
}

/// (astronomical year, month, day) of a Julian day number.
fn civil(day_number: i64) -> (i64, i64, i64) {
    let (b, c) = if day_number >= GREGORIAN_START {
        let a = day_number + 32_044;
        let b = (4 * a + 3).div_euclid(146_097);
        (b, a - (146_097 * b).div_euclid(4))
    } else {
        (0, day_number + 32_082)
    };
    let d = (4 * c + 3).div_euclid(1461);
    let e = c - (1461 * d).div_euclid(4);
    let m = (5 * e + 2) / 153;
    let day = e - (153 * m + 2) / 5 + 1;
    let month = m + 3 - 12 * (m / 10);
    let year = 100 * b + d - 4800 + m / 10;
    (year, month, day)
}

fn leap(year: i64) -> bool {
    if year < 1582 {
        year.rem_euclid(4) == 0
    } else {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }
}

pub(crate) fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if leap(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Year of the era, month, day, hour, minute and second of whole seconds
/// from the reference date.
fn decompose(whole: f64) -> Option<(i64, i64, i64, i64, i64, i64)> {
    if !whole.is_finite() || whole > LIMIT {
        return None;
    }
    // Foundation reads negative zero as the second before the reference date.
    let seconds = if whole == 0.0 && whole.is_sign_negative() {
        -1
    } else {
        whole.max(EARLIEST) as i64
    };
    let (year, month, day) = civil(REFERENCE_DAY + seconds.div_euclid(DAY));
    let time = seconds.rem_euclid(DAY);
    let year_of_era = if year >= 1 { year } else { 1 - year };
    Some((
        year_of_era,
        month,
        day,
        time / 3600,
        time / 60 % 60,
        time % 60,
    ))
}

/// Whole seconds and the nanoseconds the retention spelling keeps, carrying a
/// fraction that rounds to a whole second into the seconds.
fn split(at: f64) -> (f64, u32) {
    let mut whole = at.floor();
    let mut nanos = ((at - whole) * 1_000_000_000.0).round() as u32;
    if nanos == 1_000_000_000 {
        whole += 1.0;
        nanos = 0;
    }
    (whole, nanos)
}

/// Current Session retention timestamps preserve nanoseconds from the
/// Foundation epoch, including dates before 2001.
pub fn host_gregorian_timestamp(at: f64) -> Option<String> {
    if !at.is_finite() {
        return None;
    }
    let (whole, nanos) = split(at);
    let (year, month, day, hour, minute, second) = decompose(whole)?;
    if !(1..=9999).contains(&year) {
        return None;
    }
    Some(format!(
        "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{nanos:09}Z"
    ))
}

/// Returns seconds from the Foundation reference epoch, after the current
/// Gregorian calendar's month range check. Callers validate numeric fields:
/// the year is of the current era (year 0 is 1 BC, as Foundation reads it),
/// and a month outside 1...12 is refused.
pub fn host_gregorian_seconds(
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
) -> Option<f64> {
    let (year, month, day) = (i64::from(year), i64::from(month), i64::from(day));
    if !(1..=12).contains(&month) || !(1..=days_in_month(year, month)).contains(&day) {
        return None;
    }
    let day_number = if (year, month, day) < (1582, 10, 15) {
        julian_day(year, month, day)
    } else {
        gregorian_day(year, month, day)
    };
    let seconds = (day_number - REFERENCE_DAY) * DAY
        + i64::from(hour) * 3600
        + i64::from(minute) * 60
        + i64::from(second);
    Some(seconds as f64)
}

/// The current retention catalog adds Gregorian days in UTC and rejects dates
/// that its four-digit-year formatter cannot publish.
pub fn host_gregorian_add_days(at: f64, days: i32) -> Option<f64> {
    if !at.is_finite() || days <= 0 {
        return None;
    }
    // A UTC day is always 86,400 seconds; Foundation starts no earlier than
    // Julian day 0 and then drops the fraction.
    let result = at.max(EARLIEST) + f64::from(days) * DAY as f64;
    if !result.is_finite() {
        return None;
    }
    let (whole, _) = split(result);
    let (year, ..) = decompose(whole)?;
    (1..=9999).contains(&year).then_some(result)
}

#[cfg(test)]
mod timestamp_tests {
    use super::*;
    #[test]
    fn retention_timestamp_keeps_fraction_before_epoch_and_handles_rounding_carry() {
        assert_eq!(
            host_gregorian_timestamp(-0.125).as_deref(),
            Some("2000-12-31T23:59:59.875000000Z")
        );
        assert_eq!(
            host_gregorian_timestamp(0.999_999_999_8).as_deref(),
            Some("2001-01-01T00:00:01.000000000Z")
        );
        let at = host_gregorian_seconds(2026, 7, 17, 8, 0, 0).unwrap();
        assert_eq!(
            host_gregorian_timestamp(host_gregorian_add_days(at, 30).unwrap()).as_deref(),
            Some("2026-08-16T08:00:00.000000000Z")
        );
        assert!(host_gregorian_timestamp(f64::NAN).is_none());
    }

    #[test]
    fn calendar_is_julian_before_the_gregorian_start_and_counts_eras() {
        let at = |y, m, d| host_gregorian_seconds(y, m, d, 0, 0, 0).unwrap();
        let text = |at| host_gregorian_timestamp(at).unwrap();
        // The day after Julian 1582-10-04 is Gregorian 1582-10-15.
        assert_eq!(at(1582, 10, 15) - at(1582, 10, 4), 86_400.0);
        assert_eq!(text(at(1582, 10, 4)), "1582-10-04T00:00:00.000000000Z");
        assert_eq!(text(at(1582, 10, 15)), "1582-10-15T00:00:00.000000000Z");
        // The ten skipped days are read as Julian dates.
        assert_eq!(at(1582, 10, 10), at(1582, 10, 20));
        // Julian leap years before the cutover; Gregorian ones after it.
        assert!(host_gregorian_seconds(1500, 2, 29, 0, 0, 0).is_some());
        assert!(host_gregorian_seconds(1700, 2, 29, 0, 0, 0).is_none());
        assert!(host_gregorian_seconds(2000, 2, 29, 0, 0, 0).is_some());
        assert!(host_gregorian_seconds(2026, 2, 29, 0, 0, 0).is_none());
        assert!(host_gregorian_seconds(2026, 4, 31, 0, 0, 0).is_none());
        assert!(host_gregorian_seconds(2026, 4, 0, 0, 0, 0).is_none());
        assert!(host_gregorian_seconds(2026, 13, 1, 0, 0, 0).is_none());
        // Year 1 of the era, and the year before it spelled as year 1 BC.
        assert_eq!(at(1, 1, 1), -63_114_076_800.0);
        assert_eq!(text(at(1, 1, 1)), "0001-01-01T00:00:00.000000000Z");
        assert_eq!(text(at(1, 1, 1) - 1.0), "0001-12-31T23:59:59.000000000Z");
        assert_eq!(at(0, 12, 31) + 86_400.0, at(1, 1, 1));
        // Four-digit years only, in either era.
        assert_eq!(
            text(at(9999, 12, 31) + 86_399.5),
            "9999-12-31T23:59:59.500000000Z"
        );
        assert!(host_gregorian_timestamp(at(9999, 12, 31) + 86_400.0).is_none());
        assert!(host_gregorian_add_days(at(9999, 12, 1), 30).is_some());
        assert!(host_gregorian_add_days(at(9999, 12, 1), 31).is_none());
        assert!(host_gregorian_add_days(at(2026, 1, 1), 0).is_none());
        assert!(host_gregorian_timestamp(1.0e300).is_none());
        // Before Julian day 0 Foundation reads Julian day 0 (4713 BC), keeping
        // the fraction; negative zero is the second before the reference date.
        assert_eq!(
            host_gregorian_timestamp(-1.0e300).as_deref(),
            Some("4713-01-01T12:00:00.000000000Z")
        );
        assert_eq!(
            host_gregorian_timestamp(EARLIEST - 1_000.25).as_deref(),
            Some("4713-01-01T12:00:00.750000000Z")
        );
        assert_eq!(
            host_gregorian_add_days(EARLIEST - 1_000.25, 1),
            Some(EARLIEST + 86_400.0)
        );
        assert_eq!(
            host_gregorian_timestamp(-0.0).as_deref(),
            Some("2000-12-31T23:59:59.000000000Z")
        );
        // Unix epoch and a Gregorian leap day, as the Session fixtures spell them.
        assert_eq!(text(-978_307_200.0), "1970-01-01T00:00:00.000000000Z");
        assert_eq!(
            text(at(2024, 2, 29) + 45_296.25),
            "2024-02-29T12:34:56.250000000Z"
        );
    }
}
