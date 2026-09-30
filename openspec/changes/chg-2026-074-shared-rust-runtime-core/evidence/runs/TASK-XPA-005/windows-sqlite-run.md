# TASK-XPA-005 — Windows SQLite run record (WM1 slice S3)

Change: CHG-2026-074-shared-rust-runtime-core@r12. Slice: WM1 S3, the gate inventory's group 3 /
G02 ("SQLite links the system libsqlite3", PR #2331
`evidence/runs/TASK-XPA-004/windows-gate-inventory-20260930.md`). Base: `origin/main` `31c0ac28`.

Host measurement only, on the maintainer's Windows 11 x64 reference host (Windows 11 Pro
10.0.26200, non-elevated Claude Code session). No device, HDC, board, elevation, installation or
system change. Nothing here is Windows acceptance, a `supported`/`verified` claim or a
`REAL_DEVICE_PASS`; CI results are recorded on the PR, not here.

## Decision: option A, the SQLite Windows ships (`winsqlite3.dll`)

`HostSqlite` now links `winsqlite3` on Windows, as it links the system `libsqlite3` on macOS. No
crate, no vendored C, no build script: `Cargo.lock`, `deny.toml` and `supply-chain/*` are
unchanged, so the §L.1 item 2 dependency policy is not touched and `cargo deny`/`cargo vet` see
the same graph.

Why A over B (a bundled SQLite: `rusqlite` bundled or the amalgamation via `cc`):

- The macOS Runtime already links the OS library, not the `rusqlite` (bundled) that the design
  document's §E.2 row and the gate inventory's G02 row name. A keeps the two platforms the same
  shape: one binding, the OS's library on each.
- B would add `rusqlite`, `libsqlite3-sys`, `cc` (and their graph) plus ~9 MB of vendored C, each
  needing an exact-version `deny.toml` entry and a cargo-vet audit or publisher-trust rule. That is
  a §L.1 item 2 policy decision for the maintainer, and nothing measured below makes it necessary.
- The durable format is SQLite's stable file format; T0 byte equality of the database file is not
  required (§L.1 item 19). What must be equal is schema, `user_version` and query semantics (T1),
  which the replay below proves on the linked library.

Costs of A, and how they are handled:

- winsqlite3 follows Windows servicing, not a pinned release. `HostSqlite::open` refuses a library
  older than 3.33.0 (`sqlite_schema` needs 3.33.0, `SQLITE_OPEN_NOFOLLOW` 3.31.0) with
  `Unsupported`; the facts test fails below it too.
- The win32 VFS ignores `SQLITE_OPEN_NOFOLLOW` (measured below). `open` refuses a reparse-point
  database itself.

## Library facts measured on this host

Binding checks:

| Fact | Value | How |
| --- | --- | --- |
| DLL | `C:\Windows\System32\winsqlite3.dll`, FileVersion 3.51.1, SHA-256 `35693293036935d8c459850f3a43c7382b81f81b20322d78423e8ec94fb78754` | `Get-Item … .VersionInfo`, `sha256sum` |
| Exports | 297 undecorated `sqlite3_*` names (e.g. `sqlite3_open_v2`, `sqlite3_close_v2`, `sqlite3_prepare_v2`, `sqlite3_column_blob`, `sqlite3_libversion`, `sqlite3_compileoption_get`) | `dumpbin /exports` (MSVC 14.44.35207) |
| Calling convention | `SQLITE_APICALL __stdcall`, `SQLITE_CALLBACK __stdcall` for `NTDDI_VERSION >= NTDDI_WIN10_RS1` | SDK 10.0.26100 `um\winsqlite\winsqlite3.h:84-110`. `__stdcall` is ignored on x64 and ARM64; the binding uses `extern "system"`, which is correct on 32-bit x86 too |
| Import library | `Lib\10.0.26100.0\um\x64\winsqlite3.lib` and `um\arm64\winsqlite3.lib` (297 exports, machine AA64 and A641/ARM64EC, DLL name `winsqlite3.dll`) | `dumpbin /headers /exports` |
| Header version | 3.51.1 (`SQLITE_VERSION`, SDK 10.0.26100) | header |

Linked through the Rust binding (`cargo test -p arkdeck-platform --lib
linked_library_supports_the_runtime_store -- --nocapture`), cross-checked with a ctypes load of
the same DLL:

- `sqlite_version()` = **3.51.1**, source id `2025-11-28 17:28:25 281fc0e9afc38674b9b0991943b9e9d1e64c6cbdb133d35f6f5c87ff6af38a88`,
  `sqlite3_threadsafe()` = 1.
- Fresh-database defaults: `auto_vacuum` 0, `page_size` 4096, `encoding` UTF-8.
- `PRAGMA journal_mode=WAL` answers `wal`; after `PRAGMA synchronous=FULL`, `synchronous` answers 2;
  `user_version` round-trips.
