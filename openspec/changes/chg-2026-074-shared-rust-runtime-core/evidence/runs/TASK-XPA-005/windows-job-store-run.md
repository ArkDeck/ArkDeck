# TASK-XPA-005 — WM1 slice H2 run record: the Job store owner on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Milestone WM1, slice H2: the Job store owner
(`job_repository`, `JobStore`), the Job record (`job_record`, `job_record_fields`, the
`job-record.json` pretty writers) and the Windows daemon's composition of them — the Job-record
path `observe.device@1` needs. Base: protected `main` `ca880968` (#2350, with #2345 H1 and #2344
on it). Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device was contacted, no
HDC or board was used, no operation was submitted, nothing installed was read or written, and
no system setting was changed. Host tests and hosted CI are not Windows acceptance.

## What

`arkdeck-hoststore` builds on `cfg(any(target_os = "macos", windows))`:

| Owner | Why it was gated (H1 run record) | Now |
| --- | --- | --- |
| `job_index` (SQL) + `job_repository` (index owner) | G01 durable store incl. the database file identity; G04 order key | macOS + Windows; the order key is the portable calendar's (`session_time`) |
| `job_owner` (`JobStore`: admit, persist, reads) | over the index | macOS + Windows, less what reads other macOS-only owners (below) |
| `job_record`, `job_record_fields` (`JobRecord`, `durable_bytes`) | row types; `job_plan::step_set_digest` (over device facts, Artifact reads) | macOS + Windows; Swift's `stepSetDigest` moved verbatim to `job_step_digest.rs`, which `job_plan` (`step_set_digest`, `debug_hap_plan::compensations`) and the record reader both call |
| `session_json::encode_pretty`, `encode_canonical_pretty`, `parse_foundation` | only their callers | macOS + Windows |
| `operation_request`, `recovery_epoch` | only their callers | macOS + Windows (`recovery_epoch`'s unit test stays macOS: it sets modes) |
| Recovery epoch indexes (`EpochIndexes`, `epoch_indexes`, `indexed_status`) | lived in `flash_recovery.rs` (macOS) | moved verbatim to `job_epoch_indexes.rs` (a `job_owner` submodule), `job_flash_state.rs` un-gated |

Windows arms (everything else is the macOS code):

1. **Database identity** (`job_repository::database_identity`). macOS: the store's
   `document_metadata` → `(dev, ino)`, unchanged. Windows: the store's owner rule on the entry
   (`owned_kind_and_size`: owner the user, owner-only DACL, single link, regular, same volume)
   and its volume serial and FileIdInfo file id (`file_identity`), read before and after the
   owner check; the owner remembers it at open and every read and write re-checks it, so a
   database replaced under the owner is not read. The `-wal`, `-shm` and `-journal` companions
   pass the same owner/single-link/regular rule on both platforms (`validate_files`,
   `inspection`), which is all the macOS owner checks of them (it takes no dev/ino of the
   companions). SQLite creates them inside the private directory, so they inherit its
   owner-only DACL and pass; a linked or directory companion is refused (test below).
2. **First index file**: macOS `OpenOptions` `0600` + `sync_all` (unchanged); Windows the store's
   `create_document` (owner-only descriptor, relative to the held root), SQLite writes the
   layout, the file is flushed and checked to be the one created, and the directory flushed.
3. **Recovery epoch probe**: `document_metadata` on macOS, the store's owner rule on Windows
   (`job_epoch_indexes::probe_private_document`), for `epoch_indexes` and `recovery_epoch_of`.
4. **`job.list` without the snapshot pager** (see "Stays gated"): on Windows a list whose
   snapshot is one page is answered as the pager answers its first page — the same rows, bounds,
   refusals and member order, a fresh revision, `hasMore: false`, no cursor — without storing it;
   the pager also stores such a snapshot, but nothing can read it back (its only cursor, the
   first page's token, is never handed out). A list of more than one page (by `pageSize` or the
   pager's 1 MiB page bound), any cursor, and `job.timeline` are refused `rejected` (the
   foundation's code for a method it lacks; the control contract's `job.*` error enum has no
   `operationUnavailable`).

`macOS` is otherwise unchanged: `HdcLifecycleInterlock`, `acquire_hdc_lifecycle_interlock` and
`current_jobs` (over `hdc_impact_source`), the Import/workspace/retention/Session-continuity
censuses (`import_references`, `job_retention_census`, `workspace_references`,
`mutation_state_continuity`), Flash recovery, and the Job owner's two macOS test submodules are
gated to macOS inside `job_owner.rs`; `list` builds its rows once and hands them to the pager on
macOS exactly as before.

### Platform: document replacement waits out a brief holder

`HostDirectory::publish_document` on NTFS (#2338) replaces by a POSIX-semantics rename. The
recorded-store corpus below persisted Job records a dozen times in a row and failed
`OutcomeUnknown(STATUS_ACCESS_DENIED 0xC0000022)` in 3 of 5 runs, at different Jobs each time;
the same `persist` retried at once succeeded, and the Job directory held only
`job-record.json` (the failed rename replaced nothing). That is a filter (anti-malware or
indexing) holding the just-published file without delete sharing for a moment. The rename is
now retried on `ERROR_ACCESS_DENIED`/`ERROR_SHARING_VIOLATION` with backoff for about a second
in all before the failure is answered (`windows/host_store.rs::rename_replacing`); any other
failure is answered at once, and a failed rename cannot publish twice. After the change the
corpus passed 6 of 6 runs, and `a_replacement_waits_out_a_brief_holder_of_the_replaced_document`
(platform) holds the file without delete sharing for 100 ms (published after it) and then for
good (refused, file unchanged, no staged file left). macOS is untouched.

### Daemon composition

`windows_lifecycle::Authority::compose` adds the Job store beside the Target owners, in a private
child `jobs-state` of the root (`StateRoot::private_child`: created owner-only, an existing one
never re-permissioned; one that is not owner-only ends the start, exit 69, ruling 5's rule
applied to the owner's directory), opened with `JobStore::open_owner`. `jobs-state` is the macOS
isolated owner's name; the account root uses it too, because the host store cannot open
`%LOCALAPPDATA%\ArkDeck\Agentd` itself (its DACL also grants SYSTEM, B1's finding), while
Swift's production daemon keeps the index at the state root beside its other owners. The owner
census line reads `arkdeck-agentd owners: targets, jobs`. `Host::job_resource` serves
`job.status`, `job.show`, `job.events` and the one-page `job.list`.

`runtime service restart` (#2344) reads the current Jobs from one complete `job.list` snapshot
before it stops a daemon, and treats "The Job owner is not configured" as "no Jobs". With the
Job store composed, the one-page list is that snapshot, so a restart still refuses to interrupt a
current Job; `windows_client_start_process.rs`'s restart proof now reports `jobOwner: true`
(the only change to that test). Refusing `job.list` outright would have made every Windows
restart fail closed; this is why the one-page arm exists.

## Stays gated, and why

| Owner | Blocker |
| --- | --- |
| `snapshot_pager` (and so `job.timeline`, lists of more than one page) | its retention reads `document_metadata` and removes through `remove_document`, which take `std::fs::Metadata`: the ruling-7 port (E1, #2356 in CI) |
| `session_publication` (`SessionPublisher`, staged recovery) | holds the Session owner (`SessionStore`, `StorageHold`) and `session_inventory::STAGING` |
| `session_owner`, `session_inventory` | `snapshot_pager` and the cleanup/export submodules (E1) |
| HDC lifecycle interlock, current-Job census | `hdc_impact_source` / `hdc_control_action`; no Windows HDC lifecycle is composed |
| Job planner, admitter, runner, reconciler, recovery (`recover_active_jobs`) | device facts, device steps, Artifact owners, HDC tuple |

So no Job is admitted on Windows yet: the GJ-1 hop below records the Swift Jobs into the store
with the owner's own `admit`/`persist`, then reads them through the daemon.

## GJ-1 hop

Owner level (`arkdeck-hoststore`, macOS and Windows), with the recorded Swift Job stores as the
oracle:

- `tests/job_store_corpus.rs`:
  - every `job-record.json` under `rust/tests/fixtures` the reader decodes is re-encoded by
    `durable_bytes` to its exact bytes (T0): **412**; 1 refused, the
    `rockchip-startup/…/alias.unreadableJob` fixture, recorded as unreadable on purpose;
  - every recorded Job index (`index.json` with `userVersion`: **153**) whose rows all carry
    their record (**145**, 368 rows; 8 do not, as in S3's replay) is rebuilt through
    `JobStore::open_owner` — admission in admission order, then `version − 1` `persist`s at the
    recorded update time — and the index read back after the owner is dropped equals the
    recorded projection: schema, `user_version` 1, journal mode `wal`, every row with the
    **order key computed by the Rust owner** and the record digest (T1); every `job-record.json`
    the owner published is the recorded bytes (T0);
  - where the fixture records Swift's answers to the Job reads (`reads.json`), the rebuilt store
    reopened as a reader (a restart), with the recorded Journals beside the records, answers as
    Swift answered: `job.status` 68, `job.show` 68, `job.events` 1, all equal. Excluded: the one
    Job `job-reconcile-analyzer` reads from a resident record ahead of the durable one (its
    `job.reconcile` failed after the Journal moved), which a restarted reader cannot see;
- `tests/job_store_writer.rs` (the Swift writer oracle, now on Windows too): 5 of 5;
- `tests/job_store_files.rs` (new): WAL/SHM written and accepted after a restart; a linked or
  directory `-wal`/`-shm`/`-journal` and a linked database refused by owner and reader; a replaced
  database not read (macOS: renamed and copied back → `recordUnreadable`; Windows: SQLite holds the
  open database without delete sharing, so the rename is refused and reads continue).

Daemon level, Windows (`arkdeck-agentd/tests/windows_job_store_process.rs`), over a fresh
development root with every `ARKDECK_`/`OHOS_HDC_` input removed:

1. The four recorded `observe.device@1` Jobs (`rust/tests/fixtures/observe-device/store`) are
   recorded into `jobs-state` by the owner (admit + persist to the recorded version, each
   Journal beside its record). The observed Job reads `succeeded` with 16 Journal events.
2. The real daemon starts (census `targets, jobs`); over its pipe `job.status`, `job.show`,
   `job.events` of every Job and `job.list` equal the store's in-process answers (fresh
   snapshot revision and sealed cursors labelled); `job.timeline` and a two-page list are
   refused `rejected`; an absent Job is `notFound`. A one-event page's cursor is taken.
3. Stopped by its own stop request and restarted: the same answers, and the cursor from before
   the restart reads on to the remaining 15 events (the `jec1` key the store keeps). The records
   are byte-identical afterwards.
4. `jobs-state` created as an ordinary directory (inherited grants): the start is refused, exit
   69, "the Job store … is unusable …; nothing was started", no index created.
5. Real CLI against a copy of the daemon signed with the host-trusted development signer
   (`ARKDECK_DEV_SIGNER_THUMBPRINT` from `HKCU\Environment`, `windows-dev-identity.ps1 sign`):
   the Jobs recorded before the first start are read after a restart through
   `arkdeck job status|show|events --job <id>` and `arkdeck job list` (exit 0, results equal to
   the store's), and `arkdeck job timeline` reports the refusal (`operationFailed`, wire code
   `rejected`). **Ran** on this host (not skipped).

Not in this hop: a Job admitted and run by the Windows daemon itself (no planner/runner/HDC),
Session publication, the restart path's Job recovery (`recover_active_jobs`).

## Windows CLI coverage

Unchanged: `job.status`, `job.show`, `job.events`, `job.list` keep Windows `partial` (ruling 9:
a real surface, target contract not closed — no Job can be submitted or run on Windows yet, and
`job.list` is one page only). `cli-feature-coverage.json` and the oracle hashes pinning it are
therefore not regenerated.

## Local checks (Windows 11 x64, rustc per `rust-toolchain.toml`, `CARGO_TARGET_DIR` on D:)

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 | clean (Windows build of every crate) |
| `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-platform -p arkdeck-cli` (with `ARKDECK_DEV_SIGNER_THUMBPRINT`) | 0 | all pass; hoststore lib 57 passed, 2 ignored (was 31); `job_store_corpus` 2, `job_store_writer` 5, `job_store_files` 3; platform `windows_host_store` 10; agentd `windows_job_store_process` 3, `windows_client_start_process` 3, `windows_target_owners_process` 3 |
| `sh scripts/check-sdd.sh` (`ARKDECK_PYTHON` = the SDD venv, `PYTHONUTF8=1`) | 0 | 0 errors, 0 warnings |
| `git diff --check` | 0 | clean |

macOS and ubuntu cannot be built on this host. Every widened predicate is
`any(target_os = "macos", windows)`, so Linux compiles what it compiled before. The macOS arm of
every changed item was re-read: the moved `stepSetDigest`, `EpochIndexes` and
`recovery_epochs` are verbatim; `job_plan::step_set_digest` and `debug_hap_plan::compensations`
keep their signatures and map a missing step to the same `internal_failure()`; the record
reader maps it to the same `recordUnreadable`; `job_repository`'s macOS `create_database` and
`database_identity` are the previous statements; `job_owner::list` hands the same row producer to
the pager; the tests now also built on macOS (`job_store_corpus`, `job_store_files`,
`session_json`'s) create their copies owner-only (`journal_scratch`: `0700` directories, `0600`
files) and `job_store_writer` uses the same scratch roots instead of `/private/tmp`. CI decides.
`Cargo.lock` is unchanged.

## Open for the maintainer / next slices

1. `jobs-state` below the account root diverges from Swift's production layout (index at the
   state root) because the account root's DACL also grants SYSTEM. If the account root should
   become owner-only instead, the Job store could move to the root; recorded here, not decided.
2. When the ruling-7 port lands (E1, #2356), `snapshot_pager` can be built on Windows and the
   one-page `job.list` arm removed; `job.timeline` and multi-page lists follow, then the Session
   owner and `SessionPublisher`.
3. The replacement retry in the NTFS store is a platform behaviour every Windows owner now
   gets; its bound (≈1 s) is a judgement, measured only on this host.
