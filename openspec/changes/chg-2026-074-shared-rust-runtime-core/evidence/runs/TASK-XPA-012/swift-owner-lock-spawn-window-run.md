# Swift non-blocking owner locks while children are spawned — macOS, 2026-09-14

TASK-XPA-012 remains in progress. Base: protected main `c8d20163` (#1899). The residuals of
[host-lock-spawn-window-run.md](host-lock-spawn-window-run.md) (#1899) list five Swift owners that take
`flock(LOCK_EX | LOCK_NB)` and refuse at once as open to the same spawn window. They are not: each one
releases with `flock(LOCK_UN)` before it closes, and an explicit unlock ends the lock for every holder
of the open file description, including a child that still shares it. This change adds regression
tests and this record. It changes no product code, durable format, lock file, method, schema, CLI leaf,
entitlement or installed state. Every fixture is disposable host data; nothing here is device evidence.
The measurements ran on `fffcaa93`; no file under `Packages/ArkDeckKit/Sources` changed from there to
`c8d20163`.

## Already on main / this change / still remaining

| Already on main | This change | Still remaining for TASK-XPA-012 |
| --- | --- | --- |
| The Rust owners retry `flock(LOCK_EX \| LOCK_NB)` for up to 500 ms before refusing (#1899); that record lists the five Swift owners as exposed | Measurements showing the Swift owners are not exposed and why; five regression tests that fail if an owner stops unlocking before it closes | Rust: release with `flock(LOCK_UN)` before close (see Residuals); otherwise as in `facade-history-owner-run.md` |

## Mechanism: unlock versus close

A child spawned by another thread shares every open file description of its parent until its exec
closes the close-on-exec ones, and a `flock` belongs to the open file description. What happens to a
lock the parent gives up in that window depends on how it gives it up:

- `close(fd)` alone drops the parent's reference. The description, and its lock, live on in the child
  until its exec; a non-blocking attempt through a new description fails with `EWOULDBLOCK`. The Rust
  `HostReadLock` is released this way (it has no `Drop`, and no Rust crate calls `LOCK_UN`).
- `flock(fd, LOCK_UN)` releases the lock of the description itself. XNU keys `flock` locks by the
  file's `fileglob`, which the child's copy shares, so the lock is gone for the child too, and a new
  description acquires it at once. Every Swift owner below does this before it closes.

A C probe (session scratch) shows both outcomes deterministically. The parent locks a file, a child
takes a reference to that description, the parent gives the lock up, and a new description then tries
`flock(LOCK_EX | LOCK_NB)` while the child is still alive:

```c
int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
flock(fd, LOCK_EX | LOCK_NB);                     /* acquired */
pid = fork();                                     /* child: read(pipe), then execl() */
if (explicit_unlock) flock(fd, LOCK_UN);
close(fd);
int again = open(path, O_RDWR | O_CLOEXEC);
flock(again, LOCK_EX | LOCK_NB);                  /* while the child waits before its exec */
```

Apple M3, 8 cores, macOS 26.6.2.

| Child holding the description | Parent gives the lock up by | Attempt while the child lives | After the child exits |
| --- | --- | --- | --- |
| `fork`, stopped before `exec` | `close` | `EWOULDBLOCK` | acquired |
| `fork`, stopped before `exec` | `flock(LOCK_UN)`, then `close` | acquired | — |
| `posix_spawn`, description inherited (`posix_spawn_file_actions_addinherit_np`) | `close` | `EWOULDBLOCK` | acquired |
| `posix_spawn`, description inherited | `flock(LOCK_UN)`, then `close` | acquired | — |

The second probe counts refusals the way the Rust record does. One thread spawns `/usr/bin/true` in
a loop with the flags `ArkDeckProcess` uses for the Swift daemon's children
(`POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_START_SUSPENDED`, then `SIGCONT`); the main thread takes and
gives up an owner lock through a new `O_CLOEXEC` description 100,000 times and times each refusal
until the lock comes free. "Busy" adds that many spinning threads.

| Release | Busy | Spawns | Refused | Held p50 | Held p99 | Held max | Load average |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `close` | 0 | 1,523 | 65 | 0.04 ms | 0.28 ms | 0.28 ms | 12 |
| `flock(LOCK_UN)`, `close` | 0 | 1,571 | **0** | — | — | — | 12 |
| `close` | 16 | 1,995 | 85 | 1.10 ms | 54.3 ms | 54.3 ms | 16 |
| `flock(LOCK_UN)`, `close` | 16 | 1,787 | **0** | — | — | — | 20 |

The #1899 session reproduced the same split with its own probe, including the production Rust spawn
flags (`POSIX_SPAWN_CLOEXEC_DEFAULT | START_SUSPENDED | SETPGROUP`).

## The Swift owners

| Owner | Lock, and how long it is held | Released by | Process, and children spawned meanwhile | Exposed |
| --- | --- | --- | --- | --- |
| `BootstrapBundleRegistry.locked` (`ArkDeckBootstrap`) | `Bootstrap/v1/.lock` under the current user's home, for one operation: register, inspect, list, remove, acquire, release, retain-only, release-all and `withSharedStore`, through which `BootstrapToolRegistry` and `BootstrapDevEcoToolchainRegistry` work | `defer { flock(lock, LOCK_UN) }`, declared after `defer { close(lock) }`, so it runs first | Swift daemon (a new registry per Bootstrap RPC; workspace preset toolchain pins), Swift CLI, service install and removal. The daemon serves every connection on its own task and runs HDC, analyzer and toolchain children through `ArkDeckProcess` meanwhile | No |
| `RuntimeToolSelectionControlActionStore.transaction` (`ArkDeckStorage`) | `tool-selection-control-actions/records/.lock` in the daemon state directory, for one begin, load, list or replace; transactions of one process also queue on an `NSLock` | `defer { flock(lock, LOCK_UN) }` before `defer { Darwin.close(lock) }` | Swift daemon (`RuntimeToolSelectionCoordinator`), which starts HDC servers with the selected tool | No |
| `RuntimeHDCControlActionStore.transaction` (`ArkDeckStorage`) | `hdc-control-actions/records/.lock` in the daemon state directory, as above | as above | Swift daemon (`RuntimeHDCControlActionCoordinator`), whose actions restart the HDC server | No |
| `FileDurableSessionAuditStore` (`ArkDeckStorage`) | the Session's `audit/session.jsonl`, for the writer's lifetime; a second writer of the same Session is refused by design | `deinit`: `flock(descriptor, LOCK_UN)`, then `close`; the initializer's failure path unlocks first too | Swift daemon: Session publication (`RuntimeSessionPublication`). App: the HDC diagnostics lifecycle audit (`HDCServerLifecycleJournalAdapter`, through `HDCApplicationDiagnosticsFacade`). One writer per Session | No |
| `RuntimeUpdateStateStore.acquireOperationLease` (`ArkDeckWorkflows`) | `AutoUpdateLifecycle/.operation-v1.lock`, for one update check, download or hand-off; `operationIsActive()` takes and drops it | `RuntimeUpdateOperationLease.deinit`: `flock(descriptor, LOCK_UN)`, then `close` | The App and the Swift CLI (`AutoUpdateApplicationFacade.make()`), not the daemon | No |

Two other Swift locks also use `LOCK_NB` and unlock the same way: `SystemLogger` (its directory and
`.writer.lock`, held for the writer's lifetime, unlocked in `deinit` and in the initializer's failure
path) and the daemon's `instance.lock` (taken once at start, unlocked in `stop`). The new tests do not
cover them. Every Swift source file that takes a `flock` (25 acquisitions in 21 files) also calls
`LOCK_UN` at least as often; the blocking acquirers would only wait anyway.

Each of the five refuses only a holder that is genuinely concurrent, which is what their messages
("another bootstrap operation holds the store; retry after it completes", "another Runtime owner holds
the control-action transaction", "Session audit already has an active writer",
`operationInProgress`) describe. A bounded wait there would only delay those designed refusals, so
there is nothing to fix. Whether a Rust owner already replaces a store changes nothing:

- Bootstrap: the isolated Rust owner serves inspect, list, register and retire; the installed product
  still uses the Swift owner until the installed composition moves.
- Tool selection and HDC control actions: no Rust owner yet (tool selection writes remain in
  TASK-XPA-012; the HDC server lifecycle is TASK-XPA-016).
- Session audit: the isolated Rust owner publishes Sessions (#1896); the installed product publishes
  through the Swift daemon.
- Update state: owned by the App and the CLI, not by a daemon; it moves with the App's departure from
  `ArkDeckWorkflows` (TASK-XPA-019).

The tests below take 0.06 s and stay until each store is deleted (TASK-XPA-017 for the daemon's
stores). They are what fails if a later edit releases one of these locks by `close` alone, which is
the Rust owners' failure mode.

## Regression tests

`Tests/ArkDeckContractTests/OwnerLockSpawnWindowContractTests.swift`, one test per owner. A child
spawned with `POSIX_SPAWN_CLOEXEC_DEFAULT` inherits (`posix_spawn_file_actions_addinherit_np`) every
descriptor the test process has open on the owner's lock file and waits on its standard input: the
fork-to-exec window, held for as long as the test needs. The owner then gives its lock up, and its next
non-blocking acquisition must succeed while the child still holds the description. The Bootstrap child
is spawned inside `withSharedStore`; the control-action stores take no callback, so a FIFO named like a
record (`action-<64 zeros>.json`) holds `list()` inside its locked transaction until the child is
spawned, after which the transaction refuses the non-regular record (`recordUnreadable`) and releases;
the Session audit writer and the update lease hold their locks for their lifetime. Each test also has a
control: the test locks the same file through a description of its own, lets a child inherit it,
closes it without unlocking, and the owner refuses (`resourceConflict`, "active writer",
`operationIsActive() == true`) until the child exits.

| Test | Protected main | Unlock removed (mutation) |
| --- | --- | --- |
| `testBootstrapOwnerIsNotRefusedWhileAChildStillSharesItsReleasedLock` | passes | fails: `resourceConflict` "another bootstrap operation holds the store; retry after it completes" |
| `testHDCControlActionStoreIsNotRefusedWhileAChildStillSharesItsReleasedLock` | passes | fails: `resourceConflict` "another Runtime owner holds the control-action transaction" |
| `testToolSelectionControlActionStoreIsNotRefusedWhileAChildStillSharesItsReleasedLock` | passes | fails: `resourceConflict` "another Runtime owner holds the control-action transaction" |
| `testSessionAuditWriterIsNotRefusedWhileAChildStillSharesItsReleasedLock` | passes | fails: "Session audit already has an active writer:errno=35" |
| `testUpdateOperationLeaseIsNotReportedActiveWhileAChildStillSharesItsReleasedLock` | passes | fails: `operationIsActive()` is true and the lease is refused (`operationInProgress`) |

The task asked for a regression test that fails today. None can: the property holds on protected
main. The mutation removes exactly the five explicit unlocks (`BootstrapBundleRegistry.swift`,
`RuntimeToolSelectionControlActionStore.swift`, `RuntimeHDCControlActionStore.swift`,
`SessionAudit.swift` `deinit`, `RuntimeUpdateStateStore.swift` lease `deinit`; one deleted line each,
patch SHA-256 `eda72d60…`), which leaves each lock to `close` alone, as the Rust owners had it; it was
reverted afterwards.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| New tests | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter OwnerLockSpawnWindowContractTests` | 5 passed, 0.063 s |
| Mutation | the same, with the five unlocks removed | 5 of 5 failed (6 assertion failures), each at the acquisition made while the child holds the description; the controls still passed; reverted |
| Final text | the same, after the gate, on the committed test file | 5 passed, 0.091 s |
| Format | `xcrun swift-format lint` on the test file | no findings |

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`,
with `ARKDECK_PYTHON` on the SDD venv, on commit `2cb700ed` (base `c8d20163`). The planner selected the
common checks, the Swift lane and the design-system lane; no Rust or App lane.

- Common: SDD (0 errors, 0 warnings, 121 acceptance IDs), the planner and contract-check tests, the
  agent-PR workflow tests, and the catalog generator check and its tests.
- Design system: `npm ci` and `npm test`.
- Swift: `test_run_swiftpm.py`, then `run-test-lane.sh full`: 2,660 tests in parallel (211 s), then the
  serialized process-identity race test and the five viewer-scale tests, each lane `exitCode=0`.
- The log ends `rc=0`; 3,333 lines, SHA-256
  `2a69742b9078bb2ca7f7e208f06791d428a0070adbf162ecc1941a3da88dcf92` (session scratch `gate-r1.log`).
  Load average 37 → 52 while it ran.

The final commit differs from `2cb700ed` only in this record and in formatting of the test file (three
lines wrapped at 100 columns and one `forEach` turned into a `for` loop, as `swift-format lint`
asks); the test class was run again on that text (see Checks).

## Not run, and why

- A real Swift daemon under load, as the Rust record did: the Bootstrap owner resolves its root from
  the password database (it ignores `HOME` and `CFFIXED_USER_HOME` on purpose), so a daemon run would
  touch the installed user's Bootstrap store, and the control-action stores need an HDC server host.
  The tests drive the owners' own lock code, and the probes measure the mechanism.
- Installed activation and GJ-1: host-only; nothing installed changes and no device is involved.

## Residuals

- The Rust owners give their locks up by `close` alone and, since #1899, retry for up to 500 ms. An
  explicit `flock(LOCK_UN)` before the close removes the window where it starts, needs no wait (a
  genuine second owner is refused at once again), and also covers an acquirer the Rust retry cannot:
  a non-blocking Swift owner meeting a Rust owner's close-only release. The #1899 session confirmed
  this with its own probe and is changing the Rust `HostReadLock` in a follow-up PR, which also
  corrects the residual of `host-lock-spawn-window-run.md` that lists the five Swift owners as exposed.
- `SystemLogger` and the daemon's `instance.lock` release the same way but have no test here.
