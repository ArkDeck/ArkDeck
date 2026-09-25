# A device mutation is admitted while the previous Job's Session is being published (TASK-XPA-014, macOS, 2026-09-26)

TASK-XPA-014 / CHG-2026-074. Found by the agent execution evidence slice
(`agent/xpa-015-agent-status-widening`, TASK-XPA-015). Its new process test runs `arkdeck agent run`
of a workspace copy and then of `input.tap@1` against the isolated Rust daemon, and about one run
in twenty refused the tap. The coordinator ruled that the fix goes in its own PR, ahead of that
slice's contract change.

Base: protected `main` `9bd452b55` (#2204). Disposable host data only; nothing here is device
evidence.

## Failure

In `check-contracts.py`'s candidate view the tap came back as a pre-admission refusal:

```
"code":"admissionDenied","message":"Session storage is being updated",
"details":{"method":"agent.run","newDispatchCount":0,"phase":"preAdmission"}
```

For an agent execution such a refusal is terminal, as Swift's `submitForAgent` treats it.

- `arkdeck agent run` returns once the owned Job is terminal. The daemon's run is still publishing
  that Job's Session, and it holds the Session owner's storage lock, `.session-storage.lock` (S),
  in two sections: `publication_status` (`session_publication.rs:172`) and
  `register_published_session` (`:429`).
- A device mutation proves the Runtime's mutation state (`MutationAuthority::require_state`)
  before its admission (`job_admission.rs:382`, workspace `:508`) and again before each
  consumption (`mutation_execution.rs:107`, `167`, `241`, `354`, `500`, `645`). The proof includes
  the Session root the storage status names. That status was read through the
  `runtime.storage.status` handler, whose `flock(LOCK_EX | LOCK_NB)` refuses a held lock
  (`resourceConflict` "Session storage is being updated"). An admission reports this as
  `admissionDenied`; a consumption as `authorizationRequired: …`.

A second race showed once the first was fixed and the new concurrency test ran in the full
`hoststore` suite (`recordUnreadable` "Runtime mutation state continuity cannot be proved"):

- The proof scans the Session root (`inspect_session_children`) after the status read has released
  S.
- A publication that changes the retention catalog writes it through a temporary
  `.arkdeck-retention-catalog.json.<nonce>.part` in that root, then renames it into place
  (`HostDirectory::publish_document`).
- A scan that listed the temporary name found it gone, and refused.

## Swift

- `ArkDeckAgentDaemonMain/main.swift` composes the engine's `validateMutationState` as
  `RuntimeStateContinuity.requireMutationState(…, sessionRoots: [URL(filePath: try
  runtimeSessionStorage.status().rootPath)])`. The engine calls it before a device mutation's
  admission (`RuntimeJobEngine.preauthorize`) and before each consumption.
- `RuntimeSessionStorageStore.status()` reads under `withLockedDocument`, which waits for the lock:
  `while flock(lock, LOCK_EX) != 0`, `EINTR` retried, with no bound.
- `RuntimeStateContinuity`'s scan skips a path that no longer exists. `rejectSymbolicLink` ignores
  a failed `lstat`, then `fileExists(atPath:isDirectory:)` is false, so the scan continues.
- `RuntimeJobEngine.operationAvailability` reads no storage and never calls
  `validateMutationState`.

## Change

- `SessionStore::waited_status` (`session_owner.rs:317`) is Swift's `status()`: the status under
  `HostDirectory::wait_lock(LOCK, false)`, a blocking `flock(LOCK_EX)` with `EINTR` retried and no
  bound, as Swift's.
  - The publication's own status read already waited (`publication_status`, since #1843) and now
    calls it.
  - `MutationAuthority::require_state` (`job_admission.rs:172`) reads the Session root through it
    instead of the `runtime.storage.status` handler, so both the admission and every re-check
    before a consumption wait.
- `MutationAuthority::state_proven_now` keeps the operation availability report
  (`arkdeck-agentd/src/host.rs:1064`) on the read that does not wait
  (`SessionStore::status_without_waiting`, `session_owner.rs:327`). A held lock reads as not
  proved, as before.
  - Swift's availability reads no storage.
  - Letting `operation.list`, `operation.describe`, `doctor` and target availability wait behind a
    publication or an export would be a new stall with no Swift counterpart.
  - The pre-existing difference, a mutation operation reported unavailable while the lock is held,
    is unchanged.
- The continuity scan skips an entry gone since its listing: `NotFound` from `kind_and_size`,
  `child` or `validate_path` (`mutation_state_continuity.rs`, `gone`). This is Swift's rule.
  - What is gone retains no Journal to prove, and anyone able to remove a Session could remove it
    before the scan anyway.
  - Everything else unreadable still refuses. An entry that is still there keeps every check, the
    journal replay included.

## Why the waits cannot deadlock

Checked against every acquisition of S. A read-only audit of `arkdeck-hoststore`,
`arkdeck-agentd` and `arkdeck-platform` found no other acquisition. The lock order is: Job slot →
Target lane → capability reservation guard → store locks. S is a store lock.

**What a thread holds when it waits for S.**
- **An admission** (`submit` → `preauthorize`, `job_admission.rs:315`) holds:
  - the `hdc_lifecycle` read guard from `admission_interlock()` at `:298`
    (`job_owner.rs:81`, `try_read`);
  - on an agent path, also the agent execution owner's `gate` (`agent_execution.rs:1394`).
- **A consumption** holds:
  - the global reservation guard (`DeviceHolds`' second mutex; `mutation_execution.rs:67`, `237`,
    `617`);
  - the Job's Target lane (`device_run.rs:381`–`388`, `405`–`410`) or the workspace lane;
  - its run slot.
- **Neither** holds `activity`, the Job index, the capability store's lock or a Target store lock at
  that point.

**What a thread holding S takes.**
- **The retention catalog lock, and only that.** It blocks in `register_session`
  (`session_inventory.rs:230`) and is only tried everywhere else. Inside the daemon every holder of
  the catalog lock already holds S, so that wait cannot close a cycle.
- **Nothing from the holders above.** No Session owner, inventory or export code references the
  reservation guard, a lane, a run slot, `gate`, `hdc_lifecycle`, `activity`, the capability store or
  the Target store.
- **The publisher's own position.** It takes S after its run has let go of its lane
  (`device_run.rs:388`/`410`) and its reservation guard. It persists after publishing
  (`job_run.rs:310`–`312`), and `agents.finish` runs after the whole run (`arkdeck-agentd/src/host.rs:679`).

**The remaining acquisitions.**
- **`require_state`** lets go of S (the lock is local to `waited_status`) before
  `require_mutation_state` locks `activity` (`mutation_state_continuity.rs:214`).
- **Session cleanup** holds `activity` (`job_owner.rs:454`, `with_active_sessions`) and only *tries*
  S (`session_cleanup_owner.rs:187`), so it never waits on S.
- **The `hdc_lifecycle` write side** is only tried (`job_owner.rs:103`, `try_write`).

**Not deadlocks, but new waits.** A consumption waiting for S holds the global reservation guard and
its lane. So a long S holder, such as an export or cleanup apply or a list or pin scan, delays
consumption on every Target until it ends, where before the consumption failed at once. An
admission waiting for S keeps `hdc_lifecycle` read-locked, so an HDC lifecycle action is refused
meanwhile. On an agent path it also keeps `gate`, so other `agent.*` requests queue.

Swift serializes the same way: its engine calls `validateMutationState` from inside the admission
and consumption it runs, and its status read waits without a bound.

## A difference left to its owner

The `runtime.storage.status`, `.policy` and `.root` methods still refuse a held lock, and
`rust/scripts/check-session-owner.py` holds them to it. The corpus has such refusals, recorded
from the Rust owner by #1843. Swift's `RuntimeStorageResourceHandler` waits (`status`,
`updatePolicy`, `updateRoot`, all under `withLockedDocument`).

