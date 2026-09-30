# TASK-XPA-005 — WM1 slice S1 run record: the durable host store on NTFS

Change: CHG-2026-074-shared-rust-runtime-core@r12. Milestone WM1, slice S1 (group 1 "durable host
store" of the TASK-XPA-004 gate inventory: G01 plus the account/state-root part of G09). Base:
protected `main` `64b9af82` (#2334). Host: the Windows 11 x64 reference host, non-elevated, NTFS.
No device was contacted; no operation was submitted; no installed state was touched. Host tests
and hosted CI are not Windows acceptance.

## What

`arkdeck-platform` gains a Windows implementation of the durable host store with the Unix public
surface, file names and bytes:

- `src/windows/host_fs.rs`: the NTFS primitives. Directory-relative opens (`NtCreateFile` with a
  root directory handle, `FILE_OPEN_REPARSE_POINT`, reparse points refused, every share mode);
  `FileIdInfo`/`FileStandardInfo`/`FileBasicInfo` identity; owner SID and DACL reading; protected
  owner-only security descriptors for everything the store creates; `LockFileEx` on one byte at
  offset 2^64-2; POSIX-semantics rename (`NtSetInformationFile(FileRenameInformationEx)`) and
  delete (`FileDispositionInfoEx`); `FlushFileBuffers` for files and write-held directories;
  end-of-file appends; handle-bound enumeration; the canonical-path rule on the opened handle.
- `src/windows/host_store.rs`: `HostDirectory` (the core document, lock, publication and
  Session-publication methods), `HostReadLock`, `HostDocument`, `HostDocumentPass`,
  `HostFileIdentity`, `HostDirectoryFacts`, `PayloadCheck`, `ExclusiveOutcome`,
  `OwnerOnlyReadFailure`, `DocumentPublishError`.
- `src/windows/host_journal.rs`: `HostJournal` and `HostJournalAppender` (`.manifest.lock`,
  `journal.jsonl`, `event-cursor-key.v1`), the Unix record discipline and refusals.
- `src/windows/account.rs`: `application_support_directory()` = the token's
  `FOLDERID_LocalAppData` (Known Folder API; the `LOCALAPPDATA` variable is not read, as Unix does
  not read `HOME`) and `arkdeck_application_support_root()` = its `ArkDeck` child (design §D.2).
- `src/lib.rs`: the Windows exports, in their own `cfg(windows)` block. No Unix or macOS line
  changed; `windows/identity.rs` only widens three helpers to `pub(crate)`.
- `Cargo.toml`: `windows-sys` features `Wdk_Foundation`, `Wdk_Storage_FileSystem`,
  `Win32_System_Com`, `Win32_UI_Shell` (no new crate; `Cargo.lock` unchanged).
- `tests/windows_host_store.rs` (9 tests) and 2 unit tests in `windows::host_store`.

Not in this slice (still macOS-only, listed in the platform README): the export, import-upload,
update, trace-removal, session-removal, diagnostic-log and payload-cache submodules, and the
`std::fs::Metadata`-typed `document_metadata`/`remove_document` (std exposes no stable file id on
Windows `Metadata`, so they need a different signature before they can fail closed there).

## Why each Windows choice

| Unix | Windows | Reason (SPK-5 unless stated) |
| --- | --- | --- |
| `flock` on the separate lock files | `LockFileEx` exclusive on byte 2^64-2 of the same files | Mandatory on NTFS: a locked range refuses reads through any other handle (error 33). A lock far beyond any end of file never covers data, so `mark_catalog_initialized`'s marker (byte 0 of the lock file) and `append_record`'s audit log stay readable. Refused for a second handle in the same process, as `flock` is; released at once when the holder dies. |
| `renameat`, `renameatx_np(RENAME_EXCL)` | `FileRenameInformationEx` with `POSIX_SEMANTICS` (with or without `REPLACE_IF_EXISTS`), relative to the directory handle | `MoveFileExW(REPLACE_EXISTING)` fails with error 5 while any handle holds the target; the POSIX rename succeeds when holders share delete and they keep the old bytes. Every handle the store opens therefore shares read, write and delete. Measured here: Win32 `SetFileInformationByHandle(FileRenameInfoEx)` refuses a root-directory-relative rename with error 87, so `NtSetInformationFile` is called directly. The task text still names `MoveFileExW` write-through; the measurement rules it out. |
| `fsync` (+ `F_FULLFSYNC`), directory `fsync` | `FlushFileBuffers` | A directory flush needs a write-capable directory handle (a read-only one: error 5). Measured here: a handle cannot reopen itself with more access (relative empty-name reopen for write: error 5), so private and Session-tree directories are held with add-entry rights from the start. |
| dev/ino | `FileIdInfo` volume serial + file id | Stable across opens and in-place rewrites. A file id using the upper 64 bits (ReFS) is refused rather than folded into the `u64` inode. `HostJournal::generation` is 0: the NTFS file reference carries its own reuse sequence number. |
| owner euid, mode `0600`/`0700`, no group/other bits (`0o022` for Session trees) | owner SID = token user; no allow ACE for anyone else (Session trees: none with a write right); `0600` = owner may read and write data, sealed `0400` = a protected owner-read-only DACL | Fail closed: a NULL DACL, an object or callback ACE, a foreign owner or a foreign grant refuses. Created entries carry an explicit `O:<user>D:P(A;[OICI];FA;;;<user>)`, so the owner is the user even on an elevated token whose default owner is Administrators. |
| `canonicalize() == path` | `GetFinalPathNameByHandleW` of the opened directory equals the path (plain or `\\?\`) | Refuses junctions, links, 8.3 short names and other-case spellings in any component, decided on the handle that is then held. |
| volume UUID (`uuid:`) | volume GUID of the held handle in the same spelling | The profile's VolumeIdentityResolver: never a drive letter. |

## GJ hop

GJ-1 hops 5/9 (Job journal durability and restart readback), primitive level:
`a_job_journal_survives_process_death_as_a_byte_prefix_and_completes_to_the_recorded_bytes`
replays the macOS-recorded journal `rust/tests/fixtures/agent-execution/store/jobs/job-73b1…/journal.jsonl`
through `HostJournalAppender` in a child process that exits inside an append (mid-record for the
first, second and last record; after the second record's flush). The next process finds a byte
prefix of what was being written, repairs the torn tail through `decide`, completes the journal,
and the file equals the recorded bytes (T0); `HostJournal` reads it back under `.manifest.lock`,
the cursor key is created once and reused on resume, and appends after terminal `manifest.json`
publication are refused.

No `arkdeck-hoststore` owner is un-gated by this slice. Every GJ-1 owner that sits on the host
store also needs G03 or G04: the job journal writer and job events through `session_time`
(`host_gregorian_seconds`); the capability store, recovery epochs and artifact quota through
`swift_decoding::text_key`, whose off-macOS arm silently falls back to raw bytes instead of
canonical equivalence (a T1 divergence the inventory does not list; it must become fail-closed
or portable with G03 before those owners come down). Un-gating them now would fork Runtime
semantics by OS.

## Local targeted checks (Windows 11 x64, rustc per `rust-toolchain.toml`)

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | clean |
| `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-platform --all-targets -- -D warnings` | 0 | clean |
| `cargo clippy --manifest-path rust/Cargo.toml --workspace --all-targets -- -D warnings` | 0 | clean (Windows build of every crate) |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-platform` | 0 | lib 30 passed (2 new); `windows_host_store` 9 passed (new); `windows_transport` 9 passed; `sha256_backend` 1 passed; the other 18 targets are Unix/macOS-gated (0 tests) |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |

No test sleeps: the cross-process lock test synchronizes on the child's output line and kills it;
the blocking-lock test waits on a channel. `manifest_lock`'s 5 s bounded retry is the Unix
production behaviour, mirrored.

macOS and ubuntu cannot be built on this host. The Unix code paths are untouched: every changed
shared line is inside `cfg(windows)` or in `src/windows/`, and `Cargo.toml` changes only the
`cfg(windows)` dependency's features.

## CI

To be recorded, not verified.

## Open for the maintainer / next slices

1. G03 before the host-store owners: `swift_decoding::text_key`/`same_text` fall back to raw bytes
   off macOS. Options: (a) portable canonical-equivalence tables proved by corpora (the inventory's
   G03 plan), or (b) make the off-macOS arm refuse any non-ASCII comparison first, as
   `strict_json::canonical` already does, and port the tables later.
2. `document_metadata`/`remove_document` return `std::fs::Metadata`; a Windows port needs a
   store-owned identity type (e.g. `HostFileIdentity`) in the signature, which changes the macOS
   callers (`snapshot_pager`, `bundle_list_owner`).
3. The remaining submodules (export, import upload, update, trace/session removal, diagnostic log,
   payload cache) follow the same primitives; they belong with their GJ hops (artifact export,
   GJ-1 hop 8; import, GJ-2; update, WM6).
