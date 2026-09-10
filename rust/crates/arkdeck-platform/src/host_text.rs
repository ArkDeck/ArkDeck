//! macOS CharacterSet predicates shared with the current Foundation store owner.
//! Uses immutable system tables; no Swift process, filesystem or Runtime access.
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
    fn CFStringGetCharacterAtIndex(string: *const c_void, index: isize) -> u16;
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
    fn CFStringGetRangeOfComposedCharactersAtIndex(string: *const c_void, index: isize) -> Range;
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

pub fn host_control_character(scalar: char) -> bool {
    // CFCharacterSet.h: kCFCharacterSetControl = 1 (Cc and Cf).
    member(1, scalar)
}

pub fn host_whitespace_or_newline(scalar: char) -> bool {
    // CFCharacterSet.h: kCFCharacterSetWhitespaceAndNewline = 3.
    member(3, scalar)
}

/// Canonical-equivalence key matching Swift String hashing/equality. Preserve
/// the original input separately for durable bytes and UTF-8 ordering.
pub fn host_canonical_text(value: &str) -> Option<String> {
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
        CFStringNormalize(copy, 2); // kCFStringNormalizationFormC
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

/// Bounded composed-character count for the current macOS parameter reader.
/// Iteration uses UTF-16 positions, never byte offsets or Unicode scalar count.
pub fn host_composed_text_within(value: &str, maximum: usize) -> Option<bool> {
    struct Owned(*const c_void);
    impl Drop for Owned {
        fn drop(&mut self) {
            unsafe { CFRelease(self.0) };
        }
    }
    let length = isize::try_from(value.len()).ok()?;
    // SAFETY: valid UTF-8 remains live during creation. The guard owns the
    // resulting string; each queried index is in its checked UTF-16 range.
    unsafe {
        let text = CFStringCreateWithBytes(std::ptr::null(), value.as_ptr(), length, 0x08000100, 0);
        if text.is_null() {
            return None;
        }
        let text = Owned(text);
        let units = CFStringGetLength(text.0);
        let (mut position, mut count) = (0, 0_usize);
        while position < units {
            if count == maximum {
                return Some(false);
            }
            // CF composed ranges split CRLF on macOS. Swift Character follows
            // UAX #29 GB3: CR × LF, with breaks around other controls (GB4/5).
            // Join this pair for counting without changing the source bytes.
            if position + 1 < units
                && CFStringGetCharacterAtIndex(text.0, position) == 0x0d
                && CFStringGetCharacterAtIndex(text.0, position + 1) == 0x0a
            {
                position += 2;
                count += 1;
                continue;
            }
            let range = CFStringGetRangeOfComposedCharactersAtIndex(text.0, position);
            let end = range.location.checked_add(range.length)?;
            if range.location < 0 || range.location > position || end <= position || end > units {
                return None;
            }
            position = end;
            count += 1;
        }
        Some(true)
    }
}
