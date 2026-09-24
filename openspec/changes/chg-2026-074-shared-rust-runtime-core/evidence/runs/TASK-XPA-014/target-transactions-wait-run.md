# Target owner transactions wait for each other's locks

TASK-XPA-014 / CHG-2026-074. Found while adding the device mutation lane
(`agent/xpa-014-device-mutation-lane`); not seen in CI. Disposable host data only;
nothing here is device evidence.

## Failure

`TargetStore::publishing` (`rust/crates/arkdeck-hoststore/src/target_owner.rs`) runs
every Target owner transaction: `hdc_route`, `target.list` and `target.show`, display
and candidate names, adoption, Import binding, and on the lane branch
`mutation_lane_key`. It took `.targets.lock` and `.target-display-names.lock` through
`HostDirectory::lock_document`, which is `flock(LOCK_EX | LOCK_NB)`. A `flock` belongs
to the open file description, so a transaction that began while another held the
locks was refused at once with `Target storage is being updated` or `Display names
are being updated` (`resourceConflict`, or `internalError` for the empty phase). That
holds for another thread of the daemon's one owner, which opens its own descriptor,
as much as for another owner of the directory.

Two device Jobs on different Targets, or a Job beside a `target.list`, a
`device.observations` or the App's poll, could then fail `hdc.facts()`
(`device_facts.rs` → `hdc_route`). That fails an evidence step
(`evidenceIncomplete: descriptor-bound target facts unavailable: …`) or refuses a lane
entry with zero dispatch.

## Swift

- `RuntimeTargetStore` (`ArkDeckWorkflows/Bootstrap/DeviceBootstrap.swift`) serializes
  its calls on one `DispatchQueue` (`queue.sync`). Its `persist` takes `.targets.lock`
  with a blocking `flock(lockFD, LOCK_EX)`; `load()` reads under no lock.
- `RuntimeTargetDisplayNameStore.withLockedDocument` takes
  `.target-display-names.lock` with a blocking `flock(lock, LOCK_EX)`, retrying `EINTR`.
- `RuntimeJobEngine.recoveryEpochIndexes` opens a second `RuntimeTargetStore` on the
  same directory inside the daemon; only the blocking `flock` orders it with the
  daemon's own store.

So Swift never refuses a Target transaction because a lock is held, whether the
holder is the same store, another store or another process.

## Change

- `publishing` takes both locks with `HostDirectory::wait_lock(name, false)`: a
  blocking `flock(LOCK_EX)` with `EINTR` retried, the lock created 0600 when absent
  and never synchronized. The capability store, the post-Flash alias store, recovery
  epochs and the Session status read already use it for Swift's blocking locks. Each
  transaction opens its own descriptor, so the wait orders the threads of one owner as
  well as other owners and processes. No separate in-process mutex was added: it would
  duplicate that wait and, being per owner, would not cover a second owner such as
  Swift's engine store.
- Any other lock failure stays `recordUnreadable`. The two refusal messages are gone;
  no frame, schema, fixture or test matched on them.
- No transaction starts another one. Every closure reads or edits only the two
  documents it is handed, and `hdc_route` and `resolve_import_binding` read the live
  candidates before the locks. With waiting locks a nested transaction would wait for
  itself, which the documentation of `publishing` now states. On the lane branch,
  `mutation_lane_key`'s closure is as pure, and `enter_mutation_lane` enters the lane
  only after that transaction returns: lane then locks, never the other way round.
- Across processes a held lock is now waited for, as Swift waits, where it was
  refused. In production the daemon's instance lock leaves it the only process in
  `targets-state/`.

## Test

`target_owner::tests::overlapping_transactions_wait_for_each_other`: two threads meet
at a `Barrier` before each of 64 rounds. One reads `hdc_route(CANONICAL)` over the
`import-target-current/alias` fixture. The other sets the canonical Target's display
name along a compare-and-swap chain, whose publication (`F_FULLFSYNC`) holds both locks
for milliseconds. It runs over one owner, then over two owners of one directory. Every
route must be revision 2 through `post-flash-hdc-address`, and every write must return
the next generation. No sleeps.

- `72fd46b63` with only the test added: failed 5 of 5 runs in the one-owner pass,
  either on the write (`resourceConflict`, `Target storage is being updated`, phase
  `targetDisplayNameOwner`) or on the route (`Err("Target storage is being updated")`).
- With the change: `target_owner::tests` passed 5 of 5 runs (9 tests, 0.87–0.96 s).

## Local targeted checks

Logs are in this session's scratchpad,
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-claim-credit-endpoint-69af1c/9233b2dd-55e5-444d-aaec-22d45494fbe3/scratchpad/`.

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0.
- `CARGO_BUILD_JOBS=2 cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-hoststore
  -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`: exit 0; `clippy.log`.
- `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-hoststore
  -p arkdeck-agentd -p arkdeck-soak --no-fail-fast`: exit 101, 79 test binaries, 676
  passed, 3 failed, 14 ignored; `test.log`. The three failures were
  `import_publication_process`, `managed_hdc_process` and `production_composition`
  of `arkdeck-agentd`. Each spawns the `arkdeck` CLI from the target directory, which a
  `-p`-scoped run does not build, and each failed with `NotFound`. After
  `cargo build -p arkdeck-cli` (exit 0), rerunning those three binaries with
  `cargo test -p arkdeck-agentd --test import_publication_process --test
  managed_hdc_process --test production_composition`: exit 0, 19 passed;
  `test-agentd-cli.log`.
- `ARKDECK_PYTHON=/private/tmp/arkdeck-validation-venv/bin/python sh
  scripts/check-sdd.sh`: exit 0, 0 errors, 0 warnings; `sdd.log`.

## CI

Pending when this was committed.
