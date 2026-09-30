//! The CoreFoundation Gregorian calendar that `host_calendar` replaced, kept
//! as the macOS parity oracle for its portable arithmetic. Test builds on
//! macOS only; no Runtime path links it. Each call owns its calendar and UTC
//! zone and drains the Foundation objects it autoreleases.
use crate::autorelease_pool::AutoreleasePool;
use std::ffi::c_void;

#[repr(C)]
struct Range {
    location: isize,
    length: isize,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFGregorianCalendar: *const c_void;
    fn CFCalendarCreateWithIdentifier(
        allocator: *const c_void,
        identifier: *const c_void,
    ) -> *mut c_void;
    fn CFTimeZoneCreateWithTimeIntervalFromGMT(
        allocator: *const c_void,
        seconds: f64,
    ) -> *const c_void;
    fn CFCalendarSetTimeZone(calendar: *mut c_void, zone: *const c_void);
    fn CFCalendarComposeAbsoluteTime(
        calendar: *const c_void,
        at: *mut f64,
        description: *const i8,
        ...
    ) -> u8;
    fn CFCalendarGetRangeOfUnit(
        calendar: *const c_void,
        smaller: usize,
        bigger: usize,
        at: f64,
    ) -> Range;
    fn CFCalendarAddComponents(
        calendar: *const c_void,
        at: *mut f64,
        options: usize,
        description: *const i8,
        ...
    ) -> u8;
    fn CFCalendarDecomposeAbsoluteTime(
        calendar: *const c_void,
        at: f64,
        description: *const i8,
        ...
    ) -> u8;
    fn CFRelease(object: *const c_void);
}

struct Owned(*const c_void);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: nonnull create-rule object, exclusively owned by this guard.
        unsafe { CFRelease(self.0) };
    }
}

/// Current Session retention timestamps preserve nanoseconds from the
/// Foundation epoch, including dates before 2001.
pub(crate) fn timestamp(at: f64) -> Option<String> {
    if !at.is_finite() {
        return None;
    }
    let mut whole = at.floor();
    let mut nanos = ((at - whole) * 1_000_000_000.0).round() as u32;
    if nanos == 1_000_000_000 {
        whole += 1.0;
        nanos = 0;
    }
    let _pool = AutoreleasePool::push();
    // SAFETY: create-rule objects are owned locally; the six output pointers
    // match the y/M/d/H/m/s C-int descriptors and live through the call.
    unsafe {
        let calendar = CFCalendarCreateWithIdentifier(std::ptr::null(), kCFGregorianCalendar);
        if calendar.is_null() {
            return None;
        }
        let calendar = Owned(calendar);
        let zone = CFTimeZoneCreateWithTimeIntervalFromGMT(std::ptr::null(), 0.0);
        if zone.is_null() {
            return None;
        }
        let zone = Owned(zone);
        CFCalendarSetTimeZone(calendar.0.cast_mut(), zone.0);
        let (mut year, mut month, mut day, mut hour, mut minute, mut second) =
            (0_i32, 0_i32, 0_i32, 0_i32, 0_i32, 0_i32);
        if CFCalendarDecomposeAbsoluteTime(
            calendar.0,
            whole,
            c"yMdHms".as_ptr(),
            &mut year as *mut i32,
            &mut month as *mut i32,
            &mut day as *mut i32,
            &mut hour as *mut i32,
            &mut minute as *mut i32,
            &mut second as *mut i32,
        ) == 0
            || !(1..=9999).contains(&year)
        {
            return None;
        }
        Some(format!(
            "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{nanos:09}Z"
        ))
    }
}