- `PRAGMA compile_options`:
  `ATOMIC_INTRINSICS=0`, `COMPILER=msvc-1938`, `DEFAULT_AUTOVACUUM`, `DEFAULT_CACHE_SIZE=-2000`,
  `DEFAULT_FILE_FORMAT=4`, `DEFAULT_JOURNAL_SIZE_LIMIT=-1`, `DEFAULT_MMAP_SIZE=0`,
  `DEFAULT_PAGE_SIZE=4096`, `DEFAULT_PCACHE_INITSZ=20`, `DEFAULT_RECURSIVE_TRIGGERS`,
  `DEFAULT_SECTOR_SIZE=4096`, `DEFAULT_SYNCHRONOUS=2`, `DEFAULT_WAL_AUTOCHECKPOINT=1000`,
  `DEFAULT_WAL_SYNCHRONOUS=2`, `DEFAULT_WORKER_THREADS=0`, `DIRECT_OVERFLOW_READ`,
  `ENABLE_API_ARMOR`, `ENABLE_BYTECODE_VTAB`, `ENABLE_COLUMN_METADATA`, `ENABLE_DBPAGE_VTAB`,
  `ENABLE_DBSTAT_VTAB`, `ENABLE_FTS3`, `ENABLE_FTS3_PARENTHESIS`, `ENABLE_FTS4`, `ENABLE_FTS5`,
  `ENABLE_GEOPOLY`, `ENABLE_RBU`, `ENABLE_RTREE`, `ENABLE_STAT4`, `ENABLE_STMTVTAB`,
  `MALLOC_SOFT_LIMIT=1024`, `MAX_ATTACHED=10`, `MAX_COLUMN=2000`, `MAX_COMPOUND_SELECT=500`,
  `MAX_DEFAULT_PAGE_SIZE=8192`, `MAX_EXPR_DEPTH=1000`, `MAX_FUNCTION_ARG=1000`,
  `MAX_LENGTH=1000000000`, `MAX_LIKE_PATTERN_LENGTH=50000`, `MAX_MMAP_SIZE=0x7fff0000`,
  `MAX_PAGE_COUNT=0xfffffffe`, `MAX_PAGE_SIZE=65536`, `MAX_SQL_LENGTH=1000000000`,
  `MAX_TRIGGER_DEPTH=100`, `MAX_VARIABLE_NUMBER=32766`, `MAX_VDBE_OP=250000000`,
  `MAX_WORKER_THREADS=8`, `MUTEX_W32`, `OMIT_LOCALTIME`, `SYSTEM_MALLOC`, `TEMP_STORE=1`,
  `THREADSAFE=1`.

What the durable formats need, against those facts. The only SQLite store is the v1 Job index
`runtime-jobs.sqlite3` (`arkdeck-hoststore/src/job_repository.rs`; no other crate opens SQLite).
It uses `CREATE TABLE/INDEX`, `PRAGMA user_version`/`journal_mode=WAL`/`synchronous=FULL`,
`sqlite_schema`, `BEGIN IMMEDIATE`/`BEGIN`/`COMMIT`/`ROLLBACK`, `COALESCE(MAX(…))`,
`COLLATE BINARY`, `LIMIT` and bound text/integer/blob values. It uses no JSON, date/time,
full-text or extension functions, so `OMIT_LOCALTIME` and the FTS/RTREE options do not bear on it.

| Need | winsqlite3 3.51.1 |
| --- | --- |
| WAL journal | not `OMIT_WAL`; `journal_mode=WAL` → `wal` |
| `synchronous=FULL` | answers 2 (`DEFAULT_WAL_SYNCHRONOUS=2` does not matter: the owner sets it) |
| `user_version` | round-trips |
| `sqlite_schema` name | ≥ 3.33.0 |
| `SQLITE_OPEN_FULLMUTEX` (the `Send` claim) | `THREADSAFE=1`, `MUTEX_W32` |
| `SQLITE_OPEN_NOFOLLOW` | flag accepted (≥ 3.31.0) but **not enforced by the win32 VFS**: a ctypes `sqlite3_open_v2(link, READWRITE\|FULLMUTEX\|NOFOLLOW)` on a symbolic link to a database returned `SQLITE_OK`. `HostSqlite::open` now refuses a reparse-point final component with `SQLITE_CANTOPEN_SYMLINK` (1550), what the unix VFS answers, so callers see one behaviour |
| Nonblocking contention | `sqlite3_busy_timeout(0)`, unchanged |

Page size, cache size, `auto_vacuum` and the other defaults are file-level or tuning values the
store neither sets nor reads; the oracle does not record them and T1 does not compare them.

### Windows 11 ARM64 (decision 9)

The SDK ships an ARM64 (and ARM64EC) `winsqlite3.lib` with the same 297 exports, and
`winsqlite3.dll` is an in-box System32 component on Windows 10 and later. This host is x64 and has
only the `x86_64-pc-windows-msvc` Rust target installed (nothing was installed), so the ARM64 link
and the DLL's version on an ARM64 host are **not measured here**. They belong with the ARM64 host of
§L.1 item 14; the facts test prints them there, and `open`'s 3.33.0 floor fails closed if an older
library were found.

