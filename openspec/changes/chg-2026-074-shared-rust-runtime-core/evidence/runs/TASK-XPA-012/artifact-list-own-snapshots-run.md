# The Artifact list keeps its own snapshots, where Swift's does (TASK-XPA-012, macOS, 2026-09-26)

TASK-XPA-012 / CHG-2026-074. The Rust `artifact.list` kept its page snapshots in the Job owner's
`cli-job-snapshots`, where `job.list` and `job.timeline` keep theirs. One pager's retention then
reclaimed the other's snapshots: 32 Artifact lists reclaimed a Job list's snapshot, and its cursor
answered `invalidCursor`. #2246's record listed this for its own slice. The coordinator assigned
it on 2026-09-26, the hub relayed it, and both agreed the terms below:
- **The directory** is Swift's, `<Artifact root>/.imports-v1/artifact-snapshots`.
- **The pager's bounds and order** are Swift's, cited by line.
- **Swift keeps no lock file.** The `.snapshots.lock` of the Rust locked pager is an existing
  difference of the shared pager: recorded, not changed.
- **Upgrade.** Old Artifact snapshots are not moved. An old cursor answers Swift's
  `invalidCursor`, and the Job owner's pager reclaims the residue; a test pins both.
- **The Trace census** keeps treating the new directory as an entry that retains every Trace
  entry: recorded below, not changed.
- **No contract input changes.**