The coordinator ruled on 2026-09-26 that this is the next slice: the methods are to wait as Swift
does, with the harness and corpus updated from a Swift recording. `status_without_waiting` stays
the availability report's own read after that change.

## A race left for a ruling

Rust's continuity scan descends into the `YYYY/MM/session-ID` tree, up to three levels. Swift's scan
looks only at the root's direct children, so for the current layout it never reads a Session's
Journal. The deeper scan sees a Session while it is being published. The publication creates the
Session's directories, then copies the Job's Journal event by event, then publishes the Manifest,
all without S (`session_publication.rs`, steps 5–7). During that window a device mutation's proof
can find one of the following:

- a Session directory with neither Journal nor Manifest, treated as a container. At depth 3 its
  `audit/` or `artifacts/` subdirectory is refused.
- a Journal whose copy is still in progress. Its torn tail refuses, and so does a mutation intent
  whose outcome has not been copied yet.

Swift never refuses there. Fixing it means deciding how the hardened scan treats an unfinished
Session, for example not descending into a directory that holds `.session-identity.json` without
a Manifest. That weakens or keeps a deliberate hardening, so it is left for a ruling. This PR does
not change it.

## Tests

- **`session_owner::tests::a_device_mutation_admission_waits_for_a_held_storage_lock`**: a held S
  keeps `require_state` from answering. Once S is released, it is admitted.
  - Negative control: with `job_admission.rs` as on `main`, the refusal arrives at once and the test
    fails at its first assertion.
