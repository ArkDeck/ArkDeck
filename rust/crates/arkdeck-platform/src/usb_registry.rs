//! The Runtime's own read-only USB device census from the I/O Registry: the
//! trusted source of the USB relations that prove a target observation, read
//! as Swift's `RockchipProductUSBProbe.systemIdentities()` reads it for
//! `TargetUSBRelation.registeredDAYU200()`
//! (`ArkDeckWorkflows/RockchipDeviceBinding.swift`). The maintainer's decision
//! Q1=B of 2026-09-24 keeps this read in ArkDeck, in its one FFI crate, until
//! the ArkForge lane can serve it after M4.
//!
//! A census matches the services of one registry class and reads their
//! properties. It opens no device or interface, sends no USB request, and
//! claims, changes or writes nothing. Every object it obtains is released on
//! every path, and every census drains its own autorelease pool.
//!
//! [`UsbHostDevice::from_entry`] is Swift's per-entry rule: an entry without a
//! numeric `idVendor`, `idProduct` and `locationID` and a string
//! `USB Serial Number` (else `kUSBSerialNumberString`) is no identity and is
//! passed over; the numbers read as `NSNumber` reads them; the product name
//! is optional; the registry entry ID names one attachment lifetime and is
//! absent when the registry answers none or zero. Which identities are the
//! registered DAYU200, and when a relation proves a candidate, is the HDC
//! provider's (`arkdeck_provider_hdc::UsbRegistryRelations`).
//!
//! One difference from Swift, which never asks: a census whose iterator did
//! not stay valid through the enumeration may be incomplete, so it is
//! unavailable rather than a shorter list.
use std::fmt;

/// An I/O Registry property as a census reads it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RegistryValue {
    /// A `CFNumber` as a signed 64-bit integer, or a `CFBoolean` as 1 or 0:
    /// what Swift's `as? NSNumber` accepts.
    Number(i64),
    /// A `CFString`, decoded from UTF-16 with U+FFFD for an unpaired
    /// surrogate, as a Swift `String` reads one.
    Text(String),
    /// Any other type, which neither `as? NSNumber` nor `as? String` accepts.
    Other,
}

/// One registry entry a census holds while it reads it.
pub trait RegistryEntry {
    /// The property named `key`, if the entry has one.
    fn property(&self, key: &str) -> Option<RegistryValue>;
    /// The entry's registry entry ID, if the registry answers one.
    fn registry_entry_id(&self) -> Option<u64>;
}

/// Why a census could not be taken. Swift's census throws its one
/// "USB registry unavailable" for the first two and never asks the third.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RegistryUnavailable {
    /// No matching dictionary could be created for the class.
    Matching,
    /// `IOServiceGetMatchingServices` answered this `kern_return_t`.
    Services(i32),
    /// The iterator did not stay valid through the enumeration.
    Invalidated,
}

impl fmt::Display for RegistryUnavailable {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Matching => {
                formatter.write_str("USB registry unavailable: no matching dictionary")
            }
            Self::Services(status) => write!(
                formatter,
                "USB registry unavailable: IOServiceGetMatchingServices answered {status:#x}"
            ),
            Self::Invalidated => {
                formatter.write_str("USB registry unavailable: the census iterator was invalidated")
            }
        }
    }
}

impl std::error::Error for RegistryUnavailable {}

/// Swift `RockchipProductUSBIdentity` as `systemIdentities()` builds it from
/// one `IOUSBHostDevice` entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UsbHostDevice {
    pub serial: String,
    pub vendor_id: u16,
    pub product_id: u16,
    /// `locationID` in decimal, as Swift's `String(location.uint64Value)`.
    pub topology: String,
    pub product_name: Option<String>,
    /// One attachment lifetime, not a durable device identity.
    pub registry_entry_id: Option<u64>,
}

impl UsbHostDevice {
    /// Swift's per-entry rule of `systemIdentities()`, or `None` for an entry
    /// it passes over.
    pub fn from_entry<E: RegistryEntry + ?Sized>(entry: &E) -> Option<Self> {
        let number = |key: &str| match entry.property(key) {
            Some(RegistryValue::Number(value)) => Some(value),
            _ => None,
        };
        let text = |key: &str| match entry.property(key) {
            Some(RegistryValue::Text(value)) => Some(value),
            _ => None,
        };
        let vendor = number("idVendor")?;
        let product = number("idProduct")?;
        let location = number("locationID")?;
        let serial = text("USB Serial Number").or_else(|| text("kUSBSerialNumberString"))?;
        let registry_entry_id = entry.registry_entry_id().filter(|id| *id != 0);
        Some(Self {
            serial,
            // `NSNumber.uint16Value` keeps the low sixteen bits.
            vendor_id: vendor as u16,
            product_id: product as u16,
            // `NSNumber.uint64Value` keeps the signed value's bits, so a
            // 32-bit number with its high bit set reads as Swift reads it.
            topology: (location as u64).to_string(),
            product_name: text("USB Product Name"),
            registry_entry_id,
        })
    }
}