## What changed

- `arkdeck-platform/src/host_sqlite.rs`: one `extern "system"` block linked as `sqlite3` on macOS
  and `winsqlite3` on Windows; per-OS `sqlite_path` (unix: bytes, unchanged; Windows: UTF-8 or
  refused, reparse-point refusal, 3.33.0 floor); the open flags named. The module is built on
  `any(target_os = "macos", windows)`; Linux is still not built.
- `arkdeck-hoststore/src/job_index.rs` (new): the Job index's SQL moved verbatim out of
  `job_repository.rs` — schema, layout check, owner journal, admission lookup, `admit`, `describes`,
  `update`, `ROWS`, `AdmissionVerdict`. `job_repository` (macOS) calls it; its behaviour is
  unchanged. On Windows it is built for tests only, because the owner around it still needs the
  durable host-store primitives (G01: `HostDirectory`, `HostReadLock`, file identity) and the
  Runtime timestamp order key (G04: `host_gregorian_seconds`).
- `arkdeck-hoststore/src/job_index_tests.rs` (new, macOS and Windows): the replay below and a
  layout-refusal test.
- `arkdeck-platform/README.md`: "Runtime SQLite (TASK-XPA-005)".

Gates removed: `lib.rs:196-199` of `arkdeck-platform` (`host_sqlite`, `HostSqlite`,
`SqliteValue`) now include Windows. No hoststore owner gate is removed; `job_repository`, the Job
owner and the 87 hoststore test files stay macOS-only until G01/G04 land.

## Parity evidence (T1) on this host

`recorded_swift_indexes_replay_on_the_linked_sqlite` walks `rust/tests/fixtures/**` for every
`index.json` holding `userVersion` — the Job index snapshots the Swift oracle recorded (the
`tests/support::index` projection: schema rows of `sqlite_schema`, `user_version`, `journal_mode`,
every `runtime_job` row with its record's SHA-256). For each snapshot it creates a fresh index
through `job_index::create` on the linked library, sets the owner journal, and for every row admits
it (recorded order key, the Job's `jobs/<id>/job-record.json` as the record) and applies
`version − 1` state updates. It then checks the duplicate and conflict verdicts and that an update
naming another creation time is refused, closes the owner, and compares the oracle projection, as
a whole, with the recorded snapshot twice: through a read-only connection (as `tests/support::index`
reads a closed store) and with the index reopened for writing, as after a restart. It also checks
the Job list order (`created_at_order_key, job_id COLLATE BINARY`).

The first CI run (PR #2335, macOS `xcode-27` workspace job) failed the first version of this test,
which opened the read-only connection *beside the still-open owner*: on the macOS system SQLite the
first query of that connection answered `SQLITE_CANTOPEN` (14); on winsqlite3 it passed. The Job
index code does not read that way (the owner's readers use its own connection; the oracle reader
and `InspectedIndex` read a store no owner holds), so the test now closes the owner first, as the
existing macOS tests do. The cause on macOS was not diagnosed here (no macOS host in this slice).

Result on Windows (x64, winsqlite3 3.51.1):
**153 recorded indexes, 390 rows, all equal**. 368 rows carry the recorded record bytes (their
`job-record.json` SHA-256 equals the recorded `recordSHA256`); for the other 22 rows, whose record
file is not part of the snapshot, a placeholder record stands in, and its digest replaces
`recordSHA256` in the comparison. Every other column, the schema text, `user_version` 1 and
journal mode `wal` are compared as recorded. `a_layout_that_is_not_v1_is_refused` passes: a future
`user_version`, an extra index, a dropped index and an extra table are each refused `InvalidData`.

Not proved here: the order key is replayed as recorded, not computed (computing it is G04's
`host_gregorian_seconds`), and the owner's file checks (G01) are not run. No recorded durable
SQLite *file* exists in the fixtures (the oracle records the projection, not database bytes), so
there is no macOS-written database file to read back; the SQLite file format is what makes such a
file readable.

## Checks run locally (Windows x64, rustc 1.98.1, `CARGO_TARGET_DIR` on D:)

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: pass.
- `cargo clippy --manifest-path rust/Cargo.toml --workspace --all-targets -- -D warnings`: pass
  (Windows).
- `cargo test -p arkdeck-platform -p arkdeck-hoststore`: pass. Platform unit tests 25 (6 SQLite,
  including the Windows-only verbatim/drive path, non-Unicode refusal and linked-database refusal;
  symbolic links were creatable on this host, so the link case ran rather than skipped);
  hoststore unit tests 8 (2 new); the macOS-gated test targets build empty on Windows.
- macOS and Linux were not built here. The macOS arm of every changed `cfg` was re-read: the unix
  `sqlite_path` is the previous byte conversion; `job_repository` calls `job_index` with the same
  statements, values and transaction boundaries. CI decides.
