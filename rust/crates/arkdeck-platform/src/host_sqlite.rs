//! Bounded SQLite calls for the Runtime store. SQL is supplied by the
//! repository implementation, never by a control request. The connection is
//! single-thread owned; callers serialize access at the repository boundary.
//!
//! Both platforms link the SQLite their OS ships, so no SQLite source enters
//! the build: macOS the system `libsqlite3`, Windows `winsqlite3.dll` (in
//! System32 since Windows 10, import library `winsqlite3.lib` in the Windows
//! SDK). winsqlite3 declares its fixed-argument API `__stdcall`; `extern
//! "system"` is that convention on 32-bit Windows and the C convention on
//! every other target, where the two are the same (TASK-XPA-005).
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::io;
use std::path::Path;
use std::ptr;

#[cfg_attr(target_os = "macos", link(name = "sqlite3"))]
#[cfg_attr(windows, link(name = "winsqlite3"))]
unsafe extern "system" {
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
        destructor: Option<unsafe extern "system" fn(*mut c_void)>,
    ) -> c_int;
    fn sqlite3_bind_blob(
        statement: *mut c_void,
        index: c_int,
        value: *const c_void,
        bytes: c_int,
        destructor: Option<unsafe extern "system" fn(*mut c_void)>,
    ) -> c_int;
    fn sqlite3_column_count(statement: *mut c_void) -> c_int;
    fn sqlite3_column_type(statement: *mut c_void, column: c_int) -> c_int;
    fn sqlite3_column_int64(statement: *mut c_void, column: c_int) -> i64;
    fn sqlite3_column_bytes(statement: *mut c_void, column: c_int) -> c_int;
    fn sqlite3_column_blob(statement: *mut c_void, column: c_int) -> *const c_void;
    fn sqlite3_column_text(statement: *mut c_void, column: c_int) -> *const u8;
    fn sqlite3_changes(db: *mut c_void) -> c_int;
    #[cfg(windows)]
    fn sqlite3_libversion_number() -> c_int;
}