/// Every `IOUSBHostDevice` identity on the host, in registry order, as
/// Swift's `systemIdentities()` answers them: entries it passes over are not
/// listed, and nothing is deduplicated.
#[cfg(target_os = "macos")]
pub fn usb_host_devices() -> Result<Vec<UsbHostDevice>, RegistryUnavailable> {
    registry_census(c"IOUSBHostDevice", |entry| UsbHostDevice::from_entry(entry))
}

/// Every service of `class` on the host, in registry order, each read by
/// `read` while the census holds it; entries `read` passes over are not
/// listed. Read-only: see the module documentation.
#[cfg(target_os = "macos")]
pub fn registry_census<T>(
    class: &std::ffi::CStr,
    read: impl FnMut(&dyn RegistryEntry) -> Option<T>,
) -> Result<Vec<T>, RegistryUnavailable> {
    iokit::census(class, read)
}

#[cfg(target_os = "macos")]
mod iokit {
    use super::{RegistryEntry, RegistryUnavailable, RegistryValue};
    use crate::autorelease_pool::AutoreleasePool;
    use std::ffi::{CStr, c_char, c_void};

    /// `io_object_t`, a Mach port name.
    type IoObject = u32;

    const KERN_SUCCESS: i32 = 0;
    /// `kIOMainPortDefault`: `MACH_PORT_NULL` names the default main port.
    const MAIN_PORT_DEFAULT: u32 = 0;
    /// `kCFNumberSInt64Type`.
    const NUMBER_SINT64: isize = 4;
    /// `kCFStringEncodingUTF8`.
    const UTF8: u32 = 0x0800_0100;