Base: protected `main` `8bddca654` (#2249). Disposable host data only; nothing here is device
evidence.

## Swift

`RuntimeArtifactStore.artifactInventory` (`RuntimeArtifactStore.swift:1093–1113`):
- **It opens the Import store first** (`_ = try imports()`, `:1098`). That makes `.imports-v1` and
  its `records`, `identities` and `payloads` directories, each private (`:1470–1475`;
  `RuntimeImportStore.swift:57–69`).
- **It then pages in `.imports-v1/artifact-snapshots`** (`:1099`). The comment at `:1096–1097`:
  "Keep snapshots inside the already-private, non-Job Import metadata tree. They never appear in
  Artifact quota inventory or Job history."

Each Swift pager has its own directory:
- `job.list` and `job.timeline`: `<state>/cli-job-snapshots` (`RuntimeJobEngine.swift:5252`,
  `:5303`);
- `artifact.import.list`: `.imports-v1/snapshots` (`RuntimeArtifactStore.swift:1574`);
- `artifact.list`: `.imports-v1/artifact-snapshots`.

All three are one type, `RuntimeSnapshotPager`:

| What | Swift (`RuntimeSnapshotPager.swift`) | Rust (`snapshot_pager.rs`) |
| --- | --- | --- |
| Its directory | made private (0700) on first use; one that is not private is refused (`:24–38`) | opened (`:198`); each owner makes it private |
| Snapshot and page bounds | 16 MiB and 1 MiB (`:21–22`) | the same (`:23–24`) |
| More than 32 documents | refused (`:157`) | refused (`:447`) |
| Reclaim order | oldest modification date first, then name (`:173`) | the same (`:450`) |
| Reclaimed while | 32 or more remain, or they exceed 64 MiB (`:174–176`) | the same (`:25`, `:453`) |
| A missing snapshot, another query's cursor or an unknown token | `invalidCursor`, "cursor is invalid, belongs to another query or its snapshot was reclaimed" (`:112–113`, `:118`, `:63`) | the same words (`:50–63`) |
| Lock file | none | `.snapshots.lock` beside the snapshots (`:26`, `:286`) |

The pager is unchanged.

## Change

- **`ArtifactReadStore::list_snapshots`** (`artifact_read_owner.rs:203`) answers
  `<Artifact root>/.imports-v1/artifact-snapshots`.
  - On the first list it makes `.imports-v1` and `artifact-snapshots`, each private (0700).
  - After that it opens them: no directory is made or synced again on each list.
- **`handle_list` and `handle_owned_list`** (`artifact_resources.rs:119`, `:136`) page there. They
  no longer take a directory, and neither does `ImportUploadStore::artifact_resource`
  (`import_publication.rs:306`, `:360`).
- **The daemon** (`host.rs:1324`, `:1329`) no longer asks the Job owner for the directory.
  - An Import owner's Artifact resources no longer need a Job owner, as in Swift. The refusal
    "Artifact snapshot storage is unavailable" is gone.
  - A Job owner's `artifact.list` without a Job owner is still refused
    (`operationUnavailable`, "Artifact Job owner is unavailable", the same details). The refusal
    now comes from the owner check, after the parameters are read, as for `artifact.read`,
    `.inspect` and `.export`.
  - **This is Swift's order** (`RuntimeArtifactResourceHandler.swift`):
    1. the Artifact store (`:16`);
    2. closed parameters with one tagged owner (`:26–28`);
    3. the owner (`:29`);
    4. a Job owner's existence, asked of the engine (`:30`);
    5. the cursor (`:47`), then the page size and the list (`:50`).

    Rust's `handle_owned_list` checks in the same order (`artifact_resources.rs:141–172`). A
    missing Job owner is answered at step 4, where Swift asks its engine.
  - **Swift has no such state.** The engine is not optional (`:7`) and the daemon always passes
    it (`AgentDaemon.swift:1230–1236`). Both Rust daemon compositions compose a Job owner
    (`production.rs:578`, `main.rs:430`), so the refusal is not observable there either.
- **`JobStore::snapshot_directory`** served only this and is removed.

**Declared differences:**
- **The lock file** (above) is unchanged. The new directory gets its `.snapshots.lock`, as every
  Rust pager opened with `open` does.
- **The Import skeleton.** Swift's list also makes `records`, `identities` and `payloads`; Rust's
  makes only `.imports-v1` and `artifact-snapshots`. Both daemon compositions open the Import owner,
  which makes the skeleton (`import_upload.rs:331–335`), before the Artifact owner
  (`production.rs:567`, `main.rs:421`), and neither starts without it. The two trees are the same
  whenever the daemon answers.
- **A directory that is not private** is refused with `recordUnreadable` in both. Swift's message
  names the store; Rust's is "Artifact resource is unreadable", as it was for the Job owner's
  directory. Unchanged.

## Upgrade

- **Old Artifact snapshots are not moved.** An earlier Rust Runtime left them in
  `cli-job-snapshots`.
- **An old cursor.** The new directory has no such snapshot, so the list answers `invalidCursor`,
  "cursor is invalid, belongs to another query or its snapshot was reclaimed", with
  `{"phase":"artifactOwner","newDispatchCount":0}`. That is Swift's answer for a reclaimed
  snapshot; the caller lists again.
- **The residue** counts toward the Job owner's budget of 32 snapshots and 64 MiB. It is older than
  any Job snapshot written since, so it is the first reclaimed once that budget is reached. Until
  then it stays within the same bound as before, and nothing reads it.

## The Trace census (recorded, not changed)

- **What it retains.** `with_trace_retention` (`artifact_read_owner.rs:278`) retains every Trace
  entry while the Artifact root holds anything it cannot prove inactive.
  - Below `.imports-v1` it accepts only the empty Import skeleton and the owner lock
    (`import_namespace_retains`, `:333`). Any other entry retains every Trace entry.
- **The effect.** After the first `artifact.list`, `artifact-snapshots` is such an entry, and
  Trace maintenance retains every Trace entry from then on.
  - Any Job or Import directory in the Artifact root already has that effect, and every owner
    with Artifacts to list has one.
  - It is new only for a root whose listed owners have no Artifacts. Rust, unlike Swift, makes no
    empty Job directory for them.
- **Left as it is,** at the coordinator's direction.

## Tests

**New: `tests/artifact_list_snapshots.rs`.** The fixture is a Job owner root beside an Artifact
root, with two finished Jobs and two Artifacts of one of them.
- **`the_artifact_list_keeps_its_pages_where_swift_does`:**
  - the first page makes `.imports-v1/artifact-snapshots` (0700) and keeps its one snapshot there,
    named by its revision;
  - the Job owner's directory holds none;
  - the next page is read from it;
  - the Artifact usage census and quota answer as before.
- **`artifact_lists_leave_a_job_list_cursor_alone`:** a Job list's first page, then 40 Artifact
  lists (the Artifact directory ends with 32). The Job list's cursor still answers its next page,
  and the Job owner's directory holds its one snapshot.
- **`an_artifact_snapshot_of_before_is_answered_as_reclaimed_and_reclaimed_by_the_job_pager`:**
  1. An Artifact list's snapshot is moved into `cli-job-snapshots`, as an earlier Runtime left it.
  2. Its cursor answers `invalidCursor` in Swift's words, with the Artifact owner's details.
  3. 31 Job lists bring the directory to 32 snapshots, the residue still among them.
  4. The next Job list reclaims the residue, and only it.

**`tests/flash_run.rs`.**
- Swift's tree for the Flash stories holds `artifacts/.imports-v1/artifact-snapshots` (0700). It is
  no longer declared Swift-only: the Rust tree must hold it, with the same mode.
- Each pager's snapshots are counted in their own directory. They used to be summed across both.

**The other call sites** drop the directory argument.

**Negative control.** `list_snapshots` answered the Job owner's `cli-job-snapshots`, the shared
directory of before:
- **`artifact_lists_leave_a_job_list_cursor_alone`** failed where the Job list's cursor is read
  again after the 40 Artifact lists. It answered `invalidCursor`, "cursor is invalid, belongs to
  another query or its snapshot was reclaimed": the bug this slice fixes.
- **The other two new tests** failed: the directory they look in was never made.
- **Five Flash replays** failed (`alias`, `canonical`, `reconcile`, and `recovery` twice). Swift's
  Artifact snapshot directory was missing from the Rust tree, and the Artifact pager's snapshots
  were counted among the Job owner's.

With the change restored, all of these pass again.

## Contract

No contract input changes.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-vj-rust-target`, logs in
`/private/tmp/arkdeck-vj-logs/`, on `8bddca654`, 10:00–10:20, before the hub's 12:30–13:10 quiet
window. The 1-minute load was 3.5 to 7.

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --all-targets -- -D warnings`: exit 0 (`s37-clippy2.log`).
  - The same with `--target x86_64-pc-windows-msvc` and with `--target x86_64-unknown-linux-gnu`:
    exit 0 each (`s37-clippy-cross.log`).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --no-fail-fast`: exit 0 (`s37-test.log`): 116 suites, 858 passed, 0 failed, 18
  ignored (the ignores already existed).
- The negative control above (`s37-nc.log`).
- `sh scripts/check-sdd.sh`: exit 0.

**After the rebases** onto `952e28604` (#2251) and then `f9d6cac06` (#2252), the ArkForge lane's
managed control and execution authority, which touch none of these files (`s37-rebased.log`,
`s37-rebased2.log`), each time:
- fmt and the same native clippy: exit 0 each.
- `cargo test -p arkdeck-hoststore --test artifact_list_snapshots --test flash_run --test
  import_upload`: exit 0, 3, 12 and 36 passed (1 ignored, existing).

**Not run:**
- `generate-contract.py --check` and `check-contracts.py`: no contract input changes.
- The App and a device.

## CI

#2254, head `4263b241c`, run 36211694831: every selected lane passed.
- Rust workspace: macOS 10m43s, Ubuntu 2m17s, Windows 4m22s. Host-independent checks: 32s.
- `guard` (run 36211694648); `swift` aggregate. `swift-tests` was not selected.

It merged as `20130b631`. Recorded by the next slice (TASK-XPA-019, the App ingress's door
refusals), as AGENTS.md has it.
