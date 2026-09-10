//! The bootstrap registries use Foundation's legacy ISO8601DateFormatter.
//! Keep this separate from Session's calendar and the newer ISO8601FormatStyle.
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
pub fn host_legacy_iso8601(value: &str) -> Option<bool> {
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
