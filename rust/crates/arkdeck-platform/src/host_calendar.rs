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
    fn CFRelease(object: *const c_void);
}

struct Owned(*const c_void);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: nonnull create-rule object, exclusively owned by this guard.
        unsafe { CFRelease(self.0) };
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