- **`session_owner::tests::admissions_and_publication_reads_wait_for_each_other`**: #2147's shape.
  A publication's status read and an admission meet at a `Barrier` before each of 64 rounds, so
  they contend for S. Every publication must read the status and every admission be proved. There
  are no sleeps and no time bound; a deadlock would hang the test.
  - Negative control: with `job_admission.rs` as on `main`, it failed 5 of 5 runs, on an
    admission's refusal.
  - Before the scan fix, one full-suite run failed on the second race: the catalog's first
    publication in round one.
  - 20 of 20 runs pass alone.
- **`session_owner::tests::the_availability_report_reads_the_state_without_waiting`**: with S held,
  `state_proven_now` answers `false` at once. Once released, it answers `true`. A 60 s bound only
  turns a wait into a failure.
- **`job_owner::mutation_state_continuity::tests::an_entry_gone_since_the_listing_is_skipped`**:
  a listed name that no longer exists is skipped. A retained Session whose Journal does not
  replay, beside it, still refuses.
  - Negative control: with `gone` answering `false`, the first scan refuses and the test fails.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-vj-rust-target`, logs in
`/private/tmp/arkdeck-vj-logs/`. `arkdeck-agentd` and `arkdeck-soak` are the crates that depend on
`arkdeck-hoststore`.

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0 (`fix-fmt-r3.log`).
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak --all-targets -- -D warnings`: exit 0 (`fix-clippy-r3.log`).
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore -p arkdeck-agentd
  -p arkdeck-soak`: exit 0 (`fix-test-r3.log`), on the tree rebased on `9bd452b55`.
  - 109 suites: 825 passed, 0 failed, 14 ignored (the ignores already existed).
  - The `arkdeck-hoststore` library: 342 passed, 5 ignored.
  - The same three checks passed on `1bfa52054` before the rebase (`fix-fmt.log`,
    `fix-clippy.log`, `fix-test-r2.log`: 108 suites, 819 passed).
- The negative controls above, and `admissions_and_publication_reads_wait_for_each_other` alone 20
  times: 20 passed.
- `sh scripts/check-sdd.sh` (validation venv): exit 0 (`fix-check-sdd.log`).
- With the admission wait but before the scan and availability changes, TASK-XPA-015's process test
  `agent_run_cli_process` passed 10 of 10 runs on that slice's branch. That test is not in this PR;
  it runs again there after the rebase.
- Not run:
  - `generate-contract.py --check` and `check-contracts.py`: no contract input changes.
  - Swift and the App: nothing of theirs changes.
  - A device.

## CI

#2207, head `78b3e8390`, run 36166497620: every selected lane passed.
- Rust workspace: macOS 14m27s, Ubuntu 2m18s, Windows 4m49s. Host-independent checks: 45s.
- `guard`; `swift` aggregate.

It merged as `a3de6c316`. Recorded by the next slice (TASK-XPA-012, storage requests wait), as
AGENTS.md has it.