    #[repr(C)]
    struct Range {
        location: isize,
        length: isize,
    }

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOServiceMatching(name: *const c_char) -> *const c_void;
        fn IOServiceGetMatchingServices(
            main_port: u32,
            matching: *const c_void,
            existing: *mut IoObject,
        ) -> i32;
        fn IOIteratorNext(iterator: IoObject) -> IoObject;
        fn IOIteratorIsValid(iterator: IoObject) -> i32;
        fn IOObjectRelease(object: IoObject) -> i32;
        fn IORegistryEntryCreateCFProperty(
            entry: IoObject,
            key: *const c_void,
            allocator: *const c_void,
            options: u32,
        ) -> *const c_void;
        fn IORegistryEntryGetRegistryEntryID(entry: IoObject, id: *mut u64) -> i32;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            allocator: *const c_void,
            bytes: *const u8,
            length: isize,
            encoding: u32,
            external: u8,
        ) -> *const c_void;
        fn CFGetTypeID(value: *const c_void) -> usize;
        fn CFNumberGetTypeID() -> usize;
        fn CFBooleanGetTypeID() -> usize;
        fn CFStringGetTypeID() -> usize;
        fn CFNumberGetValue(number: *const c_void, kind: isize, output: *mut c_void) -> u8;
        fn CFBooleanGetValue(boolean: *const c_void) -> u8;
        fn CFStringGetLength(string: *const c_void) -> isize;
        fn CFStringGetCharacters(string: *const c_void, range: Range, buffer: *mut u16);
        fn CFRelease(value: *const c_void);
    }

    /// An I/O Kit object reference this census obtained, released once when
    /// dropped. Zero is no object.
    struct Held(IoObject);

    impl Drop for Held {
        fn drop(&mut self) {
            if self.0 != 0 {
                // SAFETY: a reference this census obtained and releases once.
                unsafe { IOObjectRelease(self.0) };
            }
        }
    }

    /// A create-rule Core Foundation object, released when dropped.
    struct Owned(*const c_void);

    impl Drop for Owned {
        fn drop(&mut self) {
            // SAFETY: a nonnull create-rule object owned by this guard alone.
            unsafe { CFRelease(self.0) };
        }
    }

    impl RegistryEntry for Held {
        fn property(&self, key: &str) -> Option<RegistryValue> {
            let length = isize::try_from(key.len()).ok()?;
            // SAFETY: `key` is valid for `length` bytes during the call; the
            // string follows the create rule and its guard releases it.
            let key =
                unsafe { CFStringCreateWithBytes(std::ptr::null(), key.as_ptr(), length, UTF8, 0) };
            if key.is_null() {
                return None;
            }
            let key = Owned(key);
            // SAFETY: a registry entry this census holds and a live key; the
            // property follows the create rule and its guard releases it.
            let value =
                unsafe { IORegistryEntryCreateCFProperty(self.0, key.0, std::ptr::null(), 0) };
            if value.is_null() {
                return None;
            }
            Some(registry_value(&Owned(value)))
        }

        fn registry_entry_id(&self) -> Option<u64> {
            let mut id = 0;
            // SAFETY: a registry entry this census holds and a live output.
            (unsafe { IORegistryEntryGetRegistryEntryID(self.0, &mut id) } == KERN_SUCCESS)
                .then_some(id)
        }
    }

    fn registry_value(value: &Owned) -> RegistryValue {
        // SAFETY: `value` is a live Core Foundation object, each accessor is
        // called only on its own type, and every output is a live local.
        unsafe {
            let kind = CFGetTypeID(value.0);
            if kind == CFNumberGetTypeID() {
                // `NSNumber` converts whatever it holds, lossy or not: so does
                // this, and every integer the registry holds fits exactly.
                let mut number = 0_i64;
                CFNumberGetValue(value.0, NUMBER_SINT64, (&raw mut number).cast());
                RegistryValue::Number(number)
            } else if kind == CFBooleanGetTypeID() {
                RegistryValue::Number(i64::from(CFBooleanGetValue(value.0) != 0))
            } else if kind == CFStringGetTypeID() {
                let length = CFStringGetLength(value.0);
                let Ok(count) = usize::try_from(length) else {
                    return RegistryValue::Other;
                };
                let mut units = vec![0_u16; count];
                if count > 0 {
                    CFStringGetCharacters(
                        value.0,
                        Range {
                            location: 0,
                            length,
                        },
                        units.as_mut_ptr(),
                    );
                }
                RegistryValue::Text(String::from_utf16_lossy(&units))
            } else {
                RegistryValue::Other
            }
        }
    }

    pub(super) fn census<T>(
        class: &CStr,
        mut read: impl FnMut(&dyn RegistryEntry) -> Option<T>,
    ) -> Result<Vec<T>, RegistryUnavailable> {
        let _pool = AutoreleasePool::push();
        // SAFETY: a nul-terminated class name. The dictionary follows the
        // create rule, and the call below consumes it on every path.
        let matching = unsafe { IOServiceMatching(class.as_ptr()) };
        if matching.is_null() {
            return Err(RegistryUnavailable::Matching);
        }
        let mut iterator = 0;
        // SAFETY: consumes `matching`'s one reference, whatever it answers,
        // and writes the iterator it returns into a live local.
        let status =
            unsafe { IOServiceGetMatchingServices(MAIN_PORT_DEFAULT, matching, &mut iterator) };
        let iterator = Held(iterator);
        if status != KERN_SUCCESS {
            return Err(RegistryUnavailable::Services(status));
        }
        // With no service of the class the kernel answers success and no
        // iterator: an empty census, as Swift's loop reads it.
        if iterator.0 == 0 {
            return Ok(Vec::new());
        }
        let mut found = Vec::new();
        loop {
            // SAFETY: the iterator this census holds; each entry it returns
            // is a reference the guard below releases.
            let entry = Held(unsafe { IOIteratorNext(iterator.0) });
            if entry.0 == 0 {
                break;
            }
            if let Some(value) = read(&entry) {
                found.push(value);
            }
        }
        // A registry change can invalidate an iterator, and an iterator that
        // failed returns no more entries: either way the census may be short.
        // SAFETY: the iterator this census holds.
        if unsafe { IOIteratorIsValid(iterator.0) } == 0 {
            return Err(RegistryUnavailable::Invalidated);
        }
        Ok(found)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    /// A registry entry of named properties, as a census would hold one.
    #[derive(Clone)]
    struct Entry {
        properties: BTreeMap<&'static str, RegistryValue>,
        id: Option<u64>,
    }

    impl RegistryEntry for Entry {
        fn property(&self, key: &str) -> Option<RegistryValue> {
            self.properties.get(key).cloned()
        }

        fn registry_entry_id(&self) -> Option<u64> {
            self.id
        }
    }

    impl Entry {
        fn with(mut self, key: &'static str, value: Option<RegistryValue>) -> Self {
            match value {
                Some(value) => self.properties.insert(key, value),
                None => self.properties.remove(key),
            };
            self
        }
    }

    fn text(value: &str) -> Option<RegistryValue> {
        Some(RegistryValue::Text(value.to_owned()))
    }

    fn number(value: i64) -> Option<RegistryValue> {
        Some(RegistryValue::Number(value))
    }

    /// A DAYU200 in its HDC-normal personality as the registry lists it.
    fn board() -> Entry {
        Entry {
            properties: BTreeMap::new(),
            id: Some(4_295_032_173),
        }
        .with("idVendor", number(0x2207))
        .with("idProduct", number(0x5000))
        .with("locationID", number(18_874_368))
        .with(
            "USB Serial Number",
            text("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        )
        .with("USB Product Name", text("\"HDC Device\""))
    }

    #[test]
    fn an_entry_reads_as_swift_s_identity() {
        assert_eq!(
            UsbHostDevice::from_entry(&board()),
            Some(UsbHostDevice {
                serial: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into(),
                vendor_id: 0x2207,
                product_id: 0x5000,
                topology: "18874368".into(),
                product_name: Some("\"HDC Device\"".into()),
                registry_entry_id: Some(4_295_032_173),
            })
        );
        // Through a trait object, as a census hands entries out.
        let entry: &dyn RegistryEntry = &board();
        assert_eq!(
            UsbHostDevice::from_entry(entry),
            UsbHostDevice::from_entry(&board())
        );
    }

    #[test]
    fn an_entry_without_its_numbers_or_a_string_serial_is_passed_over() {
        for key in ["idVendor", "idProduct", "locationID"] {
            assert_eq!(
                UsbHostDevice::from_entry(&board().with(key, None)),
                None,
                "{key}"
            );
            for other in [text("8711"), Some(RegistryValue::Other)] {
                assert_eq!(
                    UsbHostDevice::from_entry(&board().with(key, other.clone())),
                    None,
                    "{key} as {other:?}"
                );
            }
        }
        let no_serial = board().with("USB Serial Number", None);
        assert_eq!(UsbHostDevice::from_entry(&no_serial), None);
        assert_eq!(
            UsbHostDevice::from_entry(&no_serial.with("kUSBSerialNumberString", number(7))),
            None,
            "a serial that is not a string"
        );
    }

    #[test]
    fn the_serial_falls_back_to_the_legacy_key_only_without_a_string_serial() {
        let legacy = text("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        let serial = |entry: Entry| UsbHostDevice::from_entry(&entry).map(|device| device.serial);
        assert_eq!(
            serial(board().with("kUSBSerialNumberString", legacy.clone())).as_deref(),
            Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            "the current key wins"
        );
        for current in [None, number(1), Some(RegistryValue::Other)] {
            assert_eq!(
                serial(
                    board()
                        .with("USB Serial Number", current.clone())
                        .with("kUSBSerialNumberString", legacy.clone())
                )
                .as_deref(),
                Some("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
                "{current:?}"
            );
        }
        // Swift takes the string as it is: validity is the relation's rule.
        assert_eq!(
            serial(board().with("USB Serial Number", text(""))).as_deref(),
            Some("")
        );
    }

    #[test]
    fn numbers_read_as_nsnumber_reads_them() {
        let read = |key: &'static str, value: i64| {
            UsbHostDevice::from_entry(&board().with(key, number(value))).unwrap()
        };
        // A 16-bit number with its high bit set is stored signed.
        assert_eq!(read("idVendor", -30_585).vendor_id, 0x8887);
        // `uint16Value` keeps the low sixteen bits of anything wider.
        assert_eq!(read("idProduct", 0x1_5000).product_id, 0x5000);
        assert_eq!(read("idVendor", 1).vendor_id, 1, "a boolean reads as 1");
        // A 32-bit location with its high bit set is stored signed, and
        // `uint64Value` keeps its bits.
        assert_eq!(
            read("locationID", -2_147_483_648).topology,
            "18446744071562067968"
        );
        assert_eq!(read("locationID", 0).topology, "0");
        assert_eq!(read("locationID", i64::MAX).topology, i64::MAX.to_string());
    }

    #[test]
    fn the_product_name_and_the_attachment_are_optional() {
        let unnamed = UsbHostDevice::from_entry(&board().with("USB Product Name", None)).unwrap();
        assert_eq!(unnamed.product_name, None);
        let unnamed =
            UsbHostDevice::from_entry(&board().with("USB Product Name", number(3))).unwrap();
        assert_eq!(unnamed.product_name, None, "a name that is not a string");
        for id in [None, Some(0)] {
            let entry = Entry { id, ..board() };
            assert_eq!(
                UsbHostDevice::from_entry(&entry).unwrap().registry_entry_id,
                None,
                "{id:?}"
            );
        }
    }

    #[test]
    fn unavailability_names_its_cause() {
        assert_eq!(
            RegistryUnavailable::Services(-536_870_210).to_string(),
            "USB registry unavailable: IOServiceGetMatchingServices answered 0xe00002be"
        );
        assert!(
            RegistryUnavailable::Invalidated
                .to_string()
                .starts_with("USB registry unavailable")
        );
    }
}
