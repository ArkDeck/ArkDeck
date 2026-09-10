//! Gregorian calendar primitives for the macOS Session store's frozen dates.
//! Each call owns its calendar and UTC zone; no shared mutable formatter state.
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
pub fn host_gregorian_timestamp(at: f64) -> Option<String> {
    if !at.is_finite() {
        return None;
    }
    let mut whole = at.floor();
    let mut nanos = ((at - whole) * 1_000_000_000.0).round() as u32;
    if nanos == 1_000_000_000 {
        whole += 1.0;
        nanos = 0;
    }
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
pub fn host_gregorian_seconds(
    year: i32,
    month: i32,
    day: i32,
    hour: i32,
    minute: i32,
    second: i32,
) -> Option<f64> {
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
pub fn host_gregorian_add_days(at: f64, days: i32) -> Option<f64> {
    if !at.is_finite() || days <= 0 {
        return None;
    }
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
}
