//! Foundation URL parsing/encoding, without a product allowlist or network I/O.
use std::ffi::{CString, c_char, c_int, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostUrlParts {
    pub canonical: String,
    pub scheme: Option<String>,
    pub user: Option<String>,
    pub password: Option<String>,
    pub host: Option<String>,
    pub port: Option<String>,
    pub fragment: Option<String>,
}

struct Fields {
    values: [Option<String>; 7],
    invalid: bool,
}
impl Fields {
    fn new() -> Self {
        Self {
            values: std::array::from_fn(|_| None),
            invalid: false,
        }
    }
}

#[link(name = "Foundation", kind = "framework")]
unsafe extern "C" {
    fn arkdeck_update_context(
        context: *mut c_void,
        field: unsafe extern "C" fn(*mut c_void, c_int, *const c_char, usize),
    ) -> c_int;
    fn arkdeck_update_record_attempt(seconds: f64) -> c_int;
    fn arkdeck_diagnostic_log(level: c_int, message: *const c_char) -> c_int;
    fn arkdeck_file_url(
        text: *const c_char,
        context: *mut c_void,
        field: unsafe extern "C" fn(*mut c_void, c_int, *const c_char, usize),
    ) -> c_int;
    fn arkdeck_url_parts(
        text: *const c_char,
        context: *mut c_void,
        field: unsafe extern "C" fn(*mut c_void, c_int, *const c_char, usize),
    ) -> c_int;
    fn arkdeck_url_query(
        text: *const c_char,
        names: *const *const c_char,
        values: *const *const c_char,
        count: usize,
        removing: c_int,
        context: *mut c_void,
        field: unsafe extern "C" fn(*mut c_void, c_int, *const c_char, usize),
    ) -> c_int;
}

#[derive(Debug)]
pub struct HostUpdateContext {
    pub bundle_version: Option<String>,
    pub system_version: String,
    pub application_support: Option<std::path::PathBuf>,
}

pub fn host_update_context() -> Option<HostUpdateContext> {
    let mut fields = Fields::new();
    // SAFETY: synchronous metadata read with the same bounded-lifetime callback.
    let success = unsafe { arkdeck_update_context((&mut fields as *mut Fields).cast(), field) };
    if success == 0 || fields.invalid {
        return None;
    }
    Some(HostUpdateContext {
        bundle_version: fields.values[0].take(),
        system_version: fields.values[1].take()?,
        application_support: fields.values[2].take().map(Into::into),
    })
}

#[derive(Clone, Copy)]
pub enum HostDiagnosticLevel {
    Info,
    Notice,
    Error,
}

/// OS sink for a caller-redacted bounded public diagnostic message.
pub fn host_diagnostic_log(level: HostDiagnosticLevel, message: &str) -> bool {
    if message.len() > 1024 {
        return false;
    }
    let Ok(message) = CString::new(message) else {
        return false;
    };
    let level = match level {
        HostDiagnosticLevel::Info => 0,
        HostDiagnosticLevel::Notice => 1,
        HostDiagnosticLevel::Error => 2,
    };
    // SAFETY: bounded live C string, native helper uses a fixed format string.
    unsafe { arkdeck_diagnostic_log(level, message.as_ptr()) != 0 }
}

/// Records a manual check in the same standard UserDefaults domain as Swift.
/// No path, suite override or arbitrary key/value is accepted from a caller.
pub fn host_update_record_attempt(seconds: f64) -> bool {
    // SAFETY: finite scalar only; the native helper contains SDK exceptions.
    seconds.is_finite() && unsafe { arkdeck_update_record_attempt(seconds) } != 0
}

#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {
    fn arkdeck_update_reveal(path: *const c_char) -> c_int;
}

/// Performs one Finder selection from the CLI's main thread. Consent and
/// exact artifact validation are required at the caller before invoking this.
pub fn host_update_reveal(path: &std::path::Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    if !path.is_absolute() {
        return false;
    }
    let Ok(path) = CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    // SAFETY: synchronous SDK call, live NUL-terminated filesystem path.
    unsafe { arkdeck_update_reveal(path.as_ptr()) != 0 }
}