/// SQLITE_OPEN_READONLY/READWRITE/CREATE, FULLMUTEX, NOFOLLOW.
const OPEN_READ_ONLY: c_int = 0x1;
const OPEN_READ_WRITE: c_int = 0x2;
const OPEN_CREATE: c_int = 0x4;
const OPEN_FULL_MUTEX: c_int = 0x10000;
const OPEN_NO_FOLLOW: c_int = 0x0100_0000;
/// SQLITE_CANTOPEN_SYMLINK, what NOFOLLOW answers for a linked database.
#[cfg(windows)]
const CANT_OPEN_SYMLINK: c_int = 14 | (6 << 8);
/// The oldest library whose semantics the Runtime's durable formats rely on:
/// the `sqlite_schema` name (3.33.0) and SQLITE_OPEN_NOFOLLOW (3.31.0). The
/// macOS library is pinned by the platform's minimum OS; winsqlite3 follows
/// Windows servicing, so it is checked before every open.
#[cfg(windows)]
const MINIMUM_VERSION: c_int = 3_033_000;

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
        if !path.is_absolute() || (read_only && create) {
            return Err(super::invalid("invalid Runtime SQLite open mode"));
        }
        let path = sqlite_path(path)?;
        let mut raw = ptr::null_mut();
        let flags = (if read_only {
            OPEN_READ_ONLY
        } else {
            OPEN_READ_WRITE
        }) | if create { OPEN_CREATE } else { 0 }
            | OPEN_FULL_MUTEX
            | OPEN_NO_FOLLOW;
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
        self.query_map(sql, values, maximum_bytes, Ok)
    }

    /// Project each owned row before stepping to the next. The cumulative byte
    /// budget still covers every source column, including discarded payloads.
    /// An error drops all projected results and finalizes the statement.
    pub fn query_map<T>(
        &mut self,
        sql: &str,
        values: &[SqliteValue],
        maximum_bytes: usize,
        mut project: impl FnMut(Vec<SqliteValue>) -> io::Result<T>,
    ) -> io::Result<Vec<T>> {
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
            rows.push(project(row)?);
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

/// The UTF-8 path SQLite opens. The unix VFS refuses a linked database itself
/// under NOFOLLOW.
#[cfg(unix)]
fn sqlite_path(path: &Path) -> io::Result<CString> {
    use std::os::unix::ffi::OsStrExt;
    CString::new(path.as_os_str().as_bytes()).map_err(|_| super::invalid("invalid SQLite path"))
}

/// The UTF-8 path winsqlite3 opens (its VFS converts it to UTF-16); a path
/// that is not Unicode has no such spelling and is refused. The win32 VFS does
/// not implement NOFOLLOW, so a database that is a reparse point is refused
/// here with the code the unix VFS answers, checked as that VFS checks it:
/// the final component, before the open.
#[cfg(windows)]
fn sqlite_path(path: &Path) -> io::Result<CString> {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    // SAFETY: a constant query of the loaded library.
    if unsafe { sqlite3_libversion_number() } < MINIMUM_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "the system SQLite library is older than the Runtime store requires",
        ));
    }
    let text = path
        .to_str()
        .ok_or_else(|| super::invalid("invalid SQLite path"))?;
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 => {
            return Err(error(CANT_OPEN_SYMLINK));
        }
        Ok(_) => (),
        Err(error) if error.kind() == io::ErrorKind::NotFound => (),
        Err(error) => return Err(error),
    }
    CString::new(text).map_err(|_| super::invalid("invalid SQLite path"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh private directory below the account's temporary root.
    fn scratch(label: &str) -> std::path::PathBuf {
        let nonce = u128::from_ne_bytes(crate::random_bytes::<16>().unwrap());
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("sqlite-{label}-{nonce:x}"));
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut std::fs::DirBuilder::new(), 0o700)
            .create(&root)
            .unwrap();
        #[cfg(windows)]
        std::fs::create_dir(&root).unwrap();
        root
    }

    #[test]
    fn projection_preserves_source_budget_and_finalizes_on_failure() {
        let root = scratch("projection");
        let mut db = HostSqlite::open(&root.join("store.sqlite"), false, true).unwrap();
        db.execute("CREATE TABLE rows (id INTEGER, payload BLOB)", &[])
            .unwrap();
        for id in 0..3 {
            db.execute(
                "INSERT INTO rows VALUES (?, ?)",
                &[SqliteValue::Integer(id), SqliteValue::Blob(vec![42; 1024])],
            )
            .unwrap();
        }
        let sql = "SELECT id, payload FROM rows ORDER BY id";
        let projected = db
            .query_map(sql, &[], 3096, |row| Ok(row[0].integer().unwrap()))
            .unwrap();
        assert_eq!(projected, [0, 1, 2]);
        // Dropping every payload does not bypass the original aggregate limit.
        assert!(db.query_map(sql, &[], 3095, |_| Ok(())).is_err());
        let error = db
            .query_map(sql, &[], 3096, |row| {
                if row[0].integer() == Some(1) {
                    Err(io::Error::other("projection failed"))
                } else {
                    Ok(())
                }
            })
            .unwrap_err();
        assert_eq!(error.to_string(), "projection failed");
        // Both failure paths finalize their statement and release its read lock.
        db.execute("DROP TABLE rows", &[]).unwrap();
        drop(db);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// The facts of the linked library the Runtime store relies on. `cargo
    /// test -- --nocapture` prints the version and compile options, which the
    /// TASK-XPA-005 run record keeps for each platform.
    #[test]
    fn linked_library_supports_the_runtime_store() {
        let root = scratch("facts");
        let mut db = HostSqlite::open(&root.join("facts.sqlite3"), false, true).unwrap();
        let version = db.query("SELECT sqlite_version()", &[], 1024).unwrap();
        let [row] = version.as_slice() else {
            panic!("one version row")
        };
        let version = row[0].text().unwrap().to_owned();
        let parts: Vec<u32> = version.split('.').map(|n| n.parse().unwrap()).collect();
        assert!(parts.as_slice() >= [3, 33, 0].as_slice(), "{version}");
        let options: Vec<String> = db
            .query("PRAGMA compile_options", &[], 64 * 1024)
            .unwrap()
            .into_iter()
            .map(|row| row[0].text().unwrap().to_owned())
            .collect();
        println!("sqlite_version={version}");
        for option in &options {
            println!("compile_option={option}");
        }
        // File-level defaults the store never sets; recorded, not pinned.
        for pragma in ["auto_vacuum", "page_size", "encoding"] {
            let value = db.query(&format!("PRAGMA {pragma}"), &[], 1024).unwrap();
            println!("pragma_{pragma}={:?}", value[0][0]);
        }
        for absent in [
            "OMIT_WAL",
            "OMIT_PRAGMA",
            "OMIT_SCHEMA_PRAGMAS",
            "THREADSAFE=0",
        ] {
            assert!(!options.iter().any(|o| o == absent), "{absent}");
        }
        // The store's pragmas answer as the Job index expects them.
        assert_eq!(
            db.query("PRAGMA journal_mode=WAL", &[], 1024).unwrap(),
            [[SqliteValue::Text("wal".into())]]
        );
        db.execute("PRAGMA synchronous=FULL", &[]).unwrap();
        assert_eq!(
            db.query("PRAGMA synchronous", &[], 1024).unwrap(),
            [[SqliteValue::Integer(2)]]
        );
        db.execute("PRAGMA user_version=1", &[]).unwrap();
        assert_eq!(
            db.query("PRAGMA user_version", &[], 1024).unwrap(),
            [[SqliteValue::Integer(1)]]
        );
        drop(db);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn open_mode_refuses_relative_paths_and_read_only_creation() {
        let root = scratch("mode");
        let error = HostSqlite::open(Path::new("store.sqlite3"), false, true)
            .err()
            .unwrap();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        let error = HostSqlite::open(&root.join("store.sqlite3"), true, true)
            .err()
            .unwrap();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        // A missing database is not created without `create`.
        assert!(HostSqlite::open(&root.join("store.sqlite3"), false, false).is_err());
        assert!(!root.join("store.sqlite3").exists());
        std::fs::remove_dir_all(root).unwrap();
    }

    /// winsqlite3 opens the path spellings the Runtime resolves: the verbatim
    /// form `canonicalize` returns and the plain drive form, as one file.
    #[cfg(windows)]
    #[test]
    fn windows_paths_open_one_database() {
        let root = scratch("paths");
        let verbatim = root.join("store.sqlite3");
        let text = verbatim.to_str().unwrap();
        assert!(text.starts_with(r"\\?\"), "{text}");
        let mut db = HostSqlite::open(&verbatim, false, true).unwrap();
        db.execute("CREATE TABLE t(v)", &[]).unwrap();
        db.execute("INSERT INTO t VALUES(7)", &[]).unwrap();
        drop(db);
        let plain = std::path::PathBuf::from(&text[4..]);
        let mut db = HostSqlite::open(&plain, true, false).unwrap();
        assert_eq!(
            db.query("SELECT v FROM t", &[], 1024).unwrap(),
            [[SqliteValue::Integer(7)]]
        );
        drop(db);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// A path with no Unicode spelling is refused before SQLite sees it.
    #[cfg(windows)]
    #[test]
    fn windows_non_unicode_path_is_refused() {
        use std::os::windows::ffi::OsStringExt;
        let root = scratch("unicode");
        let name = std::ffi::OsString::from_wide(&[0x61, 0xD800, 0x62]);
        let error = HostSqlite::open(&root.join(name), false, true)
            .err()
            .unwrap();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// NOFOLLOW parity: a database that is a reparse point is refused with
    /// SQLITE_CANTOPEN_SYMLINK, as the unix VFS refuses it. Creating a
    /// symbolic link needs the privilege or Developer Mode; without it the
    /// case is reported and skipped, never passed silently.
    #[cfg(windows)]
    #[test]
    fn windows_linked_database_is_refused() {
        let root = scratch("link");
        let target = root.join("target.sqlite3");
        drop(HostSqlite::open(&target, false, true).unwrap());
        let link = root.join("store.sqlite3");
        if let Err(error) = std::os::windows::fs::symlink_file(&target, &link) {
            eprintln!("skipped: no symbolic link privilege ({error})");
            std::fs::remove_dir_all(root).unwrap();
            return;
        }
        for (read_only, create) in [(false, false), (true, false), (false, true)] {
            let error = HostSqlite::open(&link, read_only, create).err().unwrap();
            assert_eq!(error.to_string(), "Runtime SQLite operation failed (1550)");
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}
