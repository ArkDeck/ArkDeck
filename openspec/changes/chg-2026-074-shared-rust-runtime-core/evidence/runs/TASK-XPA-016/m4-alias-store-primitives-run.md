# TASK-XPA-016 — M4 run record: the alias store's host primitives

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M4 (GJ-4), lane B's "Rockchip
live-mode and post-flash binding" item, fourth slice: the host-store primitives Swift's
post-flash HDC alias store needs and the crate did not have, in `arkdeck-platform`, with no
store logic. Host measurement
only — not hardware, platform or conformance evidence (POL-VERIFY-001, POL-MODE-001). No device,
no HDC, no store: every test runs against a scratch directory.

Base: protected main `3d880989` (#1932). Branch `agent/xpa-016-alias-store-primitives-20260914`;
no stacking (independent of #1934/#1936/#1937).

## What was missing

After a complete overwrite the DAYU200 may come back on HDC with a new serial; the adopted
Target stays usable only through the post-flash HDC alias that `verifyBoundBuild` publishes once
the exact build is read (the proof `RockchipHdcObserver::verify_bound_build` now returns, #1936).
Swift keeps that alias in `RockchipPostFlashHDCBindingStore` (`RockchipPostFlashHDCBinding.swift`,
494 lines): an owner-only document `rockchip-post-flash-hdc-binding.json` under the product's
Application Support root (the parent of the daemon state directory), with a lock, a three-way
publication (same proof → idempotent, revision advance → the superseded epoch archived, anything
else → the four-conjunct chain rule), an `O_EXCL` archive that is compared rather than replaced
when its name is taken, and a reissue reconciliation. Mapped for this record (read-only, no
device): the port splits into pure decision logic and canonical bytes (the alias-store owner's,
over `arkdeck-contract`'s canonical JSON) and four host rules `arkdeck-platform`'s `HostDirectory`
did not have — the crate's `open` requires an existing canonical root, `publish_document` is the only writer
(rename-based), `owned()` checks the 0077 mask rather than exactly 0600, and nothing
creates-or-compares; the waited-for lock Swift takes is the crate's existing `wait_lock`. It also had no notion of the
Application Support root, and its two spellings of a home (`runtime_home()` honouring
`CFFIXED_USER_HOME`; `bootstrap_root()` and `arkdeck-agentd`'s dev-root guard reading the
password database or `HOME`) disagree with Foundation under a test harness.

## What Swift does

- `prepareRoot` (429–439): the root must be absolute; `createDirectory(withIntermediateDirectories:
  true, attributes: [.posixPermissions: 0o700])`; then `chmod(rootURL.path, 0o700)` unconditionally.
  Every later operation is descriptor-relative and `O_NOFOLLOW`.
- `validateFile` (441–449): `S_IFREG`, `st_nlink == 1`, `st_uid == getuid()`, mode exactly `0o600`;
  applied to the lock, the document and the archives.
- The lock (111–119, 252–260): `openat(O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)`,
  `validateFile`, blocking `flock(LOCK_EX)`, `LOCK_UN` before `close`; readers take no lock.
- `load` (374–405): `ENOENT` → `nil`; otherwise `validateFile`, `0 < st_size <= 65536`, the whole
  file.
- `archiveSuperseded` (311–343): `openat(O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
  0o600)`, write, `fsync(file)`, `fsync(root)` — no rename, no `F_FULLFSYNC`, no `fchmod`; on
  `EEXIST`, `archivedEntryMatches` (347–372): `validateFile`, `st_size <= 65536`, a size mismatch
  is "different", else a byte compare. Nothing ever removes an archive.
- The root: `main.swift` 415–417, `resolvedStateDirectory.deletingLastPathComponent()` —
  `~/Library/Application Support/ArkDeck`, with the home Foundation resolves from
  `CFFIXED_USER_HOME` (`NSHomeDirectory()`), never `HOME`.

## What Rust now does

- `rust/crates/arkdeck-platform/src/host_store.rs` (macOS), additive:
  `HostDirectory::open_or_create_private(path)` — absolute path, `DirBuilder` recursive 0700,
  `chmod(0o700)` on the root unconditionally, then `open_root` by the canonical path (the crate's
  own owner/mask/volume rules apply from there);
  `HostDirectory::create_exclusive_or_match(name, bytes, maximum) -> ExclusiveOutcome::{Created,
  Matched, Different}` — Swift's `O_EXCL` create, write, `fsync(file)`, `fsync(dir)`, and on
  `AlreadyExists` the owner-only check, the size shortcut and the byte compare, never a write;
  `HostDirectory::read_owner_only(name, maximum) -> Option<Vec<u8>>` — `NotFound` as `None`,
  else `owned()` plus exactly `0o600`, `1..=maximum` bytes, the whole file. `owner_only()` is
  Swift's `validateFile` on top of `owned()`.
- `src/account.rs`: `application_support_directory()` (`<home>/Library/Application Support`) and
  `arkdeck_application_support_root()` (`…/ArkDeck`) over `runtime_home()`.
- Not done here, on purpose: the record and its canonical bytes, `validate`, `publish`'s
  resolution, `archive_name`, `reconcileReissuedLineage` — the alias-store owner's slice, over
  these primitives; `arkdeck-agentd`'s `HOME`-based dev-root guard (lane A's file) — noted for
  them; a `fchmod(0o600)` after `publish_document`'s write (Swift's `commit` does it; the
  crate's temp file is created 0600 and only an owner-restricting umask would differ) — left
  as is rather than changing every store's publication.

## Tests

`cargo test -p arkdeck-platform` — `tests/host_store_alias_primitives.rs` 5/5, every other test
binary of the crate unchanged and passing; `cargo clippy --workspace --all-targets -- -D warnings`
clean on the host and `-p arkdeck-platform` clean for `--target x86_64-unknown-linux-gnu` /
`x86_64-pc-windows-msvc`; `cargo fmt --all -- --check` clean.

| Test | Proves |
| --- | --- |
| `a_private_root_is_created_owner_only_and_reopened` | two missing levels created 0700; a root left 0755 is made 0700 on reopen, not refused; a relative path and a file path are refused; the result publishes and reads as a private root |
| `an_exclusive_document_is_created_once_and_matched_only_byte_for_byte` | `Created` with mode 0600 and the bytes; `Matched` on the same bytes; `Different` for other bytes of the same length, another length and an empty occupant, the occupant untouched; refusals for nothing to write, more than the limit (and nothing created), a 0644 occupant, an occupant above the limit, a link at the name, a multi-segment name and `..` |
| `an_owner_only_read_tells_absence_from_every_refusal` | `None` for absence; the bytes for a 0600 file; refusals for a smaller limit, 0644, 0400, empty, a directory, a link, `..` and a nested name |
| `the_existing_waited_lock_is_the_store_s_lock` | Swift's blocking `LOCK_EX` without a sync of a new lock is the crate's existing `wait_lock(name, false)`: with the lock held, the non-blocking `lock_document` is refused and `wait_lock` returns only after the holder drops it (≥ 250 ms of a 300 ms hold); the lock file is 0600 |
| `the_application_support_root_follows_the_runtime_home` | `<runtime_home>/Library/Application Support` and `…/ArkDeck`, absolute |

## Not run, and why

- No store: the record's bytes, the publication's three branches and the reissue reconciliation
  are the alias-store owner's; and the repository holds no recorded T0 oracle for that document
  (only two evidence notes under `chg-2026-059` describe field values from a real host). A
  Swift-only oracle — publish, same-proof retry, revision advance with its archive, an archive
  collision, a reissue reconciliation — is the next lane-B slice, so that the store's Rust replays
  bytes.
- `CFFIXED_USER_HOME` is not set in the test: setting process environment from a parallel test is
  unsound in Rust 2024, and `runtime_home()`'s own precedence is already pinned by its module.

## Facts for the maintainer from the map (not blocking this slice)

1. `commit` puts `renameat` and `fsync(root)` under one guard and reports both as "post-flash
   binding cannot be committed" — a directory-sync failure after a successful rename is reported
   as not published while the alias is on disk. `publish_document`'s `DocumentPublishError::
   OutcomeUnknown` already models the distinction; the store's port should decide deliberately.
2. `archiveSuperseded` is materially less durable than `commit` (no `F_FULLFSYNC`, no rename): a
   crash mid-write leaves a short archive at the final name, which `archivedEntryMatches` then
   treats as a different entry forever. `create_exclusive_or_match` reproduces the rule as is.
3. Two `isSHA256` spellings (`value.count == 64` in the store, `utf8.count` in `SHA256Hex`) and two
   `nowUTC` spellings (`ISO8601Timestamps` in the executor, `ISO8601DateFormatter` in the
   reconciler) feed the same durable file; nothing pins that they agree.
4. `arkdeck-agentd/src/main.rs` 93–95 derives its Application Support guard from `HOME`, which
   Foundation ignores; `arkdeck_application_support_root()` is the replacement.
