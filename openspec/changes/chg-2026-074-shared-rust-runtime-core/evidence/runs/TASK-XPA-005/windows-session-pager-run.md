# TASK-XPA-005 — WM1 slice H3 run record: the Session owner, publication and snapshot pages on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1, slice H3 (TASK-XPA-005/014 on
Windows): the snapshot pager, the Session storage owner, the Session census and the Session
publication writer on NTFS, and the Windows daemon's `job.list` and `job.timeline` through the
Job store's pager instead of H2's one-page answer.

Base: the head of #2361 (H2, Job store owner on Windows; `50ff5707`, then `3885d716`), with the
head of #2356 (E1, Artifact read/export on Windows; `bc42a792`, then `5785d054`) and
`origin/main` `2fb64e36` (#2366, workspace project owner) merged into it. Their overlap in
`Authority::compose` and `host.rs` is resolved by composing every owner: the Windows daemon now
composes the Target owners, the Artifact read and export owner, the Job store and the workspace
project owner (`arkdeck-agentd owners: targets, artifacts, jobs, workspaceProjects`), and an
Artifact's Job is proved by the Job store on Windows as on macOS (`require_artifact_job` is one
function). Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device was contacted,
no HDC or board was used, no operation was submitted, nothing installed was read or written, and
no system setting was changed. Host tests and hosted CI are not Windows acceptance.

## What

`arkdeck-hoststore` builds on `cfg(any(target_os = "macos", windows))`:

| Owner | Was | Now |
| --- | --- | --- |
| `snapshot_pager` | built on Windows by E1 (ruling 7), its tests macOS-only | its tests run on Windows too |
| `job_owner` `job.list`, `job.timeline` | macOS pager; Windows one-page answer, timeline refused `rejected` | the pager on both; the one-page answer (`single_page`) is gone |
| `session_owner` (`SessionStore`, `StorageHold`) | macOS-only | macOS + Windows, less its cleanup and export submodules |
| `session_inventory` (census, retention catalog) | macOS-only | macOS + Windows, less its cleanup and export censuses |
| `session_publication` (`SessionPublisher`, `recover_staged`) | macOS-only | macOS + Windows |

Windows arms (everything else is the macOS code):

1. **Session root spelling** (`session::absolute_root`): a local drive's absolute path (`D:\…`),
   in the settings document and in a `runtime.storage.root` request; macOS and Linux keep `/…`.
2. **Canonical path** (`session_owner::canonical_path`): `canonicalize`, with a local drive's
   verbatim `\\?\D:\…` spelled `D:\…`, as the host store's canonical rule accepts it.
3. **Manifest `platformProfile`**: `PLATFORM-WINDOWS@0.2.0` on Windows, the profile the Session
   is published under; macOS keeps `PLATFORM-MACOS@0.2.0`. A platform decision of this slice:
   writing the macOS profile into a Session published on Windows would misstate its provenance.
   The field is a free non-empty string in `openspec/contracts/manifest.schema.json`.
4. **Marker root path**: the canonical path as it is (no `/private` alias to drop).

One change on both OSes: the writer drops every handle below its staged Session before the
rename (`session_publication.rs`, step 8). Windows renames no directory while a handle below it
is open (the rename failed `ERROR_ACCESS_DENIED`); the handles are not used after step 7, so
macOS behaviour and bytes are unchanged.

Test support: `test_private` gains `plant_owner_only`, `widen` and `link` (mode bits on macOS;
on Windows the store's own owner-only create, a file written in the temporary directory and
moved in, and a second hard link, since a symbolic link needs a privilege). The Windows
dev-dependency on `arkdeck-platform` enables `allocation-meter`, as on macOS.

