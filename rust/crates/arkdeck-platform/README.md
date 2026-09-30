# Platform boundary (TASK-XPA-002)

The crate supplies authenticated local byte streams and bounded, hash-pinned
read-only process execution. No wire contract contains its executable paths,
argument arrays or installation identity configuration. It has no capability,
recovery, journal or device-mutation API.

- Unix sockets require a physical owner-only `0700` parent and a `0600` socket;
  both ends verify peer effective UID. Bind never unlinks an existing endpoint.
- Windows listeners explicitly use the current logon SID DACL,
  `FILE_FLAG_FIRST_PIPE_INSTANCE` and `PIPE_REJECT_REMOTE_CLIENTS`. A name
  another server already holds refuses bind as "held by another instance",
  whether the holder allows more instances (`ERROR_ACCESS_DENIED`) or only one
  (`ERROR_PIPE_BUSY`); bind never waits for or retries against it. The accepted
  connection's client PID is held through a process handle and checked against
  the daemon's user SID and elevation before a handler can receive it.
- Windows clients use identification SQOS, compare pipe owner SID to their own
  token owner SID, then verify this connection's server PID, installed image
  path, and a trusted Authenticode signing-certificate SHA256 or exact MSIX family.
  They retain the process and image handles until disconnect. If server PID is
  unavailable, they fail before sending frames; no identity fallback is enabled.
- `VerifiedTool` retains the hashed regular file. macOS launches its `/.vol`
  inode path suspended, revalidates before resuming, and retains the child PID
  with `WNOWAIT` until process-group cleanup. Windows denies file writes/deletion,
  holds physical parent directories against replacement, starts suspended,
  checks the child image, assigns a kill-on-close job and then resumes it. Both
  use argv arrays, a clean child environment, combined stdout/stderr limits and
  deadlines. The only provider environment override is a numeric
  `OHOS_HDC_SERVER_PORT`; it never changes the user's environment.
- Process output completion uses bounded channel waits. Unix readers are
  nonblocking; the Windows reader peeks before reading available bytes, with one
  reader per pipe. Termination errors are returned, and Windows cleanup waits for
  the retained process and an empty Job Object within a five-second budget.
  Named-pipe I/O expiry requests cancellation, then drains kernel completion to
  keep the borrowed buffer safe. A strict cancellation wall-clock bound is not
  established by this implementation or cross compilation; native cancellation
  latency and races remain part of SPK-3 validation.
- The Windows `LoopbackServerLease` reads the kernel TCP owner tables (IPv4 and
  IPv6, `GetExtendedTcpTable`) without a network connection or process spawn,
  as the macOS lease reads libproc (TASK-XPA-005). The candidates are the owners
  of a listener on the endpoint's port whose image is the verified path; exactly
  one must own exactly one listener, bound to `127.0.0.1` or `::ffff:127.0.0.1`,
  run the verified tool's file (`FileIdInfo`, whose bytes the SHA-256 pin covers)
  as the calling user and elevation, and two scans must agree. The lease holds
  the process handle and yields a `ServerIdentityReceipt` (PID, `GetProcessTimes`
  creation time as Unix seconds/microseconds, path, digest, endpoint). No
  candidate is `NotFound`; a wildcard, a second listener, a second process, an
  owner that cannot be inspected or a changed file is `PermissionDenied`. No argv
  is read: Windows has no supported read of another process's command line.
