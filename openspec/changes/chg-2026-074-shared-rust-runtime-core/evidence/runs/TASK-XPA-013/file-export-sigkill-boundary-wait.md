# SIGKILL export test waits for its child, not a 5 s budget — macOS, 2026-09-14

TASK-XPA-013 remains in progress. Base: protected main `6cf99fb6`. Test-only change: no product
code, contract, durable format or installed state changes.

## Failure

`host_store::file_export::tests::sigkill_around_publication_preserves_original_or_complete_file_and_restart_never_replays`
(#1874) failed once on 2026-09-14 in `cargo test -p arkdeck-platform -p arkdeck-hoststore -p
arkdeck-agentd -p arkdeck-control -p arkdeck-cli` on this 8-core host (load average about 4–10,
shortly after other sessions' heavy builds), then passed three times alone. The message was not
kept. The test re-executes its own test binary as an export child, gives it 5 s to write a `ready`
marker at the publication boundary, SIGKILLs it, checks the destination and then runs a restart
child that must not replay the export.

## Reproduction

A probe starts the test binary with only this test, finds the export child with
`proc_listchildpids` within about a millisecond of the spawn, and sends SIGSTOP and later SIGCONT to
the child or to the test process. The child needs tens of milliseconds to reach its marker, so the
stop always lands first.

| Unchanged test | Runs | Result |
| --- | ---: | --- |
| No stall | 1 | passed |
| Export child stopped 6 s | 3 | 3 failed: `export child did not reach the publication boundary` (`host_file_export.rs:717`) |
| Test process stopped 6 s | 3 | 3 passed: the child reaches its marker meanwhile, and the loop checks the marker before the clock |
| Export child killed before its marker | 1 | failed: `export child exited before the publication boundary`, without the child's exit status |

Stopping both processes for 6 s failed 1 of 3 runs: the stop can land before the test takes its
deadline right after the spawn returns, so that variant is not used as evidence.

Reaching the marker is real work: a new process, a 512 KiB copy with two digests, `fsync` and
`F_FULLFSYNC`. From the child's first sighting to its marker, 40 export children at load 8.7–10.3
took 70 ms at the median and 244 ms at most. The 5 s budget therefore fails only when a
multi-second stall hits the child, and this host produced one during these runs: at load 24.7 a
test process took 4.9 s from its own exec to its first spawn, the same kind of exec and file work
that the child does.

## Mechanism

It is the wall-clock budget: stopping the child past 5 s gives the exact failure on every run.

The flock-inheritance race cannot produce this failure:

- No process in this test takes a flock. A `DYLD_INSERT_LIBRARIES` interposer that logs every
  `flock(2)` call, and every process that loads it, saw five processes (the test process, two
  export children and two restart children) and no flock call. The same interposer on
  `host_store::publication_tests::process_death_preserves_a_complete_old_or_new_document` logged
  `LOCK_EX | LOCK_NB` in both the test process and its child, and the test process's `LOCK_UN` (the
  child exits while it holds its lock). A child that another test spawns therefore holds nothing
  that these processes need.
- As a spawner, this test cannot break the other tests of the library test binary either. Their
  locks all go through `HostReadLock`, which unlocks before it closes since #1903. The two sites
  that release a lock by closing only, `HostDirectory::append_record` and
  `LocalListener::bind_facade`, are not called by any test in that binary.

Moving the test into its own binary would not change the failure, so it stays where it is.

## Change

- The export test waits up to 60 s, instead of 5 s, for the child's marker or its exit; the bound
  only keeps a hung child from hanging the test. The failure reports the child's exit status, and
  the child's stderr is no longer discarded, so a child that panics before the boundary shows its
  own message.
- `crates/arkdeck-hoststore/tests/import_upload_process_death.rs` (#1890) waits for its helper in
  the same way with a 10 s budget. Stopping its first helper for 11 s failed 3 of 3 runs with
  `child failed before AfterBeginCheckpoint: signal: 9 (SIGKILL)`. It now waits up to 60 s too.

## Checks

| Changed tests | Runs | Result |
| --- | ---: | --- |
| Export child stopped 6 s | 3 | 3 passed |
| Export child stopped 30 s | 1 | passed |
| Test process stopped 6 s | 1 | passed |
| Export child killed before its marker | 1 | failed at once: `export child exited before the publication boundary: signal: 9 (SIGKILL)` |
| Export child made to fail before its marker | 1 | failed at once with the child's own panic, ``called `Result::unwrap()` on an `Err` value: Custom { kind: InvalidData, error: "export source or staging identity changed" }`` at `host_file_export.rs:671`, then `... exit status: 101` (the unchanged test showed only its own line) |
| Import helper stopped 11 s | 3 | 3 passed |
| Import helper killed before its marker | 1 | failed at once: `child failed before AfterBeginCheckpoint: signal: 9 (SIGKILL)` |

To make the child fail, the probe stopped it before it opened its source and hard-linked the
payload (link count 2), which the export refuses.

The command that failed, `cargo test -p arkdeck-platform -p arkdeck-hoststore -p arkdeck-agentd -p
arkdeck-control -p arkdeck-cli`, passed on the changed tree at load 14.5–19.2: 53 test binaries,
451 tests passed, 0 failed, 14 ignored, both changed tests included.

`cargo fmt --all --check` and warnings-denied Clippy for all targets of both crates are clean.

The probe, the interposer and the logs are in this session's scratchpad
(`/private/tmp/claude-501/…/65a43115-826c-4c00-9c97-e9913e959f57/scratchpad`).

Unified local gate: `python3 scripts/ci/plan.py --repo-root . --base-revision origin/main
--head-revision HEAD --merge-base --include-worktree --run-local` on commit `e2e6ac7e` (base
`6cf99fb6`), with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding
`PyYAML==6.0.3` and `jsonschema==4.26.0`, at load 16–51. The planner classified 3 changed files and
selected the common and Rust lanes (no Swift, design-system or App lane): planner tests (31) and
agent-PR workflow tests (12), SDD (0 errors, 0 warnings, 121 acceptance IDs), catalog generator
tests (49) and `--check`; `generate-contract.py --check`, `cargo fmt --all --check`,
warnings-denied Clippy, workspace tests (67 binaries: 522 passed, 0 failed, 14 ignored, both
changed tests included), `test_contract_checks.py` (35 tests OK), `check-contracts.py` passing both
views with every candidate process harness and `test-macos-facade.py` (7 tests OK), `cargo deny`
and `cargo vet` (36 fully audited). The log ends `gate exit=0`, SHA-256
`24df2ea12ba2e18b07b49185fbc016cc4c8f27ec5af989649e6c5d746ae17394`.

Protected main then gained `6b7a79e3` (#1906: one App file, no Rust input), and this change was
rebased onto it. On the rebased commit `f5a6be1b` the common checks passed again: planner tests,
agent-PR workflow tests, SDD, catalog generator tests and `--check`, and `generate-contract.py
--check` (contract identity unchanged, `1d7d101e83fe`). Log SHA-256
`55b2b0313bd21904c11c63f58a2ef20f8bbc0b405e8cf82a655b106ccd646d93`.

## Not run

No device. No Swift, contract or design-system input changed. Other short wall-clock assertions in
the Rust tests (`analyzer_process.rs` `started.elapsed() < 5 s`, `verified_process.rs` `< 2 s`)
assert promptness as the property under test and are not changed here.
