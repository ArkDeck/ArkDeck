//! Property lists read by CoreFoundation, the reader Swift's
//! `PropertyListSerialization` uses, so a document is accepted or refused as
//! Swift accepts or refuses it whatever its format (XML or binary).
//!
//! The document is bounded before it is parsed and every value is copied out
//! of CoreFoundation into [`PropertyListValue`] before the parsed objects are
//! released; nothing borrowed outlives its owner.
use std::collections::BTreeMap;
use std::ffi::c_void;
use std::io;
use std::ptr;

/// A document larger than this is refused before it is parsed.
pub const MAX_PROPERTY_LIST_BYTES: usize = 1024 * 1024;
const MAX_DEPTH: usize = 32;
const MAX_NODES: usize = 100_000;
const UTF8: u32 = 0x0800_0100;
const NUMBER_SINT64: isize = 4;
const NUMBER_FLOAT64: isize = 6;

/// One property-list value, as CoreFoundation parsed it.
#[derive(Clone, Debug, PartialEq)]
pub enum PropertyListValue {
    String(String),
    /// A `<true/>` or `<false/>`.
    Boolean(bool),
    Integer(i64),
    Real(f64),
    /// Seconds since 2001-01-01T00:00:00Z.
    Date(f64),
    Data(Vec<u8>),
    Array(Vec<PropertyListValue>),
    Dictionary(BTreeMap<String, PropertyListValue>),
}

impl PropertyListValue {
    /// Swift's `as? String`.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(text) => Some(text),
            _ => None,
        }
    }

    /// Swift's `as? Bool`: a boolean, or a number that is exactly 0 or 1 (an
    /// `NSNumber` bridges to `Bool` only then).
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Self::Boolean(flag) => Some(*flag),
            Self::Integer(0) => Some(false),
            Self::Integer(1) => Some(true),
            Self::Real(value) if *value == 0.0 => Some(false),
            Self::Real(value) if *value == 1.0 => Some(true),
            _ => None,
        }
    }

    /// Swift's `as? [String: Any]`.
    pub fn as_dictionary(&self) -> Option<&BTreeMap<String, PropertyListValue>> {
        match self {
            Self::Dictionary(fields) => Some(fields),
            _ => None,
        }
    }

    /// Swift's `as? [String]`: an array every element of which is a string.
    pub fn as_strings(&self) -> Option<Vec<&str>> {
        match self {
            Self::Array(items) => items.iter().map(Self::as_str).collect(),
            _ => None,
        }
    }

    /// Swift's `as? [String: String]`: a dictionary every value of which is a
    /// string.
    pub fn as_string_dictionary(&self) -> Option<BTreeMap<&str, &str>> {
        self.as_dictionary()?
            .iter()
            .map(|(key, value)| Some((key.as_str(), value.as_str()?)))
            .collect()
    }

    /// Swift's `as? [String: Bool]`.
    pub fn as_bool_dictionary(&self) -> Option<BTreeMap<&str, bool>> {
        self.as_dictionary()?
            .iter()
            .map(|(key, value)| Some((key.as_str(), value.as_bool()?)))
            .collect()
    }
}

#[repr(C)]
struct CFRange {
    location: isize,
    length: isize,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: *const c_void);
    fn CFGetTypeID(value: *const c_void) -> usize;
    fn CFDataCreate(allocator: *const c_void, bytes: *const u8, length: isize) -> *const c_void;
    fn CFDataGetTypeID() -> usize;
    fn CFDataGetLength(data: *const c_void) -> isize;
    fn CFDataGetBytePtr(data: *const c_void) -> *const u8;
    fn CFPropertyListCreateWithData(
        allocator: *const c_void,
        data: *const c_void,
        options: usize,
        format: *mut isize,
        error: *mut *const c_void,
    ) -> *const c_void;
    fn CFStringGetTypeID() -> usize;
    fn CFStringGetLength(value: *const c_void) -> isize;
    fn CFStringGetBytes(
        value: *const c_void,
        range: CFRange,
        encoding: u32,
        loss_byte: u8,
        external: u8,
        buffer: *mut u8,
        maximum: isize,
        used: *mut isize,
    ) -> isize;
    fn CFBooleanGetTypeID() -> usize;
    fn CFBooleanGetValue(value: *const c_void) -> u8;
    fn CFNumberGetTypeID() -> usize;
    fn CFNumberIsFloatType(value: *const c_void) -> u8;
    fn CFNumberGetValue(number: *const c_void, kind: isize, output: *mut c_void) -> u8;
    fn CFDateGetTypeID() -> usize;
    fn CFDateGetAbsoluteTime(value: *const c_void) -> f64;
    fn CFArrayGetTypeID() -> usize;
    fn CFArrayGetCount(array: *const c_void) -> isize;
    fn CFArrayGetValueAtIndex(array: *const c_void, index: isize) -> *const c_void;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFDictionaryGetCount(dictionary: *const c_void) -> isize;
    fn CFDictionaryGetKeysAndValues(
        dictionary: *const c_void,
        keys: *mut *const c_void,
        values: *mut *const c_void,
    );
}