Still macOS-only, and why: the Session cleanup and export owners (their previews, plans,
records and the host store's Session removal, which is not on NTFS); the Artifact usage owner
the daemon's `runtime.storage.*` pairs the Session domain with; and the Job runners,
cancellation and reconciliation that call the writer. So the Windows daemon composes no
Session owner yet. The workspace project mutation census of #2366 stays refused on Windows:
the Job owner's workspace census (`workspace_references`) is still macOS-only.

## Measurements (Windows 11 x64)

1. **Recorded Swift Sessions published again**
   (`session_publication_windows_tests.rs::recorded_swift_sessions_are_published_again_byte_for_byte`):
   every recorded Job store with a Sessions tree beside it (37 stores under
   `rust/tests/fixtures`). Each Job is handed to the writer as before Swift's publication (the
   recorded record without its marker, the recorded Journal without `finalized`), in the order
   Swift's catalog registered them; a Job refused storage is published over a volume reported
   full, and a recorded Session collision is reproduced. Result: 76 Sessions published and 42
   refusals, every marker, Manifest proposal, Job Journal, Session file, catalog and storage
   owner directory equal to Swift's bytes but for (a) the marker's host labels (root path,
   device, inode, volume, admission generation), (b) the Manifest's `platformProfile` and what
   names its digest (the Journal's `finalized`, the audit record, the marker's digests, byte
   count and Journal seal), and (c) 8 checkpoint seals of recorded records Swift persisted
   again after their publication (their seal is the given record's). Git keeps no empty
   directory, so each Session's empty `artifacts/raw` and `artifacts/derived` are checked by
   name. Every Session is then read back a page at a time through `session.list` (each cursor
   read by an owner opened after it was handed out) and by `session.show`, both schema-valid;
   a Session a stopped publication left unregistered makes the census refuse the list, as
   Swift's does.
2. **Crash between Manifest and rename** (`a_session_a_crash_left_staged_is_removed_at_the_next_start_and_nothing_else`):
   a child process publishing a recorded Job exits (75) at `ManifestPublished`; its Session is
   staged, not published; `recover_staged` removes it (proved this Runtime's), keeps and names
   three rogue entries, leaves the Job's record and Journal as the crash left them, changes
   nothing a second time, and removes staging once empty.
3. **Swift storage lock-wait oracle** (`tests/windows_session_owner.rs`):
   `runtime.storage.status`, `.policy`, `.root`, `session.list`, `session.pin`, each sent while
   the storage (or catalog) lock is held, answer Swift's Session domain byte for byte once it
   is released (roots read as the oracle's paths). Not replayed: the Artifact domain and
   `session.export.preview` (macOS-only owners).
4. **Snapshot pager and Job list stream**: the pager's 10 tests (whole-snapshot oracle, bounds,
   cursor across restart, retention, unsafe snapshot, allocation bounds) and the 4 Job list
   stream tests run on Windows unchanged in substance.
5. **Real daemon across a restart** (`arkdeck-agentd/tests/windows_job_store_process.rs`): the
   recorded `observe.device@1` Jobs; `job.status`, `show`, `events`, `timeline` and `list` over
   the pipe equal the store's in-process answers before and after a restart; `job.list` and the
   observed Job's `job.timeline` paged one row at a time, every page the next row of the whole
   answer under one snapshot revision, the cursor handed out before the restart read to the end
   after it. `windows_artifact_owner_process.rs`: the recorded Job `job-73b1…` recorded into
   `jobs-state`; `artifact.list`, `inspect` and `read` equal the owner's in-process answers
   before and after a restart, `artifact.export` publishes the recorded bytes, a Job the Job
   owner does not hold is refused `resourceNotFound` with zero dispatch.
6. **Real CLI against the dev-signed daemon** (`ARKDECK_DEV_SIGNER_THUMBPRINT` from
   `HKCU\Environment`): `job status|show|events|timeline|list` after a restart equal the store's
   answers, and `job list --page-size 1` / `job timeline --page-size 1` cursors from before the
   restart read the next row after it; `artifact list|inspect|read|export` answer as the owner
   and export the recorded bytes.

## Local targeted checks

Worktree `D:\src\ArkDeck-wt\h3-session`, `CARGO_TARGET_DIR=D:\cargo-target\h3-session`.

| Command | Exit | Notes |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | log `D:\cargo-target\h3-session\clippy.log` |
| `cargo test --no-fail-fast -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-platform -p arkdeck-cli` (with `ARKDECK_DEV_SIGNER_THUMBPRINT`) | 0 | 229 test binaries ok; hoststore lib 81 passed, 2 ignored; `windows_session_owner` 1; agentd `windows_job_store_process` 3, `windows_artifact_owner_process` 3, `windows_workspace_projects_process` 3, `windows_target_owners_process` 3; log `D:\cargo-target\h3-session\test.log` |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings, 121 acceptance IDs; union-merge check ok |
| `git diff --check` | 0 | |

Not run here: macOS and Linux builds (no such host). The macOS side of every change was
re-read cfg by cfg: the macOS code paths are unchanged but for the dropped handles before the
rename and the tests' fixture helpers, which keep their mode bits and symbolic links on macOS;
Linux compiles none of the ported modules and keeps `/…` roots. CI's macOS and ubuntu lanes are
the verdict.

## CI

To be recorded by the next slice; not verified here.