/// Returns seconds from the Foundation reference epoch, after the current
/// Gregorian calendar's month range check. Callers validate numeric fields.
pub(crate) fn seconds(
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
) -> Option<f64> {
    let _pool = AutoreleasePool::push();
    // SAFETY: the calendar and zone follow create-rule ownership. All variadic
    // arguments match the documented y/M/d/H/m/s C-int component descriptors;
    // output pointers reference live initialized f64 values for each call.
    unsafe {
        let calendar = CFCalendarCreateWithIdentifier(std::ptr::null(), kCFGregorianCalendar);
        if calendar.is_null() {
            return None;
        }
        let calendar_owner = Owned(calendar);
        let zone = CFTimeZoneCreateWithTimeIntervalFromGMT(std::ptr::null(), 0.0);
        if zone.is_null() {
            return None;
        }
        let zone = Owned(zone);
        CFCalendarSetTimeZone(calendar, zone.0);
        let mut first = 0.0;
        if CFCalendarComposeAbsoluteTime(
            calendar_owner.0,
            &mut first,
            c"yMdHms".as_ptr(),
            year,
            month,
            1_i32,
            0_i32,
            0_i32,
            0_i32,
        ) == 0
        {
            return None;
        }
        let range = CFCalendarGetRangeOfUnit(calendar_owner.0, 1 << 4, 1 << 3, first);
        if range.location < 0
            || range.length < 0
            || !(range.location..range.location.checked_add(range.length)?)
                .contains(&(day as isize))
        {
            return None;
        }
        let mut seconds = 0.0;
        if CFCalendarComposeAbsoluteTime(
            calendar_owner.0,
            &mut seconds,
            c"yMdHms".as_ptr(),
            year,
            month,
            day,
            hour,
            minute,
            second,
        ) == 0
            || !seconds.is_finite()
        {
            return None;
        }
        Some(seconds)
    }
}

/// The current retention catalog adds Gregorian days in UTC and rejects dates
/// that its four-digit-year formatter cannot publish.
pub(crate) fn add_days(at: f64, days: i32) -> Option<f64> {
    if !at.is_finite() || days <= 0 {
        return None;
    }
    let _pool = AutoreleasePool::push();
    // SAFETY: create-rule objects are guarded; C varargs match d (int) and
    // y (int*) descriptors. No pointer escapes this function.
    unsafe {
        let calendar = CFCalendarCreateWithIdentifier(std::ptr::null(), kCFGregorianCalendar);
        if calendar.is_null() {
            return None;
        }
        let calendar = Owned(calendar);
        let zone = CFTimeZoneCreateWithTimeIntervalFromGMT(std::ptr::null(), 0.0);
        if zone.is_null() {
            return None;
        }
        let zone = Owned(zone);
        CFCalendarSetTimeZone(calendar.0.cast_mut(), zone.0);
        let mut result = at;
        if CFCalendarAddComponents(calendar.0, &mut result, 0, c"d".as_ptr(), days) == 0
            || !result.is_finite()
        {
            return None;
        }
        let mut whole = result.floor();
        if ((result - whole) * 1_000_000_000.0).round() == 1_000_000_000.0 {
            whole += 1.0;
        }
        let mut year = 0_i32;
        if CFCalendarDecomposeAbsoluteTime(calendar.0, whole, c"y".as_ptr(), &mut year as *mut i32)
            == 0
            || !(1..=9999).contains(&year)
        {
            return None;
        }
        Some(result)
    }
}

/// Portable arithmetic against CoreFoundation on this Mac: composition of
/// every month and edge day across the eras, the Julian cutover and the year
/// limits; decomposition at every day around the cutover and the era change,
/// at the four-digit-year limits and at seeded instants with fractions; and
/// day addition from seeded instants. A mismatch lists the first inputs.
#[cfg(test)]
mod parity {
    use crate::{host_gregorian_add_days, host_gregorian_seconds, host_gregorian_timestamp};

    fn report(name: &str, mismatches: &[String], total: usize) {
        assert!(
            mismatches.is_empty(),
            "{name}: {} of {total} differ from CoreFoundation; first: {:?}",
            mismatches.len(),
            &mismatches[..mismatches.len().min(40)]
        );
    }

    /// SplitMix64: a fixed, seeded sequence of instants.
    fn instants(count: usize, low: f64, high: f64) -> Vec<f64> {
        let mut state = 0x9E37_79B9_7F4A_7C15_u64;
        (0..count)
            .map(|_| {
                state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
                let mut z = state;
                z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
                z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
                z ^= z >> 31;
                low + (high - low) * ((z >> 11) as f64 / (1_u64 << 53) as f64)
            })
            .collect()
    }

