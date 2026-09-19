# TASK-XPA-014 — recovery port, slice 2c-a: the capability ledger's `resolvesUnknown` Swift oracle

Change: CHG-2026-074-shared-rust-runtime-core@r11. Part of slice 2 of the recovery port the
maintainer ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`). This records, from Swift, the store the Rust
capability ledger replays once it takes the one outcome rewrite Swift permits, so that the Rust
slice changes no Swift file (r11 rule 10). Host-local only: a test-owned temporary store holds
the two synthetic capabilities; nothing installed is touched.

Base: protected main `78ee48ee` (#2026). Branch `agent/xpa-014-recovery-capability-oracle-20260919`,
no stack. Files:
- `Packages/ArkDeckKit/Tests/ArkDeckContractTests/CapabilityResolveOracleContractTests.swift` (new);
- `rust/tests/fixtures/capability-resolve/` (new: the store's checkpoint, ledger and lock under
  `store/capabilities/`, their kinds and modes in `tree.json`, `cases.json`, `provenance.json`);
- this record.

## Carrier and what was missing

The package's §2 names `Sources/ArkDeckStorage/RuntimeCapabilityStore.swift` 509–543,
`recordOutcome(...)`: outcomes are appended, never replaced; the only permitted change is
`resolvesUnknown` (an `outcomeUnknown` use later settled `confirmed` or `safeToReflash`); any
other change is `outcomeConflict`. The finishing branches of `finishReconcile` rely on it: a
confirmed non-execution records `safeToReflash`, a still-unknown one re-records `outcomeUnknown`.

Rust's `capability_store.rs` `record_outcome` matches Swift line for line except that it refuses
every change, `resolvesUnknown` included; `tests/capability_write.rs` pins that refusal
("cannot change outcomeUnknown to confirmed") as the placeholder while recovery was unported. No
recorded store held a use with two outcomes.

## The oracle

In a test-owned store, two synthetic `debug.hap` capabilities (three uses each):
- `CAP-RT-RESOLVE-CONFIRMED`: use 1 `outcomeUnknown`, then `confirmed` (`failed`); use 2, linked to
  that resolution, `confirmed` (`succeeded`).
- `CAP-RT-RESOLVE-SAFE`: use 1 `outcomeUnknown`, then `safeToReflash` (`failed`); use 2 left
  pending.

The store is laid out as the M2 oracles' stores are (`store/capabilities/`): the checkpoint holds
both capabilities as installed, the ledger every consumption and outcome in order, so the Rust
replay of every ledger event reproduces the two two-outcome uses byte for byte.

`cases.json` records six refused changes, each `outcomeConflict` with Swift's rendering:
confirmed → `outcomeUnknown`, confirmed → `safeToReflash`, safe → confirmed, safe →
`outcomeUnknown`, and confirmed with another terminal state. The test asserts that no refusal
wrote a byte, and that recording the same resolution again at another time writes nothing.

## Local targeted checks

Per `AGENTS.md` on main `d732e798` (#2015) the unified gate is the PR's CI; locally:

| Command | Exit | Result |
| --- | --- | --- |
| `ARKDECK_RUST_CAPABILITY_RESOLVE_RECORD=/private/tmp/arkdeck-capability-resolve-r1 sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter CapabilityResolveOracleContractTests` | 0 | 1 test, 0 failures |
| the same into `…-r2`, `diff -r` against r1 | 0 | 1 test, 0 failures; identical byte for byte |
| compare mode, fixture installed | 0 | 1 test, 0 failures |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

## CI

The PR's `guard` and `swift` aggregate: recorded after the run completes.

## Not in this slice

The Rust `record_outcome` taking `resolvesUnknown` and replaying this store (the next slice), and
the callers that record a resolution (`finishReconcile`'s device-bound branches, the lineage
repairs).
