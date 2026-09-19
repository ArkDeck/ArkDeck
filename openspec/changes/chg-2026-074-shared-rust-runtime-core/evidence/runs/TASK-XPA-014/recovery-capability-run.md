# TASK-XPA-014 — recovery port, slice 2c-b: the capability ledger resolves an unknown outcome

Change: CHG-2026-074-shared-rust-runtime-core@r11. Part of slice 2 of the recovery port the
maintainer ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`): Swift's `RuntimeCapabilityStore.recordOutcome`
rule ported unchanged, replaying the store slice 2c-a recorded
(`recovery-capability-oracle-run.md`). Host-local only: test-owned stores.

Base: protected main `7b5872f1` (#2029). Branch `agent/xpa-014-recovery-capability-20260919`,
stacked on `agent/xpa-014-recovery-capability-oracle-20260919` (slice 2c-a, whose store this
slice replays). Once 2c-a merges, this branch is rebased onto main with only its own commit. No
Swift file changes here.

## Delivered

- `capability_store.rs` `record_outcome`: the one change Swift permits, `resolvesUnknown`. An
  `outcomeUnknown` use may be settled `confirmed` or `safeToReflash`; the settlement is appended
  after the unknown one, digested into the lineage as every outcome is, and written as one ledger
  event. The same outcome again still writes nothing, and every other change is still refused
  with Swift's rendering (`cannot change <current> to <new>`).
- `tests/capability_write.rs`:
  - the byte-for-byte replay of the M2 oracles' stores now also replays `capability-resolve`
    (two uses left unknown, then resolved; one capability used again after its resolution, the
    other left pending), checkpoint, ledger and entries equal to Swift's; a use may carry a second
    outcome only after an unknown first one;
  - the synthetic refusal test no longer pins the placeholder refusal of `outcomeUnknown →
    confirmed`: use 2 still blocks the lineage while unknown, a readback resolves it (the lineage
    shows `[outcomeUnknown, confirmed]` and no longer names it as the blocker), and it cannot go
    back to unknown;
  - `a_resolved_outcome_refuses_every_further_change_as_swift_does`: the six changes Swift refused
    after its resolutions are refused with Swift's rendering, the same resolution again is
    accepted, and none writes a byte.
- `rust/README.md`: the capability paragraph, rewritten in place.

No Rust caller records a resolution yet: `finishReconcile`'s device-bound branches and the
lineage repairs that do are later sub-slices of slice 2. The runner's settlement of the use it
consumed (`mutation_execution.rs`) is unchanged.

## Local targeted checks

Per `AGENTS.md` on main `d732e798` (#2015) the unified gate is the PR's CI. Locally, with
`CARGO_BUILD_JOBS=2`:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy -p arkdeck-hoststore --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-hoststore` | 0 | 384 passed, 0 failed, 12 ignored, 46 test binaries |

Log: scratchpad `logs/checks-s2c.log`, SHA-256
`4cdd84dfb340fb45721c5419030e638e02c01fcf7bf939f987659df711a87ef9`.

## CI

| PR | Head | Runs | Result |
| --- | --- | --- | --- |
| #2034 (stacked on 2c-a, #2033) | `3f7db50e` | 35446195556, 35446195559, 35446195749 | 11 checks passed, `app-build` skipped; merged as `2af5c806`, after #2033 |
