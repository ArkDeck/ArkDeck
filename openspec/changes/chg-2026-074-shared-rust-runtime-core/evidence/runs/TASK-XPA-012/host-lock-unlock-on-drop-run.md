# Host-store owner locks unlock before they close — macOS, 2026-09-14

TASK-XPA-012 remains in progress. Base: protected main `2b7c1405` (#1901). This change revises the
fix #1899 merged the same day; `host-lock-spawn-window-run.md` keeps the mechanism, the
measurements and the process inventory. It changes no durable format, lock file, method, schema,
CLI leaf, entitlement or installed state. Every fixture below is disposable host data; nothing here
is device evidence. The tests and measurements below ran on `c8d20163` (#1899); since then #1900
(`job.cancel` for running Jobs) changed no lock code, and #1901 added only the Swift owners'
regression tests and their record.

## Already on main / this change / still remaining

| Already on main | This change | Still remaining for TASK-XPA-012 |
| --- | --- | --- |
| #1899: owner locks are retried for up to 500 ms before refusing; its record measures the spawn window and finds the isolated owner's `job.run` exposed | `HostReadLock` unlocks before its descriptor closes; the retry and the facade test that pinned it are removed; regression tests; corrections to the #1899 record | As before: installed ownership of the Session, Trace cache, Bootstrap and Target stores, tool selection writes, trace database preparation, GJ-1 |

## Why the fix changes

`flock` locks belong to the open file description. `flock(fd, LOCK_UN)` releases the lock for
every reference to that description at once, including the one a spawned child holds between fork
and exec; only a release by closing the descriptor leaves the lock held until the child execs. A
separate session checking the Swift owners found this. It is measured here with the #1899 probe,
changed only to unlock before closing. Apple M3, 8 cores, macOS 26.6.2, 100,000 acquisitions per
row, load average 21 → 44:

| Spawn | Busy | Close only | Unlock, then close |
| --- | ---: | --- | --- |
| `posix_spawn` | 0 | 78 refused, held up to 0.73 ms | 0 refused |
| fork + exec | 0 | 60 refused, held up to 15.3 ms | 0 refused |
| production flags | 0 | 75 refused, held up to 5.8 ms | 0 refused |
| production flags | 16 | 137 refused, held up to 126.9 ms | 0 refused |
| fork + exec | 16 | 233 refused, held up to 67.4 ms (#1899 record) | 0 refused |

Rust's `HostReadLock` released by closing its descriptor, so #1899 could only outwait the child. A
retry races the window: the 126.9 ms above already exceeds the 106 ms that sized #1899's bound. It
never helped an acquirer that makes a single non-blocking attempt from another process, such as a
Swift owner or a harness probe, and it delayed every genuine refusal by 500 ms.

Swift's owners already unlock first: `BootstrapBundleRegistry`,
`RuntimeToolSelectionControlActionStore` and `RuntimeHDCControlActionStore` through defers that run
the unlock before the close, `SessionAudit` and `RuntimeUpdateStateStore` in `deinit` and on their
failure paths. The #1899 record's residual that called them exposed was wrong; it now says so. The
Swift regression tests are #1901 (`OwnerLockSpawnWindowContractTests`,
`swift-owner-lock-spawn-window-run.md`), which shares no file with this change.

## Change

- `impl Drop for HostReadLock`: `flock(LOCK_UN)` on the descriptor, which then closes. Every owner
  lock is a `HostReadLock`: `lock_document`, `try_lock_existing`, `try_lock_existing_strict`,
  ArkTrace's `try_trace_lock_existing`, the Job journal's manifest lock and Session publication's
  `wait_lock`.
- The #1899 retry (`HostDirectory::LOCK_WAIT`) is removed: one non-blocking attempt, and a second
  live owner is refused at once again, as before #1899 and as Swift's non-blocking owners refuse.
- The facade test #1899 added (`a_lock_released_within_the_wait_is_taken_instead_of_refused`) is
  removed with the retry. A second holder that releases later is not a spawned child: without a
  wait, any single non-blocking attempt refuses it, so it tested the retry, not the window.
- `rust/README.md` states the unlock instead of the retry.

A child's exec closes its own reference without unlocking, so a live owner keeps its lock while
children come and go; only the owner's release unlocks it (tested below).

## Regression tests

`arkdeck-platform` `tests/host_lock_spawn_window.rs`, a test binary of its own (the workspace lint
forbids `unsafe` outside `arkdeck-platform`, and holding a child before its exec needs `pre_exec`):

| Test | On `c8d20163` (#1899) | With this change |
| --- | --- | --- |
| `a_lock_released_while_a_forked_child_shares_it_is_free_at_once`: a close-only control stays held while a child waits between fork and exec; then at each of the three entry points the owner takes the lock, a child forks, the owner drops it, and one non-blocking attempt from a new open file description must succeed | fails: `entry 0: a released owner lock stayed held by a forked child` | passes |
| `a_live_owner_keeps_its_lock_while_children_come_and_go`: a child that shared the owner's descriptor execs and exits; every entry point and a single attempt are still refused while the owner lives | passes | passes |
| `drop_and_reopen_survive_children_another_thread_spawns_in_a_loop`: 20,000 release-and-reacquire cycles across the three entry points while another thread spawns children that delay their exec by 2 ms | passes, by waiting | passes without waiting, 0 refused |

The first row is the regression: with the retry, a released lock still refuses the single attempt
any other owner makes. The loop test refused 10,167 of 20,000 before #1899 (#1899 record).

## The isolated daemon

The #1899 driver (200 analyzer `job.run`s, one analyzer child each, while a second client pipelines
`history.filter.list`) against the daemon built from this change (SHA-256 `da8b21c463175d36…`): 200
succeeded, 748,500 History requests, 0 `resourceConflict`, load average 25 → 87. The #1899 record
has the unfixed baseline: 227 of 733,100 refused at `ac66aaa3`.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| New tests, repeated | the built `host_lock_spawn_window` test binary, 20 runs at load average 25 – 29 | 20 passed, 0.5 – 1.1 s each |
| Affected crates | `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli --no-fail-fast` | all passed (49 result lines); `bootstrap_missing_lock.rs` 1.0 s → 0.01 s now that refusals no longer wait |
| Format | `cargo fmt --all --check` | clean |
| Clippy, three targets | `cargo clippy --workspace --all-targets [--target x86_64-pc-windows-msvc \| x86_64-unknown-linux-gnu] -- -D warnings` | exit 0 each |

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding `PyYAML==6.0.3` and
`jsonschema==4.26.0`. The planner selected the common checks and the Rust lane only. Logs: session
scratch `gate-r3.log` and `gate-r4.log`.

- Final run on commit `6d572549` (base `446d9248`): the same steps as the first run below, 134
  `cargo test` results all ok with the three new tests passing in both contract views;
  `gate exit=0`, 2,114 lines, SHA-256 `51bcef8f779ab8c358c5db868076fbd8b63621b9f8beecc1bfdfc784fa3b59db`.
- First run on commit `3e3abe5f` (base `c8d20163`): SDD (0 errors, 0 warnings, 121 acceptance IDs),
  the catalog generator check and its tests, the planner and agent-PR workflow tests,
  `generate-contract.py --check`, `cargo fmt --check`, warnings-denied Clippy, the workspace tests,
  `test_contract_checks.py`, `check-contracts.py` with both views and every candidate process harness
  passing, `cargo deny` and `cargo vet` (36 fully audited); 132 `cargo test` results all ok, the three
  new tests among them in both views; `gate exit=0`, 2,080 lines, SHA-256
  `c9f1ccb9bf811a1c8073871ef4e6e06246f4501a42e1c5936d60f2b81eb6d630`.

After the final run the branch was rebased over #1901, which adds only a Swift test and its record,
so no input of the Rust lane changed. The common checks (SDD, the catalog generator check and its
tests, the planner and agent-PR workflow tests) were re-run on the rebased commit, which differs from
`6d572549` only in its base and in this record's header and gate section.

## Not run, and why

- Installed activation: no installed state changes, and the installed facade was not exposed.
- The real Swift pair (`check-facade-host-owners.py`): forwarding, lock files and formats are
  unchanged.
- GJ-1: a host-only change; no device is involved.

## Residuals

- A process that dies while one of its children sits between fork and exec releases its locks by the
  kernel's close, not by an unlock, so they stay held until that child execs. Only process death does
  this; every Rust release path unlocks.
- A lease lock that another process releases by closing alone while it spawns still looks in use to
  `try_trace_lock_existing` for the window; that entry is kept, never removed.
