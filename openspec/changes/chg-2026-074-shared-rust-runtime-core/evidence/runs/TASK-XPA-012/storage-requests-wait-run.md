# The Session storage requests wait for a held storage or catalog lock, as Swift's do (TASK-XPA-012, macOS, 2026-09-26)

TASK-XPA-012 / CHG-2026-074. #1843 served the Session storage settings from Rust, and later
slices served the Session resources and export. Wherever Swift waits for a Session lock, those
Rust owners refused a held one. #2207 (TASK-XPA-014) made a device mutation's admission wait, as
Swift's does, and left the rest.

The hub ruled on 2026-09-26 what this slice covers:
- `runtime.storage.status`, `.policy` and `.root`, with the retention catalog lock their status
  read takes;
- `session.list`, `.show`, `.pin` and `.unpin`;
- `session.export.preview` and `.apply`.

Session cleanup waits until after the publication slice, because its caller holds the Job
activity guard (see "Left as they are").

Base: protected `main` `3315a9cba` (#2217). The Rust checks below ran on this base. The Swift
oracle was recorded on `6c47b55e1` (#2208); since then main changed no Swift source, only one
contract test and one `workspace.project.show` ControlFrames line. Disposable host data only;
nothing here is device evidence.

## The difference

The storage lock is `session-state/.session-storage.lock` (S). The catalog lock is the selected
root's `.arkdeck-retention-catalog.lock` (C).

| Request | Lock Rust took with `LOCK_NB` | Its refusal (`resourceConflict`) |
| --- | --- | --- |
| `runtime.storage.status`, `.policy`, `.root` | S (`SessionStore::handle`) | "Session storage is being updated" |
| the same, reconciling the catalog | C (`session_inventory_owned`) | "Session catalog is being updated" |
| `session.list` (first page), `.show`, `.pin`, `.unpin` | S (`resource_rows`); C for the reconcile and the pin's compare-and-swap (`session_resource_rows`) | as above |
| `session.export.preview`, `.apply` | S (`with_session_configuration`); C (`session_export_snapshot`) | as above |

S is held:
- by every storage request;
- by a Session publication, for its status read and its catalog entry;
- by the Session resources, export and cleanup.

C is held only under S. So any of these requests could fail only because a Job had just ended,
or because another request was being answered.

## Swift

- `RuntimeSessionStorageStore` runs `status`, `updatePolicy`, `updateRoot`, `listSessions` (a
  first page), `showSession`, `updateSessionPin`, `previewSessionExport` and
  `applySessionExport` under `withLockedDocument`. That lock waits:
  `while flock(lock, LOCK_EX) != 0`, `EINTR` retried, with no bound.
- `SessionRetentionCatalog` waits for C the same way (`SessionRetentionCatalog.swift:875`).
- A cursor's page reads its private snapshot under no lock. `RuntimeSnapshotPager` takes no file
  lock at all.
- Parameters are checked before any lock. The first recording ran into this: an export preview
  without `allowSensitive` answered `invalidInput` at once.

## Change

Each item states what its caller holds when it waits.

1. **`runtime.storage.*`.** `SessionStore::handle` takes S through `HostDirectory::wait_lock`: a
   blocking `flock(LOCK_EX)`, `EINTR` retried, no bound.
   - Caller: `arkdeck-agentd` `runtime_storage`, on the control connection's thread, after
     measuring the Artifact domain (`ArtifactUsage::status`), which takes no lock.
   - It holds nothing.
2. **The catalog lock.** The owned inventory (`inventory` in `session_inventory.rs`, behind the
   status read of every storage request and resource read) and `session_resource_rows`' pin
   compare-and-swap wait for C (`wait_lock`), as does the export inventory
   (`session_export_inventory.rs`).
   - Caller: each runs under S.
   - Every holder of C in the daemon holds S, so under S it only waits for a holder outside the
     daemon.
   - The now-unreachable "Session catalog is being updated" mappings are gone.
3. **Session resources.** `resource_lock` waits for S. `session.list` takes it before the snapshot
   pager, for a first page only, as Swift's `listSessions` does. `show`, `pin` and `unpin` take
   it first. `resource_rows` works under the lock it is given.
   - Caller: `arkdeck-agentd`'s Session resource route.
   - It holds nothing; a first page holds no snapshot lock while it waits.
   - Taking the pager's lock first, as before, would have kept every cursor page refused ("Snapshot
     storage is being updated") while a first page waited.
4. **Export.** `preview_export` and `apply_export` go through `with_waited_session_configuration`,
   which waits for S.
   - Caller: `arkdeck-agentd`'s export routes.
   - They hold nothing: no Job activity guard, which only cleanup takes.
5. **Cleanup, unchanged.** `preview_cleanup` and `apply_cleanup_with_checkpoint` keep
   `with_session_configuration`, which only tries S. Its catalog lock
   (`session_cleanup_inventory.rs`) is unchanged too.

Also changed:
- `rust/scripts/check-session-owner.py`, `check-session-resources.py` and
  `check-session-export.py` expect the waits, through the real daemon and socket (see below);
- `rust/README.md`;
- #2207's record gains its CI line.

## Why the waits cannot deadlock

- The waiters for S hold nothing (items 1, 3, 4) or are publications holding only their
  `RunSlot`. A waiter for C holds only S.
- A holder of S takes only C: a storage request, a resource read, an export, a publication's
  status read or catalog entry. A first `session.list` page also tries the snapshot pager's lock.
  - Nothing waits for that lock; every taker only tries it.
  - Nothing waits for S while holding it: a cursor page takes no S.
- A device mutation's admission and consumption wait for S holding their own guards (#2207's
  record), and no holder of S takes those guards.
- The one holder of the Job activity guard that takes S, cleanup, only tries it.
- What changes: a request now waits as long as another holder keeps S or C, as Swift's does. The
  longest holders are an export apply and a cleanup apply. The CLI's 30 s request budget can end
  a client's wait first.

## The Swift oracle

`StorageLockWaitOracleContractTests` (ArkDeckContractTests) records
`rust/tests/fixtures/storage-lock-wait-oracle/`:
- `frames.jsonl`, eight exchanges;
- `manifest.json`, the one retained Session's Manifest.

It drives the production `RuntimeControlPlaneHandler` over three stores:
- a `RuntimeSessionStorageStore` whose clock is 2026-09-26T00:00:00Z;
- a `RuntimeArtifactStore` whose quota is the Rust daemon's, 8 GiB;
- `session-fixture`, a finalized Session completed 2026-09-01, in the root the requests select.

The root is fixed at `/private/tmp/arkdeck-storage-lock-wait-oracle`.

| # | Request | Held | Answered once released |
| --- | --- | --- | --- |
| 0 | `runtime.storage.status` | S | generation 1, default root |
| 1 | `runtime.storage.policy` (generation 1) | S | generation 2 |
| 2 | `runtime.storage.root` (generation 2, `custom`) | S | generation 3, one Session, 1230 bytes |
| 3 | `session.list` (page size 10) | S | the Session, catalog generation 0 |
| 4 | `session.pin` (generation 0) | S | pinned, generation 1 |
| 5 | `runtime.storage.status` | C of `custom` | catalog generation 1, 1230 bytes pinned |
| 6 | `session.export.preview` | S | a ready preview, 1105 bytes estimated |
| 7 | `runtime.storage.status` | nothing | the state the requests left |

- **The wait.** For every frame but the last, no answer may arrive within 200 ms of sending; each
  arrives once its lock is released.
- **Labels.** Random and host values are recorded as labels: the list's `snapshotRevision`; the
  preview's `previewId` and `previewDigest`; its destination's and source's devices, inodes and
  volume.

Swift's answers were recorded (r1) in a Swift window the hub granted, then compared byte for byte
in a second run (r2). Both runs were `run-swiftpm.sh test --filter
StorageLockWaitOracleContractTests`, exit 0 (`/private/tmp/arkdeck-vj-logs/swift-storage-r1.log`,
`swift-storage-r2.log`). In Swift every frame but the last waited, the status read under C among
them: no answer arrived while its lock was held.

## The Rust replay

`storage_lock_wait_oracle` (`arkdeck-hoststore/tests`):
- lays down the same root and Session;
- holds the same lock for each frame and sends the same request as `arkdeck-agentd` composes it;
- requires every frame but the last to be still waiting 200 ms after sending;
- requires every answer to be Swift's byte for byte, with the same labels applied, and to
  conform to the method's published schema.

One reading applies. Swift records a root under `/private/tmp` without `/private`: its
`canonicalRoot` resolves through `resolvingSymlinksInPath` and `standardizedFileURL`, which drop
`/private` where the path without it exists. Rust's `canonicalize` keeps it. The replay reads the
Rust root that way. The difference predates this slice and shows only for a root under `/private`;
an installed root, under `~/Library`, shows none.

## The check scripts

Each runs through the real daemon and socket.
- **`check-session-owner.py`.** It holds S and sends a request, which must still be waiting half
  a second later and be answered once S is released: `runtime.storage.status` where a `.policy`
  refusal was, then `.policy` and `.root` at the end.
- **`check-session-resources.py`.** With S held, a cursor page still answers at once. `session.show`
  waits with S held and again with C held, and answers the unchanged Session; it replaces a
  refused `session.pin` in each place, so later generations are unchanged.
- **`check-session-export.py`.** `session.export.preview` waits with S held and then answers the
  same source and catalog status as the preview before it.
- **`check-session-cleanup.py`.** Unchanged: cleanup still refuses a held S.

## The corpus

`runtime.storage.policy.jsonl` keeps the refusal #1843 recorded from the Rust owner, although Swift
never gives it. The corpus is append-only, and both owners still answer `resourceConflict` for a
stale generation, so the derived schemas do not change. No contract input changes. The oracle's
frames are not appended: they hold no shape the corpus lacks.

## Left as they are

- **Session cleanup** (`preview_cleanup`, `apply_cleanup_with_checkpoint`) still tries S, and its
  inventory still tries C.
  - It holds the Job activity guard when it does. The publication slice (TASK-XPA-014) puts a
    device mutation's proof, which takes that guard, under S.
  - Cleanup is to wait only once it takes S before the guard. The hub ruled it a slice after that
    one.
- **A failed `flock`.** Rust maps it to `recordUnreadable`; Swift maps it to `resourceConflict`
  "Session storage lock cannot be acquired". It shows only when `flock` itself fails.
- **The `/private` root reading**, above.
- **The snapshot pager's own lock.** Rust takes it; Swift's pager has none. A cursor page read
  while a first page is being stored can be refused ("Snapshot storage is being updated"), in a
  window as short as storing the snapshot. This predates the change.

## Tests

- **`session_owner::tests`**
  - `storage_requests_wait_for_a_held_storage_lock`: status, policy and root.
  - `storage_writes_and_publication_reads_wait_for_each_other`: #2147's shape. A `Barrier` before
    each of 64 rounds; no sleeps and no time bound.
  - `corrupt_configuration_is_not_replaced_and_a_held_catalog_lock_delays_a_policy_write`. It
    asserted a refusal before.
- **`session_inventory::tests::unknown_content_counts_bytes_and_a_held_catalog_lock_delays_initialization`**.
  It asserted `WouldBlock` before.
- **`session_owner::cleanup::tests::a_first_session_page_waiting_for_the_storage_lock_leaves_cursor_pages_readable`**.
- **`storage_lock_wait_oracle`**, above.
- **Negative controls**, each change undone alone:
  - `handle` taking S with `LOCK_NB`: the replay failed at frame 0, the unit tests 3 of 3 runs, and
    `check-session-owner.py` on the status refusal.
  - `resource_rows` taking S with `LOCK_NB`: the replay failed at frame 3.
  - The owned inventory taking C with `LOCK_NB`: frame 5.
  - Export not waiting: frame 6.
  - The first page taking S inside the pager: the cursor test failed ("Snapshot storage is being
    updated").

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-vj-rust-target`, logs in
`/private/tmp/arkdeck-vj-logs/`, on `3315a9cba`. The host was loaded (1-minute load between 9 and
19 at the samples taken) while the crate tests ran.

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0 (`s2b-fmt.log`).
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --all-targets -- -D warnings`: exit 0 (`s2b-clippy.log`).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --no-fail-fast`: exit 0, 110 suites, 811 passed, 0 failed, 13 ignored (the
  ignores already existed); the `arkdeck-hoststore` library 320 passed (`s2b-test.log`).
- `python3 rust/scripts/check-session-owner.py`, `check-session-resources.py`,
  `check-session-export.py` and `check-session-cleanup.py`, each with `--bin-dir` on this tree's
  build: `PASS` each (23, 27, 15 and 27 control exchanges; `s2b-scripts.log`).
- Swift, in a window the hub granted: `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test
  --filter StorageLockWaitOracleContractTests`, recording (r1) and then comparing (r2): exit 0
  both (`swift-storage-r1.log`, `swift-storage-r2.log`).
- The negative controls above, on `6c47b55e1`.
- `sh scripts/check-sdd.sh` (validation venv): exit 0.
- Not run:
  - `generate-contract.py --check` and `check-contracts.py`: no contract input changes.
  - The App: nothing of it changes.
  - A device.

## CI

Pending.
