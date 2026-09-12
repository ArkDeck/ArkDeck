//! Bounded SQLite calls for the macOS Runtime store. SQL is supplied by the
//! repository implementation, never by a control request. The connection is
//! single-thread owned; callers serialize access at the repository boundary.
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::io;
use std::path::Path;
use std::ptr;

#[link(name = "sqlite3")]
unsafe extern "C" {
    fn sqlite3_open_v2(
        path: *const c_char,
        db: *mut *mut c_void,
        flags: c_int,
        vfs: *const c_char,
    ) -> c_int;
    fn sqlite3_close_v2(db: *mut c_void) -> c_int;
    fn sqlite3_busy_timeout(db: *mut c_void, ms: c_int) -> c_int;
    fn sqlite3_prepare_v2(
        db: *mut c_void,
        sql: *const c_char,
        bytes: c_int,
        statement: *mut *mut c_void,
        tail: *mut *const c_char,
    ) -> c_int;
    fn sqlite3_finalize(statement: *mut c_void) -> c_int;
    fn sqlite3_step(statement: *mut c_void) -> c_int;
    fn sqlite3_bind_parameter_count(statement: *mut c_void) -> c_int;
    fn sqlite3_bind_null(statement: *mut c_void, index: c_int) -> c_int;
    fn sqlite3_bind_int64(statement: *mut c_void, index: c_int, value: i64) -> c_int;
    fn sqlite3_bind_text(
        statement: *mut c_void,
        index: c_int,
        value: *const c_char,
        bytes: c_int,
        destructor: Option<unsafe extern "C" fn(*mut c_void)>,
    ) -> c_int;
    fn sqlite3_bind_blob(
        statement: *mut c_void,
        index: c_int,
        value: *const c_void,
        bytes: c_int,
        destructor: Option<unsafe extern "C" fn(*mut c_void)>,
    ) -> c_int;
    fn sqlite3_column_count(statement: *mut c_void) -> c_int;
    fn sqlite3_column_type(statement: *mut c_void, column: c_int) -> c_int;
    fn sqlite3_column_int64(statement: *mut c_void, column: c_int) -> i64;
    fn sqlite3_column_bytes(statement: *mut c_void, column: c_int) -> c_int;
    fn sqlite3_column_blob(statement: *mut c_void, column: c_int) -> *const c_void;
    fn sqlite3_column_text(statement: *mut c_void, column: c_int) -> *const u8;
    fn sqlite3_changes(db: *mut c_void) -> c_int;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SqliteValue {
    Null,
    Integer(i64),
    Text(String),
    Blob(Vec<u8>),
}
impl SqliteValue {
    pub fn text(&self) -> Option<&str> {
        if let Self::Text(value) = self {
            Some(value)
        } else {
            None
        }
    }
    pub fn integer(&self) -> Option<i64> {
        if let Self::Integer(value) = self {
            Some(*value)
        } else {
            None
        }
    }
    pub fn blob(&self) -> Option<&[u8]> {
        if let Self::Blob(value) = self {
            Some(value)
        } else {
            None
        }
    }
}

pub struct HostSqlite(*mut c_void);
// SAFETY: SQLite FULLMUTEX serializes the connection. The wrapper exposes only
// &mut operations and holds no statement or SQLite-owned pointer across calls.
unsafe impl Send for HostSqlite {}
impl Drop for HostSqlite {
    fn drop(&mut self) {
        // SAFETY: the pointer is a live, exclusively owned SQLite connection.
        unsafe { sqlite3_close_v2(self.0) };
    }
}
struct Statement(*mut c_void);
impl Drop for Statement {
    fn drop(&mut self) {
        // SAFETY: every successful prepare is finalized exactly once.
        unsafe { sqlite3_finalize(self.0) };
    }
}
fn error(code: c_int) -> io::Error {
    io::Error::new(
        if matches!(code & 255, 5 | 6) {
            io::ErrorKind::WouldBlock
        } else {
            io::ErrorKind::InvalidData
        },
        format!("Runtime SQLite operation failed ({code})"),
    )
}
fn check(code: c_int) -> io::Result<()> {
    if code == 0 { Ok(()) } else { Err(error(code)) }
}
impl HostSqlite {
    /// The caller validates the private directory and auxiliary file identities
    /// before opening. NOFOLLOW also rejects a replaced database symlink.
    pub fn open(path: &Path, read_only: bool, create: bool) -> io::Result<Self> {
        use std::os::unix::ffi::OsStrExt;
        if !path.is_absolute() || (read_only && create) {
            return Err(super::invalid("invalid Runtime SQLite open mode"));
        }
        let path = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| super::invalid("invalid SQLite path"))?;
        let mut raw = ptr::null_mut();
        let flags =
            (if read_only { 1 } else { 2 }) | if create { 4 } else { 0 } | 0x10000 | 0x01000000;
        // SAFETY: NUL-terminated path, writable output pointer, default VFS.
        let result = unsafe { sqlite3_open_v2(path.as_ptr(), &mut raw, flags, ptr::null()) };
        if result != 0 || raw.is_null() {
            if !raw.is_null() {
                // SAFETY: SQLite returns a closeable connection even on failure.
                unsafe { sqlite3_close_v2(raw) };
            }
            return Err(error(result));
        }
        let connection = Self(raw);
        // Nonblocking contention is observable. A request must not sit behind
        // another owner's transaction or trigger an automatic mutation retry.
        check(unsafe { sqlite3_busy_timeout(raw, 0) })?;
        Ok(connection)
    }

    pub fn query(
        &mut self,
        sql: &str,
        values: &[SqliteValue],
        maximum_bytes: usize,
    ) -> io::Result<Vec<Vec<SqliteValue>>> {
        let sql = CString::new(sql).map_err(|_| super::invalid("invalid SQLite statement"))?;
        let mut raw = ptr::null_mut();
        let mut tail = ptr::null();
        // SAFETY: SQLite reads a live NUL-terminated string and fills outputs.
        check(unsafe { sqlite3_prepare_v2(self.0, sql.as_ptr(), -1, &mut raw, &mut tail) })?;
        if raw.is_null() {
            return Err(super::invalid("empty SQLite statement"));
        }
        let statement = Statement(raw);
        // SAFETY: tail points into sql, which lives through this call.
        if !unsafe { CStr::from_ptr(tail) }
            .to_bytes()
            .iter()
            .all(u8::is_ascii_whitespace)
            || unsafe { sqlite3_bind_parameter_count(raw) } as usize != values.len()
        {
            return Err(super::invalid("one bound SQLite statement is required"));
        }
        for (offset, value) in values.iter().enumerate() {
            let index = c_int::try_from(offset + 1).map_err(|_| error(18))?;
            // SQLITE_STATIC (null destructor) is safe: values remain borrowed
            // until the statement is stepped and finalized before returning.
            let result = unsafe {
                match value {
                    SqliteValue::Null => sqlite3_bind_null(raw, index),
                    SqliteValue::Integer(value) => sqlite3_bind_int64(raw, index, *value),
                    SqliteValue::Text(value) => sqlite3_bind_text(
                        raw,
                        index,
                        value.as_ptr().cast(),
                        c_int::try_from(value.len()).map_err(|_| error(18))?,
                        None,
                    ),
                    SqliteValue::Blob(value) => sqlite3_bind_blob(
                        raw,
                        index,
                        value.as_ptr().cast(),
                        c_int::try_from(value.len()).map_err(|_| error(18))?,
                        None,
                    ),
                }
            };
            check(result)?;
        }
        let mut rows = Vec::new();
        let mut total = 0usize;
        loop {
            // SAFETY: statement is bound and remains live.
            let result = unsafe { sqlite3_step(statement.0) };
            if result == 101 {
                break;
            }
            if result != 100 {
                return Err(error(result));
            }
            let columns = unsafe { sqlite3_column_count(raw) };
            if !(0..=64).contains(&columns) {
                return Err(error(18));
            }
            let mut row = Vec::new();
            for column in 0..columns {
                let kind = unsafe { sqlite3_column_type(raw, column) };
                let count = unsafe { sqlite3_column_bytes(raw, column) };
                let count = usize::try_from(count).map_err(|_| error(18))?;
                total = total.checked_add(count.max(8)).ok_or_else(|| error(18))?;
                if total > maximum_bytes || count > 16 * 1024 * 1024 {
                    return Err(error(18));
                }
                let value = match kind {
                    1 => SqliteValue::Integer(unsafe { sqlite3_column_int64(raw, column) }),
                    3 | 4 => {
                        let pointer = if kind == 3 {
                            unsafe { sqlite3_column_text(raw, column) }
                        } else {
                            unsafe { sqlite3_column_blob(raw, column) }.cast()
                        };
                        if count > 0 && pointer.is_null() {
                            return Err(error(7));
                        }
                        // SAFETY: column bytes are valid until the next step;
                        // count was bounded before allocating or copying.
                        let bytes = if count == 0 {
                            &[]
                        } else {
                            unsafe { std::slice::from_raw_parts(pointer, count) }
                        };
                        if kind == 3 {
                            SqliteValue::Text(
                                std::str::from_utf8(bytes)
                                    .map_err(|_| error(20))?
                                    .to_owned(),
                            )
                        } else {
                            SqliteValue::Blob(bytes.to_vec())
                        }
                    }
                    5 => SqliteValue::Null,
                    _ => return Err(error(20)),
                };
                row.push(value);
            }
            rows.push(row);
        }
        Ok(rows)
    }

    pub fn execute(&mut self, sql: &str, values: &[SqliteValue]) -> io::Result<usize> {
        if !self.query(sql, values, 0)?.is_empty() {
            return Err(error(20));
        }
        // SAFETY: the connection is live and this observes its last statement.
        usize::try_from(unsafe { sqlite3_changes(self.0) }).map_err(|_| error(20))
    }
}