/// Foundation file URL escaping; does not open, create or resolve the path.
pub fn host_file_url(path: &std::path::Path) -> Option<String> {
    use std::os::unix::ffi::OsStrExt;
    if !path.is_absolute() {
        return None;
    }
    let path = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut fields = Fields::new();
    // SAFETY: synchronous SDK helper retains none of the live stack buffers.
    let success =
        unsafe { arkdeck_file_url(path.as_ptr(), (&mut fields as *mut Fields).cast(), field) };
    if success == 0 || fields.invalid {
        return None;
    }
    fields.values[0].take()
}

unsafe extern "C" fn field(raw: *mut c_void, slot: c_int, bytes: *const c_char, length: usize) {
    // SAFETY: both native URL helpers synchronously borrow this stack Fields
    // and each NSData view; no callback or field pointer is retained.
    let fields = unsafe { &mut *raw.cast::<Fields>() };
    let result = catch_unwind(AssertUnwindSafe(|| {
        if !(0..7).contains(&slot) || (bytes.is_null() && length != 0) {
            fields.invalid = true;
            return;
        }
        let bytes = if length == 0 {
            &[][..]
        } else {
            // SAFETY: the callback's NSData contains exactly length bytes.
            unsafe { std::slice::from_raw_parts(bytes.cast::<u8>(), length) }
        };
        match std::str::from_utf8(bytes) {
            Ok(value) => fields.values[slot as usize] = Some(value.to_owned()),
            Err(_) => fields.invalid = true,
        }
    }));
    if result.is_err() {
        fields.invalid = true;
    }
}

pub fn inspect_host_url(value: &str) -> Option<HostUrlParts> {
    let value = CString::new(value).ok()?;
    let mut fields = Fields::new();
    // SAFETY: live string and context for a synchronous, exception-contained SDK call.
    let success =
        unsafe { arkdeck_url_parts(value.as_ptr(), (&mut fields as *mut Fields).cast(), field) };
    if success == 0 || fields.invalid {
        return None;
    }
    let [canonical, scheme, user, password, host, port, fragment] = fields.values;
    Some(HostUrlParts {
        canonical: canonical?,
        scheme,
        user,
        password,
        host,
        port,
        fragment,
    })
}

fn query(value: &str, items: &[(&str, Option<&str>)], removing: bool) -> Option<String> {
    let value = CString::new(value).ok()?;
    let owned_names: Vec<CString> = items
        .iter()
        .map(|(name, _)| CString::new(*name))
        .collect::<Result<_, _>>()
        .ok()?;
    let owned_values: Vec<Option<CString>> = items
        .iter()
        .map(|(_, value)| value.map(CString::new).transpose())
        .collect::<Result<_, _>>()
        .ok()?;
    let names: Vec<_> = owned_names.iter().map(|name| name.as_ptr()).collect();
    let values: Vec<_> = owned_values
        .iter()
        .map(|value| {
            value
                .as_ref()
                .map_or(std::ptr::null(), |value| value.as_ptr())
        })
        .collect();
    let mut fields = Fields::new();
    // SAFETY: all CStrings, pointer arrays and result context live until the
    // synchronous native call returns; lengths match and null values mean nil.
    let success = unsafe {
        arkdeck_url_query(
            value.as_ptr(),
            names.as_ptr(),
            values.as_ptr(),
            names.len(),
            i32::from(removing),
            (&mut fields as *mut Fields).cast(),
            field,
        )
    };
    if success == 0 || fields.invalid {
        return None;
    }
    fields.values[0].take()
}

pub fn host_url_with_query(value: &str, items: &[(&str, Option<&str>)]) -> Option<String> {
    query(value, items, false)
}
pub fn host_url_without_query_names(value: &str, names: &[&str]) -> Option<String> {
    query(
        value,
        &names.iter().map(|name| (*name, None)).collect::<Vec<_>>(),
        true,
    )
}
