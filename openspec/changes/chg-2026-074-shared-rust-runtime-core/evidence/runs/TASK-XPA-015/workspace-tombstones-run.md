# A workspace project removed after its presets leaves a readable store (TASK-XPA-015, M3)

A defect Swift's and Rust's registration owners shared, fixed in both in one
change, as the 枢纽 and the coordinating session ruled (2026-09-25): remove a
registered project's presets (`workspace.preset.remove`), then the project
(`workspace.project.remove`, which refuses only while an available preset
names the project and so names this order in its own refusal), and the
removed presets' records — their tombstones, which the store keeps so a
removal's replay still answers — name a project the document no longer
holds. Both owners then refused every read of the store: every
`workspace.project.*` and `workspace.preset.*` request answered
`recordUnreadable` (Swift "workspace preset store record is inconsistent",
Rust "workspace project document or storage is inconsistent"), and so did
the daemon's own start-up reads (Swift `startupRecords()` and
`presetCompositionRecords()` in `ArkDeckAgentDaemonMain`; the Rust
composition's, through `with_workspace_operations` in both the development
and the production daemon): **the next daemon start failed**, and nothing a
caller could send repaired the store.

Base: protected `main` `1bfa52054` (#2202; the checks ran on `b954874f2`,
#2200, which carries #2199 — the two later commits touch only `AGENTS.md`,
an agent guide and the CLI tests' support). No stack; independent of #2197. Also carries two follow-ups of #2199's independent
review (below) and records the hosted soak of #2185 in its run record
(`evidence/runs/TASK-XPA-025/snapshot-pager-bounded-run.md` §7).

| Already on `main` | This change | Still remaining |
|---|---|---|
| The registration owner in Swift and Rust, with the same document and answers | The reader accepts a tombstone whose project was removed, in both; Rust answers the preset checks with Swift's messages; the Swift oracle recorded before and after the fix, replayed; regression tests in both | Nothing of this defect; the writer is left as it was (below) |

## The fix: the reader

Each owner validates every preset record when it loads the document. A preset
must name a registered project — unless it is a tombstone: `state` `removed`,
at a generation of 2 or more, every digest and timestamp still as the removal
wrote it. That one shape is accepted with its project gone; any other
inconsistency is refused exactly as before (`recordUnreadable`). A store the
defect already broke therefore reads again on its next access, with no
migration: the document is unchanged.

- Swift `RuntimeWorkspaceProjectStore` (document load): the project-membership
  condition of the per-preset guard becomes `records contains the project ||
  state == "removed"`.
- Rust `workspace_project_presets::record`: the same condition. The same
  function now answers the two Swift refusals the load reaches for a preset
  — "workspace preset state and generation are inconsistent" and "workspace
  preset store record is inconsistent" — instead of the generic "workspace
  project document or storage is inconsistent", so the damaged-store answers
  below are byte for byte Swift's.

**The writer is not changed.** Removing a project could delete or redirect its
tombstones, but a tombstone is what lets the removal's replay answer (the
replay of the preset removal after the project is gone now answers the
tombstone again), the reader fix alone repairs every store already broken,
and a writer change would change the durable document both owners write.

### Tombstones decide nothing

Checked before relaxing the reader, in both owners:

- Admission: a workspace Job acquires its project and presets through
  `acquireUse` / `acquire_use`, which read only `available` presets of a
  registered project; capabilities are matched against the profile's
  facts, never a preset record.
- Composition: `presetCompositionRecords()` / `preset_composition_records()`
  take only `available` presets, so a tombstone neither composes a preset nor
  counts as applied.
- Pins: a preset's toolchain and credential pins are released in the removal's
  own dependency transaction before the tombstone is saved; the credential
  owner's start-up reconciliation reads the composition records.
- The other readers: preset list and show take `available` presets only;
  project update and removal ask whether an `available` preset names the
  project; preset update and removal refuse a removed preset unless the
  request is the replay of its own removal, which answers the tombstone; a
  preset registration repeating a tombstone's request answers the tombstone.

A tombstone is read only to answer its own replays, and never admits, grants,
composes or pins anything, so accepting one whose project is gone widens no
authority.

## The oracle

`WorkspaceTombstoneOracleContractTests` sends, through the production handler
over the registration owner, 15 requests: a project and a symbol preset
registered; the preset removed, then the project; the preset removal
replayed; the project list, the project shown, its presets listed; the same
registration repeated, the list, the presets, the preset registration
repeated; then, with the tombstone's last mutation digest altered in the file,
the list and the presets; the file restored, the list.

- `before-fix-frames.jsonl`, recorded with the owner as it was (the defect's
  evidence): after the project's removal, all 11 answers are
  `recordUnreadable`, "workspace preset store record is inconsistent" —
  including after the file is restored.