struct Owned(*const c_void);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: Owned only ever holds a nonnull create-rule CF reference.
        unsafe { CFRelease(self.0) };
    }
}

fn unreadable(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

/// Parses a property list of any format, as `PropertyListSerialization`
/// parses it.
pub fn read_property_list(bytes: &[u8]) -> io::Result<PropertyListValue> {
    if bytes.is_empty() || bytes.len() > MAX_PROPERTY_LIST_BYTES {
        return Err(unreadable(
            "the property list is empty or exceeds its byte bound",
        ));
    }
    // SAFETY: the buffer is live and bounded for the call; each create-rule
    // result is owned by an `Owned` and released when it leaves scope.
    unsafe {
        let data = CFDataCreate(ptr::null(), bytes.as_ptr(), bytes.len() as isize);
        if data.is_null() {
            return Err(unreadable("the property list could not be buffered"));
        }
        let data = Owned(data);
        let plist =
            CFPropertyListCreateWithData(ptr::null(), data.0, 0, ptr::null_mut(), ptr::null_mut());
        if plist.is_null() {
            return Err(unreadable("the property list is malformed"));
        }
        let plist = Owned(plist);
        let mut nodes = 0;
        convert(plist.0, 0, &mut nodes)
    }
}

/// Copies one parsed value out of CoreFoundation.
///
/// # Safety
///
/// `value` is a live CF object owned by the parsed property list for the
/// whole call.
unsafe fn convert(
    value: *const c_void,
    depth: usize,
    nodes: &mut usize,
) -> io::Result<PropertyListValue> {
    *nodes += 1;
    if value.is_null() || depth > MAX_DEPTH || *nodes > MAX_NODES {
        return Err(unreadable(
            "the property list exceeds its depth or size bound",
        ));
    }
    // SAFETY: `value` is live (the caller's contract); each accessor below is
    // called only after its type identifier matched.
    unsafe {
        let kind = CFGetTypeID(value);
        if kind == CFStringGetTypeID() {
            return string(value).map(PropertyListValue::String);
        }
        if kind == CFBooleanGetTypeID() {
            return Ok(PropertyListValue::Boolean(CFBooleanGetValue(value) != 0));
        }
        if kind == CFNumberGetTypeID() {
            if CFNumberIsFloatType(value) != 0 {
                let mut real = 0f64;
                if CFNumberGetValue(value, NUMBER_FLOAT64, (&mut real as *mut f64).cast()) == 0 {
                    return Err(unreadable("a property-list number is unreadable"));
                }
                return Ok(PropertyListValue::Real(real));
            }
            let mut integer = 0i64;
            if CFNumberGetValue(value, NUMBER_SINT64, (&mut integer as *mut i64).cast()) == 0 {
                return Err(unreadable("a property-list integer does not fit 64 bits"));
            }
            return Ok(PropertyListValue::Integer(integer));
        }
        if kind == CFDateGetTypeID() {
            return Ok(PropertyListValue::Date(CFDateGetAbsoluteTime(value)));
        }
        if kind == CFDataGetTypeID() {
            let length = CFDataGetLength(value);
            let start = CFDataGetBytePtr(value);
            if length < 0 || (length > 0 && start.is_null()) {
                return Err(unreadable("property-list data is unreadable"));
            }
            let bytes = if length == 0 {
                Vec::new()
            } else {
                std::slice::from_raw_parts(start, length as usize).to_vec()
            };
            return Ok(PropertyListValue::Data(bytes));
        }
        if kind == CFArrayGetTypeID() {
            let count = CFArrayGetCount(value);
            if count < 0 || count as usize > MAX_NODES {
                return Err(unreadable("a property-list array exceeds its bound"));
            }
            let mut items = Vec::with_capacity(count as usize);
            for index in 0..count {
                items.push(convert(
                    CFArrayGetValueAtIndex(value, index),
                    depth + 1,
                    nodes,
                )?);
            }
            return Ok(PropertyListValue::Array(items));
        }
        if kind == CFDictionaryGetTypeID() {
            let count = CFDictionaryGetCount(value);
            if count < 0 || count as usize > MAX_NODES {
                return Err(unreadable("a property-list dictionary exceeds its bound"));
            }
            let mut keys = vec![ptr::null(); count as usize];
            let mut values = vec![ptr::null(); count as usize];
            CFDictionaryGetKeysAndValues(value, keys.as_mut_ptr(), values.as_mut_ptr());
            let mut fields = BTreeMap::new();
            for (key, item) in keys.into_iter().zip(values) {
                if key.is_null() || CFGetTypeID(key) != CFStringGetTypeID() {
                    return Err(unreadable("a property-list dictionary key is not a string"));
                }
                let key = string(key)?;
                let item = convert(item, depth + 1, nodes)?;
                if fields.insert(key, item).is_some() {
                    return Err(unreadable("a property-list dictionary repeats a key"));
                }
            }
            return Ok(PropertyListValue::Dictionary(fields));
        }
    }
    Err(unreadable("a property-list value has an unknown type"))
}

/// The UTF-8 bytes of one CF string, NUL included where the string holds one.
///
/// # Safety
///
/// `value` is a live CFString.
unsafe fn string(value: *const c_void) -> io::Result<String> {
    // SAFETY: `value` is a live CFString (the caller's contract); the buffer
    // is sized from the measured byte count before the second call writes it.
    unsafe {
        let length = CFStringGetLength(value);
        if length < 0 {
            return Err(unreadable("a property-list string is unreadable"));
        }
        let range = || CFRange {
            location: 0,
            length,
        };
        let mut needed = 0isize;
        if CFStringGetBytes(value, range(), UTF8, 0, 0, ptr::null_mut(), 0, &mut needed) != length
            || needed < 0
            || needed as usize > MAX_PROPERTY_LIST_BYTES * 4
        {
            return Err(unreadable("a property-list string is not UTF-8"));
        }
        let mut buffer = vec![0u8; needed as usize];
        let mut used = 0isize;
        if CFStringGetBytes(
            value,
            range(),
            UTF8,
            0,
            0,
            buffer.as_mut_ptr(),
            needed,
            &mut used,
        ) != length
            || used != needed
        {
            return Err(unreadable("a property-list string is not UTF-8"));
        }
        String::from_utf8(buffer).map_err(|_| unreadable("a property-list string is not UTF-8"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- a comment is not a value -->
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.arkdeck.agentd</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Users/a b/Library/Application Support/ArkDeck/Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>ARKDECK_HDC_PATH</key>
		<string>/opt/å/hdc</string>
	</dict>
	<key>MachServices</key>
	<dict>
		<key>com.arkdeck.agentd</key>
		<true/>
	</dict>
	<key>KeepAlive</key>
	<integer>1</integer>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>Ratio</key>
	<real>0.5</real>
	<key>Blob</key>
	<data>AAEC</data>
</dict>
</plist>
"#;

    #[test]
    fn a_launch_agent_document_reads_as_swift_bridges_it() {
        let document = read_property_list(XML.as_bytes()).unwrap();
        let fields = document.as_dictionary().unwrap();
        assert_eq!(fields["Label"].as_str(), Some("com.arkdeck.agentd"));
        assert_eq!(
            fields["ProgramArguments"].as_strings().unwrap(),
            [
                "/Users/a b/Library/Application Support/ArkDeck/Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd"
            ]
        );
        assert_eq!(
            fields["EnvironmentVariables"]
                .as_string_dictionary()
                .unwrap()["ARKDECK_HDC_PATH"],
            "/opt/å/hdc"
        );
        assert!(fields["MachServices"].as_bool_dictionary().unwrap()["com.arkdeck.agentd"]);
        // An NSNumber of exactly 1 bridges to Bool, as Swift's `as? Bool`.
        assert_eq!(fields["KeepAlive"].as_bool(), Some(true));
        assert_eq!(fields["ThrottleInterval"].as_bool(), None);
        assert_eq!(fields["ThrottleInterval"], PropertyListValue::Integer(5));
        assert_eq!(fields["Ratio"], PropertyListValue::Real(0.5));
        assert_eq!(fields["Blob"], PropertyListValue::Data(vec![0, 1, 2]));
        assert!(fields["Label"].as_strings().is_none());
    }

    #[test]
    fn a_malformed_or_unbounded_document_is_refused() {
        for bytes in [
            &b""[..],
            b"not a property list <",
            b"<plist><dict><key>a</key></dict></plist>",
        ] {
            assert!(read_property_list(bytes).is_err(), "{bytes:?}");
        }
        let mut large = b"<plist><string>".to_vec();
        large.resize(MAX_PROPERTY_LIST_BYTES + 1, b'a');
        assert!(read_property_list(&large).is_err());
    }
}
