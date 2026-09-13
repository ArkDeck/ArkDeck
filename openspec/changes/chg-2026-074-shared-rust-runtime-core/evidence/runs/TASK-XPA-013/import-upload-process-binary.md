# Import upload SIGKILL test in its own binary — macOS, 2026-09-13

TASK-XPA-013 remains in progress. Base: protected main `dfdb6b68`. Test-only change: no product
code, contract, durable format or installed state changes.

## Failure

Swift CI run 34764599985 (for a change that does not touch Import) failed the macOS Rust workspace:
`crates/arkdeck-hoststore/tests/import_upload.rs`
`partial_and_synced_chunks_recover_only_the_uncommitted_suffix` panicked at
`ImportUploadStore::open(...).unwrap()` with `Os { code: 35, kind: WouldBlock }`, reopening the
Import owner lock right after dropping the previous owner in the same thread. The same test binary's
`sigkill_upload_recovery_uses_only_durable_checkpoints` spawns five `sigkill_upload_helper` child
processes while the binary's other tests run in parallel.

## Mechanism

`HostDirectory::lock_document` takes `flock(LOCK_EX | LOCK_NB)` on an `O_CLOEXEC` descriptor. A C
probe on this host runs one thread that spawns `/usr/bin/true` in a loop while another opens the
lock file, locks it, closes it and immediately reopens and locks it again:

| Spawn | Reopens | `EWOULDBLOCK` |
| --- | ---: | ---: |
| `posix_spawn` | 100,000 | 201 |
| fork and exec | 100,000 | 170 |

A spawned child shares the parent's open-file descriptions until exec closes the close-on-exec
descriptors, so a lock the parent has already released is briefly still held and a non-blocking
reopen fails. Any test in the binary that drops and reopens an owner can fail while the SIGKILL test
spawns. 150 local runs of the unchanged binary, with and without the spawning test, did not
reproduce it (load 2.2 on 8 cores): the window is the spawn itself, so a failure count depends on
load and timing, and the probe is the proof.

## Change

`sigkill_upload_recovery_uses_only_durable_checkpoints` and `sigkill_upload_helper` move unchanged,
with the part of the fixture they use, into `crates/arkdeck-hoststore/tests/import_upload_process_death.rs`.
Cargo runs test binaries one after another. In the new binary the helper is ignored unless the
parent invokes it, and the parent waits for each killed child before it reopens the owner, so no
reopen overlaps a spawn. `tests/import_upload.rs` keeps its other 12 tests and no longer spawns a
process.

Whether a production owner opened per request can meet the same transient refusal (for example the
facade's History filter owner while the facade spawns the paired Swift daemon) is a separate
follow-up; nothing in product code changes here.

## Checks

| Check | Result |
| --- | --- |
| `cargo test -p arkdeck-hoststore --test import_upload --test import_upload_process_death` | 12 passed; 1 passed and the helper ignored |
| `cargo test -p arkdeck-hoststore` | every binary passed (unit tests 120 passed, 5 ignored) |
| Clippy, warnings denied | clean for macOS, Windows and Linux |
| `tests/import_upload.rs` | no `Command`, `current_exe` or SIGKILL test remains |

Those targeted checks are in `/private/tmp/xpa013-process-binary-checks-20260913-r1.log`. The
script's optional stress loop did not run: zsh treats `status` as read-only, so the script stopped
after the checks, all of which had passed.

Unified local gate: `python3 scripts/ci/plan.py --repo-root . --base-revision origin/main
--head-revision HEAD --merge-base --include-worktree --run-local` on commit `98d847f5` (base
`dfdb6b68`), with `ARKDECK_PYTHON` on the SDD venv and the planner started from a venv holding
`PyYAML==6.0.3` and `jsonschema==4.26.0`. The planner classified 3 changed files and selected the
common and Rust lanes (no Swift, design-system or App lane): planner and agent-PR workflow tests,
SDD (0 errors, 0 warnings, 121 acceptance IDs), catalog generator tests and `--check`;
`generate-contract.py --check`, `cargo fmt --all --check`, warnings-denied Clippy, workspace tests,
`test_contract_checks.py` (33 tests OK), `check-contracts.py` passing both views with every
candidate process harness and `test-macos-facade.py` (7 tests OK), `cargo deny` and `cargo vet` (36
fully audited). Log: `/private/tmp/xpa013-process-binary-gate-20260913-r1.log`, ends
`gate exit=0`, SHA-256 `34e88812e2e5009c02b08ac5efebdcebabc1acdc3811aaca122fef295de9d17e`.

## Not run

No device. No Swift, contract or design-system input changed.