    #[test]
    fn composition_matches_corefoundation() {
        let years = [
            0, 1, 2, 3, 4, 99, 100, 101, 399, 400, 401, 1000, 1499, 1500, 1581, 1582, 1583, 1600,
            1700, 1800, 1900, 1969, 1970, 2000, 2001, 2024, 2025, 2026, 2100, 2400, 9998, 9999,
            10_000, 506_714,
        ];
        let mut mismatches = Vec::new();
        let mut total = 0;
        for year in years {
            for month in 1..=12 {
                for day in [0, 1, 4, 5, 14, 15, 28, 29, 30, 31, 32] {
                    for (hour, minute, second) in [(0, 0, 0), (12, 34, 56), (23, 59, 59)] {
                        total += 1;
                        let portable =
                            host_gregorian_seconds(year, month, day, hour, minute, second);
                        let foundation = super::seconds(year, month, day, hour, minute, second);
                        if portable.map(f64::to_bits) != foundation.map(f64::to_bits) {
                            mismatches.push(format!(
                                "{year}-{month}-{day} {hour}:{minute}:{second} portable={portable:?} foundation={foundation:?}"
                            ));
                        }
                    }
                }
            }
        }
        for day in 1..=31 {
            total += 1;
            let portable = host_gregorian_seconds(1582, 10, day, 0, 0, 0);
            let foundation = super::seconds(1582, 10, day, 0, 0, 0);
            if portable.map(f64::to_bits) != foundation.map(f64::to_bits) {
                mismatches.push(format!(
                    "1582-10-{day} portable={portable:?} foundation={foundation:?}"
                ));
            }
        }
        report("host_gregorian_seconds", &mismatches, total);
    }

    #[test]
    fn decomposition_matches_corefoundation() {
        const DAY: f64 = 86_400.0;
        let cutover = -13_197_600_000.0; // 1582-10-15T00:00:00Z, checked below
        let year_one = -63_114_076_800.0;
        let mut samples = vec![
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
            0.0,
            -0.0,
            -0.125,
            0.999_999_999_8,
            0.5,
            1.0e-10,
            -1.0e-10,
            1.0e12,
            -1.0e12,
            1.0e13,
            -1.0e13,
            1.0e15,
            -1.0e15,
            1.0e16,
            -1.0e16,
            1.0e300,
            -1.0e300,
        ];
        for offset in -40..=40 {
            let at = cutover + f64::from(offset) * DAY;
            samples.extend([at, at - 0.5, at + 0.25]);
            let at = year_one + f64::from(offset) * DAY;
            samples.extend([at, at - 0.5, at + 0.25]);
        }
        for anchor in [
            host_gregorian_seconds(9999, 12, 31, 0, 0, 0).unwrap(),
            host_gregorian_seconds(1, 1, 1, 0, 0, 0).unwrap() - 9998.0 * 366.0 * DAY,
            host_gregorian_seconds(1, 1, 1, 0, 0, 0).unwrap() - 9999.0 * 365.25 * DAY,
        ] {
            for offset in -3..=3 {
                samples.push(anchor + f64::from(offset) * DAY - 0.5);
                samples.push(anchor + f64::from(offset) * DAY);
            }
        }
        samples.extend(instants(20_000, -3.2e11, 2.6e11));
        samples.extend(instants(2_000, -1.0e3, 1.0e3));
        let mismatches: Vec<String> = samples
            .iter()
            .filter(|at| host_gregorian_timestamp(**at) != super::timestamp(**at))
            .map(|at| {
                format!(
                    "{at:?} portable={:?} foundation={:?}",
                    host_gregorian_timestamp(*at),
                    super::timestamp(*at)
                )
            })
            .collect();
        report("host_gregorian_timestamp", &mismatches, samples.len());
        assert_eq!(
            host_gregorian_timestamp(cutover).as_deref(),
            Some("1582-10-15T00:00:00.000000000Z")
        );
    }

    #[test]
    fn day_addition_matches_corefoundation() {
        let mut mismatches = Vec::new();
        let mut total = 0;
        let mut starts = instants(3_000, -3.2e11, 2.6e11);
        starts.extend([0.0, -0.125, 0.999_999_999_8, 0.1, 810_000_000.123_456_8]);
        starts.push(host_gregorian_seconds(9999, 12, 1, 8, 0, 0).unwrap());
        for at in starts {
            for days in [
                -1,
                0,
                1,
                7,
                29,
                30,
                31,
                90,
                365,
                366,
                3_650,
                36_500,
                i32::MAX,
            ] {
                total += 1;
                let portable = host_gregorian_add_days(at, days);
                let foundation = super::add_days(at, days);
                if portable.map(f64::to_bits) != foundation.map(f64::to_bits) {
                    mismatches.push(format!(
                        "{at:?} + {days} portable={portable:?} foundation={foundation:?}"
                    ));
                }
            }
        }
        report("host_gregorian_add_days", &mismatches, total);
    }
}
