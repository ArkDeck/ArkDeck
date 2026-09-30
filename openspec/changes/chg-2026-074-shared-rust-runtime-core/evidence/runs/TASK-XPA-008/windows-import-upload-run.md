# TASK-XPA-008 — slice U1 run record: the host store's import upload on NTFS

Change: CHG-2026-074-shared-rust-runtime-core. Slice U1, a TASK-XPA-008 prerequisite (gate
inventory G40 on G01): the host-store import-upload submodule and `HostImportSource` on Windows,
so GJ-2's durable import can later run there. Base: protected `main` `84a44be1` (#2345). Host:
the Windows 11 x64 reference host, non-elevated, NTFS. No device was contacted; no operation was
submitted; no installed state was touched. Host tests and hosted CI are not Windows acceptance.

## What

`arkdeck-platform` gains `src/windows/host_import_upload.rs`, a submodule of the NTFS host store
(#2338), with the Unix `host_import_upload.rs` public surface, names, bounds, bytes and refusals:

- `HostImportSource` (open, `check_identity`, `chunk`; `name`, `byte_count`, `sha256`).
- `HostUploadFile` (`open`, `byte_count`, `checkpoint_identity`, `complete_digest`,
  `validator_bytes`, `validator_reader`, `publish_immutable`, `recover`, `append`,
  `append_with_checkpoint`), `HostUploadReader`, `UploadChunkCheckpoint`, `UploadWritePoint`.
- `HostDirectory::publish_import_checkpoint`.

`src/lib.rs` exports them in the existing `cfg(windows)` block; `src/windows/host_store.rs`
declares the submodule. No Unix or macOS line changed: the macOS `host_import_upload.rs` is
untouched, and `host_fs.rs` is unchanged.

| Unix | Windows | Why |
| --- | --- | --- |
| source `open(O_NOFOLLOW)` | `CreateFileW` with `FILE_FLAG_OPEN_REPARSE_POINT`; a reparse point answers `ERROR_STOPPED_ON_SYMLINK` (the `ELOOP`); a `:` stream name, a non-disk handle, a directory, an empty or over-bound file refused | a link or junction as the last component is never read through; intermediate components resolve as they do on macOS |
| source identity = `fstat` before/after every chunk + `lstat(path)` dev/ino | `FileIdInfo`, size, link count, attributes, last-write and change times of the held handle before/after every chunk + the name reopened for `FILE_READ_ATTRIBUTES` must be a regular file with the same volume and file id | a changed file, a new hard link, a metadata change or a replaced name refuses (`InvalidData`, the CLI's "source changed") |
| (no share modes) | the source is shared for reading only | while held nobody writes it, renames it, or replaces or deletes its name (SPK-5: a POSIX rename over a name held without delete sharing fails); a source another process holds open for writing cannot be opened (error 32, "Import source cannot be opened") |
| stage `openat(O_CREAT\|O_EXCL, 0600)` only for a zero-offset checkpoint | `NtCreateFile(FILE_CREATE)` relative to the held payloads directory with the protected owner-only DACL, only when `allow_create` | an absent committed prefix is never replaced by a new empty stage |
| `private_regular` (regular, `mode & 077 == 0`, owner, one link) | regular, one link, owner SID = token user, no grant to anyone else | the store's owner-only reading of `0600` |
| `F_FULLFSYNC` | `FlushFileBuffers` on the file; the directory barrier on the write-held directory handle | SPK-5 |
| payload: `.tmp` copy, digest, `fchmod 0400`, `renameatx_np(RENAME_EXCL)` | the same `.tmp` copy (opened with write and `WRITE_DAC` before the seal), digest, the sealed owner-read-only DACL, POSIX rename without replace | an existing Artifact is never replaced (`AlreadyExists`); readers of the sealed payload need only read |
| interrupted copy `unlinkat` by name after `validate` | deleted through the held handle (POSIX delete) after `validate` | cleanup cannot reach another file that took the name |
| killed publisher's copy reclaimed with `document_metadata`/`remove_document` | the same names; the copy opened relative to the root, checked owner-only single-link regular and still linked, deleted through that handle, then the directory barrier | `document_metadata`/`remove_document` are not on Windows (E1); the check is the one they make |
| `checkpoint_identity` dev:ino:gen:size:mtime:ns:ctime:ns:uid:mode:nlink | volume:inode:0:size:mtime:ns:ctime:ns:owner rights:attributes:links | the same field order; an in-memory cache key only, never persisted |

### CLI

`artifact import <kind>` uploads stay refused on Windows with `unsupportedOnPlatform` before any
frame (no behaviour change, so `cli-feature-coverage.json` and the oracle hash are unchanged). The
source reader is now available there, but the daemon side is not: `arkdeck-hoststore`
`ImportUploadStore` (the Import owner) still needs owners that are macOS-only on main —

- `job_owner::import_references` (the Job store, H2) for its import-use references;
- `artifact_publication` (`publish_import`) and `artifact_read_owner` (E1) for publication;
- `document_metadata`/`remove_document` (the `std::fs::Metadata`-typed pair, E1) for its
  record and staging removal;
- `flash_archive::import_validation` and `snapshot_pager` for validation and listing.

Lifting the refusal before those land would send frames to a daemon that cannot own the Import.
The comment above the Windows `upload` now says exactly this.

## Tests (no sleeps; the child process is synchronized by its exit code)

`tests/host_import_upload.rs`, compiled on macOS and Windows alike (`cfg(any(target_os =
"macos", windows))`; scratch roots are created owner-only, `0700`/`0600` on macOS, by the store):

| Test | What it holds |
| --- | --- |
| `a_recorded_source_imports_through_staging_to_the_recorded_bytes` | the recorded `rust/tests/fixtures/import-upload-current/fixture.hap` read by identity (4096 bytes, `399a3017…b67a` = the recorded intent); the stage refused before its checkpoint, created, a bad digest or offset refused, the first 2048 bytes appended = the recorded Swift stage `imp-dcb7943f-….stage` byte for byte (T0, `7bd630e3…363d`); reopened, recovered from the recorded chunk record, completed; digests, validator input, identity key; a wrong-digest publication leaves nothing; the published sealed payload = the source bytes, `PayloadCheck::Verified`, not writable; the recorded frozen records `820b32aa….json` / `7fc7da24….json` published exclusively and replaced only against the exact prior |
| `a_source_whose_identity_changes_mid_read_is_refused` | a last-write change between open and first read → `InvalidData`; a rename over the name between open and first read → refused by the share mode on Windows (the read completes on the identified file), `InvalidData` on macOS; over-bound, empty and directory sources refused; the caller's deadline stops the read |
| `a_held_source_cannot_be_written_or_removed` (Windows) | while held: open-for-write fails with error 32, delete fails; after release both succeed |
| `link_sources_are_refused` | a junction and a `:stream` name (Windows); a file symbolic link (created here: Developer Mode is on) is unopenable, not "changed" or "over bound"; the target is unchanged |
| `an_existing_artifact_is_never_replaced` | `AlreadyExists`, the earlier bytes intact, no copy left |
| `a_killed_writer_leaves_torn_staging_and_no_published_artifact` | a child process exits inside the second append (after the partial write, and after the flush before its record commits): the stage is a byte prefix of the source beyond the committed 2048 bytes and nothing is published; the next lifetime rolls back to the recorded stage bytes; a killed publisher's `.ART-….<nonce>.tmp` leaves no Artifact and is reclaimed by the next publication, which publishes the source bytes |

## Local targeted checks (Windows 11 x64, rustc per `rust-toolchain.toml`, `CARGO_TARGET_DIR` on D:)

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-cli` | 0 | 313 passed, 0 failed across the three crates: `host_import_upload` 7 passed (new); platform lib 56, `windows_host_store` 9, `windows_transport` 14, `windows_tool_dispatch` 21, `windows_stop` 1; hoststore lib 31, `job_journal_corpus` 1, `job_journal_process_death` 2, `job_journal_restart` 2; CLI lib 65, `import_resources` 7 and the other CLI targets; macOS/Unix-gated targets run 0 tests |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |

macOS and ubuntu cannot be built on this host. The new test file is compiled on macOS by CI; its
macOS arm exercises the unchanged macOS submodule.

## CI

To be recorded, not verified.

## Open for the lead / next slices

1. The Import owner (`ImportUploadStore`) comes to Windows after the Job store (H2) and the
   Artifact publication/read owners with a store-owned `document_metadata`/`remove_document`
   (E1); then the CLI's Windows `upload` becomes the macOS one and the coverage JSON and its
   oracle hash change.
2. The source share mode refuses a file another process holds open for writing. If GJ-2 needs to
   import a file an IDE still holds, the alternative is to share writing too and rely on the
   identity check alone, as macOS does; that is a ruling for the maintainer, not taken here.
