# Host-store owner locks while children are spawned — macOS, 2026-09-14

TASK-XPA-012 remains in progress. Base: protected main `fffcaa93` (#1897). This change fixes the
shared lock primitive of the Rust host-store owners (`arkdeck-platform` `HostDirectory`). It changes
no durable format, lock file, method, schema, CLI leaf, entitlement or installed state. Every fixture
below is disposable host data; nothing here is device evidence. The measurements ran on the bases
named with them; #1897 (`job.cancel`) changes neither the lock code nor the analyzer spawn.

## Already on main / this change / still remaining

| Already on main | This change | Still remaining for TASK-XPA-012 |
| --- | --- | --- |
| Rust owners take `flock(LOCK_EX \| LOCK_NB)` once and map a held lock to `resourceConflict` (or `WouldBlock`); the Job journal's manifest lock already retries for 5 s; the isolated owner runs analyzer children for `job.run` (#1894) and publishes their Sessions (#1896) | Owner locks are retried for up to `HostDirectory::LOCK_WAIT` (500 ms) before the same refusal; regression tests; the measurements below | As in `facade-history-owner-run.md`: installed ownership of the Session, Trace cache, Bootstrap and Target stores, tool selection writes, trace database preparation, GJ-1 |

## Mechanism

Swift CI run 34764599985 failed a test binary that reopened an Import owner while another test in
the same binary spawned children (TASK-XPA-013 `import-upload-process-binary.md`, fixed on the test
side by #1890). A spawned child shares every open file description of its parent until its exec
closes the close-on-exec descriptors. A `flock` belongs to the open file description, so a lock the
parent has already released stays held until the child execs, and a non-blocking reacquisition in
that window fails with `EWOULDBLOCK`, whether this process or another one makes it.

A C probe measures it. One thread spawns `/usr/bin/true` and reaps it in a loop; the main thread
repeats the owner's acquisition 100,000 times and, on a refusal, keeps retrying the same descriptor
to time how long the lock stays held:

```c
int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NONBLOCK, 0600);
if (flock(fd, LOCK_EX | LOCK_NB) != 0) {          /* EWOULDBLOCK: refused */
  uint64_t t0 = now_ns();
  while (flock(fd, LOCK_EX | LOCK_NB) != 0) {}
  held[refused++] = now_ns() - t0;
}
close(fd);
```

Apple M3, 8 cores, macOS 26.6.2, 100,000 acquisitions per row. "Busy" adds that many spinning threads
to the probe; the host also carried other sessions' builds, so its load average is given per row.

| Spawn | Busy | Load average | Spawns | Refused | Held p50 | Held p99 | Held max |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| `posix_spawn` | 0 | ≈12 | 1,497 | 72 | 0.07 ms | 0.39 ms | 0.39 ms |
| fork + exec | 0 | ≈12 | 1,128 | 55 | 0.56 ms | 1.45 ms | 1.45 ms |
| `posix_spawn` | 16 | 12 → 25 | 2,506 | 129 | 1.10 ms | 24.2 ms | 25.4 ms |
| fork + exec | 16 | 12 → 25 | 2,109 | 233 | 2.57 ms | 36.5 ms | 67.4 ms |
| `posix_spawn` | 32 | 15 → 30 | 4,849 | 204 | 1.14 ms | 38.8 ms | 82.2 ms |
| fork + exec | 32 | 15 → 30 | 3,288 | 291 | 3.08 ms | 65.2 ms | 106.1 ms |
| production flags | 0 | 116 – 136 | 1,306 | 170 | 0.77 ms | 11.9 ms | 15.8 ms |
| `posix_spawn` | 0 | 116 – 136 | 1,315 | 150 | 0.97 ms | 10.3 ms | 12.2 ms |
| production flags | 16 | 116 – 136 | 3,181 | 241 | 1.31 ms | 41.2 ms | 89.6 ms |
| `posix_spawn` | 16 | 116 – 136 | 3,344 | 235 | 1.19 ms | 34.1 ms | 67.4 ms |

"Production flags" is the spawn `arkdeck-platform` `macos_process.rs` performs for every verified tool
and analyzer: `POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT`
with stdio file actions, then `SIGCONT`. Closing descriptors by default at exec does not shorten the
window.

## Production processes

| `arkdeck-agentd` mode | Owner locks | Children spawned in the same process | Exposed |
| --- | --- | --- | --- |
| Facade (the installed LaunchAgent program) | `history.filter.*`: `HistoryStore::open` and `lock_document` per request (`facade_owners.rs`) | The paired Swift daemon, once and synchronously, before the listener accepts or the Mach service starts (`facade.rs`) | Not today: no owner lock is held while that spawn runs. Any later spawn in this process would expose it. |
| Isolated owner (`ARKDECK_DEVELOPMENT_STATE_ROOT`) | Every store is opened once at startup and each request takes and releases its owner lock (`lock_document`; Bootstrap reads `try_lock_existing_strict`). The Import owner and the Job repository hold theirs for the process lifetime | `job.run` for `analyzer.extract-crash-signature@1` spawns one analyzer child per run on that request's thread, while up to 16 connection threads serve other requests | **Yes**, measured below |
| Standalone (neither) | None: no host store is composed | Verified HDC tool runs | No |

The other spawns are test-only (`host_store.rs` and `host_file_export.rs` under `#[cfg(test)]`) or
not on macOS (`process.rs` for Linux, which has no host store beside it). Session publication
(#1896) takes its Session and publication-shard locks with an unbounded blocking wait, as Swift does,
so it outlasts a spawn window instead of refusing.

## The isolated daemon, measured

A driver (session scratch; described here) seeds a disposable isolated root with the job.run
oracle's source Artifacts (`rust/tests/fixtures/job-run-analyzer/artifacts/job-oracle-source`),
copies the oracle's analyzer outside `/private`, and starts the daemon with
`ARKDECK_DEVELOPMENT_STATE_ROOT`, `ARKDECK_ENDPOINT` and `ARKDECK_ANALYZER_PATH`. One client then
admits and runs 200 analyzer Jobs (`job.submit` of the oracle's `answered` request with a fresh
request id and idempotency key, then `job.run`) while a second client pipelines
`history.filter.list`, 100 frames per connection, until the Jobs are done. Nothing but the daemon
itself takes the History filter lock, so every refusal is a lock the daemon had released.

| Daemon | SHA-256 | `job.run` | History requests | `resourceConflict` | Load average |
| --- | --- | --- | ---: | ---: | --- |
| protected main `ac66aaa3` | `78c713de7f315822…` | 200 succeeded | 733,100 | **227** | 20 → 14 |
| this change on `ac66aaa3` | `62eda3a2d9fcd5e1…` | 200 succeeded | 661,600 | **0** | 14 → 8 |
| protected main `489c7b65` | `1640df34a0e40170…` | 200 succeeded | 258,900 | **595** | 136 → 142 |
| this change on `489c7b65` | `8c0df4aa0bd84dc2…` | 200 succeeded | 266,700 | **0** | 142 → 108 |

## Change

`HostDirectory::lock_document`, `try_lock_existing` and `try_lock_existing_strict` retry
`flock(LOCK_EX | LOCK_NB)` every millisecond while it answers `EWOULDBLOCK`, for at most
`HostDirectory::LOCK_WAIT` = 500 ms, about five times the longest window above, and then refuse
exactly as before (`EWOULDBLOCK`, or `None`), which every owner maps unchanged. Two owners stay
exclusive: each attempt is still an exclusive non-blocking `flock`, and a second live owner is still
refused, only after the wait. Swift's owners of the same files wait without a bound.

Unchanged on purpose: ArkTrace's lock probe `try_trace_lock_existing` (see Residuals), the Job
journal's manifest lock (already retries for 5 s), Session publication's blocking `wait_lock`, and
the facade's transport-directory lock (taken once at startup and never retaken in the process).

## Regression tests (written first, failing before the change)

| Test | Before | After |
| --- | --- | --- |
| `arkdeck-platform` `tests/host_lock_spawn_window.rs` `a_released_lock_a_forked_child_still_shares_is_reacquired_once_the_child_execs`: a child held between fork and exec by `pre_exec`; the test releases the lock, shows one non-blocking attempt is refused, and lets the child exec after 100 ms; all three entry points | `entry 0 refused after 47.459µs` | passes; each acquisition waited ≥ 90 ms |
| same file, `drop_and_reopen_survive_children_another_thread_spawns_in_a_loop`: another thread spawns children that delay their exec by 2 ms; 20,000 release-and-reacquire cycles across the three entry points | `10167 of 20000 reacquisitions refused while 76 children were spawned` | 0 refused |
| same file, `a_live_second_owner_is_still_refused_once_the_wait_has_passed` (added with the change) | — | refused (`EWOULDBLOCK`, `None`) after ≥ 500 ms at each entry point; acquired once the owner drops |
| `arkdeck-agentd` `facade_owners::tests::a_lock_released_within_the_wait_is_taken_instead_of_refused`: the facade's per-request reopen while a second holder releases 100 ms into the request | `resourceConflict` "History filter is being updated" | answered, generation 1 |

"Before" ran on protected main `b547ea29`. The lock code of `host_store.rs` is unchanged through
`ac66aaa3`: #1894 added `seal_document` and #1896 the `session_publication` module declaration. The
spawning tests have a test binary of their own (every other test's locks would be shared with their
children) and live in `arkdeck-platform`: the workspace lint forbids `unsafe` in every other crate
and `pre_exec` is `unsafe`. The facade test therefore uses a second holder instead of a child; both
end the same way for the owner.

Existing tests that hold a lock and expect a refusal still pass, 500 ms later per refused attempt
(`existing_lock_excludes_another_process_and_releases_on_drop`: 0.01 s → 1.0 s). The concurrent-writer
tests that expect one winner and `resourceConflict` for the other still see it, now as the stale
generation after the wait instead of the held lock.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| New tests, repeated | the built `host_lock_spawn_window` test binary, 20 runs at load average 100 – 131 | 20 passed, 3.4 – 3.9 s each |
| Affected crates | `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli --no-fail-fast`, on `b547ea29` and again rebased on `ac66aaa3` | all passed both times |
| Format | `cargo fmt --all --check` | clean |
| Clippy, three targets | `cargo clippy --workspace --all-targets [--target x86_64-pc-windows-msvc \| x86_64-unknown-linux-gnu] -- -D warnings`, rebased on `ac66aaa3` | exit 0 each |

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding `PyYAML==6.0.3` and
`jsonschema==4.26.0`. The planner selected the common checks and the Rust lane: no Swift, App or
design-system lane, because the change touches only `rust/**` and this record. Logs: session scratch
`gate-r1.log` and `gate-r2.log`.

- Final run on commit `51633f1e` (base `fffcaa93`). Common checks: SDD (0 errors, 0 warnings, 121
  acceptance IDs), the catalog generator check and its tests, the planner tests and the agent-PR
  workflow tests. Rust lane: `generate-contract.py --check`, `cargo fmt --check`, warnings-denied
  Clippy, the workspace tests, `test_contract_checks.py`, `check-contracts.py` with both the published
  and the candidate view passing (Clippy, tests, binary builds, the `windows_spk3` process self-test
  and every candidate process harness, `test-macos-facade.py` included), `cargo deny` and `cargo vet`
  (36 fully audited). Every `cargo test` result in the log is ok (132, none failed). The log ends
  `gate exit=0`; 2,091 lines, SHA-256 `7aed55a191f6cf2aa2a45479709cf48ca4da424fb7c3b4da14d0522c65d5fdac`.
  Part of it ran while other sessions held the host at load average up to 170, which slowed unrelated
  suites (`import_upload.rs` 13.1 s and `artifact_read_owner.rs` 35.8 s, against 0.8 s each in the
  first run of the same change); `bootstrap_missing_lock.rs`, whose two refused attempts now wait,
  stayed at its expected 1.0 – 1.2 s.
- First run on commit `cd54fabc` (base `ac66aaa3`), before the rebase over #1897: the same steps, 128
  `cargo test` results all ok, `gate exit=0`, SHA-256
  `56d8529a8668e74081c14e2b168b9dd40ab23be7491a0bb3a93aeb75d044e77c`.

After the final run only this section changed.

## Not run, and why

- Installed activation: the installed facade is not exposed today and this change touches no
  installed state; it reaches installed helpers with the normal helper rebuild.
- The real Swift pair (`check-facade-host-owners.py`): forwarding, lock files and formats are
  unchanged; its foreign-lock-holder step now answers after 500 ms.
- GJ-1: a host-only change; no device is involved.

## Residuals

- `try_trace_lock_existing` keeps ArkTrace's single non-blocking probe. A lease lock held only by a
  spawn window makes that entry look in use, so it is kept, never removed; waiting there would cost up
  to 500 ms for every genuinely leased entry an inventory or purge visits.
- The Swift daemon spawns children too, and its non-blocking locks are open to the same window:
  `BootstrapBundleRegistry` ("another bootstrap operation holds the store"),
  `RuntimeToolSelectionControlActionStore`, `RuntimeHDCControlActionStore`, `SessionAudit` and
  `RuntimeUpdateStateStore`. Not measured or changed here; that code is retired at G5.
- A genuine second owner now waits 500 ms for its refusal, and a process harness that holds a lock
  to check a refusal takes 0.5 s longer per such request.