- `frames.jsonl`, recorded after the fix, twice, identically, then verified:
  the replay answers the tombstone; the list is empty; the project and its
  presets are `workspaceReferenceNotFound`; the repeated registration
  registers the project again (awaiting a restart), its presets are empty,
  and the repeated preset registration answers the tombstone (`removed`);
  the damaged tombstone is refused (`recordUnreadable`, "workspace preset
  store record is inconsistent"); the restored file reads.

`workspace_tombstone_oracle` (hoststore) replays `frames.jsonl` against the Rust
owner over the same fixed root and clock, damaging and restoring the file at
the same points: every answer byte for byte Swift's and admitted by the
published method schemas. No control method schema changes.

## Follow-ups of #2199's review

- **F1 — the availability oracle's fixed root is serialized.**
  `workspace_availability_oracle` rebuilt and removed
  `/private/tmp/arkdeck-workspace-availability-oracle` without the lock every
  other fixed-root oracle of the crate takes, so two worktrees running the
  hoststore tests at once could remove each other's fixture. It now takes
  `<root>.lock` before the root is rebuilt and releases it after the root is
  removed, as `workspace_read_oracle` does; `workspace_tombstone_oracle`, new
  here, does the same. Checked by running the binary twice at once (both
  pass); a lock is not something a single run can show missing.
- **F2 — an idempotent register replay answers Swift's projection when it
  can.** Swift answers a `workspace.project.register` replay through
  `encodeRegisteredWorkspaceProject`, as `list` answers the project: once the
  start composed the registration, active with what the start published.
  #2199 kept the restart-required projection for every replay (declared),
  because the published register result has `reason` as text only. The
  replay now answers the composed projection whenever its `reason` is text —
  a registration the start did not compose, one that did not resolve, one
  with no operation offered — and keeps the declared restart-required answer
  only when every operation is offered (`reason` `null`). Unit test:
  `a_register_replay_answers_what_the_start_published_when_it_can`.

## Tests

In both implementations:

- the store the removals leave reads again, now and after a restart —
  Swift's start-up reads (`startupRecords()`, `presetCompositionRecords()`)
  and the Rust composition at start-up (`WorkspaceComposition::compose`)
  included — and the removal's replay answers the tombstone;
- only that shape is accepted: the same tombstone with its last mutation
  digest altered, a removed preset at generation 1, and an available preset
  whose project's record was dropped are each refused with Swift's message,
  and nothing is written;
- the removals repeat: the same project registered again, a new preset
  registered and removed, the project removed again, and the store with two
  tombstones still reads.

Swift: `RuntimeWorkspaceProjectStoreContractTests`
(`testAProjectRemovedAfterItsPresetsLeavesAReadableStore`,
`testOnlyARemovedPresetMayOutliveItsProject`,
`testThePresetAndProjectRemovalsCanBeRepeated`). Rust:
`tests/workspace_project.rs` (`a_project_removed_after_its_presets_leaves_a_readable_store`,
`only_a_removed_preset_may_outlive_its_project`,
`the_preset_and_project_removals_can_be_repeated`,
`a_store_left_by_the_removals_composes_at_start_up`).

Mutations (`scratchpad/s28/mutate_e.py`), each caught by a failing test and
restored by checksum:

| Mutation | Caught by |
|---|---|
| a tombstone must name a registered project (the defect) | all four `workspace_project.rs` tests above |
| any preset may outlive its project | `only_a_removed_preset_may_outlive_its_project` |
| the tombstone's own record is no longer checked | `only_a_removed_preset_may_outlive_its_project` |
| a damaged preset answers the generic message | `only_a_removed_preset_may_outlive_its_project` |
| a state its generation cannot have answers the generic message | `only_a_removed_preset_may_outlive_its_project` |
| a register replay always awaits a restart (F2) | `a_register_replay_answers_what_the_start_published_when_it_can` |

6/6 caught (`/private/tmp/arkdeck-s28-e-mutations.log`). The cargo run of a
mutation stops at the first failing test binary, so the oracle replay
(`workspace_tombstone_oracle`) is listed for none; run alone against the
first mutation it fails too.

## Local targeted checks

With `CARGO_BUILD_JOBS=2` and this tree's own target; logs are
`/private/tmp/arkdeck-s28-e-*.log`. The Rust checks ran again after the
rebase onto `b954874f2` with F1 and F2 in.

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak
  --all-targets -- -D warnings`: exit 0; the same with `--target
  x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc`: exit 0, 0.
- `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak
  --no-fail-fast`: exit 0; 109 targets, 821 passed, 0 failed, 14 ignored
  (existing) (`-test-2.log`). The run before it (`-test.log`) failed one test
  of #2190, `workspace_read_oracle::the_host_tools_answer_the_reads_as_they_answer_directly`
  (the host's `/usr/bin/git` status Job `failed`), with the 1-minute load at
  8–9 from other sessions' builds; it passed alone three times and in the
  full re-run, and nothing here touches the reads — recorded as an invalid
  run.
- Swift: the recording before the fix
  (`ARKDECK_RUST_WORKSPACE_TOMBSTONE_RECORD=<dir> sh
  Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  WorkspaceTombstoneOracleContractTests`): exit 0, 15 frames
  (`-before.log`); after the fix, twice (identical): exit 0, 0 (`-rec1.log`,
  `-rec2.log`); then `--filter
  '(WorkspaceTombstoneOracleContractTests|RuntimeWorkspaceProjectStoreContractTests)'`
  in verify mode: exit 0, 17 tests (`-verify.log`); and, with the start-up
  assertions added, `--filter
  '(WorkspaceTombstoneOracleContractTests|RuntimeWorkspaceProjectStoreContractTests|HostOnlyAdmissionContractTests|RuntimeOwnedWorkspaceContractTests)'`:
  exit 0, 39 tests, 0 failures (`-swift-regression.log`). No Swift file this
  change touches moved in the rebase (main added only #2199's availability
  oracle, which removes no project).
- The availability oracle run twice at once, sharing the target: both pass
  (`-f1-a.log`, `-f1-b.log`).
- `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `check-readonly.py
  --bin-dir <target>/debug` (validation venv): exit 0, PASS.
- Mutations: 6/6 caught.
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: `generate-contract.py --check` and `check-contracts.py` (no
  contract input changes: no schema, corpus or Catalog), the App, devices, the
  installed service.

## CI

Pending.
