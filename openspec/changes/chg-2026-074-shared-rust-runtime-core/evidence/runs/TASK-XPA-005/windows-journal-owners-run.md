# TASK-XPA-005 — WM1 slice H1 run record: the Job Journal owners on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1, slice H1: un-gate the
`arkdeck-hoststore` owners whose only Windows blocker was the durable host store (G01, #2338) or
the host text and calendar (G03/G04, #2336), in GJ-1 order. Base: protected `main` `b3eb5528`
(#2336). Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device was contacted; no
operation was submitted; no installed state was touched. Host tests and hosted CI are not Windows
acceptance.

## What

The Job Journal owners and the decoders they read through build on
`cfg(any(target_os = "macos", windows))`. The code is the macOS code: no owner gained a Windows
arm, and the only production edit besides the gates is moving the Job snapshot's two wire-failure
constructors (`failure`, `unreadable`) from `job_record.rs` into `job_failure.rs`, re-exported from
`job_record` unchanged, so the events reader no longer pulls in the Job record (which sits on the
SQLite index). Linux has no durable host store and still builds none of them.

| Owner | GJ-1 role | Why it was gated (inventory) | Now |
| --- | --- | --- | --- |
| `job_journal` (`JournalEvent`, `JOURNAL_KINDS`) | the Journal's closed per-event decoder | G31, c-inh: behind G04 (`session_time`) and the Session Manifest decoder | macOS + Windows |
| `job_journal_events` | the record factories | G31, c-inh (only its callers) | macOS + Windows |
| `job_journal_replay` (`ReplayFacts` …) | journal replay | G31, c-inh | macOS + Windows |
| `job_journal_writer` (`JournalWriter`, `inspect_journal`) | the Job journal writer | G31, c-inh: G01 `HostJournalAppender` | macOS + Windows |
| `job_events` (+ `job_failure`) | the Job events reader (`jec1` cursors) | G31, c-inh: G01 `HostJournal`; `aes-gcm` was a macOS-only dependency | macOS + Windows; `aes-gcm` now `cfg(any(macos, windows))` (same pinned version, `Cargo.lock` unchanged) |
| `session_manifest`, `session_step_arguments`, `recovery_manifest` | the Session Manifest decoder the Journal decoder validates steps with | G35, c-inh: G03/G04 | macOS + Windows |
| `strict_json`, `swift_decoding` | Foundation member-name and `String` equality the Recovery Manifest reads through | G31, c-inh: G03 (`canonical_host_text`; portable since #2336, no raw-byte fallback left) | macOS + Windows |

`job_events`, `job_failure`, `session_manifest`, `strict_json`, `swift_decoding` and the replay's
`holds_destructive_step_intent` carry `cfg_attr(not(target_os = "macos"), allow(dead_code))`:
their other callers (`JobStore::events`, the Session inventory, the capability store, the cutover
facts) are still macOS-only. Same pattern as `format_time` in #2336.

### Gates removed (predicate `target_os = "macos"` → `any(target_os = "macos", windows)`)

| File | Count |
| --- | ---: |
| `rust/crates/arkdeck-hoststore/src/lib.rs` | 15 (`job_events`, `job_journal` + its `pub use`, `job_journal_events`, `job_journal_replay`, `job_journal_writer`, the two `pub use`s of replay and writer, `strict_json`, `swift_decoding`, `recovery_manifest` + its `pub use`, `session_manifest`, `session_step_arguments`) |
| `rust/crates/arkdeck-hoststore/src/session_graphemes.rs` | 1 (`indices`, used by the step-argument decoder) |
| `rust/crates/arkdeck-hoststore/Cargo.toml` | 1 (`aes-gcm` target table) |
| `rust/crates/arkdeck-hoststore/tests/job_journal_process_death.rs` | 1 (whole file) |
| `rust/crates/arkdeck-hoststore/tests/session_publication_cost.rs` | 1 (whole file; `#[ignore]`d measurement) |
| **Total** | **19** |

In-module test gates: the writer, replay and events unit tests had no gate of their own but used
`std::os::unix` (`DirBuilderExt`, `PermissionsExt`) and `/private/tmp`; their scratch roots now come
from `src/test_private.rs` (mode 0700 on macOS, as before; on Windows the store's own
`HostDirectory::open_or_create_private`, because a directory the standard library creates inherits
the temporary directory's DACL, which the store refuses). The events test checks the cursor key's
rights through the store's owner-only read on Windows and the mode on macOS. The replay's
`#[ignore]`d 10,000-record measurement runs its replay part everywhere and its Job-owner proof part
on macOS only (it needs `JobStore`).

### Stays gated, and why

| Owner | Blocker |
| --- | --- |
| `job_repository`, `job_owner` (`JobStore`: admit, persist `job-record.json`, serve `job.events`) | the SQLite Job index, WM1 slice S3 (in flight); not touched here |
| `job_record`, `job_record_fields` (`JobRecord`, `durable_bytes`) | import `job_repository`'s row types and `identifier`/`order_key`, and `job_plan::step_set_digest` (over `device_facts`, `device_steps`, `artifact_read_owner`); follows S3 and the Job plan |
| `session_json::encode_pretty` & co. (G04p, the `job-record.json` spelling) | pure, but only `JobRecord` and the Artifact writers call them; un-gating them alone is dead code |
| `session_publication` (`SessionPublisher`, staged recovery) | needs `JobStore`/`JobRecord`, and the Session owner (`session_owner`, `snapshot_pager`) |
| `session_owner`, `snapshot_pager`, `session_inventory` | `document_metadata`/`remove_document` still take `std::fs::Metadata` (see below); the inventory also carries the cleanup and export submodules |
| `cutover_facts`, `recovery_epoch`, `capability_store`, `artifact_quota` | Swift cutover (G42) / their own G31 and G32 owners; not GJ-1 journal owners |
| agentd `job.events`, `RunSlot`, `recover_active_jobs` | over `JobStore` |

`document_metadata`/`remove_document` were not ported: no owner un-gated here calls them. The
maintainer's ruling 7 (`../../windows-maintainer-rulings-20260930.md`: a store-owned identity type, e.g. `HostFileIdentity`, with the macOS callers
`snapshot_pager` and `bundle_list_owner` changed with it) applies to the slice that un-gates the
Session owner, together with Session publication after S3.

## GJ-1 hop

Owner level, through the Rust owners on NTFS (hops 5 and 9: Journal durability and restart
readback), with the recorded macOS fixtures as oracle:

1. `tests/job_journal_corpus.rs`: every distinct Journal under `rust/tests/fixtures`
   (a `.jsonl` whose first record is `jobCreated`, deduplicated by SHA-256) is copied into an
   owner-only directory and replayed by `inspect_journal`; the ones that replay whole (231 Journals,
   2,907 records; 1 recorded torn tail is a refusal oracle's input and is skipped) are then written
   again record by record by `JournalWriter` into a fresh owner-only directory. Each written file is
   the recorded bytes (T0) and replays to the same `ReplayFacts` (T1).
2. `tests/job_journal_restart.rs` (own binary; it re-executes itself), over the recorded
   `observe.device@1` Job `job-0f77f8c5…` (16 records): a child process writes the Job's Journal and
   exits inside the append of record 9 (`AfterPartialRecord`); the parent finds a byte prefix of the
   recorded Journal, torn, with 8 durable records. A second child repairs the torn tail, completes
   the Journal, copies it into `Sessions/2026/09/session-job-0f77f8c5…` record by record, publishes
   the Session's recorded `manifest.json` write-once under `.manifest.lock`, and exits holding
   everything open. The test process then reads both Journals (bytes and facts), and the Manifest,
   back as recorded; a second publication is refused `AlreadyExists` and an append of a well-formed
   record is refused (`Refused`, the terminal-Manifest check) with nothing changed.
3. `tests/job_journal_process_death.rs`: both write points on the `unknown` oracle, unchanged from
   macOS.

Not in this hop: the Session publisher itself composing the Manifest from a Job record (needs
`JobStore`), and the daemon's restart path (`recover_active_jobs`).

## Local targeted checks (Windows 11 x64, rustc per `rust-toolchain.toml`, `CARGO_TARGET_DIR` on D:)

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | clean |
| `cargo clippy --manifest-path rust/Cargo.toml --workspace --all-targets -- -D warnings` | 0 | clean (Windows build of every crate) |
| `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-platform` | 0 | hoststore lib 31 passed, 1 ignored (21 newly run on Windows: writer 8, events 4, replay 1, recovery manifest 4, strict JSON 3, Swift text 1; was 10); `job_journal_process_death` 2; `job_journal_corpus` 1; `job_journal_restart` 2; `session_publication_cost` 1 ignored; platform lib 49 passed, 1 ignored; `windows_host_store` 9; `windows_transport` 14; `windows_stop` 1; `sha256_backend` 1; the other targets are macOS/Unix-gated (0 tests) |
| `cargo test -p arkdeck-hoststore --test session_publication_cost -- --ignored --nocapture` | 0 | measurement, debug build: 44-record Journal copied 20×; one durable append median 6.8 ms, p95 9.6 ms; a whole copy median 262 ms |
| `sh scripts/check-sdd.sh` (`ARKDECK_PYTHON` = the SDD venv, `PYTHONUTF8=1`) | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |

No test sleeps for synchronization: the restart test waits on each child's exit. (The existing
`a_held_manifest_lock_is_awaited` unit test, now also run on Windows, holds the lock for 300 ms on
a thread; it asserts only that the writer waits it out, unchanged.)

macOS and ubuntu cannot be built on this host. cfg pairings re-read: every widened predicate is
`any(target_os = "macos", windows)`, so Linux compiles exactly what it compiled before; on macOS
the owners are unchanged, `job_record` re-exports the moved constructors under their old names
and visibility, the unit tests' macOS scratch roots are created with mode 0700 as before, and the
`cfg_attr` dead-code allowances are inert on macOS. `Cargo.lock` is unchanged.

## CI

First round (PR #2345): `Rust workspace (xcode-27)` failed both new tests on macOS. Cause: the
tests copied recorded Journals with `fs::write`, which leaves mode 0644 under the usual umask, and
`inspect_journal` opens a private directory whose reads refuse any group or other bit (Windows'
inherited owner-only DACL passed). The corpus test counted those store refusals as "recorded torn"
and so wrote nothing (`0 0`); the restart test's `recorded_facts` unwrapped the refusal. Fixed in
the tests: recorded copies are created 0600 on macOS (`journal_scratch::write_private_file`), and
the corpus test skips only a torn replay or a replay-rule refusal, failing on any other refusal.
No store check changed. Final result: to be recorded, not verified.

## Open for the maintainer / next slices

1. Session publication and the Session owner on Windows wait for S3 (`JobStore`) and the
   `document_metadata`/`remove_document` port the ruling describes; that slice changes
   `snapshot_pager` and `bundle_list_owner` on macOS in the same PR.
2. `HostDirectory::open_or_create_private` (both platforms, Swift `prepareRoot`) makes an existing
   root owner-only rather than refusing it. This slice uses it only for fresh test roots; ruling 5
   (an existing state root with a foreign DACL is refused, never tightened) bears on its
   production callers when they come to Windows.