- `VerifiedTool::run_tool` and `ManagedServer::launch` run on Windows too
  (TASK-XPA-005): `CreateProcessW` from the argv array, suspended, admitted into
  a kill-on-close Job object and resumed once its image is the retained file; the
  base environment `PATH`/`SystemRoot`/`WINDIR` plus a named overlay that cannot
  replace the base or set `__COMPAT_LAYER` (names compared ignoring case); an
  optional canonical (`\\?\`-spelled) working directory; `NUL` stdin; per-stream
  capture with drain (blocking readers cancelled with `CancelSynchronousIo` once
  stopped); a deadline or cancellation that terminates the whole Job at once
  (there is no TERM; the owner's exit code is 1). `ManagedServer::verifies`
  proves a receipt names that very child (launch record, creation time, image
  file, membership of its own Job, declared `-s <endpoint>`, loopback or
  wildcard listener) in place of the macOS argv read.

The trust boundary is the current design F.2: arbitrary same-user code is outside
the boundary; the same user's correctly signed installed daemon is trusted.
The stricter failure when server PID is unavailable does not establish whether
that API works on supported Windows builds. SPK-3 measures it on a `CreateFileW`
client handle, since the [Microsoft reference](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeserverprocessid)
still describes a `CreateNamedPipe` handle. Pipe access rights follow
[Named Pipe Security and Access Rights](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights).

## Durable host store on NTFS (TASK-XPA-005)

`src/windows/host_store.rs`, `host_journal.rs` and `host_fs.rs` give Windows the
same `HostDirectory`, `HostReadLock`, `HostDocument`, `HostJournal` and
`HostJournalAppender` surface as the Unix `host_store.rs`, with the same file
names and bytes (T0): only the OS primitive under each check differs, chosen
from the SPK-5 facts measured on NTFS.

| Unix | Windows |
| --- | --- |
| `openat(dirfd, name, O_NOFOLLOW)` | `NtCreateFile` relative to the held directory handle with `FILE_OPEN_REPARSE_POINT`, a reparse point refused; every handle shares read, write and delete |
| `fstat` dev/ino, size, mtime/ctime | `FileIdInfo` (volume serial, file id), `FileStandardInfo`, `FileBasicInfo` last-write and change times; a file id beyond 64 bits (ReFS) is refused, never folded |
| owner = euid; mode `0600`/`0700`, no group or other bits | owner SID = token user; the DACL grants nobody else anything (a Session tree: nobody else any write right); entries are created with an explicit protected owner-only DACL |
| `flock(LOCK_EX)` on the separate lock files | `LockFileEx` on one byte at offset 2^64-2 of the same lock files: NTFS locks are mandatory, so the lock never covers a byte anyone reads (the catalog marker in byte 0 stays readable); released when the holder dies |
| `renameat`, `renameatx_np(RENAME_EXCL)` | `NtSetInformationFile(FileRenameInformationEx)` with POSIX semantics, replacing or not, relative to the directory handle; readers holding the old file keep its bytes |
| `unlinkat` | `FileDispositionInfoEx` delete with POSIX semantics |
| `fsync`, `F_FULLFSYNC`, directory `fsync` | `FlushFileBuffers`; directories the store writes in are held with add-entry rights, which a directory flush needs |
| `O_APPEND` | `WriteFile` at the documented end-of-file offset |
| `canonicalize() == path` | the held handle's `GetFinalPathNameByHandleW` equals the path (plain or `\\?\` spelling): no junction, link, short name or other case |
| volume UUID | the volume GUID of the held handle, in the same `uuid:` spelling |

`application_support_directory()` is the account's `FOLDERID_LocalAppData`
(Known Folder API, never the `LOCALAPPDATA` variable, as Unix ignores `HOME`);
`arkdeck_application_support_root()` is its `ArkDeck` child. Not yet on
Windows: the export, update, trace-removal, session-removal,
diagnostic-log and payload-cache submodules, and the `std::fs::Metadata`-typed
`document_metadata`/`remove_document`. `PayloadCheck::Unopenable` carries a
Win32 error code on Windows. `HostJournal::generation` is 0 on NTFS, whose
file reference already carries a reuse sequence number.

`tests/windows_host_store.rs` replays a macOS-recorded Job journal through a
process that dies inside an append (mid-record, and after the record's flush),
repairs the byte-prefix tail in the next process, completes the journal to the
recorded bytes and reads it back under the lock. It also covers the refusals
(hard links, junctions, foreign ACEs, reserved name characters, non-canonical
paths), lock exclusion within and across processes and its release on kill,
and readers that keep their bytes across a replace.

## Import upload on NTFS (TASK-XPA-008)

`src/windows/host_import_upload.rs` gives Windows the import-upload submodule
with the Unix names, bounds, bytes and refusals: `HostImportSource`,
`HostUploadFile` (with `HostUploadReader`, `UploadChunkCheckpoint`,
`UploadWritePoint`) and `HostDirectory::publish_import_checkpoint`.

- The source is opened by `CreateFileW` with `FILE_FLAG_OPEN_REPARSE_POINT`
  (a link or junction as its last component is refused as `O_NOFOLLOW`
  refuses it; a `:` stream name and any non-disk handle too) and shared for
  reading only: while it is held nobody writes it, renames it, or replaces or
  deletes its name. Its `FileIdInfo` identity, size, link count, attributes
  and both times are still compared before and after every chunk, and its name
  is reopened for its attributes and must still name the same file, which
  catches what no share mode refuses (a metadata change, a new hard link, a
  replaced parent directory).
- Staging files are created owner-only (`0600`) only for a durable
  zero-offset checkpoint, written by offset, flushed with `FlushFileBuffers`,
  and must stay the owner's single-link regular file bound to their name.
- An Artifact payload is copied into a private `.<name>.<nonce>.tmp`, digest
  checked, sealed owner read-only (`0400`) through the handle opened before
  the seal, flushed and renamed with POSIX semantics and no replace
  (`RENAME_EXCL`): an existing Artifact is never replaced. An interrupted
  copy is deleted through its own handle; one left by a killed process is
  reclaimed by the next publication after the same owner-only check.
- `checkpoint_identity` keeps the Unix eleven-field order (generation 0; the
  owner's granted rights and the attributes where Unix has uid and mode). It
  is an in-memory cache key, never persisted.

`tests/host_import_upload.rs` runs on macOS and Windows alike: the recorded
`import-upload-current` source read by identity, staged to the recorded Swift
committed prefix (T0), recovered, completed and published to the recorded
digest; the frozen checkpoint records published and replaced; a source whose
identity changes mid-read refused (and on Windows its name cannot be replaced
while it is held); symbolic-link and junction sources refused; an existing
Artifact never replaced; and a writer killed inside an append leaving a byte
prefix and no Artifact, rolled back to the recorded prefix and completed by
the next lifetime, which also reclaims a killed publisher's copy file.

## Validation

```sh
cargo test -p arkdeck-platform
cargo clippy -p arkdeck-platform --all-targets -- -D warnings
cargo check -p arkdeck-platform --target x86_64-pc-windows-msvc --all-targets
cargo run -p arkdeck-platform --example windows_spk3 -- process-selftest
```

The tests create isolated host fixtures. macOS results and a Windows cross build
do not count as Windows OS or hardware acceptance. Windows-native tests cover
actual named-pipe name ownership, same-account wrong-image/unsigned-server
zero-frame refusals, exact completion counts, rapid-disconnect recovery, exit
code 259, open-writer behavior, cleanup failure reporting, checked token/TCP
array lengths, existing-listener kernel identity, the tool runner and managed
server (`tests/windows_tool_dispatch.rs`, whose fake tool is the test binary
itself, a `harness = false` target) and Job kill-on-close of a live child tree
(`windows::process::tests`). Successful trusted
publisher/package authentication, cross-account/elevation/remote tests and
packaged client access still need the corresponding real host/setup.

## SPK-3 on Windows

Build `cargo build --release -p arkdeck-platform --example windows_spk3` and use
`rust/scripts/windows-spk3.ps1` with the actual daemon, CLI and probe paths plus
the installation's signer/package identity. Supply a new output directory;
the script refuses to overwrite prior records. It only controls its own test
daemon/probe processes. It does not start HDC, install certificates/drivers,
unblock downloaded executables, change policy or create accounts.

The script records binary hashes, OS build/architecture, MotW and Authenticode
state, the client-handle server-PID result, first-instance and same-account squat
refusals, product command output, and remaining setup conditions. A supplied
second-account credential enables cross-account checks. A supplied distinct
remote session plus identical probe enables the remote-client test. A registered
MSIX probe can prove package identity and connection; the script checks the
observed family instead of inferring packaging from its path. Credentials are
never written to the record.

Supply `-PythonPath` with a Python interpreter containing `jsonschema` to validate
the recorded CLI envelopes and method results. The harness first confirms that
all producer processes have exited and all outputs have drained, writes
`spk3.json` with `recordingComplete`, then invokes
`check-readonly.py --spk3-recordings`. The derived `spk3-schema-validation.json`
and `schema-invocation.json` record that later result without rewriting the raw
host record. Missing interpreter/dependencies or unfinished recording remain
unvalidated, never a schema or device acceptance pass.

For an elevated same-user client, first run this in the normal user's terminal
with an isolated `\\.\pipe\arkdeck-spk3-*` endpoint:

```powershell
& $ProbePath guard-server $Endpoint
```

Then run this from a separately elevated terminal:

```powershell
& $ProbePath raw-connect $Endpoint
```

This raw probe sends zero bytes and checks OS connection behavior only. A pipe
open may succeed before the daemon's SID/elevation validation closes it; proving
the server refusal additionally requires the `guard-server-result` record to
show `authenticated: false` and `frameConsumerEntries: 0`.
Do not describe a client-only result as proof that no handler ran.

The host record remains `INCOMPLETE` until its external conditions and actual
DAYU200/current Windows HDC profile are reviewed. A zero exit code for candidates
does not prove the connected board's identity, and an empty result does not pass
hardware acceptance. Existing Windows tuple/driver/signing gaps are not replaced
with a fixture, fabricated hash registration or a support declaration.

## Runtime SQLite (TASK-XPA-005)

`HostSqlite` (`src/host_sqlite.rs`) links the SQLite the OS ships and adds no
crate or C source: the system `libsqlite3` on macOS, `winsqlite3.dll` on
Windows (in System32 since Windows 10; import library `winsqlite3.lib` in the
Windows SDK `um\x64` and `um\arm64`). winsqlite3 exports the undecorated
`sqlite3_*` names and declares its fixed-argument API `__stdcall`, which the
binding spells `extern "system"`: that is the C convention on x64 and ARM64.
Linux does not build it yet.

Two Windows differences are handled inside `open`, so callers see the macOS
behaviour:

- The win32 VFS ignores `SQLITE_OPEN_NOFOLLOW` (measured: winsqlite3 3.51.1
  opens a symbolic link to a database). `open` refuses a final path component
  that is a reparse point with `SQLITE_CANTOPEN_SYMLINK` (1550), the answer
  the unix VFS gives, checked as that VFS checks it: before the open.
- The path is passed as UTF-8, which winsqlite3 converts to UTF-16; a path with
  no Unicode spelling is refused. Verbatim (`\?\`) and drive paths name the
  same database.

winsqlite3 follows Windows servicing rather than a pinned release, so `open`
refuses a library older than 3.33.0 (`sqlite_schema`, NOFOLLOW). The Job
index's SQL (`arkdeck-hoststore/src/job_index.rs`) replays every Job index the
Swift oracle recorded under `rust/tests/fixtures` on each platform's library
and reads back the recorded schema, `user_version`, journal mode and rows. The
measured library facts are in the TASK-XPA-005 run record; print them with:

```sh
cargo test -p arkdeck-platform --lib linked_library_supports_the_runtime_store -- --nocapture
```

## DevEco files and pinned signing files on Windows (TASK-XPA-011)

`src/windows/deveco_files.rs` is the Windows `DevEcoRoot`/`DevEcoRole`
reader (gate G15): the same no-follow, bounded, identity-checked reads as
`host_deveco_files.rs` over a Windows DevEco Studio directory (default
`%ProgramFiles%\Huawei\DevEco Studio`), which is a plain directory rather than
a signed `.app` bundle:

| Role | macOS (`<X>.app/Contents/…`) | Windows (`<root>\…`) |
| --- | --- | --- |
| `productManifest` | `Resources/product-info.json` | `product-info.json` |
| `sdkManifest` | `sdk/default/sdk-pkg.json` | `sdk\default\sdk-pkg.json` |
| `node` | `tools/node/bin/node` (execute bits) | `tools\node\node.exe` (a `.exe` the caller holds `FILE_EXECUTE` on) |
| `hvigor` | `tools/hvigor/bin/hvigorw.js` | `tools\hvigor\bin\hvigorw.js` |
| `signedResourceEnvelope` | `_CodeSignature/CodeResources` | none: Windows binds no manifest to a publisher signature, so the role does not exist |

The root must be a canonical drive path holding the Windows launcher
`bin\devecostudio64.exe`; any other layout (a macOS tree on a Windows disk, a
relative, UNC, `.`/`..`, other-case or short-name spelling, a junction
anywhere) is refused. Every directory from the drive root down and every
child is opened relative to its parent without following a reparse point and
must be owned by the token user or a trusted principal (`SYSTEM`,
`Administrators`, `TrustedInstaller`, the places of Unix root) with no write
right for anyone else; the drive root alone may let others add entries (the
`/Applications`/sticky `/tmp` exception). A child's facts are the host store's
`HostFileIdentity` (volume serial, `FileIdInfo` file id, size, last-write and
change times), its link count (exactly 1) and whether it is executable.
`host_deveco_resources` and `property_list` stay macOS-only: Windows DevEco
ships no property list. The manifests' facts are parsed portably by
`arkdeck-hoststore::parse_deveco_manifests` (launch entry `Windows`/`amd64`).

`src/windows/pinned_file.rs` (`measure_host_file`, `host_resolved_path`) is
what the signing layer's `measure`/`foundation_resolved_path`
(`arkdeck-provider-workspace/src/file_identity.rs`) run on Windows: one
no-follow handle answers the file's identity, owner and DACL, execute right
and SHA-256, and the identity is taken again on that handle and on a second
open of the path after the last byte, so a file written or replaced while it
is measured is refused. `tests/windows_deveco_files.rs` covers both against
fixture trees (synthetic manifests; the scratch base is the account's
`LocalAppData`, since the temporary directory may grant other principals
write), plus an ignored, shape-only probe of a local installation:

```sh
ARKDECK_LIVE_DEVECO_ROOT='<DevEco root>' cargo test -p arkdeck-platform --test windows_deveco_files -- --ignored live_deveco
```
